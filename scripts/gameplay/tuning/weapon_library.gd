class_name WeaponLibrary
extends RefCounted

## The twenty-entry weapon table.
##
## Held in code rather than as twenty `.tres` files. Weapons are balanced against
## each other, so having the whole set side by side in one screenful is worth more
## than per-weapon inspector editing, and it keeps `assets/tuning/` from filling up
## with near-identical resources. The `.tres` files that remain -- the projectile and
## ship tunings -- describe *bodies*, which is a different thing: a weapon only ever
## says how those bodies differ for this trigger pull.
##
## The first four entries (LASER, DOUBLE_LASER, TRIPLE_LASER, ROCKET) establish the
## baseline feel of the game and are deliberately close to how those weapons have
## always played. The remaining sixteen are new additions that use the same three
## projectile bodies (laser, mine, rocket) but vary their parameters to produce
## entirely different behaviours.
##
## Balance shape: everything is paid for with ammo. Pickups drop constantly, so
## an exotic weapon is a burst of a few seconds rather than a permanent upgrade, and
## running dry drops the ship back to the unlimited laser instead of leaving it
## unarmed.

## Perpendicular spacing used by the double laser and inherited by the other
## wing-mounted weapons. Matches NRConst.DOUBLE_LASER_OFFSET (10.0).
const WING_SPACING := 10.0

static var _table: Dictionary = {}


## Returns the definition for a weapon, falling back to the plain laser so an
## unrecognised value can never leave a ship unable to shoot.
static func get_definition(weapon: NRTypes.WeaponType) -> WeaponDefinition:
	if _table.is_empty():
		_build_table()
	return _table.get(weapon, _table[NRTypes.WeaponType.LASER]) as WeaponDefinition


static func all_definitions() -> Array:
	if _table.is_empty():
		_build_table()
	return _table.values()


static func display_name(weapon: NRTypes.WeaponType) -> String:
	return get_definition(weapon).display_name


