class_name NRSpinner
extends Control

## A left-arrow / value / right-arrow option cycler used across the options screens.
## The scene owns the row nodes; this script handles wrap-around input and MenuScroll
## feedback.

signal value_changed(index: int, value: Variant)

@export var label_text: String = "":
	set(value):
		label_text = value
		if is_instance_valid(_label):
			_label.text = value
			_label.visible = not value.is_empty()

var selected_index: int = 0:
	set(value):
		_set_index(value, false)
	get:
		return _selected_index

var wrap_around: bool = true

@onready var _label: Label = %Label
@onready var _value_label: Label = %ValueLabel
@onready var _left_arrow: TextureRect = %LeftArrow
@onready var _right_arrow: TextureRect = %RightArrow

var _selected_index: int = 0
var _options: Array = []
var _display_texts: PackedStringArray = PackedStringArray()


func _ready() -> void:
	focus_mode = Control.FOCUS_ALL
	mouse_filter = Control.MOUSE_FILTER_STOP
	custom_minimum_size = Vector2(0, 54)
	_label.text = label_text
	_label.visible = not label_text.is_empty()
	_left_arrow.texture = Assets.texture("Shape_LeftArrow")
	_right_arrow.texture = Assets.texture("Shape_RightArrow")
	_left_arrow.gui_input.connect(_on_arrow_input.bind(-1))
	_right_arrow.gui_input.connect(_on_arrow_input.bind(1))
	_update_value_text()
	focus_entered.connect(_on_focus_entered)
	# The row is a bare Control, so the theme's Button focus stylebox never applies to
	# it and the ring is the only thing that shows which setting is selected.
	NRFocusRing.attach(self)


## Sets the cyclable options. `display_texts`, when supplied, overrides how each
## option renders (e.g. "Off"/"On" for a boolean option array).
func set_options(values: Array, display_texts: PackedStringArray = PackedStringArray()) -> void:
	_options = values.duplicate()
	_display_texts = display_texts
	selected_index = clampi(selected_index, 0, maxi(_options.size() - 1, 0))
	_update_value_text()


func current_value() -> Variant:
	if _options.is_empty():
		return null
	return _options[clampi(selected_index, 0, _options.size() - 1)]


## Selects the option equal to `value`, if present, without emitting.
func select_value(value: Variant) -> void:
	var index := _options.find(value)
	if index >= 0:
		_set_index(index, false)


func _on_arrow_input(event: InputEvent, direction: int) -> void:
	if event is InputEventMouseButton and event.pressed and event.button_index == MOUSE_BUTTON_LEFT:
		grab_focus()
		_step(direction)


func _step(direction: int) -> void:
	if _options.size() <= 1:
		return
	var next := selected_index + direction
	if wrap_around:
		next = posmod(next, _options.size())
	else:
		next = clampi(next, 0, _options.size() - 1)
	if next != selected_index:
		_set_index(next, true)
		AudioManager.play_sound("MenuScroll")


func _set_index(value: int, emit: bool) -> void:
	if _options.is_empty():
		_selected_index = 0
	else:
		_selected_index = clampi(value, 0, _options.size() - 1)
	_update_value_text()
	if emit:
		value_changed.emit(_selected_index, current_value())


func _update_value_text() -> void:
	if not is_instance_valid(_value_label):
		return
	if _options.is_empty():
		_value_label.text = ""
		return
	if selected_index < _display_texts.size():
		_value_label.text = _display_texts[selected_index]
	else:
		_value_label.text = str(current_value())


func _gui_input(event: InputEvent) -> void:
	if event.is_action_pressed("ui_left") or event.is_action_pressed("move_left"):
		_step(-1)
		accept_event()
	elif event.is_action_pressed("ui_right") or event.is_action_pressed("move_right"):
		_step(1)
		accept_event()


func _on_focus_entered() -> void:
	AudioManager.play_sound("MenuScroll")
