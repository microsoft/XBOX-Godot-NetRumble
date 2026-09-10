class_name NRFriendList
extends Control

## The friends who are in a NetRumble session right now, and the way into one (XR-070).
## Opened from the main menu's Join Friend row.
##
## The list is deliberately only the *joinable* friends rather than the whole roster.
## This title has nothing to offer a friend who is offline or playing something else —
## no profile browsing, no "invite to play" for an account that is not in a session —
## so a full roster would be a list of rows that do nothing. What it can do is put the
## player in their friend's match in one press, which is what the requirement asks for.
##
## Structured like NRPlayerActions: a modal over the screen that opened it, rows built
## from what the platform actually reports, and a status line for the states that have
## no rows (loading, nobody to join, no platform to ask, not allowed online).
##
## The overlay is also where the "you cannot do this" cases surface. Join Friend opens
## it unconditionally rather than refusing with a dialog first, so every negative answer
## is one empty list the player backs out of with Cancel or B, not a modal in front of a
## screen they never got to see. The privilege answer is still authoritative: refresh
## waits on the same XR-045 resolution flow as Host and Lobby Code before offering rows.

## A friend's session was chosen. The payload is the lobby connection string their
## activity advertised, ready for NetManager.join_by_invite().
signal join_requested(connection_string: String)
signal closed()

const _BUTTON_SCENE: PackedScene = preload("res://scenes/ui/elements/nr_button.tscn")

@onready var _title_label: Label = %TitleLabel
@onready var _status_label: Label = %StatusLabel
@onready var _actions: VBoxContainer = %Actions
@onready var _cancel_button: NRButton = %CancelButton

## Set while the platform round trip is in flight, so Refresh cannot stack two.
var _loading := false
## Last active denial found by _refresh(). Kept separate from the cache because a failed
## platform check deliberately fails open and should not be presented as a denial.
var _online_denial := ""
## The overlay is not a screen, so closing it never triggers ScreenManager's reveal
## hook. Without this a gamepad would be left with nothing focused underneath.
var _previous_focus: Control = null


func _ready() -> void:
	_previous_focus = get_viewport().gui_get_focus_owner()
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_STOP
	_title_label.text = "Join Friend"
	_cancel_button.pressed.connect(_on_cancel)
	await _refresh()


## Asks the platform who is joinable and rebuilds the rows. Reading the friends list is
## a service round trip on first open, so the overlay says it is working rather than
## appearing empty for a second and then filling in.
func _refresh() -> void:
	if _loading:
		return
	_loading = true
	_clear_actions()
	_online_denial = ""
	_show_status("Checking online permissions…")
	_cancel_button.call_deferred("grab_focus")

	var friends: Array[Dictionary] = []
	if Services != null:
		_online_denial = await Services.resolve_multiplayer_denial_reason()
		if _online_denial.is_empty():
			_show_status("Looking for friends to join…")
			friends = await Services.joinable_friends()
	_loading = false
	if not is_inside_tree():
		return

	_clear_actions()
	if friends.is_empty():
		_show_status(_empty_reason())
		_cancel_button.call_deferred("grab_focus")
		return

	_hide_status()
	for friend in friends:
		_add_friend(friend)
	# Refreshing is the only way to notice a friend who started a match after the list
	# was opened, and it is cheaper than closing and reopening: the friends group is
	# already tracked by then, so only the activity lookup repeats.
	_add_action("Refresh", func() -> void: await _refresh())
	_focus_first()


## Why there is nobody to join, in the player's terms. The cases are distinguished
## because they mean different things: a build that cannot ask the platform should say
## so rather than claim the player has no friends playing, and an account that is not
## allowed online should hear that instead of a roster that merely looks empty.
##
## The last case covers two situations this list cannot tell apart -- an account with no
## friends, and an account whose friends are all doing something else -- because
## joinable_friends() returns an empty array for both. It is worded for the second, which
## is overwhelmingly the common one, and which does not read as a remark about the player.
func _empty_reason() -> String:
	if not _online_denial.is_empty():
		return _online_denial
	if Services == null or not Services.social_available():
		return "Joining a friend needs an Xbox sign-in on a console or PC GDK build."
	return "None of your friends are in a NetRumble match right now."


func _add_friend(friend: Dictionary) -> void:
	var connection_string := String(friend.get("connection_string", ""))
	if connection_string.is_empty():
		return
	_add_action(_friend_label(friend), func() -> void: _on_friend_chosen(connection_string))


## "Gamertag — 3/8" when the activity reported a player count, the gamertag alone when
## it did not. max_players is 0 for an activity published without one, and a count of
## "3/0" reads as a bug.
func _friend_label(friend: Dictionary) -> String:
	var gamertag := String(friend.get("gamertag", ""))
	if gamertag.is_empty():
		gamertag = String(friend.get("display_name", "Friend"))
	var max_players := int(friend.get("max_players", 0))
	var current_players := int(friend.get("current_players", 0))
	if max_players <= 0:
		return gamertag
	return "%s — %d/%d" % [gamertag, current_players, max_players]


func _add_action(label: String, handler: Callable) -> void:
	var button := _BUTTON_SCENE.instantiate() as NRButton
	button.text = label
	button.pressed.connect(handler)
	_actions.add_child(button)


func _clear_actions() -> void:
	for child in _actions.get_children():
		_actions.remove_child(child)
		child.queue_free()


func _focus_first() -> void:
	var first: Node = _actions.get_child(0) if _actions.get_child_count() > 0 else _cancel_button
	(first as Control).call_deferred("grab_focus")


func _show_status(text: String) -> void:
	_status_label.text = text
	_status_label.visible = true


func _hide_status() -> void:
	_status_label.text = ""
	_status_label.visible = false


## The join itself belongs to the menu, which owns the loading screen and the failure
## dialog, so this closes behind the request rather than waiting underneath it.
func _on_friend_chosen(connection_string: String) -> void:
	join_requested.emit(connection_string)
	_close()


func _on_cancel() -> void:
	_close()


func _close() -> void:
	closed.emit()
	queue_free()


func _gui_input(event: InputEvent) -> void:
	if event.is_action_pressed("ui_back_action"):
		accept_event()
		_on_cancel()


func _unhandled_input(event: InputEvent) -> void:
	if event.is_action_pressed("ui_back_action"):
		get_viewport().set_input_as_handled()
		_on_cancel()


func _exit_tree() -> void:
	NRScreen.restore_overlay_focus(_previous_focus)
