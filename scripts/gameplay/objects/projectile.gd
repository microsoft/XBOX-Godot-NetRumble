class_name Projectile
extends GameObject

## The base class is a laser; RocketProjectile and MineProjectile extend it.
##
## Projectiles have a negligible mass so the solver reports the contact without them
## meaningfully pushing what they hit. A contact that should pass through simply does
## not apply damage; there is no explicit pass-through mechanism.

## Designer-tunable stats. Subclasses swap in their own `.tres` and re-apply it.
@export var tuning: ProjectileTuning = preload("res://assets/tuning/laser_tuning.tres")

var projectile_type: NRTypes.ProjectileType = NRTypes.ProjectileType.LASER
var can_damage_owner: bool = false
var damage_amount: float = 0.0
var damage_radius: float = 0.0
var duration: Timer = null
var owner_id: int = 0
var starting_velocity: float = 0.0

## Per-shot modifiers handed over by the weapon that fired this projectile. Reset to
## the projectile tuning's own values whenever the body is drawn from the pool, so a
## railgun slug recycled as a plain laser does not keep its pierce or its size.
var pierce_remaining: int = 0
var bounces_remaining: int = 0
var homing_rate: float = 0.0

var _duration_scale: float = 1.0
var _sprite_scale: float = 1.0
var _tint_override: Color = Color(0.0, 0.0, 0.0, 0.0)
var _light_radius: float = 0.0
var _light_energy: float = 1.0
## The spec as received, so it can be forwarded verbatim in the spawn message.
var _shot_spec: Dictionary = {}

var _authoritative_hits: Array[Dictionary] = []
## Seconds a client keeps a shot alive past its nominal lifetime while waiting for the
## authority's detonation. Long enough that the host always wins the race in normal
## play, so this only ever retires shots the authority has genuinely stopped tracking.
const CLIENT_EXPIRY_GRACE := 2.0
var _client_expiry_pending: bool = false
var _collision_exceptions: Array[PhysicsBody2D] = []
var _sprite: Sprite2D = null
var _base_sprite_scale: Vector2 = Vector2.ONE
var _light: PointLight2D = null


func _init() -> void:
	object_type = NRTypes.GameObjectType.PROJECTILE
	apply_tuning()


## Re-applied in _ready() so a tuning resource assigned in a scene wins over the
## default that _init() sees.
func _ready() -> void:
	duration = $DurationTimer
	duration.one_shot = true
	duration.process_callback = Timer.TIMER_PROCESS_PHYSICS
	duration.timeout.connect(_on_duration_timeout)
	apply_tuning()
	super()


## Projectiles are simulated bodies so they bounce nothing: a negligible mass lets
## the solver report contacts while transferring no meaningful momentum. The tuning
## `mass` is still used for explosion damage falloff.
const CONTACT_MASS := 0.001


func apply_tuning() -> void:
	projectile_type = tuning.projectile_type
	mass = CONTACT_MASS
	radius = tuning.radius
	starting_velocity = tuning.velocity
	can_damage_owner = tuning.can_damage_owner
	damage_amount = tuning.damage_amount
	damage_radius = tuning.damage_radius


## Restores every stat to the projectile scene's own tuning, discarding whatever the
## last weapon to use this pooled body did to it.
##
## Called on every draw from the pool rather than only when a spec is present,
## because the pool is shared: the plasma cannon and the plain laser take bodies from
## the same array, and a body that kept the cannon's triple radius and 3.2x sprite
## scale would come back as an enormous, slow laser.
func clear_shot_spec() -> void:
	_shot_spec = {}
	apply_tuning()
	pierce_remaining = 0
	bounces_remaining = 0
	homing_rate = 0.0
	_duration_scale = 1.0
	_sprite_scale = 1.0
	_tint_override = Color(0.0, 0.0, 0.0, 0.0)
	_light_radius = 0.0
	_light_energy = 1.0
	_apply_sprite_scale()
	_apply_light()


## Applies the compact per-shot dictionary produced by
## [method WeaponDefinition.to_shot_spec]. Clients call this from the spawn message,
## so both sides end up with identical shots.
func apply_shot_spec(spec: Dictionary) -> void:
	clear_shot_spec()
	if spec.is_empty():
		return
	_shot_spec = spec
	damage_amount = tuning.damage_amount * float(spec.get("ds", 1.0))
	starting_velocity = tuning.velocity * float(spec.get("ss", 1.0))
	_duration_scale = float(spec.get("rs", 1.0))
	radius = tuning.radius * float(spec.get("xs", 1.0))
	var splash := float(spec.get("sp", -1.0))
	damage_radius = tuning.damage_radius if splash < 0.0 else splash
	pierce_remaining = int(spec.get("pc", 0))
	bounces_remaining = int(spec.get("bn", 0))
	homing_rate = float(spec.get("hm", 0.0))
	_sprite_scale = float(spec.get("gs", 1.0))
	_light_radius = float(spec.get("lr", 0.0))
	_light_energy = float(spec.get("le", 1.0))
	var packed_color := int(spec.get("c", 0))
	_tint_override = Color(0.0, 0.0, 0.0, 0.0) if packed_color == 0 else Color.hex(packed_color)
	_apply_sprite_scale()
	_apply_light()
	_update_visuals()


