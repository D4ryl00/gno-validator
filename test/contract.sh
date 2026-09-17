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
echo "== gnoland source mode =="

assert_eq() {
  local expected="$1" actual="$2" desc="$3"
  if [[ "$actual" == "$expected" ]]; then
    ok "$desc"
  else
    bad "$desc (expected ${expected}, got ${actual})"
  fi
}

# Run a snippet against a synthetic validator.env. The subshell keeps ENV_FILE
# and any variable the snippet sets out of the harness's own scope; the
# functions under test come from the source at the top of this file.
with_env() {
  (
    set +e
    tmpd="$(mktemp -d)"
    ENV_FILE="$tmpd/validator.env"
    printf '%s\n' "$1" >"$ENV_FILE"
    eval "$2"
    rc=$?
    rm -rf "$tmpd"
    exit "$rc"
  )
}

out="$(with_env 'GNO_VERSION=master' 'gnoland_source_mode')"
assert_eq "build" "$out" "source mode is 'build' when validator.env names no image ref"

out="$(with_env 'GNOLAND_IMAGE_REF=ghcr.io/gnolang/gno/gnoland:sha-00417a1' 'gnoland_source_mode')"
assert_eq "image" "$out" "source mode is 'image' when validator.env names an image ref"

with_env 'GNO_VERSION=master' 'check_gno_source' >/dev/null 2>&1
assert_rc 0 $? "the source check passes with a gno ref alone"

with_env 'GNOLAND_IMAGE_REF=ghcr.io/gnolang/gno/gnoland:sha-00417a1' 'check_gno_source' >/dev/null 2>&1
assert_rc 0 $? "the source check passes with an image ref alone"

BOTH_SET='GNO_VERSION=master
GNOLAND_IMAGE_REF=ghcr.io/gnolang/gno/gnoland:sha-00417a1'

with_env "$BOTH_SET" 'check_gno_source' >/dev/null 2>&1
assert_rc 1 $? "the source check fails when both a gno ref and an image ref are set"

# The error has to name both keys: an operator who added one and inherited the
# other from validator.env.example cannot act on "conflicting configuration".
err="$(with_env "$BOTH_SET" 'err_gno_source_conflict' 2>&1 >/dev/null)"
case "$err" in
*GNOLAND_IMAGE_REF*GNO_VERSION* | *GNO_VERSION*GNOLAND_IMAGE_REF*)
  ok "the conflict error names both GNOLAND_IMAGE_REF and GNO_VERSION"
  ;;
*) bad "the conflict error names both GNOLAND_IMAGE_REF and GNO_VERSION (got: ${err})" ;;
esac

# A key present but empty is not "set": validator.env.example ships blank and
# commented keys, and neither should trip the conflict.
EMPTY_GNO='GNO_VERSION=
GNOLAND_IMAGE_REF=ghcr.io/gnolang/gno/gnoland:sha-00417a1'
with_env "$EMPTY_GNO" 'check_gno_source' >/dev/null 2>&1
assert_rc 0 $? "an empty GNO_VERSION does not conflict with an image ref"

# The check is only useful if the commands actually run it. These drive the
# real preflight and the real command entry points in a fresh shell, because
# this file stubs preflight to a no-op at file scope.
with_fresh_env() {
  local body="$1" snippet="$2" state="${3:-}" tmpd rc
  tmpd="$(mktemp -d)"
  printf '%s\n' "$body" >"$tmpd/validator.env"
  printf '%s\n' "$snippet" >"$tmpd/snippet.sh"
  # Written even when empty: STATE_FILE always points here, so "no state" is
  # an absent recorded digest rather than the repo's real .build-state.
  [[ -n "$state" ]] && printf '%s\n' "$state" >"$tmpd/build-state"
  # set -e stays ON here, unlike the rest of this file: a bare `preflight ...`
  # line in a cmd_* function relies on it to abort, so disabling it would let
  # execution run past a failed check and test nothing.
  bash --noprofile --norc -c 'set -euo pipefail; source ./.Makefile.sh; ENV_FILE="$1/validator.env"; STATE_FILE="$1/build-state"; source "$1/snippet.sh"' _ "$tmpd"
  rc=$?
  rm -rf "$tmpd"
  return "$rc"
}

