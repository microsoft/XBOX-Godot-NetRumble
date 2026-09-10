class_name NRSlider
extends Control

## A labelled, focusable slider row for NRMenuList.
##
## The options list is otherwise built entirely out of NRSpinner, which is the right
## control for a handful of named choices.
## It is the wrong one for a continuous range: cycling a spinner one notch at a time
## across a whole spectrum is slow on a gamepad and gives no sense of where in the
## range the current value sits, which is exactly what a drop-rate setting needs to
## communicate.
##
## Focus lives on this root rather than on the inner HSlider, mirroring NRSpinner, so
## NRMenuList's wrap-around neighbour wiring keeps working unchanged and the arrow keys
## are handled here. The HSlider is left mouse-interactive so the bar can also just be
## dragged, but it never takes focus itself, which would otherwise strand gamepad
## navigation inside the row.
##
## The row is laid out to sit in the same grid as the spinner rows around it: the bar
## spans exactly the span a spinner's two arrows bracket, so every row in the list
## begins and ends its control on the same two columns, and the readout follows the
## label on the left where the spinner rows have nothing.

signal value_changed(value: float)

@export var label_text: String = "":
	set(text):
		label_text = text
		if is_instance_valid(_label):
			_label.text = text
			_label.visible = not text.is_empty()

@onready var _label: Label = %Label
@onready var _value_label: Label = %ValueLabel
@onready var _slider: HSlider = %Slider

## Formats the raw value for the readout. Left unset, the value is printed as-is.
var format_value: Callable = Callable()

var _emitting := true


func _ready() -> void:
	focus_mode = Control.FOCUS_ALL
	mouse_filter = Control.MOUSE_FILTER_STOP
	custom_minimum_size = Vector2(0, 54)
	_label.text = label_text
	_label.visible = not label_text.is_empty()
	_slider.value_changed.connect(_on_slider_value_changed)
	focus_entered.connect(_on_focus_entered)
	_update_value_text()
	# Focus lives on this root rather than the inner HSlider, which has focus_mode 0
	# and so never draws the theme's focus box. The ring marks the whole row instead.
	NRFocusRing.attach(self)


## Configures the range. Called before `set_value` so the value is not clamped against
## a stale range.
func configure(minimum: float, maximum: float, step: float) -> void:
	_slider.min_value = minimum
	_slider.max_value = maximum
	_slider.step = step
	_update_value_text()


## Sets the slider without emitting, for seeding the row from saved settings.
func set_value_silent(value: float) -> void:
	_emitting = false
	_slider.value = value
	_emitting = true
	_update_value_text()


func current_value() -> float:
	return _slider.value


func _step(direction: int) -> void:
	var step: float = _slider.step if _slider.step > 0.0 else (_slider.max_value - _slider.min_value) / 20.0
	var next := clampf(_slider.value + step * float(direction), _slider.min_value, _slider.max_value)
	if is_equal_approx(next, _slider.value):
		return
	_slider.value = next
	AudioManager.play_sound("MenuScroll")


func _on_slider_value_changed(value: float) -> void:
	_update_value_text()
	if _emitting:
		value_changed.emit(value)


func _update_value_text() -> void:
	if not is_instance_valid(_value_label):
		return
	if format_value.is_valid():
		_value_label.text = str(format_value.call(_slider.value))
	else:
		_value_label.text = str(_slider.value)


func _gui_input(event: InputEvent) -> void:
	if event.is_action_pressed("ui_left") or event.is_action_pressed("move_left"):
		_step(-1)
		accept_event()
	elif event.is_action_pressed("ui_right") or event.is_action_pressed("move_right"):
		_step(1)
		accept_event()


func _on_focus_entered() -> void:
	AudioManager.play_sound("MenuScroll")
