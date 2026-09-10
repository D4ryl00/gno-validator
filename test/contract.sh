#!/usr/bin/env bash
# contract.sh — unit tests for the non-interactive automation contract (Plan A).
#
# Sources .Makefile.sh as a library and stubs every function that touches
# Docker or the network, so the suite runs in well under a second with no
# daemon, no images and no chain. It tests exit codes and output shape only —
# the real container behaviour is covered by test/e2e-*.sh.
set -uo pipefail # deliberately NOT -e: assertions must observe non-zero rcs

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJECT_ROOT"

PASS=0
FAIL=0

ok() {
  PASS=$((PASS + 1))
  printf '  ok   %s\n' "$1"
}

bad() {
  FAIL=$((FAIL + 1))
  printf '  FAIL %s\n' "$1" >&2
}

assert_rc() {
  local expected="$1" actual="$2" desc="$3"
  if [[ "$actual" == "$expected" ]]; then
    ok "$desc"
  else
    bad "$desc (expected rc ${expected}, got ${actual})"
  fi
}

assert_defined() {
  local fn="$1"
  if declare -F "$fn" >/dev/null 2>&1; then
    ok "function ${fn} is defined after sourcing"
  else
    bad "function ${fn} is NOT defined after sourcing"
  fi
}

# --- Source the backend as a library ----------------------------------------
# .Makefile.sh sets -euo pipefail; undo -e so assertions can observe failures.
# shellcheck source=/dev/null
source ./.Makefile.sh
set +e

echo "== sourcing =="
assert_defined confirm
assert_defined cmd_start
assert_defined classify_state

# --- Stubs for everything that touches Docker, the network or the clock ------
preflight() { :; }
resolve_signer_mode() { :; }
resolve_input_hashes() { :; }
resolve_gno_inputs() { :; }
drift_analyze() { :; }
drift_warn() { :; }
ensure_images() { :; }
_fresh_up() { :; }
_compose() { :; }
_compose_noenv() { :; }

echo ""
echo "== start =="

classify_state() { STATE_OVERALL="running"; }
cmd_start >/dev/null 2>&1
assert_rc 3 $? "start on a running stack reports unchanged"

classify_state() { STATE_OVERALL="stopped"; }
cmd_start >/dev/null 2>&1
assert_rc 0 $? "start on a stopped stack reports changed"

classify_state() { STATE_OVERALL="none"; }
cmd_start >/dev/null 2>&1
assert_rc 0 $? "start with no containers reports changed"

echo ""
printf 'passed: %d  failed: %d\n' "$PASS" "$FAIL"
((FAIL == 0))
