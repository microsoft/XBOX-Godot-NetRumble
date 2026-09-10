class_name Starfield
extends Node2D

## Parallax2D starfield with three depth layers, used in menus and gameplay alike.
##
## Stars are distributed across Near, Mid and Far Parallax2D layers: each layer uses a
## fixed random seed so the sky is deterministic and tiles seamlessly. The tile pixels
## are generated at runtime into a Texture2D, avoiding a shipped PNG while keeping the
## sparse white-on-dark-blue look.
##
## The field orbits a slow circle driven by the engine clock rather than per-instance
## state, so the sky stays continuous across screen changes instead of jumping. Each
## depth layer is offset by its scroll_scale factor to produce the parallax depth.

const BACKGROUND_COLOR := Color(0.0, 0.0, 16.0 / 255.0, 1.0)
const TILE_SIZE := Vector2i(1024, 1024)

## The field orbits a circle of this radius. One lap takes `2 * PI * PARALLAX_PERIOD`
## seconds (~188 s), so the drift is a slow wander rather than a scroll in any fixed
## direction.
const PARALLAX_PERIOD := 30.0
const PARALLAX_AMPLITUDE := 2048.0

const LAYER_DATA: Array[Dictionary] = [
	{"name": "Near", "scroll_scale": Vector2(0.9, 0.9), "count": 96, "alpha": 1.0, "seed": 101},
	{"name": "Mid", "scroll_scale": Vector2(0.55, 0.55), "count": 88, "alpha": 0.63, "seed": 202},
	{"name": "Far", "scroll_scale": Vector2(0.25, 0.25), "count": 72, "alpha": 0.38, "seed": 303},
]

var _background: ColorRect = null
var _layers: Array[Parallax2D] = []


func _ready() -> void:
	_build_background()
	for layer_data in LAYER_DATA:
		_add_layer(layer_data)

	var viewport := get_viewport()
	if viewport != null and not viewport.size_changed.is_connected(_resize_background):
		viewport.size_changed.connect(_resize_background)
	_resize_background()
	_drift()


## Advances the orbital drift each frame. The field position at time `t` is computed
## analytically rather than accumulated — each layer is placed at its absolute world
## offset, so there is no floating-point drift over long sessions. Parallax2D.scroll_offset
## translates a layer 1:1 and is not affected by scroll_scale, so the depth factor is
## applied here explicitly.
##
## Driven off the engine clock rather than a per-instance timer because every screen
## builds its own starfield: a shared clock phase (and the fixed per-layer seeds) is
## what keeps the sky continuous across a screen change instead of jumping.
func _process(_delta: float) -> void:
	_drift()


func _drift() -> void:
	var time := (float(Time.get_ticks_msec()) / 1000.0) / PARALLAX_PERIOD
	# Start of the orbit, so the field begins undisplaced rather than 2048 px off.
	var travelled := Vector2(cos(time) - 1.0, sin(time)) * PARALLAX_AMPLITUDE
	for i in _layers.size():
		var factor: float = float(LAYER_DATA[i]["scroll_scale"].x)
		_layers[i].scroll_offset = -travelled * factor


func _build_background() -> void:
	_background = ColorRect.new()
	_background.name = "Background"
	_background.color = BACKGROUND_COLOR
	_background.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_background)
	move_child(_background, 0)


func _resize_background() -> void:
	if _background != null:
		_background.position = Vector2.ZERO
		_background.size = get_viewport_rect().size
	_update_repeat_times()


## Parallax2D wraps a layer's origin into [-repeat_size, 0), so a tile can start a
## full tile-width off-screen. The default repeat_times of 1 only draws two tiles,
## which left the right of a 1920-wide viewport bare once the layer was displaced;
## cover the viewport plus one tile of slack instead.
func _update_repeat_times() -> void:
	var view := get_viewport_rect().size
	var tile := Vector2(TILE_SIZE)
	var times := int(maxf(
		ceilf((view.x + tile.x) / tile.x),
		ceilf((view.y + tile.y) / tile.y)))
	for layer in _layers:
		layer.repeat_times = maxi(times, 1)


func _add_layer(layer_data: Dictionary) -> void:
	var parallax := Parallax2D.new()
	parallax.name = str(layer_data["name"])
	parallax.scroll_scale = layer_data["scroll_scale"]
	parallax.repeat_size = Vector2(TILE_SIZE)
	add_child(parallax)
	_layers.append(parallax)

	var sprite := Sprite2D.new()
	sprite.name = "Stars"
	sprite.centered = false
	sprite.texture = _make_star_texture(
		int(layer_data["count"]),
		float(layer_data["alpha"]),
		int(layer_data["seed"]))
	parallax.add_child(sprite)


func _make_star_texture(count: int, alpha: float, layer_seed: int) -> Texture2D:
	var image := Image.create(TILE_SIZE.x, TILE_SIZE.y, false, Image.FORMAT_RGBA8)
	image.fill(Color.TRANSPARENT)

	var rng := RandomNumberGenerator.new()
	rng.seed = layer_seed
	for i in count:
		var x := rng.randi_range(0, TILE_SIZE.x - 1)
		var y := rng.randi_range(0, TILE_SIZE.y - 1)
		var brightness := rng.randf_range(0.55, 1.0)
		var star_color := Color(1.0, 1.0, 1.0, alpha * brightness)
		image.set_pixel(x, y, star_color)
		if rng.randf() < 0.18 and x + 1 < TILE_SIZE.x:
			image.set_pixel(x + 1, y, star_color * Color(1.0, 1.0, 1.0, 0.7))

	return ImageTexture.create_from_image(image)
