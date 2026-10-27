extends ColorRect

## Analytic Glow adapter. Disabled state is the undithered design shader; paused state keeps the
## current breathing pose and materials while stopping all uniform updates.

const FAMILY := &"glow"
const BACKGROUND_GROUP := &"ui_background_motion"
const DESIGN_SIZE := Vector2(1920.0, 1080.0)
const BASE_COLOR := Color(0.019607843, 0.019607843, 0.019607843, 1.0)
const SHADER_PATH := "res://scripts/ui/backgrounds/glow.gdshader"
const LOOP_SECONDS := 12.0
const STRENGTH_AMPLITUDE := 0.15
const SCALE_AMPLITUDE := 0.015

const U_COVER := &"cover_xform"
const U_STRENGTH := &"strength"
const U_SIZE := &"size_scale"
const U_DITHER := &"dither"

static var _shared_attempted := false
static var _shared_ready := false
static var _shared_warning_sent := false
static var _shared_shader: Shader

## Used only by UIBackgroundMotion.prepare(); it never touches the presentation family clock.
var preparation_time_override := -1.0

var _shader_material: ShaderMaterial
var _eligibility_registered := false
var _last_eligibility := false
var _preparation_ready := false
var _initialized := false


func _enter_tree() -> void:
	if preparation_time_override >= 0.0:
		return
	add_to_group(BACKGROUND_GROUP)
	_connect_controller()
	_eligibility_registered = false
	if _initialized:
		_restore_after_reparent.call_deferred()


func _ready() -> void:
	_initialized = true
	color = BASE_COLOR
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	resized.connect(_update_cover)
	if preparation_time_override >= 0.0:
		_preparation_ready = _ensure_material()
		if _preparation_ready:
			_apply_breathing(preparation_time_override, 1.0)
		set_process(false)
		return
	_connect_controller()
	_sync_eligibility()
	_refresh_state()


func _exit_tree() -> void:
	if preparation_time_override < 0.0:
		if UIBackgroundMotion.state_changed.is_connected(_on_motion_state_changed):
			UIBackgroundMotion.state_changed.disconnect(_on_motion_state_changed)
		UIBackgroundMotion.remove_adapter(self)
		_eligibility_registered = false
		_last_eligibility = false
	material = null
	_shader_material = null


func _notification(what: int) -> void:
	if not _initialized or preparation_time_override >= 0.0:
		return
	if (
		what == NOTIFICATION_VISIBILITY_CHANGED
		or what == NOTIFICATION_DISABLED
		or what == NOTIFICATION_ENABLED
		or what == NOTIFICATION_PAUSED
		or what == NOTIFICATION_UNPAUSED
	):
		_sync_eligibility()


func _process(_delta: float) -> void:
	var sample_time: float = UIBackgroundMotion.time_for(FAMILY)
	_apply_breathing(sample_time, UIBackgroundMotion.envelope_for(FAMILY))


func preparation_draw_ready() -> bool:
	return preparation_time_override >= 0.0 and _preparation_ready and material != null


func motion_family() -> StringName:
	return FAMILY


static func preload_shared() -> bool:
	if _shared_attempted:
		return _shared_ready
	_shared_attempted = true
	if not ResourceLoader.exists(SHADER_PATH):
		return _shared_fail("analytic shader is missing")
	var shader := ResourceLoader.load(SHADER_PATH) as Shader
	if shader == null:
		return _shared_fail("analytic shader is invalid")
	_shared_shader = shader
	_shared_ready = true
	return true


static func _shared_fail(reason: String) -> bool:
	_shared_ready = false
	_shared_shader = null
	if not _shared_warning_sent:
		push_warning("Glow background motion: %s; drawing the flat #050505 fallback" % reason)
		_shared_warning_sent = true
	return false


func _sync_eligibility() -> void:
	var eligible := is_inside_tree() and is_visible_in_tree() and can_process()
	if _eligibility_registered and eligible == _last_eligibility:
		return
	_eligibility_registered = true
	_last_eligibility = eligible
	UIBackgroundMotion.set_adapter_eligibility(self, FAMILY, eligible)


func _connect_controller() -> void:
	if not UIBackgroundMotion.state_changed.is_connected(_on_motion_state_changed):
		UIBackgroundMotion.state_changed.connect(_on_motion_state_changed)


func _restore_after_reparent() -> void:
	if not is_inside_tree() or preparation_time_override >= 0.0:
		return
	_sync_eligibility()
	_refresh_state()


func _refresh_state() -> void:
	var state := UIBackgroundMotion.state_for(FAMILY)
	var sample_time := 0.0
	var activation := 1.0
	if state != UIBackgroundMotion.STATE_DISABLED:
		sample_time = UIBackgroundMotion.time_for(FAMILY)
		activation = UIBackgroundMotion.envelope_for(FAMILY)
	if not _ensure_material():
		set_process(false)
		return
	if state == UIBackgroundMotion.STATE_DISABLED:
		_apply_design_state()
		set_process(false)
		return
	_apply_breathing(sample_time, activation)
	set_process(state == UIBackgroundMotion.STATE_RUNNING and _last_eligibility)


func _ensure_material() -> bool:
	if _shader_material != null:
		_update_cover()
		return true
	if not preload_shared():
		material = null
		return false
	var shader_material := ShaderMaterial.new()
	shader_material.shader = _shared_shader
	material = shader_material
	_shader_material = shader_material
	_update_cover()
	return true


func _apply_design_state() -> void:
	if _shader_material == null:
		return
	_shader_material.set_shader_parameter(U_STRENGTH, 1.0)
	_shader_material.set_shader_parameter(U_SIZE, 1.0)
	_shader_material.set_shader_parameter(U_DITHER, 0.0)


func _apply_breathing(sample_time: float, activation: float) -> void:
	if _shader_material == null:
		return
	var t := maxf(sample_time, 0.0)
	var breath := sin(TAU * fmod(t, LOOP_SECONDS) / LOOP_SECONDS)
	var envelope := clampf(activation, 0.0, 1.0)
	_shader_material.set_shader_parameter(
		U_STRENGTH,
		1.0 + STRENGTH_AMPLITUDE * envelope * breath
	)
	_shader_material.set_shader_parameter(
		U_SIZE,
		1.0 + SCALE_AMPLITUDE * envelope * breath
	)
	# Dither 1 selects rounded-once breathing with fixed grain; 0 selects staged Off. Animated t = 0 stays within 3 codes, not pixel-equal.
	_shader_material.set_shader_parameter(U_DITHER, 1.0)


func _update_cover() -> void:
	if _shader_material == null or size.x <= 0.0 or size.y <= 0.0:
		return
	var span := size / maxf(size.x / DESIGN_SIZE.x, size.y / DESIGN_SIZE.y)
	var origin := (DESIGN_SIZE - span) * 0.5
	_shader_material.set_shader_parameter(
		U_COVER,
		Vector4(
			span.x / DESIGN_SIZE.x,
			span.y / DESIGN_SIZE.y,
			origin.x / DESIGN_SIZE.x,
			origin.y / DESIGN_SIZE.y
		)
	)


func _on_motion_state_changed() -> void:
	_refresh_state()
