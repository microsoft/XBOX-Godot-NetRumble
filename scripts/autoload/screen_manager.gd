extends Node

## Stack-based screen navigation.
##
## Screens are ordinary PackedScenes whose root extends `res://scripts/ui/screens/screen.gd`.
## The manager owns a container node injected by `res://scenes/main.tscn` at startup;
## only the top screen receives input, and screens below it stay visible only when the
## screen above them is flagged as a popup.

signal screen_pushed(screen: NRScreen)
signal screen_popped(screen: NRScreen)

## Screen scenes are referenced by path, not `preload`ed. A screen script that calls
## `ScreenManager.push()` makes every screen scene depend on this autoload, so
## preloading them here would form a resource cycle that fails during import.
## `_resolve_scene()` validates and caches instead.
const ACQUIRE_USER := "res://scenes/ui/screens/acquire_user_screen.tscn"
const MAIN_MENU := "res://scenes/ui/screens/main_menu_screen.tscn"
const LOBBY := "res://scenes/ui/screens/lobby_screen.tscn"
const GAMEPLAY := "res://scenes/ui/screens/gameplay_screen.tscn"
const GAME_MENU := "res://scenes/ui/screens/game_menu_screen.tscn"
const MATCH_HISTORY := "res://scenes/ui/screens/match_history_screen.tscn"
const LOADING := "res://scenes/ui/screens/loading_screen.tscn"

const DIALOG_BOX := "res://scenes/ui/dialog_box.tscn"

var _container: Node = null
## Gameplay lives outside the UI CanvasLayer so a real Camera2D can drive the view.
var world_container: Node2D = null
## Draws behind the world (layer -2); hosts the starfield, whose Parallax2D layers
## follow the gameplay Camera2D.
var background_container: CanvasLayer = null
var _stack: Array[NRScreen] = []
var _scene_cache: Dictionary[String, PackedScene] = {}


## Called once by main.tscn. Screens are parented under `container`.
func set_container(container: Node) -> void:
	_container = container


## Called once by main.tscn. A Camera2D only affects nodes outside a CanvasLayer,
## so the simulated world is parented here rather than under the screen.
func set_world_containers(world: Node2D, background: CanvasLayer) -> void:
	world_container = world
	background_container = background


func get_stack_size() -> int:
	return _stack.size()


func current_screen() -> NRScreen:
	if _stack.is_empty():
		return null
	return _stack.back()


## True when `scene_path` is anywhere on the stack, not just on top. Callers waiting for
## a screen to be *gone* need the whole stack, because a screen sitting under its own
## dialog is still in charge of where the player ends up.
func has_screen(scene_path: String) -> bool:
	for screen in _stack:
		if is_instance_valid(screen) and screen.scene_file_path == scene_path:
			return true
	return false


## Pushes a screen scene and returns the instantiated screen node.
## `payload` is handed to the screen via `configure()` before it enters the tree,
## so screens can initialise without racing `_ready`.
func push(scene_path: String, payload: Variant = null) -> NRScreen:
	if _container == null:
		push_error("ScreenManager.push called before set_container()")
		return null

	var packed := _resolve_scene(scene_path)
	if packed == null:
		return null

	var screen := packed.instantiate() as NRScreen
	if screen == null:
		push_error("ScreenManager: '%s' does not have an NRScreen root" % packed.resource_path)
		return null

	if payload != null:
		screen.configure(payload)

	var previous := current_screen()
	# Recorded before the new screen is added: _refresh_visibility() hides a covered
	# screen, and hiding a Control makes the viewport drop its focus owner, so a screen
	# asked afterwards would always report nothing to come back to.
	if previous != null:
		previous.on_covered()

	_stack.append(screen)
	_container.add_child(screen)
	_refresh_visibility()

	screen_pushed.emit(screen)
	return screen


