class_name NRTypes
extends RefCounted

## Shared enumerations used across the entire gameplay simulation.
##
## Centralised here so the network layer, simulation, UI, and AI all speak the same
## vocabulary and ordinal values stay stable across builds. Enumerators that ride the
## network as integer ordinals are ordered and contiguous; adding new values must
## always append rather than insert, to avoid breaking saves or wire messages.

enum GameObjectType {
	ASTEROID,
	POWER_UP,
	PROJECTILE,
	SHIP,
	UNKNOWN,
}

## Twenty weapons, listed in the order they are encoded on the wire and in save data.
## The first four — Laser, DoubleLaser, TripleLaser, Rocket — are the baseline weapons
## all ships start with and the ones the netcode refers to by ordinal, so they are
## pinned at the head of the list. The remaining sixteen are extended weapons available
## only as pickups.
##
## The list is deliberately flat rather than a "family plus modifier" scheme: every
## weapon is one entry in WeaponLibrary describing how many shots it fires, how they
## are spread, and what each one does. Adding a weapon means adding an enumerator and
## a table row, and nothing else in the simulation has to know about it.
enum WeaponType {
	LASER,
	DOUBLE_LASER,
	TRIPLE_LASER,
	ROCKET,
	QUAD_LASER,
	SPREAD_SHOT,
	SCATTER_GUN,
	BEAM_LANCE,
	PULSE_BEAM,
	HOMING_MISSILE,
	SWARM_MISSILES,
	PLASMA_CANNON,
	RAILGUN,
	SHOTGUN_BLAST,
	FLAK_BURST,
	RICOCHET_GUN,
	CHAIN_LIGHTNING,
	VULCAN,
	NOVA_BURST,
	SEEKER_MINES,
}

## Everything a pickup can be. Weapon pickups grant a WeaponType, buff pickups grant a
## timed BuffType, and restore pickups top the collector back up on the spot.
##
## The first three enumerators — DoubleLaser, TripleLaser, Rocket — are pinned at the
## head so their ordinals, which ride the network as ints, remain stable. All other
## pickup types follow in order of addition.
enum PowerUpType {
	DOUBLE_LASER,
	TRIPLE_LASER,
	ROCKET,
	QUAD_LASER,
	SPREAD_SHOT,
	SCATTER_GUN,
	BEAM_LANCE,
	PULSE_BEAM,
	HOMING_MISSILE,
	SWARM_MISSILES,
	PLASMA_CANNON,
	RAILGUN,
	SHOTGUN_BLAST,
	FLAK_BURST,
	RICOCHET_GUN,
	CHAIN_LIGHTNING,
	VULCAN,
	NOVA_BURST,
	SEEKER_MINES,
	LASER_REFIT,
	BUFF_RAPID_FIRE,
	BUFF_AFTERBURNER,
	BUFF_CLOAK,
	BUFF_DOUBLE_DAMAGE,
	BUFF_OVERSHIELD,
	BUFF_REGENERATION,
	BUFF_QUICK_CHARGE,
	BUFF_MULTI_SHOT,
	BUFF_RICOCHET,
	BUFF_VAMPIRIC,
	RESTORE_SHIELD,
	RESTORE_HULL,
}

## What collecting a pickup actually does. Stored on the definition rather than
## inferred from the enumerator, so the three groups can be reordered freely.
enum PickupKind {
	WEAPON,
	BUFF,
	RESTORE,
}

## Timed ship modifiers. Values are used as dictionary keys on Ship and ride the
## network as ints, so they are ordered and contiguous.
enum BuffType {
	RAPID_FIRE,
	AFTERBURNER,
	CLOAK,
	DOUBLE_DAMAGE,
	OVERSHIELD,
	REGENERATION,
	QUICK_CHARGE,
	MULTI_SHOT,
	RICOCHET,
	VAMPIRIC,
}

enum ProjectileType {
	LASER,
	MINE,
	ROCKET,
}

## Asteroid size tiers, smallest first. Five tiers let a large rock break down through
## several visibly different generations before the last fragment is destroyed outright.
## Values are ordered and contiguous, and code relies on that: a split spawns the tier
## at `size - 1`, and TINY is the terminal tier.
enum AsteroidSize {
	TINY,
	SMALL,
	MEDIUM,
	LARGE,
	HUGE,
}

## Bit flags. WAITING and PLAYABLE are composite masks, so always test membership
## with `has_match_state()` rather than `==`.
enum MatchState {
	LOADING = 0,
	PLAYERS_JOINING = 1,
	## Kept for the WAITING mask. The match flow goes straight from PLAYERS_JOINING
	## to STARTING so players are placed only once; WARMING_UP is never entered but
	## its bit value must stay fixed because it is part of the wire protocol.
	WARMING_UP = 2,
	STARTING = 8,
	RUNNING = 16,
	MATCH_COMPLETE = 32,
	WAITING = 3,
	PLAYABLE = 19,
}

## Replicated to every peer as an int and stored in the PlayFab lobby's search
## attributes, so these are wire values: adding a mode must append, never insert.
enum GameModeType {
	DEATHMATCH,
}

enum GameplayEventType {
	LASER_FIRED,
	LASER_IMPACT,
	SHIP_SPAWNED,
	SHIP_DESTROYED,
	MINE_DETONATED,
	ROCKET_FIRED,
	ROCKET_TRAIL,
	ROCKET_DETONATED,
	POWER_UP_SPAWNED,
	POWER_UP_COLLECTED,
	ASTEROID_IMPACT,
	BUFF_COLLECTED,
	RESTORE_COLLECTED,
}

enum ShipType {
	SHIP0,
	SHIP1,
	SHIP2,
	SHIP3,
}


## MatchState values are flags; `WAITING` and `PLAYABLE` are composite masks.
static func has_match_state(value: MatchState, mask: MatchState) -> bool:
	if mask == MatchState.LOADING:
		return value == MatchState.LOADING
	return (int(value) & int(mask)) != 0
