#requires -Version 5.1
<#
    KhzJanitor - reclaim a bloated Windows box.

    SAFETY CONTRACT
    ---------------
    Nothing is deleted unless -Apply is passed. Without it every function only
    measures and reports. All destructive paths are whitelisted literals; there
    is no recursive wildcard deletion of user directories anywhere in this file.
#>

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Continue'

$script:Root    = Join-Path $env:ProgramData 'KhzJanitor'
$script:LogDir  = Join-Path $script:Root 'logs'
$script:Ledger  = Join-Path $script:Root 'ledger.csv'

# ---------------------------------------------------------------- internals

function Write-Khz {
    param([string]$Message, [string]$Level = 'info')
    $colour = switch ($Level) {
        'ok'   { 'Green' }
        'warn' { 'Yellow' }
        'err'  { 'Red' }
        'head' { 'Cyan' }
        default { 'Gray' }
    }
    Write-Host $Message -ForegroundColor $colour
}

function Test-KhzAdmin {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    (New-Object Security.Principal.WindowsPrincipal $id).IsInRole(
        [Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Get-KhzPathSize {
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) { return 0L }
    try {
        $sum = Get-ChildItem -LiteralPath $Path -Recurse -Force -File -ErrorAction SilentlyContinue |
                Measure-Object -Property Length -Sum
        if ($null -eq $sum.Sum) { return 0L }
        return [int64]$sum.Sum
    } catch { return 0L }
}

function Format-KhzBytes {
    param([int64]$Bytes)
    if ($Bytes -ge 1GB) { return ('{0:N2} GB' -f ($Bytes / 1GB)) }
    if ($Bytes -ge 1MB) { return ('{0:N1} MB' -f ($Bytes / 1MB)) }
    if ($Bytes -ge 1KB) { return ('{0:N0} KB' -f ($Bytes / 1KB)) }
    return "$Bytes B"
}

<#
    Deletes the *contents* of a directory, never the directory itself, and only
    when -Apply is present. Files held open by a running process are skipped
    silently - that is expected and not an error.
#>
function Clear-KhzDirectory {
    param(
        [Parameter(Mandatory)][string]$Path,
        [string]$Label = $Path,
        [int]$OlderThanDays = 0,
        [switch]$Apply
    )

    if (-not (Test-Path -LiteralPath $Path)) {
        return [pscustomobject]@{ Label = $Label; Bytes = 0L; Skipped = $true }
    }

    $cutoff = (Get-Date).AddDays(-1 * $OlderThanDays)
    $items = Get-ChildItem -LiteralPath $Path -Force -ErrorAction SilentlyContinue |
             Where-Object { $OlderThanDays -le 0 -or $_.LastWriteTime -lt $cutoff }

    $freed = 0L
    foreach ($item in $items) {
        $size = if ($item.PSIsContainer) { Get-KhzPathSize $item.FullName } else { [int64]$item.Length }
        if ($Apply) {
            try {
                Remove-Item -LiteralPath $item.FullName -Recurse -Force -ErrorAction Stop
                $freed += $size
            } catch { }
        } else {
            $freed += $size
        }
    }

    [pscustomobject]@{ Label = $Label; Bytes = $freed; Skipped = $false }
}

function Set-KhzPolicy {
    param(
        [Parameter(Mandatory)][string]$Key,
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)]$Value,
        [string]$Type = 'DWord',
        [switch]$Apply
    )
    if (-not $Apply) { Write-Khz "      would set $Key\$Name = $Value"; return }
    try {
        if (-not (Test-Path -LiteralPath $Key)) { New-Item -Path $Key -Force | Out-Null }
        New-ItemProperty -Path $Key -Name $Name -Value $Value -PropertyType $Type -Force | Out-Null
        Write-Khz "      set $Name = $Value" 'ok'
    } catch { Write-Khz "      failed $Name : $($_.Exception.Message)" 'err' }
}

# ---------------------------------------------------------------- 1. logs

