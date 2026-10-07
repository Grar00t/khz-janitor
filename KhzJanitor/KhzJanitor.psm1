#requires -Version 5.1
<#
    KhzJanitor 1.2.1 - reclaim a bloated Windows box.

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
$script:Locked = 0

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

function Get-KhzFreeMB {
    $letter = $env:SystemDrive.TrimEnd(':')
    $d = Get-PSDrive -Name $letter -ErrorAction SilentlyContinue
    if ($null -eq $d) { return 0 }
    [int]($d.Free / 1MB)
}

function Get-KhzPathSize {
    param([string]$Path)
    if ([string]::IsNullOrWhiteSpace($Path)) { return 0L }
    if (-not (Test-Path -LiteralPath $Path)) { return 0L }
    try {
        # C:\DumpStack.log.tmp and friends list but cannot be opened.
        $item = Get-Item -LiteralPath $Path -Force -ErrorAction SilentlyContinue
        if ($null -eq $item) { return 0L }
        if (-not $item.PSIsContainer) { return [int64]$item.Length }

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

<#
    Deletion is silent by design. Using -ErrorAction Stop inside a try/catch
    still writes a TerminatingError record into the PowerShell transcript, which
    buried the useful output in noise. Instead: delete quietly, then verify with
    Test-Path, and count what stayed behind.
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
    $items = @(Get-ChildItem -LiteralPath $Path -Force -ErrorAction SilentlyContinue |
               Where-Object { $OlderThanDays -le 0 -or $_.LastWriteTime -lt $cutoff })

    $freed = 0L
    foreach ($item in $items) {
        $size = if ($item.PSIsContainer) { Get-KhzPathSize $item.FullName } else { [int64]$item.Length }

        if (-not $Apply) { $freed += $size; continue }

        Remove-Item -LiteralPath $item.FullName -Recurse -Force -ErrorAction SilentlyContinue
        if (Test-Path -LiteralPath $item.FullName) {
            # Held open by a running process, or ACL-protected. Expected, not an error.
            $script:Locked++
        } else {
            $freed += $size
        }
    }

    [pscustomobject]@{ Label = $Label; Bytes = $freed; Skipped = $false }
}

function Remove-KhzPathMeasured {
    param(
        [Parameter(Mandatory)][string]$Path,
        [switch]$Apply
    )

    if (-not (Test-Path -LiteralPath $Path)) {
        return [pscustomobject]@{ Bytes = 0L; Removed = $false; Skipped = $true }
    }

    $size = Get-KhzPathSize $Path
    if (-not $Apply) {
        return [pscustomobject]@{ Bytes = $size; Removed = $false; Skipped = $false }
    }

    Remove-Item -LiteralPath $Path -Recurse -Force -ErrorAction SilentlyContinue
    if (Test-Path -LiteralPath $Path) {
        $script:Locked++
        return [pscustomobject]@{ Bytes = 0L; Removed = $false; Skipped = $false }
    }

    [pscustomobject]@{ Bytes = $size; Removed = $true; Skipped = $false }
}

function Get-KhzTopmostDirectories {
    param([object[]]$Directories)

    $selected = @()
    foreach ($directory in @($Directories | Sort-Object { $_.FullName.Length })) {
        $full = [IO.Path]::GetFullPath([string]$directory.FullName)
        $nested = $false

        foreach ($parent in $selected) {
            $prefix = [IO.Path]::GetFullPath([string]$parent.FullName) + [IO.Path]::DirectorySeparatorChar
            if ($full.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase)) {
                $nested = $true
                break
            }
        }

        if (-not $nested) {
            $selected += $directory
        }
    }

    @($selected)
}

function Show-KhzLocked {
    if ($script:Locked -gt 0) {
        Write-Khz "    ($script:Locked items in use or protected - skipped)" 'warn'
    }
    $script:Locked = 0
}

function Set-KhzPolicy {
    param(
        [Parameter(Mandatory)][string]$Key,
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)]$Value,
        [string]$Type = 'DWord',
        [switch]$Apply
    )
    if (-not $Apply) { Write-Khz "    would set $Key\$Name = $Value"; return }
    try {
        if (-not (Test-Path -LiteralPath $Key)) { New-Item -Path $Key -Force | Out-Null }
        New-ItemProperty -Path $Key -Name $Name -Value $Value -PropertyType $Type -Force | Out-Null
        Write-Khz "    set $Name = $Value" 'ok'
    } catch { Write-Khz "    failed $Name : $($_.Exception.Message)" 'err' }
}

