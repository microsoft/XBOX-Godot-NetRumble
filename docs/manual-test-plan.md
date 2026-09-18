# Manual test plan

The primary acceptance path demonstrates GDK/PlayFab integration. Detailed gameplay checks
remain in [secondary gameplay regression](#secondary-gameplay-regression); they are not
prerequisites for reading the platform lessons, but still apply to gameplay/network changes.

The acceptance tables contain **expected outcomes, not recorded passes**. Use [Walkthroughs](walkthroughs.md)
for source/API entry points and [record every run](#recording-a-run). Static import success,
microphone icons, local file presence and custom-ID diagnostics cannot substitute for live-service,
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
| 1: Local | Godot 4.6+ (baseline 4.6.2), built addons and imported resources; setup and readiness-failure checks only, not unsigned Practice. |
| 2: XBOX services | Registered launch, **XDKS.1**, authorized sample title/sandbox access and an XBOX test account with initialized/loaded Game Saves. Dedicated A/B accounts for isolation, a second PC for PC roaming. |
| 3: Multiplayer | Two registered XBOX players on separate machines with ready saves. Two audio endpoints for voice. |
| 4: Console | Authorized devkit(s), a Middleware console fork and accounts with ready saves; two consoles for console roaming and registered PC for supported cross-platform roaming. |

> **Custom-ID is not a Tier 3 alternative.** Even when authentication succeeds on a development
> title, it lacks the signed-in XboxUser required by XGameSaveFiles and cannot enter gameplay.
> The committed sample title additionally refuses custom-ID account creation with `0x892357BA`
> (`E_PF_PLAYER_CREATION_DISABLED`). Use registered XBOX identities, not token caches or a bypass.

Do not change committed title/package ids. Obtain authorization before switching a machine-wide
sandbox, provisioning/changing accounts/services, deploying to a device or altering network state.
See [configuration](configuration.md) and the [capability matrix](../README.md#what-works-where).

## Static checks

Start with the repository text checks and Godot import/parse checks.
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

For save changes, also run focused account-save behavioral tests with fake identity/Game Saves
objects and disposable folders, with live platform bootstrap disabled. They must exercise the
production load/write/readiness behavior without reading or modifying real account saves.
See [repository checks](../tools/repository-checks.md). A mocked pass does not establish the
live PC/console cases below.

---

## Tier 1: Local setup and readiness failures

After addon setup/import, run the editor/debug path to inspect the front end and refusal
behavior. This is not registered XBOX on PC or Practice acceptance.

```powershell
godot.exe --path .
```

| # | Check | Expected |
| --- | --- | --- |
| 1.1 | Launch with sign-in unavailable | Acquire-user screen shows failed stage/reason and Retry/Back; no gameplay |
| 1.2 | Back during acquisition | Attempt abandoned; no delayed hand-off or stale account state |
| 1.3 | Attempt Practice without a ready account/store | Refused, including direct session entry; no world or unsaved match |
| 1.4 | Attempt host/join/friend/invite without ready saves | Refused or buffered for acquisition; authentication alone does not admit play |
| 1.5 | Custom-ID authentication on an authorized development title | Authentication may succeed; missing XboxUser prevents save readiness and gameplay; no token files |
| 1.6 | Inspect history/options before account readiness | No prior account's settings, history or counters exposed |
| 1.7 | Gamepad-only acquisition/failure navigation | Focus remains visible and returns correctly from overlays; Retry/Back reachable |
| 1.8 | Retry an unavailable service repeatedly | Clear error, one effective preparation operation, no bypass or duplicate hand-off |
| 1.9 | Quit during acquisition/loading | No new initialization, no hanging process; existing bounded drain applies |

**Output panel must be clean** of `SCRIPT ERROR`, `Parse Error` and unexpected `push_error`.
Warnings for unavailable live services can be expected here; missing bootstrap scripts or
unimported resources are setup failures, not successful readiness coverage.

## Tier 2: Identity and single-player services

Needs a registered build, an identified XBOX user and ready Game Saves for playable cases.

```powershell
.\tools\deploy-pc.ps1 -Launch
```

| # | Check | Expected |
| --- | --- | --- |
| 2.1 | Account acquisition completes on launch | Authentication and save loading finish before menu/gameplay readiness; gamertag alone is insufficient |
| 2.2 | Fail/decline sign-in or save loading | Reason plus Retry/Back; no Practice or multiplayer |
| 2.3 | Play a match to completion | Match history gains a row |
| 2.4 | Earn an unearned achievement / incremental condition | Correct account's XBOX progress changes when service accepts it; an already-earned award does not unlock again |
| 2.5 | Registered-PC relaunch as the same account | Settings, history and counters load from that account's Game Saves, not desktop files |
| 2.6 | Quit during authentication or save synchronization | Exits within the shared shutdown drain window instead of hanging; no fresh preparation |
| 2.7 | Known multiplayer denial, including an invite path | All entry paths refuse with a reason; resolvable denial uses system UI and re-checks |
| 2.8 | Multiplayer allowed, communications denied | Session works without a local chat control; voice/text unavailable, not falsely successful |
| 2.9 | Observe sign-in/config labels | Distinguish GDK initialization/registration, XBOX acquisition, PlayFab authentication and save readiness |
| 2.10 | Start Practice with ready saves | World spawns; Match History changes from empty note to a row after completion |
| 2.11 | Request typed text in Practice | Unavailable action explains that chat needs an online match; no successful echo |
| 2.12 | Change options, reopen and relaunch | Same account's settings persist through Game Saves; no focus loss |
| 2.13 | Alt-tab away/back during Practice | Game audio and local simulation/clock pause and restore; not suspend |
| 2.14 | Pause menu, leave and quit | No orphaned world or hanging process; writes remain bound to the same account |

Achievement/reporting observations need real XBOX service results. Cached counters and a visible
gamertag are not substitutes. The current privilege-query fail-open behavior is a documented
limitation; record failures rather than treating an unchecked verdict as demonstrated policy.

## Account-owned saves: PC and console

These are **required expectations, not recorded runtime passes**. Use dedicated authorized
test accounts with known state; never clear a user's cloud saves to manufacture a fresh account.
Record A's and B's own settings/history/counters before and after each run. Create A's progress
through the account-owned store in this build, not by importing historical shared files.

**Original PC reproduction:** On the registered PC, launch as A, complete Practice matches and
close normally. Switch the launching XBOX account to fresh B, then relaunch the same registered
package. B must display **`No match history yet.`**, default settings and zero counters.
Complete a match as B, close and alternate A/B relaunches: both accounts must retain only their
own progress. Repeat with a B that already has nonempty Game Saves.

| Case | Required result |
|---|---|
| Original A -> fresh B reproduction, then alternate A/B | B starts empty/default; A's own Game Saves remain recoverable; neither account overwrites the other |
| B has existing settings/history/counters | B loads exactly B's state, with no A rows, preferences, counters or achievement reports |
| Both integrity slots missing in an initialized folder; valid empty history | Defaults/empty history/zero counters as applicable are authoritative, not previous memory |
| Shared `settings.cfg`, `match_history.json`, `achievement_stats.json` and token variants pre-seeded in isolated fixtures | Never read, imported, copied, modified, moved or deleted; no migration, old-wrapper reader or compatibility path |
| New profile and explicitly saved music `0.7` | New profile defaults to `0.25`; explicit `0.7` stays `0.7`, with no value remapping |
| Initialization/folder failure, unreadable slot, neither slot intact or wrong current-schema payload shape | Specific reason plus Retry/Back; no gameplay, partial account publication or default overwrite of existing files |
| Interrupted, truncated or corrupt inactive slot with an intact committed slot | Load the newest intact record; do not destroy the committed record or silently supply defaults |
| Retry after authentication succeeded but save preparation failed | Actually prepares/loads saves and can become ready; no authentication-only early success |
| Repeated Retry or stalled preparation | One effective `GDK.game_save.get_folder_async` operation; no duplicate native request, stale hand-off or unsaved-play option |
| Missing Xbox services/SCID, native failure/cancel, malformed result or inaccessible path | Xbox folder preparation fails with a safe code/HRESULT when available; no PlayFab save fallback or default overwrite |
| Distinct XboxUser and PlayFabUser objects; PF local-user handle absent | Saves bind only to XboxUser; PlayFab identity cannot read/write that binding; existing PlayFab authentication is still required |
| Resume with successful sync, failed sync then Retry, or a different synchronized folder | Old provider/generation cannot save or enable gameplay; reacquire folder and reload all three before readiness, without replaying pre-suspend memory |
| Resume with delayed Party leave or chat destroy, including repeated suspend/resume | Acquisition names previous-session cleanup and never shows Ready or hands off early; one teardown drains before fresh setup and the first gameplay request succeeds |
| Cleanup stalls during acquisition | Watchdog exposes Back/PC Quit; Back cancels the attempt without bypassing cleanup, late completion cannot restore it, and Quit remains bounded by the shared deadline |
| Cold fallback GDK initialization; remove user during Xbox/PlayFab acquisition | User-change subscription exists before the account API waits; cancellation cannot restore identity or start later calls; initialization failure starts no Xbox acquisition |
| A friends load is delayed, clear A, start B and parallel B reads, then complete A/B in either order | B starts without waiting for A; same-generation callers share one load; A cannot clear B's guard, replace B's group or leak a stale native group |
| Resume with valid synchronized settings/history but invalid counters | No partial publication or gameplay; Retry reloads all three after the failure is resolved |
| Resume an abandoned match through acquisition; repeat from a menu only | One Match Ended notice after successful handoff for the abandoned match; none for menu-only resume |
| Accept an invite while resumed acquisition is pending | Invite waits for readiness and acquisition handoff, then owns the front end without a competing Match Ended notice |
| Resume while a save-error or failed-Quit dialog is open | Old modal is removed; late answers cannot save/quit the new generation; new failures can still open their dialog and Retry/Back |
| Resume while Cannot Join/Join Failed awaits dismissal, with a newer invite buffered | Old join claim is revoked; buffered invitation drains after acquisition; stale dialog answers cannot release the replacement claim |
| Remove the account while resumed synchronization is pending | Late completion cannot restore data/readiness or show that account's abandoned-match notice |
| Back/cancel, user removal or account replacement during an awaited load | Late completion cannot publish settings/history/counters, restore the old folder or enable gameplay |
| User removed during an active session | Blocks new work, clears account/session state; surviving process reacquires an account rather than continuing the match as another user |
| Direct Practice/host/join, code/friend/invite, existing-user and fallback branches | All require current account/save readiness; buffered invites cannot bypass failed or pending loads |
| No account, missing SDK or custom-ID without XboxUser | No gameplay and no substitute persistence backend |
| Network loss with an identified account and usable platform offline folder | Practice retains same-owner persistence; connectivity hint alone does not erase readiness |
| Cold offline launch | Play only if platform identity and store resolve successfully; otherwise Retry/Back, with no offline identity guarantee |
| Write failure, then retry | Failure is visible; prior valid file remains intact; current data retries only for the same owner and is not falsely reported saved |
| Appearance write fails; restore storage and suspend/quit without another edit | Current ship/color is written without requiring a dirty-marking call |
| Repeated explicit saves with unchanged values | Each request attempts all relevant payloads; no dirty flags or equality-based skipping |
| Buffered write/flush fault or writer-process termination | Close/reopen verification rejects incomplete bytes; prior intact slot remains readable. This is not a hard-power-loss durability claim |
| Final save fails during ordinary Quit/window close | Retry/Back before shutdown begins; repeated close requests do not bypass the pending save decision |
| Options Back fails to save, including unchanged settings and in-match Options | Save error remains visible, but Back returns to main/pause actions; dismissing it leaves Resume/Leave reachable, and later explicit saves retry current values |
| A's delayed activity write finishes after B hosts | Ignore A's result and reconcile B's queued advertisement instead of stranding it |
| Published lobby suspends, then resumes | No native activity call during Suspend; owner-bound delete starts on resume without waiting for save readiness; only confirmation records cleared |
| Suspend/resume overlaps a pending publish/delete, then a new session or account | Serialized writes converge on the newest session; stale completion cannot confirm/delete a replacement owner's activity or strand its publication |
| Normal Quit with a published activity, including delayed/failed deletion | Still-authenticated owner is used after readiness is revoked; deletion drains inside the shared deadline; timeout/failure is not recorded as cleared |
| Options/appearance, match completion, suspend and shutdown | Same account store/checks; explicit requests attempt relevant payloads and report individual outcomes; deadline-bound handlers remain synchronous |
| Quit during authentication or save sync | Existing bounded drain covers preparation; no fresh initialization or hanging exit |
| More than 50 completed matches | Newest 50 history rows retained in order with current payload shapes and UI formatting |
| Same account on a second registered PC after close/sync | Settings, history and counters observed there; a local file or relaunch alone is not roaming evidence |
| Equivalent console A/B, empty/default, failure, Retry and lifecycle cases | Same ownership, readiness and save policy as PC; record actual platform outcomes |
| Console-to-console and supported PC/console roaming | Same linked account/title sees synchronized settings/history/counters on the other device; verify both directions and preserve each account's own state |

Malformed/read/write-failure and timing races belong in isolated focused tests first. Use only
authorized development diagnostics to reproduce live failures; do not damage real saves or add
shipping fault-injection/bypass flags. Record unobservable races or missing hardware/service
prerequisites as blocked/not exercised. Mocked tests and source inspection cannot establish
full PC/console parity or roaming.

## Tier 3: Multiplayer

The regression gate for anything touching `net_manager.gd`, `platform_session.gd`, `world.gd`,
`world_network_sync.gd`, `party_service.gd`, `chat_service.gd` or `match_director.gd`.

Use two registered builds/accounts with ready Game Saves. Custom-ID authentication lacks
the required XboxUser and cannot supply playable Lobby/Party/UI coverage.

| # | Check | Expected |
| --- | --- | --- |
| 3.1 | Both players acquire their accounts and saves | Distinct XBOX accounts on registered builds; each store loaded before joining |
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
| 3.14 | Join Friend and accepted invite while warm/cold | Registered XBOX path waits for account/save readiness before lobby; Back abandons acquisition without joining |
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

Use two focused registered machines for simultaneous gameplay/audio observation;
do not record unfocused-host behavior as
a Party latency defect. See the [sample latency limits](gameplay-reference.md#netcode-model-and-latency-limits).

### Typed-text acceptance

Use an online match, not a lobby, with registered XBOX accounts and ready saves.
Lower-level custom-ID diagnostics are not playable transport/UI or XBOX policy coverage.

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
| Missing/failed XBOX text permission batch | Text denied; voice fallback unchanged; no custom-ID gameplay substitute |
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
| 4.3 | Acquire the console account and saves | Gamertag shown and saved state loaded before gameplay |
| 4.4 | Guide/constrain and unconstrain | Game audio/local simulation pause and restore, session retained; not evidence of suspend |
| 4.5 | Actual platform suspend, confirmed by notification | Synchronous persistence, session abandonment and text clear; no deferred save dependence |
| 4.6 | Resume after 4.5, or relaunch if terminated | Resume invalidates the old provider and reacquires/loads through the acquire-user screen before gameplay; no resumed match; termination/relaunch recorded separately |
| 4.7 | Controller disconnect/reconnect | Overlay shows/hides automatically; match continues; no exclusive input-filtering claim |
| 4.8 | Other controller disconnects with platform associations available | Account-scoped detection does not mistake another account's device for the active user's |
| 4.9 | Same-console relaunch after setting/history/counter changes | State loads for that user; local persistence observation only |
| 4.10 | Close/sync, then same account on a second console | Settings/history/counters observed on the second console: actual Game Save roaming evidence |
| 4.11 | Signed-in-user removal, then another account | Deadline-safe account/chat cleanup; writes only while access remains valid; session ends and no previous account state is exposed |
| 4.12 | Full multiplayer/audio/text pass against registered PC | Same-title compatible peers; XBOX policy tested separately from custom-ID |
| 4.13 | Sustained offline hint and terminal Party/host loss | Online session ends with a reason; hint grace is eight seconds; Practice requires the identified account's still-ready store |
| 4.14 | Brief hint loss restored before grace expires | No hint-only session teardown if Party survives; endpoint failures may still end it |

Read [Game Saves](walkthroughs.md#game-saves-and-account-isolation), the
[account-save matrix](#account-owned-saves-pc-and-console) and
[lifecycle](walkthroughs.md#lifecycle-connectivity-and-controllers) before these cases.
One console cannot demonstrate cross-console roaming. An icon cannot demonstrate audible voice.

### Xbox Guide Quit and suspend saves

Use an authorized test account and record the build, changed data, connectivity and whether
the observation is on the same console or another device. Exercise **Constrain -> Suspend ->
Terminate** through Xbox Guide -> Quit. Saving belongs on Suspend; merely opening/closing
Guide is not the termination test. Do not delete or corrupt real account saves to manufacture
a failure.

| Case | Expected |
| --- | --- |
| Change an Options value but do not press Back; Guide -> Quit | The current setting is written on Suspend and reloads on the same console/account |
| Earn lifetime counters during an unfinished match; Guide -> Quit | Counters written on Suspend reload; no fabricated completed-match row or resumed match |
| Complete a match, then Guide -> Quit before/after acknowledging results | The completed history reloads once |
| Current settings, history retry and counters together in an isolated fixture | All three writes are attempted before teardown and before the actual main-script suspend notification returns, even if an earlier payload fails |
| Constrain only | No Constrain writes, timer or SDK initialization |
| Repeated Suspend with unchanged values | Each Suspend attempts settings, history and counters with no new SDK initialization |
| Inject write failures or unavailable/lost account in isolated tests | Explicit per-stage/payload outcome; prior valid data preserved; no cross-account write or success claim |
| Terminate an isolated child immediately after the actual suspend handler returns | Fresh process reloads the successful checkpoint without a normal Quit call, resume or another frame |

Capture suspend entry, account/store readiness, per-payload outcomes, elapsed save time and
handler exit. On console, verify that the packaged engine delivers Suspend to the title and
does not complete suspension before the synchronous handler finishes. Compare the observed
duration with the applicable platform deadline; do not substitute a guessed budget.

First verify same-console reload. If that succeeds but another device is stale, investigate
cloud synchronization separately. A completed local write is not an upload receipt.
Isolated notification/process-termination tests do not establish real Xbox notification
delivery, roaming, or hard-power-loss durability.

## Secondary gameplay regression

Keep this coverage for simulation, tuning, RPC and presentation changes. Source/behavior detail
is in [gameplay reference](gameplay-reference.md) and [protocol](protocol.md). Use both focused
peers in a low-latency setup, with ready account saves for all modes including Practice;
record conditions instead of asserting a WAN latency guarantee.

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
| Options and display settings | Every setting survives close/reopen in the same account's Game Saves on PC/console; no lost focus |
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
icons from audio, constrain from suspend, and custom-ID diagnostics from registered gameplay/XBOX policy.
Written walkthroughs and static checks establish none of those live outcomes. A networking
change checked only at Tier 1 has not completed multiplayer acceptance.
