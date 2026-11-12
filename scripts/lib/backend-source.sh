# shellcheck shell=bash
# Shared by scripts/check-backend-sync.sh and tests/liquidsoap/run.sh: the
# backend source at a given ref (deploy-init-plan.md D3, 11.13).
#
# The ref is, in order: the --ref argument, BACKEND_REF, or v${BACKEND_TAG}
# from release.env. Until the first release tag exists, pass the commit
# recorded in config/backend-source.env.
#
# The source is the public GitHub repository (no token), or a local
# checkout given with --backend-dir; from a local checkout the files are
# taken with `git archive <ref>`, so uncommitted changes there never count.

BACKEND_REPO_URL=${BACKEND_REPO_URL:-https://github.com/AstRonin/radio-atlantida-backend.git}

# default_backend_ref <deploy root>: v${BACKEND_TAG} of release.env.
default_backend_ref() {
  local tag
  tag=$(sed -n 's/^BACKEND_TAG=//p' "$1/release.env" | tr -d '\r"' | head -n 1)
  if [[ -z "$tag" ]]; then
    echo "backend-source: no BACKEND_TAG in release.env" >&2
    return 1
  fi
  printf 'v%s\n' "$tag"
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
    v*) echo "backend-source: if the release tag $1 does not exist yet, pass --ref <commit> (see config/backend-source.env)" >&2 ;;
  esac
}
