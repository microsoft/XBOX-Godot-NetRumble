extends NRScreen

## The gameplay screen. The simulation lives in the world node
## (scenes/gameplay/world.tscn) and the match state machine in MatchDirector; this
## screen hosts both, follows the local ship with a camera, wires world gameplay
## events into the particle manager, draws the HUD (score / health / shield / weapon /
## timer / countdown / roster overlay) and routes the pause and chat/voice actions.
## Match flow (countdown, completion, cancellation) is driven off MatchDirector's
## signals rather than the world directly.
##
## The world, starfield and particle scenes are loaded by path behind
## ResourceLoader.exists() checks, so the screen still opens if one of them is absent.

const _WORLD_SCENE := "res://scenes/gameplay/world.tscn"
const _STARFIELD_SCENE := "res://scenes/gameplay/fx/starfield.tscn"
const _PARTICLES_SCENE := "res://scenes/gameplay/particle_manager.tscn"
const _ROSTER_OVERLAY_SCENE: PackedScene = preload("res://scenes/ui/elements/nr_roster_overlay.tscn")
const _CHAT_ENTRY_SCENE: PackedScene = preload("res://scenes/ui/elements/nr_chat_entry.tscn")

## HUD bar ranges come from the same tuning resource the ships use.
const SHIP_TUNING: ShipTuning = preload("res://assets/tuning/ship_tuning.tres")

## How quickly the camera converges on the local ship, in units of 1/second.
const _CAMERA_SMOOTHING := 8.0

@onready var _roster_anchor: Control = %RosterAnchor
@onready var _score_label: Label = %ScoreLabel
@onready var _timer_label: Label = %TimerLabel
@onready var _weapon_label: Label = %WeaponLabel
@onready var _health_bar: ProgressBar = %HealthBar
@onready var _shield_bar: ProgressBar = %ShieldBar
@onready var _countdown_label: Label = %CountdownLabel
@onready var _chat_log: NRChatLog = %ChatLog

var _world: World = null
var _particles: Node = null
var _director: MatchDirector = null
var _starfield: Node = null
var _camera: Camera2D = null
var _reticle: AimReticle = null
var _roster: NRRosterOverlay = null
var _chat_entry: NRChatEntry = null
## The chat dialog stays open across a send and does not disable its own OK button, and
## verifying a message is now a round-trip to Xbox Services. Without this a second press
## sends the text twice and the refusal reason of the first send is lost.
var _chat_send_in_flight := false
var _chat_context := 0
var _screen_flash: ColorRect = null
var _flash_tween: Tween = null

var _match_finished := false


func _init() -> void:
	allow_back = false


func _ready() -> void:
	super._ready()

	_health_bar.max_value = SHIP_TUNING.health_max
	_shield_bar.max_value = SHIP_TUNING.shield_max
	_style_bar(_health_bar, &"HealthBar")
	_style_bar(_shield_bar, &"ShieldBar")
	_countdown_label.text = ""

	# Gameplay is parented outside this screen's CanvasLayer so a real Camera2D
	# drives the view. Moving a CanvasLayer's contents by hand would also fight
	# the physics server, which owns every entity's transform.
	_starfield = _spawn_scene(_STARFIELD_SCENE, ScreenManager.background_container, false)
	_spawn_world()
	_particles = _spawn_scene(_PARTICLES_SCENE, ScreenManager.world_container, false)
	_setup_camera()
	_setup_reticle()

	_roster = _ROSTER_OVERLAY_SCENE.instantiate()
	_roster_anchor.add_child(_roster)

	_setup_screen_flash()

	_start_director()
	_connect_signals()
	_chat_context = NetManager.begin_match_chat()
	_refresh_roster()
	_apply_overlay_visibility()

	# Report the local player as loaded through the networked path; MatchDirector
	# advances past PLAYERS_JOINING once every player has reported in. Works for
	# host, client (RPCs the host) and offline alike.
	NetManager.report_local_player_loaded()
	_update_loading_indicator()


## HUD bar colours come from project Theme variations (HealthBar / ShieldBar),
## so colours and the StyleBox geometry are kept together in the theme resource.
func _style_bar(bar: ProgressBar, variation: StringName) -> void:
	bar.theme_type_variation = variation


