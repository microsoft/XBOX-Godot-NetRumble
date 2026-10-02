# Matchmaking

The current build shows one focusable **Matchmaking** row directly above **Host Match**. When the
queue, addon and capacity-four Deathmatch profile are available, pressing it opens a four-slot
group and starts the Quick Match lifecycle. When a dependency is unavailable, the same row shows
the exact reason without starting online work.

When everyone is ready, the current group chooses one automatic route. Groups of one to three
search for a two- to four-player match. A full group of four uses **Private Start**: it starts a
private match in the same Lobby and Party network without a ticket or search. Any change to the
initial group resets readiness before either route can start.

The matchmade path uses the players currently present in the arranged session rather than
claiming the service exposed a complete assigned roster. Both routes keep session capacity four,
which is separate from the number of players who start a particular round.

Automated fake-SDK coverage validates the title state machine and adverse service ordering. The
four-client campaign remains the required evidence for live queue, Lobby, Party, activity and
invite interoperability.

See also: [Multiplayer](multiplayer.md) · [Configuration](configuration.md) ·
[Platform services](platform-services.md)

## Target profile

The queue allows 2-4 players and the play session has capacity four:

- queue: `godotnr_q`;
- ticket timeout: 600 seconds;
- one local PlayFab user per running game instance;
- premade groups of one through three, with remote members submitted through
  `members_to_match_with`;
- a private arranged lobby with four slots and automatic PlayFab Lobby owner migration for
  matched play;
- a full ready group of four promoted in place to a private four-slot session with its existing
  owner and no owner migration.

The queue has no title-side team or equality attributes. Protocol compatibility is verified
through lobby/member properties before Party transport admission rather than being claimed as a
queue rule.

A ticket that already fills the queue maximum is rejected. The normal full-group path never
submits one because Private Start is chosen before ticket creation. Native error handling remains
defensive and does not choose another play route from a ticket failure.

The title confirms that cause only when the addon exposes the native `0x89235652` result. The
supported addon forwards the real HRESULT for terminal ticket failure. An early completion with
no usable ticket id can still be a generic `E_FAIL`; that remains a generic Matchmaking failure
and carries return-to-group guidance separately. Ticket status alone, a missing ticket id or
service message text never proves a queue-size rejection or "no match." If an unexpected
full-group ticket fails without a proven cause, the player is directed back to the group to ready
up for Private Start.

## Service boundary

`MatchmakingService` owns ticket handles independently of screens:

- validates immutable group membership before an SDK call;
- connects ticket notifications before reconciling the current status snapshot;
- keeps service cancellation distinct from a local timeout;
- preserves native diagnostics separately from player-facing reasons;
- owns late ticket cleanup after an account, flow, or screen has moved on;
- arms one cancellable alarm at the search deadline;
- invalidates only old-runtime ticket obligations after a confirmed PlayFab Multiplayer reset.

Ticket terminal status and cancellation completion are separate obligations. Matched,
Cancelled or Failed is authoritative ticket state; an in-flight native cancel remains owned
until its completion or confirmed Multiplayer invalidation. On the supported addon, a cancel that
loses to Matched returns the matched ticket and completes without a routine service reset.
Bounded recovery remains for explicitly unfinished or failed native work.

`PartyService` owns native resources by captured context:

- staging and arranged Lobby handles may coexist during an arranged join;
- a staging context can become a private play session without replacing its Lobby, Party network
  or Godot peer;
- lobby updates, locks, descriptor publication, and leaves target the captured context;
- a stale completion cannot leave or overwrite a replacement context;
- only one Party transport is attached to Godot at a time;
- descriptor publication requires an unrevoked permit after the caller has activated the peer.
- every scoped create/join/prepare/transport/lock/post operation carries its own absolute
  deadline and cleanup handle;
- a caller may receive `TIMEOUT` while the still-running native result remains owned; a late
  Lobby or network is released exactly once and cannot attach to a replacement context;
- a non-OK scoped Lobby or Party leave remains cleanup-pending after returning its service error;
  only confirmed multiplayer recovery clears that obligation, while failed recovery requires a
  restart;
- retained failed-leave debt can exist between cleanup runs: it continues to block online entry,
  but the title distinguishes that obligation from cleanup currently executing so an available
  owner can start the existing recovery promptly;
- unexpected Lobby disconnect or owner change is reported separately from Party transport loss;
- a confirmed Multiplayer reset advances the recovery epoch before notifying the ticket service.

Capacity, premade size and the first start's selected players are separate facts. Ticket creation
knows the premade and capacity four, not the service's complete assignment.

## Private Start

Private Start is the automatic full-group route:

1. The current four admitted group members all acknowledge the current composition and ready up.
2. The owner closes admission and locks the existing staging Lobby.
3. One checked update changes that Lobby to Private access, marks it as a private play session and
   publishes a title-owned session id plus the exact starting four.
4. Every member reads back the same private control before the ordinary countdown and loading
   path begins.

The Lobby, Party network, descriptor, peer, owner and four-slot capacity do not change. Private
Start creates no match ticket, arrangement, room code, replacement Lobby or replacement network.
The private session id is not a PlayFab match id.

