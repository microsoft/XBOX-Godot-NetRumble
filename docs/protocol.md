# NetRumble wire protocol reference

> **You do not need this page to run or learn from the sample.** It is a wire-format
> reference for contributors modifying netcode, RPC routing or payload compatibility.

Start with [Architecture](architecture.md),
[Lobby/Party connection flows](multiplayer.md#connection-flows) and
[Walkthroughs](walkthroughs.md) to learn the integration. The
[gameplay reference](gameplay-reference.md) covers simulation and presentation.

NetRumble uses Godot's high-level `MultiplayerAPI` over a PlayFab Party transport
(`PlayFabPartyPeer`, a `MultiplayerPeerExtension`). All messages are declared as
`@rpc` functions on the `NetManager` autoload. The host is always peer id `1`.

**Where the code lives.** `scripts/autoload/net_manager.gd` declares every `@rpc`: the
message *transport*. `scripts/gameplay/world_network_sync.gd` is the message *content*:
it builds the outgoing snapshot on the host and applies every inbound message on
clients, so the writer and the reader of each format below sit side by side in one file.

If you are not modifying netcode, the high-level model is enough: Godot RPC messages ride over
PlayFab Party transport, while Party chat handles voice, text and transcription separately. The
host owns the authoritative simulation; clients send inputs and receive snapshots and reliable
events. You can use the sample without memorizing the byte layouts below, but any netcode change
must update the relevant schema and version rules.

```text
Client input  ->  PlayFab Party transport  ->  Host simulation
                                                   |
                                                   v
Clients  <-  snapshots and reliable events  <-  PlayFab Party transport

Voice, text and transcription travel over Party chat controls,
not over Godot RPCs.
```

> **See also:** [session lifecycle](multiplayer.md#leave-and-loss) and
> [simulation vs match flow](gameplay-reference.md#simulation-vs-match-flow).

---

## RPC routing note

Godot routes every `@rpc` call by the *node path* of the node the method is declared
on. All 30 entry points live on `NetManager` (the autoload at `/root/NetManager`).
Moving any one of them to a different node changes its route; peers running the old
path and peers running the new path silently miss each other, and neither a headless
import pass nor a single-instance run catches the mismatch. Anything that needs a
new `@rpc` should be declared here, not on a gameplay node.

---

## Protocol version
Two builds that disagree about this document cannot play together, and **the failure
is silent unless something checks**.  `scripts/gameplay/nr_protocol.gd` (`NRProtocol`)
is that check.

### Why it is needed

Godot identifies an `@rpc` method on the wire by an **index** into the declaring node's
RPC list, not by name. Adding, removing or renaming any `@rpc` on `NetManager` shifts
the index of every method after it. Peers built either side of such a change connect
successfully and then send each other traffic that lands on the wrong handler or on
none at all. What a player sees is a match that joins and then does nothing: no
roster, no ships, no error message.

This cost real time in a bug bash session before the check existed.

### The two parts

`NRProtocol.version_string()` renders `WIRE_VERSION` and `RPC_SET_VERSION` as one
dot-separated token. They are separate because there are two independent ways to
break compatibility and neither implies the other:

| Constant | Bump it when |
|---|---|
| `WIRE_VERSION` | Any replicated payload's schema changes: a key added, removed, renamed or repurposed in a `Dictionary` that crosses the wire. Every format in this document counts. |
| `RPC_SET_VERSION` | The `@rpc` method set on `NetManager` changes: one added, removed, renamed, or the signature of an existing one altered. |

Renaming a snapshot key from `"px"` to `"posx"` changes no method name and so cannot
move an index. Adding one `@rpc` moves every index and touches no payload schema.

> `RPC_SET_VERSION` is hand-maintained today, which is its weakness: this check exists
> because nobody remembers to think about compatibility while adding an RPC, and a
> constant they must remember to bump has the same failure mode. The intended
> replacement is a hash derived from the sorted `@rpc` method names at startup.
> `version_string()` already renders this part as an opaque token so the hash can drop
> in without changing the wire format or any comparison logic.

### Where it is enforced

**Primary: the PlayFab lobby.** The host publishes `version_string()` in the lobby's
search properties under `NRProtocol.LOBBY_KEY` (`string_key3`; `string_key1` and
`string_key2` are the join code and game mode).  `PartyService` reads it off the
*attached* lobby immediately after joining and refuses a mismatch before the Party
network join, so it covers join-by-code, invites and protocol activation alike.

This layer is primary because the lobby is PlayFab's channel rather than Godot's. A
version check delivered over Godot RPC is subject to the exact corruption it exists to
detect; a check on the lobby still reads correctly when the peers cannot understand
each other's traffic at all.

**Backstop: the identity handshake.** `_submit_player_identity` carries the version
as its second argument and the host rejects a mismatch through `_reject_join`. This is
best-effort by nature, for the reason just given, but it costs nothing and catches
peers that reach the transport without passing the lobby check.

### Rules

- A **missing** version is a mismatch, not a pass. That is what a build from before
  this check looks like, and letting it through would admit the exact case this was
  written for.
- A mismatch is **blocking**, never a warning. A refusal the player can read is more
  useful than a silent empty roster.
- Everything built before the first versioned release is incompatible with it. Adding
  `_reject_join` and the version argument to `_submit_player_identity` both moved the
  RPC indices.

### Version history

| `version_string()` | Change |
|---|---|
| `1.1` | First versioned release. |
| `1.2` | `RPC_SET_VERSION` → 2: `_accept_join` and `_receive_join_admission` added for [host admission and lobby locking](multiplayer.md#closing-a-match-to-newcomers).  No payload schema changed, so `WIRE_VERSION` stayed at 1. |

---

## Message inventory

Messages are grouped by purpose. Each `@rpc` annotation is of the form
`@rpc(who_can_call, call_mode, reliability [, channel])`. All of the RPCs below use
`call_remote` (the call does not execute on the sender).

### Session and roster

These messages establish and maintain the player list. All are **reliable** because a
missed roster entry leaves a peer with a permanently stale view.

| RPC method | Direction | Reliability | Purpose |
|---|---|---|---|
| `_request_player_identity` | host → client | reliable | Host asks a newly connected client to submit its `PlayerState` |
| `_submit_player_identity` | client → host | reliable | Client delivers its `PlayerState` dict plus its `NRProtocol.version_string()`; host overwrites `entity_id` from Party's authenticated key |
| `_reject_join` | host → client | reliable | Host refuses a peer and gives the reason; the client treats it as an end of session (match already started, or a [protocol mismatch](#protocol-version)) |
| `_accept_join` | host → client | reliable | Host has admitted the peer and already replayed the roster and mode to it. This — not the transport attaching — is what resolves the client's pending join |
| `_receive_join_admission` | host → all | reliable | Host's admission gate opened or closed, so every member can retire or republish its own XBOX activity |
| `_receive_roster_entry` | host → all | reliable | Host fans out one (possibly color-adjusted) `PlayerState` to every peer |
| `_receive_player_left` | host → all | reliable | Notifies every peer that a player has disconnected |
| `_submit_ready_state` | client → host | reliable | Client changes its ready flag |
| `_receive_ready_state` | host → all | reliable | Host fans out a ready-flag change |
| `_submit_appearance` | client → host | reliable | Client requests a color/style change |
| `_receive_appearance` | host → all | reliable | Host fans out a confirmed color/style pair |
| `_submit_player_loaded` | client → host | reliable | Client reports its gameplay scene is ready |
| `_receive_player_loaded` | host → all | reliable | Host fans out the loaded flag; MatchDirector waits for all before unblocking |

### Match lifecycle

| RPC method | Direction | Reliability | Purpose |
|---|---|---|---|
| `_receive_match_state` | host → all | reliable | Delivers the new `NRTypes.MatchState` integer |
| `_receive_match_reset` | host → all | reliable | Returns the session to the lobby: clears scores, ready and in-game flags, and reopens the session to joins |
| `_receive_countdown` | host → all | reliable | Pre-match countdown tick, in whole seconds remaining |
| `_receive_match_clock` | host → all | unreliable\_ordered | Current match elapsed time (float); clients advance their own clock between arrivals |
| `_receive_game_mode` | host → all | reliable | Delivers the `NRTypes.GameModeType`; governs time limit and win condition |

### Simulation state

These messages carry the world itself. Snapshots are unreliable because the next one
supersedes the current one; everything else is reliable because it cannot be
reconstructed from later state.

| RPC method | Direction | Reliability | Purpose |
|---|---|---|---|
| `_receive_match_created` | host → all | reliable | Full initial world description (see [Match-created payload](#match-created-payload)) |
| `_receive_match_starting` | host → all | reliable | Per-entity reset positions for the start of a round |
| `_receive_world_snapshot` | host → all | unreliable\_ordered | Per-tick position/velocity/health for all ships and asteroids (see [Snapshot schema](#snapshot-schema)) |
| `_receive_projectile_spawned` | host → all | reliable | A new projectile entered the field |
| `_receive_projectile_detonated` | host → all | reliable | A projectile detonated; carries hit results |
| `_receive_asteroid_split` | host → all | reliable | An asteroid broke up; carries fragment descriptions |
| `_receive_ship_spawned` | host → all | reliable | A ship re-entered play (respawn) |
| `_receive_ship_destroyed` | host → all | reliable | A ship reached zero health |
| `_receive_power_up_spawned` | host → all | reliable | A power-up body appeared on the field |
| `_receive_power_up_collected` | host → all | reliable | A ship collected a power-up |
| `_receive_match_completed` | host → all | reliable | Match is over; carries final scores |

### Player actions

| RPC method | Direction | Reliability | Purpose |
|---|---|---|---|
| `_receive_ship_input` | client → host | unreliable\_ordered | Sender's own peer id, movement vector, fire vector, mine-deploy flag, sequence number |
| `_receive_gameplay_event` | host → all | unreliable | Positional event for local FX/audio (laser impact, rocket fired, etc.) |
| `_receive_score_updated` | host → all | reliable | One player's score changed |

### Chat

Text and voice travel over Party's chat controls and never appear in the `@rpc` inventory.
`NetManager.send_chat_message()` moderates through `Services.verify_chat_text()` before
`ChatService.send_chat_text()` submits to Party. One local signal echoes a successful SDK
submission, not a delivery acknowledgment. Received Party text passes policy/lifecycle and
authenticated-roster checks before the gameplay screen displays it.

The four-row `NRChatLog` is transient in-match presentation. Adding it changes no gameplay
RPC declarations, payloads or protocol version. See [typed-text behavior](multiplayer.md#chat).

---

## Snapshot schema

`MatchDirector` drives a snapshot at `NRConst.WORLD_SNAPSHOT_HZ` (30 Hz) by calling
`World.broadcast_snapshot()`, which delegates to `WorldNetworkSync`; that builds the
payload and hands it to `NetManager.broadcast_world_snapshot()` to put on the wire.
The payload is a `Dictionary`:

```
{
  "frame": <int>,         # monotonically increasing snapshot counter
  "objects": [ <entry>, … ]
}
```

Each `<entry>` is built by `WorldNetworkSync._snapshot_entry()`
(`scripts/gameplay/world_network_sync.gd`), which is also where the client-side reader
of this schema lives.

### Why single-character keys?

A snapshot entry is sent once per entity per tick. With up to eight ships and
(typically) a dozen or more asteroids, the key strings repeat across every entry in
every packet. Single-character keys are a real fraction of the total payload size at
30 Hz. They are a **wire format**: renaming a key breaks every peer that has not
shipped the same change simultaneously. Maintainer instruction: do not rename them without
bumping `NRProtocol.WIRE_VERSION`, see [Protocol version](#protocol-version).

### Common fields (every entity)

| Key | Type | Units | Meaning |
|---|---|---|---|
| `"id"` | int | none | `unique_id` of the game object; stable for the life of the match |
| `"px"` | float | pixels | World-space X position |
| `"py"` | float | pixels | World-space Y position |
| `"vx"` | float | pixels/s | X velocity |
| `"vy"` | float | pixels/s | Y velocity |
| `"rot"` | float | radians | Rotation |

### Ship-only fields

These are only present when the entry was built for a `Ship` (`is_ship = true`).

| Key | Type | Units | Meaning |
|---|---|---|---|
| `"h"` | float | none | Current health |
| `"s"` | float | none | Current shield |
| `"w"` | int | none | `NRTypes.WeaponType` enum value of the active primary weapon |
| `"b"` | Dictionary | none | Buff state from `Ship.buff_state()`; contents vary by active buffs |

**Why `"h"`, `"s"`, `"w"`, `"b"` are present.** Damage is resolved on the host for
every ship, including the local player's. If health and shield were omitted, a
client's local prediction would diverge permanently after any hit.  `"w"` and `"b"`
change how a ship moves and whether it can be hit, so clients need them to predict
correctly for the duration of a pickup or buff.

### What is deliberately not sent

- **Projectile positions** are not in the snapshot. Each projectile is announced once
  with `_receive_projectile_spawned` (position, velocity, shot spec) and each client
  predicts its motion locally until `_receive_projectile_detonated` arrives. A missed
  spawn message is noticeable; a missed position update is not.
- **Power-up positions** are sent on spawn; power-ups do not move.
- **Input state** is not echoed in the snapshot. The host reads input from
  `_receive_ship_input` and applies it to the authoritative simulation; clients see the
  result as the ship's position and velocity in the next snapshot.
- **Score** is carried by `_receive_score_updated` on change, not repeated every tick.
- **Match clock** rides `_receive_match_clock` on its own unreliable channel.

### Snapshot reconciliation

On a **non-authority client**, `WorldNetworkSync._on_world_snapshot_received()`:

1. Discards out-of-order frames (`frame <= last_world_data_frame`).
2. For each entry, lerps the object toward the host's reported position and velocity
   using `SNAPSHOT_LERP` (0.35).
3. For the **local ship**, calls `_reconcile_local_ship()` instead: the lerp factor is
   `LOCAL_SNAPSHOT_LERP` (0.12) to avoid rubber-banding, and if the positional error
   exceeds `LOCAL_SNAPSHOT_SNAP_DISTANCE` (250 px) the host's state is taken outright.
4. Takes health (`"h"`), shield (`"s"`), weapon (`"w"`) and buff state (`"b"`) verbatim
   for every ship, because damage is resolved on the host.

The host's `broadcast_snapshot()` is a no-op on clients; it is called only on the
authority.

---

## Match-created payload

Sent once per match by `World._build_match_created_payload()` via
`_receive_match_created`. Clients use it to construct the world before the start
countdown.

```
{
  "width":  <int>,          # world bounding-box width in pixels
  "height": <int>,          # world bounding-box height in pixels

  "asteroids": [
    {
      "id":        <int>,   # unique_id
      "size":      <int>,   # NRTypes.AsteroidSize enum
      "variation": <int>,   # visual variant index
      "px": <float>, "py": <float>,
      "vx": <float>, "vy": <float>,
      "rot": <float>
    },
    …
  ],

  "ships": [
    {
      "id":       <int>,    # unique_id of the Ship node
      "peer_id":  <int>,    # owning Godot peer id
      "entity_id": <str>,   # PlayFab entity id (Party-authenticated on the host)
      "color_id": <int>,    # index into the player-color palette
      "style_id": <int>,    # ship style variant index
      "px": <float>, "py": <float>,
      "rot": <float>
    },
    …
  ],

  "power_ups": [
    { "id": <int> },        # unique_id of the PowerUp pool node; type assigned at spawn
    …
  ]
}
```

**Notes:**

- The `power_ups` list carries only IDs. Which pickup a body represents is decided
  at spawn time and travels with `_receive_power_up_spawned`, so the match-created
  payload does not need to be rebuilt when the drop table changes.
- Ship velocities are not included; ships start from rest and are reset to spawn points
  in the subsequent `_receive_match_starting` message.
- A client that receives `_receive_match_created` while a world already exists ignores
  it (the barrier non-null guard in `World.apply_match_created()`), preventing double-build.

---

## Shot spec (projectile spawn payload)

Each `_receive_projectile_spawned` message carries a `"spec"` sub-dictionary built by
`WeaponDefinition.to_shot_spec()`. Clients use it to render and predict the shot; the
host uses its own copy and clients never consult the weapon table for a received
projectile.

Two-character keys, for the same reason as snapshot keys: the scatter-class weapons
send eight shots at once, so these keys repeat eight times per volley.

| Key | Meaning |
|---|---|
| `"ds"` | Damage scale (relative to base projectile) |
| `"ss"` | Speed scale |
| `"rs"` | Range scale (scales lifetime, which determines range) |
| `"xs"` | Radius scale |
| `"sp"` | Splash radius in pixels; -1 inherits from projectile tuning, 0 disables |
| `"pc"` | Pierce count (extra bodies the shot passes through) |
| `"bn"` | Bounce count (reflections off the barrier) |
| `"hm"` | Homing rate in radians/s; 0 = straight shot |
| `"gs"` | Sprite scale |
| `"lr"` | Point-light radius in pixels; 0 = light off |
| `"le"` | Point-light energy |
| `"c"` | Shot color packed as `Color.to_rgba32()`; zero alpha = use firing player's color |

---

## Reliability tiers

| Tier | Godot mode | Used for |
|---|---|---|
| **Reliable** | `"reliable"` | Any message a peer must observe exactly once: roster changes, spawns, detonations, match state transitions, scores. A missed reliable message leaves the peer in a permanently wrong state. |
| **Unreliable ordered** | `"unreliable_ordered"` | Per-frame state that is superseded by the next message: world snapshots, ship input, match clock. An out-of-order delivery is discarded; a dropped packet is invisible because the next one arrives soon. |
| **Unreliable** | `"unreliable"` | Local FX/audio events (`_receive_gameplay_event`). A missed explosion sound or particle cue is imperceptible; ordering does not matter because the events are positional and self-contained. |

The reasoning behind the tier assignment: the cost of a missed *reliable* delivery is
far higher than the cost of a missed *unreliable* delivery. The match clock and the
world snapshot are the performance-sensitive paths, and both are tolerable under loss
because they are continuous streams. Everything that cannot be reconstructed from the
next message uses `"reliable"`.

---

## Authority rules

**What the host decides:**
- Damage, health and shield for every ship.
- Whether a projectile detonates and what it hits.
- Asteroid splits: which fragments spawn, at what positions and velocities.
- Score increments.
- Power-up spawns, assignments and collections.
- Ship spawns and respawns.
- World dimensions and initial positions.

**What a client may assert:**
- Its own input (movement vector, fire direction, mine-deploy flag). The host applies
  this to its simulation; clients predict locally but are corrected by snapshots.
- Its own `PlayerState` on join (`_submit_player_identity`): display name, XUID,
  preferred color, ship style. The host validates color uniqueness and overwrites
  `entity_id` with Party's authenticated key.

**What the host validates rather than trusts:**
- **`entity_id`** in the submitted `PlayerState` is discarded. The host overwrites it
  with the entity key Party authenticated for that peer. A client cannot present
  another player's entity id.
- **Color** in the submitted `PlayerState` may be reassigned if it collides with an
  existing player's color.
- **Input magnitude** is clamped by `ShipInput.update_remote_input()`. A non-finite
  vector is dropped entirely (it would propagate NaN into the simulation).
- **Input sequence** is compared against the last received; stale or replayed input is
  ignored.
- **The sender of an input packet** is cross-checked. Each packet names the peer that
  sent it, and the host drops it unless that matches `get_remote_sender_id()`. The
  claim is a checksum on the transport, never a credential: a client that names
  another peer only silences itself, while a packet the transport mis-attributes is
  dropped instead of steering somebody else's ship. Dropped packets are counted and
  reported by `NetManager._note_misattributed_input()`.
- **XUID** (`PlayerState.xbox_user_id`) is a *claim*, not a credential. It travels
  over the game's own RPC and nothing about the transport vouches for it. The host
  does not validate it inline; `ProfileService` checks it separately by asking PlayFab
  which entity owns the claimed XUID and comparing that against the Party-authenticated
  entity id for the same peer. Anything reading `xbox_user_id` directly is reading an
  unverified value, acceptable for recent-player reporting, not acceptable as a
  security boundary.
- **Remote input is aged out** after `ShipInput.REMOTE_INPUT_TIMEOUT` (1 second) of
  silence, so a stalled or disconnected client's ship does not keep thrusting
  indefinitely.

---

## Input message

Sent by clients to the host at `NRConst.INPUT_SEND_HZ` (60 Hz, matching the physics
tick rate) via `_receive_ship_input`, plus immediately on a mine deploy (a single-frame
edge).

Input travels on an unreliable channel. The full state is resent every interval
rather than only on change: a single dropped packet would otherwise leave the host
steering the ship with the last known state indefinitely.

| Field | Type | Meaning |
|---|---|---|
| `movement` | Vector2 | Normalized (or digital) movement direction; magnitude ≤ `MAX_INPUT_MAGNITUDE` (4.0) |
| `fire` | Vector2 | Aim direction; same magnitude bound |
| `deploy_mine` | bool | True on the frame the player pressed the mine key |
| `sequence` | int | Monotonically increasing; host discards lower-sequence packets |

The host short-circuits its own input through the same `ship_input_received` signal
the RPC raises, so the simulation has one code path for local and remote players.
