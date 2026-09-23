class_name PartyService
extends RefCounted

## PlayFab Party transport plus PlayFab Lobby discovery.
##
## Party provides the peer-to-peer transport; Lobby provides discovery. The two are
## separate PlayFab services and this file is where they are stitched together into a
## single join-code handshake:
##
##   host  : create Party network -> wait for its base64 descriptor -> create a
##           PlayFab lobby whose searchable string_key1 is the five-character join
##           code and whose member-visible properties carry the descriptor.
##   client: search lobbies for string_key1 == code -> join that lobby -> read the
##           descriptor back out -> join the same Party network.
##
## The lobby publishes the descriptor under a code a player can read aloud, and it stays
## live for the whole session after that: its membership lock is what closes a match to
## newcomers once it starts (see set_lobby_locked).
##
## The returned PlayFabPartyPeer inherits MultiplayerPeerExtension, so it drops
## straight into Godot's high-level MultiplayerAPI: every @rpc in NetManager keeps
## working untouched and Party becomes the wire underneath them.
##
## Addon SDK objects are held as Variant and reached through Engine.get_singleton /
## ClassDB.instantiate on purpose. The godot_playfab classes only exist once the
## native library loads, so naming them in type positions would break parsing on a
## machine without the extension.
##
## Voice and text chat are a separate lesson and live in chat_service.gd. This file
## still owns their lifetime — a chat control has to exist before the network join
## that connects it to the mesh, and is destroyed as part of leave() — but nothing
## else about chat is decided here.

signal peer_joined(peer_id: int)
signal peer_left(peer_id: int)
## The Party network is gone and is not coming back: it was destroyed underneath us, or
## it reported DISCONNECTED or FAILED. Carries a reason fit to show the player.
##
## Only raised for a loss this instance did not ask for. `leave()` detaches the state
## handler before it tears the network down, so a deliberate exit is silent and callers
## can treat this as "the session ended badly" with no further filtering.
signal network_lost(reason: String)
## The low-level twin of `network_lost`, raised only for an actual DESTROYED change.
## Subscribe to `network_lost` instead unless you specifically need to distinguish a
## destroyed network from one that reported DISCONNECTED or FAILED; both mean the
## session is over, and handling both here would end it twice.
signal network_destroyed()
## A Party operation or state-change batch failed. **Not terminal** — the network may
## still be usable — so this reports the failure without ending the session.
signal party_failed(message: String)
signal cleanup_status_changed(message: String)

## Lobby property the host publishes the Party descriptor under. Matches the key used
## by the addon's own Party tutorial so the two interoperate.
const DESCRIPTOR_KEY := "party_descriptor"
## PlayFab only indexes its reserved search keys; the join code has to live in one.
## string_key3 is taken too, by the protocol version -- see NRProtocol.LOBBY_KEY.
const JOIN_CODE_KEY := "string_key1"
const GAME_MODE_KEY := "string_key2"

## The descriptor is finalized asynchronously after the network is created, and lobby
## properties replicate on their own schedule. Both are polled rather than raced.
const DESCRIPTOR_TIMEOUT := 20.0
const LOBBY_PROPERTY_TIMEOUT := 20.0
const POLL_INTERVAL := 0.1

## PlayFabLobby membership-lock values. Declared here for the same reason the Party
## network-change kinds below are: this file only ever reaches PlayFabLobby through a
## Variant, so the addon's own constants are not visible to the parser.
const MEMBERSHIP_LOCK_UNLOCKED := 0
const MEMBERSHIP_LOCK_LOCKED := 1

## How long a membership-lock update is waited on before the title stops waiting on it.
## A lock is on the path between pressing ready and the match starting, so it cannot be
## allowed to hang the lobby indefinitely.
const LOBBY_LOCK_TIMEOUT := 15.0

## Membership-lock failures the caller can show. The SDK's own message is a developer
## diagnostic (see _reason), so it is logged rather than displayed.
const LOCK_FAILED_NO_LOBBY := "This match is no longer advertised to other players."
const LOCK_FAILED_NOT_HOST := "Only the host can open or close a match to new players."
const LOCK_FAILED_UNSUPPORTED := "The installed PlayFab addon cannot lock a lobby. Rebuild addons/ from the pinned submodule."
const LOCK_FAILED_TIMEOUT := "The match service did not confirm the change in time."
const LOCK_FAILED_BUSY := "An earlier change to this match has not finished yet."
const LOCK_FAILED_SUPERSEDED := "The match changed while it was being updated."
const LOCK_FAILED_SERVICE := "The match service refused to update this match."

## Five characters. Ambiguous glyphs (I, O, 0, 1) are excluded so codes can be read
## aloud over voice chat without being misheard.
const JOIN_CODE_LENGTH := 5
const JOIN_CODE_ALPHABET := "ABCDEFGHJKLMNPQRSTUVWXYZ23456789"

## Party network-change kinds, as reported on the `kind` member of a network-state
## change. These are addon-free fallbacks only; loaded contracts use ClassDB below.
const NETWORK_CHANGE_STATE := 1
const NETWORK_CHANGE_PEER_JOINED := 2
const NETWORK_CHANGE_PEER_LEFT := 3
const NETWORK_CHANGE_DESCRIPTOR_UPDATED := 4
const NETWORK_CHANGE_DESTROYED := 5
const NETWORK_CHANGE_ERROR := 6
const NETWORK_CHANGES := {
	&"NETWORK_CHANGE_STATE": NETWORK_CHANGE_STATE,
	&"NETWORK_CHANGE_PEER_JOINED": NETWORK_CHANGE_PEER_JOINED,
	&"NETWORK_CHANGE_PEER_LEFT": NETWORK_CHANGE_PEER_LEFT,
	&"NETWORK_CHANGE_DESCRIPTOR_UPDATED": NETWORK_CHANGE_DESCRIPTOR_UPDATED,
	&"NETWORK_CHANGE_DESTROYED": NETWORK_CHANGE_DESTROYED,
	&"NETWORK_CHANGE_ERROR": NETWORK_CHANGE_ERROR,
}
const RECOVERY_FAILED := "Multiplayer cleanup could not complete safely. Online play is unavailable. Restart the game before trying again."

## Party network states. Only these two are terminal; the rest of the sequence
## (CREATING, CONNECTING, AUTHENTICATING, CONNECTED) is the ordinary path to a live
## network and needs no handling. DISCONNECTING is deliberately absent — see
## _handle_network_state().
const NETWORK_STATE_DISCONNECTED := 5
const NETWORK_STATE_FAILED := 6

