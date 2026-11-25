<#
.SYNOPSIS
    Self-contained, rule-based Windows C: disk analyzer, cleaner, and cache relocator.
    Classifies storage into NotNeeded, NeededMoveOffC, OptionalReview, and NeededKeep
    using deterministic rules with zero AI or external service dependencies.

.EXAMPLE
    .\Optimize-Disk.ps1
    .\Optimize-Disk.ps1 -Mode Interactive
    .\Optimize-Disk.ps1 -Mode AutoSafe -WhatIf
    .\Optimize-Disk.ps1 -Mode AutoSafe -AutoRelocate -EmptyRecycleBin
    .\Optimize-Disk.ps1 -Mode Report -ExportMarkdown .\disk-report.md
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [ValidateSet('Report', 'Interactive', 'AutoSafe')]
    [string]$Mode = 'Report',

    [string]$RelocateDrive,

    [switch]$AutoRelocate,

    [switch]$SkipInstallerAudit,

    [int]$MinItemSizeMB = 5,

    [int]$MinTempAgeMinutes = 60,

    [switch]$EmptyRecycleBin,

    [switch]$ForceRunningApps,

    [string]$ExportJson,

    [string]$ExportMarkdown
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$srcDir = Join-Path $PSScriptRoot 'src'
Import-Module (Join-Path $srcDir 'DiskOptimizer.Common.psm1') -Force
Import-Module (Join-Path $srcDir 'DiskOptimizer.Rules.psm1') -Force

function Invoke-DecisionDelete {
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)][psobject]$Decision,
        [switch]$ForceApps
    )

    if ($Decision.NeededStatus -eq 'NeededKeep') {
        throw "Refusing to delete protected decision '$($Decision.Id)'."
    }

    if (-not $ForceApps -and @($Decision.ProcessGuard).Count -gt 0) {
        $running = Get-Process -Name $Decision.ProcessGuard -ErrorAction SilentlyContinue
        if ($running) {
            $names = (($running.ProcessName | Select-Object -Unique) -join ', ')
            Write-Host ("  Skipped {0} (running: {1})" -f $Decision.Name, $names) -ForegroundColor Yellow
            return [int64]0
        }
    }

    if ($Decision.ItemType -eq 'FileList' -and @($Decision.TargetPaths).Count -gt 0) {
        $freed = [int64]0
        foreach ($fp in $Decision.TargetPaths) {
            if (-not (Test-Path -LiteralPath $fp)) { continue }
            $fi = Get-Item -LiteralPath $fp -Force -ErrorAction SilentlyContinue
            if (-not $fi) { continue }
            $len = $fi.Length
            if ($PSCmdlet.ShouldProcess($fp, 'Delete file')) {
                try {
                    [System.IO.File]::Delete($fp)
                    $freed += $len
                } catch {}
            } else {
                $freed += $len
            }
        }
        Write-Host ("  {0,-42}: {1,7:N1} MB" -f $Decision.Name, ($freed / 1MB)) -ForegroundColor Green
        return $freed
    }

    $res = Remove-SafeDirectoryContents -Path $Decision.Path -MinAgeMinutes $Decision.MinAgeMinutes -Label $Decision.Name -WhatIf:$WhatIfPreference
    Write-Host ("  {0,-42}: {1,7:N1} MB" -f $Decision.Name, $res.FreedMB) -ForegroundColor Green
    return [int64]$res.FreedBytes
}

