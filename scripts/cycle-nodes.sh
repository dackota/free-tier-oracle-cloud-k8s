#!/usr/bin/env bash
#
# cycle-nodes.sh -- safely roll the OKE worker nodes onto a new node-pool
# template (new Kubernetes version and/or node image), one node at a time.
#
# WHEN TO RUN THIS
#   AFTER a `terraform apply` that bumped the cluster's kubernetes_version (see
#   docs/kubernetes-upgrades.md). That apply upgrades the *control plane* and
#   updates the node-pool *template*, but it does NOT touch running worker
#   nodes -- they keep their old version/image until they are replaced. This
#   script performs that replacement.
#
# WHY IT IS CAREFUL (this cluster's specific constraints)
#   * Free tier is at the FULL Always-Free allowance (2x A1 nodes, 4 OCPU /
#     24 GB, exactly 200 GB / 2 boot volumes). There is NO room for a surge
#     node, so nodes are replaced strictly ONE AT A TIME, in place. Terminate
#     ALWAYS passes --preserve-boot-volume false: a leaked 100 GB boot volume
#     would push the account to 3 volumes / 300 GB, breach the block-storage
#     cap, and block the replacement node from ever launching.
#   * Longhorn holds real data (the change-tracking-dashboard SQLite volume).
#     Before draining any node this script GATES on every Longhorn volume
#     being `healthy`. With the default node-drain-policy
#     (block-if-contains-last-replica), that same gate is what lets Longhorn
#     release the instance-manager PodDisruptionBudget so the drain can finish
#     -- the drained node, by construction, never holds a volume's last
#     replica. Between nodes we wait for volumes to rebuild back to `healthy`
#     before touching the next one -- and we delete the terminated node's now-
#     stale replica so Longhorn rebuilds immediately instead of waiting out
#     replica-replenishment-wait-interval (600s).
#   * A1 capacity is scarce ("Out of host capacity"); OKE retries the
#     replacement internally. We wait patiently (READY_TIMEOUT) rather than
#     failing fast.
#
# INVARIANTS
#   * At most one node is unschedulable/absent at any moment.
#   * A node is never drained while any Longhorn volume is degraded.
#   * A node already at TARGET_VERSION is left untouched (idempotent: safe to
#     re-run after an interruption -- it resumes with whatever is left).
#
# USAGE
#   scripts/cycle-nodes.sh [--yes] [--dry-run] [--context CTX] [--region R]
#                          [--target vX.Y.Z]
#
#   # typical, right after the apply:
#   scripts/cycle-nodes.sh
#
#   # non-interactive (e.g. wrapped in the capacity-retry helper is NOT needed
#   # here -- OKE handles replacement retries itself):
#   scripts/cycle-nodes.sh --yes
#
# ENVIRONMENT / FLAGS (flags win over env; defaults shown)
#   --context CTX  / KCONTEXT       kube context            (oci-home-lab)
#   --region R     / OCI_REGION     OCI region for terminate (us-phoenix-1)
#   --target V     / TARGET_VERSION kubelet version to reach (control-plane
#                                   server version, auto-detected if unset)
#   --dry-run      / DRY_RUN=1      print actions, mutate nothing
#   --yes          / ASSUME_YES=1   do not prompt before terminating a node
#   DRAIN_TIMEOUT  (default 600)    seconds for `kubectl drain`
#   READY_TIMEOUT  (default 2700)   seconds to wait for a replacement node
#   LH_TIMEOUT     (default 1200)   seconds to wait for Longhorn to heal
set -euo pipefail

CONTEXT="${KCONTEXT:-oci-home-lab}"
REGION="${OCI_REGION:-us-phoenix-1}"
TARGET_VERSION="${TARGET_VERSION:-}"
DRY_RUN="${DRY_RUN:-0}"
ASSUME_YES="${ASSUME_YES:-0}"
DRAIN_TIMEOUT="${DRAIN_TIMEOUT:-600}"
READY_TIMEOUT="${READY_TIMEOUT:-2700}"
LH_TIMEOUT="${LH_TIMEOUT:-1200}"
POLL="${POLL:-15}" # seconds between status polls

