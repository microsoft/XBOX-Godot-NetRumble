<#
.SYNOPSIS
    Validates the PC and Xbox MicrosoftGame.config files, and the export preset
    settings that point at them, against the constraints the GDK enforces at
    runtime and at package time.

.DESCRIPTION
    Each target has its own config:

      PC        MicrosoftGame.config at the project root.
      Scarlett  the file the "Xbox Series X|S" preset names in
                application/game_config (xbox/MicrosoftGame.config).

    MicrosoftGame.config is read by the GDK when the runtime initializes, and by
    the export platforms when packaging. Both failure modes are quiet: a
    malformed file makes GDK.initialize() fail with an HRESULT and nothing else,
    while the game keeps running with every platform service unavailable. Godot
    itself still exits 0, so the headless parse job does not notice.

    Most rules below correspond to a hazard documented in the comment block at
    the top of the root MicrosoftGame.config. The rest keep the two configs from
    drifting apart and keep package output and signing keys out of the
    committed presets.

.EXAMPLE
    .\tools\check-game-config.ps1

.EXAMPLE
    .\tools\check-game-config.ps1 -Path MicrosoftGame.config

.PARAMETER Path
    Check one config on its own instead of the committed pair. The script reads
    the device family from the file's Executable element and runs only the
    rules that look at a single file. It skips the checks that compare the two
    configs and the checks on export_presets.cfg. A PC config's logo paths
    resolve from the file's folder; a Scarlett config's bare logo names resolve
    from storelogos.
#>
[CmdletBinding()]
param(
    [string]$Path
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'common.ps1')

$problems = [System.Collections.Generic.List[string]]::new()

# The committed location of the console config. The console preset must name it.
$expectedConsoleConfig = 'xbox/MicrosoftGame.config'
$expectedMetadataFolder = 'storelogos'

# ShellVisuals attributes that name image files. These are the ones the export
# platforms stage, and the ones makepkg and wdapp fail on when missing.
$logoAttributes = @('StoreLogo', 'Square150x150Logo', 'Square44x44Logo', 'Square480x480Logo', 'SplashScreenImage')

# Top-level elements that legitimately differ between the two configs.
$targetSpecificElements = @('ExecutableList', 'DesktopRegistration')


function Add-Problem {
    param([string]$Label, [string]$Message)
    $problems.Add("[$Label] $Message")
}

# Loads one config. Returns the parsed document, or $null after recording why it
# could not be read. Applies the rules that need the raw text.
function Read-GameConfig {
    param([string]$Label, [string]$Path)

    if (-not (Test-Path -LiteralPath $Path)) {
        Add-Problem $Label "$Path not found."
        return $null
    }

    $raw = Get-Content -LiteralPath $Path -Raw

    # 1. Well-formedness. The usual way to break this is writing a double hyphen
    #    inside the comment block as an em dash; XML forbids '--' in comments, and
    #    the GDK then fails to parse the whole file.
    $doc = New-Object System.Xml.XmlDocument
    try {
        $doc.LoadXml($raw)
    }
    catch {
        $detail = $_.Exception.InnerException
        if ($null -eq $detail) { $detail = $_.Exception }
        $message = "Not well-formed XML: $($detail.Message)"
        if ($detail.Message -match 'comment') {
            $message += " Note: '--' is illegal inside an XML comment; use an em dash instead."
        }
        Add-Problem $Label $message
        return $null
    }

    # 4. The "XBOX on PC" export platform regex-searches the raw text for the first
    #    Executable element's Name attribute, and the search is not XML-aware: a
    #    start-tag spelled inside any comment would be matched ahead of the real
    #    one. Applied to both configs so the rule does not depend on which file a
    #    platform reads.
    foreach ($comment in [regex]::Matches($raw, '(?s)<!--.*?-->')) {
        if ($comment.Value -match '<Executable[^>]*\bName\s*=') {
            Add-Problem $Label ('A comment block spells an <Executable ... Name="..."> start-tag. ' +
                'The export platform''s regex is not XML-aware and will match it.')
            break
        }
    }

    # 5. Godot's XMLParser re-emits the root closing tag when anything follows it,
    #    which makes the export parser pop past the bottom of its element stack
    #    and abort the export.
    if ($raw -notmatch '</Game>\s*$') {
        Add-Problem $Label 'Content follows the closing </Game> tag. Trailing text breaks the export parser.'
    }

    return $doc
}

