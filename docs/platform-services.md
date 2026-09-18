# Platform services: sign-in, achievements and saves

> **This page is for Godot developers learning how sign-in, policy, achievements and saves fit
> around the sample.** You can skip maintainer notes marked as editing instructions unless you
> are changing a service wrapper or config.

`Services` owns the wrappers described here, including `PartyService` and `ChatService`;
`NetManager` consumes them and its `PlatformSession` helper applies session policy.
Use the [README capability matrix](../README.md#what-works-where) for environment
coverage and [Walkthroughs](walkthroughs.md) for player actions and observable outcomes.

See also: [Architecture](architecture.md) · [Multiplayer](multiplayer.md) ·
[Configuration](configuration.md)

---

## Sign-in
The first screen the game shows is the **acquire-user screen**
(`scenes/ui/screens/acquire_user_screen.tscn`). It owns authentication and save loading:

| Stage | What the player sees |
|---|---|
| Previous session cleanup | **Finishing the previous session** while resume/account-change Party and chat teardown drains; not Ready |
| Authenticating / loading saves | Progress while `Services` resolves identity and prepares/loads the account store |
| Needs interaction | The failed stage/reason plus **Retry / Back** |
| Ready | Signed-in account and complete saved state, then a hand-off to the main menu |

The dedicated screen shows each asynchronous stage and keeps any platform UI from competing
with a live main menu. It does not imply that every sign-in opens an account picker: this
sample's simplified user model normally supplies the launching XBOX user.

**Every gameplay path, including Practice, requires an account and ready saves.** Back
abandons acquisition without enabling play; late results cannot hand off to a menu or restore
an old account's state. Retry reattempts save preparation even when authentication already
succeeded. Repeated Retry must not start overlapping preparation operations.
Acquisition cannot hand off before pending session teardown completes. If cleanup stalls,
the existing watchdog exposes **Back** and PC **Quit**; Back abandons the readiness attempt,
not the native cleanup or safety gate. Quit uses the existing shared shutdown deadline,
including a chat destroy whose local control handle is already cleared. No timeout permits
gameplay through an unfinished teardown.

### GDK → PlayFab identity exchange

The shipping sign-in path:

1. `IdentityService._ensure_xbox_user()` uses `XBOX.users.get_primary_user()` when already
   signed in, otherwise `XBOX.users.add_default_user_async()` resolves the launching `XboxUser`.
2. `PlayFab.users.sign_in_with_xuser_async(xbox_user)` exchanges that user for a `PlayFabUser` (a PlayFab entity
   token).
3. `IdentityService._publish_entity_display_name()` calls
   `PlayFab.accounts.set_display_name_async()` to publish the gamertag as the entity display name.
4. `Services` prepares Game Saves and stages settings, history and counters for that account.
   Only successful, current-owner loading publishes ready state and permits gameplay and
   achievement reporting. Account policy and device association use the same identity.

User-change events are subscribed before Xbox acquisition starts. If bootstrap has not
initialized GDK, the identity fallback first initializes it successfully, then emits
`platform_ready`; cancellation is checked before the next account API call. The later
post-authentication subscription check remains idempotent, but is not relied on to catch
removal during Xbox or PlayFab acquisition.

Friends-group loads are single-flight per owner and generation. Clearing an account releases
its load guard and waiting readers immediately, so a replacement account need not wait for
the old SDK call. A late successful old group is destroyed rather than cached, and its
completion cannot release the replacement's guard. Current read/load failures keep the
existing warning-and-empty-result contract; no previous account's group is substituted.

This requires a registered build of the game, a signed-in XBOX identity on the machine, and a
title configured for XBOX authentication. For this sample use **XDKS.1** and an authorized test
account. Registration, XBOX acquisition, PlayFab authentication and Game Save sync are distinct
steps; a displayed gamertag alone is not proof that every service succeeded.
See [Configuration](configuration.md).

With the simplified user model (`AdvancedUserModel=false`), `XBOX.users.add_default_user_async()`
supplies the launching user. The interactive add (`add_user_with_ui_async()`) fails with
`E_INVALIDARG` under the simplified model; the fallback remains in the wrapper, but do not rely
on it to acquire another user. Sign in to the XBOX app before registered PC launch. A failed
attempt exposes its reason and allows Retry or Back; no failure offers unsaved Practice.

Debug desktop `--pf-user` instead calls `PlayFab.users.sign_in_with_custom_id_async()`, with
account creation allowed only by the separate development title selected by `--pf-title`.
There is no signed-in XboxUser on this path. Authentication may
succeed as a debug diagnostic, but Game Saves cannot become ready, so gameplay stays blocked.

> The GDK singleton is registered under the name in `gdk/runtime/singleton_name`, which this
> project sets to `XBOX` (see [Addon maintenance](addon-maintenance.md#xbox-class-prefix-and-the-xbox-singleton)).
> Services resolve it through `XboxBootstrap.find_singleton()` rather than the global, so the
> name stays a project setting: code reads `gdk.users.add_default_user_async()`.

---

## Privileges and player communication
Two XR requirements shape what an account is allowed to do online, and both are enforced
title-side (see [XBOX Requirements](xr-compliance.md), XR-045 and XR-015).

`PrivilegeService` is the only place that calls `check_privilege_async` and
`resolve_privilege_with_ui_async`. The addon forwards the privilege integer straight to
`XUserCheckPrivilege()` without named constants, so the two the title needs are declared locally:
`MULTIPLAYER` (254) and `COMMUNICATIONS` (252), taken from the GDK `XUserPrivilege` reference.

- **Multiplayer** is required before hosting and before every join path. `NetManager` funnels
  host, join by code and join by invite through `_require_multiplayer_privilege()`, so a denial
  fails the connection with the privilege's own message rather than a generic error.
- **Communications** decides `enable_voice_chat` and `enable_text_chat` and whether a local chat
  control is created at all. Denied chat is *absent*, not just muted; gameplay transport may
  still work when multiplayer is allowed.
- A resolvable denial goes through `resolve_privilege_with_ui_async` and is re-checked once, so
  only a still-denied privilege reaches the player as a failure. A `banned` account is never sent
  to the resolution UI.

**Privilege checks fail open** when the GDK/user is unavailable **or the query fails**,
returning an unchecked verdict and warning on query failure. This is a sample limitation, not
a certification claim. Registered XBOX on PC can perform real checks; custom-ID cannot.
This lower-level privilege behavior does not bypass the separate account/save-readiness gate.
Answers are warmed after sign-in and cached, and
the cache is cleared on sign-out and on `user_changed` with a `privileges` change kind, because a
privilege can be resolved from the guide mid-session.
If a refreshed verdict revokes communications mid-session, the chat control is destroyed.
Restoring the privilege does not recreate it in the existing network: **leave and rejoin**
to establish chat again. The sample does not implement live network reconfiguration.

A stale privilege response is not an unchecked grant: host/join setup stays closed and retries
a current-generation check before proceeding. `PrivilegeService` owns its cache invalidation
generation, so abandoned query or system-remediation responses cannot repopulate cleared state.

### PrivacyService

`PrivacyService` owns the per-player half. `PlatformSession` initiates evaluation on roster
and relevant account-state changes. It batches
`communicate_using_voice` and `communicate_using_text` for the remote XUIDs through
`batch_check_permission_async`, then overlays the platform **mute list** and **avoid list**: an
avoided player loses voice and text; a muted player loses voice. `PlatformSession` pushes the
verdict into `ChatService`, which applies render-side audio/text mutes and relationship
permissions. Voice restrictions remove audio permissions; text eligibility independently adds
`CHAT_PERMISSION_RECEIVE_TEXT`. A voice-only mute must not become a text denial.

Outgoing typed messages are addressed to an explicit target list rather than broadcast, because
Party has no send-side text permission: `PartyChatPermissionOptions` is send/receive *audio* plus
`ReceiveText`. Excluding a restricted player from the target list is the sanctioned mechanism.
Removing a roster peer removes it from eligible text recipients immediately, even if Party
has not removed its chat control yet.
Inbound Party text is validated against the same per-peer **text** policy before `ChatService`
emits `text_received`. XBOX peers awaiting a verdict, missing an XUID or denied text are not
admitted for text. `PrivacyService` defaults missing/failed **text** permission answers to
`false`, but does not cache those failures as permanent denials; a later evaluation can obtain
a valid answer. The existing voice-query fallback is unchanged. Lower-level custom-ID
diagnostics allow text only for authenticated current-roster peers, not arbitrary Party senders;
they are not a gameplay path past save readiness.
`PrivacyService` likewise owns invalidation generations for permission and mute/avoid-list
queries; late responses cannot refill caches cleared for a different account/policy context.

The player's own per-player mute is separate: occupied lobby roster rows are focusable, and
activating one opens the **player actions** overlay: mute, report and view profile. A voice the
platform already silenced cannot be unmuted by the player, and the row says so. The two mute sources
are combined in one funnel, so lifting a restriction never unmutes someone the player muted.

The in-match display removes newly text-restricted senders' retained rows and never replays
discarded content after restoration. User/account-cache invalidation triggers text privacy
re-evaluation and clears retained text while verdicts are pending.
Identity/session changes invalidate asynchronous policy,
moderation and send results. The local microphone starts muted without preventing permitted
typed text. See [the text lifecycle](multiplayer.md#chat) and
[policy acceptance](walkthroughs.md#privileges-privacy-and-reporting).

---

## Moderation and reporting
Chat is the only content a player authors in this title, making it the whole UGC surface
(XR-018). `ModerationService` owns both halves.

### String verification

With an XBOX user and available GDK, `NetManager.send_chat_message()` runs text through
`Services.verify_chat_text()` → `ModerationService.verify()` →
`gdk.string_verify.verify_string_async()` *before* handing it to Party; a message the service
refuses never becomes a packet. The chat entry dialog stays open on a failed send with the text
intact; a refusal takes that path, with the reason shown in a dialog over the entry. The
offending substring the service returns is not echoed in the failure dialog.

**Verification fails closed**, unlike the privilege checks. A privilege query that cannot reach
the service should not stop a match from starting; publishing unverified user text is the violation
itself. A message that could not be checked is held back with "try again" rather than "that was
offensive". The title does not know that it was. With no GDK or no XBOX user there is nothing to
verify against and the check is skipped entirely at that service boundary. Custom-ID diagnostics
**cannot demonstrate string verification** or bypass gameplay readiness.
The received display uses Party `message.text`, not raw `original_text` or translations;
no speech/transcription path is enabled.

### Reporting

Reporting goes through `XboxSocial.submit_reputation_feedback_async`, from the player actions
overlay. The four reasons come from the feedback types the addon documents; an unknown type fails
the call. "View Profile" opens the system profile card, which is where XBOX itself offers blocking
and its own report flow. A match returns to the lobby when it ends, so reporting is reachable
right after the offense against the same roster.

> `XGameUiShowPlayerReportUI` is not bound by the addon, so the title owns the reason list.

---

## Achievements

The sample defines ten XBOX achievements, split between one-shot unlocks and incremental
progress, driven by counters the title keeps itself. These are XBOX service reports,
not PlayFab achievements.

`AchievementService` wraps a single call, `update_achievement_async(user, id, percent)`,
which maps to `XblAchievementsManagerUpdateAchievement`. Reporting `100` unlocks;
anything lower records progress the service retains. That is the whole API, and it is why
the title never has to ask the service what it already knows: it reports the current
position and lets the service keep the higher of the two.

| Id | Achievement | Rule |
|---|---|---|
| `1` | Shakedown Cruise | Finish your first match |
| `2` | Space Debris | Get destroyed for the first time |
| `3` | First Blood | Destroy your first enemy ship |
| `4` | Rumble Champion | Win a match |
| `5` | Untouchable | Win a match without being destroyed |
| `6` | Arms Dealer | Fire every weapon at least once *(incremental)* |
| `7` | Fully Buffed | Collect every buff at least once *(incremental)* |
| `8` | Rock Breaker | Destroy 250 asteroids *(incremental)* |
| `9` | Full House | Finish a match in every mode *(incremental)* |
| `10` | Centurion | Destroy 100 enemy ships *(incremental)* |

The ids are the `AchievementId` values in [`achievements2017.xml`](achievements2017.xml),
the config published for this title; the names and descriptions come from
[`localization.xml`](localization.xml). An id is the only thing tying a rule to the name
and gamerscore the service already published. Maintainer note: nothing here may be
renumbered alone.

### Why the counters are separate from the service

`AchievementTracker` holds the lifetime counters and the rules that turn them into a
percentage. It knows nothing about the GDK or the network; `Services` binds its state and
reports to the ready account. Practice can advance that account's counters with a usable
platform-managed offline store, but never unsigned or during failed save preparation.
Loaded counters replace memory rather than merging progress from another account or failed
session. Resynchronization reports only the current account's progress. Because the service
keeps the highest percentage it has seen, replaying a report that already landed changes nothing.

Two details are easy to get wrong when adapting this:

- **Progress is reported, not accumulated on the service.** The set achievements
  (`6`, `7`, `9`) are tracked as bitmasks over the `NRTypes` enums and converted to a
  percentage at report time, so adding a weapon or a mode moves the target with it rather
  than leaving the achievement reachable without the new entry.
- **Every player reports their own.** The counters describe the local player, on the
  machine that player is sitting at. The host does not, and must not, unlock
  achievements on a client's behalf.

Achievement ids must be published on the title before an unlock can succeed. The committed XML
documents the sample's definitions; it is not a live-service status check. Use the registered
sample in **XDKS.1** with an eligible account and observe progress in the XBOX achievement UI.
Already-earned achievements do not unlock again, and no in-game achievement browser is supplied.
Reporting failures log a warning; locally advanced counters do not prove a service award.
See [Configuration](configuration.md#configuration-checklist) and
[achievement walkthrough](walkthroughs.md#achievements).

---

## Game saves

**XBOX on PC and console use Xbox XGameSaveFiles through the existing GDK addon.**
`GameSaveService` is the title's single persistence service. Its asynchronous preparation calls
`GDK.game_save.get_folder_async(xbox_user)`, which wraps `XGameSaveFilesGetFolderWithUiAsync`.
The addon uses the XboxUser native handle and SCID from initialized `XboxServices.get_scid()`.
The completed XboxResult has dictionary data `{path: String}`, not a bare path string.
There is no PlayFab Game Saves onboarding requirement, save API call, fallback or migration.
PlayFab authentication and multiplayer remain separate existing requirements.
The title uses the files API only, never `XGameSaveInitializeProvider`.
Microsoft's [folder API remarks](https://learn.microsoft.com/gaming/gdk/docs/reference/system/xgamesavefiles/functions/xgamesavefilesgetfolderwithuiasync)
require reacquisition on resume and prohibit mixing XGameSaveFiles with XGameSave;
mixing providers fails with `E_GS_PROVIDER_MISMATCH`.

Readiness and every file operation bind to that signed-in XboxUser and account generation.
Custom-ID authentication without an XboxUser is insufficient; a PlayFab local-user handle
does not establish save ownership. Preparation is single-flight, including native returned
Signals, and rejects canceled or stale completions before publishing a folder.

On resume, `Services.invalidate_saves_for_resume()` invalidates the old binding and generation.
The acquire-user flow repeats folder synchronization and all three loads before republishing
readiness; the synchronized payloads are authoritative, not a merge with pre-suspend memory.
This also applies when resuming from a menu without a match. Failed synchronization offers
Retry/Back, never access through a cached pre-suspend folder.
Resume also releases obsolete save-error and Quit-dialog guards; their late answers cannot
save or shut down the new generation. After acquisition hands off, an abandoned match gets
one **Match Ended** notice unless an accepted invite has taken over the front end. Menu-only
resume has no match notice, and account loss cancels the departing account's notice.
The invite router likewise releases a join claim whose outcome dialog was replaced by resume,
without discarding a newer buffered invitation. An old outcome cannot release the new claim.

The folder holds **`profile.json`** for settings, **`history.json`** for the newest 50 completed
matches, and **`stats.json`** for lifetime achievement counters. Each has an **`.alt`** companion:
two current-format slots containing a sequence, serialized JSON payload and SHA-256 integrity
envelope. Writes update only the inactive slot and verify its bytes after closing/reopening.
Reads choose the newest intact slot, preserving the previous committed save across an incomplete
candidate write. This is write integrity, not backward compatibility or migration.

`Services` validates all three logical saves before publishing the account's state. Both slots
missing after successful folder initialization supply defaults/empty history/zero counters;
valid empty data is authoritative. A damaged candidate with an intact alternate is recoverable.
Initialization/folder failure, unreadable slots, no intact record or invalid current-schema shapes
instead produce a reason and **Retry / Back**, with no gameplay and no overwrite by defaults.
There is no legacy wrapper reader or shared-state merge.

Regular changes and synchronous lifecycle persistence use the same verified account folder.
An explicit save writes the relevant current payloads without dirty flags or unchanged-value
skipping. Suspend and normal shutdown attempt all three logical saves. Live audio/UI updates
do not decide whether a later save is needed.
Options **Back** always attempts its save while the account is current, but a failed write
does not trap the player in Options: the main-menu or pause-menu actions return, with an
explicit save-error dialog above them. Dismissing that dialog does not discard settings;
later explicit saves retry the retained values. Account/readiness guards still apply.
Write failures are visible and retain current values for same-owner retry; they must not damage a
previous valid file or be treated as saved. Account removal/Back invalidates pending loads;
late completions cannot publish state or restore a folder. Removal clears settings, history,
counters and report caches, ends the departing session and blocks new work. Deadline-bound
lifecycle handlers do not await UI or start new initialization; writes require still-valid access.
The platform manages cloud synchronization; the title does not issue an upload call.
Microsoft's [XGameSaveFiles overview](https://learn.microsoft.com/gaming/gdk/docs/features/common/game-save/xgamesavefiles)
requires provider acquisition at launch and resume and describes automatic upload attempts
after the game session ends. Completion of local writes is not an upload receipt or a promise
that another device can immediately load them. Observe same-device recovery and cloud roaming
separately. See [Game Saves debugging](https://learn.microsoft.com/gaming/gdk/docs/features/common/game-save/game-saves-debugging)
for SCID, sandbox and Partner Center Connected Storage prerequisites.

An ordinary Quit/window close that fails its final save offers Retry/Back before shutdown
begins. Forced platform deadlines remain separate. Process-termination tests do not establish
hard-power-loss or hardware disk-cache durability.

There are **no desktop or `--pf-user` save caches and no migration**. Historical
`settings.cfg`, `match_history.json`, `achievement_stats.json` and token variants outside the
selected folder are left untouched: no reads, imports, moves, copies or deletion. Settings
keep their current names and defaults, including music `0.25`; explicitly saved music `0.7`
remains `0.7`, with no value remapping or compatibility reader.

Practice still requires an identified account and ready saves. A platform-supported offline
folder can satisfy that requirement; a connectivity hint alone does not invalidate it.
Cold offline identity/store acquisition is not guaranteed. If either is unavailable, stay
at Retry/Back rather than playing without saves.

**Demonstrate in stages:** alternate A/B on a registered PC and verify each account's state,
then observe the same account on a second PC after synchronization. Repeat on console and
across supported PC/console configurations with the linked identity/title. These are expected
acceptance cases, not recorded passes. A file or same-device relaunch alone proves neither
isolation nor roaming. [Walkthrough](walkthroughs.md#game-saves-and-account-isolation).

---

<a id="controller-association"></a>

## Controller association and GameInput

NetRumble uses the GDK's GameInput device APIs, reached through the user and device calls, to
track which controllers belong to the signed-in user, and it raises an overlay when that
controller disconnects. `DeviceService` owns this. Full controller *association*, meaning routing
gameplay input only from the associated pad, is **not** implemented; the rest of this section
explains what is built and why the remainder was withdrawn.

**`DeviceService` exists and tracks association/detection; it does not filter input.**
`Services` starts it without a user for offline detection and reseeds it after XBOX sign-in.
`start(user)` reads `gdk.users.get_devices_for_user(user)` and subscribes to
`device_association_changed`; Godot's `Input.joy_connection_changed` supplies a fallback.
Once the platform has supplied associations, that account-scoped list wins over raw pad count.

`controller_lost` / `controller_bound` drive the persistent `ControllerDisconnectOverlay` in
`scripts\main.gd`. Loss shows a reconnect prompt; reconnection hides it automatically. The
simulation/session is not paused or torn down by this path. A keyboard-only desktop boot
does not spuriously report controller loss.

There is **no mapping from platform hex device ids to Godot `InputEvent.device` indices** and
no per-user input filter or sign-in-time controller picker wired here. Other connected devices
may still drive input. Detection is therefore partial controller-requirement coverage, not
proof of XR-112/XR-115 compliance. Do not infer exclusive controller ownership from the overlay.
