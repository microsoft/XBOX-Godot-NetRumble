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
signal network_lost(reason: String, context: Variant)
## The low-level twin of `network_lost`, raised only for an actual DESTROYED change.
## Subscribe to `network_lost` instead unless you specifically need to distinguish a
## destroyed network from one that reported DISCONNECTED or FAILED; both mean the
## session is over, and handling both here would end it twice.
signal network_destroyed()
## A Party operation or state-change batch failed. **Not terminal** — the network may
## still be usable — so this reports the failure without ending the session.
signal party_failed(message: String, context: Variant)
signal cleanup_status_changed(message: String)
signal context_updated(context: Variant)
signal context_lost(reason: String, context: Variant)
signal multiplayer_invalidated(recovery_epoch: int)
signal _owned_work_changed()

## Lobby property the host publishes the Party descriptor under. Matches the key used
## by the addon's own Party tutorial so the two interoperate.
const DESCRIPTOR_KEY := "party_descriptor"
## PlayFab only indexes its reserved search keys; the join code has to live in one.
## string_key3 is taken too, by the protocol version -- see NRProtocol.LOBBY_KEY.
const JOIN_CODE_KEY := "string_key1"
const GAME_MODE_KEY := "string_key2"
const LOBBY_KIND_KEY := "string_key4"
const LOBBY_KIND_STAGING := "matchmaking_staging"
const LOBBY_KIND_ARRANGED := "arranged"
const SEARCH_CONTROL_KEY := "nr_search"
const SESSION_PHASE_KEY := "nr_phase"
const ROUND_GENERATION_KEY := "nr_round"
const MATCH_ID_MEMBER_KEY := "nr_match_id"
const MATCH_ORIGIN_MEMBER_KEY := "nr_matchmaking_origin"
const MATCH_ORIGIN_VALUE := "matchmaking"
const HANDOFF_READY_MEMBER_KEY := "nr_handoff_ready"
const STAGING_RETIRED_MEMBER_KEY := "nr_staging_retired"
const MATCHMAKING_INVITATION_ID := "NetRumble"
const SEARCH_CONTROL_SCHEMA := 1
const ARRANGED_PHASE_BOOTSTRAP := "bootstrap"
const ARRANGED_PHASE_GAMEPLAY := "gameplay"
const ARRANGED_PHASE_REMATCH := "rematch_gathering"

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
const ARRANGED_OPERATION_TIMEOUT := 30.0
const ARRANGED_HANDOFF_TIMEOUT := 90.0

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
const LOBBY_CHANGE_OWNER_CHANGED := 5
const LOBBY_CHANGE_DISCONNECTED := 6

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


class LobbyContext extends RefCounted:
	signal lobby_leave_finished(result)
	signal transport_leave_finished(result)

	var context_id: int = 0
	var service_owner: WeakRef = null
	var role: StringName = &""
	var kind: String = ""
	var lobby: Variant = null
	var network: Variant = null
	var peer: Variant = null
	var local_user: Variant = null
	var local_key: Dictionary = {}
	var account_generation: int = -1
	var flow_epoch: int = 0
	var recovery_epoch: int = 0
	var operation_id: int = 0
	var expected_count: int = 0
	var local_creator: bool = false
	var owner_key: Dictionary = {}
	var active_permit: int = 0
	var published_phase: String = ""
	var published_lobby_properties: Dictionary = {}
	var published_search_properties: Dictionary = {}
	var left_lobby := false
	var left_transport := false
	var lobby_leave_running := false
	var transport_leave_running := false
	var retired := false
	var cleanup_pending := false
	var pending_operations := 0
	var lock_running := false
	var lock_operation := 0
	var lock_result: Variant = null
	var post_running := false
	var post_operation := 0
	var post_result: Variant = null
	var clock: OnlineFlowClock = null
	var network_callback: Callable = Callable()
	var lobby_callback: Callable = Callable()
	var loss_emitted := false


class ScopedOperation extends RefCounted:
	signal cleanup_changed(operation)
	signal settled_changed(operation)

	var id: int = 0
	var context_id: int = 0
	var account_generation: int = -1
	var flow_epoch: int = 0
	var recovery_epoch: int = 0
	var operation_id: int = 0
	var deadline_msec: int = 0
	var clock: OnlineFlowClock = null
	var outcome: int = -1
	var reason_code: StringName = &""
	var reason: String = ""
	var diagnostic: String = ""
	var cleanup_pending := false
	var retired := false
	var settled := false
	var native_done := false
	var publication_permit := 0
	var required_permit := 0
	var kind: StringName = &""
	var timeout_reason_code: StringName = &""
	var timeout_reason: String = ""
	var deadline_alarm: Variant = null


class PartyResult extends RefCounted:
	enum Outcome {
		OK,
		INVALID,
		CANCELLED,
		SUPERSEDED,
		TIMEOUT,
		SERVICE_ERROR,
	}

	var outcome := Outcome.INVALID
	var reason_code: StringName = &""
	var reason: String = ""
	var diagnostic: String = ""
	var context: LobbyContext = null
	var peer: Variant = null
	var owner_key: Dictionary = {}
	var local_creator := false
	var descriptor_ready := false
	var descriptor := ""
	var publication_permit := 0
	var cleanup_pending := false
	var operation: ScopedOperation = null

	func ok() -> bool:
		return outcome == Outcome.OK


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
var _clock: OnlineFlowClock = null
var _contexts: Dictionary = {}
var _next_context_id := 1
var _next_context_operation := 1
var _next_scoped_operation_id := 1
var _next_publication_permit := 1
var _attached_context: LobbyContext = null
var _owned_operation_count := 0
var _legacy_attach_succeeded := true
var _scoped_recovery_epoch := 0
var _scoped_operations: Dictionary = {}


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


func configure_clock(clock: OnlineFlowClock) -> void:
	if has_owned_work() or _leaving:
		push_warning("[Party] Cannot replace the online-flow clock while work is active.")
		return
	_clock = clock


## True when the godot_playfab extension is present. Everything else assumes this.
func is_available() -> bool:
	return _playfab() != null


func has_network() -> bool:
	return _network != null


func peer() -> Variant:
	return _peer


func cancel_pending_join() -> void:
	_join_operation_token += 1
	for context_value: Variant in _contexts.values():
		var context := context_value as LobbyContext
		context.operation_id += 1
		context.active_permit = 0


## The joined lobby's connection string, or empty when there is no lobby. This is the
## value an invitee needs for an explicit join, so it is what the Xbox multiplayer
## activity advertises: handing it out skips _find_lobby() entirely,
## which is the slowest and least reliable part of joining.
func lobby_connection_string(context: LobbyContext = null) -> String:
	var target: Variant = context.lobby if context != null else _lobby
	if target == null:
		return ""
	return String(target.connection_string)


func lobby_id(context: LobbyContext) -> String:
	if not _context_is_live(context):
		return ""
	return String(context.lobby.lobby_id)


## PlayFab entity key for a Party peer, as a {"id", "type"} dictionary. The entity id is
## PlayFab's own authenticated identity for the player, so it is what the roster uses to
## tell two players apart even when they share a local profile. Unlike a XUID carried in
## an RPC payload, it comes from Party's authenticated local user and cannot be spoofed
## by a modified client.
func entity_key_for(peer_id: int) -> Dictionary:
	if _peer == null:
		return {}
	return _peer.get_peer_entity_key(peer_id)


func local_entity_key(context: LobbyContext = null) -> Dictionary:
	if context != null:
		return context.local_key.duplicate()
	if _peer == null:
		return {}
	return _copy_entity_key(_peer.get_peer_entity_key(_peer.get_unique_id()))


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
	# The matchmaking lock contract requires the addon API introduced by
	# microsoft/XBOX-Godot-Sample#179.
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

	var deadline := _bounded_deadline(_clock, 0, LOBBY_LOCK_TIMEOUT)
	while _lock_running and _lock_operation == operation \
		and not _deadline_expired(_clock, deadline):
		await _sleep_until_poll(_clock, deadline)
	if _lock_operation != operation or lobby != _lobby:
		return {"ok": false, "error": LOCK_FAILED_SUPERSEDED}
	if _lock_running:
		return {"ok": false, "error": LOCK_FAILED_TIMEOUT}
	return _lock_result.duplicate()


func _post_membership_lock(lobby: Variant, membership_lock: int, operation: int) -> void:
	var result: Variant = await _native_call(lobby, &"set_membership_lock_async", [membership_lock])
	# The lobby may have been left, or a later update may own the outcome. In either case,
	# this result belongs to no current caller.
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
	var deadline := _bounded_deadline(_clock, 0, LOBBY_LOCK_TIMEOUT)
	while _lock_running and not _deadline_expired(_clock, deadline):
		await _sleep_until_poll(_clock, deadline)
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

	_legacy_attach_succeeded = true
	_attach_network(created.data, true)
	if not _legacy_attach_succeeded:
		await _leave_network_instance(created.data)
		join_code = ""
		return _fail("Another Party transport is already attached.")
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

	var joined_lobby: Variant = joined.data
	var search_value: Variant = _object_value(joined_lobby, &"search_properties", {})
	var search_properties: Dictionary = search_value as Dictionary \
		if typeof(search_value) == TYPE_DICTIONARY else {}
	var kind := String(search_properties.get(LOBBY_KIND_KEY, ""))
	if kind == LOBBY_KIND_STAGING or kind == LOBBY_KIND_ARRANGED:
		var unavailable_reason := _matchmaking_join_unavailable_reason()
		if not unavailable_reason.is_empty():
			await _leave_lobby_instance(joined_lobby)
			return _kind_refusal(unavailable_reason, kind)
		return await _join_scoped_lobby(user, joined_lobby, kind, operation)

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

	var outcome := await _join_attached_lobby(user, code, operation)
	outcome["kind"] = ""
	outcome["context"] = null
	return outcome


func _join_scoped_lobby(
	user: Variant,
	lobby: Variant,
	kind: String,
	operation: int
) -> Dictionary:
	var role := &"staging" if kind == LOBBY_KIND_STAGING else &"arranged"
	var context := _new_context(
		role, kind, user, _operation_account_generation, 0)
	var context_operation := context.operation_id
	_attach_context_lobby(context, lobby)
	var state := snapshot(context)
	var protocol := String((state.search_properties as Dictionary).get(
		NRProtocol.LOBBY_KEY, ""))
	var destination := "staging_gathering"
	var match_id := ""
	var round := 0
	var owner_key: Dictionary = state.owner_key
	context.expected_count = int(state.max_members)
	if bool(state.disconnected) or context.expected_count != MatchmakingService.EXPECTED_MATCH_COUNT:
		await leave_lobby(context)
		return _kind_refusal(
			"That matchmaking lobby is no longer available.",
			kind)
	if bool(state.membership_locked):
		await leave_lobby(context)
		return _kind_refusal(
			"That matchmaking lobby is no longer accepting players.",
			kind)
	if kind == LOBBY_KIND_ARRANGED:
		var arranged := _validate_arranged_rematch_state(state, true)
		if not bool(arranged.get("ok", false)):
			await leave_lobby(context)
			return _kind_refusal(String(arranged.get(
				"error",
				"That arranged match is not accepting rematch players.")), kind)
		protocol = String(arranged.get("protocol", ""))
		match_id = String(arranged.get("match_id", ""))
		round = int(arranged.get("round", 0))
		owner_key = (arranged.get("owner_key", {}) as Dictionary).duplicate()
		context.owner_key = owner_key.duplicate()
		destination = "arranged_rematch"
	else:
		var search_control: Dictionary = state.search_control
		if bool(search_control.get("valid", false)) \
			and String(search_control.get("phase", "")) != "gathering":
			await leave_lobby(context)
			return _kind_refusal(
				"That matchmaking group has already started searching.",
				kind)
	if not NRProtocol.is_compatible(protocol):
		await leave_lobby(context)
		return _kind_refusal(
			NRProtocol.mismatch_message(protocol, NRProtocol.version_string()),
			kind)

	var member_properties := {
		MatchmakingService.PROTOCOL_MEMBER_KEY: NRProtocol.version_string(),
		MATCH_ORIGIN_MEMBER_KEY: MATCH_ORIGIN_VALUE,
	}
	if kind == LOBBY_KIND_ARRANGED:
		member_properties[MATCH_ID_MEMBER_KEY] = match_id
	var member_post := await post_context_update(
		context, {}, {}, member_properties, _operation_deadline_msec)
	if not member_post.ok():
		await leave_lobby(context)
		return _kind_refusal(
			member_post.reason if not member_post.reason.is_empty() \
				else "Could not verify this matchmaking lobby member.",
			kind)
	if kind == LOBBY_KIND_ARRANGED:
		state = snapshot(context)
		var confirmed := _validate_arranged_rematch_state(state)
		if not bool(confirmed.get("ok", false)) \
			or String(confirmed.get("match_id", "")) != match_id \
			or int(confirmed.get("round", -1)) != round \
			or not _entity_keys_match(
				confirmed.get("owner_key", {}) as Dictionary,
				owner_key):
			await leave_lobby(context)
			return _kind_refusal(
				"That arranged match changed while the invitation was being accepted.",
				kind)

	var descriptor_result := await _await_context_transport_properties(
		context, 0, context_operation)
	if not descriptor_result.ok():
		await leave_lobby(context)
		return _kind_refusal(descriptor_result.reason, kind)
	if not _is_join_operation_current(operation):
		await leave_lobby(context)
		return _kind_refusal("Join cancelled.", kind)
	var cfg: Variant = _make_party_config(0, MATCHMAKING_INVITATION_ID)
	var party: Variant = _party_sdk()
	if cfg == null or party == null:
		await leave_lobby(context)
		return _kind_refusal("The PlayFab Party service is unavailable.", kind)
	await _chat.ensure_control(user, cfg, func() -> bool:
		return _is_join_operation_current(operation) \
			and _context_operation_current(context, context_operation))
	if not _is_join_operation_current(operation) \
		or not _context_operation_current(context, context_operation):
		await leave_lobby(context)
		return _kind_refusal("Join cancelled.", kind)
	_begin_owned_call(context)
	var network: Variant = await party.join_network_async(
		user, descriptor_result.descriptor, cfg)
	if not _is_join_operation_current(operation) \
		or not _context_operation_current(context, context_operation):
		if _result_ok(network):
			await _leave_stale_network_instance(context, _result_data(network))
		_end_owned_call(context)
		await leave_lobby(context)
		return _kind_refusal("Join cancelled.", kind)
	if not _result_ok(network):
		_end_owned_call(context)
		await leave_lobby(context)
		return _kind_refusal(_join_failure(network, "Party network"), kind)
	if not _attach_context_transport(context, _result_data(network), false):
		await _leave_network_instance(_result_data(network))
		_end_owned_call(context)
		await leave_lobby(context)
		return _kind_refusal(
			"The Party service did not return a usable transport.",
			kind)
	_end_owned_call(context)
	join_code = ""
	var joined := {
		"ok": true,
		"peer": _peer,
		"code": "",
		"error": "",
		"kind": kind,
		"context": context,
		"destination": destination,
	}
	if kind == LOBBY_KIND_ARRANGED:
		joined["match_id"] = match_id
		joined["round"] = round
		joined["owner_key"] = owner_key
		joined["expected_count"] = context.expected_count
	return joined