# Rules that apply to each config on its own.
function Test-GameConfig {
    param([string]$Label, [System.Xml.XmlDocument]$Doc, [string]$DeviceFamily)

    $game = $Doc.Game

    # 2. The simplified user model requires both identifiers. Omit either and the
    #    process is killed with 0x89240102 at GDExtension load, with no other
    #    diagnostic.
    foreach ($element in 'TitleId', 'MSAAppId') {
        if ([string]::IsNullOrWhiteSpace([string]$game.$element)) {
            Add-Problem $Label "<$element> is missing or empty. The GDK requires it; without it the process is killed at GDExtension load."
        }
    }
    if ([string]::IsNullOrWhiteSpace([string]$game.Identity.Name)) {
        Add-Problem $Label '<Identity Name="..."> is missing or empty.'
    }

    # 3. One executable, for this config's device family. Each export platform
    #    takes the binary name from the first Executable.
    $executables = @($game.ExecutableList.Executable)
    if ($executables.Count -ne 1) {
        Add-Problem $Label "<ExecutableList> must declare exactly one <Executable> (found $($executables.Count))."
    }
    elseif ($executables[0].TargetDeviceFamily -ne $DeviceFamily) {
        Add-Problem $Label ("The <Executable> must target $DeviceFamily " +
            "(found '$($executables[0].TargetDeviceFamily)').")
    }

    # DesktopRegistration is PC-only.
    $registration = $game.SelectSingleNode('DesktopRegistration')
    if ($DeviceFamily -eq 'PC') {
        $protocolExe = [string]$game.DesktopRegistration.MultiplayerProtocol.Executable
        if ($executables.Count -eq 1 -and $protocolExe -ne $executables[0].Name) {
            Add-Problem $Label ("<DesktopRegistration><MultiplayerProtocol Executable=`"$protocolExe`"> " +
                "must name the PC executable '$($executables[0].Name)'.")
        }
    }
    elseif ($registration) {
        Add-Problem $Label '<DesktopRegistration> is PC-only and must not appear in the console config.'
    }
}

function Get-TopLevelElements {
    param([System.Xml.XmlDocument]$Doc)
    return @($Doc.DocumentElement.ChildNodes | Where-Object { $_ -is [System.Xml.XmlElement] })
}

function Format-Xml {
    param([string]$Text)
    return ($Text -replace '\s+', ' ').Trim()
}

# Every value the two configs share must match. Logo attributes are compared by
# file name, because the console config uses bare names.
function Compare-SharedValues {
    param([System.Xml.XmlDocument]$PcDoc, [System.Xml.XmlDocument]$ConsoleDoc)

    $pcElements = Get-TopLevelElements $PcDoc | Where-Object { $_.Name -notin $targetSpecificElements }
    $consoleElements = Get-TopLevelElements $ConsoleDoc | Where-Object { $_.Name -notin $targetSpecificElements }

    $names = @($pcElements.Name) + @($consoleElements.Name) | Select-Object -Unique
    foreach ($name in $names) {
        $pc = @($pcElements | Where-Object Name -eq $name)
        $console = @($consoleElements | Where-Object Name -eq $name)
        if ($pc.Count -ne $console.Count) {
            Add-Problem 'shared' ("<$name> appears $($pc.Count) time(s) in the PC config and " +
                "$($console.Count) time(s) in the console config. Both configs must declare the same elements.")
            continue
        }

        for ($i = 0; $i -lt $pc.Count; $i++) {
            $attributeNames = @($pc[$i].Attributes.Name) + @($console[$i].Attributes.Name) | Select-Object -Unique
            foreach ($attribute in $attributeNames) {
                $pcValue = [string]$pc[$i].GetAttribute($attribute)
                $consoleValue = [string]$console[$i].GetAttribute($attribute)
                if ($attribute -in $logoAttributes) {
                    $pcValue = [System.IO.Path]::GetFileName($pcValue)
                    $consoleValue = [System.IO.Path]::GetFileName($consoleValue)
                }
                if ($pcValue -cne $consoleValue) {
                    Add-Problem 'shared' ("<$name $attribute> differs: PC '$pcValue', console '$consoleValue'.")
                }
            }

            $pcInner = Format-Xml $pc[$i].InnerXml
            $consoleInner = Format-Xml $console[$i].InnerXml
            if ($pcInner -cne $consoleInner) {
                Add-Problem 'shared' "<$name> content differs: PC '$pcInner', console '$consoleInner'."
            }
        }
    }
}

# Each logo the config names must exist where its export platform looks.
#   PC       stages each logo at its path relative to the project root.
#   console  places the logos beside the config at the package root, so the
#            config names bare files in packaging/metadata_folder.
function Test-Logos {
    param([string]$Label, [System.Xml.XmlDocument]$Doc, [string]$LogoRoot, [switch]$BareNames)

    foreach ($attribute in $logoAttributes) {
        $value = [string]$Doc.Game.ShellVisuals.GetAttribute($attribute)
        if (-not $value) {
            Add-Problem $Label "<ShellVisuals $attribute> is missing."
            continue
        }
        if ($BareNames -and $value -match '[\\/]') {
            Add-Problem $Label ("<ShellVisuals $attribute=`"$value`"> must be a bare file name; " +
                'the exporter copies the logos to the package root.')
            continue
        }
        $path = Join-Path $LogoRoot $value.Replace('/', '\')
        if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
            Add-Problem $Label "<ShellVisuals $attribute=`"$value`"> does not resolve: $path not found."
        }
    }
}

function Find-Preset {
    param([object[]]$Presets, [string]$Name)

    $preset = $Presets | Where-Object { $_.Name -eq $Name } | Select-Object -First 1
    if (-not $preset) {
        Add-Problem 'export_presets.cfg' ("The '$Name' preset is missing. A console-fork editor drops the " +
            '"XBOX on PC" preset when it saves export_presets.cfg; restore it from git.')
    }
    return $preset
}

function Complete-Check {
    param([string]$CleanMessage)

    if ($problems.Count -gt 0) {
        Write-Host "check-game-config: FAIL - $($problems.Count) problem(s)" -ForegroundColor Red
        foreach ($problem in $problems) { Write-Host "  - $problem" }
        exit 1
    }
    Write-Host "check-game-config: clean - $CleanMessage" -ForegroundColor Green
    exit 0
}


# ── One file (-Path) ────────────────────────────────────────────────────────

if ($Path) {
    $label = Split-Path -Leaf $Path
    $doc = Read-GameConfig -Label $label -Path $Path
    if (-not $doc) { Complete-Check -CleanMessage '' }

    $family = [string](@($doc.Game.ExecutableList.Executable) | Select-Object -First 1).TargetDeviceFamily
    if ($family -notin @('PC', 'Scarlett')) {
        Add-Problem $label ("Cannot tell the device family: the first <Executable> must set " +
            "TargetDeviceFamily to PC or Scarlett (found '$family').")
        Complete-Check -CleanMessage ''
    }

    Test-GameConfig -Label $label -Doc $doc -DeviceFamily $family
    if ($family -eq 'PC') {
        Test-Logos -Label $label -Doc $doc -LogoRoot (Split-Path -Parent (Resolve-Path -LiteralPath $Path).Path)
    } else {
        Test-Logos -Label $label -Doc $doc -LogoRoot (Resolve-ProjectPath -Path $expectedMetadataFolder) -BareNames
    }

    Write-Host ('check-game-config: -Path checks one file only; the shared-value and ' +
        'export_presets.cfg checks were skipped.') -ForegroundColor DarkGray
    Complete-Check -CleanMessage "$Path is a well-formed $family config."
}


# ── Presets ────────────────────────────────────────────────────────────────

$presets = @(Get-ExportPresets)
$pcPreset = Find-Preset $presets $script:PcPresetName
$consolePreset = Find-Preset $presets $script:ConsolePresetName

# Package output and key files are chosen in the editor for one build and never
# committed: a key file path is machine-specific, and the scripts and docs
# assume the committed presets produce loose builds.
if ($pcPreset) {
    if ((Get-ExportPresetMode -Preset $pcPreset) -ne 'Loose') {
        Add-Problem $script:PcPresetName 'dev/register_loose must be true in the committed preset.'
    }
    if (Get-PresetOption -Preset $pcPreset -Name 'packaging/ekb_file') {
        Add-Problem $script:PcPresetName 'packaging/ekb_file must be empty in the committed preset. Never commit a key path.'
    }
}

$consolePath = $null
$metadataRoot = $null
if ($consolePreset) {
    $configured = Get-PresetOption -Preset $consolePreset -Name 'application/game_config'
    if ($configured -ne $expectedConsoleConfig) {
        Add-Problem $script:ConsolePresetName "application/game_config must be `"$expectedConsoleConfig`" (found `"$configured`")."
    }
    $consolePath = Resolve-ProjectPath -Path $expectedConsoleConfig

    # Both spellings, with and without a trailing slash, are accepted.
    $metadata = (Get-PresetOption -Preset $consolePreset -Name 'packaging/metadata_folder').TrimEnd('/', '\')
    if ($metadata -ne $expectedMetadataFolder) {
        Add-Problem $script:ConsolePresetName "packaging/metadata_folder must be `"$expectedMetadataFolder`" (found `"$metadata`")."
    }
    $metadataRoot = Resolve-ProjectPath -Path $expectedMetadataFolder

    if ((Get-ExportPresetMode -Preset $consolePreset) -ne 'Loose') {
        Add-Problem $script:ConsolePresetName 'packaging/package_type must be 1 (Loose) in the committed preset.'
    }
    if (Get-PresetOption -Preset $consolePreset -Name 'packaging/secret_key') {
        Add-Problem $script:ConsolePresetName 'packaging/secret_key must be empty in the committed preset. Never commit a key path.'
    }
}


# ── Configs ────────────────────────────────────────────────────────────────

$pcPath = Get-GameConfigPath -DeviceFamily 'PC'
$pcDoc = Read-GameConfig -Label 'PC config' -Path $pcPath
if ($pcDoc) {
    Test-GameConfig -Label 'PC config' -Doc $pcDoc -DeviceFamily 'PC'
    Test-Logos -Label 'PC config' -Doc $pcDoc -LogoRoot (Split-Path -Parent $pcPath)
}

$consoleDoc = $null
if ($consolePath) {
    $consoleDoc = Read-GameConfig -Label 'console config' -Path $consolePath
    if ($consoleDoc) {
        Test-GameConfig -Label 'console config' -Doc $consoleDoc -DeviceFamily 'Scarlett'
        Test-Logos -Label 'console config' -Doc $consoleDoc -LogoRoot $metadataRoot -BareNames
    }
}

if ($pcDoc -and $consoleDoc) {
    Compare-SharedValues -PcDoc $pcDoc -ConsoleDoc $consoleDoc
}

# The console preset carries its own copies of the identity values under
# application/. The exporter uses them only when no game config is set, but
# they must never disagree with the config it does use.
if ($consolePreset -and $consoleDoc) {
    $game = $consoleDoc.Game
    $expected = [ordered]@{
        'application/product_name'    = [string]$game.Identity.Name
        'application/company_name'    = ([string]$game.Identity.Publisher) -replace '^CN=', ''
        'application/product_version' = [string]$game.Identity.Version
        'application/app_id'          = [string]$game.MSAAppId
        'application/title_id'        = [string]$game.TitleId
        'application/store_id'        = [string]$game.StoreId
    }
    foreach ($option in $expected.Keys) {
        $actual = Get-PresetOption -Preset $consolePreset -Name $option
        if ($actual -cne $expected[$option]) {
            Add-Problem $script:ConsolePresetName "$option is '$actual' but the console config says '$($expected[$option])'."
        }
    }
}


Complete-Check -CleanMessage ('both MicrosoftGame.config files are well-formed, ' +
    'agree on shared values, and match the committed presets.')
