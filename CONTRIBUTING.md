# Contributing to win-disk-optimizer

Thank you for helping make Windows storage cleanup safer and more transparent for everyone!

## Guiding Principles

1. **Zero destructive surprises**: Never delete personal libraries (`Documents`, `Desktop`, `Pictures`, `Videos`, `Downloads`, `OneDrive`), browser logins/cookies/bookmarks, or active Windows Installer packages.
2. **Explain every rule**: Every rule in `src/DiskOptimizer.Rules.psm1` must supply a clear `Reason`, accurate `Confidence` (`High` or `Medium`), and appropriate `NeededStatus` (`NotNeeded`, `NeededMoveOffC`, `OptionalReview`, or `NeededKeep`).
3. **PowerShell 5.1 & 7+ compatibility**: Avoid PowerShell 7-only syntax (`??`, `?:`, `-Parallel`) so scripts work out of the box on default Windows 10 and Windows 11 installations.
4. **StrictMode compliance**: All scripts run under `Set-StrictMode -Version Latest`. Use `Get-PropertySum` rather than `(Measure-Object ... -Sum).Sum` on potentially empty collections.

## Adding a New Cache or Cleanup Rule

1. Add or update the rule inside `src/DiskOptimizer.Rules.psm1` (or `Get-KnownCacheTargets` / `Get-RelocatableCacheTargets` in `src/DiskOptimizer.Common.psm1`).
2. Add a synthetic test case in `tests/Test-DiskOptimizer.ps1` verifying classification (`NotNeeded`, `NeededMoveOffC`, or `OptionalReview`) and confirming protected sibling files are untouched.
3. Run the full test suite locally before opening a pull request:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\tests\Test-DiskOptimizer.ps1
```
