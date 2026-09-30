# KhzJanitor

A PowerShell module that reclaims a Windows machine choking on logs, caches,
browser extensions, telemetry services and multi-gigabyte cloud SDK modules.

Written because a build box kept failing with
`The paging file is too small for this operation to complete` while several
gigabytes of `Microsoft.Graph.*` sub-modules sat unused on disk.

## Safety contract

**Nothing is deleted unless you pass `-Apply`.** The default run only measures
and prints what it would remove.

- Fixed system/cache cleanup roots are explicit literal paths.
- Development-artifact cleanup is the deliberate exception: it recursively enumerates only `~/dev` and `~/source`, then removes directories whose **exact directory name** is one of `bin`, `obj`, `TestResults`, `node_modules`, `target`, `__pycache__`, or `.pytest_cache`.
- It does not perform an unrestricted recursive wildcard deletion from the user profile or an arbitrary caller-supplied root.
- `Clear-KhzDirectory` removes the contents of a supplied folder, never the folder itself.
- Files locked by a running process are skipped silently. That is expected.
- Every run writes a transcript to `%ProgramData%\KhzJanitor\logs` and appends a row to `ledger.csv`.

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
| **Logs** | Clears configured Windows/application log and dump locations. `-Aggressive` also clears Windows event logs. |
| **Caches** | Clears configured browser/application caches. It also scans only `~/dev` and `~/source` for the exact build/cache directory names documented in the safety contract. `-Aggressive` adds NuGet, npm, pip and yarn caches. |
| **EdgeExtensions** | Lists extension IDs per profile, then removes extension state. `-Aggressive` can set `ExtensionInstallBlocklist = *`. |
| **Copilot** | Applies the documented Windows/Edge policies and removes the listed optional app packages. |
| **Modules** | Removes selected `Microsoft.Graph.*` / `Az.*` modules while retaining the protected module set documented by the implementation. `-OldVersionsOnly` keeps the newest of each. |
| **Telemetry** | Applies the module's documented service/task/policy changes. |
| **Pagefile** | Diagnoses virtual-memory exhaustion and can re-enable automatic pagefile management. Requires a reboot for resulting system changes to take effect. |

## Recommended first run

```powershell
Invoke-KhzJanitor                                   # look at the numbers
Invoke-KhzJanitor -Tasks Pagefile -Apply            # fix virtual memory, then reboot
Invoke-KhzJanitor -Tasks Logs,Caches,Modules -Apply # the three biggest wins
Register-KhzDailyTask -Apply                        # keep it that way
```

The daily task runs `Logs`, `Caches` and `EdgeExtensions` only; it does not run
the policy or module tasks.

## Uninstall

```powershell
Unregister-KhzDailyTask
Remove-Item (Get-Module KhzJanitor -ListAvailable).ModuleBase -Recurse -Force
```

Policies written by the `Copilot` and `Telemetry` tasks persist by design.
Delete the corresponding keys under `HKLM:\SOFTWARE\Policies\Microsoft\` to
revert those policy changes.

## Verification boundary

The dry-run contract is observable from the implementation: destructive calls are gated by `-Apply`. The README does not claim rollback of every system policy or event-log deletion. Review the dry-run output before applying changes.

## License

MIT.