func _validate_arranged_rematch_state(
	state: Dictionary,
	allow_local_unwritten: bool = false
) -> Dictionary:
	if bool(state.get("disconnected", true)) \
		or int(state.get("max_members", 0)) != MatchmakingService.EXPECTED_MATCH_COUNT \
		or int(state.get("access_policy", -1)) != 2 \
		or int(state.get("owner_migration", -1)) != 0 \
		or bool(state.get("restrict_invites_to_owner", true)) \
		or bool(state.get("membership_locked", true)):
		return {
			"ok": false,
			"error": "That arranged match is not accepting rematch players.",
		}
	var control_value: Variant = state.get("arranged_control", {})
	var control: Dictionary = control_value as Dictionary \
		if typeof(control_value) == TYPE_DICTIONARY else {}
	if not bool(control.get("valid", false)) \
		or String(control.get("phase", "")) != ARRANGED_PHASE_REMATCH:
		return {
			"ok": false,
			"error": "That arranged match is not in rematch gathering.",
		}
	var owner_value: Variant = state.get("owner_key", {})
	var owner_key := _copy_entity_key(owner_value as Dictionary) \
		if typeof(owner_value) == TYPE_DICTIONARY else {}
	if owner_key.is_empty():
		return {
			"ok": false,
			"error": "That arranged match has no current owner.",
		}
	var owner_protocol := ""
	var owner_present := false
	var match_id := String(control.get("match_id", ""))
	var local_value: Variant = state.get("local_key", {})
	var local_key := _copy_entity_key(local_value as Dictionary) \
		if typeof(local_value) == TYPE_DICTIONARY else {}
	var members_value: Variant = state.get("members", [])
	var members: Array = members_value as Array \
		if typeof(members_value) == TYPE_ARRAY else []
	for member_value: Variant in members:
		if typeof(member_value) != TYPE_DICTIONARY:
			continue
		var member := member_value as Dictionary
		if not bool(member.get("connected", false)):
			continue
		var key_value: Variant = member.get("key", {})
		var key := _copy_entity_key(key_value as Dictionary) \
			if typeof(key_value) == TYPE_DICTIONARY else {}
		var properties_value: Variant = member.get("properties", {})
		var properties: Dictionary = properties_value as Dictionary \
			if typeof(properties_value) == TYPE_DICTIONARY else {}
		var member_protocol := String(properties.get(
			MatchmakingService.PROTOCOL_MEMBER_KEY, ""))
		if allow_local_unwritten and _entity_keys_match(key, local_key) \
			and member_protocol.is_empty() \
			and String(properties.get(MATCH_ID_MEMBER_KEY, "")).is_empty():
			continue
		if not NRProtocol.is_compatible(member_protocol) \
			or String(properties.get(MATCH_ID_MEMBER_KEY, "")) != match_id:
			return {
				"ok": false,
				"error": "That arranged match has incompatible member metadata.",
			}
		if _entity_keys_match(key, owner_key):
			owner_present = true
			owner_protocol = member_protocol
	if not owner_present:
		return {
			"ok": false,
			"error": "That arranged match owner is not connected.",
		}
	return {
		"ok": true,
		"match_id": match_id,
		"round": int(control.get("round", 0)),
		"owner_key": owner_key,
		"protocol": owner_protocol,
	}


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


## Reads the protocol version the host advertised alongside the join code. An empty
## protocol identifies an incompatible host and is rejected by NRProtocol.is_compatible.
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

	_legacy_attach_succeeded = true
	_attach_network(network.data, false)
	if not _legacy_attach_succeeded:
		await _leave_network_instance(network.data)
		var joined_lobby: Variant = _lobby
		_detach_lobby()
		await _leave_lobby_instance(joined_lobby)
		return _fail("Another Party transport is already attached.")
	if not _network_is_usable():
		return _fail(JOIN_FAILED_UNKNOWN)
	join_code = code
	return {
		"ok": true,
		"peer": _peer,
		"code": code,
		"error": "",
		"destination": "",
	}


# --- Teardown ---------------------------------------------------------------

## Terminal whole-service cleanup. Matchmaking handoff code must use leave_lobby() /
## leave_transport() for captured contexts; this global operation is for retire-first exits,
## account teardown and shutdown, and waits for every legacy and scoped resource it owns.
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
	var network: Variant = _network if _attached_context == null else null
	var was_host := _is_host
	var scoped_contexts := _contexts.values().duplicate()
	_detach_lobby()
	if _attached_context == null:
		_detach_network()
	# Descriptor clearing must never hold either leave hostage. All three calls and
	# scoped cleanup and any late create/join results share this one graceful deadline.
	if was_host and lobby != null and not lobby.is_disconnected():
		_clear_descriptor(lobby)
	_leave_lobby_instance(lobby)
	_leave_network_instance(network)
	for context_value: Variant in scoped_contexts:
		var context := context_value as LobbyContext
		leave_transport(context)
		leave_lobby(context)
	while not _pending_native.is_empty() \
			or (_chat != null and _chat.is_control_operation_pending()) \
			or not _captured_contexts_quiescent(scoped_contexts) \
			or _owned_operation_count > 0:
		if _now_msec() >= deadline:
			break
		await _sleep(POLL_INTERVAL)
	if _cleanup_failed or not _pending_native.is_empty() \
			or (_chat != null and _chat.is_control_operation_pending()) \
			or not _captured_contexts_quiescent(scoped_contexts) \
			or _owned_operation_count > 0:
		await _recover_services()
	if recovery_error.is_empty():
		_reconcile_initialized_services()
		for context_value: Variant in scoped_contexts:
			_discard_context(context_value as LobbyContext)
		_owned_work_changed.emit()
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
		_complete_scoped_recovery()
		multiplayer_invalidated.emit(_scoped_recovery_epoch)
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


func _matchmaking_join_unavailable_reason() -> String:
	if Services == null or not Services.has_method("quick_match_available"):
		return "Quick Match is unavailable in this build."
	if Services.quick_match_available():
		return ""
	var reason := Services.quick_match_unavailable_reason()
	return reason if not reason.is_empty() else "Quick Match is unavailable in this build."


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
	return _new_lobby_config()


func _make_search_config(code: String) -> Variant:
	var search: Variant = _new_lobby_search_config()
	if search == null:
		return null
	# PlayFab's lobby filter grammar wants single-quoted string literals; double quotes
	# come back as a 'bad request' from the service.
	search.filter = "%s eq '%s'" % [JOIN_CODE_KEY, code]
	search.max_results = 2
	return search


## One lobby lookup only. PlayFab's search index is eventually consistent, but a join
## code has to be read aloud and typed by another person before this runs, which gives
## ordinary hosts time to appear. A miss returns an immediate editable retry, and the
## single FindLobbies call prevents a rate-limit spiral.
##
## Returns {"connection_string", "member_count", "max_member_count", "error"}, with the
## counts taken from the same summary as the connection string. A search that worked and
## matched nothing leaves every field empty; a failed search sets only `error` to the
## player-facing reason, keeping service failure distinct from an empty result.
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
	# A membership update posted against the lobby being dropped is unobservable and
	# must not answer for the next lobby.
	_lock_operation += 1
	_lock_running = false
	_lock_result = {}
	_lobby = null


# --- Network ----------------------------------------------------------------

func _attach_network(network: Variant, is_host: bool) -> void:
	_legacy_attach_succeeded = false
	if _network != null or _attached_context != null:
		return
	if network == null:
		return
	_network = network
	_is_host = is_host
	_peer = network.local_peer
	if not network.state_changed.is_connected(_on_network_state_changed):
		network.state_changed.connect(_on_network_state_changed)
	_legacy_attach_succeeded = true


func _detach_network() -> void:
	if _attached_context != null:
		_disconnect_context_transport(_attached_context)
		return
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
			network_lost.emit(
				reason if not reason.is_empty() else "The match connection was closed.",
				null)
		&"NETWORK_CHANGE_ERROR":
			party_failed.emit(_reason(change.result), null)


## Terminal network states end the session; the rest are the ordinary connect sequence
## (CREATING, CONNECTING, AUTHENTICATING, CONNECTED) and are left alone. DISCONNECTING is
## deliberately not terminal: it is the leading edge of a teardown this instance may have
## asked for, and DISCONNECTED or DESTROYED follows either way.
func _handle_network_state(state: int, reason: String) -> void:
	match state:
		NETWORK_STATE_DISCONNECTED:
			_retain_lost_network_for_cleanup()
			network_lost.emit(
				reason if not reason.is_empty() else "The match connection was lost.",
				null)
		NETWORK_STATE_FAILED:
			_retain_lost_network_for_cleanup()
			network_lost.emit(
				reason if not reason.is_empty() else "The match connection failed.",
				null)


## The change's own reason string, falling back to its result. Party fills one or the
## other depending on the kind, and neither is guaranteed.
func _change_reason(change: Variant) -> String:
	var reason := String(_object_value(change, &"reason", "")).strip_edges()
	if not reason.is_empty():
		return reason
	var result: Variant = _object_value(change, &"result", null)
	if result != null:
		return _reason(result)
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


func _leave_stale_lobby_instance(context: LobbyContext, lobby: Variant) -> void:
	if context == null or context.recovery_epoch == _scoped_recovery_epoch:
		await _leave_lobby_instance(lobby)
		return
	if lobby == null or lobby.is_disconnected():
		return
	var result: Variant = await lobby.leave_async()
	if not _result_ok(result):
		push_warning("[Party] Leaving an old-recovery lobby failed: %s" % _reason(result))


func _leave_stale_network_instance(context: LobbyContext, network: Variant) -> void:
	if context == null or context.recovery_epoch == _scoped_recovery_epoch:
		await _leave_network_instance(network)
		return
	if network == null or network.local_peer == null:
		return
	var result: Variant = await network.leave_async()
	if not _result_ok(result):
		push_warning("[Party] Leaving an old-recovery Party network failed: %s" % _reason(result))


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


# --- Scoped matchmaking resources ------------------------------------------

