class_name ChatService
extends RefCounted

## Voice and text chat over PlayFab Party, and the communication policy that governs it.
##
## Party carries chat on its own channel rather than the game's RPCs: once a chat control
## exists for a local user, voice reaches every other control in the mesh without the title
## routing a single packet. Typed messages travel the same path.
##
## The lesson here is that "who may talk to whom" has two independent authors and they must
## never be allowed to fight:
##
## - **The platform** decides what the account is permitted to do. The communications
##   privilege (XR-045) decides whether this account may chat at all, and per-player privacy
##   verdicts (XR-015) decide who it may hear and read. Neither is negotiable from inside
##   the title.
## - **The player** decides who they want to hear. That is an ordinary mute, and it must not
##   be able to lift a restriction the platform imposed — nor be silently undone when one is
##   lifted.
##
## Those are tracked separately for exactly that reason ([member _player_muted_ids] against
## [member _restricted_voice] / [member _restricted_text]) and combined in one place,
## [method _apply_peer_policy], which is the only writer of Party's three levers: the
## render-side audio mute, the render-side text mute, and the chat-control permissions that
## decide whether the local microphone reaches a player at all.
##
## Denied chat is *absent* rather than muted. Without the privilege no chat control is
## created and the Party network is built with both chat flags off, so there is no mesh to
## leak through if something else here is wrong.
##
## PartyService calls [method ensure_control] as part of hosting or joining, but it does
## not destroy the control when it leaves. A chat control is per-user, not per-match, and
## this title has one user for its whole lifetime — the platform terminates it when that
## account signs out — so the control is retained across matches and reused by the next
## one. Rebuilding it each time cost two native round trips for something that had not
## changed, and the destroy half of that sat inside PartyService.leave(), where a call
## that never returned left every later join waiting on the leave it opens with. It is
## destroyed instead when the chat privilege is withdrawn (XR-045) or when the title
## exits. Everything else on this class is driven by NetManager, which owns the roster the
## privacy verdicts are resolved against.

## Raised whenever the voice-chat mesh changes, so the lobby roster can repaint its
## microphone indicators without polling.
signal chat_changed()
signal text_received(entity_key: Dictionary, text: String)
signal text_policy_changed()
signal _control_operation_finished()

const MAX_MESSAGE_LENGTH := 100

## Chat indicator states, in the order the roster's microphone textures are indexed by.
enum ChatIndicator {
	NONE,      ## No chat control for this player; the icon is hidden.
	AVAILABLE, ## Voice is up and unmuted.
	MUTED,     ## Incoming audio muted locally, or the local mic is muted.
	TALKING,   ## Currently speaking. Unreachable: see chat_indicator_for().
}

## The local user's chat control, created explicitly before any network join because
## PlayFabPartyChat never creates one implicitly.
var _chat_user: Variant = null
## Entity ids Party currently reports as audio-muted for the local player. Mirrors the
## service's own state through audio_muted_changed rather than being written directly.
var _muted_ids: Dictionary = {}
## Entity ids the player muted deliberately, as opposed to a platform-forced mute. Kept
## apart from _muted_ids (which mirrors Party's own state) so unmuting a player cannot
## lift a restriction the platform imposed.
var _player_muted_ids: Dictionary = {}
## Entity ids the platform will not let the local player hear or read (XR-015). Set by
## NetManager from the privacy verdicts; not toggleable from inside the title.
var _restricted_voice: Dictionary = {}
var _restricted_text: Dictionary = {}
var _text_evaluated: Dictionary = {}
var _control_generation := 0
var _control_operation_pending := false
var _text_policy_generation := 0
var last_text_error := ""
## Whether this account may use voice and text chat at all (XR-045). Set before host or
## join; false builds the network with both chat flags off and never creates a chat
## control, so there is no mesh rather than a silenced seat in one.
var _chat_allowed: bool = true
## Whether the local microphone is held silent. Voice starts muted: enabling Party
## voice must not open a live mic the moment a lobby opens.
var _self_muted: bool = true


# --- Communication policy ---------------------------------------------------

## Declares whether this account may chat at all (XR-045). NetManager resolves the
## communications privilege and calls this before host() or join(); the answer decides
## whether PartyService's network config turns the chat flags on and whether a local chat
## control is created. Denied chat is absent rather than muted: there is no mesh to be
## admitted to, so nothing can leak through a mistake elsewhere.
func set_chat_allowed(allowed: bool) -> void:
	if _chat_allowed == allowed:
		return
	_chat_allowed = allowed
	invalidate_text_policy()


