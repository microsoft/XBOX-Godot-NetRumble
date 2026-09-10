class_name Ship
extends GameObject

## The player-controlled (or bot-controlled) ship.

## Designer-tunable stats. Overridable per-instance in the inspector.
@export var tuning: ShipTuning = preload("res://assets/tuning/ship_tuning.tres")

var entity_id: String = ""
var owner_peer_id: int = 0
var ship_color_id: int = 0
var ship_style_id: int = 0
var ship_color: Color = Color.WHITE

var shield: float = 0.0
var primary_weapon: NRTypes.WeaponType = NRTypes.WeaponType.LASER
## Volleys left before the ship falls back to the plain laser. -1 is unlimited.
var weapon_ammo: int = -1
var last_damaged_by_id: int = 0

## BuffType -> seconds remaining. Absent means "not active", so the whole buff system
## is a dictionary the rest of the ship queries rather than ten booleans and ten
## timers.
var buffs: Dictionary = {}

var ship_input: ShipInput = ShipInput.new()

## How much the buffs currently in effect change the ship. Kept as named constants
## rather than magic numbers scattered through the query methods, since these are the
## numbers that actually decide whether a buff feels worth chasing.
const RAPID_FIRE_SCALE := 0.45
const AFTERBURNER_SCALE := 1.55
const DOUBLE_DAMAGE_SCALE := 2.0
const OVERSHIELD_SCALE := 2.0
const QUICK_CHARGE_DELAY_SCALE := 0.3
const QUICK_CHARGE_RATE_SCALE := 2.5
const REGENERATION_PER_SECOND := 2.5
const MULTI_SHOT_EXTRA_SHOTS := 2
const MULTI_SHOT_EXTRA_SPREAD := 0.35
const RICOCHET_EXTRA_BOUNCES := 3
const VAMPIRIC_FRACTION := 0.25
const CLOAK_ALPHA := 0.22

var _invulnerability_timer: Timer = null
var _shield_recharge_timer: Timer = null
var _time_to_next_fire: Timer = null
var _time_to_next_mine: Timer = null

var _sprite_base: Sprite2D = null
var _sprite_overlay: Sprite2D = null
var _sprite_shield: Sprite2D = null
var _sprite_thruster: Sprite2D = null
var _contrail: Line2D = null
var _invulnerability_tween: Tween = null


func _init() -> void:
	object_type = NRTypes.GameObjectType.SHIP
	mass = tuning.mass
	radius = tuning.radius


func _ready() -> void:
	_bind_timers()
	super()

func setup(player_state: PlayerState) -> void:
	unique_id = GameObject.allocate_id()
	entity_id = player_state.entity_id
	owner_peer_id = player_state.peer_id
	ship_color_id = player_state.ship_color_id
	ship_style_id = player_state.ship_style_id
	ship_color = Assets.player_color(ship_color_id)


func setup_networked(id: int, peer_id: int, entity: String, color_id: int, style_id: int) -> void:
	unique_id = id
	owner_peer_id = peer_id
	entity_id = entity
	ship_color_id = color_id
	ship_style_id = style_id
	ship_color = Assets.player_color(ship_color_id)


func start() -> void:
	velocity = Vector2.ZERO
	buffs.clear()
	health = tuning.health_max
	shield = shield_maximum()
	_start_cooldown(_invulnerability_timer, tuning.invulnerable_timer_max)
	_stop_cooldown(_shield_recharge_timer)
	_stop_cooldown(_time_to_next_mine)
	set_primary_weapon(NRTypes.WeaponType.LASER)
	ship_input.reset()
	_start_invulnerability_tween()
	_reset_contrail()


func tick(delta: float) -> void:
	# Remote players' input arrives over an unreliable channel, so the authority ages
	# it out rather than steering their ship on a packet that may be seconds old.
	if world != null and world.is_authority and world.local_ship != self:
		ship_input.tick_remote_input(delta)

	_tick_buffs(delta)
	_update_shield(delta)

	_process_controls_movement(delta)
	_process_controls_weapon(delta)
	_process_controls_mine(delta)

	super.tick(delta)
	_update_contrail()