func create_staging(
	user: Variant,
	capacity: int,
	mode_name: String,
	account_generation: int,
	flow_epoch: int,
	deadline_msec: int = 0
) -> PartyResult:
	if user == null or capacity != 4 or mode_name.strip_edges().is_empty():
		return _context_failure(
			PartyResult.Outcome.INVALID,
			&"invalid_staging_spec",
			"Matchmaking staging requires a signed-in user, four slots, and a game mode.")
	if not _account_is_current(account_generation):
		return _context_failure(
			PartyResult.Outcome.SUPERSEDED,
			&"account_changed",
			"The signed-in account changed before matchmaking started.")
	if _network != null:
		return _context_failure(
			PartyResult.Outcome.INVALID,
			&"transport_already_attached",
			"Leave the current game before starting matchmaking.")
	if _leaving or _recovering or not recovery_error.is_empty():
		return _context_failure(
			PartyResult.Outcome.SUPERSEDED,
			&"cleanup_pending",
			recovery_error if not recovery_error.is_empty() \
				else "The previous online session is still being cleaned up.")

	var context := _new_context(&"staging", LOBBY_KIND_STAGING, user, account_generation, flow_epoch)
	context.expected_count = capacity
	var operation := _begin_scoped_operation(
		context,
		&"create_staging",
		deadline_msec,
		NRConst.MATCH_ESTABLISHMENT_SECONDS)
	if operation == null:
		_discard_context(context)
		return _context_failure(
			PartyResult.Outcome.SUPERSEDED,
			&"scoped_operation_unavailable",
			"The previous online session is still being cleaned up.")
	_run_create_staging(context, user, capacity, mode_name, operation)
	return await _await_scoped_operation(
		operation,
		context,
		&"staging_timeout",
		"Matchmaking staging did not finish in time.")


func _run_create_staging(
	context: LobbyContext,
	user: Variant,
	capacity: int,
	mode_name: String,
	operation: ScopedOperation
) -> void:
	var ready_error := await _ensure_context_initialized(
		context, operation.deadline_msec, operation)
	if not _scoped_operation_current(context, operation):
		_discard_context(context)
		_finish_scoped_operation(
			operation,
			context,
			PartyResult.Outcome.SUPERSEDED,
			&"staging_superseded",
			"Matchmaking staging was replaced.")
		return
	if not ready_error.is_empty():
		_discard_context(context)
		_finish_scoped_operation(
			operation,
			context,
			PartyResult.Outcome.SERVICE_ERROR,
			&"playfab_initialization_failed",
			ready_error)
		return

	var cfg: Variant = _make_party_config(capacity, MATCHMAKING_INVITATION_ID)
	var party: Variant = _party_sdk()
	if cfg == null or party == null:
		_discard_context(context)
		_finish_scoped_operation(
			operation,
			context,
			PartyResult.Outcome.INVALID,
			&"party_unavailable",
			"The PlayFab Party service is unavailable.")
		return
	await _chat.ensure_control(user, cfg, func() -> bool:
		return _scoped_operation_current(context, operation))
	if not _scoped_operation_current(context, operation):
		_discard_context(context)
		_finish_scoped_operation(
			operation,
			context,
			PartyResult.Outcome.SUPERSEDED,
			&"staging_superseded",
			"Matchmaking staging was replaced.")
		return
	var created: Variant = await party.create_and_join_network_async(user, cfg)
	if not _scoped_operation_current(context, operation):
		if _result_ok(created):
			await _leave_stale_network_instance(context, _result_data(created))
		_discard_context(context)
		_finish_scoped_operation(
			operation,
			context,
			PartyResult.Outcome.SUPERSEDED,
			&"staging_superseded",
			"Matchmaking staging was replaced.")
		return
	if not _result_ok(created):
		_discard_context(context)
		_finish_scoped_operation(
			operation,
			context,
			PartyResult.Outcome.SERVICE_ERROR,
			&"party_create_failed",
			"Could not create the matchmaking Party network.",
			_reason(created))
		return

	if not _attach_context_transport(context, _result_data(created), true):
		await _leave_network_instance(_result_data(created))
		_discard_context(context)
		_finish_scoped_operation(
			operation,
			context,
			PartyResult.Outcome.INVALID,
			&"transport_already_attached",
			"Another Party transport is already attached.")
		return
	var descriptor := await _await_context_descriptor(
		context, operation.deadline_msec, operation.operation_id, operation)
	if descriptor.is_empty():
		var superseded := not _scoped_operation_current(context, operation)
		_settle_scoped_operation(
			operation,
			PartyResult.Outcome.SUPERSEDED if superseded else PartyResult.Outcome.TIMEOUT,
			&"staging_superseded" if superseded else &"party_descriptor_timeout",
			"Matchmaking staging was replaced." if superseded \
				else "The Party network never published a connection descriptor.")
		await leave_transport(context)
		await leave_lobby(context)
		_finish_scoped_operation(operation, context, operation.outcome)
		return

	var lobby_cfg: Variant = _new_lobby_config()
	var multiplayer: Variant = _multiplayer_sdk()
	if lobby_cfg == null or multiplayer == null:
		_settle_scoped_operation(
			operation,
			PartyResult.Outcome.INVALID,
			&"lobby_unavailable",
			"The PlayFab Lobby service is unavailable.")
		await leave_transport(context)
		await leave_lobby(context)
		_finish_scoped_operation(operation, context, operation.outcome)
		return
	lobby_cfg.max_players = capacity
	lobby_cfg.access_policy = 0
	lobby_cfg.owner_migration_policy = 2
	lobby_cfg.restrict_invites_to_lobby_owner = false
	lobby_cfg.search_properties = {
		GAME_MODE_KEY: mode_name,
		NRProtocol.LOBBY_KEY: NRProtocol.version_string(),
		LOBBY_KIND_KEY: LOBBY_KIND_STAGING,
	}
	lobby_cfg.lobby_properties = {
		DESCRIPTOR_KEY: "",
		SESSION_PHASE_KEY: "creating",
	}
	lobby_cfg.member_properties = {
		MatchmakingService.PROTOCOL_MEMBER_KEY: NRProtocol.version_string(),
		MATCH_ORIGIN_MEMBER_KEY: MATCH_ORIGIN_VALUE,
	}
	var lobby_result: Variant = await multiplayer.create_lobby_async(user, lobby_cfg)
	if not _scoped_operation_current(context, operation):
		if _result_ok(lobby_result):
			await _leave_stale_lobby_instance(context, _result_data(lobby_result))
		await leave_transport(context)
		_discard_context(context)
		_finish_scoped_operation(
			operation,
			context,
			PartyResult.Outcome.SUPERSEDED,
			&"staging_superseded",
			"Matchmaking staging was replaced.")
		return
	if not _result_ok(lobby_result):
		_settle_scoped_operation(
			operation,
			PartyResult.Outcome.SERVICE_ERROR,
			&"staging_lobby_create_failed",
			"Could not create the matchmaking lobby.",
			_reason(lobby_result))
		await leave_transport(context)
		_discard_context(context)
		_finish_scoped_operation(operation, context, operation.outcome)
		return

	_attach_context_lobby(context, _result_data(lobby_result))
	var permit := _issue_publication_permit(context)
	_finish_scoped_operation(
		operation,
		context,
		PartyResult.Outcome.OK,
		&"",
		"",
		"",
		permit)


func publish_transport(
	context: LobbyContext,
	permit: int,
	phase: String,
	extra_lobby_properties: Dictionary = {},
	extra_search_properties: Dictionary = {},
	deadline_msec: int = 0
) -> PartyResult:
	if not _context_is_current(context) or context.network == null or context.lobby == null:
		return _context_failure(
			PartyResult.Outcome.INVALID,
			&"invalid_context",
			"The matchmaking context is no longer active.",
			context)
	if permit <= 0 or permit != context.active_permit:
		return _context_failure(
			PartyResult.Outcome.SUPERSEDED,
			&"publication_revoked",
			"Transport publication permission is no longer current.",
			context)
	if not context.local_creator or not _context_local_is_owner(context):
		return _context_failure(
			PartyResult.Outcome.INVALID,
			&"publication_not_owner",
			"Only the arranged lobby owner may publish the Party transport.",
			context)
	var descriptor := String(_object_value(context.network, &"descriptor", ""))
	if descriptor.is_empty():
		return _context_failure(
			PartyResult.Outcome.INVALID,
			&"descriptor_unavailable",
			"The Party network has no connection descriptor.",
			context)
	if context.kind == LOBBY_KIND_ARRANGED:
		var control := decode_arranged_control(extra_lobby_properties)
		if not bool(control.get("valid", false)) \
			or String(control.get("phase", "")) != phase:
			return _context_failure(
				PartyResult.Outcome.INVALID,
				&"arranged_control_invalid",
				"Arranged transport publication needs matching match, round, and phase control.",
				context)

	var lobby_properties := extra_lobby_properties.duplicate(true)
	lobby_properties[DESCRIPTOR_KEY] = descriptor
	lobby_properties[SESSION_PHASE_KEY] = phase
	var search_properties := extra_search_properties.duplicate(true)
	if context.kind == LOBBY_KIND_ARRANGED:
		search_properties[LOBBY_KIND_KEY] = LOBBY_KIND_ARRANGED
	var posted := await _post_context_update_checked(
		context,
		lobby_properties,
		search_properties,
		{},
		deadline_msec,
		permit)
	if not posted.ok():
		return posted
	context.published_phase = phase
	context.published_lobby_properties = lobby_properties.duplicate(true)
	context.published_search_properties = search_properties.duplicate(true)
	posted.publication_permit = permit
	posted.descriptor = descriptor
	posted.descriptor_ready = true
	return posted


func join_arranged(
	user: Variant,
	arrangement: String,
	member_properties: Dictionary,
	expected_count: int,
	account_generation: int,
	flow_epoch: int,
	deadline_msec: int = 0
) -> PartyResult:
	if expected_count != MatchmakingService.EXPECTED_MATCH_COUNT:
		return _context_failure(
			PartyResult.Outcome.INVALID,
			&"arranged_profile_mismatch",
			"The arranged lobby does not match the four-player Deathmatch profile.")
	if user == null or arrangement.strip_edges().is_empty():
		return _context_failure(
			PartyResult.Outcome.INVALID,
			&"invalid_arranged_join",
			"The arranged lobby join request is invalid.")
	if not _account_is_current(account_generation):
		return _context_failure(
			PartyResult.Outcome.SUPERSEDED,
			&"account_changed",
			"The signed-in account changed before the arranged lobby join.")
	if _leaving or _recovering or not recovery_error.is_empty():
		return _context_failure(
			PartyResult.Outcome.SUPERSEDED,
			&"cleanup_pending",
			recovery_error if not recovery_error.is_empty() \
				else "The previous online session is still being cleaned up.")
	var multiplayer: Variant = _multiplayer_sdk()
	var config: Variant = _new_lobby_join_config()
	if multiplayer == null or config == null:
		return _context_failure(
			PartyResult.Outcome.INVALID,
			&"arranged_join_unavailable",
			"This build cannot configure an arranged lobby.")

	config.max_member_count = expected_count
	config.access_policy = 2
	config.owner_migration_policy = 0
	config.restrict_invites_to_lobby_owner = false
	config.member_properties = member_properties.duplicate(true)
	var context := _new_context(
		&"arranged", LOBBY_KIND_ARRANGED, user, account_generation, flow_epoch)
	context.expected_count = expected_count
	var operation := _begin_scoped_operation(
		context,
		&"join_arranged",
		deadline_msec,
		ARRANGED_OPERATION_TIMEOUT)
	if operation == null:
		_discard_context(context)
		return _context_failure(
			PartyResult.Outcome.SUPERSEDED,
			&"scoped_operation_unavailable",
			"The previous online session is still being cleaned up.")
	_run_join_arranged(context, user, arrangement, config, operation)
	return await _await_scoped_operation(
		operation,
		context,
		&"arranged_join_timeout",
		"Joining the arranged lobby took too long.")


func _run_join_arranged(
	context: LobbyContext,
	user: Variant,
	arrangement: String,
	config: Variant,
	operation: ScopedOperation
) -> void:
	var multiplayer: Variant = _multiplayer_sdk()
	if multiplayer == null:
		_discard_context(context)
		_finish_scoped_operation(
			operation,
			context,
			PartyResult.Outcome.INVALID,
			&"arranged_join_unavailable",
			"This build cannot configure an arranged lobby.")
		return
	var result: Variant = await multiplayer.join_arranged_lobby_async(user, arrangement, config)
	if not _scoped_operation_current(context, operation):
		if _result_ok(result):
			await _leave_stale_lobby_instance(context, _result_data(result))
		_discard_context(context)
		_finish_scoped_operation(
			operation,
			context,
			PartyResult.Outcome.SUPERSEDED,
			&"arranged_join_superseded",
			"The arranged lobby join was replaced.")
		return
	if not _result_ok(result):
		_discard_context(context)
		_finish_scoped_operation(
			operation,
			context,
			PartyResult.Outcome.SERVICE_ERROR,
			&"arranged_join_failed",
			"Could not join the arranged PlayFab lobby.",
			_reason(result))
		return

	_attach_context_lobby(context, _result_data(result))
	var state := snapshot(context)
	var owner_key: Dictionary = state.owner_key
	if bool(state.disconnected) \
		or int(state.max_members) != context.expected_count \
		or int(state.access_policy) != 2 \
		or int(state.owner_migration) != 0 \
		or bool(state.restrict_invites_to_owner) \
		or owner_key.is_empty():
		_settle_scoped_operation(
			operation,
			PartyResult.Outcome.INVALID,
			&"arranged_configuration_mismatch",
			"The arranged lobby configuration did not match the four-player private profile.")
		await leave_lobby(context)
		_finish_scoped_operation(operation, context, operation.outcome)
		return
	context.owner_key = owner_key.duplicate()
	_finish_scoped_operation(operation, context, PartyResult.Outcome.OK)


