class_name MatchDirector
extends Node

## Match orchestration: owns the MatchState machine, ship respawn queue, scoring
## rules and win conditions.
##
## The World node underneath stays a pure simulation and is driven from here. Keeping
## the two separate means MatchDirector can pause, rewind or skip phases without
## touching the physics objects, and World never needs to know about score or respawn.
##
## The host runs the full state machine. Clients only mirror state pushed down by the
## host through NetManager.

signal match_state_changed(state: NRTypes.MatchState)
signal match_state_entered(state: NRTypes.MatchState)
signal match_state_exited(state: NRTypes.MatchState)
signal countdown_changed(seconds_remaining: int)
signal score_changed(peer_id: int, score: int)
signal match_completed(payload: Dictionary)
signal match_canceled()

var world: Node = null
var match_state: NRTypes.MatchState = NRTypes.MatchState.LOADING
var game_mode_type: NRTypes.GameModeType = NRTypes.GameModeType.DEATHMATCH

var elapsed_match_time: float = 0.0
var starting_time_remaining: float = 0.0

var _is_authority: bool = false
var _world_update_timer: float = 0.0
var _clock_broadcast_timer: float = 0.0
var _last_countdown_broadcast: int = -1
var _loading_timer: Timer = null
var _starting_timer: Timer = null
## Set while the platform has the title constrained (XR-001). Independent of the match
## state machine: the match stays in whatever phase it was in, it just stops advancing.
var _externally_paused: bool = false
## One one-shot timer per destroyed ship. Fires asynchronously so multiple deaths in
## the same tick each get their own respawn countdown without interfering.
var _ship_respawns: Dictionary = {}


func _ready() -> void:
	if _loading_timer == null:
		_create_timers()
	set_physics_process(false)
	# The lifecycle handler in main.gd reaches the running match through this group
	# rather than a direct reference, the same way screens reach the shutdown path.
	add_to_group(&"match_director")
	NetManager.match_state_changed.connect(_on_remote_match_state_changed)
	NetManager.countdown_changed.connect(_on_remote_countdown_changed)
	NetManager.match_clock_received.connect(_on_remote_match_clock)
	NetManager.match_completed_received.connect(_on_remote_match_completed)
	NetManager.ship_input_received.connect(_on_ship_input_received)
	NetManager.player_left.connect(_on_player_left)


## `world_node` is the instantiated `scenes/gameplay/world.tscn` root.
func setup(world_node: Node, mode: NRTypes.GameModeType) -> void:
	if _loading_timer == null:
		_create_timers()
	world = world_node
	game_mode_type = mode
	_is_authority = NetManager.is_host()

	if world != null and world.has_signal("ship_destroyed"):
		world.ship_destroyed.connect(_on_ship_destroyed)

	var states: Array[PlayerState] = NetManager.sorted_players()
	if world != null and world.has_method("initialize"):
		world.initialize(_is_authority, mode, states)

	_reset_timers()
	_set_match_state(NRTypes.MatchState.PLAYERS_JOINING if _is_authority else NRTypes.MatchState.LOADING)

	# A match can be built while the title is already constrained -- an invite redeeming
	# behind an open Guide is the realistic case -- and the constrain notification for it
	# fired before this director existed, so the current state is read rather than waited
	# for.
	var app_root := get_tree().get_first_node_in_group(&"app_root")
	if app_root != null and app_root.has_method(&"is_constrained"):
		set_externally_paused(app_root.is_constrained())

	# The world is announced to clients exactly once, from `world.start_match()`,
	# so every peer builds its entities from a single authoritative layout.
	set_physics_process(true)


func _reset_timers() -> void:
	elapsed_match_time = 0.0
	starting_time_remaining = 0.0
	_world_update_timer = 0.0
	_clock_broadcast_timer = 0.0
	_last_countdown_broadcast = -1
	_stop_phase_timers()
	_clear_ship_respawns()


