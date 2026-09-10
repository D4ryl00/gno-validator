# Tests

## `e2e-tmkms-local.sh` — local bundled tmkms, end-to-end

Proves the **local bundled tmkms** signer mode works end-to-end: it builds the
gnoland + tmkms images from this repo, generates a softsign validator key,
synthesizes a `genesis.json` with that validator, boots gnoland + a bundled
tmkms container, and asserts that:

- tmkms connects to gnoland's privval socket (`connected to validator successfully`),
- gnoland reports `This node is a validator`,
- tmkms actually signs consensus (`signed Precommit`),
- the RPC shows block height advancing (`>= 2`) with voting power `>= 1`,
- the running chain id matches the configured one.

### Run

```sh
make e2e
# or:
bash test/e2e-tmkms-local.sh
```

**Requirements:** Docker + curl. No host Go toolchain needed — `gnogenesis` is
built inside a throwaway container. First run is slow (~10 min: gno clone + image
builds); re-runs reuse Docker's layer cache.

### Isolation

The test never touches a real deployment. It runs in a temp workdir under its own
compose project (`gno-validator-e2e`), its own image names (`gno-validator-e2e-*`),
and its own host ports (default `36656`–`36659`, loopback only). Containers, the
temp dir, and (by default) the e2e images are removed on exit.

### Config (env overrides)

| Var | Default | Meaning |
| --- | --- | --- |
| `GNO_REPO` | `gnolang/gno` | gno source repo slug (matches `validator.env.example`) |
| `GNO_VERSION` | `master` | gno ref to build (matches `validator.env.example`); carries `tmkms_listener` support since PR #5718 |
| `CHAIN_ID` | `gno-tmkms-e2e` | test chain id |
| `RPC_PORT` / `P2P_PORT` / `SIGNER_PORT` | `36657` / `36656` / `36659` | host ports |
| `KEEP_IMAGES=1` | _(off)_ | keep the e2e images after the run (faster re-runs) |
| `NO_CACHE=1` | _(off)_ | `docker build --no-cache` |

> `GNO_VERSION` defaults to `master` (like `validator.env.example`). Set it to a
> commit/tag to pin a reproducible build.

### Not covered here

Signer **mode detection** (`config.overrides` → local / remote / off) is pure
shell in `.Makefile.sh` and is cheap to check directly; this script focuses on the
expensive, high-value behavior: real tmkms signing. The remote (`tcp://`) path is
covered by `e2e-horcrux.sh` below.

---

## `e2e-horcrux.sh` — remote signer via a horcrux cluster, end-to-end

Proves the **remote signer** mode works end-to-end, driven by a 2-of-3
[horcrux](https://github.com/aeddi/horcrux) threshold cluster: it builds the
gnoland and horcrux images, generates a validator key and splits it into three
shards, boots gnoland with a `tcp://` `tmkms_listener` plus three cosigners, and
asserts that the cluster signs consensus for the node.

This is the production topology — the node runs here, the signer runs elsewhere —
so it covers the three things specific to gnoland that vanilla horcrux gets
wrong:

1. **Persistent connection identities.** gnoland requires a non-empty
   `allowed_kms_pubkeys` on a `tcp://` listener, so each cosigner runs
   `create-conn-key` and all three pubkeys are allowlisted. An ephemeral
   identity could never match.
2. **A single signer slot.** gnoland accepts one signer connection with a 3 s
   accept window, so the cluster runs with
   `leaderOnlyChainNodeConnections: true`. The test asserts that the
   non-leader cosigners log that they are parking without dialing — without
   that setting the connection churns and the validator signs nothing.
3. **Leadership handoff.** `horcrux elect` forces a new leader; the test then
   asserts the old leader releases the chain-node connection, the new one takes
   it, and the chain keeps advancing.

It also asserts on `make gen-identity`'s remote-mode output: the node connection
pubkey pinned as each cosigner's `connPubKey` is parsed from that output and
cross-checked against `node_key.json`, so a regression there fails the test.

### Run

```sh
bash test/e2e-horcrux.sh
```

**Requirements:** Docker + curl. No host Go toolchain needed. First run is slow
(~15 min: gno and horcrux clones + image builds).

### Isolation

Own temp workdir, own compose project (`gno-validator-e2e-horcrux`), own image
names, own network, and own host ports (default `37656`–`37659`, loopback only),
so it can run alongside `e2e-tmkms-local.sh`. Containers, the network, the temp
dir, and (by default) the images it built are removed on exit.

### Config (env overrides)

| Var | Default | Meaning |
| --- | --- | --- |
| `GNO_REPO` / `GNO_VERSION` | `gnolang/gno` / `master` | gno source to build |
| `HORCRUX_REPO` | `https://github.com/aeddi/horcrux.git` | horcrux source to build |
| `HORCRUX_REF` | `main` | horcrux ref to build |
| `HORCRUX_IMAGE` | _(unset)_ | use this prebuilt local image instead of building; not removed at cleanup |
| `CHAIN_ID` | `gno-horcrux-e2e` | test chain id |
| `RPC_PORT` / `P2P_PORT` / `SIGNER_PORT` | `37657` / `37656` / `37659` | host ports |
| `KEEP_IMAGES=1` | _(off)_ | keep the e2e images after the run |
| `NO_CACHE=1` | _(off)_ | `docker build --no-cache` |

> The fork publishes no image yet, so the default is to build from source. Point
> `HORCRUX_IMAGE` at a locally built image (e.g. from a working checkout) to
> test changes without pushing them.
