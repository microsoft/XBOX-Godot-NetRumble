extends NRScreen

## Top global scores. Each visit queries PlayFab; there is no offline leaderboard cache.

@onready var _list: NRMenuList = %MenuList

var _submission_row: NRButton = null
var _loading := false


func _ready() -> void:
	super._ready()
	Services.leaderboard_submission_changed.connect(_refresh_submission_status)
	_rebuild()


func _rebuild() -> void:
	if _loading:
		return
	_loading = true
	_show_loading()

	var result: Dictionary = await Services.get_leaderboard()
	if not is_inside_tree() or is_queued_for_deletion():
		return

	_loading = false
	_list.clear_rows()
	_submission_row = _add_notice("")
	_refresh_submission_status()
	if not bool(result["ok"]):
		_add_notice(String(result["message"]))
	else:
		var entries: Array = result["entries"]
		for entry: Dictionary in entries:
			# Focus scrolls the container on a gamepad, so score rows must be buttons
			# even though selecting one does nothing.
			_list.add_button(_format_entry(entry), Callable())
		if entries.is_empty():
			_list.add_button("No leaderboard entries to display.", Callable())
	_list.add_button("Refresh", _rebuild)
	_list.add_button("Back", on_back_pressed)
	_focus_rows.call_deferred()


func _show_loading() -> void:
	_list.clear_rows()
	_submission_row = _add_notice("")
	_refresh_submission_status()
	_list.add_button("Loading\u2026", Callable())
	_list.add_button("Back", on_back_pressed)
	_focus_rows.call_deferred()


## Policy instructions and HRESULTs must wrap rather than being clipped to one line.
func _add_notice(message: String) -> NRButton:
	var row := _list.add_button(message, Callable())
	row.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	row.clip_text = false
	return row


func _refresh_submission_status() -> void:
	if not is_inside_tree() or is_queued_for_deletion():
		return
	if not is_instance_valid(_submission_row) or _submission_row.is_queued_for_deletion():
		return
	var status := Services.get_leaderboard_submission()
	var message := String(status.get("message", ""))
	var held_focus := get_viewport().gui_get_focus_owner() == _submission_row
	_submission_row.text = "Last score submission:\n" + message if not message.is_empty() else ""
	_submission_row.visible = not message.is_empty()
	_list.refresh_focus_wrap()
	if not _submission_row.visible and held_focus:
		_focus_rows.call_deferred()


func _format_entry(entry: Dictionary) -> String:
	return "#%d: %s - Score: %d" % [
		int(entry["rank"]), String(entry["display_name"]), int(entry["score"])]


## Check at deferred execution time: a query can finish beneath a newer screen or
## overlay, and its completion must not take focus away from that UI.
func _focus_rows() -> void:
	if not is_inside_tree() or is_queued_for_deletion() or not is_active:
		return
	var focused := get_viewport().gui_get_focus_owner()
	if focused != null and not is_ancestor_of(focused):
		return
	_list.focus_first()
