class_name PowerUp
extends GameObject

## A collectible pickup. Its mass is negligible and it only masks the `ships` layer,
## so a ship that touches it collects it without being deflected by the physics
## solver.

var power_up_type: NRTypes.PowerUpType = NRTypes.PowerUpType.DOUBLE_LASER
var definition: PowerUpDefinition = null

var _sprite: Sprite2D = null
var _pulse_animation: AnimationPlayer = null
var _label: Label = null
var _light: PointLight2D = null


func _init() -> void:
	object_type = NRTypes.GameObjectType.POWER_UP
	_apply_definition(power_up_type)


func setup(type: NRTypes.PowerUpType) -> void:
	unique_id = GameObject.allocate_id()
	_apply_definition(type)


func setup_networked(id: int) -> void:
	unique_id = id


## Re-points a pooled body at a different pickup.
##
## Pickups used to be one instance per type, created once and never changed. There are
## thirty-two of them now and only a handful live at a time, so the bodies are pooled
## and generic: the authority picks a type when it spawns one and both peers call this
## to dress the body accordingly.
func assign_type(type: NRTypes.PowerUpType) -> void:
	if power_up_type == type and definition != null and _sprite != null:
		return
	_apply_definition(type)
	_refresh_appearance()


func _apply_definition(type: NRTypes.PowerUpType) -> void:
	power_up_type = type
	definition = Assets.power_up_definition(type)
	radius = definition.radius


func start() -> void:
	health = 1.0
	velocity = Vector2.ZERO
	if _pulse_animation != null:
		_pulse_animation.play("pulse")


func tick(delta: float) -> void:
	set_facing(rotation + definition.rotation_speed * delta)
	super.tick(delta)


func on_contact(other: GameObject) -> void:
	if world == null or other == null:
		return
	if other is Ship and world.is_authority:
		world.collect_power_up(self, other as Ship)


func _build_visuals() -> void:
	_sprite = $Sprite
	_pulse_animation = $PulseAnimation
	_label = get_node_or_null(^"Label")
	_build_light()
	_refresh_appearance()


## Applies the current definition's art. Called on every type change, not just once,
## because the bodies are pooled.
##
## The project ships three power-up textures and there are thirty-two pickups, so the
## texture only picks the silhouette; the tint and the short label carry the actual
## identity. A label is far cheaper than commissioning twenty-nine sprites and stays
## legible at the zoom the game is played at.
func _refresh_appearance() -> void:
	if _sprite == null or definition == null:
		return
	_sprite.texture = definition.texture
	_sprite.modulate = definition.tint
	if _label != null:
		_label.text = definition.label
		_label.modulate = Color(1.0, 1.0, 1.0, 0.9)
	if _light != null:
		_light.color = definition.tint
		_light.texture_scale = definition.light_radius / 128.0
	_configure_pulse_animation()
	if _pulse_animation != null and is_active:
		_pulse_animation.play("pulse")


## Pickups light the rocks around them, which is what makes one visible from across
## the field. Built in code for the same reason the projectiles' lights are: the
## radius is a per-pickup property, so authoring it into power_up.tscn would just mean
## overwriting it here anyway.
func _build_light() -> void:
	if _light != null:
		return
	_light = PointLight2D.new()
	_light.name = "PickupLight"
	_light.texture = FXLighting.radial_light_texture()
	_light.blend_mode = Light2D.BLEND_MODE_ADD
	_light.shadow_enabled = false
	_light.energy = 0.9
	add_child(_light)


func _update_visuals() -> void:
	if _light != null:
		_light.visible = is_active


func _configure_pulse_animation() -> void:
	if _pulse_animation == null or _sprite == null:
		return
	_pulse_animation.stop()
	var animation := Animation.new()
	var period := TAU * definition.pulse_rate
	animation.length = period
	animation.loop_mode = Animation.LOOP_LINEAR
	var track := animation.add_track(Animation.TYPE_VALUE)
	animation.track_set_path(track, ^"Sprite:scale")
	animation.track_set_interpolation_type(track, Animation.INTERPOLATION_CUBIC)
	animation.value_track_set_update_mode(track, Animation.UPDATE_CONTINUOUS)
	var base := Vector2.ONE
	var high := Vector2.ONE * (1.0 + definition.pulse_amplitude)
	var low := Vector2.ONE * (1.0 - definition.pulse_amplitude)
	animation.track_insert_key(track, 0.0, base)
	animation.track_insert_key(track, period * 0.25, high)
	animation.track_insert_key(track, period * 0.5, base)
	animation.track_insert_key(track, period * 0.75, low)
	animation.track_insert_key(track, period, base)
	var library := AnimationLibrary.new()
	library.add_animation("pulse", animation)
	if _pulse_animation.has_animation_library(""):
		_pulse_animation.remove_animation_library("")
	_pulse_animation.add_animation_library("", library)
