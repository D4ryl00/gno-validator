#!/usr/bin/env bash
# e2e-tmkms-local.sh — end-to-end test of the "local bundled tmkms" signer mode.
#
# Proves the full local-tmkms path works: builds the gnoland + tmkms images from
# the repo, generates a softsign validator key, synthesizes a genesis.json with
# that validator, boots gnoland + a bundled tmkms container, and asserts that
# tmkms actually signs consensus (Precommit) and the node validates with voting
# power while block height advances.
#
# Heavyweight and opt-in: it clones gno and builds images (first run ~10 min).
# Requires Docker + curl. No host Go toolchain needed (gnogenesis is built in a
# throwaway container).
#
# Isolation: everything runs in a temp workdir under its own compose project
# name (gno-validator-e2e), its own image names (gno-validator-e2e-*), and its
# own host ports (default 36656-36659). It never touches a real deployment's
# containers, images, data dirs, or the default 2665x ports. Containers and the
# temp dir are torn down on exit.
#
# Env overrides:
#   GNO_REPO      gno source repo slug          (default: D4ryl00/gno)
#   GNO_VERSION   branch/tag/commit with tmkms  (default: a pinned commit)
#   CHAIN_ID      test chain id                 (default: gno-tmkms-e2e)
#   RPC_PORT/P2P_PORT/SIGNER_PORT  host ports     (default: 36657/36656/36659)
#   KEEP_IMAGES=1 keep the e2e images after the run (default: removed)
#   NO_CACHE=1    docker build --no-cache
set -euo pipefail

# --- Config -----------------------------------------------------------------
GNO_REPO="${GNO_REPO:-gnolang/gno}"
# Defaults match validator.env.example (gnolang/gno @ master). master carries
# tmkms_listener support (PR #5718). Override GNO_VERSION to pin a commit.
GNO_VERSION="${GNO_VERSION:-master}"
CHAIN_ID="${CHAIN_ID:-gno-tmkms-e2e}"
RPC_PORT="${RPC_PORT:-36657}"
P2P_PORT="${P2P_PORT:-36656}"
SIGNER_PORT="${SIGNER_PORT:-36659}"

PROJECT="gno-validator-e2e"
GNOLAND_IMAGE="gno-validator-e2e-gnoland"
TMKMS_IMAGE="gno-validator-e2e-tmkms"
GENESIS_IMAGE="gno-validator-e2e-gnogenesis"
KEYNAME_ADDR=""

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
HUID="$(id -u)"
HGID="$(id -g)"
WORKDIR=""
RPC="http://127.0.0.1:${RPC_PORT}"

log() { printf '\n\033[1m==> %s\033[0m\n' "$*"; }
fail() {
  printf '\n\033[31mFAIL: %s\033[0m\n' "$*" >&2
  dump_diagnostics
  exit 1
}

compose() {
  ( cd "$WORKDIR" && docker compose --env-file validator.env --profile tmkms-local "$@" )
}

dump_diagnostics() {
  [[ -z "$WORKDIR" || ! -f "$WORKDIR/docker-compose.yml" ]] && return 0
  echo "----- gnoland logs (tail) -----" >&2
  compose logs --tail 40 gnoland 2>&1 | tail -40 >&2 || true
  echo "----- tmkms logs (tail) -----" >&2
  compose logs --tail 40 tmkms 2>&1 | tail -40 >&2 || true
}

cleanup() {
  local rc=$?
  if [[ -n "$WORKDIR" && -f "$WORKDIR/docker-compose.yml" ]]; then
    log "Cleaning up containers"
    compose down -v --remove-orphans >/dev/null 2>&1 || true
  fi
  if [[ "${KEEP_IMAGES:-0}" != "1" ]]; then
    docker rmi -f "$GNOLAND_IMAGE" "$TMKMS_IMAGE" "$GENESIS_IMAGE" >/dev/null 2>&1 || true
  fi
  [[ -n "$WORKDIR" && -d "$WORKDIR" ]] && rm -rf "$WORKDIR"
  exit "$rc"
}
trap cleanup EXIT INT TERM

# --- 0. Preflight -----------------------------------------------------------
command -v docker >/dev/null || { echo "docker required" >&2; exit 2; }
docker info >/dev/null 2>&1 || { echo "docker daemon unreachable" >&2; exit 2; }
command -v curl >/dev/null || { echo "curl required" >&2; exit 2; }

