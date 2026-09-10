class_name GameObject
extends RigidBody2D

## Base class for every simulated entity.
##
## Motion, collision response and elastic bounce are handled by Godot's 2D physics.
## Each entity is a [RigidBody2D] with a [CircleShape2D] sized from its tuning
## radius, and the named collision layers in project.godot decide what interacts
## with what:
##
## [codeblock]
## ships       layer 1  mask ships | asteroids | walls
## asteroids   layer 2  mask ships | asteroids | walls
## projectiles layer 3  mask ships | asteroids | projectiles | walls
## pickups     layer 4  mask ships
## walls       layer 5  mask none
## [/codeblock]
##
## Entities that must detect contacts without pushing anything -- projectiles and
## power-ups -- are given a negligible `mass` instead of a filtered mask, so the
## solver reports the contact but transfers no meaningful momentum. Contacts that
## should pass through simply do not apply damage; there is no explicit "pass-through"
## return value.
##
## Coordinate convention: forward is (sin(rot), -cos(rot)), i.e. rotation 0 = up,
## increasing rotation = clockwise. Godot 2D is also y-down / clockwise-positive,
## and the ship art points up, so child sprites need no rotation offset.

var object_type: NRTypes.GameObjectType = NRTypes.GameObjectType.UNKNOWN
var unique_id: int = 0
var health: float = 1.0

## Velocity sampled before the current physics step. Contact handlers need the
## approach speed, and by the time [signal RigidBody2D.body_entered] fires the
## solver has already applied the bounce.
var pre_step_velocity: Vector2 = Vector2.ZERO

var world: World = null

## Alias for [member RigidBody2D.linear_velocity] so gameplay and netcode code can
## keep talking about "velocity".
var velocity: Vector2:
	get:
		return linear_velocity
	set(value):
		linear_velocity = value

## Collision radius. Writing it resizes the body's [CircleShape2D].
var radius: float = 0.0:
	set(value):
		radius = value
		_apply_radius()

var is_active: bool = true:
	set(value):
		is_active = value
		visible = value
		_sync_physics_state()

## Cleared by [MatchDirector] between match phases so the bodies hold still without
## being deactivated.
var simulation_running: bool = true:
	set(value):
		simulation_running = value
		_sync_physics_state()
		_on_simulation_running_changed(value)

var _body_shape: CollisionShape2D = null
## Layers/masks authored in the entity scene, restored whenever the object goes live.
var _base_layer: int = 0
var _base_mask: int = 0
var _base_collision_captured: bool = false

## Unique ids are allocated by the authority and replicated to clients, so the
## counter only advances on the host. Client objects are stamped with the id
## carried in the spawn/creation payload.
static var _next_unique_id: int = 0


static func allocate_id() -> int:
	_next_unique_id += 1
	return _next_unique_id


func _ready() -> void:
	gravity_scale = 0.0
	# Every entity's facing is driven by gameplay code, never by the solver.
	lock_rotation = true
	can_sleep = false
	contact_monitor = true
	max_contacts_reported = 8

	_body_shape = get_node_or_null(^"CollisionShape2D")
	if _body_shape != null and _body_shape.shape != null:
		_body_shape.shape = _body_shape.shape.duplicate()
	_capture_base_collision()
	body_entered.connect(_on_contact_body)

	_apply_radius()
	visible = is_active
	_sync_physics_state()
	_build_visuals()
	_update_visuals()


func set_world(w: World) -> void:
	world = w


## Repositions the body. The physics server owns an active body's transform and
## overwrites plain [member Node2D.position] writes on the next sync, so spawning,
## respawning and snapshot corrections have to push the transform to the server.
func teleport(to: Vector2, new_rotation: float = rotation) -> void:
	position = to
	rotation = new_rotation
	PhysicsServer2D.body_set_state(
		get_rid(), PhysicsServer2D.BODY_STATE_TRANSFORM, global_transform)


## Reorients the body. Like [method teleport], this has to push the transform to the
## physics server: an active body's transform is owned by the server, which restores
## it over any plain [member Node2D.rotation] write on its next sync, so gameplay
## facing changes are silently discarded unless the server is told about them.
func set_facing(new_rotation: float) -> void:
	rotation = new_rotation
	PhysicsServer2D.body_set_state(
		get_rid(), PhysicsServer2D.BODY_STATE_TRANSFORM, global_transform)


func start() -> void:
	pass


