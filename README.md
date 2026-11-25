# win-disk-optimizer

[![CI](https://github.com/manikbaunthiyal/win-disk-optimizer/actions/workflows/ci.yml/badge.svg)](https://github.com/manikbaunthiyal/win-disk-optimizer/actions/workflows/ci.yml)
![Platform](https://img.shields.io/badge/platform-Windows%2010%20%7C%2011-0078D6)
![PowerShell](https://img.shields.io/badge/PowerShell-5.1%2B%20%7C%207%2B-5391FE)
![License](https://img.shields.io/badge/license-MIT-green)

Self-contained, rule-based Windows `C:` disk analyzer, cleaner, and cache relocator. **Runs completely standalone on any Windows 10/11 machine with zero AI, zero cloud APIs, and zero external dependencies.**

A built-in deterministic rule engine ([DiskOptimizer.Rules.psm1](src/DiskOptimizer.Rules.psm1)) inspects your system and automatically classifies every finding into clear, explainable categories:

| Classification | Meaning | Default Action |
|---|---|---|
| **`NotNeeded` (Safe Delete)** | Temp files (>60 min), crash dumps, reproducible package/IDE/browser HTTP caches, unused updaters | Delete safely (auto in `AutoSafe`, prompted in `Interactive`) |
| **`NotNeeded` (Admin)** | Orphaned `.msi`/`.msp` packages in `C:\Windows\Installer`, `Windows Update` download cache | Elevated cleanup via `Invoke-AdminCleanup.ps1` |
| **`NeededMoveOffC`** | Valuable dev/AI caches (`.gradle`, `.cache\huggingface`, `.cache\whisper`, `uv`, `Pub`, `.cargo`, `.ollama`) | Move to secondary drive (`D:\Caches`, auto-detected) + set env vars + NTFS junctions |
| **`OptionalReview`** | Large media/replay/preview caches, duplicate root tools (`C:\ffmpeg*`), old `.exe`/`.msi` installers in `Downloads` (>30 days), `hiberfil.sys` | Prompted individually in `Interactive` mode; never touched automatically |
| **`NeededKeep` (Protected)** | Personal libraries (`Documents`, `Desktop`, `Pictures`, `Videos`, `OneDrive`), browser logins/cookies/bookmarks, active `Windows\Installer` packages, already-junctioned caches | Strictly protected |

---

## Quick Start (Zero Setup)

> **Double-click option:** Run [Run-Optimizer.bat](Run-Optimizer.bat) from Windows Explorer to launch the guided interactive optimizer immediately.

### 1. Generate a Full Decision Report (Read-Only)

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\Optimize-Disk.ps1 -Mode Report
```

Export the report to Markdown or JSON:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\Optimize-Disk.ps1 -Mode Report -ExportMarkdown .\disk-report.md
```

### 2. Guided Interactive Optimization (Recommended)

Walks you through safe deletions, relocating dev/AI caches to your largest secondary drive (e.g. `D:\Caches`), reviewing optional items, and optionally launching Administrator cleanup via UAC:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\Optimize-Disk.ps1 -Mode Interactive
```

### 3. Unattended Safe Cleanup (`AutoSafe`)

Ideal for regular maintenance or Windows Task Scheduler. Cleans only high-confidence `NotNeeded` items when their apps aren't running (never deletes `OptionalReview` or protected data):

```powershell
# Preview first
powershell -NoProfile -ExecutionPolicy Bypass -File .\Optimize-Disk.ps1 -Mode AutoSafe -WhatIf

# Run unattended safe cleanup (and automatically relocate heavy caches to best non-C: drive)
powershell -NoProfile -ExecutionPolicy Bypass -File .\Optimize-Disk.ps1 -Mode AutoSafe -AutoRelocate -EmptyRecycleBin
```

To schedule weekly automatic safe cleanup via Windows Task Scheduler:

```powershell
$action = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument '-NoProfile -ExecutionPolicy Bypass -File "D:\AI\win-disk-optimizer\Optimize-Disk.ps1" -Mode AutoSafe -IncludeInstallerAudit:$false'
$trigger = New-ScheduledTaskTrigger -Weekly -DaysOfWeek Sunday -At 11am
Register-ScheduledTask -TaskName 'WinDiskOptimizer-Weekly' -Action $action -Trigger $trigger -Description 'Safe weekly C: cache cleanup'
```

---

## Individual Scripts (Modular Usage)

- **[scripts/Analyze-DiskSpace.ps1](scripts/Analyze-DiskSpace.ps1)** — Raw folder size breakdown and orphaned `Windows\Installer` inspection (`-Quick`, `-IncludeInstallerAudit`, `-AsJson`).
- **[scripts/Invoke-UserCleanup.ps1](scripts/Invoke-UserCleanup.ps1)** — Category-targeted user cache cleaner (`-Categories Temp,CrashDumps,DevCaches,IdeCaches,BrowserCaches,LauncherCaches,UpdaterCaches,All`, `-WhatIf`).
- **[scripts/Move-CacheToDrive.ps1](scripts/Move-CacheToDrive.ps1)** — Relocate specific caches (`-DestinationRoot D:\Caches -Keys gradle,huggingface,whisper,uv`) with verified `robocopy`, User env vars, NTFS junctions, and `-Restore` rollback.
- **[scripts/Invoke-AdminCleanup.ps1](scripts/Invoke-AdminCleanup.ps1)** — Administrator cleanup for orphaned `C:\Windows\Installer` packages (with optional `-BackupDir`), `DISM` `WinSxS` cleanup, Windows Update / Delivery Optimization / WER caches, and optional `-HibernationMode Reduced|Off`.

## Running Tests

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\tests\Test-DiskOptimizer.ps1
```

## Safety Guarantees

- **Hard path protection (`Test-IsProtectedPath`)**: Refuses to delete `Windows\System32`, `WinSxS`, `Documents`, `Desktop`, `Pictures`, `Music`, `Videos`, `Downloads`, `OneDrive` roots, or browser profile roots.
- **No login/session loss**: Browser and launcher rules target only `Cache`, `Code Cache`, `GPUCache`, `DawnCache`, and `GrShaderCache` across all discovered profiles—never `Cookies` or `Login Data`.
- **Dynamic permission & state awareness**: Checks effective ACL permissions (`Test-PathWritable`), active `PATH` binaries (for duplicate tool detection), active environment variables (for stale cache detection), and Windows Installer COM + Registry before classifying an item.
- **Verified relocations**: Uses `robocopy` and verifies file counts and byte sums before removing the original folder and creating an NTFS junction.

## Example Output (`-Mode Report`)

```text
=== 1. NOT NEEDED - SAFE TO DELETE (USER) (7 items, 0.66 GB) ===
Brave Browser (Default) Code Cache  BrowserCache  302.8 MB  High  Reproducible browser HTTP/shader cache...
Cached Updater (updater)            Updater        56.2 MB  Medium Cached updater installer.exe...

=== 2. NOT NEEDED - ADMIN CLEANUP REQUIRED (1 items, 15.39 GB) ===
Orphaned Windows Installer Patches  OrphanedInstaller  15.39 GB  High  Orphaned .msi/.msp packages not referenced by Windows Installer COM or Registry

=== 4. OPTIONAL REVIEW - USER DECISION RECOMMENDED (5 items, 8.18 GB) ===
Windows Hibernation File            SystemOptimization  5.54 GB  High    Hibernation/Fast Startup reserve...

=== 5. NEEDED - PROTECTED / ALREADY OPTIMIZED (8 items, 0.00 GB) ===
Personal Documents Folder           Protected           0.00 GB  High    Protected personal user library; never auto-deleted.
Hugging Face AI Models              RelocatableCache    0.00 GB  High    Already relocated via NTFS junction to D:\AI\huggingface-cache

Summary -> Safe User Delete: 677.3 MB | Admin Cleanup: 15.39 GB | Relocate Off C: 0.00 GB
```

## Contributing & Security

- Contributions are welcome! Read [CONTRIBUTING.md](CONTRIBUTING.md) before opening a pull request or proposing a new cache rule.
- Please review [SECURITY.md](SECURITY.md) for safety guarantees and vulnerability reporting.

## Requirements

- Windows 10 or Windows 11
- Windows PowerShell 5.1+ or PowerShell 7+
- Administrator rights only for `Invoke-AdminCleanup.ps1` (all other modes run as a standard user)

## License

[MIT](LICENSE)
