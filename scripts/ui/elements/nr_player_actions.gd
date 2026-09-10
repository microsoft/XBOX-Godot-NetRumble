class_name NRPlayerActions
extends Control

## The actions the player can take against another player on the lobby roster: mute,
## report (XR-018) and the system profile card. Activating an occupied roster row opens
## this instead of toggling the mute directly, because a report needs a reason and there
## is no free button on the lobby for a second one-press action.
##
## Rows are built from what NetManager says is possible for this player, so an action
## that cannot work — reporting from a desktop custom-id session, muting someone the
## platform already silenced — is absent rather than offered and refused.

signal closed()

const _BUTTON_SCENE: PackedScene = preload("res://scenes/ui/elements/nr_button.tscn")

@onready var _title_label: Label = %TitleLabel
@onready var _status_label: Label = %StatusLabel
@onready var _actions: VBoxContainer = %Actions
@onready var _cancel_button: NRButton = %CancelButton

var _peer_id := 0
var _player_name := ""
## Set while a report reason is being picked, so the same overlay can show the second
## list without a second scene.
var _reporting := false

## The overlay is not a screen, so closing it never triggers ScreenManager's reveal
## hook. Without this a gamepad would be left with nothing focused underneath.
var _previous_focus: Control = null
## Optional override for callers whose opener should not regain focus after the modal
## closes. The lobby uses this for roster rows because Space is Ready there, not "open
## the last row action again."
var _restore_focus: Control = null


## Call before adding to the tree. `player_name` is only ever a gamertag or the name a
## peer reported, both of which are already on the roster.
func setup(peer_id: int, player_name: String) -> void:
	_peer_id = peer_id
	_player_name = player_name


func set_restore_focus(control: Control) -> void:
	_restore_focus = control


func _ready() -> void:
	_previous_focus = get_viewport().gui_get_focus_owner()
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_STOP
	_cancel_button.pressed.connect(_on_cancel)
	_build_actions()


func _build_actions() -> void:
	_title_label.text = _player_name if not _player_name.is_empty() else "Player"
	_status_label.text = ""
	_status_label.visible = false
	_clear_actions()

	if NetManager.can_mute_peer(_peer_id):
		var muted := NetManager.is_peer_muted(_peer_id)
		_add_action("Unmute Player" if muted else "Mute Player", _on_mute)
	if NetManager.can_report_player(_peer_id):
		_add_action("Report Player", _on_report)
		_add_action("View Profile", _on_profile)
	if _actions.get_child_count() == 0:
		_show_status("There is nothing to do for this player.")
	_focus_first()


## The reason list. Reporting without a reason tells the service nothing, and the
## service rejects a feedback type it does not know, so the reasons come from
## ModerationService rather than from here.
func _build_report_reasons() -> void:
	_reporting = true
	_title_label.text = "Report %s" % _player_name
	_status_label.text = ""
	_status_label.visible = false
	_clear_actions()
	for reason: Dictionary in ModerationService.REPORT_REASONS:
		var feedback_type := String(reason.get("type", ""))
		_add_action(String(reason.get("label", "")), func() -> void:
			await _submit_report(feedback_type))
	_focus_first()


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


func _on_mute() -> void:
	# Muting is a pair of GDK round-trips on console, so the list stands down for the
	# duration: a second press would toggle the state straight back, and Report would
	# open a reason list this coroutine is about to tear down.
	_clear_actions()
	_show_status("Updating…")
	await NetManager.toggle_peer_mute(_peer_id)
	if not is_inside_tree():
		return
	_close()


func _on_report() -> void:
	_build_report_reasons()


func _on_profile() -> void:
	# The system card is modal on console, so the overlay closes behind it rather than
	# waiting underneath for a result the player cannot see. The call is deliberately not
	# awaited: this node is freed by _close() and would never be resumed.
	NetManager.show_player_profile(_peer_id)
	_close()


func _submit_report(feedback_type: String) -> void:
	_clear_actions()
	_show_status("Sending report…")
	var sent: bool = await NetManager.report_player(_peer_id, feedback_type)
	if not is_inside_tree():
		return
	# Reporting is one-shot: a second report of the same thing adds nothing, and leaving
	# the list up invites one. Xbox is told; the player is told it was told.
	_show_status("Report sent. Thanks for helping keep Xbox safe." if sent
			else "That report couldn't be sent right now.")
	_cancel_button.text = "Close"
	_cancel_button.call_deferred("grab_focus")


func _on_cancel() -> void:
	if _reporting and _actions.get_child_count() > 0:
		# Backing out of the reason list returns to the actions rather than closing, so
		# a mis-picked "Report" is one button away from being undone.
		_reporting = false
		_cancel_button.text = "Cancel"
		_build_actions()
		return
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
	var target := _restore_focus if _restore_focus != null else _previous_focus
	NRScreen.restore_overlay_focus(target)
