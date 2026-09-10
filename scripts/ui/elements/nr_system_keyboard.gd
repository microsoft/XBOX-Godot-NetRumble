class_name NRSystemKeyboard
extends RefCounted

## Console-only bridge to the GDK's system text-entry UI (XGameUiShowTextEntryAsync).
## Xbox has no hardware keyboard, so a LineEdit is untypable there; on PC the LineEdit
## is left exactly as it was and this helper reports itself unavailable.

const XboxBootstrap := preload("res://addons/godot_gdk/runtime/gdk_bootstrap.gd")


## True only on a console build with the GDK extension loaded. Gated on the `scarlett`
## feature tag rather than on the singleton alone so a desktop GDK build keeps typing
## into the LineEdit.
static func is_available() -> bool:
	if not OS.has_feature("scarlett"):
		return false
	var xbox: Variant = XboxBootstrap.find_singleton()
	return xbox != null and xbox.game_ui != null


## Shows the system keyboard and returns the entered text, or null when it is
## unavailable, failed, or the player cancelled.
static func request(
		title: String,
		description: String,
		default_text: String,
		input_scope: String,
		max_length: int) -> Variant:
	if not is_available():
		return null
	var xbox: Variant = XboxBootstrap.find_singleton()
	var result: Variant = await xbox.game_ui.show_text_entry_async(
			title, description, default_text, input_scope, max_length)
	if result == null or not result.ok or result.data == null:
		return null
	return str(result.data.text)
