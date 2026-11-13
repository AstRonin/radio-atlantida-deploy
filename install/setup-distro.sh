#!/usr/bin/env bash
# setup-distro.sh: the Linux half of the host install (deploy-init-plan.md D4
# 6.3). install.ps1 copies install/ and docker-compose.yml into the
# radio-atlantida distribution (/var/lib/radio-atlantida/src) and runs this
# as root. Idempotent: a second run changes nothing and says so.
#
#   setup-distro.sh --network-mode nat|mirrored [--media-root /mnt/d/...]
#
# Two passes on a new distribution. The first runs without systemd (the
# fresh import has no /etc/wsl.conf yet): it writes wsl.conf, the users, the
# packages (without starting services), the files and units, and exits 10:
# "restart the distribution and run me again". install.ps1 then runs
# `wsl --terminate radio-atlantida` and the second pass, which runs under
# systemd, starts containerd and Docker, sets the journal owner, and makes
# the final checks (systemd state, Docker and Compose versions, the media
# folder). A later run (install.bat again, an engine upgrade from a new
# versions.env) is a single pass; it exits 10 only if /etc/wsl.conf changed.
#
# Exit codes: 0 done; 10 done, restart the distribution and run again;
# 1 failed (the message says why); 2 usage.
#
# Test switches (an ubuntu:24.04 container has no systemd and no Docker):
#   --skip-packages        no apt, no Docker: packages and Docker checks are
#                          skipped (the apt source, pin, and unattended-upgrades
#                          files are still written)
#   --skip-systemd         never call systemctl (units are installed only)
#   --final                run the final checks although systemd is not PID 1
#   --journal-owner U:G    owner of /srv/radio/journal instead of the uid the
#                          pinned Liquidsoap image runs as
set -Eeuo pipefail

SRC=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
VERSIONS=$SRC/versions.env
COMPOSE_FILE=$SRC/../docker-compose.yml

RADIO_USER=radio
RADIO_UID=1000
MEDIA_GROUP=radio-media
MEDIA_GID=10001
DOCKER_PACKAGES=(docker-ce docker-ce-cli containerd.io docker-compose-plugin docker-buildx-plugin)
# tzdata: the timers name the station time zone (OnCalendar ... Asia/Yerevan);
# without it systemd refuses them.
BASE_PACKAGES=(ca-certificates curl git jq iproute2 gnupg unattended-upgrades util-linux tzdata)

MODE=
MEDIA_ROOT=
SKIP_PACKAGES=false
SKIP_SYSTEMD=false
FORCE_FINAL=false
JOURNAL_OWNER=
CHANGED=0
RESTART_NEEDED=false

say() { printf '%s\n' "$*"; }
step() { say "==> $*"; }
changed() {
  say "    changed: $*"
  CHANGED=$((CHANGED + 1))
}
warn() { say "WARNING: $*"; }
die() {
  say "ERROR: $*" >&2
  exit 1
}
trap 'say "ERROR: unexpected failure at line $LINENO: $BASH_COMMAND" >&2' ERR
trap 'unblock_service_starts' EXIT

usage() {
  sed -n '2,/^set -Eeuo/p' "${BASH_SOURCE[0]}" | sed -e '$d' -e 's/^# \{0,1\}//'
}

parse_args() {
  while (($#)); do
    case $1 in
      --network-mode) MODE=${2:-}; shift 2 ;;
      --media-root) MEDIA_ROOT=${2:-}; shift 2 ;;
      --skip-packages) SKIP_PACKAGES=true; shift ;;
      --skip-systemd) SKIP_SYSTEMD=true; shift ;;
      --final) FORCE_FINAL=true; shift ;;
      --journal-owner) JOURNAL_OWNER=${2:-}; shift 2 ;;
      -h | --help) usage; exit 0 ;;
      *) usage >&2; exit 2 ;;
    esac
  done
  case $MODE in
    nat | mirrored) ;;
    *) say "--network-mode must be nat or mirrored" >&2; exit 2 ;;
  esac
  if [[ -n $JOURNAL_OWNER && ! $JOURNAL_OWNER =~ ^[0-9]+:[0-9]+$ ]]; then
    say "--journal-owner must be <uid>:<gid>" >&2
    exit 2
  fi
  return 0
}

