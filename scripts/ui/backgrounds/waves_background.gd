extends TextureRect

## Existing Waves TextureRects keep their exact static path. Animated and frozen states reuse the
## wave materials; only an explicitly disabled state releases them.

const FAMILY := &"waves"
const BACKGROUND_GROUP := &"ui_background_motion"
const DESIGN_SIZE := Vector2(1920.0, 1080.0)
const ATLAS_SIZE := Vector2i(1024, 547)
const ATLAS_SIZE_F := Vector2(1024.0, 547.0)
const STRANDS_SIZE := Vector2i(1920, 728)
const EXPECTED_COUNT := 1591
const LOOP_SECONDS := 60.0
const EASE_SECONDS := 3.0

const BASE_SHADER_PATH := "res://scripts/ui/backgrounds/waves_base.gdshader"
const SUB_SHADER_PATH := "res://scripts/ui/backgrounds/waves_dots_sub.gdshader"
const ADD_SHADER_PATH := "res://scripts/ui/backgrounds/waves_dots_add.gdshader"
const WAVE_INCLUDE_PATH := "res://scripts/ui/backgrounds/wave_field.gdshaderinc"
const ATLAS_PATH := "res://assets/textures/UI/Background/Motion/Waves_DotAtlas.png"
const STRANDS_PATH := "res://assets/textures/UI/Background/Motion/Waves_Strands_band.png"
const DATA_PATH := "res://assets/textures/UI/Background/Motion/Waves_DotData.res"
const MULTIMESH_PATH := "res://assets/textures/UI/Background/Motion/Waves_DotMultiMesh.res"

const U_STRANDS := &"strands"
const U_ATLAS := &"atlas"
const U_ATLAS_SIZE := &"atlas_size"
const U_INST_DATA := &"inst_data"
const U_T_PHASE := &"t_phase"
const U_EASE := &"ease"

static var _shared_attempted := false
static var _shared_ready := false
static var _shared_warning_sent := false
static var _shared_base_shader: Shader
static var _shared_sub_shader: Shader
static var _shared_add_shader: Shader
static var _shared_atlas: Texture2D
static var _shared_strands: Texture2D
static var _shared_data_texture: ImageTexture
static var _shared_multimesh: MultiMesh

## Used only by UIBackgroundMotion.prepare(); it never touches the presentation family clock.
var preparation_time_override := -1.0

var _design_root: Node2D
var _base_material: ShaderMaterial
var _add_material: ShaderMaterial
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
	clip_contents = true
	resized.connect(_fit)
	if preparation_time_override >= 0.0:
		_preparation_ready = _build_animated(preparation_time_override, 1.0)
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
	_free_animated()


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
	_apply_time(sample_time, UIBackgroundMotion.envelope_for(FAMILY))


func preparation_draw_ready() -> bool:
	return preparation_time_override >= 0.0 and _preparation_ready \
			and material != null and _design_root != null


func motion_family() -> StringName:
	return FAMILY


static func preload_shared() -> bool:
	if _shared_attempted:
		return _shared_ready
	_shared_attempted = true

	if (
		not ResourceLoader.exists(BASE_SHADER_PATH)
		or not ResourceLoader.exists(SUB_SHADER_PATH)
		or not ResourceLoader.exists(ADD_SHADER_PATH)
		or not FileAccess.file_exists(WAVE_INCLUDE_PATH)
		or not ResourceLoader.exists(ATLAS_PATH)
		or not ResourceLoader.exists(STRANDS_PATH)
		or not ResourceLoader.exists(DATA_PATH)
		or not ResourceLoader.exists(MULTIMESH_PATH)
	):
		return _shared_fail("a required shader or motion resource is missing")

	var base_shader := ResourceLoader.load(BASE_SHADER_PATH) as Shader
	var sub_shader := ResourceLoader.load(SUB_SHADER_PATH) as Shader
	var add_shader := ResourceLoader.load(ADD_SHADER_PATH) as Shader
	var atlas := Assets.texture("BackgroundMotion_WavesDotAtlas")
	var strands := Assets.texture("BackgroundMotion_WavesStrands")
	var data_image := ResourceLoader.load(DATA_PATH) as Image
	var multimesh := ResourceLoader.load(MULTIMESH_PATH) as MultiMesh

	if base_shader == null or sub_shader == null or add_shader == null:
		return _shared_fail("a shader resource is invalid")
	if atlas == null or Vector2i(atlas.get_size()) != ATLAS_SIZE:
		return _shared_fail("dot atlas must be 1024x547")
	if strands == null or Vector2i(strands.get_size()) != STRANDS_SIZE:
		return _shared_fail("strand texture must be 1920x728")
	if (
		data_image == null
		or data_image.get_format() != Image.FORMAT_RGBAF
		or data_image.get_width() != EXPECTED_COUNT
		or data_image.get_height() != 2
	):
		return _shared_fail("instance data must be a 1591x2 RGBAF Image")
	if (
		multimesh == null
		or multimesh.transform_format != MultiMesh.TRANSFORM_2D
		or multimesh.instance_count != EXPECTED_COUNT
		or multimesh.use_colors
		or multimesh.use_custom_data
	):
		return _shared_fail("dot MultiMesh format or count is invalid")
	var quad := multimesh.mesh as QuadMesh
	if (
		quad == null
		or not quad.size.is_equal_approx(Vector2.ONE)
		or not quad.center_offset.is_equal_approx(Vector3(0.5, 0.5, 0.0))
	):
		return _shared_fail("dot MultiMesh must use the required unit QuadMesh")

	var data_texture := ImageTexture.create_from_image(data_image)
	if (
		data_texture == null
		or Vector2i(data_texture.get_size()) != Vector2i(EXPECTED_COUNT, 2)
	):
		return _shared_fail("instance data could not be uploaded")

	_shared_base_shader = base_shader
	_shared_sub_shader = sub_shader
	_shared_add_shader = add_shader
	_shared_atlas = atlas
	_shared_strands = strands
	_shared_data_texture = data_texture
	_shared_multimesh = multimesh
	_shared_ready = true
	return true


