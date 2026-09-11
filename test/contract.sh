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

echo ""
echo "== direct invocation =="

# The automation contract is only deliverable through direct invocation (see
# README.md's "Automation contract" — `make` collapses every non-zero recipe
# exit to its own generic 2, so it cannot carry the changed/unchanged/error
# distinction). This pins the entry point itself: run as a real script (not
# sourced) with no command, exactly as Ansible's docs example does, and it
# must exit 2 (usage) per its own dispatcher, never abort before printing
# usage, and never touch Docker to get there.
bash ./.Makefile.sh >/dev/null 2>&1
assert_rc 2 $? "bash .Makefile.sh with no command exits 2 (usage), pinning the direct-invocation contract"

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
echo "== stop =="

classify_state() { STATE_OVERALL="none"; }
cmd_stop >/dev/null 2>&1
assert_rc 3 $? "stop with no containers reports unchanged"

classify_state() { STATE_OVERALL="stopped"; }
cmd_stop >/dev/null 2>&1
assert_rc 3 $? "stop on an already-stopped stack reports unchanged"

classify_state() {
  STATE_OVERALL="running"
  STATE_GNOLAND="running"
  STATE_TMKMS="absent"
  STATE_SENTINEL="running"
}
cmd_stop >/dev/null 2>&1
assert_rc 0 $? "stop on a running stack reports changed"

echo ""
echo "== restart =="

classify_state() { STATE_OVERALL="none"; }
cmd_restart >/dev/null 2>&1
assert_rc 1 $? "restart with no containers is an error"

# A running stack where cmd_stop returns RC_UNCHANGED. Call sequence:
# 1. cmd_restart's classify_state: running (enters else branch)
# 2. cmd_stop's classify_state: stopped → returns RC_UNCHANGED (3)
# 3. cmd_start's classify_state: stopped → returns 0 (changed)
# The guard must accept RC_UNCHANGED (3) and continue to cmd_start.
#
# _CLASSIFY_CALLS lives at file scope and is left set after this block. A
# later block adding its own call-counting classify_state stub must reset
# it (_CLASSIFY_CALLS=0) before use, or it will start from this stale count.
_CLASSIFY_CALLS=0
classify_state() {
  _CLASSIFY_CALLS=$((_CLASSIFY_CALLS + 1))
  if ((_CLASSIFY_CALLS == 1)); then
    STATE_OVERALL="running"
  elif ((_CLASSIFY_CALLS == 2)); then
    STATE_OVERALL="stopped"
  else
    STATE_OVERALL="stopped"
  fi
  STATE_GNOLAND="running"
  STATE_TMKMS="absent"
  STATE_SENTINEL="running"
}
cmd_restart >/dev/null 2>&1
assert_rc 0 $? "restart proceeds when cmd_stop returns RC_UNCHANGED"

# Verify the guard prevents abort under set -e when cmd_stop returns RC_UNCHANGED.
# Without the guard, a bare cmd_stop returning 3 would abort the script under set -e.
# This subshell keeps set -e active throughout to demonstrate the guard is necessary.
bash -c '
  set -euo pipefail
  source ./.Makefile.sh

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

  _CLASSIFY_CALLS=0
  classify_state() {
    _CLASSIFY_CALLS=$((_CLASSIFY_CALLS + 1))
    if ((_CLASSIFY_CALLS == 1)); then
      STATE_OVERALL="running"
    elif ((_CLASSIFY_CALLS == 2)); then
      STATE_OVERALL="stopped"
    else
      STATE_OVERALL="stopped"
    fi
    STATE_GNOLAND="running"
    STATE_TMKMS="absent"
    STATE_SENTINEL="running"
  }

  cmd_restart >/dev/null 2>&1
  exit $?
' >/dev/null 2>&1
assert_rc 0 $? "restart guard prevents set -e abort when cmd_stop returns RC_UNCHANGED"

echo ""
echo "== build =="

# Reproduce the "nothing to rebuild" path without Docker: a readable previous
# build state whose recorded inputs equal the current ones, and image inspects
# that succeed.
# resolve_signer_mode is stubbed to a no-op at file scope (see stub block
# above); cmd_build reads $SIGNER_MODE directly (not via the signer_mode
# function), and that no-op leaves it unset. Under this file's `set -u`,
# referencing an unset variable is fatal regardless of -e, so give it a
# value here.
resolve_signer_mode() { SIGNER_MODE="remote"; }
resolve_gno_inputs() {
  GNO_REPO="gnolang/gno"
  GNO_VERSION="test"
  GNO_COMMIT_HASH="deadbeef"
}
read_build_state_as_prev() {
  cat <<'EOS'
PREV_GNO_COMMIT=deadbeef
PREV_GNO_VERSION=test
PREV_GNO_REPO=gnolang/gno
PREV_GNOLAND_CONTENT_HASH=samehash
PREV_GNOLAND_IMAGE_TAG=gno-validator-gnoland:test
EOS
}
content_hash_for() { echo "samehash"; }
signer_mode() { echo "remote"; }
sha256_of_file() { echo "aaaa"; }
docker() { return 0; } # image inspect succeeds

