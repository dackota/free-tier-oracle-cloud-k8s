#!/usr/bin/env bash
# Self-contained plain-bash test suite for scripts/apply-with-capacity-retry.sh
# (no bats-core available in this environment). Run with:
#   test/apply-with-capacity-retry.test.sh
#
# Exercises the wrapper at its seam: the wrapped command is a stub
# (test/fixtures/stub-cmd.sh) that fails a configured number of times then
# succeeds, and `sleep` is shadowed by test/fixtures/sleep so backoff is
# observable (a counter) instead of a real wait. No Terraform involved.
#
# shellcheck disable=SC2329 # test_*/helper functions are invoked reflectively by main() via `declare -F`, not by name.
set -u
IFS=$'\n\t'

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WRAPPER="$ROOT_DIR/scripts/apply-with-capacity-retry.sh"
FIXTURES_DIR="$ROOT_DIR/test/fixtures"
STUB_CMD="$FIXTURES_DIR/stub-cmd.sh"

# One shared scratch directory for the whole run (not one per case): each
# fork this suite avoids (mktemp/rm/cat per case) matters, since every
# wrapper invocation below already forks real subprocesses for each
# attempt/sleep -- that's the point of testing at the seam.
WORK_ROOT="$(mktemp -d)"
trap 'rm -rf "$WORK_ROOT"' EXIT
CASE_ID=0

PASS_COUNT=0
FAILED_COUNT=0

pass() { PASS_COUNT=$((PASS_COUNT + 1)); }

fail() {
  FAILED_COUNT=$((FAILED_COUNT + 1))
  echo "FAIL: $1"
}

assert_eq() {
  local expected="$1" actual="$2" msg="$3"
  if [ "$expected" = "$actual" ]; then
    pass
  else
    fail "$msg (expected=$expected actual=$actual)"
  fi
}

assert_nonzero() {
  local actual="$1" msg="$2"
  if [ "$actual" -ne 0 ]; then
    pass
  else
    fail "$msg (expected non-zero, got 0)"
  fi
}

# run_wrapper N M
# Invokes the wrapper with MAX_ATTEMPTS=M against the stub command
# configured to fail N times before succeeding, BACKOFF=0 so any real
# sleep in the implementation would still be instant (belt and suspenders
# alongside the shadowed `sleep` fixture). Populates the globals
# ATTEMPTS, SLEEPS, EXIT_CODE.
run_wrapper() {
  local n="$1" m="$2"
  local attempts_file sleeps_file
  CASE_ID=$((CASE_ID + 1))
  attempts_file="$WORK_ROOT/attempts-$CASE_ID"
  sleeps_file="$WORK_ROOT/sleeps-$CASE_ID"

  PATH="$FIXTURES_DIR:$PATH" \
    MAX_ATTEMPTS="$m" BACKOFF=0 \
    FAIL_COUNT="$n" ATTEMPTS_FILE="$attempts_file" SLEEP_COUNT_FILE="$sleeps_file" \
    "$WRAPPER" "$STUB_CMD"
  EXIT_CODE=$?

  # `$(< file)` is a bash builtin read -- no `cat` fork per case.
  ATTEMPTS=0
  [ -f "$attempts_file" ] && ATTEMPTS="$(<"$attempts_file")"
  SLEEPS=0
  [ -f "$sleeps_file" ] && SLEEPS="$(<"$sleeps_file")"
}

# check_invariant N M
# Asserts the R16 invariant for a single (N, M) point:
#   attempts == min(N+1, M)
#   sleeps   == attempts - 1
#   exit 0   iff N < M, else non-zero
check_invariant() {
  local n="$1" m="$2"
  run_wrapper "$n" "$m"

  local expected_attempts
  if [ "$n" -lt "$m" ]; then
    expected_attempts=$((n + 1))
  else
    expected_attempts="$m"
  fi
  local expected_sleeps=$((expected_attempts - 1))

  assert_eq "$expected_attempts" "$ATTEMPTS" "attempts executed (N=$n M=$m)"
  assert_eq "$expected_sleeps" "$SLEEPS" "sleeps performed (N=$n M=$m)"

  if [ "$n" -lt "$m" ]; then
    assert_eq "0" "$EXIT_CODE" "exit code on within-budget success (N=$n M=$m)"
  else
    assert_nonzero "$EXIT_CODE" "exit code on persistent failure (N=$n M=$m)"
  fi
}

