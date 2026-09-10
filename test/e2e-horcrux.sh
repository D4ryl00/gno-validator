#!/usr/bin/env bash
# e2e-horcrux.sh — end-to-end test of the "remote signer" mode, driven by a
# 3-cosigner horcrux threshold cluster.
#
# Proves the production signing path works: builds the gnoland and horcrux
# images, generates a validator key, splits it into 2-of-3 shards across three
# cosigners, boots gnoland with a tcp:// tmkms_listener plus the three
# cosigners, and asserts the cluster signs consensus while the node validates
# with voting power and block height advances.
#
# It covers the three things that are specific to gnoland and that vanilla
# horcrux gets wrong (see the aeddi/horcrux fork notes):
#
#   1. gnoland requires a non-empty allowed_kms_pubkeys on a tcp:// listener, so
#      every cosigner needs a persistent connKeyFile. An ephemeral connection
#      identity could never match the allowlist.
#   2. gnoland holds exactly ONE signer slot with a 3s accept window, so the
#      cluster must run with leaderOnlyChainNodeConnections. Without it the
#      connection churns and the validator signs nothing.
#   3. On a leadership change the new leader must take over that single slot.
#      Step 8 forces an election and asserts the chain keeps advancing.
#
# It also exercises 'make gen-identity' in remote mode: the node connection
# pubkey pinned as each cosigner's connPubKey is read from its output, so a
# regression there fails this test rather than silently shipping.
#
# Heavyweight and opt-in: clones gno and horcrux and builds both (first run
# ~15 min). Requires Docker + curl. No host Go/Rust toolchain needed.
#
# Isolation: everything runs in a temp workdir under its own compose project
# name (gno-validator-e2e-horcrux), its own image names, and its own host ports
# (default 37656-37659), so it can run alongside e2e-tmkms-local.sh and never
# touches a real deployment's containers, images, data dirs or 2665x ports.
# Containers and the temp dir are torn down on exit.
#
# Env overrides:
#   GNO_REPO       gno source repo slug            (default: gnolang/gno)
#   GNO_VERSION    branch/tag/commit               (default: master)
#   HORCRUX_REPO   horcrux git URL to build from   (default: aeddi/horcrux)
#   HORCRUX_REF    branch/tag/commit to build      (default: main)
#   HORCRUX_IMAGE  prebuilt image to use instead   (default: build from source)
#   CHAIN_ID       test chain id                   (default: gno-horcrux-e2e)
#   RPC_PORT/P2P_PORT/SIGNER_PORT  host ports      (default: 37657/37656/37659)
#   KEEP_IMAGES=1  keep the e2e images after the run (default: removed)
#   NO_CACHE=1     docker build --no-cache
set -euo pipefail

# --- Config -----------------------------------------------------------------
GNO_REPO="${GNO_REPO:-gnolang/gno}"
GNO_VERSION="${GNO_VERSION:-master}"
# The gno fork carries the tm2 compatibility fixes vanilla horcrux lacks: a
# spec-compliant sign response (tm2 validates the returned vote strictly) and
# leaderOnlyChainNodeConnections. Upstream strangelove-ventures/horcrux is
# archived and cannot sign for a gnoland node.
HORCRUX_REPO="${HORCRUX_REPO:-https://github.com/aeddi/horcrux.git}"
HORCRUX_REF="${HORCRUX_REF:-main}"
CHAIN_ID="${CHAIN_ID:-gno-horcrux-e2e}"
RPC_PORT="${RPC_PORT:-37657}"
P2P_PORT="${P2P_PORT:-37656}"
SIGNER_PORT="${SIGNER_PORT:-37659}"

# 2-of-3: any two cosigners can sign, so the cluster survives losing one. Also
# the smallest set where a leadership handoff is observable (step 8).
THRESHOLD=2
SHARDS=3

PROJECT="gno-validator-e2e-horcrux"
GNOLAND_IMAGE="gno-validator-e2e-horcrux-gnoland"
GENESIS_IMAGE="gno-validator-e2e-horcrux-gnogenesis"
# Empty unless the caller supplied one, in which case the build is skipped and
# the image is left alone at cleanup (we did not create it).
HORCRUX_IMAGE_PREBUILT="${HORCRUX_IMAGE:-}"
HORCRUX_IMAGE="${HORCRUX_IMAGE:-gno-validator-e2e-horcrux-horcrux}"

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
HUID="$(id -u)"
HGID="$(id -g)"
WORKDIR=""
NETWORK="${PROJECT}_net"
RPC="http://127.0.0.1:${RPC_PORT}"