## Local UDP bind ports. Party binds a socket at initialization; 0 asks the OS for an
## ephemeral port, -1 keeps the platform's own preferred multiplayer port.
const UDP_PORT_EPHEMERAL := 0
const UDP_PORT_PLATFORM_DEFAULT := -1

## Why a join failed, in the player's terms. These are the title's own strings, chosen
## by HRESULT below, and they are the only thing a failed join is allowed to put on
## screen.
##
## The SDK also returns a message, and it is tempting to forward it: it is specific, it
## is already written, and it is right there on the result. It is also documented as
## unsuitable for this. "These error messages are intended to only be looked at by
## developers. They are not localized or intended for consumption by end users, so are
## best suited for internal development logs" -- Handling Lobby and Matchmaking SDK
## errors, PlayFab Multiplayer documentation. Forwarding it put a bare `0x89235400` in
## front of a player during the 2026-09-02 bug bash, and made the difference between
## "full" and "not joinable" depend on wording this title does not own.
const JOIN_FAILED_ENDED := "That match has already ended."
const JOIN_FAILED_NOT_JOINABLE := "That match is no longer accepting players."
const JOIN_FAILED_ALREADY_IN := "You are already in that match."
const JOIN_FAILED_ALREADY_ELSEWHERE := "You are already in another match. Leave it before joining this one."
const JOIN_FAILED_BANNED := "You cannot rejoin that match."
const JOIN_FAILED_NOT_ALLOWED := "You do not have permission to join that match."
const JOIN_FAILED_SIGNED_OUT := "Your sign-in expired. Sign in again, then try to join."
const JOIN_FAILED_BUSY := "Too many attempts. Wait a moment, then try again."
const JOIN_FAILED_SERVICE := "The match service is unavailable. Try again in a moment."
## Nothing above matched. Says what happened and no more, because the title genuinely
## does not know which of the causes it was.
const JOIN_FAILED_UNKNOWN := "That match could not be joined."
## Decided from the member counts on the lobby search result, before any join is
## attempted, rather than from an HRESULT. PlayFab documents no "lobby full" error, so
## waiting for the join to fail would put whichever generic refusal the service happened
## to send in front of the player instead. See join().
const JOIN_FAILED_FULL := "That match is full."
## The join-code search itself failed and no HRESULT in the table explained why. Kept
## apart from "No match found", which means the search worked and nothing matched.
const JOIN_FAILED_SEARCH := "Could not look up that join code. Try again in a moment."
## Party or Lobby could not initialize on this device. The SDK's reason goes to the log,
## for the same reason as above.
const MULTIPLAYER_START_FAILED := "Online multiplayer could not start. Try again in a moment."

## HRESULT to message. godot_playfab binds no named constants for these, so they are
## declared here from the PlayFab Multiplayer error reference rather than left as bare
## integers at the match site -- the same treatment the network-change kinds above get.
## Values are the unsigned 32-bit form; _join_failure() normalizes before looking up,
## because the addon may hand back either sign.
const JOIN_FAILURE_MESSAGES := {
	0x89236226: JOIN_FAILED_ENDED,             # The requested lobby doesn't exist.
	0x89236227: JOIN_FAILED_NOT_JOINABLE,      # The requested lobby wasn't in a joinable state.
	0x89236225: JOIN_FAILED_ALREADY_IN,        # The requested user was already a member of the lobby.
	0x89236233: JOIN_FAILED_ALREADY_ELSEWHERE, # Already in the maximum number of allowed lobbies.
	0x89236232: JOIN_FAILED_BANNED,            # The member has been banned from the lobby.
	0x8923620E: JOIN_FAILED_NOT_ALLOWED,       # The user isn't authorized to execute the operation.
	0x8923621A: JOIN_FAILED_SIGNED_OUT,        # The entity wasn't locally authenticated.
	0x8923620D: JOIN_FAILED_SIGNED_OUT,        # The provided entity token has expired.
	0x89236216: JOIN_FAILED_BUSY,              # A Lobby request rate limit was exceeded.
	0x8923640D: JOIN_FAILED_BUSY,              # A request rate limit was exceeded.
	0x8923620C: JOIN_FAILED_SERVICE,           # The PlayFab service returned an unexpected error.
	0x89236212: JOIN_FAILED_SERVICE,           # The PlayFab Service returned an unknown error.
	0x89236409: JOIN_FAILED_SERVICE,           # Unexpected error with a 4XX status code.
	0x8923640A: JOIN_FAILED_SERVICE,           # Unexpected error with a 5XX status code.
}

var join_code: String = ""

var _network: Variant = null
var _lobby: Variant = null
var _peer: Variant = null
var _is_host: bool = false
var _party_initialized: bool = false
var _multiplayer_initialized: bool = false

## Bumped whenever a join is superseded or abandoned. The PlayFab async calls cannot be
## cancelled once handed to the addon, so every await boundary checks this before it
## attaches a lobby/network that the player has already timed out or backed away from.
var _join_operation_token := 0
var _operation_account_generation := -1
var _operation_deadline_msec := 0

## Voice and text chat, which live alongside a Party network rather than inside it: see
## chat_service.gd. Held here because this service owns the network's lifetime, so it is
## the only place that knows when a chat control may exist. Everything a player or the UI
## does with chat goes through Services.chat() instead.
var _chat: ChatService
var _leaving := false
signal _leave_completed()
var recovery_error := ""
var cleanup_status := ""
var _network_changes: Dictionary = {}
var _contract_error := ""
var _native_epoch := 0
var _native_sequence := 0
var _pending_native: Dictionary = {}
var _cleanup_failed := false
var _recovering := false

## Membership-lock serialization. An SDK update cannot be recalled once posted, so a
## second lock request waits for the first to settle rather than posting an opposite
## update the service is free to apply in either order. `_lock_operation` retires the
## coroutine of an abandoned or superseded update so its late result cannot be read as
## the answer to a newer one.
var _lock_running := false
var _lock_operation := 0
var _lock_result: Dictionary = {}


func _init(chat: ChatService) -> void:
	_chat = chat
	_load_network_contract()


func _bound_network_constant(name: StringName) -> int:
	if not ClassDB.class_exists(&"PlayFabParty"):
		return int(NETWORK_CHANGES[name])
	if ClassDB.class_has_integer_constant(&"PlayFabParty", name):
		return ClassDB.class_get_integer_constant(&"PlayFabParty", name)
	return -1


func _load_network_contract() -> void:
	_network_changes.clear()
	_contract_error = ""
	for name: StringName in NETWORK_CHANGES:
		var value := _bound_network_constant(name)
		if value < 1 or _network_changes.values().has(value):
			_contract_error = "The installed PlayFab addon has an incompatible network event contract. Rebuild addons/ from the pinned submodule."
			push_warning("[Party] " + _contract_error)
			return
		_network_changes[name] = value


