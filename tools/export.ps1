<#
.SYNOPSIS
    Exports NetRumble for Xbox on PC and/or Xbox Series X|S.

.DESCRIPTION
    Drives Godot's command-line exporter against the presets in
    export_presets.cfg.

    The export itself deliberately runs *without* --headless. Godot bakes the
    precompiled D3D12 shader blobs (.d3d12xs.cache) into the .pck at export
    time, and that baking step only happens when a RenderingDevice exists.
    Under --headless it is silently skipped: the export still reports success,
    but the package is ~6 MB smaller and the title is terminated at startup on
    console (terminate result 0x87E50006) because Xbox cannot compile shaders at
    runtime. A short-lived Godot window during the export is expected.

    The two targets are not symmetrical:

      pc       Uses the "XBOX on PC" preset from the godot_gdk addon. That
               platform stages the build into <output>\_gdk_staging. With
               dev/register_loose=true (the committed default) it finishes by
               running `wdapp register` on that folder, and no .exe appears at
               the preset's export_path — the staging folder *is* the
               deliverable. With package output it runs makepkg instead and
               writes an .msixvc into <output>.

      console  Uses the "Xbox Series X|S" preset, which only exists in a
               Middleware console fork of Godot. Point -ConsoleGodotExe (or
               $env:GODOT_CONSOLE) at that editor binary. In Loose mode (the
               committed default) the deliverable is the layout in the preset's
               output directory, ready for `xbapp deploy`. In Package mode the
               exporter runs makepkg and writes an .xvc there instead.

    Package or Loose is chosen in the editor's Export dialog, together with the
    signing key; this script exports whatever the preset says and checks for the
    matching output. In package mode only a package written by this run counts.
    Never commit a preset set to package output or naming a key file;
    tools\check-game-config.ps1 fails on both.

.PARAMETER Target
    pc, console, or both. Defaults to pc.

.PARAMETER Configuration
    debug or release. Defaults to release.

.PARAMETER Clean
    Delete the preset's output directory before exporting. Use this after
    renaming an executable — stale binaries from a previous export otherwise
    linger in the layout and get deployed.

.PARAMETER GodotExe
    Godot binary used for the PC export. Falls back to $env:GODOT_BIN,
    $env:GODOT, then `godot` / `godot4` on PATH.

.PARAMETER ConsoleGodotExe
    A Middleware console fork used for the Xbox Series X|S export. Falls back to
    $env:GODOT_CONSOLE. There is no PATH fallback — a stock `godot` on PATH has
    no Xbox Series X|S platform, so guessing one would fail confusingly.

.PARAMETER Import
    Force a `--headless --import` pass before exporting. Happens automatically
    when the project has never been imported on this machine.

.EXAMPLE
    .\tools\export.ps1 -Target pc -Configuration debug

.EXAMPLE
    .\tools\export.ps1 -Target both -Clean
#>
[CmdletBinding()]
param(
    [ValidateSet('pc', 'console', 'both')][string]$Target = 'pc',
    [ValidateSet('debug', 'release')][string]$Configuration = 'release',
    [switch]$Clean,
    [string]$GodotExe,
    [string]$ConsoleGodotExe,
    [switch]$Import
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'common.ps1')


function Invoke-ProjectImport {
    param([Parameter(Mandatory)][string]$Godot)

    Write-Step 'Importing project resources'
    # --import exits non-zero on some builds even when the import succeeded, so
    # the result is advisory: a genuinely broken import fails the export next.
    $result = Invoke-Tool -FilePath $Godot -Arguments @('--headless', '--path', $script:RepoRoot, '--import')
    if ($result.ExitCode -ne 0) {
        Write-Warning "godot --import exited with $($result.ExitCode); continuing to the export."
    }
}


function Invoke-GodotExport {
    param(
        [Parameter(Mandatory)][string]$Godot,
        [Parameter(Mandatory)]$Preset
    )

    Write-Step "Exporting '$($Preset.Name)' ($Configuration, $(Get-ExportPresetMode -Preset $Preset))"
    Write-Detail "Godot:  $Godot"
    Write-Detail "Output: $($Preset.ExportPath)"

    if ($Clean) { Clear-OutputDirectory -Path $Preset.OutputDir }
    New-Item -ItemType Directory -Path $Preset.OutputDir -Force | Out-Null

    if ($Import -or -not (Test-Path -LiteralPath (Join-Path $script:RepoRoot '.godot'))) {
        Invoke-ProjectImport -Godot $Godot
    }

    $exportFlag = if ($Configuration -eq 'release') { '--export-release' } else { '--export-debug' }

    Invoke-ToolOrFail `
        -FilePath $Godot `
        -Arguments @('--path', $script:RepoRoot, $exportFlag, $Preset.Name, $Preset.ExportPath) `
        -FailureMessage "Godot export of preset '$($Preset.Name)' failed" | Out-Null
}


# Godot can report success while the exporter bailed part-way, so each target
# confirms the artifact it is actually judged on.
function Assert-ExportArtifact {
    param(
        [Parameter(Mandatory)]$Preset,
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$Description
    )

    if (-not (Test-Path -LiteralPath $Path)) {
        Fail ("Export of '$($Preset.Name)' reported success but the $Description is missing:`n" +
            "  $Path`nCheck the Godot output above for export errors.")
    }
    Write-Success "Export complete: $Path"
}

