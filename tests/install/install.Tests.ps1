# Pester 5 tests of install.ps1 (deploy-init-plan.md D4, D7 9.1 item 10).
#
# install.ps1 is dot-sourced, so only its functions are defined. Every
# wrapper that touches Windows (CIM, registry, Task Scheduler, Defender,
# downloads) and Invoke-Native (wsl.exe, dism.exe, powercfg.exe, w32tm.exe)
# is mocked by a small fake machine ($script:Fake), so the tests run the real
# step logic on any PowerShell: tests/install/run.sh runs them with
# PowerShell 7 on Linux; CI on a Windows runner (D7) runs them under Windows
# PowerShell 5.1. What the wrappers themselves do on Windows is part of the
# Windows acceptance run (docs/runbook.md section 11).

BeforeAll {
    $script:RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '../..')).Path
    . (Join-Path $script:RepoRoot 'install.ps1')

    $script:Versions = ConvertFrom-KeyValueText @(Get-Content (Join-Path $script:RepoRoot 'install/versions.env'))
    $script:Password = 'S3cret-Pw!x'

    function Reset-Fake {
        $script:Fake = @{
            Os            = [pscustomobject]@{ Caption = 'Microsoft Windows 10 Home'; Build = 19045; Ubr = 6456; Edition = 'Core'; DisplayVersion = '22H2'; Architecture = 'AMD64' }
            Updates       = [pscustomobject]@{ NewestKb = 'KB5066791'; NewestDate = [datetime]'2025-10-14'; Esu = 'not detected' }
            Hardware      = [pscustomobject]@{ HypervisorPresent = $false; VirtualizationFirmwareEnabled = $true; RamGB = 16; LogicalProcessors = 8 }
            Account       = 'radio'
            DockerDesktop = $false
            FreeGB        = 300
            Features      = @{ 'Microsoft-Windows-Subsystem-Linux' = 'Disabled'; 'VirtualMachinePlatform' = 'Disabled' }
            DismRc        = 3010
            WslVersion    = $null
            WslAfterUpdate = '2.6.1.0'
            UpdateRc      = 0
            Distros       = @()
            SetupRc       = New-Object System.Collections.Queue
            SetupRcDefault = 0
            Installed     = $false
            RepoCloned    = $false
            FirstRunRc    = 0
            Tasks         = @{}
            RegisterFailures = 0
            Registry      = @{}
            Exclusions    = @()
            DefenderAvailable = $true
            NotIndexed    = $false
            BackupDir     = $false
            Drive         = [pscustomobject]@{ DriveType = 'Fixed'; DriveFormat = 'NTFS'; BusType = 'SATA' }
            FolderExists  = $true
            Sha           = $script:Versions['UBUNTU_ROOTFS_SHA256']
            Calls         = New-Object System.Collections.Generic.List[string]
            Restarted     = $false
        }
        # A fresh import: the first setup-distro.sh pass asks for a restart.
        $script:Fake.SetupRc.Enqueue(10)
    }

    function Invoke-FakeNative {
        param([string]$FilePath, [string[]]$ArgumentList, [bool]$Interactive)
        $f = $script:Fake
        $line = ('{0} {1}' -f (Split-Path -Leaf $FilePath), ($ArgumentList -join ' '))
        if ($Interactive) { $line = 'INTERACTIVE ' + $line }
        $f.Calls.Add($line)
        Write-InstallLog ('+ ' + $line)
        $ok = { param($out) [pscustomobject]@{ ExitCode = 0; Output = @($out) } }
        $rc = { param($code, $out) [pscustomobject]@{ ExitCode = $code; Output = @($out) } }
        $a = $ArgumentList
        switch -Wildcard ((Split-Path -Leaf $FilePath)) {
            'dism.exe' {
                $name = ($a | Where-Object { $_ -like '/featurename:*' }) -replace '^/featurename:', ''
                if ($f.DismRc -eq 3010) { $f.Features[$name] = 'EnablePending' }
                elseif ($f.DismRc -eq 0) { $f.Features[$name] = 'Enabled' }
                return (& $rc $f.DismRc '')
            }
            # What Windows records for these commands, read by the hardening check.
            'powercfg.exe' {
                if ($a[0] -eq '/hibernate') { $f.Registry["$($script:PowerKey)|HibernateEnabled"] = 0 }
                return (& $ok '')
            }
            'w32tm.exe' {
                if ($a[0] -eq '/config') { $f.Registry["$($script:W32TimeParams)|NtpServer"] = $script:NtpPeers }
                return (& $ok '')
            }
            'wsl.exe' {
                if ($a[0] -eq '--version') {
                    if ($f.WslVersion) { return (& $ok @("WSL version: $($f.WslVersion)", 'Kernel version: 6.6.87.2-1')) }
                    return (& $rc -1 @('Usage: wsl.exe [Argument] [Options...] [CommandLine]'))
                }
                if ($a[0] -eq '--update') {
                    if ($f.UpdateRc -ne 0 -and $a -notcontains '--web-download') { return (& $rc $f.UpdateRc 'store failed') }
                    $f.WslVersion = $f.WslAfterUpdate
                    return (& $ok 'updated')
                }
                if ($a[0] -in @('--set-default-version', '--shutdown', '--terminate')) { return (& $ok '') }
                if ($a[0] -eq '-l') {
                    if ($f.Distros.Count -eq 0) { return (& $rc -1 'Windows Subsystem for Linux has no installed distributions.') }
                    return (& $ok $f.Distros)
                }
                if ($a[0] -eq '--import') { $f.Distros += $a[1]; return (& $ok 'imported') }
                $exec = [array]::IndexOf($a, '--exec')
                $cmd = @($a | Select-Object -Skip ($exec + 1))
                switch ($cmd[0]) {
                    'bash' {
                        $code = $f.SetupRcDefault
                        if ($f.SetupRc.Count -gt 0) { $code = $f.SetupRc.Dequeue() }
                        return (& $rc $code @('==> Host', 'setup-distro: done'))
                    }
                    'jq' { if ($f.Installed) { return (& $ok '"1.0.0"') } return (& $rc 1 '') }
                    'test' {
                        if ($cmd[2] -like '*/.git') { if ($f.RepoCloned) { return (& $ok '') } return (& $rc 1 '') }
                        return (& $ok '')
                    }
                    'git' { $f.RepoCloned = $true; return (& $ok 'cloned') }
                    'grep' { return (& $ok @('PANEL_PORT=8080', 'MONITORING_ENABLED=true', 'GRAFANA_PORT=3000')) }
                    'bin/radioctl' {
                        if ($f.FirstRunRc -eq 0) { $f.Installed = $true }
                        return (& $rc $f.FirstRunRc '')
                    }
                    default { return (& $ok '') }
                }
            }
        }
        return (& $ok '')
    }

    function Invoke-TestInstall {
        param([hashtable]$Options = @{}, [switch]$CreateAccount)
        $opts = @{
            DryRun = $false; Resume = $false; Yes = $true; InstallRoot = (Join-Path $TestDrive 'root'); MediaFolder = ''
            ActiveHoursStart = -1; ActiveHoursEnd = -1; AccountName = 'radio'; RepoUrl = 'https://github.com/AstRonin/radio-atlantida-deploy'
        }
        foreach ($k in $Options.Keys) { $opts[$k] = $Options[$k] }
        Initialize-Context -Options $opts -Overrides @{
            StateDir = (Join-Path $TestDrive 'state'); UserProfile = (Join-Path $TestDrive 'profile'); Desktop = (Join-Path $TestDrive 'desktop')
            RepoRoot = $script:RepoRoot; ComputerName = 'STATION'; Now = [datetime]'2026-11-13T10:00:00Z'
        }
        return (Invoke-Install -CreateAccountOnly:$CreateAccount)
    }

    function Get-RunLog { return (Get-Content -Raw -LiteralPath $script:Ctx.LogFile) }
    function Get-WslConfigText { return (Read-TextFile (Join-Path (Join-Path $TestDrive 'profile') '.wslconfig')) }
    function Get-FakeCalls { param([string]$Like) return @($script:Fake.Calls | Where-Object { $_ -like $Like }) }
    function Get-SavedState { return (ConvertTo-PlainHashtable ((Get-Content -Raw (Join-Path (Join-Path $TestDrive 'state') 'install-state.json')) | ConvertFrom-Json)) }
}

