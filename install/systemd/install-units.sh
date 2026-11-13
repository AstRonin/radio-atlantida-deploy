#!/usr/bin/env bash
# Installs and enables the systemd units of this folder inside the
# radio-atlantida distribution (deploy-init-plan.md D4 6.3 step 6, D6 task
# 2). Run as root; setup-distro.sh calls it. Idempotent: an unchanged unit
# is not rewritten, and enabling twice changes nothing.
#
# - radio-network.service (6.5) and radio-boot-check.service (6.3 step 6)
#   are enabled for the next boot, not started here: radio-network needs the
#   deploy repository, which install.ps1 clones afterwards and then starts
#   the unit once; the boot check only makes sense at boot.
# - The timers are enabled and started; their services do nothing until
#   `radioctl first-run` has written runtime/applied.env.
# - The keep-alive helper /usr/local/bin/radio-keepalive is not a unit: the
#   Windows task runs it (6.4); setup-distro.sh installs it.
#
# Without a running systemd (the first pass of setup-distro.sh on a fresh
# import) the units are only enabled; systemd starts them after the restart.
#
# Test switches: SYSTEMD_UNIT_DIR (default /etc/systemd/system), SYSTEMCTL
# (default systemctl), SYSTEMD_BOOTED (yes/no; default: /run/systemd/system
# exists).
set -Eeuo pipefail

src=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
dest=${SYSTEMD_UNIT_DIR:-/etc/systemd/system}
systemctl=${SYSTEMCTL:-systemctl}
booted=${SYSTEMD_BOOTED:-}
if [[ -z $booted ]]; then
  booted=no
  [[ -d /run/systemd/system ]] && booted=yes
fi
UNITS=(radio-network.service radio-boot-check.service
  radio-backup.service radio-backup.timer radio-restore-drill.service radio-restore-drill.timer)
BOOT_UNITS=(radio-network.service radio-boot-check.service)
TIMERS=(radio-backup.timer radio-restore-drill.timer)

changed=false
for u in "${UNITS[@]}"; do
  if ! cmp -s "$src/$u" "$dest/$u"; then
    install -m 0644 "$src/$u" "$dest/$u"
    echo "installed $dest/$u"
    changed=true
  fi
done
if [[ $booted == yes ]]; then
  if $changed; then
    "$systemctl" daemon-reload
  fi
  "$systemctl" enable --quiet "${BOOT_UNITS[@]}"
  "$systemctl" enable --now "${TIMERS[@]}"
else
  "$systemctl" enable --quiet "${BOOT_UNITS[@]}" "${TIMERS[@]}"
fi
