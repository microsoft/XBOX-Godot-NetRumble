<#
.SYNOPSIS
    Build the GDK/PlayFab addons from the external\xbox-godot-sample submodule
    and install them into addons\.

.DESCRIPTION
    `addons\` is build output, not source. It is gitignored, and this script is
    the only thing that writes it. A fresh clone has no addons at all until this
    runs, so the project cannot load its GDExtensions until it does.

    Three things are combined into each installed addon:

    1. The submodule's own build output. `external\xbox-godot-sample` is pinned
       to a commit of https://github.com/microsoft/XBOX-Godot-Sample; its CMake
       build drops the addon DLLs and every runtime dependency into that repo's
       `addons\<addon>\bin\`. Everything except the build-system files is then
       copied here.

    2. The GRDK console redistributables. `libHttpClient.GDK.dll` and
       `Microsoft.Xbox.Services.GDK.C.Thunks.dll` are the Game Core flavours of
       two libraries the desktop build ships in Win32 form. They come from an
       installed Microsoft GDK edition, not from the addon build, and only the
       Xbox Series X|S export loads them.

    3. The project's `.gdextension` manifests, from `tools\addon-overrides\`.
       Upstream's manifests declare Windows libraries only. NetRumble's add the
       `scarlett.*` library entries and the `[dependencies] scarlett.x86_64`
       blocks that name the two DLLs above, without which the console export
       silently ships a package whose extension cannot load.

    Debug and Release are configured into separate CMake binary directories
    because godot-cpp's GODOTCPP_TARGET is a configure-time cache variable;
    sharing one directory links the debug godot-cpp into the Release DLLs, which
    load fine and then corrupt the heap. The submodule's own build_addons.ps1
    owns that split — this script only selects the configuration.

    Both configurations are installed by default because the `.gdextension`
    manifests name both library paths: the editor loads the debug DLL and the
    release export loads the release one.

.PARAMETER Configuration
    `Both` (default), `Debug`, or `Release`. Which native addon DLLs to build
    and install.

.PARAMETER GdkVersion
    Microsoft GDK edition to take the console redistributables from (e.g.
    `260400`). Defaults to the highest installed edition.

.PARAMETER SkipBuild
    Reinstall from whatever the submodule last built. Fails if an expected DLL
    is missing rather than installing a partial addon set.

.PARAMETER SkipConsoleRedist
    Do not install the GRDK console redistributables. For machines with no
    Microsoft GDK installed — CI runners get the GDK through vcpkg, which is
    enough to build the addons but does not provide the Game Core DLLs. The
    result loads on desktop; the Xbox Series X|S export will not work.

.PARAMETER SkipSubmoduleUpdate
    Leave the submodule at its current checkout instead of resetting it to the
    pinned commit. Use when testing an unmerged upstream branch.

.PARAMETER Clean
    Wipe the submodule's CMake binary directories and reconfigure from scratch.

.PARAMETER IncludeDebugSymbols
    Also install the addon PDBs. They are ~150 MB each and gitignored, so they
    are left out by default.

.OUTPUTS
    Exits 0 on success; throws with the failing command or missing file
    otherwise.

.EXAMPLE
    .\tools\sync_addons.ps1
    The normal case: build Debug and Release, install everything into addons\.

.EXAMPLE
    .\tools\sync_addons.ps1 -SkipBuild
    Reinstall after editing tools\addon-overrides\, without a rebuild.

.EXAMPLE
    .\tools\sync_addons.ps1 -Configuration Release -GdkVersion 260400 -Clean
#>
[CmdletBinding()]
param(
    [ValidateSet('Debug', 'Release', 'Both')]
    [string]$Configuration = 'Both',

    [string]$GdkVersion = '',

    [switch]$SkipBuild,

    [switch]$SkipConsoleRedist,

    [switch]$SkipSubmoduleUpdate,

    [switch]$Clean,

    [switch]$IncludeDebugSymbols
)

. (Join-Path $PSScriptRoot 'common.ps1')

$script:SubmodulePath = 'external/xbox-godot-sample'
$script:SubmoduleDir = Join-Path $script:RepoRoot ($script:SubmodulePath -replace '/', '\')
$script:AddonsDir = Join-Path $script:RepoRoot 'addons'
$script:OverridesDir = Join-Path $PSScriptRoot 'addon-overrides'

# Only the addons NetRumble loads. The submodule also builds godot_gameinput and
# the C# facades; installing those would add plugins the project never enables.
$script:Addons = @(
    @{ Name = 'godot_gdk';             Native = $true },
    @{ Name = 'godot_playfab';         Native = $true },
    @{ Name = 'godot_gdk_editortools'; Native = $false }
)

# Build-system files that live in the upstream addon trees and must not be
# installed. tests_support\ is the dangerous one: its scripts extend GutTest, so
# without the GUT plugin every parse of the project reports
# "Could not find base class GutTest".
$script:ExcludedDirectories = @('src', 'tests_support')
$script:ExcludedFiles = @('CMakeLists.txt')

# GRDK redistributables the Xbox Series X|S export needs, named by the
# [dependencies] scarlett.x86_64 blocks in tools\addon-overrides. Paths are
# relative to a GDK edition directory. The Release thunks are correct for both
# configurations: the manifests name one file, and the debug addon links release
# imports.
$script:ConsoleRedist = @{
    godot_gdk = @(
        'GRDK\ExtensionLibraries\Xbox.LibHttpClient\Redist\x64\libHttpClient.GDK.dll',
        'GRDK\ExtensionLibraries\Xbox.Services.API.C\Lib\x64\Release\Microsoft.Xbox.Services.GDK.C.Thunks.dll'
    )
}


function Get-SelectedConfigurations {
    if ($Configuration -eq 'Both') { return @('Debug', 'Release') }
    return @($Configuration)
}

$script:SelectedConfigurations = @(Get-SelectedConfigurations)


# ── Submodule ───────────────────────────────────────────────────────────────

function Update-AddonSubmodule {
    $marker = Join-Path $script:SubmoduleDir 'tools\build_addons.ps1'

    if ($SkipSubmoduleUpdate -and (Test-Path -LiteralPath $marker)) {
        Write-Detail "Leaving $script:SubmodulePath at its current checkout"
        return
    }

    if ($SkipSubmoduleUpdate) {
        Fail "-SkipSubmoduleUpdate was given but $script:SubmodulePath is not checked out."
    }

    Write-Detail "git submodule update --init --recursive $script:SubmodulePath"
    & git -C $script:RepoRoot submodule update --init --recursive -- $script:SubmodulePath
    if ($LASTEXITCODE -ne 0) {
        Fail "git submodule update failed with exit code $LASTEXITCODE."
    }

    if (-not (Test-Path -LiteralPath $marker)) {
        Fail "$script:SubmodulePath checked out but $marker is missing. The submodule pin may predate the build scripts."
    }

    $sha = (& git -C $script:SubmoduleDir rev-parse --short HEAD).Trim()
    Write-Detail "Addon source at $sha"
}


# ── Build ───────────────────────────────────────────────────────────────────

# The submodule's CMake presets resolve their toolchain file through
# $env:VCPKG_ROOT, so it has to be set before cmake runs. Visual Studio ships a
# vcpkg the presets are happy with.
function Initialize-VcpkgRoot {
    if ($env:VCPKG_ROOT -and (Test-Path -LiteralPath (Join-Path $env:VCPKG_ROOT 'scripts\buildsystems\vcpkg.cmake'))) {
        Write-Detail "VCPKG_ROOT=$env:VCPKG_ROOT"
        return
    }

    if ($env:VCPKG_INSTALLATION_ROOT -and (Test-Path -LiteralPath (Join-Path $env:VCPKG_INSTALLATION_ROOT 'scripts\buildsystems\vcpkg.cmake'))) {
        $env:VCPKG_ROOT = $env:VCPKG_INSTALLATION_ROOT
        Write-Detail "VCPKG_ROOT=$env:VCPKG_ROOT"
        return
    }

    $tried = @()
    foreach ($drive in @('C:', 'D:')) {
        $base = "$drive\Program Files\Microsoft Visual Studio"
        if (-not (Test-Path -LiteralPath $base)) { continue }
        foreach ($year in @('2026', '2022')) {
            foreach ($edition in @('Enterprise', 'Professional', 'Community', 'BuildTools')) {
                $candidate = Join-Path $base "$year\$edition\VC\vcpkg"
                $tried += $candidate
                if (Test-Path -LiteralPath (Join-Path $candidate 'scripts\buildsystems\vcpkg.cmake')) {
                    $env:VCPKG_ROOT = $candidate
                    Write-Detail "VCPKG_ROOT=$env:VCPKG_ROOT"
                    return
                }
            }
        }
    }

    Fail ("Could not locate vcpkg. Tried VCPKG_ROOT, VCPKG_INSTALLATION_ROOT and:`n  " +
        ($tried -join "`n  ") +
        "`nInstall the Visual Studio vcpkg component, or set VCPKG_ROOT to a vcpkg checkout.")
}

