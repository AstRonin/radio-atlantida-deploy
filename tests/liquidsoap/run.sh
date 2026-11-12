#!/usr/bin/env bash
# Checks the production playout script config/liquidsoap/radio.liq
# (deploy-init-plan.md D3, 9.1 item 6):
#   1. `liquidsoap --check` in the pinned image, as the production service
#      runs it (tests/liquidsoap/compose.yml extends it unchanged);
#   2. the runtime smoke test: the backend's own smoke tool (dev/liqsmoke,
#      Go, at the same backend ref as the script) runs the production
#      service against a test Icecast, plain and behind a TLS proxy, with a
#      stub backend: startup output from the backend, OK unchanged,
#      refusals, every codec x channels x sample rate at the lowest and
#      highest bitrate and on both sides of every encoder limit, TLS, and a
#      restart from the state file with the backend down.
# `liquidsoap --check` alone is not enough: it accepts scripts that fail
# only when an encoder starts (5.2).
#
# Needs docker with compose, git, and (for the smoke test) go. The stack is
# the compose project radio-deploy-liqsmoke and is removed at the end; on a
# failure `compose ps -a` and the logs of every service are printed first.

set -Eeuo pipefail

root=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
# shellcheck source=scripts/lib/backend-source.sh
source "$root/scripts/lib/backend-source.sh"

usage() {
  cat <<'EOF'
Usage: tests/liquidsoap/run.sh [--ref REF] [--backend-dir DIR] [--check-only]

  --ref REF          backend tag or commit of the smoke tool (default:
                     $BACKEND_REF, else v${BACKEND_TAG} from release.env);
                     use the ref config/liquidsoap/radio.liq was taken from
  --backend-dir DIR  take the smoke tool from a local backend checkout
                     (git archive REF) instead of github.com
                     (default: $BACKEND_DIR)
  --check-only       only run liquidsoap --check (no backend source, no go)
EOF
}

ref=${BACKEND_REF:-}
local_dir=${BACKEND_DIR:-}
check_only=false
while (($#)); do
  case "$1" in
    --ref) ref=${2:?--ref needs a value}; shift 2 ;;
    --backend-dir) local_dir=${2:?--backend-dir needs a value}; shift 2 ;;
    --check-only) check_only=true; shift ;;
    -h | --help) usage; exit 0 ;;
    *) usage >&2; exit 2 ;;
  esac
done
if [[ -z "$ref" ]] && ! $check_only; then
  ref=$(default_backend_ref "$root")
fi

project=radio-deploy-liqsmoke
compose_file=$root/tests/liquidsoap/compose.yml

# Everything mounted into the non-root containers (liquidsoap, nginx) must
# be readable by another uid on Linux: directories 0755, files 0644; the
# journal is written by the liquidsoap user, so it is 0777.
work=$(mktemp -d)
mkdir "$work/src" "$work/media" "$work/journal" "$work/certs"
chmod 0755 "$work" "$work/media" "$work/certs"
chmod 0777 "$work/journal"

# Test values for the variables the compose files need. Only `liquidsoap` of
# ../../docker-compose.yml is used, but Compose interpolates the whole file.
export ICECAST_SOURCE_PASSWORD=smoke-source
export LIQUIDSOAP_CONTROL_USER=source
export LIQUIDSOAP_CONTROL_PASSWORD=smoke-control
export MEDIA_ROOT=$work/media
export PLAYOUT_JOURNAL_ROOT=$work/journal
export LIQSMOKE_CERTS=$work/certs
export BACKEND_TAG=0.0.0 FRONTEND_TAG=0.0.0
export BACKEND_DIGEST=sha256:0000000000000000000000000000000000000000000000000000000000000000
export FRONTEND_DIGEST=$BACKEND_DIGEST
export POSTGRES_USER=smoke POSTGRES_PASSWORD=smoke POSTGRES_DB=smoke
export LIVE_UDP_BIND=127.0.0.1 LIVE_PUBLIC_IPS=127.0.0.1

compose() {
  docker compose -f "$compose_file" -p "$project" "$@"
}

cleanup() {
  compose down -v -t 1 --remove-orphans >/dev/null 2>&1 || true
  rm -rf "$work" 2>/dev/null || true
}
trap cleanup EXIT

diagnose() {
  echo "--- docker compose ps -a" >&2
  compose ps -a >&2 || true
  echo "--- docker compose logs" >&2
  compose logs --no-color --timestamps >&2 || true
}

fail() {
  echo "liquidsoap test: FAIL: $*" >&2
  diagnose
  exit 1
}

if ! $check_only; then
  commit=$(fetch_backend "$ref" "$local_dir" "$work/src")
  echo "smoke tool: backend $ref = $commit (${local_dir:-$BACKEND_REPO_URL})"
  # A throwaway CA and the TLS proxy certificate (files 0644, dir 0755).
  go -C "$work/src" run ./dev/liqsmoke -cert "$work/certs"
else
  # Only the mount source must exist for --check; no TLS is used.
  : >"$work/certs/ca.pem"
  chmod 0644 "$work/certs/ca.pem"
fi

echo "liquidsoap --check config/liquidsoap/radio.liq"
compose run --rm --no-deps -T --entrypoint liquidsoap liquidsoap \
  --check /etc/liquidsoap/radio.liq || fail "liquidsoap --check"
echo "liquidsoap --check: ok"
if $check_only; then
  exit 0
fi

go -C "$work/src" run ./dev/liqsmoke -compose-file "$compose_file" -project "$project" ||
  fail "runtime smoke test"
echo "liquidsoap test: PASS"