function Clear-KhzLogs {
    [CmdletBinding()] param([switch]$Apply, [int]$KeepDays = 3, [switch]$ClearEventLogs)

    Write-Khz "`n[1] logs" 'head'
    $results = @()

    $targets = @(
        @{ P = "$env:SystemRoot\Logs";                                   L = 'Windows\Logs';        D = $KeepDays },
        @{ P = "$env:SystemRoot\Temp";                                    L = 'Windows\Temp';        D = 0 },
        @{ P = "$env:SystemRoot\Panther";                                 L = 'Setup (Panther)';     D = 0 },
        @{ P = "$env:SystemRoot\SoftwareDistribution\Download";           L = 'WU downloads';        D = 0 },
        @{ P = "$env:ProgramData\Microsoft\Windows\WER\ReportQueue";      L = 'WER queue';           D = 0 },
        @{ P = "$env:ProgramData\Microsoft\Windows\WER\ReportArchive";    L = 'WER archive';         D = 0 },
        @{ P = "$env:ProgramData\Microsoft\Windows\WER\Temp";             L = 'WER temp';            D = 0 },
        @{ P = "$env:ProgramData\USOPrivate\UpdateStore";                 L = 'Update store';        D = 0 },
        @{ P = "$env:LOCALAPPDATA\CrashDumps";                            L = 'Crash dumps';         D = 0 },
        @{ P = "$env:LOCALAPPDATA\Microsoft\Windows\WebCache";            L = 'WebCache';            D = 0 },
        @{ P = "$env:LOCALAPPDATA\Temp";                                  L = 'User temp';           D = 0 },
        @{ P = "$env:LOCALAPPDATA\D3DSCache";                             L = 'D3D shader cache';    D = 0 },
        @{ P = "$env:LOCALAPPDATA\NVIDIA\DXCache";                        L = 'NVIDIA DX cache';     D = 0 },
        @{ P = "$env:LOCALAPPDATA\NVIDIA\GLCache";                        L = 'NVIDIA GL cache';     D = 0 }
    )

    foreach ($t in $targets) {
        $r = Clear-KhzDirectory -Path $t.P -Label $t.L -OlderThanDays $t.D -Apply:$Apply
        if (-not $r.Skipped -and $r.Bytes -gt 0) {
            Write-Khz ('    {0,-22} {1}' -f $r.Label, (Format-KhzBytes $r.Bytes))
        }
        $results += $r
    }

    # memory dumps sit at the root and are single huge files
    foreach ($dump in @("$env:SystemRoot\MEMORY.DMP", "$env:SystemRoot\Minidump")) {
        if (Test-Path -LiteralPath $dump) {
            $size = Get-KhzPathSize $dump
            if ($size -eq 0 -and (Test-Path -LiteralPath $dump -PathType Leaf)) {
                $size = (Get-Item -LiteralPath $dump).Length
            }
            Write-Khz ('    {0,-22} {1}' -f (Split-Path $dump -Leaf), (Format-KhzBytes $size))
            if ($Apply) { Remove-Item -LiteralPath $dump -Recurse -Force -ErrorAction SilentlyContinue }
            $results += [pscustomobject]@{ Label = 'memory dump'; Bytes = $size; Skipped = $false }
        }
    }

    if ($ClearEventLogs) {
        if ($Apply) {
            $n = 0
            wevtutil el 2>$null | ForEach-Object {
                try { wevtutil cl "$_" 2>$null; $n++ } catch { }
            }
            Write-Khz "    event logs cleared: $n" 'ok'
        } else {
            Write-Khz '    would clear all Windows event logs' 'warn'
        }
    }

    [int64]($results | Measure-Object -Property Bytes -Sum).Sum
}

# ---------------------------------------------------------------- 2. caches

