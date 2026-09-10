<#
.SYNOPSIS
    Validates MicrosoftGame.config against the constraints the GDK enforces at runtime
    and at package time.

.DESCRIPTION
    MicrosoftGame.config is read by the GDK when the runtime initializes, and by the
    addon's export platform when packaging. Both failure modes are quiet: a malformed
    file makes GDK.initialize() fail with an HRESULT and nothing else, while the game
    keeps running with every platform service unavailable. Godot itself still exits 0,
    so the headless parse job does not notice.

    Every rule below corresponds to a hazard documented in the comment block at the top
    of MicrosoftGame.config itself.

.EXAMPLE
    .\tools\check-game-config.ps1
    .\tools\check-game-config.ps1 -Path MicrosoftGame.config
#>
[CmdletBinding()]
param(
    [string]$Path = (Join-Path $PSScriptRoot '..\MicrosoftGame.config')
)

$ErrorActionPreference = 'Stop'
$problems = [System.Collections.Generic.List[string]]::new()

if (-not (Test-Path $Path)) {
    Write-Host "check-game-config: FAIL - $Path not found." -ForegroundColor Red
    exit 1
}

$raw = Get-Content $Path -Raw

# 1. Well-formedness. The usual way to break this is writing a double hyphen inside the
#    comment block as an em dash; XML forbids '--' in comments, and the GDK then fails
#    to parse the whole file.
try {
    $doc = New-Object System.Xml.XmlDocument
    $doc.LoadXml($raw)
}
catch {
    $detail = $_.Exception.InnerException
    if ($null -eq $detail) { $detail = $_.Exception }
    Write-Host "check-game-config: FAIL - not well-formed XML." -ForegroundColor Red
    Write-Host "  $($detail.Message)"
    Write-Host "  Note: '--' is illegal inside an XML comment; use an em dash instead."
    exit 1
}

$game = $doc.Game

# 2. The simplified user model requires both identifiers. Omit either and the process is
#    killed with 0x89240102 at GDExtension load, with no other diagnostic.
foreach ($element in 'TitleId', 'MSAAppId') {
    $value = $game.$element
    if ([string]::IsNullOrWhiteSpace([string]$value)) {
        $problems.Add("<$element> is missing or empty. The GDK requires it; without it the process is killed at GDExtension load.")
    }
}

if ([string]::IsNullOrWhiteSpace([string]$game.Identity.Name)) {
    $problems.Add('<Identity Name="..."> is missing or empty.')
}

# 3. Executable order is load-bearing. The "XBOX on PC" export platform finds the staged
#    .exe name by regex-searching the raw file text for the first Executable element's
#    Name attribute. The search is not XML-aware, so a PC entry that is not first makes a
#    PC export emit a console-named binary.
$executables = @($game.ExecutableList.Executable)
if ($executables.Count -eq 0) {
    $problems.Add('<ExecutableList> declares no <Executable>.')
}
else {
    if ($executables[0].TargetDeviceFamily -ne 'PC') {
        $problems.Add("The first <Executable> must target PC (found '$($executables[0].TargetDeviceFamily)'). The PC export platform reads the first Name attribute it finds.")
    }
    $ids = $executables | ForEach-Object { $_.Id }
    $duplicates = $ids | Group-Object | Where-Object Count -gt 1
    foreach ($duplicate in $duplicates) {
        $problems.Add("Duplicate Executable Id '$($duplicate.Name)'. Ids must be unique or config validation fails at package time.")
    }
}

# 4. Same non-XML-aware regex: an Executable start-tag spelled inside any comment would
#    be matched ahead of the real one, naming the binary after the comment. Every comment
#    is checked, not just the first -- a later one still precedes <ExecutableList>.
foreach ($comment in [regex]::Matches($raw, '(?s)<!--.*?-->')) {
    if ($comment.Value -match '<Executable[^>]*\bName\s*=') {
        $problems.Add('A comment block spells an <Executable ... Name="..."> start-tag. The export platform''s regex is not XML-aware and will match it.')
        break
    }
}

# 5. Godot's XMLParser re-emits the root closing tag when anything follows it, which makes
#    the GDK export plugin pop past the bottom of its element stack and abort the export.
if ($raw -notmatch '</Game>\s*$') {
    $problems.Add('Content follows the closing </Game> tag. Trailing text breaks the GDK export plugin''s parser.')
}

if ($problems.Count -gt 0) {
    Write-Host "check-game-config: FAIL - $($problems.Count) problem(s) in $Path" -ForegroundColor Red
    foreach ($problem in $problems) { Write-Host "  - $problem" }
    exit 1
}

Write-Host 'check-game-config: clean - MicrosoftGame.config is well-formed and complete.' -ForegroundColor Green
exit 0
