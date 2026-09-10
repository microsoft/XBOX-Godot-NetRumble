class_name NRButton
extends Button

## The shared project Theme owns the enabled/hovered/pressed visuals; this script
## adds focus and audio feedback: MenuScroll when focus/hover is gained, MenuSelect
## on activation.

var _sounds_enabled := true


func _ready() -> void:
	focus_mode = Control.FOCUS_ALL
	mouse_filter = Control.MOUSE_FILTER_STOP
	autowrap_mode = TextServer.AUTOWRAP_OFF
	clip_text = true
	if theme_type_variation == &"":
		theme_type_variation = &"NRMenuButton"

	focus_entered.connect(_on_focus_entered)
	mouse_entered.connect(_on_mouse_entered)
	pressed.connect(_on_pressed)


func set_sounds_enabled(enabled: bool) -> void:
	_sounds_enabled = enabled


func _on_focus_entered() -> void:
	if _sounds_enabled and not disabled:
		AudioManager.play_sound("MenuScroll")


func _on_mouse_entered() -> void:
	if _sounds_enabled and not disabled:
		grab_focus()


func _on_pressed() -> void:
	if _sounds_enabled and not disabled:
		AudioManager.play_sound("MenuSelect")
