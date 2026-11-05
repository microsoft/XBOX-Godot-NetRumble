extends Node

## Session controller for UI-background clocks, accessibility pauses and covered pipeline warm-up.

signal state_changed
signal _prepare_finished

const WAVES := &"waves"
const GLOW := &"glow"
const BACKGROUND_GROUP := &"ui_background_motion"
const TOGGLE_ACTION := &"toggle_background_motion"
const DESKTOP_PAUSE_SHORTCUT := "Ctrl+Shift+M / View"
const CONSOLE_PAUSE_SHORTCUT := "View"

const STATE_DISABLED := 0
const STATE_PAUSED := 1
const STATE_RUNNING := 2

const WAVES_SCRIPT_PATH := "res://scripts/ui/backgrounds/waves_background.gd"
const GLOW_SCRIPT_PATH := "res://scripts/ui/backgrounds/glow_background.gd"
const SHIP_CARD_SHADER_PATH := "res://assets/ui/ship_card.gdshader"
const SHIP_PREVIEW_SHADER_PATH := "res://assets/ui/ship_preview.gdshader"
const WARM_UP_TIME := 13.0
const WARM_UP_FRAMES := 3
const WARM_UP_TIMEOUT_USEC := 2000000
const ACTIVATION_SECONDS := 3.0

var time_override: float = -1.0:
	set(value):
		if time_override == value:
			return
		_sync_all_clocks()
		time_override = value
		_recompute_all_clocks()
		state_changed.emit()

var session_paused: bool = false:
	set(value):
		if session_paused == value:
			return
		_sync_all_clocks()
		session_paused = value
		_update_effective_transition()
		_recompute_all_clocks()
		state_changed.emit()

## Test seam for the headless background-motion suite. Production never changes this.
var test_force_gpu := false

var _constrained := false
var _suspended := false
var _pipelines_warmed := false
var _family_elapsed: Dictionary[StringName, float] = {}
var _family_last_usec: Dictionary[StringName, int] = {}
var _family_running: Dictionary[StringName, bool] = {}
var _family_skip_next_delta: Dictionary[StringName, bool] = {}
var _activation_elapsed: Dictionary[StringName, float] = {}
var _adapter_family: Dictionary[int, StringName] = {}
var _adapter_eligible: Dictionary[int, bool] = {}

var _waves_script: Script
var _glow_script: Script
var _ship_card_shader: Shader
var _ship_preview_shader: Shader
var _preparing := false
var _prepare_cancelled := false
var _warm_up_nodes: Array[CanvasItem] = []
var _prepare_warning_sent := false
var _draw_serial := 0
var _last_effective_enabled := false


func _ready() -> void:
	if PlayerProfile != null and not PlayerProfile.settings_changed.is_connected(
			_on_profile_settings_changed
	):
		PlayerProfile.settings_changed.connect(_on_profile_settings_changed)
	RenderingServer.frame_post_draw.connect(_on_frame_post_draw)
	_ensure_family(WAVES)
	_ensure_family(GLOW)
	_last_effective_enabled = effective_enabled()


## True only when the persisted preference, renderer support and covered warm-up all allow motion.
## Session pause, constrain and suspension are PAUSED states, not disabled states.
func effective_enabled() -> bool:
	return PlayerProfile.animate_backgrounds and _renderer_supported() and _pipelines_warmed


func time_for(family: StringName) -> float:
	if time_override >= 0.0:
		return time_override
	if family != WAVES and family != GLOW:
		return 0.0
	_ensure_family(family)
	_sync_family(family)
	return _family_elapsed[family]


## A deterministic capture override and every disabled state report the fully enabled value.
## Otherwise this ramp advances only while the family runs and restarts solely after
## DISABLED -> ENABLED.
func envelope_for(family: StringName) -> float:
	if time_override >= 0.0 or not effective_enabled():
		return 1.0
	if family != WAVES and family != GLOW:
		return 1.0
	_ensure_family(family)
	var progress := clampf(_activation_elapsed[family] / ACTIVATION_SECONDS, 0.0, 1.0)
	return progress * progress * (3.0 - 2.0 * progress)


func state_for(family: StringName) -> int:
	if not effective_enabled():
		return STATE_DISABLED
	if (
		time_override >= 0.0
		or session_paused
		or _constrained
		or _suspended
		or not _family_has_eligible_adapter(family)
	):
		return STATE_PAUSED
	return STATE_RUNNING


