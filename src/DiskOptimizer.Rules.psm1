Set-StrictMode -Version Latest

$commonModule = Join-Path $PSScriptRoot 'DiskOptimizer.Common.psm1'
Import-Module $commonModule -Global

function Get-DefaultSystemContext {
    <#
    .SYNOPSIS
        Returns standard Windows environment paths (overridable in automated tests).
    #>
    [CmdletBinding()]
    param()

    return @{
        SystemDrive      = $env:SystemDrive
        SystemRoot       = $env:SystemRoot
        UserProfile      = $env:USERPROFILE
        LocalAppData     = $env:LOCALAPPDATA
        AppData          = $env:APPDATA
        ProgramData      = $env:ProgramData
        ProgramFiles     = $env:ProgramFiles
        ProgramFilesX86  = ${env:ProgramFiles(x86)}
        UseLiveRegistry  = $true
        UseLiveEnvVars   = $true
        EnvOverrides     = @{}
    }
}

function New-RuleDecision {
    <#
    .SYNOPSIS
        Constructs a normalized cleanup/optimization classification record.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Id,
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][string]$Category,
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][int64]$SizeBytes,
        [Parameter(Mandatory)][ValidateSet('NotNeeded', 'NeededMoveOffC', 'OptionalReview', 'NeededKeep')][string]$NeededStatus,
        [Parameter(Mandatory)][ValidateSet('Delete', 'MoveToSecondaryDrive', 'AdminCleanup', 'ReviewPrompt', 'Keep')][string]$RecommendedAction,
        [Parameter(Mandatory)][ValidateSet('High', 'Medium')][string]$Confidence,
        [Parameter(Mandatory)][string]$Reason,
        [ValidateSet('Directory', 'FileList', 'OrphanedInstallers', 'SystemComponent')][string]$ItemType = 'Directory',
        [bool]$RequiresAdmin = $false,
        [int]$MinAgeMinutes = 0,
        [string[]]$ProcessGuard = @(),
        [string]$EnvVar = '',
        [string]$RelocateSubdir = '',
        [string[]]$TargetPaths = @()
    )

    return [PSCustomObject]@{
        Id                = $Id
        Name              = $Name
        Category          = $Category
        Path              = $Path
        ItemType          = $ItemType
        SizeBytes         = $SizeBytes
        SizeMB            = [math]::Round($SizeBytes / 1MB, 1)
        SizeGB            = [math]::Round($SizeBytes / 1GB, 2)
        NeededStatus      = $NeededStatus
        RecommendedAction = $RecommendedAction
        Confidence        = $Confidence
        RequiresAdmin     = $RequiresAdmin
        MinAgeMinutes     = $MinAgeMinutes
        ProcessGuard      = $ProcessGuard
        EnvVar            = $EnvVar
        RelocateSubdir    = $RelocateSubdir
        TargetPaths       = $TargetPaths
        Reason            = $Reason
    }
}

function Get-AgedDirectorySizeBytes {
    param(
        [Parameter(Mandatory)][string]$Path,
        [int]$MinAgeMinutes = 0
    )

    if (-not (Test-Path -LiteralPath $Path)) { return [int64]0 }
    if ($MinAgeMinutes -le 0) { return (Get-DirectorySizeFast -Path $Path) }

    $cutoff = (Get-Date).AddMinutes(-$MinAgeMinutes)
    $sum = (Get-ChildItem -LiteralPath $Path -Force -Recurse -File -ErrorAction SilentlyContinue |
        Where-Object { $_.LastWriteTime -lt $cutoff } |
        Measure-Object Length -Sum).Sum
    if ($sum) { return [int64]$sum }
    return [int64]0
}

function Get-TempAndCrashDecisions {
    param(
        [Parameter(Mandatory)][hashtable]$Context,
        [int]$MinTempAgeMinutes,
        [int64]$MinBytes
    )

    $items = @(
        @{ Id = 'temp.user';       Name = 'User Temporary Files';        Cat = 'Temp';       Path = (Join-Path $Context.LocalAppData 'Temp'); Age = $MinTempAgeMinutes; Reason = "Temporary files older than $MinTempAgeMinutes min; Windows and apps recreate them if needed." }
        @{ Id = 'temp.windows';    Name = 'Windows Temporary Files';     Cat = 'Temp';       Path = (Join-Path $Context.SystemRoot 'Temp');   Age = $MinTempAgeMinutes; Reason = "System temp files older than $MinTempAgeMinutes min; safe to purge." }
        @{ Id = 'crash.user';      Name = 'User Crash Dumps';            Cat = 'CrashDumps'; Path = (Join-Path $Context.LocalAppData 'CrashDumps'); Age = 0; Reason = 'Diagnostic crash .dmp snapshots left after application crashes.' }
        @{ Id = 'crash.wer_arch';  Name = 'WER Report Archive';          Cat = 'CrashDumps'; Path = (Join-Path $Context.ProgramData 'Microsoft\Windows\WER\ReportArchive'); Age = 0; Reason = 'Historical Windows Error Reporting archives.' }
        @{ Id = 'crash.wer_queue'; Name = 'WER Report Queue';            Cat = 'CrashDumps'; Path = (Join-Path $Context.ProgramData 'Microsoft\Windows\WER\ReportQueue');   Age = 0; Reason = 'Queued Windows Error Reporting diagnostic bundles.' }
    )

    foreach ($it in $items) {
        if (-not (Test-Path -LiteralPath $it.Path)) { continue }
        $bytes = Get-AgedDirectorySizeBytes -Path $it.Path -MinAgeMinutes $it.Age
        if ($bytes -lt $MinBytes) { continue }

        $needsAdmin = -not (Test-PathWritable -Path $it.Path)
        $action = if ($needsAdmin) { 'AdminCleanup' } else { 'Delete' }
        New-RuleDecision -Id $it.Id -Name $it.Name -Category $it.Cat -Path $it.Path -SizeBytes $bytes `
            -NeededStatus 'NotNeeded' -RecommendedAction $action -Confidence 'High' `
            -RequiresAdmin $needsAdmin -MinAgeMinutes $it.Age -Reason $it.Reason
    }
}

