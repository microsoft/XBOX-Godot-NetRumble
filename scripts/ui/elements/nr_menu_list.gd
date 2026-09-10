class_name NRMenuList
extends VBoxContainer

## A vertical list of focusable rows (buttons and spinners) with wrap-around navigation.
## Godot's focus system does the neighbour walking; this element just registers the rows
## and wires first<->last wrap-around after each addition so navigation loops instead of
## dead-ending at the top or bottom of the list.

signal focus_changed(index: int)

const _ROW_HEIGHT := 54.0
const _BUTTON_SCENE := preload("res://scenes/ui/elements/nr_button.tscn")
const _SPINNER_SCENE := preload("res://scenes/ui/elements/nr_spinner.tscn")
const _SLIDER_SCENE := preload("res://scenes/ui/elements/nr_slider.tscn")

## Theme variation applied to buttons added through this list.
##
## Main menu rows render as bare centred text (NRTitleButton), while panel menus and
## the pause menu use the boxed variation that draws a background slab behind each row.
## Lists default to the boxed variation; the main menu opts into the transparent one.
@export var button_variation: StringName = &"NRMenuButton"

## Gap between rows. The main menu stacks its 54px rows at a 54px pitch with no gap;
## the boxed lists keep a small gap so their backgrounds stay distinct.
@export var row_separation: int = 5

## Focusable rows only. Headers and notes are children but never entries here, so
## focus navigation skips straight over them.
var _rows: Array[Control] = []


func _ready() -> void:
	add_theme_constant_override("separation", row_separation)
	alignment = BoxContainer.ALIGNMENT_BEGIN


func add_button(text: String, on_selected: Callable) -> NRButton:
	var button := _BUTTON_SCENE.instantiate() as NRButton
	button.text = text
	button.theme_type_variation = button_variation
	button.custom_minimum_size = Vector2(0, _ROW_HEIGHT)
	button.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	if on_selected.is_valid():
		button.pressed.connect(on_selected)
	_register(button)
	return button


## Adds a labelled spinner row. `display_texts` overrides how options render.
func add_spinner(
		label_text: String,
		options: Array,
		on_changed: Callable,
		display_texts: PackedStringArray = PackedStringArray()) -> NRSpinner:
	var spinner := _SPINNER_SCENE.instantiate() as NRSpinner
	spinner.label_text = label_text
	spinner.custom_minimum_size = Vector2(0, _ROW_HEIGHT)
	spinner.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	add_child(spinner)
	spinner.set_options(options, display_texts)
	if on_changed.is_valid():
		spinner.value_changed.connect(func(index: int, value: Variant) -> void: on_changed.call(index, value))
	_rows.append(spinner)
	spinner.focus_entered.connect(_on_row_focus_entered.bind(spinner))
	_update_wrap()
	return spinner


## Adds a labelled slider row for a continuous value. `format_value` renders the
## readout beside the bar; without it the raw number is shown.
func add_slider(
		label_text: String,
		minimum: float,
		maximum: float,
		step: float,
		initial: float,
		on_changed: Callable,
		format_value: Callable = Callable()) -> NRSlider:
	var slider := _SLIDER_SCENE.instantiate() as NRSlider
	slider.label_text = label_text
	slider.custom_minimum_size = Vector2(0, _ROW_HEIGHT)
	slider.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	add_child(slider)
	# Configured only once the node is in the tree: the range and value live on the
	# inner HSlider, which the @onready reference does not resolve until then.
	slider.format_value = format_value
	slider.configure(minimum, maximum, step)
	slider.set_value_silent(initial)
	if on_changed.is_valid():
		slider.value_changed.connect(func(value: float) -> void: on_changed.call(value))
	_rows.append(slider)
	slider.focus_entered.connect(_on_row_focus_entered.bind(slider))
	_update_wrap()
	return slider


func _register(row: Control) -> void:
	add_child(row)
	_rows.append(row)
	row.focus_entered.connect(_on_row_focus_entered.bind(row))
	_update_wrap()