with_fresh_env 'GNO_VERSION=master' 'preflight gno_source' >/dev/null 2>&1
assert_rc 0 $? "preflight accepts the gno_source check with one source configured"

with_fresh_env "$BOTH_SET" 'preflight gno_source' >/dev/null 2>&1
assert_rc 1 $? "preflight gno_source rejects a validator.env naming both sources"

# Wired into the commands that act on images, not merely available: a
# conflicting validator.env must stop build and start before either touches
# Docker.
# The Docker stubs exit 9 rather than no-op: reaching them at all means the
# refusal came too late (or not at all), and rc 9 says so instead of letting
# a real `compose build` run from the test suite.
REACHED_DOCKER='check_docker() { return 0; }
check_genesis() { return 0; }
docker() { exit 9; }
_compose() { exit 9; }
_compose_noenv() { exit 9; }'

with_fresh_env "$BOTH_SET" "$REACHED_DOCKER
cmd_build" >/dev/null 2>&1
assert_rc 1 $? "build refuses a validator.env naming both sources before touching Docker"

with_fresh_env "$BOTH_SET" "$REACHED_DOCKER
cmd_start" >/dev/null 2>&1
assert_rc 1 $? "start refuses a validator.env naming both sources before touching Docker"

echo ""
echo "== image ref pinning =="

TAG_REF='ghcr.io/gnolang/gno/gnoland:sha-00417a1'
DIGEST='sha256:805d723bcd2938ac42d3056f70d11a2f50ee89ca852c618f6aee60fe1bfd79ad'

out="$(with_fresh_env "GNOLAND_IMAGE_REF=${TAG_REF}" 'gnoland_image_ref')"
assert_eq "$TAG_REF" "$out" "the image ref is read from validator.env"

# Already pinned by the operator: nothing to look up, nothing to append.
out="$(with_fresh_env "GNOLAND_IMAGE_REF=${TAG_REF}@${DIGEST}" 'gnoland_pinned_ref')"
assert_eq "${TAG_REF}@${DIGEST}" "$out" "a ref that already names a digest is used unchanged"

# Pin-on-pull: the digest recorded at the last pull is what runs, so a tag
# that moved between staging and recreate cannot swap the binary underneath.
STATE_MATCHING="GNOLAND_IMAGE_REF=\"${TAG_REF}\"
GNOLAND_IMAGE_DIGEST=\"${DIGEST}\""
out="$(with_fresh_env "GNOLAND_IMAGE_REF=${TAG_REF}" 'gnoland_pinned_ref' "$STATE_MATCHING")"
assert_eq "${TAG_REF}@${DIGEST}" "$out" "a bare tag is pinned to the digest recorded at the last pull"

# Nothing pulled yet — there is no digest to pin to, and the bare ref is the
# only honest answer. The first pull resolves and records it.
out="$(with_fresh_env "GNOLAND_IMAGE_REF=${TAG_REF}" 'gnoland_pinned_ref')"
assert_eq "$TAG_REF" "$out" "a bare tag with no recorded digest resolves to itself"

# The operator repointed the ref. The recorded digest belongs to the previous
# one, so pinning to it would silently keep running the old image.
STATE_OTHER="GNOLAND_IMAGE_REF=\"ghcr.io/gnolang/gno/gnoland:sha-01c5ff8\"
GNOLAND_IMAGE_DIGEST=\"sha256:0213017bf53986338807f50ac8d6ec0851bcf95b3680dd3f5226d237461abfb5\""
out="$(with_fresh_env "GNOLAND_IMAGE_REF=${TAG_REF}" 'gnoland_pinned_ref' "$STATE_OTHER")"
assert_eq "$TAG_REF" "$out" "a digest recorded for a different ref is not reused"

echo ""
echo "== image mode build =="

assert_contains() {
  local haystack="$1" needle="$2" desc="$3"
  case "$haystack" in
  *"$needle"*) ok "$desc" ;;
  *) bad "$desc (no '${needle}' in output)" ;;
  esac
}

