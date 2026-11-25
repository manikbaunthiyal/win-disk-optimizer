# Security Policy

## Reporting a Vulnerability or Unsafe Rule

`win-disk-optimizer` interacts directly with the Windows filesystem, NTFS junctions, and Windows Installer metadata. If you discover a rule or edge case that could delete unintended user files, misidentify an active Windows Installer package, or bypass `Test-IsProtectedPath`:

1. Please **do not** disclose destructive reproduction steps publicly before a fix is ready.
2. Open a private security advisory on GitHub (**Security -> Advisories -> Report a vulnerability**) or file a minimal issue without sharing sensitive local paths.

## Built-In Safety Boundaries

- `Test-IsProtectedPath` explicitly blocks recursive deletion on critical OS directories, personal library roots, and Chromium profile roots.
- `Move-CacheToDrive.ps1` verifies copied file counts and byte sums via `robocopy` before removing the original directory.
- `Invoke-AdminCleanup.ps1` cross-checks both Windows Installer COM (`ProductsEx`, `PatchesEx`) and `HKLM\...\Installer\UserData` registry entries before marking `.msi`/`.msp` packages orphaned, and supports `-BackupDir` instead of permanent deletion.