function Invoke-AddonBuild {
    param([Parameter(Mandatory)][string]$BuildConfiguration)

    $buildScript = Join-Path $script:SubmoduleDir 'tools\build_addons.ps1'
    $arguments = @{
        Preset        = 'addon-package'
        Configuration = $BuildConfiguration
    }
    if ($Clean) { $arguments.Clean = $true }

    # build_addons.ps1 throws on a non-zero cmake exit, so a return here means
    # the build succeeded.
    & $buildScript @arguments
}


# ── Install ─────────────────────────────────────────────────────────────────

function Test-InstallableFile {
    param(
        [Parameter(Mandatory)][string]$RelativePath,
        [Parameter(Mandatory)][string]$FileName
    )

    foreach ($excluded in $script:ExcludedDirectories) {
        if ($RelativePath -like "$excluded\*") { return $false }
    }
    if ($script:ExcludedFiles -contains $FileName) { return $false }

    if ($FileName -like '*.pdb' -and -not $IncludeDebugSymbols) { return $false }

    # Godot's import metadata. If someone has ever opened the submodule in the
    # editor these exist there, and copying them would make the installed tree
    # depend on that. The editor regenerates both on first import; nothing in
    # this project references an addon script by UID.
    if ($FileName -like '*.uid' -or $FileName -like '*.import') { return $false }

    # A configuration that was not built leaves a stale DLL from a previous run
    # in the submodule's bin\. Installing it would ship an addon built from a
    # different commit than the one just synced.
    if ($FileName -match '^.+\.windows\.(debug|release)\.x86_64\.(dll|pdb)$') {
        $dllConfiguration = (Get-Culture).TextInfo.ToTitleCase($Matches[1])
        if ($script:SelectedConfigurations -notcontains $dllConfiguration) { return $false }
    }

    return $true
}

