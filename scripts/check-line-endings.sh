#!/usr/bin/env bash
# Line endings, encodings, and paths of the tracked files
# (deploy-init-plan.md §1, 9.1 item 11, 11.8; docs/tech-design.md §9.1):
#
#   - .gitattributes gives every text file its eol: crlf for *.bat and
#     *.ps1, lf for everything else (bin/radioctl, *.sh, ...);
#   - the index holds LF only (git normalises text files; a CRLF or mixed
#     file in the index means it was added without the attributes);
#   - the working tree matches the attribute: CRLF for *.bat and *.ps1, LF
#     elsewhere (a fresh checkout does this; a stale local copy shows up
#     here and is fixed with `git add --renormalize .` and a new checkout);
#   - *.ps1 starts with a UTF-8 BOM (Windows PowerShell 5.1 reads BOM-less
#     files as ANSI, §1.1), and no other file has one;
#   - no two paths differ only by case (NTFS is case-insensitive).
#
# Bash rather than the plan's check-line-endings.ps1: it reads git's own
# view of every file (`git ls-files --eol`: index, working tree, and
# attributes), runs in the Linux CI job next to the other checks without a
# PowerShell install, and also runs on the developer's Mac (bash 3.2 too);
# on a Windows checkout the eol attribute
# has already converted the files, so a PowerShell check there would only
# repeat what git did.
set -Eeuo pipefail
root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
cd "$root"

bad=0
problem() {
  echo "line endings: $*"
  bad=1
}

n=0
while IFS= read -r -d '' rec; do
  # "i/<eol> w/<eol> attr/<attributes> \t<path>", e.g.
  # "i/lf    w/crlf  attr/text eol=crlf    \tinstall.ps1"
  meta=${rec%%$'\t'*}
  path=${rec#*$'\t'}
  ieol=$(awk '{print $1}' <<<"$meta")
  weol=$(awk '{print $2}' <<<"$meta")
  attrs=$(sed -n 's|.*attr/||p' <<<"$meta" | sed 's/[[:space:]]*$//')
  ieol=${ieol#i/}
  weol=${weol#w/}
  case " $attrs " in
    *" -text "* | *" binary "*) continue ;;
    *" text "* | *" text=auto "*) ;;
    *)
      problem "$path has no text attribute in .gitattributes ('$attrs')"
      continue
      ;;
  esac
  [[ $ieol == -text || -z $ieol ]] && continue # binary content under text=auto, or empty
  n=$((n + 1))
  case $path in
    *.bat | *.ps1) want=crlf ;;
    *) want=lf ;;
  esac
  [[ " $attrs " == *" eol=$want "* ]] || problem "$path: .gitattributes gives '$attrs', expected eol=$want"
  [[ $ieol == lf || $ieol == none ]] || problem "$path: the index holds $ieol line endings (expected lf; git add --renormalize)"
  if [[ -e $path && $weol != none && -n $weol ]]; then
    [[ $weol == "$want" ]] || problem "$path: the working tree has $weol line endings, expected $want"
  fi
  if [[ -e $path ]]; then
    bom=$(head -c 3 "$path" | od -An -tx1 | tr -d ' \n')
    case $path in
      *.ps1) [[ $bom == efbbbf ]] || problem "$path: no UTF-8 BOM (Windows PowerShell 5.1 would read it as ANSI)" ;;
      *) [[ $bom != efbbbf ]] || problem "$path: has a UTF-8 BOM (only *.ps1 files have one)" ;;
    esac
  fi
done < <(git ls-files -z --eol)

dups=$(git ls-files | tr '[:upper:]' '[:lower:]' | sort | uniq -d)
[[ -z $dups ]] || problem "paths that differ only by case: $dups"

if ((bad)); then
  echo "line endings: FAIL"
  exit 1
fi
echo "line endings: $n text files ok (CRLF *.bat/*.ps1 with BOM on *.ps1, LF elsewhere)"