func _spawn_world() -> void:
	if not ResourceLoader.exists(_WORLD_SCENE):
		return
	var packed := load(_WORLD_SCENE) as PackedScene
	if packed == null:
		return
	_world = packed.instantiate() as World
	if _world == null:
		return
	ScreenManager.world_container.add_child(_world)
	_world.gameplay_event.connect(_on_gameplay_event)
	_world.local_ship_changed.connect(_on_local_ship_changed)


## The camera owns smoothing and edge clamping via its built-in limit/smoothing settings.
func _setup_camera() -> void:
	if ScreenManager.world_container == null:
		return
	_camera = Camera2D.new()
	_camera.name = "MatchCamera"
	_camera.position_smoothing_enabled = true
	_camera.position_smoothing_speed = _CAMERA_SMOOTHING
	ScreenManager.world_container.add_child(_camera)
	_camera.make_current()
	var barrier: Barrier = null if _world == null else _world.barrier
	if barrier != null and is_instance_valid(barrier):
		_camera.limit_left = 0
		_camera.limit_top = 0
		_camera.limit_right = int(barrier.get_width())
		_camera.limit_bottom = int(barrier.get_height())


## The mouse aiming crosshair. It goes into the world container next to the camera so
## it resolves to the same world space the shots are fired into, rather than to screen
## space where it would slide off the aim point as the camera moves.
func _setup_reticle() -> void:
	if ScreenManager.world_container == null:
		return
	_reticle = AimReticle.new()
	ScreenManager.world_container.add_child(_reticle)


## Gameplay popups sit above the world CanvasLayer. Keep the mouse reticle's device
## state, but hand the hardware cursor back while pause/options/dialog UI is active.
func on_covered() -> void:
	super.on_covered()
	if _reticle != null:
		_reticle.set_ui_occluded(true)


func on_revealed() -> void:
	super.on_revealed()
	if _reticle != null:
		_reticle.set_ui_occluded(false)


## The world, starfield, particles, reticle and camera are parented outside this
## screen, so they have to be torn down with it.
func _exit_tree() -> void:
	NetManager.end_match_chat(_chat_context)
	for node: Node in [_world, _starfield, _particles, _reticle, _camera]:
		if node != null and is_instance_valid(node):
			node.queue_free()
	_world = null
	_starfield = null
	_particles = null
	_reticle = null
	_camera = null


func _spawn_scene(path: String, parent: Node, to_back: bool) -> Node:
	if not ResourceLoader.exists(path):
		return null
	var packed := load(path) as PackedScene
	if packed == null:
		return null
	var instance := packed.instantiate()
	parent.add_child(instance)
	if to_back:
		parent.move_child(instance, 0)
	return instance


func _start_director() -> void:
	if _world == null:
		return
	_director = MatchDirector.new()
	add_child(_director)
	_director.setup(_world, NetManager.game_mode_type)
	_director.countdown_changed.connect(_on_countdown_changed)
	_director.match_state_changed.connect(_on_match_state_changed)
	_director.score_changed.connect(_on_score_changed)
	_director.match_completed.connect(_on_match_completed)
	_director.match_canceled.connect(_on_match_canceled)


func _connect_signals() -> void:
	NetManager.roster_changed.connect(_refresh_roster)
	NetManager.chat_indicators_changed.connect(_refresh_roster)
	NetManager.server_disconnected.connect(_on_server_disconnected)
	NetManager.player_loaded.connect(_on_player_loaded)
	NetManager.chat_message_received.connect(_on_chat_message_received)
	NetManager.chat_cleared.connect(_chat_log.clear)
	NetManager.chat_text_policy_changed.connect(_refresh_chat_senders)
	PlayerProfile.settings_changed.connect(_apply_overlay_visibility)


func _on_player_loaded(_peer_id: int) -> void:
	_update_loading_indicator()


## While players are still loading the centre label doubles as a "waiting for
## players (n/total)" indicator until MatchDirector starts the countdown.
func _update_loading_indicator() -> void:
	if _director != null and _director.match_state != NRTypes.MatchState.PLAYERS_JOINING \
			and _director.match_state != NRTypes.MatchState.LOADING:
		return
	var total := NetManager.players.size()
	var loaded := 0
	for state in NetManager.players.values():
		if state.in_game:
			loaded += 1
	if loaded < total:
		_countdown_label.add_theme_font_size_override("font_size", 48)
		_countdown_label.text = "Waiting for players (%d/%d)" % [loaded, total]
	else:
		_countdown_label.text = ""


