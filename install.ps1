<#
.SYNOPSIS
    Windows half of the Radio Atlantida host install (deploy-init-plan.md D4,
    6.2). Run through install.bat, signed in as the local account radio.

.DESCRIPTION
    Turns a Windows 10 (build 19044+, Store WSL) or Windows 11 machine into a
    station host: WSL2 and the radio-atlantida distribution with Docker
    Engine, autostart at boot without a sign-in, host settings, and the first
    configuration of the stack (bin/radioctl first-run inside WSL).

    Idempotent and resumable: each finished step is recorded in
    C:\ProgramData\RadioAtlantida\install-state.json, and every step also
    checks the real state before it changes anything. A run writes
    C:\ProgramData\RadioAtlantida\logs\install-YYYY-MM-DDTHHMMSSZ.log.
    Secrets are never printed or logged.

    Windows PowerShell 5.1 (PowerShell 7 is not required). The logic lives
    in small functions; everything that touches Windows (CIM, registry,
    Task Scheduler, Defender, wsl.exe, dism.exe, powercfg.exe, w32tm.exe)
    goes through thin wrappers, so tests/install/install.Tests.ps1 can mock
    them. Statements about Windows behaviour that could not be tested on a
    Mac are marked "(verify on Windows)"; docs/runbook.md section 11 collects
    them in the Windows acceptance checklist.

.PARAMETER DryRun
    Print every step and its check result; change nothing.
.PARAMETER Resume
    Continue after the reboot of the Windows features step (the one-shot
    logon task passes it).
.PARAMETER CreateAccount
    Create the local administrator account radio and stop.
.PARAMETER Yes
    Accept the defaults of the questions (media folder, active hours). Never
    answers a question that interrupts the air.
.PARAMETER InstallRoot
    Folder of the distribution's virtual disk (default C:\RadioAtlantida).
.PARAMETER MediaFolder
    The station's Windows media folder (default: asked, D:\RadioAtlantida\media).
.PARAMETER ActiveHoursStart
    Windows Update active hours start, 0-23 (default: asked, 6).
.PARAMETER ActiveHoursEnd
    Windows Update active hours end, 0-23, 0 = midnight (default: asked, 0).
.PARAMETER AccountName
    The dedicated local account (default radio).
.PARAMETER RepoUrl
    The public deploy repository cloned inside WSL.
.PARAMETER MinFreeGB
    Free space in GB the drive of InstallRoot needs for a first install
    (default 20). A lower value lets a first install continue on purpose, with
    a warning. An existing distribution only warns below it.
.PARAMETER UseLocalVersions
    Install the pins of this copy's install\versions.env even when the deploy
    repository inside the distribution (which update.bat keeps current) has
    other ones. Without it such a difference stops the install.
.PARAMETER Elevated
    Internal: set by the self-elevation, so the elevated window waits for
    Enter before it closes.
#>
[CmdletBinding()]
param(
    [switch]$DryRun,
    [switch]$Resume,
    [switch]$CreateAccount,
    [switch]$Yes,
    [string]$InstallRoot = 'C:\RadioAtlantida',
    [string]$MediaFolder = '',
    [int]$ActiveHoursStart = -1,
    [int]$ActiveHoursEnd = -1,
    [string]$AccountName = 'radio',
    [string]$RepoUrl = 'https://github.com/AstRonin/radio-atlantida-deploy',
    [ValidateRange(1, 100000)][int]$MinFreeGB = 20,
    [switch]$UseLocalVersions,
    [switch]$Elevated
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# ---------------------------------------------------------------------------
# Constants

$script:DistroName = 'radio-atlantida'
$script:KeepAliveTaskName = 'Radio Atlantida WSL'
$script:ResumeTaskName = 'Radio Atlantida install resume'
$script:Features = @('Microsoft-Windows-Subsystem-Linux', 'VirtualMachinePlatform')
# Windows 10 21H2; the Store WSL needs the November 2022 cumulative update
# (19044.2311 / 19045.2311) or later (plan 6.1).
$script:MinBuild = 19044
$script:MinWin10Ubr = 2311
$script:Win11Build = 22000
# Windows 11 22H2: mirrored networking (plan 6.5).
$script:MirroredBuild = 22621
# Free space on the drive of the distribution's virtual disk: Docker images
# (two releases during an update), the database, the journal, and the
# backups (14 daily and 14 update dumps, 3 boundary dumps, journal copies)
# live there; the media folder does not (it stays on Windows, 6.6). About
# 15-20 GB is really used; 20 GB is the minimum, more is recommended for
# growth. -MinFreeGB overrides it (a lower value warns).
$script:DefaultMinFreeGB = 20
$script:MinRamGB = 16
# The WSL VM's memory (.wslconfig, plan 6.4): half the RAM, at least 4 GB,
# at most 16 GB (8 GB on a 16 GB machine).
$script:VmMemoryMinGB = 4
$script:VmMemoryMaxGB = 16
$script:DefaultMediaFolder = 'D:\RadioAtlantida\media'
# BACKUP_WINDOWS_COPY of .env.example (/mnt/c/RadioAtlantida/backups).
$script:WindowsBackupDir = 'C:\RadioAtlantida\backups'
$script:LinuxSrcDir = '/var/lib/radio-atlantida/src'
$script:LinuxDeployDir = '/opt/radio-atlantida/deploy'
$script:NtpPeers = 'time.windows.com,0x9 pool.ntp.org,0x9'
$script:MaxActiveHours = 18
$script:ReachableUrls = @(
    'https://cloud-images.ubuntu.com/',
    'https://download.docker.com/',
    'https://ghcr.io/',
    'https://github.com/'
)

# The run's context: options, paths, state, facts. Initialize-Context fills it.
$script:Ctx = @{}

# ---------------------------------------------------------------------------
# Output and logging

function Write-InstallLog {
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Message)
    $file = $script:Ctx['LogFile']
    if (-not $file) { return }
    $line = '{0} {1}{2}' -f (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ'), $Message, [Environment]::NewLine
    [System.IO.File]::AppendAllText($file, $line, (New-Object System.Text.UTF8Encoding($false)))
}

function Write-Info {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingWriteHost', '',
        Justification = 'An interactive installer: the operator reads the console.')]
    param([AllowEmptyString()][string]$Message = '')
    Write-Host $Message
    Write-InstallLog $Message
}

function Write-Warn {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingWriteHost', '',
        Justification = 'An interactive installer: the operator reads the console.')]
    param([Parameter(Mandatory)][string]$Message)
    Write-Host ('WARNING: ' + $Message) -ForegroundColor Yellow
    Write-InstallLog ('WARNING: ' + $Message)
}

function Write-StepTitle {
    param([Parameter(Mandatory)][string]$Title)
    Write-Info ''
    Write-Info ('==> ' + $Title)
}

# Stop-Install: a planned stop with a message for the operator (exit 1).
function Stop-Install {
    param([Parameter(Mandatory)][string]$Message)
    $ex = New-Object System.Exception $Message
    $ex.Data['RadioStop'] = $true
    throw $ex
}

# ---------------------------------------------------------------------------
# Pure logic (tested by tests/install/install.Tests.ps1)

