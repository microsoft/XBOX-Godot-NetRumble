# Shared helpers for the NetRumble export/deploy scripts.
#
# Dot-source this from the sibling scripts:
#     . (Join-Path $PSScriptRoot 'common.ps1')
#
# Nothing here runs a build; it only locates tooling and reads the files that
# define what a NetRumble package is — export_presets.cfg and the two
# MicrosoftGame.config files — so the scripts never hard-code a name that lives
# there.

$ErrorActionPreference = 'Stop'

$script:RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path

# Preset names as written in export_presets.cfg.
$script:PcPresetName = 'XBOX on PC'
$script:ConsolePresetName = 'Xbox Series X|S'

# The "XBOX on PC" export platform always stages the loose package into a
# _gdk_staging folder beside the preset's export_path, then hands that folder to
# `wdapp register`. See addons/godot_gdk/editor/gdk_export_platform.gd.
$script:PcStagingFolderName = '_gdk_staging'

# File extension of the package each target's makepkg step writes into the
# preset's output folder when the preset is set to package output.
$script:PackageExtensions = @{
    PC       = '.msixvc'
    Scarlett = '.xvc'
}

$script:GdkBinDirCache = $null
$script:GdkEditionDirCache = @{}


# ── Console output ──────────────────────────────────────────────────────────

function Write-Step {
    param([Parameter(Mandatory)][string]$Message)
    Write-Host ''
    Write-Host "==> $Message" -ForegroundColor Cyan
}

function Write-Detail {
    param([Parameter(Mandatory)][string]$Message)
    Write-Host "    $Message" -ForegroundColor DarkGray
}

function Write-Success {
    param([Parameter(Mandatory)][string]$Message)
    Write-Host "    $Message" -ForegroundColor Green
}

function Fail {
    param([Parameter(Mandatory)][string]$Message)
    throw $Message
}


# ── GDK toolchain discovery ─────────────────────────────────────────────────

# Mirrors addons/godot_gdk_editortools/core/gdk_toolchain.gd: GDK_BIN wins, then
# the installer's %GameDK%\bin, then the default install path.
function Get-GdkBinDir {
    if ($script:GdkBinDirCache) { return $script:GdkBinDirCache }

    $candidates = @()
    if ($env:GDK_BIN) { $candidates += $env:GDK_BIN }
    if ($env:GameDK) { $candidates += (Join-Path $env:GameDK 'bin') }
    $candidates += 'C:\Program Files (x86)\Microsoft GDK\bin'

    foreach ($candidate in $candidates) {
        if ($candidate -and (Test-Path -LiteralPath (Join-Path $candidate 'makepkg.exe'))) {
            $script:GdkBinDirCache = (Resolve-Path -LiteralPath $candidate).Path
            return $script:GdkBinDirCache
        }
    }

    Fail ("Could not locate the Microsoft GDK bin directory. Tried:`n  " +
        ($candidates -join "`n  ") +
        "`nInstall the Microsoft GDK, or set GDK_BIN to the folder containing makepkg.exe.")
}

# The GDK installs one directory per edition (`260400`, `251001`, …) beside the
# shared `bin` folder. `bin` alone cannot answer "which redistributables", so
# anything that copies a GRDK redist DLL has to name an edition.
#
# Pass -Version to pin one; omit it to take the highest installed.
function Get-GdkEditionDir {
    param([string]$Version = '')

    $key = if ($Version) { $Version } else { '' }
    if ($script:GdkEditionDirCache.ContainsKey($key)) { return $script:GdkEditionDirCache[$key] }

    $root = Split-Path -Parent (Get-GdkBinDir)

    $editions = @(
        Get-ChildItem -LiteralPath $root -Directory -ErrorAction SilentlyContinue |
            Where-Object { $_.Name -match '^\d+$' -and (Test-Path -LiteralPath (Join-Path $_.FullName 'GRDK')) }
    )
    if ($editions.Count -eq 0) {
        Fail "No Microsoft GDK edition directories found under $root. Install a GDK edition (the shared 'bin' folder alone is not enough)."
    }

    if ($Version) {
        $match = $editions | Where-Object { $_.Name -eq $Version } | Select-Object -First 1
        if (-not $match) {
            Fail ("Microsoft GDK edition '$Version' is not installed. Available: " +
                (($editions.Name | Sort-Object) -join ', '))
        }
        $selected = $match
    } else {
        $selected = $editions | Sort-Object { [int]$_.Name } | Select-Object -Last 1
    }

    $script:GdkEditionDirCache[$key] = $selected.FullName
    return $selected.FullName
}