# read_pins: versions.env as KEY=VALUE (parsed, never sourced).
declare -A PIN=()
read_pins() {
  local line
  [[ -f $VERSIONS ]] || die "$VERSIONS is missing"
  while IFS= read -r line || [[ -n $line ]]; do
    [[ $line =~ ^([A-Z0-9_]+)=(.*)$ ]] || continue
    PIN[${BASH_REMATCH[1]}]=${BASH_REMATCH[2]}
  done <"$VERSIONS"
  local k
  for k in DOCKER_APT_KEY_FINGERPRINT DOCKER_CE_VERSION CONTAINERD_VERSION \
    DOCKER_COMPOSE_PLUGIN_VERSION DOCKER_BUILDX_PLUGIN_VERSION; do
    [[ -n ${PIN[$k]:-} ]] || die "versions.env has no $k"
  done
}

pin_of() {
  case $1 in
    docker-ce | docker-ce-cli) printf '%s' "${PIN[DOCKER_CE_VERSION]}" ;;
    containerd.io) printf '%s' "${PIN[CONTAINERD_VERSION]}" ;;
    docker-compose-plugin) printf '%s' "${PIN[DOCKER_COMPOSE_PLUGIN_VERSION]}" ;;
    docker-buildx-plugin) printf '%s' "${PIN[DOCKER_BUILDX_PLUGIN_VERSION]}" ;;
  esac
}

