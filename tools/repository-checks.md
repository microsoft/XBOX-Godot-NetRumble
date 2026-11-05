# Repository checks

> **You do not need this page to run, export or learn from the sample.** It is for
> contributors changing repository text or package configuration, and CI runs these checks as
> required gates.

---

These repository text checks need no engine, SDK or secrets, and run as hard gates in CI
(`.github/workflows/ci.yml`). Run them locally before pushing:

```powershell
.\tools\check-deport.ps1 -Detailed     # sample voice
.\tools\check-game-config.ps1          # MicrosoftGame.config validity
```

For script/resource changes, follow with the existing Godot parse/import sequence **in order**:

```powershell
godot.exe --headless --path . --import
godot.exe --headless --path . --quit
```

Inspect both exit codes and both outputs for script/resource errors; Godot can report errors
while exiting zero. This needs built addons/importable resources and does not test registration,
Party, Xbox policy or roaming. CI's parse/import job is currently advisory; these text checks
are hard gates. See [CONTRIBUTING](../CONTRIBUTING.md) and [Manual test plan](../docs/manual-test-plan.md).

Account-save and multiplayer lifecycle changes also need the behavioral suite:

```powershell
.\tools\run-save-tests.ps1 -Godot 'C:\path\to\Godot_console.exe'
# Faster multiplayer-only iteration; the default command above includes this suite.
.\tools\run-save-tests.ps1 -Godot 'C:\path\to\Godot_console.exe' -Suite Multiplayer
# Front-end layouts, account gating, real keyboard/gamepad events and lobby controls.
.\tools\run-save-tests.ps1 -Godot 'C:\path\to\Godot_console.exe' -Suite UI
# Render the same isolated UI suite in a window and save viewport-only PNGs.
.\tools\run-save-tests.ps1 -Godot 'C:\path\to\Godot_console.exe' -Suite UI -ScreenshotDirectory 'C:\temp\netrumble-ui'
```

The runner uses isolated, distinct Xbox/PlayFab identities, fake GDK XGameSaveFiles results
(including returned Signals and dictionary `{path}` data), and disposable folders, never real
user saves, and does not initialize the live platform addons. It runs the copied project's
import pass, then a compile gate that loads every script and scene under `scripts`, `scenes`
and `tools\tests` against the sandbox's own autoload list and stops before any suite on a parse
or load error. Only then does it execute production GDScript with test doubles. It removes its
temporary project afterwards. The same runner is wired into the existing Godot CI job.

The copy omits `.import` sidecars, so assets import with engine defaults, except for an explicit
allowlist in `run-save-tests.ps1`: the title and menu wordmarks, the Xbox mark, the Xbox glass
logo and the loading ring keep their repository settings (2x SVG rasterization, lossless
storage, full mip chains, straight alpha), and so do the Waves dot atlas and strand band
(lossless, no mipmaps, no alpha-border fixing). Their quality at every window size depends on
those settings, so the suite must exercise what ships; the runner stops with an error if an
allowlisted sidecar or its source is missing.

`multiplayer_failure_tests.gd`, called by `save_tests.gd`, injects synchronous errors,
returned completion Signals, terminal events and stalled native operations while retaining
production PartyService host/join/attach/leave and NetManager lifecycle logic. It covers
all six event kinds, pre-bind loss, absolute 45-second establishment and shared 15-second
cleanup boundaries, scoped Party/Lobby reset, stale completions, manual retry/chat recreation,
autonomous native reset/readiness reconciliation (including partial initialization), and
actual host/code/friend/invite loading screens. Clock seams advance deadlines without
waiting real budgets. No live addon, root-runtime shutdown, machine connectivity change
or real account/save/network modification is part of these tests. Native SDK ownership
and installed-binary provenance require separate companion-addon validation.

The network double rejects leave after native destruction, including the peer-disconnect
callback preceding DESTROYED. These cases verify retained chat, zero unnecessary scoped
shutdowns, safe manual retry and exact-instance handling of late results/old notifications.
Terminal state alone still requires cleanup; real leave errors are not broadly ignored.

