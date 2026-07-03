#!/usr/bin/env bash
# Test fixture: a wrapped-command stub for exercising
# scripts/apply-with-capacity-retry.sh at the wrapper seam (no Terraform
# involved). It fails the first FAIL_COUNT times it is invoked, then
# succeeds on every invocation after that, recording its own invocation
# count in ATTEMPTS_FILE so the test can assert "attempts executed"
# without any real process-tree introspection.
#
# Required env vars:
#   FAIL_COUNT     - number of leading invocations that should fail
#   ATTEMPTS_FILE  - path to a counter file this stub increments per call
set -euo pipefail

: "${FAIL_COUNT:?FAIL_COUNT env var is required}"
: "${ATTEMPTS_FILE:?ATTEMPTS_FILE env var is required}"

count=0
if [ -f "$ATTEMPTS_FILE" ]; then
  count="$(cat "$ATTEMPTS_FILE")"
fi
count=$((count + 1))
echo "$count" >"$ATTEMPTS_FILE"

if [ "$count" -le "$FAIL_COUNT" ]; then
  exit 1
fi
exit 0