func _process(delta: float) -> void:
	_follow_local_ship(delta)
	_update_hud()


func _on_local_ship_changed(ship: GameObject) -> void:
	# Snap on respawn so the view doesn't sweep across the map.
	if ship != null and _camera != null:
		_camera.position = ship.position
		_camera.reset_smoothing()


## Points the camera at the local ship. Smoothing and edge limits are the camera's
## own, so this is a plain assignment.
func _follow_local_ship(_delta: float) -> void:
	if _world == null or _camera == null:
		return
	var ship: Ship = _world.local_ship
	if ship == null or not is_instance_valid(ship):
		return
	_camera.position = ship.position


func _update_hud() -> void:
	var local := NetManager.local_player()
	_score_label.text = "Score: %d" % (local.score if local != null else 0)
	_timer_label.text = _format_time(_director.time_remaining() if _director != null else 0.0)

	var ship: Ship = null if _world == null else _world.local_ship
	if ship != null and is_instance_valid(ship):
		_health_bar.value = clampf(ship.health, 0.0, SHIP_TUNING.health_max)
		_shield_bar.value = clampf(ship.shield, 0.0, SHIP_TUNING.shield_max)
		_weapon_label.text = "Weapon: %s%s%s" % [
			_weapon_name(int(ship.primary_weapon)),
			_ammo_suffix(ship.weapon_ammo),
			_buff_suffix(ship),
		]
	else:
		_health_bar.value = 0.0
		_shield_bar.value = 0.0
		_weapon_label.text = "Weapon: —"


## Ammo is only worth showing for the weapons that have any: the four originals are
## unlimited and reporting "∞" beside them every frame is just noise.
func _ammo_suffix(ammo: int) -> String:
	return "" if ammo < 0 else " x%d" % ammo


## Lists the buffs currently in effect. There are ten of them and any number can be
## running at once, so they are shown as a compact trailing list rather than given
## their own HUD widget.
func _buff_suffix(ship: Ship) -> String:
	if ship.buffs.is_empty():
		return ""
	var names: Array[String] = []
	for buff_type in ship.buffs.keys():
		names.append(_buff_name(int(buff_type)))
	names.sort()
	return "  [%s]" % " ".join(names)


func _buff_name(buff_type: int) -> String:
	var keys := NRTypes.BuffType.keys()
	if buff_type < 0 or buff_type >= keys.size():
		return "?"
	return String(keys[buff_type]).capitalize()


func _format_time(seconds: float) -> String:
	var total := int(seconds)
	return "%d:%02d" % [total / 60, total % 60]


func _weapon_name(weapon: int) -> String:
	return WeaponLibrary.display_name(weapon as NRTypes.WeaponType).capitalize()


func _on_gameplay_event(event_type: NRTypes.GameplayEventType, position: Vector2) -> void:
	if _particles != null and _particles.has_method("play_event"):
		var local := NetManager.local_player()
		var color := local.color() if local != null else Color.WHITE
		_particles.play_event(event_type, position, color)
	_flash_for_event(event_type, position)


# --- Screen flash -----------------------------------------------------------

## Flash colours and strengths, keyed by event.
const _FLASH_NEAR_DISTANCE := 900.0
const _DESTRUCTION_FLASH_COLOR := Color(1.0, 0.86, 0.62)
const _DESTRUCTION_FLASH_STRENGTH := 0.62
const _DETONATION_FLASH_COLOR := Color(1.0, 0.7, 0.35)
const _DETONATION_FLASH_STRENGTH := 0.22

## A full-screen overlay used to punch the whole view white for a few frames.
##
## Built in code rather than authored into gameplay_screen.tscn: it has no layout to
## speak of, it must sit above every other HUD element, and creating it here keeps the
## flash's colour, opacity and decay in one place next to the code that drives it.
func _setup_screen_flash() -> void:
	_screen_flash = ColorRect.new()
	_screen_flash.name = "ScreenFlash"
	_screen_flash.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_screen_flash.set_anchors_preset(Control.PRESET_FULL_RECT)
	_screen_flash.color = Color(1.0, 1.0, 1.0, 0.0)
	# Drawn additively so a flash brightens the scene rather than washing a flat white
	# sheet over it, which would hide the explosion the player is meant to be looking
	# at.
	var material := CanvasItemMaterial.new()
	material.blend_mode = CanvasItemMaterial.BLEND_MODE_ADD
	_screen_flash.material = material
	_screen_flash.z_index = 100
	add_child(_screen_flash)


