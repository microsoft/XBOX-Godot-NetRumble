class_name World
extends Node2D

## The gameplay simulation. Owns spawning, projectile pooling, explosions, power-ups
## and per-object ticking. Movement and collision are handled by Godot's physics
## engine; network transport is handled by NetManager broadcasts.
##
## This node is the pure simulation. The match-flow state machine (MatchState,
## scoring, respawn timing, win conditions) lives in MatchDirector, which owns the
## clock and drives this node by calling `tick(delta)`. Splitting them this way means
## a paused match, a countdown phase and a snapshot correction all resolve in a
## defined order without re-entrancy: MatchDirector decides whether the world runs,
## then calls `tick()` exactly once per physics frame.
##
## Authority model: the host runs the full simulation and is the source of truth for
## damage and spawning; clients tick the world locally for smooth motion/prediction,
## but every authoritative outcome is gated behind `is_authority` and corrected by
## world snapshots. What the host actually puts on the wire, and what a client does
## when it arrives, lives in world_network_sync.gd — this node owns the simulation
## those messages describe.

signal gameplay_event(event_type: NRTypes.GameplayEventType, position: Vector2)
signal local_ship_changed(ship: GameObject)
## Emitted by the authority when a ship's health reaches zero. MatchDirector owns
## the scoring/respawn response; `killer_peer_id` is the peer of the ship whose
## projectile last damaged the victim, or -1 for environmental/suicide deaths.
signal ship_destroyed(ship: Node, killer_peer_id: int)

const SPAWN_POINT_PADDING := 100.0
## Dead zone around the local ship inside which the cursor produces no aim direction.
## Without it, a cursor resting on top of the ship normalises a near-zero vector and
## the shots spray in whatever direction the last sub-pixel of jitter pointed.
const MOUSE_AIM_DEAD_ZONE := 12.0


## Entity scenes. Exported so the world scene can swap them without touching code.
## These are assigned in world.tscn instead of being `preload`ed here on purpose: every
## entity script extends GameObject, which declares `var world: World`, so a preload
## would close a cyclic resource load (asteroid.tscn -> asteroid.gd -> game_object.gd ->
## world.gd -> asteroid.tscn) that fails with "Parse Error: Busy" on load and export.
@export var ship_scene: PackedScene
@export var barrier_scene: PackedScene
@export var asteroid_scene: PackedScene
@export var power_up_scene: PackedScene
## Keyed by NRTypes.ProjectileType.
@export var projectile_scenes: Dictionary = {}

var is_authority: bool = false
var game_mode: NRTypes.GameModeType = NRTypes.GameModeType.DEATHMATCH

var game_objects: Dictionary = {}        # unique_id -> GameObject
var ships: Dictionary = {}               # unique_id -> Ship
var asteroids: Dictionary = {}           # unique_id -> Asteroid
var power_ups: Dictionary = {}           # unique_id -> PowerUp (the whole pool)
var active_projectiles: Dictionary = {}  # unique_id -> Projectile
## Pickups currently sitting on the field, and the pooled bodies waiting to become
## one. Several drops can sit on the field at once; the spawn timer paces how quickly
## the field is topped back up after a pickup is collected.
var active_power_ups: Dictionary = {}    # unique_id -> PowerUp
var free_power_ups: Array[PowerUp] = []

var barrier: Barrier = null
var local_ship: Ship = null
var last_world_data_frame: int = 0

var _players: Array[PlayerState] = []
var _ships_by_peer: Dictionary = {}      # peer_id -> Ship
var _projectile_caches: Dictionary = {}  # ProjectileType -> Array[Projectile]
var _pending_mine_detonations: Array[MineProjectile] = []
var _processing_mine_detonations: bool = false

var _power_up_spawn_timer: Timer = null

var _local_input: ShipInput = ShipInput.new()
var _input_sequence: int = 0
var _input_accum: float = 0.0
## Ship unique_id -> BotController for every NPC opponent. Authority-side only, and in
## practice only ever populated offline: bots are a practice-mode feature and are
## never introduced into a networked session.
var _bot_controllers: Dictionary = {}

var _world_width: int = 0
var _world_height: int = 0
## Mirrors the gate MatchDirector applies through set_simulation_running, so entities
## created mid-match (asteroid fragments) are born in the same state as their peers
## instead of being the only bodies still moving during a frozen phase.
var _simulation_running: bool = true


## Ships already reported through `ship_destroyed`, so a still-active corpse is not
## re-announced before MatchDirector processes the death.
var _announced_deaths: Dictionary = {}

## Owns the wire format and every inbound network message — see world_network_sync.gd.
## Held rather than made a child node so it cannot acquire a tick of its own: the
## simulation must advance only when MatchDirector says so.
var _net_sync: WorldNetworkSync = null


# --- Public API (driven by MatchDirector) -----------------------------------

## MatchDirector owns the match clock and drives per-object logic via tick(); the
## physics engine advances the bodies on its own schedule.
func _ready() -> void:
	_power_up_spawn_timer = $PowerUpSpawnTimer
	_power_up_spawn_timer.one_shot = true
	_power_up_spawn_timer.process_callback = Timer.TIMER_PROCESS_PHYSICS
	_power_up_spawn_timer.wait_time = NRConst.power_up_spawn_interval(_power_up_frequency())
	set_physics_process(false)


func initialize(authority: bool, mode: NRTypes.GameModeType, player_states: Array[PlayerState]) -> void:
	is_authority = authority
	game_mode = mode
	_players = player_states
	_projectile_caches = {
		NRTypes.ProjectileType.LASER: [],
		NRTypes.ProjectileType.MINE: [],
		NRTypes.ProjectileType.ROCKET: [],
	}
	_net_sync = WorldNetworkSync.new(self)
	if is_authority:
		_server_initialize()
		_reset_power_up_spawn_timer()


## Lay the world out once, activate the ships and hand the constructed world to
## clients so they can build theirs. Called a single time per match, right before the
## start countdown, so nothing gets repositioned under the players again.
func start_match() -> void:
	if not is_authority:
		return
	reset()
	_world_start()
	NetManager.broadcast_match_created(_build_match_created_payload())
	NetManager.broadcast_match_starting(_build_match_starting_payload())
	if local_ship != null:
		local_ship_changed.emit(local_ship)


