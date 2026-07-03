#!/usr/bin/env bash
#
# apply-with-capacity-retry.sh -- the normal apply path for this project.
#
# OCI's Always Free A1 Node pool (VM.Standard.A1.Flex) is notorious for a
# transient "Out of host capacity" error on create/scale. That failure is
# not a broken build -- it means the region is momentarily out of free A1
# capacity and the same apply will typically succeed on a later retry. This
# wrapper re-attempts a wrapped command with a fixed backoff between
# attempts so a transient shortage doesn't require babysitting the apply.
#
# The wrapped command is passed through as "$@", so this script has no
# knowledge of Terraform/OpenTofu (or any credentials) -- it just retries
# whatever it's handed. That makes it independently testable at the wrapper
# seam with a stub command instead of a real `terraform apply`.
#
# Invariant (R16): exits 0 iff the wrapped command succeeds within the
# attempt budget; exits non-zero on persistent failure within budget; on
# immediate success it runs exactly one attempt and never sleeps.
#
# Usage:
#   scripts/apply-with-capacity-retry.sh <command> [args...]
#
# Example (the normal way to apply this project's Terraform/OpenTofu):
#   MAX_ATTEMPTS=30 BACKOFF=60 scripts/apply-with-capacity-retry.sh terraform apply
#
# Environment variables (both optional, sensible defaults shown):
#   MAX_ATTEMPTS - maximum number of attempts before giving up (default: 30)
#   BACKOFF      - seconds to sleep between attempts (default: 60)
set -euo pipefail

MAX_ATTEMPTS="${MAX_ATTEMPTS:-30}"
BACKOFF="${BACKOFF:-60}"

if [ "$#" -eq 0 ]; then
  echo "usage: $0 <command> [args...]" >&2
  echo "  MAX_ATTEMPTS=30 BACKOFF=60 $0 terraform apply" >&2
  exit 2
fi

attempt=0
# NOTE: `until "$@"` is a compound-command condition, so set -e does not
# treat the wrapped command's non-zero exit as a script-ending error --
# it's exactly what drives the retry loop below.
until "$@"; do
  attempt=$((attempt + 1))
  if [ "$attempt" -ge "$MAX_ATTEMPTS" ]; then
    echo "apply-with-capacity-retry: giving up after $attempt attempt(s)" >&2
    exit 1
  fi
  echo "apply-with-capacity-retry: attempt $attempt failed, retrying in ${BACKOFF}s..." >&2
  sleep "$BACKOFF"
done

exit 0