func is_cleanup_pending() -> bool:
	return _leaving or _recovering or not recovery_error.is_empty()


func _now_msec() -> int:
	return Time.get_ticks_msec()


## Track calls before dispatch, including operations which have not exposed a resource.
## Retiring an epoch fences continuations, not the native SDK's ownership.
func _native_call(target: Variant, method: StringName, args: Array = []) -> Variant:
	if _recovering or not recovery_error.is_empty():
		return null
	_native_sequence += 1
	var ticket := _native_sequence
	var epoch := _native_epoch
	_pending_native[ticket] = true
	var result: Variant = await target.callv(method, args)
	_pending_native.erase(ticket)
	return result if epoch == _native_epoch else null


## True when the godot_playfab extension is present. Everything else assumes this.
func is_available() -> bool:
	return _playfab() != null


func has_network() -> bool:
	return _network != null


func peer() -> Variant:
	return _peer


func cancel_pending_join() -> void:
	_join_operation_token += 1


## The joined lobby's connection string, or empty when there is no lobby. This is the
## value an invitee needs for an explicit join, so it is what the Xbox multiplayer
## activity advertises: handing it out skips _find_lobby() entirely, which is the
## slowest and least reliable part of joining.
func lobby_connection_string() -> String:
	if _lobby == null:
		return ""
	return String(_lobby.connection_string)


## PlayFab entity key for a Party peer, as a {"id", "type"} dictionary. The entity id is
## PlayFab's own authenticated identity for the player, so it is what the roster uses to
## tell two players apart even when they share a local profile. Unlike a XUID carried in
## an RPC payload, it comes from Party's authenticated local user and cannot be spoofed
## by a modified client.
func entity_key_for(peer_id: int) -> Dictionary:
	if _peer == null:
		return {}
	return _peer.get_peer_entity_key(peer_id)


# --- Membership lock --------------------------------------------------------

## True when this instance owns the lobby and can therefore change its membership lock.
func is_lobby_owner() -> bool:
	return _is_host and _lobby != null


## Opens or closes the lobby to new members. Returns {"ok": bool, "error": String}.
##
## Locking membership is what stops a match being joined once it has started. The host's
## own gate turns away a peer that reaches it, but by then the joiner has already found
## the lobby, joined it, and built a Party connection -- work that ends in a refusal and
## a confusing wait. The lock refuses the join at the service, before any of that: a
## locked lobby is still searchable by code and still holds its existing members, it just
## will not take new ones. That is exactly the shape this needs, which is why the lobby is
## locked rather than deleted and rebuilt. Deleting it would invalidate the join code, the
## connection string every published activity and sent invite carries, and the descriptor
## the running match is reachable through.
##
## Owner-only, like the descriptor republish in leave(): a guest calling this would get a
## service error, so it is refused locally with something the player can read.
##
## The wait is bounded, and a timeout is not a cancellation -- the update may still land.
## The result says only whether the change was confirmed; an unconfirmed one leaves the
## caller to fail closed and offer a retry rather than assume either outcome.
func set_lobby_locked(locked: bool) -> Dictionary:
	if _lock_running:
		var settled := await _await_lock_settled()
		if not settled:
			return {"ok": false, "error": LOCK_FAILED_BUSY}
	if _leaving or _lobby == null:
		return {"ok": false, "error": LOCK_FAILED_NO_LOBBY}
	if not _is_host:
		return {"ok": false, "error": LOCK_FAILED_NOT_HOST}
	# The pinned submodule predating microsoft/XBOX-Godot-Sample#179 has no lock API, and
	# an addons/ tree built from it would otherwise fail with an unrelated script error.
	if not _lobby.has_method("set_membership_lock_async"):
		return {"ok": false, "error": LOCK_FAILED_UNSUPPORTED}
	if _lobby.is_disconnected():
		return {"ok": false, "error": LOCK_FAILED_NO_LOBBY}

	var lobby: Variant = _lobby
	_lock_operation += 1
	var operation := _lock_operation
	_lock_running = true
	_lock_result = {}
	_post_membership_lock(lobby, MEMBERSHIP_LOCK_LOCKED if locked else MEMBERSHIP_LOCK_UNLOCKED, operation)

	var waited := 0.0
	while _lock_running and _lock_operation == operation and waited < LOBBY_LOCK_TIMEOUT:
		await _sleep(POLL_INTERVAL)
		waited += POLL_INTERVAL
	if _lock_operation != operation or lobby != _lobby:
		return {"ok": false, "error": LOCK_FAILED_SUPERSEDED}
	if _lock_running:
		return {"ok": false, "error": LOCK_FAILED_TIMEOUT}
	return _lock_result.duplicate()


func _post_membership_lock(lobby: Variant, membership_lock: int, operation: int) -> void:
	var result: Variant = await _native_call(lobby, &"set_membership_lock_async", [membership_lock])
	# The lobby this answers for may have been left, or a later update may already own the
	# outcome. Either way this result is no longer anybody's answer.
	if operation != _lock_operation:
		return
	if result != null and result.ok:
		_lock_result = {"ok": true, "error": ""}
	else:
		push_warning("[Party] Updating the lobby membership lock failed: %s" % _reason(result))
		_lock_result = {"ok": false, "error": LOCK_FAILED_SERVICE}
	_lock_running = false


## Waits for an in-flight membership update to settle. Returns false when it has not,
## which keeps a retry from posting the opposite update while the first is still out.
func _await_lock_settled() -> bool:
	var waited := 0.0
	while _lock_running and waited < LOBBY_LOCK_TIMEOUT:
		await _sleep(POLL_INTERVAL)
		waited += POLL_INTERVAL
	return not _lock_running


# --- Host -------------------------------------------------------------------

