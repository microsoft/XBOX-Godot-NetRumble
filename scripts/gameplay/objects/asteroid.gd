class_name Asteroid
extends GameObject

## A drifting obstacle. Movement, bouncing off other asteroids, ships and the barrier
## are all handled by the RigidBody2D + PhysicsMaterial authored in asteroid.tscn;
## this script only owns the gameplay consequences.
##
## Rocks take weapon damage and break apart. Each size tier splits into fragments of
## the tier below (see AsteroidTuning.split_size_for) until the TINY tier, which is
## destroyed outright. The split itself is World's job, because spawning entities
## while the world is mid-iteration over `game_objects` is not safe; this script only
## drives health to zero and World's `_detect_split_asteroids` picks it up at the end
## of the tick.

## Designer-tunable stats. Overridable per-instance in the inspector.
@export var tuning: AsteroidTuning = preload("res://assets/tuning/asteroid_tuning.tres")

var asteroid_size: NRTypes.AsteroidSize = NRTypes.AsteroidSize.SMALL
var variation: int = 0
## Unique id of the last object to damage this rock, mirroring the same field on Ship.
## World reads it when the rock breaks apart, to work out whose shot did it.
var last_damaged_by_id: int = 0

var _sprite: Sprite2D = null


func _init() -> void:
	object_type = NRTypes.GameObjectType.ASTEROID


## Authority-side construction: rolls size-derived stats, a random spin, a random
## initial velocity and a random texture variation.
func setup(size: NRTypes.AsteroidSize) -> void:
	unique_id = GameObject.allocate_id()
	_apply_size(size)
	rotation = randf_range(0.0, TAU)
	var initial_velocity := randf_range(tuning.velocity_initial_min, tuning.velocity_initial_max)
	velocity = _random_direction() * initial_velocity
	variation = randi_range(0, 2)


func setup_networked(id: int, size: NRTypes.AsteroidSize, tex_variation: int) -> void:
	unique_id = id
	_apply_size(size)
	variation = tex_variation


## Authority-side construction for a fragment thrown off by a split. The id, tier and
## texture are decided by World so the same values can be replayed on every client.
func setup_fragment(id: int, size: NRTypes.AsteroidSize, tex_variation: int) -> void:
	unique_id = id
	_apply_size(size)
	variation = tex_variation
	rotation = randf_range(0.0, TAU)


func _apply_size(size: NRTypes.AsteroidSize) -> void:
	asteroid_size = size
	radius = tuning.radius_for(size)
	health = radius * tuning.radius_health_ratio
	mass = radius * tuning.radius_mass_ratio
	# Godot applies `v *= 1 - damp * step` per step, producing exponential velocity
	# decay. linear_damp_mode REPLACE applies the tuned rate directly.
	linear_damp_mode = RigidBody2D.DAMP_MODE_REPLACE
	linear_damp = tuning.velocity_decay_rate


## The tier this asteroid breaks into, or -1 when it is the terminal tier and is
## simply destroyed.
func split_size() -> int:
	return AsteroidTuning.split_size_for(asteroid_size)


## Weapon damage. Reaching zero does not act here: World polls for dead asteroids
## once the tick's iteration is finished and performs the split then, because
## spawning fragments (or freeing this body) from inside a contact callback would
## mutate `game_objects` while explosion damage is walking it.
func take_damage(source: GameObject, damage: float) -> void:
	if not is_active or damage <= 0.0 or source == null or health <= 0.0:
		return
	last_damaged_by_id = source.unique_id
	health = maxf(health - damage, 0.0)


## Spin is coupled to speed, so it stays script-driven; linear decay is the body's
## linear_damp.
func tick(delta: float) -> void:
	var velocity_mass_ratio := velocity.length_squared() / mass
	set_facing(rotation + velocity_mass_ratio * tuning.velocity_mass_ratio_to_rotation_scalar * delta)
	super.tick(delta)


func on_contact(other: GameObject) -> void:
	if other is Asteroid:
		_on_contact_asteroid(other as Asteroid)
	elif other is Ship:
		_on_contact_ship(other as Ship)


func _on_contact_asteroid(other: Asteroid) -> void:
	if world != null and other != null and unique_id < other.unique_id:
		world.emit_gameplay_event(NRTypes.GameplayEventType.ASTEROID_IMPACT, position)


## Ramming damage uses the velocities sampled before the physics step, because the
## solver has already exchanged momentum by the time the contact is reported.
func _on_contact_ship(ship: Ship) -> void:
	var to_ship := position - ship.position
	var distance_sq := to_ship.length_squared()
	if distance_sq > 0.0:
		to_ship *= 1.0 / sqrt(distance_sq)
		var asteroid_speed := to_ship.dot(pre_step_velocity)
		var ship_speed := to_ship.dot(ship.pre_step_velocity)
		var ramming_speed := ship_speed - asteroid_speed
		var momentum := mass * ramming_speed
		ship.take_damage(self, momentum * tuning.momentum_damage_scalar)

	if world != null:
		world.emit_gameplay_event(NRTypes.GameplayEventType.ASTEROID_IMPACT, position)


## Texture and scale both follow from the size/variation rolled at spawn, so they are
## set once here rather than recomputed every frame. The sprite is scaled so the
## painted rock lines up with the body's collision radius.
func _build_visuals() -> void:
	_sprite = $Sprite
	_sprite.texture = tuning.texture_for(variation)
	var s := radius / tuning.texture_radius
	_sprite.scale = Vector2(s, s)


func _random_direction() -> Vector2:
	var angle := randf_range(0.0, TAU)
	return Vector2(cos(angle), sin(angle))
