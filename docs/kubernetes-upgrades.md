# Upgrading Kubernetes

How to move this OKE cluster to a new Kubernetes version safely. Read this
whenever you bump the version; it captures the constraints that make a naive
"change the number and apply" risky on *this* cluster.

- **Control plane** is upgraded by Terraform (OKE-managed, no workload downtime).
- **Worker nodes** are NOT touched by `terraform apply` — they must be replaced
  afterward, one at a time, by [`scripts/cycle-nodes.sh`](../scripts/cycle-nodes.sh).

> All `kubectl` commands below pass `--context oci-home-lab` explicitly — never
> rely on the active context.

---

## How versioning is wired

`terraform/oci-containerengine-cluster.tf` pins one literal:

```hcl
kubernetes_version = "v1.36.1"
```

The node pool **derives** its version from the cluster
(`oci-containerengine-nodepool.tf`: `kubernetes_version = oci_containerengine_cluster.main.kubernetes_version`),
so control plane and nodes can never drift apart in code. The node **image** is
resolved by string-matching the version *and a pinned OS*:

```hcl
strcontains(s.source_name, "Oracle-Linux-8.10")   # OS pinned on purpose
strcontains(s.source_name, "OKE-1.36.1")           # from the version literal
```

The OS is pinned because OKE publishes **multiple OS images per Kubernetes
version** (e.g. v1.36.1 ships both OL 8.10 and OL 9.7 aarch64). Without the pin,
the `[0]` pick is nondeterministic and a routine k8s bump could silently jump
the OS major version. Moving to a new OS is a **deliberate** edit of that
literal, reviewed on its own.

---

## Constraints that shape the procedure

1. **One minor version at a time.** OKE only allows upgrading the control plane
   by a single minor version (patch bumps like 1.36.0 → 1.36.1 are always fine).
   Check what's actually offered before planning (Step 1). Never skip minors.
2. **No surge capacity + pod-count cap.** The cluster sits at the full
   Always-Free allowance (2× A1, 4 OCPU / 24 GB, 200 GB / 2 boot volumes). There
   is no room for a third (surge) node, so nodes are replaced **in place, one at
   a time**. During each replacement everything runs on the single remaining
   node — CPU/memory fit (combined requests ≈ 1.3 vCPU / 1.9 GiB vs. 1.8 vCPU /
   9.2 GiB per node), but the VCN-native CNI **`max_pods_per_node = 31`** cap is
   the binding limit: two full nodes hold ~48 pods, so while one node is down
   its pods can't all fit on the survivor and some go **Pending** until the
   replacement joins. Kubernetes has no built-in rebalancer, so pods can stay
   concentrated on one node afterward (leaving DaemonSet pods Pending on a node
   at its cap) — see the rebalance note under "If something goes wrong".
3. **Boot volumes must be deleted on terminate.** A leaked 100 GB boot volume
   would put the account at 3 volumes / 300 GB, breach the block-storage cap,
   and block the replacement from launching. The script always passes
   `--preserve-boot-volume false`.
4. **Longhorn holds real data.** The `change-tracking-dashboard` SQLite volume
   lives on Longhorn (2 replicas, one per node). A node is never drained while
   any volume is degraded, and we wait for replicas to rebuild between nodes.
   This gate also releases Longhorn's instance-manager PodDisruptionBudget so
   the drain can complete (drain policy `block-if-contains-last-replica`). After
   a node is terminated its replica lingers as a `stopped` replica on the dead
   node, and Longhorn waits `replica-replenishment-wait-interval` (**default
   600s**) before rebuilding it elsewhere — which would stall each node's Gate 3
   by ~10 min. `cycle-nodes.sh` deletes that stale replica to force an immediate
   rebuild (safe: the surviving replica holds the data).
5. **A1 capacity is scarce.** "Out of host capacity" on the replacement is
   transient; OKE retries internally and the script waits patiently.
6. **Single-replica stateful app.** `change-tracking-dashboard` is one RWO pod,
   so it has a brief outage when its node is cycled. Unavoidable without a
   second replica; fine for a homelab. Schedule the window accordingly.

---

## Runbook

### Step 1 — See what upgrade OKE offers

```bash
CID=ocid1.cluster.oc1.phx.aaaaaaaa3y2nd6y775kszzvliz5t3qew77jymgruxhdhdk73dc4dojcgdzla
oci ce cluster get --region us-phoenix-1 --cluster-id "$CID" \
  --query 'data.{current:"kubernetes-version",available:"available-kubernetes-upgrades"}'
```

Pick the target from `available-kubernetes-upgrades` (one minor/patch step).

### Step 2 — Pre-flight: confirm the node image exists for the target + OS

The node image for the target version **and** the pinned OS must exist, or the
replacement node has no image and creation fails. Set `TGT` to your target
(e.g. `1.37.0`) and confirm exactly one match:

