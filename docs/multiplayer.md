# Multiplayer with PlayFab Lobby and Party

> **This page is for Godot developers learning how NetRumble uses Lobby, Party and XBOX
> activity.** You can skip maintainer notes marked as editing instructions unless you are
> changing that code path.

**PlayFab Lobby** discovers sessions and carries the Party descriptor. **PlayFab Party**
authenticates peers and carries Godot gameplay traffic plus its separate voice/text channel.
**XBOX multiplayer activity** makes that Lobby session discoverable through friends and invites.
This sample does not use the PlayFab Matchmaking queue/ticket product.

See also: [Architecture](architecture.md) · [Platform Services](platform-services.md) ·
[Configuration](configuration.md) · [Walkthroughs](walkthroughs.md).
The [README matrix](../README.md#what-works-where) defines environment coverage.

---

## Connection flows

`Services` owns `PartyService` and `ChatService`. `NetManager` obtains them through
`Services.party()` / `Services.chat()`, resolves multiplayer/communication privileges, then
attaches the returned `PlayFabPartyPeer` to Godot's `MultiplayerAPI`.

### Host

1. `NetManager` calls `_require_multiplayer_privilege()`. See
   [Privileges](platform-services.md#privileges-and-player-communication).
2. The **sample wrapper** `PartyService.host()` initializes Party and PlayFab Multiplayer,
   leaves any previous network, and generates a five-character code.
3. `ChatService.ensure_control()` calls `PlayFab.party.chat.create_local_chat_control_async()`
   **before** the network call, when communications are allowed.
4. `PlayFab.party.create_and_join_network_async(user, config)` creates the network; the code
   is its invitation id. The wrapper waits for the descriptor, then calls
   `PlayFab.multiplayer.create_lobby_async()`: `string_key1` is the code, `string_key2` the
   game mode, `string_key3` the protocol version, and `party_descriptor` a member-visible property.
5. `NetManager` attaches the peer; `PlatformSession` advertises the Lobby connection string
   through XBOX activity so **Join Friend** can find it.
6. The host waits in the lobby. When all members are ready, the sample starts the match
   automatically (a solo lobby is guarded against immediate start).

### Join by lobby code

1. `NetManager` calls `_require_multiplayer_privilege()`.
2. The **sample wrapper** `PartyService.join()` normalizes the code.
   `_find_lobby_connection_string()` makes **one** `PlayFab.multiplayer.find_lobbies_async()`
   lookup for `string_key1`. Search is eventually consistent and rate-limited; a miss returns
   to the still-editable code entry so the player can correct it or retry. No automatic backoff loop runs.
3. `PlayFab.multiplayer.join_lobby_async()` attaches the Lobby. The wrapper checks its protocol
   version before reading `party_descriptor` and joining Party.
4. After ensuring a local chat control, `PlayFab.party.join_network_async()` uses that descriptor
   and the same code as invitation id. `NetManager` attaches the peer and exchanges the roster.
5. The client reaches the lobby. A code-join attempt has a **45-second overall timeout**
   (`NRConst.JOIN_CODE_TIMEOUT_SECONDS`); descriptor waits are independently bounded at 20 seconds.
   Cancel/timeout invalidates pending work so a late SDK result cannot seat a canceled join.

### Join by friend / invite

1. `Services.joinable_friends()` combines the XBOX social graph with multiplayer activities.
   The selected activity carries a **Lobby connection string**, not a Party descriptor.
2. `NetManager.join_by_invite()` calls the sample `PartyService.join_by_connection_string()`.
   It skips code **search**, not Lobby join: `PlayFab.multiplayer.join_lobby_async()` still
   validates the session/version and supplies the code/descriptor for `PlayFab.party.join_network_async()`.
3. For shell activations, `ActivityService` normalizes accepted invites, pending invites and
   protocol URIs into a request. `InviteRouter` buffers it until sign-in and the acquire screen
   have completed; if it contains a host XUID, XBOX activity resolves that to a connection string.
4. A cold-launch request expires after five minutes. Continue Offline declines it. An invite
   received while already playing asks before leaving the current session.

Join Friend and shell invites require a registered XBOX session. Custom-ID has no XBOX friends
or activity; the UI explains that unavailability. An ended/full/in-progress/incompatible session
can still refuse a valid-looking activation. See the [invite walkthrough](walkthroughs.md#friends-and-cold-launch-invites).

Both join paths reach the host through `_on_peer_connected()`, so both are refused the same
way if the match has already started — see [Closing a match to newcomers](#closing-a-match-to-newcomers). The
refusal arrives as an ordinary disconnect carrying `JOIN_REJECTED_IN_PROGRESS`, which the
pending join reports directly rather than opening an empty lobby.

### Leave and loss

`NetManager` first clears `_peer` and synchronously detaches Godot's multiplayer peer, without
calling `peer.close()`. `PartyService` alone releases the native session: clear the host's
advertised descriptor, leave Lobby/Party and detach listeners. The local chat control is
deliberately left alone — it belongs to the signed-in player rather than to the match, so it is
retained and reused by the next one; see [Chat](#chat).
Its serialized `leave()` lets overlapping exits/rejoins await the same teardown rather than
leave the native network twice. `PlatformSession` retires XBOX activity/presence.
The in-match chat display is invalidated immediately, without waiting for remote cleanup.
Host loss ends clients' sessions and returns them to the **main menu**; a completed match
returns to the lobby. Suspend abandons local state synchronously rather than awaiting these calls.
See [lifecycle](architecture.md#process-lifecycle) and [terminal loss](architecture.md#how-a-match-ends-badly).

**Known blocker:** [microsoft/XBOX-Godot-Sample#169](https://github.com/microsoft/XBOX-Godot-Sample/issues/169)
The pinned addon's `PlayFab.party.chat.destroy_local_chat_control_async()` await did not resolve
in the observed live run. That call is no longer on the leave path — the chat control is retained
across matches — so leaving and rejoining no longer waits on it, and a live leave/rejoin has since
completed. The addon defect itself is unfixed: the call still runs at title exit, where
`main.gd::_quit_now()` holds it inside the shutdown drain so it can delay an exit but not hang
one. Quitting immediately after a voice match has not been retested since that change, and no
native edit, fire-and-forget destruction or forced-exit workaround is included.

---

## PlayFabPartyPeer

`PlayFabPartyPeer` derives from `MultiplayerPeerExtension`, making it a drop-in Godot
`MultiplayerPeer`. Every `@rpc` in `net_manager.gd` is ordinary Godot RPC. Only the peer
*construction* is PlayFab-specific, and it lives entirely in
`scripts/services/party_service.gd`.

---

## PartyService details that are easy to get wrong

Two details in `PartyService` are easy to get wrong and produce errors that are not obviously
related to the mistake:

### The join code is the Party invitation id

`PartyNetwork::AuthenticateLocalUser` rejects any client whose invitation identifier differs from
the host's. Leaving `PlayFabPartyConfig.invitation_id` empty makes the addon generate an opaque
value that cannot be forwarded to joining clients.

The five-character join code is mutually known: the client types it, so it is minted *before*
the network is created and passed on both sides. Getting this wrong produces:

```
AuthenticateLocalUser: invalid argument specified
```

### `find_lobbies_async` resolves to `PlayFabLobbySearchResult`

`find_lobbies_async` does not resolve to an array. The summaries are on the result's `lobbies`
member. Treating `result.data` as an `Array` silently yields zero matches with no error.

---

## Voice chat
The lobby is voice-only and has no text history. Microphone icons report availability/mute state,
not proof of audible communication. Voice lives in
`scripts/services/chat_service.gd`, separate from the transport: `PartyService` enables
`enable_voice_chat` on the network config and owns when a chat control may exist, while
`ChatService` owns everything the control then does. See
[Privileges](platform-services.md#privileges-and-player-communication).

Maintainer note: two things are worth knowing before editing the voice path:

- **The local chat control must exist before the network join.** `create_local_chat_control_async`
  is decoupled from `create_and_join_network_async` / `join_network_async`, and a network join
  never creates one. `ChatService.ensure_control()` is therefore called from both the host and
  join paths *before* the network call. Creation is serialized with ordinary destruction and
  canceled-control cleanup: a replacement cannot be created until the previous control's
  destruction completes.
- **Talking indicators are not wired up.** `Available` and `Muted` reflect real state, but the
  defined `TALKING` indicator is not emitted by the sample. Demonstrate voice by hearing a
  distinct phrase in **both directions** on two audio endpoints, not by looking at icons.

The local microphone starts **muted** so enabling voice never opens a live mic unasked. In the
lobby, `T` (or gamepad Y) toggles it. Self-mute is implemented by dropping `SEND_AUDIO` from the
chat permissions of every remote entity.

---

## Chat

During a match, `open_voice_chat` (`T` / gamepad Y) opens the existing **typed-text entry**,
including the console system keyboard. The gameplay HUD has four recent messages, not a chat
window with scrollback. In the lobby, the same action still toggles the microphone.

```text
NRChatEntry → NetManager.send_chat_message → Services.verify_chat_text
            → ChatService.send_chat_text → PlayFab.party.chat.send_text_async
            → one local echo after successful SDK submission

PlayFab.party.chat.text_message_received(entity_key, message)
  → ChatService.text_received: text policy, length and lifecycle validation
  → NetManager.chat_message_received: authenticated Party sender → current roster peer
  → gameplay screen → NRChatLog: sender label + plain text
```

Outgoing moderation uses XBOX string verification when an XBOX user/service is available;
custom-ID bypasses that check. `last_chat_error` explains unavailable chat, no eligible
recipients, moderation refusal, changed sessions or failed Party submission. Failed sends keep
the entry text and show the error; they do not add a successful local row.

`CHAT_PERMISSION_RECEIVE_TEXT` is granted **independently** of voice permissions. A muted
microphone or voice-only player/platform mute does not deny typed text. XBOX text policy must
resolve before new text is admitted; missing, failed or denied text verdicts exclude send targets
and suppress received messages. Missing/failed query results are not cached as permanent
denials; a later evaluation can obtain a real verdict. The voice-query fallback is unchanged.
Account-cache invalidation clears retained text while policy is re-evaluated. Roster removal
immediately removes that peer from eligible recipients, even if its Party chat control remains.
An empty target list fails explicitly because the addon treats an empty array as broadcast.
Debug custom-ID permits only recognized current-session peers without claiming XBOX policy coverage.

Only `message.text` from a valid typed-text event is shown: never `original_text`, translations,
transcriptions or sender-supplied markup/identity metadata. The sender is matched to the current
roster through `PartyService.entity_key_for(peer_id)`, not `PlatformSession`'s replicated
identity fallback. Labels use `PlayerState.display_label()` and its verified-name path.
Unknown, stale or restricted senders are not displayed.

The entry and service boundaries enforce **100 characters**. `NRChatLog` retains at most
**four** messages in order, dropping the oldest on a fifth. Each is rendered by an ordinary
`Label` (no BBCode), with wrapping and a bounded row height. The panel is passive and does not
take gameplay focus. Match exit, identity invalidation, session loss and suspend clear
it; newly restricted/departed senders' rows are removed. The next match starts empty, with no
lobby backlog, disk/cloud persistence or replay after permission restoration.
`begin_match_chat()` / `end_match_chat()` only manage this transient UI context, not transport.
If communications privilege is revoked mid-session, the chat control is destroyed. Restoring
that privilege requires leaving/rejoining to recreate the control; there is no live network
reconfiguration.

One local echo means **Party accepted the submission**, not that another player received or
read it. Chat has no gameplay RPCs and changes no wire protocol. Speech-to-text, text-to-speech,
transcription and translation are not demonstrated; their flags remain off. Receiving typed
text requires ReceiveText permission, **not** enabling transcription.

See [communication walkthroughs](walkthroughs.md#two-way-voice-and-typed-text) and
[chat acceptance](manual-test-plan.md#typed-text-acceptance).

## Admission: how a match closes and how a join succeeds

### Closing a match to newcomers

`PLAYERS_JOINING` covers both the lobby and scene loading, so `NetManager._accepting_joins`
separately tracks admission. Two mechanisms enforce it, and both are needed:

**The lobby's membership lock** stops a latecomer being admitted to the session.
`LobbyScreen._try_auto_start()` awaits `NetManager.close_joins()` before it broadcasts
`STARTING`, which calls `PartyService.set_lobby_locked(true)` →
`PlayFabLobby.set_membership_lock_async()`. The lobby is **locked, not deleted**: it keeps its
join code, its connection string — the one every published activity and sent invite carries —
its existing members and the Party descriptor the running match is reachable through. A locked
lobby refuses new *members*; it does not necessarily vanish from discovery, which is why the
host's door below is not redundant. Locking fails closed: an unconfirmed lock does not start
the match, and the lobby offers Try Again or Stay In Lobby rather than starting one it is still
advertising.

**The host's door** covers a join already in flight when the lock landed.
`_on_peer_connected()` checks `_accepting_joins`, and `_submit_player_identity()` checks again
after the asynchronous handshake. `_reject_join` supplies a readable reason. The roster,
readiness and loading barrier can then assume members were admitted before start.

The host reopens the match from `LobbyScreen._ready()` when it returns to the waiting lobby —
not when the match ends. Players read the results screen at their own pace, and a lobby that
reopened at the final whistle would take newcomers while everyone else was still looking at
final scores. `_apply_match_reset()` also un-readies every human player, and readying up is a
lobby shortcut, so the next round cannot begin until every current player is back and ready.
An unlock that fails leaves the match closed with Try Again or Leave Match.

Every one of those transactions is bound to a session identity. `NetManager.session_id()`
returns a number that no later session reuses; the lobby captures it before each service call
and each recovery dialog and re-checks it afterwards, because `has_session()` answers "is there
a session" and by then the useful question is "is this still *that* session". Retry after the
lock failed re-validates that the match is still startable — if the last other player left or
un-readied while the dialog was up, it reopens the lobby instead of retrying a start that would
do nothing and leave the host sealed into a solo lobby with no join code.

XBOX activity follows admission on every member, host and guest alike: `_receive_join_admission`
mirrors the host's gate onto each client, and `PlatformSession` retires or republishes its own
activity from it. A closed match therefore stops being offered in the guide and on friends'
profile cards, rather than offering a Join that ends in a refusal.

### Advertising is confirmed, not assumed

`PlatformSession` keeps three things apart: the state this session *wants* advertised
(`_activity_published`), what the service is *known* to hold (`_activity_remote`), and the fact
that a write can leave the answer genuinely **unknown**. `ActivityService.set_activity()` and
`delete_activity()` return one of `CONFIRMED`, `FAILED`, `UNAVAILABLE` or `INVALID`, because a
call that was never sent and one the service accepted are not the same result and a bool cannot
tell them apart.

Only `CONFIRMED` changes what the title believes is out there. A refused write leaves the state
unknown rather than assumed-clear, which is what makes a failed publish followed by a close
still send a delete — recording the failed publish as "nothing published" is exactly how a
started match stayed advertised.

Retries are bounded: one attempt and at most three more, at 1 s, 2 s and 4 s, and only for
writes the service actually refused. The budget belongs to a lifecycle episode — this session
opening, closing or ending, or a genuine account or connectivity recovery — and is deliberately
*not* restarted by roster refreshes, which arrive often enough to make a budget meaningless. On
exhaustion the unresolved state is kept and a warning names the operation and the attempt count;
there is no dialog, because the membership lock and the host's door are what actually keep an
unwanted joiner out. **Retirement is therefore not instantaneous.** While the service is
failing, a friend's guide can go on showing a session that has already started, and the join
they attempt from it is refused by the host rather than by the advertisement.

### How a join actually succeeds

A join reports success when the host sends `_accept_join`, not when the transport attaches.
Party connects a client to the mesh before the host has looked at it, and the host may still
turn it away — so a join resolved on the transport alone reported success for sessions the
player was never admitted to. The refusal then arrived while the loading screen was still up,
too late to change an answer already recorded, and the player landed in a lobby with no roster
and no join code.

`NetManager.join_by_code()` and `join_by_invite()` return a **`JoinRequest`** immediately,
before the attempt has done anything, and the caller awaits `request.wait()`. The handle is
returned early on purpose: the screen that owns the attempt needs to name *this* attempt while
it is still running — to bind its Cancel button to it, and to know afterwards that the answer
it is reading is its own. Shared flags on the autoload could not do that. An invite accepted
while a code join was still on the loading screen set the shared flag, and the code join's own
waiter read it and reported the replacement's outcome as its own.

Each request carries its own outcome — `SUCCEEDED`, `CANCELLED`, `SUPERSEDED` or `FAILED` — its
own reason, and the identity of the session it was admitted to. Code, friend-activity and
invite joins all go through one driver, so all three get the same 45-second budget spanning
both halves of joining, the same cancellation handling and the same admission handling.

Four things fall out of that:

- **Acceptance is provisional.** `_accept_join` records the admission; it does not emit success,
  publish an activity or open anything. The request's own poll consumes it a moment later, after
  checking that the player has not canceled in the meantime. A Cancel recorded before the
  acceptance is consumed therefore wins — the player asked to stop, and should not be seated
  because the answer overtook them.
- **Supersession is silent.** A replaced join shows no dialog, changes no screen and navigates
  nowhere; the join that replaced it owns all of that. From the player's side nothing failed.
- **Teardown happens once.** The replaced join and the replacement both wait on one
  single-flight cleanup, so the peer is never detached twice — the second detach would land on
  whatever session existed by then, which is the replacement's live one.
- **Success is checked against a session identity, not a peer.** Consumers call
  `NetManager.joined_session_is_live(request)`, which compares the session the request was
  admitted to against the one that exists now. Looking merely for *a* peer would happily accept
  the next session as this one.

A session lost while a join is pending is answered by that join rather than by a second
disconnect dialog. Owned UI cleanup goes with owned outcomes: join screens are removed by
instance through `ScreenManager.remove()` rather than by `pop()`, so a flow resuming from an
await takes down its own loading screen and not whichever one happens to be on top.

<a id="scope-and-non-goals"></a>

## What this sample does not do (and why)

The game is host-authoritative; Party supplies transport, not its simulation rules.
**No host migration:** losing the host ends the session. **No join-in-progress:** admission
closes when the lobby commits to starting. Low-latency setups best suit the demonstration;
fixed prediction/correction can rubber-band over higher-latency networks. These are **sample
gameplay limitations, not Party shortcomings**.

### The netcode model and where it runs out

Detailed interpolation, prediction and latency mechanics moved to the
[gameplay reference](gameplay-reference.md#netcode-model-and-latency-limits).
[Protocol](protocol.md) remains the maintainer reference for RPC routing and snapshot formats.

---

## Testing two players on one PC
GDK / XBOX sign-in is one user per PC and cannot produce two identities locally. For local
multiplayer testing the addons support a **custom-ID** path, exposed through two command-line
overrides (environment variables `PF_CUSTOM_ID` and `PF_TITLE_ID` also work):

```powershell
# terminal 1, host
godot.exe --path . -- --pf-user=alice --pf-title=<dev-title-id>
# terminal 2, client
godot.exe --path . -- --pf-user=bob   --pf-title=<dev-title-id>
```

Each `--pf-user` value signs in as a *distinct* PlayFab entity and gets its own
`user://settings_<token>.cfg`, `match_history_<token>.json` and `achievement_stats_<token>.json`.
These are plaintext desktop caches, not account-scoped Game Save. The menu
shows "(test user)" so a custom-ID session is never mistaken for a real one.

**Four caveats apply:**

1. **Debug-desktop only.** `IdentityService.developer_overrides_allowed()` ignores both overrides
   on a console build and in any exported release build. A shipping build can only reach PlayFab
   through the XBOX-linked path. A suppressed override logs a warning.

2. **Requires a title that permits custom-ID account creation.** The sample's production title
   (`1A9AB9`) does **not**. Custom-id login there returns
   `E_PF_PLAYER_CREATION_DISABLED` (`0x892357BA`). Use a development title for this flow.

3. **Party binds a UDP socket and by default pins a fixed port.** A second local instance would
   fail with *"failed to bind or connect the UDP socket because the address is already in local
   use."* `PartyService` therefore passes `local_udp_port = 0` (OS-assigned) to
   `initialize_async` **for custom-ID sessions only**; real sessions keep `-1` so Game Core's
   preferred multiplayer port applies. The PlayFab addon registers
   `playfab/party/local_udp_socket_bind_port` to override that port. This project leaves it at
   the addon default, so the setting is deliberately absent from `project.godot`.

4. **Party uses `direct_peer_connectivity = NONE`** so all traffic relays through PlayFab, which
   also helps two instances coexist on one host.

Custom-ID bypasses XBOX privileges, privacy and string verification; it provides no XBOX
achievement reporting, friends/invites or console save roaming. It can demonstrate Lobby/Party
and typed-text UI, not XBOX policy. Both instances must use the same development title and
compatible build. Follow the [Manual test plan](manual-test-plan.md); these instructions are not
evidence that a two-instance or live-service run has passed.