assert_not_contains() {
  local haystack="$1" needle="$2" desc="$3"
  case "$haystack" in
  *"$needle"*) bad "$desc (unexpected '${needle}' in output)" ;;
  *) ok "$desc" ;;
  esac
}

out="$(with_fresh_env "GNOLAND_IMAGE_REF=${TAG_REF}" 'docker() { echo "DOCKER $*"; }
gnoland_pull' 2>&1)"
assert_contains "$out" "DOCKER pull ${TAG_REF}" "the pull fetches the pinned ref"
assert_contains "$out" "DOCKER tag ${TAG_REF} gno-validator-gnoland" \
  "the pulled image is tagged as the local gnoland image, so every inspect and run keeps working"

# The whole point of image mode: no compile, and no network round-trip to
# resolve a gno commit either. The git stub proves resolve_gno_inputs is not
# reaching for one.
IMAGE_BUILD_STUBS='check_docker() { return 0; }
resolve_signer_mode() { SIGNER_MODE="remote"; }
signer_mode() { echo "remote"; }
sentinel_pull() { :; }
write_build_state() { :; }
docker() { echo "DOCKER $*"; }
_compose() { echo "COMPOSE $*"; }
git() { echo "GIT $*"; return 1; }'

out="$(with_fresh_env "GNOLAND_IMAGE_REF=${TAG_REF}" "$IMAGE_BUILD_STUBS
FORCE=1 cmd_build" 2>&1)"
assert_contains "$out" "DOCKER pull ${TAG_REF}" "build in image mode pulls the image"
assert_not_contains "$out" "COMPOSE build gnoland" "build in image mode never compiles gnoland"

# Resolving a gno commit means a `git ls-remote` round-trip, which image mode
# has no use for. Asserting on the stub's output would prove nothing (the call
# is inside a command substitution whose stderr is discarded), so assert on
# the outcome: had the lookup run, its output would BE the commit hash.
out="$(with_fresh_env "GNOLAND_IMAGE_REF=${TAG_REF}" 'git() { echo "CALLED-GIT"; }
resolve_gno_inputs
echo "commit=[${GNO_COMMIT_HASH:-}]"' 2>&1)"
assert_contains "$out" "commit=[]" "image mode resolves no gno commit, so no network round-trip"

# Build mode is untouched: it still compiles rather than pulling a gnoland image.
out="$(with_fresh_env 'GNO_VERSION=master' "$IMAGE_BUILD_STUBS
FORCE=1 cmd_build" 2>&1)"
assert_contains "$out" "COMPOSE build gnoland" "build in build mode still compiles gnoland"

echo ""
echo "== image mode state and drift =="

STATE_STUBS='docker() { return 0; }
sentinel_image_ref() { echo "ghcr.io/aeddi/gno-watchtower/sentinel:v1.2.0"; }
sentinel_local_digest() { echo "sha256:1111111111111111111111111111111111111111111111111111111111111111"; }
sentinel_remote_digest() { :; }
gnoland_local_digest() { echo "'"$DIGEST"'"; }
gnoland_remote_digest() { echo "'"$DIGEST"'"; }
resolve_gno_inputs
write_build_state
cat "$STATE_FILE"'

out="$(with_fresh_env "GNOLAND_IMAGE_REF=${TAG_REF}" "$STATE_STUBS" 2>&1)"
assert_contains "$out" 'GNOLAND_SOURCE_MODE="image"' "the state records which source the images came from"
assert_contains "$out" "GNOLAND_IMAGE_REF=\"${TAG_REF}\"" "the state records the image ref"
assert_contains "$out" "GNOLAND_IMAGE_DIGEST=\"${DIGEST}\"" "the state records the digest actually pulled"

# Build mode keeps recording what it always did — the drift check reads these.
out="$(with_fresh_env 'GNO_VERSION=master' 'git() { echo "abc123"; }
'"$STATE_STUBS" 2>&1)"
assert_contains "$out" 'GNOLAND_SOURCE_MODE="build"' "build mode records its source too"
assert_contains "$out" 'GNO_COMMIT="abc123"' "build mode still records the gno commit"