## Creates the Party network and advertises it on a lobby. Returns
## {"ok": bool, "peer": Variant, "code": String, "error": String}.
func host(user: Variant, max_players: int, game_mode: String, deadline_msec: int = 0) -> Dictionary:
	if not _user_is_ready(user):
		return _fail("Sign in and load your saved data before hosting.")
	if is_cleanup_pending():
		return _fail(recovery_error if not recovery_error.is_empty() else "The previous match is still being cleaned up.")
	var operation := _begin_join_operation(deadline_msec)
	await leave(false)
	var ready_error := await _ensure_initialized(operation)
	if not _is_join_operation_current(operation):
		return _fail("Host cancelled.")
	if not ready_error.is_empty():
		return _fail(ready_error)
	if user == null:
		return _fail("You must be signed in to host a match.")

	# The join code is minted before the network because it doubles as Party's
	# invitation identifier, which has to be fixed at creation time.
	join_code = _generate_join_code()

	var cfg: Variant = _make_party_config(max_players, join_code)
	var pf: Variant = _playfab()
	# The chat control has to exist before the network join, which is what connects it
	# to the mesh. Creating it afterwards leaves the local player mute to everyone.
	await _chat.ensure_control(user, cfg, func() -> bool: return _is_join_operation_current(operation))
	if not _is_join_operation_current(operation):
		return _fail("Host cancelled.")
	var created: Variant = await _native_call(pf.party, &"create_and_join_network_async", [user, cfg])
	if not _is_join_operation_current(operation):
		if created != null and created.ok:
			await _leave_network_instance(created.data)
		return _fail("Host cancelled.")
	if created == null or not created.ok:
		join_code = ""
		return _fail("Could not create the Party network: %s" % _reason(created))

	_attach_network(created.data, true)
	if not _network_is_usable():
		return _fail("PlayFab Party did not return a usable network peer.")

	var descriptor: String = await _await_descriptor(operation)
	if not _is_join_operation_current(operation):
		return _fail("Host cancelled.")
	if descriptor.is_empty():
		leave()
		return _fail("The Party network never published a connection descriptor.")

	var lobby_error := await _create_lobby(user, descriptor, max_players, game_mode, operation)
	if not _is_join_operation_current(operation):
		return _fail("Host cancelled.")
	if not lobby_error.is_empty():
		leave()
		return _fail(lobby_error)
	if not _network_is_usable():
		return _fail("The match connection ended before it could be advertised.")

	return {"ok": true, "peer": _peer, "code": join_code, "error": ""}


# --- Join -------------------------------------------------------------------

## Resolves a five-character join code to a lobby, reads the Party descriptor out of
## it and joins that network. Returns {"ok", "peer", "code", "error"}.
func join(user: Variant, code: String, deadline_msec: int = 0) -> Dictionary:
	if not _user_is_ready(user):
		return _fail("Sign in and load your saved data before joining.")
	if is_cleanup_pending():
		return _fail(recovery_error if not recovery_error.is_empty() else "The previous match is still being cleaned up.")
	var operation := _begin_join_operation(deadline_msec)
	await leave(false)
	var ready_error := await _ensure_initialized(operation)
	if not _is_join_operation_current(operation):
		return _fail("Join cancelled.")
	if not ready_error.is_empty():
		return _fail(ready_error)
	if user == null:
		return _fail("You must be signed in to join a match.")

	var normalized := _normalize_join_code(code)
	if normalized.length() != JOIN_CODE_LENGTH:
		return _fail("Join codes are %d characters long." % JOIN_CODE_LENGTH)

	var lookup := await _find_lobby(user, normalized, operation)
	if not _is_join_operation_current(operation):
		return _fail("Join cancelled.")
	var search_error := String(lookup.error)
	if not search_error.is_empty():
		return _fail(search_error)
	var connection_string := String(lookup.connection_string)
	if connection_string.is_empty():
		return _fail("No match found for code %s." % normalized)
	# The count is a snapshot of the search, not a reservation. A lobby reported full is
	# refused here without a join; one that fills after the search is still refused by
	# the service below, and gets whatever message that refusal maps to -- not this one.
	var members := int(lookup.member_count)
	var capacity := int(lookup.max_member_count)
	if _is_at_capacity(members, capacity):
		push_warning("[Party] Not joining %s: the lobby search reported it full (%d/%d)." % [
			normalized, members, capacity])
		return _fail(JOIN_FAILED_FULL)

	return await _join_lobby_by_connection_string(user, connection_string, normalized, operation)


## Joins straight from a lobby connection string, which is what an accepted Xbox invite
## or a platform join carries. Unlike join() there is no code to search for, so the
## five-character code is recovered from the lobby's search properties instead — it is
## needed for more than the UI, see _join_attached_lobby.
func join_by_connection_string(user: Variant, connection_string: String, deadline_msec: int = 0) -> Dictionary:
	if not _user_is_ready(user):
		return _fail("Sign in and load your saved data before joining.")
	if is_cleanup_pending():
		return _fail(recovery_error if not recovery_error.is_empty() else "The previous match is still being cleaned up.")
	var operation := _begin_join_operation(deadline_msec)
	await leave(false)
	var ready_error := await _ensure_initialized(operation)
	if not _is_join_operation_current(operation):
		return _fail("Join cancelled.")
	if not ready_error.is_empty():
		return _fail(ready_error)
	if user == null:
		return _fail("You must be signed in to join a match.")
	if connection_string.is_empty():
		return _fail("That invitation is no longer valid.")

	return await _join_lobby_by_connection_string(user, connection_string, "", operation)


## Shared tail of both join paths: join the lobby, settle on the join code, then join
## the Party network the lobby advertises. `expected_code` is empty when the caller
## does not already know it (the invite path), in which case it comes from the lobby.
func _join_lobby_by_connection_string(user: Variant, connection_string: String, expected_code: String, operation: int) -> Dictionary:
	var joined: Variant = await _native_call(_playfab().multiplayer, &"join_lobby_async", [user, connection_string, null])
	if not _is_join_operation_current(operation):
		if joined != null and joined.ok:
			await _leave_lobby_instance(joined.data)
		return _fail("Join cancelled.")
	if joined == null or not joined.ok:
		return _fail(_join_failure(joined, "Lobby join"))

	_attach_lobby(joined.data)

	# Checked here, before the Party network join and before the descriptor wait,
	# because this is the last point where both peers still agree on how to talk.
	# Everything after this runs over Godot's RPC layer, which is precisely what a
	# version mismatch breaks -- so a mismatch has to be caught on the lobby or not
	# at all. Blocking rather than warning: the alternative is the silent empty
	# roster this check was written to replace.
	var host_protocol := _lobby_protocol_version()
	if not NRProtocol.is_compatible(host_protocol):
		push_warning("[Party] Refusing join: match protocol '%s', local protocol '%s'." % [
			host_protocol, NRProtocol.version_string()])
		leave()
		return _fail(NRProtocol.mismatch_message(host_protocol, NRProtocol.version_string()))

	var code := expected_code
	if code.is_empty():
		code = _lobby_join_code()
	# The code is Party's invitation identifier, not a caption — without it the network
	# join below cannot authenticate. See _join_attached_lobby.
	if code.is_empty():
		push_warning("[Party] Refusing join: the lobby advertises no join code.")
		leave()
		return _fail(JOIN_FAILED_UNKNOWN)

	return await _join_attached_lobby(user, code, operation)


