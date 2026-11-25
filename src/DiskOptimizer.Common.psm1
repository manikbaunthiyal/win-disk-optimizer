Set-StrictMode -Version Latest

function Test-IsAdministrator {
    <#
    .SYNOPSIS
        Returns $true if the current PowerShell process has Administrator privileges.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param()

    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($identity)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Get-DriveUsageSummary {
    <#
    .SYNOPSIS
        Returns used, free, and total GB for local FileSystem drives.
    #>
    [CmdletBinding()]
    param(
        [string[]]$DriveLetters
    )

    $drives = Get-PSDrive -PSProvider FileSystem | Where-Object {
        $_.Used -ne $null -and $_.Free -ne $null -and (
            -not $DriveLetters -or $DriveLetters -contains $_.Name
        )
    }

    foreach ($d in $drives) {
        $total = $d.Used + $d.Free
        $freePct = if ($total -gt 0) { [math]::Round(($d.Free / $total) * 100, 1) } else { 0 }
        [PSCustomObject]@{
            Drive       = "$($d.Name):"
            UsedGB      = [math]::Round($d.Used / 1GB, 2)
            FreeGB      = [math]::Round($d.Free / 1GB, 2)
            TotalGB     = [math]::Round($total / 1GB, 2)
            FreePercent = $freePct
        }
    }
}

function Get-DirectorySizeFast {
    <#
    .SYNOPSIS
        Fast iterative directory size calculation in bytes, skipping reparse points (junctions/symlinks).
    #>
    [CmdletBinding()]
    [OutputType([int64])]
    param(
        [Parameter(Mandatory)]
        [string]$Path
    )

    if (-not (Test-Path -LiteralPath $Path)) {
        return [int64]0
    }

    $rootInfo = Get-Item -LiteralPath $Path -Force -ErrorAction SilentlyContinue
    if ($null -eq $rootInfo -or ($rootInfo.Attributes -band [System.IO.FileAttributes]::ReparsePoint)) {
        return [int64]0
    }

    $total = [int64]0
    $stack = New-Object 'System.Collections.Generic.Stack[string]'
    $stack.Push($Path)

    while ($stack.Count -gt 0) {
        $curr = $stack.Pop()
        try {
            $di = [System.IO.DirectoryInfo]::new($curr)
            if ($di.Attributes -band [System.IO.FileAttributes]::ReparsePoint) { continue }

            foreach ($f in $di.EnumerateFiles()) {
                $total += $f.Length
            }
            foreach ($d in $di.EnumerateDirectories()) {
                if (-not ($d.Attributes -band [System.IO.FileAttributes]::ReparsePoint)) {
                    $stack.Push($d.FullName)
                }
            }
        } catch {
            # Access-denied folders (e.g., System Volume Information, WindowsApps) are skipped cleanly.
        }
    }

    return $total
}

function Get-SubfolderSizes {
    <#
    .SYNOPSIS
        Lists immediate subdirectories under Root sorted by size descending.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Root,

        [int]$Top = 15
    )

    if (-not (Test-Path -LiteralPath $Root)) {
        return @()
    }

    $dirs = Get-ChildItem -LiteralPath $Root -Force -Directory -ErrorAction SilentlyContinue
    $items = foreach ($d in $dirs) {
        if ($d.Attributes -band [System.IO.FileAttributes]::ReparsePoint) { continue }
        $bytes = Get-DirectorySizeFast -Path $d.FullName
        [PSCustomObject]@{
            Name      = $d.Name
            FullName  = $d.FullName
            SizeBytes = $bytes
            SizeMB    = [math]::Round($bytes / 1MB, 1)
            SizeGB    = [math]::Round($bytes / 1GB, 2)
        }
    }

    return ($items | Sort-Object SizeBytes -Descending | Select-Object -First $Top)
}

