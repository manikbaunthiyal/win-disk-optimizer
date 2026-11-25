<#
.SYNOPSIS
    Safely cleans user-level temporary files, crash dumps, and application caches
    without deleting personal files, browser logins, cookies, bookmarks, or IDE settings.

.EXAMPLE
    .\Invoke-UserCleanup.ps1 -WhatIf
    .\Invoke-UserCleanup.ps1 -Categories Temp,CrashDumps,DevCaches,IdeCaches
    .\Invoke-UserCleanup.ps1 -Categories All -EmptyRecycleBin
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [ValidateSet('Temp', 'CrashDumps', 'DevCaches', 'IdeCaches', 'BrowserCaches', 'LauncherCaches', 'UpdaterCaches', 'All')]
    [string[]]$Categories = @('Temp', 'CrashDumps', 'DevCaches', 'IdeCaches'),

    [int]$MinTempAgeMinutes = 60,

    [switch]$EmptyRecycleBin,

    [switch]$ForceRunningApps
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'SilentlyContinue'

$modulePath = Join-Path (Split-Path -Parent $PSScriptRoot) 'src\DiskOptimizer.Common.psm1'
Import-Module $modulePath -Force

$selectedCategories = if ($Categories -contains 'All') {
    @('Temp', 'CrashDumps', 'DevCaches', 'IdeCaches', 'BrowserCaches', 'LauncherCaches', 'UpdaterCaches')
} else {
    $Categories
}

$driveLetter = ($env:SystemDrive -replace ':', '')
$beforeFree = (Get-PSDrive -Name $driveLetter).Free
Write-Host ("{0}: Free BEFORE: {1:N2} GB" -f $driveLetter, ($beforeFree / 1GB)) -ForegroundColor Cyan

$targets = Get-KnownCacheTargets | Where-Object { $selectedCategories -contains $_.Category }
$results = @()

foreach ($t in $targets) {
    if (-not (Test-Path -LiteralPath $t.Path)) { continue }

    if (-not $ForceRunningApps -and $t.ProcessGuard.Count -gt 0) {
        $running = Get-Process -Name $t.ProcessGuard -ErrorAction SilentlyContinue
        if ($running) {
            Write-Host ("Skipped {0} (app running: {1})" -f $t.Label, (($running.ProcessName | Select-Object -Unique) -join ', ')) -ForegroundColor Yellow
            continue
        }
    }

    $age = if ($t.Category -eq 'Temp') { $MinTempAgeMinutes } else { $t.MinAgeMinutes }
    $res = Remove-SafeDirectoryContents -Path $t.Path -MinAgeMinutes $age -Label $t.Label
    $results += $res
    if ($res.FreedBytes -gt 0) {
        Write-Host ("{0,-32}: {1,7:N1} MB ({2} files)" -f $res.Label, $res.FreedMB, $res.FilesDeleted) -ForegroundColor Green
    }
}

if ($EmptyRecycleBin) {
    if ($PSCmdlet.ShouldProcess("Recycle Bin on ${driveLetter}:", 'Empty Recycle Bin')) {
        Clear-RecycleBin -DriveLetter $driveLetter -Force -ErrorAction SilentlyContinue
        Write-Host "Emptied Recycle Bin on ${driveLetter}:" -ForegroundColor Green
    }
}

$totalSimulatedMB = [math]::Round((Get-PropertySum -Items $results -Property 'FreedBytes') / 1MB, 1)
$afterFree = (Get-PSDrive -Name $driveLetter).Free

if ($WhatIfPreference) {
    Write-Host ("`n[WhatIf] Estimated recoverable space: {0:N1} MB ({1:N2} GB)" -f $totalSimulatedMB, ($totalSimulatedMB / 1024)) -ForegroundColor Cyan
} else {
    Write-Host ("`n{0}: Free AFTER : {1:N2} GB" -f $driveLetter, ($afterFree / 1GB)) -ForegroundColor Cyan
    Write-Host ("Net Freed      : {0:N2} GB ({1:N1} MB)" -f (($afterFree - $beforeFree) / 1GB), (($afterFree - $beforeFree) / 1MB)) -ForegroundColor Green
}
