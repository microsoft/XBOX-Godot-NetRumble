class_name NRConst
extends RefCounted

## Global, non-designer-facing constants: world size, network cadence and match flow.
##
## Per-entity tuning (ship, asteroid, projectile, power-up stats) now lives in the
## Resources under `scripts/gameplay/tuning/`, instanced as `.tres` in `assets/tuning/`
## so it can be edited in the inspector. Values here are ones that describe the
## simulation itself rather than how any single entity feels.

# --- Pickups ---------------------------------------------------------------
## Seconds between drops at the extremes of the Power-Up Frequency setting. There are
## thirty-two pickups now, so the pacing is a player setting rather than a constant,
## running from a sparse drop a minute to a deliberately chaotic one every five seconds.
const POWER_UP_SPAWN_TIMER_MIN := 5.0
const POWER_UP_SPAWN_TIMER_MAX := 60.0
## How many pickups may be live simultaneously, at those same extremes. The cap moves
## with the drop rate because the two describe the same thing from opposite ends: a
## drop a minute would never reach a high cap anyway, and a drop every five seconds
## needs the headroom or the field saturates and the timer idles.
const MAX_ACTIVE_POWER_UPS_MIN := 2
const MAX_ACTIVE_POWER_UPS_MAX := 20
## Size of the pickup pool. Comfortably above MAX_ACTIVE_POWER_UPS_MAX so a collection
## and a spawn landing in the same frame always have a free body to work with.
const POWER_UP_POOL_SIZE := 24


## Seconds between drops for a normalised (0..1) Power-Up Frequency setting. The
## setting reads as "frequency", so 1.0 is the *shortest* interval and the mapping
## runs backwards down the range.
static func power_up_spawn_interval(frequency: float) -> float:
	return lerpf(POWER_UP_SPAWN_TIMER_MAX, POWER_UP_SPAWN_TIMER_MIN, clampf(frequency, 0.0, 1.0))


## How many pickups may be uncollected at once for a normalised (0..1) setting.
static func max_active_power_ups(frequency: float) -> int:
	return roundi(lerpf(
		float(MAX_ACTIVE_POWER_UPS_MIN), float(MAX_ACTIVE_POWER_UPS_MAX), clampf(frequency, 0.0, 1.0)))

# --- Barrier ---------------------------------------------------------------
## Uniform scale applied to the barrier wall and end-cap sprites.
const BARRIER_END_SCALE := 1.65
const BARRIER_ROTATION_SPEED := 0.5

# --- World -----------------------------------------------------------------
const DOUBLE_LASER_OFFSET := 8.0
const TRIPLE_LASER_SPREAD := deg_to_rad(2.5)
const MINE_SPAWN_DISTANCE := 8.0
const SPEED_DAMAGE_RATIO := 0.5
const FIND_SPAWN_POINT_ATTEMPTS := 25
## Sized for the worst case across all twenty weapons: the volley weapons put eight or
## twelve shots in the air per trigger pull, and a fully-wound vulcan keeps roughly
## fifty of its own alive at once. Running the pool dry is silent (the shot simply
## never appears), so it is sized conservatively.
const MAX_LASERS_PER_PLAYER := 140
const MAX_MINES_PER_PLAYER := 8
const MAX_ROCKETS_PER_PLAYER := 10

# --- Match flow ------------------------------------------------------------
## Rocks break apart rather than being indestructible scenery, so every one of these
## is a seed that multiplies into several generations of fragments. The starting count
## is deliberately low for that reason.
const ASTEROID_COUNT := 12
## Hard ceiling on live asteroids. A HUGE rock yields split_count^4 fragments, so
## without a cap a field of large rocks can multiply into thousands of bodies and
## bury the physics server. Splits past the cap destroy the rock without fragments.
const MAX_ASTEROIDS := 96
const WORLD_WIDTH := 2400
const WORLD_HEIGHT := 2400
## Grace period for every player to finish loading before the match proceeds.
const SIMULATION_DELAY_PLAYERS_LOADING := 60.0
## Single countdown after the world is laid out and before the match goes live.
const SIMULATION_DELAY_STARTING := 5.0
const SHIP_RESPAWN_DELAY := 5.0

# --- Networking ------------------------------------------------------------
## Host broadcasts an authoritative world snapshot at this rate, giving clients
## enough correction ticks to keep remote objects smooth without saturating the
## connection with full-world payloads.
const WORLD_SNAPSHOT_HZ := 30.0
## Host broadcasts the authoritative match clock at this rate so client HUD timers
## stay locked to it.
const MATCH_CLOCK_HZ := 2.0
## Clients push their input to the host at this rate. Matched to the physics tick rate
## so the host has a fresh sample for every simulation step instead of reusing one
## sample across two: an input packet is a few dozen bytes, which is noise beside the
## world snapshot, and halving the interval halves the latency the batching itself adds
## (on average half an interval). Dispatch runs from _physics_process, so raising this
## above physics/common/physics_ticks_per_second buys nothing.
const INPUT_SEND_HZ := 60.0
## Backstop for a typed-code join whose PlayFab/Party async call never resumes. A real
## join now does one FindLobbies round trip, one JoinLobby round trip, up to
## LOBBY_PROPERTY_TIMEOUT (20s) for descriptor replication, then the chat-control and
## Party-network joins; 45 seconds leaves roughly 25 seconds for those service calls
## without replacing the fast "no match found" path for a typo.
const JOIN_CODE_TIMEOUT_SECONDS := 45.0

# --- Practice mode ---------------------------------------------------------
## Ceiling on AI opponents in a practice match. The lobby roster draws eight slots,
## one of which is the local player.
##
## Lives here rather than on NetManager because PlayerProfile clamps the saved setting
## while it loads, and PlayerProfile is autoloaded *before* NetManager -- reaching for
## the autoload that early would fail. NRConst is a plain class with no such ordering.
const MAX_PRACTICE_BOTS := 7
