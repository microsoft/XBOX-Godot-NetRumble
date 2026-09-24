# Matchmaking

The current build shows one focusable **Matchmaking** row directly above **Host Match**. When the
queue, addon and four-player Deathmatch profile are available, pressing it opens a four-slot
group and starts the Quick Match lifecycle. When a dependency is unavailable, the same row shows
the exact reason without starting online work.

Automated fake-SDK coverage validates the title state machine and adverse service ordering. The
four-client campaign remains the required evidence for live queue, Lobby, Party, activity and
invite interoperability.

See also: [Multiplayer](multiplayer.md) · [Configuration](configuration.md) ·
[Platform services](platform-services.md)

## Target profile

The target profile is four-player Deathmatch:

- queue: `godotnr_q`;
- ticket timeout: 600 seconds;
- one local PlayFab user per running game instance;
- premade groups of one through four, with remote members submitted through
  `members_to_match_with`;
- a private arranged lobby with four slots and automatic PlayFab Lobby owner migration.

The queue has no title-side team or equality attributes. Protocol compatibility is verified
through lobby/member properties before Party transport admission rather than being claimed as a
queue rule.

A full group of four is deliberately submitted through the same ticket path, but PlayFab rejects
a ticket that already fills this queue's maximum. See
[A full group of four cannot use Quick Match](known-issues.md#a-full-group-of-four-cannot-use-quick-match).

## Service boundary

`MatchmakingService` owns ticket handles independently of screens:

- validates immutable group membership before an SDK call;
- connects ticket notifications before reconciling the current status snapshot;
- keeps service cancellation distinct from a local timeout;
- preserves native diagnostics separately from player-facing reasons;
- owns late ticket cleanup after an account, flow, or screen has moved on;
- arms one cancellable alarm at the search deadline;
- invalidates only old-runtime ticket obligations after a confirmed PlayFab Multiplayer reset.

`PartyService` owns native resources by captured context:

- staging and arranged Lobby handles may coexist during an arranged join;
- lobby updates, locks, descriptor publication, and leaves target the captured context;
- a stale completion cannot leave or overwrite a replacement context;
- only one Party transport is attached to Godot at a time;
- descriptor publication requires an unrevoked permit after the caller has activated the peer.
- every scoped create/join/prepare/transport/lock/post operation carries its own absolute
  deadline and cleanup handle;
- a caller may receive `TIMEOUT` while the still-running native result remains owned; a late
  Lobby or network is released exactly once and cannot attach to a replacement context;
- unexpected Lobby disconnect or owner change is reported separately from Party transport loss;
- a confirmed Multiplayer reset advances the recovery epoch before notifying the ticket service.

Unexpected staging Lobby loss is terminal even after the old-transport-loss branch is armed.
That armed exception applies only to the captured old Party transport. Normal handoff retires the
staging Lobby deliberately; `PartyService` disconnects its Lobby callback before native teardown,
so the expected retirement emits no `context_lost`.

The ordinary hosted/code/invite APIs remain compatibility entry points. Scoped matchmaking
cleanup never guesses which of two lobbies a global field refers to.

The flow uses two distinct handoff barriers: all four connected native members
must first publish compatible handoff acknowledgements before the owner locks the arranged
Lobby, then the fresh Party transport admits the exact pinned cohort before the first match can
start. After admission, every matched member must confirm successful retirement of its captured
staging resources in the arranged Lobby; COMMITTING_START remains blocked until all four
confirmations are present. That exact-four requirement remains active through loading and the
first `RUNNING` transition. Later rounds retain the arranged Lobby/network and use the hosted
rematch rule of two to four current humans.

## Metadata allocation

PlayFab search keys are service-reserved slots:

| Key | Use |
| --- | --- |
| `string_key1` | Hosted room code |
| `string_key2` | Game mode |
| `string_key3` | NetRumble protocol version |
| `string_key4` | Matchmaking lobby kind |

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

## Invite destinations

The Lobby connection string remains opaque and is passed unchanged through the invite path.
After joining only the candidate Lobby, `PartyService` classifies `string_key4` before Party
authentication:

- ordinary hosted Lobby: existing code/activity admission, destination `""`;
- matchmaking staging Lobby: only unlocked Gathering is accepted, destination
  `staging_gathering`;
- arranged Lobby: only a valid unlocked `rematch_gathering` round with compatible owner/member
  metadata is accepted, destination `arranged_rematch`;
- searching, bootstrap, gameplay, locked, stale or incompatible candidates are released before
  any Party network call.

An invited rematch replacement joins the retained arranged Lobby and its existing Party
descriptor with invitation id `NetRumble`. It creates no ticket and calls no arranged-lobby join
API.

## Availability and validation

Quick Match is available when all of these are true:

1. the queue name is present;
2. the PlayFab extension is loaded;
3. the PlayFab addon exposes group-ticket create/join, ticket status/cancellation, and arranged
   Lobby configuration;
4. `Assets.game_mode(DEATHMATCH)` exists and its configured `GameModeConfig.player_count` is
   exactly four, matching the independently configured queue size.

Account/save readiness, privilege, connectivity and unfinished cleanup are additional entry
conditions. A failed condition leaves the Matchmaking row focusable and reports its title-owned
reason.

The fake-SDK behavioral suite covers capability/profile rejection, groups of one through four,
level-triggered ticket status, cancellation/failure/timeout separation, scoped deadlines and
late cleanup, terminal Lobby loss, admission proofs, atomic arranged control, invite destination
fences, rematch adoption, and shared-runtime invalidation:

```powershell
.\tools\run-save-tests.ps1
```

That suite does not establish native Party/Lobby interoperability. Changes to `party_service.gd`
or `net_manager.gd` also require the Tier 3 two-peer evidence described in the
[manual test plan](manual-test-plan.md).