func is_chat_allowed() -> bool:
	return _chat_allowed


func has_control() -> bool:
	return _chat_user != null


func can_exchange_text(entity_key: Dictionary) -> bool:
	var entity_id := String(entity_key.get("id", ""))
	return _chat_allowed and _text_evaluated.has(entity_id) and not _restricted_text.has(entity_id)


## Unknown text relationships stay closed until the current account's verdict arrives.
func invalidate_text_policy() -> void:
	_text_policy_generation += 1
	_text_evaluated.clear()
	text_policy_changed.emit()


func retain_text_peers(entity_keys: Array[Dictionary]) -> void:
	var present: Dictionary = {}
	for entity_key in entity_keys:
		present[String(entity_key.get("id", ""))] = true
	var changed := false
	for entity_id in _text_evaluated.keys():
		if not present.has(entity_id):
			_text_evaluated.erase(entity_id)
			changed = true
	if changed:
		_text_policy_generation += 1
		text_policy_changed.emit()


## Synchronous: called before any asynchronous session or account teardown.
func invalidate_session() -> void:
	_control_generation += 1
	invalidate_text_policy()


static func valid_text(text: String) -> bool:
	return not text.strip_edges().is_empty() and text.length() <= MAX_MESSAGE_LENGTH


## Applies a platform privacy verdict for one player (XR-015). `allow_voice` false mutes
## their audio and `allow_text` false excludes them from typed messages this account sends.
## Called by NetManager whenever the roster changes; the player's own mute choice is
## tracked separately, so lifting a restriction does not unmute someone they muted.
func set_peer_restrictions(entity_key: Dictionary, allow_voice: bool, allow_text: bool) -> void:
	var entity_id := String(entity_key.get("id", ""))
	if entity_id.is_empty():
		return
	var changed := not _text_evaluated.has(entity_id)
	_text_evaluated[entity_id] = true
	if allow_voice:
		changed = _restricted_voice.erase(entity_id) or changed
	elif not _restricted_voice.has(entity_id):
		_restricted_voice[entity_id] = true
		changed = true
	if allow_text:
		changed = _restricted_text.erase(entity_id) or changed
	elif not _restricted_text.has(entity_id):
		_restricted_text[entity_id] = true
		changed = true
	if changed:
		_text_policy_generation += 1
		text_policy_changed.emit()
		await _apply_peer_policy(entity_key)
		chat_changed.emit()


## True when the platform, rather than the player, is silencing this entity's voice. The
## mute control keys off this: a text-only restriction leaves a player audible, and an
## audible player must stay mutable.
func is_peer_voice_restricted(entity_key: Dictionary) -> bool:
	var entity_id := String(entity_key.get("id", ""))
	return not entity_id.is_empty() and _restricted_voice.has(entity_id)


## True when the player muted this entity themselves.
func is_peer_muted(entity_key: Dictionary) -> bool:
	var entity_id := String(entity_key.get("id", ""))
	return not entity_id.is_empty() and _player_muted_ids.has(entity_id)


## Forgets every restriction and player mute. Called on teardown so verdicts from a
## previous session cannot follow the player into the next one.
func clear_chat_restrictions() -> void:
	_player_muted_ids.clear()
	_restricted_voice.clear()
	_restricted_text.clear()
	invalidate_text_policy()


## The lobby is voice-only: microphone indicators on the roster and nothing else. Text
## chat stays off there, so the lobby needs no chat panel.
##
## Party's own "is talking" signal (PartyChatControl::GetChatIndicator) has no binding
## in godot_playfab, so TALKING is unreachable here; AVAILABLE and MUTED are driven
## from real state rather than approximated.
func chat_indicator_for(entity_key: Dictionary) -> ChatIndicator:
	var chat: Variant = _chat()
	if chat == null or entity_key.is_empty() or not _chat_allowed:
		return ChatIndicator.NONE
	var entity_id: String = String(entity_key.get("id", ""))
	if entity_id.is_empty():
		return ChatIndicator.NONE

	var local: Variant = _local_chat_control()
	if local != null and _chat_user != null:
		var local_key: Dictionary = _local_entity_key()
		if _entity_keys_match(local_key, entity_key):
			return ChatIndicator.MUTED if _self_muted else ChatIndicator.AVAILABLE

	var control: Variant = chat.get_chat_control(entity_key)
	if control == null:
		return ChatIndicator.NONE
	if _muted_ids.has(entity_id) or _restricted_voice.has(entity_id):
		return ChatIndicator.MUTED
	return ChatIndicator.AVAILABLE