func shot_spec() -> Dictionary:
	return _shot_spec


func start() -> void:
	if duration != null:
		duration.wait_time = maxf(tuning.duration * _duration_scale, 0.02)
		duration.start()
	health = tuning.health
	_client_expiry_pending = false
	_authoritative_hits.clear()


func tick(delta: float) -> void:
	if homing_rate > 0.0:
		_steer_towards_target(delta)
	super.tick(delta)


## Turns the shot towards the nearest ship that is not its owner.
##
## Steering is a capped rotation of the velocity vector rather than a re-aim, so a
## missile keeps its speed and traces a visible arc instead of snapping onto the
## target. Guidance runs on every peer, not just the authority: a client that
## simulated its missiles in a straight line would see them drift away from the
## authority's path and then teleport back on the next correction.
func _steer_towards_target(delta: float) -> void:
	if world == null:
		return
	var target := world.find_nearest_enemy_ship(position, owner_id)
	if target == null:
		return
	var speed := velocity.length()
	if speed <= 0.0:
		return
	var desired := (target.position - position).normalized()
	var current := velocity / speed
	var turn := clampf(current.angle_to(desired), -homing_rate * delta, homing_rate * delta)
	var steered := current.rotated(turn)
	velocity = steered * speed
	set_facing(atan2(steered.x, -steered.y))


func set_owner_and_direction(ship: Ship, direction: Vector2) -> void:
	if ship == null:
		return
	set_owner_ship(ship)
	velocity = direction * starting_velocity
	# Forward is (sin(rot), -cos(rot)), so the facing that points along the travel
	# direction is atan2(x, -y). Anything else leaves the sprite -- and the rocket's
	# exhaust trail, which is emitted out of the body's local -forward -- pointing
	# away from where the projectile is actually going.
	teleport(ship.position, atan2(direction.x, -direction.y))


## Projectiles spawn at the centre of the ship that fired them, i.e. fully inside its
## collider. Gameplay already ignores owner contacts, but the solver does not: it
## depenetrates the overlap, and because a projectile's mass is negligible it absorbs
## the whole correction and is flung off course -- by up to 90 degrees, differently for
## each aim direction. A collision exception keeps the shot out of the solver's hands
## while leaving explosion damage (which is a radius query) untouched.
func set_owner_ship(ship: Ship) -> void:
	_clear_collision_exceptions()
	if ship == null:
		return
	owner_id = ship.unique_id
	exempt_from_collisions(ship)


func exempt_from_collisions(body: PhysicsBody2D) -> void:
	if body == null or body == self or _collision_exceptions.has(body):
		return
	add_collision_exception_with(body)
	_collision_exceptions.append(body)


func _clear_collision_exceptions() -> void:
	for body in _collision_exceptions:
		if is_instance_valid(body):
			remove_collision_exception_with(body)
	_collision_exceptions.clear()


func activate_from_authority(new_owner_id: int, pos: Vector2, vel: Vector2, rot: float, spec: Dictionary = {}) -> void:
	set_owner_ship(world.get_ship_by_id(new_owner_id) if world != null else null)
	owner_id = new_owner_id
	apply_shot_spec(spec)
	teleport(pos, rot)
	velocity = vel
	is_active = true
	start()


func deactivate_from_authority(pos: Vector2) -> void:
	teleport(pos)
	_deactivate()


func on_contact(other: GameObject) -> void:
	if other is Ship:
		_on_contact_ship(other as Ship)
	elif other is Asteroid:
		_on_contact_asteroid(other as Asteroid)
	elif other is Projectile:
		_on_contact_projectile(other as Projectile)


## Projectiles die against the barrier unless the weapon that fired them bought
## bounces.
##
## The barrier is four axis-aligned walls, and `body_entered` does not hand over a
## contact normal, so the wall that was hit is inferred from which side of the world
## the shot has left. That is exact for an axis-aligned box and costs nothing.
func on_wall_contact() -> void:
	if bounces_remaining <= 0 or world == null or world.barrier == null:
		die()
		return
	bounces_remaining -= 1
	var reflected := velocity
	if position.x <= world.barrier.get_left() or position.x >= world.barrier.get_right():
		reflected.x = -reflected.x
	if position.y <= world.barrier.get_top() or position.y >= world.barrier.get_bottom():
		reflected.y = -reflected.y
	if reflected.is_equal_approx(velocity):
		die()
		return
	velocity = reflected
	set_facing(atan2(reflected.x, -reflected.y))


func _on_contact_ship(ship: Ship) -> void:
	if ship != null:
		if ship.unique_id == owner_id:
			return
		if ship.is_untargetable():
			return
		if world != null and world.is_authority:
			ship.take_damage(self, damage_amount)
			world.credit_damage_dealt(owner_id, damage_amount)
			_record_authoritative_hit(ship)
	_consume_hit(ship)