# ConvertTo-WslPath 'D:\Radio Atlantida\media' -> '/mnt/d/Radio Atlantida/media'
# (wsl.conf: automount root /mnt/). Drive-letter paths only.
function ConvertTo-WslPath {
    param([Parameter(Mandatory)][string]$WindowsPath)
    if ($WindowsPath -notmatch '^([A-Za-z]):(\\.*)?$') {
        throw "not an absolute path with a drive letter: $WindowsPath"
    }
    $drive = $Matches[1].ToLowerInvariant()
    $rest = ''
    if ($Matches.Count -gt 2 -and $Matches[2]) { $rest = $Matches[2] }
    $rest = $rest.TrimEnd('\').Replace('\', '/')
    return ('/mnt/' + $drive + $rest)
}

# Get-NetworkMode: mirrored on Windows 11 22H2+ (22621), NAT otherwise.
function Get-NetworkMode {
    param([Parameter(Mandatory)][int]$Build)
    if ($Build -ge $script:MirroredBuild) { return 'mirrored' }
    return 'nat'
}

# Test-WindowsBuild: $null when supported, else the reason.
function Test-WindowsBuild {
    param([Parameter(Mandatory)][int]$Build, [int]$Ubr = 0)
    if ($Build -lt $script:MinBuild) {
        return "Windows build $Build is too old: Windows 10 21H2 (build 19044) or later, or Windows 11, is required."
    }
    if ($Build -lt $script:Win11Build -and $Ubr -lt $script:MinWin10Ubr) {
        return "Windows 10 build $Build.$Ubr lacks the update level the Store WSL needs ($Build.$($script:MinWin10Ubr) or later): install the cumulative updates first."
    }
    return $null
}

# ConvertTo-FourPartVersion: '2.4.4' -> [version]'2.4.4.0'.
function ConvertTo-FourPartVersion {
    param([Parameter(Mandatory)][string]$Version)
    $parts = @($Version.Split('.') | ForEach-Object { [int]$_ })
    while ($parts.Count -lt 4) { $parts += 0 }
    return New-Object System.Version($parts[0], $parts[1], $parts[2], $parts[3])
}

function Compare-VersionString {
    param([Parameter(Mandatory)][string]$Left, [Parameter(Mandatory)][string]$Right)
    return (ConvertTo-FourPartVersion $Left).CompareTo((ConvertTo-FourPartVersion $Right))
}

# ConvertFrom-WslVersionOutput: the WSL version from `wsl --version` (first
# line, "WSL version: 2.4.4.0", localized label), or $null.
function ConvertFrom-WslVersionOutput {
    param([AllowEmptyCollection()][string[]]$Lines = @())
    foreach ($line in $Lines) {
        $clean = ($line -replace "`0", '').Trim()
        if (-not $clean) { continue }
        if ($clean -match '(\d+\.\d+\.\d+(\.\d+)?)') { return $Matches[1] }
        return $null
    }
    return $null
}

# ConvertFrom-DistroList: names from `wsl -l -q`.
function ConvertFrom-DistroList {
    param([AllowEmptyCollection()][string[]]$Lines = @())
    $names = @()
    foreach ($line in $Lines) {
        $clean = ($line -replace "`0", '').Trim()
        if ($clean) { $names += $clean }
    }
    return , $names
}

# ConvertFrom-KeyValueText: KEY=VALUE lines (install/versions.env); comments
# and blank lines skipped. Parsed, never executed.
function ConvertFrom-KeyValueText {
    param([AllowEmptyCollection()][string[]]$Lines = @())
    $map = @{}
    foreach ($line in $Lines) {
        if ($line -match '^\s*([A-Za-z_][A-Za-z0-9_]*)=(.*)$') {
            $map[$Matches[1]] = $Matches[2].Trim()
        }
    }
    return $map
}

# Compare-VersionsMap: the keys (sorted) whose values differ between two
# parsed versions.env files; a key missing on one side counts as different.
function Compare-VersionsMap {
    param([Parameter(Mandatory)][hashtable]$Windows, [Parameter(Mandatory)][hashtable]$Distro)
    $keys = @(@($Windows.Keys) + @($Distro.Keys) | Sort-Object -Unique)
    $diff = @()
    foreach ($k in $keys) {
        if (-not $Windows.ContainsKey($k) -or -not $Distro.ContainsKey($k) -or [string]$Windows[$k] -cne [string]$Distro[$k]) { $diff += $k }
    }
    return , $diff
}

# Get-VmMemoryGB: the WSL VM's memory for a machine with $RamGB of RAM: half
# of it, within VmMemoryMinGB..VmMemoryMaxGB.
function Get-VmMemoryGB {
    param([Parameter(Mandatory)][int]$RamGB)
    $half = [int][Math]::Floor($RamGB / 2)
    return [Math]::Min($script:VmMemoryMaxGB, [Math]::Max($script:VmMemoryMinGB, $half))
}

# Get-WslConfigSettings: the [wsl2] keys of %UserProfile%\.wslconfig for a
# network mode and machine (plan 6.4, 6.5): keys to set and keys to remove.
function Get-WslConfigSettings {
    param([Parameter(Mandatory)][ValidateSet('nat', 'mirrored')][string]$Mode,
        [Parameter(Mandatory)][int]$LogicalProcessors,
        [Parameter(Mandatory)][int]$RamGB)
    $processors = [Math]::Max(2, [Math]::Floor($LogicalProcessors / 2))
    $set = [ordered]@{
        'memory'        = ('{0}GB' -f (Get-VmMemoryGB -RamGB $RamGB))
        'processors'    = [string]$processors
        'swap'          = '4GB'
        # WSL 2.x: the VM is not stopped after the last distribution stops
        # (the keep-alive keeps the distribution itself running; 6.4).
        'vmIdleTimeout' = '-1'
    }
    $remove = @()
    if ($Mode -eq 'mirrored') {
        $set['networkingMode'] = 'mirrored'
        # Ignored in mirrored mode (WSL warns about it at every start).
        $remove += 'localhostForwarding'
    }
    else {
        # NAT is the default mode; the key is not written on Windows 10,
        # where the Store WSL may not know it (verify on Windows).
        $set['localhostForwarding'] = 'true'
        $remove += 'networkingMode'
    }
    return @{ Set = $set; Remove = $remove }
}

# Merge-WslConfig: the .wslconfig text with the keys of one section set or
# removed; other sections, unknown keys, and comments are kept.
function Merge-WslConfig {
    param([AllowEmptyString()][string]$Text = '',
        [Parameter(Mandatory)][System.Collections.IDictionary]$Set,
        [string[]]$Remove = @(),
        [string]$Section = 'wsl2')
    $lines = @()
    if ($Text) { $lines = @($Text -split "\r?\n") }
    if ($lines.Count -gt 0 -and $lines[-1] -eq '') { $lines = @($lines | Select-Object -First ($lines.Count - 1)) }
    $out = New-Object System.Collections.Generic.List[string]
    $pending = [ordered]@{}
    foreach ($k in $Set.Keys) { $pending[$k] = $Set[$k] }
    $inSection = $false
    $sectionSeen = $false
    $flush = {
        foreach ($k in @($pending.Keys)) { $out.Add(('{0}={1}' -f $k, $pending[$k])) }
        $pending.Clear()
    }
    foreach ($line in $lines) {
        if ($line -match '^\s*\[([^\]]+)\]\s*$') {
            if ($inSection) { & $flush }
            $inSection = ($Matches[1].Trim() -ieq $Section)
            if ($inSection) { $sectionSeen = $true }
            $out.Add($line)
            continue
        }
        if ($inSection -and $line -match '^\s*([A-Za-z0-9_.]+)\s*=') {
            $key = $Matches[1]
            $match = @($pending.Keys | Where-Object { $_ -ieq $key })
            if ($match.Count -gt 0) {
                $out.Add(('{0}={1}' -f $match[0], $pending[$match[0]]))
                $pending.Remove($match[0])
                continue
            }
            if (@($Remove | Where-Object { $_ -ieq $key }).Count -gt 0) { continue }
        }
        $out.Add($line)
    }
    if ($inSection) { & $flush }
    if (-not $sectionSeen) {
        if ($out.Count -gt 0 -and $out[$out.Count - 1] -ne '') { $out.Add('') }
        $out.Add('[' + $Section + ']')
        & $flush
    }
    return (($out -join "`r`n") + "`r`n")
}

# Get-ActiveHoursSpan: hours from start to end (end 0 = midnight).
function Get-ActiveHoursSpan {
    param([Parameter(Mandatory)][int]$Start, [Parameter(Mandatory)][int]$End)
    $span = ($End - $Start + 24) % 24
    if ($span -eq 0) { $span = 24 }
    return $span
}

# Test-ActiveHours: $null when valid, else the reason. Windows allows at most
# 18 hours (plan 6.7).
function Test-ActiveHours {
    param([Parameter(Mandatory)][int]$Start, [Parameter(Mandatory)][int]$End)
    if ($Start -lt 0 -or $Start -gt 23 -or $End -lt 0 -or $End -gt 23) {
        return 'active hours are whole hours from 0 to 23 (end 0 = midnight)'
    }
    $span = Get-ActiveHoursSpan -Start $Start -End $End
    if ($span -gt $script:MaxActiveHours) {
        return "active hours $Start-$End span $span hours; Windows allows at most $($script:MaxActiveHours)"
    }
    return $null
}

# Test-MediaFolderFacts: $null when the folder may be the media root, else the
# reason. $Drive: @{ DriveType; DriveFormat; BusType } of its drive, or $null.
function Test-MediaFolderFacts {
    param([Parameter(Mandatory)][string]$Path, $Drive, [bool]$Exists)
    if ($Path.StartsWith('\\')) { return "$Path is a network share; the media folder must be on a local NTFS drive" }
    if ($Path -notmatch '^[A-Za-z]:\\') { return "$Path is not an absolute path with a drive letter" }
    $letter = $Path.Substring(0, 1).ToUpperInvariant()
    if ($null -eq $Drive) { return "drive ${letter}: does not exist" }
    if ($Drive.DriveType -eq 'Network') { return "drive ${letter}: is a network drive; the media folder must be on a local NTFS drive" }
    if ($Drive.DriveType -eq 'Removable') { return "drive ${letter}: is removable; the media folder must be on a fixed local drive" }
    if ($Drive.DriveType -ne 'Fixed') { return "drive ${letter}: is of type $($Drive.DriveType); the media folder must be on a fixed local drive" }
    if ($Drive.BusType -eq 'USB') { return "drive ${letter}: is an external USB disk; the media folder must be on an internal drive" }
    if ($Drive.DriveFormat -ne 'NTFS') { return "drive ${letter}: is $($Drive.DriveFormat), not NTFS" }
    if (-not $Exists) { return "$Path does not exist; create it or choose the station's existing media folder" }
    return $null
}

# Get-PatchReport: the lines logged about the edition and patch level
# (plan 6.2 step 1, 11.17), and the warnings. Never a stop.
function Get-PatchReport {
    param([Parameter(Mandatory)]$Os, [Parameter(Mandatory)]$Updates, [Parameter(Mandatory)][datetime]$Now)
    $lines = @()
    $warnings = @()
    $lines += ('Windows: {0} ({1}), build {2}.{3}, version {4}' -f $Os.Caption, $Os.Edition, $Os.Build, $Os.Ubr, $Os.DisplayVersion)
    if ($Updates.NewestKb) {
        $lines += ('Newest installed update: {0}, installed {1}' -f $Updates.NewestKb, $Updates.NewestDate.ToString('yyyy-MM-dd'))
        $age = [int]($Now - $Updates.NewestDate).TotalDays
        if ($age -gt 90) {
            $warnings += "the newest installed update is $age days old; the machine gets no security fixes (accepted, plan 11.17)"
        }
    }
    else {
        $lines += 'Newest installed update: none found'
        $warnings += 'no installed update was found'
    }
    $lines += ('Extended Security Updates (ESU): {0}' -f $Updates.Esu)
    if ($Os.Build -lt $script:Win11Build -and $Updates.Esu -like 'enrolled*') {
        $warnings += 'ESU is enrolled: updates and their reboots resume; use "Pause updates" and install updates by hand in a maintenance window (runbook)'
    }
    return @{ Lines = $lines; Warnings = $warnings }
}

function Get-SupportNote {
    return @(
        'Windows 10 reached end of support on 14 October 2025; without ESU this machine gets no more',
        'security fixes (Defender signatures still update). The station exposes no inbound port. Do not',
        'use this machine for email or browsing. An upgrade to Windows 11 is recommended later; install.bat',
        'then switches to mirrored networking by itself.'
    )
}

function ConvertTo-XmlText {
    param([AllowEmptyString()][string]$Text)
    return [System.Security.SecurityElement]::Escape($Text)
}

# New-KeepAliveTaskXml: the task "Radio Atlantida WSL" (plan 6.4): at boot and
# every 5 minutes, as the radio account whether logged on or not (password
# stored by Task Scheduler), not elevated, no time limit, restart on failure
# every minute, no second instance, also on battery.
function New-KeepAliveTaskXml {
    param([Parameter(Mandatory)][string]$UserId, [Parameter(Mandatory)][string]$WslExe)
    $taskArgs = '-d {0} -u radio --exec /usr/local/bin/radio-keepalive' -f $script:DistroName
    return @"
<?xml version="1.0" encoding="UTF-16"?>
<Task version="1.4" xmlns="http://schemas.microsoft.com/windows/2004/02/mit/task">
  <RegistrationInfo>
    <Description>Starts the WSL distribution radio-atlantida at boot and keeps it running (Radio Atlantida, install.bat).</Description>
  </RegistrationInfo>
  <Triggers>
    <BootTrigger>
      <Repetition>
        <Interval>PT5M</Interval>
        <StopAtDurationEnd>false</StopAtDurationEnd>
      </Repetition>
      <Enabled>true</Enabled>
    </BootTrigger>
  </Triggers>
  <Principals>
    <Principal id="Author">
      <UserId>$(ConvertTo-XmlText $UserId)</UserId>
      <LogonType>Password</LogonType>
      <RunLevel>LeastPrivilege</RunLevel>
    </Principal>
  </Principals>
  <Settings>
    <MultipleInstancesPolicy>IgnoreNew</MultipleInstancesPolicy>
    <DisallowStartIfOnBatteries>false</DisallowStartIfOnBatteries>
    <StopIfGoingOnBatteries>false</StopIfGoingOnBatteries>
    <AllowHardTerminate>true</AllowHardTerminate>
    <StartWhenAvailable>true</StartWhenAvailable>
    <RunOnlyIfNetworkAvailable>false</RunOnlyIfNetworkAvailable>
    <IdleSettings>
      <StopOnIdleEnd>false</StopOnIdleEnd>
      <RestartOnIdle>false</RestartOnIdle>
    </IdleSettings>
    <AllowStartOnDemand>true</AllowStartOnDemand>
    <Enabled>true</Enabled>
    <Hidden>false</Hidden>
    <RunOnlyIfIdle>false</RunOnlyIfIdle>
    <WakeToRun>false</WakeToRun>
    <ExecutionTimeLimit>PT0S</ExecutionTimeLimit>
    <Priority>7</Priority>
    <RestartOnFailure>
      <Interval>PT1M</Interval>
      <Count>999</Count>
    </RestartOnFailure>
  </Settings>
  <Actions Context="Author">
    <Exec>
      <Command>$(ConvertTo-XmlText $WslExe)</Command>
      <Arguments>$(ConvertTo-XmlText $taskArgs)</Arguments>
    </Exec>
  </Actions>
</Task>
"@
}

# Test-KeepAliveTaskXml: whether a registered task (Export-ScheduledTask) is
# the keep-alive task of New-KeepAliveTaskXml.
function Test-KeepAliveTaskXml {
    param([AllowEmptyString()][string]$Xml)
    if (-not $Xml) { return $false }
    try { $x = [xml]$Xml } catch { return $false }
    $t = $x.DocumentElement
    try {
        $exec = $t.Actions.Exec
        $boot = $t.Triggers.BootTrigger
        return ($exec.Command -like '*wsl.exe') -and
            ($exec.Arguments -eq ('-d {0} -u radio --exec /usr/local/bin/radio-keepalive' -f $script:DistroName)) -and
            ($null -ne $boot) -and ($boot.Repetition.Interval -eq 'PT5M') -and
            ($t.Principals.Principal.LogonType -eq 'Password') -and
            ($t.Settings.ExecutionTimeLimit -eq 'PT0S') -and
            ($t.Settings.MultipleInstancesPolicy -eq 'IgnoreNew')
    }
    catch { return $false }
}

# New-ResumeTaskXml: the one-shot task "at logon of radio, highest
# privileges" that continues the install after the features reboot (a
# RunOnce entry would not run elevated). install.ps1 deletes it when the
# install continues.
function New-ResumeTaskXml {
    param([Parameter(Mandatory)][string]$UserId, [Parameter(Mandatory)][string]$Command, [Parameter(Mandatory)][string]$Arguments)
    return @"
<?xml version="1.0" encoding="UTF-16"?>
<Task version="1.4" xmlns="http://schemas.microsoft.com/windows/2004/02/mit/task">
  <RegistrationInfo>
    <Description>Continues the Radio Atlantida install after the reboot (deleted when it continues).</Description>
  </RegistrationInfo>
  <Triggers>
    <LogonTrigger>
      <Enabled>true</Enabled>
      <UserId>$(ConvertTo-XmlText $UserId)</UserId>
    </LogonTrigger>
  </Triggers>
  <Principals>
    <Principal id="Author">
      <UserId>$(ConvertTo-XmlText $UserId)</UserId>
      <LogonType>InteractiveToken</LogonType>
      <RunLevel>HighestAvailable</RunLevel>
    </Principal>
  </Principals>
  <Settings>
    <MultipleInstancesPolicy>IgnoreNew</MultipleInstancesPolicy>
    <DisallowStartIfOnBatteries>false</DisallowStartIfOnBatteries>
    <StopIfGoingOnBatteries>false</StopIfGoingOnBatteries>
    <ExecutionTimeLimit>PT0S</ExecutionTimeLimit>
    <Enabled>true</Enabled>
  </Settings>
  <Actions Context="Author">
    <Exec>
      <Command>$(ConvertTo-XmlText $Command)</Command>
      <Arguments>$(ConvertTo-XmlText $Arguments)</Arguments>
    </Exec>
  </Actions>
</Task>
"@
}

# ConvertTo-CommandLineArgument: one argument quoted for a Windows command
# line (the C runtime rules that wsl.exe uses to split it).
function ConvertTo-CommandLineArgument {
    param([AllowEmptyString()][string]$Argument)
    if ($Argument -ne '' -and $Argument -notmatch '[\s"]') { return $Argument }
    $sb = New-Object System.Text.StringBuilder
    [void]$sb.Append('"')
    $backslashes = 0
    foreach ($ch in $Argument.ToCharArray()) {
        if ($ch -eq '\') { $backslashes++; continue }
        if ($ch -eq '"') {
            [void]$sb.Append([char]'\', 2 * $backslashes + 1)
            [void]$sb.Append('"')
        }
        else {
            if ($backslashes -gt 0) { [void]$sb.Append([char]'\', $backslashes) }
            [void]$sb.Append($ch)
        }
        $backslashes = 0
    }
    if ($backslashes -gt 0) { [void]$sb.Append([char]'\', 2 * $backslashes) }
    [void]$sb.Append('"')
    return $sb.ToString()
}

function ConvertTo-CommandLine {
    param([AllowEmptyCollection()][string[]]$ArgumentList = @())
    return (($ArgumentList | ForEach-Object { ConvertTo-CommandLineArgument $_ }) -join ' ')
}

function New-InternetShortcutText {
    param([Parameter(Mandatory)][string]$Url)
    return "[InternetShortcut]`r`nURL=$Url`r`n"
}

# Get-ForwardedArguments: the bound parameters as a command line for the
# elevated or resumed instance.
function Get-ForwardedArguments {
    param([Parameter(Mandatory)][System.Collections.IDictionary]$Bound)
    $out = @()
    foreach ($k in $Bound.Keys) {
        $v = $Bound[$k]
        if ($v -is [System.Management.Automation.SwitchParameter]) {
            if ($v.IsPresent) { $out += "-$k" }
        }
        elseif ($v -is [bool]) {
            if ($v) { $out += "-$k" }
        }
        else {
            $out += "-$k"
            $out += ('"{0}"' -f ([string]$v).Replace('"', ''))
        }
    }
    return , $out
}

# ---------------------------------------------------------------------------
# Thin wrappers around Windows (mocked by the tests; not run on Linux)

function Invoke-Native {
    param([Parameter(Mandatory)][string]$FilePath, [string[]]$ArgumentList = @(), [switch]$Interactive, [switch]$Echo)
    Write-InstallLog ('+ {0} {1}' -f $FilePath, ($ArgumentList -join ' '))
    $out = @()
    $code = 0
    $previous = $ErrorActionPreference
    # Windows PowerShell 5.1 turns native stderr into terminating errors
    # under 'Stop' when it is redirected.
    $ErrorActionPreference = 'Continue'
    try {
        if ($Interactive) {
            # The child gets this console directly (a pipeline would hold
            # back prompts that end without a newline).
            $psi = New-Object System.Diagnostics.ProcessStartInfo
            $psi.FileName = $FilePath
            $psi.Arguments = ConvertTo-CommandLine $ArgumentList
            $psi.UseShellExecute = $false
            $proc = [System.Diagnostics.Process]::Start($psi)
            $proc.WaitForExit()
            $code = $proc.ExitCode
        }
        else {
            $out = @(& $FilePath @ArgumentList 2>&1 | ForEach-Object {
                    $line = ([string]$_) -replace "`0", ''
                    if ($Echo) { Write-Info ('    ' + $line) }
                    $line
                })
            $code = $LASTEXITCODE
        }
    }
    catch {
        $out = @([string]$_)
        $code = -1
    }
    finally {
        $ErrorActionPreference = $previous
    }
    if (-not $Echo) { foreach ($l in $out) { Write-InstallLog ('    ' + $l) } }
    Write-InstallLog ('    exit ' + $code)
    return [pscustomobject]@{ ExitCode = $code; Output = $out }
}

function Get-WslExe {
    return (Join-Path $env:SystemRoot 'System32\wsl.exe')
}

function Get-CmdExe {
    return (Join-Path $env:SystemRoot 'System32\cmd.exe')
}

# Get-RepoWslPath: this checkout (where install.bat runs from) as WSL sees it.
function Get-RepoWslPath {
    return (ConvertTo-WslPath $script:Ctx.RepoRoot)
}

function Invoke-Wsl {
    param([string[]]$ArgumentList = @(), [switch]$Interactive, [switch]$Echo)
    return Invoke-Native -FilePath (Get-WslExe) -ArgumentList $ArgumentList -Interactive:$Interactive -Echo:$Echo
}

function Get-OsFacts {
    $os = Get-CimInstance -ClassName Win32_OperatingSystem
    $cv = Get-ItemProperty -Path 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion'
    $display = ''
    if ($cv.PSObject.Properties['DisplayVersion']) { $display = $cv.DisplayVersion }
    elseif ($cv.PSObject.Properties['ReleaseId']) { $display = $cv.ReleaseId }
    return [pscustomobject]@{
        Caption        = $os.Caption
        Build          = [int]$os.BuildNumber
        Ubr            = [int]$cv.UBR
        Edition        = $cv.EditionID
        DisplayVersion = $display
        Architecture   = $env:PROCESSOR_ARCHITECTURE
    }
}

function Get-HardwareFacts {
    $cs = Get-CimInstance -ClassName Win32_ComputerSystem
    $cpu = @(Get-CimInstance -ClassName Win32_Processor)[0]
    return [pscustomobject]@{
        HypervisorPresent             = [bool]$cs.HypervisorPresent
        VirtualizationFirmwareEnabled = [bool]$cpu.VirtualizationFirmwareEnabled
        RamGB                         = [Math]::Round($cs.TotalPhysicalMemory / 1GB)
        LogicalProcessors             = [int]$cs.NumberOfLogicalProcessors
    }
}

# Get-UpdateFacts: the newest installed update and the ESU status. ESU is
# detected from an activated ESU license (SoftwareLicensingProduct); the
# consumer ESU enrolment may not show there (verify on Windows).
function Get-UpdateFacts {
    $newest = Get-HotFix | Where-Object { $_.InstalledOn } | Sort-Object -Property InstalledOn -Descending | Select-Object -First 1
    $esu = 'not detected'
    try {
        $lic = @(Get-CimInstance -ClassName SoftwareLicensingProduct -Filter "Name LIKE '%ESU%' AND LicenseStatus = 1")
        if ($lic.Count -gt 0) { $esu = 'enrolled (' + $lic[0].Name + ')' }
    }
    catch { $esu = 'unknown (the license query failed)' }
    $kb = $null
    $date = [datetime]::MinValue
    if ($newest) { $kb = $newest.HotFixID; $date = [datetime]$newest.InstalledOn }
    return [pscustomobject]@{ NewestKb = $kb; NewestDate = $date; Esu = $esu }
}

function Test-Administrator {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    return (New-Object Security.Principal.WindowsPrincipal($id)).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Get-CurrentAccountName { return $env:USERNAME }

function Test-LocalAccount {
    param([Parameter(Mandatory)][string]$Name)
    return [bool](Get-LocalUser -Name $Name -ErrorAction SilentlyContinue)
}

function New-LocalAdminAccount {
    param([Parameter(Mandatory)][string]$Name, [Parameter(Mandatory)][securestring]$Password)
    New-LocalUser -Name $Name -Password $Password -PasswordNeverExpires -AccountNeverExpires `
        -FullName 'Radio Atlantida' -Description 'Radio Atlantida station account (install.bat)' | Out-Null
    # S-1-5-32-544: the local Administrators group under any display language.
    Add-LocalGroupMember -SID 'S-1-5-32-544' -Member $Name
}

function Test-DockerDesktop {
    $keys = @('HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*',
        'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*')
    $found = @(Get-ItemProperty -Path $keys -ErrorAction SilentlyContinue |
            Where-Object { $_.PSObject.Properties['DisplayName'] -and $_.DisplayName -like 'Docker Desktop*' })
    return ($found.Count -gt 0) -or (Test-Path (Join-Path $env:ProgramFiles 'Docker\Docker\Docker Desktop.exe'))
}

function Get-FreeSpaceGB {
    param([Parameter(Mandatory)][string]$Path)
    $drive = New-Object System.IO.DriveInfo($Path.Substring(0, 1))
    return [Math]::Floor($drive.AvailableFreeSpace / 1GB)
}

function Test-UrlReachable {
    param([Parameter(Mandatory)][string]$Url)
    try {
        Invoke-WebRequest -Uri $Url -Method Head -UseBasicParsing -TimeoutSec 20 | Out-Null
        return $true
    }
    catch {
        # An HTTP error status still proves the host answers.
        return ($null -ne $_.Exception.PSObject.Properties['Response'] -and $null -ne $_.Exception.Response)
    }
}

function Get-FeatureState {
    param([Parameter(Mandatory)][string]$Name)
    return [string](Get-WindowsOptionalFeature -Online -FeatureName $Name).State
}

function Get-DriveFacts {
    param([Parameter(Mandatory)][string]$Letter)
    $info = New-Object System.IO.DriveInfo($Letter)
    if (-not $info.IsReady -and [string]$info.DriveType -eq 'NoRootDirectory') { return $null }
    $bus = ''
    try { $bus = [string](Get-Partition -DriveLetter $Letter -ErrorAction Stop | Get-Disk).BusType } catch { $bus = '' }
    $format = ''
    if ($info.IsReady) { $format = $info.DriveFormat }
    return [pscustomobject]@{ DriveType = [string]$info.DriveType; DriveFormat = $format; BusType = $bus }
}

function Test-FolderExists {
    param([Parameter(Mandatory)][string]$Path)
    return (Test-Path -LiteralPath $Path -PathType Container)
}

function New-Folder {
    param([Parameter(Mandatory)][string]$Path)
    New-Item -ItemType Directory -Path $Path -Force | Out-Null
}

# Defender: $null when Defender is not available (another antivirus).
function Get-DefenderExclusions {
    try { return @((Get-MpPreference -ErrorAction Stop).ExclusionPath | Where-Object { $_ }) }
    catch { return $null }
}

function Add-DefenderExclusion {
    param([Parameter(Mandatory)][string]$Path)
    Add-MpPreference -ExclusionPath $Path
}

function Test-FolderNotIndexed {
    param([Parameter(Mandatory)][string]$Path)
    $attr = (Get-Item -LiteralPath $Path -Force).Attributes
    return (($attr -band [System.IO.FileAttributes]::NotContentIndexed) -ne 0)
}

# Set-FolderNotIndexed: "Allow files in this folder to have contents
# indexed" off for the folder and everything in it.
function Set-FolderNotIndexed {
    param([Parameter(Mandatory)][string]$Path)
    $items = @(Get-Item -LiteralPath $Path -Force) + @(Get-ChildItem -LiteralPath $Path -Recurse -Force -ErrorAction SilentlyContinue)
    foreach ($i in $items) {
        $i.Attributes = $i.Attributes -bor [System.IO.FileAttributes]::NotContentIndexed
    }
}

function Get-RegistryValue {
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)][string]$Name)
    $p = Get-ItemProperty -Path $Path -Name $Name -ErrorAction SilentlyContinue
    if ($null -eq $p) { return $null }
    return $p.$Name
}

function Set-RegistryValue {
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)][string]$Name, [Parameter(Mandatory)]$Value,
        [string]$Type = 'DWord')
    if (-not (Test-Path $Path)) { New-Item -Path $Path -Force | Out-Null }
    New-ItemProperty -Path $Path -Name $Name -Value $Value -PropertyType $Type -Force | Out-Null
}

function Set-TimeServiceAutomatic {
    Set-Service -Name W32Time -StartupType Automatic
    Start-Service -Name W32Time
}

function Get-ScheduledTaskXml {
    param([Parameter(Mandatory)][string]$Name)
    try { return [string](Export-ScheduledTask -TaskName $Name -ErrorAction Stop) }
    catch { return $null }
}

function Register-TaskFromXml {
    param([Parameter(Mandatory)][string]$Name, [Parameter(Mandatory)][string]$Xml, [string]$User = '', [securestring]$Password = $null)
    if ($null -ne $Password) {
        # Plain text only for the call itself; never stored or logged.
        Register-ScheduledTask -TaskName $Name -Xml $Xml -User $User -Password (ConvertFrom-SecureStringToPlain $Password) -Force | Out-Null
    }
    else {
        Register-ScheduledTask -TaskName $Name -Xml $Xml -Force | Out-Null
    }
}

function Remove-ScheduledTaskByName {
    param([Parameter(Mandatory)][string]$Name)
    Unregister-ScheduledTask -TaskName $Name -Confirm:$false -ErrorAction SilentlyContinue
}

function Start-ScheduledTaskByName {
    param([Parameter(Mandatory)][string]$Name)
    Start-ScheduledTask -TaskName $Name
}

function Read-Secret {
    param([Parameter(Mandatory)][string]$Prompt)
    return (Read-Host -Prompt $Prompt -AsSecureString)
}

function ConvertFrom-SecureStringToPlain {
    param([Parameter(Mandatory)][securestring]$Secure)
    $ptr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($Secure)
    try { return [Runtime.InteropServices.Marshal]::PtrToStringBSTR($ptr) }
    finally { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($ptr) }
}

function Read-Answer {
    param([Parameter(Mandatory)][string]$Prompt, [string]$Default = '')
    $a = Read-Host -Prompt ('{0} [{1}]' -f $Prompt, $Default)
    if (-not $a) { return $Default }
    return $a.Trim()
}

function Confirm-Action {
    param([Parameter(Mandatory)][string]$Prompt)
    $a = Read-Host -Prompt ($Prompt + ' Type yes to continue')
    return ($a -eq 'yes')
}

function Restart-Host { Restart-Computer -Force }

function New-ShellShortcut {
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)][string]$Target, [string]$WorkingDirectory = '')
    $shell = New-Object -ComObject WScript.Shell
    $lnk = $shell.CreateShortcut($Path)
    $lnk.TargetPath = $Target
    if ($WorkingDirectory) { $lnk.WorkingDirectory = $WorkingDirectory }
    $lnk.Save()
}

function Save-Download {
    param([Parameter(Mandatory)][string]$Url, [Parameter(Mandatory)][string]$Path)
    $previous = $ProgressPreference
    $ProgressPreference = 'SilentlyContinue'
    try { Invoke-WebRequest -Uri $Url -OutFile $Path -UseBasicParsing }
    finally { $ProgressPreference = $previous }
}

function Get-FileSha256 {
    param([Parameter(Mandatory)][string]$Path)
    return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()
}

function Start-Elevated {
    param([Parameter(Mandatory)][string]$ScriptPath, [string[]]$Arguments = @())
    $argList = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', ('"{0}"' -f $ScriptPath)) + $Arguments + @('-Elevated')
    $p = Start-Process -FilePath 'powershell.exe' -ArgumentList $argList -Verb RunAs -Wait -PassThru
    return $p.ExitCode
}

# ---------------------------------------------------------------------------
# Context and state

function Write-TextFile {
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)][AllowEmptyString()][string]$Text)
    $dir = Split-Path -Parent $Path
    if ($dir -and -not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    [System.IO.File]::WriteAllText($Path, $Text, (New-Object System.Text.UTF8Encoding($false)))
}

function Read-TextFile {
    param([Parameter(Mandatory)][string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) { return '' }
    return [System.IO.File]::ReadAllText($Path)
}

function ConvertTo-PlainHashtable {
    param($Object)
    if ($null -eq $Object) { return $null }
    if ($Object -is [System.Management.Automation.PSCustomObject]) {
        $h = @{}
        foreach ($p in $Object.PSObject.Properties) { $h[$p.Name] = ConvertTo-PlainHashtable $p.Value }
        return $h
    }
    if ($Object -is [System.Collections.IEnumerable] -and $Object -isnot [string]) {
        return , @($Object | ForEach-Object { ConvertTo-PlainHashtable $_ })
    }
    return $Object
}

function Read-InstallState {
    $file = $script:Ctx.StateFile
    $state = @{ schema = 1; steps = @{}; values = @{} }
    if (Test-Path -LiteralPath $file) {
        $loaded = ConvertTo-PlainHashtable ((Read-TextFile $file) | ConvertFrom-Json)
        if ($loaded) {
            if ($loaded['steps']) { $state.steps = $loaded['steps'] }
            if ($loaded['values']) { $state.values = $loaded['values'] }
        }
    }
    return $state
}

function Save-InstallState {
    if ($script:Ctx.DryRun) { return }
    Write-TextFile -Path $script:Ctx.StateFile -Text ($script:Ctx.State | ConvertTo-Json -Depth 6)
}

function Set-StateValue {
    param([Parameter(Mandatory)][string]$Name, $Value)
    $script:Ctx.State.values[$Name] = $Value
    Save-InstallState
}

function Get-StateValue {
    param([Parameter(Mandatory)][string]$Name)
    return $script:Ctx.State.values[$Name]
}

# Initialize-Context: options from the parameters; $Overrides replaces paths
# and facts (tests).
function Initialize-Context {
    param([Parameter(Mandatory)][hashtable]$Options, [hashtable]$Overrides = @{})
    $repo = $PSScriptRoot
    $stateDir = ''
    if ($env:ProgramData) { $stateDir = Join-Path $env:ProgramData 'RadioAtlantida' }
    $minFree = $script:DefaultMinFreeGB
    if ($Options.ContainsKey('MinFreeGB') -and [int]$Options['MinFreeGB'] -gt 0) { $minFree = [int]$Options['MinFreeGB'] }
    $ctx = @{
        MinFreeGB        = $minFree
        UseLocalVersions = [bool]$Options['UseLocalVersions']
        DryRun           = [bool]$Options['DryRun']
        Resume           = [bool]$Options['Resume']
        Yes              = [bool]$Options['Yes']
        InstallRoot      = $Options['InstallRoot']
        MediaFolder      = $Options['MediaFolder']
        ActiveHoursStart = $Options['ActiveHoursStart']
        ActiveHoursEnd   = $Options['ActiveHoursEnd']
        AccountName      = $Options['AccountName']
        RepoUrl          = $Options['RepoUrl']
        RepoRoot         = $repo
        StateDir         = $stateDir
        UserProfile      = $env:USERPROFILE
        Desktop          = ''
        ComputerName     = $env:COMPUTERNAME
        Now              = (Get-Date)
    }
    foreach ($k in $Overrides.Keys) { $ctx[$k] = $Overrides[$k] }
    if (-not $ctx.Desktop) { $ctx.Desktop = [Environment]::GetFolderPath('Desktop') }
    $ctx.StateFile = Join-Path $ctx.StateDir 'install-state.json'
    $logDir = Join-Path $ctx.StateDir 'logs'
    $stamp = $ctx.Now.ToUniversalTime().ToString('yyyy-MM-ddTHHmmssZ')
    $suffix = ''
    if ($ctx.DryRun) { $suffix = '-dry-run' }
    $ctx.LogFile = Join-Path $logDir ('install-{0}{1}.log' -f $stamp, $suffix)
    if (-not (Test-Path -LiteralPath $logDir)) { New-Item -ItemType Directory -Path $logDir -Force | Out-Null }
    $script:Ctx = $ctx
    $script:Ctx.State = Read-InstallState
    $versionsFile = Join-Path (Join-Path $ctx.RepoRoot 'install') 'versions.env'
    if (-not (Test-Path -LiteralPath $versionsFile)) { Stop-Install "install\versions.env is missing next to install.ps1 ($versionsFile)" }
    $script:Ctx.Versions = ConvertFrom-KeyValueText @(Get-Content -LiteralPath $versionsFile)
}

function Get-KeepAliveUserId { return ('{0}\{1}' -f $script:Ctx.ComputerName, $script:Ctx.AccountName) }

function Test-DistroExists {
    $r = Invoke-Wsl -ArgumentList @('-l', '-q')
    if ($r.ExitCode -ne 0) { return $false }
    return ((ConvertFrom-DistroList $r.Output) -contains $script:DistroName)
}

function Get-WslVersion {
    $r = Invoke-Wsl -ArgumentList @('--version')
    if ($r.ExitCode -ne 0) { return $null }
    return ConvertFrom-WslVersionOutput $r.Output
}

# Test-StackInstalled: radioctl recorded an installed release (state.json
# .current), i.e. the air may be running.
function Test-StackInstalled {
    if (-not (Test-DistroExists)) { return $false }
    $r = Invoke-Wsl -ArgumentList @('-d', $script:DistroName, '-u', 'radio', '--exec', 'jq', '-e', '.current.backend_tag',
        ($script:LinuxDeployDir + '/state.json'))
    return ($r.ExitCode -eq 0)
}

# Invoke-VersionsCheck: install.ps1 installs the pins of this Windows copy's
# install\versions.env, but update.bat keeps the deploy repository inside the
# distribution current (git pull), so after an engine pin change the Windows
# copy can be the older one (or, before update.bat pulled, the newer one).
# When the distribution and its copy exist and the pins differ, the install
# stops before any change (a dry run only warns), unless -UseLocalVersions.
# No distribution, or no deploy repository in it yet: nothing to compare.
# Runs as its own step after WSL is ready and before the first step that can
# stop WSL. Running setup-distro.sh from the distribution's copy instead was
# rejected: install.ps1 and its other inputs (WSL_MIN_VERSION, the rootfs
# pins, update.bat, docker-compose.yml) would still come from this copy, so
# two versions of the installer would mix; and the distribution's copy is
# not always the newer one.
function Invoke-VersionsCheck {
    if (-not (Test-DistroExists)) {
        Write-InstallLog '    no distribution yet: versions not compared'
        return
    }
    $path = $script:LinuxDeployDir + '/install/versions.env'
    $r = Invoke-Wsl -ArgumentList @('-d', $script:DistroName, '-u', 'radio', '--exec', 'cat', $path)
    if ($r.ExitCode -ne 0) {
        Write-InstallLog "    $path not readable (no deploy repository yet): versions not compared"
        return
    }
    $distro = ConvertFrom-KeyValueText $r.Output
    $diff = Compare-VersionsMap -Windows $script:Ctx.Versions -Distro $distro
    if ($diff.Count -eq 0) {
        Write-InstallLog "    the pins equal $path"
        return
    }
    $detail = @($diff | ForEach-Object {
            $w = '(none)'; $d = '(none)'
            if ($script:Ctx.Versions.ContainsKey($_)) { $w = $script:Ctx.Versions[$_] }
            if ($distro.ContainsKey($_)) { $d = $distro[$_] }
            ('{0}: this copy {1}, distribution {2}' -f $_, $w, $d)
        })
    if ($script:Ctx.UseLocalVersions) {
        Write-Warn ('-UseLocalVersions: installing the pins of this copy''s install\versions.env, which differ from {0} ({1})' -f $path, ($detail -join '; '))
        return
    }
    $msg = ('install\versions.env of this copy ({0}) differs from the deploy repository inside the distribution ({1}): {2}. ' -f $script:Ctx.RepoRoot, $path, ($detail -join '; ')) +
    'install.bat installs the pins of this copy, so this copy is out of date. Get a fresh copy of the deploy repository on Windows ' +
    '(download the ZIP again and unpack it over this folder, or git pull in it; runbook 6.3) and run install.bat again. ' +
    'If this copy is the newer one, run update.bat first (it pulls the repository inside the distribution). ' +
    'To install the pins of this copy on purpose: install.bat -UseLocalVersions. Nothing was changed.'
    if ($script:Ctx.DryRun) { Write-Warn $msg } else { Stop-Install $msg }
}

# Confirm-AirInterruption: a step that stops WSL on a machine whose stack is
# installed needs the operator's yes (never answered by -Yes).
function Confirm-AirInterruption {
    param([Parameter(Mandatory)][string]$What)
    if (-not (Test-StackInstalled)) { return }
    Write-Warn "$What stops WSL and interrupts the air for a few minutes. Run install.bat in a maintenance window."
    if (-not (Confirm-Action -Prompt 'Interrupt the air now?')) {
        Stop-Install "stopped before: $What. Nothing was changed by this step; run install.bat again in a maintenance window."
    }
}

# ---------------------------------------------------------------------------
# Steps (plan 6.2). Each has a Check (true: already in the wanted state)
# and an Apply. Steps without a Check always run (they change nothing or
# are idempotent themselves).

function Invoke-Preflight {
    $os = Get-OsFacts
    $script:Ctx.Os = $os
    $updates = Get-UpdateFacts
    $report = Get-PatchReport -Os $os -Updates $updates -Now $script:Ctx.Now
    foreach ($l in $report.Lines) { Write-Info ('    ' + $l) }
    foreach ($w in $report.Warnings) { Write-Warn $w }

    $reason = Test-WindowsBuild -Build $os.Build -Ubr $os.Ubr
    if ($reason) { Stop-Install $reason }
    if ($os.Architecture -ne 'AMD64') { Stop-Install "this installer needs 64-bit x86 Windows (found $($os.Architecture))" }
    $script:Ctx.NetworkMode = Get-NetworkMode -Build $os.Build
    if ($os.Build -lt $script:Win11Build -and -not (Get-StateValue 'support_note_shown')) {
        Write-Info ''
        foreach ($l in Get-SupportNote) { Write-Info ('    ' + $l) }
        if (-not $script:Ctx.DryRun) { Set-StateValue 'support_note_shown' $true }
    }

    $hw = Get-HardwareFacts
    $script:Ctx.Hardware = $hw
    if (-not $hw.HypervisorPresent -and -not $hw.VirtualizationFirmwareEnabled) {
        Stop-Install 'virtualization is off: enable VT-x/AMD-V (Intel Virtualization Technology / SVM) in the BIOS/UEFI settings'
    }
    Write-Info ('    {0} GB RAM, {1} logical processors, virtualization on' -f $hw.RamGB, $hw.LogicalProcessors)
    if ($hw.RamGB -lt $script:MinRamGB) { Write-Warn ("{0} GB RAM is below the recommended {1} GB (the WSL VM gets {2} GB)" -f $hw.RamGB, $script:MinRamGB, (Get-VmMemoryGB -RamGB $hw.RamGB)) }

    $account = Get-CurrentAccountName
    if ($account -ine $script:Ctx.AccountName) {
        Stop-Install ("this install must run signed in as the local account '{0}' (now: '{1}'): the WSL distribution belongs to the account that installs it. Create the account with: install.bat -CreateAccount, then sign in as {0} and run install.bat again." -f $script:Ctx.AccountName, $account)
    }
    if (Test-DockerDesktop) { Stop-Install 'Docker Desktop is installed: uninstall it first (it competes for WSL and the ports)' }

    $free = Get-FreeSpaceGB -Path $script:Ctx.InstallRoot
    $minFree = $script:Ctx.MinFreeGB
    if ($minFree -lt $script:DefaultMinFreeGB) {
        Write-Warn ("-MinFreeGB {0}: the free space check is lowered below the recommended {1} GB on purpose; the station needs about 15-20 GB and more as it grows" -f $minFree, $script:DefaultMinFreeGB)
    }
    if ($free -lt $minFree) {
        if (Test-DistroExists) { Write-Warn "$free GB free on the drive of $($script:Ctx.InstallRoot)" }
        else { Stop-Install "$free GB free on the drive of $($script:Ctx.InstallRoot); at least $minFree GB are needed (install.bat -MinFreeGB <GB> lowers it on purpose)" }
    }
    $failed = @()
    foreach ($u in $script:ReachableUrls) { if (-not (Test-UrlReachable -Url $u)) { $failed += $u } }
    if ($failed.Count -gt 0) {
        $msg = 'not reachable: ' + ($failed -join ', ')
        if ($script:Ctx.DryRun) { Write-Warn $msg } else { Stop-Install ($msg + '; check the internet connection') }
    }
    Write-Info ('    account {0}, {1} GB free, network mode {2}' -f $account, $free, $script:Ctx.NetworkMode)
}

function Test-FeaturesEnabled {
    foreach ($f in $script:Features) { if ((Get-FeatureState -Name $f) -ne 'Enabled') { return $false } }
    # The install continues after the reboot: the resume task goes.
    if (-not $script:Ctx.DryRun -and (Get-ScheduledTaskXml -Name $script:ResumeTaskName)) {
        Remove-ScheduledTaskByName -Name $script:ResumeTaskName
        Write-Info '    resume task removed'
    }
    return $true
}

function Invoke-Features {
    $reboot = $false
    foreach ($f in $script:Features) {
        $st = Get-FeatureState -Name $f
        if ($st -eq 'Enabled') { continue }
        if ($st -eq 'EnablePending') { $reboot = $true; continue }
        $r = Invoke-Native -FilePath 'dism.exe' -ArgumentList @('/online', '/enable-feature', "/featurename:$f", '/all', '/norestart')
        if ($r.ExitCode -eq 3010) { $reboot = $true }
        elseif ($r.ExitCode -ne 0) { Stop-Install "dism.exe could not enable $f (exit $($r.ExitCode)); see $($script:Ctx.LogFile)" }
        else { Write-Info "    $f enabled" }
    }
    if (-not $reboot) { return 'done' }
    $cmd = Get-CmdExe
    $bat = Join-Path $script:Ctx.RepoRoot 'install.bat'
    $extra = ''
    if ($script:Ctx.MinFreeGB -ne $script:DefaultMinFreeGB) { $extra = ' -MinFreeGB {0}' -f $script:Ctx.MinFreeGB }
    if ($script:Ctx.UseLocalVersions) { $extra += ' -UseLocalVersions' }
    $arguments = ('/c ""{0}" -Resume -InstallRoot "{1}"{2}"' -f $bat, $script:Ctx.InstallRoot, $extra)
    Register-TaskFromXml -Name $script:ResumeTaskName -Xml (New-ResumeTaskXml -UserId (Get-KeepAliveUserId) -Command $cmd -Arguments $arguments)
    Write-Info '    Windows must restart to finish enabling WSL. After the restart, sign in as'
    Write-Info ('    {0}: the install continues by itself (task "{1}").' -f $script:Ctx.AccountName, $script:ResumeTaskName)
    return 'reboot'
}

function Test-WslReady {
    $v = Get-WslVersion
    if (-not $v) { return $false }
    $script:Ctx.WslVersion = $v
    return ((Compare-VersionString $v $script:Ctx.Versions['WSL_MIN_VERSION']) -ge 0)
}

function Invoke-WslSetup {
    $r = Invoke-Wsl -ArgumentList @('--update') -Echo
    if ($r.ExitCode -ne 0) {
        Write-Warn 'wsl --update through the Store failed; trying the download from GitHub (--web-download)'
        $r = Invoke-Wsl -ArgumentList @('--update', '--web-download') -Echo
        if ($r.ExitCode -ne 0) { Stop-Install "wsl --update failed (exit $($r.ExitCode)); see $($script:Ctx.LogFile)" }
    }
    $r = Invoke-Wsl -ArgumentList @('--set-default-version', '2')
    if ($r.ExitCode -ne 0) { Write-Warn 'wsl --set-default-version 2 failed (the import names version 2 itself)' }
    $v = Get-WslVersion
    if (-not $v) {
        Stop-Install 'wsl --version prints no version: the Store WSL is not available on this Windows build (Windows 10 needs 19044.2311 or later)'
    }
    if ((Compare-VersionString $v $script:Ctx.Versions['WSL_MIN_VERSION']) -lt 0) {
        Stop-Install "WSL $v is older than $($script:Ctx.Versions['WSL_MIN_VERSION']) after wsl --update"
    }
    $script:Ctx.WslVersion = $v
    Write-Info "    WSL $v"
}

function Test-NetworkModeRecorded {
    return ((Get-StateValue 'network_mode') -eq $script:Ctx.NetworkMode)
}

function Invoke-NetworkMode {
    $old = Get-StateValue 'network_mode'
    if ($old) { Write-Info "    network mode changes from $old to $($script:Ctx.NetworkMode)" }
    Set-StateValue 'network_mode' $script:Ctx.NetworkMode
    Write-Info ('    {0} mode (Windows build {1})' -f $script:Ctx.NetworkMode, $script:Ctx.Os.Build)
}

function Get-WslConfigPath { return (Join-Path $script:Ctx.UserProfile '.wslconfig') }

function Get-WantedWslConfig {
    $current = Read-TextFile (Get-WslConfigPath)
    $s = Get-WslConfigSettings -Mode $script:Ctx.NetworkMode -LogicalProcessors $script:Ctx.Hardware.LogicalProcessors -RamGB $script:Ctx.Hardware.RamGB
    return @{ Current = $current; Wanted = (Merge-WslConfig -Text $current -Set $s.Set -Remove $s.Remove) }
}

function Test-WslConfig {
    $c = Get-WantedWslConfig
    return ($c.Current -eq $c.Wanted)
}

function Invoke-WslConfig {
    $c = Get-WantedWslConfig
    $exists = Test-DistroExists
    if ($exists) { Confirm-AirInterruption -What 'Changing .wslconfig' }
    Write-TextFile -Path (Get-WslConfigPath) -Text $c.Wanted
    Write-Info ('    {0} written' -f (Get-WslConfigPath))
    if ($exists) {
        $r = Invoke-Wsl -ArgumentList @('--shutdown')
        if ($r.ExitCode -ne 0) { Stop-Install 'wsl --shutdown failed' }
        Write-Info '    WSL restarted with the new settings'
    }
}

# Resolve-MediaFolder: the media folder from -MediaFolder, the state, or the
# operator; checked every run (a disconnected drive stops the install).
function Resolve-MediaFolder {
    if ($script:Ctx['MediaWindows']) { return }
    $path = $script:Ctx.MediaFolder
    if (-not $path) { $path = Get-StateValue 'media_windows' }
    if (-not $path) {
        if ($script:Ctx.DryRun -or $script:Ctx.Yes) { $path = $script:DefaultMediaFolder }
        else { $path = Read-Answer -Prompt "The station's Windows media folder" -Default $script:DefaultMediaFolder }
    }
    $path = $path.Trim().TrimEnd('\')
    if ($path -match '^[A-Za-z]:$') { $path += '\' }
    $drive = $null
    if ($path -match '^[A-Za-z]:\\') { $drive = Get-DriveFacts -Letter $path.Substring(0, 1) }
    $exists = $false
    if ($null -ne $drive) { $exists = Test-FolderExists -Path $path }
    $reason = Test-MediaFolderFacts -Path $path -Drive $drive -Exists $exists
    if ($reason) { Stop-Install "media folder: $reason" }
    $script:Ctx.MediaWindows = $path
    $script:Ctx.MediaWsl = ConvertTo-WslPath $path
    Write-Info ('    media folder {0} (WSL: {1})' -f $script:Ctx.MediaWindows, $script:Ctx.MediaWsl)
}

function Test-Folders {
    Resolve-MediaFolder
    if ((Get-StateValue 'media_windows') -ne $script:Ctx.MediaWindows) { return $false }
    $ex = Get-DefenderExclusions
    if ($null -ne $ex -and -not ($ex -contains $script:Ctx.MediaWindows)) { return $false }
    if (-not (Test-FolderNotIndexed -Path $script:Ctx.MediaWindows)) { return $false }
    return (Test-FolderExists -Path $script:WindowsBackupDir)
}

function Invoke-Folders {
    Resolve-MediaFolder
    $ex = Get-DefenderExclusions
    if ($null -eq $ex) {
        Write-Warn 'Microsoft Defender is not available: add an exclusion for the media folder in the antivirus in use'
    }
    elseif (-not ($ex -contains $script:Ctx.MediaWindows)) {
        Add-DefenderExclusion -Path $script:Ctx.MediaWindows
        Write-Info '    Defender exclusion added'
    }
    if (-not (Test-FolderNotIndexed -Path $script:Ctx.MediaWindows)) {
        Set-FolderNotIndexed -Path $script:Ctx.MediaWindows
        Write-Info '    indexing turned off for the media folder'
    }
    if (-not (Test-FolderExists -Path $script:WindowsBackupDir)) {
        New-Folder -Path $script:WindowsBackupDir
        Write-Info "    $($script:WindowsBackupDir) created (the Windows copy of the backups)"
    }
    Set-StateValue 'media_windows' $script:Ctx.MediaWindows
    Set-StateValue 'media_wsl' $script:Ctx.MediaWsl
}

function Invoke-Distro {
    $url = $script:Ctx.Versions['UBUNTU_ROOTFS_URL']
    $sha = ([string]$script:Ctx.Versions['UBUNTU_ROOTFS_SHA256']).ToLowerInvariant()
    if (-not $url -or -not $sha) { Stop-Install 'install\versions.env has no UBUNTU_ROOTFS_URL or UBUNTU_ROOTFS_SHA256' }
    $downloads = Join-Path $script:Ctx.InstallRoot 'downloads'
    $target = Join-Path $script:Ctx.InstallRoot 'wsl'
    New-Folder -Path $downloads
    New-Folder -Path $target
    $file = Join-Path $downloads ($url.Substring($url.LastIndexOf('/') + 1))
    if (-not (Test-Path -LiteralPath $file) -or (Get-FileSha256 -Path $file) -ne $sha) {
        Write-Info "    downloading $url"
        Save-Download -Url $url -Path $file
    }
    $have = Get-FileSha256 -Path $file
    if ($have -ne $sha) {
        Remove-Item -LiteralPath $file -Force
        Stop-Install "the downloaded root file system has SHA-256 $have, install\versions.env pins $sha; nothing was imported"
    }
    Write-Info '    checksum ok'
    $r = Invoke-Wsl -ArgumentList @('--import', $script:DistroName, $target, $file, '--version', '2') -Echo
    if ($r.ExitCode -ne 0) { Stop-Install "wsl --import failed (exit $($r.ExitCode)); see $($script:Ctx.LogFile)" }
    Remove-Item -LiteralPath $file -Force
    Write-Info "    distribution $($script:DistroName) imported into $target"
}

function Invoke-SetupDistro {
    $setup = $script:LinuxSrcDir + '/install/setup-distro.sh'
    $a = @('-d', $script:DistroName, '-u', 'root', '--exec', 'bash', $setup, '--network-mode', $script:Ctx.NetworkMode,
        '--media-root', $script:Ctx.MediaWsl)
    return (Invoke-Wsl -ArgumentList $a -Echo).ExitCode
}

# Invoke-LinuxHalf: plan 6.2 step 8. Always runs (setup-distro.sh is
# idempotent and applies a new versions.env); exit 10 means "restart the
# distribution and run again" (a fresh import, or a changed wsl.conf).
function Invoke-LinuxHalf {
    Resolve-MediaFolder
    $d = $script:DistroName
    $wslRepo = Get-RepoWslPath
    foreach ($a in @(
            @('-d', $d, '-u', 'root', '--exec', 'rm', '-rf', $script:LinuxSrcDir),
            @('-d', $d, '-u', 'root', '--exec', 'mkdir', '-p', $script:LinuxSrcDir),
            @('-d', $d, '-u', 'root', '--exec', 'cp', '-R', ($wslRepo + '/install'), ($wslRepo + '/docker-compose.yml'), ($script:LinuxSrcDir + '/')))) {
        $r = Invoke-Wsl -ArgumentList $a
        if ($r.ExitCode -ne 0) { Stop-Install "copying install\ into the distribution failed; see $($script:Ctx.LogFile)" }
    }
    $rc = Invoke-SetupDistro
    if ($rc -eq 10) {
        Confirm-AirInterruption -What 'Restarting the distribution (setup-distro.sh changed /etc/wsl.conf)'
        $r = Invoke-Wsl -ArgumentList @('--terminate', $d)
        if ($r.ExitCode -ne 0) { Stop-Install "wsl --terminate $d failed" }
        Write-Info '    distribution restarted (systemd, user radio, drive mount options)'
        $rc = Invoke-SetupDistro
    }
    if ($rc -ne 0) {
        Stop-Install "setup-distro.sh failed (exit $rc); its output is in $($script:Ctx.LogFile)"
    }
}

function Test-KeepAliveTask {
    return (Test-KeepAliveTaskXml (Get-ScheduledTaskXml -Name $script:KeepAliveTaskName))
}

function Invoke-KeepAliveTask {
    $user = Get-KeepAliveUserId
    $xml = New-KeepAliveTaskXml -UserId $user -WslExe (Get-WslExe)
    Write-Info ('    The task runs as {0} whether or not anyone is signed in; Windows stores the password.' -f $user)
    for ($try = 1; $try -le 3; $try++) {
        $secure = Read-Secret -Prompt ('Windows password of {0}' -f $user)
        try {
            Register-TaskFromXml -Name $script:KeepAliveTaskName -Xml $xml -User $user -Password $secure
            Write-Info ('    task "{0}" registered: at boot and every 5 minutes' -f $script:KeepAliveTaskName)
            Start-ScheduledTaskByName -Name $script:KeepAliveTaskName
            Write-Info '    task started'
            return
        }
        catch {
            Write-Warn ('the task was not registered (wrong password?): {0}' -f $_.Exception.Message)
        }
    }
    Stop-Install 'the keep-alive task could not be registered after 3 attempts'
}

function Get-ActiveHoursChoice {
    $start = $script:Ctx.ActiveHoursStart
    $end = $script:Ctx.ActiveHoursEnd
    $saved = Get-StateValue 'active_hours'
    if ($start -lt 0 -and $saved) { $start = [int]$saved[0] }
    if ($end -lt 0 -and $saved) { $end = [int]$saved[1] }
    if ($start -lt 0) {
        if ($script:Ctx.DryRun -or $script:Ctx.Yes) { $start = 6 }
        else { $start = [int](Read-Answer -Prompt 'Windows Update active hours: start hour (0-23)' -Default '6') }
    }
    if ($end -lt 0) {
        if ($script:Ctx.DryRun -or $script:Ctx.Yes) { $end = 0 }
        else { $end = [int](Read-Answer -Prompt 'Active hours: end hour (0-23, 0 = midnight)' -Default '0') }
    }
    $reason = Test-ActiveHours -Start $start -End $end
    if ($reason) { Stop-Install $reason }
    return @($start, $end)
}

$script:UxSettings = 'HKLM:\SOFTWARE\Microsoft\WindowsUpdate\UX\Settings'
$script:W32TimeParams = 'HKLM:\SYSTEM\CurrentControlSet\Services\W32Time\Parameters'
$script:PowerKey = 'HKLM:\SYSTEM\CurrentControlSet\Control\Power'

function Test-Hardening {
    $hours = Get-ActiveHoursChoice
    $script:Ctx.ActiveHours = $hours
    return ((Get-RegistryValue -Path $script:UxSettings -Name 'ActiveHoursStart') -eq $hours[0]) -and
        ((Get-RegistryValue -Path $script:UxSettings -Name 'ActiveHoursEnd') -eq $hours[1]) -and
        ((Get-RegistryValue -Path $script:W32TimeParams -Name 'NtpServer') -eq $script:NtpPeers) -and
        ((Get-RegistryValue -Path $script:PowerKey -Name 'HibernateEnabled') -eq 0)
}

# Invoke-Hardening: plan 6.7, Home-compatible (no Pro-only policy such as
# AUOptions).
function Invoke-Hardening {
    $hours = $script:Ctx.ActiveHours
    if (-not $hours) { $hours = Get-ActiveHoursChoice }
    foreach ($a in @(@('/change', 'standby-timeout-ac', '0'), @('/change', 'hibernate-timeout-ac', '0'),
            @('/change', 'disk-timeout-ac', '0'), @('/hibernate', 'off'))) {
        $r = Invoke-Native -FilePath 'powercfg.exe' -ArgumentList $a
        if ($r.ExitCode -ne 0) { Stop-Install "powercfg $($a -join ' ') failed" }
    }
    Write-Info '    power: no sleep, no hibernation, no disk timeout on AC; hibernation and Fast Startup off'
    Set-RegistryValue -Path $script:UxSettings -Name 'ActiveHoursStart' -Value $hours[0]
    Set-RegistryValue -Path $script:UxSettings -Name 'ActiveHoursEnd' -Value $hours[1]
    # "Automatically adjust active hours" off, so Windows keeps the window
    # (verify on Windows).
    Set-RegistryValue -Path $script:UxSettings -Name 'SmartActiveHoursState' -Value 0
    Set-StateValue 'active_hours' $hours
    Write-Info ('    Windows Update active hours {0}:00-{1}:00' -f $hours[0], $hours[1])
    Set-TimeServiceAutomatic
    $r = Invoke-Native -FilePath 'w32tm.exe' -ArgumentList @('/config', '/syncfromflags:manual', "/manualpeerlist:$($script:NtpPeers)", '/update')
    if ($r.ExitCode -ne 0) { Stop-Install 'w32tm /config failed' }
    $r = Invoke-Native -FilePath 'w32tm.exe' -ArgumentList @('/resync')
    if ($r.ExitCode -ne 0) { Write-Warn 'w32tm /resync failed; Windows Time syncs at its next interval' }
    Write-Info "    time: Windows Time automatic, NTP $($script:NtpPeers)"
}

function Invoke-DeployRepo {
    Resolve-MediaFolder
    $d = $script:DistroName
    $dir = $script:LinuxDeployDir
    $r = Invoke-Wsl -ArgumentList @('-d', $d, '-u', 'radio', '--exec', 'test', '-d', ($dir + '/.git'))
    if ($r.ExitCode -eq 0) {
        $r = Invoke-Wsl -ArgumentList @('-d', $d, '-u', 'radio', '--exec', 'git', '-C', $dir, 'pull', '--ff-only') -Echo
        if ($r.ExitCode -ne 0) { Stop-Install "git pull in $dir failed; see $($script:Ctx.LogFile)" }
    }
    else {
        $r = Invoke-Wsl -ArgumentList @('-d', $d, '-u', 'radio', '--exec', 'git', 'clone', $script:Ctx.RepoUrl, $dir) -Echo
        if ($r.ExitCode -ne 0) { Stop-Install "git clone $($script:Ctx.RepoUrl) failed; see $($script:Ctx.LogFile)" }
    }
    # radio-network.service writes runtime/network.env, which the first run
    # needs; at boot it runs by itself.
    $r = Invoke-Wsl -ArgumentList @('-d', $d, '-u', 'root', '--exec', 'systemctl', 'start', 'radio-network.service')
    if ($r.ExitCode -ne 0) { Stop-Install "radio-network.service failed; in WSL: journalctl -u radio-network.service" }
    $r = Invoke-Wsl -ArgumentList @('-d', $d, '-u', 'radio', '--exec', 'test', '-f', ($dir + '/runtime/network.env'))
    if ($r.ExitCode -ne 0) { Stop-Install 'runtime/network.env was not written by radio-network.service' }
    Write-Info '    deploy repository ready; network values written'
    Write-Info ''
    Write-Info '    First configuration (radioctl first-run): its questions follow.'
    $r = Invoke-Wsl -Interactive -ArgumentList @('-d', $d, '-u', 'radio', '--cd', $dir, '--exec', 'bin/radioctl', 'first-run',
        '--media-root', $script:Ctx.MediaWsl)
    if ($r.ExitCode -ne 0) {
        Stop-Install 'radioctl first-run failed (its log is in logs/ of the deploy repository; update.bat logs shows it). Fix the cause and run install.bat again.'
    }
}

# Get-StackSettings: the panel and Grafana ports and the monitoring switch
# from .env inside WSL (no secret is read).
function Get-StackSettings {
    $s = @{ PANEL_PORT = '8080'; GRAFANA_PORT = '3000'; MONITORING_ENABLED = 'true' }
    $r = Invoke-Wsl -ArgumentList @('-d', $script:DistroName, '-u', 'radio', '--exec', 'grep', '-E',
        '^(PANEL_PORT|GRAFANA_PORT|MONITORING_ENABLED)=', ($script:LinuxDeployDir + '/.env'))
    if ($r.ExitCode -eq 0) {
        $kv = ConvertFrom-KeyValueText $r.Output
        foreach ($k in $kv.Keys) { $s[$k] = $kv[$k].Trim("'", '"') }
    }
    return $s
}

function Get-ShortcutPlan {
    Resolve-MediaFolder
    $s = Get-StackSettings
    $desk = $script:Ctx.Desktop
    $plan = @(
        @{ Path = (Join-Path $desk 'Radio panel.url'); Url = ('http://127.0.0.1:{0}' -f $s.PANEL_PORT) },
        @{ Path = (Join-Path $desk 'Radio media.lnk'); Target = $script:Ctx.MediaWindows },
        @{ Path = (Join-Path $desk 'Radio update.lnk'); Target = (Join-Path $script:Ctx.InstallRoot 'update.bat'); WorkingDirectory = $script:Ctx.InstallRoot }
    )
    if ($s.MONITORING_ENABLED -eq 'true') {
        $plan += @{ Path = (Join-Path $desk 'Radio Grafana.url'); Url = ('http://127.0.0.1:{0}' -f $s.GRAFANA_PORT) }
    }
    return $plan
}

function Test-Shortcuts {
    $updateCopy = Join-Path $script:Ctx.InstallRoot 'update.bat'
    if ((Read-TextFile $updateCopy) -ne (Read-TextFile (Join-Path $script:Ctx.RepoRoot 'update.bat'))) { return $false }
    foreach ($p in Get-ShortcutPlan) {
        if (-not (Test-Path -LiteralPath $p.Path)) { return $false }
        if ($p.ContainsKey('Url') -and (Read-TextFile $p.Path) -ne (New-InternetShortcutText -Url $p.Url)) { return $false }
    }
    return $true
}

# Invoke-Shortcuts: plan 6.2 step 12. update.bat is copied to InstallRoot,
# so the shortcut does not depend on the folder install.bat ran from.
function Invoke-Shortcuts {
    Write-TextFile -Path (Join-Path $script:Ctx.InstallRoot 'update.bat') -Text (Read-TextFile (Join-Path $script:Ctx.RepoRoot 'update.bat'))
    foreach ($p in Get-ShortcutPlan) {
        if ($p.ContainsKey('Url')) { Write-TextFile -Path $p.Path -Text (New-InternetShortcutText -Url $p.Url) }
        else { New-ShellShortcut -Path $p.Path -Target $p.Target -WorkingDirectory ([string]$p['WorkingDirectory']) }
        Write-Info ('    {0}' -f (Split-Path -Leaf $p.Path))
    }
}

function Write-Summary {
    $v = $script:Ctx.Versions
    $os = $script:Ctx.Os
    Write-Info ('    Windows build {0}.{1}, WSL network mode {2}' -f $os.Build, $os.Ubr, $script:Ctx.NetworkMode)
    $wslv = '?'
    if ($script:Ctx['WslVersion']) { $wslv = $script:Ctx.WslVersion }
    Write-Info ('    WSL {0}; Ubuntu 24.04; Docker Engine {1}; Compose {2}' -f $wslv, $v['DOCKER_CE_VERSION'], $v['DOCKER_COMPOSE_PLUGIN_VERSION'])
    if ($script:Ctx['MediaWindows']) { Write-Info ('    media folder {0}' -f $script:Ctx.MediaWindows) }
    Write-Info '    The Grafana admin password was shown once by the first run above (it is not shown again).'
    Write-Info '    Next: import the media in the panel ("Radio panel"), build the grid and clocks, set the'
    Write-Info '    emergency playlist, then the cut-over (update.bat cutover; docs\runbook.md). Test a cold reboot:'
    Write-Info '    the stack must be healthy within 5 minutes with nobody signed in (update.bat status).'
    Write-Info ('    Log: {0}' -f $script:Ctx.LogFile)
}

# Steps that only check (they also run in a dry run and are not recorded).
$script:CheckOnlySteps = @('preflight', 'versions')

# Get-InstallSteps: the steps of plan 6.2 in order. The versions check runs
# once WSL works and before the first step that can stop WSL (.wslconfig).
function Get-InstallSteps {
    return @(
        @{ Name = 'preflight'; Title = 'Preflight'; Check = $null; Apply = { Invoke-Preflight } },
        @{ Name = 'features'; Title = 'Windows features (WSL, Virtual Machine Platform)'; Check = { Test-FeaturesEnabled }; Apply = { Invoke-Features } },
        @{ Name = 'wsl'; Title = 'WSL (Store version)'; Check = { Test-WslReady }; Apply = { Invoke-WslSetup } },
        @{ Name = 'versions'; Title = 'Pinned versions (install\versions.env)'; Check = $null; Apply = { Invoke-VersionsCheck } },
        @{ Name = 'network-mode'; Title = 'Network mode'; Check = { Test-NetworkModeRecorded }; Apply = { Invoke-NetworkMode } },
        @{ Name = 'wslconfig'; Title = '.wslconfig'; Check = { Test-WslConfig }; Apply = { Invoke-WslConfig } },
        @{ Name = 'folders'; Title = 'Media folder and Windows backup folder'; Check = { Test-Folders }; Apply = { Invoke-Folders } },
        @{ Name = 'distro'; Title = 'Distribution radio-atlantida'; Check = { Test-DistroExists }; Apply = { Invoke-Distro } },
        @{ Name = 'linux'; Title = 'Linux half (setup-distro.sh)'; Check = $null; Apply = { Invoke-LinuxHalf } },
        @{ Name = 'keepalive'; Title = 'Boot and keep-alive task'; Check = { Test-KeepAliveTask }; Apply = { Invoke-KeepAliveTask } },
        @{ Name = 'hardening'; Title = 'Host settings (power, active hours, time)'; Check = { Test-Hardening }; Apply = { Invoke-Hardening } },
        @{ Name = 'deploy'; Title = 'Deploy repository and first configuration'; Check = { Test-StackInstalled }; Apply = { Invoke-DeployRepo } },
        @{ Name = 'shortcuts'; Title = 'Desktop shortcuts'; Check = { Test-Shortcuts }; Apply = { Invoke-Shortcuts } }
    )
}

function Set-StepDone {
    param([Parameter(Mandatory)][string]$Name)
    $script:Ctx.State.steps[$Name] = $script:Ctx.Now.ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
    Save-InstallState
}

# Invoke-InstallSteps: runs the steps; returns 0, or 3010 when Windows must
# restart first.
function Invoke-InstallSteps {
    foreach ($s in Get-InstallSteps) {
        Write-StepTitle $s.Title
        if ($null -ne $s.Check) {
            $inPlace = [bool](& $s.Check)
            if ($inPlace) {
                $how = 'in place'
                $rec = $script:Ctx.State.steps[$s.Name]
                # PowerShell 7's ConvertFrom-Json turns the ISO time into a DateTime.
                if ($rec -is [datetime]) { $rec = $rec.ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ') }
                if ($rec) { $how = 'done (recorded ' + $rec + ')' }
                Write-Info ('    {0}: skipped' -f $how)
                if (-not $script:Ctx.DryRun -and -not $script:Ctx.State.steps[$s.Name]) { Set-StepDone $s.Name }
                continue
            }
        }
        if ($script:Ctx.DryRun) {
            if ($null -eq $s.Check) {
                if ($s.Name -in $script:CheckOnlySteps) { & $s.Apply | Out-Null; continue }
                Write-Info '    [dry-run] would run (this step runs every time; it is idempotent)'
            }
            else { Write-Info '    [dry-run] not in place: would run' }
            continue
        }
        $result = & $s.Apply
        if ($result -eq 'reboot') {
            Set-StepDone $s.Name
            if (Confirm-Action -Prompt 'Restart Windows now?') { Restart-Host }
            else { Write-Info '    Restart Windows later; the install continues at the next sign-in of radio.' }
            return 3010
        }
        if ($s.Name -notin $script:CheckOnlySteps) { Set-StepDone $s.Name }
    }
    Write-StepTitle 'Summary'
    if ($script:Ctx.DryRun) { Write-Info '    DRY RUN: nothing was changed.' }
    Write-Summary
    return 0
}

function Invoke-CreateAccount {
    $name = $script:Ctx.AccountName
    Write-StepTitle "Local account $name"
    if (Test-LocalAccount -Name $name) {
        Write-Info "    the account $name exists. Sign in as $name and run install.bat."
        return 0
    }
    if ($script:Ctx.DryRun) {
        Write-Info "    [dry-run] would create the local administrator $name (password never expires)"
        return 0
    }
    $p1 = Read-Secret -Prompt "Password for $name"
    $p2 = Read-Secret -Prompt 'Repeat the password'
    $same = (ConvertFrom-SecureStringToPlain $p1) -ceq (ConvertFrom-SecureStringToPlain $p2)
    if (-not $same) { Stop-Install 'the passwords differ; nothing was created' }
    New-LocalAdminAccount -Name $name -Password $p1
    Write-Info "    local administrator $name created (password never expires)."
    Write-Info "    Sign out, sign in as $name, and run install.bat again."
    return 0
}

# Invoke-Install: the whole run after elevation; returns the exit code.
function Invoke-Install {
    param([switch]$CreateAccountOnly)
    Write-Info ('Radio Atlantida host install ({0})' -f $script:Ctx.Now.ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ'))
    if ($script:Ctx.DryRun) { Write-Info 'DRY RUN: every step is checked; nothing is changed.' }
    if ($script:Ctx.Resume) { Write-Info 'Resuming after the restart.' }
    Write-InstallLog ('options: install root {0}, account {1}, repository {2}' -f $script:Ctx.InstallRoot, $script:Ctx.AccountName, $script:Ctx.RepoUrl)
    try {
        if ($CreateAccountOnly) { return (Invoke-CreateAccount) }
        return (Invoke-InstallSteps)
    }
    catch {
        if ($_.Exception.Data['RadioStop']) {
            Write-Info ''
            Write-Info ('STOPPED: ' + $_.Exception.Message)
        }
        else {
            Write-Info ''
            Write-Info ('ERROR: unexpected failure: ' + $_.Exception.Message)
            Write-InstallLog ($_.ScriptStackTrace)
        }
        Write-Info ('Log: ' + $script:Ctx.LogFile)
        return 1
    }
}

function Invoke-Main {
    param([Parameter(Mandatory)][hashtable]$Bound)
    if (-not (Test-Administrator)) {
        return (Start-Elevated -ScriptPath $PSCommandPath -Arguments (Get-ForwardedArguments $Bound))
    }
    $env:WSL_UTF8 = '1'
    try { [Console]::OutputEncoding = New-Object System.Text.UTF8Encoding($false) } catch { Write-Verbose 'console encoding unchanged' }
    $opts = @{
        DryRun = $DryRun; Resume = $Resume; Yes = $Yes; InstallRoot = $InstallRoot; MediaFolder = $MediaFolder
        ActiveHoursStart = $ActiveHoursStart; ActiveHoursEnd = $ActiveHoursEnd; AccountName = $AccountName; RepoUrl = $RepoUrl
        MinFreeGB = $MinFreeGB; UseLocalVersions = $UseLocalVersions
    }
    $code = 1
    try {
        Initialize-Context -Options $opts
        $code = Invoke-Install -CreateAccountOnly:$CreateAccount
    }
    catch {
        Write-Info ('STOPPED: ' + $_.Exception.Message)
    }
    if ($Elevated) { Read-Host -Prompt 'Press Enter to close this window' | Out-Null }
    return $code
}

# Dot-sourced by the tests: define the functions only.
if ($MyInvocation.InvocationName -ne '.') {
    exit (Invoke-Main -Bound $PSBoundParameters)
}