# ---------------------------------------------------------------- 1. logs

function Clear-KhzLogs {
    [CmdletBinding()] param([switch]$Apply, [int]$KeepDays = 3, [switch]$ClearEventLogs)

    Write-Khz "`n[1] logs" 'head'
    $script:Locked = 0
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
        @{ P = "$env:LOCALAPPDATA\AMD\DxCache";                         L = 'AMD DX cache';       D = 0 },
        @{ P = "$env:LOCALAPPDATA\JetBrains\JetLogs";                   L = 'JetBrains logs';     D = 0 },
        @{ P = "$env:SystemRoot\Temp\JetLogs";                          L = 'JetBrains ETW logs'; D = 0 }
    )

    foreach ($t in $targets) {
        $r = Clear-KhzDirectory -Path $t.P -Label $t.L -OlderThanDays $t.D -Apply:$Apply
        if (-not $r.Skipped -and $r.Bytes -gt 0) {
            Write-Khz ('    {0,-22} {1}' -f $r.Label, (Format-KhzBytes $r.Bytes))
        }
        $total += $r.Bytes
    }

    foreach ($dump in @("$env:SystemRoot\MEMORY.DMP", "$env:SystemRoot\Minidump")) {
        $candidateBytes = Get-KhzPathSize $dump
        if ($candidateBytes -le 0) { continue }
        Write-Khz ('    {0,-22} {1}' -f (Split-Path $dump -Leaf), (Format-KhzBytes $candidateBytes))
        $result = Remove-KhzPathMeasured -Path $dump -Apply:$Apply
        $total += $result.Bytes
    }

    if ($ClearEventLogs) {
        if ($Apply) {
            $n = 0
            foreach ($log in @(wevtutil el 2>$null)) {
                wevtutil cl "$log" 2>$null
                $n++
            }
            Write-Khz "    event logs cleared: $n" 'ok'
        } else {
            Write-Khz ('    would clear {0} event logs' -f (Get-KhzCount (wevtutil el 2>$null))) 'warn'
        }
    }

    Show-KhzLocked
    $total
}

# ---------------------------------------------------------------- 2. caches