# makepkg writes the package into the preset's output folder under a name it
# derives from the package identity, so the package is found by extension.
# A package older than this run is left over from an earlier export.
function Assert-FreshPackage {
    param(
        [Parameter(Mandatory)]$Preset,
        [Parameter(Mandatory)][ValidateSet('PC', 'Scarlett')][string]$DeviceFamily,
        [Parameter(Mandatory)][datetime]$Since
    )

    $extension = $script:PackageExtensions[$DeviceFamily]
    $package = Find-NewestPackage -Directory $Preset.OutputDir -Extension $extension -Since $Since
    if (-not $package) {
        Fail ("Export of '$($Preset.Name)' in package mode reported success but wrote no $extension " +
            "to $($Preset.OutputDir) during this run. An older package there does not count. " +
            'Check the makepkg output above.')
    }
    Write-Success "Package created: $($package.FullName)"
    return $package.FullName
}


function Export-Pc {
    $preset = Get-ExportPreset -Name $script:PcPresetName
    $mode = Get-ExportPresetMode -Preset $preset

    $godot = Resolve-GodotExe `
        -Explicit $GodotExe `
        -EnvNames @('GODOT_BIN', 'GODOT') `
        -PathCommands @('godot', 'godot4') `
        -Purpose 'the Xbox on PC export' `
        -Hint 'Pass -GodotExe <path>, or put godot.exe on PATH.'

    $started = Get-Date
    Invoke-GodotExport -Godot $godot -Preset $preset

    if ($mode -eq 'Package') {
        return (Assert-FreshPackage -Preset $preset -DeviceFamily 'PC' -Since $started)
    }

    $stagingDir = Join-Path $preset.OutputDir $script:PcStagingFolderName
    $exeName = (Get-GameConfigExecutable -DeviceFamily 'PC').Name
    Assert-ExportArtifact -Preset $preset -Path (Join-Path $stagingDir $exeName) `
        -Description 'staged package executable'

    Write-Detail "Loose package staged at: $stagingDir"
    return $stagingDir
}


function Export-Console {
    $preset = Get-ExportPreset -Name $script:ConsolePresetName
    $mode = Get-ExportPresetMode -Preset $preset

    $godot = Resolve-GodotExe `
        -Explicit $ConsoleGodotExe `
        -EnvNames @('GODOT_CONSOLE') `
        -Purpose 'the Xbox Series X|S export' `
        -Hint ("The `"Xbox Series X|S`" export platform only exists in a Middleware console fork " +
            "of Godot. Pass -ConsoleGodotExe <path to that editor .exe>, or set `$env:GODOT_CONSOLE.")

    $started = Get-Date
    Invoke-GodotExport -Godot $godot -Preset $preset

    if ($mode -eq 'Package') {
        return (Assert-FreshPackage -Preset $preset -DeviceFamily 'Scarlett' -Since $started)
    }

    Assert-ExportArtifact -Preset $preset -Path $preset.ExportPath -Description 'console executable'

    # xbapp deploy registers the apps declared in the config it finds at the
    # root of the deploy path; without it the layout copies but never registers.
    $stagedConfig = Join-Path $preset.OutputDir 'MicrosoftGame.config'
    if (-not (Test-Path -LiteralPath $stagedConfig)) {
        Fail "Export finished but MicrosoftGame.config was not staged into $($preset.OutputDir)."
    }

    Write-Detail "Console layout staged at: $($preset.OutputDir)"
    return $preset.OutputDir
}


$results = [ordered]@{}

# Stamped before either export so the packaged build reports the commit it was
# actually built from, and a mismatched pair of peers can be told apart.
Write-Step 'Stamping the build'
Write-BuildStamp

if ($Target -in @('pc', 'both')) { $results['pc'] = Export-Pc }
if ($Target -in @('console', 'both')) { $results['console'] = Export-Console }

Write-Step 'Done'
foreach ($key in $results.Keys) {
    Write-Success ("{0,-8} {1}" -f $key, $results[$key])
}