## Reads the join code back off the lobby the host advertised it on. Search properties
## are set at create time (_create_lobby) and are visible to anyone who can see the
## lobby, so this works for a joiner who never typed the code in.
func _lobby_join_code() -> String:
	if _lobby == null:
		return ""
	var properties: Variant = _lobby.search_properties
	if typeof(properties) != TYPE_DICTIONARY:
		return ""
	var code := _normalize_join_code(String((properties as Dictionary).get(JOIN_CODE_KEY, "")))
	return code if code.length() == JOIN_CODE_LENGTH else ""


## Reads the protocol version the host advertised alongside the join code. Empty when
## the host published none, which is what a build from before this check looks like;
## NRProtocol.is_compatible treats that as a mismatch rather than as permission.
func _lobby_protocol_version() -> String:
	if _lobby == null:
		return ""
	var properties: Variant = _lobby.search_properties
	if typeof(properties) != TYPE_DICTIONARY:
		return ""
	return String((properties as Dictionary).get(NRProtocol.LOBBY_KEY, ""))


## Awaits the descriptor the host published on the attached lobby and joins that Party
## network. `code` doubles as Party's invitation identifier: _make_party_config feeds it
## to the config, and Party's AuthenticateLocalUser rejects a client whose identifier
## differs from the one the host created the network with, so it has to be the real code.
func _join_attached_lobby(user: Variant, code: String, operation: int) -> Dictionary:
	var descriptor: String = await _await_lobby_descriptor(operation)
	if not _is_join_operation_current(operation):
		return _fail("Join cancelled.")
	if descriptor.is_empty():
		# Same words as the service's "not joinable" refusal, so say in the log which one
		# this was: the lobby admitted the player but never offered a Party network.
		push_warning("[Party] Match %s has no Party network descriptor; the host left or never published one." % code)
		leave()
		return _fail("Match %s is no longer accepting players." % code)

	var join_cfg: Variant = _make_party_config(0, code)
	await _chat.ensure_control(user, join_cfg, func() -> bool: return _is_join_operation_current(operation))
	if not _is_join_operation_current(operation):
		return _fail("Join cancelled.")
	var network: Variant = await _native_call(_playfab().party, &"join_network_async", [user, descriptor, join_cfg])
	if not _is_join_operation_current(operation):
		if network != null and network.ok:
			await _leave_network_instance(network.data)
		return _fail("Join cancelled.")
	if network == null or not network.ok:
		leave()
		return _fail(_join_failure(network, "Party network join"))

	_attach_network(network.data, false)
	if not _network_is_usable():
		return _fail("PlayFab Party did not return a usable network peer.")
	join_code = code
	return {"ok": true, "peer": _peer, "code": code, "error": ""}


# --- Teardown ---------------------------------------------------------------

func leave(invalidate_pending: bool = true) -> void:
	if _chat != null:
		_chat.invalidate_session()
	if invalidate_pending:
		cancel_pending_join()
	if _leaving:
		# Nothing can reach a caller parked here: cancel_pending_join() only takes effect
		# where the token is re-read, which is after this await returns. Whatever the
		# leave in progress waits on, this caller waits on too.
		await _leave_completed
		return
	if not recovery_error.is_empty():
		return
	_leaving = true
	_reconcile_initialized_services()
	var deadline := _now_msec() + int(NRConst.MATCH_CLEANUP_SECONDS * 1000.0)
	var lobby: Variant = _lobby
	var network: Variant = _network
	var was_host := _is_host
	_detach_lobby()
	_detach_network()
	# Descriptor clearing must never hold either leave hostage. All three calls and
	# any late create/join results share this one graceful deadline.
	if was_host and lobby != null and not lobby.is_disconnected():
		_clear_descriptor(lobby)
	_leave_lobby_instance(lobby)
	_leave_network_instance(network)
	while not _pending_native.is_empty() or (_chat != null and _chat.is_control_operation_pending()):
		if _now_msec() >= deadline:
			break
		await _sleep(POLL_INTERVAL)
	if _cleanup_failed or not _pending_native.is_empty() or (_chat != null and _chat.is_control_operation_pending()):
		await _recover_services()
	if recovery_error.is_empty():
		_reconcile_initialized_services()
	_is_host = false
	join_code = ""
	if _chat != null:
		_chat.clear_chat_restrictions()
	# The chat control deliberately outlives the session. It is per-user, not per-match:
	# rebuilding it on every leave and rejoin costs two native round trips for a thing
	# that has not changed, and the destroy half of that is one of the awaits that can
	# leave this function unfinished -- which strands every later join behind it, because
	# join() opens with `await leave(false)`. ChatService keeps it until the chat privilege
	# is withdrawn or the title exits. See ChatService.destroy_control().
	_leaving = false
	_leave_completed.emit()


func _clear_descriptor(lobby: Variant) -> void:
	var result: Variant = await _native_call(lobby, &"set_properties_async", [{DESCRIPTOR_KEY: ""}])
	if result == null or not result.ok:
		push_warning("[Party] Could not clear the descriptor: %s" % _reason(result))


func _set_cleanup_status(message: String) -> void:
	cleanup_status = message
	cleanup_status_changed.emit(message)


func _recover_services() -> void:
	_recovering = true
	_native_epoch += 1
	cancel_pending_join()
	_set_cleanup_status("Recovering multiplayer services")
	if _chat != null:
		_chat.begin_service_reset()
	var pf: Variant = _playfab()
	var safe := pf != null
	# Always attempt both scoped shutdowns. Never shut down PlayFab, accounts or saves.
	if pf != null:
		for service: Variant in [pf.party, pf.multiplayer]:
			if service == null or not service.has_method("shutdown_async"):
				safe = false
				push_warning("[Party] Scoped multiplayer shutdown is unavailable.")
				continue
			var result: Variant = await service.shutdown_async()
			if result == null or not result.ok or service.is_initialized():
				safe = false
				push_warning("[Party] Scoped multiplayer shutdown failed: %s" % _reason(result))
	if safe:
		_pending_native.clear()
		_party_initialized = false
		_multiplayer_initialized = false
		_cleanup_failed = false
		if _chat != null:
			_chat.finish_service_reset()
	else:
		recovery_error = RECOVERY_FAILED
		_set_cleanup_status(recovery_error)
	_recovering = false


# --- Initialization ---------------------------------------------------------