func is_self_muted() -> bool:
	return _self_muted


## Holds the local microphone silent. Party has no single "mute my own input" call, so
## this drops the local SEND_AUDIO permission for every remote control in the mesh.
func set_self_muted(muted: bool) -> void:
	# With chat denied there is no chat control, so unmuting would silently do nothing.
	if not _chat_allowed and not muted:
		return
	if _self_muted == muted:
		return
	_self_muted = muted
	await _apply_self_mute()
	chat_changed.emit()


func toggle_self_muted() -> void:
	await set_self_muted(not _self_muted)


## Mutes incoming voice from one player. This is the player's own choice; a
## platform-forced mute goes through set_peer_restrictions() and survives an unmute.
func set_peer_muted(entity_key: Dictionary, muted: bool) -> void:
	var entity_id := String(entity_key.get("id", ""))
	if entity_id.is_empty():
		return
	if muted:
		_player_muted_ids[entity_id] = true
	else:
		_player_muted_ids.erase(entity_id)
	await _apply_peer_policy(entity_key)


## Pushes the combined verdict for one player — what the player chose, plus what the
## platform forces — to Party. One funnel so the two sources can never fight, and so
## every one of Party's three levers moves together: the render-side audio mute, the
## render-side text mute, and the chat-control permissions that decide whether the local
## microphone reaches them at all.
func _apply_peer_policy(entity_key: Dictionary) -> void:
	var chat: Variant = _chat()
	if chat == null or entity_key.is_empty() or _local_chat_control() == null:
		return
	var entity_id := String(entity_key.get("id", ""))
	var generation := _control_generation
	var policy_generation := _text_policy_generation
	var muted := _player_muted_ids.has(entity_id) or _restricted_voice.has(entity_id)
	var result: Variant = await chat.set_audio_muted_async(entity_key, muted)
	if generation != _control_generation or policy_generation != _text_policy_generation:
		return
	if result != null and not result.ok:
		push_warning("[Party] Could not change mute state: %s" % _reason(result))
	result = await chat.set_text_muted_async(entity_key, not can_exchange_text(entity_key))
	if generation != _control_generation or policy_generation != _text_policy_generation:
		return
	if result != null and not result.ok:
		push_warning("[Party] Could not change text mute state: %s" % _reason(result))
	await _apply_peer_permissions(entity_key)


## Voice and typed text have independent relationship permissions (XR-015).
## ReceiveText never depends on whether the local microphone is muted.
func _apply_peer_permissions(entity_key: Dictionary) -> void:
	var chat: Variant = _chat()
	if chat == null or _chat_user == null:
		return
	var permissions := 0
	if _chat_allowed and not _restricted_voice.has(String(entity_key.get("id", ""))):
		permissions = _chat_permission(&"CHAT_PERMISSION_RECEIVE_AUDIO")
		if not _self_muted:
			permissions |= _chat_permission(&"CHAT_PERMISSION_SEND_AUDIO")
	if can_exchange_text(entity_key):
		permissions |= _chat_permission(&"CHAT_PERMISSION_RECEIVE_TEXT")
	var result: Variant = await chat.set_chat_permissions_async(entity_key, permissions)
	if result != null and not result.ok:
		push_warning("[Party] Could not set chat permissions: %s" % _reason(result))


## Sends typed text to the currently eligible remote controls over Party's chat path.
##
## Party has no send-side text permission *by design* — PartyChatPermissionOptions covers
## send/receive audio and ReceiveText only. Party.h is explicit that each SendText() call
## takes an explicit target list, and "including or omitting a target is equivalent to
## granting or denying send permission for that text message". So a player this account
## may not write to is excluded by *addressing* rather than by permission, which is the
## sanctioned mechanism and not a workaround (XR-015).
func send_chat_text(message: String) -> bool:
	last_text_error = ""
	if not valid_text(message):
		return _text_failure("Messages must contain between 1 and %d characters." % MAX_MESSAGE_LENGTH)
	var chat: Variant = _chat()
	if chat == null or _chat_user == null or not _chat_allowed:
		return _text_failure("Text chat is unavailable. Leave and rejoin the session to try again.")
	var targets: Array = []
	for entity_key: Dictionary in chat.get_remote_entity_keys():
		if can_exchange_text(entity_key):
			targets.append(entity_key)
	# The addon treats an empty array as broadcast, not as "nobody".
	if targets.is_empty():
		return _text_failure("No players are currently available for text chat.")
	var generation := _control_generation
	var policy_generation := _text_policy_generation
	var result: Variant = await chat.send_text_async(message, targets)
	if generation != _control_generation or policy_generation != _text_policy_generation:
		return _text_failure("The chat session or its permissions changed. Please try again.")
	if result == null or not result.ok:
		return _text_failure("Could not send the message: %s" % _reason(result))
	return true


