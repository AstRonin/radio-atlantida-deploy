#!/usr/bin/env bash
# Runs shellcheck on every bash file of the repository (deploy-init-plan.md 9.1
# item 8, §1.1), in the pinned koalaman/shellcheck image. The files are found,
# not listed: every tracked *.sh or *.bash file and every tracked file whose
# first line is a bash shebang (bin/radioctl, install/radio-keepalive, the
# test stubs, ...). The *.bats files are left out: shellcheck does not parse
# the @test syntax; their shared code is tests/radioctl/helpers.bash.
#
#   scripts/check-shell.sh          check, exit 1 on any finding
#   scripts/check-shell.sh --list   print the files that would be checked
set -Eeuo pipefail
root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
# koalaman/shellcheck:v0.10.0, multi-arch index digest (checked 2026-11-13).
image=koalaman/shellcheck:v0.10.0@sha256:2097951f02e735b613f4a34de20c40f937a6c8f18ecb170612c88c34517221fb

files=()
while IFS= read -r -d '' f; do
  case $f in
    *.bats) continue ;;
    *.sh | *.bash) files+=("$f") ;;
    *)
      if [[ -f $root/$f ]] && head -n 1 "$root/$f" | grep -Eq '^#!.*[/ ]bash([[:space:]]|$)'; then
        files+=("$f")
      fi
      ;;
  esac
done < <(git -C "$root" ls-files -z)

if [[ ${1:-} == --list ]]; then
  printf '%s\n' "${files[@]}"
  exit 0
fi
((${#files[@]})) || {
  echo "check-shell: no bash files found" >&2
  exit 1
}

# -x follows the `source` lines; their `# shellcheck source=` paths are
# relative to the repository root, which is the working directory here.
docker run --rm -v "$root:/mnt:ro" -w /mnt "$image" -x "${files[@]}"
echo "shellcheck: ${#files[@]} files clean"
