# KhzJanitor

A PowerShell module that reclaims a Windows machine choking on logs, caches,
browser extensions, telemetry services and multi-gigabyte cloud SDK modules.

Written because a build box kept failing with
`The paging file is too small for this operation to complete` while several
gigabytes of `Microsoft.Graph.*` sub-modules sat unused on disk.

## Safety contract

**Cleanup operations reached through `Invoke-KhzJanitor` do not delete or mutate targets unless you pass `-Apply`.** The default `Invoke-KhzJanitor` run measures and prints what those cleanup tasks would change. This is not a module-wide guarantee: other exported commands have their own semantics; for example, `Unregister-KhzDailyTask` unregisters the scheduled task directly.

- Fixed system/cache cleanup roots are explicit literal paths.
- Development-artifact cleanup is the deliberate exception: it recursively enumerates only `~/dev` and `~/source`, then removes directories whose **exact directory name** is one of `bin`, `obj`, `TestResults`, `node_modules`, `target`, `__pycache__`, or `.pytest_cache`.
- It does not perform an unrestricted recursive wildcard deletion from the user profile or an arbitrary caller-supplied root.
- `Clear-KhzDirectory` removes the contents of a supplied folder, never the folder itself.
- Files locked by a running process are skipped silently. That is expected.
- `Invoke-KhzJanitor` writes a transcript to `%ProgramData%\KhzJanitor\logs` and appends a row to `ledger.csv`.

