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
               platform stages a loose package into <output>\_gdk_staging and,
               because the preset sets dev/register_loose=true, finishes by
               running `wdapp register` on it. No .exe appears at the preset's
               export_path — the staging folder *is* the deliverable.

      console  Uses the "Xbox Series X|S" preset, which only exists in a
               Middleware console fork of Godot. Point -ConsoleGodotExe (or
               $env:GODOT_CONSOLE) at that editor binary. The deliverable is the
               loose layout in the preset's output directory, ready for
               `xbapp deploy`.

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
        [Parameter(Mandatory)][string]$PresetName,
        [Parameter(Mandatory)][string]$ExpectedArtifact,
        [string]$ArtifactDescription = 'exported build'
    )

    $preset = Get-ExportPreset -Name $PresetName

    Write-Step "Exporting '$PresetName' ($Configuration)"
    Write-Detail "Godot:  $Godot"
    Write-Detail "Output: $($preset.ExportPath)"

    if ($Clean) { Clear-OutputDirectory -Path $preset.OutputDir }
    New-Item -ItemType Directory -Path $preset.OutputDir -Force | Out-Null

    if ($Import -or -not (Test-Path -LiteralPath (Join-Path $script:RepoRoot '.godot'))) {
        Invoke-ProjectImport -Godot $Godot
    }

    $exportFlag = if ($Configuration -eq 'release') { '--export-release' } else { '--export-debug' }

    Invoke-ToolOrFail `
        -FilePath $Godot `
        -Arguments @('--path', $script:RepoRoot, $exportFlag, $preset.Name, $preset.ExportPath) `
        -FailureMessage "Godot export of preset '$PresetName' failed" | Out-Null

    # Godot can report success while the exporter bailed part-way, so confirm
    # the artifact this target is actually judged on.
    if (-not (Test-Path -LiteralPath $ExpectedArtifact)) {
        Fail ("Export of '$PresetName' reported success but the $ArtifactDescription is missing:`n" +
            "  $ExpectedArtifact`nCheck the Godot output above for export errors.")
    }

    Write-Success "Export complete: $ExpectedArtifact"
    return $preset
}


function Export-Pc {
    $preset = Get-ExportPreset -Name $script:PcPresetName
    $stagingDir = Join-Path $preset.OutputDir $script:PcStagingFolderName
    $exeName = (Get-GameConfigExecutable -DeviceFamily 'PC').Name

    $godot = Resolve-GodotExe `
        -Explicit $GodotExe `
        -EnvNames @('GODOT_BIN', 'GODOT') `
        -PathCommands @('godot', 'godot4') `
        -Purpose 'the Xbox on PC export' `
        -Hint 'Pass -GodotExe <path>, or put godot.exe on PATH.'

    Invoke-GodotExport `
        -Godot $godot `
        -PresetName $script:PcPresetName `
        -ExpectedArtifact (Join-Path $stagingDir $exeName) `
        -ArtifactDescription 'staged package executable' | Out-Null

    Write-Detail "Loose package staged at: $stagingDir"
    return $stagingDir
}


function Export-Console {
    $preset = Get-ExportPreset -Name $script:ConsolePresetName

    $godot = Resolve-GodotExe `
        -Explicit $ConsoleGodotExe `
        -EnvNames @('GODOT_CONSOLE') `
        -Purpose 'the Xbox Series X|S export' `
        -Hint ("The `"Xbox Series X|S`" export platform only exists in a Middleware console fork " +
            "of Godot. Pass -ConsoleGodotExe <path to that editor .exe>, or set `$env:GODOT_CONSOLE.")

    Invoke-GodotExport `
        -Godot $godot `
        -PresetName $script:ConsolePresetName `
        -ExpectedArtifact $preset.ExportPath `
        -ArtifactDescription 'console executable' | Out-Null

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
