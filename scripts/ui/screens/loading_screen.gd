extends NRScreen

## Loading screen: an animated green ring around a stationary Xbox mark.
## configure({"message"}) overrides the caption; cancellation keeps its existing owner.

const _RING_SPEED := 1.5

signal cancelled()

@onready var _message_label: Label = %MessageLabel
@onready var _ring: TextureRect = %Ring
@onready var _cancel_button: Button = %CancelButton

var _message: String = "Loading match..."
var _allow_cancel := false
var _cancel_requested := false


func set_status(message: String, cancelling: bool = true) -> void:
	_message = message
	if cancelling:
		_cancel_requested = true
		_allow_cancel = false
	if is_node_ready():
		_message_label.text = message
		_cancel_button.disabled = _cancel_requested


func follow_join(request: JoinRequest) -> void:
	request.status_changed.connect(set_status)
	if not request.status.is_empty():
		set_status(request.status, request.cleaning_up)


func follow_host() -> void:
	NetManager.host_status_changed.connect(set_status)


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


func _process(delta: float) -> void:
	_ring.rotation += _RING_SPEED * delta


func _unhandled_input(event: InputEvent) -> void:
	if not is_active:
		return
	if _allow_cancel and event.is_action_pressed("ui_back_action"):
		get_viewport().set_input_as_handled()
		_on_cancel_pressed()


func _on_cancel_pressed() -> void:
	if _cancel_requested or not _allow_cancel:
		return
	_cancel_requested = true
	_cancel_button.disabled = true
	_message_label.text = "Canceling…"
	cancelled.emit()
