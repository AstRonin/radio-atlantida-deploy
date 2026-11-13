#!/usr/bin/env bash
# Installs and enables the systemd units of this folder inside the
# radio-atlantida distribution (deploy-init-plan.md D6 task 2). Run as root;
# setup-distro.sh calls it (D4, plan 6.3 step 6). Idempotent: an unchanged
# unit is not rewritten, and enabling twice changes nothing.
#
# The timers are enabled and started here; their services do nothing until
# `radioctl first-run` has written runtime/applied.env.
#
# D4 adds radio-network.service and radio-boot-check.service to UNITS and
# their enable line.
#
# Test switches: SYSTEMD_UNIT_DIR (default /etc/systemd/system), SYSTEMCTL
# (default systemctl).
set -Eeuo pipefail

src=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
dest=${SYSTEMD_UNIT_DIR:-/etc/systemd/system}
systemctl=${SYSTEMCTL:-systemctl}
UNITS=(radio-backup.service radio-backup.timer radio-restore-drill.service radio-restore-drill.timer)
TIMERS=(radio-backup.timer radio-restore-drill.timer)

changed=false
for u in "${UNITS[@]}"; do
  if ! cmp -s "$src/$u" "$dest/$u"; then
    install -m 0644 "$src/$u" "$dest/$u"
    echo "installed $dest/$u"
    changed=true
  fi
done
if $changed; then
  "$systemctl" daemon-reload
fi
"$systemctl" enable --now "${TIMERS[@]}"