## Flashes the view for the events worth flashing for, scaled by how close they were.
##
## Distance-scaled deliberately: with this many explosives in play, flashing at full
## strength for every detonation anywhere on the map would leave the screen strobing.
## A kill across the field registers as a dim pulse; one next to the player fills the
## screen.
func _flash_for_event(event_type: NRTypes.GameplayEventType, position: Vector2) -> void:
	var color := Color.WHITE
	var strength := 0.0
	match event_type:
		NRTypes.GameplayEventType.SHIP_DESTROYED:
			color = _DESTRUCTION_FLASH_COLOR
			strength = _DESTRUCTION_FLASH_STRENGTH
		NRTypes.GameplayEventType.MINE_DETONATED, NRTypes.GameplayEventType.ROCKET_DETONATED:
			color = _DETONATION_FLASH_COLOR
			strength = _DETONATION_FLASH_STRENGTH
		_:
			return

	var ship: Ship = null if _world == null else _world.local_ship
	if ship != null and is_instance_valid(ship):
		var distance := ship.position.distance_to(position)
		strength *= 1.0 - clampf(distance / _FLASH_NEAR_DISTANCE, 0.0, 1.0)
	if strength <= 0.01:
		return
	_flash_screen(color, strength)


func _flash_screen(color: Color, strength: float) -> void:
	if _screen_flash == null:
		return
	if _flash_tween != null:
		_flash_tween.kill()
	# Overlapping flashes take the brighter of the two rather than summing, so a
	# chain of kills cannot stack the screen into solid white.
	var peak := maxf(strength, _screen_flash.color.a)
	_screen_flash.color = Color(color.r, color.g, color.b, peak)
	_flash_tween = create_tween()
	_flash_tween.tween_property(_screen_flash, "color:a", 0.0, 0.35) \
		.set_trans(Tween.TRANS_EXPO).set_ease(Tween.EASE_OUT)


func _on_countdown_changed(seconds_remaining: int) -> void:
	if seconds_remaining > 0:
		_countdown_label.add_theme_font_size_override("font_size", 180)
		_countdown_label.text = str(seconds_remaining)
	else:
		_countdown_label.text = ""


func _on_match_state_changed(state: NRTypes.MatchState) -> void:
	# The centre countdown is shown only during STARTING; hide it
	# once the match is actually running or has ended.
	if state == NRTypes.MatchState.RUNNING or state == NRTypes.MatchState.MATCH_COMPLETE:
		_countdown_label.text = ""


func _on_score_changed(_peer_id: int, _score: int) -> void:
	_refresh_roster()


func _refresh_roster() -> void:
	if _roster != null:
		_roster.refresh(NetManager.players_by_score(), _mic_states())
	_refresh_chat_senders()


func _on_chat_message_received(peer_id: int, text: String) -> void:
	var state: PlayerState = NetManager.players.get(peer_id)
	if state != null and NetManager.can_read_chat_from(peer_id):
		_chat_log.add_message(peer_id, state.display_label(), text)


func _refresh_chat_senders() -> void:
	var names: Dictionary[int, String] = {}
	for state: PlayerState in NetManager.players.values():
		if NetManager.can_read_chat_from(state.peer_id):
			names[state.peer_id] = state.display_label()
	_chat_log.refresh_senders(names)


## Maps peer id -> mic state for the roster overlay, using the same Party chat
## indicators the lobby roster shows.
func _mic_states() -> Dictionary:
	var states := {}
	for state in NetManager.players_by_score():
		match NetManager.chat_indicator_for(state.peer_id):
			ChatService.ChatIndicator.MUTED:
				states[state.peer_id] = "muted"
			ChatService.ChatIndicator.TALKING:
				states[state.peer_id] = "talking"
			ChatService.ChatIndicator.AVAILABLE:
				states[state.peer_id] = "available"
			_:
				states[state.peer_id] = "none"
	return states


func _apply_overlay_visibility() -> void:
	if _roster != null:
		_roster.visible = PlayerProfile.show_roster_overlay


