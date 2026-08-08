#!/usr/bin/env bash
# Creates the four Secrets the Nautobot stack reads (ADR 0003 / R4): this repo
# is public and has no secrets-management component, so these are generated
# locally and applied straight to the cluster, never committed.
#
# The Nautobot chart CAN generate these itself, but only correctly under `helm
# install` — it uses bitnami's common.secrets.passwords.manage, which relies on
# a cluster `lookup` to retain the previously generated value. ArgoCD renders
# with `helm template`, where lookup returns empty, so the secret key, superuser
# password and API token would be regenerated on every single sync. Hence
# operator-owned Secrets plus the chart's existingSecret references.
#
# Usage:
#   scripts/bootstrap-nautobot-secrets.sh --context <kube-context> [--force]
#
# Idempotent: an existing Secret is left untouched unless --force is passed.
# Re-running without --force is safe and is the intended way to fill in a Secret
# that was deleted.
#
# --force ROTATES the values, which is destructive:
#   * NAUTOBOT_SECRET_KEY invalidates every active session and every password
#     reset token, and is required to restore an encrypted database backup —
#     record it somewhere durable before rotating.
#   * the database password is rotated in the Secret only; PostgreSQL itself
#     keeps the old one until you ALTER USER, so the app will fail to connect
#     until you do. Same for the Redis password.
#   * the superuser password/API token only take effect on a fresh install —
#     the chart creates that user once and does not reconcile it afterwards.

set -euo pipefail

namespace="nautobot"
context=""
force=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --context)
      context="${2:-}"
      shift 2
      ;;
    --force)
      force=1
      shift
      ;;
    -h | --help)
      sed -n '2,30p' "$0" | sed 's/^# \{0,1\}//'
      exit 0
      ;;
    *)
      echo "error: unknown argument '$1'" >&2
      exit 2
      ;;
  esac
done

# The repo convention (and the global kubectl rule) is to always pass --context
# explicitly rather than trust whatever the active context happens to be — this
# script writes credentials, so guessing the cluster is not acceptable.
if [[ -z "$context" ]]; then
  echo "error: --context <kube-context> is required" >&2
  echo "       available: $(kubectl config get-contexts -o name | tr '\n' ' ')" >&2
  exit 2
fi

if ! kubectl --context "$context" cluster-info >/dev/null 2>&1; then
  echo "error: cannot reach cluster for context '$context'" >&2
  exit 1
fi

# ArgoCD creates this namespace on first sync (CreateNamespace=true), but this
# script normally runs BEFORE that so the Secrets exist when the pods first
# start. Creating it here is harmless either way; ArgoCD adopts it and applies
# its own managed labels.
if ! kubectl --context "$context" get namespace "$namespace" >/dev/null 2>&1; then
  echo "creating namespace $namespace"
  kubectl --context "$context" create namespace "$namespace"
fi

# 50 bytes of base64 -> ~68 chars, comfortably past Django's 50-char guidance
# and free of shell-hostile characters (base64's alphabet only, tr-stripped of
# any newline). Used for every generated value; `openssl rand` is the source.
gen() {
  openssl rand -base64 50 | tr -d '\n=/+' | cut -c1-50
}

# create_secret <name> <key=value>...
# Skips an existing Secret unless --force, in which case it is deleted and
# recreated. The delete is deliberate rather than a plain `kubectl apply`: apply
# does a three-way merge against the last-applied-configuration annotation, so a
# Secret that was ever created or edited by hand (no such annotation) would keep
# stray keys from the old object instead of being replaced outright. Deleting
# first makes "rotate" mean the same thing regardless of how the Secret got
# there.
create_secret() {
  local name="$1"
  shift

  if kubectl --context "$context" -n "$namespace" get secret "$name" >/dev/null 2>&1; then
    if [[ "$force" -eq 0 ]]; then
      echo "SKIP   $name (already exists; pass --force to rotate)"
      return 0
    fi
    echo "ROTATE $name"
    kubectl --context "$context" -n "$namespace" delete secret "$name"
  else
    echo "CREATE $name"
  fi

  local args=()
  local pair
  for pair in "$@"; do
    args+=(--from-literal="$pair")
  done

  kubectl --context "$context" -n "$namespace" \
    create secret generic "$name" "${args[@]}" \
    --dry-run=client -o yaml |
    kubectl --context "$context" apply -f -
}

# Django SECRET_KEY. Read by the nautobot chart via
# nautobot.django.existingSecret / existingSecretSecretKeyKey.
create_secret "nautobot-secret-key" \
  "NAUTOBOT_SECRET_KEY=$(gen)"

# PostgreSQL credentials. The username must match POSTGRES_USER in
# gitops/workloads/nautobot-postgres/values.yaml and the database name in
# nautobot.db.name; the password is consumed by BOTH the postgres container
# (POSTGRES_PASSWORD) and Nautobot (nautobot.db.existingSecret), which is why
# it lives in one Secret rather than two.
create_secret "nautobot-db-auth" \
  "username=nautobot" \
  "password=$(gen)"

# Redis password. Consumed by the redis container's --requirepass and by
# Nautobot via nautobot.redis.existingSecret.
create_secret "nautobot-redis-auth" \
  "redis-password=$(gen)"

# Initial Nautobot superuser. Only consumed on first install — the chart's init
# container creates the user once and does not reconcile it on later syncs, so
# changing these afterwards does nothing. Change the password in the Nautobot UI
# instead.
create_secret "nautobot-superuser" \
  "password=$(gen)" \
  "apitoken=$(gen)"

echo
echo "Done. Retrieve the initial superuser password with:"
echo "  kubectl --context $context -n $namespace get secret nautobot-superuser \\"
echo "    -o jsonpath='{.data.password}' | base64 -d; echo"
