class_name PickupLibrary
extends RefCounted

## The thirty-two-entry pickup table: twenty weapons, ten buffs and two restores.
##
## Like `WeaponLibrary` this lives in code rather than in `assets/tuning/`. Thirty-two
## `.tres` files would each be a dozen lines of near-identical boilerplate, and the
## drop table has to be balanced as a whole -- which is far easier to do when every
## row and every spawn weight is visible at once.
##
## Weapon pickups are simply mirrored off `WeaponLibrary`: their display name comes
## from the weapon they grant, so retuning or renaming a weapon does not leave a
## stale pickup behind. Only their colour and label are stated here.

## Textures the pickups are drawn from. There are three, and thirty-two pickups, so
## the silhouette indicates the broad family and the tint plus label identifies the
## individual pickup.
const TEXTURE_WEAPON := "PowerUp_DoubleLaser"
const TEXTURE_ORDNANCE := "PowerUp_Rocket"
const TEXTURE_SUPPORT := "PowerUp_TripleLaser"

static var _table: Dictionary = {}
static var _weighted_types: Array[int] = []


static func get_definition(type: NRTypes.PowerUpType) -> PowerUpDefinition:
	if _table.is_empty():
		_build_table()
	return _table.get(type, _table[NRTypes.PowerUpType.DOUBLE_LASER]) as PowerUpDefinition


static func all_types() -> Array:
	if _table.is_empty():
		_build_table()
	return _table.keys()


## Picks a pickup honouring `spawn_weight`.
##
## The weights are expanded once into a flat array of repeated enumerators rather than
## being summed and searched on every draw. Drops are frequent now -- one every second
## or two, for the whole match -- so the draw happens often enough to be worth making
## a single array index, and the table is small enough that the expansion costs
## nothing.
static func random_type() -> NRTypes.PowerUpType:
	if _weighted_types.is_empty():
		_build_table()
	return _weighted_types[randi() % _weighted_types.size()] as NRTypes.PowerUpType