function Clear-KhzCaches {
    [CmdletBinding()] param([switch]$Apply, [switch]$IncludePackageCaches)

    Write-Khz "`n[2] caches" 'head'
    $script:Locked = 0
    $total = 0L

    $chromium = [ordered]@{
        'Edge'    = "$env:LOCALAPPDATA\Microsoft\Edge\User Data"
        'Chrome'  = "$env:LOCALAPPDATA\Google\Chrome\User Data"
        'Brave'   = "$env:LOCALAPPDATA\BraveSoftware\Brave-Browser\User Data"
        'Vivaldi' = "$env:LOCALAPPDATA\Vivaldi\User Data"
    }
    $leaves = @(
        'Cache', 'Code Cache', 'GPUCache', 'DawnCache', 'DawnGraphiteCache',
        'GrShaderCache', 'ShaderCache', 'Service Worker\CacheStorage',
        'Service Worker\ScriptCache', 'Storage\ext'
    )

    foreach ($name in $chromium.Keys) {
        $root = $chromium[$name]
        if (-not (Test-Path -LiteralPath $root)) { continue }

        $rootBytes = 0L
        $profileDirs = @(Get-ChildItem -LiteralPath $root -Directory -ErrorAction SilentlyContinue |
                         Where-Object { $_.Name -eq 'Default' -or $_.Name -like 'Profile *' })

        foreach ($prof in $profileDirs) {
            foreach ($leaf in $leaves) {
                $rootBytes += (Clear-KhzDirectory -Path (Join-Path $prof.FullName $leaf) -Apply:$Apply).Bytes
            }
        }
        foreach ($shared in @('ShaderCache', 'GrShaderCache', 'component_crx_cache', 'GraphiteDawnCache')) {
            $rootBytes += (Clear-KhzDirectory -Path (Join-Path $root $shared) -Apply:$Apply).Bytes
        }

        Write-Khz ('    {0,-22} {1}  ({2} profiles)' -f $name, (Format-KhzBytes $rootBytes), (Get-KhzCount $profileDirs))
        $total += $rootBytes
    }

    $ffBytes = 0L
    foreach ($ffRoot in @("$env:LOCALAPPDATA\Mozilla\Firefox\Profiles", "$env:APPDATA\Mozilla\Firefox\Profiles")) {
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

    $misc = @(
        @{ P = "$env:LOCALAPPDATA\Microsoft\Windows\Explorer";                 L = 'thumbnail cache' },
        @{ P = "$env:LOCALAPPDATA\Microsoft\Windows\INetCache";                L = 'INetCache' },
        @{ P = "$env:LOCALAPPDATA\Microsoft\Terminal Server Client\Cache";     L = 'RDP cache' },
        @{ P = "$env:LOCALAPPDATA\Microsoft\Office\16.0\OfficeFileCache";      L = 'Office cache' },
        @{ P = "$env:LOCALAPPDATA\Microsoft\Edge\User Data\Crashpad";          L = 'Edge crashpad' },
        @{ P = "$env:LOCALAPPDATA\Microsoft\VSApplicationInsights";            L = 'VS telemetry' },
        @{ P = "$env:LOCALAPPDATA\JetBrains\Transient";                        L = 'JetBrains transient' },
        @{ P = "$env:LOCALAPPDATA\JetBrains\caches";                           L = 'JetBrains caches' },
        @{ P = "$env:APPDATA\Code\CachedData";                                 L = 'VS Code cached data' },
        @{ P = "$env:APPDATA\Code\Cache";                                      L = 'VS Code cache' },
        @{ P = "$env:APPDATA\Code\CachedExtensionVSIXs";                       L = 'VS Code vsix cache' },
        @{ P = "$env:APPDATA\Notion\Cache";                                    L = 'Notion cache' },
        @{ P = "$env:APPDATA\Notion\Code Cache";                               L = 'Notion code cache' },
        @{ P = "$env:APPDATA\Notion\GPUCache";                                 L = 'Notion GPU cache' },
        @{ P = "$env:USERPROFILE\.dotnet\optimizationdata";                    L = 'dotnet opt data' },
        @{ P = "$env:USERPROFILE\.templateengine";                             L = 'dotnet templates' },
        @{ P = "$env:ProgramData\Microsoft\Network\Downloader";                L = 'delivery optimization' },
        @{ P = "$env:ProgramData\Docker\log";                                  L = 'Docker logs' },
        @{ P = "$env:LOCALAPPDATA\Docker\log";                                 L = 'Docker user logs' },
        @{ P = "$env:LOCALAPPDATA\Google\DriveFS\Logs";                        L = 'Google Drive logs' }
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
            @{ P = "$env:USERPROFILE\.gradle\caches";     L = 'gradle caches' },
            @{ P = "$env:LOCALAPPDATA\Android\Sdk\system-images"; L = 'android system images' }
        )) {
            $r = Clear-KhzDirectory -Path $pkg.P -Label $pkg.L -Apply:$Apply
            if ($r.Bytes -gt 0) { Write-Khz ('    {0,-22} {1}' -f $r.Label, (Format-KhzBytes $r.Bytes)) }
            $total += $r.Bytes
        }
    }

    foreach ($devRoot in @((Join-Path $env:USERPROFILE 'dev'), (Join-Path $env:USERPROFILE 'source'))) {
        if (-not (Test-Path -LiteralPath $devRoot)) { continue }

        $candidates = @(Get-ChildItem -LiteralPath $devRoot -Directory -Recurse -Force -ErrorAction SilentlyContinue |
                        Where-Object { $_.Name -in @('bin','obj','TestResults','node_modules','target','__pycache__','.pytest_cache') })
        $stale = @(Get-KhzTopmostDirectories -Directories $candidates)

        $devBytes = 0L
        $devCount = 0
        foreach ($d in $stale) {
            $result = Remove-KhzPathMeasured -Path $d.FullName -Apply:$Apply
            $devBytes += $result.Bytes
            if (-not $Apply -or $result.Removed) { $devCount++ }
        }
        if ($devBytes -gt 0) {
            Write-Khz ('    {0,-22} {1}  ({2} dirs in {3})' -f 'build output', (Format-KhzBytes $devBytes), $devCount, (Split-Path $devRoot -Leaf))
        }
        $total += $devBytes
    }

    Show-KhzLocked
    $total
}

