class_name NRShipCard
extends Panel

## The lobby ship card, drawn in code.
##
## The Panel keeps its role and its theme style (LobbyShipPreview): it hosts and clips the rotated
## ship sprites, and its StyleBoxFlat draws the white 0.15, 1 px outline with rounded bottom corners
## over an opaque #050505 fill. When the card shader loads, the ShipCardFill child, drawn behind the
## Panel (show_behind_parent), paints the design's opaque rounded fill and radial teal stack
## (assets/ui/ship_card.gdshader), and the Panel's own fill is suppressed so only its outline draws
## on top. Without the shader the theme's opaque fill is the card. The shader takes its corner
## radius, anti-aliasing and corner detail from that same StyleBoxFlat, so the fill's silhouette
## always matches the outline. Static: nothing animates or processes.

const SHADER_PATH := "res://assets/ui/ship_card.gdshader"
const FILL_NAME := ^"ShipCardFill"
## Stands in for StyleBoxFlat's hard edge when its anti-aliasing is off.
const HARD_EDGE_AA := 0.01

## false keeps the theme's opaque fallback fill (tests and diagnostics).
@export var use_shader := true:
	set(value):
		use_shader = value
		if is_node_ready():
			_apply()

var _fill: ColorRect
var _material: ShaderMaterial


func _ready() -> void:
	_fill = get_node_or_null(FILL_NAME) as ColorRect
	resized.connect(_sync_rect_size)
	_apply()


## True while the shader fill draws the card; false while the theme's opaque fill does.
func is_shader_fill() -> bool:
	return _fill != null and _fill.visible and _fill.material != null


## Uses the shader fill when it is available, else the theme's opaque fill. The Panel's centre
## fill is suppressed only while the shader fill is in use.
func _apply() -> void:
	remove_theme_stylebox_override(&"panel")
	var theme_style := get_theme_stylebox(&"panel") as StyleBoxFlat
	if use_shader and _material == null and _fill != null and theme_style != null:
		_material = _load_material()
	var shader_fill := use_shader and _material != null and _fill != null and theme_style != null
	if _fill != null:
		_fill.material = _material if shader_fill else null
		_fill.visible = shader_fill
	if not shader_fill:
		return
	var aa_size: float = theme_style.anti_aliasing_size if theme_style.anti_aliasing else HARD_EDGE_AA
	_material.set_shader_parameter(&"corner_radius", float(theme_style.corner_radius_bottom_left))
	_material.set_shader_parameter(&"aa_size", aa_size)
	_material.set_shader_parameter(&"corner_detail", float(theme_style.corner_detail))
	# The fill reaches half the anti-aliasing ramp past the Panel, as StyleBoxFlat's ramp does; the
	# Panel's clip_contents scissor trims the fill and the outline alike.
	_fill.offset_left = -0.5 * aa_size
	_fill.offset_top = -0.5 * aa_size
	_fill.offset_right = 0.5 * aa_size
	_fill.offset_bottom = 0.5 * aa_size
	var outline := theme_style.duplicate() as StyleBoxFlat
	outline.draw_center = false
	add_theme_stylebox_override(&"panel", outline)
	_sync_rect_size()


func _load_material() -> ShaderMaterial:
	var shader: Shader = null
	if ResourceLoader.exists(SHADER_PATH):
		shader = load(SHADER_PATH) as Shader
	if shader == null:
		push_warning("NRShipCard: %s is unavailable; the card keeps the theme's opaque fill." % SHADER_PATH)
		return null
	var card_material := ShaderMaterial.new()
	card_material.shader = shader
	return card_material


func _sync_rect_size() -> void:
	if _material != null:
		_material.set_shader_parameter(&"rect_size", size)