# --- Buffs ------------------------------------------------------------------

## Ages every active buff out and drops the ones that have run down.
##
## Ticked on every peer rather than only on the authority. Buffs change how the ship
## looks (cloak) and how it moves (afterburner), and a client that waited to be told
## a buff had expired would keep predicting a ship that is no longer boosted -- which
## the snapshot then has to yank back. Grants and refreshes are still authority-only
## and replicated, so the two sides start their clocks together.
func _tick_buffs(delta: float) -> void:
	if buffs.is_empty():
		return
	for buff_type in buffs.keys():
		var remaining := float(buffs[buff_type]) - delta
		if remaining <= 0.0:
			buffs.erase(buff_type)
			_on_buff_expired(buff_type as NRTypes.BuffType)
		else:
			buffs[buff_type] = remaining


func grant_buff(buff_type: NRTypes.BuffType, duration: float) -> void:
	# Re-collecting a buff refreshes it rather than stacking, so a player camping a
	# drop cannot bank a minute of double damage.
	buffs[int(buff_type)] = maxf(duration, float(buffs.get(int(buff_type), 0.0)))
	if buff_type == NRTypes.BuffType.OVERSHIELD:
		shield = shield_maximum()


func has_buff(buff_type: NRTypes.BuffType) -> bool:
	return buffs.has(int(buff_type))


func buff_time_remaining(buff_type: NRTypes.BuffType) -> float:
	return float(buffs.get(int(buff_type), 0.0))


## Serialises the buff table for the network. Keys are ints already, so this is only
## flattening the dictionary into something the RPC layer will accept unchanged.
func buff_state() -> Dictionary:
	return buffs.duplicate()


func apply_buff_state(state: Dictionary) -> void:
	var had_overshield := has_buff(NRTypes.BuffType.OVERSHIELD)
	buffs = state.duplicate()
	if had_overshield and not has_buff(NRTypes.BuffType.OVERSHIELD):
		shield = minf(shield, shield_maximum())


func _on_buff_expired(buff_type: NRTypes.BuffType) -> void:
	# The overshield's extra capacity disappears with it, so the surplus has to be
	# trimmed or the ship keeps a shield reading above its own maximum for ever.
	if buff_type == NRTypes.BuffType.OVERSHIELD:
		shield = minf(shield, shield_maximum())


func shield_maximum() -> float:
	return tuning.shield_max * (OVERSHIELD_SCALE if has_buff(NRTypes.BuffType.OVERSHIELD) else 1.0)


## Damage multiplier applied to every shot this ship fires.
func damage_multiplier() -> float:
	return DOUBLE_DAMAGE_SCALE if has_buff(NRTypes.BuffType.DOUBLE_DAMAGE) else 1.0


func extra_shots() -> int:
	return MULTI_SHOT_EXTRA_SHOTS if has_buff(NRTypes.BuffType.MULTI_SHOT) else 0


func extra_spread() -> float:
	return MULTI_SHOT_EXTRA_SPREAD if has_buff(NRTypes.BuffType.MULTI_SHOT) else 0.0


func extra_bounces() -> int:
	return RICOCHET_EXTRA_BOUNCES if has_buff(NRTypes.BuffType.RICOCHET) else 0


## Cloaked ships are skipped by projectile contacts and by bot target selection, so
## the buff genuinely means "cannot be hit" rather than merely "hard to see".
func is_untargetable() -> bool:
	return has_buff(NRTypes.BuffType.CLOAK)


## Credits a fraction of the damage this ship deals back as health, capped at the
## hull maximum. Called by World once a shot's damage has actually been applied.
func credit_vampiric_damage(damage_dealt: float) -> void:
	if damage_dealt <= 0.0 or not has_buff(NRTypes.BuffType.VAMPIRIC):
		return
	health = minf(tuning.health_max, health + damage_dealt * VAMPIRIC_FRACTION)