function Get-MsiPackageProductName {
    <#
    .SYNOPSIS
        Reads the target or product name embedded inside an .msi or .msp file.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [object]$InstallerCom,

        [Parameter(Mandatory)]
        [string]$FilePath
    )

    $ext = [System.IO.Path]::GetExtension($FilePath).ToLowerInvariant()
    if ($ext -eq '.msp') {
        try {
            $db = $InstallerCom.OpenDatabase($FilePath, 32) # msiOpenDatabaseModePatchFile + ReadOnly
            $view = $db.OpenView("SELECT Property, Value FROM MsiPatchMetadata")
            $view.Execute()
            $target = $null
            $display = $null
            while ($row = $view.Fetch()) {
                $key = $row.StringData(1)
                if ($key -eq 'TargetProductName') { $target = $row.StringData(2) }
                elseif ($key -eq 'DisplayName') { $display = $row.StringData(2) }
            }
            if (-not [string]::IsNullOrWhiteSpace($target)) { return [string]$target }
            if (-not [string]::IsNullOrWhiteSpace($display)) { return [string]$display }
        } catch {}
    } else {
        try {
            $db = $InstallerCom.OpenDatabase($FilePath, 0) # msiOpenDatabaseModeReadOnly
            $view = $db.OpenView("SELECT Value FROM Property WHERE Property='ProductName'")
            $view.Execute()
            $row = $view.Fetch()
            if ($row) {
                $val = $row.StringData(1)
                if (-not [string]::IsNullOrWhiteSpace($val)) { return [string]$val }
            }
        } catch {}
    }

    return '(unknown)'
}

function Get-OrphanedWindowsInstallers {
    <#
    .SYNOPSIS
        Identifies .msi and .msp files in Windows\Installer that are no longer registered
        with any installed Windows Installer product or patch.
    #>
    [CmdletBinding()]
    param(
        [switch]$IncludeMetadata,
        [string]$InstallerDir = (Join-Path $env:SystemRoot 'Installer')
    )

    if (-not (Test-Path -LiteralPath $InstallerDir)) {
        return @()
    }

    $wi = New-Object -ComObject WindowsInstaller.Installer
    $known = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::OrdinalIgnoreCase)

    foreach ($prod in $wi.ProductsEx('', '', 7)) {
        try {
            $lp = $prod.InstallProperty('LocalPackage')
            if ($lp) { [void]$known.Add($lp) }
        } catch {}
    }

    foreach ($patch in $wi.PatchesEx('', '', 7, 15)) {
        try {
            $lp = $patch.PatchProperty('LocalPackage')
            if ($lp) { [void]$known.Add($lp) }
        } catch {}
    }

    foreach ($regGlob in @(
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Installer\UserData\*\Patches\*',
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Installer\UserData\*\Products\*\InstallProperties'
    )) {
        Get-ChildItem -Path $regGlob -ErrorAction SilentlyContinue | ForEach-Object {
            $props = Get-ItemProperty -LiteralPath $_.PSPath -ErrorAction SilentlyContinue
            if ($props -and $props.PSObject.Properties['LocalPackage'] -and $props.LocalPackage) {
                [void]$known.Add([string]$props.LocalPackage)
            }
        }
    }

    $files = Get-ChildItem -LiteralPath $InstallerDir -Force -File -ErrorAction SilentlyContinue |
        Where-Object { $_.Extension -in '.msi', '.msp' -and -not $known.Contains($_.FullName) } |
        Sort-Object Length -Descending

    foreach ($f in $files) {
        $productName = if ($IncludeMetadata) {
            Get-MsiPackageProductName -InstallerCom $wi -FilePath $f.FullName
        } else {
            $null
        }

        [PSCustomObject]@{
            Name          = $f.Name
            FullName      = $f.FullName
            SizeBytes     = $f.Length
            SizeMB        = [math]::Round($f.Length / 1MB, 1)
            LastWriteTime = $f.LastWriteTime
            ProductName   = $productName
        }
    }
}