## A native state-pump reset can complete an unexposed create/join without any
## network signal reaching us. Native uninitialized state confirms its controls
## were released; local caches and retained chat must not outlive that boundary.
func _reconcile_initialized_services() -> void:
	var pf: Variant = _playfab()
	if pf == null:
		return
	var party_ready: bool = pf.party.is_initialized()
	var lobby_ready: bool = pf.multiplayer.is_initialized()
	if not party_ready and _chat != null \
			and (_party_initialized or _chat.has_control() or _chat.is_control_operation_pending()):
		_chat.begin_service_reset()
		_chat.finish_service_reset()
	_party_initialized = party_ready
	_multiplayer_initialized = lobby_ready


## Brings up PlayFab, Party and the Multiplayer (lobby) service. Returns an empty
## string on success or a player-facing message describing what is missing.
func _ensure_initialized(operation: int) -> String:
	if not _is_join_operation_current(operation):
		return "Session cancelled."
	if not recovery_error.is_empty():
		return recovery_error
	if not _contract_error.is_empty():
		return _contract_error
	var pf: Variant = _playfab()
	if pf == null:
		return "The PlayFab extension is not installed in this build."

	if not pf.is_initialized():
		return "PlayFab is not initialized. Sign in before hosting or joining."

	_reconcile_initialized_services()
	if not _party_initialized:
		var party_init: Variant = await _native_call(pf.party, &"initialize_async", [null, _local_udp_port()])
		if not _is_join_operation_current(operation):
			return "Session cancelled."
		_reconcile_initialized_services()
		if party_init == null or not party_init.ok:
			push_warning("[Party] PlayFab Party could not start: %s" % _reason(party_init))
			return MULTIPLAYER_START_FAILED
		if not _party_initialized:
			return "PlayFab Party stopped while the match was being prepared."

	if not _multiplayer_initialized:
		var mp_init: Variant = await _native_call(pf.multiplayer, &"initialize_async")
		if not _is_join_operation_current(operation):
			return "Session cancelled."
		_reconcile_initialized_services()
		if mp_init == null or not mp_init.ok:
			push_warning("[Party] PlayFab Lobby could not start: %s" % _reason(mp_init))
			return MULTIPLAYER_START_FAILED

	if not _party_initialized or not _multiplayer_initialized:
		return "The multiplayer services stopped while the match was being prepared."
	return ""


func _begin_join_operation(deadline_msec: int = 0) -> int:
	_join_operation_token += 1
	_operation_account_generation = Services.account_generation()
	_operation_deadline_msec = deadline_msec if deadline_msec > 0 \
		else _now_msec() + int(NRConst.MATCH_ESTABLISHMENT_SECONDS * 1000.0)
	cleanup_status = ""
	return _join_operation_token


func _is_join_operation_current(operation: int) -> bool:
	var connectivity := Services.connectivity()
	return (operation == 0 or operation == _join_operation_token) \
		and Services.is_current_account(_operation_account_generation) \
		and (_operation_deadline_msec == 0 or _now_msec() < _operation_deadline_msec) \
		and (connectivity == null or connectivity.is_online())


func _user_is_ready(user: Variant) -> bool:
	return Services.is_current_account(Services.account_generation()) and user != null and user == Services.playfab_user()


## Party binds a UDP socket at initialization, and by default it picks a fixed port. A
## second instance on the same machine then fails to join with "failed to bind or
## connect the UDP socket because the address is already in local use". Asking the OS
## for an ephemeral port instead is what makes two local test clients possible.
## Shipping sessions keep the platform default so Game Core's preferred multiplayer port
## still applies. The addon registers playfab/party/local_udp_socket_bind_port to override
## that port; this project leaves it at its default, so it is absent from project.godot.
func _local_udp_port() -> int:
	return UDP_PORT_EPHEMERAL if Services.is_custom_id_session() else UDP_PORT_PLATFORM_DEFAULT


# --- Lobby ------------------------------------------------------------------

func _create_lobby(user: Variant, descriptor: String, max_players: int, game_mode: String, operation: int) -> String:
	var cfg: Variant = _make_lobby_config()
	if cfg == null:
		return "PlayFabLobbyConfig is unavailable in this build."
	cfg.max_players = maxi(max_players, 2)
	cfg.access_policy = 0  # ACCESS_POLICY_PUBLIC — required for find_lobbies_async.
	cfg.owner_migration_policy = 2  # OWNER_MIGRATION_NONE; the host owns the sim.
	# The protocol version rides on the lobby rather than on the game's own RPCs
	# because a mismatch corrupts those RPCs. The lobby is PlayFab's channel, not
	# Godot's, so it still reads correctly when the peers cannot understand each
	# other's traffic at all. See NRProtocol.
	cfg.search_properties = {
		JOIN_CODE_KEY: join_code,
		GAME_MODE_KEY: game_mode,
		NRProtocol.LOBBY_KEY: NRProtocol.version_string(),
	}
	cfg.lobby_properties = {DESCRIPTOR_KEY: descriptor}

	var result: Variant = await _native_call(_playfab().multiplayer, &"create_lobby_async", [user, cfg])
	if not _is_join_operation_current(operation):
		if result != null and result.ok:
			await _leave_lobby_instance(result.data)
		return "Host cancelled."
	if result == null or not result.ok:
		return "Could not advertise the match: %s" % _reason(result)
	if result.data == null or result.data.is_disconnected():
		return "The match service did not return a usable lobby."
	_attach_lobby(result.data)
	return ""


func _make_lobby_config() -> Variant:
	return ClassDB.instantiate("PlayFabLobbyConfig")


func _make_search_config(code: String) -> Variant:
	var search: Variant = ClassDB.instantiate("PlayFabLobbySearchConfig")
	if search == null:
		return null
	# PlayFab's lobby filter grammar wants single-quoted string literals; double quotes
	# come back as a 'bad request' from the service.
	search.filter = "%s eq '%s'" % [JOIN_CODE_KEY, code]
	search.max_results = 2
	return search


