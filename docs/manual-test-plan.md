# Manual test plan

The primary acceptance path demonstrates GDK/PlayFab integration. Detailed gameplay checks
remain in [secondary gameplay regression](#secondary-gameplay-regression); they are not
prerequisites for reading the platform lessons, but still apply to gameplay/network changes.

The acceptance tables contain **expected outcomes, not recorded passes**. Use [Walkthroughs](walkthroughs.md)
for source/API entry points and [record every run](#recording-a-run). Static import success,
microphone icons, desktop caches and custom-ID sessions cannot substitute for live-service,
audio, roaming and XBOX policy observations.

## Known cleanup blocker

Coordinated live testing on **2026-09-08** reported five host sends with five local echoes;
the client received those five messages, submitted one reply with one local echo, and the host
received that reply. The four-message display bound and transient clearing were also observed.
This is positive evidence for the typed-text path, **not a full end-to-end pass**.

Coordinated title-side verification also reported **76 passing fake-SDK assertions**, covering
delayed ordinary destruction/recreation, stale privacy/list cache writes, invalidated/coalesced
host/setup privilege checks, current grants/denials and stale system remediation. A fresh full
Godot import/quit and convention/configuration checks passed. These results exercise title-side
contracts; they do not expand the live-service observations above.

**Leave and rejoin were blocked by
[microsoft/XBOX-Godot-Sample#169](https://github.com/microsoft/XBOX-Godot-Sample/issues/169)
and are no longer:** the pinned addon's `PlayFab.party.chat.destroy_local_chat_control_async()`
await did not resolve in the observed run, and forcing the process to exit crashed the game.
`PartyService.leave()` used to await that call, so a stalled leave stranded the following rejoin
on the joining screen and took Cancel with it. The title now retains the chat control across
matches — it belongs to the signed-in player, not to the match — and a live two-player
leave/rejoin has since completed normally.

The addon defect is unfixed and still tracked upstream; only the sample's dependence on it during
a leave has been removed. The call still runs at title exit, where it is held inside the existing
shutdown drain so it can delay an exit rather than hang one, and on chat-privilege withdrawal.
**Quitting immediately after a voice match has not been retested since that change**, so exit
behavior after voice remains unverified — do not record it as passed, and do not recommend forced
exit as a workaround. Native files and the pinned submodule remain unchanged; do not replace
awaited destruction with fire-and-forget. Local display clearing is still not evidence that native
cleanup finished. Record the exact build, environment and logs with any coordinated run. XBOX
identity/policy, moderation, console system keyboard, real microphone audio, invites and console
Game Save roaming remain unverified by these observations.

The lobby membership lock and host-admission handshake (cases 3.18–3.31) were added against
addon commit `5cc6310`, which resolves
[microsoft/XBOX-Godot-Sample#170](https://github.com/microsoft/XBOX-Godot-Sample/issues/170).
They are verified only by the Godot import/parse gate and code review so far; the live cases are
**not exercised**. Cases 3.24–3.31 cover races found in review rather than reported behavior.
Several need a failure induced deliberately — 3.26 and 3.27 need the membership lock to be
failed, and 3.29–3.31 need the XBOX activity service to be failed — which on this title means
stepping the relevant `await` in a debugger in an authorized development environment. **Do not
commit fault-injection hooks to make these reproducible**, and do not record an interleaving as
passing unless it was actually observed.

## Prerequisites

| Tier | Needs |
| --- | --- |
| 1: Local | Godot 4.6+ (baseline 4.6.2), built addons and imported resources. No service account needed for Practice. |
| 2: XBOX services | Registered launch, **XDKS.1**, authorized sample title/sandbox access and an XBOX test account signed in. |
| 3: Multiplayer | Two registered XBOX players on separate machines for full coverage; alternatively a separate **development PlayFab title** permitting custom-ID for transport/UI only. Two audio endpoints for voice. |
| 4: Console | Authorized devkit(s), a Middleware console fork and accounts; two consoles for save roaming. |

> **Tier 3 cannot use the title this sample ships with.** Custom-ID login against it returns
> `0x892357BA` (`E_PF_PLAYER_CREATION_DISABLED`), because custom-ID account creation is disabled
> there. Use a development title of your own for custom-ID, or two registered XBOX identities.
> Without either environment, multiplayer acceptance is blocked. Custom-ID alone cannot cover
> XBOX privilege/privacy, moderated strings, invites or achievements.

Do not change committed title/package ids. Obtain authorization before switching a machine-wide
sandbox, provisioning/changing accounts/services, deploying to a device or altering network state.
See [configuration](configuration.md) and the [capability matrix](../README.md#what-works-where).

## Static checks

The existing CI checks are pure-text rules plus a Godot import/parse job (currently advisory).
With addons already built, run in this order:

```powershell
.\tools\check-deport.ps1 -Detailed
.\tools\check-game-config.ps1
godot.exe --headless --path . --import
godot.exe --headless --path . --quit
```

Check both Godot exit codes **and both outputs** for `SCRIPT ERROR`, `Parse Error`,
`Failed to load script` and `Cannot open file`. A zero exit code alone is not a pass.
Import must precede `--quit` on a fresh checkout. These checks do not exercise services.

---

## Tier 1: Local, no platform services

After addon setup/import, run the separate editor/debug path and choose Continue Offline.
This is not registered XBOX on PC acceptance.

```powershell
godot.exe --path .
```

| # | Check | Expected |
| --- | --- | --- |
| 1.1 | Launch to first screen with sign-in unavailable | Acquire-user screen shows the failed stage/reason and offers Continue Offline |
| 1.2 | Continue offline → main menu | Menu renders on the starfield; no error spam in Output |
| 1.3 | Start a practice match | World spawns: barrier, asteroids, your ship |
| 1.4 | Request typed text in Practice | Unavailable action explains that chat needs an online match; no successful echo |
| 1.5 | Change options, reopen, then desktop relaunch | Local settings persist; no cloud-roaming claim |
| 1.6 | Match History before/after completion | Empty note before history exists; completed match adds a row |
| 1.7 | Gamepad-only menu/options navigation | Focus remains visible, scroll follows focus, focus restores on closing overlays |
| 1.8 | Alt-tab away/back during Practice | Game audio mutes/restores and local simulation/clock pauses/resumes; not suspend |
| 1.9 | Pause menu → leave → quit | No orphaned world or hanging process |

**Output panel must be clean** of `SCRIPT ERROR`, `Parse Error` and unexpected `push_error`.
Warnings for unavailable live services can be expected here; missing bootstrap scripts or
unimported resources are setup failures, not successful offline coverage.

## Tier 2: Identity and single-player services

Needs a registered build and a signed-in XBOX user.

```powershell
.\tools\deploy-pc.ps1 -Launch
```

| # | Check | Expected |
| --- | --- | --- |
| 2.1 | Sign-in completes on launch | Gamertag shown; stage text advances rather than stalling |
| 2.2 | Fail/decline sign-in, then choose Continue Offline | Practice reachable by explicit choice; later Sign In reopens the acquire screen |
| 2.3 | Play a match to completion | Match history gains a row |
| 2.4 | Earn an unearned achievement / incremental condition | Correct account's XBOX progress changes when service accepts it; an already-earned award does not unlock again |
| 2.5 | Desktop relaunch | Settings, history and counters survive through local caches, not console Game Save |
| 2.6 | Quit during sign-in | Exits within the shutdown drain window instead of hanging |
| 2.7 | Known multiplayer denial, including an invite path | All entry paths refuse with a reason; resolvable denial uses system UI and re-checks |
| 2.8 | Multiplayer allowed, communications denied | Session works without a local chat control; voice/text unavailable, not falsely successful |
| 2.9 | Observe sign-in/config labels | Distinguish GDK initialization/registration from XBOX acquisition and PlayFab authentication |

Achievement/reporting observations need real XBOX service results. Cached counters and a visible
gamertag are not substitutes. The current privilege-query fail-open behavior is a documented
limitation; record failures rather than treating an unchecked verdict as demonstrated policy.

## Tier 3: Multiplayer

The regression gate for anything touching `net_manager.gd`, `platform_session.gd`, `world.gd`,
`world_network_sync.gd`, `party_service.gd`, `chat_service.gd` or `match_director.gd`.

Prefer two registered builds/accounts for end-to-end XBOX coverage. The alternative below uses
debug desktop custom-ID and covers only Lobby/Party/UI:

```powershell
# terminal 1, host
godot.exe --path . -- --pf-user=alice --pf-title=<dev-title-id>
# terminal 2, client
godot.exe --path . -- --pf-user=bob   --pf-title=<dev-title-id>
```

| # | Check | Expected |
| --- | --- | --- |
| 3.1 | Both players sign in distinctly | XBOX accounts on registered builds, or distinct names marked "(test user)" on custom-ID |
| 3.2 | Host Match → lobby | Five-character join code displayed |
| 3.3 | Client: Join → Lobby Code → type the code | Client lands in the host's lobby |
| 3.4 | Roster on both sides | Both players listed, correct names, no flicker on updates |
| 3.5 | Change ship/color; join/leave roster rows | Changes replicate without losing focus |
| 3.6 | Both ready up | Match starts automatically; a solo lobby does **not** start |
| 3.7 | Move/fire/score from both sides | Gameplay RPCs visibly work; run the secondary regression table for gameplay/network changes |
| 3.8 | Match end and next match | Both return to lobby; next match has no old text |
| 3.9 | Client closes mid-match | Host removes it and continues; departed sender's retained rows disappear |
| 3.10 | Host closes mid-match | Client sees a reason and returns to main menu, not a dead match |
| 3.11 | Cancel join, retry, and allow an attempt to time out | Code remains editable after failure; no delayed join after abandonment; code timeout is 45 seconds |
| 3.12 | Wrong/newly-created code | One search, then success or readable failure with explicit editable retry; no automatic backoff |
| 3.13 | Try joining after start or with incompatible protocol | Readable refusal; existing match/roster remains valid; the refused client never sees the lobby, empty or otherwise |
| 3.14 | Join Friend and accepted invite while warm/cold | Registered XBOX path reaches lobby; cold activation survives acquire-user, Continue Offline declines it |
| 3.15 | Lobby voice, then in-match typed text | Hear real speech both directions; complete typed-text acceptance below |
| 3.16 | Constrain/alt-tab host and client separately | Local director pauses without a global pause RPC; constrained host stops advancing authoritative simulation |
| 3.17 | Repeated host/join/leave | No duplicate text handlers/echoes, stale activity, prior-match rows or retained controls |
| 3.18 | Both ready up, then watch the host's lobby | Status reads "Closing the match to new players…" before the match starts; the join code and Invite slots disappear |
| 3.19 | Third client types the host's code while the match is running | Refused at the **lobby** (locked membership) rather than by the host, and refused again if it reaches the host; failure dialog names a reason and the code stays editable |
| 3.20 | Match ends; client dismisses results, host does not | Client waits in the lobby un-readied; the match stays closed and the join code stays hidden until the host also returns |
| 3.21 | Host dismisses results | Status reads "Reopening the match to new players…", then the **same** join code reappears and Invite slots come back |
| 3.22 | Third client joins the reopened lobby, then all ready up | Join succeeds with a full roster; the next match does not start until every current player has returned and readied |
| 3.23 | Host leaves while a client is still reading results | Client returns to the **main menu** with a reason, never to a dead lobby |
| 3.24 | Cancel the joining screen at the moment the host admits the joiner | Returns to the main menu with no failure dialog; the joiner is not seated, and the host's roster does not keep them |
| 3.25 | Accept an XBOX invite while a code join is still on the joining screen | The replaced join reports nothing at all — no dialog, no screen change; the invited session opens normally and is still live 45 s later |
| 3.26 | Force the membership lock to fail, then have the only other player leave before choosing Try Again | The lobby reopens instead of sitting closed; the join code and Invite slots come back |
| 3.27 | Force the membership lock to fail, then have the host lose the session while the "Could Not Start Match" dialog is up | The host leaves by the disconnect route only; neither Try Again nor Stay In Lobby acts on the ended session, and no second dialog appears |
| 3.28 | Press Cancel on a *stale* joining screen after an invite has replaced that join | The replacement's join and its loading screen are unaffected; only the stale attempt stops |
| 3.29 | Fail the activity delete once, then let it succeed | The activity is only recorded as cleared on the successful attempt; exactly one retry is sent, after ~1 s |
| 3.30 | Fail every activity write while players keep joining and leaving | Four attempts total in that episode (initial + 1 s, 2 s, 4 s); roster changes add no attempts; a warning names the operation and the count, and no dialog appears |
| 3.31 | Fail an activity publish, then close the match | A delete is still sent despite the publish never being confirmed; the close starts a fresh budget |

### Tier 3 fast path

For iteration, 3.2 → 3.3 → 3.6 → 3.7 → 3.10 covers connection, replication and teardown.
It does **not** replace text/privacy/audio acceptance for communication changes.

> **After any change that moves an `@rpc` method**, 3.3 and 3.7 are mandatory. Godot routes RPCs by
> node path, so a relocated `@rpc` fails silently at runtime rather than at parse time. The parse
> gate cannot catch it and only a real two-instance join will.

On one desktop, focusing one instance constrains the other. Use two focused machines
for reliable simultaneous gameplay/audio observation; do not record unfocused-host behavior as
a Party latency defect. See the [sample latency limits](gameplay-reference.md#netcode-model-and-latency-limits).

### Typed-text acceptance

Use an online match, not a lobby. Cases involving XBOX policy/moderation require registered
XBOX accounts; run permitted transport/UI cases on custom-ID only, with that limitation recorded.

| Case | Expected |
|---|---|
| Both permitted peers send while microphones are muted | Remote text appears on each peer; exactly one local echo per successful send; no audio permission broadening |
| Five distinct messages | Exactly the latest four retained/displayed in order; oldest removed, no scrollback |
| Empty/whitespace input | Entry stays blank and nothing happens; no published message or successful echo |
| Exactly 100 characters | Accepted if moderation/policy permits; intact wrapped plain text on both peers |
| More than 100 characters at service/receive boundary | Rejected rather than silently published/displayed; normal entry also limits input to 100 |
| Markup-like text and long wrapped rows | Ordinary Labels render literally with no BBCode; four wrapped, bounded-height rows fit without obscuring essential HUD or stealing input |
| Moderation refusal, unavailable verification or SDK send failure | Input retained with a reason, no successful echo; custom-ID cannot cover XBOX verification failure |
| No eligible recipients | Explicit failure, not empty-array broadcast or false local success |
| Roster peer leaves while its Party chat control lingers | Immediately excluded from eligible recipients; no new send targets or displayed rows for that peer |
| Text denied but voice allowed | No outgoing target/ReceiveText/display for denied peer; allowed voice unchanged |
| Voice denied or muted but text allowed | Voice stays restricted; typed text still works |
| Pending privacy, missing/unknown sender or departed peer | No unauthorized new row; sender must resolve through PartyService.entity_key_for and current roster, never the replicated fallback |
| Missing/failed XBOX text permission batch | Text denied; voice fallback unchanged; custom-ID without XBOX privacy still permits authenticated current-roster peers |
| Failed/missing text query followed by a successful evaluation | Failure is not cached as a permanent denial; new text follows the resolved verdict, with no old-content replay |
| User/account-cache invalidation | Text privacy re-evaluated; no retained text while pending and no replay afterward |
| Late privilege/privacy/list responses after cache invalidation | Abandoned responses cannot repopulate the cleared service-owned caches |
| Host/join privilege check invalidated during setup or system remediation | Gate stays closed until a current-generation check resolves; current denial refuses and current grant can proceed |
| Text permission revoked with retained rows | Affected rows removed; restoration never replays discarded content |
| Communications privilege revoked mid-session, then restored | Control destroyed on revocation; restoration requires leave/rejoin to recreate chat, not live network reconfiguration |
| Leave/cancel/loss during moderation, send or privacy evaluation | Late result cannot send/add a row in a new match or identity |
| Match exit, suspend, identity removal and new match | All rows cleared; no lobby backlog or account/session carryover |
| Repeated sessions and echo behavior | One handler/one echo; local echo denotes SDK submission only, never receipt by another peer |
| Overlapping leave/rejoin and ordinary/canceled control destruction | Peer detaches synchronously; PartyService owns one serialized native teardown; replacement control creation waits for destruction to complete; fake-SDK success does not clear the live cleanup blocker |
| Keyboard/gamepad and console system keyboard | Existing open/submit/cancel/focus behavior preserved; failed entry remains editable |
| Offline or communications-denied account | Clear unavailable behavior, not a working-looking chat panel |

Normal UI cannot create every malformed SDK event, force a pending-policy race or exceed its
own entry limit. Use authorized diagnostics/debugger control when available and record the
method; otherwise mark those cases **not exercised**, not implicitly passed by a normal send.
Focused fake-SDK checks cover title-side cases, not real Party teardown or XBOX/hardware
behavior. Receiving typed text never requires transcription flags.

## Tier 4: Console

| # | Check | Expected |
| --- | --- | --- |
| 4.1 | `.\tools\deploy-console.ps1 -ConsoleAddress <ip> -Launch` | Title launches on the devkit |
| 4.2 | `python tools\pckdiff.py scarlett_build\NetRumbleConsole.pck` | Shader cache present |
| 4.3 | Sign-in with the console account | Gamertag shown |
| 4.4 | Guide/constrain and unconstrain | Game audio/local simulation pause and restore, session retained; not evidence of suspend |
| 4.5 | Actual platform suspend, confirmed by notification | Synchronous persistence, session abandonment and text clear; no deferred save dependence |
| 4.6 | Resume after 4.5, or relaunch if terminated | Resume routes to menu with notice when applicable; no resumed match; termination/relaunch recorded separately |
| 4.7 | Controller disconnect/reconnect | Overlay shows/hides automatically; match continues; no exclusive input-filtering claim |
| 4.8 | Other controller disconnects with platform associations available | Account-scoped detection does not mistake another account's device for the active user's |
| 4.9 | Same-console relaunch after setting/history/counter changes | State loads for that user; local persistence observation only |
| 4.10 | Close/sync, then same account on a second console | Settings/history/counters observed on the second console: actual Game Save roaming evidence |
| 4.11 | Signed-in-user removal, then another account | Synchronous commit and account/chat cleanup; no previous account's history/counters/settings exposed |
| 4.12 | Full multiplayer/audio/text pass against registered PC | Same-title compatible peers; XBOX policy tested separately from custom-ID |
| 4.13 | Sustained offline hint and terminal Party/host loss | Online session ends with a reason; hint grace is eight seconds; Practice remains available |
| 4.14 | Brief hint loss restored before grace expires | No hint-only session teardown if Party survives; endpoint failures may still end it |

Read [Game Save](walkthroughs.md#console-game-save-and-account-isolation) and
[lifecycle](walkthroughs.md#lifecycle-connectivity-and-controllers) before these cases.
One console cannot demonstrate cross-console roaming. An icon cannot demonstrate audible voice.

## Secondary gameplay regression

Keep this coverage for simulation, tuning, RPC and presentation changes. Source/behavior detail
is in [gameplay reference](gameplay-reference.md) and [protocol](protocol.md). Use both focused
peers in a low-latency setup; record conditions instead of asserting a WAN latency guarantee.

| Check | Expected |
|---|---|
| Practice layout and movement | Barrier, asteroids and ship spawn; thrust/rotation/camera work; boundary collisions follow the barrier rules |
| Asteroid destruction | Fragments spawn with inherited momentum on both peers, including from a client's shot |
| Every weapon/power-up | Weapon/buff changes, pickup effects/audio; pickup disappears for all peers and benefits only the collector |
| Death and respawn | Explosion, queue and ship return; host/client health and respawn state agree |
| Bots | Bots fly, engage and shoot; solo Practice remains playable |
| Client movement and shooting | Visible on host and client; host resolves damage and score; no broken RPC route |
| Scoring | Shared scores agree; other-player projectile kill +1, self/environment death -1 floored at zero |
| Mines and rockets | Spawn/detonation events agree; trajectory visuals checked under recorded network conditions |
| Match layout/countdown/end | Layout created once before countdown; both peers reach results and return to lobby coherently |
| Every mode and loading barrier | Existing readiness, loaded flags and win conditions remain intact; no late admission |
| Options and display settings | Every setting survives close/reopen; correct storage path for platform; no lost focus |
| HUD/camera/effects | Camera follows/clamps, UI remains readable, starfield/effects render; text panel does not obstruct essential HUD |
| Menus/overlays | Gamepad focus is visible and scroll follows it across roster, options, chat entry and failure dialogs |
| Exit and repeated matches | No orphaned world, stale physics bodies, duplicate audio/events or prior-match UI state |

---

## Recording a run

Record date, commit/build stamp (including dirty marker), protocol, Godot/addon versions,
registered/editor/custom-ID path, sandbox/title, account roles, device/audio/network setup,
exact cases/actions, observed results and relevant errors. Avoid credentials, chat contents and
raw account identifiers in shared logs.

Mark each case **passed**, **failed**, **blocked** or **not exercised**, with evidence/reason.
Separate local file persistence from observed roaming, a submitted text echo from remote display,
icons from audio, constrain from suspend, and custom-ID transport from registered XBOX policy.
Written walkthroughs and static checks establish none of those live outcomes. A networking
change checked only at Tier 1 has not completed multiplayer acceptance.
