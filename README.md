# gno-validator

Docker Compose setup for a `gnoland` validator node.
By default the node signs with its built-in local file signer; optionally it can
use [`tmkms`](https://github.com/iqlusioninc/tmkms) as a remote signer — either a
**bundled** tmkms container on the same host (dev/lab) or an **external** tmkms on
a dedicated host (production). The signer is selected entirely in `config.overrides`.
`gnoland` is built from source (`gnolang/gno`); the bundled tmkms image is built
from source (`iqlusioninc/tmkms`, softsign backend) only when local mode is used.
A `sentinel` sidecar ships node metrics, logs, and OTLP traces to an external [gno-watchtower](https://github.com/aeddi/gno-watchtower) server.

## Prerequisites

- Docker and Docker Compose v2
- make

## Setup

Seven-step quick start. Each step links to the matching detailed section below when one exists.

### 1. `validator.env`

Environment variables (image tags, host ports, gnoland flags). Copy the example and edit. See [validator.env reference](#validatorenv-reference) for the full list.

```sh
cp validator.env.example validator.env
$EDITOR validator.env
```

### 2. `config.overrides`

Per-node gnoland config (moniker, peers, telemetry labels). Copy the example and fill the required fields. See [config.overrides reference](#configoverrides-reference).

```sh
cp config.overrides.example config.overrides
$EDITOR config.overrides
```

### 3. `sentinel.toml`

Sentinel sidecar config. Ask your watchtower operator for the server URL and auth token, then copy the example and set `server.url` / `server.token` — leaving the `<placeholders>` unchanged causes the sentinel container to crash-loop with a clear validation error at startup. Full field reference: [gno-watchtower → Sentinel config](https://github.com/aeddi/gno-watchtower#sentinel-config-configtoml).

```sh
cp sentinel.toml.example sentinel.toml
$EDITOR sentinel.toml
```

### 4. Generate the signing identity

```sh
make gen-identity
```

Behavior depends on the signer selected in `config.overrides` (see [Signing](#signing)):

- **local file signer** (default) — creates `gnoland-data/secrets/priv_validator_key.json` and prints the validator address / pub_key / node peer ID.
- **local tmkms** (`unix://` listener) — also writes `tmkms-data/consensus.key` (the softsign consensus key, derived from the same validator key) for the bundled tmkms container.
- **remote tmkms** (`tcp://` listener) — generates no signing key locally; prints the node peer ID and the values to exchange with the tmkms operator.

### 5. Provide `genesis.json`

Copy your chain's genesis file to the repo root:

```sh
cp /path/to/genesis.json .
```

### 6. Start

```sh
make start
```

Builds the gnoland image on first run (minutes; also the tmkms image if local tmkms is selected — the Rust build adds several minutes), creates containers, starts the node.

### 7. Verify

```sh
make infos               # identity, network config, build metadata, checksums
make status watch=5      # live status table (height, peers, VP) refreshing every 5s
```

---

## Configuration reference

### validator.env reference

| Variable              | Default                           | Meaning                                                                                                                                                                                                                                           |
| --------------------- | --------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `GNO_VERSION`         | `master`                          | Branch, tag, or commit hash of `gnolang/gno` to build.                                                                                                                                                                                            |
| `GNO_REPO`            | `gnolang/gno`                     | GitHub repo slug to clone gno sources from.                                                                                                                                                                                                       |
| `SENTINEL_IMAGE_TAG`  | `latest`                          | Tag or digest for the sentinel image pulled from `ghcr.io/aeddi/gno-watchtower/sentinel`. Pin a digest (`sha256:...`) for reproducibility; drift is reported when a tag like `latest` advances on the registry.                                   |
| `GNOLAND_RPC_LADDR`   | `0.0.0.0`                         | Host interface gnoland RPC binds to. Use `127.0.0.1` when exposing RPC only via a reverse proxy.                                                                                                                                                  |
| `GNOLAND_RPC_PORT`    | `26657`                           | Host port mapped to gnoland RPC.                                                                                                                                                                                                                  |
| `GNOLAND_P2P_LADDR`   | `0.0.0.0`                         | Host interface gnoland P2P binds to. Use `127.0.0.1` only if this node should not accept inbound peer connections.                                                                                                                                |
| `GNOLAND_P2P_PORT`    | `26656`                           | Host port mapped to gnoland P2P.                                                                                                                                                                                                                  |
| `TMKMS_LISTEN_LADDR`  | `0.0.0.0`                         | Host interface for the tmkms privval listener. Only used with a **remote** (`tcp://`) tmkms signer; inert otherwise. Restrict / firewall to the signer host in production.                                                                         |
| `TMKMS_LISTEN_PORT`   | `26659`                           | Host port mapped to the tmkms privval listener (remote mode).                                                                                                                                                                                     |
| `GNOLAND_EXTRA_FLAGS` | `--skip-genesis-sig-verification` | Extra flags appended to `gnoland start`, word-split on whitespace. Add or remove as needed (e.g. `--skip-genesis-sig-verification --log-level info`).                                                                                             |
| `GNOLAND_NTP_UPDATE`  | `1`                               | Any non-empty value enables in-container NTP sync at gnoland startup (tries `ntpd`, then `rdate`, then an HTTPS `Date` header; first success wins). Set empty to skip — e.g. when `chronyd` / `systemd-timesyncd` already manages the host clock. |
| `GNOLAND_LOG_SIZE`    | `3`                               | Number of 1 GB gnoland log files to keep (3 × 1 GB = 3 GB total).                                                                                                                                                                                 |

### config.overrides reference

Per-node gnoland config. Each line is `key = value`; `#` comments and blank lines are ignored. Applied to `gnoland-data/config/config.toml` on every container start and every `make infos` run. `config.overrides` is gitignored and stays local to each operator.

**Required fields:**

- `moniker` — human-readable node name.
- `p2p.external_address` — public P2P address, e.g. `<your-ip>:26656`.
- `p2p.persistent_peers` — comma-separated peers to keep persistent connections to.
- `telemetry.service_instance_id` — node identifier tagged on OTLP traces (e.g. your moniker).
- `telemetry.service_name` — service identifier tagged on OTLP traces (e.g. the chain ID).

**Recommended fields** (included in `config.overrides.example`):

- `application.prune_strategy = "syncable"`
- `consensus.peer_gossip_sleep_duration = "10ms"`
- `consensus.timeout_commit = "3s"`
- `mempool.size = 10000`
- `p2p.flush_throttle_timeout = "10ms"`
- `p2p.max_num_outbound_peers = 40`

**Signer fields** (optional; commented out by default → local file signer). Set these to use tmkms — see [Signing](#signing):

- `consensus.priv_validator.tmkms_listener.listen_addr` — `unix://…` (bundled local tmkms) or `tcp://…` (remote tmkms). Empty/absent = local file signer. Set this key **last**.
- `consensus.priv_validator.tmkms_listener.chain_id` — must match tmkms's `[[validator]].chain_id`.
- `consensus.priv_validator.tmkms_listener.protocol_version` — must be `"v0.34"`.
- `consensus.priv_validator.tmkms_listener.allowed_kms_pubkeys` — required (non-empty) on `tcp://`; the tmkms identity pubkey(s), comma-separated. Ignored on `unix://`.

**Hardcoded overrides** — the entrypoint re-applies these after your `config.overrides` on every container start, so they always win:

| Key                                                     | Value                      | Why                                                                                                       |
| ------------------------------------------------------- | -------------------------- | --------------------------------------------------------------------------------------------------------- |
| `p2p.laddr`                                             | `tcp://0.0.0.0:26656`      | In-container P2P bind (host interface/port via `GNOLAND_P2P_LADDR`/`GNOLAND_P2P_PORT` in `validator.env`) |
| `rpc.laddr`                                             | `tcp://0.0.0.0:26657`      | In-container RPC bind (host interface/port via `GNOLAND_RPC_LADDR`/`GNOLAND_RPC_PORT` in `validator.env`) |
| `telemetry.metrics_enabled`                             | `true`                     | Sentinel collects OTLP metrics                                                                            |
| `telemetry.traces_enabled`                              | `true`                     | Sentinel collects OTLP traces                                                                             |
| `telemetry.exporter_endpoint`                           | `http://sentinel:4318`     | In-compose DNS name for the sentinel sidecar                                                              |

Any other gnoland config key is fair game — add what you need (e.g. `p2p.seeds`).

### sentinel.toml reference

Sentinel's format is defined upstream. See [gno-watchtower → Sentinel config](https://github.com/aeddi/gno-watchtower#sentinel-config-configtoml) for every field. The only values you must set for this project are `server.url` and `server.token` (supplied by the watchtower operator). `sentinel.toml` is gitignored and stays local to each operator.

---

## Operations

### Lifecycle

| Command                 | What it does                                                                                                                                                                                    | Cost                                            |
| ----------------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ----------------------------------------------- |
| `make start`            | First run: builds images + creates containers. Stopped containers: resumes them (preserves container logs). Already running: no-op, prints a drift report if any input changed since last boot. | Free after first run.                           |
| `make stop`             | Stops services but keeps containers (no recreate). Idempotent.                                                                                                                                  | Free.                                           |
| `make restart`          | `stop` + `start`. Re-applies `config.overrides` on the way up.                                                                                                                                  | Free.                                           |
| `make update [force=1]` | Rebuilds images if build inputs changed, pulls sentinel on digest drift, recreates containers if `validator.env` / `docker-compose.yml` changed. `force=1` does everything unconditionally.     | Rebuild minutes; recreate wipes container logs. |
| `make reset [yes=1]`    | Wipes chain state (`db`, `wal`, `priv_validator_state.json`). Prompts to stop and restart around the wipe; `yes=1` skips all prompts. Preserves signing keys (`tmkms-data/`, validator key) and node_id.          | Destructive on chain DB.                        |

### Build (rarely needed manually)

| Command                | What it does                                                                                                                                                                                                          |
| ---------------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `make build [force=1]` | Builds images when `.build-state` doesn't match the current inputs (gno commit, `Dockerfile`, entrypoints) or the tagged images are missing. `force=1` rebuilds anyway. `start` and `update` call this automatically. |

### Inspection

| Command                     | What it does                                                                                                                                                                                                                                                                                                                                                                                                             |
| --------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| `make status [watch=<sec>]` | Node status table (height, peers, validator VP, sync). `watch=N` refreshes every N seconds (requires jq — auto-installed under `.tools/bin/` if absent; falls back to raw JSON if install fails).                                                                                                                                                                                                                        |
| `make infos`                | Validator identity, network config, build metadata, binary checksums.                                                                                                                                                                                                                                                                                                                                                    |
| `make logs [since=<d>]`     | Merged TUI of gnoland + sentinel logs (plus tmkms in local mode) via [gonzo](https://github.com/control-theory/gonzo). Per-service defaults: gnoland=1h, tmkms/sentinel=24h. `since=X` overrides them. Each line is tagged `service.name` so the built-in Service column filters by origin. Auto-installed under `.tools/bin/` on first use; config lives at `.tools/gonzo.yml` (tracked). Press `?` inside the TUI for keybindings. |

### Cleanup

| Command                           | What it does                                                                                                                                                                                                                                                        |
| --------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `make clean-imgs [all=1] [yes=1]` | Default: remove stale `gno-validator-*` tags (anything not matching the current `.build-state`). `all=1` removes all gno-validator images and the sentinel image too. `yes=1` skips the confirm prompt. Refuses if any container still references a targeted image. |

### Setup

| Command             | What it does                                                    |
| ------------------- | --------------------------------------------------------------- |
| `make gen-identity` | Generate/show the validator identity (and the tmkms softsign key in local mode). See [Signing](#signing). |
| `make help`         | Show the target list.                                           |

### Change → command cheat sheet

| You edited…                            | Minimum command |
| -------------------------------------- | --------------- |
| `config.overrides`                     | `make restart`  |
| `validator.env`, `docker-compose.yml`  | `make update`   |
| `Dockerfile`, `docker/*-entrypoint.sh` | `make update`   |
| Upstream `GNO_VERSION` branch moved    | `make update`   |

> `make update` prompts before recreating — pass `force=1` to skip the prompt.

### How drift detection works

`make build` writes `.build-state` (gitignored) recording the commit, version, repo, per-image content hashes, and the sentinel image digest resolved from ghcr. `make start` and `make update` read it back and report drift precisely (e.g., `gno commit advanced on chain/test12: 8513a68f → 9a2b4c1e`, or `sentinel image advanced on latest: 8513a68f → 9a2b4c1e`). The gnoland commit check hits `git ls-remote`, and the sentinel check hits `docker manifest inspect`; both gracefully skip on network failure.

Downloaded tools (gonzo, jq) live under `.tools/bin/` (gitignored, auto-fetched on first use). Gonzo's config lives at `.tools/gonzo.yml` (tracked).

## Architecture

- **gnoland** exposes RPC (`GNOLAND_RPC_PORT`, default `26657`) and P2P (`GNOLAND_P2P_PORT`, default `26656`) to the host. When `GNOLAND_NTP_UPDATE` is set (default), the container syncs its clock before launching gnoland, trying `ntpd`, then `rdate`, then an HTTPS `Date` header until one succeeds. The container has `CAP_SYS_TIME`, so on a Linux host this also updates the host's clock — disable `GNOLAND_NTP_UPDATE` if another NTP daemon already manages the host.
- **tmkms** (optional) signs votes/proposals for gnoland via the upstream Tendermint privval v0.34 protocol — **tmkms dials gnoland**, which listens. In local mode it runs as a bundled container reaching gnoland over a shared Unix socket (no network port). In remote mode it runs on a dedicated host and connects to gnoland's TCP listener (`TMKMS_LISTEN_PORT`, default `26659`).
- **sentinel** collects gnoland RPC status, container logs, OTLP traces, and system resources, then forwards them to a central watchtower server. Image is pulled from `ghcr.io/aeddi/gno-watchtower/sentinel` (tag set via `SENTINEL_IMAGE_TAG`).
- `gnoland-data/`, `tmkms-data/`, and `genesis.json` are gitignored — back them up.

## Signing

The signer is selected in `config.overrides` via `consensus.priv_validator.tmkms_listener.listen_addr`. Set that key **last** (validation requires the other `tmkms_listener.*` fields first). See [`config.overrides.example`](config.overrides.example) and the upstream [tmkms quickstart](https://github.com/gnolang/gno/blob/master/docs/validators/tmkms-quickstart.md).

| Mode | `listen_addr` | tmkms runs | Consensus key | Use for |
| --- | --- | --- | --- | --- |
| **Local file signer** (default) | _(unset)_ | — | `gnoland-data/secrets/priv_validator_key.json` | Simplest; single-host, no KMS |
| **Local tmkms** | `unix:///tmkms-sock/privval.sock` | bundled container (`make start`) | `tmkms-data/consensus.key` (softsign, on disk) | Dev/lab parity with the tmkms path |
| **Remote tmkms** | `tcp://0.0.0.0:26659` | operator-run, dedicated host | on the tmkms host (HSM/softsign) | Production |

**Local tmkms.** `make gen-identity` creates the validator key and exports its softsign copy to `tmkms-data/consensus.key`. `make start` builds the tmkms image (Rust, several minutes on first run) and runs the container; tmkms dials gnoland's Unix socket. Softsign keeps the key on disk, so this is **dev/lab only** — for production use a remote tmkms with an HSM.

**Remote tmkms.** `make gen-identity` prints the **node peer ID**; give it, the `chain_id`, and the `listen_addr` to the tmkms operator. They pin the peer ID in tmkms's `addr = "tcp://<peer-id>@<host>:26659"` and hand back their **tmkms identity pubkey**, which you put in `allowed_kms_pubkeys`. Register the validator's consensus pub_key (from the tmkms host) in `genesis.json`. Start tmkms first (it retries via `reconnect = true`); gnoland then waits up to 60 s for it to dial in. Firewall `TMKMS_LISTEN_PORT` to the signer's IP.

## Logging

- gnoland: up to 3 GB by default (3 × 1 GB files, rotated), configurable via `GNOLAND_LOG_SIZE`
- tmkms (local mode only): up to 1 GB
- sentinel: up to 100 MB

## Optional: Reverse Proxy

The [`reverse-proxy/`](reverse-proxy/) subfolder contains a Caddy setup that exposes the node services (RPC, Gnockpit) over HTTPS with automatic Let's Encrypt certificates. See [`reverse-proxy/README.md`](reverse-proxy/README.md) for setup instructions.