## One lobby lookup only. PlayFab's search index is eventually consistent, but a join
## code has to be read aloud and typed by another person before this runs, which gives
## ordinary hosts time to appear. When a code still misses, an immediate editable retry
## is clearer than a silent backoff loop, and one FindLobbies call cannot create the
## rate-limit spiral that retrying used to guard against.
##
## Returns {"connection_string", "member_count", "max_member_count", "error"}, with the
## counts taken from the same summary as the connection string. A search that worked and
## matched nothing leaves every field empty; a search that failed sets only `error`, to
## the player-facing reason. The two used to look identical, which reported a rate limit
## or an expired sign-in as "No match found".
func _find_lobby(user: Variant, code: String, operation: int = 0) -> Dictionary:
	var lookup := {"connection_string": "", "member_count": 0, "max_member_count": 0, "error": ""}
	if not _is_join_operation_current(operation):
		return lookup
	var search: Variant = _make_search_config(code)
	var found: Variant = await _native_call(_playfab().multiplayer, &"find_lobbies_async", [user, search])
	if not _is_join_operation_current(operation):
		return lookup
	if found == null or not found.ok:
		lookup["error"] = _join_failure(found, "Lobby search", JOIN_FAILED_SEARCH)
		return lookup
	var summary: Variant = _first_live_summary(found.data)
	if summary == null:
		return lookup
	var members := _summary_count(summary, "member_count")
	var capacity := _summary_count(summary, "max_member_count")
	if capacity <= 0:
		push_warning("[Party] Lobby search result for %s carries no capacity (%d/%d); joining without a capacity check." % [
			code, members, capacity])
	lookup["connection_string"] = String(summary.connection_string)
	lookup["member_count"] = members
	lookup["max_member_count"] = capacity
	return lookup


## find_lobbies_async hands back a PlayFabLobbySearchResult wrapper — the summaries live
## on its `lobbies` array, not on `data` directly. Treating `data` as an Array silently
## yields zero matches rather than an error, which is a hard failure to diagnose.
##
## Join codes are unique in practice, so the first live result wins. Tolerating extra
## results rather than demanding exactly one keeps a stale duplicate lobby from blocking
## an otherwise valid join. The capacity check reads this summary's counts and no other:
## another result's counts say nothing about the lobby actually being joined.
func _first_live_summary(result: Variant) -> Variant:
	if result == null:
		return null
	var summaries: Variant = result.lobbies
	if typeof(summaries) != TYPE_ARRAY:
		return null
	for entry in summaries:
		if entry == null:
			continue
		if not String(entry.connection_string).is_empty():
			return entry
	return null


## A member count off a search summary (PlayFabLobbySummary, filled from the service's
## currentMemberCount and maxMemberCount), or 0 when the summary carries none.
func _summary_count(summary: Variant, property: String) -> int:
	var value: Variant = summary.get(property)
	return int(value) if typeof(value) in [TYPE_INT, TYPE_FLOAT] else 0


## True only for a real capacity that the lobby has reached. A capacity of 0 is what a
## summary without counts looks like, and is not evidence of a full lobby.
func _is_at_capacity(member_count: int, max_member_count: int) -> bool:
	return max_member_count > 0 and member_count >= max_member_count


func _attach_lobby(lobby: Variant) -> void:
	_detach_lobby()
	_lobby = lobby


func _detach_lobby() -> void:
	# A membership update posted against the lobby being dropped can no longer be
	# observed, and must not be left to answer for whatever lobby comes next.
	_lock_operation += 1
	_lock_running = false
	_lock_result = {}
	_lobby = null


# --- Network ----------------------------------------------------------------

func _attach_network(network: Variant, is_host: bool) -> void:
	_detach_network()
	if network == null:
		return
	_network = network
	_is_host = is_host
	_peer = network.local_peer
	if not network.state_changed.is_connected(_on_network_state_changed):
		network.state_changed.connect(_on_network_state_changed)


func _detach_network() -> void:
	if _network != null and _network.state_changed.is_connected(_on_network_state_changed):
		_network.state_changed.disconnect(_on_network_state_changed)
	_network = null
	_peer = null


func _retain_lost_network_for_cleanup() -> void:
	if _network != null and _network.state_changed.is_connected(_on_network_state_changed):
		_network.state_changed.disconnect(_on_network_state_changed)
	_peer = null
	cancel_pending_join()


func _network_is_usable() -> bool:
	return _network != null and _peer is MultiplayerPeer \
		and _peer.get_connection_status() == MultiplayerPeer.CONNECTION_CONNECTED


## Party's aggregate network change signal. `kind` says what changed; for a state change
## the new state is in `change.state`.
##
## The kinds split into two groups that must not be treated alike. DESTROYED, and a state
## of DISCONNECTED or FAILED, are terminal: the network is gone and the match cannot
## continue, so they raise `network_lost` and the session ends. ERROR is *not* terminal —
## the addon documents it as "a Party operation or state-change batch failed", which
## includes failures the network survives — so it is reported and the match carries on.
## Ending a match on a recoverable error would be its own defect.
func _on_network_state_changed(change: Variant) -> void:
	if change == null or _network == null or change.network != _network:
		return
	var kind := int(change.kind)
	match _network_changes.find_key(kind):
		&"NETWORK_CHANGE_STATE":
			_handle_network_state(int(change.state), _change_reason(change))
		&"NETWORK_CHANGE_PEER_JOINED":
			peer_joined.emit(int(change.peer_id))
		&"NETWORK_CHANGE_PEER_LEFT":
			peer_left.emit(int(change.peer_id))
		&"NETWORK_CHANGE_DESCRIPTOR_UPDATED":
			# Party can re-issue the descriptor (for example after a migration).
			# Republish so late joiners resolve the current network.
			_republish_descriptor()
		&"NETWORK_CHANGE_DESTROYED":
			var reason := _change_reason(change)
			cancel_pending_join()
			_detach_network()
			var operation := _join_operation_token
			network_destroyed.emit()
			if operation != _join_operation_token or _network != null:
				return
			network_lost.emit(reason if not reason.is_empty()
				else "The match connection was closed.")
		&"NETWORK_CHANGE_ERROR":
			party_failed.emit(_reason(change.result))


## Terminal network states end the session; the rest are the ordinary connect sequence
## (CREATING, CONNECTING, AUTHENTICATING, CONNECTED) and are left alone. DISCONNECTING is
## deliberately not terminal: it is the leading edge of a teardown this instance may have
## asked for, and DISCONNECTED or DESTROYED follows either way.
func _handle_network_state(state: int, reason: String) -> void:
	match state:
		NETWORK_STATE_DISCONNECTED:
			_retain_lost_network_for_cleanup()
			network_lost.emit(reason if not reason.is_empty()
				else "The match connection was lost.")
		NETWORK_STATE_FAILED:
			_retain_lost_network_for_cleanup()
			network_lost.emit(reason if not reason.is_empty()
				else "The match connection failed.")


## The change's own reason string, falling back to its result. Party fills one or the
## other depending on the kind, and neither is guaranteed.
func _change_reason(change: Variant) -> String:
	var reason := String(change.reason).strip_edges()
	if not reason.is_empty():
		return reason
	if change.result != null:
		return _reason(change.result)
	return ""