function Get-BrowserCacheDecisions {
    param(
        [Parameter(Mandatory)][hashtable]$Context,
        [int64]$MinBytes
    )

    $browsers = @(
        @{ Key = 'edge';    Label = 'Microsoft Edge'; UserData = (Join-Path $Context.LocalAppData 'Microsoft\Edge\User Data');                  Proc = @('msedge') }
        @{ Key = 'chrome';  Label = 'Google Chrome';  UserData = (Join-Path $Context.LocalAppData 'Google\Chrome\User Data');                   Proc = @('chrome') }
        @{ Key = 'brave';   Label = 'Brave Browser';  UserData = (Join-Path $Context.LocalAppData 'BraveSoftware\Brave-Browser\User Data');     Proc = @('brave') }
        @{ Key = 'vivaldi'; Label = 'Vivaldi';        UserData = (Join-Path $Context.LocalAppData 'Vivaldi\User Data');                         Proc = @('vivaldi') }
        @{ Key = 'opera';   Label = 'Opera';          UserData = (Join-Path $Context.AppData 'Opera Software\Opera Stable');                    Proc = @('opera') }
    )

    $cacheSubdirs = @('Cache', 'Code Cache', 'GPUCache', 'DawnCache', 'GrShaderCache')

    foreach ($b in $browsers) {
        if (-not (Test-Path -LiteralPath $b.UserData)) { continue }

        $profileDirs = @($b.UserData)
        $profileDirs += Get-ChildItem -LiteralPath $b.UserData -Directory -ErrorAction SilentlyContinue |
            Where-Object { $_.Name -eq 'Default' -or $_.Name -like 'Profile *' } |
            ForEach-Object { $_.FullName }

        foreach ($profDir in $profileDirs) {
            $profName = Split-Path -Leaf $profDir
            foreach ($sub in $cacheSubdirs) {
                $target = Join-Path $profDir $sub
                if (-not (Test-Path -LiteralPath $target)) { continue }
                $bytes = Get-DirectorySizeFast -Path $target
                if ($bytes -lt $MinBytes) { continue }

                New-RuleDecision -Id "browser.$($b.Key).$profName.$sub" `
                    -Name "$($b.Label) ($profName) $sub" -Category 'BrowserCache' -Path $target -SizeBytes $bytes `
                    -NeededStatus 'NotNeeded' -RecommendedAction 'Delete' -Confidence 'High' `
                    -ProcessGuard $b.Proc `
                    -Reason 'Reproducible browser HTTP/shader cache; cookies, logins, bookmarks, and history remain untouched.'
            }
        }
    }

    $ffRoot = Join-Path $Context.LocalAppData 'Mozilla\Firefox\Profiles'
    if (Test-Path -LiteralPath $ffRoot) {
        foreach ($prof in (Get-ChildItem -LiteralPath $ffRoot -Directory -ErrorAction SilentlyContinue)) {
            $cache2 = Join-Path $prof.FullName 'cache2'
            if (-not (Test-Path -LiteralPath $cache2)) { continue }
            $bytes = Get-DirectorySizeFast -Path $cache2
            if ($bytes -lt $MinBytes) { continue }

            New-RuleDecision -Id "browser.firefox.$($prof.Name)" `
                -Name "Firefox ($($prof.Name)) cache2" -Category 'BrowserCache' -Path $cache2 -SizeBytes $bytes `
                -NeededStatus 'NotNeeded' -RecommendedAction 'Delete' -Confidence 'High' `
                -ProcessGuard @('firefox') `
                -Reason 'Reproducible Firefox disk cache; bookmarks, passwords, and sessions remain untouched.'
        }
    }
}

