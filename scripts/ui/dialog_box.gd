extends NRScreen

## A modal popup (is_popup = true so the screen beneath stays visible) with a
## severity-coloured title bar, a wrapped message, and one or two buttons.
## ScreenManager.show_dialog() awaits `dismissed`, which carries true when the accept
## button was chosen and false on cancel.

signal dismissed(accepted: bool)

@onready var _title_label: Label = %TitleLabel
@onready var _title_bar: PanelContainer = %TitleBar
@onready var _message_label: Label = %MessageLabel
@onready var _ok_button: Button = %OkButton
@onready var _cancel_button: Button = %CancelButton

var _title: String = ""
var _message: String = ""
var _severity: String = "default"
var _show_cancel: bool = false
var _ok_text: String = ""
var _cancel_text: String = ""


func _init() -> void:
	is_popup = true
	# Back is handled explicitly so it maps to a cancel/accept decision.
	allow_back = false


func configure(payload: Variant) -> void:
	if typeof(payload) != TYPE_DICTIONARY:
		return
	_title = str(payload.get("title", ""))
	_message = str(payload.get("message", ""))
	_severity = str(payload.get("severity", "default"))
	_show_cancel = bool(payload.get("show_cancel", false))
	# Optional. "OK"/"Cancel" answer a question the message asks, but a dialog offering
	# two actions -- retry or leave -- reads as a guess about which button does what
	# unless the buttons say so themselves.
	_ok_text = str(payload.get("ok_text", ""))
	_cancel_text = str(payload.get("cancel_text", ""))


func _ready() -> void:
	super._ready()
	_title_label.text = _title
	_message_label.text = _message
	_title_bar.theme_type_variation = _title_variation()

	if not _ok_text.is_empty():
		_ok_button.text = _ok_text
	if not _cancel_text.is_empty():
		_cancel_button.text = _cancel_text
	_cancel_button.visible = _show_cancel
	_ok_button.pressed.connect(_on_ok)
	_cancel_button.pressed.connect(_on_cancel)

	_ok_button.call_deferred("grab_focus")


func _title_variation() -> StringName:
	match _severity:
		"error":
			return &"DialogTitleError"
		"warning":
			return &"DialogTitleWarning"
		_:
			return &"DialogTitle"


func _unhandled_input(event: InputEvent) -> void:
	if not is_active:
		return
	if event.is_action_pressed("ui_back_action"):
		get_viewport().set_input_as_handled()
		if _show_cancel:
			_on_cancel()
		else:
			_on_ok()


var _dismissing: bool = false


func _on_ok() -> void:
	_dismiss(true)


func _on_cancel() -> void:
	_dismiss(false)


## Order matters. `await dialog.dismissed` resumes its caller inline during
## `emit()`, and callers routinely push or replace screens the moment they wake
## (the lobby's Leave does `replace_all(MAIN_MENU)`). Popping afterwards would
## discard whatever they just pushed and leave the stack empty, so this dialog
## takes itself off the stack *before* announcing the result.
func _dismiss(accepted: bool) -> void:
	if _dismissing:
		return
	_dismissing = true
	ScreenManager.pop()
	dismissed.emit(accepted)
