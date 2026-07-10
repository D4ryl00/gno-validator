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
| `GNO_REPO` | `gnolang/gno` | gno source repo slug |
| `GNO_VERSION` | pinned commit | official gnolang/gno commit that carries `tmkms_listener` support (PR #5718) |
| `CHAIN_ID` | `gno-tmkms-e2e` | test chain id |
| `RPC_PORT` / `P2P_PORT` / `TMKMS_PORT` | `36657` / `36656` / `36659` | host ports |
| `KEEP_IMAGES=1` | _(off)_ | keep the e2e images after the run (faster re-runs) |
| `NO_CACHE=1` | _(off)_ | `docker build --no-cache` |

> `GNO_VERSION` is pinned to the official `gnolang/gno` commit that introduced the
> tmkms feature. Bump it (or set the env var) to a newer `gnolang/gno` commit.

### Not covered here

Signer **mode detection** (`config.overrides` → local / remote / off) is pure
shell in `.Makefile.sh` and is cheap to check directly; this script focuses on the
expensive, high-value behavior: real tmkms signing. The **remote (tcp://) tmkms**
mode is not exercised end-to-end here (it needs an external signer host); its
wiring shares the same `tmkms_listener` path as local mode.
