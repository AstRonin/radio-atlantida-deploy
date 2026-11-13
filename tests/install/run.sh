#!/usr/bin/env bash
# shellcheck disable=SC2016 # the PowerShell commands are single-quoted on purpose
# Runs the Pester tests of install.ps1 and PSScriptAnalyzer on the
# PowerShell files (deploy-init-plan.md D7 9.1 items 8 and 10) in a pinned
# PowerShell 7 image. The Windows-only parts are mocked (see
# install.Tests.ps1); CI on a Windows runner (D7) runs the same tests under
# Windows PowerShell 5.1.
#
#   tests/install/run.sh            Pester and PSScriptAnalyzer
#   tests/install/run.sh --pester   Pester only
set -Eeuo pipefail
root=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
image=radio-deploy-pester:5.7.1
docker build -q --platform linux/amd64 -t "$image" "$root/tests/install" >/dev/null
run() { docker run --rm --platform linux/amd64 -v "$root:/repo:ro" -w /repo "$image" pwsh -NoProfile -NonInteractive -Command "$1"; }
run '$c = New-PesterConfiguration; $c.Run.Path = "tests/install"; $c.Run.Exit = $true; $c.Output.Verbosity = "Detailed"; Invoke-Pester -Configuration $c'
[[ ${1:-} == --pester ]] && exit 0
run '$ErrorActionPreference = "Stop"; $r = @(foreach ($f in "install.ps1", "tests/install/install.Tests.ps1", "tests/install/run-windows.ps1") { Invoke-ScriptAnalyzer -Path $f -Settings tests/install/PSScriptAnalyzerSettings.psd1 }); if ($r.Count) { $r | Format-Table -AutoSize -Wrap | Out-String -Width 200 | Write-Host; exit 1 }; Write-Host "PSScriptAnalyzer: no findings"'