func _physics_process(delta: float) -> void:
	if world == null:
		return

	# Constrained *offline*: the world is already frozen by the simulation gate, but the
	# clocks, countdown and respawn logic live here and would otherwise keep advancing
	# behind the Guide and jump on return. An online match deliberately keeps running --
	# see _constrain_freezes_simulation().
	if _externally_paused and _constrain_freezes_simulation():
		return

	if not _is_authority:
		# Clients only tick the world so interpolation and local prediction advance;
		# all authoritative outcomes arrive via snapshots.
		world.tick(delta)
		# The match clock is host-owned, but it has to keep moving locally between
		# the host's updates or the HUD timer sits frozen on the client.
		if NRTypes.has_match_state(match_state, NRTypes.MatchState.RUNNING):
			elapsed_match_time += delta
		return

	if not NRTypes.has_match_state(match_state, NRTypes.MatchState.MATCH_COMPLETE):
		_tick_ship_destroyed_logic()

	if NRTypes.has_match_state(match_state, NRTypes.MatchState.PLAYERS_JOINING):
		_handle_players_loading(delta)
	elif NRTypes.has_match_state(match_state, NRTypes.MatchState.STARTING):
		_handle_starting()
	elif NRTypes.has_match_state(match_state, NRTypes.MatchState.RUNNING):
		_handle_running(delta)


# --- Match state ticks ------------------------------------------------------

func _handle_players_loading(delta: float) -> void:
	# Players can keep flying while others finish loading.
	world.tick(delta)

	var all_loaded := true
	for peer_id in NetManager.players:
		if not (NetManager.players[peer_id] as PlayerState).in_game:
			all_loaded = false
			break

	if all_loaded:
		# Single round setup: the world picks every spawn point once here, hands the
		# finished layout to the clients, and nothing is repositioned again until the
		# match is over. The countdown then runs on that final layout.
		world.start_match()
		_set_match_state(NRTypes.MatchState.STARTING)


func _handle_starting() -> void:
	starting_time_remaining = _starting_timer.time_left if _starting_timer != null else 0.0
	_broadcast_countdown(starting_time_remaining)


func _handle_running(delta: float) -> void:
	elapsed_match_time += delta
	world.tick(delta)

	_world_update_timer += delta
	var interval := 1.0 / NRConst.WORLD_SNAPSHOT_HZ
	if _world_update_timer >= interval:
		_world_update_timer = 0.0
		if world.has_method("broadcast_snapshot"):
			world.broadcast_snapshot()

	_clock_broadcast_timer += delta
	if _clock_broadcast_timer >= 1.0 / NRConst.MATCH_CLOCK_HZ:
		_clock_broadcast_timer = 0.0
		NetManager.broadcast_match_clock(elapsed_match_time)

	_check_for_match_time_limit_met()


# --- Ship destruction, scoring and respawn ---------------------------------

func _tick_ship_destroyed_logic() -> void:
	if not world.has_method("get_ships"):
		return

	var destroyed: Array = []
	var ships: Dictionary = world.get_ships()
	for unique_id in ships:
		var ship = ships[unique_id]
		if ship == null or not is_instance_valid(ship):
			continue
		if not ship.is_active:
			continue
		if ship.health > 0.0:
			continue
		destroyed.append(ship)

	if destroyed.is_empty():
		return

	# Deterministic ordering so host and clients agree on scoring order.
	destroyed.sort_custom(func(a, b) -> bool: return a.unique_id < b.unique_id)

	var score_deaths := NRTypes.has_match_state(match_state, NRTypes.MatchState.RUNNING)
	for ship in destroyed:
		ship.die()
		NetManager.broadcast_ship_destroyed({
			"ship_id": ship.unique_id,
			"peer_id": _peer_id_for_ship(ship),
		})
		if score_deaths:
			_update_score(ship, ships)

	if score_deaths:
		_check_for_match_score_met()

	for ship in destroyed:
		if not NRTypes.has_match_state(match_state, NRTypes.MatchState.MATCH_COMPLETE):
			_queue_ship_respawn(ship)