Cover owner changes, authoritative empty
state, failed/malformed reads without overwrite or gameplay, Retry, canceled/stale completions,
missing SDK/SCID, signed-out users, same-owner write retry, resume provider reacquisition and
transactional full reload, actual acquisition handoff with abandoned-match notice/invite
priority, resume account loss and obsolete save/Quit modal guards, failed appearance
persistence followed by Suspend, unchanged explicit
save requests and the 50-row history bound. No save requires a separate dirty-marking call.
Actual menu-button regressions cover failed Options Back with inline/deferred error dialogs,
retained values and stale-account guards. Lifecycle cases cover orphaned invite outcomes,
newer buffered claims, owner-bound activity retirement outside Suspend, shutdown readiness
revocation, shared drain timeout and serialized old/new session/account writes.
PR-feedback regressions cover delayed resume Party/chat cleanup before readiness, actual
stall Back/Quit actions, repeated resume, cold fallback initialization with early removal
subscription, cancellation at acquisition stages, and social-group ownership/single-flight
across delayed replacement-account loads.
Source checks for forbidden desktop/token
caches and migration code supplement behavior tests; they do not replace them.

Registered-PC A/B isolation, console parity and same-account roaming still require live
[manual acceptance](../docs/manual-test-plan.md#account-owned-saves-pc-and-console).
Mocked success, import success and local file presence are not runtime parity evidence.
Without a signed-in XboxUser, account saves cannot become ready. Do not add a shipping
bypass to run tests.

The UI suite uses the production input map, theme, designer artwork and screen scenes, with the same
isolated account/save doubles as the behavioral suite. It covers acquisition failure/Retry and
completed progress, matchmaking placement, footer navigation/focus restoration, connectivity
without row movement, Options Back, loading cancellation, live ship/colour selection, reserved
colours, practice opponents, the maximum roster, hosted join-code admission and the matchmaking
group's rules/invite-only entry.
Layout checks include 16:9, 16:10 and ultrawide windows. Screenshot capture needs a graphics
display and is restricted to `-Suite UI`; it captures only the test viewport, not the desktop.
The default `All` suite also runs these UI assertions headlessly.

Branding checks load those five allowlisted textures through the production registry and
screens. Each must be a lossless `CompressedTexture2D` at its exact 2x size with a full mip
chain and the preserved import settings. Mip-0 probes require straight-alpha wordmark edges
(premultiplied art scores near zero), a white antialiased Xbox-mark edge, at most
`MAX_WORDMARK_SEAM_DIPS` pixels per wordmark lying more than 0.08 alpha below both horizontal
or both vertical neighbours, and alpha of at least 0.90 at the wordmarks' fill/outline junction
probes (`WORDMARK_SEAM_PROBES`), which are tied to the SVG geometry and must be re-derived if the
wordmark artwork changes.
On the title, main menu and loading screens every logo must filter linearly between mipmaps,
fit with keep-aspect centring, keep its logical size, stay inside the viewport, draw at its
texture aspect and never be magnified past its imported pixels at 960x540, 1280x720,
1366x768, 1600x900, 1920x1080, 2560x1440 and 3840x2160, plus 1600x1000 and 2560x1080. Only
window size and layout change, so these checks also run headlessly. With
`-ScreenshotDirectory`, the suite also captures each of those screens at every size
(`branding-title-1280x720.png`, `branding-menu-…`, `branding-loading-…`) and the loading ring
turned 45 degrees (`branding-loading-ring45-…`). Every branding capture must match the
requested window size exactly, so a display that cannot open a 3840x2160 window fails instead
of skipping. Visual comparison with the design itself is a manual review step; neither these
checks nor CI depend on it.

Background checks cover the root `Background` of all six screens at those nine sizes plus 1280x960
(4:3), headlessly and without extra captures:
- **Waves screens** (main menu, loading, History, Leaderboards) must keep the registry texture as
  a `TextureRect` with the Waves motion adapter and its `KEEP_ASPECT_COVERED` fit. They must cover
  the viewport and draw uniformly scaled texels from a centred crop of the 1920x1080 art. With
  motion off, the `TextureRect` has no material and no dot layers.
- **Glow screens** (title, lobby) must be a full-rect, input-transparent #050505 `ColorRect` with
  the glow adapter and its analytic shader. They must reference no Glow PNG, cover the viewport,
  and sample the same centred design-space crop.

The lobby ship card check requires all of the following:
- The preview Panel keeps its `clip_contents`, theme variation and ship sprites.
- Its `ShipCardFill` child draws behind it with the card shader, which takes the card's size and
  the outline's corner settings.
- Over that fill, the Panel draws only the white 15 % outline with 12 px bottom corners.
- With the shader turned off, the opaque theme fill returns.
- Both enlarged ship layers draw through `ship_preview.gdshader`.

The lobby check also requires the selected colour's tile to stop where its accent strip starts, so
the strip's cut corner shows the page. Both Options lists (main menu and in-match) must inset every
spinner and slider row's text and controls from the row's edge, where the focus outline is drawn,
and every row value must fit without clipping.

`background_motion_tests.gd` checks `UIBackgroundMotion` with the real Waves and Glow adapters. It
runs in `All` and `-Suite UI`. Headless, it first proves that the real renderer checks never await a
GPU frame. It then sets the controller's `test_force_gpu` seam and plays the renderer by emitting
`RenderingServer.frame_post_draw`; emitting nothing stands for a minimised window. Clocks and the
re-enable ramp are steered with `seek_family_for_tests()`, `seek_envelope_for_tests()`,
`time_override` and pauses, so the suite never waits out animation time. A running clock is checked
only against bounds measured on the monotonic clock, never a fixed ceiling, so a slow machine
cannot fail it. Every resume or continue check waits briefly and requires real advancement:
the clock, or the ramp, must be strictly past its frozen value and within the measured elapsed
time. A clock that stays frozen therefore fails. It covers:
- the warm-up timeout falling back to static, with no cold activation afterwards;
- when `main.gd` retries a failed warm-up. A retry needs a visible front-end background and no
  gameplay screen on the stack when it runs: focus during gameplay, or with gameplay under a
  front-end background, adds no cover and starts no warm-up; a retry scheduled before gameplay
  replaces the front end is refused when it runs; and a refused post-startup retry keeps its one
  attempt. A first focus retries with no prior focus loss. A resume with no focus change routes to
  the title and then retries: it waits under the one cover while an earlier warm-up is still in
  flight and retries under a fresh cover once that warm-up fails, and its retry is refused over
  gameplay or while the title is still constrained. Gameplay pushed while a retry warms cancels
  it: its cover and draws leave in that frame, and draws arriving afterwards cannot complete it.
  Each cover must be effectively visible, cover the whole viewport, be opaque #050505 and sit on a
  canvas layer above every background and warm-up draw.
- the deterministic `time_override` pose, and the glow's breath repeating exactly every 12 s;
- Off as the exact static path;
- the 3 s re-enable ramp. It starts at 0 after Off-to-On and after a sign-out reset, freezes while
  paused, and is not restarted by swaps or by Paused-to-Running. It never stacks, and reads 1 under
  `time_override`.
- overlapping ramps. While the Waves first-activation ease and the re-enable ramp are both part-way
  (in step, as on the first activation after warm-up, or with either one ahead), the `ease` uniform
  is their minimum, never their product. Glow has no first-activation ease and scales its breath
  by the ramp alone.
- phase continuity across swaps, with no rest-frame flash;
- constrain, dialog and hidden-screen freezes without a jump;
- nested pause reasons;
- Ctrl+Shift+M / View: each pauses and resumes without touching account data, a held key repeat
  does not toggle again, the shortcut does nothing without a visible background, and it leaves the
  session pause unchanged while motion is disabled. Only the exact combination toggles: F8, M,
  Shift+M, Ctrl+M and Ctrl+Shift+Alt+M do not, and m and Shift+M type into the focused join-code
  field while motion keeps running.
- suspend, through `main.gd`: every payload is saved before motion is suspended. Across a suspend
  and a resume with no focus change, both clocks, both part-way ramps and the drawn poses hold
  exactly, then continue without the suspended time. Resume clears only suspension, so the session
  pause and a focus loss keep motion paused until focus returns.
- `MotionHintLabel` on the loading and title screens, pushed through `ScreenManager`: it reads
  "Ctrl+Shift+M / View pauses background motion", and is visible while running and while paused,
  hidden after Options Off, and visible again after On.

The UI suite checks that the title and loading screens carry `MotionHintLabel` with the PC wording
("Ctrl+Shift+M / View pauses background motion"), hidden while motion is disabled. The hint uses
the `MotionHint` theme type, opaque text of at least 26 px with no translucent modulate, and stays
inside the 90 % title-safe area at the nine window sizes above. On the title, Ctrl+Shift+M or View
with motion disabled neither pauses anything nor starts sign-in. The main menu's Options shows the
note "Ctrl+Shift+M / View pauses background motion for this session." within the list's width.

`save_tests.gd` covers the presentation sidecar and the Options row with its Ctrl+Shift+M / View
note:
- default, reset, round trip and account isolation;
- missing (On), damaged (Off, with core settings kept and the sidecar replaced by the next save),
  and failed writes (reported, then retried);
- invalid payloads in both slots: one explicit save replaces both, the reader then selects the
  saved value, and it reloads. A repair cut off between its two slot writes (the second slot left
  untouched or torn) reports one failure, reads as damaged or as the new value, keeps core
  settings, and the next save completes it;
- keys from newer builds, which are kept;
- the owner and generation fences, including an account change while loading.

It pins the profile schema of builds that predate the sidecar as a fixture (`_old_profile_schema`)
and runs upgrade, older build, upgrade:
- The upgrade loads a profile an older build saved, writes nothing on load, and saves Off to the
  sidecar while `profile.json` keeps its schema.
- The older build then loads the account and saves its own schema.
- The upgrade loads both changes.

A `profile.json` slot carrying `animateBackgrounds`, newest or older, fails the load like any
wrong-schema payload: the slots stay byte-intact, and nothing is written.

Suspend persists a changed sidecar without Options being left. It is committed right after
`profile.json`, in the two-slot envelope, and it reloads. A failed sidecar write during suspend
fails the suspend save, is reported once, leaves the committed sidecar unchanged, and is retried
by the next suspend.

Rendered-frame waits are bounded: they count `frame_post_draw` against a monotonic deadline and
fail the case explicitly instead of hanging. This covers UI screenshots and the glow renders.

With `-ScreenshotDirectory`, the suite also renders the glow on the GPU at 1920x1080:
- **Off.** It requires MAE ≤ 0.10/255 and max ≤ 2 against
  `tools\tests\fixtures\Background_Glow_designer.png`, the designer's export. A `.gdignore` keeps
  that fixture out of imports and exports; the test reads it with `Image.load_from_file`.
- **The first breathing frame** (t = 0, through the adapter's preparation seam). It stays within
  3 code values of Off, with each channel's mean offset ≤ 1. It is rounded once, so it is not
  pixel-equal to Off.
- **Below the glow.** Off is exactly #050505. The ungated noise in the breathing frame is one
  value for R, G and B, rounding 5 to 4, 5 or 6 with a mean within 0.05 of 5. Both 4 and 6 must
  occur: the bias is zero, but the pixels are not exact.
- **Screen-fixed noise.** Two renders of the same frozen pose (t = 3 s) are pixel-identical, and
  t = 15 s renders exactly as t = 3 s.
- **Hotspot range.** On a 32x32 window at the hotspot, t = 3 s minus t = 9 s matches the
  breathing range of the design's float composite within 0.25 code values per channel.

Four checks stay manual because they need the design files, renders or a GPU profiler: the ship
card's match with the design, banding while the backgrounds animate, the hint's contrast against
the animated backdrop (at least 4.5:1), and the added GPU cost of background motion, which must
stay within 0.25 ms at 1080p and 0.75 ms at 4K. No automated check covers them. The
[manual test plan](../docs/manual-test-plan.md#background-motion) lists them with the editor and
console checks.

The Waves per-dot data (`Waves_DotData.res`, `Waves_DotMultiMesh.res`) was baked once from the
design's dot positions and is committed as data; it must load in Godot 4.6.2 and 4.7.2, and
`background_motion_tests.gd` loads and validates both files through the real Waves adapter.

The same suite renders and exercises the remaining shared-style surfaces: long History
lists, a delayed Leaderboards query, normal/warning/error dialogs, join-code validation,
friends and player-report overlays, chat entry, controller-disconnect notification, the
production Practice HUD and in-match pause/options. These checks use the real scene hierarchy
and theme rather than standalone style samples; live Xbox system UI is outside their scope.

## `check-deport.ps1`

NetRumble is the reference sample for GDK and PlayFab integration in Godot, so
it has to explain the platform on its own terms rather than by comparison to
any other implementation. This script fails the build when framing of that kind
appears in `scripts/`, `docs/`, `tools/` or the README. `-Detailed` lists every
hit with its file and line.

## `check-game-config.ps1`

`MicrosoftGame.config` fails quietly in both directions, which is what makes it
worth a dedicated check:

- **At runtime**, a malformed file makes GDK initialization fail: `XboxBootstrap`
  gets back an HRESULT and nothing more. The game keeps running with every
  platform service unavailable and gameplay blocked by account/save readiness, and Godot
  still exits 0, so the headless parse job cannot see it. The easy way to cause this is writing `--` inside the
  comment block as an em dash; XML forbids a double hyphen in a comment.
- **At export**, the hazards produce a mis-named binary or an aborted package
  rather than an error message.

Every rule the script enforces mirrors a hazard already documented in the
config's own comment block: well-formed XML, `TitleId` / `MSAAppId` /
`Identity` present, the PC entry first in `ExecutableList`, unique executable
ids, no `Executable` start-tag spelled inside the comment, and nothing
following the closing `</Game>` tag.