The development-artifact rule is destructive when `-Apply` is present: do not use it if build outputs under `~/dev` or `~/source` must be preserved.

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
Invoke-KhzJanitor                                  # dry run for Invoke-KhzJanitor cleanup tasks
Invoke-KhzJanitor -Apply                           # apply selected/default cleanup tasks
Invoke-KhzJanitor -Apply -Aggressive               # adds destructive targets documented below
Invoke-KhzJanitor -Tasks Modules,Caches -Apply     # only what you name
Register-KhzDailyTask -Apply                       # daily at 03:30 as SYSTEM (admin)
Get-KhzReport                                      # current disk / RAM / module counts
```

Run elevated for tasks 4, 6 and 7. The rest work as a normal user.

## What each task does

### Logs

`Logs -Apply` can clear contents from the configured Windows/application log and dump locations **and** non-log cleanup roots that are intentionally grouped into this task: Windows/User temp, Setup/Panther, Windows Update downloads and update-store data, WER queue/archive/temp, WebCache, crash dumps, D3D/NVIDIA/AMD shader caches, JetBrains logs, IIS/Perf/System log roots, and memory/minidump paths. Existing `KeepDays` rules apply where the implementation assigns them.

With `-Aggressive`, the task also clears Windows Event Logs via `wevtutil`.

### Caches

`Caches -Apply` clears configured browser/application caches, including Chromium profile caches, Firefox cache roots, thumbnail/INet/RDP/Office caches, VS/JetBrains/VS Code caches, Notion cache roots, dotnet template/optimization data, delivery-optimization data, Docker logs, and Google Drive logs.

It also recursively scans only `~/dev` and `~/source` for directories named exactly:

```text
bin  obj  TestResults  node_modules  target  __pycache__  .pytest_cache
```

With `-Aggressive`, package/SDK cleanup additionally clears:

```text
~/.nuget/packages
%LOCALAPPDATA%\NuGet\v3-cache
npm caches
pip cache
yarn cache
~/.cargo/registry
~/.gradle/caches
%LOCALAPPDATA%\Android\Sdk\system-images
```

### EdgeExtensions

`EdgeExtensions -Apply` stops Edge/WebView2 processes when present and clears these directories for each detected Edge profile:

```text
Extensions
Local Extension Settings
Extension State
Extension Rules
```

Clearing `Extensions` removes installed extension package files, not merely cached settings. With `-Aggressive`, the task can also set Edge `ExtensionInstallBlocklist` entry `1` to `*`, blocking future extension installation under that policy.

### Copilot

`Copilot -Apply` writes the implementation's Windows/Edge policy values and HKCU values, including Windows Copilot/WindowsAI controls, Edge sidebar/shopping/startup/background/ads/page-context controls, `ShowCopilotButton`, and ContentDeliveryManager values.

It also attempts to remove installed AppX packages matching these implementation patterns:

```text
*Copilot*
*BingSearch*
*XboxGamingOverlay*
*XboxGameOverlay*
*XboxSpeechToTextOverlay*
*GamingApp*
*ZuneMusic*
*ZuneVideo*
*QuickAssist*
*MicrosoftStickyNotes*
*Clipchamp*
*WindowsFeedbackHub*
*GetHelp*
*MicrosoftSolitaireCollection*
*BingWeather*
*BingNews*
*People*
*windowscommunicationsapps*
```

OneDrive is deliberately not in that removal list.

### Modules

`Modules -Apply` removes selected installed PowerShell module folders matching Microsoft Graph/Azure/legacy-cloud module families while preserving the implementation's protected modules and explicit `-Keep` list. `-OldVersionsOnly` keeps the newest discovered version of each matched module.

### Telemetry

`Telemetry -Apply` persistently stops/disables these services when present:

```text
DiagTrack
dmwappushservice
WerSvc
MapsBroker
RetailDemo
PcaSvc
```

It also disables these scheduled tasks when present:

```text
\Microsoft\Windows\Application Experience\Microsoft Compatibility Appraiser
\Microsoft\Windows\Application Experience\ProgramDataUpdater
\Microsoft\Windows\Application Experience\StartupAppTask
\Microsoft\Windows\Customer Experience Improvement Program\Consolidator
\Microsoft\Windows\Customer Experience Improvement Program\UsbCeip
\Microsoft\Windows\DiskDiagnostic\Microsoft-Windows-DiskDiagnosticDataCollector
\Microsoft\Windows\Feedback\Siuf\DmClient
\Microsoft\Windows\Feedback\Siuf\DmClientOnScenarioDownload
\Microsoft\Windows\Windows Error Reporting\QueueReporting
\Microsoft\Windows\Autochk\Proxy
```

Finally it writes `HKLM:\SOFTWARE\Policies\Microsoft\Windows\DataCollection\AllowTelemetry = 0`.

### Pagefile

`Pagefile` diagnoses virtual-memory exhaustion and can re-enable automatic pagefile management. Resulting system changes require a reboot before they are fully reflected by the running OS.

## Recommended first run

```powershell
Invoke-KhzJanitor                                   # inspect the dry-run output
Invoke-KhzJanitor -Tasks Pagefile -Apply            # fix virtual memory, then reboot
Invoke-KhzJanitor -Tasks Logs,Caches,Modules -Apply # apply only after reviewing targets above
Register-KhzDailyTask -Apply                        # keep it that way
```

The daily task runs `Logs`, `Caches` and `EdgeExtensions` only; it does not run the policy or module tasks.

## Uninstall

```powershell
Unregister-KhzDailyTask
Remove-Item (Get-Module KhzJanitor -ListAvailable).ModuleBase -Recurse -Force
```

`Unregister-KhzDailyTask` performs the unregister action directly; it is not an `Invoke-KhzJanitor` dry-run operation.

Policies, disabled services/tasks, AppX removals, and registry values written by applied tasks can persist after the module itself is removed. This README does **not** prescribe deleting whole parent registry keys: those keys can contain unrelated Windows settings. To revert a registry change, remove or restore only the individual values identified by the implementation/transcript. Service/task/AppX restoration must be handled separately from registry cleanup.

## Verification boundary

The dry-run statement above applies specifically to cleanup mutations selected and dispatched by `Invoke-KhzJanitor`: those task calls receive `-Apply:$Apply`, and their destructive paths/policy writes are implemented with that gate. It does **not** apply to every exported helper command and does not imply automatic rollback of event-log deletion, removed extension/AppX files, package caches, service/task state, or registry policy changes.

Review the dry-run target list before applying any cleanup.

## License

MIT.
