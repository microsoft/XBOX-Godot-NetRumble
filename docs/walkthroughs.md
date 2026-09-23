# Platform demonstration walkthroughs

These are **instructions and expected observations, not completed test results**. Record the
build/protocol, environment, actions, actual outcomes and skips in your run notes using the
[manual test plan](manual-test-plan.md#recording-a-run). Do not mark an unavailable account,
title, service, audio endpoint or console as a pass.

**Current limitation:** Coordinated live testing has demonstrated two-way typed text,
the four-message bound and clearing. The pinned addon's local chat-control destruction await does
not resolve, and forcing the process to exit has crashed the game. Leaving a match no longer waits
on that call — the chat control is retained for the signed-in player and reused — so leave/rejoin
works, but the
[underlying defect](manual-test-plan.md#known-cleanup-blocker) is unresolved pending
[microsoft/XBOX-Godot-Sample#169](https://github.com/microsoft/XBOX-Godot-Sample/issues/169),
and quitting straight after a voice match is untested. No native edit or fire-and-forget workaround is included. The steps below
are instructions, not a claim that the complete lifecycle or certification passed.

Start with the [registered-PC quickstart](../README.md#quickstart-registered-xbox-on-pc) and
[canonical capability matrix](../README.md#what-works-where). Keep the committed sample
identifiers unchanged. Sandbox changes, account/service provisioning and remote deployment
require authorization; none is implied by reading a walkthrough.

The source paths below are relative to the repository. **Sample wrappers** such as
`PartyService.host()` are distinct from the **addon APIs** they call.

## XBOX sign-in into PlayFab identity

**Prerequisites:** Built addons, registered PC package, authorized sample access, **XDKS.1**
and a corresponding XBOX test account signed in to the XBOX app. The console equivalent
requires its authorized devkit/account. Direct editor launch is not this path.

**Action:** Launch with `.\tools\deploy-pc.ps1 -Launch`. Follow the acquire-user stages until
the menu appears after save loading. On failure, read the stage/reason and choose Retry after
fixing setup, or Back to abandon acquisition. Neither Practice nor multiplayer bypasses saves.

**Source / addon API:** `scripts\ui\screens\acquire_user_screen.gd` calls `Services.sign_in()`.
`scripts\services\identity_service.gd` uses `gdk.users.get_primary_user()` or
`add_default_user_async()`, then **`PlayFab.users.sign_in_with_xuser_async(xbox_user)`**.
`PlayFab.accounts.set_display_name_async()` publishes the entity display name. `Services`
then prepares and validates the account's saves before publishing ready state, and warms
policy/device state.

**Observable outcome:** The stages distinguish XBOX acquisition, PlayFab authentication and
save loading; the menu shows the gamertag only after readiness. A successful host/join exercises that PlayFab
identity. A title/sandbox label alone is not proof of sign-in.

**Unavailable / failure:** Registration does not grant title access. Wrong sandbox, absent
launching user, missing addons or failed PlayFab authentication produces a reason on the acquire
screen. Under the simplified user model, do not expect the interactive-add fallback to supply
a second account. An initialization/read failure after authentication still blocks all
gameplay and must be retried; a displayed identity is not save-readiness evidence.

## Host and join by code

**Prerequisites:** Two distinct signed-in players on compatible builds using the same title,
network access, ready account saves and allowed multiplayer privilege. Use separate registered
machines/accounts. Custom-ID users without a signed-in XboxUser cannot pass readiness;
see [testing prerequisites](multiplayer.md#testing-two-players-on-one-pc).

**Action:** Host a match, read the five-character code and enter it through Join Match's code
entry on the other machine. Observe both rosters before readying both players. Repeat with a
wrong code and correct it in the still-open entry; cancel a pending attempt, then retry.

**Source / addon API:** `NetManager` resolves the multiplayer and communications checks.
The sample `PartyService.host()` calls `PlayFab.party.create_and_join_network_async()` then
`PlayFab.multiplayer.create_lobby_async()`. `PartyService.join()` calls
`PlayFab.multiplayer.find_lobbies_async()` **once**, `join_lobby_async()`, and then
`PlayFab.party.join_network_async()`. `ChatService.ensure_control()` precedes each network
create/join when allowed. The returned `PlayFabPartyPeer` becomes Godot's multiplayer peer.

**Observable outcome:** Both players share the code/roster and enter the same match when ready.
The Lobby's code/version/descriptor bridge discovery to Party; gameplay traffic then runs over
ordinary Godot RPCs. A solo lobby does not auto-start.

**Unavailable / failure:** Search may not yet see a new Lobby; correct or explicitly retry
the editable code rather than assume an automatic search loop. Code joins time out after
45 seconds — one budget covering both connection and the host's admission, not a fresh clock
after the transport attaches. Version mismatch is rejected at Lobby attachment; full/ended
sessions also refuse, and a match that has started has its lobby membership locked, so the
lobby admits no new members and the code no longer gets anyone in. A join reports success only
after the host's `_accept_join`, so a refusal can never open an empty lobby. Canceling a join
the host had already admitted does not mean the host never saw the joiner — it did, briefly,
and the cancellation's teardown is what removes them again. A canceled or timed-out join
carries its own outcome on its `JoinRequest`, so it cannot complete later into a different
session, and a join replaced by an accepted invite reports nothing at all.

## Friends and cold-launch invites

**Prerequisites:** Two authorized XBOX identities with the appropriate friend relationship,
registered PC/console packages in the same sandbox/title, and a host waiting in the lobby.
XBOX activity must actually publish; custom-ID is not coverage.

**Action:** First join through **Join Friend** on the main menu. Leave, then use an empty host
lobby slot's **Invite To Game** action. Accept through the XBOX shell while the recipient title
is closed; complete sign-in after cold launch. Separately accept while already in a session
and exercise the leave-current-match confirmation.

**Source / addon API:** `Services.joinable_friends()` combines `SocialService.friends()`
(`gdk.social.get_friends_async()`) with `ActivityService.joinable_activities()`
(`gdk.multiplayer_activity.get_activities_async()`). `PlatformSession.publish_activity()` uses
`ActivityService.set_activity()` and `gdk.multiplayer_activity.set_activity_async()`;
`show_invite_ui_async()` opens the system invite picker.
`ActivityService` normalizes `gdk.activation` events, reading the Lobby connection string from
the raw activation URI, and `InviteRouter` buffers them until
account identity, saves and the front end are ready. `NetManager.join_by_invite()` calls the sample
`PartyService.join_by_connection_string()`; addon `join_lobby_async()` still runs before
`PlayFab.party.join_network_async()`, but code search is skipped.

**Observable outcome:** The friend's activity yields a joinable row; a cold activation survives
the acquire-user flow and reaches that lobby, without asking for a code. During actual play,
`PlatformSession` reports encounters via `update_recent_players()` /
`flush_recent_players_async()` and updates XBOX presence. Normal leave retires the activity.
Suspend retains an owner-bound retirement without starting SDK work; resume sends the delete
through the same serialized writer. Normal Quit waits for retirement within its existing
shutdown deadline, even after gameplay readiness is revoked. Failed or unavailable deletion
is not recorded as success. See Microsoft's
[multiplayer activities guidance](https://learn.microsoft.com/gaming/gdk/docs/services/multiplayer/mpa/concepts/live-mpa-activities).

**Unavailable / failure:** Missing activity/relationships, a full or ended lobby, privilege
denial or incompatible builds can refuse the join. A match that has started locks its lobby
membership and every member retires its activity, so the joinable row disappears rather than
offering a Join that would be refused; a cached activity or invite still reaches the host's
door, which refuses it. Pending requests expire after five minutes;
Back abandons acquisition without joining, and failed save loading offers Retry/Back rather
than bypassing readiness. Resume revokes an orphaned outcome-dialog join claim but preserves
newer buffered invitations for the next ready acquisition handoff. Record whether a real cold activation arrived, not merely
whether a warm code join worked.

## Two-way voice and typed text

**Prerequisites:** Two permitted online peers, distinct microphone/headset endpoints and an
active Party connection. Use registered XBOX identities with ready saves;
custom-ID diagnostics cannot enter these gameplay flows. Check actual audio routing and avoid acoustic
feedback between nearby devices.

**Action:** In the lobby, microphones start **muted**. Use `T` / gamepad Y to unmute and exchange
different spoken phrases in both directions; remute and confirm audio stops. Ready into a match.
While microphones remain muted, use the same action to open typed-text entry and send a message
from each peer. Exchange five distinguishable messages, including literal markup-like text,
then leave and enter a new match.

**Source / addon API:** `scripts\services\chat_service.gd` wraps
`PlayFab.party.chat.create_local_chat_control_async()`, `set_chat_permissions_async()`,
audio/text mute APIs and `send_text_async(text, targets)`. It subscribes to
`text_message_received(entity_key, message)` and emits sample `text_received` after validation.
`NetManager.send_chat_message()` moderates via `Services.verify_chat_text()` and
`gdk.string_verify.verify_string_async()` before submission. `NetManager.chat_message_received`
maps the authenticated sender to the roster using `PartyService.entity_key_for(peer_id)`,
not a replicated identity fallback; `gameplay_screen.gd` sends
`PlayerState.display_label()` and plain text to `NRChatLog`. `NRSystemKeyboard` uses
`gdk.game_ui.show_text_entry_async()` on console.

**Observable outcome:** Real speech is audible in both directions when allowed/unmuted; icons
alone are insufficient. Text works with microphones muted because
`CHAT_PERMISSION_RECEIVE_TEXT` is independent of voice. Each successful send adds **one**
local echo and a remote row. Echo confirms SDK submission, not remote delivery. After the
fifth message, only messages two through five remain, in order. A new match starts empty.

**Unavailable / failure:** Communications denial creates no chat control. Missing recipients,
failed moderation/SDK send or session changes show a reason and retain the entry text, without
a successful echo. The 100-character boundary applies to send/receive; text renders literally,
never as markup. There is no lobby text history, scrollback, persistence, talking indicator,
speech-to-text, text-to-speech, transcription or translation. `message.text` is displayed,
never raw `original_text` or translations. See [full chat acceptance](manual-test-plan.md#typed-text-acceptance).

## Privileges, privacy and reporting

**Prerequisites:** Authorized registered XBOX accounts with known multiplayer/communications
privileges and reproducible **separate text and voice** privacy verdicts. Use accounts/settings
you are permitted to manage. If the available account controls cannot produce a case, record
it as untested; do not substitute a custom-ID result.

**Action:** Attempt host/code join/invite join with multiplayer denied; exercise resolvable
denial where available. Join with multiplayer allowed but communications denied. With permitted
peers, compare text-denied/voice-allowed against voice-denied/text-allowed. Use the lobby's player
actions to mute, unmute, report or view a profile. Change authorized policy and trigger its
account-state refresh/rejoin path; observe retained-row removal when text is revoked.
Separately revoke communications privilege during a session, then restore it and leave/rejoin.

**Source / addon API:** `PrivilegeService.ensure()` wraps
`gdk.users.check_privilege_async()` and `resolve_privilege_with_ui_async()`.
`PlatformSession.apply_chat_privilege()` gates control creation.
`apply_chat_restrictions()` invokes `PrivacyService.evaluate()` through
`gdk.privacy.batch_check_permission_async()` plus mute/avoid lists.
`ChatService` applies independent permissions and explicit send targets, then checks again at
receive time. `ModerationService.report()` uses `gdk.social.submit_reputation_feedback_async()`;
`show_profile_card()` uses `gdk.game_ui.show_player_profile_card_async()`.

**Observable outcome:** Known multiplayer denial prevents all join entry points; communication
denial does not falsely offer working chat. Voice mute does not deny typed text. Pending/unknown
XBOX text policy admits no row; newly denied senders lose retained rows without later replay.
Account-cache invalidation clears retained text while privacy is re-evaluated. Mid-session
communications revocation destroys the control; restoration alone does not restore chat until
the player leaves/rejoins.
A refused outgoing string stays in entry with a reason. A successful report means the service
accepted feedback, not that a moderation action occurred.

**Unavailable / failure:** Privilege-query failure currently fails open; missing/failed XBOX text
privacy answers fail closed without caching query failures as permanent denials; existing
voice fallback is unchanged. XBOX string verification
failure with an available user/service blocks publication. Lower-level custom-ID diagnostics
skip those XBOX checks, but cannot bypass the title's account/save gate.
Policy is refreshed through roster/account events, not a claimed continuous privacy feed.
No live network reconfiguration is supplied for restored communications privilege.
Gamercards/reporting are available from the lobby, not every name-bearing surface; see
[XBOX Requirements](xr-compliance.md).

## Achievements

**Prerequisites:** Registered XBOX on PC or console, sample title/sandbox access, and an
account with an observable unearned achievement or incremental progress below completion.
Do not change achievement ids or reset live account state merely to manufacture a result.

**Action:** Finish a match, be destroyed, or earn another
[documented gameplay condition](platform-services.md#achievements). Observe the appropriate
XBOX achievement/progress UI. Repeat a condition already earned and compare behavior.

**Source / addon API:** Gameplay feeds `AchievementTracker`; `Services._on_achievement_progress()`
calls `AchievementService.update_progress()` and
`gdk.achievements.update_achievement_async(user, id, percent)`. Each peer reports its own
local player. Account loading replaces counters with that account's saved state before
resynchronizing reports; it never merges unsigned or another account's progress.

**Observable outcome:** The platform records progress or an unlock for the correct local
account. Reporting 100 means unlock; lower percentages report incremental progress. Replaying
an already-earned condition does not create another unlock. The title has no achievement browser.

**Unavailable / failure:** Locally advanced counters are not XBOX awards. Missing/unpublished
ids, account/title access or service failures can prevent reporting; inspect warnings and record
the actual platform outcome. Committed XML definitions are not evidence of current service state.

<a id="console-game-save-and-account-isolation"></a>

## Game Saves and account isolation

**Prerequisites:** Registered PC or authorized console builds, linked XBOX accounts and working
Xbox XGameSaveFiles with the configured SCID. Use dedicated A/B accounts with known state; use a second PC/console for
roaming. Do not clear cloud saves or import old shared files to manufacture test state.

**Action:** Reproduce the reported PC case: launch as A, change an identifiable setting and
complete Practice matches. Close normally, switch the launching XBOX account to fresh B and
relaunch the same registered package. B must show **`No match history yet.`**, default settings
and zero counters. Complete a match as B and alternate A/B relaunches, preserving each account's
own saves. Repeat with nonempty B saves. New music defaults to `0.25`; explicitly save `0.7`
and confirm it remains `0.7`.

Close and allow synchronization, then launch on a **second PC with the same account** and
observe settings/history/counters. Repeat the isolation, failure and roaming cases on console,
and verify supported PC/console roaming in both directions with the configured linked
identity/title. Record sync prompts/errors rather than assuming completion.

**Source / addon API:** `Services` coordinates owner-bound preparation and loading through
the title's single `GameSaveService`, using `GDK.game_save.get_folder_async(xbox_user)` /
native `XGameSaveFilesGetFolderWithUiAsync`. One asynchronous operation performs initial
synchronization/system UI and returns dictionary data `{path: String}` on both platforms.
The XboxUser and generation own the binding; the initialized Xbox services supply the SCID.
`profile.json`,
`history.json` (newest 50 rows) and `stats.json` are read/validated before ready state is
published, then written only for their current owner. Synchronous lifecycle writes do not
start initialization or issue upload calls. Resume invalidates the old provider binding and
repeats synchronization plus all three loads before allowing gameplay.

**Observable outcome:** A/B never inherit each other's state or achievement reports; returning
to A recovers A's own Game Saves. Confirmed missing files and valid empty history replace memory
with defaults/empty state. Only observing synchronized state on another device demonstrates
roaming. These steps specify expectations, not a live parity result; local writes are not
remote upload acknowledgments.

**Unavailable / failure:** Missing signed-in XboxUser/SCID, initialization/folder/read failures or
malformed payloads block all gameplay, including Practice, with Retry/Back and no default
overwrite. Retry after successful authentication must retry saves. Cancel/Back or account loss
during loading invalidates late completions. Write failures remain visible; current values stay
in memory for same-owner retry without damaging valid files. Explicit saves write their relevant
payloads regardless of whether values changed. There is no desktop/token cache, shared-file
import, legacy wrapper reader, migration or music remap; historical files are never read,
modified, moved or deleted.

An identified account with a ready platform-managed offline folder may play Practice.
Cold offline identity/store resolution is not guaranteed. Missing devices/service access block
parity/roaming evidence; mark them accordingly. Use the
[full acceptance matrix](manual-test-plan.md#account-owned-saves-pc-and-console) for failed and
stale loads, write retry, 50-row retention and no-migration fixtures.

## Lifecycle, connectivity and controllers

**Prerequisites:** Registered PC for focus/desktop behavior; authorized console tooling for
**actual suspend/resume**, a controller for disconnect detection and a second peer for
session-loss observation. Only alter network conditions on authorized test devices.

**Action:** Open/close Guide (or alt-tab on desktop) and observe constrain/unconstrain.
Separately invoke a real platform suspend, verify the suspend notification, then resume or
relaunch as the platform permits. Exercise host departure and sustained connectivity loss.
Disconnect/reconnect the associated controller; separately exercise signed-in-user removal.

For the termination case, change a setting without leaving Options or earn in-match counters,
then use **Guide -> Quit**. Observe **Constrain -> Suspend -> Terminate**, with saving on
Suspend, and relaunch as the same account on the same console. Record the suspend save
outcomes before interpreting a later cross-device result as a cloud synchronization issue.
See the [suspend-save matrix](manual-test-plan.md#xbox-guide-quit-and-suspend-saves).

**Source / addon API:** `scripts\main.gd` receives Godot notifications from the console
display server. Suspend calls `Services.persist_for_suspend()` then
`NetManager.abandon_for_suspend()` synchronously. Connectivity comes from
`gdk.networking.connectivity_hint_changed`; `DeviceService` reads
`gdk.users.get_devices_for_user()` / `device_association_changed` and Godot joypad events.
`gdk.users.user_changed` drives synchronous `Services.persist_user_state()` on removal.

**Observable outcome:** Constrain mutes game audio and freezes the local director without a
global pause RPC. Actual suspend commits state, abandons the session and clears chat; resume
reacquires the Xbox save provider and reloads through the acquire-user screen, not into a resumed match. Host loss ends
clients' sessions. An offline hint sustained beyond eight seconds ends online play; Practice
remains available only with the identified account's ready, usable store. Controller loss
shows a reconnect overlay without pausing the match; reconnection hides it. User removal
invalidates pending account operations, clears all account/chat state and ends the departing
session. A surviving process reacquires an account before allowing more gameplay.

**Unavailable / failure:** Guide/focus alone is not suspend coverage; game-audio mute is not
Party microphone mute. Connectivity hints are not endpoint reachability tests. Detection does
not filter Godot input to one account's controller. The platform may terminate instead of
resume; record that outcome and check persistence on relaunch, rather than claiming resume
passed. See [lifecycle contract](architecture.md#process-lifecycle).
