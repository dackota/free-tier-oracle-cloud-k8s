#!/usr/bin/env bash
# Verifies the .gitignore security control (ADR 0003 / R4): the repo is public,
# so state, tfvars, OCI key material, and kubeconfig must never be committable.
#
# Usage: scripts/check-gitignore-control.sh
# Exits 0 when every sensitive path is ignored and every ordinary path is not;
# exits 1 (with a diagnostic per failing path) otherwise.

set -euo pipefail

repo_root="$(git rev-parse --show-toplevel)"
cd "$repo_root"

# Representative sensitive paths that must be ignored (R4): Terraform state,
# tfvars/auto.tfvars, OCI API signing key material, and kubeconfig.
sensitive_paths=(
  "terraform/terraform.tfstate"
  "terraform/terraform.tfstate.backup"
  "terraform/.terraform/providers/registry.terraform.io/oracle/oci/lock.json"
  "terraform/terraform.tfvars"
  "terraform/secrets.auto.tfvars"
  "oci_api_key.pem"
  "terraform/oci_api_key_2026-01-01.pem"
  "kubeconfig"
  "terraform/kubeconfig.yaml"
)

# Representative ordinary paths that must remain trackable.
tracked_paths=(
  "README.md"
  "terraform/variables.tf"
  "terraform/terraform.tfvars.example"
)

failures=0

for path in "${sensitive_paths[@]}"; do
  if git check-ignore -q -- "$path"; then
    echo "PASS: ignored   -- $path"
  else
    echo "FAIL: NOT ignored (expected ignored) -- $path" >&2
    failures=$((failures + 1))
  fi
done

for path in "${tracked_paths[@]}"; do
  if git check-ignore -q -- "$path"; then
    echo "FAIL: ignored (expected trackable) -- $path" >&2
    failures=$((failures + 1))
  else
    echo "PASS: trackable -- $path"
  fi
done

if [ "$failures" -ne 0 ]; then
  echo "gitignore security control check FAILED ($failures mismatch(es))" >&2
  exit 1
fi

echo "gitignore security control check PASSED"
