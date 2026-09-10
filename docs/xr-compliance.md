# XBOX Requirements and where the code is

NetRumble is a sample for Microsoft GDK and PlayFab integration. A large part of that
integration exists because of the XBOX Requirements (XRs), the certification rules a
title must meet to ship on XBOX. This page maps each requirement to the code that
answers it, so you can find the equivalent call site for your own title.

Each heading links to the requirement on Microsoft Learn. Requirement text is quoted or
paraphrased from the [XBOX Requirements for XBOX console games][xr-index] (version 16.3,
1 July 2026); the [test cases][xr-tests] page is the companion document that describes
how certification actually exercises each one.

New to the XBOX vocabulary on this page? The [glossary](glossary.md) defines every term it
uses, one line each.

**Nothing here has been cert-tested.**  This is a map of the sample's code, not a record
of a submission outcome. It describes implemented paths and known gaps, not complete
requirement coverage. Use the [README environment matrix](../README.md#what-works-where),
[Walkthroughs](walkthroughs.md) and [Manual test plan](manual-test-plan.md) to distinguish
what can be demonstrated from what was actually observed. Custom-ID success is not XBOX
privilege/privacy coverage; desktop persistence is not console save roaming.

Scope is the game code under `scripts/`, plus `project.godot`, `MicrosoftGame.config`
and `export_presets.cfg`. The `addons/` tree (`godot_gdk`, `godot_playfab`) is a
dependency; it is cited to show which platform API a service wraps.

[xr-index]: https://learn.microsoft.com/en-us/gaming/gdk/docs/store/policies/console/certification-requirements
[xr-tests]: https://learn.microsoft.com/en-us/gaming/gdk/docs/store/policies/console/console-certification-requirements-and-tests

---

## Index

| XR | Requirement | Primary code |
| --- | --- | --- |
| [001](#xr-001-title-stability) | Title Stability | `scripts/main.gd` |
| [013](#xr-013-linking-microsoft-accounts-with-publisher-accounts) | Linking Microsoft Accounts with Publisher Accounts | `scripts/services/identity_service.gd` |
| [014](#xr-014-player-data-and-personal-information) | Player Data and Personal Information | `scripts/services/identity_service.gd`, `scripts/autoload/player_profile.gd` |
| [015](#xr-015-managing-player-communication) | Managing Player Communication | `scripts/services/privacy_service.gd` |
| [018](#xr-018-user-generated-content) | User-Generated Content | `scripts/services/moderation_service.gd` |
| [022](#xr-022-official-naming-standards) | Official Naming Standards | `scripts/ui/screens/lobby_screen.gd`, `MicrosoftGame.config` |
| [045](#xr-045-xbox-network-and-account-privileges) | XBOX network and Account Privileges | `scripts/services/privilege_service.gd` |
| [046](#xr-046-display-name-and-gamerpic) | Display Name and Gamerpic | `scripts/services/profile_service.gd` |
| [047](#xr-047-user-profile-access) | User-Profile Access | `scripts/services/moderation_service.gd` |
| [048](#xr-048-profile-settings-usage) | Profile Settings Usage | `scripts/services/profile_service.gd` |
| [052](#xr-052-user-state-and-title-save-location-roaming-and-dependencies) | User State and Title-Save Location | `scripts/services/game_save_service.gd` |
| [055](#xr-055-achievements-and-gamerscore) | Achievements and Gamerscore | `docs/achievements2017.xml` |
| [057](#xr-057-unlocking-achievements) | Unlocking Achievements | `scripts/services/achievement_service.gd` |
| [064](#xr-064-joinable-game-sessions-and-online-play) | Joinable Game Sessions and Online Play | `scripts/services/activity_service.gd` |
| [067](#xr-067-maintaining-multiplayer-session-state) | Maintaining Multiplayer Session State | `scripts/autoload/platform_session.gd` |
| [070](#xr-070-friends-lists) | Friends Lists | `scripts/services/social_service.gd` |
| [074](#xr-074-loss-of-connectivity-to-xbox-and-partner-services) | Loss of Connectivity | `scripts/services/connectivity_service.gd` |
| [112](#xr-112-controller-association) | Controller association (partial) | `scripts/services/device_service.gd` |
| [115](#xr-115-controller-and-user-removal) | Controller and user removal (partial) | `scripts/main.gd`, `scripts/autoload/services.gd` |
| [124](#xr-124-game-invitations) | Game Invitations | `scripts/services/activity_service.gd` |
| [130](#xr-130-xbox-console-families-and-generations) | XBOX Console Families and Generations | `MicrosoftGame.config` |

---

## XR-001: Title Stability

<https://learn.microsoft.com/en-us/gaming/gdk/docs/store/policies/xr/xr001>

Products must start up promptly, keep running, stay responsive, and shut down
gracefully. In practice this is the game life cycle: suspend, resume and constrain.

`main.gd` `_notification()` handles all four lifecycle notifications plus the close
request. On XBOX these arrive from `DisplayServerGDK`, which registers for
`RegisterAppStateChangeNotification` and `RegisterAppConstrainedChangeNotification` and
mirrors them onto the Godot scene tree as ordinary notifications, so a Godot title
handles them the same way it handles any other engine notification.

- **Suspend** calls `Services.persist_for_suspend()`, then
  `NetManager.abandon_for_suspend()`, then stops audio. The handler is straight-line:
  no `await`, no `call_deferred`, no timers, because the process is frozen the instant
  it returns and the platform commonly terminates rather than resumes.
- **Resume** restarts music and, if the session was dropped, returns to the main menu.
- **Constrain** (`NOTIFICATION_APPLICATION_FOCUS_OUT` / `_IN`) mutes audio through
  `AudioManager.set_system_muted()` and freezes the match through
  `MatchDirector.set_externally_paused()`, so the match clock cannot expire behind an
  open Guide.

Opening Guide or alt-tabbing demonstrates **constrain**, not necessarily suspend. Verify an
actual suspend notification separately: it abandons the match, clears transient chat and
persists state without waiting for the network. Constrain retains the session and only freezes
the local director; it broadcasts no global pause. Game-audio mute is separate from Party voice.

Quit is desktop-only; on console the platform owns leaving the game.
`NRScreen.is_console()` gates the quit row.

**Code:** `scripts/main.gd`, `scripts/autoload/net_manager.gd`
(`abandon_for_suspend`), `scripts/autoload/audio_manager.gd`,
`scripts/gameplay/match_director.gd` (`set_externally_paused`).

---

## XR-013: Linking Microsoft Accounts with Publisher Accounts

<https://learn.microsoft.com/en-us/gaming/gdk/docs/store/policies/xr/xr013>

Titles using partner-hosted services must offer to link that account to the user's
Microsoft account, and must authenticate the link with an XSTS token rather than
credentials collected in-game.

PlayFab is the partner-hosted service here.  `IdentityService.sign_in()` links the two
accounts with `PlayFab.users.sign_in_with_xuser_async(xbox_user)`, which exchanges the
GDK `XUser` for a PlayFab identity through XSTS. The title never presents a login form
and never handles a credential.

A `--pf-user` / `PF_CUSTOM_ID` flag enables `sign_in_with_custom_id_async` so two
instances can run on one desktop for testing. That path bypasses XBOX sign-in, so it is
disabled by a runtime build-feature guard on console and exported release builds:
`IdentityService.developer_overrides_allowed()` returns `false` when
`OS.has_feature("scarlett")` is true or the build is not a debug build, and both
`resolve_custom_id_token()` and the `--pf-title` handler consult it. It requires a separate
development PlayFab title permitting custom-ID creation, not a change to committed identifiers.

**Code:** `scripts/services/identity_service.gd` (`sign_in`,
`developer_overrides_allowed`, `resolve_custom_id_token`).

---

## XR-014: Player Data and Personal Information

<https://learn.microsoft.com/en-us/gaming/gdk/docs/store/policies/xr/xr014>

Titles must not expose information that identifies or impersonates a player, and must
handle player data lawfully.

The sample handles account identifiers, gamertags and player-authored chat for the integration;
this page is not a privacy/legal assessment. Console `user://` is one storage area shared
by the whole title, so a settings
file written there outlives the account that wrote it and is readable by the next
account signed in on that console.

`IdentityService.has_protected_storage()` is the single predicate that decides where
state goes. On console, `profile.json`, `history.json` and `stats.json` are written only to the
PlayFab Game Save synced folder, which the platform scopes per user and protects at
rest; nothing is written to `user://` at all. On desktop, where there is no synced
folder, a plain `ConfigFile` at `user://settings.cfg` is used instead. Registered XBOX on PC
uses this same desktop path. It is not a protected per-XBOX-user store.
Typed-text history stays in the in-match UI only, with at most four rows; it is not saved.

`IdentityService._publish_entity_display_name()` writes the gamertag to the PlayFab
entity profile so PlayFab surfaces show a name rather than a raw entity id. An entity
id is an account identifier and is not for display.

**Code:** `scripts/services/identity_service.gd` (`has_protected_storage`,
`_publish_entity_display_name`), `scripts/autoload/player_profile.gd`,
`scripts/autoload/services.gd` (`_load_local_history`, `_save_local_history`),
`scripts/services/game_save_service.gd`.

---

## XR-015: Managing Player Communication

<https://learn.microsoft.com/en-us/gaming/gdk/docs/store/policies/xr/xr015>

Titles must not allow communication over the XBOX network when the user's privacy
settings do not permit it. The two permissions to check are `CommunicateUsingText` and
`CommunicateUsingVoice`.

`PrivacyService.evaluate()` batches both permissions through
`batch_check_permission_async` for every remote XUID, then overlays the platform mute
and avoid lists. `Services` clears cached account state on relevant `user_changed` events
(`privileges`, `signed_in_again`, account add/removal); it does not subscribe to a separate
continuous privacy-change feed.
`PlatformSession.apply_chat_restrictions()` runs the evaluation on every `roster_changed`
and pushes the verdicts into `ChatService.set_peer_restrictions()`.
Account-cache invalidation also triggers re-evaluation; retained text is cleared while the
new verdicts are pending.

Voice and typed text are separate verdicts. Voice denial removes audio permissions; allowed
text independently grants `CHAT_PERMISSION_RECEIVE_TEXT`. Self-mute and player/platform
voice mute do not imply text denial. Text is addressed to an explicit eligible target list;
`send_chat_text()` refuses when it is empty instead of triggering the addon's empty-list broadcast.

`ChatService` also checks text eligibility/lifecycle at receive time. Pending, missing or failed
XBOX text answers deny new text (`PrivacyService` defaults text to `false`, without changing
the voice fallback). These query failures are not cached as permanent text denials.
Roster removal immediately removes text-recipient eligibility, even if a chat control lingers.
`NetManager` resolves senders through `PartyService.entity_key_for(peer_id)` and the current
roster, not a replicated identity fallback. `NRChatLog` removes newly restricted senders' rows and clears on
match/session/identity loss. No raw `original_text`, transcription or translation is displayed.
ReceiveText does not require speech features to be enabled.

The chat flags in `PartyService._make_party_config()` are derived from the
communications privilege (XR-045) rather than hardcoded. A peer with no XUID on a
session where privacy is available fails closed. Custom-ID bypasses XBOX privacy; it still
admits text only for recognized session peers. The existing voice-query fail-open behavior
and account-event refresh coverage remain limitations to exercise, not certification guarantees.

**Code:** `scripts/services/privacy_service.gd`,
`scripts/autoload/platform_session.gd` (`apply_chat_restrictions`, `toggle_peer_mute`),
`scripts/services/chat_service.gd` (`_apply_peer_policy`, `_apply_peer_permissions`,
`_on_text_message_received`), `scripts/ui/elements/nr_chat_log.gd`,
`scripts/services/party_service.gd` (`_make_party_config`).

---

## XR-018: User-Generated Content

<https://learn.microsoft.com/en-us/gaming/gdk/docs/store/policies/xr/xr018>

Titles containing UGC must provide an in-product way to report it, or proactively detect
inappropriate content, and must respect the player's UGC privileges.

Typed chat is the only content a player authors in this sample.
`NetManager.send_chat_message()` is the single outgoing funnel and calls
`Services.verify_chat_text()` before `ChatService.send_chat_text()`. With an XBOX user/GDK,
verification failure or refusal prevents submission; the entry stays open with its text and a
reason. Custom-ID bypasses XBOX string verification and cannot validate that protection.
Accepted sends produce one local echo after successful Party submission, not a delivery receipt.

Reporting is available from `NRPlayerActions`, opened from an occupied lobby roster row.
`ModerationService.report()` submits reputation feedback through
`submit_reputation_feedback_async`.

**Code:** `scripts/autoload/net_manager.gd` (`send_chat_message`, `report_player`),
`scripts/services/moderation_service.gd`,
`scripts/ui/elements/nr_player_actions.gd`.

---

## XR-022: Official Naming Standards

[Requirement text][xr-index] (XR-022 has no standalone page; it is defined in the index
and points at the [Terminology List][terminology].)

[terminology]: https://learn.microsoft.com/en-us/gaming/gdk/docs/store/policies/console/console-certification-terminology

Titles must use the terms in the current Terminology List for console and XBOX network
features, and must not invent names for system components.

- `LobbyScreen._prompt_for()` reads the binding out of Godot's `InputMap` and renders
  the official XBOX button name on console (`X Ready  Y Mute  B Leave`), falling back to
  keyboard labels on desktop. A Godot title that ships the default `ui_accept` glyphs
  will fail this.
- `MicrosoftGame.config` `PublisherDisplayName` is `Xbox Advanced Technology Group`.
- Documentation uses "XBOX network" for the service and "XBOX services" for the APIs.

**Code:** `scripts/ui/screens/lobby_screen.gd` (`_prompt_for`), `MicrosoftGame.config`.

---

## XR-045: XBOX network and Account Privileges

<https://learn.microsoft.com/en-us/gaming/gdk/docs/store/policies/xr/xr045>

Titles must check XBOX network privileges before allowing the actions they gate, and
must invoke the system UI so a restricted player (typically a child account) can request
an exception.

`PrivilegeService` is the only place the privilege API is called.  `MULTIPLAYER := 254`
and `COMMUNICATIONS := 252` are the `XPRIVILEGE_MULTIPLAYER_SESSIONS` and
`XPRIVILEGE_COMMUNICATIONS` ids from the requirement's table.  `ensure()` offers
`resolve_privilege_with_ui_async` when a denial is resolvable, then re-checks once with
the cache bypassed. The requirement is explicit that privilege state must not be
assumed to persist.

`NetManager._require_multiplayer_privilege()` gates host, join-by-code and
join-by-invite through one funnel.  `PlatformSession.apply_chat_privilege()` resolves
communications before the Party network is built.
Revocation detected mid-session destroys the chat control. After the privilege is restored,
leave/rejoin is required to recreate it; live network reconfiguration is not demonstrated.

Privilege queries fail **open** when there is no initialized GDK/user or when the query itself
fails (with a warning for failed queries). Real registered XBOX on PC is supported; custom-ID
bypasses these checks. Known denial is enforced, but this fallback is a sample limitation.

**Code:** `scripts/services/privilege_service.gd`,
`scripts/autoload/net_manager.gd` (`_require_multiplayer_privilege`),
`scripts/autoload/platform_session.gd` (`apply_chat_privilege`).

---

## XR-046: Display Name and Gamerpic

<https://learn.microsoft.com/en-us/gaming/gdk/docs/store/policies/xr/xr046>

On console the gamertag must be the primary display name, and it must be rendered
correctly for the gamertag type in use: 15 ASCII characters for a classic gamertag, all
16 characters including the `#` suffix for a modern one.

`IdentityService.sign_in()` reads `xbox_user.gamertag` (the classic gamertag) for the
local player. For remote players `ProfileService` prefers the modern in-game display
name from `get_game_display_name()` and falls back to `get_gamertag()`; both are
service-issued, neither is player-supplied text.  `PlayerState.display_label()` is the
single read point and falls back to the roster-supplied name for bots, offline play and
peers whose XUID claim did not verify.

Gamerpics are not displayed anywhere in this sample. The requirement governs displaying
one correctly, not displaying one at all.

**Code:** `scripts/services/identity_service.gd` (`sign_in`),
`scripts/services/profile_service.gd` (`_load_gamertags`),
`scripts/gameplay/player_state.gd` (`display_label`).

---

## XR-047: User-Profile Access

<https://learn.microsoft.com/en-us/gaming/gdk/docs/store/policies/xr/xr047>

> Titles must give users the option to access other XBOX network users' gamercards (user
> profiles) wherever users' display names are enumerated.

`ModerationService.show_profile_card()` calls
`gdk.game_ui.show_player_profile_card_async(user, target_xuid)`, which raises the system
gamercard. It is reached from `NRPlayerActions`, opened by activating an occupied
roster row in the lobby.

**Partial.** The lobby roster is covered. The in-match roster, typed-text sender labels and
friend list also enumerate names without a gamercard path, so this is not full coverage.

**Code:** `scripts/services/moderation_service.gd` (`show_profile_card`),
`scripts/autoload/net_manager.gd` (`show_player_profile`),
`scripts/ui/elements/nr_player_actions.gd`.

---

## XR-048: Profile Settings Usage

<https://learn.microsoft.com/en-us/gaming/gdk/docs/store/policies/xr/xr048>

XBOX is the source of truth for profile information. Titles must not store gamertags or
other XBOX-sourced profile data beyond a local cache used to survive disconnection, and
must refresh that cache on the next connection.

Nothing XBOX-sourced is persisted.  `PlayerProfile.to_dict()`, the cloud-save payload,
holds audio, appearance, video, HUD and gameplay settings only; no gamertag, XUID or
entity id appears in it.

Gamertags live in `ProfileService`'s in-memory dictionaries for the life of the process.
`clear_session()` drops the per-peer map when a session ends because peer ids are
reused; `clear()` also drops the XUID-keyed caches when the user changes, because those
answers were obtained with the departing account's credentials.

**Code:** `scripts/services/profile_service.gd` (`clear_session`, `clear`),
`scripts/autoload/player_profile.gd` (`to_dict`).

---

## XR-052: User State and Title-Save Location, Roaming and Dependencies

<https://learn.microsoft.com/en-us/gaming/gdk/docs/store/policies/xr/xr052>

Titles must associate saved state with the user who created it, must avoid saving state
for a user who is no longer signed in, and save data must not depend on local storage.

- **Per-user by construction.** On console, saves go exclusively to the PlayFab Game
  Save synced folder, which the platform partitions per user and roams across consoles.
  `IdentityService.has_protected_storage()` gates the choice.
- **User removal commits state.** `Services._on_user_changed()` handles `removed` by
  calling `persist_user_state()` when the removed user is the signed-in one: it writes
  settings, history and achievement counters, clears identity/the Game Save handle, and
  clears in-memory account/chat state. The whole path is synchronous, with no `await`
  anywhere, because the process may be torn down on the next frame.

Writing into the synced folder *is* the save; the platform flushes that folder after the
title closes, which is why nothing calls `upload_with_ui_async` on this path.
Folder resolution/writes can fail; console then has no desktop-cache fallback.
A successful local write does not prove roaming. Observe the same account on a second console
after synchronization, and a different account for isolation; see the
[Game Save walkthrough](walkthroughs.md#console-game-save-and-account-isolation).

**Code:** `scripts/services/game_save_service.gd`,
`scripts/autoload/services.gd` (`_on_user_changed`, `persist_user_state`),
`scripts/services/identity_service.gd` (`has_protected_storage`, `sign_out`).

---

## XR-055: Achievements and Gamerscore

[Requirement text][xr-index] (XR-055 has no standalone page; it is defined in the index.)

Every XBOX console title must ship achievements, and the launch bar is fixed: **minimum
10 achievements, 1000 gamerscore, and no single achievement above 200 gamerscore**.

`docs/achievements2017.xml` is built to exactly that bar: ten achievements totalling
1000 gamerscore, the largest worth 200:

| Id | Achievement | Gamerscore | Kind |
| --- | --- | --- | --- |
| 1 | Finish your first match | 25 | one-shot |
| 2 | Get destroyed for the first time | 25 | one-shot |
| 3 | Destroy your first enemy ship | 25 | one-shot |
| 4 | Win a match | 100 | one-shot |
| 5 | Win a match without being destroyed | 150 | one-shot |
| 6 | Fire every weapon at least once | 125 | incremental |
| 7 | Collect every buff power-up | 100 | incremental |
| 8 | Destroy 250 asteroids | 100 | incremental |
| 9 | Complete a match in every game mode | 150 | incremental |
| 10 | Destroy 100 enemy ships | 200 | incremental |

`docs/achievements2017.xml` and `docs/localization.xml` describe the sample title's definitions;
their presence is not a live-service verification result. Unlocking on PC requires registered
launch, **XDKS.1** and an eligible XBOX account. The id must resolve on the configured service;
`AchievementService` warns on a failed update. Observe the platform UI, not just a local counter.

**Code:** `docs/achievements2017.xml`, `docs/localization.xml`,
`scripts/services/achievement_service.gd` (the id constants).

---

## XR-057: Unlocking Achievements

<https://learn.microsoft.com/en-us/gaming/gdk/docs/store/policies/xr/xr057>

Achievements must be earnable through gameplay alone, without buying additional content,
and must not be unlockable by any non-gameplay shortcut.

Two objects split the work.  `AchievementTracker` holds the lifetime counters and
converts them to a percentage; `AchievementService` calls
`update_achievement_async(user, id, percent)`, which maps to
`XblAchievementsManagerUpdateAchievement`. One-shot achievements report `100`;
incremental ones report progress as the counters move.

- Progress is reported per player, on that player's own console, against the local
  signed-in user. The host never unlocks on a client's behalf.
- The counters advance offline, including in practice matches with no identity at all,
  and `resync()` re-reports them once sign-in resolves. The service keeps the highest
  percentage it has been told, so a replayed report is harmless.
- The "every weapon" and "every buff" achievements track bitmasks over the `NRTypes`
  enums, so adding a weapon or buff moves the target instead of leaving the achievement
  reachable without it.

The sample has **no in-game achievement list**; the Guide is the only place progress is
visible. That is permitted, but a shipping title usually wants its own surface.

**Code:** `scripts/services/achievement_service.gd`,
`scripts/services/achievement_tracker.gd`, `scripts/autoload/services.gd` (counter feeds
and `resync`).

---

## XR-064: Joinable Game Sessions and Online Play

<https://learn.microsoft.com/en-us/gaming/gdk/docs/store/policies/xr/xr064>

Titles offering joinable sessions must make them joinable through the XBOX shell, and,
for PC builds using XBOX sign-in, through Game Bar.

- `ActivityService` publishes an activity on host and join, keeps player count, the
  `followed` join restriction and a `group_id` (the join code) in step with the roster,
  and deletes the activity on leave. Updates are coalesced, so a join storm is one call.
- It subscribes to the GDK singleton's `activation` for `invite_accepted`,
  `pending_invite_received` and `protocol_activated`, normalizing all three into one
  `join_requested` signal.
- `InviteRouter` buffers an activation that arrives before sign-in resolves (the normal
  path for a cold launch from an invite), resolves the host's XUID once a user is signed
  in, and lands the player in the lobby.
- The GDK runtime starts at process launch through `XboxBootstrap`, ahead of `Services`,
  so an activation delivered before sign-in is not dropped. Autoload order in
  `project.godot` is what guarantees this.
- `allow_cross_platform_join` is `true`, which the XBOX shell requires before it will
  offer "Join Game" between the console and PC GDK builds.

**Code:** `scripts/services/activity_service.gd`, `scripts/autoload/invite_router.gd`,
`scripts/autoload/platform_session.gd`, `project.godot` (autoload order),
`MicrosoftGame.config` (protocol activation).

---

## XR-067: Maintaining Multiplayer Session State

<https://learn.microsoft.com/en-us/gaming/gdk/docs/store/policies/xr/xr067>

Titles with online multiplayer must maintain session state on the XBOX network, either
through MPSD **or**, for a title with its own session state, by recording player
interactions with the Multiplayer Activity Recent Players feature.

NetRumble takes the second route: PlayFab Lobby and Party own session state, so MPSD is
not needed.  `PlatformSession._report_recent_players()` reports every XUID in the session
once the match is genuinely running, not from the lobby, and at most once per session.
The service flush is coalesced.

Presence moves with the session in the same place: "Hosting a match" / "In a match" on
connect, "Playing &lt;mode&gt;" once running, "Practice match" offline, "In the menus" on
leave.

**Code:** `scripts/autoload/platform_session.gd` (`_report_recent_players`, presence
updates), `scripts/services/activity_service.gd`.

---

## XR-070: Friends Lists

[Requirement text][xr-index] (XR-070 has no standalone page; it is defined in the index.)

Titles must use the XBOX network friends list as the primary list of friends, must
source it from XBOX APIs, and must not store it permanently on game servers.

The "Join Friend" row on the main menu opens `nr_friend_list.tscn`. The list is built
live from two platform reads and nothing is persisted: `SocialService.friends()` (the
Social Manager graph) answers who the friends are, and
`ActivityService.joinable_activities()` answers which of them are in a joinable session.
Only joinable friends are listed.

Joining reuses `NetManager.join_by_invite()` with the activity's connection string, so a
friend join and an accepted invite converge on one code path.

**Code:** `scripts/services/social_service.gd`,
`scripts/services/activity_service.gd` (`joinable_activities`),
`scripts/autoload/services.gd` (`joinable_friends`),
`scripts/ui/elements/nr_friend_list.gd`.

---

## XR-074: Loss of Connectivity to XBOX and Partner Services

<https://learn.microsoft.com/en-us/gaming/gdk/docs/store/policies/xr/xr074>

Titles must handle XBOX and partner service connectivity errors gracefully, message the
player appropriately, and must not blame the XBOX network for a partner service outage.

- `ConnectivityService` subscribes to `XboxNetworking`'s `connectivity_hint_changed` and
  collapses the hint into one `connectivity_changed(online)` signal. The main menu grays
  out Host and Join and shows "No connection, online play unavailable", leaving Practice
  selectable.
- `NetManager._on_connectivity_changed()` starts an 8-second grace period on loss and
  re-checks before acting, so a brief hint flap does not end a match Party would have
  survived.
- `PartyService.network_lost` (the terminal Party failures `NETWORK_CHANGE_DESTROYED`,
  `DISCONNECTED` and `FAILED`) routes into `NetManager._on_server_disconnected()`, the
  same path a host departure uses.

The gate **fails open** by design: only `network_initialized false` and connectivity
level `NONE` count as offline. A false "offline" locks a player with a working
connection out of online play with no recourse; a false "online" costs one failed
attempt.

**Code:** `scripts/services/connectivity_service.gd`,
`scripts/autoload/net_manager.gd` (`_on_connectivity_changed`,
`_on_server_disconnected`), `scripts/services/party_service.gd` (`network_lost`),
`scripts/ui/screens/main_menu_screen.gd`.

---

## XR-112: Controller association

[Requirement text][xr-index].

**Partial.** `DeviceService.start(user)` reads `gdk.users.get_devices_for_user(user)` and
tracks `device_association_changed`. Platform associations are preferred once observed;
Godot's connected joypads provide a fallback when they are unavailable.

This detects associations; it does not assign a Godot device index to an XBOX user.
The sample has no per-user input filter or sign-in-time controller picker. All connected
devices can still contribute input, so the detection path is not proof of exclusive ownership.

**Code:** `scripts/services/device_service.gd`, `scripts/autoload/services.gd`
(`_warm_account_state`). See [controller behavior](platform-services.md#controller-association).

---

## XR-115: Controller and user removal

[Requirement text][xr-index].

`DeviceService.controller_lost` shows the `ControllerDisconnectOverlay` owned by `main.gd`;
`controller_bound` hides it automatically. Loss does not pause or abandon the network match.
Keyboard-only desktop startup does not count as losing a controller.

When the platform removes the signed-in XBOX user, `Services.persist_user_state()` commits
settings/history/counters synchronously and invalidates account/chat state. The simplified
user model does not provide an in-game account-switching session.

**Partial.** Exercise account-scoped device events and user removal on authorized hardware.
The overlay alone does not establish input filtering or full requirement compliance.

**Code:** `scripts/main.gd` (`_on_controller_lost`, `_on_controller_bound`),
`scripts/services/device_service.gd`, `scripts/autoload/services.gd`
(`_on_user_changed`, `persist_user_state`).

---

## XR-124: Game Invitations

[Requirement text][xr-index] (XR-124 has no standalone page; it is defined in the index.)

> Games that support joinable multiplayer experiences must allow players to send game
> invitations using the XBOX network platform from within the game.

Empty lobby roster slots render as "Invite To Game…" and are real focus targets, so a
controller can reach them. Activating one calls
`ActivityService.show_invite_ui(user)` → `show_invite_ui_async`, which raises the system
player picker. The platform owns the picker and the sending; the title supplies only the
activity to invite into.

`LobbyScreen._can_invite()` keeps the slots inert until there is a published activity to
invite someone to, so a practice match, or a session that has not yet registered an
activity, does not offer an invite that would fail.

The receiving side is XR-064: `ActivityService` normalizes `invite_accepted` and
`pending_invite_received`, and `InviteRouter` turns them into a join.

**Code:** `scripts/services/activity_service.gd` (`show_invite_ui`),
`scripts/ui/screens/lobby_screen.gd` (`_can_invite`, `_on_invite_requested`),
`scripts/ui/elements/nr_roster_row.gd`.

---

## XR-130: XBOX Console Families and Generations

<https://learn.microsoft.com/en-us/gaming/gdk/docs/store/policies/xr/xr130>

A title targeting a console generation must support the whole family of devices in it,
must be navigable by gamepad throughout, and must roam saves across the generation.

The title targets XBOX Series X|S only; there is no XBOX One SKU or Smart Delivery pairing.
Screens use focusable controls and `NRScreen` restores focus on reveal; gamepad coverage
still requires the manual pass, including system text entry and the passive chat panel.
Game Save supplies the roaming mechanism (XR-052), not evidence that it has been observed
across the console family. Test both device coverage and synchronization before claiming them.

This XR becomes a hard blocker if an XBOX One SKU is ever added, and the store listing
must match the decision.

**Code:** `MicrosoftGame.config`, `export_presets.cfg`,
`scripts/ui/screens/screen.gd` (focus restoration).