# --- 1. Isolated workdir ----------------------------------------------------
# Copy the working tree's build inputs (so uncommitted changes are tested too),
# then rename the compose project + image names so nothing collides with a real
# deployment. Relative bind mounts (./tmkms-sock, ./gnoland-data, ...) resolve
# inside WORKDIR.
log "Setting up isolated workdir"
WORKDIR="$(mktemp -d "${TMPDIR:-/tmp}/gno-val-e2e.XXXXXX")"
cp "$REPO_ROOT/Dockerfile" "$REPO_ROOT/docker-compose.yml" "$REPO_ROOT/.Makefile.sh" "$WORKDIR/"
cp -R "$REPO_ROOT/docker" "$WORKDIR/docker"
mkdir -p "$WORKDIR/gnoland-data" "$WORKDIR/tmkms-data" "$WORKDIR/tmkms-sock"

# Rename project + images in the copied compose file.
sed -i.bak \
  -e 's/^name: gno-validator$/name: '"$PROJECT"'/' \
  -e 's/image: gno-validator-gnoland/image: '"$GNOLAND_IMAGE"'/' \
  -e 's/image: gno-validator-tmkms/image: '"$TMKMS_IMAGE"'/' \
  "$WORKDIR/docker-compose.yml"
rm -f "$WORKDIR/docker-compose.yml.bak"

# Same isolation for the copied .Makefile.sh (used by step 7's reset check): it
# resolves PROJECT_ROOT from its own location, so data dirs land in WORKDIR, but
# its container names are hardcoded to the default project and would otherwise
# inspect a real deployment's containers.
sed -i.bak \
  -e 's/^GNOLAND_CONTAINER=.*/GNOLAND_CONTAINER="'"$PROJECT"'-gnoland-1"/' \
  -e 's/^TMKMS_CONTAINER=.*/TMKMS_CONTAINER="'"$PROJECT"'-tmkms-1"/' \
  -e 's/^SENTINEL_CONTAINER=.*/SENTINEL_CONTAINER="'"$PROJECT"'-sentinel-1"/' \
  -e 's/^GNOLAND_IMAGE=.*/GNOLAND_IMAGE="'"$GNOLAND_IMAGE"'"/' \
  -e 's/^TMKMS_IMAGE=.*/TMKMS_IMAGE="'"$TMKMS_IMAGE"'"/' \
  "$WORKDIR/.Makefile.sh"
rm -f "$WORKDIR/.Makefile.sh.bak"

cat >"$WORKDIR/validator.env" <<EOF
GNO_REPO=${GNO_REPO}
GNO_VERSION=${GNO_VERSION}
GNOLAND_RPC_LADDR=127.0.0.1
GNOLAND_RPC_PORT=${RPC_PORT}
GNOLAND_P2P_LADDR=127.0.0.1
GNOLAND_P2P_PORT=${P2P_PORT}
GNOLAND_EXTRA_FLAGS=--skip-genesis-sig-verification
GNOLAND_NTP_UPDATE=
TMKMS_CHAIN_ID=${CHAIN_ID}
SIGNER_LISTEN_LADDR=127.0.0.1
SIGNER_LISTEN_PORT=${SIGNER_PORT}
EOF

# Local (unix://) tmkms — listen_addr LAST (validation requires the rest first).
cat >"$WORKDIR/config.overrides" <<EOF
moniker = "e2e-tmkms-val"
consensus.priv_validator.tmkms_listener.chain_id = "${CHAIN_ID}"
consensus.priv_validator.tmkms_listener.protocol_version = "v0.34"
consensus.priv_validator.tmkms_listener.listen_addr = "unix:///tmkms-sock/privval.sock"
EOF

export HOST_UID="$HUID" HOST_GID="$HGID"
BUILD_ARGS=(); [[ "${NO_CACHE:-0}" == "1" ]] && BUILD_ARGS+=(--no-cache)

# --- 2. Build validator images ---------------------------------------------
log "Building gnoland + tmkms images (this can take several minutes)"
compose build "${BUILD_ARGS[@]}" gnoland tmkms

# --- 3. Generate the softsign validator key --------------------------------
# Mirrors 'make gen-identity' (local mode): gnoland creates the validator key,
# and its 32-byte ed25519 seed is exported base64 as tmkms's softsign key.
log "Generating validator identity + softsign key"
gnoland_run() {
  docker run --rm --user "${HUID}:${HGID}" \
    -v "$WORKDIR/gnoland-data:/gnoland-data" \
    --entrypoint gnoland "$GNOLAND_IMAGE" "$@"
}
gnoland_run secrets init >/dev/null 2>&1 || true