func _text_failure(reason: String) -> bool:
	last_text_error = reason
	push_warning("[Party] %s" % reason)
	return false


# --- Chat control lifecycle -------------------------------------------------
#
# Driven by PartyService, because a chat control is only meaningful alongside a Party
# network: it is created as part of hosting or joining one and destroyed as part of
# leaving it.

## Creates the local chat control once per user. Idempotent in the addon, but the
## signal wiring must only happen once.
##
## [param still_current] reports whether the join that asked for this control is still the
## one in progress. PlayFab's async calls cannot be cancelled once handed to the addon, so
## a join the player has already abandoned can still land here — it is checked either side
## of the create, and a control that arrives too late is destroyed rather than kept. The
## token itself belongs to PartyService, which owns the join lifecycle.
func ensure_control(user: Variant, cfg: Variant, still_current: Callable = Callable()) -> void:
	var chat: Variant = _chat()
	if chat == null or user == null:
		return
	if not _still_current(still_current):
		return
	var generation := _control_generation
	# Neither creation nor destruction may reuse a user's control while another
	# native lifecycle operation still owns it.
	while _control_operation_pending:
		await _control_operation_finished
		if generation != _control_generation or not _still_current(still_current):
			return
	# No communications privilege, no chat control: the account is kept out of the mesh
	# rather than placed in it and silenced (XR-045).
	if not _chat_allowed:
		# A control retained from an earlier match must not survive a verdict that has
		# since turned against it.
		if _chat_user != null:
			await _destroy_control_now()
		return
	if _chat_user != null:
		# Retained from an earlier match. Reusing it is the point of keeping it: a chat
		# control is per-user, this title has exactly one user for its whole lifetime,
		# and nothing about the control changed when the previous session ended.
		return
	_control_operation_pending = true
	var result: Variant = await chat.create_local_chat_control_async(user, cfg)
	if generation != _control_generation or not _still_current(still_current):
		if result != null and result.ok:
			var destroyed: Variant = await chat.destroy_local_chat_control_async(user)
			if destroyed != null and not destroyed.ok:
				push_warning("[Party] Destroying a cancelled chat control failed: %s" % _reason(destroyed))
		_finish_control_operation()
		return
	if result == null or not result.ok:
		# Voice is a nicety; a failure here must not stop the match from starting.
		push_warning("[Party] Voice chat unavailable: %s" % _reason(result))
		_finish_control_operation()
		return
	_chat_user = user
	if not chat.chat_control_added.is_connected(_on_chat_control_added):
		chat.chat_control_added.connect(_on_chat_control_added)
	if not chat.chat_control_removed.is_connected(_on_chat_control_removed):
		chat.chat_control_removed.connect(_on_chat_control_removed)
	if not chat.audio_muted_changed.is_connected(_on_audio_muted_changed):
		chat.audio_muted_changed.connect(_on_audio_muted_changed)
	if not chat.text_message_received.is_connected(_on_text_message_received):
		chat.text_message_received.connect(_on_text_message_received)
	_finish_control_operation()


func _finish_control_operation() -> void:
	_control_operation_pending = false
	_control_operation_finished.emit()


func destroy_control() -> void:
	invalidate_session()
	while _control_operation_pending:
		await _control_operation_finished
	await _destroy_control_now()


## The teardown itself, without the session invalidation or the in-flight wait that
## [method destroy_control] does first.
##
## Split out for [method ensure_control], which has already passed the same gate and must
## not bump the control generation: it captured that generation before its own awaits, and
## dropping a retained control whose privilege has since been withdrawn must not read as
## the outside invalidation that guard is watching for.
func _destroy_control_now() -> void:
	var chat: Variant = _chat()
	var user: Variant = _chat_user
	_chat_user = null
	_muted_ids.clear()
	if chat == null:
		chat_changed.emit()
		return
	if chat.chat_control_added.is_connected(_on_chat_control_added):
		chat.chat_control_added.disconnect(_on_chat_control_added)
	if chat.chat_control_removed.is_connected(_on_chat_control_removed):
		chat.chat_control_removed.disconnect(_on_chat_control_removed)
	if chat.audio_muted_changed.is_connected(_on_audio_muted_changed):
		chat.audio_muted_changed.disconnect(_on_audio_muted_changed)
	if chat.text_message_received.is_connected(_on_text_message_received):
		chat.text_message_received.disconnect(_on_text_message_received)
	if user != null:
		_control_operation_pending = true
		var result: Variant = await chat.destroy_local_chat_control_async(user)
		if result != null and not result.ok:
			push_warning("[Party] Destroying the chat control failed: %s" % _reason(result))
		_finish_control_operation()
	chat_changed.emit()