func prepare_transport(
	context: LobbyContext,
	user: Variant,
	deadline_msec: int = 0
) -> PartyResult:
	if not _context_is_current(context) or context.kind != LOBBY_KIND_ARRANGED \
		or context.lobby == null or not _context_local_is_owner(context) \
		or context.expected_count != MatchmakingService.EXPECTED_MATCH_COUNT:
		return _context_failure(
			PartyResult.Outcome.INVALID,
			&"arranged_transport_not_owner",
			"Only the arranged lobby owner may create its Party network.",
			context)
	if _network != null:
		return _context_failure(
			PartyResult.Outcome.INVALID,
			&"transport_already_attached",
			"The previous Party transport must be left before creating the arranged network.",
			context)
	var operation := _begin_scoped_operation(
		context,
		&"prepare_transport",
		deadline_msec,
		ARRANGED_OPERATION_TIMEOUT)
	if operation == null:
		return _context_failure(
			PartyResult.Outcome.SUPERSEDED,
			&"scoped_operation_unavailable",
			"The previous online session is still being cleaned up.",
			context)
	_run_prepare_transport(context, user, operation)
	return await _await_scoped_operation(
		operation,
		context,
		&"arranged_transport_timeout",
		"Creating the arranged Party transport took too long.")


func _run_prepare_transport(
	context: LobbyContext,
	user: Variant,
	operation: ScopedOperation
) -> void:
	var ready_error := await _ensure_context_initialized(
		context, operation.deadline_msec, operation)
	if not _scoped_operation_current(context, operation):
		_finish_scoped_operation(
			operation,
			context,
			PartyResult.Outcome.SUPERSEDED,
			&"arranged_transport_superseded",
			"The arranged transport was replaced.")
		return
	if not ready_error.is_empty():
		_finish_scoped_operation(
			operation,
			context,
			PartyResult.Outcome.SERVICE_ERROR,
			&"playfab_initialization_failed",
			ready_error)
		return
	var cfg: Variant = _make_party_config(
		context.expected_count, MATCHMAKING_INVITATION_ID)
	var party: Variant = _party_sdk()
	if cfg == null or party == null:
		_finish_scoped_operation(
			operation,
			context,
			PartyResult.Outcome.INVALID,
			&"party_unavailable",
			"The PlayFab Party service is unavailable.")
		return
	await _chat.ensure_control(user, cfg, func() -> bool:
		return _scoped_operation_current(context, operation))
	if not _scoped_operation_current(context, operation):
		_finish_scoped_operation(
			operation,
			context,
			PartyResult.Outcome.SUPERSEDED,
			&"arranged_transport_superseded",
			"The arranged transport was replaced.")
		return
	var created: Variant = await party.create_and_join_network_async(user, cfg)
	if not _scoped_operation_current(context, operation):
		if _result_ok(created):
			await _leave_stale_network_instance(context, _result_data(created))
		_finish_scoped_operation(
			operation,
			context,
			PartyResult.Outcome.SUPERSEDED,
			&"arranged_transport_superseded",
			"The arranged transport was replaced.")
		return
	if not _result_ok(created):
		_finish_scoped_operation(
			operation,
			context,
			PartyResult.Outcome.SERVICE_ERROR,
			&"arranged_transport_create_failed",
			"Could not create the arranged Party network.",
			_reason(created))
		return
	if not _attach_context_transport(context, _result_data(created), true):
		await _leave_network_instance(_result_data(created))
		_finish_scoped_operation(
			operation,
			context,
			PartyResult.Outcome.INVALID,
			&"transport_already_attached",
			"Another Party transport is already attached.")
		return
	var descriptor := await _await_context_descriptor(
		context, operation.deadline_msec, operation.operation_id, operation)
	if descriptor.is_empty():
		var superseded := not _scoped_operation_current(context, operation)
		_settle_scoped_operation(
			operation,
			PartyResult.Outcome.SUPERSEDED if superseded else PartyResult.Outcome.TIMEOUT,
			&"arranged_transport_superseded" if superseded else &"party_descriptor_timeout",
			"The arranged transport was replaced." if superseded \
				else "The arranged Party network never published a connection descriptor.")
		await leave_transport(context)
		_finish_scoped_operation(operation, context, operation.outcome)
		return
	var permit := _issue_publication_permit(context)
	_finish_scoped_operation(
		operation,
		context,
		PartyResult.Outcome.OK,
		&"",
		"",
		"",
		permit)


func join_transport(
	context: LobbyContext,
	user: Variant,
	deadline_msec: int = 0
) -> PartyResult:
	if not _context_is_current(context) or context.kind != LOBBY_KIND_ARRANGED \
		or context.lobby == null \
		or context.expected_count != MatchmakingService.EXPECTED_MATCH_COUNT:
		return _context_failure(
			PartyResult.Outcome.INVALID,
			&"invalid_arranged_context",
			"The arranged lobby is no longer active.",
			context)
	if _network != null:
		return _context_failure(
			PartyResult.Outcome.INVALID,
			&"transport_already_attached",
			"The previous Party transport must be left before joining the arranged network.",
			context)
	var operation := _begin_scoped_operation(
		context,
		&"join_transport",
		deadline_msec,
		ARRANGED_HANDOFF_TIMEOUT)
	if operation == null:
		return _context_failure(
			PartyResult.Outcome.SUPERSEDED,
			&"scoped_operation_unavailable",
			"The previous online session is still being cleaned up.",
			context)
	_run_join_transport(context, user, operation)
	return await _await_scoped_operation(
		operation,
		context,
		&"arranged_transport_timeout",
		"Joining the arranged Party transport took too long.")


func _run_join_transport(
	context: LobbyContext,
	user: Variant,
	operation: ScopedOperation
) -> void:
	var ready_error := await _ensure_context_initialized(
		context, operation.deadline_msec, operation)
	if not _scoped_operation_current(context, operation):
		_finish_scoped_operation(
			operation,
			context,
			PartyResult.Outcome.SUPERSEDED,
			&"arranged_transport_superseded",
			"The arranged transport was replaced.")
		return
	if not ready_error.is_empty():
		_finish_scoped_operation(
			operation,
			context,
			PartyResult.Outcome.SERVICE_ERROR,
			&"playfab_initialization_failed",
			ready_error)
		return
	var transport := await _await_context_transport_properties(
		context, operation.deadline_msec, operation.operation_id, operation)
	if not transport.ok():
		_finish_scoped_operation(
			operation,
			context,
			transport.outcome,
			transport.reason_code,
			transport.reason,
			transport.diagnostic)
		return
	var cfg: Variant = _make_party_config(0, MATCHMAKING_INVITATION_ID)
	var party: Variant = _party_sdk()
	if cfg == null or party == null:
		_finish_scoped_operation(
			operation,
			context,
			PartyResult.Outcome.INVALID,
			&"party_unavailable",
			"The PlayFab Party service is unavailable.")
		return
	await _chat.ensure_control(user, cfg, func() -> bool:
		return _scoped_operation_current(context, operation))
	if not _scoped_operation_current(context, operation):
		_finish_scoped_operation(
			operation,
			context,
			PartyResult.Outcome.SUPERSEDED,
			&"arranged_transport_superseded",
			"The arranged transport was replaced.")
		return
	var joined: Variant = await party.join_network_async(user, transport.descriptor, cfg)
	if not _scoped_operation_current(context, operation):
		if _result_ok(joined):
			await _leave_stale_network_instance(context, _result_data(joined))
		_finish_scoped_operation(
			operation,
			context,
			PartyResult.Outcome.SUPERSEDED,
			&"arranged_transport_superseded",
			"The arranged transport was replaced.")
		return
	if not _result_ok(joined):
		_finish_scoped_operation(
			operation,
			context,
			PartyResult.Outcome.SERVICE_ERROR,
			&"arranged_transport_join_failed",
			"Could not join the arranged Party network.",
			_reason(joined))
		return
	if not _attach_context_transport(context, _result_data(joined), false):
		await _leave_network_instance(_result_data(joined))
		_finish_scoped_operation(
			operation,
			context,
			PartyResult.Outcome.INVALID,
			&"transport_already_attached",
			"Another Party transport is already attached.")
		return
	_finish_scoped_operation(operation, context, PartyResult.Outcome.OK)


func set_context_locked(
	context: LobbyContext,
	locked: bool,
	deadline_msec: int = 0
) -> PartyResult:
	if not _context_is_current(context) or context.lobby == null \
		or _lobby_is_disconnected(context.lobby):
		return _context_failure(
			PartyResult.Outcome.INVALID,
			&"context_unavailable",
			"The PlayFab lobby is no longer available.",
			context)
	if not _context_local_is_owner(context):
		return _context_failure(
			PartyResult.Outcome.INVALID,
			&"context_not_owner",
			"Only the PlayFab lobby owner may change its membership lock.",
			context)
	var operation := _begin_scoped_operation(
		context, &"set_context_locked", deadline_msec, LOBBY_LOCK_TIMEOUT)
	if operation == null:
		return _context_failure(
			PartyResult.Outcome.SUPERSEDED,
			&"scoped_operation_unavailable",
			"The previous online session is still being cleaned up.",
			context)
	_run_context_lock(context, locked, operation)
	return await _await_scoped_operation(
		operation,
		context,
		&"context_lock_timeout",
		"The match service did not confirm the membership lock in time.")


func post_context_update(
	context: LobbyContext,
	lobby_properties: Dictionary,
	search_properties: Dictionary,
	member_properties: Dictionary,
	deadline_msec: int = 0
) -> PartyResult:
	return await _post_context_update_checked(
		context,
		lobby_properties,
		search_properties,
		member_properties,
		deadline_msec,
		0)


func _post_context_update_checked(
	context: LobbyContext,
	lobby_properties: Dictionary,
	search_properties: Dictionary,
	member_properties: Dictionary,
	deadline_msec: int,
	required_permit: int
) -> PartyResult:
	if not _context_is_current(context) or context.lobby == null:
		return _context_failure(
			PartyResult.Outcome.INVALID,
			&"context_unavailable",
			"The PlayFab lobby is no longer available.",
			context)
	if context.kind == LOBBY_KIND_ARRANGED \
		and (lobby_properties.has(MATCH_ID_MEMBER_KEY)
			or lobby_properties.has(ROUND_GENERATION_KEY)
			or lobby_properties.has(SESSION_PHASE_KEY)) \
		and not bool(decode_arranged_control(lobby_properties).get("valid", false)):
		return _context_failure(
			PartyResult.Outcome.INVALID,
			&"arranged_control_invalid",
			"Arranged state updates need a valid match id, round, and phase.",
			context)
	if (not lobby_properties.is_empty() or not search_properties.is_empty()) \
		and not _context_local_is_owner(context):
		return _context_failure(
			PartyResult.Outcome.INVALID,
			&"context_not_owner",
			"Only the PlayFab lobby owner may update shared lobby state.",
			context)
	var requires_owner := not lobby_properties.is_empty() or not search_properties.is_empty()
	var update_error := _context_operation_error(context, requires_owner)
	if update_error != null:
		return update_error
	var operation := _begin_scoped_operation(
		context, &"post_context_update", deadline_msec, LOBBY_LOCK_TIMEOUT)
	if operation == null:
		return _context_failure(
			PartyResult.Outcome.SUPERSEDED,
			&"scoped_operation_unavailable",
			"The previous online session is still being cleaned up.",
			context)
	operation.required_permit = required_permit
	_run_context_update(
		context,
		lobby_properties.duplicate(true),
		search_properties.duplicate(true),
		member_properties.duplicate(true),
		operation)
	return await _await_scoped_operation(
		operation,
		context,
		&"context_update_timeout",
		"The match service did not confirm the lobby update in time.")