function Test-IsProtectedPath {
    <#
    .SYNOPSIS
        Returns $true if Path is a critical OS, personal library, or browser profile root
        that automated directory deletion must never wipe.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)]
        [string]$Path
    )

    try {
        $norm = [System.IO.Path]::GetFullPath($Path).TrimEnd('\')
    } catch {
        return $true
    }

    if ($norm -match '^[A-Za-z]:$') { return $true }

    $protectedRoots = @(
        $env:SystemRoot,
        (Join-Path $env:SystemRoot 'System32'),
        (Join-Path $env:SystemRoot 'SysWOW64'),
        (Join-Path $env:SystemRoot 'WinSxS'),
        (Join-Path $env:SystemRoot 'Installer'),
        $env:ProgramFiles,
        ${env:ProgramFiles(x86)},
        $env:ProgramData,
        (Split-Path -Parent $env:USERPROFILE),
        $env:USERPROFILE,
        (Join-Path $env:USERPROFILE 'Documents'),
        (Join-Path $env:USERPROFILE 'Desktop'),
        (Join-Path $env:USERPROFILE 'Pictures'),
        (Join-Path $env:USERPROFILE 'Music'),
        (Join-Path $env:USERPROFILE 'Videos'),
        (Join-Path $env:USERPROFILE 'Downloads'),
        (Join-Path $env:USERPROFILE 'OneDrive'),
        (Join-Path $env:USERPROFILE 'OneDrive\Documents'),
        (Join-Path $env:USERPROFILE 'OneDrive\Desktop'),
        (Join-Path $env:USERPROFILE 'OneDrive\Pictures'),
        $env:LOCALAPPDATA,
        $env:APPDATA
    ) | Where-Object { $_ } | ForEach-Object { [System.IO.Path]::GetFullPath($_).TrimEnd('\') }

    foreach ($p in $protectedRoots) {
        if ($norm.Equals($p, [System.StringComparison]::OrdinalIgnoreCase)) {
            return $true
        }
    }

    # Never wipe an entire Chromium User Data root or Profile root directly.
    if ($norm -match '\\User Data(\\(Default|Profile \d+))?$') {
        return $true
    }

    return $false
}

function Test-PathWritable {
    <#
    .SYNOPSIS
        Checks whether the current process token holds effective delete/write rights on Path.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)]
        [string]$Path
    )

    if (Test-IsAdministrator) { return $true }
    if (-not (Test-Path -LiteralPath $Path)) { return $false }

    try {
        $acl = Get-Acl -LiteralPath $Path -ErrorAction Stop
        $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
        $principal = New-Object Security.Principal.WindowsPrincipal($identity)

        $allowWrite = $false
        $denyWrite = $false
        $writeMask = [System.Security.AccessControl.FileSystemRights]::Delete -bor
                     [System.Security.AccessControl.FileSystemRights]::WriteData -bor
                     [System.Security.AccessControl.FileSystemRights]::Modify -bor
                     [System.Security.AccessControl.FileSystemRights]::FullControl

        foreach ($rule in $acl.GetAccessRules($true, $true, [Security.Principal.SecurityIdentifier])) {
            $sid = $rule.IdentityReference -as [Security.Principal.SecurityIdentifier]
            if (-not $sid -or -not $principal.IsInRole($sid)) { continue }
            if ($rule.FileSystemRights -band $writeMask) {
                if ($rule.AccessControlType -eq [System.Security.AccessControl.AccessControlType]::Deny) {
                    $denyWrite = $true
                } else {
                    $allowWrite = $true
                }
            }
        }
        return ($allowWrite -and -not $denyWrite)
    } catch {
        return $false
    }
}

