class_name NRChatEntry
extends Control

## A modal overlay that captures a free-text chat message (max 100 chars).
## nr_chat_entry.tscn owns the dialog layout.

signal submitted(text: String)
signal cancelled()

const MAX_MESSAGE_LENGTH := ChatService.MAX_MESSAGE_LENGTH

@export var title: String = "Chat Message":
	set(value):
		title = value
		if is_instance_valid(_title_label):
			_title_label.text = value

@onready var _title_label: Label = %TitleLabel
@onready var _line_edit: LineEdit = %LineEdit
@onready var _ok_button: NRButton = %OkButton
@onready var _cancel_button: NRButton = %CancelButton

## The overlay is not a screen, so closing it never triggers ScreenManager's reveal
## hook. Without this a gamepad would be left with nothing focused underneath.
var _previous_focus: Control = null


func _ready() -> void:
	_previous_focus = get_viewport().gui_get_focus_owner()
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_STOP
	_title_label.text = title
	_line_edit.max_length = MAX_MESSAGE_LENGTH
	_line_edit.text_submitted.connect(_on_text_submitted)
	_ok_button.pressed.connect(_on_ok)
	_cancel_button.pressed.connect(_on_cancel)
	if NRSystemKeyboard.is_available():
		_line_edit.gui_input.connect(_on_line_edit_gui_input)
		_open_system_keyboard()
	else:
		_line_edit.call_deferred("grab_focus")


## Console has no hardware keyboard, so the system text-entry UI opens with the dialog
## and can be reopened with A from the message field.
func _open_system_keyboard() -> void:
	_ok_button.call_deferred("grab_focus")
	var text: Variant = await NRSystemKeyboard.request(
			title, "", _line_edit.text, "chat", MAX_MESSAGE_LENGTH)
	if not is_inside_tree():
		return
	if text != null:
		_line_edit.text = str(text)
	_ok_button.grab_focus()


func _on_line_edit_gui_input(event: InputEvent) -> void:
	if event.is_action_pressed("ui_accept"):
		_line_edit.accept_event()
		_open_system_keyboard()


func _on_text_submitted(_text: String) -> void:
	_on_ok()


func _on_ok() -> void:
	# The dialog stays open when the callback returns false, so the typed message
	# survives a failed send. Closing is therefore the owner's decision, not this element's.
	submitted.emit(_line_edit.text.strip_edges())


func _on_cancel() -> void:
	cancelled.emit()
	queue_free()


func _gui_input(event: InputEvent) -> void:
	if event.is_action_pressed("ui_back_action"):
		accept_event()
		_on_cancel()


func _unhandled_input(event: InputEvent) -> void:
	if event.is_action_pressed("ui_back_action"):
		get_viewport().set_input_as_handled()
		_on_cancel()


func _exit_tree() -> void:
	NRScreen.restore_overlay_focus(_previous_focus)