function Get-GdkTool {
    param([Parameter(Mandatory)][string]$Name)

    $binDir = Get-GdkBinDir
    $path = Join-Path $binDir $Name
    if (-not (Test-Path -LiteralPath $path)) {
        Fail "$Name not found in $binDir. Repair or update the Microsoft GDK installation."
    }
    return $path
}


# ── Godot discovery ─────────────────────────────────────────────────────────

function Resolve-GodotExe {
    param(
        [string]$Explicit,
        [string[]]$EnvNames = @(),
        [string[]]$DefaultPaths = @(),
        [string[]]$PathCommands = @(),
        [Parameter(Mandatory)][string]$Purpose,
        [string]$Hint = ''
    )

    if ($Explicit) {
        if (-not (Test-Path -LiteralPath $Explicit)) {
            Fail "Godot executable not found at '$Explicit'."
        }
        return (Resolve-Path -LiteralPath $Explicit).Path
    }

    $tried = @()

    foreach ($name in $EnvNames) {
        $value = [Environment]::GetEnvironmentVariable($name)
        $tried += ('$env:' + $name + $(if ($value) { " = $value" } else { ' (unset)' }))
        if ($value -and (Test-Path -LiteralPath $value)) {
            return (Resolve-Path -LiteralPath $value).Path
        }
    }

    foreach ($path in $DefaultPaths) {
        $tried += $path
        if (Test-Path -LiteralPath $path) {
            return (Resolve-Path -LiteralPath $path).Path
        }
    }

    foreach ($command in $PathCommands) {
        $tried += "$command (on PATH)"
        $found = Get-Command $command -CommandType Application -ErrorAction SilentlyContinue |
            Select-Object -First 1
        if ($found) { return $found.Source }
    }

    $message = "Could not locate a Godot executable for $Purpose. Tried:`n  " + ($tried -join "`n  ")
    if ($Hint) { $message += "`n$Hint" }
    Fail $message
}


# ── Build stamp ─────────────────────────────────────────────────────────────

# Writes the commit this package was built from into a generated script the
# title reads at runtime, so a player can read their build off the main menu and
# two peers can be compared without guessing.
#
# Generated rather than committed because the value is a property of the build,
# not of the source: committing it would make every export dirty the tree, and
# the checked-in value would be wrong for every build but the last one.
# `scripts/generated/` is gitignored for that reason.
#
# A .gd file is used rather than a data file because scripts are always exported;
# a .txt would need an `include_filter` entry in every preset to survive.
function Write-BuildStamp {
    $generatedDir = Join-Path $script:RepoRoot 'scripts\generated'
    if (-not (Test-Path -LiteralPath $generatedDir)) {
        New-Item -ItemType Directory -Path $generatedDir -Force | Out-Null
    }

    Push-Location $script:RepoRoot
    try {
        $commit = (git rev-parse --short=8 HEAD 2>$null)
        $branch = (git rev-parse --abbrev-ref HEAD 2>$null)
        $dirty = -not [string]::IsNullOrWhiteSpace((git status --porcelain 2>$null | Out-String))
    } finally {
        Pop-Location
    }

    if ([string]::IsNullOrWhiteSpace($commit)) { $commit = 'unknown' }
    if ([string]::IsNullOrWhiteSpace($branch)) { $branch = 'unknown' }

    $contents = @(
        '# Generated by tools/common.ps1 (Write-BuildStamp) on every export.',
        '# Not committed: this describes the build, not the source. See .gitignore.',
        'extends RefCounted',
        '',
        "const COMMIT := `"$commit`"",
        "const BRANCH := `"$branch`"",
        "const DIRTY := $($dirty.ToString().ToLowerInvariant())",
        ''
    ) -join "`n"

    Set-Content -LiteralPath (Join-Path $generatedDir 'build_info.gd') -Value $contents -NoNewline -Encoding UTF8

    $suffix = if ($dirty) { ' (dirty)' } else { '' }
    Write-Detail "Build stamp: $commit on $branch$suffix"
}