static func _build_table() -> void:
	_table.clear()
	_weighted_types.clear()

	# --- Weapon pickups -------------------------------------------------------
	# One per weapon, including a "laser refit" so a player who wants to dump an
	# awkward exotic can pick their way back to the reliable default.
	_add_weapon(NRTypes.PowerUpType.LASER_REFIT, NRTypes.WeaponType.LASER,
		Color(0.85, 0.9, 1.0), "LSR", TEXTURE_WEAPON, 0.6)
	_add_weapon(NRTypes.PowerUpType.DOUBLE_LASER, NRTypes.WeaponType.DOUBLE_LASER,
		Color(0.6, 0.85, 1.0), "II", TEXTURE_WEAPON, 1.6)
	_add_weapon(NRTypes.PowerUpType.TRIPLE_LASER, NRTypes.WeaponType.TRIPLE_LASER,
		Color(0.5, 1.0, 0.9), "III", TEXTURE_SUPPORT, 1.4)
	_add_weapon(NRTypes.PowerUpType.QUAD_LASER, NRTypes.WeaponType.QUAD_LASER,
		Color(0.6, 0.95, 1.0), "IV", TEXTURE_WEAPON, 1.2)
	_add_weapon(NRTypes.PowerUpType.SPREAD_SHOT, NRTypes.WeaponType.SPREAD_SHOT,
		Color(1.0, 0.85, 0.4), "SPR", TEXTURE_SUPPORT, 1.2)
	_add_weapon(NRTypes.PowerUpType.SCATTER_GUN, NRTypes.WeaponType.SCATTER_GUN,
		Color(1.0, 0.6, 0.25), "SCT", TEXTURE_SUPPORT, 1.0)
	_add_weapon(NRTypes.PowerUpType.SHOTGUN_BLAST, NRTypes.WeaponType.SHOTGUN_BLAST,
		Color(1.0, 0.45, 0.35), "SHT", TEXTURE_SUPPORT, 1.0)
	_add_weapon(NRTypes.PowerUpType.VULCAN, NRTypes.WeaponType.VULCAN,
		Color(1.0, 0.95, 0.55), "VUL", TEXTURE_WEAPON, 1.0)
	_add_weapon(NRTypes.PowerUpType.BEAM_LANCE, NRTypes.WeaponType.BEAM_LANCE,
		Color(0.55, 1.0, 0.75), "BEA", TEXTURE_WEAPON, 0.9)
	_add_weapon(NRTypes.PowerUpType.PULSE_BEAM, NRTypes.WeaponType.PULSE_BEAM,
		Color(0.5, 0.8, 1.0), "PLS", TEXTURE_WEAPON, 0.9)
	_add_weapon(NRTypes.PowerUpType.RAILGUN, NRTypes.WeaponType.RAILGUN,
		Color(0.85, 0.7, 1.0), "RAI", TEXTURE_WEAPON, 0.6)
	_add_weapon(NRTypes.PowerUpType.CHAIN_LIGHTNING, NRTypes.WeaponType.CHAIN_LIGHTNING,
		Color(0.7, 0.9, 1.0), "CHN", TEXTURE_WEAPON, 0.9)
	_add_weapon(NRTypes.PowerUpType.ROCKET, NRTypes.WeaponType.ROCKET,
		Color(1.0, 0.5, 0.35), "RKT", TEXTURE_ORDNANCE, 1.2)
	_add_weapon(NRTypes.PowerUpType.HOMING_MISSILE, NRTypes.WeaponType.HOMING_MISSILE,
		Color(1.0, 0.55, 0.55), "HOM", TEXTURE_ORDNANCE, 0.8)
	_add_weapon(NRTypes.PowerUpType.SWARM_MISSILES, NRTypes.WeaponType.SWARM_MISSILES,
		Color(1.0, 0.7, 0.4), "SWM", TEXTURE_ORDNANCE, 0.7)
	_add_weapon(NRTypes.PowerUpType.SEEKER_MINES, NRTypes.WeaponType.SEEKER_MINES,
		Color(1.0, 0.4, 0.7), "SKR", TEXTURE_ORDNANCE, 0.7)
	_add_weapon(NRTypes.PowerUpType.PLASMA_CANNON, NRTypes.WeaponType.PLASMA_CANNON,
		Color(0.55, 1.0, 0.55), "PLA", TEXTURE_ORDNANCE, 0.8)
	_add_weapon(NRTypes.PowerUpType.FLAK_BURST, NRTypes.WeaponType.FLAK_BURST,
		Color(1.0, 0.8, 0.3), "FLK", TEXTURE_ORDNANCE, 0.9)
	_add_weapon(NRTypes.PowerUpType.NOVA_BURST, NRTypes.WeaponType.NOVA_BURST,
		Color(1.0, 1.0, 0.85), "NVA", TEXTURE_ORDNANCE, 0.6)
	_add_weapon(NRTypes.PowerUpType.RICOCHET_GUN, NRTypes.WeaponType.RICOCHET_GUN,
		Color(0.8, 1.0, 0.4), "RIC", TEXTURE_WEAPON, 0.9)

	# --- Buffs ----------------------------------------------------------------
	# Durations are short because drops are frequent: a buff is a window of
	# advantage a player fights to make use of, not a state they settle into.
	_add_buff(NRTypes.PowerUpType.BUFF_RAPID_FIRE, NRTypes.BuffType.RAPID_FIRE,
		"RAPID FIRE", 12.0, Color(1.0, 0.85, 0.2), ">>")
	_add_buff(NRTypes.PowerUpType.BUFF_AFTERBURNER, NRTypes.BuffType.AFTERBURNER,
		"AFTERBURNER", 12.0, Color(0.4, 0.8, 1.0), "^^")
	_add_buff(NRTypes.PowerUpType.BUFF_CLOAK, NRTypes.BuffType.CLOAK,
		"CLOAK", 8.0, Color(0.6, 0.6, 0.8), "()")
	_add_buff(NRTypes.PowerUpType.BUFF_DOUBLE_DAMAGE, NRTypes.BuffType.DOUBLE_DAMAGE,
		"DOUBLE DAMAGE", 12.0, Color(1.0, 0.3, 0.3), "x2")
	_add_buff(NRTypes.PowerUpType.BUFF_OVERSHIELD, NRTypes.BuffType.OVERSHIELD,
		"OVERSHIELD", 15.0, Color(0.4, 1.0, 1.0), "[]")
	_add_buff(NRTypes.PowerUpType.BUFF_REGENERATION, NRTypes.BuffType.REGENERATION,
		"REGENERATION", 15.0, Color(0.4, 1.0, 0.5), "++")
	_add_buff(NRTypes.PowerUpType.BUFF_QUICK_CHARGE, NRTypes.BuffType.QUICK_CHARGE,
		"QUICK CHARGE", 15.0, Color(0.5, 0.9, 1.0), "~~")
	_add_buff(NRTypes.PowerUpType.BUFF_MULTI_SHOT, NRTypes.BuffType.MULTI_SHOT,
		"MULTI SHOT", 12.0, Color(1.0, 0.6, 1.0), "*")
	_add_buff(NRTypes.PowerUpType.BUFF_RICOCHET, NRTypes.BuffType.RICOCHET,
		"RICOCHET", 12.0, Color(0.8, 1.0, 0.4), "/\\")
	_add_buff(NRTypes.PowerUpType.BUFF_VAMPIRIC, NRTypes.BuffType.VAMPIRIC,
		"VAMPIRIC", 12.0, Color(0.9, 0.2, 0.5), "<3")

	# --- Restores -------------------------------------------------------------
	# Weighted heavily: with this much ordnance in the air a match without a steady
	# supply of repairs turns into a respawn queue.
	_add_restore(NRTypes.PowerUpType.RESTORE_SHIELD, "SHIELD BOOST",
		0.0, 100.0, Color(0.35, 0.8, 1.0), "SHL", 3.0)
	_add_restore(NRTypes.PowerUpType.RESTORE_HULL, "HULL REPAIR",
		25.0, 25.0, Color(0.4, 1.0, 0.6), "HUL", 2.5)