function Install-Addon {
    param([Parameter(Mandatory)][hashtable]$Addon)

    $name = $Addon.Name
    $source = Join-Path $script:SubmoduleDir "addons\$name"
    $destination = Join-Path $script:AddonsDir $name

    if (-not (Test-Path -LiteralPath $source -PathType Container)) {
        Fail "Addon '$name' is missing from the submodule at $source."
    }

    if ($Addon.Native) {
        foreach ($config in $script:SelectedConfigurations) {
            $dll = Join-Path $source ("bin\{0}.windows.{1}.x86_64.dll" -f $name, $config.ToLowerInvariant())
            if (-not (Test-Path -LiteralPath $dll -PathType Leaf)) {
                Fail "Expected $config DLL is missing: $dll. Run without -SkipBuild."
            }
        }
    }

    # A full replace, not a merge. A file that upstream deleted has to disappear
    # here too, and a merge would leave it behind for the engine to load.
    if (Test-Path -LiteralPath $destination) {
        Remove-Item -LiteralPath $destination -Recurse -Force
    }
    New-Item -ItemType Directory -Path $destination -Force | Out-Null

    $prefix = (Resolve-Path -LiteralPath $source).Path.TrimEnd('\') + '\'
    $installed = 0

    foreach ($file in Get-ChildItem -LiteralPath $source -Recurse -File) {
        $relative = $file.FullName.Substring($prefix.Length)
        if (-not (Test-InstallableFile -RelativePath $relative -FileName $file.Name)) { continue }

        $target = Join-Path $destination $relative
        New-Item -ItemType Directory -Path (Split-Path -Parent $target) -Force | Out-Null
        Copy-Item -LiteralPath $file.FullName -Destination $target -Force
        $installed++
    }

    Write-Detail "$name — $installed files"
}

function Install-ConsoleRedistributables {
    $edition = Get-GdkEditionDir -Version $GdkVersion
    Write-Detail "GDK edition $(Split-Path -Leaf $edition)"

    foreach ($name in $script:ConsoleRedist.Keys) {
        $destination = Join-Path $script:AddonsDir "$name\bin"
        if (-not (Test-Path -LiteralPath $destination)) {
            Fail "Cannot install console redistributables: $destination does not exist."
        }

        foreach ($relative in $script:ConsoleRedist[$name]) {
            $source = Join-Path $edition $relative
            if (-not (Test-Path -LiteralPath $source -PathType Leaf)) {
                Fail ("Console redistributable not found: $source`n" +
                    "The Xbox Series X|S export needs it. Install the GRDK extension libraries for this edition, or pass -GdkVersion to select another.")
            }
            Copy-Item -LiteralPath $source -Destination $destination -Force
            Write-Detail "$name — $(Split-Path -Leaf $source)"
        }
    }
}

function Install-Overrides {
    if (-not (Test-Path -LiteralPath $script:OverridesDir -PathType Container)) {
        Fail "Override directory is missing: $script:OverridesDir"
    }

    $prefix = (Resolve-Path -LiteralPath $script:OverridesDir).Path.TrimEnd('\') + '\'

    foreach ($file in Get-ChildItem -LiteralPath $script:OverridesDir -Recurse -File -Force) {
        $relative = $file.FullName.Substring($prefix.Length)

        # An override is <addon>\<path-within-the-addon>. Anything loose at the
        # root (README.md, .gdignore) documents or configures the directory
        # itself and is not installed.
        if ($relative -notmatch '\\') { continue }

        $addonName = ($relative -split '\\')[0]
        if ($script:Addons.Name -notcontains $addonName) {
            Fail "Override '$relative' does not belong to an installed addon."
        }

        $target = Join-Path $script:AddonsDir $relative
        New-Item -ItemType Directory -Path (Split-Path -Parent $target) -Force | Out-Null
        Copy-Item -LiteralPath $file.FullName -Destination $target -Force
        Write-Detail $relative
    }
}


# ── Verify ──────────────────────────────────────────────────────────────────

# Every res:// path a manifest names has to resolve, because Godot does not
# complain when one does not. A missing [libraries] entry leaves the extension
# unloaded; a missing [dependencies] entry produces a console package that
# terminates before any GDScript runs, with nothing naming the extension.
#
# This is the guard on the two lists this script hard-codes ($ConsoleRedist) and
# on the manifests in tools\addon-overrides: edit one without the other and the
# mismatch is caught here rather than on a devkit.
function Test-InstalledManifests {
    $missing = @()

    foreach ($addon in $script:Addons | Where-Object { $_.Native }) {
        $name = $addon.Name
        $manifest = Join-Path $script:AddonsDir "$name\$name.gdextension"
        if (-not (Test-Path -LiteralPath $manifest -PathType Leaf)) {
            Fail "Installed manifest is missing: $manifest"
        }

        $section = ''
        foreach ($line in Get-Content -LiteralPath $manifest) {
            if ($line -match '^\s*\[(?<name>[a-z_]+)\]') {
                $section = $Matches.name
                continue
            }

            $required = @()
            if ($section -eq 'libraries' -and $line -match '^\s*(?<key>[^\s=]+)\s*=\s*"(?<path>res://[^"]+)"') {
                $libraryKey = $Matches.key
                $libraryPath = $Matches.path

                # A configuration that was not installed has no DLL by design.
                if ($libraryKey -match '\.(debug|release)\.') {
                    $keyConfiguration = (Get-Culture).TextInfo.ToTitleCase($Matches[1])
                    if ($script:SelectedConfigurations -notcontains $keyConfiguration) { continue }
                }
                $required = @($libraryPath)
            } elseif ($section -eq 'dependencies' -and $line -match '"(?<path>res://[^"]+)"\s*:') {
                $required = @($Matches.path)
            }

            foreach ($resPath in $required) {
                $relative = $resPath -replace '^res://', '' -replace '/', '\'
                if (Test-Path -LiteralPath (Join-Path $script:RepoRoot $relative) -PathType Leaf) { continue }

                $fileName = Split-Path -Leaf $relative
                if ($SkipConsoleRedist -and ($script:ConsoleRedist.Values | ForEach-Object { $_ } | ForEach-Object { Split-Path -Leaf $_ }) -contains $fileName) {
                    continue
                }
                $missing += "$name.gdextension -> $resPath"
            }
        }
    }

    if ($missing.Count -gt 0) {
        Fail ("Installed manifests name files that do not exist:`n  " + ($missing -join "`n  ") +
            "`nEither the build did not produce them or tools\addon-overrides names a file this script does not install.")
    }

    Write-Detail 'Every res:// path named by the installed manifests resolves.'
}


# ── Run ─────────────────────────────────────────────────────────────────────

Write-Step "Addon source ($script:SubmodulePath)"
Update-AddonSubmodule

if ($SkipBuild) {
    Write-Step "Build — skipped"
} else {
    Write-Step "Build ($($script:SelectedConfigurations -join ', '))"
    Initialize-VcpkgRoot
    foreach ($config in $script:SelectedConfigurations) {
        Invoke-AddonBuild -BuildConfiguration $config
    }
}

Write-Step 'Install addons'
foreach ($addon in $script:Addons) {
    Install-Addon -Addon $addon
}

if ($SkipConsoleRedist) {
    Write-Step 'Install console redistributables — skipped'
    Write-Host '    addons\ is desktop-only: the Xbox Series X|S export will fail to load its extensions.' -ForegroundColor Yellow
} else {
    Write-Step 'Install console redistributables'
    Install-ConsoleRedistributables
}

Write-Step 'Apply project .gdextension overrides'
Install-Overrides

Write-Step 'Verify'
Test-InstalledManifests

Write-Step 'Done'
Write-Success "addons\ rebuilt from $script:SubmodulePath ($($script:SelectedConfigurations -join ', '))."
Write-Detail 'Open the project in Godot to re-import; .uid files are regenerated on first import.'