## Applies a restore pickup. Health is clamped to the hull maximum and shield to
## whatever the current overshield state allows.
func apply_restore(health_restored: float, shield_restored: float) -> void:
	if health_restored > 0.0:
		health = minf(tuning.health_max, health + health_restored)
	if shield_restored > 0.0:
		shield = minf(shield_maximum(), shield + shield_restored)
		_stop_cooldown(_shield_recharge_timer)


## Spends a volley of ammunition, dropping back to the laser when the magazine runs
## dry. Unlimited weapons (ammo -1) are left alone.
func consume_weapon_ammo() -> void:
	if weapon_ammo < 0:
		return
	weapon_ammo -= 1
	if weapon_ammo <= 0:
		set_primary_weapon(NRTypes.WeaponType.LASER)


func set_primary_weapon(weapon: NRTypes.WeaponType) -> void:
	primary_weapon = weapon
	weapon_ammo = WeaponLibrary.get_definition(weapon).ammo
	_stop_cooldown(_time_to_next_fire)


## Snapshot form of [method set_primary_weapon]. Ammo is spent on the authority and
## its consequence -- the weapon itself -- is what gets replicated, so this must not
## reset the cooldown or refill the magazine on every snapshot; it only corrects the
## client's idea of what the ship is holding.
func set_primary_weapon_networked(weapon: NRTypes.WeaponType) -> void:
	if primary_weapon == weapon:
		return
	primary_weapon = weapon
	weapon_ammo = WeaponLibrary.get_definition(weapon).ammo


## Relay a remote player's input onto this ship (called by MatchDirector when it
## receives NetManager.ship_input_received on the authority).
func update_remote_input(movement: Vector2, fire: Vector2, deploy_mine: bool, sequence: int) -> void:
	ship_input.update_remote_input(movement, fire, deploy_mine, sequence)


func on_mine_deployed() -> void:
	_start_cooldown(_time_to_next_mine, tuning.mine_deploy_rate)


func set_invulnerable(invulnerable: bool) -> void:
	if invulnerable:
		_start_cooldown(_invulnerability_timer, tuning.invulnerable_timer_max)
		_start_invulnerability_tween()
	else:
		_stop_cooldown(_invulnerability_timer)
		_stop_invulnerability_tween()


func is_invulnerable() -> bool:
	return _invulnerability_timer != null and not _invulnerability_timer.is_stopped()


func take_damage(source: GameObject, damage: float) -> void:
	if health <= 0.0:
		return
	if source == null:
		return
	if is_invulnerable() or damage <= 0.0:
		return
	# The cloak is a hard immunity, not a to-hit penalty: contacts skip cloaked ships
	# entirely, and this is the backstop for the damage that does not arrive through
	# a contact (splash from an explosion nearby).
	if is_untargetable():
		return

	var delay := tuning.shield_recharge_delay
	if has_buff(NRTypes.BuffType.QUICK_CHARGE):
		delay *= QUICK_CHARGE_DELAY_SCALE
	_start_cooldown(_shield_recharge_timer, delay)

	if shield <= 0.0:
		health -= damage
	else:
		shield -= damage
		if shield < 0.0:
			# Shield overflow (negative) is carried into health.
			health += shield
			shield = 0.0

	last_damaged_by_id = source.unique_id


func apply_authoritative_damage_state(new_health: float, new_shield: float) -> void:
	health = new_health
	shield = new_shield
	_start_cooldown(_shield_recharge_timer, tuning.shield_recharge_delay)