while [ "$#" -gt 0 ]; do
  case "$1" in
    --yes) ASSUME_YES=1 ;;
    --dry-run) DRY_RUN=1 ;;
    --context) CONTEXT="$2"; shift ;;
    --region) REGION="$2"; shift ;;
    --target) TARGET_VERSION="$2"; shift ;;
    -h|--help) sed -n '2,60p' "$0"; exit 0 ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
  shift
done

# --- Hard rule for this repo: never rely on the active kube context. -----------
kc() { kubectl --context "$CONTEXT" "$@"; }
log() { printf '\n\033[1m== %s\033[0m\n' "$*"; }
info() { printf '   %s\n' "$*"; }
die() { printf '\033[31mERROR: %s\033[0m\n' "$*" >&2; exit 1; }

run() { # echo + execute, or just echo under --dry-run
  info "\$ $*"
  [ "$DRY_RUN" = "1" ] && return 0
  "$@"
}

confirm() { # confirm "prompt" -> honored unless ASSUME_YES
  [ "$ASSUME_YES" = "1" ] && return 0
  [ "$DRY_RUN" = "1" ] && return 0
  read -r -p "   $1 [y/N] " reply
  [ "$reply" = "y" ] || [ "$reply" = "Y" ]
}

# --- Longhorn helpers ---------------------------------------------------------
lh_present() { kc get ns longhorn-system >/dev/null 2>&1; }

lh_unhealthy_count() {
  # Number of Longhorn volumes whose robustness is not "healthy". 0 if none.
  kc -n longhorn-system get volumes.longhorn.io -o json 2>/dev/null \
    | jq '[.items[] | select(.status.robustness != "healthy")] | length'
}

wait_lh_healthy() {
  lh_present || { info "Longhorn not installed; skipping volume gate."; return 0; }
  local deadline=$((SECONDS + LH_TIMEOUT)) bad
  while :; do
    bad="$(lh_unhealthy_count)"
    [ "$bad" = "0" ] && { info "All Longhorn volumes healthy."; return 0; }
    [ "$SECONDS" -ge "$deadline" ] && die "Longhorn still has $bad unhealthy volume(s) after ${LH_TIMEOUT}s."
    info "Waiting for Longhorn to heal ($bad volume(s) not healthy)..."
    sleep "$POLL"
  done
}

# After a node is terminated, Longhorn keeps its replica as a `stopped` replica
# pinned to the now-deleted node and, by default, waits
# `replica-replenishment-wait-interval` (600s) before rebuilding it elsewhere --
# so Gate 3 would otherwise idle ~10 min per node. Deleting the stale replica
# (its data is safe on the surviving healthy replica) forces an immediate
# rebuild on the fresh node. Only replicas whose node has left the cluster are
# touched, so a healthy replica is never removed.
clear_stale_longhorn_replicas() {
  lh_present || return 0
  local live stale r
  live="$(kc get nodes -o jsonpath='{.items[*].metadata.name}')"
  stale="$(kc -n longhorn-system get replicas.longhorn.io -o json 2>/dev/null \
    | jq -r --arg live "$live" '
        ($live | split(" ")) as $nodes
        | .items[]
        | select(.spec.nodeID != null and .spec.nodeID != "")
        | select([.spec.nodeID] - $nodes | length > 0)
        | .metadata.name')"
  for r in $stale; do
    info "Clearing stale Longhorn replica $r (its node has left the cluster)."
    run kc -n longhorn-system delete replica.longhorn.io "$r"
  done
}

# --- Node helpers -------------------------------------------------------------
ready_node_count() {
  kc get nodes -o json | jq '[.items[] | select(any(.status.conditions[]; .type=="Ready" and .status=="True"))] | length'
}

node_count() { kc get nodes -o json | jq '.items | length'; }

instance_ocid_for_node() { kc get node "$1" -o jsonpath='{.spec.providerID}'; }