# Drift: the tag moved under us. The recorded digest is what is running, the
# remote one is what the tag points at now, and the operator has to be told.
DRIFT_STATE="GNOLAND_SOURCE_MODE=\"image\"
GNOLAND_IMAGE_REF=\"${TAG_REF}\"
GNOLAND_IMAGE_DIGEST=\"${DIGEST}\""
MOVED='sha256:4b161a2b5d5fcceab4badd4d519ea73465c078a17e6fb1e9b0bae2e01c1a7b87'

out="$(with_fresh_env "GNOLAND_IMAGE_REF=${TAG_REF}" 'gnoland_remote_digest() { echo "'"$MOVED"'"; }
eval "$(read_build_state_as_prev)"
resolve_gno_inputs
build_state_drift_summary' "$DRIFT_STATE" 2>&1)"
rc=$?
assert_contains "$out" "advanced" "a moved tag is reported as drift"
assert_rc 1 "$rc" "a moved tag makes the drift summary report drift"

out="$(with_fresh_env "GNOLAND_IMAGE_REF=${TAG_REF}" 'gnoland_remote_digest() { echo "'"$DIGEST"'"; }
eval "$(read_build_state_as_prev)"
resolve_gno_inputs
build_state_drift_summary' "$DRIFT_STATE" 2>&1)"
assert_rc 0 $? "an unchanged digest is no drift"
assert_eq "" "$out" "an unchanged digest reports nothing"

# The operator repointed GNOLAND_IMAGE_REF. That is drift regardless of digests.
out="$(with_fresh_env 'GNOLAND_IMAGE_REF=ghcr.io/gnolang/gno/gnoland:sha-01c5ff8' 'gnoland_remote_digest() { echo "'"$DIGEST"'"; }
eval "$(read_build_state_as_prev)"
resolve_gno_inputs
build_state_drift_summary' "$DRIFT_STATE" 2>&1)"
assert_rc 1 $? "changing the image ref is drift"
assert_contains "$out" "sha-01c5ff8" "the drift summary names the new ref"

echo ""
echo "== image mode reporting =="

# `make infos` is where an operator checks what a node is about to run, so in
# image mode it has to name the ref and the digest — the gno repo/version/commit
# labels it prints in build mode are absent from a prebuilt image.
INFOS_STUBS='preflight() { :; }
ensure_images() { :; }
init_gnoland_data() { :; }
resolve_ports() { GNOLAND_RPC_LADDR=127.0.0.1; GNOLAND_RPC_PORT=26657; GNOLAND_P2P_LADDR=0.0.0.0; GNOLAND_P2P_PORT=26656; }
signer_mode() { echo "remote"; }
gnoland_run() { return 1; }
image_label() { :; }
sentinel_image_ref() { echo "sentinel:v1.2.0"; }
sentinel_local_digest() { echo "sha256:deadbeef"; }
sentinel_version() { echo "v1.2.0"; }
gnoland_local_digest() { echo "'"$DIGEST"'"; }
gnoland_binary_version() { echo "heads/chain/mainnet.3436+00417a1be"; }
sha256_of_file() { echo "aaaa"; }
docker() { return 1; }
DRIFT_OVERRIDES=0
cmd_infos'

out="$(with_fresh_env "GNOLAND_IMAGE_REF=${TAG_REF}" "$INFOS_STUBS" 2>&1)"
assert_contains "$out" "$TAG_REF" "infos names the image ref in image mode"
assert_contains "$out" "${DIGEST:0:19}" "infos names the digest that is running"

# Automation reads status-json, and a converge that cannot tell the two modes
# apart cannot report which one a host is on.
if [[ -n "${JQ_FOR_TESTS:-}" ]] || JQ_FOR_TESTS="$(command -v jq)"; then
  STATUS_STUBS='preflight() { :; }
