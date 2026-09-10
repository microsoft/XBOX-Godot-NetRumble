<#
.SYNOPSIS
    Fails if any "this is a port" framing has crept back into the sample.

.DESCRIPTION
    NetRumble is presented as the reference sample for Microsoft GDK and PlayFab
    integration in Godot. Nothing in it should describe itself by comparison to a
    prior implementation: a reader learning the platform has no context for such a
    comparison, and it undercuts the sample's standing as the canonical example.

    This script is the durable guarantee behind that. It is run by CI and can be
    run locally at any time:

        .\tools\check-deport.ps1

    The addons/ tree is deliberately out of scope. It is vendored third-party code
    and is not ours to rewrite.

.PARAMETER Detailed
    List every offending line rather than a per-file count.

.OUTPUTS
    Exit code 0 when clean, 1 when references are found.
#>
[CmdletBinding()]
param(
    [switch]$Detailed
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$repoRoot = Split-Path -Parent $PSScriptRoot

# Each pattern is a regex matched case-insensitively against every scanned line.
# Keep these anchored on word boundaries: a bare "port" matches export, support,
# transport, important and report, and would make this check useless.
$patterns = [ordered]@{
    'C++ reference'        = 'C\+\+'
    'C++ source file'      = '\.cpp\b'
    'C++ source path'      = '\bGame/(UI|Gameplay|Screens|Managers|Assets)\b'
    'Upstream repo'        = 'PlayFabXPlat'
    'XNA reference'        = '\bXNA\b'
    'Port framing'         = '\b(is|as)\s+a\s+port\b|\bthis\s+port\b|\bthe\s+port\b|\bported\s+(from|to)\b|\bports\s+the\b|\bport\s+of\b|\bporting\b|\bre-?implement(s|ed|ation)\s+of\b'
    'Original comparison'  = '\bthe\s+original\b|\boriginal\s+sample\b|\bsource\s+sample\b'
}

# Files that define the sample's own voice. addons/ is excluded as vendored code.
$targets = @(
    'README.md'
    'project.godot'
    'MicrosoftGame.config'
)
$targetDirs = @('scripts', 'docs', 'tools')

$files = [System.Collections.Generic.List[string]]::new()
foreach ($t in $targets) {
    $p = Join-Path $repoRoot $t
    if (Test-Path $p) { $files.Add($p) }
}
foreach ($d in $targetDirs) {
    $p = Join-Path $repoRoot $d
    if (-not (Test-Path $p)) { continue }
    Get-ChildItem -Path $p -Recurse -File -Include *.gd, *.md, *.ps1, *.py, *.cfg |
        ForEach-Object { $files.Add($_.FullName) }
}

# This script necessarily contains the very strings it searches for.
$selfPath = $PSCommandPath
$findings = [System.Collections.Generic.List[object]]::new()

foreach ($file in $files) {
    if ($file -eq $selfPath) { continue }
    # Wrapped in @() because Get-Content returns a bare [string] for a single-line
    # file, and under Set-StrictMode that has no .Count -- which would abort this
    # gate with an error unrelated to what it checks. Indexing a string would also
    # walk characters rather than lines.
    $lines = @(Get-Content -LiteralPath $file -ErrorAction SilentlyContinue)
    if ($lines.Count -eq 0) { continue }

    for ($i = 0; $i -lt $lines.Count; $i++) {
        foreach ($name in $patterns.Keys) {
            if ($lines[$i] -match $patterns[$name]) {
                $findings.Add([PSCustomObject]@{
                    File    = $file.Substring($repoRoot.Length + 1)
                    Line    = $i + 1
                    Kind    = $name
                    Text    = $lines[$i].Trim()
                })
            }
        }
    }
}

if ($findings.Count -eq 0) {
    Write-Host "check-deport: clean - no port framing found in $($files.Count) files." -ForegroundColor Green
    exit 0
}

Write-Host "check-deport: found $($findings.Count) reference(s) that describe this sample as a port.`n" -ForegroundColor Red

if ($Detailed) {
    foreach ($f in $findings) {
        Write-Host ("  {0}:{1}" -f $f.File, $f.Line) -ForegroundColor Yellow
        Write-Host ("      [{0}] {1}" -f $f.Kind, $f.Text)
    }
} else {
    $findings |
        Group-Object File |
        Sort-Object Count -Descending |
        ForEach-Object { Write-Host ("  {0,4}  {1}" -f $_.Count, $_.Name) }
    Write-Host "`nRe-run with -Detailed to see each line."
}

Write-Host "`nNetRumble is the reference GDK + PlayFab sample. It should explain the" -ForegroundColor Cyan
Write-Host "platform on its own terms, not by comparison to a previous implementation." -ForegroundColor Cyan
exit 1
