$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$manifest = Join-Path $PSScriptRoot '..\KhzJanitor\KhzJanitor.psd1'
Import-Module $manifest -Force
$module = Get-Module KhzJanitor -ErrorAction Stop

function Assert-Khz {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) { throw "ASSERTION FAILED: $Message" }
}

$root = Join-Path $env:TEMP ("khz-janitor-test-" + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $root -Force | Out-Null

try {
    $target = Join-Path $root 'delete-me'
    New-Item -ItemType Directory -Path $target -Force | Out-Null
    [IO.File]::WriteAllBytes((Join-Path $target 'payload.bin'), (New-Object byte[] 4096))

    $dry = & $module { param($Path) Remove-KhzPathMeasured -Path $Path } $target
    Assert-Khz (Test-Path -LiteralPath $target) 'dry-run removed the target'
    Assert-Khz ($dry.Bytes -eq 4096) 'dry-run did not report the candidate bytes'
    Assert-Khz (-not $dry.Removed) 'dry-run reported a removal'

    $applied = & $module { param($Path) Remove-KhzPathMeasured -Path $Path -Apply } $target
    Assert-Khz (-not (Test-Path -LiteralPath $target)) 'apply left the target behind'
    Assert-Khz ($applied.Removed) 'apply did not confirm removal'
    Assert-Khz ($applied.Bytes -eq 4096) 'apply did not report verified reclaimed bytes'

    $dev = Join-Path $root 'dev'
    $outer = Join-Path $dev 'project\node_modules'
    $inner = Join-Path $outer 'package\node_modules'
    New-Item -ItemType Directory -Path $inner -Force | Out-Null

    $topmost = @(& $module {
        param($Root)
        $dirs = @(Get-ChildItem -LiteralPath $Root -Directory -Recurse -Force |
                  Where-Object { $_.Name -eq 'node_modules' })
        @(Get-KhzTopmostDirectories -Directories $dirs)
    } $dev)

    Assert-Khz ($topmost.Count -eq 1) 'nested build artifacts were not deduplicated'
    Assert-Khz ($topmost[0].FullName -eq (Get-Item -LiteralPath $outer).FullName) 'wrong topmost build artifact selected'

    Write-Host 'KhzJanitor smoke tests passed.'
}
finally {
    Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
}
