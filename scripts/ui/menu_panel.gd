class_name NRMenuPanel
extends CenterContainer

## Reusable panel shell for menu screens. Screens own their menu rows, while the
## shared title bar and scroll container stay in this one scene.

@export var title: String = "Menu":
	set(value):
		title = value
		if is_instance_valid(_title_label):
			_title_label.text = value

@export var panel_size: Vector2 = Vector2(960, 540):
	set(value):
		panel_size = value
		if is_instance_valid(_panel):
			_panel.custom_minimum_size = value
			# The list scrolls, so it contributes no height of its own: the panel is
			# exactly `panel_size` and a list taller than it scrolls inside.
			_scroll.set_deferred("scroll_vertical", 0)

@onready var _panel: PanelContainer = %Panel
@onready var _scroll: ScrollContainer = %Scroll
@onready var _title_label: Label = %TitleLabel
@onready var _menu_list: NRMenuList = %MenuList


func _ready() -> void:
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	_panel.custom_minimum_size = panel_size
	_title_label.text = title


func menu_list() -> NRMenuList:
	return _menu_list
