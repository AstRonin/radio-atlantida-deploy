#!/usr/bin/env bash
# Inside the test container (tests/distro/run.sh): prepares the container
# like a fresh WSL import, runs setup-distro.sh twice, and checks the result.
set -Eeuo pipefail
fail() {
  echo "FAIL: $*" >&2
  exit 1
}
ok() { echo "ok - $*"; }
expect_eq() { [[ $1 == "$2" ]] || fail "$3: expected '$2', got '$1'"; ok "$3"; }

# systemd (for systemctl enable and systemd-analyze), and iproute2 /
# util-linux, which a WSL rootfs has; tzdata, which setup-distro.sh installs
# itself (skipped here with --skip-packages) and the timers need.
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq >/dev/null
apt-get install -y -qq --no-install-recommends systemd iproute2 util-linux ca-certificates tzdata >/dev/null

# The copy install.ps1 makes: install/ and docker-compose.yml.
src=/var/lib/radio-atlantida/src
mkdir -p "$src"
cp -R /repo/install /repo/docker-compose.yml "$src/"
setup=$src/install/setup-distro.sh

id ubuntu >/dev/null 2>&1 && ok "the image has the stock user ubuntu (uid $(id -u ubuntu)), renamed below"

if [[ ${WITH_APT:-false} == true ]]; then
  echo "== pass 1 with apt (Docker packages from versions.env)"
  had_policy=false
  [[ -e /usr/sbin/policy-rc.d ]] && had_policy=true
  rc=0
  bash "$setup" --network-mode nat --journal-owner 100:101 || rc=$?
  expect_eq "$rc" 10 "pass 1 exits 10 (restart needed)"
  declare -A PIN=()
  while IFS='=' read -r k v; do [[ $k =~ ^[A-Z_]+$ ]] && PIN[$k]=$v; done <"$src/install/versions.env"
  expect_eq "$(dpkg-query -W -f='${Version}' docker-ce)" "${PIN[DOCKER_CE_VERSION]}" "docker-ce at the pin"
  expect_eq "$(dpkg-query -W -f='${Version}' docker-ce-cli)" "${PIN[DOCKER_CE_VERSION]}" "docker-ce-cli at the pin"
  expect_eq "$(dpkg-query -W -f='${Version}' containerd.io)" "${PIN[CONTAINERD_VERSION]}" "containerd.io at the pin"
  expect_eq "$(dpkg-query -W -f='${Version}' docker-compose-plugin)" "${PIN[DOCKER_COMPOSE_PLUGIN_VERSION]}" "compose plugin at the pin"
  expect_eq "$(dpkg-query -W -f='${Version}' docker-buildx-plugin)" "${PIN[DOCKER_BUILDX_PLUGIN_VERSION]}" "buildx plugin at the pin"
  expect_eq "$(apt-mark showhold | sort | tr '\n' ' ')" "containerd.io docker-buildx-plugin docker-ce docker-ce-cli docker-compose-plugin " "Docker packages held"
  # Docker's ubuntu image ships its own policy-rc.d; setup-distro.sh adds
  # one only when none exists and removes only its own.
  if $had_policy; then
    [[ -e /usr/sbin/policy-rc.d ]] || fail "the image's policy-rc.d was removed"
    ok "the image's own policy-rc.d is kept"
  else
    [[ ! -e /usr/sbin/policy-rc.d ]] || fail "policy-rc.d left behind"
    ok "policy-rc.d removed after the install"
  fi
  [[ -f /var/lib/radio-atlantida/upgraded ]] && ok "the one-time upgrade is recorded"
  expect_eq "$(gpg --show-keys --with-colons /etc/apt/keyrings/docker.asc | awk -F: '$1=="fpr"{print $10; exit}')" "${PIN[DOCKER_APT_KEY_FINGERPRINT]}" "Docker apt key fingerprint"
  for p in git jq curl gnupg unattended-upgrades; do dpkg -s "$p" >/dev/null 2>&1 || fail "$p not installed"; done
  ok "base packages installed"
  echo "== second apt pass: no package change"
  out=$(bash "$setup" --network-mode nat --journal-owner 100:101 2>&1) || rc=$?
  echo "$out" | grep -q "changed:" && { echo "$out"; fail "the second pass changed something"; }
  ok "second pass with apt changes nothing"
  exit 0
fi

echo "== pass 1 (fresh import: no wsl.conf yet)"
rc=0
bash "$setup" --network-mode nat --skip-packages --journal-owner 100:101 || rc=$?
expect_eq "$rc" 10 "pass 1 exits 10 (restart needed)"

# What WSL's drive mount shows with the wsl.conf options: the Windows media
# folder owned by radio:radio-media with group write (simulated).
media="/mnt/d/Radio Atlantida/медиа"
mkdir -p "$media"
chown 1000:10001 "$media"
chmod 0775 "$media"

echo "== pass 2 (after the restart; final checks without Docker and systemd)"
out=$(bash "$setup" --network-mode nat --skip-packages --skip-systemd --journal-owner 100:101 --final --media-root "$media" 2>&1) || {
  echo "$out"
  fail "pass 2 failed"
}
echo "$out"
grep -q "setup-distro: nothing to change." <<<"$out" || fail "pass 2 changed something"
ok "pass 2 changes nothing and exits 0"
grep -q "media folder $media: group radio-media, group write, create and rename ok" <<<"$out" || fail "media check missing"
ok "media check passes (Cyrillic name, space)"