function Get-BestRelocationDrive {
    <#
    .SYNOPSIS
        Returns non-system fixed local drives sorted by free space descending (preferring NTFS).
    #>
    [CmdletBinding()]
    param()

    $sysDrive = $env:SystemDrive.TrimEnd('\')
    $disks = Get-CimInstance -ClassName Win32_LogicalDisk -Filter 'DriveType=3' -ErrorAction SilentlyContinue |
        Where-Object { $_.DeviceID -and -not $_.DeviceID.Equals($sysDrive, [System.StringComparison]::OrdinalIgnoreCase) }

    $results = foreach ($d in $disks) {
        $isNtfs = ($d.FileSystem -eq 'NTFS')
        [PSCustomObject]@{
            DriveLetter = $d.DeviceID
            Root        = "$($d.DeviceID)\"
            FileSystem  = $d.FileSystem
            IsNtfs      = $isNtfs
            FreeBytes   = [int64]$d.FreeSpace
            FreeGB      = [math]::Round($d.FreeSpace / 1GB, 2)
            TotalGB     = [math]::Round($d.Size / 1GB, 2)
        }
    }

    return @($results | Sort-Object IsNtfs, FreeBytes -Descending)
}

function Get-PropertySum {
    <#
    .SYNOPSIS
        Safely sums a numeric property across zero, one, or many items under Set-StrictMode.
    #>
    [CmdletBinding()]
    [OutputType([int64])]
    param(
        [AllowEmptyCollection()]
        [object[]]$Items = @(),

        [Parameter(Mandatory)]
        [string]$Property
    )

    $total = [int64]0
    foreach ($it in $Items) {
        if ($null -eq $it) { continue }
        $prop = $it.PSObject.Properties[$Property]
        if ($prop -and $null -ne $prop.Value) {
            $total += [int64]$prop.Value
        }
    }
    return $total
}

function Group-InstallersByProduct {
    <#
    .SYNOPSIS
        Groups orphaned Windows Installer objects by ProductName safely without Group-Object null issues.
    #>
    [CmdletBinding()]
    param(
        [AllowEmptyCollection()]
        [object[]]$Orphans = @()
    )

    $groups = @{}
    foreach ($o in $Orphans) {
        if ($null -eq $o) { continue }
        $pname = if ([string]::IsNullOrWhiteSpace($o.ProductName)) { '(unknown)' } else { [string]$o.ProductName }
        if (-not $groups.ContainsKey($pname)) {
            $groups[$pname] = @{ Count = 0; Bytes = [int64]0 }
        }
        $groups[$pname].Count++
        $groups[$pname].Bytes += [int64]$o.SizeBytes
    }

    $rows = foreach ($kv in $groups.GetEnumerator()) {
        [PSCustomObject]@{
            ProductName = $kv.Key
            Count       = $kv.Value.Count
            SizeBytes   = $kv.Value.Bytes
            SizeGB      = [math]::Round($kv.Value.Bytes / 1GB, 2)
        }
    }
    return @($rows | Sort-Object SizeBytes -Descending)
}

function Invoke-VerifiedDirectoryCopy {
    <#
    .SYNOPSIS
        Copies From -> To using robocopy and verifies file count and total bytes match.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$From,
        [Parameter(Mandatory)][string]$To
    )

    if (-not (Test-Path -LiteralPath $To)) {
        New-Item -ItemType Directory -Path $To -Force | Out-Null
    }

    $srcFiles = @(Get-ChildItem -LiteralPath $From -Force -Recurse -File -ErrorAction SilentlyContinue)
    $srcCount = [int64]$srcFiles.Count
    $srcBytes = Get-PropertySum -Items $srcFiles -Property 'Length'

    & robocopy $From $To /E /COPY:DAT /R:1 /W:1 /MT:8 /NFL /NDL /NJH /NJS /NC /NS /NP | Out-Null
    if ($LASTEXITCODE -ge 8) {
        throw "robocopy failed ($From -> $To) with exit code $LASTEXITCODE. Source left untouched."
    }

    $dstFiles = @(Get-ChildItem -LiteralPath $To -Force -Recurse -File -ErrorAction SilentlyContinue)
    $dstCount = [int64]$dstFiles.Count
    $dstBytes = Get-PropertySum -Items $dstFiles -Property 'Length'

    if ($dstCount -lt $srcCount -or $dstBytes -lt $srcBytes) {
        throw "Verification mismatch ($From -> $To): src=$srcCount/$srcBytes, dst=$dstCount/$dstBytes. Source left untouched."
    }

    return [PSCustomObject]@{ Files = $srcCount; Bytes = $srcBytes }
}