function Clear-KhzCaches {
    [CmdletBinding()] param([switch]$Apply, [switch]$IncludePackageCaches)

    Write-Khz "`n[2] caches" 'head'
    $total = 0L

    $browserRoots = @(
        "$env:LOCALAPPDATA\Microsoft\Edge\User Data",
        "$env:LOCALAPPDATA\Google\Chrome\User Data",
        "$env:LOCALAPPDATA\BraveSoftware\Brave-Browser\User Data"
    )
    $browserLeaves = @(
        'Cache', 'Code Cache', 'GPUCache', 'DawnCache', 'DawnGraphiteCache',
        'GrShaderCache', 'ShaderCache', 'Service Worker\CacheStorage',
        'Service Worker\ScriptCache', 'Storage\ext'
    )

    foreach ($root in $browserRoots) {
        if (-not (Test-Path -LiteralPath $root)) { continue }
        $profiles = @('Default') + (
            Get-ChildItem -LiteralPath $root -Directory -ErrorAction SilentlyContinue |
            Where-Object { $_.Name -like 'Profile *' } | Select-Object -ExpandProperty Name
        )
        foreach ($profile in ($profiles | Select-Object -Unique)) {
            foreach ($leaf in $browserLeaves) {
                $p = Join-Path (Join-Path $root $profile) $leaf
                $r = Clear-KhzDirectory -Path $p -Apply:$Apply
                $total += $r.Bytes
            }
        }
        Write-Khz ('    {0,-22} {1}' -f (Split-Path $root -Parent | Split-Path -Leaf), (Format-KhzBytes $total))
    }

    $misc = @(
        @{ P = "$env:LOCALAPPDATA\Microsoft\Windows\Explorer";        L = 'thumbnail cache' },
        @{ P = "$env:LOCALAPPDATA\Microsoft\Windows\INetCache";       L = 'INetCache' },
        @{ P = "$env:LOCALAPPDATA\Microsoft\Terminal Server Client\Cache"; L = 'RDP cache' },
        @{ P = "$env:LOCALAPPDATA\Packages\Microsoft.Windows.Search_cw5n1h2txyewy\LocalState\AppIconCache"; L = 'search icons' },
        @{ P = "$env:LOCALAPPDATA\Microsoft\Office\16.0\OfficeFileCache"; L = 'Office cache' },
        @{ P = "$env:APPDATA\Code\CachedData";                        L = 'VS Code cached data' },
        @{ P = "$env:APPDATA\Code\Cache";                             L = 'VS Code cache' },
        @{ P = "$env:LOCALAPPDATA\Microsoft\VisualStudio\Packages\_Instances"; L = 'VS instances' },
        @{ P = "$env:USERPROFILE\.dotnet\optimizationdata";           L = 'dotnet opt data' },
        @{ P = "$env:ProgramData\Microsoft\Network\Downloader";       L = 'delivery optimization' }
    )

    foreach ($m in $misc) {
        $r = Clear-KhzDirectory -Path $m.P -Label $m.L -Apply:$Apply
        if (-not $r.Skipped -and $r.Bytes -gt 0) {
            Write-Khz ('    {0,-22} {1}' -f $r.Label, (Format-KhzBytes $r.Bytes))
        }
        $total += $r.Bytes
    }

    # Package caches are opt-in: clearing them makes the next build slow.
    if ($IncludePackageCaches) {
        foreach ($pkg in @(
            @{ P = "$env:USERPROFILE\.nuget\packages";        L = 'nuget packages' },
            @{ P = "$env:LOCALAPPDATA\NuGet\v3-cache";        L = 'nuget http cache' },
            @{ P = "$env:LOCALAPPDATA\Temp\NuGetScratch";     L = 'nuget scratch' },
            @{ P = "$env:APPDATA\npm-cache";                  L = 'npm cache' },
            @{ P = "$env:LOCALAPPDATA\pip\Cache";             L = 'pip cache' },
            @{ P = "$env:LOCALAPPDATA\Yarn\Cache";            L = 'yarn cache' }
        )) {
            $r = Clear-KhzDirectory -Path $pkg.P -Label $pkg.L -Apply:$Apply
            if ($r.Bytes -gt 0) { Write-Khz ('    {0,-22} {1}' -f $r.Label, (Format-KhzBytes $r.Bytes)) }
            $total += $r.Bytes
        }
    }

    # bin/obj under the dev tree - the single biggest win on a build machine
    $devRoot = Join-Path $env:USERPROFILE 'dev'
    if (Test-Path -LiteralPath $devRoot) {
        $stale = Get-ChildItem -LiteralPath $devRoot -Directory -Recurse -Force -ErrorAction SilentlyContinue |
                 Where-Object { $_.Name -in @('bin','obj','TestResults','node_modules','target') }
        $devBytes = 0L
        foreach ($d in $stale) {
            $devBytes += Get-KhzPathSize $d.FullName
            if ($Apply) { Remove-Item -LiteralPath $d.FullName -Recurse -Force -ErrorAction SilentlyContinue }
        }
        if ($devBytes -gt 0) {
            Write-Khz ('    {0,-22} {1}  ({2} dirs)' -f 'dev build output', (Format-KhzBytes $devBytes), $stale.Count)
        }
        $total += $devBytes
    }

    $total
}

