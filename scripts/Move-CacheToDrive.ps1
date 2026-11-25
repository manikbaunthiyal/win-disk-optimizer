<#
.SYNOPSIS
    Safely relocates large developer and AI caches (.gradle, huggingface, whisper, uv, pub)
    from C: to another drive using robocopy verification, User environment variables,
    and zero-byte NTFS directory junctions.

.EXAMPLE
    .\Move-CacheToDrive.ps1 -DestinationRoot D:\Caches -WhatIf
    .\Move-CacheToDrive.ps1 -DestinationRoot D:\Caches -Keys gradle,huggingface,whisper,uv
    .\Move-CacheToDrive.ps1 -DestinationRoot D:\Caches -Keys gradle -Restore
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory)]
    [string]$DestinationRoot,

    [ValidateSet('gradle', 'huggingface', 'whisper', 'uv', 'pub', 'All')]
    [string[]]$Keys = @('gradle', 'huggingface', 'whisper', 'uv'),

    [switch]$NoJunction,

    [switch]$Restore
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$modulePath = Join-Path (Split-Path -Parent $PSScriptRoot) 'src\DiskOptimizer.Common.psm1'
Import-Module $modulePath -Force

$selectedKeys = if ($Keys -contains 'All') {
    @('gradle', 'huggingface', 'whisper', 'uv', 'pub')
} else {
    $Keys
}

$targets = Get-RelocatableCacheTargets | Where-Object { $selectedKeys -contains $_.Key }

foreach ($t in $targets) {
    $dest = Join-Path $DestinationRoot $t.DefaultSubdir

    if ($Restore) {
        if (-not (Test-Path -LiteralPath $t.Source)) {
            Write-Host "Skip restore (missing): $($t.Source)" -ForegroundColor Gray
            continue
        }
        $item = Get-Item -LiteralPath $t.Source -Force
        if (-not ($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint)) {
            Write-Host "Skip restore (not a junction): $($t.Source)" -ForegroundColor Yellow
            continue
        }
        $actualTarget = if ($item.Target) { $item.Target[0] } else { $dest }
        if (-not (Test-Path -LiteralPath $actualTarget)) {
            Write-Warning "Junction target missing for $($t.Label): $actualTarget"
            continue
        }

        if ($PSCmdlet.ShouldProcess("$($t.Source) <- $actualTarget", 'Restore cache back to original location')) {
            # Remove junction reparse point safely without deleting target contents
            [System.IO.Directory]::Delete($t.Source)
            $stats = Invoke-VerifiedDirectoryCopy -From $actualTarget -To $t.Source
            if ($t.EnvVar) {
                [Environment]::SetEnvironmentVariable($t.EnvVar, $null, 'User')
            }
            Write-Host ("Restored {0} ({1:N2} GB) back to {2}" -f $t.Label, ($stats.Bytes / 1GB), $t.Source) -ForegroundColor Green
        }
        continue
    }

    if (-not (Test-Path -LiteralPath $t.Source)) {
        Write-Host "Skip (not found): $($t.Label) [$($t.Source)]" -ForegroundColor Gray
        continue
    }

    $srcItem = Get-Item -LiteralPath $t.Source -Force
    if ($srcItem.Attributes -band [System.IO.FileAttributes]::ReparsePoint) {
        Write-Host "Skip (already a junction): $($t.Label) -> $($srcItem.Target -join ', ')" -ForegroundColor Yellow
        continue
    }

    if ((Test-Path -LiteralPath $dest) -and (@(Get-ChildItem -LiteralPath $dest -Force -ErrorAction SilentlyContinue).Count -gt 0)) {
        Write-Warning "Destination already exists and is non-empty: $dest. Skipping $($t.Label)."
        continue
    }

    $bytes = Get-DirectorySizeFast -Path $t.Source
    if ($PSCmdlet.ShouldProcess("$($t.Source) -> $dest", ("Move {0:N2} GB and link" -f ($bytes / 1GB)))) {
        Write-Host ("Moving {0} ({1:N2} GB) -> {2}..." -f $t.Label, ($bytes / 1GB), $dest) -ForegroundColor Cyan
        $stats = Invoke-VerifiedDirectoryCopy -From $t.Source -To $dest

        if ($t.EnvVar) {
            [Environment]::SetEnvironmentVariable($t.EnvVar, $dest, 'User')
            Write-Host ("  Set User env {0} = {1}" -f $t.EnvVar, $dest)
        }

        Remove-Item -LiteralPath $t.Source -Recurse -Force
        if (-not $NoJunction) {
            New-Item -ItemType Junction -Path $t.Source -Target $dest | Out-Null
            Write-Host ("  Created junction {0} -> {1}" -f $t.Source, $dest)
        }

        Write-Host ("  Freed {0:N2} GB on system drive ({1} files)." -f ($stats.Bytes / 1GB), $stats.Files) -ForegroundColor Green
    }
}