func leave_lobby(context: LobbyContext) -> PartyResult:
	if context == null:
		return _context_failure(
			PartyResult.Outcome.INVALID,
			&"invalid_context",
			"No scoped lobby was supplied.")
	if context.lobby_leave_running:
		var coalesced: Variant = await context.lobby_leave_finished
		if coalesced is PartyResult:
			return coalesced as PartyResult
		return _context_failure(
			PartyResult.Outcome.SERVICE_ERROR,
			&"scoped_lobby_leave_missing_result",
			"The scoped lobby leave returned no result.",
			context)
	_retire_context_operations(context)
	context.operation_id += 1
	context.active_permit = 0
	if context.left_lobby or context.lobby == null:
		context.left_lobby = true
		_retire_context_if_empty(context)
		return _context_success(context)
	context.active_permit = 0
	context.lock_operation += 1
	context.post_operation += 1
	context.lock_running = false
	context.post_running = false
	context.lock_result = null
	context.post_result = null
	var lobby: Variant = context.lobby
	var leave_epoch := context.recovery_epoch
	_disconnect_context_lobby(context)
	context.lobby = null
	context.left_lobby = true
	context.lobby_leave_running = true
	_refresh_context_cleanup(context)
	if context.local_user != null and bool(lobby.is_owner(context.local_user)):
		var properties_value: Variant = _object_value(lobby, &"properties", {})
		if typeof(properties_value) == TYPE_DICTIONARY \
			and not String((properties_value as Dictionary).get(DESCRIPTOR_KEY, "")).is_empty():
			var cleared: Variant = await lobby.set_properties_async({DESCRIPTOR_KEY: ""})
			if not _result_ok(cleared):
				push_warning("[Party] Clearing a scoped descriptor failed: %s" % _reason(cleared))
	var result: Variant = await lobby.leave_async()
	if leave_epoch != _scoped_recovery_epoch:
		return _context_success(context)
	context.lobby_leave_running = false
	_refresh_context_cleanup(context)
	if not _result_ok(result):
		_cleanup_failed = true
		push_warning("[Party] Leaving scoped lobby failed: %s" % _reason(result))
		_retire_context_if_empty(context)
		var failed := _context_failure(
			PartyResult.Outcome.SERVICE_ERROR,
			&"scoped_lobby_leave_failed",
			"The PlayFab lobby did not confirm that it was left.",
			context,
			_reason(result))
		context.lobby_leave_finished.emit(failed)
		return failed
	_retire_context_if_empty(context)
	var succeeded := _context_success(context)
	context.lobby_leave_finished.emit(succeeded)
	return succeeded


func leave_transport(context: LobbyContext) -> PartyResult:
	if context == null:
		return _context_failure(
			PartyResult.Outcome.INVALID,
			&"invalid_context",
			"No scoped Party transport was supplied.")
	if context.transport_leave_running:
		var coalesced: Variant = await context.transport_leave_finished
		if coalesced is PartyResult:
			return coalesced as PartyResult
		return _context_failure(
			PartyResult.Outcome.SERVICE_ERROR,
			&"scoped_transport_leave_missing_result",
			"The scoped Party transport leave returned no result.",
			context)
	_retire_context_operations(context)
	context.operation_id += 1
	context.active_permit = 0
	if context.left_transport or context.network == null:
		context.left_transport = true
		_retire_context_if_empty(context)
		return _context_success(context)
	var network: Variant = context.network
	var leave_epoch := context.recovery_epoch
	_disconnect_context_transport(context)
	context.network = null
	context.peer = null
	context.left_transport = true
	context.transport_leave_running = true
	_refresh_context_cleanup(context)
	var result: Variant = await network.leave_async()
	if leave_epoch != _scoped_recovery_epoch:
		return _context_success(context)
	context.transport_leave_running = false
	_refresh_context_cleanup(context)
	if not _result_ok(result):
		_cleanup_failed = true
		push_warning("[Party] Leaving scoped Party transport failed: %s" % _reason(result))
		_retire_context_if_empty(context)
		var failed := _context_failure(
			PartyResult.Outcome.SERVICE_ERROR,
			&"scoped_transport_leave_failed",
			"The Party transport did not confirm that it was left.",
			context,
			_reason(result))
		context.transport_leave_finished.emit(failed)
		return failed
	_retire_context_if_empty(context)
	var succeeded := _context_success(context)
	context.transport_leave_finished.emit(succeeded)
	return succeeded


func snapshot(context: LobbyContext) -> Dictionary:
	if not _context_is_live(context):
		return _empty_context_snapshot()
	var lobby: Variant = context.lobby
	if lobby == null:
		return _empty_context_snapshot()
	var members: Array[Dictionary] = []
	var native_members: Variant = _object_value(lobby, &"members", [])
	if typeof(native_members) == TYPE_ARRAY:
		for member: Variant in native_members:
			if member == null:
				continue
			var key_value: Variant = _object_value(member, &"entity_key", {})
			var key := _copy_entity_key(key_value as Dictionary) \
				if typeof(key_value) == TYPE_DICTIONARY else {}
			if key.is_empty():
				continue
			var properties_value: Variant = _object_value(member, &"properties", {})
			members.append({
				"key": key,
				"connected": int(_object_value(member, &"connection_status", 0)) == 1,
				"properties": (properties_value as Dictionary).duplicate(true)
					if typeof(properties_value) == TYPE_DICTIONARY else {},
			})
	var properties_value: Variant = _object_value(lobby, &"properties", {})
	var search_value: Variant = _object_value(lobby, &"search_properties", {})
	var properties: Dictionary = (properties_value as Dictionary).duplicate(true) \
		if typeof(properties_value) == TYPE_DICTIONARY else {}
	var search_properties: Dictionary = (search_value as Dictionary).duplicate(true) \
		if typeof(search_value) == TYPE_DICTIONARY else {}
	var owner_value: Variant = _object_value(lobby, &"owner_entity_key", {})
	var owner_key := _copy_entity_key(owner_value as Dictionary) \
		if typeof(owner_value) == TYPE_DICTIONARY else {}
	return {
		"context_id": context.context_id,
		"role": String(context.role),
		"kind": context.kind,
		"recovery_epoch": context.recovery_epoch,
		"expected_count": context.expected_count,
		"lobby_id": String(_object_value(lobby, &"lobby_id", "")),
		"local_key": context.local_key.duplicate(),
		"owner_key": owner_key,
		"is_local_owner": _context_local_is_owner(context),
		"members": members,
		"max_members": int(_object_value(lobby, &"max_member_count", 0)),
		"access_policy": int(_object_value(lobby, &"access_policy", -1)),
		"owner_migration": int(_object_value(lobby, &"owner_migration_policy", -1)),
		"restrict_invites_to_owner": bool(_object_value(
			lobby, &"restrict_invites_to_lobby_owner", true)),
		"membership_locked": int(_object_value(lobby, &"membership_lock", 0))
			== MEMBERSHIP_LOCK_LOCKED,
		"disconnected": _lobby_is_disconnected(lobby),
		"search_properties": search_properties,
		"properties": properties,
		"phase": String(properties.get(SESSION_PHASE_KEY, "")),
		"search_control": decode_search_control(String(properties.get(SEARCH_CONTROL_KEY, ""))),
		"arranged_control": decode_arranged_control(properties),
	}


func admission_proof(context: LobbyContext, peer_id: int) -> Dictionary:
	var proof := {
		"valid": false,
		"pending": false,
		"reason_code": "context_unavailable",
		"context_id": context.context_id if context != null else 0,
		"recovery_epoch": context.recovery_epoch if context != null else -1,
		"peer_id": peer_id,
		"entity_key": {},
		"native_present": false,
		"native_connected": false,
		"member_properties": {},
		"owner_key": {},
		"expected_count": context.expected_count if context != null else 0,
		"local_creator": context.local_creator if context != null else false,
		"transport_attached": false,
	}
	if not _context_is_current(context) or context.peer == null \
		or context != _attached_context or context.network == null:
		return proof
	proof["transport_attached"] = true
	if not (context.peer is MultiplayerPeer) \
		or context.peer.get_connection_status() != MultiplayerPeer.CONNECTION_CONNECTED:
		proof["reason_code"] = "transport_unavailable"
		return proof
	var raw_key: Variant = context.peer.get_peer_entity_key(peer_id)
	var entity_key := _copy_entity_key(raw_key as Dictionary) \
		if typeof(raw_key) == TYPE_DICTIONARY else {}
	proof["entity_key"] = entity_key
	if entity_key.is_empty():
		proof["reason_code"] = "party_identity_missing"
		return proof
	var state := snapshot(context)
	var state_owner: Dictionary = state.owner_key
	proof["owner_key"] = state_owner.duplicate()
	if not context.owner_key.is_empty() \
		and not _entity_keys_match(context.owner_key, state_owner):
		proof["reason_code"] = "owner_changed"
		return proof
	var members: Array = state.members
	for member_value: Variant in members:
		if typeof(member_value) != TYPE_DICTIONARY:
			continue
		var member := member_value as Dictionary
		var member_key_value: Variant = member.get("key", {})
		var member_key := _copy_entity_key(member_key_value as Dictionary) \
			if typeof(member_key_value) == TYPE_DICTIONARY else {}
		if not _entity_keys_match(member_key, entity_key):
			continue
		proof["native_present"] = true
		proof["native_connected"] = bool(member.get("connected", false))
		var properties_value: Variant = member.get("properties", {})
		proof["member_properties"] = (properties_value as Dictionary).duplicate(true) \
			if typeof(properties_value) == TYPE_DICTIONARY else {}
		if not bool(proof["native_connected"]):
			proof["reason_code"] = "native_member_disconnected"
			return proof
		proof["valid"] = true
		proof["reason_code"] = ""
		return proof
	proof["pending"] = members.size() < context.expected_count
	proof["reason_code"] = "native_member_pending" if bool(proof["pending"]) \
		else "native_member_missing"
	return proof


func context_is_quiescent(context: LobbyContext) -> bool:
	if context == null or context.service_owner == null:
		return false
	var owner: Variant = context.service_owner.get_ref()
	if owner != self:
		return false
	if context.recovery_epoch < _scoped_recovery_epoch:
		return true
	if context.recovery_epoch != _scoped_recovery_epoch \
		or _contexts.get(context.context_id) == context \
		or not context.retired \
		or context.pending_operations > 0 \
		or context.cleanup_pending \
		or context.lobby_leave_running \
		or context.transport_leave_running \
		or context.lobby != null \
		or context.network != null:
		return false
	for operation_value: Variant in _scoped_operations.values():
		var operation := operation_value as ScopedOperation
		if operation != null and operation.context_id == context.context_id:
			return false
	return true


func has_owned_work() -> bool:
	return not _contexts.is_empty() or _owned_operation_count > 0 \
		or not _scoped_operations.is_empty()


func drain_owned_work(deadline_msec: int) -> void:
	while has_owned_work() and (deadline_msec <= 0 or _context_now_msec(_clock) < deadline_msec):
		await _sleep_with_clock(_clock, POLL_INTERVAL)


static func encode_search_control(envelope: Dictionary) -> String:
	var epoch := int(envelope.get("epoch", 0))
	var phase := String(envelope.get("phase", "")).strip_edges()
	var raw_group: Variant = envelope.get("group", [])
	if epoch <= 0 or phase.is_empty() or typeof(raw_group) != TYPE_ARRAY:
		return ""
	var group: Array[Dictionary] = []
	var seen: Dictionary = {}
	for raw_key: Variant in raw_group:
		if typeof(raw_key) != TYPE_DICTIONARY:
			return ""
		var key := _copy_entity_key(raw_key as Dictionary)
		if key.is_empty():
			return ""
		var fingerprint: String = "%s\u001f%s" % [key.id, key.type]
		if seen.has(fingerprint):
			return ""
		seen[fingerprint] = true
		group.append(key)
	group.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		return ("%s\u001f%s" % [a.id, a.type]) \
			< ("%s\u001f%s" % [b.id, b.type]))
	var normalized := {
		"schema": SEARCH_CONTROL_SCHEMA,
		"epoch": epoch,
		"phase": phase,
		"group": group,
	}
	for optional_key: String in ["ticket_id", "reason_code", "reason"]:
		var value := String(envelope.get(optional_key, ""))
		if not value.is_empty():
			normalized[optional_key] = value
	return JSON.stringify(normalized)