# --- Property/invariant test: sweep N across the attempt-budget space ---
# Covers, for several MAX_ATTEMPTS budgets M: N=0 (immediate success),
# N=M-1 (last-chance success), N=M and N>M (persistent failure), and
# every value in between -- plus a randomized fuzz pass over both N and M
# -- so the invariant is checked over the input space, not a handful of
# examples. Every case here forks a real wrapper process plus one real
# subprocess per attempt/sleep (that's the point of testing at the
# wrapper seam) -- the grid below is sized to keep the suite fast without
# giving up coverage of every edge the invariant names.
test_invariant_holds_across_attempt_budget_space() {
  local m n
  for m in 1 2 5; do
    # Exhaustive sweep: every N from immediate success through two
    # attempts past the budget (persistent failure, at and beyond the
    # budget edge).
    for n in $(seq 0 $((m + 2))); do
      check_invariant "$n" "$m"
    done
  done

  # Generated (randomized) spread on top of the exhaustive sweep above:
  # both N and M vary per iteration, so the property is also checked
  # against (N, M) combinations not explicitly enumerated.
  local fuzz_iteration
  # shellcheck disable=SC2034 # loop counter drives iteration count only; m/n are what vary.
  for fuzz_iteration in $(seq 1 8); do
    m=$((RANDOM % 6 + 1)) # 1..6
    n=$((RANDOM % (m + 3)))
    check_invariant "$n" "$m"
  done
}

# --- Example-style cases (read as documentation of the invariant) ---
test_immediate_success_runs_one_attempt_with_no_sleep() {
  run_wrapper 0 5
  assert_eq "0" "$EXIT_CODE" "immediate success exit code"
  assert_eq "1" "$ATTEMPTS" "immediate success attempt count"
  assert_eq "0" "$SLEEPS" "immediate success sleep count"
}

test_last_chance_success_at_final_attempt() {
  run_wrapper 4 5
  assert_eq "0" "$EXIT_CODE" "last-chance success exit code"
  assert_eq "5" "$ATTEMPTS" "last-chance success attempt count"
  assert_eq "4" "$SLEEPS" "last-chance success sleep count"
}

test_persistent_failure_exhausts_budget_and_exits_nonzero() {
  run_wrapper 5 5
  assert_nonzero "$EXIT_CODE" "persistent failure exit code"
  assert_eq "5" "$ATTEMPTS" "persistent failure attempt count"
  assert_eq "4" "$SLEEPS" "persistent failure sleep count"
}

test_persistent_failure_beyond_budget_still_stops_at_budget() {
  run_wrapper 100 5
  assert_nonzero "$EXIT_CODE" "beyond-budget failure exit code"
  assert_eq "5" "$ATTEMPTS" "beyond-budget failure attempt count"
  assert_eq "4" "$SLEEPS" "beyond-budget failure sleep count"
}

# --- R15: script is documented as the normal apply path ---
test_wrapper_is_executable() {
  if [ -x "$WRAPPER" ]; then
    pass
  else
    fail "wrapper script is not executable: $WRAPPER"
  fi
}

test_wrapper_header_documents_usage_as_normal_apply_path() {
  local header
  header="$(<"$WRAPPER")"

  case "$header" in
  *"MAX_ATTEMPTS"*) pass ;;
  *) fail "header comment does not mention MAX_ATTEMPTS" ;;
  esac

  case "$header" in
  *"BACKOFF"*) pass ;;
  *) fail "header comment does not mention BACKOFF" ;;
  esac

  case "$header" in
  *"terraform apply"*) pass ;;
  *) fail "header comment does not document a terraform apply usage example" ;;
  esac
}

# --- Baseline hardening: no wrapped command supplied ---
test_missing_command_argument_exits_nonzero_with_usage() {
  local stderr_file
  CASE_ID=$((CASE_ID + 1))
  stderr_file="$WORK_ROOT/stderr-$CASE_ID"

  "$WRAPPER" 2>"$stderr_file"
  local exit_code=$?

  assert_nonzero "$exit_code" "missing command argument exit code"
  case "$(<"$stderr_file")" in
  *usage*) pass ;;
  *) fail "missing command argument does not print a usage message" ;;
  esac
}

# --- Run all tests ---
main() {
  local test_fn
  for test_fn in $(declare -F | awk '{print $3}' | grep '^test_'); do
    echo "-- $test_fn --"
    "$test_fn"
  done

  echo
  echo "Passed: $PASS_COUNT, Failed: $FAILED_COUNT"
  if [ "$FAILED_COUNT" -ne 0 ]; then
    exit 1
  fi
  exit 0
}

main "$@"
