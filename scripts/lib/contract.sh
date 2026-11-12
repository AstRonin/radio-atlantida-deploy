# shellcheck shell=bash
# The contract header of the Liquidsoap script (deploy-init-plan.md 5.3
# task 2, cross-repo B2):
#
#   # radio-atlantida-contract: <N>
#   # min-backend: <X.Y.Z>
#
# Shared by scripts/check-backend-sync.sh (the header exists) and
# bin/radioctl (min-backend against the backend tag, the contract number
# against the applied one).

CONTRACT_RE='^# radio-atlantida-contract: ([0-9]+)$'
MIN_BACKEND_RE='^# min-backend: ([0-9]+\.[0-9]+\.[0-9]+)$'

# script_contract <file>: prints the contract number; returns 1 without one.
script_contract() {
  local line
  while IFS= read -r line; do
    if [[ $line =~ $CONTRACT_RE ]]; then
      printf '%s\n' "${BASH_REMATCH[1]}"
      return 0
    fi
  done <"$1"
  return 1
}

# script_min_backend <file>: prints the min-backend version; returns 1
# without one.
script_min_backend() {
  local line
  while IFS= read -r line; do
    if [[ $line =~ $MIN_BACKEND_RE ]]; then
      printf '%s\n' "${BASH_REMATCH[1]}"
      return 0
    fi
  done <"$1"
  return 1
}
