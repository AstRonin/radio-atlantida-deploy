# shellcheck shell=bash
# Shared by scripts/check-backend-sync.sh and tests/liquidsoap/run.sh: the
# backend source at a given ref (deploy-init-plan.md D3, 11.13).
#
# The ref is, in order: the --ref argument, BACKEND_REF, v${BACKEND_TAG}
# from release.env when that tag exists in the backend repository, else the
# commit recorded in config/backend-source.env (with a warning). The
# fallback covers the time before the first backend release tag; once
# release.env names a real release (digests set), CI requires the tag
# (scripts/check-release.sh), so the fallback cannot hide a missing tag.
#
# The source is the public GitHub repository (no token), or a local
# checkout given with --backend-dir; from a local checkout the files are
# taken with `git archive <ref>`, so uncommitted changes there never count.

BACKEND_REPO_URL=${BACKEND_REPO_URL:-https://github.com/AstRonin/radio-atlantida-backend.git}

# release_backend_tag <deploy root>: v${BACKEND_TAG} of release.env.
release_backend_tag() {
  local tag
  tag=$(sed -n 's/^BACKEND_TAG=//p' "$1/release.env" | tr -d '\r"' | head -n 1)
  if [[ -z "$tag" ]]; then
    echo "backend-source: no BACKEND_TAG in release.env" >&2
    return 1
  fi
  printf 'v%s\n' "$tag"
}

# backend_tag_exists <tag> <local checkout or empty>: 0 if the tag exists
# in the local checkout, or else in the public repository.
backend_tag_exists() {
  if [[ -n "$2" ]]; then
    git -C "$2" rev-parse --verify --quiet "refs/tags/$1" >/dev/null
  else
    [[ -n $(git ls-remote --tags "$BACKEND_REPO_URL" "refs/tags/$1" 2>/dev/null) ]]
  fi
}

# default_backend_ref <deploy root> [<local checkout>]: v${BACKEND_TAG} if
# that tag exists, else BACKEND_SOURCE_COMMIT of config/backend-source.env.
default_backend_ref() {
  local tag commit msg
  tag=$(release_backend_tag "$1") || return 1
  if backend_tag_exists "$tag" "${2:-}"; then
    printf '%s\n' "$tag"
    return 0
  fi
  commit=$(sed -n 's/^BACKEND_SOURCE_COMMIT=//p' "$1/config/backend-source.env" 2>/dev/null | tr -d '\r"' | head -n 1)
  if [[ -z "$commit" ]]; then
    echo "backend-source: the backend tag $tag does not exist and config/backend-source.env has no BACKEND_SOURCE_COMMIT" >&2
    return 1
  fi
  msg="the backend tag $tag does not exist yet; using BACKEND_SOURCE_COMMIT $commit of config/backend-source.env"
  if [[ ${GITHUB_ACTIONS:-} == true ]]; then
    echo "::warning title=backend ref::$msg" >&2
  else
    echo "backend-source: $msg" >&2
  fi
  printf '%s\n' "$commit"
}

# fetch_backend <ref> <local checkout or empty> <dest dir>: writes the
# backend tree at <ref> into <dest dir> (which must exist and be empty) and
# prints the full commit hash.
fetch_backend() {
  local ref=$1 local_dir=$2 dest=$3 commit
  if [[ -n "$local_dir" ]]; then
    if ! commit=$(git -C "$local_dir" rev-parse --verify --quiet "${ref}^{commit}"); then
      echo "backend-source: ref '$ref' not found in $local_dir" >&2
      hint_missing_ref "$ref"
      return 1
    fi
    git -C "$local_dir" archive --format=tar "$commit" | tar -x -C "$dest"
  else
    git -C "$dest" init -q
    if ! git -C "$dest" fetch -q --depth 1 "$BACKEND_REPO_URL" "$ref"; then
      echo "backend-source: cannot fetch '$ref' from $BACKEND_REPO_URL" >&2
      hint_missing_ref "$ref"
      return 1
    fi
    git -C "$dest" -c advice.detachedHead=false checkout -q FETCH_HEAD
    commit=$(git -C "$dest" rev-parse "FETCH_HEAD^{commit}")
    rm -rf "$dest/.git"
  fi
  printf '%s\n' "$commit"
}

hint_missing_ref() {
  case "$1" in
    v*) echo "backend-source: if the release tag $1 does not exist yet, leave out --ref and BACKEND_REF (the default falls back to config/backend-source.env)" >&2 ;;
  esac
}
