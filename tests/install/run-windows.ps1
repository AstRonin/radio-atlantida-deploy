# Runs the Pester tests of install.ps1 and PSScriptAnalyzer under Windows
# PowerShell 5.1, the PowerShell the station runs (deploy-init-plan.md §1.1,
# D7 9.1 items 8 and 10). Used by the CI job "windows" on a Windows runner;
# tests/install/run.sh runs the same test file and settings with PowerShell 7
# in a Linux container. Pester and PSScriptAnalyzer are pinned to the
# versions of tests/install/Dockerfile.
#
#   powershell.exe -NoProfile -ExecutionPolicy Bypass -File tests\install\run-windows.ps1
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$PesterVersion = '5.7.1'
$AnalyzerVersion = '1.25.0'
$root = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path

Write-Output ('PowerShell {0} ({1})' -f $PSVersionTable.PSVersion, $PSVersionTable.PSEdition)
if ($PSVersionTable.PSVersion.Major -ne 5) { throw 'run this with Windows PowerShell 5.1 (powershell.exe)' }

# PowerShellGet of Windows PowerShell 5.1 needs TLS 1.2 and the NuGet provider.
[Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
if (-not (Get-PackageProvider -ListAvailable -Name NuGet -ErrorAction SilentlyContinue | Where-Object { $_.Version -ge [version]'2.8.5.201' })) {
    Install-PackageProvider -Name NuGet -MinimumVersion 2.8.5.201 -Scope CurrentUser -Force | Out-Null
}
Set-PSRepository -Name PSGallery -InstallationPolicy Trusted
foreach ($m in @(@{ Name = 'Pester'; Version = $PesterVersion }, @{ Name = 'PSScriptAnalyzer'; Version = $AnalyzerVersion })) {
    if (-not (Get-Module -ListAvailable -Name $m.Name | Where-Object { $_.Version -eq [version]$m.Version })) {
        # -SkipPublisherCheck: Windows ships an older Pester signed by another certificate.
        Install-Module -Name $m.Name -RequiredVersion $m.Version -Scope CurrentUser -Force -SkipPublisherCheck -AllowClobber
    }
    Import-Module -Name $m.Name -RequiredVersion $m.Version -Force
}

Set-Location $root
$config = New-PesterConfiguration
$config.Run.Path = 'tests\install'
$config.Run.PassThru = $true
$config.Output.Verbosity = 'Detailed'
$result = Invoke-Pester -Configuration $config
if ($result.FailedCount -gt 0 -or $result.Result -ne 'Passed') { throw ('Pester: {0} failed' -f $result.FailedCount) }

$files = @('install.ps1', 'tests\install\install.Tests.ps1', 'tests\install\run-windows.ps1')
$findings = @(foreach ($f in $files) { Invoke-ScriptAnalyzer -Path $f -Settings 'tests\install\PSScriptAnalyzerSettings.psd1' })
if ($findings.Count -gt 0) {
    $findings | Format-Table -AutoSize -Wrap | Out-String -Width 200 | Write-Output
    throw ('PSScriptAnalyzer: {0} findings' -f $findings.Count)
}
Write-Output 'PSScriptAnalyzer: no findings'