## Reposition asteroids and ships to fresh spawn points, respawn the ships and
## recycle projectiles/power-ups.
func reset() -> void:
	if not is_authority:
		return

	for asteroid in asteroids.values():
		(asteroid as Asteroid).teleport(Vector2.ZERO)
	for ship in ships.values():
		(ship as Ship).teleport(Vector2.ZERO)

	for asteroid in asteroids.values():
		var a := asteroid as Asteroid
		a.teleport(find_spawn_point(a.radius))

	for ship in ships.values():
		var s := ship as Ship
		s.teleport(find_spawn_point(s.radius))
		s.start()
		s.is_active = true

	reset_projectile_cache()
	_reset_power_ups()


## Advance the whole simulation by one step. MatchDirector calls this only while
## the sim should be running (PLAYERS_JOINING/RUNNING), leaving it frozen otherwise.
func tick(delta: float) -> void:
	_dispatch_local_input(delta)
	_tick_bots(delta)
	_simulate(delta)
	if is_authority:
		tick_power_ups(delta)
		_detect_destroyed_ships()
		_detect_split_asteroids()


## Build a world snapshot and send it. MatchDirector calls this on its own 30 Hz
## schedule, so the world keeps no snapshot timer of its own. The snapshot's contents
## are defined in world_network_sync.gd, alongside the client code that reads them.
func broadcast_snapshot() -> void:
	_net_sync.broadcast_snapshot()


func get_game_object(unique_id: int) -> Node:
	return game_objects.get(unique_id, null)


func remove_ship_for(peer_id: int) -> void:
	var ship := _ships_by_peer.get(peer_id, null) as Ship
	if ship == null:
		return

	var owned: Array[int] = []
	for id in active_projectiles:
		var projectile := active_projectiles[id] as Projectile
		if projectile != null and projectile.owner_id == ship.unique_id:
			owned.append(id)
	for id in owned:
		destroy_game_object_by_id(id)

	if local_ship == ship:
		local_ship = null

	_ships_by_peer.erase(peer_id)
	ships.erase(ship.unique_id)
	game_objects.erase(ship.unique_id)
	_bot_controllers.erase(ship.unique_id)
	ship.queue_free()


func get_ship_for(peer_id: int) -> Node:
	return _ships_by_peer.get(peer_id, null)


func get_ships() -> Dictionary:
	return ships


func get_ship_by_id(ship_id: int) -> Ship:
	return ships.get(ship_id, null)


## Brings a ship back at `spawn_point` once its respawn delay has run out.
##
## The authority's respawn timer and the client's ship-spawned message both land here
## so the two cannot drift, and so that the one thing neither path can work out for
## itself is done in exactly one place: telling the screen that the local player's ship
## has moved somewhere it did not fly to.
##
## Without that notification the camera is left smoothing toward a spawn point on the
## far side of the map from wherever the player died. For the second or so that sweep
## takes, the player's own ship is off-screen and somebody else's is centred in view --
## which reads as the controls having been handed to the wrong ship, and reads that way
## again on every single death.
func respawn_ship(ship: Ship, spawn_point: Vector2) -> void:
	if ship == null or not is_instance_valid(ship):
		return
	ship.teleport(spawn_point)
	ship.start()
	ship.is_active = true
	if ship == local_ship:
		local_ship_changed.emit(ship)


func reset_projectile_cache() -> void:
	for projectile in active_projectiles.values():
		var p := projectile as Projectile
		p.is_active = false
		(_projectile_caches[p.projectile_type] as Array).append(p)
	active_projectiles.clear()
	_pending_mine_detonations.clear()
	_processing_mine_detonations = false


# --- Local input + snapshot cadence -----------------------------------------

func _dispatch_local_input(delta: float) -> void:
	if local_ship == null:
		return

	# The local ship's input object IS _local_input, so processing it here applies
	# immediate local prediction; the network send only mirrors it to the host.
	_local_input.process_local_input(_mouse_aim_direction())

	_input_accum += delta
	var interval := 1.0 / NRConst.INPUT_SEND_HZ
	var due := _input_accum >= interval
	# Input rides an unreliable channel, so the full state is resent every interval
	# rather than only when it changes: a single dropped packet would otherwise leave
	# the host steering this ship with stale input forever (a released stick keeps
	# thrusting, and the ship flies off across the map on every other peer's view).
	# Mine deploys are a one-frame edge, so those still go out immediately.
	if due or _local_input.deploy_mine_pressed:
		_input_sequence += 1
		NetManager.send_ship_input(
			_local_input.movement_direction,
			_local_input.fire_direction,
			_local_input.deploy_mine_pressed,
			_input_sequence)
	if due:
		# Carry the remainder instead of zeroing. Zeroing throws away the overshoot, so
		# the achievable rate collapses to the largest divisor of the tick rate -- at a
		# 60 Hz tick, asking for 45 Hz would quietly get 30 Hz, and asking for 60 Hz
		# would need delta to land exactly on the interval every single frame. Clamped
		# to one interval so a frame spike cannot queue a burst of catch-up packets.
		_input_accum = minf(_input_accum - interval, interval)


## Aim direction from the local ship to the mouse cursor while the `click` action is
## held, or Vector2.ZERO when the player is not mouse-aiming.
##
## Returned as a unit vector on purpose: `Ship._process_controls_weapon` compares the
## squared magnitude against `fire_threshold_squared` (0.25) to decide whether to
## shoot, so a raw ship-to-cursor vector would work but a short one -- cursor close to
## the ship -- would silently refuse to fire.
func _mouse_aim_direction() -> Vector2:
	if local_ship == null or not Input.is_action_pressed("click"):
		return Vector2.ZERO
	# get_global_mouse_position() resolves through this node's canvas transform, which
	# the gameplay camera already drives, so no manual camera maths is needed.
	var to_cursor := get_global_mouse_position() - local_ship.position
	if to_cursor.length_squared() < MOUSE_AIM_DEAD_ZONE * MOUSE_AIM_DEAD_ZONE:
		return Vector2.ZERO
	return to_cursor.normalized()


# --- Simulation -------------------------------------------------------------

## Advance per-object gameplay logic. Movement, collision response and barrier
## bounce are the physics engine's job now -- entities are RigidBody2D bodies with
## CircleShape2D colliders and elastic PhysicsMaterials, and contacts arrive through
## GameObject.on_contact()/on_wall_contact(). This replaces roughly 300 lines of
## hand-rolled swept circle collision, momentum exchange and wall reflection.
func _simulate(delta: float) -> void:
	# Clients tick the world before the host's match-created payload arrives, so
	# the barrier (and everything else) may not exist yet. Nothing to simulate.
	if barrier == null:
		return
	barrier.update(delta)

	for obj in game_objects.values():
		var game_object := obj as GameObject
		if game_object != null and game_object.is_active:
			game_object.tick(delta)

	_process_pending_mine_detonations()