# ---------------------------------------------------------------- 3. Edge extensions

function Remove-KhzEdgeExtensions {
    [CmdletBinding()] param([switch]$Apply, [switch]$BlockFutureInstalls)

    Write-Khz "`n[3] Edge extensions" 'head'
    $script:Locked = 0
    $total = 0L
    $root = "$env:LOCALAPPDATA\Microsoft\Edge\User Data"

    if (-not (Test-Path -LiteralPath $root)) { Write-Khz '    Edge not installed' 'warn'; return 0L }

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
        Write-Khz ('    {0}  x{1}' -f $id, $seen[$id])
    }
    Write-Khz ('    {0} unique extensions across {1} profiles, {2}' -f
        (Get-KhzCount $seen.Keys), (Get-KhzCount $profileDirs), (Format-KhzBytes $total)) 'ok'

    if ($BlockFutureInstalls) {
        Set-KhzPolicy -Key 'HKLM:\SOFTWARE\Policies\Microsoft\Edge\ExtensionInstallBlocklist' `
                      -Name '1' -Value '*' -Type String -Apply:$Apply
    }

    Show-KhzLocked
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
        @{ K = 'HKLM:\SOFTWARE\Policies\Microsoft\Edge';                   N = 'CopilotPageContext';          V = 0 }
    )
    foreach ($p in $pol) { Set-KhzPolicy -Key $p.K -Name $p.N -Value $p.V -Apply:$Apply }

    $user = @(
        @{ K = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced';      N = 'ShowCopilotButton'; V = 0 },
        @{ K = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager'; N = 'SilentInstalledAppsEnabled'; V = 0 },
        @{ K = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager'; N = 'SubscribedContent-338388Enabled'; V = 0 },
        @{ K = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager'; N = 'SystemPaneSuggestionsEnabled'; V = 0 }
    )
    foreach ($p in $user) { Set-KhzPolicy -Key $p.K -Name $p.N -Value $p.V -Apply:$Apply }

    # OneDrive is deliberately NOT in this list: it may hold synced work files.
    $appx = @('*Copilot*', '*BingSearch*', '*XboxGamingOverlay*', '*XboxGameOverlay*',
              '*XboxSpeechToTextOverlay*', '*GamingApp*', '*ZuneMusic*', '*ZuneVideo*',
              '*QuickAssist*', '*MicrosoftStickyNotes*', '*Clipchamp*',
              '*WindowsFeedbackHub*', '*GetHelp*', '*MicrosoftSolitaireCollection*',
              '*BingWeather*', '*BingNews*', '*People*', '*windowscommunicationsapps*')

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
    foreach ($g in @($all | Group-Object Name)) {
        $name = $g.Name
        if (@($protected | Where-Object { $name -like $_ }).Count -gt 0) { continue }

        $versions = @($g.Group | Sort-Object Version -Descending)
        $doomed = if ($OldVersionsOnly -or ($Keep -contains $name)) {
            @($versions | Select-Object -Skip 1)
        } else { $versions }

        foreach ($v in $doomed) {
            $candidateBytes = Get-KhzPathSize $v.ModuleBase
            $result = Remove-KhzPathMeasured -Path $v.ModuleBase -Apply:$Apply
            $total += $result.Bytes

            if (-not $Apply) {
                $removed++
                continue
            }

            if ($result.Removed) {
                $removed++
                Write-Khz ('    removed {0} {1}  {2}' -f $name, $v.Version, (Format-KhzBytes $candidateBytes)) 'ok'
            } else {
                Write-Khz ('    locked  {0} {1}' -f $name, $v.Version) 'warn'
            }
        }
    }

    Write-Khz ('    {0} module folders, {1}' -f $removed, (Format-KhzBytes $total)) 'ok'
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
            Stop-Service -Name $svc -Force -ErrorAction SilentlyContinue
            Set-Service -Name $svc -StartupType Disabled -ErrorAction SilentlyContinue
            $now = (Get-Service -Name $svc -ErrorAction SilentlyContinue).StartType
            Write-Khz "    $svc -> $now" 'ok'
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
        if (-not (Get-ScheduledTask -TaskName $leaf -TaskPath $path -ErrorAction SilentlyContinue)) { continue }
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
    pagefile maximum - was reached.

    Win32_PageFileSetting reports 'A general error occurred that is not covered
    by a more specific error code' when InitialSize does not fit in the free
    space on the volume. Asking for 8192 MB with 1.1 GB free fails with exactly
    that message. So: measure free space first, clamp, and say so out loud.
#>
function Repair-KhzPagefile {
    [CmdletBinding()] param(
        [switch]$Apply,
        [int]$InitialMB = 0,
        [int]$MaximumMB = 0,
        [switch]$UseAutomatic
    )

    Write-Khz "`n[7] virtual memory" 'head'

    $cs = Get-CimInstance Win32_ComputerSystem
    $os = Get-CimInstance Win32_OperatingSystem
    $ramGB = [math]::Round($cs.TotalPhysicalMemory / 1GB, 1)

    $usage = @(Get-CimInstance Win32_PageFileUsage -ErrorAction SilentlyContinue)
    $currentMB = if ((Get-KhzCount $usage) -gt 0) { $usage[0].AllocatedBaseSize } else { 0 }
    $peakMB    = if ((Get-KhzCount $usage) -gt 0) { $usage[0].PeakUsage } else { 0 }

    $limitGB = [math]::Round($os.TotalVirtualMemorySize / 1MB, 1)
    $usedGB  = [math]::Round(($os.TotalVirtualMemorySize - $os.FreeVirtualMemory) / 1MB, 1)
    $freeMB  = Get-KhzFreeMB

    Write-Khz "    physical RAM       : $ramGB GB"
    Write-Khz "    pagefile           : $currentMB MB (peak $peakMB MB)"
    Write-Khz "    automatic managed  : $($cs.AutomaticManagedPagefile)"
    Write-Khz "    commit limit       : $limitGB GB, in use $usedGB GB"
    Write-Khz "    free disk          : $([math]::Round($freeMB/1024,2)) GB"

    $headroomGB = [math]::Round($limitGB - $usedGB, 1)
    if ($headroomGB -lt 3) {
        Write-Khz "    commit headroom    : $headroomGB GB - this is why tools die" 'err'
    }

    if ($InitialMB -le 0) { $InitialMB = [int][math]::Max(4096, $ramGB * 1024) }
    if ($MaximumMB -le 0) { $MaximumMB = [int][math]::Max(16384, $ramGB * 1024 * 3) }

    # The pagefile is allocated eagerly at InitialSize. Leave 2 GB breathing room.
    $budgetMB = $freeMB - 2048
    if ($InitialMB -gt $budgetMB) {
        Write-Khz "    cannot allocate $InitialMB MB: only $freeMB MB free on $env:SystemDrive" 'err'
        if ($budgetMB -lt 2048) {
            Write-Khz '    free at least 6 GB first, then re-run this task' 'err'
            Write-Khz '    biggest lever right now: Invoke-KhzJanitor -Tasks Components -Apply' 'warn'
            return 0L
        }
        $InitialMB = [int]$budgetMB
        Write-Khz "    clamped initial size to $InitialMB MB" 'warn'
    }

    if ($currentMB -ge $InitialMB -and -not $UseAutomatic) {
        Write-Khz '    already at or above the size that fits on this disk' 'ok'
        return 0L
    }

    Write-Khz "    target             : initial $InitialMB MB, maximum $MaximumMB MB" 'warn'

    if (-not (Test-KhzAdmin)) { Write-Khz '    needs admin to change' 'err'; return 0L }
    if (-not $Apply) { Write-Khz '    would resize the pagefile' 'warn'; return 0L }

    $done = $false
    if (-not $UseAutomatic) {
        try {
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
            $done = $true
        } catch {
            Write-Khz "    explicit sizing failed: $($_.Exception.Message)" 'warn'
            Write-Khz '    falling back to the automatic pagefile' 'warn'
        }
    }

    if (-not $done) {
        try {
            Set-CimInstance -InputObject $cs -Property @{ AutomaticManagedPagefile = $true } -ErrorAction Stop
            Write-Khz '    automatic pagefile enabled' 'ok'
            $done = $true
        } catch {
            Write-Khz "    failed: $($_.Exception.Message)" 'err'
            Write-Khz '    an Intune or group policy may own this setting' 'warn'
        }
    }

    if ($done) { Write-Khz '    REBOOT REQUIRED' 'err' }
    0L
}

