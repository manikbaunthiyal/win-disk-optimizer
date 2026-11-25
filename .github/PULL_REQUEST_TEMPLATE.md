## Summary

- What rule, fix, or improvement does this PR make?

## Safety Checklist

- [ ] Verified no personal data, logins, or active installer files can be deleted
- [ ] Compatible with Windows PowerShell 5.1 and PowerShell 7+ (`Set-StrictMode -Version Latest`)
- [ ] Ran `powershell -NoProfile -ExecutionPolicy Bypass -File .\tests\Test-DiskOptimizer.ps1` and all tests pass