function Invoke-DecisionRelocate {
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)][psobject]$Decision,
        [Parameter(Mandatory)][string]$DestinationRoot
    )

    if (-not $Decision.RelocateSubdir) { return [int64]0 }
    $dest = Join-Path $DestinationRoot $Decision.RelocateSubdir

    if ((Test-Path -LiteralPath $dest) -and (@(Get-ChildItem -LiteralPath $dest -Force -ErrorAction SilentlyContinue).Count -gt 0)) {
        Write-Warning "  Destination exists and is non-empty: $dest. Skipping $($Decision.Name)."
        return [int64]0
    }

    if ($PSCmdlet.ShouldProcess("$($Decision.Path) -> $dest", ("Relocate {0:N2} GB" -f $Decision.SizeGB))) {
        Write-Host ("  Moving {0} ({1:N2} GB) -> {2}..." -f $Decision.Name, $Decision.SizeGB, $dest) -ForegroundColor Cyan
        $stats = Invoke-VerifiedDirectoryCopy -From $Decision.Path -To $dest
        if ($Decision.EnvVar) {
            [Environment]::SetEnvironmentVariable($Decision.EnvVar, $dest, 'User')
            Write-Host ("    Set User env $($Decision.EnvVar) = $dest")
        }
        Remove-Item -LiteralPath $Decision.Path -Recurse -Force
        New-Item -ItemType Junction -Path $Decision.Path -Target $dest | Out-Null
        Write-Host ("    Created junction $($Decision.Path) -> $dest") -ForegroundColor Green
        return [int64]$stats.Bytes
    }
    return [int64]$Decision.SizeBytes
}

function Format-RuleReport {
    param(
        [Parameter(Mandatory)][psobject[]]$Decisions,
        [Parameter(Mandatory)][psobject[]]$Drives
    )

    Write-Host "`n=== STORAGE DRIVES ===" -ForegroundColor Cyan
    $Drives | Format-Table -AutoSize

    $groups = @(
        @{ Status = 'NotNeeded';      Filter = { -not $_.RequiresAdmin }; Title = '1. NOT NEEDED - SAFE TO DELETE (USER)';            Color = 'Green' }
        @{ Status = 'NotNeeded';      Filter = { $_.RequiresAdmin };      Title = '2. NOT NEEDED - ADMIN CLEANUP REQUIRED';           Color = 'Yellow' }
        @{ Status = 'NeededMoveOffC'; Filter = { $true };                 Title = '3. NEEDED - RELOCATE TO SECONDARY DRIVE';          Color = 'Cyan' }
        @{ Status = 'OptionalReview'; Filter = { $true };                 Title = '4. OPTIONAL REVIEW - USER DECISION RECOMMENDED';   Color = 'Magenta' }
        @{ Status = 'NeededKeep';     Filter = { $true };                 Title = '5. NEEDED - PROTECTED / ALREADY OPTIMIZED';        Color = 'Gray' }
    )

    foreach ($g in $groups) {
        $rows = @($Decisions | Where-Object { $_.NeededStatus -eq $g.Status } | Where-Object $g.Filter)
        if ($rows.Count -eq 0) { continue }
        $sumGB = [math]::Round((Get-PropertySum -Items $rows -Property 'SizeBytes') / 1GB, 2)
        Write-Host ("`n=== {0} ({1} items, {2:N2} GB) ===" -f $g.Title, $rows.Count, $sumGB) -ForegroundColor $g.Color
        $rows | Select-Object Name, Category, SizeMB, SizeGB, Confidence, Reason | Format-Table -AutoSize -Wrap
    }
}

function Export-ReportMarkdown {
    param(
        [Parameter(Mandatory)][string]$OutPath,
        [Parameter(Mandatory)][psobject[]]$Decisions,
        [Parameter(Mandatory)][psobject[]]$Drives
    )

    $lines = New-Object 'System.Collections.Generic.List[string]'
    $lines.Add('# Windows Disk Optimization Report')
    $lines.Add("Generated: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')")
    $lines.Add('')
    $lines.Add('## Drives')
    $lines.Add('| Drive | Used (GB) | Free (GB) | Total (GB) | Free % |')
    $lines.Add('|---|---:|---:|---:|---:|')
    foreach ($d in $Drives) {
        $lines.Add("| $($d.Drive) | $($d.UsedGB) | $($d.FreeGB) | $($d.TotalGB) | $($d.FreePercent)% |")
    }
    $lines.Add('')
    $lines.Add('## Rule Decisions')
    $lines.Add('| Status | Action | Item | Size (MB) | Requires Admin | Reason | Path |')
    $lines.Add('|---|---|---|---:|:---:|---|---|')
    foreach ($r in $Decisions) {
        $reasonEsc = ($r.Reason -replace '\|', '\|')
        $lines.Add("| $($r.NeededStatus) | $($r.RecommendedAction) | $($r.Name) | $($r.SizeMB) | $($r.RequiresAdmin) | $reasonEsc | ``$($r.Path)`` |")
    }
    Set-Content -LiteralPath $OutPath -Value $lines -Encoding UTF8
    Write-Host "Exported Markdown report to: $OutPath" -ForegroundColor Cyan
}