## Scoring rule: killing yourself, or dying to anything that isn't another player's
## projectile, costs a point instead of awarding one.
func _update_score(ship, ships: Dictionary) -> void:
	if ship == null:
		return

	var killer = null
	var damager = world.get_game_object(ship.last_damaged_by_id) if world.has_method("get_game_object") else null
	if damager != null and is_instance_valid(damager):
		if damager.object_type == NRTypes.GameObjectType.PROJECTILE:
			killer = ships.get(damager.owner_id, null)

	if killer != null and killer != ship:
		_apply_score_delta(_peer_id_for_ship(killer), 1)
	else:
		_apply_score_delta(_peer_id_for_ship(ship), -1)


func _apply_score_delta(peer_id: int, delta: int) -> void:
	var state: PlayerState = NetManager.players.get(peer_id, null)
	if state == null:
		return
	# Deaths can't push a score below zero.
	if delta < 0 and state.score <= 0:
		return

	state.score = maxi(state.score + delta, 0)
	NetManager.broadcast_score_updated({"peer_id": peer_id, "score": state.score, "delta": delta})
	score_changed.emit(peer_id, state.score)


func _queue_ship_respawn(ship) -> void:
	if ship == null or not is_instance_valid(ship):
		return
	_cancel_ship_respawn(ship)
	var timer := Timer.new()
	timer.one_shot = true
	timer.process_callback = Timer.TIMER_PROCESS_PHYSICS
	timer.wait_time = NRConst.SHIP_RESPAWN_DELAY
	timer.paused = not _state_runs_simulation()
	add_child(timer)
	_ship_respawns[ship.unique_id] = timer
	timer.timeout.connect(_on_ship_respawn_timeout.bind(ship, timer))
	timer.start()


func _on_ship_respawn_timeout(ship, timer: Timer) -> void:
	if ship == null or not is_instance_valid(ship):
		if timer != null:
			timer.queue_free()
		return
	_ship_respawns.erase(ship.unique_id)
	if world != null and not NRTypes.has_match_state(match_state, NRTypes.MatchState.MATCH_COMPLETE):
		var spawn_point: Vector2 = world.find_spawn_point(ship.radius)
		world.respawn_ship(ship, spawn_point)
		NetManager.broadcast_ship_spawned({
			"ship_id": ship.unique_id,
			"peer_id": _peer_id_for_ship(ship),
			"px": spawn_point.x,
			"py": spawn_point.y,
		})
	if timer != null:
		timer.queue_free()


func _on_ship_destroyed(_ship, _killer_peer_id: int) -> void:
	# Destruction is polled in _tick_ship_destroyed_logic rather than handled in
	# the signal, so that all deaths in a tick are processed in a single ordered
	# pass after World has finished iterating game_objects.
	pass


# --- Win conditions ---------------------------------------------------------

func _check_for_match_time_limit_met() -> void:
	if elapsed_match_time >= Assets.game_mode(game_mode_type).time_limit:
		_complete_match("time_limit")


func _check_for_match_score_met() -> void:
	var target := Assets.game_mode(game_mode_type).target_score
	for peer_id in NetManager.players:
		if (NetManager.players[peer_id] as PlayerState).score >= target:
			_complete_match("score_limit")
			return


## A match with a single player left has nobody to play against, so it ends rather
## than leaving the last player flying around an empty world. Offline play is exempt:
## it is a legitimate one-player session and never sees a peer leave anyway.
func _check_for_last_player_standing() -> void:
	if not _is_authority or NetManager.is_offline():
		return
	if NRTypes.has_match_state(match_state, NRTypes.MatchState.MATCH_COMPLETE):
		return
	if NetManager.players.size() > 1:
		return
	_complete_match("last_player_standing")


