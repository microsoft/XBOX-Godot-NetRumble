# Gameplay maintainer reference

> **You do not need this page to run or learn from the sample.** It is a secondary
> maintainer reference for contributors changing simulation, physics, tuning, netcode or
> presentation.

NetRumble is a 2D top-down space shooter: up to 8 players in ships, asteroids, weapon pick-ups,
and scoring. This secondary reference retains the simulation, tuning, netcode and presentation
detail. Gameplay is unchanged; it supplies traffic and match events for the platform demonstration.

Start with [Architecture](architecture.md), [Multiplayer](multiplayer.md) and
[Walkthroughs](walkthroughs.md) for the integration. Use [Protocol](protocol.md) for payload
schemas and [gameplay regression](manual-test-plan.md#secondary-gameplay-regression) after changes here.

---

## Project layout

```
addons/          godot_gdk, godot_playfab, godot_gdk_editortools (build output; see docs/addon-maintenance.md)
external/        xbox-godot-sample submodule, the addon source
MicrosoftGame.config   GDK identity (project root)
storelogos/      store tiles referenced by MicrosoftGame.config (.gdignore'd)
assets/
  textures/      51 sprites
  audio/         16 sound effects and music tracks
  tuning/        designer-facing .tres tuning for ships, asteroids, projectiles, power-ups
  fx/            gameplay_events.tres (GameplayEventType → effect scene)
  ui/            netrumble.tres (the project-wide Theme)
scenes/
  main.tscn      entry point
  gameplay/
    entities/    ship, asteroid, laser, rocket, mine, power-up, barrier
    fx/          one-shot particle effects and the parallax starfield
  ui/
    elements/    reusable controls (buttons, menu lists, spinners, roster rows,
                 chat lines, overlays)
    screens/     one scene per screen (7: acquire-user, main menu, match history,
                 lobby, gameplay, game menu, loading; Options is a row set built
                 into the main and game menus, not a screen of its own)
scripts/
  autoload/      Assets, AudioManager, PlayerProfile, Services, NetManager,
                 ScreenManager, InviteRouter (plus platform_session.gd, which
                 NetManager owns rather than being an autoload itself)
  gameplay/      simulation, match flow, shared types and constants
    objects/     ship, asteroid, projectiles, power-up
    tuning/      Resource subclasses backing assets/tuning/*.tres
  fx/            particle dispatch and starfield
  services/      identity, device, privilege, privacy, moderation, social, activity, party,
                 chat, achievement, game save, connectivity, profile
  ui/            screen implementations and element library
```

Designer-facing tuning lives in `assets/tuning/*.tres`, backed by `Resource` subclasses in
`scripts/gameplay/tuning/`. `scripts/gameplay/nr_const.gd` keeps only the genuinely global,
non-designer-facing values (world size, snapshot rates, spawn attempt counts);
`nr_types.gd` holds the shared enums.

---

## Simulation vs match flow

The simulation boundary:

- **`World`** owns *the simulation*: spawning, object pooling, collision response and per-object
  ticking. It does **not** run `_physics_process`; it is ticked explicitly.
- **`WorldNetworkSync`** owns *replication*: it builds the outgoing snapshot on the host and
  applies every inbound message on clients. Held by `World` as a plain object, deliberately not a
  child node, so it cannot acquire a tick of its own. See
  [Protocol](protocol.md) for the wire format it defines.
- **`MatchDirector`** owns *match flow*: the state machine, countdowns, the respawn queue,
  scoring, and win conditions. It calls `world.tick(delta)`.

Keeping the tick explicit is what lets gameplay logic be frozen during the loading and starting
phases. `World.set_simulation_running()` freezes the physics bodies to match.

A client ticks its `World` before the host's match-created payload arrives, so the barrier,
asteroids and ships may not exist yet. `World` guards against this rather than assuming an
initialized world.

---

## Netcode model and latency limits

These are limits of this game's replication, **not PlayFab Party limitations**.
`WorldNetworkSync` applies snapshots on arrival; [snapshot reconciliation](protocol.md#snapshot-reconciliation)
describes the exact reader/writer contract.

| Mechanism | Behavior |
|---|---|
| Remote interpolation | Non-local objects ease toward host state at `SNAPSHOT_LERP` (0.35), hiding the 30 Hz cadence and some jitter. |
| Local prediction | Local input moves the local ship each frame. Correction uses `LOCAL_SNAPSHOT_LERP` (0.12), preserves facing inside 25 degrees, and snaps beyond 250 px error. |
| Authoritative damage | Health, shield, weapon and buffs come from host snapshots rather than client prediction. |

There is no RTT measurement or clock synchronization, no acknowledged-input replay, no
server-side rewind for hits, and no buffered/time-based snapshot interpolation. Fixed correction
can pull a moving client back toward older host state; an apparent client-side hit can miss
the host's current target; arrival jitter passes into movement. `_receive_ship_input` already
carries a sequence, but snapshots do not acknowledge it.

Use a low-latency setup for the demonstration and record actual network conditions.
Wide-area latency can produce rubber-banding and apparent missed shots, especially with more
remote players. No measured latency guarantee follows from this model. Adding input replay,
rewind or buffering would be separate gameplay work with protocol implications.

---

## Physics

Movement, collision response and wall bounce are the **engine's** job, not the title's. Every
entity is a `RigidBody2D` (`GameObject extends RigidBody2D`) with a `CircleShape2D` sized from its
tuning resource; the barrier is a `StaticBody2D` with four thick slabs placed outside the play
area so nothing can tunnel through at max speed.

Collision layers (named in `project.godot`) encode the interaction rules:

| Entity | Layer | Mask | Notes |
|---|---|---|---|
| Ship | `ships` | ships, asteroids, walls | script-driven velocity decay; `linear_damp` stays 0 |
| Asteroid | `asteroids` | ships, asteroids, walls | `linear_damp` in `DAMP_MODE_REPLACE` |
| Laser / Rocket / Mine | `projectiles` | ships, asteroids, projectiles, walls | `mass = 0.001` |
| Power-up | `pickups` | ships | `mass = 0.001` |
| Barrier | `walls` | *(none)* | |

Maintainers changing this physics section should preserve two invariants:

- **"Detect but don't push" is done with negligible mass, not with layers.** Godot's collision
  test is `(A.layer & B.mask) || (B.layer & A.mask)`, an *or*, so one-way collision cannot be
  expressed with layers alone. Projectiles and power-ups instead carry a mass small enough that the
  solver reports the contact while transferring no meaningful momentum.
- **Contact damage must read `pre_step_velocity`.** `GameObject.tick()` runs before the physics
  step and caches it; by the time `body_entered` fires the solver has already exchanged momentum,
  so post-contact velocities under-report the impact.

Do **not** park a pooled body by disabling its `CollisionShape2D`; a `RigidBody2D` whose shapes
are all disabled is dropped by the physics server and never resumes integrating its transform, even
after the shape is re-enabled. `GameObject._sync_physics_state()` clears `collision_layer` /
`collision_mask` instead.

The physics server owns an active body's transform and overwrites plain `position` writes on its
next sync. Spawning, respawning and snapshot correction therefore go through
`GameObject.teleport()`, which pushes the transform to the server.

---

## Match state

`NRTypes.MatchState` is a set of flags, not an enumeration of exclusive values:

```
WAITING  = PLAYERS_JOINING | WARMING_UP  = 3
PLAYABLE = WAITING | RUNNING             = 19
```

Never compare composite states with `==`; use `NRTypes.has_match_state(state, flag)`.

The live flow is `PLAYERS_JOINING → STARTING → RUNNING`: the world is laid out once when the
last player finishes loading, the `STARTING` countdown runs on that final layout, and going live
only thaws the simulation. `WARMING_UP` is kept for the `WAITING` mask but is no longer entered,
so players are never repositioned mid-countdown.

---

## Object and player identifiers

Players are keyed by Godot `peer_id`; gameplay objects have their own `unique_id`.
`Projectile.owner_id` is a **ship** `unique_id`, not a peer id.
See [player identity](architecture.md#player-identity) for Party authentication and verified names,
and [saves](architecture.md#saves) for the profile/history/achievement-counter lifecycle.

---

## Coordinate convention

The coordinate system uses `forward = (sin θ, −cos θ)`: θ=0 points up, and increasing θ rotates
clockwise. This coincides naturally with Godot's 2D space (y-down, clockwise-positive rotation)
and the ship art, which points up, so sprites use `sprite.rotation = rotation` with **no
offset**.

Sprite scale is `2 * radius / textureDimension`. Godot's viewport handles aspect correction, so
no letterboxing factor is needed. Scale is baked into the entity `.tscn` scenes in the editor
rather than recomputed each frame.

---

## Camera

Gameplay lives in a real `Node2D` (`WorldContainer` in `main.tscn`) that is a **sibling** of the
UI `CanvasLayer`, driven by a real `Camera2D` that `gameplay_screen.gd` creates to follow the
local ship. `position_smoothing_enabled` does the easing; `limit_left/top/right/bottom` (taken
from the barrier bounds) does the clamping.

Do **not** introduce a manually-scrolled world root. A `Camera2D` has no effect on nodes parented
under a `CanvasLayer`. Assigning an ancestor `Node2D`'s `position` emits
`NOTIFICATION_TRANSFORM_CHANGED`, which makes every `CollisionObject2D` descendant push its node
transform back into the physics server and wipe out the motion the server just integrated.

---

## Starfield drift

`scripts/fx/starfield.gd` builds three `Parallax2D` depth layers, each drawing a runtime-baked
star tile. `Parallax2D` supplies camera parallax, but that only produces movement where a camera
moves, so the script also walks the layers slowly around a circle, giving the menus a drifting
sky. It runs in every scene, so the sky is continuous across a screen change.

Two `Parallax2D` details are worth having in writing, because both fail silently:
`scroll_offset` translates a layer 1:1 and is **not** scaled by `scroll_scale`, so the depth
factor must be applied by hand; and `repeat_times` must be sized to the viewport rather than left
at its default of `1`, or the right of a 1920-wide screen renders starless.

---

## Scoring

A killer scores **+1** only if the last damage came from another player's projectile.
Self-kills, and deaths to asteroids or barriers, cost the victim **−1**, floored at 0.
`MatchDirector` owns the rules.

---

## Theming

All `Control` styling comes from the project-wide `Theme` at `assets/ui/netrumble.tres`,
registered via `gui/theme/custom`. Per-control looks are `theme_type_variation`s (`NRMenuButton`,
`NRTitleButton`, `DialogTitle`, `SectionHeader`, `HealthBar`, …) rather than
`add_theme_*_override()` calls. A variation name must not collide with a built-in class name;
that is why the button variation is `NRMenuButton` and not `MenuButton`.

The default font is `assets/ui/segoe_ui.tres`, a `SystemFont` resolving the family **Segoe UI**
by name, so nothing proprietary is vendored and the theme still resolves on non-Windows
platforms. Sizes are derived from a 64 px design scale.

### Focus visuals

Every focusable control must show that it holds focus; it is a certification requirement, and on
a gamepad it is the only cursor there is. The themed `Button` variations carry it in their `focus`
stylebox and font color, which covers everything built from `nr_button.tscn`.

Controls that draw their own artwork cannot use that stylebox: the options rows (`NRSpinner`,
`NRSlider`) are plain `Control`s with no stylebox at all, and the lobby's ship tabs, color tabs
and stepper buttons override every `Button` stylebox with `StyleBoxEmpty` so the theme's gray slab
does not cover their textures. They use `NRFocusRing` instead, an accent outline added as the
**last child** of the control it marks, so it draws over the artwork rather than behind it, and
shown or hidden from the host's own `focus_entered` / `focus_exited`. `NRFocusRing.attach(control)`
is the whole API. Stripping a stylebox and attaching a ring go together.

Menu lists scroll, so every `ScrollContainer` holding focusable rows sets `follow_focus`.
Without it, gamepad navigation moves focus onto rows below the fold and nothing on screen
changes, which is indistinguishable from navigation not working at all.

---

## Screens as scenes

Screens are scenes, not subclasses. A screen with several sections uses one scene rather than
one scene per section:

- **Options** is one scrolling `NRMenuList` with `add_header()` section headings. Every setting is
  visible at once; a single toggle costs no navigation.

`ScreenManager.push()` takes an optional payload that it hands to the screen's `configure()`
before the screen enters the tree, which is how a caller parameterizes a screen without a
separate scene per variant: `LoadingScreen` and the dialog box both use it.

The row builders (`add_header`, `add_note`, `add_percent_spinner`, `add_bool_spinner`,
`add_choice_spinner`) live on `NRMenuList`, so a screen script is mostly a list of settings.
Headers and notes are children but not focus entries; gamepad navigation skips over them.

### Repeated widgets are element scenes

Anything that appears more than once, or that a screen rebuilds as state changes, is an element
scene under `scenes/ui/elements/`:

- `nr_roster_row.tscn` (`NRRosterRow`): the sheared roster panel: ship silhouette, ready ring,
  nameplate and microphone indicator. `set_state(PlayerState)` is the whole API;
  `set_state(null)` renders the "Invite To Game…" empty slot.
- `nr_chat_entry.tscn` (`NRChatEntry`): the in-match chat dialog. It does **not** close itself
  on submit: a failed send keeps the typed message, and closing is the owning screen's decision.
- `nr_chat_log.tscn` (`NRChatLog`): four retained messages rendered by ordinary `Label` rows
  (no BBCode), each wrapped with bounded height and no focus/input handling.
  The gameplay screen owns its transient history and clears it at
  match/session/identity boundaries; see [typed text](multiplayer.md#chat).
- `nr_player_actions.tscn` (`NRPlayerActions`): the lobby's per-player overlay: mute, report and
  view profile. Its action list is built in code rather than authored, because it lists only what
  is possible for that player, and picking "Report" replaces the list in place with the reason
  list rather than opening a second dialog.

### Lobby layout

The lobby uses a fixed 1920×1080 layout rather than flow containers, so its background textures
render 1:1 at their authored size. The ship and color selectors are tab strips built in
`lobby_screen.gd` rather than element scenes, because both are pure functions of the selection
index.

Maintainers changing this lobby layout should preserve two behaviors. There are **no footer
buttons**: ready-up is the `toggle_ready` action, read back from the ring in your own roster row,
and leaving is Back.
And the roster is **reconciled rather than rebuilt**: eight slots are allocated once at lobby
open, so a join, a leave or a ready toggle only re-binds them and gamepad focus is never dropped.

### Loading screen

Five concentric rings share one texture at increasing sizes, each rotating at its own rate and
direction. Two numbers matter and are easy to break: the rings are spaced **geometrically**
(×1.28) rather than arithmetically, because the texture's opaque band is wide enough that evenly
spaced rings overlap; and the tint ramp starts dark, because leaving the outer rings near-white
drops the caption over them to 2.3:1 contrast.
