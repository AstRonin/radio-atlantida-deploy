#!/usr/bin/env bash
# release.env names an installable release (deploy-init-plan.md §10.1,
# 9.1 item 2, 11.7):
#
#   - BACKEND_TAG and FRONTEND_TAG are X.Y.Z, at least 1.0.0, with the same
#     MAJOR.MINOR;
#   - the digests are set (sha256:<64 hex>). Before the first release, while
#     the backend tag v${BACKEND_TAG} does not exist yet, empty digests are
#     only a warning; once the tag exists they are required;
#   - with digests set, the Git tags v${BACKEND_TAG} and v${FRONTEND_TAG}
#     exist in the public backend and frontend repositories (so the sync
#     check really runs against the release, not the fallback commit of
#     config/backend-source.env);
#   - with registry credentials (GHCR_USER and GHCR_READ_TOKEN in the
#     environment: the read-only token, a CI secret), each digest is the
#     manifest list digest of its tag in GHCR. Without them this part is
#     skipped with a warning (the images are private).
set -Eeuo pipefail
root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
# shellcheck source=scripts/lib/backend-source.sh
source "$root/scripts/lib/backend-source.sh"
FRONTEND_REPO_URL=${FRONTEND_REPO_URL:-https://github.com/AstRonin/radio-atlantida-frontend.git}

val() { sed -n "s/^$1=//p" "$root/release.env" | tr -d '\r"' | head -n 1; }
bad=0
problem() {
  echo "release: $*"
  bad=1
}
warning() {
  if [[ ${GITHUB_ACTIONS:-} == true ]]; then
    echo "::warning title=release.env::$*"
  else
    echo "release: WARNING: $*"
  fi
}

btag=$(val BACKEND_TAG)
ftag=$(val FRONTEND_TAG)
bdig=$(val BACKEND_DIGEST)
fdig=$(val FRONTEND_DIGEST)
semver='^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$'

for t in "BACKEND_TAG=$btag" "FRONTEND_TAG=$ftag"; do
  v=${t#*=}
  if [[ ! $v =~ $semver ]]; then
    problem "${t%%=*} '$v' is not X.Y.Z"
  elif [[ ${BASH_REMATCH[1]} == 0 ]]; then
    problem "${t%%=*} $v is below 1.0.0 (the baseline, §10.3)"
  fi
done
[[ ${btag%.*} == "${ftag%.*}" ]] || problem "backend $btag and frontend $ftag differ in MAJOR.MINOR (11.7)"

released=false
backend_tag_exists "v$btag" "" && released=true
if [[ -z $bdig || -z $fdig ]]; then
  if $released; then
    problem "the backend tag v$btag exists, but release.env has an empty digest; a release PR sets both digests"
  else
    warning "empty digests: no release v$btag yet (placeholders until the first release; required once the tag exists)"
  fi
else
  for d in "BACKEND_DIGEST=$bdig" "FRONTEND_DIGEST=$fdig"; do
    [[ ${d#*=} =~ ^sha256:[0-9a-f]{64}$ ]] || problem "${d%%=*} '${d#*=}' is not sha256:<64 hex>"
  done
  $released || problem "release.env sets digests, but the backend tag v$btag does not exist in $BACKEND_REPO_URL"
  [[ -n $(git ls-remote --tags "$FRONTEND_REPO_URL" "refs/tags/v$ftag" 2>/dev/null) ]] ||
    problem "the frontend tag v$ftag does not exist in $FRONTEND_REPO_URL"
  if [[ -n ${GHCR_USER:-} && -n ${GHCR_READ_TOKEN:-} ]]; then
    cfg=$(mktemp -d)
    trap 'rm -rf "$cfg"' EXIT
    export DOCKER_CONFIG=$cfg
    printf '%s' "$GHCR_READ_TOKEN" | docker login ghcr.io -u "$GHCR_USER" --password-stdin >/dev/null 2>&1 ||
      problem "docker login ghcr.io failed (GHCR_USER, GHCR_READ_TOKEN)"
    for img in "radio-atlantida-backend:$btag=$bdig" "radio-atlantida-frontend:$ftag=$fdig"; do
      ref=ghcr.io/astronin/${img%%=*}
      got=$(docker buildx imagetools inspect --format '{{json .Manifest}}' "$ref" 2>/dev/null | jq -r '.digest // empty') || got=
      if [[ -z $got ]]; then
        problem "$ref was not found in the registry"
      elif [[ $got != "${img#*=}" ]]; then
        problem "$ref is $got in the registry, release.env says ${img#*=}"
      else
        echo "ok - $ref = $got"
      fi
    done
  else
    warning "digests not compared with the registry: GHCR_USER and GHCR_READ_TOKEN are not set"
  fi
fi

if ((bad)); then
  echo "release: FAIL"
  exit 1
fi
echo "release: OK (backend $btag, frontend $ftag)"