Unexpected staging Lobby loss is terminal even after the old-transport-loss branch is armed.
That armed exception applies only to the captured old Party transport. Normal handoff retires the
staging Lobby deliberately; `PartyService` disconnects its Lobby callback before native teardown,
so the expected retirement emits no `context_lost`.

The ordinary hosted-session continuity rule for a client's local-only Lobby notification loss
does not apply to Matchmaking contexts. Staging and arranged Lobby loss remains terminal until
the captured context enters its own deliberate leave boundary.

The ordinary hosted/code/invite APIs remain compatibility entry points. Scoped matchmaking
cleanup never guesses which of two lobbies a global field refers to.

Each client first waits for its own frozen premade to arrive and acknowledge the arranged Lobby
before closing that premade's old transport. The actual arranged owner can prepare the fresh
capacity-four Party network while bootstrap membership remains unlocked. Candidates are admitted
from current native Lobby and Party facts.

The owner selects the current present set only when it contains 2-4 members and every present
member is connected, admitted, compatible and has confirmed staging retirement. There is no
wait-for-four or settle timer, and the title does not claim this is the service's complete
assignment. The owner then locks and rechecks that exact selected set, publishes its start
control, and carries it unchanged through loading and first `RUNNING`.

A match can start with the players who have arrived. Players who arrive after it starts cannot
join that round and may need to search again. A present but incompatible or incomplete member is
not ignored to form a smaller compatible subset.

After the first game, the same capacity-four play session becomes an ordinary hosted ready-up
session. This applies to both the arranged matchmade session and the in-place private session.
Later rounds use the current admitted humans, require at least two, can accept compatible invited
replacements up to four, and never automatically requeue. A replacement is invite-only; no
retained round starts a new ticket.

## Metadata allocation

PlayFab search keys are service-reserved slots:

| Key | Use |
| --- | --- |
| `string_key1` | Hosted room code |
| `string_key2` | Game mode |
| `string_key3` | NetRumble protocol version |
| `string_key4` | Matchmaking lobby kind: staging, arranged or private |

Member-visible matchmaking state uses `nr_search`; arranged member compatibility uses
`nr_protocol`, `nr_match_id`, and `nr_matchmaking_origin`; transport retirement uses
`nr_handoff_ready`. Successful local staging retirement uses
`nr_staging_retired = nr_match_id`; it is absent from initial join properties and published only
after the typed leave succeeds and PartyService reports the captured context quiescent. Arranged
owner control is one checked property batch:

| Property | Value |
| --- | --- |
| `nr_match_id` | Nonempty opaque match id |
| `nr_round` | Canonical nonnegative decimal generation |
| `nr_phase` | `bootstrap`, `gameplay`, or `rematch_gathering` |

Descriptor refresh republishes the last valid match/round/phase tuple and cannot revert it.
These are string values because PlayFab Lobby property bags are string-only.

Private owner control uses `nr_play_origin = private`, a 32-character title-generated
`nr_session_id`, and the same round/phase/start-generation/start-members fields. Initial round
zero names exactly the starting four. Retained rounds use an empty selected set because their
roster follows the ordinary hosted ready-up rules.

## Invite destinations

The Lobby connection string remains opaque and is passed unchanged through the invite path.
After joining only the candidate Lobby, `PartyService` classifies `string_key4` before Party
authentication:

- ordinary hosted Lobby: existing code/activity admission, destination `""`;
- matchmaking staging Lobby: only unlocked Gathering is accepted, destination
  `staging_gathering`;
- arranged Lobby: only a valid unlocked `rematch_gathering` round with compatible owner/member
  metadata is accepted, destination `arranged_rematch`;
- private Lobby: only a valid unlocked retained `rematch_gathering` round with compatible
  owner/member metadata is accepted, destination `private_rematch`;
- searching, bootstrap, gameplay, locked, stale or incompatible candidates are released before
  any Party network call.

An invited rematch replacement joins the retained play session and its existing Party descriptor
with invitation id `NetRumble`. A private replacement writes the private session id before Party
entry. Neither origin creates a ticket; the private adapter also calls no arranged-lobby join API.

## Availability and validation

Quick Match is available when all of these are true:

1. the queue name is present;
2. the PlayFab extension is loaded;
3. the PlayFab addon exposes group-ticket create/join, ticket status/cancellation, and arranged
   Lobby configuration;
4. `Assets.game_mode(DEATHMATCH)` exists and its configured `GameModeConfig.player_count` is
   exactly four, matching the supported Lobby/Party capacity.

Account/save readiness, privilege, connectivity and unfinished cleanup are additional entry
conditions. A failed condition leaves the Matchmaking row focusable and reports its title-owned
reason.

The fake-SDK behavioral suite covers capability/profile rejection, groups of one through four,
level-triggered ticket status, cancellation/failure/timeout separation, scoped deadlines and
late cleanup, terminal Lobby loss, current-member admission facts, selected-set control, invite
destination fences, in-place private promotion/restoration, retained private rounds, rematch
adoption, and shared-runtime invalidation:

```powershell
.\tools\run-save-tests.ps1
```

That suite does not establish native Party/Lobby interoperability. Changes to `party_service.gd`
or `net_manager.gd` also require the Tier 3 two-peer evidence described in the
[manual test plan](manual-test-plan.md).