## Freezes or thaws every body. MatchDirector clears this between match phases so
## the world holds still without the entities being deactivated.
func set_simulation_running(running: bool) -> void:
	_simulation_running = running
	if _power_up_spawn_timer != null:
		_power_up_spawn_timer.paused = not running
	if barrier != null:
		barrier.set_simulation_running(running)
	for obj in game_objects.values():
		var game_object := obj as GameObject
		if game_object != null:
			game_object.simulation_running = running

## Picks a random unoccupied point inside the barrier.
##
## Deliberately keeps the manual overlap test rather than a physics-space query:
## this runs during `_server_initialize()`, before the bodies' shapes have been
## registered with the space, so `intersect_shape()` would report an empty world.
## The manual test is also deterministic, which matters for host/client agreement.
func find_spawn_point(radius: float) -> Vector2:
	if barrier == null:
		return Vector2(_world_width, _world_height) * 0.5
	var top := barrier.get_top()
	var bottom := barrier.get_bottom()
	var left := barrier.get_left()
	var right := barrier.get_right()

	var padded_radius := radius + SPAWN_POINT_PADDING

	var spawn_point := Vector2(
		radius + left + randf_range(0.0, right - left - radius),
		radius + top + randf_range(0.0, bottom - top - radius))

	for attempt in range(1, NRConst.FIND_SPAWN_POINT_ATTEMPTS + 1):
		var valid := true
		for obj in game_objects.values():
			var other := obj as GameObject
			if other == null or not other.is_active:
				continue
			if _circle_intersect(spawn_point, padded_radius, other.position, other.radius):
				valid = false
				break
		if valid:
			break
		spawn_point = Vector2(
			radius + left + randf_range(0.0, right - left - radius),
			radius + top + randf_range(0.0, bottom - top - radius))

	return spawn_point


static func _circle_intersect(center1: Vector2, radius1: float, center2: Vector2, radius2: float) -> bool:
	return (center2 - center1).length_squared() <= (radius1 + radius2) * (radius1 + radius2)



# --- Ship destruction detection (authority) --------------------------------

## Detects ships whose health has hit zero and hands them to MatchDirector, which
## owns the response (scoring, respawn queue, broadcast_ship_destroyed and calling
## ship.die()). The world only reports the death and plays the local FX/audio.
func _detect_destroyed_ships() -> void:
	var destroyed: Array[Ship] = []
	for ship in ships.values():
		var s := ship as Ship
		if s == null:
			continue
		if s.is_active and s.health > 0.0:
			_announced_deaths.erase(s.unique_id)
		elif s.health <= 0.0 and not _announced_deaths.has(s.unique_id):
			destroyed.append(s)

	destroyed.sort_custom(func(a: Ship, b: Ship) -> bool: return a.unique_id < b.unique_id)

	for ship in destroyed:
		_announced_deaths[ship.unique_id] = true
		var killer_peer_id := _resolve_killer_peer_id(ship)
		emit_gameplay_event(NRTypes.GameplayEventType.SHIP_DESTROYED, ship.position)
		note_local_ship_destroyed(ship)
		ship_destroyed.emit(ship, killer_peer_id)


func _resolve_killer_peer_id(ship: Ship) -> int:
	var damager := game_objects.get(ship.last_damaged_by_id, null) as GameObject
	if damager != null and damager is Projectile:
		var killer := get_ship_by_id((damager as Projectile).owner_id)
		if killer != null:
			return killer.owner_peer_id
	return -1


# --- Asteroid splitting (authority) -----------------------------------------

## Breaks up asteroids whose health has reached zero.
##
## Deliberately polled at the end of the tick rather than acted on inside
## `Asteroid.take_damage`. Damage arrives from two places that are both mid-iteration
## over `game_objects`: a contact callback, and `apply_explosion_damage`'s hit loop.
## Spawning fragments (or freeing the parent) from in there mutates the dictionary
## being walked. Polling also gives the same deterministic, id-ordered processing that
## `_detect_destroyed_ships` relies on.
func _detect_split_asteroids() -> void:
	var destroyed: Array[Asteroid] = []
	for asteroid in asteroids.values():
		var a := asteroid as Asteroid
		if a != null and a.is_active and a.health <= 0.0:
			destroyed.append(a)

	if destroyed.is_empty():
		return

	destroyed.sort_custom(func(a: Asteroid, b: Asteroid) -> bool: return a.unique_id < b.unique_id)
	for asteroid in destroyed:
		_split_asteroid(asteroid)


## Replaces one destroyed asteroid with the fragments it breaks into. The terminal
## (TINY) tier yields no fragments and simply disappears, which is what makes the
## chain finite.
func _split_asteroid(parent: Asteroid) -> void:
	var parent_id := parent.unique_id
	var parent_position := parent.position
	var credited_peer_id := _resolve_asteroid_credit(parent)
	var fragments := _build_asteroid_fragments(parent)

	# The parent's collider is still occupying the space the fragments are about to be
	# placed in, and `remove_object` only queues the free -- the body survives until
	# the end of the frame. Taking it out of play first stops the solver shoving the
	# new pieces out at speeds the split velocity never intended.
	parent.is_active = false
	remove_object(parent_id)

	for fragment in fragments:
		spawn_asteroid_fragment(fragment)

	emit_gameplay_event(NRTypes.GameplayEventType.ASTEROID_IMPACT, parent_position)
	note_asteroid_destroyed(credited_peer_id)
	NetManager.broadcast_asteroid_split({
		"id": parent_id,
		"px": parent_position.x,
		"py": parent_position.y,
		# Whose shot broke the rock. Only the authority can work this out, and the
		# player it credits is usually on another machine, so the answer travels with
		# the split rather than being recomputed from state clients do not have.
		"peer_id": credited_peer_id,
		"fragments": fragments,
	})


## The peer whose shot destroyed an asteroid, or -1 when nothing player-owned did.
## Mirrors `_resolve_killer_peer_id`: only projectile damage earns credit, so a rock a
## ship simply barged into belongs to nobody.
func _resolve_asteroid_credit(asteroid: Asteroid) -> int:
	var damager := game_objects.get(asteroid.last_damaged_by_id, null) as GameObject
	if damager != null and damager is Projectile:
		var shooter := get_ship_by_id((damager as Projectile).owner_id)
		if shooter != null:
			return shooter.owner_peer_id
	return -1


