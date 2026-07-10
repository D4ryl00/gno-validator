#!/bin/sh
set -eu

# tmkms remote signer (bundled "local" mode, softsign backend).
#
# tmkms DIALS gnoland's privval listener over a Unix socket shared via the
# tmkms-sock volume (gnoland listens, tmkms is the client). Softsign keeps the
# consensus key on disk, so this mode is a dev/lab convenience; production
# validators run tmkms on a dedicated host with an HSM (see README).

# Config is written into the (host-bind, writable) data dir rather than /etc so
# the container can run as the non-root host user — matching gnoland, which owns
# the shared socket and the consensus key.
CONFIG="/tmkms-data/tmkms.toml"
KEY="/tmkms-data/consensus.key"
STATE="/tmkms-data/consensus_state.json"
SOCK="unix:///tmkms-sock/privval.sock"

# ---- Check chain ID is set (must match gnoland's tmkms_listener.chain_id)
if [ -z "${TMKMS_CHAIN_ID:-}" ]; then
  printf "Error: TMKMS_CHAIN_ID is not set. Set it in validator.env to match config.overrides' tmkms_listener.chain_id.\n" >&2
  exit 1
fi

# ---- Check the consensus key exists
if [ ! -f "$KEY" ]; then
  printf "Error: consensus key not found at %s.\nRun 'make gen-identity' to create it.\n" "$KEY" >&2
  exit 1
fi

# ---- Generate tmkms.toml
# key_format = hex on the chain block matches how tm2 reports/consumes the
# pubkey; the softsign consensus.key itself is a base64-encoded 32-byte ed25519
# seed. No secret_key on a unix:// listener — SecretConnection is skipped there
# (the boundary is filesystem permissions on the socket).
cat >"$CONFIG" <<EOF
[[chain]]
id = "${TMKMS_CHAIN_ID}"
key_format = { type = "hex" }
state_file = "${STATE}"

[[providers.softsign]]
chain_ids = ["${TMKMS_CHAIN_ID}"]
key_type = "consensus"
key_format = "base64"
path = "${KEY}"

[[validator]]
chain_id = "${TMKMS_CHAIN_ID}"
addr = "${SOCK}"
protocol_version = "v0.34"
reconnect = true
EOF

# ---- Start tmkms with signal forwarding for clean container shutdown.
# Propagate tmkms's exit status so Docker's restart policy triggers on crashes.
tmkms start -c "$CONFIG" &
tmkms_pid=$!

trap 'kill "$tmkms_pid" 2>/dev/null || true' HUP INT TERM

status=0
wait "$tmkms_pid" || status=$?
exit "$status"