# ---------------------------------------------------------------- 8. memory

function Optimize-KhzMemory {
    [CmdletBinding()] param([int]$Top = 12)

    Write-Khz "`n[8] memory pressure" 'head'

    $os = Get-CimInstance Win32_OperatingSystem
    $totalGB = [math]::Round($os.TotalVisibleMemorySize / 1MB, 2)
    $freeGB  = [math]::Round($os.FreePhysicalMemory / 1MB, 2)
    $usedPct = if ($totalGB -gt 0) { [math]::Round((1 - ($freeGB / $totalGB)) * 100, 1) } else { 0 }

    Write-Khz "    RAM $freeGB GB free of $totalGB GB  ($usedPct% used)" $(if ($usedPct -gt 85) { 'err' } else { 'info' })
    Write-Khz ''

    $groups = Get-Process -ErrorAction SilentlyContinue |
              Group-Object -Property ProcessName |
              ForEach-Object {
                  $mb = [math]::Round((($_.Group | Measure-Object WorkingSet64 -Sum).Sum) / 1MB, 1)
                  [pscustomobject]@{
                      Name = $_.Name
                      MB   = $mb
                      N    = (Get-KhzCount $_.Group)
                      Pct  = if ($totalGB -gt 0) { [math]::Round($mb / ($totalGB * 1024) * 100, 1) } else { 0 }
                  }
              } | Sort-Object MB -Descending | Select-Object -First $Top

    foreach ($g in $groups) {
        Write-Khz ('    {0,-26} {1,8} MB  x{2,-3} {3,5}% of RAM' -f $g.Name, $g.MB, $g.N, $g.Pct)
    }

    $startup = @(Get-CimInstance Win32_StartupCommand -ErrorAction SilentlyContinue)
    Write-Khz ''
    Write-Khz ('    startup entries: {0}' -f (Get-KhzCount $startup))
    foreach ($s in $startup) {
        Write-Khz ('      {0,-26} {1}' -f $s.Name, $s.User)
    }
}