## Rolls the fragments a destroyed asteroid throws off. Everything random is decided
## here, on the authority, and shipped verbatim to clients -- rather than each peer
## rolling its own -- so a split looks identical on every machine.
func _build_asteroid_fragments(parent: Asteroid) -> Array[Dictionary]:
	var fragments: Array[Dictionary] = []

	var child_size := parent.split_size()
	if child_size < 0:
		return fragments

	var tuning := parent.tuning
	if tuning == null:
		return fragments

	# The parent is still counted here, so the budget runs one short of the true
	# headroom. That is deliberate: a field near the ceiling degrades by dropping
	# fragments rather than by refusing to break rocks at all.
	var budget := NRConst.MAX_ASTEROIDS - asteroids.size()
	var count := mini(maxi(tuning.split_count, 0), maxi(budget, 0))
	if count <= 0:
		return fragments

	var child_radius := tuning.radius_for(child_size as NRTypes.AsteroidSize)
	# Fragments are placed on a ring wide enough that they do not start inside each
	# other, then thrown outwards along the same radius.
	var offset_distance := child_radius * tuning.split_spawn_spread
	var base_angle := randf_range(0.0, TAU)

	for index in count:
		var angle := base_angle \
			+ TAU * float(index) / float(count) \
			+ randf_range(-tuning.split_angle_jitter, tuning.split_angle_jitter)
		var direction := Vector2(cos(angle), sin(angle))
		var speed := randf_range(tuning.split_speed_min, tuning.split_speed_max)
		fragments.append({
			"id": GameObject.allocate_id(),
			"size": child_size,
			"variation": randi_range(0, 2),
			"px": parent.position.x + direction.x * offset_distance,
			"py": parent.position.y + direction.y * offset_distance,
			# Momentum is inherited so the pieces continue the parent's drift rather
			# than appearing to stop dead and scatter from a standstill.
			"vx": parent.velocity.x + direction.x * speed,
			"vy": parent.velocity.y + direction.y * speed,
		})

	return fragments


## Builds one fragment from an authority-rolled description. Used by both the host
## (as it splits) and clients (as the split message arrives), so the two paths cannot
## drift apart.
func spawn_asteroid_fragment(data: Dictionary) -> void:
	if asteroid_scene == null:
		return
	var id := int(data.get("id", 0))
	if id == 0 or game_objects.has(id):
		return

	var asteroid := asteroid_scene.instantiate() as Asteroid
	if asteroid == null:
		return
	asteroid.set_world(self)
	asteroid.setup_fragment(
		id,
		int(data.get("size", 0)) as NRTypes.AsteroidSize,
		int(data.get("variation", 0)))
	_add_asteroid(asteroid)

	# teleport() rather than `position =`: the body is live the moment it enters the
	# tree and the physics server owns its transform from then on.
	asteroid.teleport(Vector2(data.get("px", 0.0), data.get("py", 0.0)))
	asteroid.velocity = Vector2(data.get("vx", 0.0), data.get("vy", 0.0))
	asteroid.simulation_running = _simulation_running


# --- Projectiles ------------------------------------------------------------

func create_projectiles(weapon: NRTypes.WeaponType, ship_owner_id: int, direction: Vector2) -> void:
	# Reported before the authority guard, because this is the local player pulling the
	# trigger and it has to count on their own machine. A client's ship runs its controls
	# locally and reaches here every time it fires; the shots themselves are then left to
	# the host, which is what the guard below is for.
	if local_ship != null and ship_owner_id == local_ship.unique_id:
		var tracker := _achievement_tracker()
		if tracker != null:
			tracker.note_weapon_fired(int(weapon))

	if not is_authority:
		return

	var owner := get_ship_by_id(ship_owner_id)
	if owner == null:
		return

	# One generic routine for all twenty weapons. The arrangement of each volley is
	# described by the weapon's WeaponLibrary entry and executed once here, rather
	# than duplicating the offset and rotation logic per weapon type.
	var definition := WeaponLibrary.get_definition(weapon)
	var spec := definition.to_shot_spec()
	# Buffs are folded into the spec rather than applied to the projectile afterwards,
	# so they ride the spawn message and clients build identical shots.
	spec["ds"] = float(spec["ds"]) * owner.damage_multiplier()
	spec["bn"] = int(spec["bn"]) + owner.extra_bounces()

	var shot_count := maxi(definition.shot_count + owner.extra_shots(), 1)
	var spread := definition.spread
	if shot_count > 1:
		spread += owner.extra_spread()
	var full_circle := spread >= TAU - 0.001

	var perpendicular := Vector2(-direction.y, direction.x)
	var volley: Array[Projectile] = []
	for i in shot_count:
		# `fraction` runs from -0.5 to +0.5 across the volley, so it drives both the
		# angular fan and the lateral spacing from one number and a single shot
		# naturally lands dead centre. A full-circle weapon divides by the shot count
		# instead, or its first and last shots would land on top of each other.
		var fraction := 0.0
		if shot_count > 1:
			fraction = (float(i) / float(shot_count)) - 0.5 if full_circle \
				else (float(i) / float(shot_count - 1)) - 0.5
		var angle := fraction * spread
		if definition.spread_jitter > 0.0:
			angle += randf_range(-definition.spread_jitter, definition.spread_jitter)
		var shot_direction := direction.rotated(angle)

		var shot := consume_projectile(definition.projectile_type, owner, shot_direction, spec)
		if shot == null:
			continue
		var offset := direction * definition.muzzle_offset
		if definition.lateral_spacing > 0.0:
			offset += perpendicular * (fraction * 2.0 * definition.lateral_spacing)
		if offset != Vector2.ZERO:
			# teleport(), not `position +=`: the physics server owns an active body's
			# transform and overwrites plain position writes.
			shot.teleport(shot.position + offset)
		volley.append(shot)

	if volley.is_empty():
		return

	_spawn_volley(volley)
	owner.consume_weapon_ammo()

	if definition.projectile_type == NRTypes.ProjectileType.ROCKET:
		emit_gameplay_event(NRTypes.GameplayEventType.ROCKET_FIRED, owner.position)
	else:
		emit_gameplay_event(NRTypes.GameplayEventType.LASER_FIRED, owner.position)


## Nearest ship other than the one that fired, ignoring the cloaked. Used by the
## guided weapons; kept on the World because it is the only thing holding the ship
## table, and a linear scan over at most eight ships is cheaper than any structure
## that would have to be maintained.
func find_nearest_enemy_ship(from: Vector2, exclude_ship_id: int) -> Ship:
	var best: Ship = null
	var best_distance := INF
	for entry in ships.values():
		var ship := entry as Ship
		if ship == null or not ship.is_active or ship.unique_id == exclude_ship_id:
			continue
		if ship.is_untargetable():
			continue
		var distance := from.distance_squared_to(ship.position)
		if distance < best_distance:
			best_distance = distance
			best = ship
	return best