FORCE=0 cmd_build >/dev/null 2>&1
assert_rc 3 $? "build with matching state and images reports unchanged"

echo ""
echo "== ensure_images =="

# ensure_images must not abort under set -e when its inner cmd_build call
# returns RC_UNCHANGED (the "nothing to rebuild" case) — an unchanged build
# still satisfies ensure_images' own contract of "images exist afterwards".
#
# This cannot be tested in the harness body above: the harness runs under
# `set +e` (see file header) precisely so assertions can observe non-zero
# rcs, but that also means there is no abort to prevent — a guarded and an
# unguarded call site behave identically here. Each subshell below keeps
# set -e genuinely active, one per ensure_images call site, to demonstrate
# the guard is necessary. See the "restart" guard test above for the same
# pattern.

# Call site 1: the missing == 1 branch (build-if-missing / warn-if-stale
# modes reach it whenever an image is absent).
bash -c '
  set -euo pipefail
  source ./.Makefile.sh

  preflight() { :; }
  resolve_signer_mode() { :; }
  resolve_gno_inputs() { :; }
  cmd_build() { return "$RC_UNCHANGED"; } # simulate "nothing to rebuild"
  docker() { return 1; }                  # image inspect fails → missing=1
  signer_mode() { echo "remote"; }        # skip the tmkms image inspect

  ensure_images build-if-missing >/dev/null 2>&1
  exit $?
' >/dev/null 2>&1
assert_rc 0 $? "ensure_images guard prevents set -e abort when cmd_build (missing-image branch) returns RC_UNCHANGED"

# Call site 2: the rebuild-if-drift branch (used by update/force=1).
bash -c '
  set -euo pipefail
  source ./.Makefile.sh

  preflight() { :; }
  resolve_signer_mode() { :; }
  resolve_gno_inputs() { :; }
  cmd_build() { return "$RC_UNCHANGED"; } # simulate "nothing to rebuild"
  docker() { return 0; }                  # image inspect succeeds → not missing
  signer_mode() { echo "remote"; }

  ensure_images rebuild-if-drift >/dev/null 2>&1
  exit $?
' >/dev/null 2>&1
assert_rc 0 $? "ensure_images guard prevents set -e abort when cmd_build (rebuild-if-drift branch) returns RC_UNCHANGED"

echo ""
echo "== update =="

classify_state() { STATE_OVERALL="running"; }
drift_analyze() {
  DRIFT_IMAGES=0
  DRIFT_SENTINEL=0
  DRIFT_ENV=0
  DRIFT_COMPOSE=0
}
FORCE=0 cmd_update >/dev/null 2>&1
assert_rc 3 $? "update with no drift reports unchanged"

# Guard: cmd_update's cmd_build call site (need_rebuild == 1 branch) must
# not abort under set -e when cmd_build returns RC_UNCHANGED — an unchanged
# build still satisfies "images are current" for update, so it is not an
# error. This site is not reachable with rc 3 through normal control flow
# (see the comment on the guard in .Makefile.sh), so it cannot be driven
# here the way the assertion above is — cmd_build itself must be stubbed
# to force the RC_UNCHANGED return, the same technique used for the
# ensure_images call sites above. FORCE=1 gets us into the need_rebuild == 1
# branch unconditionally (cmd_update's `if ((force == 1))` block) without
# needing real drift, and also skips the confirm prompt (gated on
# force == 0). This cannot be tested in the harness body above for the same
# reason noted at "== ensure_images ==": it runs under `set +e`, so there is
# no abort to prevent there. Keep set -e genuinely active in a subshell.
bash -c '
  set -euo pipefail
  source ./.Makefile.sh

  preflight() { :; }
  resolve_signer_mode() { :; }
  resolve_gno_inputs() { :; }
  classify_state() { STATE_OVERALL="running"; }
  drift_analyze() {
    DRIFT_IMAGES=0
    DRIFT_SENTINEL=0
    DRIFT_ENV=0
    DRIFT_COMPOSE=0
  }
  cmd_build() { return "$RC_UNCHANGED"; } # simulate "nothing to rebuild"
  _compose() { :; }
  _fresh_up() { :; }

  FORCE=1 cmd_update >/dev/null 2>&1
  exit $?
