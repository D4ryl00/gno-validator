# gno-validator

Docker Compose setup for a `gnoland` validator node.
By default the node signs with its built-in local file signer; optionally it can
delegate signing to an **external signer** over gnoland's privval listener — a
**bundled** `tmkms` container on the same host (dev/lab), or an external signer on
dedicated hosts (production): [`tmkms`](https://github.com/aeddi/tmkms) with an
HSM, or [`horcrux`](https://github.com/aeddi/horcrux) for threshold signing across
several machines. The signer is selected entirely in `config.overrides`.
`gnoland` is built from source (`gnolang/gno`); the bundled tmkms image is built
from source (`aeddi/tmkms`, the gno fork, softsign backend) only when local mode
is used.
A `sentinel` sidecar ships node metrics, logs, and OTLP traces to an external [gno-watchtower](https://github.com/aeddi/gno-watchtower) server.

## Prerequisites

- Docker and Docker Compose v2
- make

---

## Choose a signing setup first

Everything else is the same in all three; only the signer differs. Decide this
before step 2, because `config.overrides` and the setup sequence depend on it.

| | **Local file signer** | **Local tmkms** | **Remote signer** |
| --- | --- | --- | --- |
| Consensus key lives | on this host, on disk | on this host, on disk | on the signer host(s) |
| Hosts needed | 1 | 1 | 2+ (this node + signer) |
| Extra containers | — | `tmkms` (bundled) | none here |
| Key can be stolen from this host | yes | yes | no |
| Survives losing one machine | no | no | with horcrux, yes |
| `listen_addr` | _(unset)_ | `unix://…` | `tcp://…` |
| Setup | steps 1-7 as written | steps 1-7 as written | [runbook](#remote-signer-runbook) |
| Use for | testnets, throwaway nodes | dev/lab rehearsal of the tmkms path | **mainnet, real stake** |

**Which one:** use the **local file signer** unless the stake matters — it is the
simplest thing that works. Use **local tmkms** only to rehearse the tmkms path on
one machine; its softsign key sits on disk, so it buys no security over the file
signer. For anything with real slashing risk use a **remote signer**, and pick:

- **tmkms + HSM** — one signer host, key in hardware. Simpler. A dead signer host
  stops your validator.
- **horcrux** — key split across N hosts (typically 3, 2-of-3), no single host can
  sign alone and losing one host does not stop signing. More moving parts.

### Host topology

```
Local file signer / local tmkms          Remote signer (horcrux, 2-of-3)

┌─────────── host A ───────────┐         ┌────── host A ──────┐
│  gnoland + sentinel          │         │ gnoland + sentinel │   <- this repo
│  (+ tmkms container in       │         │ :26659 privval     │
│   local tmkms mode)          │         └─────────┬──────────┘
└──────────────────────────────┘                   │ cosigners dial in
                                          ┌────────┼────────┐
                                     ┌────┴───┐┌───┴────┐┌───┴────┐
                                     │ host B ││ host C ││ host D │
                                     │horcrux1││horcrux2││horcrux3│  <- ~/horcrux
                                     └────────┘└────────┘└────────┘
                                       └── cosigners talk to each other :2222
```

This repo runs on **host A only**. The signer hosts are provisioned separately —
this repo does not deploy them. In remote mode `make start` brings up gnoland and
sentinel and opens the privval port; the signer connects inward.

## Setup

Seven-step quick start for the **local file signer** and **local tmkms** setups. Each step links to the matching detailed section below when one exists. For a **remote signer**, steps 2 and 4 are replaced by the [Remote signer runbook](#remote-signer-runbook).

### 1. `validator.env`

Environment variables (image tags, host ports, gnoland flags). Copy the example and edit. See [validator.env reference](#validatorenv-reference) for the full list.

```sh
cp validator.env.example validator.env
$EDITOR validator.env
```

### 2. `config.overrides`

Per-node gnoland config (moniker, peers, telemetry labels) **and the signer**. Copy the example and fill the required fields. See [config.overrides reference](#configoverrides-reference).

If you picked a **remote signer** in [Choose a signing setup](#choose-a-signing-setup-first), stop here and follow the [Remote signer runbook](#remote-signer-runbook) instead — it replaces this step and step 4.

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
- **remote signer** (`tcp://` listener) — generates no signing key locally; prints the node's identity in both encodings (peer ID for tmkms, conn pubkey for horcrux) and the values to exchange with the signer operator.

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
| `SIGNER_LISTEN_LADDR`  | `0.0.0.0`                         | Host interface for the external signer's privval listener. Only used with a **remote** (`tcp://`) signer — tmkms or horcrux; inert otherwise. Restrict / firewall to the signer host in production.                                               |
| `SIGNER_LISTEN_PORT`   | `26659`                           | Host port mapped to the external signer's privval listener (remote mode). The gnoland config key driving it is named `tmkms_listener` upstream, but the protocol is the generic Tendermint privval one — horcrux uses it too.                     |
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

- `consensus.priv_validator.tmkms_listener.listen_addr` — `unix://…` (bundled local tmkms) or `tcp://…` (remote signer: tmkms or horcrux). Empty/absent = local file signer. Set this key **last**.
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
| `make reset [yes=1]`    | Wipes chain state (`db`, `wal`, `priv_validator_state.json`, and in local tmkms mode `tmkms-data/consensus_state.json`). Prompts to stop and restart around the wipe; `yes=1` skips all prompts. Preserves signing keys (`tmkms-data/consensus.key`, validator key) and node_id. With a *remote* signer, its double-sign state lives on the signer host and must be reset there — delete tmkms's `consensus_state.json`, or run `horcrux state set <chain-id> 0` on every cosigner. | Destructive on chain DB; clears double-sign protection. |

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

### Automation contract

Every lifecycle target is safe to run from a non-interactive session (CI,
Ansible) provided the flags below are passed. Prompts are the only thing that
can block, and each one names the flag that skips it.

| Target | Non-interactive form |
| ------ | -------------------- |
| `start`, `stop`, `restart`, `build` | no flag needed — these never prompt |
| `update` | `make update force=1` |
| `reset` | `make reset yes=1` — **not** for automation; see below |
| `clean-imgs` | `make clean-imgs yes=1` |

Exit codes:

| Code | Meaning |
| ---- | ------- |
| 0 | changed — the command did something |
| 1 | error |
| 2 | usage error (unknown command, bad `watch=`) |
| 3 | unchanged — already in the requested state |

`start`, `stop`, `build` and `update` return 3 rather than 0 when there was
nothing to do, so a caller can report *ok* versus *changed* without parsing
output. From Ansible:

```yaml
- name: Start the validator stack
  ansible.builtin.command:
    cmd: make start
    chdir: "{{ gno_validator_dir }}"
  register: gv_start
  changed_when: gv_start.rc == 0
  failed_when: gv_start.rc not in [0, 3]
```

`make status-json` is a read-only query, not a lifecycle action, so the
changed/unchanged split above doesn't apply to it: it exits 0 whenever it
could produce the JSON object (regardless of whether the node is healthy —
health lives in the JSON body, not the exit code) and 1 only if `jq` is
unavailable and auto-install fails. It never returns 3. It emits one flat
JSON object for health checks. Every key is always present; when the RPC is
unreachable, `rpc_reachable` is `false`, `height` and `peers` are `0`,
`catching_up` is `true` (the conservative reading — treat an unreachable
node as not caught up), and the string fields are empty. When the RPC is
reachable, `catching_up` reports the node's real sync state, so a genuinely
caught-up node reports `false`.

```json
{"containers":"running","gnoland":"running","sentinel":"running","rpc_reachable":true,
 "height":12345,"catching_up":false,"peers":8,"voting_power":"1000",
 "moniker":"sentry1","network":"gno-mainnet"}
```

`containers` is one of `none`, `stopped`, `running`, `mixed`, `restarting`.

**`reset` is deliberately excluded from automation.** It wipes chain state and
clears double-sign protection. It takes `yes=1` for a human in a script, but no
orchestrator should ever call it; keep it a deliberate, on-host action.

## Architecture

- **gnoland** exposes RPC (`GNOLAND_RPC_PORT`, default `26657`) and P2P (`GNOLAND_P2P_PORT`, default `26656`) to the host. When `GNOLAND_NTP_UPDATE` is set (default), the container syncs its clock before launching gnoland, trying `ntpd`, then `rdate`, then an HTTPS `Date` header until one succeeds. The container has `CAP_SYS_TIME`, so on a Linux host this also updates the host's clock — disable `GNOLAND_NTP_UPDATE` if another NTP daemon already manages the host.
- **external signer** (optional) signs votes/proposals for gnoland via the upstream Tendermint privval v0.34 protocol — **the signer dials gnoland**, which listens. Any signer speaking that protocol works; tmkms and horcrux both do. In local mode a bundled tmkms container reaches gnoland over a shared Unix socket (no network port). In remote mode the signer runs on dedicated hosts and connects to gnoland's TCP listener (`SIGNER_LISTEN_PORT`, default `26659`).
- **sentinel** collects gnoland RPC status, container logs, OTLP traces, and system resources, then forwards them to a central watchtower server. Image is pulled from `ghcr.io/aeddi/gno-watchtower/sentinel` (tag set via `SENTINEL_IMAGE_TAG`).
- `gnoland-data/`, `tmkms-data/`, and `genesis.json` are gitignored — back them up.

## Signing

The signer is selected in `config.overrides` via `consensus.priv_validator.tmkms_listener.listen_addr`. Set that key **last** (validation requires the other `tmkms_listener.*` fields first). See [`config.overrides.example`](config.overrides.example) and the upstream [tmkms quickstart](https://github.com/gnolang/gno/blob/master/docs/validators/tmkms-quickstart.md).

| Mode | `listen_addr` | tmkms runs | Consensus key | Use for |
| --- | --- | --- | --- | --- |
| **Local file signer** (default) | _(unset)_ | — | `gnoland-data/secrets/priv_validator_key.json` | Simplest; single-host, no KMS |
| **Local tmkms** | `unix:///tmkms-sock/privval.sock` | bundled container (`make start`) | `tmkms-data/consensus.key` (softsign, on disk) | Dev/lab parity with the tmkms path |
| **Remote signer** | `tcp://0.0.0.0:26659` | operator-run, dedicated host(s) | on the signer host(s) — HSM, softsign, or split into key shards | Production |

`tmkms_listener` is an upstream gnoland config name, not a tmkms-only feature: it
speaks the generic upstream Tendermint privval v0.34 protocol over an encrypted
SecretConnection, and **the signer dials gnoland**. Anything speaking that
protocol can drive it — this repo documents `tmkms` (single signer, HSM-backed)
and `horcrux` (threshold signing across several hosts).

**Local tmkms.** `make gen-identity` creates the validator key and exports its softsign copy to `tmkms-data/consensus.key`. `make start` builds the tmkms image (Rust, several minutes on first run) and runs the container; tmkms dials gnoland's Unix socket. Softsign keeps the key on disk, so this is **dev/lab only** — for production use a remote signer.

**Remote signer.** Nothing signs on this host: `make start` brings up gnoland and
sentinel and opens the privval listener, and the signer connects inward from
wherever it runs. Setup is two-sided and order-dependent — follow the
[Remote signer runbook](#remote-signer-runbook), which covers the whole sequence
step by step. The two subsections below cover what differs per signer.

### Remote signer: tmkms

Pin this node's **peer ID** in tmkms's `addr`, and put tmkms's identity pubkey in `allowed_kms_pubkeys`. tmkms retries via `reconnect = true`, so it can be started first and left to dial.

### Remote signer: horcrux (threshold signing)

[horcrux](https://github.com/aeddi/horcrux) splits the consensus key into shards held by separate cosigners, so no single host can sign alone. Use the `aeddi/horcrux` fork — it carries the tm2 compatibility fixes vanilla horcrux lacks (a spec-compliant sign response, which tm2 validates strictly, and leader-only chain-node connections). Three requirements are specific to gnoland and easy to get wrong:

1. **`connKeyFile` is mandatory**, though upstream horcrux docs present it as optional. Without a persistent connection identity each cosigner dials with a freshly generated key, which can never match the allowlist gnoland requires on `tcp://`. Run `horcrux create-conn-key` on **each** cosigner and put **all** of their pubkeys in `allowed_kms_pubkeys` — leadership rotates, so any of them may hold the connection.
2. **`leaderOnlyChainNodeConnections: true`** under `thresholdMode`. gnoland holds exactly one signer slot with a 3 s accept window. With every cosigner dialing, the connection churns about once a second and the validator signs **nothing**. Leader-only dialing gives the node one stable connection and hands it over on a leadership change.
3. **Double-sign state is per cosigner.** `make reset` cannot clear it from here; run `horcrux state set <chain-id> 0` on every cosigner if you restart the chain from genesis.

A matching `config.yaml` on each cosigner:

```yaml
connKeyFile: conn_key.json # from 'horcrux create-conn-key', per cosigner
thresholdMode:
    threshold: 2
    leaderOnlyChainNodeConnections: true
    cosigners:
        - shardID: 1
          p2pAddr: tcp://horcrux-1:2222
        - shardID: 2
          p2pAddr: tcp://horcrux-2:2222
        - shardID: 3
          p2pAddr: tcp://horcrux-3:2222
chainNodes:
    - privValAddr: tcp://<this-node>:26659
      connPubKey: <node conn pubkey from 'make gen-identity'>
```

See [horcrux's authentication docs](https://github.com/aeddi/horcrux/blob/main/docs/authentication.md) for cosigner-to-cosigner mutual TLS and the full pinning matrix. `test/e2e-horcrux.sh` runs this whole topology end to end (see [`test/README.md`](test/README.md)).

### Remote signer runbook

Setup is two-sided and order-dependent: each side needs an identity the other
produces. Steps marked **[node]** run here, **[signer]** run on the signer
host(s). This replaces steps 2 and 4 of the quick start; steps 1, 3, 5, 6, 7 are
unchanged.

**1. [node] Select remote mode with a placeholder allowlist.**

`make gen-identity` only prints the node's identity for a *remote* signer once
`config.overrides` already selects `tcp://` — but gnoland refuses an empty
`allowed_kms_pubkeys` on a `tcp://` listener, and you do not have the real
pubkeys yet. So start with a placeholder and replace it in step 4:

```
consensus.priv_validator.tmkms_listener.chain_id            = "<chain-id>"
consensus.priv_validator.tmkms_listener.protocol_version    = "v0.34"
consensus.priv_validator.tmkms_listener.allowed_kms_pubkeys = "0000000000000000000000000000000000000000000000000000000000000000"
consensus.priv_validator.tmkms_listener.listen_addr         = "tcp://0.0.0.0:26659"
```

Set `listen_addr` **last** — validation requires the other fields first. Also set
`SIGNER_LISTEN_PORT` in `validator.env` and firewall it to the signer hosts only.

**2. [node] Print the node identity.**

```sh
make gen-identity
```

No signing key is generated. Give the signer operator the `chain_id`, the
`listen_addr`, and whichever identity encoding their signer pins:

| Printed value | Pinned by | Where |
| --- | --- | --- |
| node peer ID | tmkms | `addr = "tcp://<peer-id>@<host>:26659"` |
| node conn pubkey (64 hex) | horcrux | `chainNodes[].connPubKey` |

**3. [signer] Create the signer identities and get the consensus key in place.**

*tmkms:* provision the consensus key in your HSM (or softsign), and give back the
tmkms identity pubkey.

*horcrux:* on **each** cosigner, `horcrux create-conn-key`, and give back all
three printed pubkeys. Shard the consensus key once
(`create-ed25519-shards --chain-id <chain-id> --threshold 2 --shards 3`, plus
`create-ecies-shards --shards 3`) and distribute one shard set per cosigner.
`connKeyFile` is **not optional here** — see [horcrux notes](#remote-signer-horcrux-threshold-signing).

**4. [node] Replace the placeholder with the real allowlist.**

Every signer identity, comma-separated — one per tmkms instance, or **one per
horcrux cosigner** (leadership rotates, so any of them may hold the connection):

```
consensus.priv_validator.tmkms_listener.allowed_kms_pubkeys = "<pubkey1>,<pubkey2>,<pubkey3>"
```

**5. [node] Register the validator pub_key in `genesis.json`.**

The consensus pub_key comes from the *signer* host — this node never had the key.

**6. [signer] Start the signer, then [node] `make start`.**

Order matters: gnoland waits only 60 s (`wait_for_connection_timeout`) for a
signer to dial in, then fails to start. tmkms retries on its own
(`reconnect = true`); a horcrux cluster needs all cosigners up and a leader
elected.

**7. [node] Verify.**

```sh
make status
```

Voting power `>= 1` and a climbing height mean the remote signer is signing. If
the node reports `This node is a validator` but height does not move, the signer
is connected but not signing — check the signer's own logs.

> `test/e2e-horcrux.sh` performs this entire sequence automatically against a
> throwaway 2-of-3 cluster. Read it if you want a worked example of every step.

## Logging

- gnoland: up to 3 GB by default (3 × 1 GB files, rotated), configurable via `GNOLAND_LOG_SIZE`
- tmkms (local mode only): up to 1 GB
- sentinel: up to 100 MB

## Optional: Reverse Proxy

The [`reverse-proxy/`](reverse-proxy/) subfolder contains a Caddy setup that exposes the node services (RPC, Gnockpit) over HTTPS with automatic Let's Encrypt certificates. See [`reverse-proxy/README.md`](reverse-proxy/README.md) for setup instructions.
