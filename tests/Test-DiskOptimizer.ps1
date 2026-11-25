Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$repoRoot = Split-Path -Parent $PSScriptRoot
Import-Module (Join-Path $repoRoot 'src\DiskOptimizer.Common.psm1') -Force
Import-Module (Join-Path $repoRoot 'src\DiskOptimizer.Rules.psm1') -Force

$script:Passed = 0
$script:Failed = 0

function Assert-True {
    param(
        [bool]$Condition,
        [string]$Message
    )
    if ($Condition) {
        $script:Passed++
        Write-Host "[PASS] $Message" -ForegroundColor Green
    } else {
        $script:Failed++
        Write-Host "[FAIL] $Message" -ForegroundColor Red
    }
}

# 1. PowerShell AST syntax validation across all scripts and modules
$psFiles = Get-ChildItem -Path $repoRoot -Recurse -File | Where-Object { $_.Extension -in '.ps1', '.psm1' }
foreach ($f in $psFiles) {
    $parseErrors = $null
    $null = [System.Management.Automation.Language.Parser]::ParseFile($f.FullName, [ref]$null, [ref]$parseErrors)
    Assert-True ($parseErrors.Count -eq 0) "AST syntax valid: $($f.Name)"
}

# 2. Protected path safety guardrails
Assert-True (Test-IsProtectedPath -Path (Join-Path $env:SystemRoot 'System32')) "Test-IsProtectedPath protects Windows\System32"
Assert-True (Test-IsProtectedPath -Path (Join-Path $env:USERPROFILE 'Documents')) "Test-IsProtectedPath protects user Documents"
Assert-True (Test-IsProtectedPath -Path (Join-Path $env:LOCALAPPDATA 'Google\Chrome\User Data\Default')) "Test-IsProtectedPath protects browser Default profile root"
Assert-True (-not (Test-IsProtectedPath -Path (Join-Path $env:LOCALAPPDATA 'Google\Chrome\User Data\Default\Cache'))) "Test-IsProtectedPath allows browser Cache subfolder"
Assert-True (-not (Test-IsProtectedPath -Path (Join-Path $env:USERPROFILE 'OneDrive\Documents\Adobe\Premiere Pro\14.0\Adobe Premiere Pro Video Previews'))) "Test-IsProtectedPath allows Premiere Video Previews subfolder"

$threwOnProtected = $false
try {
    Remove-SafeDirectoryContents -Path (Join-Path $env:USERPROFILE 'Documents') -WhatIf | Out-Null
} catch {
    $threwOnProtected = $true
}
Assert-True $threwOnProtected "Remove-SafeDirectoryContents refuses protected path even under -WhatIf"