## Removes the top screen. Returns true when a screen was actually popped.
func pop() -> bool:
	if _stack.is_empty():
		return false

	var screen: NRScreen = _stack.pop_back()
	screen_popped.emit(screen)
	if is_instance_valid(screen):
		screen.queue_free()

	_refresh_visibility()

	var revealed := current_screen()
	if revealed != null:
		revealed.on_revealed()
	return true


## Clears the stack and pushes `scene_path` as the sole screen.
func replace_all(scene_path: String, payload: Variant = null) -> NRScreen:
	clear()
	return push(scene_path, payload)


## Removes one particular screen, wherever it sits. Returns true when it was on the stack.
##
## pop() removes whatever is on top, which is the right answer only while the caller *is*
## the top. A flow that pushed a loading screen and then awaited cannot assume that: a
## newer flow can have pushed its own screen above, and popping there would take down the
## replacement's screen and leave the stale one behind. Naming the screen removes the one
## the caller actually owns, and does nothing if someone else already removed it.
func remove(screen: NRScreen) -> bool:
	if screen == null:
		return false
	var index := _stack.find(screen)
	if index == -1:
		return false
	_stack.remove_at(index)
	screen_popped.emit(screen)
	if is_instance_valid(screen):
		screen.queue_free()

	_refresh_visibility()

	# Only a screen removed from the top uncovers anything. Pulling one out from
	# underneath leaves whatever is above it exactly where it was, still in focus.
	if index == _stack.size():
		var revealed := current_screen()
		if revealed != null:
			revealed.on_revealed()
	return true


func clear() -> void:
	while not _stack.is_empty():
		var screen: NRScreen = _stack.pop_back()
		if is_instance_valid(screen):
			screen.queue_free()


func _resolve_scene(scene_path: String) -> PackedScene:
	if _scene_cache.has(scene_path):
		return _scene_cache[scene_path]
	var packed := load(scene_path) as PackedScene
	if packed == null:
		push_error("ScreenManager: failed to load '%s'" % scene_path)
		return null
	_scene_cache[scene_path] = packed
	return packed


## Pops screens until `scene_path` is on top, leaving the stack untouched when the
## screen isn't present.
func pop_to(scene_path: String) -> void:
	for i in range(_stack.size() - 1, -1, -1):
		if _stack[i].scene_file_path == scene_path:
			while _stack.size() > i + 1:
				pop()
			return


## Convenience wrapper that shows a modal message and awaits dismissal.
## Returns true when the user accepted, false when they cancelled.
##
## `ok_text`/`cancel_text` relabel the buttons for a dialog whose two options are both
## actions rather than a yes/no; leave them empty for the usual OK/Cancel.
func show_dialog(
		title: String,
		message: String,
		severity: String = "default",
		show_cancel: bool = false,
		ok_text: String = "",
		cancel_text: String = "") -> bool:
	var dialog := push(DIALOG_BOX, {
		"title": title,
		"message": message,
		"severity": severity,
		"show_cancel": show_cancel,
		"ok_text": ok_text,
		"cancel_text": cancel_text,
	})
	if dialog == null:
		return false
	if not dialog.has_signal("dismissed"):
		return false
	var accepted: bool = await dialog.dismissed
	return accepted


## Only the top screen processes input. Screens below stay visible when the screen
## directly above them declares itself a popup (`is_popup == true`).
func _refresh_visibility() -> void:
	var topmost := _stack.size() - 1
	var covered_by_popup := true
	for i in range(topmost, -1, -1):
		var screen := _stack[i]
		if not is_instance_valid(screen):
			continue

		var is_top := i == topmost
		screen.visible = is_top or covered_by_popup
		screen.process_mode = Node.PROCESS_MODE_INHERIT if is_top else Node.PROCESS_MODE_DISABLED
		screen.set_is_active(is_top)

		# Anything under a full-screen (non-popup) screen is hidden.
		covered_by_popup = covered_by_popup and screen.is_popup