## Adapters call this whenever inherited visibility or process eligibility changes.
func set_adapter_eligibility(adapter: Object, family: StringName, eligible: bool) -> void:
	if adapter == null:
		return
	var instance_id := adapter.get_instance_id()
	var old_family := family
	if _adapter_family.has(instance_id):
		old_family = _adapter_family[instance_id]
		var old_eligible: bool = _adapter_eligible[instance_id]
		if old_family == family and old_eligible == eligible:
			return
		_sync_family(old_family)
	_adapter_family[instance_id] = family
	_adapter_eligible[instance_id] = eligible
	_sync_family(family)
	_recompute_family(old_family)
	if old_family != family:
		_recompute_family(family)
	state_changed.emit()


func remove_adapter(adapter: Object) -> void:
	if adapter == null:
		return
	var instance_id := adapter.get_instance_id()
	if not _adapter_family.has(instance_id):
		return
	var family: StringName = _adapter_family[instance_id]
	_sync_family(family)
	_adapter_family.erase(instance_id)
	_adapter_eligible.erase(instance_id)
	_recompute_family(family)
	state_changed.emit()


func set_constrained(value: bool) -> void:
	if _constrained == value:
		return
	_sync_all_clocks()
	_constrained = value
	_recompute_all_clocks()
	state_changed.emit()


func is_constrained() -> bool:
	return _constrained


func set_suspended(value: bool) -> void:
	if _suspended == value:
		return
	_sync_all_clocks()
	_suspended = value
	_recompute_all_clocks()
	state_changed.emit()


func is_suspended() -> bool:
	return _suspended


func is_warmed() -> bool:
	return _pipelines_warmed


func is_preparing() -> bool:
	return _preparing


func wait_for_prepare() -> void:
	if _preparing:
		await _prepare_finished


## Ends a warm-up in flight at once and leaves motion static: its draws leave the tree now, and the
## awaiting prepare() returns on its next frame without counting any further draws. A later covered
## call may retry.
func cancel_prepare() -> void:
	if not _preparing:
		return
	_prepare_cancelled = true
	_remove_warm_up_nodes(_warm_up_nodes)


func pause_shortcut_label() -> String:
	return CONSOLE_PAUSE_SHORTCUT if NRScreen.is_console() else DESKTOP_PAUSE_SHORTCUT


func shortcut_available() -> bool:
	return _has_visible_enabled_background()


func front_end_background_visible() -> bool:
	return _has_visible_ui_background()


func seek_family_for_tests(family: StringName, seconds: float) -> void:
	if family != WAVES and family != GLOW:
		return
	_sync_family(family)
	_family_elapsed[family] = maxf(seconds, 0.0)
	_family_last_usec[family] = Time.get_ticks_usec()
	_family_skip_next_delta[family] = true
	state_changed.emit()


func seek_envelope_for_tests(family: StringName, seconds: float) -> void:
	if family != WAVES and family != GLOW:
		return
	_sync_family(family)
	_activation_elapsed[family] = clampf(seconds, 0.0, ACTIVATION_SECONDS)
	_family_last_usec[family] = Time.get_ticks_usec()
	_family_skip_next_delta[family] = true
	state_changed.emit()


