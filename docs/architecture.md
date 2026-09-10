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
XboxBootstrap → Assets → AudioManager → PlayerProfile → Services → NetManager → ScreenManager → InviteRouter
```

`project.godot` is the authority for this order. Bootstrap must precede GDK use; profile defaults
and desktop cache loading precede service synchronization; services precede session checks.
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
XBOX user; custom-ID sessions still maintain authenticated Party text eligibility and player mutes.
They do not demonstrate XBOX privilege/privacy checks.

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
roster name when no verified name is available (including bots, custom-ID and failed claims).
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

`IdentityService.has_protected_storage()` selects the **console** path, not simply "GDK loaded".
Console profile, history and lifetime achievement counters go to the PlayFab Game Save folder as
`profile.json`, `history.json` and `stats.json`; the title does not put those account files in
console `user://`. Before sign-in/folder resolution, the console uses defaults and memory.

Desktop, including registered XBOX on PC, keeps local `user://settings.cfg`,
`match_history.json` and `achievement_stats.json`. Debug custom-ID tokens namespace each file.
These plaintext caches are not XBOX-account-scoped Game Save and do not demonstrate roaming.
See the [Game Save lesson](platform-services.md#game-saves) for initial sync, writes and failure behavior.

`Services` holds history and achievement counters in memory so suspend/user removal can write
without an asynchronous read. `persist_user_state()` commits durable state synchronously,
invalidates chat, clears identity, the folder handle, device associations, history and counters,
and resets profile identity. `persist_for_suspend()` commits without signing out: suspension is
not account removal. A local folder write is not proof of completed remote synchronization.

## Process lifecycle

`scripts\main.gd` handles Godot application notifications. A Middleware console fork's
`DisplayServerGDK` maps app-state and constrain notifications onto the scene tree. Desktop focus
changes exercise only the constrain path; **opening Guide is not evidence that actual suspend
occurred**.

| Event | Behavior |
|---|---|
| Suspend (`NOTIFICATION_APPLICATION_PAUSED`) | `Services.persist_for_suspend()`, `NetManager.abandon_for_suspend()`, then stop game audio. Session/chat state is invalidated synchronously. |
| Resume (`NOTIFICATION_APPLICATION_RESUMED`) | Restart music; if a match was abandoned, route to the menu with a notice unless a pending invite takes the front end. |
| Constrain (`NOTIFICATION_APPLICATION_FOCUS_OUT`) | Mute game audio and call `MatchDirector.set_externally_paused(true)`; retain session/identity. |
| Unconstrain (`NOTIFICATION_APPLICATION_FOCUS_IN`) | Restore game audio and local simulation/phase-clock advancement. |

**Maintainer invariant: suspend must remain straight-line:** no `await`, timers or deferred
persistence. The platform may freeze or terminate the process as soon as the handler returns.
The local peer is detached and the roster abandoned without awaiting `PartyService`'s native
network release; there is no direct peer close, reconnect or match resume promise.

Constrain freezes the local world's simulation and phase timers, including the client's clock,
but broadcasts no pause RPC and changes no settings. A constrained host stops advancing the
authoritative world; clients are not globally paused. Game-audio mute is not a Party microphone
permission change. Test those behaviors separately.

Ordinary desktop shutdown is different: `request_shutdown()` lets in-flight sign-in/Party
teardown drain while frames still pump completions, within a shared eight-second budget.
Console user removal commits state without waiting for navigation or remote teardown.

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
Practice stays available.

This is a **device-wide hint**, not a PlayFab endpoint reachability test. Only
`network_initialized == false` or level `NONE` counts as offline. `LOCAL_ACCESS`,
`CONSTRAINED_INTERNET_ACCESS` and unavailable hints leave the gate open; an actual service call
may still fail. An online session is ended after an eight-second offline grace period if the
hint is still down. Practice is unaffected.

`NRMenuList.refresh_focus_wrap()` rebuilds explicit focus paths when availability changes.
Focus must move off a newly disabled row rather than leave controller navigation stranded.

## Project layout

`scripts\services\` contains wrappers; `scripts\autoload\` contains their owners/coordinators;
`scripts\ui\` and `scenes\ui\` contain presentation. Addon source is pinned at
`external\xbox-godot-sample`; `addons\` is build output.
`MicrosoftGame.config` defines package identity and `project.godot` defines bootstrap/settings.
See [configuration](configuration.md), [addon maintenance](addon-maintenance.md) and the
[detailed gameplay layout](gameplay-reference.md#project-layout).