# Nodes whose kubelet is not yet at TARGET_VERSION, volume-holder LAST so the
# stateful pod moves as few times as possible.
nodes_needing_cycle() {
  local holder=""
  if lh_present; then
    holder="$(kc -n longhorn-system get volumes.longhorn.io -o json 2>/dev/null \
      | jq -r '[.items[].status.currentNodeID] | map(select(. != null and . != "")) | first // ""')"
  fi
  kc get nodes -o json | jq -r --arg tgt "$TARGET_VERSION" --arg holder "$holder" '
    [ .items[]
      | select(.status.nodeInfo.kubeletVersion != $tgt)
      | .metadata.name ]
    | sort_by(. == $holder)   # false(0) before true(1): holder sorts last
    | .[]'
}

# Real (non-DaemonSet, non-Longhorn-system, non-completed) pods still bound to a
# node -- used to decide whether a drain genuinely finished.
stuck_workload_pods() {
  kc get pods -A --field-selector "spec.nodeName=$1" -o json | jq -r '
    [ .items[]
      | select((.metadata.ownerReferences // []) | any(.kind=="DaemonSet") | not)
      | select(.metadata.namespace != "longhorn-system")
      | select(.status.phase != "Succeeded" and .status.phase != "Failed")
      | "\(.metadata.namespace)/\(.metadata.name)" ]
    | .[]'
}

wait_for_replacement() {
  # Wait until the terminated instance's node object is gone and the pool is
  # back to full strength with all nodes Ready.
  local old_ocid="$1" want_nodes="$2"
  local deadline=$((SECONDS + READY_TIMEOUT))
  while :; do
    local nodes ready still_present
    nodes="$(node_count)"; ready="$(ready_node_count)"
    still_present="$(kc get nodes -o jsonpath="{range .items[*]}{.spec.providerID}{'\n'}{end}" | grep -Fc "$old_ocid" || true)"
    if [ "$still_present" = "0" ] && [ "$nodes" = "$want_nodes" ] && [ "$ready" = "$want_nodes" ]; then
      info "Replacement is up: ${ready}/${want_nodes} nodes Ready, old instance gone."
      return 0
    fi
    [ "$SECONDS" -ge "$deadline" ] && die "Replacement not Ready after ${READY_TIMEOUT}s (nodes=$nodes ready=$ready old_present=$still_present). A1 capacity may be scarce; re-run to resume."
    info "Waiting for replacement (nodes=$nodes ready=$ready, old instance present=$still_present)..."
    sleep "$POLL"
  done
}

# --- Preflight ----------------------------------------------------------------
command -v kubectl >/dev/null || die "kubectl not found on PATH"
command -v oci >/dev/null || die "oci CLI not found on PATH (needed to terminate instances)"
command -v jq >/dev/null || die "jq not found on PATH"
kc version >/dev/null 2>&1 || die "cannot reach cluster via context '$CONTEXT'"

SERVER_VERSION="$(kc version -o json | jq -r '.serverVersion.gitVersion')"
[ -n "$TARGET_VERSION" ] || TARGET_VERSION="$SERVER_VERSION"

EXPECTED_NODES="$(node_count)"
mapfile -t TO_CYCLE < <(nodes_needing_cycle)

log "Node cycle plan"
info "context        : $CONTEXT"
info "region         : $REGION"
info "control plane  : $SERVER_VERSION"
info "target kubelet : $TARGET_VERSION"
info "expected nodes : $EXPECTED_NODES"
info "dry-run        : $DRY_RUN"
if [ "$SERVER_VERSION" != "$TARGET_VERSION" ]; then
  info "NOTE: target ($TARGET_VERSION) != control plane ($SERVER_VERSION); that is unusual for a post-apply cycle."
fi
if [ "${#TO_CYCLE[@]}" -eq 0 ]; then
  log "Nothing to do -- every node is already at $TARGET_VERSION."
  exit 0
fi
info "nodes to cycle : ${TO_CYCLE[*]}"

confirm "Proceed to cycle ${#TO_CYCLE[@]} node(s), one at a time?" || die "Aborted by operator."

# --- Main loop: one node at a time --------------------------------------------
for node in "${TO_CYCLE[@]}"; do
  log "Cycling node $node"

  # Re-check the node still needs cycling (a prior partial run may have done it).
  cur="$(kc get node "$node" -o jsonpath='{.status.nodeInfo.kubeletVersion}' 2>/dev/null || true)"
  if [ -z "$cur" ]; then info "Node $node no longer exists; skipping."; continue; fi
  if [ "$cur" = "$TARGET_VERSION" ]; then info "Node $node already at $TARGET_VERSION; skipping."; continue; fi

  info "Gate 1/3: every Longhorn volume must be healthy before draining."
  wait_lh_healthy

  ocid="$(instance_ocid_for_node "$node")"
  [ -n "$ocid" ] || die "could not resolve instance OCID (providerID) for $node"
  info "instance OCID  : $ocid"

  info "Cordoning $node..."
  run kc cordon "$node"

  # Give Longhorn a moment to observe the cordon and relax the instance-manager
  # PDB (safe because the volume gate above guarantees replicas elsewhere).
  [ "$DRY_RUN" = "1" ] || sleep 10

  info "Draining $node (timeout ${DRAIN_TIMEOUT}s)..."
  # Drain may return non-zero if it can only leave Longhorn/DS pods behind; we
  # verify that explicitly below rather than trusting the exit code alone.
  run kc drain "$node" \
    --ignore-daemonsets \
    --delete-emptydir-data \
    --timeout="${DRAIN_TIMEOUT}s" || true

  if [ "$DRY_RUN" != "1" ]; then
    mapfile -t stuck < <(stuck_workload_pods "$node")
    if [ "${#stuck[@]}" -gt 0 ]; then
      die "drain left real workload pods on $node: ${stuck[*]} -- investigate before terminating."
    fi
    info "Drain complete (only DaemonSet / Longhorn-system pods remain)."
  fi

  confirm "TERMINATE instance $ocid (boot volume WILL be deleted)?" \
    || die "Aborted before terminating $node."

  info "Terminating instance (OKE will reprovision on the new template)..."
  run oci compute instance terminate \
    --region "$REGION" \
    --instance-id "$ocid" \
    --preserve-boot-volume false \
    --force

  info "Gate 2/3: wait for the replacement node to join and become Ready."
  [ "$DRY_RUN" = "1" ] || wait_for_replacement "$ocid" "$EXPECTED_NODES"

  info "Gate 3/3: wait for Longhorn to rebuild replicas back to healthy."
  [ "$DRY_RUN" = "1" ] || clear_stale_longhorn_replicas
  [ "$DRY_RUN" = "1" ] || wait_lh_healthy

  log "Node $node cycled."
done

# --- Final report -------------------------------------------------------------
log "All requested nodes cycled. Current state:"
kc get nodes -o custom-columns='NODE:.metadata.name,STATUS:.status.conditions[-1].type,VERSION:.status.nodeInfo.kubeletVersion'
if lh_present; then
  echo
  info "Longhorn volumes:"
  kc -n longhorn-system get volumes.longhorn.io \
    -o custom-columns='NAME:.metadata.name,STATE:.status.state,ROBUSTNESS:.status.robustness'
fi

# Free-tier reality check: with the VCN-native CNI max_pods_per_node cap and no
# surge node, draining one of two nodes packs every movable pod onto the
# survivor. Kubernetes has no built-in rebalancer, so after cycling some pods --
# often DaemonSet pods pinned to a node that is now at its pod cap -- can stay
# Pending. Flag it rather than auto-deleting pods, since which pods are safe to
# bounce is a judgement call (see docs/kubernetes-upgrades.md for the rebalance).
pending="$(kc get pods -A --field-selector status.phase=Pending --no-headers 2>/dev/null | wc -l | tr -d ' ')"
if [ "${pending:-0}" -gt 0 ]; then
  echo
  log "WARNING: ${pending} pod(s) still Pending after cycling."
  info "Likely the max-pods-per-node cap concentrating pods on one node. Rebalance:"
  info "  1. cordon the packed node"
  info "  2. delete a few movable (stateless, multi-replica) pods -> they reschedule to the other node"
  info "  3. uncordon the node"
  kc get pods -A --field-selector status.phase=Pending
fi