func _complete_match(reason: String) -> void:
	if NRTypes.has_match_state(match_state, NRTypes.MatchState.MATCH_COMPLETE):
		return
	_set_match_state(NRTypes.MatchState.MATCH_COMPLETE)

	var standings: Array[Dictionary] = []
	var ranked := NetManager.players_by_score()
	for i in ranked.size():
		standings.append({
			"peer_id": ranked[i].peer_id,
			"display_name": ranked[i].display_name,
			"score": ranked[i].score,
			"placement": i + 1,
		})

	var payload := {
		"reason": reason,
		"game_mode": Assets.game_mode(game_mode_type).display_name,
		"elapsed": elapsed_match_time,
		"standings": standings,
	}
	NetManager.broadcast_match_completed(payload)
	# broadcast_match_completed only raises NetManager's *_received signal, which the
	# authority ignores, so the host announces its own completion here. Without this
	# the host sits in the finished world while every client returns to the lobby.
	match_completed.emit(payload)
	_report_result(payload)


## Writes match result stats and history when a match completes.
func _report_result(payload: Dictionary) -> void:
	if Services == null or not Services.has_method("report_match_result"):
		return
	var local := NetManager.local_player()
	if local == null:
		return
	for entry in payload["standings"]:
		if int(entry["peer_id"]) == local.peer_id:
			Services.report_match_result({
				"game_mode": payload["game_mode"],
				# The display name is what the Match History screen shows; the enum is
				# what the achievement rules key on, and neither is derivable from the
				# other once the name is localised.
				"game_mode_type": int(game_mode_type),
				"score": local.score,
				"placement": int(entry["placement"]),
				"player_count": payload["standings"].size(),
				"human_count": _human_player_count(),
			})
			return


## Players on the scoreboard who are not practice bots. Used by the achievement rules
## that ask for a populated match rather than one padded out with AI.
func _human_player_count() -> int:
	var count := 0
	for peer_id in NetManager.players:
		if not (NetManager.players[peer_id] as PlayerState).is_bot:
			count += 1
	return count


# --- Input relay ------------------------------------------------------------

func _on_ship_input_received(peer_id: int, movement: Vector2, fire: Vector2, deploy_mine: bool, sequence: int) -> void:
	if not _is_authority or world == null:
		return
	var ship = world.get_ship_for(peer_id)
	if ship == null or not is_instance_valid(ship):
		return
	ship.update_remote_input(movement, fire, deploy_mine, sequence)


func _on_player_left(peer_id: int) -> void:
	if not _is_authority or world == null:
		return

	var ship = world.get_ship_for(peer_id)
	if ship != null:
		# Purge any pending respawn so a player who leaves mid-respawn isn't resurrected.
		_cancel_ship_respawn(ship)
	world.remove_ship_for(peer_id)
	_check_for_last_player_standing()


# --- State plumbing ---------------------------------------------------------

func _set_match_state(state: NRTypes.MatchState) -> void:
	if match_state == state:
		return
	var previous := match_state
	_exit_match_state(previous)
	match_state_exited.emit(previous)
	match_state = state
	_apply_simulation_gate()
	if _is_authority:
		NetManager.set_match_state(state)
	match_state_changed.emit(state)
	_enter_match_state(state)
	match_state_entered.emit(state)


func _enter_match_state(state: NRTypes.MatchState) -> void:
	if NRTypes.has_match_state(state, NRTypes.MatchState.RUNNING):
		# Both peers restart the clock here; the host then keeps the client's copy
		# honest through broadcast_match_clock.
		elapsed_match_time = 0.0
		_clock_broadcast_timer = 0.0
	if not _is_authority:
		return
	if NRTypes.has_match_state(state, NRTypes.MatchState.PLAYERS_JOINING):
		_start_phase_timer(_loading_timer, NRConst.SIMULATION_DELAY_PLAYERS_LOADING)
	elif NRTypes.has_match_state(state, NRTypes.MatchState.STARTING):
		starting_time_remaining = NRConst.SIMULATION_DELAY_STARTING
		_start_phase_timer(_starting_timer, NRConst.SIMULATION_DELAY_STARTING)
		_broadcast_countdown(starting_time_remaining)
	elif NRTypes.has_match_state(state, NRTypes.MatchState.RUNNING):
		elapsed_match_time = 0.0


