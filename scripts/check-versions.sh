#!/usr/bin/env bash
# The host pins of install/versions.env still exist upstream
# (deploy-init-plan.md D4, 9.1 item 7):
#
#   - UBUNTU_ROOTFS_URL answers, and UBUNTU_ROOTFS_SHA256 is the checksum the
#     release folder's SHA256SUMS publishes for that file; with --download
#     the file is also downloaded (about 350 MB) and hashed;
#   - Docker's apt key has DOCKER_APT_KEY_FINGERPRINT, and Docker's
#     repository for Ubuntu 24.04 (amd64, the production architecture) has
#     every pinned package version: docker-ce and docker-ce-cli
#     (DOCKER_CE_VERSION), containerd.io, docker-compose-plugin,
#     docker-buildx-plugin (`apt-cache madison` in ubuntu:24.04).
#
# tests/distro/run.sh --with-apt installs the same versions; this check is
# the fast one with a clear message when Docker or Canonical removes a pin.
#
#   scripts/check-versions.sh [--download]
set -Eeuo pipefail
root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
# The same pinned ubuntu:24.04 as tests/distro/run.sh.
image=ubuntu:24.04@sha256:2198e4c65076e9cb0b3d695219df667c0e3b0072da64ca3c2648aca17dcecaf5
download=false
[[ ${1:-} == --download ]] && download=true

pin() {
  local v
  v=$(sed -n "s/^$1=//p" "$root/install/versions.env" | tr -d '\r' | head -n 1)
  [[ -n $v ]] || {
    echo "versions: $1 is not set in install/versions.env" >&2
    exit 1
  }
  printf '%s' "$v"
}

bad=0
problem() {
  echo "versions: $*"
  bad=1
}

url=$(pin UBUNTU_ROOTFS_URL)
sha=$(pin UBUNTU_ROOTFS_SHA256)
name=${url##*/}
echo "== Ubuntu rootfs $url"
if curl -fsSIL --retry 3 -o /dev/null "$url"; then
  echo "ok - the URL answers"
else
  problem "$url does not answer"
fi
if sums=$(curl -fsSL --retry 3 "${url%/*}/SHA256SUMS"); then
  published=$(awk -v n="$name" '{f=$2; sub(/^\*/, "", f)} f == n {print $1}' <<<"$sums")
  if [[ $published == "$sha" ]]; then
    echo "ok - SHA256SUMS lists $sha for $name"
  else
    problem "SHA256SUMS lists '${published:-nothing}' for $name, versions.env pins $sha"
  fi
else
  problem "${url%/*}/SHA256SUMS does not answer"
fi
if $download; then
  got=$(curl -fsSL --retry 3 "$url" | { sha256sum 2>/dev/null || shasum -a 256; } | cut -c1-64) || got=
  if [[ $got == "$sha" ]]; then
    echo "ok - the downloaded file hashes to the pin"
  else
    problem "the downloaded file hashes to '${got:-nothing}', versions.env pins $sha"
  fi
fi

echo "== Docker apt repository (Ubuntu 24.04 noble, amd64)"
if ! docker run --rm --platform linux/amd64 -i \
  -e FPR="$(pin DOCKER_APT_KEY_FINGERPRINT)" \
  -e PKGS="docker-ce=$(pin DOCKER_CE_VERSION) docker-ce-cli=$(pin DOCKER_CE_VERSION) containerd.io=$(pin CONTAINERD_VERSION) docker-compose-plugin=$(pin DOCKER_COMPOSE_PLUGIN_VERSION) docker-buildx-plugin=$(pin DOCKER_BUILDX_PLUGIN_VERSION)" \
  "$image" bash -s <<'EOF'; then
set -Eeuo pipefail
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq >/dev/null
apt-get install -y -qq --no-install-recommends ca-certificates curl gnupg >/dev/null
install -d -m 0755 /etc/apt/keyrings
curl -fsSL --retry 3 https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
got=$(gpg --show-keys --with-colons /etc/apt/keyrings/docker.asc 2>/dev/null | awk -F: '$1 == "fpr" {print $10; exit}')
if [[ $got != "$FPR" ]]; then
  echo "versions: Docker's apt key is $got, versions.env pins $FPR"
  exit 1
fi
echo "ok - Docker's apt key fingerprint $FPR"
echo "deb [arch=amd64 signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/ubuntu noble stable" \
  >/etc/apt/sources.list.d/docker.list
apt-get update -qq >/dev/null
rc=0
for pv in $PKGS; do
  p=${pv%%=*} v=${pv#*=}
  if apt-cache madison "$p" | awk -F'|' '{gsub(/ /, "", $2); print $2}' | grep -qxF "$v"; then
    echo "ok - $p $v"
  else
    echo "versions: $p $v is not in Docker's repository; newest: $(apt-cache madison "$p" | head -n 1 | awk -F'|' '{gsub(/ /, "", $2); print $2}')"
    rc=1
  fi
done
exit $rc
EOF
  problem "the Docker apt pins do not all exist (see above)"
fi

if ((bad)); then
  echo "versions: FAIL"
  exit 1
fi
echo "versions: OK"