docker run --rm --user "${HUID}:${HGID}" \
  -v "$WORKDIR/gnoland-data:/gnoland-data" \
  -v "$WORKDIR/tmkms-data:/tmkms-data" \
  --entrypoint sh "$GNOLAND_IMAGE" -c '
    set -e
    key=/gnoland-data/secrets/priv_validator_key.json
    [ -f "$key" ] || { echo "priv_validator_key.json missing" >&2; exit 1; }
    val=$(awk "/\"priv_key\"/{f=1} f&&/\"value\"/{line=\$0; sub(/.*\"value\"[[:space:]]*:[[:space:]]*\"/,\"\",line); sub(/\".*/,\"\",line); print line; exit}" "$key")
    [ -n "$val" ] || { echo "could not parse priv_key" >&2; exit 1; }
    printf "%s" "$val" | base64 -d | head -c 32 | base64 | tr -d "\n" > /tmkms-data/consensus.key
  '
[[ -s "$WORKDIR/tmkms-data/consensus.key" ]] || fail "consensus.key was not written"

ADDR="$(gnoland_run secrets get validator_key.address --raw 2>/dev/null | tr -d '\r\n')"
PUB="$(gnoland_run secrets get validator_key.pub_key --raw 2>/dev/null | tr -d '\r\n')"
[[ -n "$ADDR" && -n "$PUB" ]] || fail "could not read validator identity"
echo "  validator: $ADDR"

# --- 4. Synthesize genesis.json --------------------------------------------
log "Building gnogenesis + generating genesis.json"
docker build "${BUILD_ARGS[@]}" \
  -f "$REPO_ROOT/test/Dockerfile.gnogenesis" \
  --build-arg "GNO_REPO=${GNO_REPO}" --build-arg "GNO_VERSION=${GNO_VERSION}" \
  -t "$GENESIS_IMAGE" "$REPO_ROOT/test" >/dev/null
gnogenesis() { docker run --rm --user "${HUID}:${HGID}" -v "$WORKDIR:/w" -w /w "$GENESIS_IMAGE" "$@"; }
gnogenesis generate --chain-id "$CHAIN_ID" --output-path /w/genesis.json >/dev/null 2>&1
gnogenesis validator add --genesis-path /w/genesis.json \
  --address "$ADDR" --pub-key "$PUB" --name val01 --power 1 >/dev/null 2>&1
gnogenesis verify --genesis-path /w/genesis.json >/dev/null 2>&1 || fail "genesis.json failed verification"

# --- 5. Boot the stack ------------------------------------------------------
log "Starting gnoland + tmkms"
compose up -d gnoland tmkms

# --- 6. Assertions ----------------------------------------------------------
# tmkms must connect and sign; the node must validate and advance blocks.
wait_for() { # <description> <timeout-s> <shell test cmd...>
  local desc="$1" timeout="$2"; shift 2
  local i=0
  while ! "$@" >/dev/null 2>&1; do
    i=$((i + 1))
    (( i > timeout / 3 )) && fail "timed out waiting for: ${desc}"
    sleep 3
  done
  echo "  OK: ${desc}"
}

