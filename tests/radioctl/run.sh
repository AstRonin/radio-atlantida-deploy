#!/usr/bin/env bash
# Runs the bats tests of bin/radioctl (deploy-init-plan.md D5, D7 9.1 item 9)
# in a pinned bats-core image; docker, git, and the clock are stubbed, so no
# Docker stack is needed. Extra arguments go to bats (e.g. -f <name>).
set -Eeuo pipefail
root=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
image=radio-deploy-bats:1.11.1
docker build -q -t "$image" "$root/tests/radioctl" >/dev/null
exec docker run --rm -v "$root:/repo:ro" -w /repo "$image" "$@" tests/radioctl
