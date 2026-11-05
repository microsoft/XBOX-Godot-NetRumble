#requires -Version 7.0
param(
    [Parameter(Mandatory = $true)]
    [string] $Godot,
    [ValidateSet('All', 'Multiplayer', 'UI')]
    [string] $Suite = 'All',
    [string] $ScreenshotDirectory = '',
    [ValidateRange(1, 600)]
    [int] $TimeoutSeconds = 120
)

$ErrorActionPreference = 'Stop'
$repo = Split-Path $PSScriptRoot -Parent
$exe = (Get-Command $Godot -ErrorAction Stop).Source
$sandbox = Join-Path ([IO.Path]::GetTempPath()) ("netrumble-save-tests-" + [guid]::NewGuid().ToString('N'))
$locks = [Collections.Generic.List[IO.FileStream]]::new()
if ($ScreenshotDirectory -and $Suite -ne 'UI') {
    throw '-ScreenshotDirectory requires -Suite UI.'
}
if ($ScreenshotDirectory) {
    $ScreenshotDirectory = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($ScreenshotDirectory)
    New-Item -ItemType Directory -Force -Path $ScreenshotDirectory | Out-Null
}
# Branding art ships as 2x vector rasters with lossless full mip chains and straight alpha, and
# the background-motion rasters are lossless without mipmaps or alpha-border fixing (the strand
# layer's LA8 colour must survive under zero alpha). Only these .import sidecars are preserved so
# the suites exercise the production settings; every other texture imports with defaults.
# .uid sidecars are not listed: the copy below never filters them, and a script or shader that
# has none yet (a new file before its first editor import) gets one from the sandbox import.
$preservedImports = @(
    'assets\textures\UI\Logo\Logo_NetRumbleTitle.svg.import'
    'assets\textures\UI\Logo\Logo_NetRumbleMenu.svg.import'
    'assets\textures\UI\Logo\Logo_XboxMark.svg.import'
    'assets\textures\UI\Logo\Logo_XboxGlass.png.import'
    'assets\textures\UI\Loading\Loading_ProgressRing.svg.import'
    'assets\textures\UI\Background\Motion\Waves_DotAtlas.png.import'
    'assets\textures\UI\Background\Motion\Waves_Strands_band.png.import'
)
foreach ($relative in $preservedImports) {
    foreach ($required in @($relative, ($relative -replace '\.import$', ''))) {
        if (-not (Test-Path -LiteralPath (Join-Path $repo $required) -PathType Leaf)) {
            throw "Allowlisted branding import is missing from the repository: $required"
        }
    }
}