func _exit_match_state(state: NRTypes.MatchState) -> void:
	if NRTypes.has_match_state(state, NRTypes.MatchState.PLAYERS_JOINING):
		_stop_phase_timer(_loading_timer)
	elif NRTypes.has_match_state(state, NRTypes.MatchState.STARTING):
		_stop_phase_timer(_starting_timer)
		starting_time_remaining = 0.0


func _create_timers() -> void:
	_loading_timer = _new_phase_timer("LoadingTimer", _on_loading_timeout)
	_starting_timer = _new_phase_timer("StartingTimer", _on_starting_timeout)


func _new_phase_timer(timer_name: String, callback: Callable) -> Timer:
	var timer := Timer.new()
	timer.name = timer_name
	timer.one_shot = true
	timer.process_callback = Timer.TIMER_PROCESS_PHYSICS
	timer.timeout.connect(callback)
	add_child(timer)
	return timer


func _start_phase_timer(timer: Timer, duration: float) -> void:
	if timer == null:
		return
	timer.wait_time = duration
	timer.start()


func _stop_phase_timer(timer: Timer) -> void:
	if timer != null:
		timer.stop()


func _stop_phase_timers() -> void:
	_stop_phase_timer(_loading_timer)
	_stop_phase_timer(_starting_timer)


## Phase timers tick on the physics callback, which keeps running while the title is
## constrained, so freezing the world is not enough to stop the loading and countdown
## phases from expiring behind the Guide.
func _set_phase_timers_paused(paused: bool) -> void:
	if _loading_timer != null:
		_loading_timer.paused = paused
	if _starting_timer != null:
		_starting_timer.paused = paused


func _on_loading_timeout() -> void:
	if not _is_authority or not NRTypes.has_match_state(match_state, NRTypes.MatchState.PLAYERS_JOINING):
		return
	# A player never finished loading. Move to a terminal state so this branch
	# can't re-fire and spam the cancellation every frame.
	_set_match_state(NRTypes.MatchState.MATCH_COMPLETE)
	match_canceled.emit()


func _on_starting_timeout() -> void:
	if not _is_authority or not NRTypes.has_match_state(match_state, NRTypes.MatchState.STARTING):
		return
	# The ships are already sitting on their final spawn points; going live only
	# has to thaw the simulation, which `_apply_simulation_gate()` does.
	_set_match_state(NRTypes.MatchState.RUNNING)


func _cancel_ship_respawn(ship) -> void:
	if ship == null or not is_instance_valid(ship):
		return
	var timer := _ship_respawns.get(ship.unique_id, null) as Timer
	if timer != null:
		timer.stop()
		timer.queue_free()
	_ship_respawns.erase(ship.unique_id)


func _clear_ship_respawns() -> void:
	for timer in _ship_respawns.values():
		var respawn_timer := timer as Timer
		if respawn_timer != null:
			respawn_timer.stop()
			respawn_timer.queue_free()
	_ship_respawns.clear()


func _state_runs_simulation() -> bool:
	return NRTypes.has_match_state(match_state, NRTypes.MatchState.PLAYERS_JOINING) \
		or NRTypes.has_match_state(match_state, NRTypes.MatchState.RUNNING)


func _set_respawn_timers_paused(paused: bool) -> void:
	for timer in _ship_respawns.values():
		var respawn_timer := timer as Timer
		if respawn_timer != null:
			respawn_timer.paused = paused


