class_name NRFocusRing
extends Control

## An accent outline drawn over whichever control currently holds focus.
##
## Most of the menu is built from NRButton, and the shared Theme gives Button a focus
## stylebox. The controls that draw their own artwork cannot use it: the options rows
## (NRSpinner, NRSlider) are plain Controls with no stylebox at all, and the lobby's
## ship tabs, colour tabs and stepper buttons deliberately strip every Button stylebox
## so the theme's grey slab does not cover their textures. All of them still take
## focus, so before this existed a gamepad could move through them with nothing on
## screen changing — which reads as navigation being broken rather than invisible.
##
## The ring is a child of the control it marks rather than a stylebox on it, so it
## works the same for a Button, a Control, or anything else focusable, and it draws
## over artwork instead of behind it.

## Outline colour and thickness. The accent matches the theme's focus borders, so a
## ringed control and a themed button read as the same state.
const _COLOR := Color(0.12, 0.83, 0.54, 1)
const _THICKNESS := 3.0

var _host: Control = null
## Shrinks the ring inside the host. Used where the host's box is larger than the
## artwork the player is actually aiming at.
var _inset: float = 0.0


## Adds a ring to `host`, or returns the one it already has. Called after the host has
## built its own children so the ring is the last child and draws on top of them.
static func attach(host: Control, inset: float = 0.0) -> NRFocusRing:
	if host == null:
		return null
	var existing := host.get_node_or_null(^"NRFocusRing") as NRFocusRing
	if existing != null:
		return existing
	var ring := NRFocusRing.new()
	ring.name = "NRFocusRing"
	ring._inset = inset
	host.add_child(ring)
	return ring


func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	offset_left = _inset
	offset_top = _inset
	offset_right = -_inset
	offset_bottom = -_inset
	resized.connect(queue_redraw)

	_host = get_parent() as Control
	if _host == null:
		visible = false
		return
	_host.focus_entered.connect(_refresh)
	_host.focus_exited.connect(_refresh)
	_refresh()


func _refresh() -> void:
	visible = is_instance_valid(_host) and _host.has_focus()


## Inset by half the line width, because draw_rect centres the stroke on the edge and
## the outer half would otherwise spill over the neighbouring row.
func _draw() -> void:
	var half := _THICKNESS * 0.5
	var box := Rect2(Vector2(half, half), size - Vector2(_THICKNESS, _THICKNESS))
	if box.size.x <= 0.0 or box.size.y <= 0.0:
		return
	draw_rect(box, _COLOR, false, _THICKNESS)