## Preloads and retains the Waves, Glow, ship card and ship preview shaders, then verifies three
## animated main-viewport draws under the caller's opaque cover. A timeout or cancel_prepare() never
## enables motion; a later covered call may retry.
func prepare(container: Node) -> void:
	if _pipelines_warmed:
		return
	if _preparing:
		await _prepare_finished
		return
	_preparing = true
	_prepare_cancelled = false

	if not _load_warm_up_resources():
		_complete_prepare(false)
		return
	if not _gpu_frames_available() or not _renderer_supported() or not is_instance_valid(container):
		_complete_prepare(false)
		return

	var waves_texture := Assets.texture("Background_Waves")
	if waves_texture == null:
		_warn_prepare_once("static Waves texture is unavailable")
		_complete_prepare(false)
		return

	var waves := TextureRect.new()
	waves.name = "WavesPipelineWarmUp"
	waves.texture = waves_texture
	waves.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	waves.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_COVERED
	waves.mouse_filter = Control.MOUSE_FILTER_IGNORE
	waves.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	waves.set_script(_waves_script)
	waves.set(&"preparation_time_override", WARM_UP_TIME)

	var glow := ColorRect.new()
	glow.name = "GlowPipelineWarmUp"
	glow.color = Color(0.019607843, 0.019607843, 0.019607843, 1.0)
	glow.mouse_filter = Control.MOUSE_FILTER_IGNORE
	glow.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	glow.set_script(_glow_script)
	glow.set(&"preparation_time_override", WARM_UP_TIME)

	var card := ColorRect.new()
	card.name = "ShipCardPipelineWarmUp"
	card.color = Color(0.019607843, 0.019607843, 0.019607843, 1.0)
	card.mouse_filter = Control.MOUSE_FILTER_IGNORE
	card.size = Vector2(589.0, 427.0)
	var card_material := ShaderMaterial.new()
	card_material.shader = _ship_card_shader
	card.material = card_material

	var ship := TextureRect.new()
	ship.name = "ShipPreviewPipelineWarmUp"
	ship.texture = Assets.ship_texture(0, "Base")
	ship.mouse_filter = Control.MOUSE_FILTER_IGNORE
	ship.size = Vector2(64.0, 64.0)
	var ship_material := ShaderMaterial.new()
	ship_material.shader = _ship_preview_shader
	ship.material = ship_material

	var warm_nodes: Array[CanvasItem] = []
	warm_nodes.append(waves)
	warm_nodes.append(glow)
	warm_nodes.append(card)
	warm_nodes.append(ship)
	for node: CanvasItem in warm_nodes:
		container.add_child(node)
		container.move_child(node, 0)
	_warm_up_nodes = warm_nodes

	var waves_ready: Variant = waves.call(&"preparation_draw_ready")
	var glow_ready: Variant = glow.call(&"preparation_draw_ready")
	if not bool(waves_ready) or not bool(glow_ready) or card.material == null:
		_remove_warm_up_nodes(warm_nodes)
		_complete_prepare(false)
		return

	var observed_serial := _draw_serial
	var verified_draws := 0
	var deadline_usec := Time.get_ticks_usec() + WARM_UP_TIMEOUT_USEC
	while verified_draws < WARM_UP_FRAMES and Time.get_ticks_usec() < deadline_usec:
		await get_tree().process_frame
		if _prepare_cancelled or not is_instance_valid(container) or not _warm_up_nodes_valid(warm_nodes):
			break
		if _draw_serial > observed_serial:
			verified_draws += _draw_serial - observed_serial
			observed_serial = _draw_serial

	_remove_warm_up_nodes(warm_nodes)
	if _prepare_cancelled:
		_complete_prepare(false)
		return
	if verified_draws < WARM_UP_FRAMES:
		_warn_prepare_once("pipeline warm-up timed out; motion remains static")
		_complete_prepare(false)
		return
	_complete_prepare(true)


func _input(event: InputEvent) -> void:
	if not event.is_action_pressed(TOGGLE_ACTION, false, true):
		return
	if event is InputEventKey and event.echo:
		return
	if not _has_visible_ui_background():
		return
	get_viewport().set_input_as_handled()
	if not shortcut_available():
		return
	session_paused = not session_paused


func _load_warm_up_resources() -> bool:
	if (
		not ResourceLoader.exists(WAVES_SCRIPT_PATH)
		or not ResourceLoader.exists(GLOW_SCRIPT_PATH)
		or not ResourceLoader.exists(SHIP_CARD_SHADER_PATH)
		or not ResourceLoader.exists(SHIP_PREVIEW_SHADER_PATH)
	):
		_warn_prepare_once("a background or lobby shader is missing")
		return false
	_waves_script = ResourceLoader.load(WAVES_SCRIPT_PATH) as Script
	_glow_script = ResourceLoader.load(GLOW_SCRIPT_PATH) as Script
	_ship_card_shader = ResourceLoader.load(SHIP_CARD_SHADER_PATH) as Shader
	_ship_preview_shader = ResourceLoader.load(SHIP_PREVIEW_SHADER_PATH) as Shader
	if (
		_waves_script == null
		or _glow_script == null
		or _ship_card_shader == null
		or _ship_preview_shader == null
	):
		_warn_prepare_once("a background or lobby shader could not be loaded")
		return false
	var waves_result: Variant = _waves_script.call(&"preload_shared")
	var glow_result: Variant = _glow_script.call(&"preload_shared")
	return bool(waves_result) and bool(glow_result)


func _has_visible_ui_background() -> bool:
	for node: Node in get_tree().get_nodes_in_group(BACKGROUND_GROUP):
		if node is CanvasItem and (node as CanvasItem).is_visible_in_tree():
			return true
	var screen := ScreenManager.current_screen()
	if screen == null or not screen.is_visible_in_tree():
		return false
	var background := screen.get_node_or_null(^"Background") as CanvasItem
	return background != null and background.is_visible_in_tree()


func _has_visible_enabled_background() -> bool:
	for node: Node in get_tree().get_nodes_in_group(BACKGROUND_GROUP):
		if not (node is CanvasItem) or not (node as CanvasItem).is_visible_in_tree():
			continue
		if not node.has_method(&"motion_family"):
			continue
		var family_value: Variant = node.call(&"motion_family")
		if family_value is StringName and state_for(StringName(family_value)) != STATE_DISABLED:
			return true
	return false


