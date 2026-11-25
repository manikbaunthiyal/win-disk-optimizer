<#
.SYNOPSIS
    Administrator cleanup for system-level bloat on Windows:
    - Verifies and removes (or backs up) orphaned .msi/.msp files in C:\Windows\Installer
    - Runs DISM Component Store cleanup (WinSxS)
    - Clears Windows Update Download cache, Delivery Optimization cache, WER reports, and Windows\Temp
    - Optionally shrinks or disables hibernation (hiberfil.sys) when requested

.EXAMPLE
    .\Invoke-AdminCleanup.ps1 -WhatIf
    .\Invoke-AdminCleanup.ps1 -BackupDir D:\InstallerOrphansBackup
    .\Invoke-AdminCleanup.ps1 -Force
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [switch]$Force,

    [string]$BackupDir,

    [switch]$SkipDism,

    [ValidateSet('Keep', 'Reduced', 'Off')]
    [string]$HibernationMode = 'Keep',

    [string]$LogPath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$modulePath = Join-Path (Split-Path -Parent $PSScriptRoot) 'src\DiskOptimizer.Common.psm1'
Import-Module $modulePath -Force

if (-not (Test-IsAdministrator)) {
    Write-Error "Administrator privileges are required. Open PowerShell as Administrator and run again."
    exit 1
}

if ($LogPath) {
    try { Start-Transcript -Path $LogPath -Force | Out-Null } catch {}
}

$driveLetter = ($env:SystemDrive -replace ':', '')
$beforeFree = (Get-PSDrive -Name $driveLetter).Free
Write-Host ("{0}: Free BEFORE: {1:N2} GB" -f $driveLetter, ($beforeFree / 1GB)) -ForegroundColor Cyan

# 1. Orphaned Windows Installer packages
Write-Host "`n[1/4] Scanning Windows\Installer for orphaned .msi/.msp packages..." -ForegroundColor Yellow
$orphans = @(Get-OrphanedWindowsInstallers -IncludeMetadata)
$orphanBytes = Get-PropertySum -Items $orphans -Property 'SizeBytes'
Write-Host ("Found {0} orphaned packages totaling {1:N2} GB." -f $orphans.Count, ($orphanBytes / 1GB))

if ($orphans.Count -gt 0) {
    Group-InstallersByProduct -Orphans $orphans | Select-Object ProductName, Count, SizeGB | Format-Table -AutoSize

    $actionWord = if ($BackupDir) { "Move to '$BackupDir'" } else { 'Delete permanently' }
    $confirmed = $Force -or $WhatIfPreference
    if (-not $confirmed) {
        $reply = Read-Host "$actionWord these $($orphans.Count) orphaned files ($([math]::Round($orphanBytes / 1GB, 2)) GB)? [y/N]"
        $confirmed = ($reply -match '^(y|yes)$')
    }

    if ($confirmed) {
        if ($BackupDir -and -not $WhatIfPreference -and -not (Test-Path -LiteralPath $BackupDir)) {
            New-Item -ItemType Directory -Path $BackupDir -Force | Out-Null
        }
        $processedBytes = [int64]0
        foreach ($f in $orphans) {
            if ($PSCmdlet.ShouldProcess($f.FullName, $actionWord)) {
                try {
                    if ($BackupDir) {
                        Move-Item -LiteralPath $f.FullName -Destination (Join-Path $BackupDir $f.Name) -Force
                    } else {
                        Remove-Item -LiteralPath $f.FullName -Force
                    }
                    $processedBytes += $f.SizeBytes
                } catch {
                    Write-Warning "Skipped $($f.Name): $($_.Exception.Message)"
                }
            }
        }
        if (-not $WhatIfPreference) {
            Write-Host ("Processed orphaned installer packages: {0:N2} GB" -f ($processedBytes / 1GB)) -ForegroundColor Green
        }
    } else {
        Write-Host "Skipped Windows\Installer cleanup." -ForegroundColor Gray
    }
}

# 2. DISM Component Store cleanup (WinSxS)
if (-not $SkipDism) {
    Write-Host "`n[2/4] Running DISM Component Store cleanup..." -ForegroundColor Yellow
    if ($PSCmdlet.ShouldProcess('WinSxS Component Store', 'Dism.exe /Online /Cleanup-Image /StartComponentCleanup')) {
        & Dism.exe /Online /Cleanup-Image /StartComponentCleanup
    }
} else {
    Write-Host "`n[2/4] Skipped DISM cleanup (-SkipDism)." -ForegroundColor Gray
}

# 3. Windows Update download cache, Delivery Optimization, WER, Windows Temp
Write-Host "`n[3/4] Clearing Windows Update cache, Delivery Optimization, WER, and Windows Temp..." -ForegroundColor Yellow
$wuDownload = Join-Path $env:SystemRoot 'SoftwareDistribution\Download'
if (Test-Path -LiteralPath $wuDownload) {
    if ($PSCmdlet.ShouldProcess($wuDownload, 'Clear Windows Update downloads')) {
        $wuRunning = ((Get-Service -Name wuauserv -ErrorAction SilentlyContinue).Status -eq 'Running')
        if ($wuRunning) { Stop-Service -Name wuauserv -Force -ErrorAction SilentlyContinue }
        Remove-SafeDirectoryContents -Path $wuDownload -Label 'Windows Update Download Cache' | Out-Null
        if ($wuRunning) { Start-Service -Name wuauserv -ErrorAction SilentlyContinue }
    }
}

if ($PSCmdlet.ShouldProcess('Delivery Optimization Cache', 'Delete-DeliveryOptimizationCache -Force')) {
    try { Delete-DeliveryOptimizationCache -Force -ErrorAction SilentlyContinue } catch {}
}

foreach ($werDir in @(
    (Join-Path $env:ProgramData 'Microsoft\Windows\WER\ReportArchive'),
    (Join-Path $env:ProgramData 'Microsoft\Windows\WER\ReportQueue')
)) {
    Remove-SafeDirectoryContents -Path $werDir -Label $werDir | Out-Null
}

Remove-SafeDirectoryContents -Path (Join-Path $env:SystemRoot 'Temp') -MinAgeMinutes 60 -Label 'Windows Temp' | Out-Null

# 4. Optional Hibernation adjustment
Write-Host "`n[4/4] Checking hibernation setting (Mode: $HibernationMode)..." -ForegroundColor Yellow
if ($HibernationMode -eq 'Off') {
    if ($PSCmdlet.ShouldProcess('hiberfil.sys', 'powercfg /h off')) {
        & powercfg /h off
    }
} elseif ($HibernationMode -eq 'Reduced') {
    if ($PSCmdlet.ShouldProcess('hiberfil.sys', 'powercfg /h /type reduced')) {
        & powercfg /h /type reduced
    }
}

$afterFree = (Get-PSDrive -Name $driveLetter).Free
if (-not $WhatIfPreference) {
    Write-Host ("`n{0}: Free AFTER : {1:N2} GB" -f $driveLetter, ($afterFree / 1GB)) -ForegroundColor Cyan
    Write-Host ("Net Freed      : {0:N2} GB" -f (($afterFree - $beforeFree) / 1GB)) -ForegroundColor Green
}

if ($LogPath) {
    try { Stop-Transcript | Out-Null } catch {}
}