## Asteroids used to be indestructible scenery that shots simply died against. They
## now take damage and break apart, so a hit is recorded the same way a ship hit is:
## the authority applies the damage and the resulting health rides the detonation
## message so clients stay in step until the split itself is announced.
func _on_contact_asteroid(asteroid: Asteroid) -> void:
	if asteroid != null and world != null and world.is_authority:
		asteroid.take_damage(self, damage_amount)
		_record_authoritative_hit(asteroid)
	_consume_hit(asteroid)


func _on_contact_projectile(other: Projectile) -> void:
	if other != null:
		if owner_id == other.owner_id:
			return
		if world != null and world.is_authority:
			other.take_damage(self, damage_amount)
			_record_authoritative_hit(other)
	_consume_hit(other)


## Spends one of the shot's lives on the thing it just hit.
##
## A piercing shot has to stop colliding with what it passed through, or the solver
## keeps handing back the same contact while the two bodies remain overlapped and the
## beam is consumed several times over by a single target.
func _consume_hit(target: GameObject) -> void:
	if pierce_remaining <= 0:
		die()
		return
	pierce_remaining -= 1
	exempt_from_collisions(target)
	if world != null and world.is_authority:
		world.emit_gameplay_event(NRTypes.GameplayEventType.LASER_IMPACT, position)


func take_damage(_source: GameObject, damage: float) -> void:
	if not is_active or damage <= 0.0:
		return
	health = maxf(health - damage, 0.0)
	if health <= 0.0:
		die()


func die() -> void:
	if not is_active or world == null or not world.is_authority:
		return
	var pos := position
	_deactivate()
	world.notify_projectile_detonated(self, pos, _authoritative_hits)
	_authoritative_hits.clear()


func _deactivate() -> void:
	if duration != null:
		duration.stop()
	_clear_collision_exceptions()
	super._deactivate()


func _record_authoritative_hit(obj: GameObject) -> void:
	if world != null and world.is_authority and obj != null:
		_authoritative_hits.append(world.create_detonation_hit(obj))


func _on_duration_timeout() -> void:
	if world != null and not world.is_authority:
		# `die()` is authority-only, so on a client the authority's detonation message
		# is the *only* thing that can retire this body. If that message is lost -- or
		# the host stops tracking the shot while the client keeps flying it -- nothing
		# else ever recycles it and the shot sits on the field for the rest of the
		# match. Wait one grace period past the nominal lifetime, so the authority
		# still wins in normal play, then clean it up locally.
		if not _client_expiry_pending and duration != null:
			_client_expiry_pending = true
			duration.wait_time = CLIENT_EXPIRY_GRACE
			duration.start()
			return
		_client_expiry_pending = false
		is_active = false
		world.retire_orphaned_projectile(self)
		return
	die()


func _build_visuals() -> void:
	_sprite = $Sprite
	if _sprite != null:
		_sprite.rotation = tuning.sprite_rotation
		_base_sprite_scale = _sprite.scale
	_apply_sprite_scale()
	_apply_light()


## Every projectile is tinted with the colour of the ship that fired it, so players
## can tell whose shots are whose. The exotic weapons override that with a colour of
## their own -- with only three projectile textures in the project, colour is the
## only thing distinguishing a plasma bolt from a railgun slug.
func _update_visuals() -> void:
	if _sprite == null:
		return
	var tint := shot_color()
	_sprite.modulate = tint
	if _light != null:
		_light.color = tint
		_light.visible = is_active and _light_radius > 0.0


func shot_color() -> Color:
	if _tint_override.a > 0.0:
		# Blended with the owner's colour rather than replacing it, so a weapon still
		# reads as belonging to a particular player.
		return _tint_override.lerp(owner_color(), 0.35)
	return owner_color()


func owner_color() -> Color:
	if world != null:
		var shooter := world.get_ship_by_id(owner_id)
		if shooter != null:
			return shooter.ship_color
	return Color.WHITE


func _apply_sprite_scale() -> void:
	if _sprite != null:
		_sprite.scale = _base_sprite_scale * _sprite_scale


## Gives the shot a [PointLight2D] so it actually illuminates the ships and asteroids
## it flies past.
##
## The light is created lazily and in code rather than authored into laser.tscn,
## mine.tscn and rocket.tscn: most shots want one, its radius and brightness are a
## per-weapon property, and the pooled bodies are built by the hundred, so paying for
## the node only once a lit weapon has actually used that body keeps the pool cheap.
##
## `texture_scale` is what sets the radius: the light texture is a 256px gradient, so
## scaling it by radius/128 makes `light_radius` read directly in world pixels.
func _apply_light() -> void:
	if _light_radius <= 0.0:
		if _light != null:
			_light.visible = false
		return
	if _light == null:
		_light = PointLight2D.new()
		_light.name = "ShotLight"
		_light.texture = FXLighting.radial_light_texture()
		_light.blend_mode = Light2D.BLEND_MODE_ADD
		_light.shadow_enabled = false
		add_child(_light)
	_light.texture_scale = _light_radius / 128.0
	_light.energy = _light_energy
	_light.visible = is_active
