class_name NRRosterRow
extends Control

## One player entry in the lobby roster.
##
## Layout: 520x61 sheared panel — ship silhouette on the left, ready-up ring beside
## it, nameplate at x=119, microphone indicator hanging outside the panel's left edge.
## An unoccupied slot renders the panel with "Invite To Game..." and hides everything else.
##
## The microphone icon is driven by NetManager.chat_indicator_for(). Party's
## GetChatIndicator has no binding in godot_playfab, so Available and Muted are
## real but Talking is currently unreachable.
##
## An occupied row is also the entry point to the actions the player can take against
## that player (XR-015 mute, XR-018 report): activating it opens the player actions
## overlay. A row with nothing available shows the inert "Invite To Game..." placeholder,
## and a player the platform silenced says so rather than looking broken.

const _NEUTRAL := Color(0.74, 0.78, 0.78, 0.66)
const _MUTED_TINT := Color(1.0, 0.25, 0.25, 0.85)

## An empty slot was activated, asking for the platform invite UI (XR-064). Only ever
## emitted while the slot is invitable — see set_invitable().
signal invite_requested
## An occupied slot was activated, asking for the actions available against that player.
## Only ever emitted while the row is actionable — see set_actions_context().
signal actions_requested(peer_id: int)

@onready var _silhouette: TextureRect = %Silhouette
@onready var _ready_ring: Control = %Ready
@onready var _checkmark: TextureRect = %Checkmark
@onready var _name_label: Label = %NameLabel
@onready var _mic: TextureRect = %Mic

## Set by set_state() before the node enters the tree; applied in _ready().
var _pending: PlayerState = null
var _pending_set: bool = false

## Whether an empty slot can actually send an invite. False on a practice match, on a
## desktop custom-id session and in any build without the GDK, where the row keeps its
## original dimmed, non-interactive appearance.
var _invitable := false
## Whether this row is currently rendering an empty slot rather than a player.
var _is_empty := true
## Peer id of the player on this row, 0 when it is empty.
var _peer_id := 0
## Whether activating this row opens the player actions overlay, and whether the player
## is muted already. A platform-restricted player is muted but not unmutable by the
## player: the restriction is not theirs to lift (XR-015).
var _actionable := false
var _muted := false
## Whether the platform, rather than the player, is the one silencing them.
var _restricted := false


func _ready() -> void:
	# Rows are real focus targets (Invite, player actions), but the row draws its own
	# panel art and has no stylebox, so the ring is what makes the selection visible.
	NRFocusRing.attach(self)
	if _pending_set:
		var state := _pending
		_pending = null
		_pending_set = false
		set_state(state)


## Applies `state` to the row, or clears it to the "Invite To Game..." placeholder
## when `state` is null. Safe to call before the node is ready, which lets the
## lobby configure a freshly instantiated row before adding it to the tree.
func set_state(state: PlayerState) -> void:
	if not is_node_ready():
		_pending = state
		_pending_set = true
		return
	if state == null:
		_silhouette.visible = false
		_ready_ring.visible = false
		_mic.visible = false
		_is_empty = true
		_peer_id = 0
		_name_label.text = "Invite To Game..."
		_apply_interactivity()
		return

	_silhouette.visible = true
	_silhouette.texture = Assets.ship_texture(state.ship_style_id, "Silhouette")
	_silhouette.modulate = state.color()
	_ready_ring.visible = true
	_checkmark.visible = state.is_ready
	_is_empty = false
	_peer_id = state.peer_id
	_apply_interactivity()
	_name_label.modulate = Color.WHITE
	_name_label.text = state.display_label() + (" (You)" if state.is_local_player else "")
	_apply_mic(NetManager.chat_indicator_for(state.peer_id))


## Declares whether an empty slot in this roster can send an invite. The lobby decides;
## the row only reflects it.
func set_invitable(invitable: bool) -> void:
	if _invitable == invitable:
		return
	_invitable = invitable
	if is_node_ready():
		_apply_interactivity()


## Declares whether activating this row opens the player actions overlay, whether the
## player is muted now, and whether the platform is the one silencing them. The lobby
## resolves all three from NetManager, which owns the platform verdicts.
func set_actions_context(actionable: bool, muted: bool, restricted: bool = false) -> void:
	if _actionable == actionable and _muted == muted and _restricted == restricted:
		return
	_actionable = actionable
	_muted = muted
	_restricted = restricted
	if is_node_ready():
		_apply_interactivity()


## An invitable empty slot and an actionable occupied one both become focusable and draw
## at full strength so they read as actions. Everything else shows the dimmed, inert
## placeholder — but a player the platform silenced still says so, because an
## unexplained permanent mute reads as a bug.
func _apply_interactivity() -> void:
	var active := (_is_empty and _invitable) or (not _is_empty and _actionable)
	focus_mode = Control.FOCUS_ALL if active else Control.FOCUS_NONE
	mouse_filter = Control.MOUSE_FILTER_STOP if active else Control.MOUSE_FILTER_IGNORE
	if _is_empty:
		_name_label.modulate = Color(1.0, 1.0, 1.0, 1.0 if active else 0.5)
		tooltip_text = "Invite a player" if active else ""
	elif active:
		tooltip_text = "Player options"
	elif _restricted:
		tooltip_text = "Muted by your Xbox privacy settings"
	else:
		tooltip_text = ""


func _gui_input(event: InputEvent) -> void:
	var invitable := _is_empty and _invitable
	var actionable := not _is_empty and _actionable
	if not invitable and not actionable:
		return
	# Space is both the stock ui_accept key and NetRumble's lobby Ready shortcut.
	# Let the screen see that event; rows still activate on Enter, gamepad A, or mouse.
	var activated := event.is_action_pressed("ui_accept") \
			and not event.is_action_pressed("toggle_ready")
	if not activated and event is InputEventMouseButton:
		var button := event as InputEventMouseButton
		activated = button.pressed and button.button_index == MOUSE_BUTTON_LEFT
	if not activated:
		return
	accept_event()
	if invitable:
		invite_requested.emit()
	else:
		actions_requested.emit(_peer_id)


func _apply_mic(indicator: int) -> void:
	match indicator:
		ChatService.ChatIndicator.AVAILABLE:
			_mic.visible = true
			_mic.texture = Assets.texture("Microphone_Available")
			_mic.modulate = _NEUTRAL
		ChatService.ChatIndicator.TALKING:
			_mic.visible = true
			_mic.texture = Assets.texture("Microphone_Talking")
			_mic.modulate = _NEUTRAL
		ChatService.ChatIndicator.MUTED:
			_mic.visible = true
			_mic.texture = Assets.texture("Microphone_Muted")
			_mic.modulate = _MUTED_TINT
		_:
			_mic.visible = false