resolve_signer_mode() { :; }
classify_state() { STATE_OVERALL="running"; STATE_GNOLAND="running"; STATE_SENTINEL="running"; }
resolve_ports() { GNOLAND_RPC_PORT=26657; }
ensure_jq() { command -v jq; }
_http_get() { return 1; }
cmd_status_json'

  out="$(with_fresh_env "GNOLAND_IMAGE_REF=${TAG_REF}" "$STATUS_STUBS" 2>/dev/null)"
  assert_eq "image" "$(printf '%s' "$out" | "$JQ_FOR_TESTS" -r '.gnoland_source')" \
    "status-json reports the image source mode"

  out="$(with_fresh_env 'GNO_VERSION=master' "$STATUS_STUBS" 2>/dev/null)"
  assert_eq "build" "$(printf '%s' "$out" | "$JQ_FOR_TESTS" -r '.gnoland_source')" \
    "status-json reports the build source mode"
fi

echo ""
echo "== image mode compose =="

# The official image's entrypoint is /usr/bin/gnoland and its WORKDIR is
# /gnoroot, so gnoland's relative default data dir would land off the mount.
# Both are corrected by an overlay, which every compose call has to include —
# otherwise the container comes up with the wrong entrypoint or writes its
# chain data somewhere the bind mount does not reach.
COMPOSE_STUBS='docker() { echo "DOCKER $*"; }
_COMPOSE_PROFILES=()
_compose up -d
_compose_noenv stop'

out="$(with_fresh_env "GNOLAND_IMAGE_REF=${TAG_REF}" "$COMPOSE_STUBS" 2>&1)"
assert_contains "$out" "-f docker-compose.yml -f docker-compose.image.yml" \
  "compose layers the image overlay on the base file in image mode"

out="$(with_fresh_env 'GNO_VERSION=master' "$COMPOSE_STUBS" 2>&1)"
assert_not_contains "$out" "docker-compose.image.yml" \
  "build mode composes from the base file alone"

# The overlay decides what actually runs, so an edit to it has to count as
# compose drift the same way an edit to the base file does.
out="$(with_fresh_env "GNOLAND_IMAGE_REF=${TAG_REF}" 'sha256_of_file() { echo "sha-of-$1"; }
resolve_input_hashes
echo "compose=[${COMPOSE_FILE_SHA256}]"' 2>&1)"
assert_contains "$out" "docker-compose.image.yml" "the compose hash covers the image overlay"

echo ""
echo "== image mode one-shot runs =="

# `make infos` and the first-run init use `docker run` directly, which bypasses
# compose and therefore the overlay. Without the same two corrections applied
# there, a pulled image runs its own entrypoint (the bare binary, so
# `gnoland secrets get ...` becomes `gnoland gnoland secrets get ...` and
# prints usage) and resolves gnoland's relative data dir against /gnoroot.
ONESHOT_STUBS='HOST_UID=1000
HOST_GID=1000
docker() { echo "DOCKER $*"; }
gnoland_run gnoland version'

out="$(with_fresh_env "GNOLAND_IMAGE_REF=${TAG_REF}" "$ONESHOT_STUBS" 2>&1)"
assert_contains "$out" "--entrypoint /entrypoint.sh" "a one-shot run selects our entrypoint in image mode"
assert_contains "$out" "gnoland-entrypoint.sh:/entrypoint.sh:ro" "a one-shot run mounts our entrypoint in image mode"
assert_contains "$out" "-w /" "a one-shot run pins the working directory in image mode"

out="$(with_fresh_env 'GNO_VERSION=master' "$ONESHOT_STUBS" 2>&1)"
assert_not_contains "$out" "--entrypoint" "a one-shot run in build mode uses the image's own entrypoint"

# The stub prints to stderr: init_gnoland_data sends the run's stdout to
# /dev/null, which would swallow the evidence this test is looking for.
INIT_STUBS='HOST_UID=1000
HOST_GID=1000
GNOLAND_DATA="$(mktemp -d)"
docker() { echo "DOCKER $*" >&2; }
init_gnoland_data'

out="$(with_fresh_env "GNOLAND_IMAGE_REF=${TAG_REF}" "$INIT_STUBS" 2>&1)"
assert_contains "$out" "--entrypoint /entrypoint.sh" "the data-dir init selects our entrypoint in image mode"
assert_contains "$out" "-w /" "the data-dir init pins the working directory in image mode"

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