log "Verifying tmkms signing + node validation"
# Capture logs into a var and match with a here-string. A `compose logs | grep -q`
# pipeline would SIGPIPE `docker compose logs` once grep matches early, and under
# `set -o pipefail` the pipeline then returns non-zero — a false "not found".
_logs() { compose logs "$1" 2>/dev/null || true; }
tmkms_logged() { local o; o="$(_logs tmkms)"; grep -q "$1" <<<"$o"; }
gnoland_logged() { local o; o="$(_logs gnoland)"; grep -q "$1" <<<"$o"; }
# Fetch /status with all whitespace stripped, then pull fields with bash regex
# (no pipes → no pipefail/SIGPIPE traps; tolerant of pretty-printed JSON).
_status() { curl -sf --max-time 3 "$RPC/status" 2>/dev/null | tr -d '[:space:]'; }
rpc_height() { local s; s="$(_status)"; [[ "$s" =~ \"latest_block_height\":\"?([0-9]+)\"? ]] && printf '%s' "${BASH_REMATCH[1]}"; }
rpc_vp() { local s; s="$(_status)"; [[ "$s" =~ \"voting_power\":\"?([0-9]+)\"? ]] && printf '%s' "${BASH_REMATCH[1]}"; }
rpc_network() { local s; s="$(_status)"; [[ "$s" =~ \"network\":\"([^\"]*)\" ]] && printf '%s' "${BASH_REMATCH[1]}"; }
rpc_height_ge2() { local h; h="$(rpc_height)"; [[ -n "$h" && "$h" -ge 2 ]]; }

wait_for "tmkms connects to the validator" 60 tmkms_logged "connected to validator successfully"
wait_for "gnoland reports it is a validator" 60 gnoland_logged "This node is a validator"
wait_for "tmkms signs a Precommit" 60 tmkms_logged "signed Precommit"
wait_for "RPC reports block height >= 2" 90 rpc_height_ge2

vp="$(rpc_vp || true)"
[[ -n "$vp" && "$vp" -ge 1 ]] || fail "validator voting power is not >= 1 (got '${vp:-empty}')"
echo "  OK: validator voting power = ${vp}"

height="$(rpc_height || true)"
network="$(rpc_network || true)"
[[ "$network" == "$CHAIN_ID" ]] || fail "chain id mismatch: RPC network='${network}' expected '${CHAIN_ID}'"

# --- 7. Reset round-trip ----------------------------------------------------
# 'make reset' must clear tmkms's double-sign state along with the chain state,
# or tmkms refuses to sign until the chain climbs back past its last height.
# Runs the real cmd_reset against the isolated workdir copy of .Makefile.sh.
log "Verifying 'make reset' clears tmkms double-sign state"
TM_STATE="$WORKDIR/tmkms-data/consensus_state.json"
PV_STATE="$WORKDIR/gnoland-data/secrets/priv_validator_state.json"

[[ -f "$TM_STATE" ]] || fail "tmkms wrote no consensus_state.json — nothing to reset"
tm_height_before="$(awk -F'"' '/"height"/{print $4; exit}' "$TM_STATE" 2>/dev/null || true)"
[[ -n "$tm_height_before" && "$tm_height_before" -gt 0 ]] ||
  fail "tmkms double-sign state is not above height 0 (got '${tm_height_before:-empty}')"
echo "  OK: tmkms double-sign state at height ${tm_height_before}"

# Stop first so reset sees was_running=0 and skips its stop/start prompts —
# restarting is done below with the e2e's own compose invocation, since cmd_start
# would go through the build-state machinery this test deliberately bypasses.
compose stop gnoland tmkms >/dev/null 2>&1 || true
( cd "$WORKDIR" && YES=1 bash .Makefile.sh reset ) || fail "'reset' exited non-zero"

[[ ! -e "$WORKDIR/gnoland-data/db" ]] || fail "reset left gnoland-data/db behind"
[[ ! -e "$WORKDIR/gnoland-data/wal" ]] || fail "reset left gnoland-data/wal behind"
[[ ! -e "$TM_STATE" ]] || fail "reset left tmkms-data/consensus_state.json behind"
[[ -s "$WORKDIR/tmkms-data/consensus.key" ]] || fail "reset destroyed tmkms-data/consensus.key"
pv_height_after="$(awk -F'"' '/"height"/{print $4; exit}' "$PV_STATE" 2>/dev/null || true)"
[[ "$pv_height_after" == "0" ]] || fail "priv_validator_state.json not at height 0 (got '${pv_height_after:-empty}')"
echo "  OK: chain state + tmkms state cleared, consensus key kept"

# tmkms must recreate the state file on its own and sign from a clean slate —
# the assumption behind deleting it rather than rewriting it to height 0.
log "Restarting after reset"
compose up -d gnoland tmkms
# Assert on the recreated state file rather than the logs: `compose stop` + `up`
# reuses the containers, so their pre-reset logs are still there and a
# "signed Precommit" grep would match the old run. A state file that reappears
# and climbs is proof tmkms recreated it and is signing now.
tm_state_ge2() {
  local h
  [[ -f "$TM_STATE" ]] || return 1
  h="$(awk -F'"' '/"height"/{print $4; exit}' "$TM_STATE" 2>/dev/null || true)"
  [[ -n "$h" && "$h" -ge 2 ]]
}
wait_for "tmkms recreates its state file and signs past height 2" 120 tm_state_ge2
wait_for "RPC reports block height >= 2 after reset" 120 rpc_height_ge2
echo "  OK: tmkms recreated its state file and resumed signing"

height="$(rpc_height || true)"
vp="$(rpc_vp || true)"

log "PASS — local bundled tmkms signed consensus for the validator"
echo "  chain_id: ${network}   height: ${height}   voting_power: ${vp}"