func tick(_delta: float) -> void:
	pre_step_velocity = linear_velocity
	_update_visuals()


## Called once per contact with another simulated entity. Momentum exchange is the
## physics engine's job; overrides only add gameplay consequences.
func on_contact(_other: GameObject) -> void:
	pass


## Called when this entity touches the barrier. Bodies with a `walls` mask bounce
## automatically, so only projectiles override this.
func on_wall_contact() -> void:
	pass


func take_damage(_source: GameObject, _damage: float) -> void:
	pass


func die() -> void:
	_deactivate()


## The GameObject-level death used by apply_projectile_detonation_results and by the
## projectile subclasses, which override die() but still need the plain recycle path.
func _deactivate() -> void:
	if world != null and is_active:
		is_active = false
		health = 0.0
		world.destroy_game_object_by_id(unique_id)


func is_dead() -> bool:
	return health == 0.0


func _on_contact_body(body: Node) -> void:
	if body == self or not is_active or not simulation_running or world == null:
		return
	var other := body as GameObject
	if other == null:
		on_wall_contact()
	elif other.is_active:
		on_contact(other)


func _apply_radius() -> void:
	_resize_shape(_body_shape)


func _resize_shape(collision_shape: CollisionShape2D) -> void:
	if collision_shape == null:
		return
	var circle := collision_shape.shape as CircleShape2D
	if circle != null and not is_equal_approx(circle.radius, radius):
		circle.radius = radius


## Inactive objects are taken out of play by clearing their collision layers rather
## than by disabling their [CollisionShape2D]: a body whose shapes are all disabled
## is dropped by the physics server and stops integrating its transform entirely,
## even after it is re-enabled.
##
## The layers are applied *eagerly*, unlike the rest of the physics state, and this
## also runs before the body has entered the tree. Both matter for the pooled
## projectiles: World fills the pool by instantiating every projectile at the origin
## and deactivating it, so until the layers are cleared the whole pool is one pile of
## mutually-overlapping bodies. The broadphase pairs each new arrival against every
## body already stacked there, which turns building the pool into an O(n^2) stall --
## measured at roughly 17 seconds for an eight-player roster (~860 projectiles), versus
## well under a tenth of a second once the layers are cleared up front.
func _sync_physics_state() -> void:
	_capture_base_collision()
	collision_layer = _base_layer if is_active else 0
	collision_mask = _base_mask if is_active else 0
	if not is_inside_tree():
		return
	if not is_active:
		linear_velocity = Vector2.ZERO
	_apply_physics_state.call_deferred()


## Remembers the layers authored in the entity scene so going live can restore them.
##
## Captured on first use rather than in `_ready()` because `is_active` is routinely set
## while an object is still detached -- pool construction does exactly that -- and by
## the time `_ready()` runs the layers have already been cleared, so reading them then
## would record 0 as the object's "live" configuration and it could never collide again.
func _capture_base_collision() -> void:
	if _base_collision_captured:
		return
	_base_collision_captured = true
	_base_layer = collision_layer
	_base_mask = collision_mask


## The body mode has to change outside the physics step, so it is deferred -- which
## means a pending freeze can land *after* gameplay has already handed the body its
## launch velocity (a projectile taken from the pool in the same frame another one was
## recycled). Entering the frozen (static) mode clears the physics server's velocity,
## so it is captured here and re-applied once the body is live again; without this the
## shot leaves the muzzle dead in place, and bodies thawed between match phases would
## resume from a standstill.
func _apply_physics_state() -> void:
	var simulating := is_active and simulation_running
	var desired_velocity := linear_velocity
	freeze = not simulating
	collision_layer = _base_layer if is_active else 0
	collision_mask = _base_mask if is_active else 0
	if simulating:
		linear_velocity = desired_velocity
	for timer in find_children("*", "Timer", true, false):
		(timer as Timer).paused = not simulating
	for animation_player in find_children("*", "AnimationPlayer", true, false):
		(animation_player as AnimationPlayer).active = simulating


func _on_simulation_running_changed(_running: bool) -> void:
	pass


## Overridden by subclasses to bind the Sprite2D children authored in their scene and
## apply any spawn-time texture/scale choices.
func _build_visuals() -> void:
	pass


## Overridden by subclasses to keep sprite colour/visibility in sync with simulation
## state each tick. Scale is baked into the entity scenes.
func _update_visuals() -> void:
	pass
