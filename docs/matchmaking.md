# Matchmaking foundations

NetRumble contains disabled service foundations for a PlayFab Matchmaking flow.
`MatchmakingService` keeps `_FLOW_IMPLEMENTED` false, there is no Quick Match menu row, and the
public entry point reports that Quick Match is unavailable even when the installed addon exposes
all required APIs.

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
- owns late ticket cleanup after an account, flow, or screen has moved on.

`PartyService` owns native resources by captured context:

- staging and arranged Lobby handles may coexist during an arranged join;
- lobby updates, locks, descriptor publication, and leaves target the captured context;
- a stale completion cannot leave or overwrite a replacement context;
- only one Party transport is attached to Godot at a time;
- descriptor publication requires an unrevoked permit after the caller has activated the peer.

The ordinary hosted/code/invite APIs remain compatibility entry points. Scoped matchmaking
cleanup never guesses which of two lobbies a global field refers to.

Arranged-lobby admission, the exact-four first-start barrier, gameplay transition and private
rematch are implementation targets, not enabled guarantees in this build.

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
`nr_handoff_ready`. These are string values because PlayFab Lobby property bags are string-only.

## Availability and validation

Quick Match remains unavailable unless all of these are true:

1. the title flow is implemented and explicitly enabled;
2. the queue name is present;
3. the PlayFab addon exposes group-ticket create/join, ticket status/cancellation, and arranged
   Lobby configuration;
4. `Assets.game_mode(DEATHMATCH)` exists and its configured `GameModeConfig.player_count` is
   exactly four, matching the independently configured queue size.

The fake-SDK behavioral suite covers capability/profile rejection, groups of one through four,
level-triggered ticket status, cancellation/failure/timeout separation, and scoped resource
cleanup:

```powershell
.\tools\run-save-tests.ps1
```

That suite does not establish native Party/Lobby interoperability. Changes to `party_service.gd`
or `net_manager.gd` also require the Tier 3 two-peer evidence described in the
[manual test plan](manual-test-plan.md).