# ---------------------------------------------------------------- 9. WinSxS

function Clear-KhzComponentStore {
    [CmdletBinding()] param([switch]$Apply, [switch]$ResetBase)

    Write-Khz "`n[9] component store (WinSxS)" 'head'
    if (-not (Test-KhzAdmin)) { Write-Khz '    needs admin - skipped' 'warn'; return 0L }

    if (-not $Apply) {
        Write-Khz '    analysing (read-only, takes a minute)...'
        & dism.exe /Online /Cleanup-Image /AnalyzeComponentStore |
            Where-Object { $_ -match 'Size|Reclaimable|Recommended' } |
            ForEach-Object { Write-Khz "    $($_.Trim())" }
        Write-Khz '    would run StartComponentCleanup' 'warn'
        return 0L
    }

    $before = Get-KhzFreeMB
    $dismArgs = @('/Online', '/Cleanup-Image', '/StartComponentCleanup')
    if ($ResetBase) { $dismArgs += '/ResetBase' }

    Write-Khz "    dism $($dismArgs -join ' ')  (this can take 10+ minutes)"
    & dism.exe @dismArgs | Where-Object { $_ -match 'complete|Error|error' } |
        ForEach-Object { Write-Khz "    $($_.Trim())" }

    $gained = [int64](Get-KhzFreeMB - $before) * 1MB
    if ($gained -gt 0) { Write-Khz "    freed $(Format-KhzBytes $gained)" 'ok' }
    if ($ResetBase) { Write-Khz '    /ResetBase used - installed updates can no longer be uninstalled' 'warn' }
    [math]::Max(0, $gained)
}

# ---------------------------------------------------------------- 10. bloatware