static func _add_weapon(type: NRTypes.PowerUpType, weapon: NRTypes.WeaponType,
		tint: Color, label: String, texture_key: String, weight: float) -> void:
	var definition := PowerUpDefinition.new()
	definition.power_up_type = type
	definition.kind = NRTypes.PickupKind.WEAPON
	definition.weapon_granted = weapon
	definition.display_name = WeaponLibrary.display_name(weapon)
	definition.tint = tint
	definition.label = label
	definition.texture = Assets.texture(texture_key)
	definition.spawn_weight = weight
	_register(definition)


static func _add_buff(type: NRTypes.PowerUpType, buff: NRTypes.BuffType,
		display_name: String, duration: float, tint: Color, label: String) -> void:
	var definition := PowerUpDefinition.new()
	definition.power_up_type = type
	definition.kind = NRTypes.PickupKind.BUFF
	definition.buff_granted = buff
	definition.buff_duration = duration
	definition.display_name = display_name
	definition.tint = tint
	definition.label = label
	definition.texture = Assets.texture(TEXTURE_SUPPORT)
	definition.spawn_weight = 1.4
	definition.rotation_speed = -2.5
	_register(definition)


static func _add_restore(type: NRTypes.PowerUpType, display_name: String,
		health: float, shield: float, tint: Color, label: String, weight: float) -> void:
	var definition := PowerUpDefinition.new()
	definition.power_up_type = type
	definition.kind = NRTypes.PickupKind.RESTORE
	definition.restore_health = health
	definition.restore_shield = shield
	definition.display_name = display_name
	definition.tint = tint
	definition.label = label
	definition.texture = Assets.texture(TEXTURE_SUPPORT)
	definition.spawn_weight = weight
	definition.pulse_amplitude = 0.2
	definition.light_radius = 150.0
	_register(definition)


static func _register(definition: PowerUpDefinition) -> void:
	_table[definition.power_up_type] = definition
	# Weights are expressed in tenths so fractional values survive the expansion.
	for i in int(round(definition.spawn_weight * 10.0)):
		_weighted_types.append(int(definition.power_up_type))
