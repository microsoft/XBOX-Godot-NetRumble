class_name AimReticle
extends Node2D

## The mouse aiming reticle drawn in the gameplay world.
##
## Mouse aiming (World._mouse_aim_direction) needs a visible cursor: the system
## arrow is too small to aim with and is drawn in screen space, so it slides against
## the world as the camera moves.
##
## This node is parented beside the world and the camera under
## ScreenManager.world_container, so `get_global_mouse_position()` already resolves
## through the gameplay camera and the reticle sits exactly on the world point the
## shots will travel towards. It is drawn rather than textured so it stays crisp at
## any resolution and needs no new art.
##
## Visibility follows the device actually in use: it appears on mouse input and gets
## out of the way as soon as the player touches a pad, so a controller session never
## has a stray crosshair parked wherever the mouse was left. The OS cursor is hidden
## while the reticle is showing and restored the moment it is not -- including on
## teardown, so a match can never leave the player without a pointer in the menus.

## Ring radius in world units, and how far the four ticks sit outside it.
const RADIUS := 17.0
const TICK_LENGTH := 7.0
const TICK_GAP := 4.0
const LINE_WIDTH := 2.0
const CENTER_DOT_RADIUS := 1.75

const IDLE_COLOR := Color(0.72, 0.78, 1.0, 0.72)
const FIRING_COLOR := Color(1.0, 0.45, 0.35, 0.95)

## How far the ring contracts while the fire button is held, as a fraction of RADIUS.
const FIRING_SCALE := 0.82
## How quickly the ring converges on its firing/idle size, in units of 1/second.
const SCALE_SMOOTHING := 18.0
## Degrees per second the tick ring rotates while firing. It is the only moving part;
## the crosshair itself stays nailed to the aim point.
const FIRING_SPIN := 90.0

var _active := false
var _firing := false
var _ui_occluded := false
var _ring_scale := 1.0
var _spin_degrees := 0.0


func _ready() -> void:
	name = "AimReticle"
	# Drawn over the entities it is aimed at. The HUD lives on a CanvasLayer above
	# this node's parent entirely, so it can never cover the score or the countdown.
	z_index = 100
	# The cursor is already resolved to world space, so the reticle must not also
	# inherit the world container's transform.
	top_level = true
	visible = false
	set_process(false)


## The OS cursor is a process-wide setting, so it has to be handed back whether this
## node is freed with the gameplay screen, with the whole scene tree, or on quit.
func _exit_tree() -> void:
	_restore_cursor()


func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventMouseMotion or event is InputEventMouseButton:
		_set_active(true)
	elif event is InputEventJoypadMotion or event is InputEventJoypadButton:
		_set_active(false)


func _process(delta: float) -> void:
	position = get_global_mouse_position()

	_firing = Input.is_action_pressed("click")
	var target_scale := FIRING_SCALE if _firing else 1.0
	_ring_scale = lerpf(_ring_scale, target_scale, clampf(SCALE_SMOOTHING * delta, 0.0, 1.0))
	if _firing:
		_spin_degrees = fposmod(_spin_degrees + FIRING_SPIN * delta, 360.0)

	queue_redraw()


func _draw() -> void:
	var color := FIRING_COLOR if _firing else IDLE_COLOR
	var ring_radius := RADIUS * _ring_scale

	draw_arc(Vector2.ZERO, ring_radius, 0.0, TAU, 48, color, LINE_WIDTH, true)
	draw_circle(Vector2.ZERO, CENTER_DOT_RADIUS, color)

	var spin := deg_to_rad(_spin_degrees)
	for index in 4:
		var angle := spin + TAU * float(index) / 4.0
		var direction := Vector2(cos(angle), sin(angle))
		draw_line(
			direction * (ring_radius + TICK_GAP),
			direction * (ring_radius + TICK_GAP + TICK_LENGTH),
			color,
			LINE_WIDTH,
			true)


func _set_active(active: bool) -> void:
	if _active == active:
		return
	_active = active
	if active:
		position = get_global_mouse_position()
		queue_redraw()
	_sync_cursor_visibility()


## Popup screens live on a CanvasLayer above the world. The reticle is intentionally
## world-space, so menu coverage restores the OS pointer instead of drawing a second,
## partly hidden cursor under the pause/options rows.
func set_ui_occluded(occluded: bool) -> void:
	if _ui_occluded == occluded:
		return
	_ui_occluded = occluded
	_sync_cursor_visibility()


func _sync_cursor_visibility() -> void:
	var should_show := _active and not _ui_occluded
	visible = should_show
	set_process(should_show)
	if should_show:
		position = get_global_mouse_position()
		Input.mouse_mode = Input.MOUSE_MODE_HIDDEN
		queue_redraw()
	else:
		_restore_cursor()


## Only ever *reveals* the cursor. Anything stronger risks stomping a mouse mode some
## other part of the game set for its own reasons.
func _restore_cursor() -> void:
	if Input.mouse_mode == Input.MOUSE_MODE_HIDDEN:
		Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