static func _build_table() -> void:
	# --- The four baseline weapons -------------------------------------------
	_add({
		"weapon_type": NRTypes.WeaponType.LASER,
		"display_name": "LASER",
		"fire_rate": 0.15,
	})
	_add({
		"weapon_type": NRTypes.WeaponType.DOUBLE_LASER,
		"display_name": "DOUBLE LASER",
		"shot_count": 2,
		"lateral_spacing": WING_SPACING,
		"fire_rate": 0.15,
	})
	_add({
		"weapon_type": NRTypes.WeaponType.TRIPLE_LASER,
		"display_name": "TRIPLE LASER",
		"shot_count": 3,
		"spread": 0.4,
		"fire_rate": 0.3,
	})
	_add({
		"weapon_type": NRTypes.WeaponType.ROCKET,
		"display_name": "ROCKET",
		"projectile_type": NRTypes.ProjectileType.ROCKET,
		"fire_rate": 0.5,
		"light_radius": 160.0,
		"light_energy": 1.6,
	})

	# --- Multi-shot kinetics --------------------------------------------------
	_add({
		"weapon_type": NRTypes.WeaponType.QUAD_LASER,
		"display_name": "QUAD LASER",
		"shot_count": 4,
		"spread": 0.16,
		"lateral_spacing": WING_SPACING * 1.6,
		"fire_rate": 0.2,
		"damage_scale": 0.8,
		"ammo": 40,
		"shot_color": Color(0.6, 0.95, 1.0),
	})
	_add({
		"weapon_type": NRTypes.WeaponType.SPREAD_SHOT,
		"display_name": "SPREAD SHOT",
		"shot_count": 5,
		"spread": 0.9,
		"fire_rate": 0.28,
		"damage_scale": 0.7,
		"range_scale": 0.7,
		"ammo": 35,
		"shot_color": Color(1.0, 0.85, 0.4),
	})
	_add({
		"weapon_type": NRTypes.WeaponType.SCATTER_GUN,
		"display_name": "SCATTER GUN",
		"shot_count": 8,
		"spread": 1.1,
		"spread_jitter": 0.12,
		"fire_rate": 0.4,
		"damage_scale": 0.45,
		"speed_scale": 0.85,
		# Short-range by design: the shots expire in a fifth of a second, so the
		# cloud only reaches a few hundred pixels and the pool recovers quickly
		# enough to survive an eight-shot volley every 0.4s.
		"range_scale": 0.06,
		"ammo": 30,
		"shot_color": Color(1.0, 0.6, 0.25),
	})
	_add({
		"weapon_type": NRTypes.WeaponType.SHOTGUN_BLAST,
		"display_name": "SHOTGUN",
		"shot_count": 7,
		"spread": 0.55,
		"spread_jitter": 0.09,
		"fire_rate": 0.55,
		"damage_scale": 0.8,
		"speed_scale": 1.1,
		"range_scale": 0.12,
		"ammo": 24,
		"sprite_scale": 1.3,
		"shot_color": Color(1.0, 0.45, 0.35),
	})
	_add({
		"weapon_type": NRTypes.WeaponType.VULCAN,
		"display_name": "VULCAN",
		"shot_count": 1,
		"spread_jitter": 0.07,
		"lateral_spacing": WING_SPACING,
		# Four times the plain laser's rate of fire, at a third of the damage.
		"fire_rate": 0.04,
		"damage_scale": 0.35,
		"speed_scale": 1.2,
		"range_scale": 0.5,
		"ammo": 160,
		"sprite_scale": 0.8,
		"light_radius": 60.0,
		"shot_color": Color(1.0, 0.95, 0.55),
	})

	# --- Beams ----------------------------------------------------------------
	_add({
		"weapon_type": NRTypes.WeaponType.BEAM_LANCE,
		"display_name": "BEAM LANCE",
		# A beam is a very fast, very short-lived shot that refuses to stop at the
		# first thing it hits. At 4x speed over a tenth of the laser's lifetime it
		# covers roughly 1300px in half a second, which reads on screen as a lance
		# rather than as a bullet -- and no new projectile type is needed for it.
		"speed_scale": 4.0,
		"range_scale": 0.1,
		"damage_scale": 1.4,
		"pierce": 4,
		"fire_rate": 0.35,
		"ammo": 30,
		"sprite_scale": 2.2,
		"light_radius": 140.0,
		"light_energy": 1.8,
		"shot_color": Color(0.55, 1.0, 0.75),
	})
	_add({
		"weapon_type": NRTypes.WeaponType.PULSE_BEAM,
		"display_name": "PULSE BEAM",
		"shot_count": 3,
		"lateral_spacing": WING_SPACING * 0.5,
		"speed_scale": 3.0,
		"range_scale": 0.16,
		"damage_scale": 0.9,
		"pierce": 2,
		"fire_rate": 0.22,
		"ammo": 45,
		"sprite_scale": 1.6,
		"light_radius": 120.0,
		"light_energy": 1.5,
		"shot_color": Color(0.5, 0.8, 1.0),
	})
	_add({
		"weapon_type": NRTypes.WeaponType.RAILGUN,
		"display_name": "RAILGUN",
		"speed_scale": 5.0,
		"range_scale": 0.14,
		"damage_scale": 3.0,
		"pierce": 8,
		"fire_rate": 0.9,
		"ammo": 12,
		"sprite_scale": 2.6,
		"light_radius": 180.0,
		"light_energy": 2.2,
		"shot_color": Color(0.85, 0.7, 1.0),
	})
	_add({
		"weapon_type": NRTypes.WeaponType.CHAIN_LIGHTNING,
		"display_name": "CHAIN LIGHTNING",
		"shot_count": 3,
		"spread": 0.5,
		"spread_jitter": 0.25,
		"speed_scale": 2.2,
		"range_scale": 0.2,
		"damage_scale": 0.6,
		"pierce": 3,
		"fire_rate": 0.18,
		"ammo": 60,
		"sprite_scale": 1.2,
		"light_radius": 110.0,
		"light_energy": 1.7,
		"shot_color": Color(0.7, 0.9, 1.0),
	})

	# --- Guided ---------------------------------------------------------------
	_add({
		"weapon_type": NRTypes.WeaponType.HOMING_MISSILE,
		"display_name": "HOMING MISSILE",
		"projectile_type": NRTypes.ProjectileType.ROCKET,
		"homing_rate": 3.2,
		"speed_scale": 0.8,
		"range_scale": 1.5,
		"fire_rate": 0.7,
		"ammo": 10,
		"light_radius": 170.0,
		"light_energy": 1.8,
		"shot_color": Color(1.0, 0.55, 0.55),
	})
	_add({
		"weapon_type": NRTypes.WeaponType.SWARM_MISSILES,
		"display_name": "SWARM MISSILES",
		"projectile_type": NRTypes.ProjectileType.ROCKET,
		"shot_count": 4,
		"spread": 1.6,
		"spread_jitter": 0.2,
		"homing_rate": 2.4,
		"speed_scale": 0.7,
		"range_scale": 1.4,
		"damage_scale": 0.4,
		"splash_radius": 80.0,
		"fire_rate": 1.1,
		"ammo": 5,
		"sprite_scale": 0.7,
		"light_radius": 120.0,
		"shot_color": Color(1.0, 0.7, 0.4),
	})
	_add({
		"weapon_type": NRTypes.WeaponType.SEEKER_MINES,
		"display_name": "SEEKER MINES",
		"projectile_type": NRTypes.ProjectileType.MINE,
		"shot_count": 3,
		"spread": 2.4,
		"muzzle_offset": 36.0,
		"homing_rate": 0.8,
		"speed_scale": 2.0,
		"range_scale": 0.4,
		"damage_scale": 0.5,
		"fire_rate": 1.4,
		"ammo": 3,
		"light_radius": 140.0,
		"shot_color": Color(1.0, 0.4, 0.7),
	})

	# --- Explosives -----------------------------------------------------------
	_add({
		"weapon_type": NRTypes.WeaponType.PLASMA_CANNON,
		"display_name": "PLASMA CANNON",
		"speed_scale": 0.5,
		"range_scale": 1.4,
		"damage_scale": 2.0,
		"radius_scale": 3.0,
		"splash_radius": 140.0,
		"fire_rate": 0.75,
		"ammo": 14,
		"sprite_scale": 3.2,
		"light_radius": 200.0,
		"light_energy": 2.0,
		"shot_color": Color(0.55, 1.0, 0.55),
	})
	_add({
		"weapon_type": NRTypes.WeaponType.FLAK_BURST,
		"display_name": "FLAK BURST",
		"shot_count": 5,
		"spread": 0.7,
		"spread_jitter": 0.15,
		"speed_scale": 0.8,
		"range_scale": 0.3,
		"damage_scale": 0.5,
		"splash_radius": 90.0,
		"radius_scale": 1.5,
		"fire_rate": 0.5,
		"ammo": 20,
		"sprite_scale": 1.5,
		"light_radius": 120.0,
		"shot_color": Color(1.0, 0.8, 0.3),
	})
	_add({
		"weapon_type": NRTypes.WeaponType.NOVA_BURST,
		"display_name": "NOVA BURST",
		# A full ring: twelve shots across TAU, so the aim direction stops mattering
		# and the weapon becomes a panic button.
		"shot_count": 12,
		"spread": TAU,
		"muzzle_offset": 26.0,
		"range_scale": 0.25,
		"damage_scale": 0.6,
		"speed_scale": 0.7,
		"splash_radius": 60.0,
		"fire_rate": 1.2,
		"ammo": 6,
		"sprite_scale": 1.4,
		"light_radius": 130.0,
		"light_energy": 1.6,
		"shot_color": Color(1.0, 1.0, 0.85),
	})
	_add({
		"weapon_type": NRTypes.WeaponType.RICOCHET_GUN,
		"display_name": "RICOCHET GUN",
		"shot_count": 2,
		"lateral_spacing": WING_SPACING * 1.2,
		"bounces": 4,
		"range_scale": 2.0,
		"damage_scale": 0.9,
		"fire_rate": 0.3,
		"ammo": 40,
		"sprite_scale": 1.2,
		"shot_color": Color(0.8, 1.0, 0.4),
	})


## Builds one definition from a sparse dictionary, leaving unlisted fields at their
## `WeaponDefinition` defaults. Written this way so each table row states only what
## makes that weapon different.
static func _add(fields: Dictionary) -> void:
	var definition := WeaponDefinition.new()
	for key in fields:
		definition.set(key, fields[key])
	_table[definition.weapon_type] = definition