function Get-IdeAndLauncherCacheDecisions {
    param(
        [Parameter(Mandatory)][hashtable]$Context,
        [int64]$MinBytes
    )

    $targets = @(
        @{ Id = 'ide.vscode.cache';     Name = 'VS Code Cache';               Cat = 'IdeCache';      Path = (Join-Path $Context.AppData 'Code\Cache');                              Proc = @('Code'); Reason = 'Reproducible Electron cache; settings, extensions, and workspaces remain intact.' }
        @{ Id = 'ide.vscode.data';      Name = 'VS Code CachedData';          Cat = 'IdeCache';      Path = (Join-Path $Context.AppData 'Code\CachedData');                         Proc = @('Code'); Reason = 'Cached V8 bytecode; VS Code regenerates on launch.' }
        @{ Id = 'ide.vscode.vsix';      Name = 'VS Code Cached VSIXs';        Cat = 'IdeCache';      Path = (Join-Path $Context.AppData 'Code\CachedExtensionVSIXs');               Proc = @('Code'); Reason = 'Downloaded VSIX extension installers already unpacked.' }
        @{ Id = 'ide.vscode.gpu';       Name = 'VS Code GPUCache';            Cat = 'IdeCache';      Path = (Join-Path $Context.AppData 'Code\GPUCache');                           Proc = @('Code'); Reason = 'Reproducible GPU shader cache.' }
        @{ Id = 'launcher.discord.c';   Name = 'Discord Cache';               Cat = 'LauncherCache'; Path = (Join-Path $Context.AppData 'discord\Cache');                           Proc = @('Discord'); Reason = 'Cached Discord images and assets.' }
        @{ Id = 'launcher.discord.cc';  Name = 'Discord Code Cache';          Cat = 'LauncherCache'; Path = (Join-Path $Context.AppData 'discord\Code Cache');                      Proc = @('Discord'); Reason = 'Cached JS bytecode for Discord.' }
        @{ Id = 'launcher.discord.dl';  Name = 'Discord Updater Downloads';   Cat = 'LauncherCache'; Path = (Join-Path $Context.LocalAppData 'Discord\download');                   Proc = @('Discord'); Reason = 'Downloaded Discord update packages.' }
        @{ Id = 'launcher.steam.c';     Name = 'Steam Web Cache';             Cat = 'LauncherCache'; Path = (Join-Path $Context.LocalAppData 'Steam\htmlcache\Default\Cache');      Proc = @('steam', 'steamwebhelper'); Reason = 'Steam store web cache (login cookies untouched).' }
        @{ Id = 'launcher.steam.cc';    Name = 'Steam Code Cache';            Cat = 'LauncherCache'; Path = (Join-Path $Context.LocalAppData 'Steam\htmlcache\Default\Code Cache'); Proc = @('steam', 'steamwebhelper'); Reason = 'Steam CEF JS cache (login cookies untouched).' }
        @{ Id = 'launcher.steam.sh';    Name = 'Steam Shader Cache';          Cat = 'LauncherCache'; Path = (Join-Path $Context.LocalAppData 'Steam\htmlcache\GrShaderCache');      Proc = @('steam', 'steamwebhelper'); Reason = 'Steam browser shader cache.' }
        @{ Id = 'launcher.epic.c';      Name = 'Epic Launcher Cache';         Cat = 'LauncherCache'; Path = (Join-Path $Context.LocalAppData 'EpicGamesLauncher\Saved\webcache_4430\Cache'); Proc = @('EpicGamesLauncher'); Reason = 'Epic Launcher CEF HTTP cache (session untouched).' }
        @{ Id = 'launcher.epic.cc';     Name = 'Epic Launcher Code Cache';    Cat = 'LauncherCache'; Path = (Join-Path $Context.LocalAppData 'EpicGamesLauncher\Saved\webcache_4430\Code Cache'); Proc = @('EpicGamesLauncher'); Reason = 'Epic Launcher CEF JS cache.' }
        @{ Id = 'launcher.epic.sw';     Name = 'Epic Launcher SW Cache';      Cat = 'LauncherCache'; Path = (Join-Path $Context.LocalAppData 'EpicGamesLauncher\Saved\webcache_4430\Service Worker\CacheStorage'); Proc = @('EpicGamesLauncher'); Reason = 'Epic Launcher service worker asset cache.' }
        @{ Id = 'game.val.crashes';     Name = 'VALORANT Crash Reports';      Cat = 'CrashDumps';    Path = (Join-Path $Context.LocalAppData 'VALORANT\Saved\Crashes');             Proc = @('VALORANT-Win64-Shipping'); Reason = 'Old game crash dumps.' }
        @{ Id = 'game.val.logs';        Name = 'VALORANT Logs';               Cat = 'CrashDumps';    Path = (Join-Path $Context.LocalAppData 'VALORANT\Saved\Logs');                Proc = @('VALORANT-Win64-Shipping'); Reason = 'Old game diagnostic log files.' }
    )

    foreach ($t in $targets) {
        if (-not (Test-Path -LiteralPath $t.Path)) { continue }
        $bytes = Get-DirectorySizeFast -Path $t.Path
        if ($bytes -lt $MinBytes) { continue }

        New-RuleDecision -Id $t.Id -Name $t.Name -Category $t.Cat -Path $t.Path -SizeBytes $bytes `
            -NeededStatus 'NotNeeded' -RecommendedAction 'Delete' -Confidence 'High' `
            -ProcessGuard $t.Proc -Reason $t.Reason
    }

    $valDemos = Join-Path $Context.LocalAppData 'VALORANT\Saved\Demos'
    if (Test-Path -LiteralPath $valDemos) {
        $bytes = Get-DirectorySizeFast -Path $valDemos
        if ($bytes -ge (50MB)) {
            New-RuleDecision -Id 'review.valorant.demos' -Name 'VALORANT Saved Match Demos' -Category 'MediaReview' `
                -Path $valDemos -SizeBytes $bytes -NeededStatus 'OptionalReview' -RecommendedAction 'ReviewPrompt' `
                -Confidence 'Medium' -Reason 'Locally saved game replay files; delete only if you do not need these replays.'
        }
    }
}