func _on_profile_settings_changed() -> void:
	_sync_all_clocks()
	_update_effective_transition()
	_recompute_all_clocks()
	state_changed.emit()


func _on_frame_post_draw() -> void:
	_draw_serial += 1


func _ensure_family(family: StringName) -> void:
	if _family_elapsed.has(family):
		return
	var now_usec := Time.get_ticks_usec()
	_family_elapsed[family] = 0.0
	_family_last_usec[family] = now_usec
	_family_running[family] = false
	_family_skip_next_delta[family] = false
	_activation_elapsed[family] = 0.0


func _sync_family(family: StringName) -> void:
	_ensure_family(family)
	var now_usec := Time.get_ticks_usec()
	if _family_skip_next_delta[family]:
		_family_skip_next_delta[family] = false
		_family_last_usec[family] = now_usec
		return
	if _family_running[family]:
		var elapsed: float = _family_elapsed[family]
		var last_usec: int = _family_last_usec[family]
		var delta := float(maxi(now_usec - last_usec, 0)) / 1000000.0
		elapsed += delta
		_family_elapsed[family] = elapsed
		_activation_elapsed[family] = minf(
			_activation_elapsed[family] + delta,
			ACTIVATION_SECONDS
		)
	_family_last_usec[family] = now_usec


func _sync_all_clocks() -> void:
	for family: StringName in _family_elapsed:
		_sync_family(family)


func _recompute_family(family: StringName) -> void:
	_ensure_family(family)
	_family_running[family] = (
		effective_enabled()
		and time_override < 0.0
		and not session_paused
		and not _constrained
		and not _suspended
		and _family_has_eligible_adapter(family)
	)
	_family_last_usec[family] = Time.get_ticks_usec()


func _recompute_all_clocks() -> void:
	for family: StringName in _family_elapsed:
		_recompute_family(family)


func _update_effective_transition() -> void:
	var enabled := effective_enabled()
	if not _last_effective_enabled and enabled:
		_reset_activation_envelopes()
	_last_effective_enabled = enabled


func _reset_activation_envelopes() -> void:
	var now_usec := Time.get_ticks_usec()
	_ensure_family(WAVES)
	_ensure_family(GLOW)
	_activation_elapsed[WAVES] = 0.0
	_activation_elapsed[GLOW] = 0.0
	_family_last_usec[WAVES] = now_usec
	_family_last_usec[GLOW] = now_usec


func _family_has_eligible_adapter(family: StringName) -> bool:
	for instance_id: int in _adapter_family:
		if _adapter_family[instance_id] == family and _adapter_eligible[instance_id]:
			return true
	return false


func _renderer_supported() -> bool:
	if test_force_gpu:
		return true
	if DisplayServer.get_name() == "headless":
		return false
	var viewport := get_viewport()
	if viewport == null or viewport.use_hdr_2d or viewport.transparent_bg:
		return false
	return RenderingServer.get_current_rendering_method() != "dummy"


func _gpu_frames_available() -> bool:
	return test_force_gpu or (
		DisplayServer.get_name() != "headless"
		and RenderingServer.get_current_rendering_method() != "dummy"
	)


func _warm_up_nodes_valid(nodes: Array[CanvasItem]) -> bool:
	for node: CanvasItem in nodes:
		if (
			not is_instance_valid(node)
			or not node.is_inside_tree()
			or not node.is_visible_in_tree()
			or node.get_viewport() == null
		):
			return false
		if node is Control:
			var control := node as Control
			if control.size.x <= 0.0 or control.size.y <= 0.0:
				return false
	return true


func _remove_warm_up_nodes(nodes: Array[CanvasItem]) -> void:
	for node: CanvasItem in nodes:
		if not is_instance_valid(node):
			continue
		node.hide()
		if node.get_parent() != null:
			node.get_parent().remove_child(node)
		node.queue_free()


func _warn_prepare_once(message: String) -> void:
	if _prepare_warning_sent:
		return
	_prepare_warning_sent = true
	push_warning("UIBackgroundMotion: %s; continuing with static backgrounds" % message)


func _complete_prepare(success: bool) -> void:
	_sync_all_clocks()
	_pipelines_warmed = success
	_update_effective_transition()
	_recompute_all_clocks()
	_preparing = false
	_prepare_cancelled = false
	_warm_up_nodes = []
	state_changed.emit()
	_prepare_finished.emit()