## Credits a vampiric shooter with a share of the damage one of its shots just dealt.
func credit_damage_dealt(shooter_id: int, damage: float) -> void:
	if not is_authority:
		return
	var shooter := get_ship_by_id(shooter_id)
	if shooter != null:
		shooter.credit_vampiric_damage(damage)


## Shots in the same volley leave the muzzle overlapping each other, so they are
## exempted from colliding as a group -- otherwise the solver depenetrates them and
## sprays the spread apart. Same-owner shots already ignore each other in gameplay.
func _spawn_volley(volley: Array[Projectile]) -> void:
	for shot in volley:
		for other in volley:
			shot.exempt_from_collisions(other)
		notify_projectile_spawned(shot)


func create_mine(ship_owner_id: int, direction: Vector2) -> bool:
	if not is_authority:
		return false
	var owner := get_ship_by_id(ship_owner_id)
	if owner == null:
		return false

	var mine := consume_projectile(NRTypes.ProjectileType.MINE, owner, direction)
	if mine == null:
		return false

	var offset := owner.radius + mine.radius + NRConst.MINE_SPAWN_DISTANCE
	mine.teleport(owner.position + direction * offset)
	notify_projectile_spawned(mine)
	return true


func create_rocket(ship_owner_id: int, direction: Vector2) -> bool:
	if not is_authority:
		return false
	var owner := get_ship_by_id(ship_owner_id)
	if owner == null:
		return false

	var rocket := consume_projectile(NRTypes.ProjectileType.ROCKET, owner, direction)
	if rocket == null:
		return false

	notify_projectile_spawned(rocket)
	emit_gameplay_event(NRTypes.GameplayEventType.ROCKET_FIRED, rocket.position)
	return true


func consume_projectile(projectile_type: NRTypes.ProjectileType, ship: Ship, direction: Vector2, spec: Dictionary = {}) -> Projectile:
	var cache := _projectile_caches.get(projectile_type, null) as Array
	if cache == null or cache.is_empty() or ship == null:
		return null

	var projectile := cache.pop_front() as Projectile
	# Applied before the body is aimed: the spec carries the shot's speed, and
	# set_owner_and_direction is what turns that speed into a velocity.
	projectile.apply_shot_spec(spec)
	projectile.set_owner_and_direction(ship, direction)
	projectile.is_active = true
	projectile.start()
	active_projectiles[projectile.unique_id] = projectile
	return projectile


## Drops a client-side shot the authority has evidently stopped tracking. Clients build
## these bodies on demand from the spawn message, so they are freed rather than pooled,
## exactly as the detonation path does.
func retire_orphaned_projectile(projectile: Projectile) -> void:
	if is_authority or projectile == null:
		return
	remove_object(projectile.unique_id)


func notify_projectile_spawned(projectile: Projectile) -> void:
	if not is_authority or projectile == null:
		return
	NetManager.broadcast_projectile_spawned({
		"projectile_type": int(projectile.projectile_type),
		"id": projectile.unique_id,
		"owner_id": projectile.owner_id,
		"px": projectile.position.x,
		"py": projectile.position.y,
		"vx": projectile.velocity.x,
		"vy": projectile.velocity.y,
		"rot": projectile.rotation,
		# Clients are told what the shot *is* rather than being expected to look the
		# weapon up: they never see the trigger pull, and a client running a
		# differently-tuned build would otherwise render and predict a different shot.
		"spec": projectile.shot_spec(),
	})


func notify_projectile_detonated(projectile: Projectile, position: Vector2, hits: Array) -> void:
	if not is_authority or projectile == null:
		return
	NetManager.broadcast_projectile_detonated({
		"projectile_type": int(projectile.projectile_type),
		"id": projectile.unique_id,
		"px": position.x,
		"py": position.y,
		"hits": hits,
	})
	match projectile.projectile_type:
		NRTypes.ProjectileType.LASER:
			emit_gameplay_event(NRTypes.GameplayEventType.LASER_IMPACT, position)
		NRTypes.ProjectileType.ROCKET:
			emit_gameplay_event(NRTypes.GameplayEventType.ROCKET_DETONATED, position)
		NRTypes.ProjectileType.MINE:
			emit_gameplay_event(NRTypes.GameplayEventType.MINE_DETONATED, position)


func queue_mine_detonation(mine: MineProjectile) -> void:
	if is_authority and mine != null and mine.try_queue_detonation():
		_pending_mine_detonations.append(mine)


func _process_pending_mine_detonations() -> void:
	if _processing_mine_detonations:
		return
	_processing_mine_detonations = true
	while not _pending_mine_detonations.is_empty():
		var mine := _pending_mine_detonations.pop_front() as MineProjectile
		if mine != null and mine.is_active:
			mine.detonate_queued()
	_processing_mine_detonations = false


func apply_explosion_damage(source: Projectile, position: Vector2, damage_amount: float, damage_radius: float, can_damage_owner: bool, excluded_target: GameObject) -> Array[Dictionary]:
	var results: Array[Dictionary] = []
	if source == null or damage_amount <= 0.0 or damage_radius <= 0.0:
		return results

	var damage_radius_squared := damage_radius * damage_radius
	var hits: Array = []

	for obj in game_objects.values():
		var game_object := obj as GameObject
		if game_object == null \
				or not game_object.is_active \
				or game_object == excluded_target \
				or game_object.object_type == NRTypes.GameObjectType.POWER_UP \
				or game_object.health <= 0.0:
			continue
		if not can_damage_owner and game_object == source:
			continue

		var direction := game_object.position - position
		var distance_squared := direction.length_squared()
		if distance_squared > damage_radius_squared:
			continue

		var distance := sqrt(distance_squared)
		var adjusted_damage := damage_amount * (damage_radius - distance) / damage_radius
		if adjusted_damage <= 0.0:
			continue

		var impulse := Vector2.ZERO
		if distance_squared > 0.0:
			impulse = direction.normalized() * adjusted_damage * NRConst.SPEED_DAMAGE_RATIO

		hits.append({"obj": game_object, "damage": adjusted_damage, "impulse": impulse})

	hits.sort_custom(func(a: Dictionary, b: Dictionary) -> bool: return (a["obj"] as GameObject).unique_id < (b["obj"] as GameObject).unique_id)

	for hit in hits:
		var game_object := hit["obj"] as GameObject
		if not game_object.is_active or game_object.health <= 0.0:
			continue
		game_object.take_damage(source, hit["damage"])
		if game_object.is_active:
			game_object.velocity += hit["impulse"]

	for hit in hits:
		results.append(create_detonation_hit(hit["obj"] as GameObject))

	return results