# ---- Main Execution ----
$driveLetter = ($env:SystemDrive -replace ':', '')
$beforeFree = (Get-PSDrive -Name $driveLetter).Free
$drives = @(Get-DriveUsageSummary)
$decisions = @(Get-DiskCleanupRecommendations -MinTempAgeMinutes $MinTempAgeMinutes -MinItemSizeMB $MinItemSizeMB -IncludeInstallerAudit:(-not $SkipInstallerAudit))

Format-RuleReport -Decisions $decisions -Drives $drives

if ($ExportJson) {
    [PSCustomObject]@{
        GeneratedAt = (Get-Date).ToString('o')
        IsAdmin     = (Test-IsAdministrator)
        Drives      = $drives
        Decisions   = $decisions
    } | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $ExportJson -Encoding UTF8
    Write-Host "Exported JSON report to: $ExportJson" -ForegroundColor Cyan
}

if ($ExportMarkdown) {
    Export-ReportMarkdown -OutPath $ExportMarkdown -Decisions $decisions -Drives $drives
}

if ($Mode -eq 'Report') {
    $safeRows = @($decisions | Where-Object { $_.NeededStatus -eq 'NotNeeded' -and -not $_.RequiresAdmin })
    $adminRows = @($decisions | Where-Object { $_.NeededStatus -eq 'NotNeeded' -and $_.RequiresAdmin })
    $relocRows = @($decisions | Where-Object { $_.NeededStatus -eq 'NeededMoveOffC' })
    $safeMB = [math]::Round((Get-PropertySum -Items $safeRows -Property 'SizeBytes') / 1MB, 1)
    $adminGB = [math]::Round((Get-PropertySum -Items $adminRows -Property 'SizeBytes') / 1GB, 2)
    $relocGB = [math]::Round((Get-PropertySum -Items $relocRows -Property 'SizeBytes') / 1GB, 2)
    Write-Host ("`nSummary -> Safe User Delete: {0:N1} MB | Admin Cleanup: {1:N2} GB | Relocate Off C: {2:N2} GB" -f $safeMB, $adminGB, $relocGB) -ForegroundColor Cyan
    Write-Host "Next: Run '.\Optimize-Disk.ps1 -Mode Interactive' for guided cleanup, or '-Mode AutoSafe' for unattended safe cleanup." -ForegroundColor Gray
    return
}

$safeUserItems = @($decisions | Where-Object { $_.NeededStatus -eq 'NotNeeded' -and -not $_.RequiresAdmin -and $_.Confidence -eq 'High' })
$safeMediumItems = @($decisions | Where-Object { $_.NeededStatus -eq 'NotNeeded' -and -not $_.RequiresAdmin -and $_.Confidence -ne 'High' })
$relocItems = @($decisions | Where-Object { $_.NeededStatus -eq 'NeededMoveOffC' })
$reviewItems = @($decisions | Where-Object { $_.NeededStatus -eq 'OptionalReview' -and (-not $_.RequiresAdmin -or (Test-IsAdministrator)) })
$adminItems = @($decisions | Where-Object { $_.NeededStatus -eq 'NotNeeded' -and $_.RequiresAdmin })

