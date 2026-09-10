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
the menu appears. On failure, read the reason, try again after fixing setup or choose
Continue Offline and start Practice.

**Source / addon API:** `scripts\ui\screens\acquire_user_screen.gd` calls `Services.sign_in()`.
`scripts\services\identity_service.gd` uses `gdk.users.get_primary_user()` or
`add_default_user_async()`, then **`PlayFab.users.sign_in_with_xuser_async(xbox_user)`**.
`PlayFab.accounts.set_display_name_async()` publishes the entity display name. `Services`
then loads applicable saves and warms policy/device state.

**Observable outcome:** The stages distinguish XBOX acquisition from PlayFab authentication;
the menu shows the gamertag. A successful host/join in the next lesson exercises that PlayFab
identity. A title/sandbox label alone is not proof of sign-in.

**Unavailable / failure:** Registration does not grant title access. Wrong sandbox, absent
launching user, missing addons or failed PlayFab authentication produces a reason on the acquire
screen. Under the simplified user model, do not expect the interactive-add fallback to supply
a second account. Continue Offline preserves Practice, not online access.

## Host and join by code

**Prerequisites:** Two distinct signed-in players on compatible builds using the same title,
network access and allowed multiplayer privilege. Registered XBOX players need separate
machines/accounts. Debug-only transport coverage may instead use two custom-ID tokens on a
separate development title; see [setup](multiplayer.md#testing-two-players-on-one-pc).

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
`ActivityService` normalizes `gdk.activation` events and `InviteRouter` buffers them until
identity and the front end are ready. `NetManager.join_by_invite()` calls the sample
`PartyService.join_by_connection_string()`; addon `join_lobby_async()` still runs before
`PlayFab.party.join_network_async()`, but code search is skipped.

**Observable outcome:** The friend's activity yields a joinable row; a cold activation survives
the acquire-user flow and reaches that lobby, without asking for a code. During actual play,
`PlatformSession` reports encounters via `update_recent_players()` /
`flush_recent_players_async()` and updates XBOX presence. Normal leave retires the activity.

**Unavailable / failure:** Missing activity/relationships, a full or ended lobby, privilege
denial or incompatible builds can refuse the join. A match that has started locks its lobby
membership and every member retires its activity, so the joinable row disappears rather than
offering a Join that would be refused; a cached activity or invite still reaches the host's
door, which refuses it. Pending requests expire after five minutes;
Continue Offline declines them. Record whether a real cold activation arrived, not merely
whether a warm code join worked.

## Two-way voice and typed text

**Prerequisites:** Two permitted online peers, distinct microphone/headset endpoints and an
active Party connection. Use registered XBOX identities for moderated/policy-aware coverage;
custom-ID only covers development transport/UI. Check actual audio routing and avoid acoustic
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
failure with an available user/service blocks publication. Custom-ID bypasses those XBOX checks.
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
local player. Sign-in merges persisted counters and calls `resync()`.

**Observable outcome:** The platform records progress or an unlock for the correct local
account. Reporting 100 means unlock; lower percentages report incremental progress. Replaying
an already-earned condition does not create another unlock. The title has no achievement browser.

**Unavailable / failure:** Offline/custom-ID counters are not XBOX awards. Missing/unpublished
ids, account/title access or service failures can prevent reporting; inspect warnings and record
the actual platform outcome. Committed XML definitions are not evidence of current service state.

## Console Game Save and account isolation

**Prerequisites:** Authorized console builds/accounts, working PlayFab Game Save and **two
consoles** for roaming. Same-console relaunch is only local persistence coverage. Desktop,
including registered XBOX on PC, uses local caches instead of this sample's console save path.

**Action:** On console A, sign in, change an identifiable setting and finish a match. Close
normally and allow synchronization to complete; relaunch to check same-console persistence.
Close again, then launch on console B with the **same account** and observe the setting/history.
Finally use a different authorized account and check isolation. Record sync prompts/errors.

**Source / addon API:** `Services.sign_in()` calls `GameSaveService.load*()`.
`PlayFab.game_saves.add_user_with_ui_async(user)` performs initial synchronization, and
`get_folder(user)` resolves the user folder. `profile.json`, `history.json` and `stats.json`
are written there using `FileAccess`; suspend/removal use cached-folder `write_now()`.
There is no explicit `upload_with_ui_async()` call on this path.

**Observable outcome:** Same-console persistence is visible first; **only observing the state
on console B proves roaming in this run**. A different account must not inherit A's settings,
history or counters. The platform handles synchronization after title close; a local write
does not acknowledge remote upload.

**Unavailable / failure:** No local user handle, unavailable folder, failed initial sync or a
write failure means there may be no durable save. Console does not fall back to account files
in `user://`; pre-sign-in/offline state is in memory. Missing console B blocks roaming evidence.
A desktop relaunch is never a substitute.

## Lifecycle, connectivity and controllers

**Prerequisites:** Registered PC for focus/desktop behavior; authorized console tooling for
**actual suspend/resume**, a controller for disconnect detection and a second peer for
session-loss observation. Only alter network conditions on authorized test devices.

**Action:** Open/close Guide (or alt-tab on desktop) and observe constrain/unconstrain.
Separately invoke a real platform suspend, verify the suspend notification, then resume or
relaunch as the platform permits. Exercise host departure and sustained connectivity loss.
Disconnect/reconnect the associated controller; separately exercise signed-in-user removal.

**Source / addon API:** `scripts\main.gd` receives Godot notifications from the console
display server. Suspend calls `Services.persist_for_suspend()` then
`NetManager.abandon_for_suspend()` synchronously. Connectivity comes from
`gdk.networking.connectivity_hint_changed`; `DeviceService` reads
`gdk.users.get_devices_for_user()` / `device_association_changed` and Godot joypad events.
`gdk.users.user_changed` drives synchronous `Services.persist_user_state()` on removal.

**Observable outcome:** Constrain mutes game audio and freezes the local director without a
global pause RPC. Actual suspend commits state, abandons the session and clears chat; resume
returns to the menu with a notice when applicable, not into a resumed match. Host loss ends
clients' sessions. An offline hint sustained beyond eight seconds ends online play; Practice
remains available. Controller loss shows a reconnect overlay without pausing the match;
reconnection hides it. User removal clears identity/chat/account caches.

**Unavailable / failure:** Guide/focus alone is not suspend coverage; game-audio mute is not
Party microphone mute. Connectivity hints are not endpoint reachability tests. Detection does
not filter Godot input to one account's controller. The platform may terminate instead of
resume; record that outcome and check persistence on relaunch, rather than claiming resume
passed. See [lifecycle contract](architecture.md#process-lifecycle).