function Invoke-TestGodot([string[]] $Arguments, [string] $InterruptedMarker = '') {
    $start = [Diagnostics.ProcessStartInfo]::new()
    $start.FileName = $exe
    $start.UseShellExecute = $false
    $start.RedirectStandardOutput = $true
    $start.RedirectStandardError = $true
    foreach ($argument in $Arguments) { $start.ArgumentList.Add($argument) }
    foreach ($name in @('APPDATA', 'LOCALAPPDATA', 'XDG_DATA_HOME', 'XDG_CONFIG_HOME')) {
        $start.Environment[$name] = Join-Path $sandbox 'userdata'
    }
    $start.Environment['NR_SAVE_TEST_ROOT'] = $sandbox
    $start.Environment['NR_SAVE_TEST_SUITE'] = $Suite
    $start.Environment['NR_UI_SCREENSHOT_ROOT'] = $ScreenshotDirectory
    $start.Environment['PF_CUSTOM_ID'] = 'A'
    $start.Environment['PF_TITLE_ID'] = ''
    $process = [Diagnostics.Process]::Start($start)
    try {
        $stdout = $process.StandardOutput.ReadToEndAsync()
        $stderr = $process.StandardError.ReadToEndAsync()
        if (-not $process.WaitForExit($TimeoutSeconds * 1000)) {
            $process.Kill($true)
            $process.WaitForExit()
            Write-Host ($stdout.GetAwaiter().GetResult() + $stderr.GetAwaiter().GetResult())
            throw "Godot save tests exceeded $TimeoutSeconds seconds."
        }
        $output = $stdout.GetAwaiter().GetResult() + $stderr.GetAwaiter().GetResult()
        if ($InterruptedMarker) {
            # Godot's Windows self-kill can exit 0; require the kill-site marker and
            # absence of the child's survival/normal-teardown failure sentinels.
            if (-not $output.Contains($InterruptedMarker) `
                -or $output -match 'SCRIPT ERROR|SAVE TEST FAIL|Parse Error|(?m)^ERROR:') {
                Write-Host $output
                throw "Expected a marked, forcibly interrupted child (exit $($process.ExitCode))."
            }
            Write-Host "CASE: $InterruptedMarker"
            return $output
        }
        if ($process.ExitCode -ne 0 -or $output -match '(?m)SCRIPT ERROR|Parse Error|^ERROR:|Failed to load script|Cannot open file|SAVE TEST FAIL') {
            Write-Host $output
            throw "Godot save tests failed (exit $($process.ExitCode))."
        }
        $output -split '\r?\n' | Where-Object { $_ -match '^CASE:|^SAVE TESTS PASSED:' } | ForEach-Object { Write-Host $_ }
        return $output
    }
    finally {
        $process.Dispose()
    }
}

function Assert-SuspendDiagnostics([string] $Output, [int] $ExpectedCount) {
    $blocks = [regex]::Matches($Output, '(?ms)^\[Lifecycle\] Suspend entry\r?\n(?<body>.*?)^\[Lifecycle\] Suspend exit save_completed=(?<saved>true|false) match_abandoned=(true|false) elapsed_ms=(?<elapsed>\d+\.\d{3})\r?$')
    if ($blocks.Count -ne $ExpectedCount) { throw "Expected $ExpectedCount complete suspend diagnostic blocks; got $($blocks.Count)." }
    foreach ($block in $blocks) {
        $lines = $block.Groups['body'].Value.TrimEnd() -split '\r?\n'
        if ($lines[0] -notmatch '^\[SaveCommit\] entry ready=(true|false) store_bound=(true|false)$') {
            throw 'Suspend diagnostics missing privacy-safe readiness.'
        }
        $ready = $Matches[1] -eq 'true'
        $cursor = 1
        $errors = 0
        $categories = @('profile', 'history', 'stats')
        for ($index = 0; $index -lt 3; $index++) {
            $prefix = "[SaveCommit] payload=$($categories[$index])"
            if ($ready) {
                if ($lines[$cursor++] -ne "$prefix action=attempt") { throw 'Missing ordered payload attempt diagnostic.' }
                $outcome = $lines[$cursor++]
                if ($outcome -eq "$prefix result=error") { $errors++ }
                elseif ($outcome -ne "$prefix result=success") { throw 'Missing payload success/error diagnostic.' }
            }
            else {
                if ($lines[$cursor++] -ne "$prefix action=skipped reason=no_ready_account") { throw 'Missing explicit payload skip reason.' }
            }
        }
        $result = if (-not $ready) { 'no_ready_account' } elseif ($errors) { 'failed_writes' } else { 'success' }
        if ($lines[$cursor++] -notmatch "^\[SaveCommit\] exit result=$result elapsed_ms=(\d+\.\d{3})$" `
            -or $cursor -ne $lines.Count) {
            throw 'Unexpected suspend diagnostic content or missing commit outcome/time.'
        }
        $saveElapsed = [double]::Parse($Matches[1], [Globalization.CultureInfo]::InvariantCulture)
        $handlerElapsed = [double]::Parse($block.Groups['elapsed'].Value, [Globalization.CultureInfo]::InvariantCulture)
        if ($handlerElapsed -lt $saveElapsed -or ($block.Groups['saved'].Value -eq 'true') -ne ($ready -and $errors -eq 0)) {
            throw 'Handler exit must follow persistence and report its actual outcome.'
        }
    }
}

function Initialize-IntegrityFixture([string] $Name) {
    $folder = Join-Path $sandbox "test-data\$Name\NetRumble"
    New-Item -ItemType Directory -Force -Path $folder | Out-Null
    $payload = '{"musicVolume":0.3}'
    $hash = [Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes("1`n$payload"))
    $record = @{ sequence = 1; payload = $payload; sha256 = [Convert]::ToHexString($hash).ToLowerInvariant() } |
        ConvertTo-Json -Compress
    [IO.File]::WriteAllText((Join-Path $folder 'profile.json'), $record)
    return $folder
}

try {
    New-Item -ItemType Directory -Path $sandbox | Out-Null
    # Copy source/resources, never shipping settings, native addons, user data or imports
    # other than the allowlisted branding sidecars.
    foreach ($directory in @('scripts', 'scenes', 'assets', 'tools\tests')) {
        $source = Join-Path $repo $directory
        foreach ($file in Get-ChildItem $source -Recurse -File) {
            $relative = [IO.Path]::GetRelativePath($repo, $file.FullName)
            if ($file.Extension -eq '.import' -and $preservedImports -notcontains $relative) { continue }
            if ($relative.StartsWith('assets\audio\')) { continue }
            $destination = Join-Path $sandbox $relative
            New-Item -ItemType Directory -Force -Path (Split-Path $destination -Parent) | Out-Null
            Copy-Item -LiteralPath $file.FullName -Destination $destination
        }
    }
    foreach ($relative in $preservedImports) {
        if (-not (Test-Path -LiteralPath (Join-Path $sandbox $relative) -PathType Leaf)) {
            throw "Allowlisted branding import was not copied into the sandbox: $relative"
        }
    }
    $bootstrap = Join-Path $sandbox 'addons\godot_gdk\runtime'
    New-Item -ItemType Directory -Force -Path $bootstrap | Out-Null
    Copy-Item (Join-Path $repo 'tools\tests\bootstrap.gd') (Join-Path $bootstrap 'gdk_bootstrap.gd')
    $inputSection = [regex]::Match(
        (Get-Content -LiteralPath (Join-Path $repo 'project.godot') -Raw),
        '(?ms)^\[input\]\r?\n.*?(?=^\[|\z)')
    if (-not $inputSection.Success) { throw 'The production input action section is missing.' }
    $testProject = @'
config_version=5

[application]
config/name="NetRumble Save Tests"
run/main_scene="res://tools/tests/save_tests.tscn"
config/use_custom_user_dir=true
config/custom_user_dir="netrumble-save-tests"

[autoload]
Assets="*res://tools/tests/assets.gd"
AudioManager="*res://tools/tests/audio.gd"
PlayerProfile="*res://scripts/autoload/player_profile.gd"
Services="*res://tools/tests/services.gd"
NetManager="*res://scripts/autoload/net_manager.gd"
ScreenManager="*res://scripts/autoload/screen_manager.gd"
UIBackgroundMotion="*res://scripts/autoload/ui_background_motion.gd"
InviteRouter="*res://scripts/autoload/invite_router.gd"

[rendering]
renderer/rendering_method="gl_compatibility"

[gui]
theme/custom="res://assets/ui/netrumble.tres"
'@
    ($testProject + [Environment]::NewLine + $inputSection.Value) |
        Set-Content -LiteralPath (Join-Path $sandbox 'project.godot') -Encoding utf8
    $common = @('--headless', '--path', $sandbox, '--log-file', (Join-Path $sandbox 'godot.log'))
    $null = Invoke-TestGodot ($common + @('--import', '--quiet'))
    # Fail fast, before any suite: every script and scene must compile against the sandbox's own
    # autoload list. An import alone parses class names only, so an autoload the sandbox lacks
    # (an undeclared identifier) would otherwise surface halfway through a suite. The checker
    # exists only inside the disposable sandbox.
    @'
extends SceneTree

const ROOTS := ["res://scripts", "res://scenes", "res://tools/tests"]


func _initialize() -> void:
	var failures := PackedStringArray()
	var counts := {"gd": 0, "tscn": 0}
	for root: String in ROOTS:
		_walk(root, failures, counts)
	for failure: String in failures:
		print("SAVE TEST FAIL: sandbox does not compile: ", failure)
	print("CASE: sandbox compiles %d scripts and %d scenes before the suites" % [counts["gd"], counts["tscn"]])
	quit(1 if not failures.is_empty() else 0)


func _walk(path: String, failures: PackedStringArray, counts: Dictionary) -> void:
	for directory: String in DirAccess.get_directories_at(path):
		_walk(path.path_join(directory), failures, counts)
	for file: String in DirAccess.get_files_at(path):
		var extension := file.get_extension()
		if extension != "gd" and extension != "tscn":
			continue
		counts[extension] = int(counts[extension]) + 1
		if load(path.path_join(file)) == null:
			failures.append(path.path_join(file))
'@ | Set-Content -LiteralPath (Join-Path $sandbox 'sandbox_compile_check.gd') -Encoding utf8
    $null = Invoke-TestGodot ($common + @('--script', 'res://sandbox_compile_check.gd'))
    if ($Suite -eq 'All') {
    foreach ($mode in @('partial', 'complete')) {
        $null = Initialize-IntegrityFixture "crash-$mode"
        $null = Invoke-TestGodot -Arguments ($common + @('res://tools/tests/crash_writer.tscn', '--', $mode)) `
            -InterruptedMarker 'SAVE CRASH TEST: terminating writer after candidate bytes'
    }
    foreach ($mode in @('success', 'partial')) {
        $childOutput = Invoke-TestGodot -Arguments ($common + @('res://tools/tests/suspend_writer.tscn', '--', $mode)) `
            -InterruptedMarker 'SAVE SUSPEND TEST: terminating immediately after main notification returned'
        Assert-SuspendDiagnostics $childOutput 1
        $result = if ($mode -eq 'success') { 'success' } else { 'failed_writes' }
        if (-not $childOutput.Contains("[SaveCommit] exit result=$result ")) {
            throw "Terminated $mode child did not report its expected save result."
        }
    }
    # Real Windows handles: deny writes to the inactive slot, deny deletion of the
    # active slot, then permit buffered writes but reject their flush by byte lock.
    $folder = Initialize-IntegrityFixture 'locked-target'
    $locks.Add([IO.FileStream]::new((Join-Path $folder 'profile.json.alt'),
        [IO.FileMode]::OpenOrCreate, [IO.FileAccess]::ReadWrite, [IO.FileShare]::Read))
    $folder = Initialize-IntegrityFixture 'locked-current'
    $locks.Add([IO.FileStream]::new((Join-Path $folder 'profile.json'),
        [IO.FileMode]::Open, [IO.FileAccess]::ReadWrite, [IO.FileShare]::ReadWrite))
    $folder = Initialize-IntegrityFixture 'locked-candidate-delete'
    $locks.Add([IO.FileStream]::new((Join-Path $folder 'profile.json.alt'),
        [IO.FileMode]::OpenOrCreate, [IO.FileAccess]::ReadWrite, [IO.FileShare]::ReadWrite))
    $folder = Initialize-IntegrityFixture 'locked-flush'
    $flushLock = [IO.FileStream]::new((Join-Path $folder 'profile.json.alt'),
        [IO.FileMode]::OpenOrCreate, [IO.FileAccess]::ReadWrite, [IO.FileShare]::ReadWrite)
    $locks.Add($flushLock)
    $flushLock.Lock(0, 1048576)
    }
    $runArguments = $common
    if ($ScreenshotDirectory) {
        $runArguments = @('--path', $sandbox, '--log-file', (Join-Path $sandbox 'godot.log'))
    }
    $output = Invoke-TestGodot $runArguments
    if ($output -notmatch 'SAVE TESTS PASSED: \d+ assertions') {
        throw 'Godot exited without completing the behavioral suite.'
    }
    if ($Suite -eq 'All') {
        Assert-SuspendDiagnostics $output 44
        Write-Host 'CASE: suspend diagnostics contain only ordered category outcomes and measured elapsed time'
    }
}
finally {
    foreach ($handle in $locks) { $handle.Dispose() }
    if (Test-Path -LiteralPath $sandbox) {
        Remove-Item -LiteralPath $sandbox -Recurse -Force
    }
}
