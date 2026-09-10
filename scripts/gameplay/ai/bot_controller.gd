class_name BotController
extends RefCounted

## Drives one NPC opponent in a practice match.
##
## A bot is a completely ordinary [Ship] whose [ShipInput] is filled in by this class
## instead of by a keyboard or a remote peer. Everything downstream -- movement,
## weapon cooldowns, damage, scoring, respawn -- runs through exactly the same code
## paths a human player's ship does, so bots cannot special-case the simulation.
##
## Bots exist only on the authority, and practice is offline, so nothing here is ever
## replicated. Input is submitted through [method Ship.update_remote_input] rather than
## written onto the ship directly, because that is the same door remote players come
## through: it clamps the vectors and refreshes the idle timeout that would otherwise
## zero the bot's input a second after it started flying.
##
## The behaviour is a small steering blend, evaluated fresh every tick:
##
## [codeblock]
## engage    hold a ring around the target, closing or backing off to reach it
## orbit     circle at that range rather than sitting still in front of the guns
## avoid     push away from asteroids on a collision course, weighted by closeness
## contain   turn back before reaching the barrier
## [/codeblock]
##
## Avoidance is weighted heavily enough to override engagement, so a bot will break
## off an attack run to get out of the way of a rock rather than fly into it -- which
## matters far more now that asteroids split and the field fills with debris.

## Laser muzzle speed, used to lead the target. Read from the same tuning resource the
## projectiles use so a designer retuning the weapon retunes the aim with it.
const _LASER_TUNING: ProjectileTuning = preload("res://assets/tuning/laser_tuning.tres")

## Engagement ring the bot tries to hold, in world units.
const ENGAGE_RANGE_MIN := 220.0
const ENGAGE_RANGE_MAX := 460.0
## Beyond this the bot stops shooting and just closes the distance; a laser's flight
## time past here makes leading guesswork and the shots only litter the arena.
const FIRE_RANGE := 620.0

## How far ahead the bot looks for asteroids, and how much wider than the two radii a
## rock has to clear before it stops being treated as a threat.
const AVOID_LOOKAHEAD := 260.0
const AVOID_MARGIN := 46.0
## Weight of the avoidance vector relative to the engagement vector. Above 1.0 so a
## rock on a collision course always wins the argument.
const AVOID_WEIGHT := 2.4

## Distance from the barrier at which the bot starts turning back, and the weight of
## that correction.
const CONTAIN_MARGIN := 180.0
const CONTAIN_WEIGHT := 2.0

## Seconds between target re-evaluations. Re-picking every frame makes a bot dither
## between two equidistant enemies instead of committing to one.
const RETARGET_INTERVAL := 0.8
## Seconds between orbit direction flips, so bots do not settle into a fixed circle.
const ORBIT_FLIP_INTERVAL := 3.5

## Aim error, in radians, applied as a slowly wandering offset rather than per-frame
## noise -- jitter that changes every frame averages out and reads as perfect aim.
const AIM_ERROR_MAX := 0.075
const AIM_WANDER_RATE := 1.4

## Seconds a bot waits before reacting to a target it has only just acquired, so it
## does not open fire the instant a player respawns in front of it.
const REACTION_DELAY := 0.35

var _world: World = null
var _ship: Ship = null

var _target: Ship = null
var _retarget_timer: float = 0.0
var _orbit_timer: float = 0.0
var _orbit_sign: float = 1.0
var _reaction_timer: float = 0.0
var _aim_phase: float = 0.0
var _aim_error: float = 0.0
var _sequence: int = 0


func _init(world: World, ship: Ship) -> void:
	_world = world
	_ship = ship
	_orbit_sign = 1.0 if randf() < 0.5 else -1.0
	_orbit_timer = randf_range(0.0, ORBIT_FLIP_INTERVAL)
	_retarget_timer = randf_range(0.0, RETARGET_INTERVAL)
	_aim_phase = randf_range(0.0, TAU)


func is_valid() -> bool:
	return _world != null and _ship != null and is_instance_valid(_ship)