```bash
COMP=$(oci ce cluster get --region us-phoenix-1 --cluster-id "$CID" --query 'data."compartment-id"' --raw-output)
TGT=1.37.0
oci ce node-pool-options get --region us-phoenix-1 --node-pool-option-id all --compartment-id "$COMP" \
  --query "data.sources[?contains(\"source-name\",'aarch64') && contains(\"source-name\",'Oracle-Linux-8.10') && contains(\"source-name\",'OKE-$TGT') && !contains(\"source-name\",'GPU')].\"source-name\""
```

If OL 8.10 is no longer published for the target, decide deliberately whether to
move OS (update the pin in `oci-containerengine-nodepool.tf`).

### Step 3 — Edit Terraform

Bump the single literal in `terraform/oci-containerengine-cluster.tf`:

```hcl
kubernetes_version = "v1.37.0"   # was v1.36.1
```

`terraform fmt` and commit.

### Step 4 — `terraform plan`, then apply

```bash
terraform -chdir=terraform plan
```

Expect the plan to show **only**:
- `oci_containerengine_cluster.main.kubernetes_version` changing, and
- `oci_containerengine_node_pool.main` updating its `kubernetes_version` and
  `image_id` (the **template**).

It must **not** show the node pool being destroyed/recreated. If it does, stop
and investigate. Then apply via the capacity-retry wrapper:

```bash
MAX_ATTEMPTS=30 BACKOFF=60 scripts/apply-with-capacity-retry.sh terraform -chdir=terraform apply
```

After this, the control plane is on the new version; the two worker nodes are
still on the old version/image (expected — within skew for one minor step).

### Step 5 — Verify the control plane

```bash
kubectl --context oci-home-lab version -o json | jq -r '.serverVersion.gitVersion'
kubectl --context oci-home-lab get nodes
kubectl --context oci-home-lab get pods -A | grep -vE 'Running|Completed' || echo "all pods healthy"
```

Server version should be the target; nodes still show the old version.

### Step 6 — Cycle the worker nodes

Dry-run first (mutates nothing), then run for real:

```bash
scripts/cycle-nodes.sh --dry-run      # review the plan and node order
scripts/cycle-nodes.sh                # prompts before terminating each node
```

The script, per node (volume-holder cycled last):
gate on Longhorn healthy → cordon → drain → terminate instance
(`--preserve-boot-volume false`) → wait for the replacement Ready → wait for
Longhorn to rebuild → next node. It is **idempotent**: if interrupted (e.g. A1
capacity stall), re-run and it resumes with whatever nodes remain on the old
version. Use `--yes` to skip prompts.

### Step 7 — Final verification

```bash
kubectl --context oci-home-lab get nodes \
  -o custom-columns='NODE:.metadata.name,VERSION:.status.nodeInfo.kubeletVersion'
kubectl --context oci-home-lab -n longhorn-system get volumes.longhorn.io \
  -o custom-columns='NAME:.metadata.name,STATE:.status.state,ROBUSTNESS:.status.robustness'
```

Both nodes on the target version, all volumes `healthy`. Confirm ArgoCD apps are
Synced/Healthy (`kubectl --context oci-home-lab -n argocd get applications`).

---

## If something goes wrong

- **Plan wants to recreate the node pool.** Do not apply. A recreate destroys
  both nodes at once. Usually means a field beyond version/image changed —
  reconcile that separately.
- **Replacement node never becomes Ready.** Almost always transient A1 "out of
  host capacity". The cluster runs (degraded) on one node meanwhile. Re-run
  `scripts/cycle-nodes.sh` to resume; it waits up to `READY_TIMEOUT` (45 min).
- **Longhorn stuck `degraded`.** Do not proceed to the next node. Check
  `kubectl --context oci-home-lab -n longhorn-system get volumes.longhorn.io`
  and the Longhorn UI; a replica may still be rebuilding on the fresh node. If
  it's a `stopped` replica pinned to a node that no longer exists (the script's
  auto-nudge didn't catch it, or you're mid-manual-cycle), delete that replica
  to force an immediate rebuild:
  `kubectl --context oci-home-lab -n longhorn-system delete replica.longhorn.io <name>`.
  A leftover Longhorn *node* for a dead worker (`Ready=False`, `KubernetesNodeGone`)
  won't delete until it's marked unschedulable —
  `kubectl --context oci-home-lab -n longhorn-system patch nodes.longhorn.io <name> --type=merge -p '{"spec":{"allowScheduling":false}}'` and Longhorn GCs it.
- **DaemonSet pods Pending after cycling.** The 31-pod cap left pods
  concentrated on one node (no descheduler). `cycle-nodes.sh` warns when this
  happens. Rebalance: `kubectl --context oci-home-lab cordon <packed-node>`,
  then delete a few movable, stateless, multi-replica pods on it (e.g. the
  Longhorn `csi-*` sidecars, which run 3 replicas) so they reschedule to the
  other node, then `uncordon`. The Pending DaemonSet pods take the freed slots.
- **Control-plane rollback.** OKE does not support downgrading the control
  plane. Treat the version bump as forward-only; validate on the available
  patch before chasing a new minor.
