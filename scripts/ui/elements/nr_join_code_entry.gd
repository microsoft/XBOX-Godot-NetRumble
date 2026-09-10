class_name NRJoinCodeEntry
extends Control

## A modal overlay that captures a fixed-length lobby join code. The scene owns the
## cells/buttons; this script enforces upper-case five-character input and emits
## `submitted`. There is no cancel signal: cancelling closes the overlay without any
## notification to callers, because no screen needs to act on a cancellation.
## Submission leaves the overlay in place; the loading screen covers it, and a failed
## join reveals the same editable code instead of making the player retype all five
## characters.

signal submitted(code: String)

## Five characters, matching PartyService.JOIN_CODE_LENGTH and the five-character
## validation PlayFabManager performs before the lobby search begins.
const JOIN_CODE_LENGTH := 5

@export var title: String = "Enter Join Code":
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
	_line_edit.max_length = JOIN_CODE_LENGTH
	_line_edit.text_changed.connect(_on_text_changed)
	_line_edit.text_submitted.connect(_on_text_submitted)
	_ok_button.pressed.connect(_on_ok)
	_cancel_button.pressed.connect(_on_cancel)
	if NRSystemKeyboard.is_available():
		_line_edit.gui_input.connect(_on_line_edit_gui_input)
		_open_system_keyboard()
	else:
		_line_edit.call_deferred("grab_focus")


## Console has no hardware keyboard, so the system text-entry UI opens with the dialog
## and can be reopened with A from the code field.
func _open_system_keyboard() -> void:
	_ok_button.call_deferred("grab_focus")
	var text: Variant = await NRSystemKeyboard.request(
			title, "", _line_edit.text, "alphanumeric", JOIN_CODE_LENGTH)
	if not is_inside_tree():
		return
	if text != null:
		_line_edit.text = str(text).to_upper()
		_on_text_changed(_line_edit.text)
	if _ok_button.disabled:
		_cancel_button.grab_focus()
	else:
		_ok_button.grab_focus()


func _on_line_edit_gui_input(event: InputEvent) -> void:
	if event.is_action_pressed("ui_accept"):
		_line_edit.accept_event()
		_open_system_keyboard()


func _on_text_changed(new_text: String) -> void:
	var upper := new_text.to_upper()
	if upper != new_text:
		var caret := _line_edit.caret_column
		_line_edit.text = upper
		_line_edit.caret_column = caret
	_ok_button.disabled = _line_edit.text.strip_edges().length() < JOIN_CODE_LENGTH


func _on_text_submitted(_text: String) -> void:
	if not _ok_button.disabled:
		_on_ok()


func _on_ok() -> void:
	submitted.emit(_line_edit.text.strip_edges().to_upper())


func refocus_code() -> void:
	if not is_inside_tree():
		return
	_line_edit.editable = true
	_line_edit.call_deferred("grab_focus")
	_line_edit.caret_column = _line_edit.text.length()


func _on_cancel() -> void:
	queue_free()


func _unhandled_input(event: InputEvent) -> void:
	if event.is_action_pressed("ui_back_action"):
		get_viewport().set_input_as_handled()
		_on_cancel()


func _exit_tree() -> void:
	NRScreen.restore_overlay_focus(_previous_focus)