func create_detonation_hit(obj: GameObject) -> Dictionary:
	if obj == null:
		return {}
	var shield := -1.0
	if obj.object_type == NRTypes.GameObjectType.SHIP:
		shield = (obj as Ship).shield
	return {
		"id": obj.unique_id,
		"health": obj.health,
		"shield": shield,
		"px": obj.position.x,
		"py": obj.position.y,
		"vx": obj.velocity.x,
		"vy": obj.velocity.y,
		"active": obj.is_active,
	}


func apply_projectile_detonation_results(hits: Array) -> void:
	for hit in hits:
		var id := int(hit.get("id", 0))
		var obj := game_objects.get(id, null) as GameObject
		if obj == null:
			continue

		obj.teleport(Vector2(hit["px"], hit["py"]))
		obj.velocity = Vector2(hit["vx"], hit["vy"])

		var shield := float(hit.get("shield", -1.0))
		if obj.object_type == NRTypes.GameObjectType.SHIP and shield >= 0.0:
			(obj as Ship).apply_authoritative_damage_state(hit["health"], shield)
		else:
			obj.health = hit["health"]

		var active := bool(hit.get("active", true))
		if not active and obj.is_active:
			destroy_game_object_by_id(id)
		else:
			obj.is_active = active


# --- Power-ups --------------------------------------------------------------

## Spawns drops until the field is carrying its allowance of them.
##
## Several drops sit on the field simultaneously: with thirty-two pickup types to
## find and ammo-limited weapons that run out in seconds, a single-slot world would
## mean most of a match spent shooting the default laser. The timer paces how quickly
## the field is topped back up after a pickup is collected.
func tick_power_ups(_delta: float) -> void:
	if not is_authority:
		return
	if active_power_ups.size() >= NRConst.max_active_power_ups(_power_up_frequency()):
		return
	if _power_up_spawn_timer != null and not _power_up_spawn_timer.is_stopped():
		return
	_spawn_power_up(PickupLibrary.random_type())
	_reset_power_up_spawn_timer()


func _spawn_power_up(type: NRTypes.PowerUpType) -> void:
	if free_power_ups.is_empty():
		return
	var power_up := free_power_ups.pop_front() as PowerUp
	if power_up == null:
		return

	# Pooled bodies are generic: which pickup they represent is decided here, at
	# spawn time, and replicated. That is what lets twelve bodies stand in for a
	# thirty-two-entry table.
	power_up.assign_type(type)
	power_up.teleport(find_spawn_point(power_up.radius))
	power_up.is_active = true
	power_up.start()
	active_power_ups[power_up.unique_id] = power_up

	NetManager.broadcast_power_up_spawned({
		"id": power_up.unique_id,
		"power_up_type": int(type),
		"px": power_up.position.x,
		"py": power_up.position.y,
	})
	emit_gameplay_event(NRTypes.GameplayEventType.POWER_UP_SPAWNED, power_up.position)


func collect_power_up(power_up: PowerUp, collector: Ship) -> void:
	if not is_authority or power_up == null or collector == null:
		return
	if not active_power_ups.has(power_up.unique_id):
		return

	var definition := power_up.definition
	apply_pickup(definition, collector)
	retire_power_up(power_up)

	NetManager.broadcast_power_up_collected({
		"id": power_up.unique_id,
		"collector_id": collector.unique_id,
		"power_up_type": int(power_up.power_up_type),
	})
	emit_gameplay_event(_pickup_event(definition), power_up.position)


## Hands a pickup's payload to whoever walked into it. The three kinds are the reason
## the definition carries a `kind` rather than the collector having to guess from the
## enumerator.
func apply_pickup(definition: PowerUpDefinition, collector: Ship) -> void:
	match definition.kind:
		NRTypes.PickupKind.WEAPON:
			collector.set_primary_weapon(definition.weapon_granted)
		NRTypes.PickupKind.BUFF:
			collector.grant_buff(definition.buff_granted, definition.buff_duration)
			# Runs on host and client alike -- clients re-derive the pickup's payload
			# from its type when the collection message arrives -- so the local player's
			# own pickups are counted wherever they are sitting.
			if collector == local_ship:
				var tracker := _achievement_tracker()
				if tracker != null:
					tracker.note_buff_collected(int(definition.buff_granted))
		NRTypes.PickupKind.RESTORE:
			collector.apply_restore(definition.restore_health, definition.restore_shield)


static func _pickup_event(definition: PowerUpDefinition) -> NRTypes.GameplayEventType:
	match definition.kind:
		NRTypes.PickupKind.BUFF:
			return NRTypes.GameplayEventType.BUFF_COLLECTED
		NRTypes.PickupKind.RESTORE:
			return NRTypes.GameplayEventType.RESTORE_COLLECTED
		_:
			return NRTypes.GameplayEventType.POWER_UP_COLLECTED


func retire_power_up(power_up: PowerUp) -> void:
	power_up.is_active = false
	active_power_ups.erase(power_up.unique_id)
	if not free_power_ups.has(power_up):
		free_power_ups.append(power_up)


func _reset_power_ups() -> void:
	active_power_ups.clear()
	free_power_ups.clear()
	for entry in power_ups.values():
		var power_up := entry as PowerUp
		power_up.is_active = false
		free_power_ups.append(power_up)
	_reset_power_up_spawn_timer()


func _reset_power_up_spawn_timer() -> void:
	if _power_up_spawn_timer == null:
		return
	_power_up_spawn_timer.wait_time = NRConst.power_up_spawn_interval(_power_up_frequency())
	_power_up_spawn_timer.start()


## The host's Power-Up Frequency setting, as a normalised 0..1 value.
##
## Only the authority spawns pickups, so this is deliberately read fresh on the
## machine running the simulation rather than replicated: clients see the resulting
## drops either way, and reading it per timer reset is what lets the setting be
## changed from the in-match pause menu and take effect without a restart.
func _power_up_frequency() -> float:
	if PlayerProfile == null:
		return 1.0
	return PlayerProfile.power_up_frequency


# --- Achievements -----------------------------------------------------------
#
# The world is the only thing that knows which ship belongs to the player sitting at this
# console, which is why the counters describing what that player did are reported from
# here. Every one of them runs on that player's own peer rather than on the host on their
# behalf: a console can only unlock achievements for its own signed-in user.
#
# Kills are the exception and are counted in Services, from the score broadcast -- the
# award already names the peer it belongs to and reaches every machine, which is the only
# way a client learns it got one.