func _process_controls_movement(delta: float) -> void:
	var new_velocity := velocity

	# Forward vector in Godot 2D: rotation 0 = up, increasing rotation = clockwise,
	# so forward = (sin(rotation), -cos(rotation)) with no offset needed.
	var forward := Vector2(sin(rotation), -cos(rotation))
	var right := Vector2(-forward.y, forward.x)

	var left_stick := ship_input.movement_direction
	var sensitivity := left_stick.length_squared()
	var boost := AFTERBURNER_SCALE if has_buff(NRTypes.BuffType.AFTERBURNER) else 1.0
	if sensitivity > 0.0:
		sensitivity = sqrt(sensitivity)

		var stick_forward := left_stick * (1.0 / sensitivity)
		var angle_diff := acos(clampf(stick_forward.dot(forward), -1.0, 1.0))
		var direction := 1.0 if stick_forward.dot(right) > 0.0 else -1.0

		if angle_diff > tuning.angle_threshold:
			var to_rotate := tuning.rotation_per_second * delta
			set_facing(rotation + minf(angle_diff, direction * to_rotate))

		var speed := tuning.speed_max * boost * delta
		new_velocity += left_stick * speed

		var length := new_velocity.length()
		if length > tuning.velocity_max * boost:
			new_velocity *= tuning.velocity_max * boost / length

	var decay := tuning.velocity_decay_rate * delta
	new_velocity -= new_velocity * decay

	velocity = new_velocity


func _process_controls_weapon(_delta: float) -> void:
	if world == null:
		return

	var direction := ship_input.fire_direction
	var sensitivity := direction.length_squared()
	if sensitivity > tuning.fire_threshold_squared:
		set_invulnerable(false)

		if _cooldown_running(_time_to_next_fire):
			return

		var fire_direction := direction.normalized()
		world.create_projectiles(primary_weapon, unique_id, fire_direction)

		# Fire rate is a property of the weapon now, not a per-weapon field on
		# ShipTuning: there are twenty weapons and adding one should not mean
		# editing the ship's tuning resource as well.
		var rate := WeaponLibrary.get_definition(primary_weapon).fire_rate
		if has_buff(NRTypes.BuffType.RAPID_FIRE):
			rate *= RAPID_FIRE_SCALE
		_start_cooldown(_time_to_next_fire, rate)


func _process_controls_mine(_delta: float) -> void:
	if not ship_input.deploy_mine_pressed:
		return

	# The deploy edge is consumed even when cooldown/pool state prevents spawning.
	ship_input.reset_mine_input()

	if world == null or _cooldown_running(_time_to_next_mine):
		return
	if not world.is_authority:
		return

	var backward := Vector2(-sin(rotation), cos(rotation))
	if world.create_mine(unique_id, backward):
		set_invulnerable(false)
		on_mine_deployed()


func _update_shield(delta: float) -> void:
	var recharge_rate := tuning.shield_recharge_rate
	if has_buff(NRTypes.BuffType.QUICK_CHARGE):
		recharge_rate *= QUICK_CHARGE_RATE_SCALE
	if not _cooldown_running(_shield_recharge_timer) and shield < shield_maximum():
		shield = minf(shield_maximum(), shield + recharge_rate * delta)

	if has_buff(NRTypes.BuffType.REGENERATION) and health < tuning.health_max:
		health = minf(tuning.health_max, health + REGENERATION_PER_SECOND * delta)

	radius = tuning.radius if shield > 0.0 else tuning.radius_no_shield


func _build_visuals() -> void:
	_sprite_thruster = $Thruster
	_sprite_base = $Base
	_sprite_overlay = $Overlay
	_sprite_shield = $Shield
	_contrail = get_node_or_null(^"Contrail")
	_sprite_base.texture = Assets.ship_texture(ship_style_id, "Base")
	_sprite_overlay.texture = Assets.ship_texture(ship_style_id, "Overlay")
	_reset_contrail()


## Sprite scale is baked into ship.tscn; only tint, shield alpha and thruster
## visibility are driven from simulation state.
func _update_visuals() -> void:
	if _sprite_base == null:
		return

	# A cloaked ship is drawn as a faint outline rather than removed outright: an
	# invisible ship is impossible to play against, and impossible to debug.
	var cloaked := is_untargetable()
	modulate.a = CLOAK_ALPHA if cloaked else 1.0

	_sprite_base.modulate = ship_color

	var thrusting := velocity.length_squared() > tuning.thruster_velocity_threshold_squared
	_sprite_thruster.visible = thrusting and is_active
	if thrusting:
		var thruster_color := ship_color
		thruster_color.a = 0.75
		_sprite_thruster.modulate = thruster_color

	if shield > 0.0:
		_sprite_shield.visible = true
		var shield_alpha := tuning.shield_alpha_max * shield / maxf(shield_maximum(), 0.001)
		_sprite_shield.modulate = Color(1.0, 1.0, 1.0, shield_alpha)
		if not is_invulnerable():
			_sprite_shield.self_modulate = ship_color
	else:
		_sprite_shield.visible = false


