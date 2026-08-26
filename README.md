# KhzJanitor

A PowerShell module that reclaims a Windows machine choking on logs, caches,
browser extensions, telemetry services and multi-gigabyte cloud SDK modules.

Written because a build box kept failing with
`The paging file is too small for this operation to complete` while several
gigabytes of `Microsoft.Graph.*` sub-modules sat unused on disk.

## Safety contract

**Nothing is deleted unless you pass `-Apply`.** The default run only measures
and prints what it would remove.

* Every destructive path is a whitelisted literal. There is no recursive
  wildcard deletion of user directories anywhere in the module.
* `Clear-KhzDirectory` removes the *contents* of a folder, never the folder.
* Files locked by a running process are skipped silently. That is expected.
* Every run writes a transcript to `%ProgramData%\KhzJanitor\logs` and appends
  a row to `ledger.csv` so you can prove what happened.

## Install

```powershell
irm https://raw.githubusercontent.com/Grar00t/khz-janitor/main/install.ps1 | iex
```

Or clone and import directly:

```powershell
git clone https://github.com/Grar00t/khz-janitor.git
Import-Module .\khz-janitor\KhzJanitor\KhzJanitor.psd1 -Force
```

## Use

```powershell
Invoke-KhzJanitor                                  # dry run, safe, no admin needed
Invoke-KhzJanitor -Apply                           # clean
Invoke-KhzJanitor -Apply -Aggressive               # + event logs, package caches, extension blocklist
Invoke-KhzJanitor -Tasks Modules,Caches -Apply     # only what you name
Register-KhzDailyTask -Apply                       # daily at 03:30 as SYSTEM (admin)
Get-KhzReport                                      # current disk / RAM / module counts
```

Run elevated for tasks 4, 6 and 7. The rest work as a normal user.

## What each task does

| Task | Action |
|------|--------|
| **Logs** | `Windows\Logs`, `Windows\Temp`, `Panther`, WU downloads, WER queue and archive, crash dumps, `MEMORY.DMP`, `Minidump`, NVIDIA shader caches. `-Aggressive` also clears every Windows event log. |
| **Caches** | Edge / Chrome / Brave cache, code cache, GPU and shader caches, service-worker storage, across every profile. Thumbnail cache, INetCache, RDP cache, Office cache, VS Code cached data. Then every `bin`, `obj`, `TestResults`, `node_modules`, `target` under `~\dev` - usually the single biggest win on a build machine. `-Aggressive` adds NuGet, npm, pip and yarn caches. |
| **EdgeExtensions** | Lists every extension ID per profile, then wipes `Extensions`, `Local Extension Settings`, `Extension State`, `Extension Rules`. Kills `msedge` first so files are not locked. `-Aggressive` sets the `ExtensionInstallBlocklist = *` policy so nothing installs again. |
| **Copilot** | Policies: `TurnOffWindowsCopilot`, `DisableAIDataAnalysis`, `HubsSidebarEnabled=0`, `StartupBoostEnabled=0`, `BackgroundModeEnabled=0`, shopping assistant off, `ShowCopilotButton=0`, and the ContentDeliveryManager suggestion keys. Then removes the Copilot, Xbox overlay, OneDrive, Zune, Quick Assist and Teams app packages. |
| **Modules** | The big one. `Microsoft.Graph.*` ships around 40 sub-modules and `Az.*` around 80; together they routinely exceed 4 GB and slow every PowerShell start through command auto-discovery. Removes them, keeping only `Microsoft.Graph.Authentication` and `Az.Accounts` by default. Use `-OldVersionsOnly` to keep the newest of each. `Microsoft.PowerShell.*`, `PSReadLine`, `PowerShellGet`, `PackageManagement` and `Pester` are hard-protected. |
| **Telemetry** | Disables `DiagTrack`, `dmwappushservice`, `WerSvc`, `MapsBroker`, `RetailDemo`, the Compatibility Appraiser, CEIP Consolidator, `UsbCeip`, disk diagnostic collector, feedback `DmClient`, `QueueReporting`, and sets `AllowTelemetry=0`. |
| **Pagefile** | Diagnoses `The paging file is too small` and `Insufficient system resources`. Both are virtual-memory exhaustion, not disk shortage. Reports RAM, current pagefile size and peak usage; re-enables the automatic pagefile if it was switched off. Requires a reboot. |

## Recommended first run

```powershell
Invoke-KhzJanitor                                   # look at the numbers
Invoke-KhzJanitor -Tasks Pagefile -Apply            # fix virtual memory, then reboot
Invoke-KhzJanitor -Tasks Logs,Caches,Modules -Apply # the three biggest wins
Register-KhzDailyTask -Apply                        # keep it that way
```

The daily task runs `Logs`, `Caches` and `EdgeExtensions` only - never the
policy or module changes, so a scheduled run can never surprise you.

## Uninstall

```powershell
Unregister-KhzDailyTask
Remove-Item (Get-Module KhzJanitor -ListAvailable).ModuleBase -Recurse -Force
```

Policies written by the `Copilot` and `Telemetry` tasks persist by design.
Delete the corresponding keys under
`HKLM:\SOFTWARE\Policies\Microsoft\` to revert them.

## License

MIT.