function Remove-SafeDirectoryContents {
    <#
    .SYNOPSIS
        Deletes files inside Path (optionally older than MinAgeMinutes), skipping locked files
        and pruning empty subdirectories. Refuses protected OS/user paths. Supports -WhatIf.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)]
        [string]$Path,

        [int]$MinAgeMinutes = 0,

        [string]$Label = $Path
    )

    if (Test-IsProtectedPath -Path $Path) {
        throw "Refusing to delete contents of protected path: $Path"
    }

    if (-not (Test-Path -LiteralPath $Path)) {
        return [PSCustomObject]@{
            Label         = $Label
            Path          = $Path
            FreedBytes    = [int64]0
            FreedMB       = 0.0
            FilesDeleted  = 0
            SkippedLocked = 0
        }
    }

    $rootItem = Get-Item -LiteralPath $Path -Force -ErrorAction SilentlyContinue
    if ($null -eq $rootItem -or ($rootItem.Attributes -band [System.IO.FileAttributes]::ReparsePoint)) {
        return [PSCustomObject]@{
            Label         = $Label
            Path          = $Path
            FreedBytes    = [int64]0
            FreedMB       = 0.0
            FilesDeleted  = 0
            SkippedLocked = 0
        }
    }

    $cutoff = (Get-Date).AddMinutes(-$MinAgeMinutes)
    $files = Get-ChildItem -LiteralPath $Path -Force -Recurse -File -ErrorAction SilentlyContinue |
        Where-Object { $MinAgeMinutes -le 0 -or $_.LastWriteTime -lt $cutoff }

    $freed = [int64]0
    $deletedCount = 0
    $lockedCount = 0

    foreach ($f in $files) {
        $len = $f.Length
        if ($PSCmdlet.ShouldProcess($f.FullName, 'Delete file')) {
            try {
                [System.IO.File]::Delete($f.FullName)
                $freed += $len
                $deletedCount++
            } catch {
                $lockedCount++
            }
        } else {
            # Account simulated savings under -WhatIf without deleting anything.
            $freed += $len
            $deletedCount++
        }
    }

    if (-not $WhatIfPreference) {
        Get-ChildItem -LiteralPath $Path -Force -Recurse -Directory -ErrorAction SilentlyContinue |
            Where-Object { -not ($_.Attributes -band [System.IO.FileAttributes]::ReparsePoint) } |
            Sort-Object { $_.FullName.Length } -Descending |
            ForEach-Object {
                try {
                    if (@(Get-ChildItem -LiteralPath $_.FullName -Force -ErrorAction SilentlyContinue).Count -eq 0) {
                        Remove-Item -LiteralPath $_.FullName -Force -ErrorAction SilentlyContinue
                    }
                } catch {}
            }
    }

    return [PSCustomObject]@{
        Label         = $Label
        Path          = $Path
        FreedBytes    = $freed
        FreedMB       = [math]::Round($freed / 1MB, 1)
        FilesDeleted  = $deletedCount
        SkippedLocked = $lockedCount
    }
}