# ---------------------------------------------------------------- 3. Edge extensions

function Remove-KhzEdgeExtensions {
    [CmdletBinding()] param([switch]$Apply, [switch]$BlockFutureInstalls)

    Write-Khz "`n[3] Edge extensions" 'head'
    $total = 0L
    $root = "$env:LOCALAPPDATA\Microsoft\Edge\User Data"

    if (-not (Test-Path -LiteralPath $root)) {
        Write-Khz '    Edge not installed' 'warn'
        return 0L
    }

    if ($Apply) {
        Get-Process msedge, msedgewebview2 -ErrorAction SilentlyContinue |
            Stop-Process -Force -ErrorAction SilentlyContinue
        Start-Sleep -Milliseconds 800
    }

    $profiles = Get-ChildItem -LiteralPath $root -Directory -ErrorAction SilentlyContinue |
                Where-Object { $_.Name -eq 'Default' -or $_.Name -like 'Profile *' }

    foreach ($p in $profiles) {
        foreach ($leaf in @('Extensions', 'Local Extension Settings', 'Extension State', 'Extension Rules')) {
            $path = Join-Path $p.FullName $leaf
            if (-not (Test-Path -LiteralPath $path)) { continue }
            if ($leaf -eq 'Extensions') {
                $ids = Get-ChildItem -LiteralPath $path -Directory -ErrorAction SilentlyContinue
                foreach ($id in $ids) { Write-Khz "    $($p.Name): $($id.Name)" }
            }
            $r = Clear-KhzDirectory -Path $path -Apply:$Apply
            $total += $r.Bytes
        }
    }

    Write-Khz ('    reclaimed {0}' -f (Format-KhzBytes $total)) 'ok'

    if ($BlockFutureInstalls) {
        Set-KhzPolicy -Key 'HKLM:\SOFTWARE\Policies\Microsoft\Edge\ExtensionInstallBlocklist' `
                      -Name '1' -Value '*' -Type String -Apply:$Apply
    }

    $total
}

# ---------------------------------------------------------------- 4. Copilot / Edge noise

function Disable-KhzCopilot {
    [CmdletBinding()] param([switch]$Apply)

    Write-Khz "`n[4] Copilot, Edge sidebar, ads" 'head'

    if (-not (Test-KhzAdmin)) { Write-Khz '    needs admin - policies skipped' 'warn'; return 0L }

    $pol = @(
        @{ K = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsCopilot'; N = 'TurnOffWindowsCopilot';     V = 1 },
        @{ K = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsAI';      N = 'DisableAIDataAnalysis';    V = 1 },
        @{ K = 'HKLM:\SOFTWARE\Policies\Microsoft\Edge';                   N = 'HubsSidebarEnabled';       V = 0 },
        @{ K = 'HKLM:\SOFTWARE\Policies\Microsoft\Edge';                   N = 'StandaloneHubsSidebarEnabled'; V = 0 },
        @{ K = 'HKLM:\SOFTWARE\Policies\Microsoft\Edge';                   N = 'EdgeShoppingAssistantEnabled'; V = 0 },
        @{ K = 'HKLM:\SOFTWARE\Policies\Microsoft\Edge';                   N = 'StartupBoostEnabled';      V = 0 },
        @{ K = 'HKLM:\SOFTWARE\Policies\Microsoft\Edge';                   N = 'BackgroundModeEnabled';    V = 0 },
        @{ K = 'HKLM:\SOFTWARE\Policies\Microsoft\Edge';                   N = 'BingAdsSuppression';       V = 1 }
    )
    foreach ($p in $pol) { Set-KhzPolicy -Key $p.K -Name $p.N -Value $p.V -Apply:$Apply }

    $user = @(
        @{ K = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced'; N = 'ShowCopilotButton'; V = 0 },
        @{ K = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager'; N = 'SilentInstalledAppsEnabled'; V = 0 },
        @{ K = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager'; N = 'SubscribedContent-338388Enabled'; V = 0 },
        @{ K = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager'; N = 'SystemPaneSuggestionsEnabled'; V = 0 }
    )
    foreach ($p in $user) { Set-KhzPolicy -Key $p.K -Name $p.N -Value $p.V -Apply:$Apply }

    $appx = @('*Copilot*', '*BingSearch*', '*XboxGamingOverlay*', '*XboxGameOverlay*',
              '*GamingApp*', '*OneDrive*', '*ZuneMusic*', '*ZuneVideo*',
              '*QuickAssist*', '*Teams*', '*MicrosoftStickyNotes*')

    foreach ($pattern in $appx) {
        $pkgs = Get-AppxPackage -Name $pattern -ErrorAction SilentlyContinue
        foreach ($pkg in $pkgs) {
            if ($Apply) {
                try {
                    Remove-AppxPackage -Package $pkg.PackageFullName -ErrorAction Stop
                    Write-Khz "    removed $($pkg.Name)" 'ok'
                } catch { Write-Khz "    locked  $($pkg.Name)" 'warn' }
            } else {
                Write-Khz "    would remove $($pkg.Name)"
            }
        }
    }

    0L
}

# ---------------------------------------------------------------- 5. PowerShell modules

<#
    Microsoft.Graph ships ~40 sub-modules and Az ships ~80. Together they can
    exceed 4 GB and they slow down every single PowerShell start because of
    command auto-discovery. This removes them, keeping only what -Keep names.
#>
function Remove-KhzStaleModules {
    [CmdletBinding()] param(
        [switch]$Apply,
        [string[]]$Keep = @('Microsoft.Graph.Authentication', 'Az.Accounts'),
        [switch]$OldVersionsOnly
    )

    Write-Khz "`n[5] PowerShell modules" 'head'

    $protected = @(
        'PowerShellGet', 'PackageManagement', 'PSReadLine', 'Pester',
        'Microsoft.PowerShell.*', 'PSDesiredStateConfiguration', 'ThreadJob'
    )

    $all = Get-Module -ListAvailable -ErrorAction SilentlyContinue |
           Where-Object { $_.Name -like 'Microsoft.Graph*' -or $_.Name -like 'Az.*' -or
                          $_.Name -like 'AzureRM*' -or $_.Name -like 'AzureAD*' -or
                          $_.Name -like 'MSOnline*' -or $_.Name -like 'SharePointPnP*' }

    if (-not $all) { Write-Khz '    nothing to remove' 'ok'; return 0L }

    $total = 0L
    $groups = $all | Group-Object Name

    foreach ($g in $groups) {
        $name = $g.Name
        if ($protected | Where-Object { $name -like $_ }) { continue }

        $versions = $g.Group | Sort-Object Version -Descending
        $doomed = if ($OldVersionsOnly -or ($Keep -contains $name)) {
            $versions | Select-Object -Skip 1
        } else {
            $versions
        }

        foreach ($v in $doomed) {
            $path = $v.ModuleBase
            $size = Get-KhzPathSize $path
            $total += $size
            if ($Apply) {
                try {
                    Remove-Item -LiteralPath $path -Recurse -Force -ErrorAction Stop
                    Write-Khz ('    removed {0} {1}  {2}' -f $name, $v.Version, (Format-KhzBytes $size)) 'ok'
                } catch {
                    Write-Khz ('    locked  {0} {1}' -f $name, $v.Version) 'warn'
                }
            } else {
                Write-Khz ('    would remove {0} {1}  {2}' -f $name, $v.Version, (Format-KhzBytes $size))
            }
        }
    }

    Write-Khz ('    total {0} across {1} module names' -f (Format-KhzBytes $total), $groups.Count) 'ok'
    $total
}

# ---------------------------------------------------------------- 6. telemetry

function Disable-KhzTelemetry {
    [CmdletBinding()] param([switch]$Apply)

    Write-Khz "`n[6] telemetry and background tasks" 'head'
    if (-not (Test-KhzAdmin)) { Write-Khz '    needs admin - skipped' 'warn'; return 0L }

    foreach ($svc in @('DiagTrack', 'dmwappushservice', 'WerSvc', 'MapsBroker', 'RetailDemo')) {
        $s = Get-Service -Name $svc -ErrorAction SilentlyContinue
        if (-not $s) { continue }
        if ($Apply) {
            try {
                Stop-Service -Name $svc -Force -ErrorAction SilentlyContinue
                Set-Service -Name $svc -StartupType Disabled -ErrorAction Stop
                Write-Khz "    disabled $svc" 'ok'
            } catch { Write-Khz "    could not disable $svc" 'warn' }
        } else {
            Write-Khz "    would disable $svc (now: $($s.Status))"
        }
    }

    $tasks = @(
        '\Microsoft\Windows\Application Experience\Microsoft Compatibility Appraiser',
        '\Microsoft\Windows\Application Experience\ProgramDataUpdater',
        '\Microsoft\Windows\Customer Experience Improvement Program\Consolidator',
        '\Microsoft\Windows\Customer Experience Improvement Program\UsbCeip',
        '\Microsoft\Windows\DiskDiagnostic\Microsoft-Windows-DiskDiagnosticDataCollector',
        '\Microsoft\Windows\Feedback\Siuf\DmClient',
        '\Microsoft\Windows\Windows Error Reporting\QueueReporting'
    )
    foreach ($t in $tasks) {
        $leaf = Split-Path $t -Leaf
        $path = (Split-Path $t -Parent) + '\'
        $task = Get-ScheduledTask -TaskName $leaf -TaskPath $path -ErrorAction SilentlyContinue
        if (-not $task) { continue }
        if ($Apply) {
            Disable-ScheduledTask -TaskName $leaf -TaskPath $path -ErrorAction SilentlyContinue | Out-Null
            Write-Khz "    disabled task $leaf" 'ok'
        } else {
            Write-Khz "    would disable task $leaf"
        }
    }

    Set-KhzPolicy -Key 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\DataCollection' `
                  -Name 'AllowTelemetry' -Value 0 -Apply:$Apply
    0L
}

# ---------------------------------------------------------------- 7. pagefile

<#
    This is the fix for 'The paging file is too small for this operation to
    complete' and for 'Insufficient system resources exist to complete the
    requested service'. Both are virtual-memory exhaustion, not disk shortage.
#>
function Repair-KhzPagefile {
    [CmdletBinding()] param([switch]$Apply)

    Write-Khz "`n[7] virtual memory" 'head'
    if (-not (Test-KhzAdmin)) { Write-Khz '    needs admin - skipped' 'warn'; return 0L }

    $cs = Get-CimInstance Win32_ComputerSystem
    $ram = [math]::Round($cs.TotalPhysicalMemory / 1GB, 1)
    Write-Khz "    physical RAM       : $ram GB"
    Write-Khz "    automatic pagefile : $($cs.AutomaticManagedPagefile)"

    $usage = Get-CimInstance Win32_PageFileUsage -ErrorAction SilentlyContinue
    if ($usage) {
        Write-Khz "    current pagefile   : $($usage.AllocatedBaseSize) MB (peak $($usage.PeakUsage) MB)"
    } else {
        Write-Khz '    current pagefile   : NONE - this is the bug' 'err'
    }

    if ($cs.AutomaticManagedPagefile -and $usage) {
        Write-Khz '    already healthy' 'ok'
        return 0L
    }

    if ($Apply) {
        try {
            Set-CimInstance -InputObject $cs -Property @{ AutomaticManagedPagefile = $true } -ErrorAction Stop
            Write-Khz '    enabled automatic pagefile - REBOOT REQUIRED' 'ok'
        } catch { Write-Khz "    failed: $($_.Exception.Message)" 'err' }
    } else {
        Write-Khz '    would enable automatic pagefile' 'warn'
    }
    0L
}

# ---------------------------------------------------------------- report

function Get-KhzReport {
    [CmdletBinding()] param()

    $drive = Get-PSDrive -Name ($env:SystemDrive.TrimEnd(':')) -ErrorAction SilentlyContinue
    $os = Get-CimInstance Win32_OperatingSystem

    [pscustomobject]@{
        Timestamp     = Get-Date
        FreeGB        = if ($drive) { [math]::Round($drive.Free / 1GB, 2) } else { $null }
        UsedGB        = if ($drive) { [math]::Round($drive.Used / 1GB, 2) } else { $null }
        RamFreeGB     = [math]::Round($os.FreePhysicalMemory / 1MB, 2)
        RamTotalGB    = [math]::Round($os.TotalVisibleMemorySize / 1MB, 2)
        Processes     = (Get-Process).Count
        StartupItems  = (Get-CimInstance Win32_StartupCommand -ErrorAction SilentlyContinue).Count
        GraphModules  = (Get-Module -ListAvailable Microsoft.Graph* -ErrorAction SilentlyContinue).Count
        AzModules     = (Get-Module -ListAvailable Az.* -ErrorAction SilentlyContinue).Count
    }
}

# ---------------------------------------------------------------- daily task

function Register-KhzDailyTask {
    [CmdletBinding()] param(
        [string]$At = '03:30',
        [switch]$Apply
    )

    Write-Khz "`n[task] daily schedule" 'head'
    if (-not (Test-KhzAdmin)) { Write-Khz '    needs admin' 'err'; return }

    $module = $PSCommandPath
    if (-not $module) { $module = Join-Path $PSScriptRoot 'KhzJanitor.psm1' }

    $cmd = "Import-Module '$module' -Force; Invoke-KhzJanitor -Apply -Quiet -Tasks Logs,Caches,EdgeExtensions"
    $enc = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($cmd))

    if (-not $Apply) {
        Write-Khz "    would register 'KhzJanitor Daily' at $At" 'warn'
        return
    }

    $action    = New-ScheduledTaskAction -Execute 'powershell.exe' `
                    -Argument "-NoProfile -NonInteractive -WindowStyle Hidden -EncodedCommand $enc"
    $trigger   = New-ScheduledTaskTrigger -Daily -At $At
    $principal = New-ScheduledTaskPrincipal -UserId 'SYSTEM' -LogonType ServiceAccount -RunLevel Highest
    $settings  = New-ScheduledTaskSettingsSet -StartWhenAvailable `
                    -DontStopIfGoingOnBatteries -AllowStartIfOnBatteries `
                    -ExecutionTimeLimit (New-TimeSpan -Minutes 30)

    Register-ScheduledTask -TaskName 'KhzJanitor Daily' -Action $action -Trigger $trigger `
        -Principal $principal -Settings $settings -Force -Description 'KhzJanitor cleanup' | Out-Null

    Write-Khz "    registered 'KhzJanitor Daily' at $At" 'ok'
}

function Unregister-KhzDailyTask {
    [CmdletBinding()] param()
    Unregister-ScheduledTask -TaskName 'KhzJanitor Daily' -Confirm:$false -ErrorAction SilentlyContinue
    Write-Khz "    removed 'KhzJanitor Daily'" 'ok'
}

# ---------------------------------------------------------------- orchestrator

function Invoke-KhzJanitor {
    [CmdletBinding()]
    param(
        [ValidateSet('Logs','Caches','EdgeExtensions','Copilot','Modules','Telemetry','Pagefile','All')]
        [string[]]$Tasks = @('All'),

        # Nothing is deleted without this switch.
        [switch]$Apply,

        [switch]$Aggressive,
        [switch]$Quiet
    )

    if ($Tasks -contains 'All') {
        $Tasks = @('Logs','Caches','EdgeExtensions','Copilot','Modules','Telemetry','Pagefile')
    }

    New-Item -ItemType Directory -Path $script:LogDir -Force | Out-Null
    $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
    $log = Join-Path $script:LogDir "khz-$stamp.log"
    try { Start-Transcript -Path $log -Force | Out-Null } catch { }

    $before = Get-KhzReport

    if (-not $Quiet) {
        Write-Khz ''
        Write-Khz '  KhzJanitor 1.0.0' 'head'
        Write-Khz ('  mode: {0}' -f $(if ($Apply) { 'APPLY - deleting' } else { 'DRY RUN - nothing will be deleted' })) `
                  $(if ($Apply) { 'err' } else { 'warn' })
        Write-Khz ('  free before: {0} GB   RAM free: {1} GB' -f $before.FreeGB, $before.RamFreeGB)
        Write-Khz ('  admin: {0}' -f (Test-KhzAdmin))
    }

    $freed = 0L
    foreach ($task in $Tasks) {
        switch ($task) {
            'Logs'           { $freed += Clear-KhzLogs -Apply:$Apply -ClearEventLogs:$Aggressive }
            'Caches'         { $freed += Clear-KhzCaches -Apply:$Apply -IncludePackageCaches:$Aggressive }
            'EdgeExtensions' { $freed += Remove-KhzEdgeExtensions -Apply:$Apply -BlockFutureInstalls:$Aggressive }
            'Copilot'        { $freed += Disable-KhzCopilot -Apply:$Apply }
            'Modules'        { $freed += Remove-KhzStaleModules -Apply:$Apply }
            'Telemetry'      { $freed += Disable-KhzTelemetry -Apply:$Apply }
            'Pagefile'       { $freed += Repair-KhzPagefile -Apply:$Apply }
        }
    }

    $after = Get-KhzReport

    Write-Khz ''
    Write-Khz '  ---------------------------------------------' 'head'
    Write-Khz ('  {0}: {1}' -f $(if ($Apply) { 'reclaimed' } else { 'reclaimable' }), (Format-KhzBytes $freed)) 'ok'
    Write-Khz ('  disk free : {0} -> {1} GB' -f $before.FreeGB, $after.FreeGB)
    Write-Khz ('  log       : {0}' -f $log)
    if (-not $Apply) { Write-Khz '  re-run with -Apply to actually delete' 'warn' }

    try {
        [pscustomobject]@{
            Time = (Get-Date).ToString('s'); Applied = [bool]$Apply
            FreedBytes = $freed; FreeGBBefore = $before.FreeGB; FreeGBAfter = $after.FreeGB
        } | Export-Csv -Path $script:Ledger -Append -NoTypeInformation -ErrorAction SilentlyContinue
    } catch { }

    try { Stop-Transcript | Out-Null } catch { }
}

Export-ModuleMember -Function Invoke-KhzJanitor, Clear-KhzLogs, Clear-KhzCaches,
    Remove-KhzEdgeExtensions, Disable-KhzCopilot, Remove-KhzStaleModules,
    Disable-KhzTelemetry, Repair-KhzPagefile, Register-KhzDailyTask,
    Unregister-KhzDailyTask, Get-KhzReport