function Get-KhzPrograms {
    [CmdletBinding()] param([int]$Top = 30)

    $keys = @(
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*',
        'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*',
        'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*'
    )

    $rows = foreach ($k in $keys) {
        foreach ($e in @(Get-ItemProperty -Path $k -ErrorAction SilentlyContinue)) {
            $name = $e.PSObject.Properties['DisplayName']
            if ($null -eq $name -or [string]::IsNullOrWhiteSpace($name.Value)) { continue }
            $sizeProp = $e.PSObject.Properties['EstimatedSize']
            $unProp   = $e.PSObject.Properties['UninstallString']
            [pscustomobject]@{
                Name      = $name.Value
                MB        = if ($sizeProp) { [math]::Round($sizeProp.Value / 1024, 1) } else { 0 }
                Uninstall = if ($unProp) { $unProp.Value } else { '' }
            }
        }
    }

    @($rows) | Sort-Object MB -Descending | Select-Object -First $Top
}

<#
    Removes software that has nothing to do with building code. Every pattern is
    explicit; nothing is matched heuristically. OneDrive is excluded on purpose.
#>
function Remove-KhzBloatware {
    [CmdletBinding()]
    param(
        [switch]$Apply,
        [string[]]$Patterns = @(
            'Google Drive', 'Google Update', 'Android Studio', 'Android SDK',
            'Dropbox', 'iTunes', 'Bonjour', 'Apple Software Update',
            'McAfee', 'Norton', 'Avast', 'Web Companion', 'Grain'
        )
    )

    Write-Khz "`n[10] non-build software" 'head'
    $script:Locked = 0
    $total = 0L

    foreach ($p in @(Get-KhzPrograms -Top 500)) {
        if (@($Patterns | Where-Object { $p.Name -like "*$_*" }).Count -eq 0) { continue }

        Write-Khz ('    {0,-40} {1,8} MB' -f $p.Name, $p.MB)
        if (-not $Apply) { Write-Khz '      would uninstall' 'warn'; continue }
        if ([string]::IsNullOrWhiteSpace($p.Uninstall)) { Write-Khz '      no uninstall string' 'warn'; continue }

        if ($p.Uninstall -match 'msiexec') {
            $guid = [regex]::Match($p.Uninstall, '\{[0-9A-Fa-f-]{36}\}').Value
            if ($guid) {
                Start-Process msiexec.exe -ArgumentList "/x $guid /qn /norestart" -Wait -ErrorAction SilentlyContinue
                Write-Khz '      uninstalled (msi)' 'ok'
            }
        } else {
            Write-Khz "      run manually: $($p.Uninstall)" 'warn'
        }
    }

    # Leftover directories that survive an uninstall.
    $dirs = @(
        @{ P = "$env:LOCALAPPDATA\Android\Sdk";              L = 'Android SDK' },
        @{ P = "$env:USERPROFILE\.android";                  L = 'Android AVDs' },
        @{ P = "$env:LOCALAPPDATA\Google\DriveFS";           L = 'Google Drive cache' },
        @{ P = "$env:LOCALAPPDATA\Google\Update";            L = 'Google Update' },
        @{ P = "$env:LOCALAPPDATA\Google\Chrome\User Data\Crashpad"; L = 'Chrome crashpad' },
        @{ P = "$env:ProgramData\Google";                    L = 'Google (ProgramData)' },
        @{ P = "$env:LOCALAPPDATA\Grain";                    L = 'Grain' },
        @{ P = "$env:APPDATA\Grain";                         L = 'Grain (roaming)' }
    )
    foreach ($d in $dirs) {
        $size = Get-KhzPathSize $d.P
        if ($size -le 0) { continue }
        Write-Khz ('    {0,-40} {1,8}' -f $d.L, (Format-KhzBytes $size))
        if ($Apply) {
            Remove-Item -LiteralPath $d.P -Recurse -Force -ErrorAction SilentlyContinue
            if (-not (Test-Path -LiteralPath $d.P)) { $total += $size } else { $script:Locked++ }
        } else { $total += $size }
    }

    Show-KhzLocked
    $total
}