function Get-KnownCacheTargets {
    <#
    .SYNOPSIS
        Returns standardized, user-agnostic Windows cleanup target definitions by category.
    #>
    [CmdletBinding()]
    param()

    $local = $env:LOCALAPPDATA
    $roaming = $env:APPDATA
    $progData = $env:ProgramData
    $winTemp = Join-Path $env:SystemRoot 'Temp'

    return @(
        @{ Category = 'Temp'; Label = 'User Temp'; Path = (Join-Path $local 'Temp'); MinAgeMinutes = 60; ProcessGuard = @() }
        @{ Category = 'Temp'; Label = 'Windows Temp'; Path = $winTemp; MinAgeMinutes = 60; ProcessGuard = @() }

        @{ Category = 'CrashDumps'; Label = 'User CrashDumps'; Path = (Join-Path $local 'CrashDumps'); MinAgeMinutes = 0; ProcessGuard = @() }

        @{ Category = 'DevCaches'; Label = 'npm cache'; Path = (Join-Path $local 'npm-cache'); MinAgeMinutes = 0; ProcessGuard = @('node') }
        @{ Category = 'DevCaches'; Label = 'pip cache'; Path = (Join-Path $local 'pip\cache'); MinAgeMinutes = 0; ProcessGuard = @() }

        @{ Category = 'IdeCaches'; Label = 'VS Code Cache'; Path = (Join-Path $roaming 'Code\Cache'); MinAgeMinutes = 0; ProcessGuard = @('Code') }
        @{ Category = 'IdeCaches'; Label = 'VS Code CachedData'; Path = (Join-Path $roaming 'Code\CachedData'); MinAgeMinutes = 0; ProcessGuard = @('Code') }
        @{ Category = 'IdeCaches'; Label = 'VS Code CachedExtensionVSIXs'; Path = (Join-Path $roaming 'Code\CachedExtensionVSIXs'); MinAgeMinutes = 0; ProcessGuard = @('Code') }
        @{ Category = 'IdeCaches'; Label = 'VS Code GPUCache'; Path = (Join-Path $roaming 'Code\GPUCache'); MinAgeMinutes = 0; ProcessGuard = @('Code') }

        @{ Category = 'BrowserCaches'; Label = 'Edge Cache'; Path = (Join-Path $local 'Microsoft\Edge\User Data\Default\Cache'); MinAgeMinutes = 0; ProcessGuard = @('msedge') }
        @{ Category = 'BrowserCaches'; Label = 'Edge Code Cache'; Path = (Join-Path $local 'Microsoft\Edge\User Data\Default\Code Cache'); MinAgeMinutes = 0; ProcessGuard = @('msedge') }
        @{ Category = 'BrowserCaches'; Label = 'Chrome Cache'; Path = (Join-Path $local 'Google\Chrome\User Data\Default\Cache'); MinAgeMinutes = 0; ProcessGuard = @('chrome') }
        @{ Category = 'BrowserCaches'; Label = 'Chrome Code Cache'; Path = (Join-Path $local 'Google\Chrome\User Data\Default\Code Cache'); MinAgeMinutes = 0; ProcessGuard = @('chrome') }
        @{ Category = 'BrowserCaches'; Label = 'Brave Cache'; Path = (Join-Path $local 'BraveSoftware\Brave-Browser\User Data\Default\Cache'); MinAgeMinutes = 0; ProcessGuard = @('brave') }
        @{ Category = 'BrowserCaches'; Label = 'Brave Code Cache'; Path = (Join-Path $local 'BraveSoftware\Brave-Browser\User Data\Default\Code Cache'); MinAgeMinutes = 0; ProcessGuard = @('brave') }

        @{ Category = 'LauncherCaches'; Label = 'Steam htmlcache Cache'; Path = (Join-Path $local 'Steam\htmlcache\Default\Cache'); MinAgeMinutes = 0; ProcessGuard = @('steam', 'steamwebhelper') }
        @{ Category = 'LauncherCaches'; Label = 'Steam htmlcache Code Cache'; Path = (Join-Path $local 'Steam\htmlcache\Default\Code Cache'); MinAgeMinutes = 0; ProcessGuard = @('steam', 'steamwebhelper') }
        @{ Category = 'LauncherCaches'; Label = 'Steam GrShaderCache'; Path = (Join-Path $local 'Steam\htmlcache\GrShaderCache'); MinAgeMinutes = 0; ProcessGuard = @('steam', 'steamwebhelper') }
        @{ Category = 'LauncherCaches'; Label = 'Epic Launcher Cache'; Path = (Join-Path $local 'EpicGamesLauncher\Saved\webcache_4430\Cache'); MinAgeMinutes = 0; ProcessGuard = @('EpicGamesLauncher') }
        @{ Category = 'LauncherCaches'; Label = 'Epic Launcher Code Cache'; Path = (Join-Path $local 'EpicGamesLauncher\Saved\webcache_4430\Code Cache'); MinAgeMinutes = 0; ProcessGuard = @('EpicGamesLauncher') }
        @{ Category = 'LauncherCaches'; Label = 'Discord Cache'; Path = (Join-Path $roaming 'discord\Cache'); MinAgeMinutes = 0; ProcessGuard = @('Discord') }
        @{ Category = 'LauncherCaches'; Label = 'Discord Code Cache'; Path = (Join-Path $roaming 'discord\Code Cache'); MinAgeMinutes = 0; ProcessGuard = @('Discord') }
        @{ Category = 'LauncherCaches'; Label = 'Discord Download Cache'; Path = (Join-Path $local 'Discord\download'); MinAgeMinutes = 0; ProcessGuard = @('Discord') }

        @{ Category = 'UpdaterCaches'; Label = 'Adobe ARM Update Cache'; Path = (Join-Path $progData 'Adobe\ARM'); MinAgeMinutes = 0; ProcessGuard = @('AdobeARM') }
        @{ Category = 'UpdaterCaches'; Label = 'PowerToys Updates Cache'; Path = (Join-Path $local 'Microsoft\PowerToys\Updates'); MinAgeMinutes = 0; ProcessGuard = @() }
    )
}

