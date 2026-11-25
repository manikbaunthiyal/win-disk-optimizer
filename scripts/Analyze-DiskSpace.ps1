<#
.SYNOPSIS
    Read-only audit of Windows disk space usage, large caches, and orphaned installers.

.EXAMPLE
    .\Analyze-DiskSpace.ps1
    .\Analyze-DiskSpace.ps1 -Top 15 -IncludeInstallerAudit
    .\Analyze-DiskSpace.ps1 -AsJson
#>
[CmdletBinding()]
param(
    [string]$TargetDrive = 'C:\',
    [int]$Top = 10,
    [switch]$Quick,
    [switch]$IncludeInstallerAudit,
    [switch]$AsJson
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'SilentlyContinue'

$modulePath = Join-Path (Split-Path -Parent $PSScriptRoot) 'src\DiskOptimizer.Common.psm1'
Import-Module $modulePath -Force

$drives = @(Get-DriveUsageSummary)
$isSystemDriveTarget = $TargetDrive.TrimEnd('\').Equals($env:SystemDrive, [System.StringComparison]::OrdinalIgnoreCase)
$rootFolders = if (-not $Quick -or -not $isSystemDriveTarget) {
    @(Get-SubfolderSizes -Root $TargetDrive -Top $Top)
} else {
    @()
}

$userFolders = @()
$localAppData = @()
$programData = @()
$windowsFolders = @()
if ($isSystemDriveTarget -and -not $Quick) {
    $userFolders = @(Get-SubfolderSizes -Root $env:USERPROFILE -Top $Top)
    $localAppData = @(Get-SubfolderSizes -Root $env:LOCALAPPDATA -Top $Top)
    $programData = @(Get-SubfolderSizes -Root $env:ProgramData -Top $Top)
    $windowsFolders = @(Get-SubfolderSizes -Root $env:SystemRoot -Top $Top)
}

$knownCaches = foreach ($target in (Get-KnownCacheTargets)) {
    if (Test-Path -LiteralPath $target.Path) {
        $bytes = Get-DirectorySizeFast -Path $target.Path
        if ($bytes -gt 1MB) {
            [PSCustomObject]@{
                Category = $target.Category
                Label    = $target.Label
                Path     = $target.Path
                SizeMB   = [math]::Round($bytes / 1MB, 1)
                SizeGB   = [math]::Round($bytes / 1GB, 2)
            }
        }
    }
}

$relocatable = foreach ($r in (Get-RelocatableCacheTargets)) {
    if (Test-Path -LiteralPath $r.Source) {
        $item = Get-Item -LiteralPath $r.Source -Force -ErrorAction SilentlyContinue
        $isLinked = [bool]($item -and ($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint))
        $bytes = if ($isLinked) { [int64]0 } else { Get-DirectorySizeFast -Path $r.Source }
        [PSCustomObject]@{
            Key      = $r.Key
            Label    = $r.Label
            Source   = $r.Source
            IsLinked = $isLinked
            Target   = if ($isLinked) { ($item.Target -join ', ') } else { $null }
            SizeMB   = [math]::Round($bytes / 1MB, 1)
            SizeGB   = [math]::Round($bytes / 1GB, 2)
        }
    }
}

$systemFiles = @()
foreach ($name in @('hiberfil.sys', 'pagefile.sys', 'swapfile.sys')) {
    $fi = Get-ChildItem -LiteralPath $TargetDrive -Force -File -Filter $name -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($fi) {
        $systemFiles += [PSCustomObject]@{
            Name   = $fi.Name
            SizeGB = [math]::Round($fi.Length / 1GB, 2)
        }
    }
}

$recycleSizeMB = 0.0
$recycleCount = 0
try {
    $shell = New-Object -ComObject Shell.Application
    $rb = $shell.NameSpace(0xa)
    $items = @($rb.Items())
    $recycleCount = $items.Count
    $sumBytes = Get-PropertySum -Items $items -Property 'Size'
    $recycleSizeMB = [math]::Round($sumBytes / 1MB, 1)
} catch {}

$orphans = @()
$orphanSummary = @()
if ($IncludeInstallerAudit) {
    $orphans = @(Get-OrphanedWindowsInstallers -IncludeMetadata)
    $orphanSummary = @(Group-InstallersByProduct -Orphans $orphans | Select-Object ProductName, Count, SizeGB)
}

if ($AsJson) {
    [PSCustomObject]@{
        IsAdmin               = Test-IsAdministrator
        Drives                = $drives
        SystemRootFiles       = $systemFiles
        RecycleBin            = @{ Items = $recycleCount; SizeMB = $recycleSizeMB }
        TopDriveFolders       = $rootFolders
        TopUserFolders        = $userFolders
        TopLocalAppData       = $localAppData
        TopProgramData        = $programData
        TopWindowsFolders     = $windowsFolders
        KnownCleanableCaches  = @($knownCaches)
        RelocatableDevCaches  = @($relocatable)
        OrphanedInstallers    = $orphanSummary
    } | ConvertTo-Json -Depth 5
    return
}

Write-Host "`n=== DRIVES ===" -ForegroundColor Cyan
$drives | Format-Table -AutoSize

if ($systemFiles.Count -gt 0) {
    Write-Host "=== SYSTEM ROOT FILES ($TargetDrive) ===" -ForegroundColor Cyan
    $systemFiles | Format-Table -AutoSize
}

Write-Host ("Recycle Bin: {0} item(s), {1:N1} MB" -f $recycleCount, $recycleSizeMB)

foreach ($section in @(
    @{ Title = "TOP FOLDERS ON $TargetDrive"; Data = $rootFolders },
    @{ Title = "TOP FOLDERS IN $env:SystemRoot"; Data = $windowsFolders },
    @{ Title = "TOP FOLDERS IN $env:USERPROFILE"; Data = $userFolders },
    @{ Title = "TOP FOLDERS IN $env:LOCALAPPDATA"; Data = $localAppData },
    @{ Title = "TOP FOLDERS IN $env:ProgramData"; Data = $programData }
)) {
    if ($section.Data.Count -gt 0) {
        Write-Host "`n=== $($section.Title) ===" -ForegroundColor Cyan
        $section.Data | Select-Object Name, SizeGB, SizeMB | Format-Table -AutoSize
    }
}

Write-Host "`n=== KNOWN CLEANABLE CACHES (> 1 MB) ===" -ForegroundColor Cyan
$knownCaches | Sort-Object SizeMB -Descending | Format-Table Category, Label, SizeMB, SizeGB, Path -AutoSize

Write-Host "`n=== RELOCATABLE DEV / AI CACHES ===" -ForegroundColor Cyan
$relocatable | Format-Table Key, Label, SizeGB, IsLinked, Target -AutoSize

if ($IncludeInstallerAudit) {
    $totalOrphanGB = [math]::Round((Get-PropertySum -Items $orphans -Property 'SizeBytes') / 1GB, 2)
    Write-Host "`n=== ORPHANED WINDOWS INSTALLER PACKAGES ($($orphans.Count) files, $totalOrphanGB GB) ===" -ForegroundColor Yellow
    $orphanSummary | Format-Table -AutoSize
} else {
    Write-Host "`nTip: Re-run with -IncludeInstallerAudit to scan C:\Windows\Installer for orphaned .msi/.msp patches." -ForegroundColor Gray
}
