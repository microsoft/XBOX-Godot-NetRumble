class_name MineProjectile
extends Projectile

## A proximity mine: drifts to a stop after launch, then detonates when a ship
## enters its trigger radius.

var _anchored: bool = false
var _detonation_queued: bool = false


func _init() -> void:
	object_type = NRTypes.GameObjectType.PROJECTILE
	tuning = preload("res://assets/tuning/mine_tuning.tres")
	apply_tuning()
	linear_damp_mode = RigidBody2D.DAMP_MODE_REPLACE
	linear_damp = tuning.drag_per_second


func start() -> void:
	super()
	_anchored = false
	_detonation_queued = false


## Drag is the body's linear_damp; this only handles the anchor threshold and spin.
func tick(delta: float) -> void:
	if not _anchored:
		if velocity.length_squared() <= tuning.minimum_velocity_squared:
			_anchored = true
			velocity = Vector2.ZERO
	else:
		velocity = Vector2.ZERO

	set_facing(rotation + tuning.rotation_speed * delta)

	super.tick(delta)


func on_contact(other: GameObject) -> void:
	if not is_active or other == null:
		return
	if other is Ship and other.unique_id == owner_id:
		return
	if other is Ship or other is Asteroid:
		die()


func take_damage(source: GameObject, damage: float) -> void:
	if not is_active or damage <= 0.0:
		return

	if source != null and source.object_type == NRTypes.GameObjectType.PROJECTILE:
		health = maxf(health - damage, 0.0)
	else:
		health = 0.0

	if health <= 0.0:
		if world != null and world.is_authority:
			world.queue_mine_detonation(self)


func die() -> void:
	if world == null or not world.is_authority:
		return
	_detonate(position, true)


func detonate_from_authority(pos: Vector2) -> void:
	_detonate(pos, false)


func detonate_queued() -> void:
	_detonate(position, true)


func try_queue_detonation() -> bool:
	if not is_active or _detonation_queued:
		return false
	_detonation_queued = true
	return true


func _detonate(pos: Vector2, notify_authority: bool) -> void:
	if not is_active:
		return

	teleport(pos)
	_detonation_queued = false
	_deactivate()

	if world != null and notify_authority:
		var hits := world.apply_explosion_damage(self, pos, damage_amount, damage_radius, can_damage_owner, null)
		world.notify_projectile_detonated(self, pos, hits)