static func decode_search_control(text: String) -> Dictionary:
	if text.strip_edges().is_empty():
		return {"valid": false}
	var parsed: Variant = JSON.parse_string(text)
	if typeof(parsed) != TYPE_DICTIONARY:
		return {"valid": false}
	var envelope := parsed as Dictionary
	if int(envelope.get("schema", 0)) != SEARCH_CONTROL_SCHEMA:
		return {"valid": false}
	var epoch := int(envelope.get("epoch", 0))
	var phase := String(envelope.get("phase", ""))
	var group: Variant = envelope.get("group", [])
	if epoch <= 0 or phase.is_empty() or typeof(group) != TYPE_ARRAY:
		return {"valid": false}
	var normalized_group: Array[Dictionary] = []
	var seen: Dictionary = {}
	for raw_key: Variant in group:
		if typeof(raw_key) != TYPE_DICTIONARY:
			return {"valid": false}
		var key := _copy_entity_key(raw_key as Dictionary)
		if key.is_empty():
			return {"valid": false}
		var fingerprint: String = "%s\u001f%s" % [key.id, key.type]
		if seen.has(fingerprint):
			return {"valid": false}
		seen[fingerprint] = true
		normalized_group.append(key)
	normalized_group.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		return ("%s\u001f%s" % [a.id, a.type]) \
			< ("%s\u001f%s" % [b.id, b.type]))
	return {
		"valid": true,
		"schema": SEARCH_CONTROL_SCHEMA,
		"epoch": epoch,
		"phase": phase,
		"group": normalized_group,
		"ticket_id": String(envelope.get("ticket_id", "")),
		"reason_code": String(envelope.get("reason_code", "")),
		"reason": String(envelope.get("reason", "")),
	}


static func encode_arranged_control(match_id: String, round: int, phase: String) -> Dictionary:
	var normalized_match_id := match_id.strip_edges()
	var normalized_phase := phase.strip_edges()
	if normalized_match_id.is_empty() or round < 0 \
		or normalized_phase not in [
			ARRANGED_PHASE_BOOTSTRAP,
			ARRANGED_PHASE_GAMEPLAY,
			ARRANGED_PHASE_REMATCH,
		]:
		return {}
	return {
		MATCH_ID_MEMBER_KEY: normalized_match_id,
		ROUND_GENERATION_KEY: str(round),
		SESSION_PHASE_KEY: normalized_phase,
	}


static func decode_arranged_control(properties: Dictionary) -> Dictionary:
	var match_id := String(properties.get(MATCH_ID_MEMBER_KEY, "")).strip_edges()
	var round_text := String(properties.get(ROUND_GENERATION_KEY, "")).strip_edges()
	var phase := String(properties.get(SESSION_PHASE_KEY, "")).strip_edges()
	if match_id.is_empty() or not round_text.is_valid_int() \
		or phase not in [
			ARRANGED_PHASE_BOOTSTRAP,
			ARRANGED_PHASE_GAMEPLAY,
			ARRANGED_PHASE_REMATCH,
		]:
		return {"valid": false}
	var round := int(round_text)
	if round < 0 or round_text != str(round):
		return {"valid": false}
	return {
		"valid": true,
		"match_id": match_id,
		"round": round,
		"phase": phase,
	}


func _new_context(
	role: StringName,
	kind: String,
	user: Variant,
	account_generation: int,
	flow_epoch: int
) -> LobbyContext:
	var context := LobbyContext.new()
	context.context_id = _next_context_id
	_next_context_id += 1
	context.service_owner = weakref(self)
	context.role = role
	context.kind = kind
	context.local_user = user
	context.local_key = _user_entity_key(user)
	context.account_generation = account_generation
	context.flow_epoch = flow_epoch
	context.recovery_epoch = _scoped_recovery_epoch
	context.operation_id = _next_context_operation
	_next_context_operation += 1
	context.clock = _clock
	_contexts[context.context_id] = context
	return context


func _begin_scoped_operation(
	context: LobbyContext,
	kind: StringName,
	deadline_msec: int,
	default_seconds: float
) -> ScopedOperation:
	if context == null or not _context_is_current(context) or _leaving or _recovering \
		or not recovery_error.is_empty():
		return null
	var operation := ScopedOperation.new()
	operation.id = _next_scoped_operation_id
	_next_scoped_operation_id += 1
	operation.context_id = context.context_id
	operation.account_generation = context.account_generation
	operation.flow_epoch = context.flow_epoch
	operation.recovery_epoch = context.recovery_epoch
	operation.operation_id = context.operation_id
	operation.deadline_msec = _bounded_deadline(
		context.clock, deadline_msec, default_seconds)
	operation.clock = context.clock if context.clock != null else OnlineFlowClock.new()
	operation.kind = kind
	operation.cleanup_pending = true
	_scoped_operations[operation.id] = operation
	_begin_owned_call(context)
	return operation


func retire_scoped_operation(operation: ScopedOperation) -> void:
	if operation == null or operation.retired:
		return
	operation.retired = true
	if not operation.settled:
		_settle_scoped_operation(
			operation,
			PartyResult.Outcome.SUPERSEDED,
			&"scoped_operation_retired",
			"The online operation was replaced.")


func _retire_context_operations(context: LobbyContext) -> void:
	if context == null:
		return
	for operation_value: Variant in _scoped_operations.values().duplicate():
		var operation := operation_value as ScopedOperation
		if operation != null and operation.context_id == context.context_id:
			retire_scoped_operation(operation)


func _await_scoped_operation(
	operation: ScopedOperation,
	context: LobbyContext,
	timeout_code: StringName,
	timeout_reason: String
) -> PartyResult:
	if operation == null:
		return _context_failure(
			PartyResult.Outcome.SUPERSEDED,
			&"scoped_operation_unavailable",
			"The previous online session is still being cleaned up.",
			context)
	operation.timeout_reason_code = timeout_code
	operation.timeout_reason = timeout_reason
	if not operation.settled:
		operation.deadline_alarm = operation.clock.alarm_at(
			operation.deadline_msec,
			_on_scoped_operation_deadline.bind(operation.id))
		await operation.settled_changed
	return _scoped_operation_result(operation, context)


func _on_scoped_operation_deadline(operation_id: int) -> void:
	var operation: ScopedOperation = _scoped_operations.get(operation_id) as ScopedOperation
	if operation == null or operation.settled:
		return
	operation.deadline_alarm = null
	operation.retired = true
	_settle_scoped_operation(
		operation,
		PartyResult.Outcome.TIMEOUT,
		operation.timeout_reason_code,
		operation.timeout_reason)


func _settle_scoped_operation(
	operation: ScopedOperation,
	outcome: int,
	code: StringName = &"",
	message: String = "",
	diagnostic: String = "",
	permit: int = 0
) -> void:
	if operation == null or operation.settled:
		return
	operation.outcome = outcome
	operation.reason_code = code
	operation.reason = message
	operation.diagnostic = diagnostic
	operation.publication_permit = permit
	operation.settled = true
	if operation.deadline_alarm != null:
		if operation.deadline_alarm.has_method("cancel"):
			operation.deadline_alarm.cancel()
		operation.deadline_alarm = null
	operation.settled_changed.emit(operation)


func _finish_scoped_operation(
	operation: ScopedOperation,
	context: LobbyContext,
	outcome: int,
	code: StringName = &"",
	message: String = "",
	diagnostic: String = "",
	permit: int = 0
) -> void:
	if operation == null:
		return
	var should_settle := not operation.settled
	operation.native_done = true
	if operation.cleanup_pending:
		operation.cleanup_pending = false
		operation.cleanup_changed.emit(operation)
	if _scoped_operations.get(operation.id) == operation:
		_scoped_operations.erase(operation.id)
	_end_owned_call(context)
	if should_settle:
		_settle_scoped_operation(operation, outcome, code, message, diagnostic, permit)


func _scoped_operation_result(
	operation: ScopedOperation,
	context: LobbyContext
) -> PartyResult:
	var result := PartyResult.new()
	result.outcome = operation.outcome
	result.reason_code = operation.reason_code
	result.reason = operation.reason
	result.diagnostic = operation.diagnostic
	result.context = context
	result.peer = context.peer if context != null else null
	result.owner_key = snapshot(context).owner_key \
		if context != null and context.lobby != null else {}
	result.local_creator = context.local_creator if context != null else false
	result.descriptor_ready = context != null and context.network != null \
		and not String(_object_value(context.network, &"descriptor", "")).is_empty()
	result.descriptor = String(_object_value(context.network, &"descriptor", "")) \
		if context != null and context.network != null else ""
	result.publication_permit = operation.publication_permit
	result.cleanup_pending = operation.cleanup_pending
	result.operation = operation
	return result


func _scoped_operation_current(
	context: LobbyContext,
	operation: ScopedOperation
) -> bool:
	return context != null and operation != null and not operation.retired \
		and operation.recovery_epoch == _scoped_recovery_epoch \
		and operation.account_generation == context.account_generation \
		and operation.flow_epoch == context.flow_epoch \
		and operation.operation_id == context.operation_id \
		and _scoped_operations.get(operation.id) == operation \
		and _context_is_current(context)


func _discard_context(context: LobbyContext) -> void:
	if context == null:
		return
	context.retired = true
	context.active_permit = 0
	_disconnect_context_lobby(context)
	_disconnect_context_transport(context)
	context.lock_result = null
	context.post_result = null
	context.lobby_callback = Callable()
	context.network_callback = Callable()
	if context.pending_operations == 0 and _contexts.get(context.context_id) == context:
		_contexts.erase(context.context_id)
		_owned_work_changed.emit()


func _retire_context_if_empty(context: LobbyContext) -> void:
	if context == null or context.cleanup_pending \
		or context.lobby_leave_running or context.transport_leave_running \
		or context.pending_operations > 0:
		return
	if context.lobby != null or context.network != null:
		return
	context.retired = true
	context.active_permit = 0
	context.lock_result = null
	context.post_result = null
	context.lobby_callback = Callable()
	context.network_callback = Callable()
	if _contexts.get(context.context_id) == context:
		_contexts.erase(context.context_id)
		_owned_work_changed.emit()


func _refresh_context_cleanup(context: LobbyContext) -> void:
	if context == null:
		return
	context.cleanup_pending = context.lobby_leave_running or context.transport_leave_running


func _complete_scoped_recovery() -> void:
	var retired_epoch := _scoped_recovery_epoch
	_scoped_recovery_epoch += 1
	for operation_value: Variant in _scoped_operations.values().duplicate():
		var operation := operation_value as ScopedOperation
		if operation == null or operation.recovery_epoch > retired_epoch:
			continue
		operation.retired = true
		var should_settle := not operation.settled
		operation.native_done = true
		if operation.cleanup_pending:
			operation.cleanup_pending = false
			operation.cleanup_changed.emit(operation)
		_scoped_operations.erase(operation.id)
		if should_settle:
			_settle_scoped_operation(
				operation,
				PartyResult.Outcome.SUPERSEDED,
				&"multiplayer_invalidated",
				"The multiplayer runtime was reset.")
	_owned_operation_count = 0
	for context_value: Variant in _contexts.values().duplicate():
		var context := context_value as LobbyContext
		if context != null and context.recovery_epoch <= retired_epoch:
			_invalidate_context_after_recovery(context)
	_owned_work_changed.emit()


func _invalidate_context_after_recovery(context: LobbyContext) -> void:
	if context == null:
		return
	var result := _context_success(context)
	context.retired = true
	context.operation_id += 1
	context.active_permit = 0
	context.left_lobby = true
	context.left_transport = true
	context.cleanup_pending = false
	context.lock_running = false
	context.post_running = false
	context.lock_result = null
	context.post_result = null
	_disconnect_context_lobby(context)
	_disconnect_context_transport(context)
	context.lobby = null
	context.network = null
	context.peer = null
	if _contexts.get(context.context_id) == context:
		_contexts.erase(context.context_id)
	if context.lobby_leave_running:
		context.lobby_leave_running = false
		context.lobby_leave_finished.emit(result)
	if context.transport_leave_running:
		context.transport_leave_running = false
		context.transport_leave_finished.emit(result)
	context.lobby_callback = Callable()
	context.network_callback = Callable()


func _begin_owned_call(context: LobbyContext) -> int:
	if context == null or context.recovery_epoch != _scoped_recovery_epoch:
		return 0
	context.pending_operations += 1
	_owned_operation_count += 1
	return context.operation_id


func _end_owned_call(context: LobbyContext) -> void:
	if context != null:
		context.pending_operations = maxi(context.pending_operations - 1, 0)
		if context.recovery_epoch == _scoped_recovery_epoch:
			_owned_operation_count = maxi(_owned_operation_count - 1, 0)
	if context != null and context.recovery_epoch == _scoped_recovery_epoch:
		_retire_context_if_empty(context)
	_owned_work_changed.emit()


func _captured_contexts_quiescent(contexts: Array) -> bool:
	for context_value: Variant in contexts:
		var context := context_value as LobbyContext
		if context == null:
			continue
		if _contexts.get(context.context_id) == context:
			return false
		if context.pending_operations > 0 or context.cleanup_pending \
			or context.lobby_leave_running or context.transport_leave_running:
			return false
	return true


