# NetRumble architecture

> **You do not need this page to run or learn from the sample.** It is implementation
> architecture for contributors changing the XBOX and PlayFab integration.

Start at the platform boundary: **`Services` owns `PartyService` and `ChatService`**,
alongside identity, XBOX policy, activity, achievements, saves and device/connectivity wrappers.
`NetManager` consumes those instances; it does not construct a second transport or chat service.
The arena supplies a roster, Party traffic and events for achievements/history.

See [capabilities by environment](../README.md#what-works-where),
[connection flows](multiplayer.md#connection-flows) and [Walkthroughs](walkthroughs.md).
Physics, simulation scheduling and presentation are in the secondary
[gameplay reference](gameplay-reference.md); wire formats are in [protocol](protocol.md).

```text
Godot UI and gameplay
        |
        v
Services facade and NetManager
    /                  \
   v                    v
GDK platform        PlayFab services
identity,           Lobby, Party,
privileges,         identity, saves
activities
```

## Ownership and addon boundary

| Owner | Responsibility / source |
|---|---|
| `XboxBootstrap` | Resolve the configured `XBOX` singleton and initialize GDK; addon bootstrap in `addons\godot_gdk\runtime\gdk_bootstrap.gd`. |
| `Services` | Construct service instances and coordinate sign-in, account invalidation, saves and achievement events; `scripts\autoload\services.gd`. |
| `IdentityService` | XBOX user acquisition, PlayFab initialization/authentication and entity display name; `scripts\services\identity_service.gd`. |
| `PartyService` | Lobby discovery, Party network/peer and chat-control lifetime; `scripts\services\party_service.gd`. |
| `ChatService` | Party voice/text, permissions, validated text events and control teardown; `scripts\services\chat_service.gd`. |
| `NetManager` | Online/offline session, roster, join admission, match state, gameplay RPCs and chat-to-roster attribution; `scripts\autoload\net_manager.gd`. |
| `PlatformSession` | XBOX view of that session; plain object owned by `NetManager`, not an autoload. |
| `PlayerProfile` / `GameSaveService` | Settings/identity presentation versus persistence into the platform folder. |
| `InviteRouter` / `ScreenManager` | Buffered activations versus front-end navigation and dialogs. |
| `main.gd` | Process lifecycle and controller-disconnect overlay. |

Service wrappers keep optional native objects behind `PlatformAccess`, bootstrap resolution and
runtime class lookup. UI/gameplay mostly consume the facade or `NetManager`; small system-UI
adapters such as `NRSystemKeyboard` also call the addon. A loaded extension does not imply
initialized services, a registered process, a signed-in user or an allowed privilege.

## Autoload order

```text
XboxBootstrap → Assets → AudioManager → PlayerProfile → Services → NetManager → ScreenManager → UIBackgroundMotion → InviteRouter
```

`project.godot` is the authority for this order. Bootstrap must precede GDK use; profile defaults
precede account-owned save loading; services precede session checks.
`UIBackgroundMotion` reads the profile's motion preference and the screens' backgrounds, so it
follows `PlayerProfile` and `ScreenManager`.
`InviteRouter` needs both the session and front end before it can redeem an activation.
These are sibling autoloads, not children of `main.gd`.

## The session vs the platform's view of it

`NetManager._party()` and `_chat()` resolve `Services.party()` and `Services.chat()`.
`PartyService.host()`, `join()` and `join_by_connection_string()` are **sample wrappers**,
not addon API names. They return a Party peer which `NetManager` attaches to Godot's
`MultiplayerAPI`; [Multiplayer](multiplayer.md) traces the actual addon calls.

On leave, `NetManager` clears its `_peer` reference first and detaches Godot's multiplayer
peer **synchronously**. `PartyService` is the sole owner of native network leave. Calling
`peer.close()` as well would initiate a second native leave; detaching is not another close.
`PartyService.leave()` serializes teardown so overlapping exits/rejoins await the same release.
Chat-control creation is serialized with both ordinary destruction and canceled-control cleanup:
replacement creation waits for the previous destruction to complete. These are title-side
ownership rules, not native addon changes.
Serialization did not resolve the addon cleanup failure: awaited chat-control destruction hangs in
live testing, and forcing the process to exit has crashed the game. The leave path no longer
depends on it — the chat control is retained for the signed-in player and reused across matches,
so leaving and rejoining never awaits destruction — and a live leave/rejoin has since completed.
The call still runs at title exit and on privilege withdrawal, so the
[underlying defect](manual-test-plan.md#known-cleanup-blocker) is worked around rather than fixed.

`PlatformSession` reacts to roster and match signals to publish/update/retire XBOX activity,
set presence, report recent players once play begins, resolve names and apply communication
policy. It also listens for account changes. XBOX-facing operations are unavailable without an
XBOX user. All gameplay requires account/save readiness.

All gameplay `@rpc` declarations stay on `/root/NetManager`: Godot routes by node path.
Party text is a separate channel, not a gameplay RPC or a protocol-version change.
`NetManager.begin_match_chat()` / `end_match_chat()` manage only the transient UI context;
they neither create a Party network nor add a chat RPC. The pinned addon supplies the
typed-text API; no native file or submodule changes are included here. The cleanup blocker
above prevents a full-session completion claim.
Lobby carries the compatibility token before Party attachment so even incompatible RPC sets can
receive a readable refusal. See [protocol compatibility](protocol.md#protocol-version).

## Player identity

Keep three identifiers distinct: the **XBOX XUID**, **PlayFab entity key** (`id`, `type`),
and **Godot peer id**. Sign-in obtains an XBOX user, then calls
`PlayFab.users.sign_in_with_xuser_async(xbox_user)`. Party authenticates the PlayFab entity.
A roster's claimed XUID or replicated entity id is not itself proof of ownership.

`ProfileService` checks the XUID through PlayFab `GetTitlePlayersFromXboxLiveIDs`, compares
the resulting title-player entity against `PartyService.entity_key_for(peer_id)`, then requests
XBOX profiles only for verified claims. Every machine performs its own check.
`PlayerState.display_label()` prefers the verified gamertag; the existing fallback is the
roster name when no verified name is available (including bots and failed claims).
This fallback is not a verification guarantee.

Typed text resolves its sender through `PartyService.entity_key_for(peer_id)` and the
**current roster**, never a display name supplied with a message or `PlatformSession`'s
replicated identity fallback. `ChatService` validates
policy/lifecycle first; `NetManager` emits the local presentation event; the gameplay screen
uses `PlayerState.display_label()` for the four-row `NRChatLog`.
Match exit, identity changes and session loss clear the log; new restrictions remove affected rows.
Account-cache invalidation also clears retained text while XBOX text policy is re-evaluated.
Communications-privilege revocation destroys the chat control; after restoration, leave/rejoin
to recreate it rather than expecting live network reconfiguration.

## Saves

**PC and console share the Xbox XGameSaveFiles backend.** `GameSaveService` owns
`profile.json` (settings), `history.json` (the newest 50 completed matches), and `stats.json`
(lifetime achievement counters) under `NetRumble` in the account folder returned by
`GDK.game_save.get_folder_async`. Absolute-path I/O avoids changing the process working directory
to the console's virtual save root.
The addon wraps `XGameSaveFilesGetFolderWithUiAsync`, using the signed-in XboxUser and the
initialized Xbox services SCID. Its result data is a dictionary with a `path` string.
The verified owner is the XboxUser, not the separate PlayFab authentication/multiplayer user.
There is no second desktop persistence backend or PlayFab save fallback. PC preparation preserves
valid current-format files from the earlier root-level layout using verified copies; originals
remain untouched, existing destination saves win, and an interrupted copy can be retried.

Resume invalidates the old save binding and generation, then returns through account acquisition.
Acquisition waits cancellably for pending Party/chat teardown before starting new account
preparation and publishing readiness. It names the wait rather than handing off to a menu
whose first gameplay request would be rejected as still finishing the previous session.
`Services.sign_in()` reacquires the provider and reloads all three authoritative payloads before
gameplay is ready again; authentication may be reused. This is required because the OS releases
the XGameSaveFiles provider on suspend. No initialization or upload is started in Suspend.

Each logical save has two current-format integrity slots: the named file and its `.alt`
companion. Both contain a `sequence`, serialized JSON `payload`, and `sha256` envelope.
Writes touch only the inactive slot, then close/reopen and verify its complete bytes.
Reads select the newest intact slot. This avoids Godot's destructive Windows rename-overwrite
behavior and detects incomplete buffered writes; it is not migration or a legacy reader.
A damaged candidate can be ignored when another intact slot exists; inaccessible slots,
invalid payloads, or damage with no intact slot fail loading. Both slots absent means no save.

**Presentation sidecar.** `presentation.json` (with its `.alt` slot) sits beside the three payloads
and holds presentation-only preferences, today `animateBackgrounds`. It uses the same envelope and
the same owner/generation fences. Its policies:
- **Downgrade policy.** Builds that predate the sidecar reject any profile slot carrying a key they
  do not know. So `profile.json` keeps exactly the schema they read, and a newer build never writes
  a new key into a core payload.
- **Optional.** It is read apart from the three payloads and never fails sign-in. A missing
  sidecar means the defaults (motion On), and it is only created once a value differs from them.
- **Damaged.** No intact slot, conflicting slots, an unreadable slot or a mistyped known key all
  count as damage. A damaged sidecar logs a warning and loads motion Off, the safe choice for a
  player who may have turned it off. Every core setting still loads, and the next explicit
  settings save replaces the damaged sidecar. An unreadable or invalid slot blocks the reader even
  beside an intact one, so when both slots block, that save overwrites both (primary first, each
  verified). It reports success only once the reader selects the saved value. Cut off between the
  two writes, it reports failure, and the sidecar reads as damaged or as the new value, never an
  older one; the next save completes the repair.
- **Forward tolerant.** Keys from newer builds are accepted and kept when this build saves.
- **Never inline.** `profile.json` keeps its strict schema. A profile slot carrying
  `animateBackgrounds`, like any unknown key, fails the load closed (Retry / Back), and nothing
  rewrites or erases it.

`Services` coordinates `unbound -> waiting for prior teardown (if needed) -> authenticating -> loading saves -> ready`.
Authentication alone is not readiness: Practice, host/join, friends and invites all require
the identified account's initialized store and successful reads. The three payloads are staged,
validated and published as one account state. Confirmed missing files in a valid folder supply
defaults, empty history and zero counters; valid empty history replaces previous memory.
Initialization, folder and read/schema errors instead block gameplay with **Retry / Back**,
without writing defaults over saved data. Retry must load saves even if authentication succeeded.

An account generation binds preparation, publication and writes to their owner. Back, user
removal and abandoned operations invalidate late completions; no old folder or payload may be
restored. Account boundaries clear all settings, history, lifetime/per-match
counters, cached achievement reports and identity state. New work and ongoing gameplay stop
on account removal; a surviving process returns to account acquisition.

This is greenfield storage: no desktop cache, shared-file import, legacy wrapper
reader, compatibility path or music-value remap. Historical `settings.cfg`,
`match_history.json`, `achievement_stats.json` and token variants outside the selected folder
are not discovered, read, copied, moved, deleted or imported. Music still defaults to `0.25`;
an explicitly saved `0.7` remains `0.7`.

`Services` retains loaded state for synchronous lifecycle persistence without an asynchronous
read or new store setup. Explicit save requests attempt their relevant current payloads even
when values are unchanged. Suspend and normal shutdown attempt settings, history and counters;
there are no save dirty flags. The one change check is the optional sidecar's: it is written,
after `profile.json`, only when it would change what the account loads. A failed sidecar write
reports a save failure and keeps the stored copy as the baseline, so the next save retries.
Writes require a current owner and
report failure; current values remain in memory for same-owner retry, never for transfer to
the next account. Suspension does
not sign out. Removal handling may persist only while the platform still permits access;
it must not start a save for an already-removed user. A local write is not proof of remote
synchronization. See the [Game Saves lesson](platform-services.md#game-saves) and
[acceptance matrix](manual-test-plan.md#account-owned-saves-pc-and-console).

## Process lifecycle

`scripts\main.gd` handles Godot application notifications. A Middleware console fork's
`DisplayServerGDK` maps app-state and constrain notifications onto the scene tree. Desktop focus
changes exercise only the constrain path; **opening Guide is not evidence that actual suspend
occurred**.

For PLM termination the sequence is **Constrain -> Suspend -> Terminate**.
The save boundary is **Suspend**, not Constrain or a late termination callback.
Pending Options edits, completed history awaiting retry, and earned lifetime counters
must be committed synchronously before session teardown and before the suspend handler returns.
There is no periodic autosave or new Constrain/settings/session-exit checkpoint policy.

| Event | Behavior |
|---|---|
| Suspend (`NOTIFICATION_APPLICATION_PAUSED`) | `Services.persist_for_suspend()`, then suspend background motion, `NetManager.abandon_for_suspend()`, then stop game audio. Session/chat state is invalidated synchronously. |
| Resume (`NOTIFICATION_APPLICATION_RESUMED`) | Clear the background-motion suspension and restart music; invalidate the old save provider/generation, account-dialog guards and active invite claim, retaining newer buffered invites. Start owner-bound activity retirement and route to acquisition for synchronization and all three loads, then retry a failed background warm-up. After handoff, an abandoned-match notice yields to invite routing; never resume a match. |
| Constrain (`NOTIFICATION_APPLICATION_FOCUS_OUT`) | Mute game audio, freeze background motion and call `MatchDirector.set_externally_paused(true)`; retain session/identity. |
| Unconstrain (`NOTIFICATION_APPLICATION_FOCUS_IN`) | Restore game audio and local simulation/phase-clock advancement; lift the background-motion freeze and retry a failed warm-up. |

**Maintainer invariant: suspend must remain straight-line:** no `await`, timers or deferred
persistence. The platform may freeze or terminate the process as soon as the handler returns.
The local peer is detached and the roster abandoned without awaiting `PartyService`'s native
network release; there is no direct peer close, reconnect or match resume promise.
Activity retirement is retained for the authenticated owner without issuing a native call
during Suspend. On resume the serialized writer deletes that advertisement, even while save
reload blocks gameplay. Only a confirmed delete records it as cleared. Account loss discards
the old ownership claim, including during already-pending suspend teardown; it never transfers
a deletion to the replacement account. A newer session's publication follows any pending delete.

Suspend diagnostics distinguish an unready account and each payload's
write outcome, and record elapsed save time and handler completion. They must not expose account
identifiers or save contents. A failed write retains current values and the previous valid slot;
it cannot be repaired by waiting for a deferred dialog after suspension. Verify actual console
notification delivery and callback completion with the [Guide Quit cases](manual-test-plan.md#xbox-guide-quit-and-suspend-saves).

Constrain freezes the local world's simulation and phase timers, including the client's clock,
but broadcasts no pause RPC and changes no settings. A constrained host stops advancing the
authoritative world; clients are not globally paused. Game-audio mute is not a Party microphone
permission change. Test those behaviors separately.

Ordinary desktop shutdown is different: `request_shutdown()` lets in-flight account/save preparation,
Party teardown, activity retirement and chat cleanup drain while frames still pump completions,
within a shared eight-second budget. Retirement uses the still-authenticated owner rather than
gameplay readiness, which shutdown has already revoked. An error or expired deadline is not
evidence that the remote advertisement was cleared.
Console user removal remains synchronous and deadline-safe, without waiting for navigation,
new save initialization or remote teardown.

## How a match ends badly

Host loss, terminal Party loss and sustained offline hints converge on
`NetManager._on_server_disconnected(reason)`: leave, record the reason, notify the screen,
and return the player to the menu. Local suspend uses the separate synchronous abandonment
path above. A completed match instead returns to the lobby.

Party is a mesh: losing peer 1 does not necessarily destroy the remaining peers' transport.
The game explicitly treats loss of that peer as loss of simulation authority. There is
**no host migration**. `PartyService.network_lost` covers destroyed/disconnected/failed networks;
`party_failed` also describes recoverable operation errors and is not by itself terminal.
Teardown detaches network listeners to avoid interpreting a deliberate leave as another failure.

## Connectivity detection

`ConnectivityService` subscribes to `gdk.networking.connectivity_hint_changed` and emits
`connectivity_changed(online)`. The main menu disables Host/Join when definitely offline;
`Services.resolve_multiplayer_denial_reason()` checks connectivity before account privilege.
Practice remains available only while the identified account's save store is ready and usable.

This is a **device-wide hint**, not a PlayFab endpoint reachability test. Only
`network_initialized == false` or level `NONE` counts as offline. `LOCAL_ACCESS`,
`CONSTRAINED_INTERNET_ACCESS` and unavailable hints leave the gate open; an actual service call
may still fail. An online session is ended after an eight-second offline grace period if the
hint is still down. The hint alone does not invalidate a usable account-owned offline folder.
A cold offline launch still needs the platform to resolve the required identity and store;
there is no separate offline-login or unsaved-play fallback.

`NRMenuList.refresh_focus_wrap()` rebuilds explicit focus paths when availability changes.
Focus must move off a newly disabled row rather than leave controller navigation stranded.

## Front-end presentation

Background art and branding assets live in `assets\textures\UI\Background\`,
`assets\textures\UI\Logo\` and `assets\textures\UI\Loading\`. The Waves background is a 1920x1080
texture, and the title and lobby glow is drawn in code (see
[Background motion](#background-motion)); both use keep-aspect cover, so non-16:9 windows
centre-crop instead of stretching: at 21:9 about rows 135–945 remain, while at 16:10 about
columns 96–1824 remain. The Waves texture has no mipmaps and is magnified 2x at 4K; its detail is
limited by a 1536x1024 source raster, so a sharper 4K Waves needs higher-resolution art.
The NET.RUMBLE wordmarks and Xbox mark are path-only SVGs, with no embedded images or fonts. Each
wordmark's 1 px outside outline is a separate shape drawn over a fill that extends 0.35 px in SVG
units (0.7 px in the imported 2x raster) beneath it, so no antialiasing gap appears at the glyph
edge. The wordmarks, Xbox mark and loading ring are SVGs that import at 2x as lossless textures
with full mipmaps and `fix_alpha_border`; the Xbox glass PNG is also mipmapped. Their
`TextureRect` nodes use `LINEAR_WITH_MIPMAPS`, reducing minification aliasing from 960x540
through 3840x2160 with no branding-texture upscaling. At 4K, the wordmarks, glass logo and ring
reach 1:1 while the Xbox mark draws at about 98%.
Interactive captions, account progress, appearance selectors and roster cards are Godot
controls, not flattened screen images. `assets\ui\netrumble.tres` owns their typography, rounded
surfaces and focus states.

Each front-end screen or state lives in one scene:

| Screen or state | Scene |
|---|---|
| Press prompt, signing in, save synchronization, signed-in confirmation | `acquire_user_screen.tscn` |
| Main menu | `main_menu_screen.tscn` |
| Joining/loading | `loading_screen.tscn` |
| Ship/color selection, rules and roster | `lobby_screen.tscn` |

Layouts use the project's 1920x1080 canvas. Acquisition and loading are center-anchored;
secondary menu actions and lobby hints are edge-anchored. The primary menu holds the
Matchmaking / Host / Join flows, while History and Leaderboards have separate footer buttons
included in keyboard/gamepad navigation. Join codes, practice opponents, matchmaking rules and
account/save readiness come from the services and `NetManager`.
The lobby previews the actual gameplay ship textures and palette. History, Leaderboards,
pause/options, dialogs, social/join/chat overlays and the gameplay HUD share the same visual
language and navigation patterns. The gameplay arena and the Xbox-owned account pickers,
keyboards, profile cards and invite dialogs are outside this theme. Warning/error titles keep
distinct severity accents, and health/shield bars keep their semantic colours.
See the isolated [UI checks](../tools/repository-checks.md) for layout/input
coverage and viewport screenshot capture.

### Background motion

The Waves backgrounds (main menu, loading, History, Leaderboards) and the Glow backgrounds
(title, lobby) move slowly. The `UIBackgroundMotion` autoload owns the session state, and the
adapters in `scripts\ui\backgrounds\` draw it: `waves_background.gd` sits on each Waves
`Background` `TextureRect`, and `glow_background.gd` on each Glow `Background` `ColorRect`.
Each family is in one of three states:

| State | When | What draws |
|---|---|---|
| Disabled | Options › Animated Backgrounds is Off; the renderer is unsupported (headless, HDR 2D, transparent viewport); or no covered warm-up has succeeded | The exact static design: Waves is the designer `TextureRect` alone (no material, no dot layers); Glow is its shader's undithered design state |
| Paused | The session pause (Ctrl+Shift+M / View); suspension; constrain (focus loss, the Guide); `time_override`; or no visible, processing background of that family (a hidden screen, or one under a dialog) | The current pose, frozen: materials stay, while the clock and uniform updates stop |
| Running | Otherwise | The uniforms follow the family clock every frame |

`effective_enabled()` combines three things:
- the preference, `PlayerProfile.animate_backgrounds`, saved in the account's presentation
  sidecar (see [Saves](#saves)); missing loads On, damaged loads Off;
- renderer support;
- a successful warm-up.

Waves and Glow have separate clocks. A clock starts at its family's first visible activation, and
stops whenever the family is paused or disabled. It keeps its phase across screen swaps, so the
next Waves screen continues the motion instead of restarting it. An adapter reads its time before
it builds its materials, so a newly shown background never flashes its rest pose. Every pose is a
pure function of the clock, and time reaches the shaders only through explicit uniforms (never
`TIME`).

**Suspend.** Suspension is a pause reason of its own. `main.gd` sets it once the suspend handler's
save has run, and clears it on resume, so both clocks and both ramps hold still in between and then
continue without a jump. Resume clears only suspension: a focus loss (the Guide) or the session
pause still holds motion until it ends.

**Re-enable ramp.** Turning motion back on never jumps from the static design to a moving pose.
- **When it starts.** Every change from Disabled to enabled restarts a 3 s ramp at 0 for both
  families: Options On, a sign-out reset back to On, or a successful warm-up or retry. A second
  restart replaces the running ramp; ramps never stack.
- **How it progresses.** The ramp is a smoothstep that advances only while its family runs, so
  pauses freeze it, and swaps and Paused-to-Running changes do not restart it.
- **What it scales.** Waves eases its displacement with `min(first-activation ease, ramp)`. Glow
  scales its breathing amplitude by the ramp; its screen-fixed noise stays on, even at ramp 0.
- **Under `time_override`.** The ramp reads 1 for a deterministic pose, and its stored progress
  resumes when the override clears.

Pipelines compile before any animated frame is presented:
1. `main.gd` puts an opaque #050505 cover over the window and awaits `prepare()`.
2. `prepare()` loads and validates the shared resources. It then draws four warm-up nodes under
   the cover (Waves, Glow, a 589x427 ship card and a ship preview sprite) at a fixed pose, and
   waits for three drawn frames. The warm-up starts no clock.
3. Headless runs never wait for frames.
4. If no frames arrive within 2 s (a minimised start), motion stays disabled and the title shows
   the static backgrounds. `main.gd` then retries under a fresh cover: once after startup, on each
   focus event (including the first focus of a title launched minimised, which never had focus to
   lose), and after a resume has routed to the title or menu, once any warm-up still in flight has
   finished.
5. A retry only ever covers the front end. When it runs, it needs a visible front-end background
   and no gameplay screen on the stack, and the title must be neither constrained nor suspended.
   An attempt refused this way does not use up the one retry after startup. If gameplay is pushed
   while a warm-up is still running, `main.gd` cancels it: its cover and draws leave in that frame,
   and motion stays static until a later retry.

Nothing starts motion without a successful covered warm-up.

Accessibility (motion is slow and continuous, with no flashes):
- **Off.** Options › Animated Backgrounds Off is the saved, exact static design, so players can
  stop moving content (XAG 117).
- **Ctrl+Shift+M / View.** Ctrl+Shift+M, with exactly those modifiers, or the controller's View
  button pauses motion for the session on any front-end screen with a background, including before
  sign-in. It writes no account data and does nothing in gameplay. Any other key or set of
  modifiers passes through, so typing M into a text field such as the join code is unaffected.
  While motion is disabled the shortcut is consumed and changes nothing, so it never reaches the
  title's press-any-button prompt. Voice and chat apps can bind the same keys (Discord's Toggle
  Mute, for example); View and the Options setting are unaffected.
- **Where it is shown.** Options states the shortcut under the row. The acquisition and loading
  screens show a `MotionHintLabel` ("Ctrl+Shift+M / View pauses background motion", or "View
  pauses background motion" on console) only while the shortcut can act, meaning a visible
  background is running or paused. The hint is hidden while motion is Off, unsupported or not
  warmed.
- **Legibility.** The hint uses the `MotionHint` theme type: 26 px text in opaque 0.8 grey, with no
  translucent modulate, inside the 90 % title-safe area at every window shape. Against the
  brightest pixel the animated backdrop draws behind the hint, at every measured pose and aspect
  (16:9, 16:10 and 2560x1080 ultrawide), the text keeps at least 5.4:1 contrast, about 9:1 at
  16:9, above the 4.5:1 minimum.
- **On.** Choosing On in Options also lifts the session pause.

**Waves** moves the designer's own 1591 dots on a slow three-wave surface: a 60 s loop, with a 3 s
ease-in from the design's exact first frame. Rendering takes three passes:
1. A base pass draws the design raster, with the wave band's strands displaced.
2. A subtractive instanced pass removes each dot at rest.
3. An additive pass draws each dot at its displaced position.

At rest the passes cancel, so frame 0 is the design image. The per-dot data lives in
`assets\textures\UI\Background\Motion\`:
- `Waves_DotData.res`: an RGBAF 1591x2 image, read by instance ID;
- `Waves_DotMultiMesh.res`;
- the dot atlas and strand textures.

The per-dot data (`Waves_DotData.res`, `Waves_DotMultiMesh.res`) was baked once from the design's
dot positions and is committed as data; the runtime reads only these resources. If any of them
fails validation, Waves stays static, with one warning.

**Glow** is drawn in code from the design's radial gradient:
- an elliptical radial light centred at (960, 433.39), with radii 1338.15 x 609.39 in the
  1920x1080 design;
- colour (50, 164, 96) at 30 % alpha, interpolated unpremultiplied over #050505.

The shader samples the same centred cover crop as the textured backgrounds and has two paths:
- **Off (the reference).** It reproduces the design export's staged 8-bit truncation, with no
  noise. The windowed UI suite holds it within MAE 0.10/255 and max 2 of the exported PNG.
- **Breathing.** A 12 s sine scales strength ±15 % and ellipse size ±1.5 % about the centre.
  The design's stops are composited in float and rounded once, `floor(v + 0.5 + noise)`, so no
  quantization contours move as the glow breathes.
- **The noise.** It is TPDF noise of ±1 code value, one value shared by R, G and B. It comes only
  from the pixel's screen position (`FRAGCOORD`), so it never moves between frames or with the
  breath. It has no boundary gate, so the background is not exact while breathing: outside the
  glow it rounds the base's 5 to 4, 5 or 6, averaging 5, which is zero mean bias, not
  pixel-exactness.
- **Versus Off.** The first breathing frame is not pixel-equal to Off. It stays within 3 code
  values, with a bias of about 0 outside the glow and up to about +0.75 code values in its core,
  where Off's staged truncation sits below the float composite.

If the shader cannot load, the `ColorRect`'s own #050505 remains.

**The lobby ship card** (`NRShipCard`, `assets\ui\ship_card.gdshader`) is drawn in code:
- an opaque #050505 card with square top corners and 12 px rounded bottom corners;
- three radial teal gradients from its top centre, composited with the design export's 8-bit
  truncation;
- a white 1 px outline at 15 % alpha.

It is static. A `ShipCardFill` child drawn behind the `ShipBackground` Panel paints the fill. The
fill's alpha follows the outline StyleBoxFlat's silhouette, including its anti-aliasing, and its
gradients are fractions of the card. The Panel keeps `clip_contents` for the rotated ship sprites,
and one rounded scissor trims the fill and the outline alike. Over the shader fill, the Panel's
StyleBoxFlat draws only the outline. Without the shader, the theme's opaque `LobbyShipPreview`
fill is the card.

**The ship preview** draws the 64x64 ship sprites at 300x300 through
`assets\ui\ship_preview.gdshader`. Bilinear filtering at that scale blurs every edge and shows the
source pixels as stair-steps. The sprites are hard shapes with anti-aliased edges, so the shader
takes coverage from a cubic B-spline of the sprite's alpha, re-thresholded at 0.5 with a
one-screen-pixel edge, and colour from a Catmull-Rom sample of the same texels: the outline stays
smooth and crisp, and the shading gradients stay smooth.

## Project layout

`scripts\services\` contains wrappers; `scripts\autoload\` contains their owners/coordinators;
`scripts\ui\` and `scenes\ui\` contain presentation. Addon source is pinned at
`external\xbox-godot-sample`; `addons\` is build output.
`MicrosoftGame.config` defines package identity and `project.godot` defines bootstrap/settings.
See [configuration](configuration.md), [addon maintenance](addon-maintenance.md) and the
[detailed gameplay layout](gameplay-reference.md#project-layout).
