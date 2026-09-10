<#
.SYNOPSIS
    Exports NetRumble for Xbox on PC and registers it with `wdapp register`.

.DESCRIPTION
    A registered package is what makes GDK sign-in, invites and protocol
    activation work on the desktop — running the project straight out of the
    editor gets you an initialized GDK but no identity.

    The "XBOX on PC" preset sets dev/register_loose=true, so the Godot export
    already ends in `wdapp register`. This script therefore exports, then
    confirms the registration actually landed and only re-runs `wdapp register`
    itself if it did not. With -SkipExport it registers the previously staged
    folder without rebuilding.

.PARAMETER Configuration
    debug or release. Defaults to release.

.PARAMETER Clean
    Wipe the export output directory before exporting.

.PARAMETER SkipExport
    Register the existing <output>\_gdk_staging folder without re-exporting.

.PARAMETER Launch
    Launch the registered package once it is in place.

.PARAMETER Unregister
    Unregister the package and exit without exporting.

.PARAMETER GodotExe
    Godot binary to export with. Falls back to $env:GODOT_BIN, $env:GODOT, then
    `godot` / `godot4` on PATH.

.EXAMPLE
    .\tools\deploy-pc.ps1

.EXAMPLE
    .\tools\deploy-pc.ps1 -Configuration debug -Launch

.EXAMPLE
    .\tools\deploy-pc.ps1 -SkipExport
#>
[CmdletBinding()]
param(
    [ValidateSet('debug', 'release')][string]$Configuration = 'release',
    [switch]$Clean,
    [switch]$SkipExport,
    [switch]$Launch,
    [switch]$Unregister,
    [string]$GodotExe
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'common.ps1')

$wdapp = Get-GdkTool 'wdapp.exe'
$preset = Get-ExportPreset -Name $script:PcPresetName
$stagingDir = Join-Path $preset.OutputDir $script:PcStagingFolderName
$pcExecutable = Get-GameConfigExecutable -DeviceFamily 'PC'


function Register-StagedPackage {
    if (-not (Test-Path -LiteralPath (Join-Path $stagingDir $pcExecutable.Name))) {
        Fail ("No staged package to register. Expected:`n" +
            "  $(Join-Path $stagingDir $pcExecutable.Name)`n" +
            "Run this script without -SkipExport, and make sure the '$($script:PcPresetName)' " +
            "preset still has dev/register_loose=true.")
    }

    Write-Step 'Registering the loose package with wdapp'
    Invoke-ToolOrFail `
        -FilePath $wdapp `
        -Arguments @('register', $stagingDir) `
        -FailureMessage 'wdapp register failed' | Out-Null
}


if ($Unregister) {
    $existing = Get-RegisteredPcPackage
    if (-not $existing) {
        Write-Step 'Nothing to unregister'
        Write-Detail "No package matching '$(Get-GameConfigIdentityName)' is registered."
        return
    }

    Write-Step "Unregistering $($existing.PackageFullName)"
    Invoke-ToolOrFail `
        -FilePath $wdapp `
        -Arguments @('unregister', $existing.PackageFullName) `
        -FailureMessage 'wdapp unregister failed' | Out-Null
    Write-Success 'Unregistered.'
    return
}


if ($SkipExport) {
    Register-StagedPackage
} else {
    $exportArgs = @{
        Target        = 'pc'
        Configuration = $Configuration
    }
    if ($Clean) { $exportArgs['Clean'] = $true }
    if ($GodotExe) { $exportArgs['GodotExe'] = $GodotExe }

    & (Join-Path $PSScriptRoot 'export.ps1') @exportArgs

    # The export platform runs `wdapp register` itself when the preset opts into
    # loose registration. Only step in when that did not happen.
    if (-not (Get-RegisteredPcPackage)) {
        Write-Detail 'Export did not leave a registered package; registering explicitly.'
        Register-StagedPackage
    }
}


Write-Step 'Verifying registration'
$package = Get-RegisteredPcPackage
if (-not $package) {
    Fail ("wdapp register reported success but no package matching " +
        "'$(Get-GameConfigIdentityName)' appears in wdapp list output.")
}

$aumid = $package.Applications |
    Where-Object { $_.Aumid -like ('*!' + $pcExecutable.Id) } |
    Select-Object -First 1 |
    ForEach-Object { $_.Aumid }
if (-not $aumid) { $aumid = ($package.Applications | Select-Object -First 1).Aumid }

Write-Success "Package: $($package.PackageFullName)"
Write-Success "AUMID:   $aumid"
Write-Detail  "Staged from: $stagingDir"
Write-Detail  'Also launchable from the Start menu / Xbox app.'


if ($Launch) {
    Write-Step "Launching $aumid"
    Invoke-ToolOrFail `
        -FilePath $wdapp `
        -Arguments @('launch', $aumid) `
        -FailureMessage 'wdapp launch failed' | Out-Null
}