function Get-RelocatableCacheTargets {
    <#
    .SYNOPSIS
        Returns large dev/AI cache definitions that can be safely moved to a secondary drive.
    #>
    [CmdletBinding()]
    param()

    $homeDir = $env:USERPROFILE
    $local = $env:LOCALAPPDATA

    return @(
        @{ Key = 'gradle';      Label = 'Gradle Cache & Wrapper'; Source = (Join-Path $homeDir '.gradle');             DefaultSubdir = 'Dev\.gradle';           EnvVar = 'GRADLE_USER_HOME' }
        @{ Key = 'huggingface'; Label = 'Hugging Face Hub Cache'; Source = (Join-Path $homeDir '.cache\huggingface'); DefaultSubdir = 'AI\huggingface-cache';  EnvVar = 'HF_HOME' }
        @{ Key = 'whisper';     Label = 'OpenAI Whisper Cache';   Source = (Join-Path $homeDir '.cache\whisper');     DefaultSubdir = 'AI\whisper-cache';      EnvVar = $null }
        @{ Key = 'uv';          Label = 'uv Package Cache';       Source = (Join-Path $local 'uv\cache');             DefaultSubdir = 'Dev\uv-cache';          EnvVar = 'UV_CACHE_DIR' }
        @{ Key = 'pub';         Label = 'Dart/Flutter Pub Cache'; Source = (Join-Path $local 'Pub\Cache');            DefaultSubdir = 'Dev\pub-cache';         EnvVar = 'PUB_CACHE' }
    )
}

Export-ModuleMember -Function @(
    'Test-IsAdministrator',
    'Test-IsProtectedPath',
    'Test-PathWritable',
    'Get-BestRelocationDrive',
    'Get-PropertySum',
    'Group-InstallersByProduct',
    'Invoke-VerifiedDirectoryCopy',
    'Get-DriveUsageSummary',
    'Get-DirectorySizeFast',
    'Get-SubfolderSizes',
    'Get-MsiPackageProductName',
    'Get-OrphanedWindowsInstallers',
    'Remove-SafeDirectoryContents',
    'Get-KnownCacheTargets',
    'Get-RelocatableCacheTargets'
)
