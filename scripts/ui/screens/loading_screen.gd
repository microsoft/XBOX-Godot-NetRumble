extends NRScreen

## Loading screen: concentric Loading_Ring textures rotating at alternating speeds
## behind a static caption. configure({"message"}) overrides the caption text.
##
## Trailing animated periods on the caption are omitted because the rotating rings
## already convey that work is in progress.

## Angular velocity per ring, in rad/s. The speeds start at 0.1 going clockwise, then
## each ring flips direction and grows by `speed * speed`:
## (0.1 -> 0.11 -> 0.1221 -> 0.137008 -> 0.155779). Integrating per frame rather than
## driving an AnimationPlayer keeps the motion seamless; a looping track has to snap
## back to its first key, and none of these rates land on a whole turn.
const RING_SPEEDS: Array[float] = [0.1, -0.11, 0.1221, -0.137008, 0.155779]

signal cancelled()

@onready var _message_label: Label = %MessageLabel
@onready var _rings_root: Control = %RingsRoot
@onready var _cancel_button: Button = %CancelButton

var _message: String = "Loading"
var _allow_cancel := false
var _cancel_requested := false
var _rings: Array[Control] = []


func _init() -> void:
	allow_back = false


func configure(payload: Variant) -> void:
	if typeof(payload) == TYPE_DICTIONARY and payload.has("message"):
		_message = str(payload["message"])
	if typeof(payload) == TYPE_DICTIONARY and payload.has("allow_cancel"):
		_allow_cancel = bool(payload["allow_cancel"])


func _ready() -> void:
	super._ready()
	_message_label.text = _message
	_cancel_button.visible = _allow_cancel
	_cancel_button.pressed.connect(_on_cancel_pressed)
	if _allow_cancel:
		_cancel_button.call_deferred("grab_focus")
	for child in _rings_root.get_children():
		var ring := child as Control
		if ring != null:
			_rings.append(ring)


func _process(delta: float) -> void:
	for i in mini(_rings.size(), RING_SPEEDS.size()):
		_rings[i].rotation += RING_SPEEDS[i] * delta


func _unhandled_input(event: InputEvent) -> void:
	if not is_active:
		return
	if _allow_cancel and event.is_action_pressed("ui_back_action"):
		get_viewport().set_input_as_handled()
		_on_cancel_pressed()


func _on_cancel_pressed() -> void:
	if _cancel_requested:
		return
	_cancel_requested = true
	_cancel_button.disabled = true
	_message_label.text = "Canceling…"
	cancelled.emit()