# --- Contrail ---------------------------------------------------------------

## Number of points kept in the trail. At 60Hz this is a little under half a second
## of history, which is long enough to read the ship's arc and short enough that a
## turning fight does not fill the screen with ribbons.
const CONTRAIL_POINTS := 26
## Minimum distance between recorded points, so a stationary ship does not pile
## every frame's position on top of itself and leave a permanent blob.
const CONTRAIL_MIN_STEP := 6.0

## Trail points are kept in world space and the Line2D is left un-transformed, so the
## ribbon stays where the ship has *been* instead of being dragged and spun around
## with the ship's own transform.
func _update_contrail() -> void:
	if _contrail == null:
		return
	if not is_active or not simulation_running:
		_contrail.visible = false
		return

	_contrail.visible = true
	var points := _contrail.points
	if points.is_empty() or position.distance_to(points[points.size() - 1]) >= CONTRAIL_MIN_STEP:
		_contrail.add_point(position)
		while _contrail.get_point_count() > CONTRAIL_POINTS:
			_contrail.remove_point(0)

	# The gradient does the fading: the tail end is transparent, so the ribbon
	# dissolves behind the ship rather than being clipped off.
	var trail_color := ship_color
	trail_color.a = 0.0 if is_untargetable() else 0.85
	_contrail.default_color = trail_color


func _reset_contrail() -> void:
	if _contrail != null:
		_contrail.clear_points()


func _bind_timers() -> void:
	_invulnerability_timer = $InvulnerabilityTimer
	_shield_recharge_timer = $ShieldRechargeTimer
	_time_to_next_fire = $FireCooldownTimer
	_time_to_next_mine = $MineCooldownTimer
	for timer in [_invulnerability_timer, _shield_recharge_timer, _time_to_next_fire, _time_to_next_mine]:
		timer.one_shot = true
		timer.process_callback = Timer.TIMER_PROCESS_PHYSICS
		timer.stop()
	_invulnerability_timer.timeout.connect(_on_invulnerability_timeout)


func _start_cooldown(timer: Timer, duration: float) -> void:
	if timer == null:
		return
	timer.wait_time = maxf(duration, 0.001)
	timer.start()


func _stop_cooldown(timer: Timer) -> void:
	if timer != null:
		timer.stop()


func _cooldown_running(timer: Timer) -> bool:
	return timer != null and not timer.is_stopped()


func _start_invulnerability_tween() -> void:
	if _sprite_shield == null:
		return
	if _invulnerability_tween != null:
		_invulnerability_tween.kill()
	_invulnerability_tween = create_tween()
	_invulnerability_tween.set_loops()
	_invulnerability_tween.set_process_mode(Tween.TWEEN_PROCESS_PHYSICS)
	var colours: Array[Color] = [
		Color.RED,
		Color.YELLOW,
		Color.GREEN,
		Color.CYAN,
		Color.BLUE,
		Color.MAGENTA,
		Color.RED,
	]
	for colour in colours:
		_invulnerability_tween.tween_property(_sprite_shield, "self_modulate", colour, 1.0 / 5.0)
	if not simulation_running:
		_invulnerability_tween.pause()


func _stop_invulnerability_tween() -> void:
	if _invulnerability_tween != null:
		_invulnerability_tween.kill()
		_invulnerability_tween = null
	if _sprite_shield != null:
		_sprite_shield.self_modulate = ship_color


func _on_invulnerability_timeout() -> void:
	_stop_invulnerability_tween()


func _on_simulation_running_changed(running: bool) -> void:
	if _invulnerability_tween == null:
		return
	if running:
		_invulnerability_tween.play()
	else:
		_invulnerability_tween.pause()
