#requires -Version 5.1
<#
    One-liner install:

    irm https://raw.githubusercontent.com/Grar00t/khz-janitor/main/install.ps1 | iex

    Installs the module for the current user, then runs a DRY RUN. Nothing is
    deleted until you call Invoke-KhzJanitor -Apply yourself.
#>

$ErrorActionPreference = 'Stop'

function Get-KhzModuleRoot {
    # GetFolderPath('MyDocuments') returns an empty string when Documents is
    # redirected to OneDrive or the known-folder registration is damaged.
    # Never trust it on its own.
    $docs = $null
    try { $docs = [Environment]::GetFolderPath('MyDocuments') } catch { }

    if ([string]::IsNullOrWhiteSpace($docs)) {
        $docs = Join-Path $HOME 'Documents'
        Write-Host 'MyDocuments was empty - falling back to $HOME\Documents' -ForegroundColor Yellow
    }

    # Refuse a synced folder: a module living in OneDrive gets uploaded,
    # locked mid-import, and re-downloaded on every machine.
    if ($docs -like '*OneDrive*') {
        $local = Join-Path $HOME 'Documents'
        if (Test-Path -LiteralPath $local) {
            Write-Host 'Documents is OneDrive-redirected - installing to the local path instead' -ForegroundColor Yellow
            $docs = $local
        } else {
            $docs = Join-Path $env:LOCALAPPDATA 'KhzJanitorHome'
            Write-Host "Documents is OneDrive-redirected - installing to $docs" -ForegroundColor Yellow
        }
    }

    if (-not (Test-Path -LiteralPath $docs)) {
        New-Item -ItemType Directory -Path $docs -Force | Out-Null
    }

    $edge = if ($PSVersionTable.PSEdition -eq 'Core') { 'PowerShell' } else { 'WindowsPowerShell' }
    Join-Path $docs (Join-Path $edge 'Modules')
}

$modules = Get-KhzModuleRoot
$dest    = Join-Path $modules 'KhzJanitor'

New-Item -ItemType Directory -Path $dest -Force | Out-Null

$base = 'https://raw.githubusercontent.com/Grar00t/khz-janitor/main/KhzJanitor'

try { [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 } catch { }

foreach ($file in @('KhzJanitor.psm1', 'KhzJanitor.psd1')) {
    Write-Host "downloading $file" -ForegroundColor Cyan
    Invoke-WebRequest -Uri "$base/$file" -OutFile (Join-Path $dest $file) -UseBasicParsing
}

# Make sure this session can see it even if the folder is not on PSModulePath.
if ($env:PSModulePath -notlike "*$modules*") {
    $env:PSModulePath = "$modules;$env:PSModulePath"
}

Import-Module (Join-Path $dest 'KhzJanitor.psd1') -Force

Write-Host ''
Write-Host "installed to $dest" -ForegroundColor Green
Write-Host 'running a dry run now - nothing will be deleted' -ForegroundColor Yellow
Write-Host ''

Invoke-KhzJanitor

Write-Host ''
Write-Host 'next steps:' -ForegroundColor Cyan
Write-Host '  Invoke-KhzJanitor -Apply                 # actually clean'
Write-Host '  Invoke-KhzJanitor -Apply -Aggressive     # + event logs, package caches, extension blocklist'
Write-Host '  Register-KhzDailyTask -Apply             # run daily at 03:30 (admin)'
Write-Host ''
Write-Host 'if a new session cannot find the module, import it by path:' -ForegroundColor DarkGray
Write-Host "  Import-Module '$dest\KhzJanitor.psd1' -Force" -ForegroundColor DarkGray