func _achievement_tracker() -> AchievementTracker:
	return Services.achievement_tracker() if Services != null else null


func note_local_ship_destroyed(ship: Ship) -> void:
	if ship == null or ship != local_ship:
		return
	var tracker := _achievement_tracker()
	if tracker != null:
		tracker.note_death()


func note_asteroid_destroyed(peer_id: int) -> void:
	if peer_id < 0 or peer_id != NetManager.local_peer_id():
		return
	var tracker := _achievement_tracker()
	if tracker != null:
		tracker.note_asteroid_destroyed()


# --- Gameplay events (audio + FX) ------------------------------------------

## Authority-sourced events: play locally and broadcast so every client fires the
## same effect exactly once (clients receive them via gameplay_event_received).
func emit_gameplay_event(event_type: NRTypes.GameplayEventType, position: Vector2) -> void:
	if is_authority:
		play_local_event(event_type, position)
		NetManager.broadcast_gameplay_event(event_type, position)


## Purely cosmetic, machine-local effects (e.g. rocket trails) that each peer
## generates from its own simulation and never sends over the network.
func emit_local_effect(event_type: NRTypes.GameplayEventType, position: Vector2) -> void:
	play_local_event(event_type, position)


## Fans an event out to the local FX layer. `ParticleManager` owns the single
## event → particles + sound mapping; the World only decides *when* events happen.
func play_local_event(event_type: NRTypes.GameplayEventType, position: Vector2) -> void:
	gameplay_event.emit(event_type, position)


# --- Object bookkeeping -----------------------------------------------------

func destroy_game_object_by_id(unique_id: int) -> void:
	var obj := game_objects.get(unique_id, null) as GameObject
	if obj == null:
		return
	obj.is_active = false
	if obj.object_type == NRTypes.GameObjectType.PROJECTILE:
		_handle_destruction_projectile(obj as Projectile)


func _handle_destruction_projectile(projectile: Projectile) -> void:
	active_projectiles.erase(projectile.unique_id)
	(_projectile_caches[projectile.projectile_type] as Array).append(projectile)


func _world_start() -> void:
	for obj in game_objects.values():
		(obj as GameObject).start()


# --- Server initialization --------------------------------------------------

func _server_initialize() -> void:
	_world_width = NRConst.WORLD_WIDTH
	_world_height = NRConst.WORLD_HEIGHT
	_init_barrier(_world_width, _world_height)
	_init_asteroids(NRConst.ASTEROID_COUNT)
	_init_ships(_players)
	_init_projectiles(_players.size())
	_init_power_ups()
	_bind_local_ship()
	_init_bots()


func _init_barrier(width: int, height: int) -> void:
	barrier = barrier_scene.instantiate() as Barrier
	add_child(barrier)
	barrier.setup(width, height)


func _init_asteroids(count: int) -> void:
	for i in count:
		# The field seeds from the upper tiers only: rocks split down through the
		# smaller ones during play, so starting on MEDIUM leaves every asteroid at
		# least two generations of breaking up ahead of it.
		var size := randi_range(
			int(NRTypes.AsteroidSize.MEDIUM), int(NRTypes.AsteroidSize.HUGE)) as NRTypes.AsteroidSize
		var asteroid := asteroid_scene.instantiate() as Asteroid
		asteroid.set_world(self)
		asteroid.setup(size)
		asteroid.teleport(find_spawn_point(asteroid.radius))
		_add_asteroid(asteroid)


func _init_ships(player_states: Array[PlayerState]) -> void:
	for player_state in player_states:
		var ship := ship_scene.instantiate() as Ship
		ship.set_world(self)
		ship.setup(player_state)
		ship.teleport(find_spawn_point(ship.radius))
		_add_ship(ship)


func _init_projectiles(player_count: int) -> void:
	var counts := {
		NRTypes.ProjectileType.LASER: NRConst.MAX_LASERS_PER_PLAYER * player_count,
		NRTypes.ProjectileType.MINE: NRConst.MAX_MINES_PER_PLAYER * player_count,
		NRTypes.ProjectileType.ROCKET: NRConst.MAX_ROCKETS_PER_PLAYER * player_count,
	}
	for projectile_type in counts:
		for i in int(counts[projectile_type]):
			var projectile := create_projectile_instance(projectile_type)
			projectile.set_world(self)
			_add_projectile(projectile)


func _init_power_ups() -> void:
	# A pool of interchangeable bodies rather than one instance per pickup type:
	# there are thirty-two pickups and only ever a handful on the field, so the pool
	# is sized for what is live rather than for the size of the table.
	for i in NRConst.POWER_UP_POOL_SIZE:
		var power_up := power_up_scene.instantiate() as PowerUp
		power_up.set_world(self)
		power_up.setup(NRTypes.PowerUpType.DOUBLE_LASER)
		_add_power_up(power_up)


func _add_asteroid(asteroid: Asteroid) -> void:
	asteroids[asteroid.unique_id] = asteroid
	game_objects[asteroid.unique_id] = asteroid
	_attach_object(asteroid)


func _add_ship(ship: Ship) -> void:
	ships[ship.unique_id] = ship
	_ships_by_peer[ship.owner_peer_id] = ship
	game_objects[ship.unique_id] = ship
	_attach_object(ship)


## Parents an entity, giving it a collision-free node name first.
##
## `add_child()` has to guarantee siblings have distinct names, and every instance of a
## scene arrives carrying the same one ("Laser", "Asteroid", ...). Resolving that
## collision costs Godot a serial-name search that walks the existing children, so
## filling the projectile pool -- roughly 108 bodies *per player* -- degrades to O(n^2)
## and a full eight-player match spent about 16 seconds frozen inside `_init_projectiles`.
##
## Every entity already owns a process-unique id, so handing that over as the node name
## sidesteps the search entirely and the pool builds in linear time.
func _attach_object(obj: GameObject) -> void:
	obj.name = "%s_%d" % [obj.get_class(), obj.unique_id]
	add_child(obj)


## Pooled projectiles are created up-front on the authority, so each needs its own id
## the moment it enters the pool. Without one every pooled projectile shares id 0 and
## collapses onto a single entry in `game_objects` / `active_projectiles`, which stops
## all but one projectile from ever being simulated.
func _add_projectile(projectile: Projectile) -> void:
	projectile.unique_id = GameObject.allocate_id()
	projectile.is_active = false
	game_objects[projectile.unique_id] = projectile
	(_projectile_caches[projectile.projectile_type] as Array).append(projectile)
	_attach_object(projectile)