static func _shared_fail(reason: String) -> bool:
	_shared_ready = false
	_shared_base_shader = null
	_shared_sub_shader = null
	_shared_add_shader = null
	_shared_atlas = null
	_shared_strands = null
	_shared_data_texture = null
	_shared_multimesh = null
	if not _shared_warning_sent:
		push_warning("Waves background motion: %s; using the exact static background" % reason)
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
	if state == UIBackgroundMotion.STATE_DISABLED:
		_free_animated()
		set_process(false)
		return
	var sample_time: float = UIBackgroundMotion.time_for(FAMILY)
	var activation := UIBackgroundMotion.envelope_for(FAMILY)
	if not _build_animated(sample_time, activation):
		set_process(false)
		return
	_apply_time(sample_time, activation)
	set_process(state == UIBackgroundMotion.STATE_RUNNING and _last_eligibility)


func _build_animated(sample_time: float, activation: float) -> bool:
	if _design_root != null:
		_apply_time(sample_time, activation)
		return true
	if not preload_shared():
		return false

	var base_material := ShaderMaterial.new()
	base_material.shader = _shared_base_shader
	base_material.set_shader_parameter(U_STRANDS, _shared_strands)

	var sub_material := ShaderMaterial.new()
	sub_material.shader = _shared_sub_shader
	_configure_dot_material(sub_material)

	var add_material := ShaderMaterial.new()
	add_material.shader = _shared_add_shader
	_configure_dot_material(add_material)
	_set_material_time(base_material, add_material, sample_time, activation)

	var design_root := Node2D.new()
	design_root.name = "WaveDesignSpace"

	var subtract := MultiMeshInstance2D.new()
	subtract.name = "DotsSubtract"
	subtract.multimesh = _shared_multimesh
	subtract.material = sub_material
	design_root.add_child(subtract)

	var add := MultiMeshInstance2D.new()
	add.name = "DotsAdd"
	add.multimesh = _shared_multimesh
	add.material = add_material
	design_root.add_child(add)

	material = base_material
	add_child(design_root)
	_design_root = design_root
	_base_material = base_material
	_add_material = add_material
	_fit()
	return true


func _configure_dot_material(dot_material: ShaderMaterial) -> void:
	dot_material.set_shader_parameter(U_ATLAS, _shared_atlas)
	dot_material.set_shader_parameter(U_ATLAS_SIZE, ATLAS_SIZE_F)
	dot_material.set_shader_parameter(U_INST_DATA, _shared_data_texture)


func _set_material_time(
		base_material: ShaderMaterial,
		add_material: ShaderMaterial,
		sample_time: float,
		activation: float) -> void:
	var t := maxf(sample_time, 0.0)
	var ramp := clampf(t / EASE_SECONDS, 0.0, 1.0)
	var first_activation := ramp * ramp * (3.0 - 2.0 * ramp)
	# The authored first activation and a later re-enable are alternate ramps, never multiplied.
	var eased := minf(first_activation, clampf(activation, 0.0, 1.0))
	var phase := fmod(t, LOOP_SECONDS)
	base_material.set_shader_parameter(U_T_PHASE, phase)
	base_material.set_shader_parameter(U_EASE, eased)
	add_material.set_shader_parameter(U_T_PHASE, phase)
	add_material.set_shader_parameter(U_EASE, eased)


func _apply_time(sample_time: float, activation: float) -> void:
	if _base_material == null or _add_material == null:
		return
	_set_material_time(_base_material, _add_material, sample_time, activation)


func _free_animated() -> void:
	material = null
	if _design_root != null:
		var old_root := _design_root
		_design_root = null
		old_root.visible = false
		if old_root.get_parent() == self:
			remove_child(old_root)
		old_root.queue_free()
	_base_material = null
	_add_material = null


func _fit() -> void:
	if _design_root == null or size.x <= 0.0 or size.y <= 0.0:
		return
	var cover_scale := maxf(size.x / DESIGN_SIZE.x, size.y / DESIGN_SIZE.y)
	_design_root.transform = Transform2D(
		0.0,
		Vector2(cover_scale, cover_scale),
		0.0,
		(size - DESIGN_SIZE * cover_scale) * 0.5
	)


func _on_motion_state_changed() -> void:
	_refresh_state()
