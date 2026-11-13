#!/usr/bin/env bash
# Prints the backend ref the checks run against (scripts/lib/backend-source.sh):
# $BACKEND_REF if set, else v${BACKEND_TAG} of release.env if that tag
# exists in the backend repository, else BACKEND_SOURCE_COMMIT of
# config/backend-source.env (with a warning on stderr). CI uses it to check
# out the backend once for the sync check and the Liquidsoap smoke test.
#
#   scripts/backend-ref.sh [--backend-dir DIR]
set -Eeuo pipefail
root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
# shellcheck source=scripts/lib/backend-source.sh
source "$root/scripts/lib/backend-source.sh"
local_dir=
if [[ ${1:-} == --backend-dir ]]; then
  local_dir=${2:?--backend-dir needs a value}
fi
if [[ -n ${BACKEND_REF:-} ]]; then
  printf '%s\n' "$BACKEND_REF"
else
  default_backend_ref "$root" "$local_dir"
fi