$bestDrive = Get-BestRelocationDrive | Select-Object -First 1
$resolvedRelocRoot = if ($RelocateDrive) {
    if ($RelocateDrive -match '^[A-Za-z]:\\?$') { Join-Path ($RelocateDrive.TrimEnd('\') + '\') 'Caches' } else { $RelocateDrive }
} elseif ($bestDrive) {
    Join-Path $bestDrive.Root 'Caches'
} else {
    $null
}

if ($Mode -eq 'AutoSafe') {
    Write-Host "`n=== RUNNING AUTO-SAFE CLEANUP ===" -ForegroundColor Green
    foreach ($d in $safeUserItems) {
        Invoke-DecisionDelete -Decision $d -ForceApps:$ForceRunningApps -WhatIf:$WhatIfPreference | Out-Null
    }
    if ($EmptyRecycleBin) {
        if ($PSCmdlet.ShouldProcess("Recycle Bin on ${driveLetter}:", 'Empty Recycle Bin')) {
            Clear-RecycleBin -DriveLetter $driveLetter -Force -ErrorAction SilentlyContinue
        }
    }
    if (($AutoRelocate -or $RelocateDrive) -and $relocItems.Count -gt 0) {
        if ($resolvedRelocRoot) {
            foreach ($r in $relocItems) {
                Invoke-DecisionRelocate -Decision $r -DestinationRoot $resolvedRelocRoot -WhatIf:$WhatIfPreference | Out-Null
            }
        } else {
            Write-Warning 'AutoRelocate requested, but no non-system fixed drive was found.'
        }
    }
} elseif ($Mode -eq 'Interactive') {
    $allSafe = @($safeUserItems + $safeMediumItems)
    if ($allSafe.Count -gt 0) {
        $safeGB = [math]::Round((Get-PropertySum -Items $allSafe -Property 'SizeBytes') / 1GB, 2)
        $ans = Read-Host "`nDelete $($allSafe.Count) safe NotNeeded items ($safeGB GB)? [Y/n]"
        if ($ans -eq '' -or $ans -match '^(y|yes)$') {
            foreach ($d in $allSafe) {
                Invoke-DecisionDelete -Decision $d -ForceApps:$ForceRunningApps -WhatIf:$WhatIfPreference | Out-Null
            }
        }
    }

    if ($relocItems.Count -gt 0) {
        if ($resolvedRelocRoot) {
            $relocGB = [math]::Round((Get-PropertySum -Items $relocItems -Property 'SizeBytes') / 1GB, 2)
            $ans = Read-Host "`nRelocate $($relocItems.Count) dev/AI caches ($relocGB GB) to '$resolvedRelocRoot' (preserves data via env vars + junctions)? [Y/n]"
            if ($ans -eq '' -or $ans -match '^(y|yes)$') {
                foreach ($r in $relocItems) {
                    Invoke-DecisionRelocate -Decision $r -DestinationRoot $resolvedRelocRoot -WhatIf:$WhatIfPreference | Out-Null
                }
            }
        } else {
            Write-Host "`nNo secondary drive detected for cache relocation." -ForegroundColor Gray
        }
    }

    if ($reviewItems.Count -gt 0) {
        Write-Host "`n--- Optional Review Items ---" -ForegroundColor Magenta
        foreach ($rv in $reviewItems) {
            $reply = Read-Host "[$($rv.SizeMB) MB] $($rv.Name) ($($rv.Reason)) -> Delete? [y/N/q]"
            if ($reply -match '^q$') { break }
            if ($reply -match '^(y|yes)$') {
                Invoke-DecisionDelete -Decision $rv -ForceApps:$ForceRunningApps -WhatIf:$WhatIfPreference | Out-Null
            }
        }
    }

    if ($adminItems.Count -gt 0 -and -not (Test-IsAdministrator)) {
        $adminGB = [math]::Round((Get-PropertySum -Items $adminItems -Property 'SizeBytes') / 1GB, 2)
        $launch = Read-Host "`n$adminGB GB requires Administrator privileges (orphaned Windows\Installer & system caches). Launch elevated cleanup via UAC? [y/N]"
        if ($launch -match '^(y|yes)$') {
            $adminScript = Join-Path $PSScriptRoot 'scripts\Invoke-AdminCleanup.ps1'
            try {
                Start-Process -FilePath 'powershell.exe' -Verb RunAs -Wait -ArgumentList @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', "`"$adminScript`"")
            } catch {
                Write-Warning "Could not launch elevated window ($($_.Exception.Message)). Open PowerShell as Administrator and run: `"$adminScript`""
            }
        }
    }
}

if (-not $WhatIfPreference) {
    $afterFree = (Get-PSDrive -Name $driveLetter).Free
    Write-Host ("`n{0}: Free BEFORE: {1:N2} GB -> AFTER: {2:N2} GB (Net Freed: {3:N2} GB)" -f $driveLetter, ($beforeFree / 1GB), ($afterFree / 1GB), (($afterFree - $beforeFree) / 1GB)) -ForegroundColor Green
}