function Get-PackageAndRelocatableDecisions {
    param(
        [Parameter(Mandatory)][hashtable]$Context,
        [int64]$MinBytes,
        [int64]$MinRelocateBytes
    )

    # 1. Purely reproducible caches (delete)
    $cleanCaches = @(
        @{ Id = 'pkg.npm';   Name = 'npm Cache';            Path = (Join-Path $Context.LocalAppData 'npm-cache');                  Proc = @('node'); Reason = 'Reproducible npm download cache; does not affect installed node_modules.' }
        @{ Id = 'pkg.pip';   Name = 'pip Cache';            Path = (Join-Path $Context.LocalAppData 'pip\cache');                  Proc = @();       Reason = 'Reproducible Python wheel cache.' }
        @{ Id = 'pkg.nuget'; Name = 'NuGet v3 Cache';       Path = (Join-Path $Context.LocalAppData 'NuGet\v3-cache');             Proc = @();       Reason = 'Reproducible NuGet package HTTP cache.' }
        @{ Id = 'pkg.yarn';  Name = 'Yarn Cache';           Path = (Join-Path $Context.LocalAppData 'Yarn\Cache');                 Proc = @();       Reason = 'Reproducible Yarn package download cache.' }
    )

    foreach ($c in $cleanCaches) {
        if (-not (Test-Path -LiteralPath $c.Path)) { continue }
        $bytes = Get-DirectorySizeFast -Path $c.Path
        if ($bytes -lt $MinBytes) { continue }

        New-RuleDecision -Id $c.Id -Name $c.Name -Category 'PackageCache' -Path $c.Path -SizeBytes $bytes `
            -NeededStatus 'NotNeeded' -RecommendedAction 'Delete' -Confidence 'High' `
            -ProcessGuard $c.Proc -Reason $c.Reason
    }

    # 2. Relocatable heavy dev/AI caches (detect if already linked, obsolete because env var moved elsewhere, or ready to relocate)
    $relocDefs = @(
        @{ Key = 'gradle';      Name = 'Gradle Cache & Wrapper'; Source = (Join-Path $Context.UserProfile '.gradle');             Subdir = 'Dev\.gradle';          EnvVar = 'GRADLE_USER_HOME'; Reason = 'Needed for Android/Java builds; relocate off C: instead of deleting to avoid re-downloading.' }
        @{ Key = 'huggingface'; Name = 'Hugging Face AI Models'; Source = (Join-Path $Context.UserProfile '.cache\huggingface'); Subdir = 'AI\huggingface-cache'; EnvVar = 'HF_HOME';          Reason = 'Needed local AI models; relocate off C: to keep models intact while freeing system drive space.' }
        @{ Key = 'whisper';     Name = 'OpenAI Whisper Models';  Source = (Join-Path $Context.UserProfile '.cache\whisper');     Subdir = 'AI\whisper-cache';     EnvVar = $null;              Reason = 'Needed local Whisper weights; relocate via NTFS junction to keep working transparently.' }
        @{ Key = 'uv';          Name = 'uv Python Cache';        Source = (Join-Path $Context.LocalAppData 'uv\cache');             Subdir = 'Dev\uv-cache';         EnvVar = 'UV_CACHE_DIR';     Reason = 'Reproducible uv wheel cache; relocate off C: to keep fast installs without consuming system space.' }
        @{ Key = 'pub';         Name = 'Dart/Flutter Pub Cache'; Source = (Join-Path $Context.LocalAppData 'Pub');                  Subdir = 'Dev\pub-cache';        EnvVar = 'PUB_CACHE';        Reason = 'Needed Dart/Flutter package cache; relocate off C: or remove if PUB_CACHE already points elsewhere.' }
        @{ Key = 'cargo';       Name = 'Rust Cargo Cache';       Source = (Join-Path $Context.UserProfile '.cargo\registry');    Subdir = 'Dev\cargo-registry';   EnvVar = 'CARGO_HOME';       Reason = 'Needed Rust crate cache; relocate off C: to preserve offline builds.' }
        @{ Key = 'ollama';      Name = 'Ollama Local Models';    Source = (Join-Path $Context.UserProfile '.ollama\models');     Subdir = 'AI\ollama-models';     EnvVar = 'OLLAMA_MODELS';    Reason = 'Needed local LLM weights; relocate off C: to preserve models.' }
    )

    $sysDrive = $Context.SystemDrive.TrimEnd('\')

    foreach ($r in $relocDefs) {
        if (-not (Test-Path -LiteralPath $r.Source)) { continue }
        $item = Get-Item -LiteralPath $r.Source -Force -ErrorAction SilentlyContinue
        if ($null -eq $item) { continue }

        if ($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint) {
            New-RuleDecision -Id "relocate.$($r.Key)" -Name $r.Name -Category 'RelocatableCache' -Path $r.Source `
                -SizeBytes 0 -NeededStatus 'NeededKeep' -RecommendedAction 'Keep' -Confidence 'High' `
                -Reason "Already relocated via NTFS junction to '$($item.Target -join ', ')' (0 bytes used on $sysDrive)."
            continue
        }

        $bytes = Get-DirectorySizeFast -Path $r.Source
        if ($bytes -lt $MinBytes) { continue }

        # Smart rule: if the official env var ALREADY points off C:, this local C: copy is stale/obsolete!
        if ($r.EnvVar) {
            $envVal = $null
            if ($Context.ContainsKey('EnvOverrides') -and $Context.EnvOverrides.ContainsKey($r.EnvVar)) {
                $envVal = $Context.EnvOverrides[$r.EnvVar]
            } elseif (-not $Context.ContainsKey('UseLiveEnvVars') -or $Context.UseLiveEnvVars) {
                $envVal = [Environment]::GetEnvironmentVariable($r.EnvVar, 'User')
                if (-not $envVal) { $envVal = [Environment]::GetEnvironmentVariable($r.EnvVar, 'Machine') }
            }
            if ($envVal -and ($envVal -match '^[A-Za-z]:') -and -not $envVal.StartsWith($sysDrive, [System.StringComparison]::OrdinalIgnoreCase)) {
                New-RuleDecision -Id "pkg.stale_$($r.Key)" -Name "Stale $($r.Name) on $sysDrive" -Category 'PackageCache' `
                    -Path $r.Source -SizeBytes $bytes -NeededStatus 'NotNeeded' -RecommendedAction 'Delete' `
                    -Confidence 'High' -Reason "$($r.EnvVar) is already configured at '$envVal', making this $sysDrive copy obsolete."
                continue
            }
        }

        if ($bytes -ge $MinRelocateBytes) {
            New-RuleDecision -Id "relocate.$($r.Key)" -Name $r.Name -Category 'RelocatableCache' -Path $r.Source `
                -SizeBytes $bytes -NeededStatus 'NeededMoveOffC' -RecommendedAction 'MoveToSecondaryDrive' `
                -Confidence 'High' -EnvVar ([string]$r.EnvVar) -RelocateSubdir $r.Subdir -Reason $r.Reason
        }
    }
}

function Get-UpdaterAndDeadSoftwareDecisions {
    param(
        [Parameter(Mandatory)][hashtable]$Context,
        [int64]$MinBytes
    )

    # 1. Adobe Refresh Manager downloaded patches in ProgramData\Adobe\ARM
    $adobeArm = Join-Path $Context.ProgramData 'Adobe\ARM'
    if (Test-Path -LiteralPath $adobeArm) {
        $bytes = Get-DirectorySizeFast -Path $adobeArm
        if ($bytes -ge $MinBytes) {
            $acroExe = Join-Path $Context.ProgramFiles 'Adobe\Acrobat DC\Acrobat\Acrobat.exe'
            $acroExe86 = if ($Context.ProgramFilesX86) { Join-Path $Context.ProgramFilesX86 'Adobe\Acrobat DC\Acrobat\Acrobat.exe' } else { '' }
            $acroInstalled = (Test-Path -LiteralPath $acroExe) -or ($acroExe86 -and (Test-Path -LiteralPath $acroExe86))

            if (-not $acroInstalled) {
                New-RuleDecision -Id 'updater.adobe_arm' -Name 'Unused Adobe Acrobat ARM Update Cache' -Category 'Updater' `
                    -Path $adobeArm -SizeBytes $bytes -NeededStatus 'NotNeeded' -RecommendedAction 'Delete' -Confidence 'High' `
                    -RequiresAdmin (-not (Test-PathWritable -Path $adobeArm)) `
                    -Reason 'Adobe Acrobat executable is not installed on C:, so these downloaded .msp patch payloads are unused.'
            } else {
                New-RuleDecision -Id 'updater.adobe_arm' -Name 'Adobe Acrobat ARM Downloaded Patches' -Category 'Updater' `
                    -Path $adobeArm -SizeBytes $bytes -NeededStatus 'OptionalReview' -RecommendedAction 'ReviewPrompt' -Confidence 'Medium' `
                    -RequiresAdmin (-not (Test-PathWritable -Path $adobeArm)) `
                    -Reason 'Downloaded Acrobat update installers; already-applied .msp files can be deleted safely.'
            }
        }
    }

    # 2. Dead Acrobat DC leftover directory (only .bak / uninstaller fragments when Acrobat.exe is missing)
    $acroFolder = Join-Path $Context.ProgramFiles 'Adobe\Acrobat DC'
    if (Test-Path -LiteralPath $acroFolder) {
        $hasExe = @(Get-ChildItem -LiteralPath $acroFolder -Filter 'Acrobat.exe' -Recurse -ErrorAction SilentlyContinue).Count -gt 0
        if (-not $hasExe) {
            $bytes = Get-DirectorySizeFast -Path $acroFolder
            if ($bytes -ge $MinBytes) {
                $needsAdmin = -not (Test-PathWritable -Path $acroFolder)
                New-RuleDecision -Id 'orphan.acrobat_dc_dir' -Name 'Dead Acrobat DC Leftover Folder' -Category 'OrphanedInstaller' `
                    -Path $acroFolder -SizeBytes $bytes -NeededStatus 'OptionalReview' -RecommendedAction $(if ($needsAdmin) { 'AdminCleanup' } else { 'ReviewPrompt' }) `
                    -Confidence 'Medium' -RequiresAdmin $needsAdmin `
                    -Reason 'Acrobat.exe is absent in this folder; remaining files appear to be leftover backups from a previous install.'
            }
        }
    }

    # 3. PowerToys downloaded update setups
    $ptUpdates = Join-Path $Context.LocalAppData 'Microsoft\PowerToys\Updates'
    if (Test-Path -LiteralPath $ptUpdates) {
        $ptExe = Join-Path $Context.ProgramFiles 'PowerToys\PowerToys.exe'
        $bytes = Get-DirectorySizeFast -Path $ptUpdates
        if ($bytes -ge $MinBytes -and (Test-Path -LiteralPath $ptExe)) {
            New-RuleDecision -Id 'updater.powertoys' -Name 'PowerToys Downloaded Update Setups' -Category 'Updater' `
                -Path $ptUpdates -SizeBytes $bytes -NeededStatus 'NotNeeded' -RecommendedAction 'Delete' -Confidence 'High' `
                -Reason 'Cached PowerToys installer executables and update logs; PowerToys itself remains installed.'
        }
    }

    # 4. Generic *-updater folders (e.g. Electron auto-updaters) - never delete active 'pending' updates
    foreach ($uDir in (Get-ChildItem -LiteralPath $Context.LocalAppData -Directory -Filter '*-updater' -ErrorAction SilentlyContinue)) {
        $pendingDir = Join-Path $uDir.FullName 'pending'
        $hasPending = (Test-Path -LiteralPath $pendingDir) -and (@(Get-ChildItem -LiteralPath $pendingDir -Force -File -ErrorAction SilentlyContinue).Count -gt 0)
        $installerFile = Join-Path $uDir.FullName 'installer.exe'
        if ((Test-Path -LiteralPath $installerFile) -and -not $hasPending) {
            $fi = Get-Item -LiteralPath $installerFile -Force -ErrorAction SilentlyContinue
            if ($fi -and $fi.Length -ge $MinBytes) {
                New-RuleDecision -Id "updater.$($uDir.Name)" -Name "Cached Updater ($($uDir.Name))" -Category 'Updater' `
                    -Path $installerFile -ItemType 'FileList' -TargetPaths @($installerFile) -SizeBytes $fi.Length `
                    -NeededStatus 'NotNeeded' -RecommendedAction 'Delete' -Confidence 'Medium' `
                    -Reason 'Cached updater installer.exe with no pending update queued.'
            }
        }
    }
}

function Get-DuplicateToolAndReviewDecisions {
    param(
        [Parameter(Mandatory)][hashtable]$Context,
        [int64]$MinBytes
    )

    # 1. Duplicate root-level ffmpeg folder when another ffmpeg.exe is active on PATH
    $sysRootDrive = "$($Context.SystemDrive.TrimEnd('\'))\"
    $activeFfmpeg = Get-Command ffmpeg.exe -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($activeFfmpeg -and $activeFfmpeg.Source) {
        foreach ($ffDir in (Get-ChildItem -LiteralPath $sysRootDrive -Directory -Filter 'ffmpeg*' -ErrorAction SilentlyContinue)) {
            if (-not $activeFfmpeg.Source.StartsWith($ffDir.FullName, [System.StringComparison]::OrdinalIgnoreCase)) {
                $bytes = Get-DirectorySizeFast -Path $ffDir.FullName
                if ($bytes -ge $MinBytes) {
                    New-RuleDecision -Id "dup.$($ffDir.Name)" -Name "Duplicate Tool ($($ffDir.Name))" -Category 'DuplicateTool' `
                        -Path $ffDir.FullName -SizeBytes $bytes -NeededStatus 'OptionalReview' -RecommendedAction 'ReviewPrompt' `
                        -Confidence 'Medium' -Reason "Active ffmpeg on PATH is '$($activeFfmpeg.Source)'; this standalone directory appears unused."
                }
            }
        }
    }

    # 2. Premiere Pro rendered video previews (protects .prproj files)
    foreach ($docRoot in @(
        (Join-Path $Context.UserProfile 'Documents\Adobe\Premiere Pro'),
        (Join-Path $Context.UserProfile 'OneDrive\Documents\Adobe\Premiere Pro')
    )) {
        if (-not (Test-Path -LiteralPath $docRoot)) { continue }
        foreach ($prevDir in (Get-ChildItem -LiteralPath $docRoot -Directory -Recurse -Filter '*Video Previews*' -ErrorAction SilentlyContinue)) {
            $bytes = Get-DirectorySizeFast -Path $prevDir.FullName
            if ($bytes -ge (50MB)) {
                New-RuleDecision -Id "review.premiere.$($prevDir.Parent.Name)" -Name "Premiere Pro $($prevDir.Parent.Name) Video Previews" `
                    -Category 'MediaReview' -Path $prevDir.FullName -SizeBytes $bytes -NeededStatus 'OptionalReview' `
                    -RecommendedAction 'ReviewPrompt' -Confidence 'High' `
                    -Reason 'Rendered video preview cache only (.PRV); Premiere Pro regenerates them as needed and .prproj project files stay untouched.'
            }
        }
    }

    # 3. Large Microsoft Store chat/media local caches (> 300 MB)
    $pkgRoot = Join-Path $Context.LocalAppData 'Packages'
    if (Test-Path -LiteralPath $pkgRoot) {
        $mediaPatterns = @(
            @{ Pattern = '*Unigram*'; Sub = 'LocalState'; Label = 'Unigram/Telegram Local Media Cache' }
            @{ Pattern = '*Spotify*'; Sub = 'LocalCache\Spotify'; Label = 'Spotify Offline/Stream Cache' }
            @{ Pattern = '*WhatsApp*'; Sub = 'LocalState'; Label = 'WhatsApp Local Media Cache' }
        )
        foreach ($mp in $mediaPatterns) {
            foreach ($pkg in (Get-ChildItem -LiteralPath $pkgRoot -Directory -Filter $mp.Pattern -ErrorAction SilentlyContinue)) {
                $target = Join-Path $pkg.FullName $mp.Sub
                if (-not (Test-Path -LiteralPath $target)) { continue }
                $bytes = Get-DirectorySizeFast -Path $target
                if ($bytes -ge (300MB)) {
                    New-RuleDecision -Id "review.pkg.$($pkg.Name)" -Name $mp.Label -Category 'MediaReview' `
                        -Path $target -SizeBytes $bytes -NeededStatus 'OptionalReview' -RecommendedAction 'ReviewPrompt' `
                        -Confidence 'Medium' -Reason 'Large local app media/stream cache; clearing frees space, though media may re-download from the cloud.'
                }
            }
        }
    }

    # 4. Old installer downloads (> 30 days old, >= 25 MB, .exe/.msi/.msix/.iso only - never PDFs/docs)
    $downloadsDir = Join-Path $Context.UserProfile 'Downloads'
    if (Test-Path -LiteralPath $downloadsDir) {
        $oldCutoff = (Get-Date).AddDays(-30)
        $oldInstallers = @(Get-ChildItem -LiteralPath $downloadsDir -Force -File -ErrorAction SilentlyContinue | Where-Object {
            $_.Extension -in '.exe', '.msi', '.msix', '.iso' -and $_.Length -ge 25MB -and $_.LastWriteTime -lt $oldCutoff
        })
        if ($oldInstallers.Count -gt 0) {
            $sumBytes = [int64](($oldInstallers | Measure-Object Length -Sum).Sum)
            New-RuleDecision -Id 'review.downloads.installers' -Name "Old Downloads Installers ($($oldInstallers.Count) files)" `
                -Category 'MediaReview' -Path $downloadsDir -ItemType 'FileList' -TargetPaths @($oldInstallers.FullName) `
                -SizeBytes $sumBytes -NeededStatus 'OptionalReview' -RecommendedAction 'ReviewPrompt' -Confidence 'Medium' `
                -Reason 'Downloaded .exe/.msi/.msix/.iso installers older than 30 days; documents and PDFs are excluded.'
        }
    }
}

function Get-SystemAndProtectedDecisions {
    param(
        [Parameter(Mandatory)][hashtable]$Context,
        [switch]$IncludeInstallerAudit
    )

    if ($IncludeInstallerAudit -and $Context.UseLiveRegistry) {
        $installerDir = Join-Path $Context.SystemRoot 'Installer'
        $orphans = @(Get-OrphanedWindowsInstallers -IncludeMetadata -InstallerDir $installerDir)
        if ($orphans.Count -gt 0) {
            $sumBytes = Get-PropertySum -Items $orphans -Property 'SizeBytes'
            $topProds = @(Group-InstallersByProduct -Orphans $orphans | Select-Object -First 3 | ForEach-Object { $_.ProductName })
            $needsAdmin = -not (Test-IsAdministrator)
            New-RuleDecision -Id 'admin.windows_installer_orphans' `
                -Name "Orphaned Windows Installer Patches ($($orphans.Count) files)" `
                -Category 'OrphanedInstaller' -Path $installerDir -ItemType 'OrphanedInstallers' `
                -TargetPaths @($orphans.FullName) -SizeBytes $sumBytes `
                -NeededStatus 'NotNeeded' -RecommendedAction 'AdminCleanup' -Confidence 'High' `
                -RequiresAdmin $needsAdmin `
                -Reason ("Orphaned .msi/.msp packages not referenced by Windows Installer COM or Registry (top: {0})." -f ($topProds -join ', '))
        }
    }

    $wuDownload = Join-Path $Context.SystemRoot 'SoftwareDistribution\Download'
    if (Test-Path -LiteralPath $wuDownload) {
        $bytes = Get-DirectorySizeFast -Path $wuDownload
        if ($bytes -ge 20MB) {
            New-RuleDecision -Id 'admin.wu_download' -Name 'Windows Update Download Cache' `
                -Category 'SystemOptimization' -Path $wuDownload -SizeBytes $bytes `
                -NeededStatus 'NotNeeded' -RecommendedAction 'AdminCleanup' -Confidence 'High' `
                -RequiresAdmin (-not (Test-IsAdministrator)) `
                -Reason 'Downloaded Windows Update payload cache; safe to clear after updates finish.'
        }
    }

    # Check root system files (hiberfil.sys) via Get-ChildItem -Force since kernel holds exclusive handle
    $sysRootDrive = "$($Context.SystemDrive.TrimEnd('\'))\"
    $hiber = Get-ChildItem -LiteralPath $sysRootDrive -Force -File -Filter 'hiberfil.sys' -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($hiber -and $hiber.Length -ge 1GB) {
        New-RuleDecision -Id 'system.hiberfil' -Name 'Windows Hibernation File (hiberfil.sys)' `
            -Category 'SystemOptimization' -Path $hiber.FullName -ItemType 'SystemComponent' -SizeBytes $hiber.Length `
            -NeededStatus 'OptionalReview' -RecommendedAction 'ReviewPrompt' -Confidence 'High' `
            -RequiresAdmin $true `
            -Reason "Hibernation/Fast Startup reserve; disabling via 'powercfg /h off' recovers $([math]::Round($hiber.Length/1GB,2)) GB if you do not use Hibernate."
    }

    # Explicitly list protected user libraries so the user sees what is safeguarded
    foreach ($lib in @('Documents', 'Desktop', 'Pictures', 'Videos', 'OneDrive')) {
        $libPath = Join-Path $Context.UserProfile $lib
        if (Test-Path -LiteralPath $libPath) {
            New-RuleDecision -Id "protected.$($lib.ToLowerInvariant())" -Name "Personal $lib Folder" `
                -Category 'Protected' -Path $libPath -SizeBytes 0 -NeededStatus 'NeededKeep' `
                -RecommendedAction 'Keep' -Confidence 'High' `
                -Reason 'Protected personal user library; never auto-deleted.'
        }
    }
}

function Get-DiskCleanupRecommendations {
    <#
    .SYNOPSIS
        Deterministically analyzes the system and classifies storage items into
        NotNeeded (safe delete), NeededMoveOffC (relocate), OptionalReview, and NeededKeep (protected).
    #>
    [CmdletBinding()]
    param(
        [int]$MinTempAgeMinutes = 60,
        [int]$MinItemSizeMB = 5,
        [int]$MinRelocateSizeMB = 50,
        [switch]$IncludeInstallerAudit,
        [hashtable]$Context
    )

    if (-not $Context) {
        $Context = Get-DefaultSystemContext
    }

    $minBytes = [int64]$MinItemSizeMB * 1MB
    $minRelocBytes = [int64]$MinRelocateSizeMB * 1MB

    $all = @()
    $all += Get-TempAndCrashDecisions -Context $Context -MinTempAgeMinutes $MinTempAgeMinutes -MinBytes $minBytes
    $all += Get-BrowserCacheDecisions -Context $Context -MinBytes $minBytes
    $all += Get-IdeAndLauncherCacheDecisions -Context $Context -MinBytes $minBytes
    $all += Get-PackageAndRelocatableDecisions -Context $Context -MinBytes $minBytes -MinRelocateBytes $minRelocBytes
    $all += Get-UpdaterAndDeadSoftwareDecisions -Context $Context -MinBytes $minBytes
    $all += Get-DuplicateToolAndReviewDecisions -Context $Context -MinBytes $minBytes
    $all += Get-SystemAndProtectedDecisions -Context $Context -IncludeInstallerAudit:$IncludeInstallerAudit

    return @($all | Sort-Object NeededStatus, SizeBytes -Descending)
}

Export-ModuleMember -Function @(
    'Get-DefaultSystemContext',
    'Get-DiskCleanupRecommendations'
)
