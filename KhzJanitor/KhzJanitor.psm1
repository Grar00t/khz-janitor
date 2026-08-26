#requires -Version 5.1
<#
    KhzJanitor 1.1.0 - reclaim a bloated Windows box.

    SAFETY CONTRACT
    ---------------
    Nothing is deleted unless -Apply is passed. Without it every function only
    measures and reports. All destructive paths are whitelisted literals; there
    is no recursive wildcard deletion of user directories anywhere in this file.
#>

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Continue'

$script:Root   = Join-Path $env:ProgramData 'KhzJanitor'
$script:LogDir = Join-Path $script:Root 'logs'
$script:Ledger = Join-Path $script:Root 'ledger.csv'

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

<#
    Under Set-StrictMode -Version Latest, $null.Count throws
    PropertyNotFoundException. Every count in this module goes through here.
#>
function Get-KhzCount {
    param($InputObject)
    if ($null -eq $InputObject) { return 0 }
    return @($InputObject).Count
}

function Test-KhzAdmin {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    (New-Object Security.Principal.WindowsPrincipal $id).IsInRole(
        [Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Get-KhzPathSize {
    param([string]$Path)
    if ([string]::IsNullOrWhiteSpace($Path)) { return 0L }
    if (-not (Test-Path -LiteralPath $Path)) { return 0L }
    try {
        if (Test-Path -LiteralPath $Path -PathType Leaf) {
            return [int64](Get-Item -LiteralPath $Path).Length
        }
        $sum = Get-ChildItem -LiteralPath $Path -Recurse -Force -File -ErrorAction SilentlyContinue |
                Measure-Object -Property Length -Sum
        if ($null -eq $sum -or $null -eq $sum.Sum) { return 0L }
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
    $items = @(Get-ChildItem -LiteralPath $Path -Force -ErrorAction SilentlyContinue |
               Where-Object { $OlderThanDays -le 0 -or $_.LastWriteTime -lt $cutoff })

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
    $total = 0L

    $targets = @(
        @{ P = "$env:SystemRoot\Logs";                                 L = 'Windows\Logs';       D = $KeepDays },
        @{ P = "$env:SystemRoot\Temp";                                  L = 'Windows\Temp';       D = 0 },
        @{ P = "$env:SystemRoot\Panther";                               L = 'Setup (Panther)';    D = 0 },
        @{ P = "$env:SystemRoot\SoftwareDistribution\Download";         L = 'WU downloads';       D = 0 },
        @{ P = "$env:SystemRoot\System32\LogFiles";                     L = 'System32\LogFiles';  D = $KeepDays },
        @{ P = "$env:SystemDrive\Logs";                                 L = 'C:\Logs';            D = $KeepDays },
        @{ P = "$env:SystemDrive\PerfLogs";                             L = 'C:\PerfLogs';        D = 0 },
        @{ P = "$env:SystemDrive\inetpub\logs";                         L = 'IIS logs';           D = $KeepDays },
        @{ P = "$env:ProgramData\Microsoft\Windows\WER\ReportQueue";    L = 'WER queue';          D = 0 },
        @{ P = "$env:ProgramData\Microsoft\Windows\WER\ReportArchive";  L = 'WER archive';        D = 0 },
        @{ P = "$env:ProgramData\Microsoft\Windows\WER\Temp";           L = 'WER temp';           D = 0 },
        @{ P = "$env:ProgramData\USOPrivate\UpdateStore";               L = 'Update store';       D = 0 },
        @{ P = "$env:LOCALAPPDATA\CrashDumps";                          L = 'Crash dumps';        D = 0 },
        @{ P = "$env:LOCALAPPDATA\Microsoft\Windows\WebCache";          L = 'WebCache';           D = 0 },
        @{ P = "$env:LOCALAPPDATA\Temp";                                L = 'User temp';          D = 0 },
        @{ P = "$env:LOCALAPPDATA\D3DSCache";                           L = 'D3D shader cache';   D = 0 },
        @{ P = "$env:LOCALAPPDATA\NVIDIA\DXCache";                      L = 'NVIDIA DX cache';    D = 0 },
        @{ P = "$env:LOCALAPPDATA\NVIDIA\GLCache";                      L = 'NVIDIA GL cache';    D = 0 },
        @{ P = "$env:LOCALAPPDATA\AMD\DxCache";                         L = 'AMD DX cache';       D = 0 }
    )

    foreach ($t in $targets) {
        $r = Clear-KhzDirectory -Path $t.P -Label $t.L -OlderThanDays $t.D -Apply:$Apply
        if (-not $r.Skipped -and $r.Bytes -gt 0) {
            Write-Khz ('    {0,-22} {1}' -f $r.Label, (Format-KhzBytes $r.Bytes))
        }
        $total += $r.Bytes
    }

    foreach ($dump in @("$env:SystemRoot\MEMORY.DMP", "$env:SystemRoot\Minidump", "$env:SystemDrive\DumpStack.log.tmp")) {
        if (-not (Test-Path -LiteralPath $dump)) { continue }
        $size = Get-KhzPathSize $dump
        if ($size -le 0) { continue }
        Write-Khz ('    {0,-22} {1}' -f (Split-Path $dump -Leaf), (Format-KhzBytes $size))
        if ($Apply) { Remove-Item -LiteralPath $dump -Recurse -Force -ErrorAction SilentlyContinue }
        $total += $size
    }

    if ($ClearEventLogs) {
        if ($Apply) {
            $n = 0
            foreach ($log in @(wevtutil el 2>$null)) {
                try { wevtutil cl "$log" 2>$null; $n++ } catch { }
            }
            Write-Khz "    event logs cleared: $n" 'ok'
        } else {
            Write-Khz ('    would clear {0} event logs' -f (Get-KhzCount (wevtutil el 2>$null))) 'warn'
        }
    }

    $total
}

# ---------------------------------------------------------------- 2. caches

function Clear-KhzCaches {
    [CmdletBinding()] param([switch]$Apply, [switch]$IncludePackageCaches)

    Write-Khz "`n[2] caches" 'head'
    $total = 0L

    # ---- Chromium family, per browser, with a correct per-root subtotal
    $chromium = [ordered]@{
        'Edge'   = "$env:LOCALAPPDATA\Microsoft\Edge\User Data"
        'Chrome' = "$env:LOCALAPPDATA\Google\Chrome\User Data"
        'Brave'  = "$env:LOCALAPPDATA\BraveSoftware\Brave-Browser\User Data"
        'Vivaldi'= "$env:LOCALAPPDATA\Vivaldi\User Data"
    }
    $leaves = @(
        'Cache', 'Code Cache', 'GPUCache', 'DawnCache', 'DawnGraphiteCache',
        'GrShaderCache', 'ShaderCache', 'Service Worker\CacheStorage',
        'Service Worker\ScriptCache', 'Storage\ext', 'IndexedDB\https_copilot*'
    )

    foreach ($name in $chromium.Keys) {
        $root = $chromium[$name]
        if (-not (Test-Path -LiteralPath $root)) { continue }

        $rootBytes = 0L
        $profileDirs = @(Get-ChildItem -LiteralPath $root -Directory -ErrorAction SilentlyContinue |
                         Where-Object { $_.Name -eq 'Default' -or $_.Name -like 'Profile *' })

        foreach ($prof in $profileDirs) {
            foreach ($leaf in $leaves) {
                if ($leaf -like '*`**') { continue }
                $p = Join-Path $prof.FullName $leaf
                $rootBytes += (Clear-KhzDirectory -Path $p -Apply:$Apply).Bytes
            }
        }

        # shared, profile-independent
        foreach ($shared in @('ShaderCache', 'GrShaderCache', 'component_crx_cache', 'GraphiteDawnCache')) {
            $rootBytes += (Clear-KhzDirectory -Path (Join-Path $root $shared) -Apply:$Apply).Bytes
        }

        Write-Khz ('    {0,-22} {1}  ({2} profiles)' -f $name, (Format-KhzBytes $rootBytes), (Get-KhzCount $profileDirs))
        $total += $rootBytes
    }

    # ---- Firefox uses a different layout entirely
    $ffRoots = @(
        "$env:LOCALAPPDATA\Mozilla\Firefox\Profiles",
        "$env:APPDATA\Mozilla\Firefox\Profiles"
    )
    $ffBytes = 0L
    foreach ($ffRoot in $ffRoots) {
        if (-not (Test-Path -LiteralPath $ffRoot)) { continue }
        foreach ($prof in @(Get-ChildItem -LiteralPath $ffRoot -Directory -ErrorAction SilentlyContinue)) {
            foreach ($leaf in @('cache2', 'startupCache', 'shader-cache', 'thumbnails', 'OfflineCache')) {
                $ffBytes += (Clear-KhzDirectory -Path (Join-Path $prof.FullName $leaf) -Apply:$Apply).Bytes
            }
        }
    }
    if ($ffBytes -gt 0) {
        Write-Khz ('    {0,-22} {1}' -f 'Firefox', (Format-KhzBytes $ffBytes))
        $total += $ffBytes
    }

    # ---- everything else
    $misc = @(
        @{ P = "$env:LOCALAPPDATA\Microsoft\Windows\Explorer";               L = 'thumbnail cache' },
        @{ P = "$env:LOCALAPPDATA\Microsoft\Windows\INetCache";              L = 'INetCache' },
        @{ P = "$env:LOCALAPPDATA\Microsoft\Terminal Server Client\Cache";   L = 'RDP cache' },
        @{ P = "$env:LOCALAPPDATA\Microsoft\Office\16.0\OfficeFileCache";    L = 'Office cache' },
        @{ P = "$env:LOCALAPPDATA\Microsoft\Edge\User Data\Crashpad";        L = 'Edge crashpad' },
        @{ P = "$env:LOCALAPPDATA\Microsoft\VisualStudio\Packages\_Instances"; L = 'VS instances' },
        @{ P = "$env:LOCALAPPDATA\Microsoft\VSApplicationInsights";          L = 'VS telemetry' },
        @{ P = "$env:LOCALAPPDATA\JetBrains\Transient";                      L = 'JetBrains transient' },
        @{ P = "$env:LOCALAPPDATA\JetBrains\caches";                         L = 'JetBrains caches' },
        @{ P = "$env:APPDATA\Code\CachedData";                               L = 'VS Code cached data' },
        @{ P = "$env:APPDATA\Code\Cache";                                    L = 'VS Code cache' },
        @{ P = "$env:APPDATA\Code\CachedExtensionVSIXs";                     L = 'VS Code vsix cache' },
        @{ P = "$env:USERPROFILE\.dotnet\optimizationdata";                  L = 'dotnet opt data' },
        @{ P = "$env:USERPROFILE\.templateengine";                           L = 'dotnet templates' },
        @{ P = "$env:ProgramData\Microsoft\Network\Downloader";              L = 'delivery optimization' },
        @{ P = "$env:ProgramData\Docker\log";                                L = 'Docker logs' },
        @{ P = "$env:LOCALAPPDATA\Docker\log";                               L = 'Docker user logs' }
    )

    foreach ($m in $misc) {
        $r = Clear-KhzDirectory -Path $m.P -Label $m.L -Apply:$Apply
        if (-not $r.Skipped -and $r.Bytes -gt 0) {
            Write-Khz ('    {0,-22} {1}' -f $r.Label, (Format-KhzBytes $r.Bytes))
        }
        $total += $r.Bytes
    }

    if ($IncludePackageCaches) {
        foreach ($pkg in @(
            @{ P = "$env:USERPROFILE\.nuget\packages";    L = 'nuget packages' },
            @{ P = "$env:LOCALAPPDATA\NuGet\v3-cache";    L = 'nuget http cache' },
            @{ P = "$env:APPDATA\npm-cache";              L = 'npm cache' },
            @{ P = "$env:LOCALAPPDATA\npm-cache";         L = 'npm cache (local)' },
            @{ P = "$env:LOCALAPPDATA\pip\Cache";         L = 'pip cache' },
            @{ P = "$env:LOCALAPPDATA\Yarn\Cache";        L = 'yarn cache' },
            @{ P = "$env:USERPROFILE\.cargo\registry";    L = 'cargo registry' },
            @{ P = "$env:USERPROFILE\.gradle\caches";     L = 'gradle caches' }
        )) {
            $r = Clear-KhzDirectory -Path $pkg.P -Label $pkg.L -Apply:$Apply
            if ($r.Bytes -gt 0) { Write-Khz ('    {0,-22} {1}' -f $r.Label, (Format-KhzBytes $r.Bytes)) }
            $total += $r.Bytes
        }
    }

    # ---- build output under the dev tree: the biggest win on a build box
    foreach ($devRoot in @((Join-Path $env:USERPROFILE 'dev'), (Join-Path $env:USERPROFILE 'source'))) {
        if (-not (Test-Path -LiteralPath $devRoot)) { continue }
        $stale = @(Get-ChildItem -LiteralPath $devRoot -Directory -Recurse -Force -ErrorAction SilentlyContinue |
                   Where-Object { $_.Name -in @('bin','obj','TestResults','node_modules','target','__pycache__','.pytest_cache') })
        $devBytes = 0L
        foreach ($d in $stale) {
            $devBytes += Get-KhzPathSize $d.FullName
            if ($Apply) { Remove-Item -LiteralPath $d.FullName -Recurse -Force -ErrorAction SilentlyContinue }
        }
        if ($devBytes -gt 0) {
            Write-Khz ('    {0,-22} {1}  ({2} dirs in {3})' -f 'build output', (Format-KhzBytes $devBytes), (Get-KhzCount $stale), (Split-Path $devRoot -Leaf))
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

    $profileDirs = @(Get-ChildItem -LiteralPath $root -Directory -ErrorAction SilentlyContinue |
                     Where-Object { $_.Name -eq 'Default' -or $_.Name -like 'Profile *' })

    $seen = @{}
    foreach ($prof in $profileDirs) {
        foreach ($leaf in @('Extensions', 'Local Extension Settings', 'Extension State', 'Extension Rules')) {
            $path = Join-Path $prof.FullName $leaf
            if (-not (Test-Path -LiteralPath $path)) { continue }
            if ($leaf -eq 'Extensions') {
                foreach ($id in @(Get-ChildItem -LiteralPath $path -Directory -ErrorAction SilentlyContinue)) {
                    if ($seen.ContainsKey($id.Name)) { $seen[$id.Name] += 1 } else { $seen[$id.Name] = 1 }
                }
            }
            $total += (Clear-KhzDirectory -Path $path -Apply:$Apply).Bytes
        }
    }

    foreach ($id in ($seen.Keys | Sort-Object { -1 * $seen[$_] })) {
        Write-Khz ('    {0}  x{1} profiles' -f $id, $seen[$id])
    }

    Write-Khz ('    {0} unique extensions across {1} profiles, {2}' -f
        (Get-KhzCount $seen.Keys), (Get-KhzCount $profileDirs), (Format-KhzBytes $total)) 'ok'

    if ($BlockFutureInstalls) {
        Set-KhzPolicy -Key 'HKLM:\SOFTWARE\Policies\Microsoft\Edge\ExtensionInstallBlocklist' `
                      -Name '1' -Value '*' -Type String -Apply:$Apply
    }

    $total
}

# ---------------------------------------------------------------- 4. Copilot

function Disable-KhzCopilot {
    [CmdletBinding()] param([switch]$Apply)

    Write-Khz "`n[4] Copilot, Edge sidebar, ads" 'head'

    if (-not (Test-KhzAdmin)) { Write-Khz '    needs admin - policies skipped' 'warn'; return 0L }

    $pol = @(
        @{ K = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsCopilot'; N = 'TurnOffWindowsCopilot';        V = 1 },
        @{ K = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsAI';      N = 'DisableAIDataAnalysis';       V = 1 },
        @{ K = 'HKLM:\SOFTWARE\Policies\Microsoft\Edge';                   N = 'HubsSidebarEnabled';          V = 0 },
        @{ K = 'HKLM:\SOFTWARE\Policies\Microsoft\Edge';                   N = 'StandaloneHubsSidebarEnabled';V = 0 },
        @{ K = 'HKLM:\SOFTWARE\Policies\Microsoft\Edge';                   N = 'EdgeShoppingAssistantEnabled';V = 0 },
        @{ K = 'HKLM:\SOFTWARE\Policies\Microsoft\Edge';                   N = 'StartupBoostEnabled';         V = 0 },
        @{ K = 'HKLM:\SOFTWARE\Policies\Microsoft\Edge';                   N = 'BackgroundModeEnabled';       V = 0 },
        @{ K = 'HKLM:\SOFTWARE\Policies\Microsoft\Edge';                   N = 'BingAdsSuppression';          V = 1 },
        @{ K = 'HKLM:\SOFTWARE\Policies\Microsoft\Edge';                   N = 'CopilotPageContext';          V = 0 },
        @{ K = 'HKLM:\SOFTWARE\Policies\Microsoft\OneDrive';               N = 'DisableFileSyncNGSC';         V = 0 }
    )
    foreach ($p in $pol) { Set-KhzPolicy -Key $p.K -Name $p.N -Value $p.V -Apply:$Apply }

    $user = @(
        @{ K = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced';        N = 'ShowCopilotButton'; V = 0 },
        @{ K = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager';   N = 'SilentInstalledAppsEnabled'; V = 0 },
        @{ K = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager';   N = 'SubscribedContent-338388Enabled'; V = 0 },
        @{ K = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager';   N = 'SystemPaneSuggestionsEnabled'; V = 0 }
    )
    foreach ($p in $user) { Set-KhzPolicy -Key $p.K -Name $p.N -Value $p.V -Apply:$Apply }

    # OneDrive is deliberately NOT in this list: it may hold synced work files.
    $appx = @('*Copilot*', '*BingSearch*', '*XboxGamingOverlay*', '*XboxGameOverlay*',
              '*GamingApp*', '*ZuneMusic*', '*ZuneVideo*', '*QuickAssist*',
              '*MicrosoftStickyNotes*', '*Clipchamp*', '*WindowsFeedbackHub*',
              '*GetHelp*', '*MicrosoftSolitaireCollection*')

    foreach ($pattern in $appx) {
        foreach ($pkg in @(Get-AppxPackage -Name $pattern -ErrorAction SilentlyContinue)) {
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

# ---------------------------------------------------------------- 5. modules

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

    $all = @(Get-Module -ListAvailable -ErrorAction SilentlyContinue |
             Where-Object { $_.Name -like 'Microsoft.Graph*' -or $_.Name -like 'Az.*' -or
                            $_.Name -like 'AzureRM*' -or $_.Name -like 'AzureAD*' -or
                            $_.Name -like 'MSOnline*' -or $_.Name -like 'SharePointPnP*' -or
                            $_.Name -like 'ExchangeOnline*' -or $_.Name -like 'MicrosoftTeams*' })

    if ((Get-KhzCount $all) -eq 0) { Write-Khz '    nothing to remove' 'ok'; return 0L }

    $total = 0L
    $removed = 0
    $groups = @($all | Group-Object Name)

    foreach ($g in $groups) {
        $name = $g.Name
        if (@($protected | Where-Object { $name -like $_ }).Count -gt 0) { continue }

        $versions = @($g.Group | Sort-Object Version -Descending)
        $doomed = if ($OldVersionsOnly -or ($Keep -contains $name)) {
            @($versions | Select-Object -Skip 1)
        } else {
            $versions
        }

        foreach ($v in $doomed) {
            $size = Get-KhzPathSize $v.ModuleBase
            $total += $size
            $removed++
            if ($Apply) {
                try {
                    Remove-Item -LiteralPath $v.ModuleBase -Recurse -Force -ErrorAction Stop
                    Write-Khz ('    removed {0} {1}  {2}' -f $name, $v.Version, (Format-KhzBytes $size)) 'ok'
                } catch {
                    Write-Khz ('    locked  {0} {1}' -f $name, $v.Version) 'warn'
                }
            }
        }
    }

    Write-Khz ('    {0} module folders, {1} total, {2} module names' -f
        $removed, (Format-KhzBytes $total), (Get-KhzCount $groups)) 'ok'
    if (-not $Apply) { Write-Khz '    (dry run - list suppressed, use -Verbose for detail)' }
    $total
}

# ---------------------------------------------------------------- 6. telemetry

function Disable-KhzTelemetry {
    [CmdletBinding()] param([switch]$Apply)

    Write-Khz "`n[6] telemetry and background tasks" 'head'
    if (-not (Test-KhzAdmin)) { Write-Khz '    needs admin - skipped' 'warn'; return 0L }

    foreach ($svc in @('DiagTrack', 'dmwappushservice', 'WerSvc', 'MapsBroker', 'RetailDemo', 'PcaSvc')) {
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
        '\Microsoft\Windows\Application Experience\StartupAppTask',
        '\Microsoft\Windows\Customer Experience Improvement Program\Consolidator',
        '\Microsoft\Windows\Customer Experience Improvement Program\UsbCeip',
        '\Microsoft\Windows\DiskDiagnostic\Microsoft-Windows-DiskDiagnosticDataCollector',
        '\Microsoft\Windows\Feedback\Siuf\DmClient',
        '\Microsoft\Windows\Feedback\Siuf\DmClientOnScenarioDownload',
        '\Microsoft\Windows\Windows Error Reporting\QueueReporting',
        '\Microsoft\Windows\Autochk\Proxy'
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
    'The paging file is too small for this operation to complete' does NOT mean
    the pagefile is missing. It means the commit limit - physical RAM plus the
    pagefile maximum - was reached. A fixed 4096 MB pagefile on an 8 GB machine
    caps the commit limit at about 12 GB, which one Docker daemon plus a
    compiler plus a browser will exhaust. This sizes it against installed RAM.
#>
function Repair-KhzPagefile {
    [CmdletBinding()] param(
        [switch]$Apply,
        [int]$InitialMB = 0,
        [int]$MaximumMB = 0,
        [switch]$UseAutomatic
    )

    Write-Khz "`n[7] virtual memory" 'head'

    $cs  = Get-CimInstance Win32_ComputerSystem
    $os  = Get-CimInstance Win32_OperatingSystem
    $ramGB = [math]::Round($cs.TotalPhysicalMemory / 1GB, 1)

    $usage = @(Get-CimInstance Win32_PageFileUsage -ErrorAction SilentlyContinue)
    $currentMB = if ((Get-KhzCount $usage) -gt 0) { $usage[0].AllocatedBaseSize } else { 0 }
    $peakMB    = if ((Get-KhzCount $usage) -gt 0) { $usage[0].PeakUsage } else { 0 }

    $commitLimitGB = [math]::Round(($os.TotalVirtualMemorySize) / 1MB, 1)
    $commitUsedGB  = [math]::Round(($os.TotalVirtualMemorySize - $os.FreeVirtualMemory) / 1MB, 1)

    Write-Khz "    physical RAM       : $ramGB GB"
    Write-Khz "    pagefile           : $currentMB MB (peak $peakMB MB)"
    Write-Khz "    automatic managed  : $($cs.AutomaticManagedPagefile)"
    Write-Khz "    commit limit       : $commitLimitGB GB, in use $commitUsedGB GB"

    # Target: enough headroom that a compiler, Docker and a browser coexist.
    if ($InitialMB -le 0) { $InitialMB = [int]([math]::Max(8192, $ramGB * 1024)) }
    if ($MaximumMB -le 0) { $MaximumMB = [int]([math]::Max(24576, $ramGB * 1024 * 3)) }

    $needsWork = $currentMB -lt $InitialMB

    if (-not $needsWork) {
        Write-Khz '    already sized adequately' 'ok'
        return 0L
    }

    Write-Khz "    RECOMMENDED        : initial $InitialMB MB, maximum $MaximumMB MB" 'warn'
    Write-Khz "    reason             : $currentMB MB + $ramGB GB RAM is what produced" 'warn'
    Write-Khz "                         'The paging file is too small' on this box" 'warn'

    if (-not (Test-KhzAdmin)) { Write-Khz '    needs admin to change' 'err'; return 0L }
    if (-not $Apply) { Write-Khz '    would resize the pagefile' 'warn'; return 0L }

    try {
        if ($UseAutomatic) {
            Set-CimInstance -InputObject $cs -Property @{ AutomaticManagedPagefile = $true } -ErrorAction Stop
            Write-Khz '    enabled automatic pagefile' 'ok'
        } else {
            if ($cs.AutomaticManagedPagefile) {
                Set-CimInstance -InputObject $cs -Property @{ AutomaticManagedPagefile = $false } -ErrorAction Stop
            }
            $setting = @(Get-CimInstance Win32_PageFileSetting -ErrorAction SilentlyContinue)
            if ((Get-KhzCount $setting) -gt 0) {
                Set-CimInstance -InputObject $setting[0] `
                    -Property @{ InitialSize = $InitialMB; MaximumSize = $MaximumMB } -ErrorAction Stop
            } else {
                New-CimInstance -ClassName Win32_PageFileSetting -Property @{
                    Name        = "$env:SystemDrive\pagefile.sys"
                    InitialSize = $InitialMB
                    MaximumSize = $MaximumMB
                } -ErrorAction Stop | Out-Null
            }
            Write-Khz "    pagefile set to $InitialMB / $MaximumMB MB" 'ok'
        }
        Write-Khz '    REBOOT REQUIRED' 'err'
    } catch {
        Write-Khz "    failed: $($_.Exception.Message)" 'err'
    }
    0L
}

# ---------------------------------------------------------------- 8. memory

<#
    On a RAM-starved box the useful question is not what is on disk but what is
    resident. This reports it and offers to trim startup entries.
#>
function Optimize-KhzMemory {
    [CmdletBinding()] param([int]$Top = 12, [switch]$Apply)

    Write-Khz "`n[8] memory pressure" 'head'

    $os = Get-CimInstance Win32_OperatingSystem
    $totalGB = [math]::Round($os.TotalVisibleMemorySize / 1MB, 2)
    $freeGB  = [math]::Round($os.FreePhysicalMemory / 1MB, 2)
    $usedPct = if ($totalGB -gt 0) { [math]::Round((1 - ($freeGB / $totalGB)) * 100, 1) } else { 0 }

    Write-Khz "    RAM $freeGB GB free of $totalGB GB  ($usedPct% used)" $(if ($usedPct -gt 85) { 'err' } else { 'info' })

    $groups = Get-Process -ErrorAction SilentlyContinue |
              Group-Object -Property ProcessName |
              ForEach-Object {
                  [pscustomobject]@{
                      Name = $_.Name
                      MB   = [math]::Round((($_.Group | Measure-Object WorkingSet64 -Sum).Sum) / 1MB, 1)
                      N    = (Get-KhzCount $_.Group)
                  }
              } | Sort-Object MB -Descending | Select-Object -First $Top

    Write-Khz ''
    foreach ($g in $groups) {
        Write-Khz ('    {0,-28} {1,8} MB  x{2}' -f $g.Name, $g.MB, $g.N)
    }

    $startup = @(Get-CimInstance Win32_StartupCommand -ErrorAction SilentlyContinue)
    Write-Khz ''
    Write-Khz ('    startup entries: {0}' -f (Get-KhzCount $startup))
    foreach ($s in $startup) {
        Write-Khz ('      {0,-26} {1}' -f $s.Name, $s.Location)
    }

    0L
}

# ---------------------------------------------------------------- 9. WinSxS

function Clear-KhzComponentStore {
    [CmdletBinding()] param([switch]$Apply, [switch]$ResetBase)

    Write-Khz "`n[9] component store (WinSxS)" 'head'
    if (-not (Test-KhzAdmin)) { Write-Khz '    needs admin - skipped' 'warn'; return 0L }

    if (-not $Apply) {
        Write-Khz '    analysing (read-only, this takes a minute)...'
        & dism.exe /Online /Cleanup-Image /AnalyzeComponentStore |
            Where-Object { $_ -match 'Size|Reclaimable|Recommended' } |
            ForEach-Object { Write-Khz "    $($_.Trim())" }
        Write-Khz '    would run StartComponentCleanup' 'warn'
        return 0L
    }

    $args = @('/Online', '/Cleanup-Image', '/StartComponentCleanup')
    if ($ResetBase) { $args += '/ResetBase' }
    Write-Khz "    dism $($args -join ' ')"
    & dism.exe @args | Where-Object { $_ -match 'complete|error|Error' } |
        ForEach-Object { Write-Khz "    $($_.Trim())" }

    if ($ResetBase) {
        Write-Khz '    /ResetBase used - installed updates can no longer be uninstalled' 'warn'
    }
    0L
}

# ---------------------------------------------------------------- reports

function Get-KhzWslImages {
    [CmdletBinding()] param()

    Write-Khz "`n[wsl] virtual disks" 'head'
    $roots = @(
        "$env:LOCALAPPDATA\Packages",
        "$env:LOCALAPPDATA\Docker\wsl",
        "$env:LOCALAPPDATA\wsl",
        "$env:ProgramData\DockerDesktop"
    )

    $found = @()
    foreach ($r in $roots) {
        if (-not (Test-Path -LiteralPath $r)) { continue }
        $found += @(Get-ChildItem -LiteralPath $r -Recurse -Force -Filter '*.vhdx' -ErrorAction SilentlyContinue)
    }

    if ((Get-KhzCount $found) -eq 0) { Write-Khz '    none found' 'ok'; return }

    foreach ($f in ($found | Sort-Object Length -Descending)) {
        Write-Khz ('    {0,10}  {1}' -f (Format-KhzBytes $f.Length), $f.FullName)
    }

    Write-Khz ''
    Write-Khz '    a vhdx never shrinks on its own. To compact:' 'warn'
    Write-Khz '      wsl --shutdown'
    Write-Khz '      Optimize-VHD -Path <file> -Mode Full      # needs Hyper-V module'
    Write-Khz '      # or: diskpart -> select vdisk file="<file>" -> compact vdisk'
}

function Get-KhzDiskHogs {
    [CmdletBinding()] param(
        [string]$Path = $env:SystemDrive,
        [int]$Top = 20,
        [int]$Depth = 2
    )

    Write-Khz "`n[hogs] largest folders under $Path" 'head'

    $dirs = @(Get-ChildItem -LiteralPath $Path -Directory -Force -ErrorAction SilentlyContinue)
    $rows = foreach ($d in $dirs) {
        [pscustomobject]@{ Path = $d.FullName; Bytes = (Get-KhzPathSize $d.FullName) }
    }

    foreach ($r in (@($rows) | Sort-Object Bytes -Descending | Select-Object -First $Top)) {
        Write-Khz ('    {0,10}  {1}' -f (Format-KhzBytes $r.Bytes), $r.Path)
    }
}

function Get-KhzReport {
    [CmdletBinding()] param()

    $letter = $env:SystemDrive.TrimEnd(':')
    $drive  = Get-PSDrive -Name $letter -ErrorAction SilentlyContinue
    $os     = Get-CimInstance Win32_OperatingSystem -ErrorAction SilentlyContinue

    [pscustomobject]@{
        Timestamp    = Get-Date
        FreeGB       = if ($drive) { [math]::Round($drive.Free / 1GB, 2) } else { 0 }
        UsedGB       = if ($drive) { [math]::Round($drive.Used / 1GB, 2) } else { 0 }
        RamFreeGB    = if ($os) { [math]::Round($os.FreePhysicalMemory / 1MB, 2) } else { 0 }
        RamTotalGB   = if ($os) { [math]::Round($os.TotalVisibleMemorySize / 1MB, 2) } else { 0 }
        Processes    = Get-KhzCount (Get-Process -ErrorAction SilentlyContinue)
        StartupItems = Get-KhzCount (Get-CimInstance Win32_StartupCommand -ErrorAction SilentlyContinue)
        GraphModules = Get-KhzCount (Get-Module -ListAvailable Microsoft.Graph* -ErrorAction SilentlyContinue)
        AzModules    = Get-KhzCount (Get-Module -ListAvailable Az.* -ErrorAction SilentlyContinue)
    }
}

# ---------------------------------------------------------------- daily task

function Register-KhzDailyTask {
    [CmdletBinding()] param([string]$At = '03:30', [switch]$Apply)

    Write-Khz "`n[task] daily schedule" 'head'
    if (-not (Test-KhzAdmin)) { Write-Khz '    needs admin' 'err'; return }

    $manifest = Join-Path $PSScriptRoot 'KhzJanitor.psd1'
    $cmd = "Import-Module '$manifest' -Force; Invoke-KhzJanitor -Apply -Quiet -Tasks Logs,Caches,EdgeExtensions"
    $enc = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($cmd))

    $exe = if ($PSVersionTable.PSEdition -eq 'Core') { 'pwsh.exe' } else { 'powershell.exe' }

    if (-not $Apply) {
        Write-Khz "    would register 'KhzJanitor Daily' at $At via $exe" 'warn'
        Write-Khz "    module: $manifest"
        return
    }

    $action    = New-ScheduledTaskAction -Execute $exe `
                    -Argument "-NoProfile -NonInteractive -WindowStyle Hidden -EncodedCommand $enc"
    $trigger   = New-ScheduledTaskTrigger -Daily -At $At
    $principal = New-ScheduledTaskPrincipal -UserId 'SYSTEM' -LogonType ServiceAccount -RunLevel Highest
    $settings  = New-ScheduledTaskSettingsSet -StartWhenAvailable `
                    -DontStopIfGoingOnBatteries -AllowStartIfOnBatteries `
                    -ExecutionTimeLimit (New-TimeSpan -Minutes 30)

    Register-ScheduledTask -TaskName 'KhzJanitor Daily' -Action $action -Trigger $trigger `
        -Principal $principal -Settings $settings -Force -Description 'KhzJanitor cleanup' | Out-Null

    Write-Khz "    registered 'KhzJanitor Daily' at $At" 'ok'
    Write-Khz '    note: the SYSTEM account has its own profile, so per-user' 'warn'
    Write-Khz '    browser caches are only cleared when you run it yourself.' 'warn'
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
        [ValidateSet('Logs','Caches','EdgeExtensions','Copilot','Modules','Telemetry',
                     'Pagefile','Memory','Components','All')]
        [string[]]$Tasks = @('All'),

        # Nothing is deleted without this switch.
        [switch]$Apply,

        [switch]$Aggressive,
        [switch]$Quiet
    )

    if ($Tasks -contains 'All') {
        $Tasks = @('Logs','Caches','EdgeExtensions','Copilot','Modules','Telemetry','Pagefile','Memory')
    }

    New-Item -ItemType Directory -Path $script:LogDir -Force | Out-Null
    $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
    $log = Join-Path $script:LogDir "khz-$stamp.log"
    try { Start-Transcript -Path $log -Force | Out-Null } catch { }

    $before = Get-KhzReport

    if (-not $Quiet) {
        Write-Khz ''
        Write-Khz '  KhzJanitor 1.1.0' 'head'
        Write-Khz ('  mode: {0}' -f $(if ($Apply) { 'APPLY - deleting' } else { 'DRY RUN - nothing will be deleted' })) `
                  $(if ($Apply) { 'err' } else { 'warn' })
        Write-Khz ('  disk free {0} GB   RAM free {1} of {2} GB   admin {3}' -f
            $before.FreeGB, $before.RamFreeGB, $before.RamTotalGB, (Test-KhzAdmin))
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
            'Memory'         { $freed += Optimize-KhzMemory }
            'Components'     { $freed += Clear-KhzComponentStore -Apply:$Apply -ResetBase:$Aggressive }
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
    Disable-KhzTelemetry, Repair-KhzPagefile, Optimize-KhzMemory,
    Clear-KhzComponentStore, Get-KhzDiskHogs, Get-KhzWslImages,
    Register-KhzDailyTask, Unregister-KhzDailyTask, Get-KhzReport