func _context_operation_current(context: LobbyContext, operation: int) -> bool:
	return operation > 0 and context != null \
		and context.recovery_epoch == _scoped_recovery_epoch \
		and _context_is_current(context) and context.operation_id == operation


func _context_is_current(context: LobbyContext) -> bool:
	return _context_is_live(context) and _account_is_current(context.account_generation)


func _attach_context_lobby(context: LobbyContext, lobby: Variant) -> void:
	if context == null or lobby == null:
		return
	context.lobby = lobby
	context.left_lobby = false
	context.loss_emitted = false
	if context.expected_count <= 0:
		context.expected_count = int(_object_value(lobby, &"max_member_count", 0))
	var callback := Callable(self, "_on_context_lobby_changed").bind(context)
	context.lobby_callback = callback
	if lobby.has_signal("state_changed") and not lobby.is_connected("state_changed", callback):
		lobby.connect("state_changed", callback)
	var owner_value: Variant = _object_value(lobby, &"owner_entity_key", {})
	context.owner_key = _copy_entity_key(owner_value as Dictionary) \
		if typeof(owner_value) == TYPE_DICTIONARY else {}


func _disconnect_context_lobby(context: LobbyContext) -> void:
	if context == null or context.lobby == null or not context.lobby_callback.is_valid():
		return
	if context.lobby.has_signal("state_changed") \
		and context.lobby.is_connected("state_changed", context.lobby_callback):
		context.lobby.disconnect("state_changed", context.lobby_callback)
	context.lobby_callback = Callable()


func _attach_context_transport(
	context: LobbyContext,
	network: Variant,
	local_creator: bool
) -> bool:
	if context == null or network == null:
		return false
	if _network != null:
		return false
	var candidate_peer: Variant = _object_value(network, &"local_peer", null)
	if not (candidate_peer is MultiplayerPeer) \
		or candidate_peer.get_connection_status() != MultiplayerPeer.CONNECTION_CONNECTED:
		return false
	context.network = network
	context.peer = candidate_peer
	context.local_creator = local_creator
	context.left_transport = false
	var callback := Callable(self, "_on_context_network_state_changed").bind(context)
	context.network_callback = callback
	if network.has_signal("state_changed") and not network.is_connected("state_changed", callback):
		network.connect("state_changed", callback)
	_attached_context = context
	_network = network
	_peer = context.peer
	_is_host = local_creator
	return true


func _disconnect_context_transport(context: LobbyContext) -> void:
	if context == null:
		return
	if context.network != null and context.network_callback.is_valid() \
		and context.network.has_signal("state_changed") \
		and context.network.is_connected("state_changed", context.network_callback):
		context.network.disconnect("state_changed", context.network_callback)
	context.network_callback = Callable()
	if _attached_context == context:
		_attached_context = null
		_network = null
		_peer = null
		_is_host = false


func _on_context_lobby_changed(change: Variant, context: LobbyContext) -> void:
	if not _context_is_live(context):
		return
	var kind := int(_object_value(change, &"kind", -1))
	var owner_value: Variant = _object_value(context.lobby, &"owner_entity_key", {})
	var current_owner := _copy_entity_key(owner_value as Dictionary) \
		if typeof(owner_value) == TYPE_DICTIONARY else {}
	if context.owner_key.is_empty() and not current_owner.is_empty():
		context.owner_key = current_owner.duplicate()
	elif not context.owner_key.is_empty() \
		and not _entity_keys_match(context.owner_key, current_owner):
		_emit_context_lost(
			context,
			"The PlayFab lobby owner changed, so this online session can no longer continue.")
		return
	if kind == LOBBY_CHANGE_DISCONNECTED:
		var result: Variant = _object_value(change, &"result", null)
		if not _result_ok(result):
			push_warning("[Party] Scoped lobby disconnected: %s" % _reason(result))
		_disconnect_context_lobby(context)
		context.lobby = null
		context.left_lobby = true
		_emit_context_lost(
			context,
			"The matchmaking lobby connection was lost.")
		return
	context_updated.emit(context)


func _emit_context_lost(context: LobbyContext, reason: String) -> void:
	if context == null or context.loss_emitted or _leaving or _recovering \
		or context.recovery_epoch != _scoped_recovery_epoch:
		return
	context.loss_emitted = true
	_retire_context_operations(context)
	context.operation_id += 1
	context.active_permit = 0
	context_lost.emit(reason, context)


func _on_context_network_state_changed(change: Variant, context: LobbyContext) -> void:
	if change == null or not _context_is_live(context):
		return
	var kind := int(_object_value(change, &"kind", -1))
	match _network_changes.find_key(kind):
		&"NETWORK_CHANGE_STATE":
			var state := int(_object_value(change, &"state", -1))
			if state == NETWORK_STATE_DISCONNECTED or state == NETWORK_STATE_FAILED:
				var reason := _change_reason(change)
				_disconnect_context_transport(context)
				context.network = null
				context.peer = null
				network_lost.emit(
					reason if not reason.is_empty() else "The match connection was lost.",
					context)
		&"NETWORK_CHANGE_PEER_JOINED":
			peer_joined.emit(int(_object_value(change, &"peer_id", 0)))
		&"NETWORK_CHANGE_PEER_LEFT":
			peer_left.emit(int(_object_value(change, &"peer_id", 0)))
		&"NETWORK_CHANGE_DESCRIPTOR_UPDATED":
			if context.active_permit > 0 and context.local_creator:
				_republish_context_descriptor(context)
		&"NETWORK_CHANGE_DESTROYED":
			var reason := _change_reason(change)
			_disconnect_context_transport(context)
			context.network = null
			context.peer = null
			network_lost.emit(
				reason if not reason.is_empty() else "The match connection was closed.",
				context)
		&"NETWORK_CHANGE_ERROR":
			party_failed.emit(_reason(_object_value(change, &"result", null)), context)


func _republish_context_descriptor(context: LobbyContext) -> void:
	if not _context_is_current(context) or context.active_permit <= 0 \
		or context.published_phase.is_empty():
		return
	await publish_transport(
		context,
		context.active_permit,
		context.published_phase,
		context.published_lobby_properties,
		context.published_search_properties)


func _issue_publication_permit(context: LobbyContext) -> int:
	var permit := _next_publication_permit
	_next_publication_permit += 1
	context.active_permit = permit
	return permit


func _ensure_context_initialized(
	context: LobbyContext,
	deadline_msec: int,
	scoped_operation: ScopedOperation = null
) -> String:
	var operation := context.operation_id
	if not _context_operation_current(context, operation) \
		or (scoped_operation != null \
			and not _scoped_operation_current(context, scoped_operation)):
		return "Session cancelled."
	var pf: Variant = _playfab()
	if pf == null:
		return "The PlayFab extension is not installed in this build."
	if not bool(pf.is_initialized()):
		return "PlayFab is not initialized. Sign in before hosting or joining."
	if not _party_initialized:
		if bool(pf.party.is_initialized()):
			_party_initialized = true
		else:
			if _deadline_expired(context.clock, deadline_msec):
				return "PlayFab Party initialization timed out."
			_begin_owned_call(context)
			var party_init: Variant = await pf.party.initialize_async(null, _local_udp_port())
			_end_owned_call(context)
			if not _context_operation_current(context, operation) \
				or (scoped_operation != null \
					and not _scoped_operation_current(context, scoped_operation)):
				return "Session cancelled."
			if not _result_ok(party_init):
				return "PlayFab Party could not start: %s" % _reason(party_init)
			_party_initialized = true
	if scoped_operation != null \
		and not _scoped_operation_current(context, scoped_operation):
		return "Session cancelled."
	if not _multiplayer_initialized:
		if bool(pf.multiplayer.is_initialized()):
			_multiplayer_initialized = true
		else:
			if _deadline_expired(context.clock, deadline_msec):
				return "PlayFab Lobby initialization timed out."
			_begin_owned_call(context)
			var mp_init: Variant = await pf.multiplayer.initialize_async()
			_end_owned_call(context)
			if not _context_operation_current(context, operation) \
				or (scoped_operation != null \
					and not _scoped_operation_current(context, scoped_operation)):
				return "Session cancelled."
			if not _result_ok(mp_init):
				return "PlayFab Lobby could not start: %s" % _reason(mp_init)
			_multiplayer_initialized = true
	return ""


func _await_context_descriptor(
	context: LobbyContext,
	deadline_msec: int,
	operation: int,
	scoped_operation: ScopedOperation = null
) -> String:
	var own_deadline := _bounded_deadline(context.clock, deadline_msec, DESCRIPTOR_TIMEOUT)
	while _context_operation_current(context, operation) \
		and (scoped_operation == null \
			or _scoped_operation_current(context, scoped_operation)) \
		and not _deadline_expired(context.clock, own_deadline):
		if context.network == null:
			return ""
		var descriptor := String(_object_value(context.network, &"descriptor", ""))
		if not descriptor.is_empty():
			return descriptor
		await _sleep_until_poll(context.clock, own_deadline)
	return ""


func _await_context_transport_properties(
	context: LobbyContext,
	deadline_msec: int,
	operation: int,
	scoped_operation: ScopedOperation = null
) -> PartyResult:
	var own_deadline := _bounded_deadline(context.clock, deadline_msec, LOBBY_PROPERTY_TIMEOUT)
	while _context_operation_current(context, operation) \
		and (scoped_operation == null \
			or _scoped_operation_current(context, scoped_operation)) \
		and not _deadline_expired(context.clock, own_deadline):
		var state := snapshot(context)
		var descriptor := String((state.properties as Dictionary).get(DESCRIPTOR_KEY, ""))
		var phase := String((state.properties as Dictionary).get(SESSION_PHASE_KEY, ""))
		if not descriptor.is_empty() and not phase.is_empty():
			var owner_protocol := ""
			for member: Dictionary in state.members:
				if _entity_keys_match(member.key, state.owner_key):
					owner_protocol = String((member.properties as Dictionary).get(
						MatchmakingService.PROTOCOL_MEMBER_KEY, ""))
					break
			if not NRProtocol.is_compatible(owner_protocol):
				return _context_failure(
					PartyResult.Outcome.INVALID,
					&"owner_protocol_mismatch",
					NRProtocol.mismatch_message(owner_protocol, NRProtocol.version_string()),
					context)
			var result := _context_success(context)
			result.descriptor = descriptor
			result.descriptor_ready = true
			return result
		await _sleep_until_poll(context.clock, own_deadline)
	if not _context_operation_current(context, operation) \
		or (scoped_operation != null \
			and not _scoped_operation_current(context, scoped_operation)):
		return _context_failure(
			PartyResult.Outcome.SUPERSEDED,
			&"arranged_transport_superseded",
			"The arranged transport was replaced.",
			context)
	return _context_failure(
		PartyResult.Outcome.TIMEOUT,
		&"arranged_transport_timeout",
		"The arranged Party transport was not published in time.",
		context)


func _run_context_lock(
	context: LobbyContext,
	locked: bool,
	operation: ScopedOperation
) -> void:
	while context.lock_running and _scoped_operation_current(context, operation) \
		and not _deadline_expired(context.clock, operation.deadline_msec):
		await _sleep_until_poll(context.clock, operation.deadline_msec)
	if not _scoped_operation_current(context, operation):
		_finish_scoped_operation(
			operation,
			context,
			PartyResult.Outcome.SUPERSEDED,
			&"context_lock_superseded",
			"The lobby changed while its membership lock was updating.")
		return
	if context.lock_running:
		_finish_scoped_operation(
			operation,
			context,
			PartyResult.Outcome.TIMEOUT,
			&"context_lock_busy",
			"An earlier lobby lock operation did not finish.")
		return
	var entry_error := _context_operation_error(context, true)
	if entry_error != null:
		_finish_scoped_operation(
			operation,
			context,
			entry_error.outcome,
			entry_error.reason_code,
			entry_error.reason,
			entry_error.diagnostic)
		return
	context.lock_running = true
	context.lock_result = null
	context.lock_operation += 1
	var lock_operation := context.lock_operation
	var result: Variant = await context.lobby.set_membership_lock_async(
		MEMBERSHIP_LOCK_LOCKED if locked else MEMBERSHIP_LOCK_UNLOCKED)
	if lock_operation == context.lock_operation:
		context.lock_running = false
	if not _scoped_operation_current(context, operation) \
		or lock_operation != context.lock_operation:
		_finish_scoped_operation(
			operation,
			context,
			PartyResult.Outcome.SUPERSEDED,
			&"context_lock_superseded",
			"The lobby changed while its membership lock was updating.")
		return
	if not _result_ok(result):
		_finish_scoped_operation(
			operation,
			context,
			PartyResult.Outcome.SERVICE_ERROR,
			&"context_lock_failed",
			"The match service refused to update the lobby membership lock.",
			_reason(result))
		return
	context_updated.emit(context)
	_finish_scoped_operation(operation, context, PartyResult.Outcome.OK)


