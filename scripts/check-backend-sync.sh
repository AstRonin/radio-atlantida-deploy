#!/usr/bin/env bash
# Compares this repository with the backend at a release ref
# (deploy-init-plan.md D3, 9.1 item 3, 11.2):
#   - config/liquidsoap/radio.liq equals the backend's dev/liquidsoap/radio.liq
#     with config/liquidsoap/production.patch applied, and has the contract
#     header;
#   - config/grafana/, config/loki/loki.yaml, config/alloy/config.alloy equal
#     dev/grafana/, dev/loki/loki.yaml, dev/alloy/config.alloy (Go test files
#     excluded);
#   - the infrastructure image pins of docker-compose.yml equal
#     docker-compose.dev.yml, and those of tests/liquidsoap/compose.yml equal
#     dev/liqsmoke/compose.yml.
# Exits 1 on any drift and prints the differences.
#
# --update writes the config files from the backend instead (the script is
# rebuilt from the dev script and the patch) and records the commit in
# config/backend-source.env; image pins are only reported, never rewritten
# (a pin change is a reviewed edit). Review and commit the result.

set -Eeuo pipefail

root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
# shellcheck source=scripts/lib/backend-source.sh
source "$root/scripts/lib/backend-source.sh"
# shellcheck source=scripts/lib/contract.sh
source "$root/scripts/lib/contract.sh"

usage() {
  cat <<'EOF'
Usage: scripts/check-backend-sync.sh [--ref REF] [--backend-dir DIR] [--update]

  --ref REF          backend tag or commit (default: $BACKEND_REF, else
                     v${BACKEND_TAG} from release.env if the tag exists, else
                     BACKEND_SOURCE_COMMIT of config/backend-source.env)
  --backend-dir DIR  read a local backend checkout (git archive REF) instead
                     of fetching github.com (default: $BACKEND_DIR)
  --update           write config/ from the backend instead of checking it
EOF
}

ref=${BACKEND_REF:-}
local_dir=${BACKEND_DIR:-}
update=false
while (($#)); do
  case "$1" in
    --ref) ref=${2:?--ref needs a value}; shift 2 ;;
    --backend-dir) local_dir=${2:?--backend-dir needs a value}; shift 2 ;;
    --update) update=true; shift ;;
    -h | --help) usage; exit 0 ;;
    *) usage >&2; exit 2 ;;
  esac
done
if [[ -z "$ref" ]]; then
  ref=$(default_backend_ref "$root" "$local_dir")
fi

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
mkdir "$work/src"
src=$work/src

drift=0

report() {
  echo "DRIFT: $*"
  drift=1
}

# build_script <dev script> <patch> <out>: the dev script with the patch
# applied. A patch without a `--- ` line (comments only) is empty.
build_script() {
  if grep -q '^--- ' "$2"; then
    if ! patch -s -o "$3" "$1" <"$2" >"$work/patch.log" 2>&1; then
      cat "$work/patch.log" >&2
      echo "config/liquidsoap/production.patch does not apply to dev/liquidsoap/radio.liq at $ref" >&2
      exit 1
    fi
  else
    cp "$1" "$3"
  fi
}

# image_pins <compose file> <image name>: the pinned references of that image.
image_pins() {
  sed -n "s|^[[:space:]]*image:[[:space:]]*\\($2:[^[:space:]]*\\).*|\\1|p" "$1" | sort -u
}

# check_pins <deploy compose> <backend compose> <image names...>
check_pins() {
  local ours=$1 theirs=$2 name a b
  shift 2
  for name in "$@"; do
    a=$(image_pins "$root/$ours" "$name")
    b=$(image_pins "$src/$theirs" "$name")
    if [[ -z "$a" || "$a" != "$b" ]]; then
      report "image $name: $ours has '${a//$'\n'/ }', backend $theirs has '${b//$'\n'/ }'"
    fi
  done
}

# check_same <ours> <theirs>: files or directories, Go test files excluded.
check_same() {
  if ! diff -r -u -x '*_test.go' "$src/$2" "$root/$1" >"$work/diff" 2>&1; then
    report "$1 differs from backend $2:"
    cat "$work/diff"
  fi
}

check_contract() {
  local f=$root/config/liquidsoap/radio.liq
  if ! script_contract "$f" >/dev/null || ! script_min_backend "$f" >/dev/null; then
    report "config/liquidsoap/radio.liq has no contract header (radio-atlantida-contract, min-backend)"
  fi
}

commit=$(fetch_backend "$ref" "$local_dir" "$src")
echo "backend $ref = $commit (${local_dir:-$BACKEND_REPO_URL})"

build_script "$src/dev/liquidsoap/radio.liq" "$root/config/liquidsoap/production.patch" "$work/radio.liq"

if $update; then
  cp "$work/radio.liq" "$root/config/liquidsoap/radio.liq"
  rm -rf "$root/config/grafana"
  cp -R "$src/dev/grafana" "$root/config/grafana"
  find "$root/config/grafana" -name '*_test.go' -delete
  cp "$src/dev/loki/loki.yaml" "$root/config/loki/loki.yaml"
  cp "$src/dev/alloy/config.alloy" "$root/config/alloy/config.alloy"
  cat >"$root/config/backend-source.env" <<EOF
# The backend commit config/ was taken from, written by
# scripts/check-backend-sync.sh --update (deploy-init-plan.md D3). Until the
# release tag v\${BACKEND_TAG} exists, the checks and CI use
# BACKEND_SOURCE_COMMIT as the backend ref (scripts/lib/backend-source.sh).
BACKEND_SOURCE_REF=$ref
BACKEND_SOURCE_COMMIT=$commit
EOF
  echo "updated config/ from backend $ref; review with git diff"
fi

if ! diff -u --label "backend dev/liquidsoap/radio.liq + production.patch" --label config/liquidsoap/radio.liq \
  "$work/radio.liq" "$root/config/liquidsoap/radio.liq" >"$work/diff"; then
  report "config/liquidsoap/radio.liq is not dev/liquidsoap/radio.liq + production.patch:"
  cat "$work/diff"
fi
check_contract
check_same config/grafana dev/grafana
check_same config/loki/loki.yaml dev/loki/loki.yaml
check_same config/alloy/config.alloy dev/alloy/config.alloy
check_pins docker-compose.yml docker-compose.dev.yml \
  postgres savonet/liquidsoap grafana/grafana grafana/loki grafana/alloy
check_pins tests/liquidsoap/compose.yml dev/liqsmoke/compose.yml \
  libretime/icecast nginxinc/nginx-unprivileged

if ((drift)); then
  echo "FAIL: drift from backend $ref ($commit)"
  exit 1
fi
echo "OK: in sync with backend $ref ($commit)"