Describe 'pure logic' {
    Context 'ConvertTo-WslPath' {
        It 'converts <Path> to <Expected>' -TestCases @(
            @{ Path = 'D:\RadioAtlantida\media'; Expected = '/mnt/d/RadioAtlantida/media' },
            @{ Path = 'd:\Radio Atlantida\My Music\'; Expected = '/mnt/d/Radio Atlantida/My Music' },
            @{ Path = 'E:\Радио\Ատլանտիդա'; Expected = '/mnt/e/Радио/Ատլանտիդա' },
            @{ Path = 'C:\'; Expected = '/mnt/c' },
            @{ Path = 'F:'; Expected = '/mnt/f' }
        ) {
            ConvertTo-WslPath $Path | Should -Be $Expected
        }
        It 'refuses <Path>' -TestCases @(@{ Path = '\\server\share\media' }, @{ Path = 'media\tracks' }, @{ Path = '/mnt/d/x' }) {
            { ConvertTo-WslPath $Path } | Should -Throw '*drive letter*'
        }
    }

    Context 'Get-NetworkMode and Test-WindowsBuild' {
        It 'build <Build> gets <Mode> mode' -TestCases @(
            @{ Build = 19044; Mode = 'nat' }, @{ Build = 19045; Mode = 'nat' }, @{ Build = 22000; Mode = 'nat' },
            @{ Build = 22621; Mode = 'mirrored' }, @{ Build = 26100; Mode = 'mirrored' }
        ) {
            Get-NetworkMode -Build $Build | Should -Be $Mode
        }
        It 'refuses builds below 19044 and Windows 10 without the WSL update level' {
            Test-WindowsBuild -Build 19043 -Ubr 9999 | Should -BeLike '*too old*'
            Test-WindowsBuild -Build 19044 -Ubr 2310 | Should -BeLike '*19044.2311 or later*'
            Test-WindowsBuild -Build 19045 -Ubr 2311 | Should -BeNullOrEmpty
            Test-WindowsBuild -Build 22000 -Ubr 0 | Should -BeNullOrEmpty
        }
    }

    Context 'versions' {
        It 'compares WSL versions with three or four parts' {
            Compare-VersionString '2.4.4.0' '2.4.4' | Should -Be 0
            Compare-VersionString '2.3.26.0' '2.4.4' | Should -Be -1
            Compare-VersionString '2.10.0' '2.4.4' | Should -Be 1
        }
        It 'reads the version from wsl --version in any language, and none from the inbox help' {
            ConvertFrom-WslVersionOutput @('WSL version: 2.6.1.0', 'Kernel version: 6.6') | Should -Be '2.6.1.0'
            ConvertFrom-WslVersionOutput @('', "W`0S`0L`0-Version: 2.4.4.0") | Should -Be '2.4.4.0'
            ConvertFrom-WslVersionOutput @('Usage: wsl.exe [Argument]') | Should -BeNullOrEmpty
        }
        It 'parses versions.env with real pins' {
            $script:Versions['UBUNTU_ROOTFS_SHA256'] | Should -Match '^[0-9a-f]{64}$'
            $script:Versions['UBUNTU_ROOTFS_URL'] | Should -Match '^https://.+24\.04.+\.tar\.gz$'
            $script:Versions['DOCKER_APT_KEY_FINGERPRINT'] | Should -Match '^[0-9A-F]{40}$'
            $script:Versions['WSL_MIN_VERSION'] | Should -Match '^\d+\.\d+\.\d+$'
            foreach ($k in 'DOCKER_CE_VERSION', 'CONTAINERD_VERSION', 'DOCKER_COMPOSE_PLUGIN_VERSION', 'DOCKER_BUILDX_PLUGIN_VERSION') {
                $script:Versions[$k] | Should -Match '~ubuntu\.24\.04~noble$'
            }
        }
    }

    Context '.wslconfig' {
        It 'VM memory is half the RAM, at least 4 GB, at most 16 GB: <RamGB> GB -> <Want> GB' -TestCases @(
            @{ RamGB = 4; Want = 4 }, @{ RamGB = 6; Want = 4 }, @{ RamGB = 8; Want = 4 }, @{ RamGB = 12; Want = 6 },
            @{ RamGB = 15; Want = 7 }, @{ RamGB = 16; Want = 8 }, @{ RamGB = 24; Want = 12 }, @{ RamGB = 32; Want = 16 },
            @{ RamGB = 64; Want = 16 }
        ) {
            Get-VmMemoryGB -RamGB $RamGB | Should -Be $Want
            (Get-WslConfigSettings -Mode nat -LogicalProcessors 4 -RamGB $RamGB).Set['memory'] | Should -Be ('{0}GB' -f $Want)
        }
        It 'NAT mode: localhostForwarding, no networkingMode; processors are half the CPUs, at least 2' {
            $s = Get-WslConfigSettings -Mode nat -LogicalProcessors 2 -RamGB 16
            $text = Merge-WslConfig -Text '' -Set $s.Set -Remove $s.Remove
            $text | Should -Be "[wsl2]`r`nmemory=8GB`r`nprocessors=2`r`nswap=4GB`r`nvmIdleTimeout=-1`r`nlocalhostForwarding=true`r`n"
        }
        It 'mirrored mode: networkingMode=mirrored, localhostForwarding removed' {
            $s = Get-WslConfigSettings -Mode mirrored -LogicalProcessors 12 -RamGB 32
            $text = Merge-WslConfig -Text "[wsl2]`r`nlocalhostForwarding=true`r`nnetworkingMode=nat`r`n" -Set $s.Set -Remove $s.Remove
            $text | Should -Match 'networkingMode=mirrored'
            $text | Should -Not -Match 'localhostForwarding'
            $text | Should -Match 'processors=6'
            $text | Should -Match 'memory=16GB'
            ([regex]::Matches($text, 'networkingMode')).Count | Should -Be 1
        }
        It 'keeps unknown keys, other sections, and comments; a second merge changes nothing' {
            $old = "# my settings`r`n[wsl2]`r`nguiSupport=false`r`nmemory=4GB`r`n`r`n[experimental]`r`nautoMemoryReclaim=gradual`r`n"
            $s = Get-WslConfigSettings -Mode nat -LogicalProcessors 8 -RamGB 16
            $new = Merge-WslConfig -Text $old -Set $s.Set -Remove $s.Remove
            $new | Should -Match '# my settings'
            $new | Should -Match 'guiSupport=false'
            $new | Should -Match '\[experimental\]\r\nautoMemoryReclaim=gradual'
            $new | Should -Match 'memory=8GB'
            $new | Should -Not -Match 'memory=4GB'
            Merge-WslConfig -Text $new -Set $s.Set -Remove $s.Remove | Should -Be $new
        }
        It 'adds the [wsl2] section after other sections' {
            $s = Get-WslConfigSettings -Mode nat -LogicalProcessors 4 -RamGB 16
            $new = Merge-WslConfig -Text "[experimental]`r`nsparseVhd=true`r`n" -Set $s.Set -Remove $s.Remove
            $new | Should -Match '^\[experimental\]\r\nsparseVhd=true\r\n\r\n\[wsl2\]\r\nmemory=8GB'
        }
    }

    Context 'active hours' {
        It 'accepts at most 18 hours' {
            Test-ActiveHours -Start 6 -End 0 | Should -BeNullOrEmpty
            Get-ActiveHoursSpan -Start 6 -End 0 | Should -Be 18
            Test-ActiveHours -Start 22 -End 4 | Should -BeNullOrEmpty
            Test-ActiveHours -Start 5 -End 0 | Should -BeLike '*19 hours*at most 18*'
            Test-ActiveHours -Start 6 -End 24 | Should -BeLike '*0 to 23*'
        }
    }

    Context 'media folder facts' {
        It 'refuses <Why>' -TestCases @(
            @{ Why = 'a UNC path'; Path = '\\nas\media'; Drive = $null; Exists = $true; Msg = '*network share*' },
            @{ Why = 'a mapped network drive'; Path = 'Z:\media'; Drive = [pscustomobject]@{ DriveType = 'Network'; DriveFormat = 'NTFS'; BusType = '' }; Exists = $true; Msg = '*network drive*' },
            @{ Why = 'a removable drive'; Path = 'E:\media'; Drive = [pscustomobject]@{ DriveType = 'Removable'; DriveFormat = 'FAT32'; BusType = 'USB' }; Exists = $true; Msg = '*removable*' },
            @{ Why = 'an external USB disk'; Path = 'F:\media'; Drive = [pscustomobject]@{ DriveType = 'Fixed'; DriveFormat = 'NTFS'; BusType = 'USB' }; Exists = $true; Msg = '*USB*' },
            @{ Why = 'a FAT32 drive'; Path = 'D:\media'; Drive = [pscustomobject]@{ DriveType = 'Fixed'; DriveFormat = 'exFAT'; BusType = 'SATA' }; Exists = $true; Msg = '*not NTFS*' },
            @{ Why = 'a missing drive'; Path = 'Q:\media'; Drive = $null; Exists = $false; Msg = '*does not exist*' },
            @{ Why = 'a missing folder'; Path = 'D:\nothing'; Drive = [pscustomobject]@{ DriveType = 'Fixed'; DriveFormat = 'NTFS'; BusType = 'NVMe' }; Exists = $false; Msg = '*does not exist*' }
        ) {
            Test-MediaFolderFacts -Path $Path -Drive $Drive -Exists $Exists | Should -BeLike $Msg
        }
        It 'accepts an existing folder on a fixed internal NTFS drive' {
            Test-MediaFolderFacts -Path 'D:\Радио media' -Drive ([pscustomobject]@{ DriveType = 'Fixed'; DriveFormat = 'NTFS'; BusType = 'NVMe' }) -Exists $true |
                Should -BeNullOrEmpty
        }
    }

    Context 'scheduled tasks' {
        BeforeAll {
            $script:KaXml = New-KeepAliveTaskXml -UserId 'STATION\radio' -WslExe 'C:\Windows\System32\wsl.exe'
            $script:Ka = ([xml]$script:KaXml).DocumentElement
        }
        It 'keep-alive: at boot, repeated every 5 minutes without an end' {
            $boot = $script:Ka.Triggers.BootTrigger
            $boot | Should -Not -BeNullOrEmpty
            $boot.Repetition.Interval | Should -Be 'PT5M'
            $boot.Repetition.PSObject.Properties['Duration'] | Should -BeNullOrEmpty
            @($script:Ka.Triggers.ChildNodes).Count | Should -Be 1
        }
        It 'keep-alive: as radio whether logged on or not, not elevated' {
            $script:Ka.Principals.Principal.UserId | Should -Be 'STATION\radio'
            $script:Ka.Principals.Principal.LogonType | Should -Be 'Password'
            $script:Ka.Principals.Principal.RunLevel | Should -Be 'LeastPrivilege'
        }
        It 'keep-alive: no time limit, IgnoreNew, restart every minute, battery allowed' {
            $st = $script:Ka.Settings
            $st.ExecutionTimeLimit | Should -Be 'PT0S'
            $st.MultipleInstancesPolicy | Should -Be 'IgnoreNew'
            $st.RestartOnFailure.Interval | Should -Be 'PT1M'
            [int]$st.RestartOnFailure.Count | Should -Be 999
            $st.DisallowStartIfOnBatteries | Should -Be 'false'
            $st.StopIfGoingOnBatteries | Should -Be 'false'
        }
        It 'keep-alive: runs wsl.exe -d radio-atlantida -u radio --exec /usr/local/bin/radio-keepalive' {
            $script:Ka.Actions.Exec.Command | Should -Be 'C:\Windows\System32\wsl.exe'
            $script:Ka.Actions.Exec.Arguments | Should -Be '-d radio-atlantida -u radio --exec /usr/local/bin/radio-keepalive'
        }
        It 'recognises its own task and not a changed one' {
            Test-KeepAliveTaskXml $script:KaXml | Should -BeTrue
            Test-KeepAliveTaskXml ($script:KaXml.Replace('PT5M', 'PT1H')) | Should -BeFalse
            Test-KeepAliveTaskXml ($script:KaXml.Replace('<LogonType>Password', '<LogonType>InteractiveToken')) | Should -BeFalse
            Test-KeepAliveTaskXml '' | Should -BeFalse
        }
        It 'resume task: at logon of radio, highest privileges, runs install.bat -Resume' {
            $x = ([xml](New-ResumeTaskXml -UserId 'STATION\radio' -Command 'C:\Windows\System32\cmd.exe' -Arguments '/c ""C:\x y\install.bat" -Resume"')).DocumentElement
            $x.Triggers.LogonTrigger.UserId | Should -Be 'STATION\radio'
            $x.Principals.Principal.RunLevel | Should -Be 'HighestAvailable'
            $x.Actions.Exec.Arguments | Should -Be '/c ""C:\x y\install.bat" -Resume"'
        }
    }

    Context 'command lines and reports' {
        It 'quotes <Arg> as <Quoted>' -TestCases @(
            @{ Arg = 'plain'; Quoted = 'plain' },
            @{ Arg = '/mnt/d/Radio Atlantida'; Quoted = '"/mnt/d/Radio Atlantida"' },
            @{ Arg = 'C:\a b\'; Quoted = '"C:\a b\\"' },
            @{ Arg = 'say "hi"'; Quoted = '"say \"hi\""' },
            @{ Arg = ''; Quoted = '""' },
            @{ Arg = '/mnt/e/Радио'; Quoted = '/mnt/e/Радио' }
        ) {
            ConvertTo-CommandLineArgument $Arg | Should -Be $Quoted
        }
        It 'forwards the bound parameters to the elevated instance' {
            $b = [ordered]@{ DryRun = [switch]$true; MediaFolder = 'D:\Radio media'; Yes = [switch]$false }
            (Get-ForwardedArguments $b) -join ' ' | Should -Be '-DryRun -MediaFolder "D:\Radio media"'
        }
        It 'reports the edition, the newest KB with its date, and ESU; an old patch level only warns' {
            $os = [pscustomobject]@{ Caption = 'Microsoft Windows 10 Home'; Build = 19045; Ubr = 6456; Edition = 'Core'; DisplayVersion = '22H2' }
            $upd = [pscustomobject]@{ NewestKb = 'KB5066791'; NewestDate = [datetime]'2025-10-14'; Esu = 'not detected' }
            $r = Get-PatchReport -Os $os -Updates $upd -Now ([datetime]'2026-11-13')
            $r.Lines -join "`n" | Should -Match 'Microsoft Windows 10 Home \(Core\), build 19045\.6456, version 22H2'
            $r.Lines -join "`n" | Should -Match 'KB5066791, installed 2025-10-14'
            $r.Lines -join "`n" | Should -Match 'ESU\): not detected'
            $r.Warnings -join "`n" | Should -Match '395 days old'
            $upd.Esu = 'enrolled (Windows 10 ESU Year 2)'
            $upd.NewestDate = [datetime]'2026-11-01'
            $r = Get-PatchReport -Os $os -Updates $upd -Now ([datetime]'2026-11-13')
            $r.Warnings -join "`n" | Should -Match 'Pause updates'
            $r.Warnings -join "`n" | Should -Not -Match 'days old'
        }
    }
}

Describe 'install runs' {
    BeforeEach {
        Reset-Fake
        Remove-Item -Recurse -Force -LiteralPath (Join-Path $TestDrive 'state'), (Join-Path $TestDrive 'profile'), (Join-Path $TestDrive 'desktop'), (Join-Path $TestDrive 'root') -ErrorAction SilentlyContinue
        $script:Ctx = @{}

        Mock Test-Administrator { $true }
        Mock Get-OsFacts { $script:Fake.Os }
        Mock Get-UpdateFacts { $script:Fake.Updates }
        Mock Get-HardwareFacts { $script:Fake.Hardware }
        Mock Get-CurrentAccountName { $script:Fake.Account }
        Mock Test-DockerDesktop { $script:Fake.DockerDesktop }
        Mock Get-FreeSpaceGB { $script:Fake.FreeGB }
        Mock Test-UrlReachable { $true }
        Mock Get-FeatureState { $script:Fake.Features[$Name] }
        Mock Get-WslExe { 'C:\Windows\System32\wsl.exe' }
        Mock Get-CmdExe { 'C:\Windows\System32\cmd.exe' }
        Mock Get-RepoWslPath { '/mnt/c/Users/radio/Downloads/radio-atlantida-deploy' }
        Mock Invoke-Native { Invoke-FakeNative -FilePath $FilePath -ArgumentList $ArgumentList -Interactive ([bool]$Interactive) }
        Mock Get-ScheduledTaskXml { $script:Fake.Tasks[$Name] }
        Mock Register-TaskFromXml {
            if ($null -ne $Password -and $script:Fake.RegisterFailures -gt 0) {
                $script:Fake.RegisterFailures--
                throw 'The user name or password is incorrect.'
            }
            $script:Fake.Tasks[$Name] = $Xml
            $script:Fake.Calls.Add(('REGISTER {0} user={1} password={2}' -f $Name, $User, ($null -ne $Password)))
        }
        Mock Remove-ScheduledTaskByName { $script:Fake.Tasks.Remove($Name); $script:Fake.Calls.Add("UNREGISTER $Name") }
        Mock Start-ScheduledTaskByName { $script:Fake.Calls.Add("START $Name") }
        Mock Read-Secret { (New-Object System.Net.NetworkCredential('', $script:Password)).SecurePassword }
        Mock Read-Answer { $Default }
        Mock Confirm-Action { $true }
        Mock Restart-Host { $script:Fake.Restarted = $true }
        Mock Get-DriveFacts { $script:Fake.Drive }
        Mock Test-FolderExists { if ($Path -eq 'C:\RadioAtlantida\backups') { return $script:Fake.BackupDir } $script:Fake.FolderExists }
        Mock New-Folder { if ($Path -eq 'C:\RadioAtlantida\backups') { $script:Fake.BackupDir = $true } else { New-Item -ItemType Directory -Force -Path $Path | Out-Null } }
        Mock Get-DefenderExclusions { if ($script:Fake.DefenderAvailable) { return , @($script:Fake.Exclusions) } return $null }
        Mock Add-DefenderExclusion { $script:Fake.Exclusions += $Path; $script:Fake.Calls.Add("EXCLUDE $Path") }
        Mock Test-FolderNotIndexed { $script:Fake.NotIndexed }
        Mock Set-FolderNotIndexed { $script:Fake.NotIndexed = $true; $script:Fake.Calls.Add("NOINDEX $Path") }
        Mock Get-RegistryValue { $script:Fake.Registry["$Path|$Name"] }
        Mock Set-RegistryValue { $script:Fake.Registry["$Path|$Name"] = $Value; $script:Fake.Calls.Add("REG $Name=$Value") }
        Mock Set-TimeServiceAutomatic { $script:Fake.Calls.Add('W32TIME automatic') }
        Mock Save-Download { New-Item -ItemType Directory -Force -Path (Split-Path -Parent $Path) | Out-Null; Set-Content -LiteralPath $Path -Value 'rootfs'; $script:Fake.Calls.Add("DOWNLOAD $Url") }
        Mock Get-FileSha256 { $script:Fake.Sha }
        Mock New-ShellShortcut { New-Item -ItemType Directory -Force -Path (Split-Path -Parent $Path) | Out-Null; Set-Content -LiteralPath $Path -Value $Target }
        Mock Test-LocalAccount { $false }
        Mock New-LocalAdminAccount { $script:Fake.Calls.Add("NEWUSER $Name") }
        Mock Write-Host { }
    }

    Context 'a fresh Windows 10 machine' {
        It 'enables the features, registers the resume task, asks to restart, and stops there' {
            Invoke-TestInstall | Should -Be 3010
            Get-FakeCalls 'dism.exe*' | Should -HaveCount 2
            $script:Fake.Tasks[$script:ResumeTaskName] | Should -Match '<LogonTrigger>'
            $script:Fake.Tasks[$script:ResumeTaskName] | Should -Match '-Resume'
            $script:Fake.Tasks[$script:ResumeTaskName] | Should -Not -Match 'MinFreeGB'
            $script:Fake.Restarted | Should -BeTrue
            Get-FakeCalls 'wsl.exe*' | Should -HaveCount 0
            (Get-SavedState).steps.Keys | Should -Contain 'features'
        }

        It 'the resume task keeps an explicit -MinFreeGB' {
            Invoke-TestInstall -Options @{ MinFreeGB = 15 } | Should -Be 3010
            $script:Fake.Tasks[$script:ResumeTaskName] | Should -Match '-Resume -InstallRoot .* -MinFreeGB 15'
        }

        It 'after the restart, -Resume removes the resume task and installs everything' {
            Invoke-TestInstall | Should -Be 3010
            foreach ($k in @($script:Fake.Features.Keys)) { $script:Fake.Features[$k] = 'Enabled' }
            $script:Fake.Calls.Clear()
            Invoke-TestInstall -Options @{ Resume = $true } | Should -Be 0
            $script:Fake.Calls | Should -Contain "UNREGISTER $($script:ResumeTaskName)"
            Get-FakeCalls 'dism.exe*' | Should -HaveCount 0
            $log = Get-RunLog
            $log | Should -Match 'Resuming after the restart'

            # WSL from the Store, NAT mode, .wslconfig
            Get-FakeCalls 'wsl.exe --update*' | Should -HaveCount 1
            (Get-SavedState).values.network_mode | Should -Be 'nat'
            $cfg = Get-WslConfigText
            $cfg | Should -Match 'localhostForwarding=true'
            $cfg | Should -Not -Match 'networkingMode'
            $cfg | Should -Match 'processors=4'
            # the support note of Windows 10, once
            $log | Should -Match 'end of support on 14 October 2025'

            # media folder, Defender, indexing, the Windows backup folder
            $script:Fake.Calls | Should -Contain 'EXCLUDE D:\RadioAtlantida\media'
            $script:Fake.Calls | Should -Contain 'NOINDEX D:\RadioAtlantida\media'
            $script:Fake.BackupDir | Should -BeTrue

            # pinned rootfs, checksum, import
            $script:Fake.Calls | Should -Contain "DOWNLOAD $($script:Versions['UBUNTU_ROOTFS_URL'])"
            @(Get-FakeCalls 'wsl.exe --import radio-atlantida *--version 2').Count | Should -Be 1

            # the Linux half twice, with a restart of the distribution between
            $setup = @($script:Fake.Calls | Where-Object { $_ -like '*--exec bash /var/lib/radio-atlantida/src/install/setup-distro.sh --network-mode nat --media-root /mnt/d/RadioAtlantida/media' -or $_ -like 'wsl.exe --terminate radio-atlantida' })
            $setup | Should -HaveCount 3
            $setup[1] | Should -Be 'wsl.exe --terminate radio-atlantida'
            Get-FakeCalls '*--exec cp -R /mnt/c/Users/radio/Downloads/radio-atlantida-deploy/install /mnt/c/Users/radio/Downloads/radio-atlantida-deploy/docker-compose.yml /var/lib/radio-atlantida/src/' | Should -HaveCount 1

            # keep-alive task with the stored password, started
            $script:Fake.Calls | Should -Contain "REGISTER $($script:KeepAliveTaskName) user=STATION\radio password=True"
            Test-KeepAliveTaskXml $script:Fake.Tasks[$script:KeepAliveTaskName] | Should -BeTrue
            $script:Fake.Calls | Should -Contain "START $($script:KeepAliveTaskName)"

            # hardening: power, active hours 6-24, NTP; no Pro-only policy
            Get-FakeCalls 'powercfg.exe /hibernate off' | Should -HaveCount 1
            Get-FakeCalls 'powercfg.exe /change standby-timeout-ac 0' | Should -HaveCount 1
            $script:Fake.Calls | Should -Contain 'REG ActiveHoursStart=6'
            $script:Fake.Calls | Should -Contain 'REG ActiveHoursEnd=0'
            Get-FakeCalls 'REG AUOptions*' | Should -HaveCount 0
            Get-FakeCalls 'REG NoAutoUpdate*' | Should -HaveCount 0
            Get-FakeCalls 'w32tm.exe /config /syncfromflags:manual*' | Should -HaveCount 1

            # repository, network values, first run in the same window
            Get-FakeCalls '*--exec git clone https://github.com/AstRonin/radio-atlantida-deploy /opt/radio-atlantida/deploy' | Should -HaveCount 1
            Get-FakeCalls '*-u root --exec systemctl start radio-network.service' | Should -HaveCount 1
            Get-FakeCalls 'INTERACTIVE wsl.exe -d radio-atlantida -u radio --cd /opt/radio-atlantida/deploy --exec bin/radioctl first-run --media-root /mnt/d/RadioAtlantida/media' | Should -HaveCount 1

            # shortcuts
            $desk = Join-Path $TestDrive 'desktop'
            Read-TextFile (Join-Path $desk 'Radio panel.url') | Should -Match 'URL=http://127.0.0.1:8080'
            Read-TextFile (Join-Path $desk 'Radio Grafana.url') | Should -Match 'URL=http://127.0.0.1:3000'
            Test-Path (Join-Path $desk 'Radio media.lnk') | Should -BeTrue
            Test-Path (Join-Path $desk 'Radio update.lnk') | Should -BeTrue
            Test-Path (Join-Path (Join-Path $TestDrive 'root') 'update.bat') | Should -BeTrue

            $steps = (Get-SavedState).steps.Keys
            foreach ($s in 'features', 'wsl', 'network-mode', 'wslconfig', 'folders', 'distro', 'linux', 'keepalive', 'hardening', 'deploy', 'shortcuts') {
                $steps | Should -Contain $s
            }
        }

        It 'logs the edition and the newest KB with its date; an old patch level is only a warning' {
            foreach ($k in @($script:Fake.Features.Keys)) { $script:Fake.Features[$k] = 'Enabled' }
            Invoke-TestInstall | Should -Be 0
            $log = Get-RunLog
            $log | Should -Match 'Windows: Microsoft Windows 10 Home \(Core\), build 19045.6456'
            $log | Should -Match 'Newest installed update: KB5066791, installed 2025-10-14'
            $log | Should -Match 'Extended Security Updates \(ESU\): not detected'
            $log | Should -Match 'WARNING: the newest installed update is 395 days old'
        }

        It 'never writes the Windows password to the log' {
            foreach ($k in @($script:Fake.Features.Keys)) { $script:Fake.Features[$k] = 'Enabled' }
            $script:Fake.RegisterFailures = 1
            Invoke-TestInstall | Should -Be 0
            Should -Invoke Read-Secret -Times 2 -Exactly
            $log = Get-RunLog
            $log | Should -Not -Match ([regex]::Escape($script:Password))
            $log | Should -Match 'wrong password'
            $script:Fake.Calls | Should -Contain "REGISTER $($script:KeepAliveTaskName) user=STATION\radio password=True"
        }
    }

    Context 'a second run' {
        It 'changes nothing: only the idempotent Linux half runs again' {
            foreach ($k in @($script:Fake.Features.Keys)) { $script:Fake.Features[$k] = 'Enabled' }
            Invoke-TestInstall | Should -Be 0
            $script:Fake.Calls.Clear()
            $before = Get-WslConfigText
            Remove-Item -LiteralPath $script:Ctx.LogFile
            Invoke-TestInstall | Should -Be 0
            $calls = @($script:Fake.Calls)
            @($calls | Where-Object { $_ -like 'dism.exe*' -or $_ -like 'REGISTER*' -or $_ -like 'REG *' -or $_ -like 'EXCLUDE*' -or $_ -like 'NOINDEX*' -or
                    $_ -like 'DOWNLOAD*' -or $_ -like '*--import*' -or $_ -like '*--terminate*' -or $_ -like '*--shutdown*' -or $_ -like 'INTERACTIVE*' -or
                    $_ -like 'powercfg*' -or $_ -like 'w32tm*' -or $_ -like '*git clone*' -or $_ -like 'wsl.exe --update*' }) | Should -HaveCount 0
            @($calls | Where-Object { $_ -like '*setup-distro.sh*' }) | Should -HaveCount 1
            Get-WslConfigText | Should -Be $before
            Get-RunLog | Should -Match 'done \(recorded'
            Get-RunLog | Should -Not -Match 'end of support on 14 October 2025'
        }
    }

    Context '-DryRun' {
        It 'checks every step and changes nothing' {
            Invoke-TestInstall -Options @{ DryRun = $true } | Should -Be 0
            Test-Path (Join-Path (Join-Path $TestDrive 'state') 'install-state.json') | Should -BeFalse
            Test-Path (Join-Path (Join-Path $TestDrive 'profile') '.wslconfig') | Should -BeFalse
            $mutating = @($script:Fake.Calls | Where-Object { $_ -notlike 'wsl.exe --version' -and $_ -notlike 'wsl.exe -l -q' -and $_ -notlike '*--exec grep*' })
            $mutating | Should -HaveCount 0
            Should -Invoke Register-TaskFromXml -Times 0
            Should -Invoke Set-RegistryValue -Times 0
            Should -Invoke Add-DefenderExclusion -Times 0
            Should -Invoke Read-Secret -Times 0
            Should -Invoke Restart-Host -Times 0
            $log = Get-RunLog
            $log | Should -Match 'DRY RUN: every step is checked; nothing is changed.'
            $log | Should -Match '\[dry-run\] not in place: would run'
            $script:Ctx.LogFile | Should -Match '-dry-run\.log$'
        }
    }

    Context 'preflight stops' {
        BeforeEach { foreach ($k in @($script:Fake.Features.Keys)) { $script:Fake.Features[$k] = 'Enabled' } }
        It 'stops on <Why> before any change' -TestCases @(
            @{ Why = 'a build below 19044'; Set = { $script:Fake.Os.Build = 19043 }; Msg = '*too old*' },
            @{ Why = 'Windows 10 without the WSL update level'; Set = { $script:Fake.Os.Ubr = 1288 }; Msg = '*19045.2311 or later*' },
            @{ Why = 'virtualization off'; Set = { $script:Fake.Hardware.VirtualizationFirmwareEnabled = $false }; Msg = '*virtualization is off*' },
            @{ Why = 'Docker Desktop'; Set = { $script:Fake.DockerDesktop = $true }; Msg = '*Docker Desktop is installed*' },
            @{ Why = 'the wrong account'; Set = { $script:Fake.Account = 'manager' }; Msg = "*signed in as the local account 'radio' (now: 'manager')*install.bat -CreateAccount*" },
            @{ Why = 'too little disk space'; Set = { $script:Fake.FreeGB = 19 }; Msg = '*19 GB free*at least 20 GB*-MinFreeGB*' },
            @{ Why = 'ARM64 Windows'; Set = { $script:Fake.Os.Architecture = 'ARM64' }; Msg = '*64-bit x86*' }
        ) {
            & $Set
            Invoke-TestInstall | Should -Be 1
            Get-RunLog | Should -BeLike ("*STOPPED: $Msg")
            @($script:Fake.Calls | Where-Object { $_ -notlike 'wsl.exe -l -q' }) | Should -HaveCount 0
        }
    }

    Context 'Windows 11' {
        It 'chooses mirrored mode, writes networkingMode=mirrored, and prints no Windows 10 note' {
            foreach ($k in @($script:Fake.Features.Keys)) { $script:Fake.Features[$k] = 'Enabled' }
            $script:Fake.Os.Build = 26100
            $script:Fake.Os.Caption = 'Microsoft Windows 11 Home'
            Invoke-TestInstall | Should -Be 0
            (Get-SavedState).values.network_mode | Should -Be 'mirrored'
            Get-WslConfigText | Should -Match 'networkingMode=mirrored'
            Get-WslConfigText | Should -Not -Match 'localhostForwarding'
            Get-FakeCalls '*setup-distro.sh --network-mode mirrored*' | Should -HaveCount 2
            Get-RunLog | Should -Not -Match 'end of support'
        }
    }

    Context 'steps' {
        BeforeEach { foreach ($k in @($script:Fake.Features.Keys)) { $script:Fake.Features[$k] = 'Enabled' } }

        It 'features already enabled: no dism, no reboot' {
            Invoke-TestInstall | Should -Be 0
            Get-FakeCalls 'dism.exe*' | Should -HaveCount 0
            $script:Fake.Restarted | Should -BeFalse
            $script:Fake.Tasks.ContainsKey($script:ResumeTaskName) | Should -BeFalse
        }

        It 'WSL at the minimum is not updated; below it runs wsl --update; no version after it stops' {
            $script:Fake.WslVersion = $script:Versions['WSL_MIN_VERSION']
            Invoke-TestInstall | Should -Be 0
            Get-FakeCalls 'wsl.exe --update*' | Should -HaveCount 0

            Reset-Fake
            foreach ($k in @($script:Fake.Features.Keys)) { $script:Fake.Features[$k] = 'Enabled' }
            Remove-Item -Recurse -Force (Join-Path $TestDrive 'state')
            $script:Fake.WslVersion = '2.0.9.0'
            Invoke-TestInstall | Should -Be 0
            Get-FakeCalls 'wsl.exe --update' | Should -HaveCount 1

            Reset-Fake
            foreach ($k in @($script:Fake.Features.Keys)) { $script:Fake.Features[$k] = 'Enabled' }
            Remove-Item -Recurse -Force (Join-Path $TestDrive 'state')
            $script:Fake.WslAfterUpdate = $null
            Invoke-TestInstall | Should -Be 1
            Get-RunLog | Should -Match 'STOPPED: wsl --version prints no version: the Store WSL is not available'
        }

        It 'a failed Store update retries with --web-download' {
            $script:Fake.UpdateRc = 1
            Invoke-TestInstall | Should -Be 0
            Get-FakeCalls 'wsl.exe --update --web-download' | Should -HaveCount 1
        }

        It '.wslconfig keeps the keys it does not own' {
            New-Item -ItemType Directory -Force (Join-Path $TestDrive 'profile') | Out-Null
            Write-TextFile -Path (Join-Path (Join-Path $TestDrive 'profile') '.wslconfig') -Text "[wsl2]`r`nguiSupport=false`r`nmemory=2GB`r`n[experimental]`r`nsparseVhd=true`r`n"
            Invoke-TestInstall | Should -Be 0
            $cfg = Get-WslConfigText
            $cfg | Should -Match 'guiSupport=false'
            $cfg | Should -Match 'sparseVhd=true'
            $cfg | Should -Match 'memory=8GB'
        }

        It '.wslconfig gives the VM half the RAM of the machine' {
            $script:Fake.Hardware.RamGB = 12
            Invoke-TestInstall | Should -Be 0
            Get-WslConfigText | Should -Match 'memory=6GB'
            Get-RunLog | Should -BeLike '*12 GB RAM is below the recommended 16 GB (the WSL VM gets 6 GB)*'
        }

        It 'an existing distribution is kept: no download, no import' {
            $script:Fake.Distros = @('Ubuntu', 'radio-atlantida')
            Invoke-TestInstall | Should -Be 0
            Get-FakeCalls 'DOWNLOAD*' | Should -HaveCount 0
            Get-FakeCalls '*--import*' | Should -HaveCount 0
        }

        It 'a rootfs checksum mismatch stops before the import' {
            $script:Fake.Sha = '0' * 64
            Invoke-TestInstall | Should -Be 1
            Get-RunLog | Should -Match 'STOPPED: the downloaded root file system has SHA-256 0{64}, install\\versions.env pins'
            Get-FakeCalls '*--import*' | Should -HaveCount 0
            $script:Fake.Distros | Should -HaveCount 0
        }

        It 'a setup-distro.sh failure stops with the log path' {
            $script:Fake.SetupRc.Clear()
            $script:Fake.SetupRc.Enqueue(1)
            Invoke-TestInstall | Should -Be 1
            Get-RunLog | Should -Match 'STOPPED: setup-distro.sh failed \(exit 1\); its output is in .*install-.*\.log'
            Get-FakeCalls 'REGISTER*' | Should -HaveCount 0
        }

        It 'free space: 20 GB is the default minimum of a first install' {
            $script:Fake.FreeGB = 20
            Invoke-TestInstall | Should -Be 0
            $script:Ctx.MinFreeGB | Should -Be 20
            Get-RunLog | Should -Not -Match 'MinFreeGB'
        }

        It 'free space: -MinFreeGB lower lets a first install continue, with a warning' {
            $script:Fake.FreeGB = 12
            Invoke-TestInstall -Options @{ MinFreeGB = 10 } | Should -Be 0
            $log = Get-RunLog
            $log | Should -Match 'WARNING: -MinFreeGB 10: the free space check is lowered below the recommended 20 GB'
            $log | Should -Match '12 GB free'
            $script:Fake.Distros | Should -Contain 'radio-atlantida'
        }

        It 'free space: a fresh install stops below an explicit -MinFreeGB' {
            $script:Fake.FreeGB = 25
            Invoke-TestInstall -Options @{ MinFreeGB = 30 } | Should -Be 1
            Get-RunLog | Should -BeLike '*STOPPED: 25 GB free*at least 30 GB*'
            Get-FakeCalls 'wsl.exe --import*' | Should -HaveCount 0
        }

        It 'free space: an existing distribution only warns below the minimum' {
            $script:Fake.Distros = @('radio-atlantida')
            $script:Fake.FreeGB = 5
            Invoke-TestInstall | Should -Be 0
            Get-RunLog | Should -Match 'WARNING: 5 GB free on the drive of'
        }

        It 'a restart of the distribution on an installed station needs a yes; no means stop' {
            $script:Fake.Distros = @('radio-atlantida')
            $script:Fake.Installed = $true
            Mock Confirm-Action { $false }
            Invoke-TestInstall | Should -Be 1
            Get-FakeCalls '*--terminate*' | Should -HaveCount 0
            Get-RunLog | Should -Match 'interrupts the air'
        }

        It 'the keep-alive task stops after three wrong passwords' {
            $script:Fake.RegisterFailures = 3
            Invoke-TestInstall | Should -Be 1
            Get-RunLog | Should -Match 'STOPPED: the keep-alive task could not be registered after 3 attempts'
        }

        It 'the media folder must be on a local NTFS drive' {
            $script:Fake.Drive = [pscustomobject]@{ DriveType = 'Network'; DriveFormat = 'NTFS'; BusType = '' }
            Invoke-TestInstall -Options @{ MediaFolder = 'Z:\media' } | Should -Be 1
            Get-RunLog | Should -Match 'STOPPED: media folder: drive Z: is a network drive'
        }

        It 'the media folder from -MediaFolder with spaces and Cyrillic gets its WSL path; an existing exclusion is not added again' {
            $script:Fake.Exclusions = @('E:\Радио Атлантида')
            Invoke-TestInstall -Options @{ MediaFolder = 'E:\Радио Атлантида\' } | Should -Be 0
            (Get-SavedState).values.media_wsl | Should -Be '/mnt/e/Радио Атлантида'
            Get-FakeCalls 'EXCLUDE*' | Should -HaveCount 0
            Get-FakeCalls '*first-run --media-root /mnt/e/Радио Атлантида' | Should -HaveCount 1
        }

        It 'without Defender the exclusion is a warning' {
            $script:Fake.DefenderAvailable = $false
            Invoke-TestInstall | Should -Be 0
            Get-RunLog | Should -Match 'WARNING: Microsoft Defender is not available'
        }

        It 'active hours are the operator window; more than 18 hours stops' {
            Invoke-TestInstall -Options @{ ActiveHoursStart = 7; ActiveHoursEnd = 1 } | Should -Be 0
            $script:Fake.Calls | Should -Contain 'REG ActiveHoursStart=7'
            $script:Fake.Calls | Should -Contain 'REG ActiveHoursEnd=1'

            Reset-Fake
            foreach ($k in @($script:Fake.Features.Keys)) { $script:Fake.Features[$k] = 'Enabled' }
            Remove-Item -Recurse -Force (Join-Path $TestDrive 'state')
            Invoke-TestInstall -Options @{ ActiveHoursStart = 5; ActiveHoursEnd = 0 } | Should -Be 1
            Get-RunLog | Should -Match 'STOPPED: active hours 5-0 span 19 hours; Windows allows at most 18'
        }

        It 'a failed first run stops; the next run tries it again' {
            $script:Fake.FirstRunRc = 1
            Invoke-TestInstall | Should -Be 1
            Get-RunLog | Should -Match 'STOPPED: radioctl first-run failed'
            $script:Fake.FirstRunRc = 0
            $script:Fake.Calls.Clear()
            Invoke-TestInstall | Should -Be 0
            Get-FakeCalls 'INTERACTIVE*first-run*' | Should -HaveCount 1
            Get-FakeCalls '*git -C /opt/radio-atlantida/deploy pull --ff-only' | Should -HaveCount 1
        }
    }

    Context '-CreateAccount' {
        It 'creates the local administrator when missing' {
            Invoke-TestInstall -CreateAccount | Should -Be 0
            $script:Fake.Calls | Should -Contain 'NEWUSER radio'
            Get-RunLog | Should -Not -Match ([regex]::Escape($script:Password))
        }
        It 'stops when the passwords differ' {
            $script:n = 0
            Mock Read-Secret { $script:n++; (New-Object System.Net.NetworkCredential('', ('pw' + $script:n))).SecurePassword }
            Invoke-TestInstall -CreateAccount | Should -Be 1
            Should -Invoke New-LocalAdminAccount -Times 0
        }
        It 'does nothing when the account exists' {
            Mock Test-LocalAccount { $true }
            Invoke-TestInstall -CreateAccount | Should -Be 0
            Should -Invoke New-LocalAdminAccount -Times 0
        }
    }
}
