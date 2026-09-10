class_name NRScreen
extends Control

## Base class for all game screens. A screen is a full-rect Control managed by the
## ScreenManager autoload. This base provides the lifecycle hooks the manager calls
## (configure/on_covered/on_revealed/set_is_active), the `is_popup` flag that keeps
## screens below a popup visible, and ui_back_action handling that pops the screen.

var is_popup: bool = false
var is_active: bool = true
var allow_back: bool = true

## Control that held focus when this screen was covered. Mouse and keyboard users can
## re-acquire a target by clicking or tabbing, but a gamepad only drives the focused
## control, so a screen revealed with nothing focused would be dead to a controller.
var _focus_before_cover: Control = null


func _ready() -> void:
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_IGNORE


## Called by ScreenManager.push() before the screen enters the tree.
func configure(_payload: Variant) -> void:
	pass


## Called when another screen is pushed on top of this one.
func on_covered() -> void:
	if not is_inside_tree():
		return
	var focused := get_viewport().gui_get_focus_owner()
	if focused != null and is_ancestor_of(focused):
		_focus_before_cover = focused


## Called when the screen above this one is popped and this becomes the top screen.
func on_revealed() -> void:
	restore_focus()


## Called by ScreenManager whenever this screen's top-of-stack status changes.
func set_is_active(active: bool) -> void:
	is_active = active


func _unhandled_input(event: InputEvent) -> void:
	if not is_active:
		return
	if allow_back and event.is_action_pressed("ui_back_action"):
		get_viewport().set_input_as_handled()
		on_back_pressed()


## Default back behaviour: pop this screen if it isn't the root. Options screens
## override this to persist settings first.
func on_back_pressed() -> void:
	if ScreenManager.get_stack_size() > 1:
		ScreenManager.pop()


## Focuses the first row of a menu list on the next frame, after it is in the tree.
func focus_menu_list(menu_list: NRMenuList) -> void:
	if is_instance_valid(menu_list):
		menu_list.call_deferred("focus_first")


## True on a console build. The feature tag is the same one IdentityService and
## NRSystemKeyboard test against.
static func is_console() -> bool:
	return OS.has_feature("scarlett")


## Quits through the app root so an in-menu Quit runs the same shutdown sequence as
## closing the window: pending settings are saved and the match is left cleanly.
## Falls back to a plain quit if the root is somehow not in the tree.
func quit_game() -> void:
	var app := get_tree().get_first_node_in_group(&"app_root")
	if app != null and app.has_method("request_shutdown"):
		app.request_shutdown()
		return
	get_tree().quit()


## Puts focus back where it was before the screen was covered, falling back to the
## screen's first focusable control (the row that was focused may have been removed
## by a rebuild while the screen was covered). Screens with nothing focusable, such
## as gameplay, simply end up with no focus.
func restore_focus() -> void:
	call_deferred("_focus_best_target")


## Focus fallback for a closing overlay. It runs deferred and gives up the moment
## anything else holds focus, so a screen focusing a control of its own still wins;
## only a gamepad that would otherwise be left with nothing is rescued.
func restore_focus_if_unfocused() -> void:
	if not is_inside_tree():
		return
	if _is_focusable(get_viewport().gui_get_focus_owner()):
		return
	_focus_best_target()


## Deferred so the choice is made after any rebuild queued in the same frame, and after
## the overlay that gave focus back has actually left the tree.
func _focus_best_target() -> void:
	if not is_inside_tree():
		return
	var target := _focus_before_cover if _is_focusable(_focus_before_cover) else _first_focusable(self)
	if target != null:
		target.grab_focus()


## Returns focus after an overlay closes. `previous` is what the overlay remembered when
## it opened and is not always usable: the screen underneath may have rebuilt its rows,
## or nothing was focused at capture time because a covering screen (the permission
## check's loading screen, say) had only just been popped and its deferred focus
## restoration had not run yet. Falling back to the screen underneath keeps a gamepad
## from being stranded with no focus at all.
static func restore_overlay_focus(previous: Control) -> void:
	if _is_focusable(previous):
		previous.call_deferred("grab_focus")
		return
	var screen := ScreenManager.current_screen()
	if screen != null:
		screen.call_deferred("restore_focus_if_unfocused")


static func _is_focusable(control: Control) -> bool:
	return is_instance_valid(control) and not _is_being_freed(control) \
		and control.is_inside_tree() and control.is_visible_in_tree() \
		and control.focus_mode != Control.FOCUS_NONE \
		and not (control is BaseButton and (control as BaseButton).disabled)


## True when the node, or anything it hangs off, is on its way out of the tree. A
## closing overlay is still parented and still holds focus while its children run their
## exit handling, and queue_free() marks only the node it was called on, so its buttons
## would otherwise pass for live focus targets.
static func _is_being_freed(node: Node) -> bool:
	var current := node
	while current != null:
		if current.is_queued_for_deletion():
			return true
		current = current.get_parent()
	return false


static func _first_focusable(node: Node) -> Control:
	for child in node.get_children():
		if child.is_queued_for_deletion():
			continue
		var control := child as Control
		if control != null:
			if not control.visible:
				continue
			if _is_focusable(control):
				return control
		var found := _first_focusable(child)
		if found != null:
			return found
	return null