func _on_match_completed(payload: Dictionary) -> void:
	if _match_finished:
		return
	_match_finished = true
	_countdown_label.text = ""
	await _show_results(payload)
	# The host can leave, or the network drop, while the results are being read. The
	# session-loss handlers stand down once _match_finished is set — deliberately, so a
	# host departure does not talk over the scoreboard — which leaves this the place that
	# has to notice, or the player is returned to a lobby with nothing in it.
	if not NetManager.has_session():
		var reason := NetManager.last_disconnect_reason
		await ScreenManager.show_dialog(
			"Disconnected",
			reason if not reason.is_empty() else "The match ended.",
			"error", false)
		ScreenManager.replace_all(ScreenManager.MAIN_MENU)
		return
	if NetManager.is_host():
		NetManager.reset_for_next_match()
	ScreenManager.replace_all(ScreenManager.LOBBY)


func _show_results(payload: Dictionary) -> void:
	var lines: Array[String] = []
	var standings: Array = payload.get("standings", [])
	for entry in standings:
		var placement := int(entry.get("placement", 0))
		# The payload carries the name the host had; each machine prefers the gamertag it
		# verified for that peer itself (XR-047), so the scoreboard does not inherit the
		# host's view of who everyone is.
		var display_name := Services.gamertag_for_peer(int(entry.get("peer_id", 0)))
		if display_name.is_empty():
			display_name = str(entry.get("display_name", "Player"))
		var score := int(entry.get("score", 0))
		lines.append("%d. %s — %d" % [placement, display_name, score])

	var message := "\n".join(lines) if not lines.is_empty() else "The match has ended."
	if String(payload.get("reason", "")) == "last_player_standing":
		message = "Everyone else left the match.\n\n%s" % message
	await ScreenManager.show_dialog("Match Complete", message, "default", false)


func _on_match_canceled() -> void:
	if _match_finished:
		return
	_match_finished = true
	await ScreenManager.show_dialog("Match Canceled", "A player failed to finish loading.", "warning", false)
	NetManager.leave_match()
	ScreenManager.replace_all(ScreenManager.MAIN_MENU)


func _on_server_disconnected() -> void:
	if _match_finished:
		return
	_match_finished = true
	await ScreenManager.show_dialog("Disconnected", NetManager.last_disconnect_reason, "error", false)
	ScreenManager.replace_all(ScreenManager.MAIN_MENU)


func _unhandled_input(event: InputEvent) -> void:
	if not is_active:
		return
	if event.is_action_pressed("toggle_game_menu"):
		get_viewport().set_input_as_handled()
		ScreenManager.push(ScreenManager.GAME_MENU)
	elif event.is_action_pressed("open_voice_chat"):
		get_viewport().set_input_as_handled()
		_open_chat()


## Opens the chat entry with a single-instance guard: pressing the chat action again
## while the dialog is up is a no-op rather than a second modal.
## An account without the communications privilege has no chat control behind the
## dialog, so it is told why instead of being handed an entry box whose send always
## fails (XR-045).
func _open_chat() -> void:
	if _chat_entry != null:
		return
	var reason := NetManager.chat_unavailable_reason()
	if not reason.is_empty():
		await ScreenManager.show_dialog("Chat Unavailable", reason, "warning", false)
		return
	_chat_entry = _CHAT_ENTRY_SCENE.instantiate()
	add_child(_chat_entry)
	_chat_entry.submitted.connect(_on_chat_submitted)
	_chat_entry.cancelled.connect(_on_chat_entry_closed)


func _on_chat_submitted(text: String) -> void:
	# Close on an empty message or a successful send; stay open otherwise so the text
	# survives a failed send and the player can edit and retry. A message the platform
	# refused reports the refusal reason in a dialog over the entry, so the player can
	# see what to change and still has the entered text to edit (XR-018).
	if _chat_send_in_flight:
		return
	_chat_send_in_flight = true
	var sent: bool = text.is_empty() or await NetManager.send_chat_message(text)
	var error := NetManager.last_chat_error
	_chat_send_in_flight = false
	if not is_inside_tree() or not NetManager.is_match_chat_current(_chat_context):
		return
	if sent:
		if _chat_entry != null:
			_chat_entry.queue_free()
			_chat_entry = null
		return
	if not error.is_empty():
		await ScreenManager.show_dialog("Message Not Sent", error, "error", false)


func _on_chat_entry_closed() -> void:
	_chat_entry = null