func _add_power_up(power_up: PowerUp) -> void:
	power_up.is_active = false
	power_ups[power_up.unique_id] = power_up
	game_objects[power_up.unique_id] = power_up
	free_power_ups.append(power_up)
	_attach_object(power_up)


func _bind_local_ship() -> void:
	local_ship = _ships_by_peer.get(NetManager.local_peer_id(), null)
	if local_ship != null:
		local_ship.ship_input = _local_input


## Attaches an AI driver to every ship whose PlayerState is flagged as a bot. Bots are
## plain ships: the only difference is where their ShipInput comes from, so nothing
## downstream of here has to know they exist.
func _init_bots() -> void:
	_bot_controllers.clear()
	if not is_authority:
		return
	for player_state in _players:
		if player_state == null or not player_state.is_bot:
			continue
		var ship := _ships_by_peer.get(player_state.peer_id, null) as Ship
		if ship == null or ship == local_ship:
			continue
		_bot_controllers[ship.unique_id] = BotController.new(self, ship)


## Runs every bot's AI for one step. Called from tick() *before* _simulate(), so a
## bot's input is applied on the same step it was decided -- exactly like the local
## player's, which _dispatch_local_input has just written.
func _tick_bots(delta: float) -> void:
	if not is_authority or _bot_controllers.is_empty():
		return
	var stale: Array[int] = []
	for ship_id in _bot_controllers:
		var controller := _bot_controllers[ship_id] as BotController
		if controller == null or not controller.is_valid():
			stale.append(ship_id)
			continue
		controller.tick(delta)
	for ship_id in stale:
		_bot_controllers.erase(ship_id)


# --- Networked construction payloads ---------------------------------------

func _build_match_created_payload() -> Dictionary:
	var asteroid_list: Array[Dictionary] = []
	for asteroid in asteroids.values():
		var a := asteroid as Asteroid
		asteroid_list.append({
			"id": a.unique_id,
			"size": int(a.asteroid_size),
			"variation": a.variation,
			"px": a.position.x,
			"py": a.position.y,
			"vx": a.velocity.x,
			"vy": a.velocity.y,
			"rot": a.rotation,
		})

	var ship_list: Array[Dictionary] = []
	for ship in ships.values():
		var s := ship as Ship
		ship_list.append({
			"id": s.unique_id,
			"peer_id": s.owner_peer_id,
			"entity_id": s.entity_id,
			"color_id": s.ship_color_id,
			"style_id": s.ship_style_id,
			"px": s.position.x,
			"py": s.position.y,
			"rot": s.rotation,
		})

	var power_up_list: Array[Dictionary] = []
	for power_up in power_ups.values():
		# Only the pool's ids are announced. Which pickup a body represents is decided
		# when it spawns and travels with the spawn message, so the world payload does
		# not have to be rebuilt every time the drop table changes.
		power_up_list.append({"id": (power_up as PowerUp).unique_id})

	return {
		"width": _world_width,
		"height": _world_height,
		"asteroids": asteroid_list,
		"ships": ship_list,
		"power_ups": power_up_list,
	}


func _build_match_starting_payload() -> Dictionary:
	var resets: Array[Dictionary] = []
	for asteroid in asteroids.values():
		resets.append(_reset_entry(asteroid as GameObject))
	for ship in ships.values():
		resets.append(_reset_entry(ship as GameObject))
	return {"resets": resets}


func _reset_entry(obj: GameObject) -> Dictionary:
	return {
		"id": obj.unique_id,
		"px": obj.position.x,
		"py": obj.position.y,
		"vx": obj.velocity.x,
		"vy": obj.velocity.y,
		"rot": obj.rotation,
	}


func apply_match_created(payload: Dictionary) -> void:
	# The host announces the world exactly once, but a duplicate (or a resend to a
	# late joiner that already built it) would otherwise stack a second barrier and a
	# second set of ships on top of the first.
	if barrier != null:
		return

	_world_width = int(payload.get("width", NRConst.WORLD_WIDTH))
	_world_height = int(payload.get("height", NRConst.WORLD_HEIGHT))
	_init_barrier(_world_width, _world_height)

	for ad in payload.get("asteroids", []):
		var asteroid := asteroid_scene.instantiate() as Asteroid
		asteroid.set_world(self)
		asteroid.setup_networked(int(ad["id"]), int(ad["size"]) as NRTypes.AsteroidSize, int(ad["variation"]))
		asteroid.position = Vector2(ad["px"], ad["py"])
		asteroid.velocity = Vector2(ad["vx"], ad["vy"])
		asteroid.rotation = ad["rot"]
		_add_asteroid(asteroid)

	for sd in payload.get("ships", []):
		var ship := ship_scene.instantiate() as Ship
		ship.set_world(self)
		ship.setup_networked(int(sd["id"]), int(sd["peer_id"]), String(sd["entity_id"]), int(sd["color_id"]), int(sd["style_id"]))
		ship.position = Vector2(sd["px"], sd["py"])
		ship.rotation = sd["rot"]
		_add_ship(ship)

	for pd in payload.get("power_ups", []):
		var power_up := power_up_scene.instantiate() as PowerUp
		power_up.set_world(self)
		power_up.setup_networked(int(pd["id"]))
		_add_power_up(power_up)

	_bind_local_ship()
	_world_start()
	if local_ship != null:
		local_ship_changed.emit(local_ship)


func apply_match_starting(payload: Dictionary) -> void:
	for rd in payload.get("resets", []):
		var obj := game_objects.get(int(rd["id"]), null) as GameObject
		if obj == null:
			continue
		obj.is_active = true
		obj.teleport(Vector2(rd["px"], rd["py"]), rd["rot"])
		obj.velocity = Vector2(rd["vx"], rd["vy"])


# --- Client construction of networked projectiles ---------------------------

## Instantiates the scene registered for a projectile type, defaulting to the laser.
func create_projectile_instance(projectile_type: NRTypes.ProjectileType) -> Projectile:
	var scene: PackedScene = projectile_scenes.get(
		projectile_type, projectile_scenes[NRTypes.ProjectileType.LASER])
	return scene.instantiate() as Projectile


func remove_object(unique_id: int) -> void:
	var obj := game_objects.get(unique_id, null) as GameObject
	if obj == null:
		return
	game_objects.erase(unique_id)
	active_projectiles.erase(unique_id)
	asteroids.erase(unique_id)
	ships.erase(unique_id)
	if obj is Ship:
		_ships_by_peer.erase((obj as Ship).owner_peer_id)
	obj.queue_free()
