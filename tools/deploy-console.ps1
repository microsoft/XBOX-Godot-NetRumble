<#
.SYNOPSIS
    Exports NetRumble for Xbox Series X|S and pushes it with `xbapp deploy`.

.DESCRIPTION
    The console export produces a loose layout — executable, .pck, GDK/PlayFab
    DLLs, gameos.xvd and the staged MicrosoftGame.config — in the preset's
    output directory. `xbapp deploy` syncs that folder to the devkit and
    registers the apps declared in the config it finds at the folder root.

    The "Xbox Series X|S" export platform ships only in a Middleware console
    fork of Godot, so -ConsoleGodotExe (or $env:GODOT_CONSOLE) must point at
    that editor binary; a stock Godot build will not have the preset's platform.

.PARAMETER Configuration
    debug or release. Defaults to release.

.PARAMETER Clean
    Wipe the export output directory before exporting. Worth doing after an
    executable rename: `xbapp deploy` copies whatever is in the folder, so an
    orphaned binary from a previous export ships to the console as well. Note
    that this also discards the ~330 MB gameos.xvd, which the export re-stages.

.PARAMETER SkipExport
    Deploy the existing layout without re-exporting.

.PARAMETER ConsoleAddress
    Console to target. Omit to use the default console set with `xbconnect`.

.PARAMETER SyncExact
    Pass /S to `xbapp deploy` so files on the console that are absent from the
    local layout are deleted. Slower, but leaves no stale remote files.

.PARAMETER Launch
    Launch the title on the console after deploying.

.PARAMETER ConsoleGodotExe
    A Middleware console fork. Falls back to $env:GODOT_CONSOLE, then the known
    local checkout path.

.EXAMPLE
    .\tools\deploy-console.ps1

.EXAMPLE
    .\tools\deploy-console.ps1 -ConsoleAddress 192.168.1.42 -Configuration debug -Launch

.EXAMPLE
    .\tools\deploy-console.ps1 -SkipExport -SyncExact
#>
[CmdletBinding()]
param(
    [ValidateSet('debug', 'release')][string]$Configuration = 'release',
    [switch]$Clean,
    [switch]$SkipExport,
    [string]$ConsoleAddress,
    [switch]$SyncExact,
    [switch]$Launch,
    [string]$ConsoleGodotExe
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'common.ps1')

$xbapp = Get-GdkTool 'xbapp.exe'
$preset = Get-ExportPreset -Name $script:ConsolePresetName
$layoutDir = $preset.OutputDir
$consoleExecutable = Get-GameConfigExecutable -DeviceFamily 'Scarlett'

# `xbapp` takes its connection options *before* the command name.
$globalArgs = @()
if ($ConsoleAddress) { $globalArgs += @('/X', $ConsoleAddress) }


if (-not $SkipExport) {
    $exportArgs = @{
        Target        = 'console'
        Configuration = $Configuration
    }
    if ($Clean) { $exportArgs['Clean'] = $true }
    if ($ConsoleGodotExe) { $exportArgs['ConsoleGodotExe'] = $ConsoleGodotExe }

    & (Join-Path $PSScriptRoot 'export.ps1') @exportArgs
}


Write-Step 'Checking the layout'
foreach ($required in @($preset.ExportPath, (Join-Path $layoutDir 'MicrosoftGame.config'))) {
    if (-not (Test-Path -LiteralPath $required)) {
        Fail ("Missing $required.`n" +
            'Run this script without -SkipExport to produce a complete console layout.')
    }
}

# The exporter names the binary after the preset's export_path, while the
# console registers whatever MicrosoftGame.config declares. A mismatch deploys
# fine and then fails to launch, so catch it here.
$exportedName = Split-Path -Leaf $preset.ExportPath
if ($exportedName -ne $consoleExecutable.Name) {
    Fail ("Layout mismatch: the '$($script:ConsolePresetName)' preset exports " +
        "'$exportedName' but MicrosoftGame.config declares '$($consoleExecutable.Name)' " +
        "for TargetDeviceFamily=`"Scarlett`". Align export_presets.cfg with the config.")
}

$stale = Get-ChildItem -LiteralPath $layoutDir -Filter '*.exe' -File |
    Where-Object { $_.Name -ne $consoleExecutable.Name }
if ($stale) {
    Write-Warning ("The layout contains executables the package does not declare, and they will " +
        "be deployed too:`n  " + (($stale | ForEach-Object { $_.Name }) -join "`n  ") +
        "`nRe-run with -Clean to rebuild the layout from scratch.")
}

$layoutSize = (Get-ChildItem -LiteralPath $layoutDir -Recurse -File |
    Measure-Object -Property Length -Sum).Sum
Write-Detail ("Layout: $layoutDir ({0:N0} MB)" -f ($layoutSize / 1MB))


Write-Step 'Deploying to the console'
if ($ConsoleAddress) {
    Write-Detail "Target: $ConsoleAddress"
} else {
    Write-Detail 'Target: default console (set with xbconnect; pass -ConsoleAddress to override).'
}

$deployArgs = $globalArgs + @('deploy', $layoutDir)
if ($SyncExact) { $deployArgs += '/S' }

$deploy = Invoke-ToolOrFail `
    -FilePath $xbapp `
    -Arguments $deployArgs `
    -FailureMessage 'xbapp deploy failed'

# `xbapp deploy` prints the package full name and every registered AUMID.
$aumid = ([regex]::Matches($deploy.Output, '\S+!' + [regex]::Escape($consoleExecutable.Id) + '\b') |
    Select-Object -First 1).Value

Write-Success 'Deployed.'
if ($aumid) { Write-Success "AUMID: $aumid" }


if ($Launch) {
    if (-not $aumid) {
        Fail ('Could not determine the AUMID from the xbapp deploy output, so there is nothing ' +
            'to launch. Run "xbapp list" on the console and launch it by hand.')
    }
    Write-Step "Launching $aumid"
    Invoke-ToolOrFail `
        -FilePath $xbapp `
        -Arguments ($globalArgs + @('launch', $aumid)) `
        -FailureMessage 'xbapp launch failed' | Out-Null
}
