class_name RocketProjectile
extends Projectile

## A homing or straight-flying rocket with a splash-damage explosion on impact.

var _direct_target: GameObject = null
var _trail: CPUParticles2D = null


func _init() -> void:
	object_type = NRTypes.GameObjectType.PROJECTILE
	tuning = preload("res://assets/tuning/rocket_tuning.tres")
	apply_tuning()


func _ready() -> void:
	super()
	_trail = get_node_or_null(^"Trail")
	_sync_trail()


func start() -> void:
	super()
	_direct_target = null
	_sync_trail()


func tick(delta: float) -> void:
	super.tick(delta)
	_sync_trail()


func on_contact(other: GameObject) -> void:
	if not is_active or other == null:
		return
	if other is Ship and other.unique_id == owner_id:
		return
	if other is Projectile and (other as Projectile).owner_id == owner_id:
		return
	if world == null or not world.is_authority:
		return

	_direct_target = other
	other.take_damage(self, damage_amount)
	world.credit_damage_dealt(owner_id, damage_amount)
	die()


func die() -> void:
	if world == null or not world.is_authority:
		return
	_detonate(position, true)


func detonate_from_authority(pos: Vector2) -> void:
	_detonate(pos, false)


func _detonate(pos: Vector2, notify_authority: bool) -> void:
	if not is_active:
		return

	teleport(pos)
	_deactivate()

	if world != null and notify_authority:
		var hits := world.apply_explosion_damage(self, pos, damage_amount, damage_radius, can_damage_owner, _direct_target)
		if _direct_target != null:
			hits.insert(0, world.create_detonation_hit(_direct_target))
		world.notify_projectile_detonated(self, pos, hits)


func _deactivate() -> void:
	super._deactivate()
	_sync_trail()


func _sync_trail() -> void:
	if _trail != null:
		_trail.emitting = is_active