func _run_context_update(
	context: LobbyContext,
	lobby_properties: Dictionary,
	search_properties: Dictionary,
	member_properties: Dictionary,
	operation: ScopedOperation
) -> void:
	while context.post_running and _scoped_operation_current(context, operation) \
		and not _deadline_expired(context.clock, operation.deadline_msec):
		await _sleep_until_poll(context.clock, operation.deadline_msec)
	if not _scoped_operation_current(context, operation):
		_finish_scoped_operation(
			operation,
			context,
			PartyResult.Outcome.SUPERSEDED,
			&"context_update_superseded",
			"The lobby changed while it was being updated.")
		return
	if context.post_running:
		_finish_scoped_operation(
			operation,
			context,
			PartyResult.Outcome.TIMEOUT,
			&"context_update_busy",
			"An earlier lobby update did not finish.")
		return
	if operation.required_permit > 0 \
		and operation.required_permit != context.active_permit:
		_finish_scoped_operation(
			operation,
			context,
			PartyResult.Outcome.SUPERSEDED,
			&"publication_revoked",
			"Transport publication permission is no longer current.")
		return
	var requires_owner := not lobby_properties.is_empty() or not search_properties.is_empty()
	var entry_error := _context_operation_error(context, requires_owner)
	if entry_error != null:
		_finish_scoped_operation(
			operation,
			context,
			entry_error.outcome,
			entry_error.reason_code,
			entry_error.reason,
			entry_error.diagnostic)
		return
	context.post_running = true
	context.post_result = null
	context.post_operation += 1
	var post_operation := context.post_operation
	if not lobby_properties.is_empty() or not search_properties.is_empty():
		var update: Variant = _new_lobby_update_config()
		if update == null:
			if post_operation == context.post_operation:
				context.post_running = false
			_finish_scoped_operation(
				operation,
				context,
				PartyResult.Outcome.INVALID,
				&"lobby_update_unavailable",
				"PlayFab lobby updates are unavailable in this build.")
			return
		if not lobby_properties.is_empty():
			update.lobby_properties = lobby_properties
		if not search_properties.is_empty():
			update.search_properties = search_properties
		var shared_result: Variant = await context.lobby.post_update_async(update)
		if post_operation == context.post_operation \
			and not _scoped_operation_current(context, operation):
			context.post_running = false
		if not _scoped_operation_current(context, operation) \
			or post_operation != context.post_operation:
			_finish_scoped_operation(
				operation,
				context,
				PartyResult.Outcome.SUPERSEDED,
				&"context_update_superseded",
				"The lobby changed while it was being updated.")
			return
		if not _result_ok(shared_result):
			context.post_running = false
			_finish_scoped_operation(
				operation,
				context,
				PartyResult.Outcome.SERVICE_ERROR,
				&"context_update_failed",
				"The match service refused to update the lobby.",
				_reason(shared_result))
			return
		if operation.required_permit > 0 \
			and operation.required_permit != context.active_permit:
			context.post_running = false
			_finish_scoped_operation(
				operation,
				context,
				PartyResult.Outcome.SUPERSEDED,
				&"publication_revoked",
				"Transport publication permission is no longer current.")
			return

	if not member_properties.is_empty():
		var member_error := _context_operation_error(context, false)
		if member_error != null:
			if post_operation == context.post_operation:
				context.post_running = false
			_finish_scoped_operation(
				operation,
				context,
				member_error.outcome,
				member_error.reason_code,
				member_error.reason,
				member_error.diagnostic)
			return
		var member_result: Variant = await context.lobby.set_member_properties_async(
			member_properties)
		if post_operation == context.post_operation \
			and not _scoped_operation_current(context, operation):
			context.post_running = false
		if not _scoped_operation_current(context, operation) \
			or post_operation != context.post_operation:
			_finish_scoped_operation(
				operation,
				context,
				PartyResult.Outcome.SUPERSEDED,
				&"context_update_superseded",
				"The lobby changed while it was being updated.")
			return
		if not _result_ok(member_result):
			context.post_running = false
			_finish_scoped_operation(
				operation,
				context,
				PartyResult.Outcome.SERVICE_ERROR,
				&"member_update_failed",
				"The match service refused to update this lobby member.",
				_reason(member_result))
			return

	context.post_running = false
	if context.kind == LOBBY_KIND_ARRANGED and not lobby_properties.is_empty():
		var control := decode_arranged_control(lobby_properties)
		if bool(control.get("valid", false)):
			context.published_phase = String(control.get("phase", ""))
			context.published_lobby_properties.merge(lobby_properties, true)
	context_updated.emit(context)
	_finish_scoped_operation(operation, context, PartyResult.Outcome.OK)


func _await_context_lock(context: LobbyContext, deadline_msec: int) -> bool:
	var own_deadline := _bounded_deadline(context.clock, deadline_msec, LOBBY_LOCK_TIMEOUT)
	while context.lock_running and _context_is_current(context) \
		and not _deadline_expired(context.clock, own_deadline):
		await _sleep_until_poll(context.clock, own_deadline)
	return not context.lock_running


func _await_context_post(context: LobbyContext, deadline_msec: int) -> bool:
	var own_deadline := _bounded_deadline(context.clock, deadline_msec, LOBBY_LOCK_TIMEOUT)
	while context.post_running and _context_is_current(context) \
		and not _deadline_expired(context.clock, own_deadline):
		await _sleep_until_poll(context.clock, own_deadline)
	return not context.post_running


func _context_local_is_owner(context: LobbyContext) -> bool:
	return context != null and context.lobby != null and context.local_user != null \
		and bool(context.lobby.is_owner(context.local_user))


func _context_operation_error(
	context: LobbyContext,
	require_owner: bool
) -> PartyResult:
	if context == null or not _context_is_current(context) or context.lobby == null \
		or _lobby_is_disconnected(context.lobby):
		return _context_failure(
			PartyResult.Outcome.SUPERSEDED,
			&"context_unavailable",
			"The PlayFab lobby is no longer available.",
			context)
	if require_owner and not _context_local_is_owner(context):
		return _context_failure(
			PartyResult.Outcome.INVALID,
			&"context_not_owner",
			"Only the PlayFab lobby owner may update shared lobby state.",
			context)
	return null


func _context_success(context: LobbyContext, permit: int = 0) -> PartyResult:
	var result := PartyResult.new()
	result.outcome = PartyResult.Outcome.OK
	result.context = context
	result.peer = context.peer if context != null else null
	result.owner_key = snapshot(context).owner_key if context != null and context.lobby != null else {}
	result.local_creator = context.local_creator if context != null else false
	result.descriptor_ready = context != null and context.network != null \
		and not String(_object_value(context.network, &"descriptor", "")).is_empty()
	result.descriptor = String(_object_value(context.network, &"descriptor", "")) \
		if context != null and context.network != null else ""
	result.publication_permit = permit
	result.cleanup_pending = context.cleanup_pending if context != null else false
	return result


func _context_failure(
	outcome: int,
	code: StringName,
	message: String,
	context: LobbyContext = null,
	diagnostic: String = ""
) -> PartyResult:
	var result := PartyResult.new()
	result.outcome = outcome
	result.reason_code = code
	result.reason = message
	result.context = context
	result.diagnostic = diagnostic
	result.cleanup_pending = context.cleanup_pending if context != null else false
	return result


func _party_sdk() -> Variant:
	var pf: Variant = _playfab()
	if pf == null:
		return null
	if typeof(pf) == TYPE_DICTIONARY:
		return (pf as Dictionary).get("party")
	return pf.get("party")


func _new_lobby_config() -> Variant:
	return ClassDB.instantiate("PlayFabLobbyConfig")


func _new_lobby_join_config() -> Variant:
	return ClassDB.instantiate("PlayFabLobbyJoinConfig")


func _new_lobby_update_config() -> Variant:
	return ClassDB.instantiate("PlayFabLobbyUpdateConfig")


func _new_lobby_search_config() -> Variant:
	return ClassDB.instantiate("PlayFabLobbySearchConfig")


func _multiplayer_sdk() -> Variant:
	var pf: Variant = _playfab()
	if pf == null:
		return null
	if typeof(pf) == TYPE_DICTIONARY:
		return (pf as Dictionary).get("multiplayer")
	return pf.get("multiplayer")


func _result_ok(result: Variant) -> bool:
	return bool(_object_value(result, &"ok", false))


func _result_data(result: Variant) -> Variant:
	return _object_value(result, &"data", null)


func _object_value(value: Variant, property: StringName, fallback: Variant) -> Variant:
	if value == null:
		return fallback
	if typeof(value) == TYPE_DICTIONARY:
		return (value as Dictionary).get(property, fallback)
	var resolved: Variant = value.get(property)
	return fallback if resolved == null else resolved


func _user_entity_key(user: Variant) -> Dictionary:
	if user == null:
		return {}
	var value: Variant = {}
	if typeof(user) == TYPE_DICTIONARY:
		value = (user as Dictionary).get("entity_key", {})
	elif user.has_method("get_entity_key"):
		value = user.get_entity_key()
	else:
		value = user.get("entity_key")
	return _copy_entity_key(value as Dictionary) if typeof(value) == TYPE_DICTIONARY else {}


func _entity_keys_match(a: Dictionary, b: Dictionary) -> bool:
	return String(a.get("id", "")) == String(b.get("id", "")) \
		and String(a.get("type", "")) == String(b.get("type", ""))


func _account_is_current(generation: int) -> bool:
	return Services == null or not Services.has_method("is_current_account") \
		or Services.is_current_account(generation)


func _lobby_is_disconnected(lobby: Variant) -> bool:
	return lobby == null or (lobby.has_method("is_disconnected") and bool(lobby.is_disconnected()))


func _bounded_deadline(
	clock: OnlineFlowClock,
	caller_deadline_msec: int,
	own_seconds: float
) -> int:
	var own_deadline := _context_now_msec(clock) + int(ceil(own_seconds * 1000.0))
	return mini(own_deadline, caller_deadline_msec) if caller_deadline_msec > 0 else own_deadline


func _deadline_expired(clock: OnlineFlowClock, deadline_msec: int) -> bool:
	return deadline_msec > 0 and _context_now_msec(clock) >= deadline_msec


func _sleep_until_poll(clock: OnlineFlowClock, deadline_msec: int) -> void:
	var remaining := float(maxi(deadline_msec - _context_now_msec(clock), 0)) / 1000.0
	await _sleep_with_clock(clock, minf(POLL_INTERVAL, remaining))


static func _copy_entity_key(value: Dictionary) -> Dictionary:
	var entity_id := String(value.get("id", "")).strip_edges()
	var entity_type := String(value.get("type", "")).strip_edges()
	if entity_id.is_empty() or entity_type.is_empty():
		return {}
	return {"id": entity_id, "type": entity_type}


func _context_is_live(context: LobbyContext) -> bool:
	return context != null and not context.retired and _contexts.get(context.context_id) == context


func _empty_context_snapshot() -> Dictionary:
	return {
		"context_id": 0,
		"role": "",
		"kind": "",
		"recovery_epoch": -1,
		"expected_count": 0,
		"lobby_id": "",
		"local_key": {},
		"owner_key": {},
		"is_local_owner": false,
		"members": [],
		"max_members": 0,
		"access_policy": -1,
		"owner_migration": -1,
		"restrict_invites_to_owner": true,
		"membership_locked": false,
		"disconnected": true,
		"search_properties": {},
		"properties": {},
		"phase": "",
		"search_control": {"valid": false},
		"arranged_control": {"valid": false},
	}


func _context_now_msec(clock: OnlineFlowClock) -> int:
	return clock.now_msec() if clock != null else Time.get_ticks_msec()


func _sleep_with_clock(clock: OnlineFlowClock, seconds: float) -> void:
	if clock != null:
		await clock.sleep_seconds(seconds)
	else:
		await _sleep(seconds)


# --- Helpers ----------------------------------------------------------------

func _make_party_config(max_players: int, invitation_id: String) -> Variant:
	var cfg: Variant = _new_party_config()
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


func _new_party_config() -> Variant:
	return ClassDB.instantiate("PlayFabPartyConfig")


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
	if _clock != null:
		await _clock.sleep_seconds(seconds)
		return
	var loop := Engine.get_main_loop() as SceneTree
	if loop == null:
		return
	await loop.create_timer(seconds).timeout


func _fail(message: String) -> Dictionary:
	return {
		"ok": false,
		"peer": null,
		"code": "",
		"error": message,
		"kind": "",
		"context": null,
	}


func _kind_refusal(message: String, kind: String) -> Dictionary:
	var result := _fail(message)
	result["kind"] = kind
	return result


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