# ── export_presets.cfg ──────────────────────────────────────────────────────

# Returns every preset as an object with Name, Platform, ExportPath (absolute),
# OutputDir (absolute) and Options (option name -> raw cfg value).
function Get-ExportPresets {
    $configPath = Join-Path $script:RepoRoot 'export_presets.cfg'
    if (-not (Test-Path -LiteralPath $configPath)) {
        Fail "export_presets.cfg not found at $configPath."
    }

    $presets = @()
    $current = $null
    $inOptions = $false

    foreach ($line in (Get-Content -LiteralPath $configPath)) {
        $text = $line.Trim()

        if ($text -match '^\[preset\.\d+\]$') {
            $current = [pscustomobject]@{
                Name       = ''
                Platform   = ''
                ExportPath = ''
                OutputDir  = ''
                Options    = @{}
            }
            $presets += $current
            $inOptions = $false
            continue
        }

        if ($text -match '^\[preset\.\d+\.options\]$') {
            $inOptions = $true
            continue
        }

        if ($text.StartsWith('[')) {
            $current = $null
            $inOptions = $false
            continue
        }

        if ($null -eq $current) { continue }
        if ($text -notmatch '^([^=]+)=(.*)$') { continue }

        $key = $Matches[1].Trim()
        $value = $Matches[2].Trim()

        if ($inOptions) {
            $current.Options[$key] = $value
            continue
        }

        switch ($key) {
            'name' { $current.Name = $value.Trim('"') }
            'platform' { $current.Platform = $value.Trim('"') }
            'export_path' { $current.ExportPath = $value.Trim('"') }
        }
    }

    foreach ($preset in $presets) {
        if (-not $preset.ExportPath) { continue }
        $preset.ExportPath = [System.IO.Path]::GetFullPath(
            [System.IO.Path]::Combine($script:RepoRoot, $preset.ExportPath.Replace('/', '\')))
        $preset.OutputDir = Split-Path -Parent $preset.ExportPath
    }

    return $presets
}

function Get-ExportPreset {
    param([Parameter(Mandatory)][string]$Name)

    $presets = @(Get-ExportPresets)
    $found = $presets | Where-Object { $_.Name -eq $Name } | Select-Object -First 1
    if (-not $found) {
        $names = ($presets | ForEach-Object { "'$($_.Name)'" }) -join ', '
        Fail ("Export preset '$Name' is not defined in export_presets.cfg (found: $names). " +
            "Add it via Project > Export > Add > $Name in the Godot editor.")
    }
    if (-not $found.ExportPath) {
        Fail "Export preset '$Name' has no export_path set in export_presets.cfg."
    }
    return $found
}

# Returns a preset option as a plain string: quotes removed, '' when unset.
function Get-PresetOption {
    param(
        [Parameter(Mandatory)]$Preset,
        [Parameter(Mandatory)][string]$Name
    )

    if (-not $Preset.Options.ContainsKey($Name)) { return '' }
    return ([string]$Preset.Options[$Name]).Trim('"')
}

# 'Loose' or 'Package'. The developer picks this in the editor's Export dialog;
# the committed presets are Loose. Defaults follow each platform's own default
# for an option the file does not set.
function Get-ExportPresetMode {
    param([Parameter(Mandatory)]$Preset)

    switch ($Preset.Name) {
        $script:PcPresetName {
            # godot_gdk addon: dev/register_loose defaults to false (package).
            if ((Get-PresetOption -Preset $Preset -Name 'dev/register_loose') -eq 'true') { return 'Loose' }
            return 'Package'
        }
        $script:ConsolePresetName {
            if ((Get-PresetOption -Preset $Preset -Name 'packaging/package_type') -eq '0') { return 'Package' }
            return 'Loose'
        }
    }
    Fail "Unknown export preset '$($Preset.Name)'."
}

# Turns a path from export_presets.cfg into an absolute filesystem path.
# Relative and res:// paths resolve against the project root.
function Resolve-ProjectPath {
    param([Parameter(Mandatory)][string]$Path)

    $value = $Path.Trim('"')
    if ($value.StartsWith('res://')) { $value = $value.Substring('res://'.Length) }
    return [System.IO.Path]::GetFullPath(
        [System.IO.Path]::Combine($script:RepoRoot, $value.Replace('/', '\')))
}


# ── Packages ────────────────────────────────────────────────────────────────

# Returns the newest package of the given extension in a folder, or $null.
# With -Since, a package written before that time does not count: an export
# that fails can leave an older package from an earlier run in place.
function Find-NewestPackage {
    param(
        [Parameter(Mandatory)][string]$Directory,
        [Parameter(Mandatory)][string]$Extension,
        [datetime]$Since = [datetime]::MinValue
    )

    if (-not (Test-Path -LiteralPath $Directory)) { return $null }

    # -Filter alone also matches longer extensions that begin the same way.
    return Get-ChildItem -LiteralPath $Directory -Filter "*$Extension" -File |
        Where-Object { $_.Extension -eq $Extension -and $_.LastWriteTime -ge $Since } |
        Sort-Object LastWriteTime -Descending |
        Select-Object -First 1
}


# ── MicrosoftGame.config ────────────────────────────────────────────────────

# Each target has its own config.
#   PC        the project root, where the "XBOX on PC" platform always reads it.
#   Scarlett  the file the console preset names in application/game_config.
function Get-GameConfigPath {
    param([Parameter(Mandatory)][ValidateSet('PC', 'Scarlett')][string]$DeviceFamily)

    if ($DeviceFamily -eq 'PC') {
        return (Join-Path $script:RepoRoot 'MicrosoftGame.config')
    }

    $preset = Get-ExportPreset -Name $script:ConsolePresetName
    $configured = Get-PresetOption -Preset $preset -Name 'application/game_config'
    if (-not $configured) {
        Fail "The '$($script:ConsolePresetName)' preset does not set application/game_config."
    }
    return (Resolve-ProjectPath -Path $configured)
}

function Get-GameConfig {
    param([Parameter(Mandatory)][ValidateSet('PC', 'Scarlett')][string]$DeviceFamily)

    $configPath = Get-GameConfigPath -DeviceFamily $DeviceFamily
    if (-not (Test-Path -LiteralPath $configPath)) {
        Fail "MicrosoftGame.config for $DeviceFamily not found at $configPath."
    }
    return [xml](Get-Content -LiteralPath $configPath -Raw)
}

# TargetDeviceFamily is 'PC' or 'Scarlett'. Returns Name (the .exe the package
# declares) and Id (the AUMID suffix).
function Get-GameConfigExecutable {
    param([Parameter(Mandatory)][ValidateSet('PC', 'Scarlett')][string]$DeviceFamily)

    $executable = (Get-GameConfig -DeviceFamily $DeviceFamily).Game.ExecutableList.Executable |
        Where-Object { $_.TargetDeviceFamily -eq $DeviceFamily } |
        Select-Object -First 1

    if (-not $executable) {
        Fail ("$(Get-GameConfigPath -DeviceFamily $DeviceFamily) declares no <Executable> with " +
            "TargetDeviceFamily=`"$DeviceFamily`".")
    }

    return [pscustomobject]@{
        Name = $executable.Name
        Id   = $executable.Id
    }
}

# Both configs carry the same identity; tools\check-game-config.ps1 enforces it.
function Get-GameConfigIdentityName {
    return (Get-GameConfig -DeviceFamily 'PC').Game.Identity.Name
}


# ── Process execution ───────────────────────────────────────────────────────

# Runs an external tool, streaming its output, and returns
# @{ ExitCode = <int>; Output = <string> }. Never throws on a non-zero exit —
# callers decide what a failure means.
function Invoke-Tool {
    param(
        [Parameter(Mandatory)][string]$FilePath,
        [string[]]$Arguments = @(),
        [string]$WorkingDirectory
    )

    $quoted = $Arguments | ForEach-Object { if ($_ -match '\s') { "`"$_`"" } else { $_ } }
    Write-Detail (">  `"$FilePath`" " + ($quoted -join ' '))

    $captured = $null
    $pushed = $false
    try {
        if ($WorkingDirectory) {
            Push-Location -LiteralPath $WorkingDirectory
            $pushed = $true
        }
        & $FilePath @Arguments 2>&1 | Tee-Object -Variable captured | Out-Host
        $exitCode = $LASTEXITCODE
    } finally {
        if ($pushed) { Pop-Location }
    }

    return @{
        ExitCode = $exitCode
        Output   = ($captured | Out-String)
    }
}

function Invoke-ToolOrFail {
    param(
        [Parameter(Mandatory)][string]$FilePath,
        [string[]]$Arguments = @(),
        [string]$WorkingDirectory,
        [Parameter(Mandatory)][string]$FailureMessage
    )

    $result = Invoke-Tool -FilePath $FilePath -Arguments $Arguments -WorkingDirectory $WorkingDirectory
    if ($result.ExitCode -ne 0) {
        Fail "$FailureMessage (exit code $($result.ExitCode))."
    }
    return $result
}


# ── wdapp helpers ───────────────────────────────────────────────────────────

# Returns the registered package matching the PC config's Identity/@Name,
# or $null. wdapp pads its output with blank lines, so the JSON is sliced out.
function Get-RegisteredPcPackage {
    $wdapp = Get-GdkTool 'wdapp.exe'
    $raw = (& $wdapp list /JSON 2>&1 | Out-String)

    $start = $raw.IndexOf('{')
    $end = $raw.LastIndexOf('}')
    if ($start -lt 0 -or $end -le $start) { return $null }

    try {
        $data = $raw.Substring($start, $end - $start + 1) | ConvertFrom-Json
    } catch {
        return $null
    }

    $identity = Get-GameConfigIdentityName
    return $data.Packages |
        Where-Object { $_.PackageFullName -like ($identity + '_*') } |
        Select-Object -First 1
}


# ── Filesystem ──────────────────────────────────────────────────────────────

function Clear-OutputDirectory {
    param([Parameter(Mandatory)][string]$Path)

    if (-not (Test-Path -LiteralPath $Path)) { return }

    # Guard against a preset whose export_path points at the repo root.
    $resolved = (Resolve-Path -LiteralPath $Path).Path.TrimEnd('\')
    if ($resolved -eq $script:RepoRoot.TrimEnd('\')) {
        Fail "Refusing to clean '$resolved': that is the repository root. Fix the preset's export_path."
    }

    Write-Detail "Cleaning $resolved"
    # Delete the contents rather than the directory: a console-deploy or shell
    # session holding a handle on the folder itself blocks removing it, but not
    # its children.
    Get-ChildItem -LiteralPath $resolved -Force | ForEach-Object {
        Remove-Item -LiteralPath $_.FullName -Recurse -Force
    }
}