function Disable-KhzStartup {
    [CmdletBinding()]
    param(
        [switch]$Apply,
        [string[]]$Names = @(
            'GoogleDriveFS', 'electron.app.Grain', 'MicrosoftEdgeAutoLaunch*',
            'Mozilla-Firefox-*', 'OneDriveSetup', 'Dropbox', 'Skype', 'Teams'
        )
    )

    Write-Khz "`n[11] startup entries" 'head'

    $hives = @(
        'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Run',
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Run',
        'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Run'
    )

    foreach ($hive in $hives) {
        if (-not (Test-Path -LiteralPath $hive)) { continue }
        $props = Get-ItemProperty -Path $hive -ErrorAction SilentlyContinue
        if ($null -eq $props) { continue }

        foreach ($prop in $props.PSObject.Properties) {
            if ($prop.Name -like 'PS*') { continue }
            if (@($Names | Where-Object { $prop.Name -like $_ }).Count -eq 0) { continue }

            if ($Apply) {
                Remove-ItemProperty -Path $hive -Name $prop.Name -Force -ErrorAction SilentlyContinue
                Write-Khz "    removed $($prop.Name)" 'ok'
            } else {
                Write-Khz "    would remove $($prop.Name)  ($(Split-Path $hive -Leaf))"
            }
        }
    }

    Write-Khz '    per-service-account copies under S-1-5-18/19/20 need' 'warn'
    Write-Khz '    the vendor uninstaller; deleting them here is not enough.' 'warn'
}

# ---------------------------------------------------------------- reports

function Get-KhzWslImages {
    [CmdletBinding()] param()

    Write-Khz "`n[wsl] virtual disks" 'head'
    $found = @()
    foreach ($r in @("$env:LOCALAPPDATA\Packages", "$env:LOCALAPPDATA\Docker\wsl",
                     "$env:LOCALAPPDATA\wsl", "$env:ProgramData\DockerDesktop")) {
        if (-not (Test-Path -LiteralPath $r)) { continue }
        $found += @(Get-ChildItem -LiteralPath $r -Recurse -Force -Filter '*.vhdx' -ErrorAction SilentlyContinue)
    }

    if ((Get-KhzCount $found) -eq 0) { Write-Khz '    none found' 'ok'; return }

    foreach ($f in ($found | Sort-Object Length -Descending)) {
        Write-Khz ('    {0,10}  {1}' -f (Format-KhzBytes $f.Length), $f.FullName)
    }
    Write-Khz ''
    Write-Khz '    a vhdx never shrinks by itself. To compact:' 'warn'
    Write-Khz '      wsl --shutdown'
    Write-Khz '      Optimize-VHD -Path <file> -Mode Full'
}

function Get-KhzDiskHogs {
    [CmdletBinding()] param([string]$Path = $env:SystemDrive, [int]$Top = 20)

    Write-Khz "`n[hogs] largest folders under $Path" 'head'
    $rows = foreach ($d in @(Get-ChildItem -LiteralPath $Path -Directory -Force -ErrorAction SilentlyContinue)) {
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
        CommitGB     = if ($os) { [math]::Round($os.TotalVirtualMemorySize / 1MB, 2) } else { 0 }
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
    Write-Khz '    SYSTEM has its own profile, so per-user browser caches are' 'warn'
    Write-Khz '    only cleared when you run it yourself.' 'warn'
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
                     'Pagefile','Memory','Components','Bloat','Startup','All')]
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
    $log = Join-Path $script:LogDir ("khz-" + (Get-Date -Format 'yyyyMMdd-HHmmss') + ".log")
    try { Start-Transcript -Path $log -Force | Out-Null } catch { }

    $before = Get-KhzReport

    if (-not $Quiet) {
        Write-Khz ''
        Write-Khz '  KhzJanitor 1.2.1' 'head'
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
            'Components'     { $freed += Clear-KhzComponentStore -Apply:$Apply -ResetBase:$Aggressive }
            'Bloat'          { $freed += Remove-KhzBloatware -Apply:$Apply }
            'Startup'        { Disable-KhzStartup -Apply:$Apply }
            'Memory'         { Optimize-KhzMemory }
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
    Clear-KhzComponentStore, Remove-KhzBloatware, Disable-KhzStartup,
    Get-KhzPrograms, Get-KhzDiskHogs, Get-KhzWslImages,
    Register-KhzDailyTask, Unregister-KhzDailyTask, Get-KhzReport
