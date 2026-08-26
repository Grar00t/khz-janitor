#requires -Version 5.1
<#
    One-liner install:

    irm https://raw.githubusercontent.com/Grar00t/khz-janitor/main/install.ps1 | iex

    Installs the module for the current user, then runs a DRY RUN. Nothing is
    deleted until you call Invoke-KhzJanitor -Apply yourself.
#>

$ErrorActionPreference = 'Stop'

$dest = Join-Path ([Environment]::GetFolderPath('MyDocuments')) 'WindowsPowerShell\Modules\KhzJanitor'
if ($PSVersionTable.PSEdition -eq 'Core') {
    $dest = Join-Path ([Environment]::GetFolderPath('MyDocuments')) 'PowerShell\Modules\KhzJanitor'
}

New-Item -ItemType Directory -Path $dest -Force | Out-Null
$base = 'https://raw.githubusercontent.com/Grar00t/khz-janitor/main/KhzJanitor'

foreach ($file in @('KhzJanitor.psm1', 'KhzJanitor.psd1')) {
    Write-Host "downloading $file" -ForegroundColor Cyan
    Invoke-WebRequest -Uri "$base/$file" -OutFile (Join-Path $dest $file) -UseBasicParsing
}

Import-Module KhzJanitor -Force

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