func _republish_descriptor() -> void:
	if _leaving or _recovering or not _is_host or _network == null or _lobby == null:
		return
	var descriptor := String(_network.descriptor)
	if descriptor.is_empty():
		return
	var result: Variant = await _native_call(_lobby, &"set_properties_async", [{DESCRIPTOR_KEY: descriptor}])
	if result != null and not result.ok:
		push_warning("[Party] Republishing the descriptor failed: %s" % _reason(result))


## The finalized descriptor may not exist yet when create_and_join_network_async
## returns; NETWORK_CHANGE_DESCRIPTOR_UPDATED fills it in. Poll rather than rely on
## the signal so a descriptor that was already populated is handled identically.
func _await_descriptor(operation: int) -> String:
	var deadline := _now_msec() + int(DESCRIPTOR_TIMEOUT * 1000.0)
	while _now_msec() < deadline:
		if not _is_join_operation_current(operation) or _network == null:
			return ""
		var descriptor := String(_network.descriptor)
		if not descriptor.is_empty():
			return descriptor
		await _sleep(POLL_INTERVAL)
	return ""


func _leave_lobby_instance(lobby: Variant) -> void:
	if lobby == null or _recovering or lobby.is_disconnected():
		return
	var epoch := _native_epoch
	var left: Variant = await _native_call(lobby, &"leave_async")
	if epoch == _native_epoch and (left == null or not left.ok):
		_cleanup_failed = true
		push_warning("[Party] Leaving a cancelled lobby failed: %s" % _reason(left))


func _leave_network_instance(network: Variant) -> void:
	if network == null or _recovering:
		return
	if network.state_changed.is_connected(_on_network_state_changed):
		network.state_changed.disconnect(_on_network_state_changed)
	# Successfully exposed networks have a local peer until native detach clears it,
	# before peer-disconnect/DESTROYED callbacks. A terminal state alone is not proof
	# of release: FAILED/DISCONNECTED can still own resources and require leave.
	if network.local_peer == null:
		return
	var epoch := _native_epoch
	var result: Variant = await _native_call(network, &"leave_async")
	if epoch == _native_epoch and (result == null or not result.ok):
		_cleanup_failed = true
		push_warning("[Party] Leaving a cancelled Party network failed: %s" % _reason(result))


## Lobby properties replicate to a joining member shortly after join_lobby_async
## completes, so the descriptor can read back empty on the first look.
func _await_lobby_descriptor(operation: int = 0) -> String:
	var deadline := _now_msec() + int(LOBBY_PROPERTY_TIMEOUT * 1000.0)
	while _now_msec() < deadline:
		if not _is_join_operation_current(operation):
			return ""
		if _lobby == null:
			return ""
		var properties: Dictionary = _lobby.properties
		var descriptor := String(properties.get(DESCRIPTOR_KEY, ""))
		if not descriptor.is_empty():
			return descriptor
		await _sleep(POLL_INTERVAL)
	return ""


# --- Helpers ----------------------------------------------------------------

func _make_party_config(max_players: int, invitation_id: String) -> Variant:
	var cfg: Variant = ClassDB.instantiate("PlayFabPartyConfig")
	if cfg == null:
		return null
	if max_players > 0:
		cfg.max_players = max_players
	# Party's AuthenticateLocalUser rejects a client whose invitation identifier differs
	# from the one the host created the network with, and an empty value makes the addon
	# generate an opaque id that cannot be forwarded. The join code is already mutually
	# known — the client types it in — so it doubles as the invitation id, well under
	# Party's 127-character limit.
	cfg.invitation_id = invitation_id
	# Voice plus text, unless the communications privilege says otherwise (XR-045).
	# Typed messages travel over Party's chat control rather than the game's own RPC
	# channel, so both flags follow the same verdict. The local mic starts muted (see
	# ChatService) so enabling voice never opens a live microphone the player did not
	# ask for; an account without the privilege gets neither.
	var chat_allowed := _chat.is_chat_allowed()
	cfg.enable_voice_chat = chat_allowed
	cfg.enable_text_chat = chat_allowed
	# Nothing displays transcribed speech, so Party is not asked to produce it.
	# Translation follows transcription: it only ever applied to transcribed text.
	cfg.enable_transcription = false
	cfg.enable_translation = false
	# Relay everything through PlayFab Party. Direct peer connectivity needs matched
	# platform-type and login-provider flags, and relaying is what lets two instances
	# on one PC (or two players behind strict NATs) reach each other unchanged.
	cfg.direct_peer_connectivity = 0  # DIRECT_PEER_CONNECTIVITY_NONE
	return cfg


## Five-character lobby code, mirroring LobbyScreen's join-code affordance and the
## five-character validation in PlayFabManager::FindLobbyByJoinCodeAsync.
func _generate_join_code() -> String:
	var code := ""
	for i in JOIN_CODE_LENGTH:
		code += JOIN_CODE_ALPHABET[randi() % JOIN_CODE_ALPHABET.length()]
	return code


func _normalize_join_code(code: String) -> String:
	var normalized := ""
	for character in code.strip_edges().to_upper():
		if JOIN_CODE_ALPHABET.contains(character):
			normalized += character
	return normalized


func _sleep(seconds: float) -> void:
	var loop := Engine.get_main_loop() as SceneTree
	if loop == null:
		return
	await loop.create_timer(seconds).timeout


func _fail(message: String) -> Dictionary:
	return {"ok": false, "peer": null, "code": "", "error": message}


func _playfab() -> Variant:
	return PlatformAccess.playfab()


func _reason(result: Variant) -> String:
	return PlatformAccess.reason(result, "the PlayFab extension is unavailable")


## The player-facing reason a join failed, and the developer-facing one in the log.
##
## `stage` names which step refused -- the lobby search, the lobby join or the Party
## network join -- so the warning is useful without the message on screen having to say
## so. `fallback` is what the player sees when the HRESULT is not in the table.
func _join_failure(result: Variant, stage: String, fallback: String = JOIN_FAILED_UNKNOWN) -> String:
	var message := fallback
	var hresult := 0
	if result != null:
		# The native HRESULT is 32-bit and signed; Godot ints are 64-bit, so a negative
		# value would never match a table written in the unsigned form the reference
		# publishes. Masking makes both spellings land on the same key.
		hresult = int(result.hresult) & 0xFFFFFFFF
		message = JOIN_FAILURE_MESSAGES.get(hresult, fallback)
	push_warning("[Party] %s failed (0x%08X, %s): %s" % [
		stage, hresult, _code_of(result), _reason(result)])
	return message


func _code_of(result: Variant) -> String:
	return String(result.code) if result != null else "no result"
