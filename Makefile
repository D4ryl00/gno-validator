# Makefile — gno-validator: gnoland validator node with optional remote signing (tmkms or horcrux).
#
# Usage: make <target> [args]
#
# Lifecycle:
#   start                            Start services (first run: builds images if needed)
#   stop                             Stop services without removing containers
#   restart                          Stop then start (re-applies config.overrides, no password prompt)
#   reset          [yes=1]           Wipe chain state (db, wal, priv_validator_state.json, and in
#                                    local tmkms mode tmkms-data/consensus_state.json). Keeps signing keys.
#   update         [force=1]         Rebuild images and/or recreate containers if anything
#                                    has changed since the last build/start. force=1 does it anyway.
#                                    Recreate loses container logs but preserves chain data + signing keys.
#
# Inspection:
#   status         [watch=<sec>]     Show block height, peers, and validator status (watch= refreshes every N seconds)
#   infos                            Print node identity, network config, build metadata, checksums
#   logs           [since=<d>]       Open merged TUI of gnoland + sentinel (+ tmkms in local mode) logs — downloads gonzo on first run.
#
# Cleanup:
#   clean-imgs     [all=1] [yes=1]   Remove stale images (default). all=1 also removes current images and sentinel.
#                                    yes=1 skips the confirm prompt.
#
# Setup:
#   gen-identity                     Generate/show the validator identity (and tmkms softsign key in local mode)
#   help                             Show this help message
#
# Configuration:
#   validator.env                    Environment variables (copy from validator.env.example)
#   config.overrides                 Per-node gnoland config (copy from config.overrides.example)
#   genesis.json                     Chain genesis file (user-provided)

SHELL := /bin/bash

# HOST_UID/HOST_GID are consumed by docker-compose.yml for gnoland's user mapping.
export HOST_UID := $(shell id -u)
export HOST_GID := $(shell id -g)

# Arg → env pass-through: `make build force=1` → FORCE=1, `make status watch=5` → WATCH=5,
# `make clean-imgs yes=1` → YES=1, `make clean-imgs all=1` → ALL=1,
# `make logs since=30m` → SINCE=30m.
export FORCE := $(force)
export WATCH := $(watch)
export YES   := $(yes)
export ALL   := $(all)
export SINCE := $(since)

PROJECT_ROOT := $(shell dirname $(realpath $(lastword $(MAKEFILE_LIST))))
SCRIPT       := bash $(PROJECT_ROOT)/.Makefile.sh

.PHONY: help gen-identity infos build start stop restart update reset \
        logs status clean-imgs e2e e2e-horcrux

help:
	@awk '/^# Usage:/,/^$$/{sub(/^# ?/,""); print}' $(MAKEFILE_LIST)

gen-identity:
	@$(SCRIPT) gen-identity

infos:
	@$(SCRIPT) infos

start:
	@$(SCRIPT) start

stop:
	@$(SCRIPT) stop

restart:
	@$(SCRIPT) restart

update:
	@$(SCRIPT) update

reset:
	@$(SCRIPT) reset

logs:
	@$(SCRIPT) logs

status:
	@$(SCRIPT) status

clean-imgs:
	@$(SCRIPT) clean-imgs

# Targets below are for CI and debugging — not part of the normal workflow,
# intentionally omitted from `make help`. Invoke directly when you need to
# force a rebuild or run the e2e signer test.

build:
	@$(SCRIPT) build

# End-to-end test of the local bundled tmkms signer (builds images; ~10 min on
# first run). Fully isolated from any live deployment. See test/README.md.
e2e:
	@bash $(PROJECT_ROOT)/test/e2e-tmkms-local.sh

# End-to-end test of the remote signer path, driven by a 2-of-3 horcrux cluster
# (builds gnoland + horcrux; ~15 min on first run). Isolated from any live
# deployment and from `make e2e`, so both can run at once. See test/README.md.
e2e-horcrux:
	@bash $(PROJECT_ROOT)/test/e2e-horcrux.sh