# --- Party signal handlers --------------------------------------------------

func _on_text_message_received(entity_key: Dictionary, message: Variant) -> void:
	if _chat_user == null or not can_exchange_text(entity_key):
		return
	if not (message is Object) or not is_instance_valid(message):
		push_warning("[Party] Ignored an invalid text message.")
		return
	var text: Variant = message.get("text")
	if not (text is String) or not valid_text(text) or message.get("is_transcription") != false:
		push_warning("[Party] Ignored an invalid text message.")
		return
	text_received.emit(entity_key, text)


func _on_chat_control_added(entity_key: Dictionary, _control: Variant) -> void:
	await _apply_self_mute()
	# A verdict may already be on file for this player — they were evaluated when the
	# roster changed, which can happen before their chat control reaches the mesh.
	await _apply_peer_policy(entity_key)
	chat_changed.emit()


func _on_chat_control_removed(entity_key: Dictionary) -> void:
	var entity_id := String(entity_key.get("id", ""))
	_muted_ids.erase(entity_id)
	_player_muted_ids.erase(entity_id)
	_restricted_voice.erase(entity_id)
	_restricted_text.erase(entity_id)
	_text_evaluated.erase(entity_id)
	text_policy_changed.emit()
	chat_changed.emit()


func _on_audio_muted_changed(entity_key: Dictionary, muted: bool) -> void:
	var entity_id := String(entity_key.get("id", ""))
	if entity_id.is_empty():
		return
	if muted:
		_muted_ids[entity_id] = true
	else:
		_muted_ids.erase(entity_id)
	chat_changed.emit()


# --- Helpers ----------------------------------------------------------------

## Applies the current self-mute state to every remote control. Called whenever the
## mesh changes, so a player who joins while muted still cannot hear the local mic.
func _apply_self_mute() -> void:
	var chat: Variant = _chat()
	if chat == null or _chat_user == null:
		return
	for entity_key: Dictionary in chat.get_remote_entity_keys():
		await _apply_peer_permissions(entity_key)


## Use the addon's bound PlayFabParty.ChatPermission constants when the extension is
## loaded; fallbacks mirror the documented values so scripts still parse in
## editor-only environments that lack the native library.
func _chat_permission(name: StringName) -> int:
	if ClassDB.class_exists(&"PlayFabParty") and ClassDB.class_has_integer_constant(&"PlayFabParty", name):
		return ClassDB.class_get_integer_constant(&"PlayFabParty", name)
	match name:
		&"CHAT_PERMISSION_SEND_AUDIO":
			return 1
		&"CHAT_PERMISSION_RECEIVE_AUDIO":
			return 2
		&"CHAT_PERMISSION_RECEIVE_TEXT":
			return 4
		_:
			return 0


## An unset callable means "no join to be superseded" — the host path, which has no
## competing operation to check against.
func _still_current(still_current: Callable) -> bool:
	return not still_current.is_valid() or bool(still_current.call())


func _chat() -> Variant:
	var pf: Variant = PlatformAccess.playfab()
	if pf == null:
		return null
	return pf.party.chat


func _local_chat_control() -> Variant:
	var chat: Variant = _chat()
	if chat == null or _chat_user == null:
		return null
	return chat.get_local_chat_control(_chat_user)


## The local user's own PlayFab entity key. PlayFabUser exposes it directly, which
## is the identity Party's chat controls are keyed on.
func _local_entity_key() -> Dictionary:
	if _chat_user == null:
		return {}
	var key: Variant = _chat_user.entity_key
	return key if key is Dictionary else {}


func _entity_keys_match(left: Dictionary, right: Dictionary) -> bool:
	var left_id: String = String(left.get("id", ""))
	return not left_id.is_empty() \
			and left_id == String(right.get("id", "")) \
			and String(left.get("type", "")) == String(right.get("type", ""))


func _reason(result: Variant) -> String:
	return PlatformAccess.reason(result, "the PlayFab extension is unavailable")