func tick(delta: float) -> void:
	if not is_valid():
		return
	if not _ship.is_active or _ship.health <= 0.0:
		# A dead bot is waiting on MatchDirector's respawn timer. Zeroing the input
		# means it does not come back still thrusting in whatever direction it died
		# facing, which looks like the corpse flying away from its own wreck.
		_submit(Vector2.ZERO, Vector2.ZERO)
		_target = null
		_reaction_timer = REACTION_DELAY
		return

	_update_target(delta)
	_update_aim_error(delta)

	var movement := _steer(delta)
	var fire := _aim(delta)
	_submit(movement, fire)


# --- Targeting --------------------------------------------------------------

func _update_target(delta: float) -> void:
	_retarget_timer -= delta
	if _target != null and (not is_instance_valid(_target) or not _target.is_active or _target.health <= 0.0):
		_target = null
	if _target != null and _retarget_timer > 0.0:
		return

	_retarget_timer = RETARGET_INTERVAL
	var previous := _target
	_target = _nearest_enemy()
	if _target != previous:
		_reaction_timer = REACTION_DELAY


func _nearest_enemy() -> Ship:
	var best: Ship = null
	var best_distance := INF
	for candidate in _world.get_ships().values():
		var ship := candidate as Ship
		if ship == null or ship == _ship or not ship.is_active or ship.health <= 0.0:
			continue
		var distance := _ship.position.distance_squared_to(ship.position)
		if distance < best_distance:
			best_distance = distance
			best = ship
	return best


# --- Steering ---------------------------------------------------------------

## Blends engagement, orbiting, asteroid avoidance and barrier containment into the
## single direction vector a ship's "left stick" expects.
func _steer(delta: float) -> Vector2:
	var steering := _engage(delta)
	steering += _avoid_asteroids() * AVOID_WEIGHT
	steering += _contain() * CONTAIN_WEIGHT

	if steering.is_zero_approx():
		return Vector2.ZERO
	return steering.normalized()


func _engage(delta: float) -> Vector2:
	if _target == null:
		# Nothing to fight: drift towards the middle so idle bots do not pile up in a
		# corner where the player never meets them.
		return _toward_center() * 0.35

	_orbit_timer -= delta
	if _orbit_timer <= 0.0:
		_orbit_timer = ORBIT_FLIP_INTERVAL
		_orbit_sign = -_orbit_sign

	var to_target := _target.position - _ship.position
	var distance := to_target.length()
	if distance <= 0.001:
		return Vector2.ZERO
	var direction := to_target / distance
	var orbit := Vector2(-direction.y, direction.x) * _orbit_sign

	if distance > ENGAGE_RANGE_MAX:
		# Close, but keep a little sideways drift so the approach is not a straight
		# line down the target's guns.
		return direction + orbit * 0.25
	if distance < ENGAGE_RANGE_MIN:
		return -direction + orbit * 0.6
	return orbit + direction * 0.15


## Sums a push away from every asteroid the bot is closing on. Rocks are weighted by
## how little clearance is left rather than by raw distance, so a large asteroid is
## given the wider berth it needs.
func _avoid_asteroids() -> Vector2:
	var avoidance := Vector2.ZERO
	var travel := _ship.velocity
	var speed := travel.length()
	var heading := travel / speed if speed > 1.0 else Vector2(sin(_ship.rotation), -cos(_ship.rotation))

	for entry in _world.asteroids.values():
		var asteroid := entry as Asteroid
		if asteroid == null or not asteroid.is_active:
			continue

		var offset := asteroid.position - _ship.position
		var distance := offset.length()
		var clearance := distance - asteroid.radius - _ship.radius - AVOID_MARGIN
		if clearance >= AVOID_LOOKAHEAD or distance <= 0.001:
			continue

		var direction := offset / distance
		# Weight by remaining clearance: touching is 1.0, a lookahead away is 0.0.
		var urgency := 1.0 - clampf(clearance / AVOID_LOOKAHEAD, 0.0, 1.0)
		# Rocks the bot is actually heading into matter more than ones beside or
		# behind it, but never zero -- an asteroid drifting into the bot is still a
		# problem even when the bot is flying the other way.
		var approach := 0.35 + 0.65 * maxf(heading.dot(direction), 0.0)
		# Steering sideways rather than straight backwards keeps the bot moving; a
		# pure reversal has it bounce off the rock's approach vector indefinitely.
		var sidestep := Vector2(-direction.y, direction.x)
		if sidestep.dot(heading) < 0.0:
			sidestep = -sidestep
		avoidance += (-direction * 0.7 + sidestep * 0.7) * urgency * urgency * approach

	return avoidance


