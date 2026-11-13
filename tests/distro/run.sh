#!/usr/bin/env bash
# Runs install/setup-distro.sh in an ubuntu:24.04 container, the way
# install.ps1 runs it in the radio-atlantida distribution, and checks what
# it wrote (deploy-init-plan.md D4 6.3; D7 9.1). Also runs
# `systemd-analyze verify` on the units of install/systemd/.
#
#   tests/distro/run.sh             files, users, units (no apt): fast
#   tests/distro/run.sh --with-apt  also the Docker apt install from
#                                   versions.env (key, pin, hold); slow
#
# A container has no systemd as PID 1 and no Docker daemon, so the services
# are only enabled, the journal owner is given with --journal-owner, and
# the final checks run with --final --skip-packages (no Docker checks). The
# real two-pass run under systemd is part of the Windows acceptance run
# (docs/runbook.md section 11) and of the Mac dry run VM (docs/dry-run.md).
set -Eeuo pipefail
root=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
# ubuntu:24.04 as of 2026-11-11, pinned by digest (the release of the WSL
# rootfs is older; setup-distro.sh upgrades it once).
image=ubuntu:24.04@sha256:2198e4c65076e9cb0b3d695219df667c0e3b0072da64ca3c2648aca17dcecaf5
with_apt=false
[[ ${1:-} == --with-apt ]] && with_apt=true
name=radio-deploy-distro-test-$$
cleanup() { docker rm -f "$name" >/dev/null 2>&1 || true; }
trap cleanup EXIT
docker run --rm --name "$name" -v "$root:/repo:ro" -e WITH_APT="$with_apt" \
  "$image" bash /repo/tests/distro/check.sh