# 3. Isolated filesystem sandbox tests
$sandbox = Join-Path ([System.IO.Path]::GetTempPath()) ("win-disk-opt-test-" + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $sandbox -Force | Out-Null

try {
    # Test Get-DirectorySizeFast + junction skipping
    $realDir = Join-Path $sandbox 'real'
    $subDir = Join-Path $realDir 'sub'
    $targetDir = Join-Path $sandbox 'junction-target'
    New-Item -ItemType Directory -Path $subDir, $targetDir -Force | Out-Null

    [System.IO.File]::WriteAllBytes((Join-Path $realDir 'a.bin'), (New-Object byte[] 1024))
    [System.IO.File]::WriteAllBytes((Join-Path $subDir 'b.bin'), (New-Object byte[] 2048))
    [System.IO.File]::WriteAllBytes((Join-Path $targetDir 'big.bin'), (New-Object byte[] 8192))

    $junction = Join-Path $realDir 'linked'
    New-Item -ItemType Junction -Path $junction -Target $targetDir | Out-Null

    $measured = Get-DirectorySizeFast -Path $realDir
    Assert-True ($measured -eq 3072) "Get-DirectorySizeFast counts real files (3072) and skips junctions (got $measured)"

    $junctionDirect = Get-DirectorySizeFast -Path $junction
    Assert-True ($junctionDirect -eq 0) "Get-DirectorySizeFast returns 0 when root itself is a junction (got $junctionDirect)"

    [System.IO.Directory]::Delete($junction)

    # Test Remove-SafeDirectoryContents with -WhatIf and -MinAgeMinutes
    $oldFile = Join-Path $subDir 'old.tmp'
    $newFile = Join-Path $subDir 'new.tmp'
    [System.IO.File]::WriteAllBytes($oldFile, (New-Object byte[] 4096))
    [System.IO.File]::WriteAllBytes($newFile, (New-Object byte[] 512))
    (Get-Item $oldFile).LastWriteTime = (Get-Date).AddHours(-3)
    (Get-Item $newFile).LastWriteTime = (Get-Date)

    $sim = Remove-SafeDirectoryContents -Path $realDir -MinAgeMinutes 60 -Label 'SandboxTemp' -WhatIf
    Assert-True ((Test-Path $oldFile) -and (Test-Path $newFile)) "Remove-SafeDirectoryContents -WhatIf leaves files intact"
    Assert-True ($sim.FilesDeleted -eq 1 -and $sim.FreedBytes -eq 4096) "Remove-SafeDirectoryContents -WhatIf simulates only files older than MinAgeMinutes (count=$($sim.FilesDeleted), bytes=$($sim.FreedBytes))"

    $actual = Remove-SafeDirectoryContents -Path $realDir -MinAgeMinutes 60 -Label 'SandboxTemp'
    Assert-True (-not (Test-Path $oldFile) -and (Test-Path $newFile) -and (Test-Path (Join-Path $realDir 'a.bin'))) "Remove-SafeDirectoryContents deletes old files and preserves newer files"
    Assert-True ($actual.FreedBytes -eq 4096) "Remove-SafeDirectoryContents reports exact freed bytes ($($actual.FreedBytes))"

    # 4. Deterministic Rule Engine tests using synthetic context (zero AI, zero real user mutation)
    $fakeRoot = Join-Path $sandbox 'fake-pc'
    $fakeUser = Join-Path $fakeRoot 'Users\tester'
    $fakeLocal = Join-Path $fakeUser 'AppData\Local'
    $fakeRoaming = Join-Path $fakeUser 'AppData\Roaming'
    $fakeProgData = Join-Path $fakeRoot 'ProgramData'
    $fakeWin = Join-Path $fakeRoot 'Windows'
    $fakePF = Join-Path $fakeRoot 'Program Files'

    New-Item -ItemType Directory -Path `
        (Join-Path $fakeLocal 'Temp'),
        (Join-Path $fakeWin 'Temp'),
        (Join-Path $fakeLocal 'Google\Chrome\User Data\Profile 1\Code Cache'),
        (Join-Path $fakeUser '.gradle'),
        (Join-Path $fakeLocal 'Pub'),
        (Join-Path $fakeUser '.cache'),
        (Join-Path $fakeUser 'Documents'),
        (Join-Path $fakeUser 'Downloads'),
        (Join-Path $fakeUser 'OneDrive\Documents\Adobe\Premiere Pro\14.0\Adobe Premiere Pro Video Previews'),
        (Join-Path $sandbox 'whisper-ext') -Force | Out-Null

    $oldTemp = Join-Path $fakeLocal 'Temp\stale.tmp'
    [System.IO.File]::WriteAllBytes($oldTemp, (New-Object byte[] (2MB)))
    (Get-Item $oldTemp).LastWriteTime = (Get-Date).AddHours(-3)
    # Fresh file only in Windows\Temp ensures Get-AgedDirectorySizeBytes handles 0 matching files safely
    [System.IO.File]::WriteAllBytes((Join-Path $fakeWin 'Temp\fresh.tmp'), (New-Object byte[] (2MB)))

    [System.IO.File]::WriteAllBytes((Join-Path $fakeLocal 'Google\Chrome\User Data\Profile 1\Code Cache\js.bin'), (New-Object byte[] (2MB)))
    [System.IO.File]::WriteAllBytes((Join-Path $fakeLocal 'Google\Chrome\User Data\Profile 1\Cookies'), (New-Object byte[] 1024))
    [System.IO.File]::WriteAllBytes((Join-Path $fakeUser '.gradle\cache.bin'), (New-Object byte[] (60MB)))
    [System.IO.File]::WriteAllBytes((Join-Path $fakeLocal 'Pub\oldpub.bin'), (New-Object byte[] (3MB)))
    New-Item -ItemType Junction -Path (Join-Path $fakeUser '.cache\whisper') -Target (Join-Path $sandbox 'whisper-ext') | Out-Null
    [System.IO.File]::WriteAllBytes((Join-Path $fakeUser 'OneDrive\Documents\Adobe\Premiere Pro\14.0\Adobe Premiere Pro Video Previews\render.prv'), (New-Object byte[] (55MB)))

    $oldExe = Join-Path $fakeUser 'Downloads\setup.exe'
    $oldPdf = Join-Path $fakeUser 'Downloads\notes.pdf'
    [System.IO.File]::WriteAllBytes($oldExe, (New-Object byte[] (30MB)))
    [System.IO.File]::WriteAllBytes($oldPdf, (New-Object byte[] (30MB)))
    (Get-Item $oldExe).LastWriteTime = (Get-Date).AddDays(-45)
    (Get-Item $oldPdf).LastWriteTime = (Get-Date).AddDays(-45)

    $ctx = @{
        SystemDrive      = 'C:'
        SystemRoot       = $fakeWin
        UserProfile      = $fakeUser
        LocalAppData     = $fakeLocal
        AppData          = $fakeRoaming
        ProgramData      = $fakeProgData
        ProgramFiles     = $fakePF
        ProgramFilesX86  = ''
        UseLiveRegistry  = $false
        UseLiveEnvVars   = $false
        EnvOverrides     = @{ PUB_CACHE = 'D:\Dev\pub-cache' }
    }

    $decisions = @(Get-DiskCleanupRecommendations -MinItemSizeMB 1 -MinRelocateSizeMB 50 -Context $ctx)
    $byId = @{}
    foreach ($d in $decisions) { $byId[$d.Id] = $d }

    Assert-True ($byId.ContainsKey('temp.user') -and $byId['temp.user'].NeededStatus -eq 'NotNeeded') "Rule engine classifies aged Temp as NotNeeded"
    Assert-True ($byId.ContainsKey('browser.chrome.Profile 1.Code Cache') -and $byId['browser.chrome.Profile 1.Code Cache'].NeededStatus -eq 'NotNeeded') "Rule engine discovers multi-profile Chrome Code Cache as NotNeeded"
    Assert-True ($byId.ContainsKey('relocate.gradle') -and $byId['relocate.gradle'].NeededStatus -eq 'NeededMoveOffC') "Rule engine classifies large .gradle as NeededMoveOffC"
    Assert-True ($byId.ContainsKey('pkg.stale_pub') -and $byId['pkg.stale_pub'].NeededStatus -eq 'NotNeeded') "Rule engine detects stale C: Pub cache when PUB_CACHE points to D:"
    Assert-True ($byId.ContainsKey('relocate.whisper') -and $byId['relocate.whisper'].NeededStatus -eq 'NeededKeep' -and $byId['relocate.whisper'].SizeBytes -eq 0) "Rule engine recognizes junctioned .cache\whisper as NeededKeep (0 bytes)"
    Assert-True ($byId.ContainsKey('review.premiere.14.0') -and $byId['review.premiere.14.0'].NeededStatus -eq 'OptionalReview') "Rule engine classifies Premiere Video Previews as OptionalReview"
    Assert-True ($byId.ContainsKey('review.downloads.installers') -and $byId['review.downloads.installers'].TargetPaths.Count -eq 1 -and $byId['review.downloads.installers'].TargetPaths[0] -eq $oldExe) "Rule engine flags old .exe in Downloads while excluding .pdf"
    Assert-True ($byId.ContainsKey('protected.documents') -and $byId['protected.documents'].NeededStatus -eq 'NeededKeep') "Rule engine marks personal Documents folder as NeededKeep"

    # 5. Script end-to-end smoke checks
    $jsonOut = & (Join-Path $repoRoot 'scripts\Analyze-DiskSpace.ps1') -TargetDrive $sandbox -Top 3 -Quick -AsJson | Out-String
    $parsed = $jsonOut | ConvertFrom-Json
    Assert-True ($null -ne $parsed -and @($parsed.Drives).Count -ge 1 -and @($parsed.TopDriveFolders).Count -ge 1) "Analyze-DiskSpace.ps1 -AsJson produces valid JSON"

    & (Join-Path $repoRoot 'scripts\Invoke-UserCleanup.ps1') -Categories Temp -WhatIf | Out-Null
    Assert-True ($?) "Invoke-UserCleanup.ps1 -WhatIf executes cleanly"

    & (Join-Path $repoRoot 'scripts\Move-CacheToDrive.ps1') -DestinationRoot (Join-Path $sandbox 'Dest') -Keys gradle -WhatIf | Out-Null
    Assert-True ($?) "Move-CacheToDrive.ps1 -WhatIf executes cleanly"

    & (Join-Path $repoRoot 'Optimize-Disk.ps1') -Mode AutoSafe -SkipInstallerAudit -WhatIf *>$null
    Assert-True ($?) "Optimize-Disk.ps1 -Mode AutoSafe -WhatIf executes cleanly"

    & (Join-Path $repoRoot 'Optimize-Disk.ps1') -Mode Report | Out-Null
    Assert-True ($?) "Optimize-Disk.ps1 -Mode Report with installer audit executes cleanly"
} finally {
    if (Test-Path -LiteralPath $sandbox) {
        # Remove junctions inside sandbox before recursive delete
        Get-ChildItem -LiteralPath $sandbox -Force -Recurse -Directory -ErrorAction SilentlyContinue |
            Where-Object { $_.Attributes -band [System.IO.FileAttributes]::ReparsePoint } |
            ForEach-Object { [System.IO.Directory]::Delete($_.FullName) }
        Remove-Item -LiteralPath $sandbox -Recurse -Force -ErrorAction SilentlyContinue
    }
}

Write-Host ("`nTest Summary: {0} passed, {1} failed" -f $script:Passed, $script:Failed) -ForegroundColor Cyan
if ($script:Failed -gt 0) {
    exit 1
}