## Turns the bot back before it reaches the barrier. Hitting the wall is survivable --
## the body simply bounces -- but a bot pinned against it is a sitting target.
func _contain() -> Vector2:
	var barrier := _world.barrier
	if barrier == null:
		return Vector2.ZERO

	var push := Vector2.ZERO
	var position := _ship.position
	var left := barrier.get_left()
	var right := barrier.get_right()
	var top := barrier.get_top()
	var bottom := barrier.get_bottom()

	push.x += maxf(0.0, 1.0 - (position.x - left) / CONTAIN_MARGIN)
	push.x -= maxf(0.0, 1.0 - (right - position.x) / CONTAIN_MARGIN)
	push.y += maxf(0.0, 1.0 - (position.y - top) / CONTAIN_MARGIN)
	push.y -= maxf(0.0, 1.0 - (bottom - position.y) / CONTAIN_MARGIN)
	return push


func _toward_center() -> Vector2:
	var barrier := _world.barrier
	if barrier == null:
		return Vector2.ZERO
	var center := Vector2(
		(barrier.get_left() + barrier.get_right()) * 0.5,
		(barrier.get_top() + barrier.get_bottom()) * 0.5)
	var offset := center - _ship.position
	return Vector2.ZERO if offset.length_squared() < 1.0 else offset.normalized()


# --- Shooting ---------------------------------------------------------------

## A unit aim vector when the bot should shoot, Vector2.ZERO otherwise. Ship's weapon
## code squares this against `fire_threshold_squared`, so a unit vector fires and a
## zero vector holds.
func _aim(delta: float) -> Vector2:
	if _target == null:
		return Vector2.ZERO

	_reaction_timer = maxf(_reaction_timer - delta, 0.0)
	if _reaction_timer > 0.0:
		return Vector2.ZERO

	var to_target := _target.position - _ship.position
	if to_target.length() > FIRE_RANGE:
		return Vector2.ZERO

	var aim := _lead_target(to_target)
	if aim.is_zero_approx():
		return Vector2.ZERO

	# Never shoot through a rock. Bots that do simply feed the asteroid field and
	# never land a hit, which reads as them ignoring the player entirely.
	if _shot_is_blocked(aim, to_target.length()):
		return Vector2.ZERO

	return aim.rotated(_aim_error)


## First-order intercept: aim at where the target will be once the laser gets there.
## Solved iteratively rather than with the quadratic because two passes converge well
## inside the aim error the bot deliberately carries anyway.
func _lead_target(to_target: Vector2) -> Vector2:
	var muzzle_speed := _LASER_TUNING.velocity
	if muzzle_speed <= 0.0:
		return to_target.normalized() if not to_target.is_zero_approx() else Vector2.ZERO

	var relative_velocity := _target.velocity - _ship.velocity
	var intercept := to_target
	for pass_index in 2:
		var flight_time := intercept.length() / muzzle_speed
		intercept = to_target + relative_velocity * flight_time
	if intercept.is_zero_approx():
		return Vector2.ZERO
	return intercept.normalized()


## Ray-versus-circle against every live asteroid, limited to the segment between the
## bot and its target so rocks behind the target are ignored.
func _shot_is_blocked(direction: Vector2, distance: float) -> bool:
	for entry in _world.asteroids.values():
		var asteroid := entry as Asteroid
		if asteroid == null or not asteroid.is_active:
			continue
		var offset := asteroid.position - _ship.position
		var along := offset.dot(direction)
		if along <= 0.0 or along >= distance:
			continue
		var perpendicular := absf(offset.cross(direction))
		if perpendicular < asteroid.radius + _ship.radius:
			return true
	return false


## Aim error wanders on a sine rather than being re-rolled per frame: per-frame noise
## averages out over a burst and the bot ends up shooting perfectly straight.
func _update_aim_error(delta: float) -> void:
	_aim_phase = fposmod(_aim_phase + AIM_WANDER_RATE * delta, TAU)
	_aim_error = sin(_aim_phase) * AIM_ERROR_MAX


# --- Input submission -------------------------------------------------------

func _submit(movement: Vector2, fire: Vector2) -> void:
	_sequence += 1
	_ship.update_remote_input(movement, fire, false, _sequence)