## Non-focusable heading that groups the rows beneath it.
func add_header(text: String) -> Label:
	var header := Label.new()
	header.text = text
	header.theme_type_variation = &"SectionHeader"
	header.custom_minimum_size = Vector2(0, 56)
	header.vertical_alignment = VERTICAL_ALIGNMENT_BOTTOM
	add_child(header)
	return header


## Non-focusable informational row, for sections that have nothing to configure.
func add_note(text: String) -> Label:
	var note := Label.new()
	note.text = text
	note.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	note.custom_minimum_size = Vector2(0, _ROW_HEIGHT)
	note.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	add_child(note)
	return note


## Adds a 0-100 percentage spinner bound to a normalised (0..1) value.
func add_percent_spinner(label_text: String, initial: float, on_percent: Callable) -> NRSpinner:
	var options: Array = []
	var display := PackedStringArray()
	for value in range(0, 101):
		options.append(value)
		display.append("%d%%" % value)
	var spinner := add_spinner(label_text, options, func(_index: int, value: Variant) -> void:
		on_percent.call(int(value) / 100.0), display)
	spinner.select_value(clampi(roundi(initial * 100.0), 0, 100))
	return spinner


func add_bool_spinner(label_text: String, initial: bool, on_toggle: Callable) -> NRSpinner:
	var spinner := add_spinner(label_text, [false, true], func(_index: int, value: Variant) -> void:
		on_toggle.call(bool(value)), PackedStringArray(["Off", "On"]))
	spinner.select_value(initial)
	return spinner


func add_choice_spinner(
		label_text: String,
		choices: PackedStringArray,
		initial_index: int,
		on_choice: Callable) -> NRSpinner:
	var options: Array = []
	for i in choices.size():
		options.append(i)
	var spinner := add_spinner(label_text, options, func(index: int, _value: Variant) -> void:
		on_choice.call(index), choices)
	spinner.select_value(clampi(initial_index, 0, maxi(choices.size() - 1, 0)))
	return spinner


## Empties the list. Every child goes, not just the focusable rows, so headers and
## notes cannot survive a rebuild.
##
## queue_free() rather than free(): rebuilds are commonly triggered from a row's own
## `pressed`/`value_changed` handler, and freeing the emitter mid-signal crashes. The
## nodes stay parented until the queue runs, so they are also still owned by the tree
## if the game shuts down first — detaching them here would orphan them and leak.
func clear_rows() -> void:
	for child in get_children():
		child.queue_free()
	_rows.clear()


func focus_first() -> void:
	for row in _rows:
		if _is_focusable(row):
			row.grab_focus()
			return


func focus_by_index(index: int) -> void:
	if index >= 0 and index < _rows.size() and _is_focusable(_rows[index]):
		_rows[index].grab_focus()


func rows() -> Array[Control]:
	return _rows


## Recomputes the focus wrap. Needed after a row's `disabled` or `visible` state changes
## outside this class: the neighbours are explicit node paths, so a row that became
## unfocusable would otherwise still be wired into the loop and swallow the focus.
func refresh_focus_wrap() -> void:
	_update_wrap()


func _is_focusable(row: Control) -> bool:
	return is_instance_valid(row) and row.focus_mode != Control.FOCUS_NONE and row.visible \
		and not (row is BaseButton and (row as BaseButton).disabled)


## Rewires vertical focus neighbours so navigation wraps between the last and first
## focusable rows.
func _update_wrap() -> void:
	var focusable: Array[Control] = []
	for row in _rows:
		if _is_focusable(row):
			focusable.append(row)
	if focusable.is_empty():
		return
	for i in focusable.size():
		var current := focusable[i]
		var prev := focusable[(i - 1 + focusable.size()) % focusable.size()]
		var next := focusable[(i + 1) % focusable.size()]
		current.focus_neighbor_top = prev.get_path()
		current.focus_neighbor_bottom = next.get_path()
		current.focus_previous = prev.get_path()
		current.focus_next = next.get_path()


func _on_row_focus_entered(row: Control) -> void:
	focus_changed.emit(_rows.find(row))