echo "== checks"
cmp /etc/wsl.conf "$src/install/wsl.conf" && ok "/etc/wsl.conf is install/wsl.conf"
grep -qx 'systemd=true' /etc/wsl.conf && grep -qx 'default=radio' /etc/wsl.conf &&
  grep -qx 'options="uid=1000,gid=10001,umask=002,fmask=002"' /etc/wsl.conf &&
  grep -qx 'appendWindowsPath=false' /etc/wsl.conf && ! grep -q metadata /etc/wsl.conf &&
  ok "wsl.conf: systemd, default user, automount options without metadata"
expect_eq "$(id -u radio)" 1000 "user radio is uid 1000"
expect_eq "$(id -gn radio)" radio "radio's primary group"
expect_eq "$(getent group radio-media | cut -d: -f3)" 10001 "group radio-media is gid 10001"
id -nG radio | tr ' ' '\n' | grep -qx radio-media && id -nG radio | tr ' ' '\n' | grep -qx docker && ok "radio is in radio-media and docker"
id ubuntu >/dev/null 2>&1 && fail "user ubuntu still exists"
[[ -d /home/radio ]] && ok "home /home/radio"
expect_eq "$(stat -c '%u:%g %a' /srv/radio/journal)" "100:101 755" "journal owner and mode"
expect_eq "$(stat -c '%U:%G %a' /srv/radio/backups)" "radio:radio 700" "backups owner and mode"
expect_eq "$(stat -c '%U:%G %a' /opt/radio-atlantida)" "radio:radio 755" "/opt/radio-atlantida owner and mode"
expect_eq "$(grep -v '^#' /etc/radio-atlantida/host.env)" "RADIO_NETWORK_MODE=nat" "host.env network mode"
expect_eq "$(stat -c %a /usr/local/bin/radio-keepalive)" 755 "radio-keepalive installed executable"
cmp -s /usr/local/bin/radio-keepalive "$src/install/radio-keepalive" && ok "radio-keepalive content"
grep -q '"userland-proxy": true' /etc/docker/daemon.json && grep -q '"max-size": "10m"' /etc/docker/daemon.json && ok "daemon.json"
grep -q 'Signed-By: /etc/apt/keyrings/docker.asc' /etc/apt/sources.list.d/docker.sources && ok "Docker apt source"
grep -A2 '^Package: docker-ce$' /etc/apt/preferences.d/radio-atlantida-docker | grep -q "Pin: version $(sed -n 's/^DOCKER_CE_VERSION=//p' "$src/install/versions.env")" &&
  grep -c 'Pin-Priority: 1001' /etc/apt/preferences.d/radio-atlantida-docker | grep -qx 5 && ok "apt pin file: 5 packages at the pinned versions"
grep -q '"\^docker-ce\$";' /etc/apt/apt.conf.d/51radio-atlantida && grep -q 'Automatic-Reboot "false"' /etc/apt/apt.conf.d/51radio-atlantida && ok "unattended-upgrades: Docker excluded, no reboot"
for u in radio-network.service radio-boot-check.service radio-backup.service radio-backup.timer radio-restore-drill.service radio-restore-drill.timer; do
  cmp -s "/etc/systemd/system/$u" "$src/install/systemd/$u" || fail "$u not installed"
done
ok "units installed"
[[ -L /etc/systemd/system/multi-user.target.wants/radio-network.service ]] &&
  [[ -L /etc/systemd/system/multi-user.target.wants/radio-boot-check.service ]] &&
  [[ -L /etc/systemd/system/timers.target.wants/radio-backup.timer ]] &&
  [[ -L /etc/systemd/system/timers.target.wants/radio-restore-drill.timer ]] && ok "boot units and timers enabled"

echo "== mirrored mode re-run changes host.env only"
out=$(bash "$setup" --network-mode mirrored --skip-packages --skip-systemd --journal-owner 100:101 --final 2>&1)
grep -q "changed: /etc/radio-atlantida/host.env" <<<"$out" && expect_eq "$(grep -c 'changed:' <<<"$out")" 1 "one change on a mode switch"

echo "== refusals"
rc=0
bash "$setup" --network-mode bridge >/dev/null 2>&1 || rc=$?
expect_eq "$rc" 2 "unknown network mode is a usage error"
chmod 0755 "$media"
rc=0
bash "$setup" --network-mode mirrored --skip-packages --skip-systemd --journal-owner 100:101 --final --media-root "$media" >/dev/null 2>&1 || rc=$?
expect_eq "$rc" 1 "a media folder without group write fails"
chgrp 0 "$media"
out=$(bash "$setup" --network-mode mirrored --skip-packages --skip-systemd --journal-owner 100:101 --final --media-root "$media" 2>&1) || true
grep -q "has group 0, not 10001" <<<"$out" && ok "a media folder without the automount group fails with the hint"

echo "== systemd-analyze verify"
# The units' ExecStart and dependencies, as on the distribution.
mkdir -p /opt/radio-atlantida/deploy/bin /opt/radio-atlantida/deploy/runtime
cp /repo/bin/radioctl /opt/radio-atlantida/deploy/bin/radioctl
chmod 0755 /opt/radio-atlantida/deploy/bin/radioctl
printf '[Unit]\nDescription=stand-in\n[Service]\nExecStart=/bin/true\n' >/etc/systemd/system/docker.service
out=$(cd /etc/systemd/system && systemd-analyze verify radio-network.service radio-boot-check.service \
  radio-backup.service radio-backup.timer radio-restore-drill.service radio-restore-drill.timer 2>&1) || {
  echo "$out"
  fail "systemd-analyze verify"
}
[[ -z $out ]] || echo "$out"
ok "systemd-analyze verify: all six units"
echo "ALL OK"