log() { printf '\n\033[1m==> %s\033[0m\n' "$*"; }
fail() {
  # %b so an embedded \n in a message (captured command output) renders.
  printf '\n\033[31mFAIL: %b\033[0m\n' "$*" >&2
  dump_diagnostics
  exit 1
}

compose() {
  ( cd "$WORKDIR" && docker compose --env-file validator.env "$@" )
}

# horcrux containers are plain 'docker run', not compose services: they need
# per-cosigner homes and a startup order compose cannot express as cleanly
# (all three must be up before gnoland, which gives up after 60s).
cosigner_name() { echo "${PROJECT}-horcrux-$1"; }

dump_diagnostics() {
  [[ -z "$WORKDIR" ]] && return 0
  if [[ -f "$WORKDIR/docker-compose.yml" ]]; then
    echo "----- gnoland logs (tail) -----" >&2
    compose logs --tail 60 gnoland 2>&1 | tail -60 >&2 || true
  fi
  local i
  for i in $(seq 1 "$SHARDS"); do
    echo "----- horcrux-$i logs (tail) -----" >&2
    docker logs --tail 40 "$(cosigner_name "$i")" 2>&1 | tail -40 >&2 || true
  done
}

cleanup() {
  local rc=$?
  local i
  for i in $(seq 1 "$SHARDS"); do
    docker rm -f "$(cosigner_name "$i")" >/dev/null 2>&1 || true
  done
  if [[ -n "$WORKDIR" && -f "$WORKDIR/docker-compose.yml" ]]; then
    log "Cleaning up containers"
    compose down -v --remove-orphans >/dev/null 2>&1 || true
  fi
  docker network rm "$NETWORK" >/dev/null 2>&1 || true
  if [[ "${KEEP_IMAGES:-0}" != "1" ]]; then
    docker rmi -f "$GNOLAND_IMAGE" "$GENESIS_IMAGE" >/dev/null 2>&1 || true
    # Only remove the horcrux image if we built it.
    [[ -z "$HORCRUX_IMAGE_PREBUILT" ]] && docker rmi -f "$HORCRUX_IMAGE" >/dev/null 2>&1 || true
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
# Same isolation discipline as e2e-tmkms-local.sh: copy the working tree's build
# inputs (so uncommitted changes are tested), then rename the compose project
# and image names so nothing collides with a real deployment or with the other
# e2e running concurrently.
log "Setting up isolated workdir"
docker network create "$NETWORK" >/dev/null 2>&1 || true
WORKDIR="$(mktemp -d "${TMPDIR:-/tmp}/gno-val-e2e-horcrux.XXXXXX")"
cp "$REPO_ROOT/Dockerfile" "$REPO_ROOT/docker-compose.yml" "$REPO_ROOT/.Makefile.sh" "$WORKDIR/"
cp -R "$REPO_ROOT/docker" "$WORKDIR/docker"
mkdir -p "$WORKDIR/gnoland-data" "$WORKDIR/tmkms-data" "$WORKDIR/tmkms-sock" "$WORKDIR/horcrux"

sed -i.bak \
  -e 's/^name: gno-validator$/name: '"$PROJECT"'/' \
  -e 's/image: gno-validator-gnoland/image: '"$GNOLAND_IMAGE"'/' \
  "$WORKDIR/docker-compose.yml"
rm -f "$WORKDIR/docker-compose.yml.bak"

# The copied .Makefile.sh resolves PROJECT_ROOT from its own location, so its
# data dirs land in WORKDIR — but its container/image names are hardcoded to the
# default project and would otherwise inspect a real deployment.
sed -i.bak \
  -e 's/^GNOLAND_CONTAINER=.*/GNOLAND_CONTAINER="'"$PROJECT"'-gnoland-1"/' \
  -e 's/^TMKMS_CONTAINER=.*/TMKMS_CONTAINER="'"$PROJECT"'-tmkms-1"/' \
  -e 's/^SENTINEL_CONTAINER=.*/SENTINEL_CONTAINER="'"$PROJECT"'-sentinel-1"/' \
  -e 's/^GNOLAND_IMAGE=.*/GNOLAND_IMAGE="'"$GNOLAND_IMAGE"'"/' \
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
SIGNER_LISTEN_LADDR=127.0.0.1
SIGNER_LISTEN_PORT=${SIGNER_PORT}
EOF

# config.overrides with a placeholder allowlist: the real cosigner pubkeys do
# not exist until step 4, but 'make gen-identity' (step 3) needs the file to
# already select remote mode so it prints the node connection pubkey. Rewritten
# in step 6 before anything starts.
write_overrides() { # <allowed_kms_pubkeys>
  cat >"$WORKDIR/config.overrides" <<EOF
moniker = "e2e-horcrux-val"
consensus.priv_validator.tmkms_listener.chain_id = "${CHAIN_ID}"
consensus.priv_validator.tmkms_listener.protocol_version = "v0.34"
consensus.priv_validator.tmkms_listener.allowed_kms_pubkeys = "$1"
consensus.priv_validator.tmkms_listener.listen_addr = "tcp://0.0.0.0:26659"
EOF
}
write_overrides "0000000000000000000000000000000000000000000000000000000000000000"

export HOST_UID="$HUID" HOST_GID="$HGID"
BUILD_ARGS=(); [[ "${NO_CACHE:-0}" == "1" ]] && BUILD_ARGS+=(--no-cache)

# --- 2. Build images --------------------------------------------------------
log "Building gnoland image (this can take several minutes)"
compose build "${BUILD_ARGS[@]}" gnoland

if [[ -n "$HORCRUX_IMAGE_PREBUILT" ]]; then
  log "Using prebuilt horcrux image: ${HORCRUX_IMAGE}"
  docker image inspect "$HORCRUX_IMAGE" >/dev/null 2>&1 ||
    fail "HORCRUX_IMAGE='${HORCRUX_IMAGE}' not found locally"
else
  # Built from test/Dockerfile.horcrux, which clones the fork and builds the
  # binary onto alpine. The fork's own docker/horcrux/Dockerfile is unusable:
  # it assembles a scratch image from ghcr.io/strangelove-ventures/infra-toolkit,
  # which stopped serving anonymous pulls (403) when upstream was archived.
  log "Building horcrux image from ${HORCRUX_REPO}#${HORCRUX_REF}"
  docker build "${BUILD_ARGS[@]}" \
    -f "$REPO_ROOT/test/Dockerfile.horcrux" \
    --build-arg "HORCRUX_REPO=${HORCRUX_REPO}" \
    --build-arg "HORCRUX_REF=${HORCRUX_REF}" \
    -t "$HORCRUX_IMAGE" "$REPO_ROOT/test" ||
    fail "horcrux image build failed"
fi

# Shell snippet (POSIX, busybox-safe) run inside a container: reads the amino
# JSON key file named by $KEYFILE and leaves its base64 private key in $b64.
# gnoland writes two shapes — a bare string for a concrete key field
# (node_key.json) and {"@type"/"type","value"} for an interface one
# (priv_validator_key.json) — so branch on whichever follows "priv_key" rather
# than scanning ahead for the next "value", which would run into the *next*
# field entirely when the shape is bare.
read_privkey_b64='
  raw=$(tr -d " \t\n\r" < "$KEYFILE")
  rest=${raw#*\"priv_key\":}
  [ "$rest" != "$raw" ] || { echo "no priv_key in $KEYFILE" >&2; exit 1; }
  case "$rest" in
    \{*) b64=${rest#*\"value\":\"}; b64=${b64%%\"*} ;;
    \"*) b64=${rest#\"};           b64=${b64%%\"*} ;;
    *)   echo "unexpected priv_key shape in $KEYFILE" >&2; exit 1 ;;
  esac
  [ -n "$b64" ] || { echo "empty priv_key in $KEYFILE" >&2; exit 1; }
'

# Every invocation joins the cluster network: 'leader' and 'elect' reach the
# cosigners by container name, so the network must exist before the first call
# (created in step 1).
horcrux_run() { # <cosigner-home-subdir> <args...>
  local home="$1"; shift
  docker run --rm --user "${HUID}:${HGID}" \
    --network "$NETWORK" \
    -v "$WORKDIR/horcrux:/horcrux" \
    "$HORCRUX_IMAGE" horcrux --home "/horcrux/${home}" "$@"
}

# --- 3. Validator identity + node connection pubkey -------------------------
log "Generating validator identity"
gnoland_run() {
  docker run --rm --user "${HUID}:${HGID}" \
    -v "$WORKDIR/gnoland-data:/gnoland-data" \
    --entrypoint gnoland "$GNOLAND_IMAGE" "$@"
}
gnoland_run secrets init >/dev/null 2>&1 || true

ADDR="$(gnoland_run secrets get validator_key.address --raw 2>/dev/null | tr -d '\r\n')"
PUB="$(gnoland_run secrets get validator_key.pub_key --raw 2>/dev/null | tr -d '\r\n')"
[[ -n "$ADDR" && -n "$PUB" ]] || fail "could not read validator identity"
echo "  validator: $ADDR"

# Read the node connection pubkey out of the real 'make gen-identity' output
# rather than recomputing it here: this is the value operators are told to paste
# into connPubKey, so the test consumes it exactly as they would. A regression
# in that output fails here.
log "Reading node connection pubkey from 'make gen-identity'"
GEN_OUT="$( ( cd "$WORKDIR" && bash .Makefile.sh gen-identity ) 2>&1 )" ||
  fail "gen-identity exited non-zero:\n${GEN_OUT}"
NODE_CONN_PUBKEY="$(sed -n 's/.*node conn pubkey:[[:space:]]*\([0-9a-f]\{64\}\).*/\1/p' <<<"$GEN_OUT" | head -1)"
[[ -n "$NODE_CONN_PUBKEY" ]] ||
  fail "gen-identity did not print a 64-hex node conn pubkey. Output was:\n${GEN_OUT}"
echo "  node conn pubkey: ${NODE_CONN_PUBKEY}"

# Cross-check the value against node_key.json, derived independently here.
# Catches a helper that parses the wrong field and happens to yield 64 hex
# chars, which the allowlist would accept and the handshake would then reject.
NODE_CONN_RECHECK="$(docker run --rm --user "${HUID}:${HGID}" \
  -e KEYFILE=/gnoland-data/secrets/node_key.json \
  -v "$WORKDIR/gnoland-data:/gnoland-data" --entrypoint sh "$GNOLAND_IMAGE" -c "
    set -e
    ${read_privkey_b64}
    printf '%s' \"\$b64\" | base64 -d | tail -c 32 | od -An -v -tx1 | tr -d ' \n'
  " 2>/dev/null || true)"
[[ "$NODE_CONN_RECHECK" == "$NODE_CONN_PUBKEY" ]] ||
  fail "node conn pubkey mismatch: gen-identity said '${NODE_CONN_PUBKEY}', node_key.json says '${NODE_CONN_RECHECK}'"
echo "  OK: matches node_key.json"

# --- 4. Cosigner configs + connection keys ----------------------------------
# config.yaml is written before create-conn-key so the key lands at the
# configured connKeyFile path. Ports are inside the container network, so every
# cosigner can use the same ones.
log "Writing cosigner configs and connection keys"
COSIGNER_LIST=""
for i in $(seq 1 "$SHARDS"); do
  COSIGNER_LIST+="        - shardID: ${i}
          p2pAddr: tcp://$(cosigner_name "$i"):2222
"
done

CONN_PUBKEYS=""
for i in $(seq 1 "$SHARDS"); do
  mkdir -p "$WORKDIR/horcrux/cosigner_${i}"
  cat >"$WORKDIR/horcrux/cosigner_${i}/config.yaml" <<EOF
signMode: threshold
connKeyFile: conn_key.json
thresholdMode:
    threshold: ${THRESHOLD}
    grpcTimeout: 500ms
    raftTimeout: 500ms
    # gnoland holds a single signer slot with a 3s accept window: without this
    # the cosigners fight over it, the connection churns ~1x/s, and the
    # validator signs nothing.
    leaderOnlyChainNodeConnections: true
    cosigners:
${COSIGNER_LIST}chainNodes:
    - privValAddr: tcp://${PROJECT}-gnoland-1:26659
      connPubKey: ${NODE_CONN_PUBKEY}
debugAddr: ""
grpcAddr: ""
maxReadSize: 1048576
EOF

  out="$(horcrux_run "cosigner_${i}" create-conn-key 2>&1)" ||
    fail "create-conn-key failed for cosigner ${i}:\n${out}"
  pk="$(sed -n 's/.*Connection public key (hex):[[:space:]]*\([0-9a-f]\{64\}\).*/\1/p' <<<"$out" | head -1)"
  [[ -n "$pk" ]] || fail "could not parse conn pubkey for cosigner ${i}:\n${out}"
  CONN_PUBKEYS+="${CONN_PUBKEYS:+,}${pk}"
  echo "  cosigner ${i}: ${pk}"
done

# --- 5. Key shards ----------------------------------------------------------
# horcrux reads a CometBFT-format priv_validator_key.json; gnoland writes amino
# JSON with gno type tags. Convert inside the gnoland container: the private key
# is 64 bytes (seed||pubkey), and the last 32 are the pubkey.
log "Sharding the validator key ${THRESHOLD}-of-${SHARDS}"
docker run --rm --user "${HUID}:${HGID}" \
  -e KEYFILE=/gnoland-data/secrets/priv_validator_key.json \
  -v "$WORKDIR/gnoland-data:/gnoland-data" \
  -v "$WORKDIR/horcrux:/horcrux" \
  --entrypoint sh "$GNOLAND_IMAGE" -c "
    set -e
    ${read_privkey_b64}
    pub=\$(printf '%s' \"\$b64\" | base64 -d | tail -c 32 | base64 | tr -d '\n')
    cat > /horcrux/priv_validator_key.json <<JSON
{
  \"pub_key\":  { \"type\": \"tendermint/PubKeyEd25519\",  \"value\": \"\${pub}\" },
  \"priv_key\": { \"type\": \"tendermint/PrivKeyEd25519\", \"value\": \"\${b64}\" }
}
JSON
  " || fail "could not convert priv_validator_key.json to CometBFT format"

# --out writes cosigner_<N>/ subdirectories, which is exactly the per-cosigner
# home layout created in step 4.
horcrux_run "" create-ed25519-shards \
  --chain-id "$CHAIN_ID" \
  --key-file /horcrux/priv_validator_key.json \
  --threshold "$THRESHOLD" --shards "$SHARDS" \
  --out /horcrux >/dev/null || fail "create-ed25519-shards failed"
horcrux_run "" create-ecies-shards \
  --shards "$SHARDS" --out /horcrux >/dev/null || fail "create-ecies-shards failed"

for i in $(seq 1 "$SHARDS"); do
  [[ -s "$WORKDIR/horcrux/cosigner_${i}/${CHAIN_ID}_shard.json" ]] ||
    fail "cosigner ${i} has no key shard"
  [[ -s "$WORKDIR/horcrux/cosigner_${i}/ecies_keys.json" ]] ||
    fail "cosigner ${i} has no ECIES key"
done
# The plaintext full key has served its purpose; keep it out of the run.
rm -f "$WORKDIR/horcrux/priv_validator_key.json"
echo "  OK: ${SHARDS} shards written, full key removed"

# --- 6. Real allowlist + genesis --------------------------------------------
log "Writing config.overrides with the cosigner allowlist"
write_overrides "$CONN_PUBKEYS"

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

# --- 7. Boot: cosigners first, then gnoland ---------------------------------
# gnoland blocks at most 60s (wait_for_connection_timeout) for a signer to dial
# in, so the cluster must be up and have elected a leader first.
log "Starting the horcrux cluster"
for i in $(seq 1 "$SHARDS"); do
  docker run -d --name "$(cosigner_name "$i")" \
    --network "$NETWORK" \
    --user "${HUID}:${HGID}" \
    -v "$WORKDIR/horcrux:/horcrux" \
    "$HORCRUX_IMAGE" horcrux --home "/horcrux/cosigner_${i}" start >/dev/null ||
    fail "could not start cosigner ${i}"
done

log "Starting gnoland"
compose up -d gnoland
# Join gnoland to the cosigner network so the cosigners resolve it by container
# name (compose places it on its own network only).
docker network connect "$NETWORK" "${PROJECT}-gnoland-1" >/dev/null 2>&1 ||
  fail "could not attach gnoland to ${NETWORK}"

# --- 8. Assertions ----------------------------------------------------------
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

# Capture logs into a variable and match with a here-string: a `logs | grep -q`
# pipeline SIGPIPEs the log producer once grep matches early, and under
# `set -o pipefail` that reads as a false "not found".
_gnoland_logs() { compose logs gnoland 2>/dev/null || true; }
_cosigner_logs() { docker logs "$(cosigner_name "$1")" 2>&1 || true; }
gnoland_logged() { local o; o="$(_gnoland_logs)"; grep -q "$1" <<<"$o"; }
any_cosigner_logged() {
  local i o
  for i in $(seq 1 "$SHARDS"); do
    o="$(_cosigner_logs "$i")"
    grep -q "$1" <<<"$o" && return 0
  done
  return 1
}

_status() { curl -sf --max-time 3 "$RPC/status" 2>/dev/null | tr -d '[:space:]'; }
rpc_height() { local s; s="$(_status)"; [[ "$s" =~ \"latest_block_height\":\"?([0-9]+)\"? ]] && printf '%s' "${BASH_REMATCH[1]}"; }
rpc_vp() { local s; s="$(_status)"; [[ "$s" =~ \"voting_power\":\"?([0-9]+)\"? ]] && printf '%s' "${BASH_REMATCH[1]}"; }
rpc_network() { local s; s="$(_status)"; [[ "$s" =~ \"network\":\"([^\"]*)\" ]] && printf '%s' "${BASH_REMATCH[1]}"; }
rpc_height_ge() { local h; h="$(rpc_height)"; [[ -n "$h" && "$h" -ge "$1" ]]; }

log "Verifying the cluster signs and the node validates"
wait_for "a cosigner connects to the validator" 90 any_cosigner_logged "Connected to Sentry"
wait_for "gnoland reports it is a validator" 90 gnoland_logged "This node is a validator"
wait_for "RPC reports block height >= 2" 120 rpc_height_ge 2

vp="$(rpc_vp || true)"
[[ -n "$vp" && "$vp" -ge 1 ]] || fail "validator voting power is not >= 1 (got '${vp:-empty}')"
echo "  OK: validator voting power = ${vp}"

network="$(rpc_network || true)"
[[ "$network" == "$CHAIN_ID" ]] || fail "chain id mismatch: RPC network='${network}' expected '${CHAIN_ID}'"

# Only the raft leader may hold the privval connection: gnoland has a single
# signer slot, and every cosigner dialing it is the failure mode that silently
# stops the validator from signing. Assert on the followers' own parking
# message rather than counting connections — a follower that never dials says
# so explicitly, and the statement stays true no matter how leadership moved.
count_cosigners_logging() { # <pattern>
  local i n=0 o
  for i in $(seq 1 "$SHARDS"); do
    o="$(_cosigner_logs "$i")"
    grep -q "$1" <<<"$o" && n=$((n + 1))
  done
  printf '%s' "$n"
}
# A cosigner emits this only when the leadership gate is installed and reports
# false, so any occurrence proves the flag is on. The eventual leader logs it
# too, before it wins the election, so the count can legitimately reach SHARDS.
parked="$(count_cosigners_logging "Not the cluster leader, deferring connection to chain node")"
[[ "$parked" -ge $((SHARDS - 1)) ]] ||
  fail "expected >= $((SHARDS - 1)) cosigners to defer dialing, found ${parked} — is leaderOnlyChainNodeConnections set?"
echo "  OK: leader-only gating active (${parked}/${SHARDS} cosigners deferred dialing at some point)"

# --- 9. Leadership handoff --------------------------------------------------
# The single privval slot must move to the new leader. This is the behaviour
# vanilla horcrux lacks, so it is the assertion that earns this test.
log "Verifying the privval slot survives a leadership change"
current_leader() { # prints the shard ID of the current raft leader
  local o
  o="$(horcrux_run "cosigner_1" leader 2>&1 || true)"
  sed -n 's/.*Current leader:[[:space:]]*\([0-9][0-9]*\).*/\1/p' <<<"$o" | head -1
}

height_before="$(rpc_height || true)"
[[ -n "$height_before" ]] || fail "could not read height before the election"
leader_before="$(current_leader)"
[[ -n "$leader_before" ]] || fail "could not determine the current raft leader"
echo "  leader before: ${leader_before}"

elect_out="$(horcrux_run "cosigner_1" elect 2>&1)" || fail "elect failed:\n${elect_out}"

leader_changed() { local l; l="$(current_leader)"; [[ -n "$l" && "$l" != "$leader_before" ]]; }
wait_for "leadership moves off cosigner ${leader_before}" 90 leader_changed

# The old leader must let go of the slot and the new one must take it, or the
# node keeps a dead connection in its single signer slot.
wait_for "the old leader releases its chain-node connection" 90 \
  any_cosigner_logged "Lost cluster leadership, releasing connection to chain node"
wait_for "the new leader connects to the chain node" 90 \
  any_cosigner_logged "Elected cluster leader, connecting to chain node"

# A handoff costs a block or two (old leader drops, new leader dials, the node
# re-accepts within its 3s window), so allow headroom before calling it a stall.
target=$((height_before + 3))
wait_for "chain advances past height ${target} after the election" 150 rpc_height_ge "$target"

leader_after="$(current_leader)"
echo "  leader after:  ${leader_after}"

height="$(rpc_height || true)"
vp="$(rpc_vp || true)"

log "PASS — a ${THRESHOLD}-of-${SHARDS} horcrux cluster signed consensus for the validator"
echo "  chain_id: ${network}   height: ${height}   voting_power: ${vp}"