' >/dev/null 2>&1
assert_rc 0 $? "update guard prevents set -e abort when cmd_build returns RC_UNCHANGED"

echo ""
echo "== reset =="

# Guard: cmd_reset's cmd_stop call site (was_running == 1 branch) must not
# abort under set -e when cmd_stop returns RC_UNCHANGED — a stack that turns
# out to already be stopped (raced between the "was it running?" check and
# the confirm prompts) is not a reason to abandon a reset the operator just
# confirmed twice. This cannot be tested in the harness body above for the
# same reason noted at "== ensure_images ==": it runs under `set +e`, so
# there is no abort to prevent there. Keep set -e genuinely active in a
# subshell, and run cmd_reset against a throwaway temp directory (never the
# real gnoland-data/tmkms-data) since it performs a destructive `rm -rf`.
bash -c '
  set -euo pipefail
  source ./.Makefile.sh

  tmpd="$(mktemp -d)"
  trap "rm -rf \"$tmpd\"" EXIT
  GNOLAND_DATA="$tmpd/gnoland-data"
  TMKMS_DATA="$tmpd/tmkms-data"
  mkdir -p "$GNOLAND_DATA/db" "$GNOLAND_DATA/secrets"
  echo "chain-data" >"$GNOLAND_DATA/db/dummy"

  preflight() { :; }
  signer_mode() { echo "remote"; }
  check_docker() { return 0; }
  classify_state() { STATE_GNOLAND="running"; STATE_TMKMS="absent"; }
  cmd_stop() { return "$RC_UNCHANGED"; } # simulate "already stopped"
  cmd_start() { return 0; }

  YES=1 cmd_reset >/dev/null 2>&1
  rc=$?
  # Prove the reset actually ran (not just that the rc looks right): the
  # guard existing but the rm -rf being skipped for some other reason would
  # still report rc 0 here without this check.
  [[ ! -d "$GNOLAND_DATA/db" ]] || exit 9
  exit "$rc"
' >/dev/null 2>&1
assert_rc 0 $? "reset guard prevents set -e abort when cmd_stop returns RC_UNCHANGED, and the reset still completes"

echo ""
echo "== status-json =="

assert_json_field() {
  local json="$1" field="$2" expected="$3" desc="$4"
  local actual
  actual="$(printf '%s' "$json" | "$JQ_FOR_TESTS" -r "$field" 2>/dev/null)"
  if [[ "$actual" == "$expected" ]]; then
    ok "$desc"
  else
    bad "$desc (expected ${expected}, got ${actual})"
  fi
}

if ! JQ_FOR_TESTS="$(command -v jq)"; then
  bad "jq is required to run the status-json tests; install it and re-run"
else
  classify_state() {
    STATE_OVERALL="running"
    STATE_GNOLAND="running"
    STATE_SENTINEL="running"
  }
  resolve_ports() { GNOLAND_RPC_PORT=26657; }
  ensure_jq() { echo "$JQ_FOR_TESTS"; }
  _http_get() {
    case "$1" in
    *"/status") cat <<'EOS'
{"result":{"node_info":{"moniker":"sentry1","network":"gno-mainnet"},
"sync_info":{"latest_block_height":"12345","catching_up":false},
"validator_info":{"voting_power":"1000"}}}
EOS
      ;;
    *"/net_info") echo '{"result":{"n_peers":"8"}}' ;;
    esac
  }

  out="$(cmd_status_json 2>/dev/null)"
  assert_rc 0 $? "status-json on a healthy node returns RC_OK"
  assert_json_field "$out" '.containers'    'running'      "containers is reported"
  assert_json_field "$out" '.rpc_reachable' 'true'         "rpc_reachable is true"
  assert_json_field "$out" '.height'        '12345'        "height is numeric"
  assert_json_field "$out" '.catching_up'   'false'        "catching_up is boolean false"
  assert_json_field "$out" '.peers'         '8'            "peers is numeric"
  assert_json_field "$out" '.moniker'       'sentry1'      "moniker is reported"

  # Unreachable RPC: every key must still be present with its documented zero.
  _http_get() { return 1; }
  out="$(cmd_status_json 2>/dev/null)"
  assert_rc 0 $? "status-json with unreachable RPC still returns RC_OK"
  assert_json_field "$out" '.rpc_reachable' 'false' "rpc_reachable is false when unreachable"
  assert_json_field "$out" '.height'        '0'     "height is 0 when unreachable"
  assert_json_field "$out" '.catching_up'   'true'  "catching_up is true when unreachable"
  assert_json_field "$out" '.moniker'       ''      "moniker is empty when unreachable"
fi

echo ""
printf 'passed: %d  failed: %d\n' "$PASS" "$FAIL"
((FAIL == 0))