# "29.9.3" from "5:29.9.3-1~ubuntu.24.04~noble" (as radioctl compares).
upstream_version() {
  local v=${1#*:}
  printf '%s' "${v%%-*}"
}

systemd_running() {
  ! $SKIP_SYSTEMD && [[ -d /run/systemd/system ]]
}

# put_file <dest> <mode> <content>: writes only when different.
put_file() {
  local dest=$1 mode=$2 content=$3 tmp
  tmp=$(mktemp)
  printf '%s' "$content" >"$tmp"
  if [[ -f $dest ]] && cmp -s "$tmp" "$dest" && [[ $(stat -c %a "$dest") == "${mode#0}" ]]; then
    rm -f "$tmp"
    return 1
  fi
  mkdir -p "$(dirname "$dest")"
  install -m "$mode" "$tmp" "$dest"
  rm -f "$tmp"
  changed "$dest"
  return 0
}

# ensure_dir <path> <uid:gid> <mode>
ensure_dir() {
  local path=$1 owner=$2 mode=$3
  if [[ ! -d $path ]]; then
    mkdir -p "$path"
    changed "$path created"
  fi
  if [[ $(stat -c %u:%g "$path") != "$owner" ]]; then
    chown "$owner" "$path"
    changed "$path owner $owner"
  fi
  if [[ $(stat -c %a "$path") != "${mode#0}" ]]; then
    chmod "$mode" "$path"
    changed "$path mode $mode"
  fi
}

check_host() {
  step "Host"
  ((EUID == 0)) || die "run as root (install.ps1 uses wsl.exe -u root)"
  local id ver
  # shellcheck source=/dev/null
  id=$(. /etc/os-release && printf '%s' "$ID")
  # shellcheck source=/dev/null
  ver=$(. /etc/os-release && printf '%s' "$VERSION_ID")
  [[ $id == ubuntu && $ver == 24.04 ]] || die "Ubuntu 24.04 expected, found $id $ver"
  say "    Ubuntu $ver, $(dpkg --print-architecture), network mode $MODE"
  if systemd_running; then
    say "    systemd is running"
  else
    say "    systemd is not running (first pass, or a test)"
  fi
}

# 1. /etc/wsl.conf
write_wsl_conf() {
  step "/etc/wsl.conf"
  if put_file /etc/wsl.conf 0644 "$(cat "$SRC/wsl.conf")"$'\n'; then
    RESTART_NEEDED=true
  else
    say "    unchanged"
  fi
}

# 2. Users and groups
ensure_users() {
  step "Users and groups"
  local name
  if getent group "$MEDIA_GROUP" >/dev/null; then
    [[ $(getent group "$MEDIA_GROUP" | cut -d: -f3) == "$MEDIA_GID" ]] ||
      die "group $MEDIA_GROUP exists with another gid than $MEDIA_GID"
  else
    name=$(getent group "$MEDIA_GID" | cut -d: -f1) || true
    [[ -z $name ]] || die "gid $MEDIA_GID is taken by group $name"
    groupadd -g "$MEDIA_GID" "$MEDIA_GROUP"
    changed "group $MEDIA_GROUP ($MEDIA_GID)"
  fi
  # docker-ce's postinst creates the group too (addgroup --system accepts
  # an existing one); created here so the membership below works first.
  if ! getent group docker >/dev/null; then
    groupadd --system docker
    changed "group docker"
  fi

  if id -u "$RADIO_USER" >/dev/null 2>&1; then
    [[ $(id -u "$RADIO_USER") == "$RADIO_UID" ]] || die "user $RADIO_USER exists with another uid than $RADIO_UID"
  else
    name=$(getent passwd "$RADIO_UID" | cut -d: -f1) || true
    if [[ $name == ubuntu ]]; then
      # Ubuntu images may carry the stock user ubuntu as uid 1000: it
      # becomes radio (the drive mount maps files to uid 1000).
      usermod -l "$RADIO_USER" -d "/home/$RADIO_USER" -m ubuntu
      if getent group ubuntu >/dev/null && ! getent group "$RADIO_USER" >/dev/null; then
        groupmod -n "$RADIO_USER" ubuntu
      fi
      changed "user ubuntu (uid $RADIO_UID) renamed to $RADIO_USER"
    elif [[ -n $name ]]; then
      die "uid $RADIO_UID is taken by user $name"
    else
      if getent group "$RADIO_USER" >/dev/null; then
        useradd -m -u "$RADIO_UID" -g "$RADIO_USER" -s /bin/bash "$RADIO_USER"
      else
        useradd -m -u "$RADIO_UID" -U -s /bin/bash "$RADIO_USER"
      fi
      changed "user $RADIO_USER ($RADIO_UID)"
    fi
  fi
  local g
  for g in "$MEDIA_GROUP" docker; do
    if ! id -nG "$RADIO_USER" | tr ' ' '\n' | grep -qx "$g"; then
      usermod -aG "$g" "$RADIO_USER"
      changed "$RADIO_USER in group $g"
    fi
  done
  say "    $(id "$RADIO_USER")"
}

pkg_version() { dpkg-query -W -f='${Version}' "$1" 2>/dev/null || true; }
pkg_installed() { [[ $(dpkg-query -W -f='${Status}' "$1" 2>/dev/null) == "install ok installed" ]]; }

# While systemd is not PID 1 (first pass), package scripts must not start
# daemons: they would run outside systemd until the restart.
POLICY_RC=/usr/sbin/policy-rc.d
block_service_starts() {
  systemd_running && return 0
  [[ -e $POLICY_RC ]] && return 0
  printf '#!/bin/sh\nexit 101\n' >"$POLICY_RC"
  chmod 0755 "$POLICY_RC"
  POLICY_RC_OURS=true
}
POLICY_RC_OURS=false
unblock_service_starts() {
  if $POLICY_RC_OURS; then
    rm -f "$POLICY_RC"
    POLICY_RC_OURS=false
  fi
}

apt_get() { DEBIAN_FRONTEND=noninteractive apt-get -y -q -o Dpkg::Options::=--force-confold "$@"; }

# 3. Packages
install_packages() {
  step "Packages"
  write_apt_files
  if $SKIP_PACKAGES; then
    write_docker_source || true
    say "    skipped (--skip-packages)"
    return 0
  fi
  block_service_starts
  local missing=() p
  for p in "${BASE_PACKAGES[@]}"; do pkg_installed "$p" || missing+=("$p"); done
  local first_upgrade=false
  [[ -f /var/lib/radio-atlantida/upgraded ]] || first_upgrade=true
  if ((${#missing[@]})) || $first_upgrade; then
    apt_get update
  fi
  if $first_upgrade; then
    # Once: the pinned rootfs is older than the archive. Later updates are
    # unattended-upgrades' (security only); held packages are never touched.
    apt_get upgrade
    mkdir -p /var/lib/radio-atlantida
    date -u +%Y-%m-%dT%H:%M:%SZ >/var/lib/radio-atlantida/upgraded
    changed "packages upgraded once"
  fi
  if ((${#missing[@]})); then
    apt_get install --no-install-recommends "${missing[@]}"
    changed "installed ${missing[*]}"
  fi
  # The source only once its key is in place, or apt update fails.
  install_docker_key
  write_docker_source || true
  local want=() differ=false
  for p in "${DOCKER_PACKAGES[@]}"; do
    want+=("$p=$(pin_of "$p")")
    [[ $(pkg_version "$p") == "$(pin_of "$p")" ]] || differ=true
  done
  if $differ; then
    apt_get update
    apt-mark unhold "${DOCKER_PACKAGES[@]}" >/dev/null 2>&1 || true
    apt_get install --allow-downgrades --allow-change-held-packages "${want[@]}"
    changed "Docker packages ${want[*]}"
  fi
  local held
  held=$(apt-mark showhold)
  for p in "${DOCKER_PACKAGES[@]}"; do
    if ! grep -qx "$p" <<<"$held"; then
      apt-mark hold "$p" >/dev/null
      changed "apt-mark hold $p"
    fi
  done
  unblock_service_starts
  say "    Docker packages at the pinned versions, held"
}

# Docker's apt source (written after its key; with --skip-packages without
# the key, so the tests see it).
write_docker_source() {
  put_file /etc/apt/sources.list.d/docker.sources 0644 "# Docker's apt repository (setup-distro.sh, install/versions.env)
Types: deb
URIs: https://download.docker.com/linux/ubuntu
Suites: noble
Components: stable
Architectures: $(dpkg --print-architecture)
Signed-By: /etc/apt/keyrings/docker.asc
"
}

# The pin and the unattended-upgrades settings (also written with
# --skip-packages, so the tests see them).
write_apt_files() {
  local p pins='' n=0
  for p in "${DOCKER_PACKAGES[@]}"; do
    pins+="
Package: $p
Pin: version $(pin_of "$p")
Pin-Priority: 1001
"
  done
  put_file /etc/apt/preferences.d/radio-atlantida-docker 0644 "# Written by setup-distro.sh from install/versions.env: the Docker packages
# stay at these versions (also held with apt-mark hold). An engine upgrade is
# a new versions.env and an install.bat run in a maintenance window.
$pins" && n=1
  put_file /etc/apt/apt.conf.d/20auto-upgrades 0644 'APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";
' && n=1
  put_file /etc/apt/apt.conf.d/51radio-atlantida 0644 '// Written by setup-distro.sh (deploy-init-plan.md D4 6.3 step 3).
// Ubuntu security updates only (the allowed origins of
// 50unattended-upgrades); the Docker packages never, and no reboot.
Unattended-Upgrade::Package-Blacklist {
    "^docker-ce$";
    "^docker-ce-cli$";
    "^containerd\.io$";
    "^docker-compose-plugin$";
    "^docker-buildx-plugin$";
};
Unattended-Upgrade::Automatic-Reboot "false";
' && n=1
  ((n)) || say "    apt files unchanged"
  return 0
}

install_docker_key() {
  local key=/etc/apt/keyrings/docker.asc fpr=${PIN[DOCKER_APT_KEY_FINGERPRINT]} tmp
  if [[ -f $key ]] && [[ $(key_fingerprint "$key") == "$fpr" ]]; then
    return 0
  fi
  tmp=$(mktemp)
  curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o "$tmp" || die "cannot download Docker's apt key"
  [[ $(key_fingerprint "$tmp") == "$fpr" ]] || die "Docker's apt key has fingerprint $(key_fingerprint "$tmp"), versions.env pins $fpr"
  install -D -m 0644 "$tmp" "$key"
  rm -f "$tmp"
  changed "$key ($fpr)"
}

key_fingerprint() {
  gpg --show-keys --with-colons "$1" 2>/dev/null | awk -F: '$1 == "fpr" { print $10; exit }'
}

# 4. Docker daemon
configure_docker() {
  step "Docker daemon"
  local daemon_changed=false
  # userland-proxy stays on: its listening sockets are what WSL's localhost
  # forwarding detects in NAT mode (6.5).
  if put_file /etc/docker/daemon.json 0644 '{
  "log-driver": "json-file",
  "log-opts": { "max-size": "10m", "max-file": "3" },
  "userland-proxy": true
}
'; then
    daemon_changed=true
  else
    say "    daemon.json unchanged"
  fi
  if $SKIP_PACKAGES || $SKIP_SYSTEMD; then
    return 0
  fi
  if systemd_running; then
    if ! systemctl is-enabled --quiet containerd docker 2>/dev/null || ! systemctl is-active --quiet docker; then
      systemctl enable --now containerd docker
      changed "containerd and docker enabled and started"
    elif $daemon_changed; then
      systemctl restart docker
      changed "docker restarted (daemon.json)"
    fi
  else
    systemctl enable containerd docker >/dev/null 2>&1 || true
    say "    containerd and docker enabled; they start after the restart"
  fi
}

docker_answers() {
  ! $SKIP_PACKAGES && command -v docker >/dev/null && docker info >/dev/null 2>&1
}

liquidsoap_image() {
  [[ -f $COMPOSE_FILE ]] || return 1
  sed -n 's/^[[:space:]]*image:[[:space:]]*\(savonet\/liquidsoap:[^[:space:]]*\).*/\1/p' "$COMPOSE_FILE" | head -n 1
}

# 5. Directories on ext4
ensure_dirs() {
  step "Directories"
  ensure_dir /srv/radio 0:0 0755
  local owner=$JOURNAL_OWNER image
  if [[ -z $owner ]]; then
    if docker_answers; then
      image=$(liquidsoap_image) || true
      [[ -n $image ]] || die "no savonet/liquidsoap image in $COMPOSE_FILE"
      # The uid the pinned image runs as (not hard-coded, 6.3 step 5).
      owner=$(docker run --rm --entrypoint id "$image" -u):$(docker run --rm --entrypoint id "$image" -g) ||
        die "cannot read the user of $image"
      say "    $image runs as $owner"
    elif [[ -d /srv/radio/journal ]]; then
      owner=$(stat -c %u:%g /srv/radio/journal)
      say "    journal owner: Docker is not running yet; kept as $owner until the next pass"
    else
      owner=0:0
      say "    journal owner: Docker is not running yet; set in the next pass"
    fi
  fi
  ensure_dir /srv/radio/journal "$owner" 0755
  ensure_dir /srv/radio/backups "$RADIO_UID:$RADIO_UID" 0700
  ensure_dir /opt/radio-atlantida "$RADIO_UID:$RADIO_UID" 0755
  ensure_dir /etc/radio-atlantida 0:0 0755
  ensure_dir /var/lib/radio-atlantida 0:0 0755
  # The network mode for radio-network.service (radioctl network).
  put_file /etc/radio-atlantida/host.env 0644 "# Written by setup-distro.sh (install.ps1 chose it from the Windows build).
RADIO_NETWORK_MODE=$MODE
" || say "    host.env unchanged ($MODE)"
  JOURNAL_OWNER_FINAL=$owner
}
JOURNAL_OWNER_FINAL=

# 6. Keep-alive helper and systemd units
install_units() {
  step "Keep-alive and systemd units"
  put_file /usr/local/bin/radio-keepalive 0755 "$(cat "$SRC/radio-keepalive")"$'\n' || say "    radio-keepalive unchanged"
  local out line sc=systemctl booted=no
  $SKIP_SYSTEMD && sc=true
  systemd_running && booted=yes
  out=$(SYSTEMCTL=$sc SYSTEMD_BOOTED=$booted bash "$SRC/systemd/install-units.sh") || die "install-units.sh failed: $out"
  if [[ -n $out ]]; then
    while IFS= read -r line; do
      if [[ $line == installed* ]]; then
        changed "${line#installed }"
      else
        say "    $line"
      fi
    done <<<"$out"
  else
    say "    units unchanged"
  fi
}

# 7. Final checks (under systemd, or with --final)
final_checks() {
  step "Checks"
  if ! $SKIP_SYSTEMD; then
    local st
    st=$(timeout 180 systemctl is-system-running --wait 2>/dev/null) || true
    case $st in
      running) say "    systemd: running" ;;
      degraded)
        warn "systemd is degraded; failed units:"
        systemctl --failed --no-legend --plain | sed 's/^/        /' || true
        ;;
      *) die "systemd is '$st' (expected running)" ;;
    esac
  fi
  if ! $SKIP_PACKAGES; then
    docker info >/dev/null 2>&1 || die "docker info does not answer"
    local have want
    want=$(upstream_version "${PIN[DOCKER_CE_VERSION]}")
    have=$(docker version --format '{{.Server.Version}}')
    [[ $have == "$want" ]] || die "Docker Engine is $have, versions.env pins $want"
    want=$(upstream_version "${PIN[DOCKER_COMPOSE_PLUGIN_VERSION]}")
    have=$(docker compose version --short)
    [[ ${have#v} == "$want" ]] || die "Docker Compose is $have, versions.env pins $want"
    say "    Docker Engine $(docker version --format '{{.Server.Version}}'), Compose $want"
    [[ $(stat -c %u:%g /srv/radio/journal) == "$JOURNAL_OWNER_FINAL" ]] || die "the journal owner is not set"
  fi
  if [[ -n $MEDIA_ROOT ]]; then
    check_media
  fi
}

# The media folder as the backend sees it (6.6): group radio-media, group
# write, and radio can create and rename a file (a transcode does that).
check_media() {
  local m=$MEDIA_ROOT
  [[ -d $m ]] || die "the media folder $m is not visible in WSL (is the drive mounted?)"
  local gid
  gid=$(stat -c %g "$m")
  [[ $gid == "$MEDIA_GID" ]] || die "the media folder $m has group $gid, not $MEDIA_GID: /etc/wsl.conf automount options are not in effect"
  [[ $(($(stat -c '0%a' "$m") & 8#020)) -ne 0 ]] || die "the media folder $m is not group-writable"
  # shellcheck disable=SC2016 # $1 and $$ expand in the inner sh
  runuser -u "$RADIO_USER" -- sh -c '
    t="$1/.radio-atlantida-write-test.$$"
    : >"$t.tmp" && mv "$t.tmp" "$t" && rm -f "$t"
  ' sh "$m" || die "the user $RADIO_USER cannot create and rename a file in $m"
  say "    media folder $m: group $MEDIA_GROUP, group write, create and rename ok"
}

main() {
  parse_args "$@"
  read_pins
  check_host
  write_wsl_conf
  ensure_users
  install_packages
  configure_docker
  ensure_dirs
  install_units
  local final=false
  { systemd_running || $FORCE_FINAL; } && final=true
  if $final && ! $RESTART_NEEDED; then
    final_checks
  fi
  say ""
  if ((CHANGED)); then
    say "setup-distro: $CHANGED change(s)."
  else
    say "setup-distro: nothing to change."
  fi
  if $RESTART_NEEDED || ! $final; then
    say "Restart the distribution (wsl --terminate radio-atlantida) and run setup-distro.sh again."
    exit 10
  fi
  exit 0
}

main "$@"