## The bodies are driven by the physics engine, so between match phases they have to
## be frozen explicitly rather than simply not being ticked.
func _apply_simulation_gate() -> void:
	if world == null or not world.has_method("set_simulation_running"):
		return
	# The constrain freeze outranks the match phase, but only offline: freezing one peer
	# of a live session desyncs it from the rest, and freezing the host stops the match
	# for everybody.
	if _externally_paused and _constrain_freezes_simulation():
		world.set_simulation_running(false)
		_set_respawn_timers_paused(true)
		_set_phase_timers_paused(true)
		return
	# Unpaused before the authority split, so a client that was constrained gets its
	# timers back too even though it is not the one that started them.
	_set_phase_timers_paused(false)
	if not _is_authority:
		# Clients keep simulating so prediction and interpolation stay warm, but they
		# have to hold still through the start countdown as well -- otherwise the local
		# ship drifts away from the host and snaps back on the first snapshot.
		world.set_simulation_running(not NRTypes.has_match_state(match_state, NRTypes.MatchState.STARTING))
		return
	var running := _state_runs_simulation()
	world.set_simulation_running(running)
	_set_respawn_timers_paused(not running)


## XR-001 requires a constrained title to pause, but a networked match is *shared*: a
## constrained host that stops simulating halts the match for every other player, and a
## constrained client stops relaying its input and falls behind. Online sessions
## therefore keep simulating -- `main.gd` still mutes audio for the constrain -- and only
## offline play actually freezes.
func _constrain_freezes_simulation() -> bool:
	return NetManager.is_offline()


## Freezes or thaws the match from outside the state machine, for the platform constrain
## path in `main.gd` (XR-001). The match keeps whatever phase it was in — this is a pause,
## not a state transition — so nothing here touches `match_state` and no match state is
## broadcast to the other peers.
func set_externally_paused(paused: bool) -> void:
	if _externally_paused == paused:
		return
	_externally_paused = paused
	_apply_simulation_gate()


func is_externally_paused() -> bool:
	return _externally_paused


func _on_remote_countdown_changed(seconds_remaining: int) -> void:
	if _is_authority:
		return
	countdown_changed.emit(seconds_remaining)


func _on_remote_match_clock(elapsed: float) -> void:
	if _is_authority:
		return
	elapsed_match_time = elapsed


func _on_remote_match_state_changed(state: NRTypes.MatchState) -> void:
	if _is_authority:
		return
	var previous := match_state
	_exit_match_state(previous)
	match_state_exited.emit(previous)
	match_state = state
	_apply_simulation_gate()
	match_state_changed.emit(state)
	_enter_match_state(state)
	match_state_entered.emit(state)


func _on_remote_match_completed(payload: Dictionary) -> void:
	if _is_authority:
		return
	var previous := match_state
	_exit_match_state(previous)
	match_state_exited.emit(previous)
	match_state = NRTypes.MatchState.MATCH_COMPLETE
	_apply_simulation_gate()
	match_completed.emit(payload)
	# Clients record their own result too; the host's write only covers the host.
	_report_result(payload)
	match_state_entered.emit(match_state)


func _broadcast_countdown(seconds_remaining: float) -> void:
	var whole := int(ceilf(maxf(seconds_remaining, 0.0)))
	if whole == _last_countdown_broadcast:
		return
	_last_countdown_broadcast = whole
	NetManager.broadcast_countdown(whole)
	countdown_changed.emit(whole)


func _peer_id_for_ship(ship) -> int:
	if ship == null or not is_instance_valid(ship):
		return 0
	return ship.owner_peer_id


func is_running() -> bool:
	return NRTypes.has_match_state(match_state, NRTypes.MatchState.RUNNING)


func is_playable() -> bool:
	return NRTypes.has_match_state(match_state, NRTypes.MatchState.PLAYABLE)


func time_remaining() -> float:
	return maxf(Assets.game_mode(game_mode_type).time_limit - elapsed_match_time, 0.0)
