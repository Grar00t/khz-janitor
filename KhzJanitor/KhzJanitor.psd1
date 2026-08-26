@{
    RootModule        = 'KhzJanitor.psm1'
    ModuleVersion     = '1.0.0'
    GUID              = '7b3f9c21-4d8a-4c17-9e6b-1a2f5d8c3e40'
    Author            = 'Suliman Alshammari'
    CompanyName       = 'GraTech'
    Copyright         = '(c) 2026 Suliman Alshammari. MIT License.'
    Description       = 'Reclaims disk and memory on bloated Windows machines. Dry-run by default.'
    PowerShellVersion = '5.1'
    FunctionsToExport = @(
        'Invoke-KhzJanitor',
        'Clear-KhzLogs',
        'Clear-KhzCaches',
        'Remove-KhzEdgeExtensions',
        'Disable-KhzCopilot',
        'Remove-KhzStaleModules',
        'Disable-KhzTelemetry',
        'Repair-KhzPagefile',
        'Register-KhzDailyTask',
        'Unregister-KhzDailyTask',
        'Get-KhzReport'
    )
    CmdletsToExport   = @()
    VariablesToExport = @()
    AliasesToExport   = @()
    PrivateData       = @{ PSData = @{
        Tags       = @('Windows','Cleanup','Debloat','Maintenance','Privacy')
        LicenseUri = 'https://github.com/Grar00t/khz-janitor/blob/main/LICENSE'
        ProjectUri = 'https://github.com/Grar00t/khz-janitor'
    } }
}
