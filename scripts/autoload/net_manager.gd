extends Node

## Host-authoritative multiplayer over PlayFab Party.
##
## The host creates a Party network and advertises its descriptor on a PlayFab lobby
## keyed by a five-character join code; clients resolve that code to the network via
## the same lobby. See PartyService for the handshake sequence.
##
## Party's PlayFabPartyPeer implements MultiplayerPeerExtension, so it plugs into
## multiplayer.multiplayer_peer like any built-in peer. Godot's high-level
## MultiplayerAPI runs on top of it, so the message layer is declarative @rpc functions
## and the bytes still travel over Party's relay infrastructure.
##
## Authority model: the host runs the simulation and is the sole source of truth for
## damage, scoring and spawning. Clients send only their own input and never author
## gameplay state directly. Any simulation output that appears on a client's screen
## arrived as a snapshot or event from the host.
##
## Reliability tiers: lobby, roster and score traffic uses reliable; per-frame ship
## input and world snapshots use unreliable_ordered. The tier for each message is set
## by the transfer_mode argument in its @rpc annotation.
##
## Mesh topology: a PlayFab Party network is a mesh, not a star. When the host leaves,
## no other peer's transport is disconnected and Godot never raises server_disconnected.
## Host departure is detected explicitly in `_on_peer_disconnected` by checking whether
## the lost peer id equals HOST_PEER_ID.
##
## Identity and trust: a roster entry's XUID arrives over the game's own RPC and is a
## claim, not a credential (XR-047). Display names shown to players come from the
## platform profile service, not from the peer. That verification, along with the rest
## of the platform's view of a session — activity, presence, recent players and chat
## policy — lives in platform_session.gd.
##
## RPC routing note: Godot resolves @rpc calls by the declaring node's scene path.
## Every @rpc entry point must stay declared on this autoload; moving any one to a
## different node changes its route and breaks the wire protocol silently at runtime.
##
## Sign-in is a hard prerequisite for host_match/join_by_code because Party and Lobby
## both require a PlayFabUser. start_offline() is the only path that runs without one.

signal roster_changed()
signal player_joined(state: PlayerState)
signal player_left(peer_id: int)
signal match_state_changed(state: NRTypes.MatchState)
signal countdown_changed(seconds_remaining: int)
## Authoritative match clock, in seconds elapsed since the match went live.
signal match_clock_received(elapsed: float)
signal game_mode_changed(mode: NRTypes.GameModeType)
## Voice-chat mesh changed (a control joined/left, or a mute flipped).
signal chat_indicators_changed()
signal chat_message_received(peer_id: int, text: String)
signal chat_text_policy_changed()
signal chat_cleared()
signal player_loaded(peer_id: int)

signal connection_succeeded()
signal connection_failed(reason: String)
signal server_disconnected()
## Whether the session is taking new players. Raised on every member, host and guest
## alike, so each one can retire or republish its own platform activity — an activity
## outlives the lobby that answers it, and a guest's is just as visible to its friends
## as the host's.
signal join_admission_changed(open: bool)

# --- Simulation traffic. The world node connects to these. -------------------
signal match_created(payload: Dictionary)
signal match_starting(payload: Dictionary)
signal world_snapshot_received(payload: Dictionary)
signal ship_input_received(peer_id: int, movement: Vector2, fire: Vector2, deploy_mine: bool, sequence: int)
signal projectile_spawned_received(payload: Dictionary)
signal projectile_detonated_received(payload: Dictionary)
signal power_up_spawned_received(payload: Dictionary)
signal power_up_collected_received(payload: Dictionary)
signal ship_spawned_received(payload: Dictionary)
signal ship_destroyed_received(payload: Dictionary)
signal asteroid_split_received(payload: Dictionary)
signal score_updated_received(payload: Dictionary)
signal gameplay_event_received(event_type: NRTypes.GameplayEventType, position: Vector2)
signal match_completed_received(payload: Dictionary)

const HOST_PEER_ID := 1

## Practice bots are given peer ids counting down from here. Godot's multiplayer peer
## ids are always positive, so a negative id can never collide with a real peer, and
## anything that looks a bot up by peer id (scoring, the roster, the world's
## ship-per-peer map) works without a second code path.
const BOT_PEER_ID_BASE := -1000
## Ceiling on practice opponents; see NRConst.MAX_PRACTICE_BOTS.
const MAX_PRACTICE_BOTS := NRConst.MAX_PRACTICE_BOTS

## Shown to a peer whose connection completed after the lobby had already started.
## Phrased for the player rather than the protocol: from their side nothing failed,
## the match simply began without them.
const JOIN_REJECTED_IN_PROGRESS := "That match has already started. Ask the host for the code again once it ends."

## Peer id -> PlayerState for everyone currently in the session, host included.
var players: Dictionary = {}
var match_state: NRTypes.MatchState = NRTypes.MatchState.LOADING
var game_mode_type: NRTypes.GameModeType = NRTypes.GameModeType.DEATHMATCH
var join_code: String = ""
## Reason the last host_match attempt failed, for the UI to show. Mirrors the text
## carried by connection_failed. Joins carry their own reason on their JoinRequest.
var last_error: String = ""
## Why the session ended from under this client, for the UI to show. Set immediately
## before server_disconnected is emitted, so a screen handling that signal can say
## whether the host left or the connection dropped rather than guessing.
var last_disconnect_reason: String = ""

var _peer: MultiplayerPeer = null
var _is_offline := false

## Whether the host will admit a peer that finishes connecting right now.
##
## This cannot be derived from `match_state`, because `PLAYERS_JOINING` means two
## different things: the lobby waiting for players, and MatchDirector waiting for
## everyone to finish loading the match scene. Joins are open in the first and must be
## closed in the second, so the session tracks the answer explicitly.
##
## Opened when a lobby is entered and closed the moment the lobby commits to starting.
## Every write goes through _set_accepting_joins so the host's clients and the platform
## activity stay in step: a client that still advertises a joinable activity for a match
## that has started sends its friends into a refusal.
var _accepting_joins := false
## Why the last attempt to open or close the session to new players failed, for the
## lobby to show. Empty when the last transition succeeded.
var last_admission_error: String = ""

## Ship input packets dropped because the transport's sender id and the id inside the
## packet disagreed, plus the timestamp of the last report. See _receive_ship_input.
var _misattributed_input_count := 0
var _misattributed_input_reported_at := 0.0
const _MISATTRIBUTED_INPUT_REPORT_INTERVAL := 5.0

## The platform's view of this session — activity, presence, recent players, chat
## policy and identity verification. Held as a plain object rather than a node: see
## platform_session.gd, which is where the Xbox Requirements work lives.
var _platform: PlatformSession = null
## Set while an internal leave_match() runs as part of starting a new session, so the
## teardown does not clear an activity that is about to be republished.
var _suppress_activity_delete := false

## Why the last chat message was not sent, for the entry dialog that stays open when it
## was refused. Set by send_chat_message() on every failure it can explain (XR-018).
var last_chat_error := ""
var _chat_context := 0
var _chat_view_active := false

const _JOIN_RESULT_POLL_INTERVAL := 0.1
const _JOIN_CODE_TIMEOUT_MESSAGE := "The join attempt timed out. Please try again."

var _join_request_sequence := 0
## The join whose outcome and teardown the session currently belongs to. Set the instant
## a join starts, so a second one arriving mid-await knows it has to take the seat rather
## than share it.
var _active_join_request: JoinRequest = null
## Requests asked to stop, keyed by request id: {"outcome": JoinRequest.Outcome,
## "reason": String}. Separate from the request's own outcome because an abort is a
## request to stop, not the answer -- the answer is written once the teardown it triggers
## has finished, and until then a poll needs to be able to see that a stop was asked for.
var _join_aborts: Dictionary = {}
## Teardown after an abandoned join is single-flight: the join being replaced and the
## replacement waiting on it both arrive here, and detaching the peer or resetting local
## state twice would take down whichever session exists by the time the second one runs.
var _join_cleanup_running := false
signal _join_cleanup_finished()
## Incremented every time a transport is bound; zeroed when the session is torn down.
## Gives each session an identity, which "is there a peer?" cannot: a join that succeeds
## as the host leaves and a join into the *next* session both see a peer, and only this
## tells them apart.
var _session_generation := 0


func _ready() -> void:
	multiplayer.peer_connected.connect(_on_peer_connected)
	multiplayer.peer_disconnected.connect(_on_peer_disconnected)
	multiplayer.connected_to_server.connect(_on_connected_to_server)
	multiplayer.connection_failed.connect(_on_connection_failed)
	multiplayer.server_disconnected.connect(_on_server_disconnected)
	var chat := _chat()
	if chat != null:
		if not chat.chat_changed.is_connected(_on_chat_changed):
			chat.chat_changed.connect(_on_chat_changed)
		chat.text_received.connect(_on_party_text_received)
		chat.text_policy_changed.connect(_on_text_policy_changed)
	PlayerProfile.identity_changed.connect(_on_chat_identity_changed)
	var party := _party()
	if party != null:
		# Party losing the network is the other way a session can end. The transport
		# route below only fires when a *peer* goes away; if Party itself drops the
		# network -- the relay becomes unreachable, the service fails the session, the
		# console loses its connection -- no peer disconnects and Godot reports nothing,
		# so without this the players sit in a match that can no longer send anything.
		if not party.network_lost.is_connected(_on_party_network_lost):
			party.network_lost.connect(_on_party_network_lost)
		if not party.party_failed.is_connected(_on_party_failed):
			party.party_failed.connect(_on_party_failed)
	var connectivity: ConnectivityService = Services.connectivity() if Services != null else null
	if connectivity != null:
		connectivity.connectivity_changed.connect(_on_connectivity_changed)
	# Constructed last, because it connects to the signals declared above and expects
	# the services it wraps to already be reachable.
	_platform = PlatformSession.new()


func _on_chat_changed() -> void:
	chat_indicators_changed.emit()
	if _platform != null:
		_platform.apply_chat_restrictions()


func _on_text_policy_changed() -> void:
	chat_text_policy_changed.emit()


func _on_chat_identity_changed() -> void:
	_clear_match_chat()
	var chat := _chat()
	if chat != null:
		chat.invalidate_session()


# --- Session lifecycle ------------------------------------------------------

## True when this instance owns the simulation: an explicit host, or offline play.
func is_host() -> bool:
	return _is_offline or (multiplayer.multiplayer_peer != null and multiplayer.is_server())


func is_offline() -> bool:
	return _is_offline


func local_peer_id() -> int:
	if _is_offline or multiplayer.multiplayer_peer == null:
		return HOST_PEER_ID
	return multiplayer.get_unique_id()


func local_player() -> PlayerState:
	return players.get(local_peer_id(), null)


## Starts a single-machine session with no networking. Used by the offline/practice
## path, which is the one mode that works without a PlayFab sign-in.
func start_offline() -> void:
	leave_match()
	_is_offline = true
	_session_generation += 1
	game_mode_type = NRTypes.GameModeType.DEATHMATCH
	_register_local_player(HOST_PEER_ID)
	_set_accepting_joins(true)
	_set_match_state(NRTypes.MatchState.PLAYERS_JOINING)
	connection_succeeded.emit()
	# No activity: a practice match is not joinable, so advertising one would offer the
	# platform a session nobody can enter.
	_platform.update_presence("Practice match")


## Creates a Party network and advertises it under a fresh join code. Awaitable;
## resolves once the network is live and the lobby carries its descriptor.
func host_match(mode: NRTypes.GameModeType = NRTypes.GameModeType.DEATHMATCH) -> bool:
	last_error = ""
	var resolved: Dictionary = await _resolve_signed_in_user()
	var user: Variant = resolved.get("user")
	if user == null:
		_fail_connection(String(resolved.get("error", "Could not host the match.")))
		return false

	_leave_match_internal()

	await _platform.apply_chat_privilege()

	var max_players := Assets.game_mode(mode).player_count
	var mode_name := String(NRTypes.GameModeType.keys()[mode])
	var result: Dictionary = await _party().host(user, max_players, mode_name)
	if not bool(result.get("ok", false)):
		_fail_connection(String(result.get("error", "Could not host the match.")))
		return false

	if not _bind_peer(result.get("peer")):
		await _party().leave()
		_fail_connection("PlayFab Party did not return a usable network peer.")
		return false

	_is_offline = false
	game_mode_type = mode
	join_code = String(result.get("code", ""))

	_register_local_player(HOST_PEER_ID)
	_set_accepting_joins(true)
	_set_match_state(NRTypes.MatchState.PLAYERS_JOINING)
	connection_succeeded.emit()
	_platform.publish_activity()
	_platform.update_presence("Hosting a match")
	return true


## Starts joining the session behind a five-character join code.
##
## Returns the handle for the attempt immediately, before it has done anything, rather
## than awaiting the answer. That is deliberate: the caller needs to name *this* attempt
## while it is still running — to bind a loading screen's Cancel button to it, and to know
## afterwards whether the answer it is reading is its own. Await the outcome with
## `await NetManager.join_by_code(code).wait()`, or hold the handle and await it later.
func join_by_code(code: String) -> JoinRequest:
	return _begin_join(code, "")


## Starts joining the session behind an accepted platform invite or protocol activation,
## which carries the lobby's connection string rather than a code (XR-064 / XR-124).
## Shares its body with join_by_code so the two paths cannot drift: an invite is the
## likeliest way to arrive at a match that has already started, so it needs the same
## deadline, cancellation and admission handling and not a shortcut around them.
func join_by_invite(connection_string: String) -> JoinRequest:
	return _begin_join("", connection_string)


## Claims the join seat for a new attempt and starts driving it.
##
## Ownership is taken here, synchronously, before anything can await. A join that claimed
## its seat only after resolving sign-in would spend that time invisible, and a second
## join starting in the gap would find the seat empty and believe itself alone.
func _begin_join(code: String, connection_string: String) -> JoinRequest:
	var previous := _active_join_request
	_join_request_sequence += 1
	var request := JoinRequest.new()
	request.id = _join_request_sequence
	_active_join_request = request
	_drive_join(request, code, connection_string, previous)
	return request


## Requests that a join stop. Scoped to a handle rather than to whichever join is running,
## because the two are not the same once a join has been replaced: an old loading screen
## whose Cancel cancelled "the active join" would cancel the join that replaced it.
##
## The PlayFab addon calls already in flight may still resume later, so this only records
## the request and invalidates PartyService's join token; _drive_join owns the awaited
## teardown and the late-result guard.
func cancel_join(request: JoinRequest) -> void:
	if request == null or not request.is_pending():
		return
	_request_join_abort(request, JoinRequest.Outcome.CANCELLED, "")


## Runs one join from start to answer, under a single deadline that spans both halves of
## joining: finding and connecting to the session, and waiting for the host to admit this
## player. One budget covers both because the player is looking at one loading screen —
## and because restarting the clock after the transport attached is what let a join sit
## indefinitely against a host that was never going to answer.
func _drive_join(request: JoinRequest, code: String, connection_string: String, previous: JoinRequest) -> void:
	if previous != null:
		# The join being replaced holds the peer and the Party network. Its teardown is
		# awaited before this one builds anything, so the replacement never attaches a
		# transport that the old join's cleanup is about to detach.
		_request_join_abort(previous, JoinRequest.Outcome.SUPERSEDED, "")
		await _finish_aborted_join(previous)
		if _active_join_request != request:
			# A third join arrived during that teardown and took the seat. It owns the
			# session now, so this one stops here rather than competing for it.
			request.settle(JoinRequest.Outcome.SUPERSEDED)
			return
		if _join_aborts.has(request.id):
			await _finish_aborted_join(request)
			return

	# Started, not awaited. The deadline below has to cover the connection as well as the
	# admission that follows it, and it cannot do that from behind an await on the
	# connection itself.
	_attach_transport(request, code, connection_string)

	var waited := 0.0
	while true:
		# Cancellation is read before the acceptance, not after it. The host's answer and
		# the player's Cancel can land between the same two polls, and a join the player
		# walked away from must not seat them because the answer arrived first.
		if _join_aborts.has(request.id):
			await _finish_aborted_join(request)
			return
		if _active_join_request != request:
			# A newer join replaced this one and has already torn it down. Stopping here
			# is the point: running the deadline out would tear down the replacement's
			# live session, which by then is the only session there is.
			request.settle(JoinRequest.Outcome.SUPERSEDED)
			return
		if request.admitted:
			_consume_admission(request)
			return
		if waited >= NRConst.JOIN_CODE_TIMEOUT_SECONDS:
			_request_join_abort(request, JoinRequest.Outcome.FAILED, _JOIN_CODE_TIMEOUT_MESSAGE)
			await _finish_aborted_join(request)
			return
		await _sleep(_JOIN_RESULT_POLL_INTERVAL)
		waited += _JOIN_RESULT_POLL_INTERVAL


## Builds the transport for one join, then leaves it to the host. A bound peer is not an
## answer: the host still has to admit this player, and _accept_join records that when it
## does, so nothing is settled here and the deadline goes on covering the wait.
func _attach_transport(request: JoinRequest, code: String, connection_string: String) -> void:
	var failure := await _join(request, code, connection_string)
	if failure.is_empty():
		return
	if not _is_join_current(request):
		# Abandoned mid-flight; whoever aborted it owns the answer.
		return
	_request_join_abort(request, JoinRequest.Outcome.FAILED, failure)


## Connects one join to its session. Returns an empty string once the peer is bound and
## the host has been asked to admit this player, or the reason it could not get that far.
func _join(request: JoinRequest, code: String, connection_string: String) -> String:
	var resolved: Dictionary = await _resolve_signed_in_user()
	if not _is_join_current(request):
		return ""
	if resolved.get("user") == null:
		return String(resolved.get("error", "Could not join the match."))
	var user: Variant = resolved.get("user")

	_leave_match_internal()

	await _platform.apply_chat_privilege()
	if not _is_join_current(request):
		return ""

	var result: Dictionary
	if connection_string.is_empty():
		result = await _party().join(user, code)
	else:
		result = await _party().join_by_connection_string(user, connection_string)
	if not _is_join_current(request):
		return ""
	if not bool(result.get("ok", false)):
		var error := String(result.get("error", ""))
		return error if not error.is_empty() else "Could not join the match."

	if not _bind_peer(result.get("peer")):
		await _party().leave()
		return "PlayFab Party did not return a usable network peer."

	_is_offline = false
	join_code = String(result.get("code", ""))
	_set_match_state(NRTypes.MatchState.LOADING)
	return ""


## True while a join still owns the session and has not been asked to stop. A request with
## no id never claimed a seat, so it can never be current: it cannot be cancelled or timed
## out against, and must not be allowed to proceed on the strength of that.
func _is_join_current(request: JoinRequest) -> bool:
	return request != null and request.id != 0 and _active_join_request == request and not _join_aborts.has(request.id)


## Turns the host's provisional acceptance into the join's answer.
##
## Acceptance is checked against the session that exists now rather than the one that
## existed when it arrived. The two can differ — the host leaves, the network drops, a
## refusal crosses the acceptance in flight — and the session generation is what tells
## them apart, where "is there a peer?" would happily accept the next session as this one.
func _consume_admission(request: JoinRequest) -> void:
	if _peer == null or _session_generation == 0 or _session_generation != request.session_id or local_player() == null:
		var reason := last_disconnect_reason
		if reason.is_empty():
			reason = "The match ended before you could join it."
		request.settle(JoinRequest.Outcome.FAILED, reason)
		return
	if not request.settle(JoinRequest.Outcome.SUCCEEDED):
		return
	if _active_join_request == request:
		_active_join_request = null
	_join_aborts.erase(request.id)
	# Published only now, once the join is answered and cannot still be cancelled out from
	# under it. Advertising the session on the strength of an acceptance the player was in
	# the middle of walking away from is the whole reason this is not done in _accept_join.
	connection_succeeded.emit()
	_platform.publish_activity()
	_platform.update_presence("In a match")


## Records that a join should stop, and why. The answer is not written here: aborting
## starts a teardown, and the request keeps reporting PENDING until that teardown has
## finished, so nothing reads success out of a session still being dismantled.
func _request_join_abort(request: JoinRequest, outcome: JoinRequest.Outcome, reason: String) -> void:
	if request == null or request.id == 0 or _join_aborts.has(request.id):
		return
	if not request.is_pending():
		return
	_join_aborts[request.id] = {"outcome": outcome, "reason": reason}
	# Invalidates whatever PartyService call this join left in flight. Safe even when a
	# replacement has already claimed the seat: the replacement awaits this teardown
	# before it starts a Party call of its own, so there is nothing newer to invalidate.
	var party := _party()
	if party != null:
		party.cancel_pending_join()


## Tears down an abandoned join and writes its answer. Both the join itself and the
## replacement waiting on it arrive here, which is why the teardown underneath is
## single-flight and why settling is one-shot.
func _finish_aborted_join(request: JoinRequest) -> void:
	var abort: Dictionary = _join_aborts.get(request.id, {})
	var outcome: JoinRequest.Outcome = abort.get("outcome", JoinRequest.Outcome.CANCELLED)
	var reason := String(abort.get("reason", ""))
	# The seat is given up before the teardown rather than after. The teardown is awaited,
	# and a join starting inside that wait has to find the seat empty — otherwise it would
	# see this dying request as the owner and take itself for a replacement of it.
	if _active_join_request == request:
		_active_join_request = null
	await _cleanup_after_join()
	_join_aborts.erase(request.id)
	if outcome == JoinRequest.Outcome.FAILED and reason.is_empty():
		reason = _JOIN_CODE_TIMEOUT_MESSAGE
	request.settle(outcome, reason)


## Clears the session an abandoned join left behind, exactly once.
##
## A replaced join and its replacement both wait on this, and so does the replaced join's
## own poll loop. Running the teardown per caller would detach the peer and reset local
## state a second time — by which point the only session those calls could reach is the
## replacement's live one.
func _cleanup_after_join() -> void:
	if _join_cleanup_running:
		await _join_cleanup_finished
		return
	_join_cleanup_running = true
	await _leave_match_for_join_abort()
	_join_cleanup_running = false
	_join_cleanup_finished.emit()


## leave_match() with the activity teardown suppressed, for the host/join paths that
## clear any previous session immediately before publishing a new one.
func _leave_match_internal() -> void:
	_suppress_activity_delete = true
	_platform.begin_activity_handover()
	leave_match()
	_platform.end_activity_handover()
	_suppress_activity_delete = false


## Answers a join that is still waiting on the host, because the session it was waiting
## for has ended. Returns true when the join now owns the outcome, which is the caller's
## cue not to raise `server_disconnected` as well: during a pending join the player is
## still on the loading screen, and two failure dialogs for one failure is one too many.
##
## Must run before the leave, so PartyService's in-flight awaits are invalidated by the
## abort rather than left to resume against a torn-down session.
func _abort_join_for_lost_session(reason: String) -> bool:
	var request := _active_join_request
	if request == null or not request.is_pending() or _join_aborts.has(request.id):
		return false
	# A join the host already answered is past what this can reach: its next poll consumes
	# the acceptance, and the session check there is the guard that catches this.
	if request.admitted:
		return false
	_request_join_abort(request, JoinRequest.Outcome.FAILED, reason)
	return true


## The reason to show when a join did not leave the player in a live session. Prefers the
## join's own failure, then the reason the session ended underneath it.
func join_failure_reason(request: JoinRequest) -> String:
	if request != null and not request.reason.is_empty():
		return request.reason
	if not last_disconnect_reason.is_empty():
		return last_disconnect_reason
	return "Could not join the match."


## True when a join that reported success is still backed by the session it was admitted
## into.
##
## Success and the screen change it triggers are not the same instant, and the session can
## end in between — the host leaves, the network drops, a refusal crosses the acceptance in
## flight. The admitted generation is compared rather than merely looking for a peer,
## because by the time the caller checks there may well *be* a peer: a different one, from
## a session this join was never admitted to. Every caller that navigates on a successful
## join checks this immediately before it does, because opening the lobby on a session
## that is not this one is exactly the empty roster and missing join code this whole path
## exists to prevent.
func joined_session_is_live(request: JoinRequest) -> bool:
	if request == null or not request.succeeded():
		return false
	return _peer != null and _session_generation != 0 and _session_generation == request.session_id and local_player() != null


func leave_match() -> void:
	_detach_peer()
	# Party teardown is asynchronous (clear the descriptor, leave the lobby, leave the
	# network). Local state is reset immediately so the UI never waits on the service,
	# and PartyService.host/join both re-await leave() before doing anything, so a
	# still-running teardown can't race a new session.
	var party := _party()
	if party != null:
		party.leave()
	_reset_after_leave()


## leave_match() that waits for the Party teardown instead of leaving it running.
##
## leave_match() abandons that teardown deliberately: every ordinary exit lands on a menu,
## and the menus stay responsive while the service unwinds behind them. The shutdown path is
## the one caller that cannot do that, because the statement after it stops the frame loop
## the addons pump their async completions on. Awaiting here is what keeps the frames coming
## until the teardown lands. See main.gd::_quit_now().
func leave_match_and_wait() -> void:
	_detach_peer()
	var party := _party()
	if party != null:
		await party.leave()
	# Left until the network is actually gone, matching _leave_match_for_join_abort():
	# nothing is waiting to observe the cleared state, and the activity and presence calls
	# this starts are then issued while there are still frames left to carry them.
	_reset_after_leave()


func _leave_match_for_join_abort() -> void:
	_detach_peer()
	var party := _party()
	if party != null:
		await party.leave()
	_reset_after_leave()


func _detach_peer() -> void:
	# PlayFabPartyPeer.close() starts its own network leave. PartyService owns that
	# operation; detach Godot first rather than leaving the same network twice.
	_peer = null
	multiplayer.multiplayer_peer = null


func _reset_after_leave() -> void:
	_clear_match_chat()
	var chat := _chat()
	if chat != null:
		chat.invalidate_session()
	_platform.reset_after_leave(_suppress_activity_delete)
	_is_offline = false
	_set_accepting_joins(false)
	# The session is gone, so nothing may still claim to have been admitted to it. Zero is
	# never a valid generation, which makes every stale acceptance fail its check.
	_session_generation = 0
	players.clear()
	join_code = ""
	last_chat_error = ""
	last_disconnect_reason = ""
	_set_match_state(NRTypes.MatchState.LOADING)
	roster_changed.emit()


## True while this instance is in a session of any kind — an online match or an offline
## practice match. Used by the lifecycle handler to decide whether a suspend actually
## costs the player anything.
##
## Asks `_peer` rather than `multiplayer.multiplayer_peer`, because the latter is never
## null: Godot seeds it with an OfflineMultiplayerPeer before anything has connected, so
## testing it would report a session from the moment the title boots.
func has_session() -> bool:
	return _is_offline or _peer != null


## Identity of the session in progress, or 0 when there is none. Numbers are never reused,
## so a value captured before an await and compared after it answers "is this still the
## same session?" — which has_session() cannot, having no memory of which one it meant.
## Callers that await a service round trip or a dialog and then act on the session need
## this: by the time they resume, "there is a session" and "there is *this* session" have
## come apart.
func session_id() -> int:
	return _session_generation


## Drops the current session because the title is being suspended (XR-001). Returns true
## when there was a session to drop, so the resume path knows whether to tell the player
## the match ended.
##
## This is leave_match() under a different name and a different contract, kept separate so
## the deadline constraint is stated where it applies rather than inherited by every menu
## exit. The suspend handler runs inside the platform's suspend deadline and the process is
## frozen the moment it returns, so nothing here may await: the peer is closed and all local
## state is reset synchronously, exactly as leave_match() already does, and the asynchronous
## Party teardown it starts is left to finish whenever the title runs again — or not at all,
## if the platform terminates instead of resuming. Either outcome is correct, because the
## network is going away regardless of whether this process is alive to watch it go.
func abandon_for_suspend() -> bool:
	if not has_session():
		return false
	leave_match()
	return true


## Party and Lobby both require a signed-in PlayFabUser, so there is no guest path into
## multiplayer. The multiplayer privilege is checked here too, so every entry point —
## host, join by code and join by invite — is covered by one funnel (XR-045).
##
## Returns {"user": Variant, "error": String}: a null user always carries a reason fit to
## show the player. The reason is returned rather than published, because host and join
## report failure differently — hosting emits connection_failed, while a join answers the
## one request that asked for it, and this funnel serves both.
func _resolve_signed_in_user() -> Dictionary:
	if Services == null:
		return {"user": null, "error": "Online services are unavailable in this build."}
	var user: Variant = Services.playfab_user()
	if user == null:
		var signed_in: bool = await Services.sign_in()
		if not signed_in:
			var reason: String = Services.sign_in_error()
			if reason.is_empty():
				reason = "You must be signed in to play online."
			return {"user": null, "error": reason}
		user = Services.playfab_user()

	var denied := await _multiplayer_privilege_denial()
	if not denied.is_empty():
		return {"user": null, "error": denied}
	return {"user": user, "error": ""}


## Blocks host and join when the account may not play online. Returns the reason it was
## refused, or an empty string when it was allowed. Services.can_play_multiplayer()
## offers the system resolution UI first, so a player who fixes the problem there carries
## straight on; only a privilege still denied afterwards becomes a failure.
func _multiplayer_privilege_denial() -> String:
	var verdict: Dictionary = await Services.can_play_multiplayer()
	if bool(verdict.get("granted", true)):
		return ""
	var reason := String(verdict.get("message", ""))
	if reason.is_empty():
		reason = "This account is not allowed to play online."
	return reason


## PlayFabPartyPeer inherits MultiplayerPeerExtension, so it is a MultiplayerPeer as far
## as Godot is concerned and drives every @rpc below.
func _bind_peer(candidate: Variant) -> bool:
	if candidate == null or not (candidate is MultiplayerPeer):
		return false
	_peer = candidate
	multiplayer.multiplayer_peer = _peer
	# Every session gets a number nothing else will reuse. It is what lets an acceptance
	# say which session it was an acceptance *to*, once there has been more than one.
	_session_generation += 1
	return true


func _sleep(seconds: float) -> void:
	await get_tree().create_timer(seconds).timeout


func _party() -> PartyService:
	return Services.party() if Services != null else null


func _chat() -> ChatService:
	return Services.chat() if Services != null else null


# --- Voice chat -------------------------------------------------------------

## Microphone state for one player, as a ChatService.ChatIndicator. Offline and
## practice sessions have no Party mesh, so every player reads back NONE and the
## roster draws no microphone icon for those players.
func chat_indicator_for(peer_id: int) -> int:
	var party := _party()
	var chat := _chat()
	if _is_offline or party == null or chat == null or not party.has_network():
		return ChatService.ChatIndicator.NONE
	var entity_key: Dictionary = _platform.entity_key_for(peer_id)
	if entity_key.is_empty():
		return ChatService.ChatIndicator.NONE
	return chat.chat_indicator_for(entity_key)


func is_voice_muted() -> bool:
	var chat := _chat()
	return chat.is_self_muted() if chat != null else true


## Toggles the local microphone. Voice starts muted, so this is how a player opts in.
func toggle_voice_mute() -> void:
	var party := _party()
	var chat := _chat()
	if party == null or chat == null or not party.has_network() or not _platform.is_chat_allowed():
		return
	await chat.toggle_self_muted()


# --- Chat policy (XR-045 / XR-015) ------------------------------------------
#
# The rules themselves -- the communications privilege, the mute and avoid lists, and
# the per-player privacy permissions -- live in platform_session.gd. What stays here is
# the API the lobby roster and chat UI call, because they ask NetManager about a peer
# and should not have to know which layer answers.

## Whether this session has voice and text chat at all.
func is_chat_allowed() -> bool:
	return _platform.is_chat_allowed()


## Player-facing reason chat is unavailable, empty when it is available.
func chat_restriction_reason() -> String:
	return _platform.chat_restriction_reason()


## True when the player may mute or unmute this peer themselves. A voice the platform
## already silenced is not theirs to lift, and the local player is not mutable at all.
func can_mute_peer(peer_id: int) -> bool:
	return _platform.can_mute_peer(peer_id)


func is_peer_muted(peer_id: int) -> bool:
	return _platform.is_peer_muted(peer_id)


## True when the platform silenced this player's voice, so the roster can say why a row
## it will not let the player unmute is muted anyway.
func is_peer_voice_restricted(peer_id: int) -> bool:
	return _platform.is_peer_voice_restricted(peer_id)


## Mutes or unmutes one player for the local player only; the lobby roster drives it.
func toggle_peer_mute(peer_id: int) -> void:
	await _platform.toggle_peer_mute(peer_id)

## Single funnel for hosting failures so the reason is both broadcast and retrievable;
## screens that await host_match read NetManager.last_error afterwards. Joins do not come
## through here — each one answers the request that asked for it.
func _fail_connection(reason: String) -> void:
	last_error = reason
	push_warning("[Net] %s" % reason)
	connection_failed.emit(reason)


func _register_local_player(peer_id: int) -> void:
	var state := PlayerState.new()
	state.peer_id = peer_id
	state.display_name = PlayerProfile.display_name
	state.entity_id = PlayerProfile.entity_id
	state.xbox_user_id = PlayerProfile.xbox_user_id
	state.ship_color_id = PlayerProfile.ship_color_id
	state.ship_style_id = PlayerProfile.ship_style_id
	state.is_local_player = true
	players[peer_id] = state
	roster_changed.emit()


# --- Practice opponents -----------------------------------------------------

## Brings the roster's bot count to `count`, adding or removing NPC opponents as
## needed. Offline only: bots are a practice-mode feature, and introducing one into a
## networked session would put a ship on the host that no client has ever been told
## about.
##
## Bots are created ready and loaded. Both flags gate the match start -- the lobby
## waits on `everyone_ready()` and MatchDirector waits on every player's `in_game` --
## and a bot has nothing to ready up or load, so leaving them false would simply hang
## the practice match forever.
func sync_practice_bots(count: int) -> void:
	if not _is_offline:
		return

	var wanted := clampi(count, 0, MAX_PRACTICE_BOTS)
	var existing := bot_players()

	for index in range(wanted, existing.size()):
		players.erase(existing[index].peer_id)

	for index in range(existing.size(), wanted):
		var state := PlayerState.new()
		state.peer_id = BOT_PEER_ID_BASE - index
		state.display_name = _bot_display_name(index)
		state.is_bot = true
		state.is_ready = true
		state.in_game = true
		state.ship_style_id = index % 4
		state.ship_color_id = _free_ship_color()
		players[state.peer_id] = state

	roster_changed.emit()


func bot_players() -> Array[PlayerState]:
	var bots: Array[PlayerState] = []
	for state: PlayerState in players.values():
		if state.is_bot:
			bots.append(state)
	bots.sort_custom(func(a: PlayerState, b: PlayerState) -> bool: return a.peer_id > b.peer_id)
	return bots


func bot_count() -> int:
	return bot_players().size()


## Picks a hull colour nobody in the roster is using yet, so the player can always
## tell which ship is theirs. Falls back to a wrap-around once the palette runs out.
func _free_ship_color() -> int:
	var taken: Array[int] = []
	for state: PlayerState in players.values():
		taken.append(state.ship_color_id)
	var palette_size := maxi(Assets.player_color_count(), 1)
	for color_id in palette_size:
		if not taken.has(color_id):
			return color_id
	return players.size() % palette_size


const _BOT_NAMES: PackedStringArray = [
	"Vega", "Rigel", "Altair", "Mira", "Antares", "Deneb", "Polaris",
]


func _bot_display_name(index: int) -> String:
	if index < _BOT_NAMES.size():
		return _BOT_NAMES[index]
	return "Bot %d" % (index + 1)


# --- Session admission ------------------------------------------------------

## True while the session would admit a newcomer: it is in a lobby rather than in or
## part-way into a match. Host-authoritative — a client's copy tracks the host's, and it
## uses it only to decide whether to advertise its own session as joinable.
func is_accepting_joins() -> bool:
	return _accepting_joins


## Seals the session against newcomers before a match starts. Awaitable; returns true
## only when the PlayFab lobby confirmed the lock.
##
## Two things close a match and both are load-bearing. The host's own gate closes, which
## turns away a peer whose connection is already in flight, and the lobby's membership is
## locked, which stops anyone finding the session in the first place. The gate alone is
## what produced the bug this exists for: a latecomer still found the lobby, still joined
## it, still built a Party network, and only then met a refusal — arriving as a
## disconnection on a client that had already recorded the join as a success.
##
## Fails closed. The local gate shuts before the service call and stays shut whatever the
## service says, so an unconfirmed lock never starts a match the lobby is still
## advertising; the caller offers a retry instead.
func close_joins() -> bool:
	return await _set_joins_open(false)


## Reopens the session to newcomers once the host is back in the waiting lobby.
## Awaitable; returns true only when the PlayFab lobby confirmed the unlock.
##
## The local gate opens only after the service does, which is the opposite order to
## close_joins and for the same reason: every window where the two disagree should err
## towards refusing a newcomer rather than advertising a join that will be refused.
func open_joins() -> bool:
	return await _set_joins_open(true)


func _set_joins_open(open: bool) -> bool:
	last_admission_error = ""
	if not is_host():
		last_admission_error = "Only the host can open or close the match."
		return false
	# Practice runs on one machine with no lobby to lock, so the local gate is all of it.
	if _is_offline:
		_set_accepting_joins(open)
		return true
	if not has_session():
		last_admission_error = "The match has ended."
		return false
	if not open:
		_set_accepting_joins(false)
	var party := _party()
	if party == null:
		last_admission_error = "PlayFab Party is unavailable in this build."
		return false
	var result: Dictionary = await party.set_lobby_locked(not open)
	if not bool(result.get("ok", false)):
		last_admission_error = String(result.get("error", "The match could not be updated."))
		push_warning("[Net] Lobby admission update failed: %s" % last_admission_error)
		return false
	# The session can end while the service is thinking. A late unlock must not reopen a
	# lobby this instance has already left.
	if not has_session():
		last_admission_error = "The match has ended."
		return false
	if open:
		_set_accepting_joins(true)
	return true


## The single writer for the admission gate. Everything that changes it comes through
## here so the two things that depend on it cannot be forgotten: the host's clients need
## the new state to retire or republish their own platform activities, and this instance
## needs it to do the same with its own.
func _set_accepting_joins(open: bool) -> void:
	if _accepting_joins == open:
		return
	_accepting_joins = open
	if is_host() and _peer != null:
		_receive_join_admission.rpc(open)
	join_admission_changed.emit(open)


## The host's admission state, mirrored onto a client. A guest publishes its own Xbox
## activity, so it has to know when the match stopped taking players -- otherwise its
## friends keep seeing a joinable session and keep being refused by it.
@rpc("authority", "call_remote", "reliable")
func _receive_join_admission(open: bool) -> void:
	if is_host():
		return
	_set_accepting_joins(open)


## The host has admitted this player: they are on its authoritative roster, they hold the
## roster and mode it replayed first, and the session is theirs to enter.
##
## This -- not the transport attaching -- is what a successful join means. Party connects a
## client to the mesh before the host has looked at it, and the host may still turn it away
## for a match already in progress or an incompatible build. A join resolved on the
## transport alone therefore reported success for sessions the player was never admitted
## to, and the refusal arrived while the loading screen was still up, too late to change an
## answer that had already been recorded. That is what left a refused player looking at a
## lobby with no roster and no join code.
##
## Recorded, not answered. The join's own poll consumes this a moment later, after it has
## checked that the player has not cancelled in the meantime and that the session is still
## there — so nothing here emits success, publishes an activity or opens a lobby.
@rpc("authority", "call_remote", "reliable")
func _accept_join() -> void:
	if is_host():
		return
	var request := _active_join_request
	if request == null or not request.is_pending() or request.admitted:
		return
	if _join_aborts.has(request.id):
		return
	if _peer == null or _session_generation == 0 or local_player() == null:
		return
	# The host only accepts while it is open, so this doubles as the client's first read
	# of the admission state -- before any _receive_join_admission has had cause to fire.
	_set_accepting_joins(true)
	request.session_id = _session_generation
	request.admitted = true


# --- Peer plumbing ----------------------------------------------------------

func _on_peer_connected(peer_id: int) -> void:
	if not is_host():
		return
	# A match in progress does not take newcomers. Admitting one used to put a player
	# on the roster who had no ship, no spawn and no scene loaded, which then leaked
	# into everything that walks `players`: the roster count, the loading barrier in
	# MatchDirector._handle_players_loading, everyone_ready(), the score-limit check
	# and last-player-standing. Turning them away here is what keeps all of those
	# honest, so the check belongs at the door rather than in each of them.
	if not _accepting_joins:
		_reject_join.rpc_id(peer_id, JOIN_REJECTED_IN_PROGRESS)
		return
	# The host replays the whole roster to the newcomer, then tells everyone about it.
	for existing_id in players:
		var existing: PlayerState = players[existing_id]
		_receive_roster_entry.rpc_id(peer_id, existing.to_dict())
	# The newcomer joined after the mode was chosen, so it has to be replayed too.
	_receive_game_mode.rpc_id(peer_id, int(game_mode_type))
	_request_player_identity.rpc_id(peer_id)


## Tells a peer the host will not have it and why. The client treats this exactly like
## any other end of session, so the reason lands in the same dialog as a host departure
## rather than needing a rejection path of its own.
@rpc("authority", "call_remote", "reliable")
func _reject_join(reason: String) -> void:
	_on_server_disconnected(reason)


func _on_peer_disconnected(peer_id: int) -> void:
	if _peer == null:
		return
	if players.has(peer_id):
		players.erase(peer_id)
		player_left.emit(peer_id)
		roster_changed.emit()
	if is_host():
		_receive_player_left.rpc(peer_id)
		return

	# The host going away is the end of the session, and this is the only notice of it
	# a client gets. A Party network is a mesh rather than a star, so the host leaving
	# does not disconnect anybody else's transport: the peer stays CONNECTED, Godot never
	# raises `server_disconnected`, and without this the clients sit in a match with no
	# authority -- no snapshots, no scoring, no way for it to ever end.
	#
	# Routed through the transport rather than an "I am leaving" RPC from the host on
	# purpose. This one signal covers every way a host can vanish: leaving from the menu,
	# being suspended by the platform, crashing, or dropping off the network. An RPC only
	# covers the first.
	if peer_id == HOST_PEER_ID:
		_on_server_disconnected("The host left the match.")


func _on_connected_to_server() -> void:
	# Registers the identity _submit_player_identity is about to send. The join is not
	# resolved here: the transport attaching says nothing about whether the host will
	# have this player. See _accept_join.
	_register_local_player(multiplayer.get_unique_id())


func _on_connection_failed() -> void:
	multiplayer.multiplayer_peer = null
	_peer = null
	_fail_connection("Connection to host failed.")


## The session is over and this instance is not the one that ended it.
##
## `_peer` is the re-entry guard: both the host's departure and a genuine transport drop
## can reach here for the same session, and the screens must not be told twice.
func _on_server_disconnected(reason: String = "") -> void:
	if _peer == null:
		return
	var message := reason if not reason.is_empty() else "You were disconnected from the match."
	# Claimed before the leave: a join still waiting on the host is answered by the abort,
	# which also invalidates PartyService's in-flight awaits. This is the path a refusal
	# arrives on, so it is what stops a rejected join from ever reporting success.
	var owned_by_join := _abort_join_for_lost_session(message)
	# A full leave, not just a local reset. The Party network and the PlayFab lobby are
	# still joined at this point, and the activity is still advertised -- the host going
	# away does not retract any of that -- so without this the player returns to the menu
	# still in a dead session and still shown to their friends as playing in it.
	leave_match()
	# Set after the leave, because the leave is what clears the previous session's reason.
	last_disconnect_reason = message
	if owned_by_join:
		# The join reports this reason itself, on a player who never left the loading
		# screen. Emitting here as well would put a second dialog behind the first.
		return
	server_disconnected.emit()


## The Party network is gone and is not coming back. Ends the session the same way a host
## departure does, so there is one route out of a dead match rather than one per cause.
##
## Reaches every participant, host included: `_on_server_disconnected` is not host-gated,
## and a host whose network died has no session left either. Its `_peer` guard swallows
## the duplicate when Party reports both a state change and a destroy for the same loss,
## and makes this a no-op when the player already left under their own steam.
func _on_party_network_lost(reason: String) -> void:
	_on_server_disconnected(reason)


## A Party operation failed without the network going down. Recorded rather than acted on:
## the addon raises this for state-change batches that fail recoverably, so ending the
## match here would drop players over errors the session survives. The terminal cases
## arrive as `network_lost` instead.
func _on_party_failed(message: String) -> void:
	if not has_session():
		return
	last_error = message
	push_warning("[NetManager] Party reported a non-fatal failure: %s" % message)


## How long the console must stay offline before an online match is ended (XR-074).
##
## The hint is device-wide and can flap -- a brief interface change, a transient radio
## drop -- over intervals a Party network rides out without losing a packet the player
## would notice. Ending a match the instant it goes low would be a regression against the
## reactive handling rather than an improvement on it, so the loss has to persist.
const _CONNECTIVITY_GRACE_SECONDS := 8.0

## Bumped on every connectivity change so a grace period that has been overtaken -- by
## the connection coming back, or by the match ending some other way -- cannot fire.
var _connectivity_token := 0


## The console's connectivity changed. Only an *online* match is at stake: a practice
## match is entirely local, and ending one because the console dropped off the network
## would be nonsense.
##
## This is the proactive route out of a dead match. `PartyService.network_lost` remains
## the backstop, and either may win: whichever arrives first ends the session and the
## other is swallowed by the `_peer` guard in `_on_server_disconnected()`.
func _on_connectivity_changed(online: bool) -> void:
	_connectivity_token += 1
	if online or _is_offline or _peer == null:
		return
	_end_match_if_still_offline(_connectivity_token)


func _end_match_if_still_offline(token: int) -> void:
	await get_tree().create_timer(_CONNECTIVITY_GRACE_SECONDS).timeout
	# Re-checked rather than trusted: the token catches a reported change, and the live
	# query catches the case where the grace period simply outlasted the problem.
	if token != _connectivity_token or _is_offline or _peer == null:
		return
	var connectivity: ConnectivityService = Services.connectivity() if Services != null else null
	if connectivity == null or connectivity.is_online():
		return
	_on_server_disconnected(connectivity.offline_reason())


# --- Roster RPCs ------------------------------------------------------------

@rpc("authority", "call_remote", "reliable")
func _request_player_identity() -> void:
	var state := local_player()
	if state == null:
		# The host's request can arrive before Godot raises connected_to_server on this
		# client, and the join now waits on the reply this sends -- so a silent return
		# here would cost the player the whole join deadline. The identity comes from the
		# local profile either way, so it is built now rather than waited for.
		_register_local_player(multiplayer.get_unique_id())
		state = local_player()
	if state == null:
		return
	_submit_player_identity.rpc_id(HOST_PEER_ID, state.to_dict(), NRProtocol.version_string())


@rpc("any_peer", "call_remote", "reliable")
func _submit_player_identity(data: Dictionary, protocol: String) -> void:
	if not is_host():
		return
	var sender := multiplayer.get_remote_sender_id()
	# Second line of defence on the protocol version. PartyService already refused this
	# peer on the lobby if it read a mismatch there, so anything arriving here either
	# skipped that path or is running a build old enough not to have it. Best-effort by
	# nature -- a mismatch is exactly what stops RPCs routing correctly, so this check
	# depends on the thing it is checking for. It costs nothing and catches the cases
	# where the method indices still happen to line up.
	if not NRProtocol.is_compatible(protocol):
		push_warning("[Net] Rejecting peer %d: peer protocol '%s', local protocol '%s'." % [
			sender, protocol, NRProtocol.version_string()])
		_reject_join.rpc_id(sender, NRProtocol.mismatch_message(NRProtocol.version_string(), protocol))
		return
	# The lobby can commit to starting between the identity request going out and this
	# reply coming back. Re-checking here closes that window: without it the newcomer
	# lands on the roster a moment after the door shut, which is the exact state the
	# gate exists to prevent.
	if not _accepting_joins:
		_reject_join.rpc_id(sender, JOIN_REJECTED_IN_PROGRESS)
		return
	var state := PlayerState.from_dict(data)
	state.peer_id = sender
	state.ship_color_id = _first_free_color(sender, state.ship_color_id)
	# Trust Party's authenticated entity key over the one the client claimed in its
	# identity RPC: taking the key from the transport rather than the message means a
	# client cannot present someone else's entity id.
	var party := _party()
	if party != null:
		var key: Dictionary = party.entity_key_for(sender)
		var authenticated := String(key.get("id", ""))
		if not authenticated.is_empty():
			state.entity_id = authenticated
	# A retried identity submission re-states an admission rather than making a second
	# one. The roster entry is refreshed either way, but player_joined announces an
	# arrival and must only fire for a genuine one.
	var already_admitted := players.has(sender)
	players[sender] = state

	# Fan the newcomer out to every peer, including back to themselves so their
	# possibly-reassigned colour sticks.
	_receive_roster_entry.rpc(state.to_dict())
	# Sent last, once the newcomer holds the roster and mode this replayed to it: the
	# acknowledgement is what resolves their join, and it should not resolve into a lobby
	# there is nothing yet to draw. See _accept_join.
	_accept_join.rpc_id(sender)
	if not already_admitted:
		player_joined.emit(state)
	roster_changed.emit()


@rpc("authority", "call_remote", "reliable")
func _receive_roster_entry(data: Dictionary) -> void:
	var state := PlayerState.from_dict(data)
	state.is_local_player = state.peer_id == local_peer_id()
	players[state.peer_id] = state
	roster_changed.emit()


@rpc("authority", "call_remote", "reliable")
func _receive_player_left(peer_id: int) -> void:
	if players.has(peer_id):
		players.erase(peer_id)
		player_left.emit(peer_id)
		roster_changed.emit()


## Colours are unique per lobby; fall back to the first unused slot on collision.
func _first_free_color(peer_id: int, preferred: int) -> int:
	var taken: Array[int] = []
	for id in players:
		if id != peer_id:
			taken.append((players[id] as PlayerState).ship_color_id)
	if not taken.has(preferred):
		return preferred
	for i in Assets.player_color_count():
		if not taken.has(i):
			return i
	return preferred


# --- Lobby actions ----------------------------------------------------------

func set_local_ready(is_ready: bool) -> void:
	var state := local_player()
	if state == null:
		return
	state.is_ready = is_ready
	if is_host():
		_apply_ready_state(local_peer_id(), is_ready)
	else:
		_submit_ready_state.rpc_id(HOST_PEER_ID, is_ready)
	roster_changed.emit()


@rpc("any_peer", "call_remote", "reliable")
func _submit_ready_state(is_ready: bool) -> void:
	if not is_host():
		return
	_apply_ready_state(multiplayer.get_remote_sender_id(), is_ready)


func _apply_ready_state(peer_id: int, is_ready: bool) -> void:
	var state: PlayerState = players.get(peer_id, null)
	if state == null:
		return
	state.is_ready = is_ready
	if not _is_offline:
		_receive_ready_state.rpc(peer_id, is_ready)
	roster_changed.emit()


@rpc("authority", "call_remote", "reliable")
func _receive_ready_state(peer_id: int, is_ready: bool) -> void:
	var state: PlayerState = players.get(peer_id, null)
	if state == null:
		return
	state.is_ready = is_ready
	roster_changed.emit()


func set_local_appearance(color_id: int, style_id: int) -> void:
	var state := local_player()
	if state == null:
		return
	state.ship_color_id = color_id
	state.ship_style_id = style_id
	PlayerProfile.ship_color_id = color_id
	PlayerProfile.ship_style_id = style_id
	PlayerProfile.save_settings()
	if is_host():
		_apply_appearance(local_peer_id(), color_id, style_id)
	else:
		_submit_appearance.rpc_id(HOST_PEER_ID, color_id, style_id)
	roster_changed.emit()


@rpc("any_peer", "call_remote", "reliable")
func _submit_appearance(color_id: int, style_id: int) -> void:
	if not is_host():
		return
	_apply_appearance(multiplayer.get_remote_sender_id(), color_id, style_id)


func _apply_appearance(peer_id: int, color_id: int, style_id: int) -> void:
	var state: PlayerState = players.get(peer_id, null)
	if state == null:
		return
	state.ship_color_id = color_id
	state.ship_style_id = style_id
	if not _is_offline:
		_receive_appearance.rpc(peer_id, color_id, style_id)
	roster_changed.emit()


@rpc("authority", "call_remote", "reliable")
func _receive_appearance(peer_id: int, color_id: int, style_id: int) -> void:
	var state: PlayerState = players.get(peer_id, null)
	if state == null:
		return
	state.ship_color_id = color_id
	state.ship_style_id = style_id
	roster_changed.emit()


## Called by the gameplay screen once its scene is built and the world is ready.
## MatchDirector waits for every player's in_game flag before leaving PLAYERS_JOINING.
func report_local_player_loaded() -> void:
	if is_host():
		_apply_player_loaded(local_peer_id())
	else:
		var state := local_player()
		if state != null:
			state.in_game = true
		_submit_player_loaded.rpc_id(HOST_PEER_ID)


@rpc("any_peer", "call_remote", "reliable")
func _submit_player_loaded() -> void:
	if not is_host():
		return
	_apply_player_loaded(multiplayer.get_remote_sender_id())


func _apply_player_loaded(peer_id: int) -> void:
	var state: PlayerState = players.get(peer_id, null)
	if state == null or state.in_game:
		return
	state.in_game = true
	if not _is_offline:
		_receive_player_loaded.rpc(peer_id)
	player_loaded.emit(peer_id)
	roster_changed.emit()


@rpc("authority", "call_remote", "reliable")
func _receive_player_loaded(peer_id: int) -> void:
	var state: PlayerState = players.get(peer_id, null)
	if state == null:
		return
	state.in_game = true
	player_loaded.emit(peer_id)
	roster_changed.emit()


## Returns every player to their pre-match state. The host calls this when a match
## tears down, so the lobby a player lands back in looks exactly like the one they
## started from.
##
## Three fields survive a match and all three have to go: in_game gates the next
## match's loading barrier, is_ready gates whether the lobby starts a match at all,
## and score is compared against the game mode's target to decide when a match is
## won. Leaving any of them set makes the second match of a session behave nothing
## like the first — a lobby everyone is already "ready" in starts a match nobody
## asked for, which the stale scores then end on its first tick.
##
## Bots keep in_game and is_ready. They have no scene to load and no button to press,
## so they are created already loaded and already ready; clearing their flags would
## strand MatchDirector at the loading barrier and leave a practice lobby that can
## never reach everyone_ready() again. Their scores do reset, because bots are ranked
## on the scoreboard alongside human players.
func reset_for_next_match() -> void:
	_apply_match_reset()
	if not _is_offline:
		_receive_match_reset.rpc()


## Clients cannot derive this locally: a client never sees the match end as a state
## change it owns, and is_ready and score are both drawn in its roster. The host
## replicates the reset so every peer's lobby agrees.
@rpc("authority", "call_remote", "reliable")
func _receive_match_reset() -> void:
	_apply_match_reset()


func _apply_match_reset() -> void:
	for state: PlayerState in players.values():
		state.in_game = state.is_bot
		state.is_ready = state.is_bot
		state.score = 0
	# Deliberately does not reopen the session. Resetting scores and readiness is a
	# roster edit every peer applies the moment the match ends; admission is a service
	# state only the host owns, and only once it is actually back in the waiting lobby --
	# players read the results screen at their own pace, and a lobby that reopened here
	# would take newcomers while everyone else was still looking at final scores. The
	# lobby unlocks it on arrival instead (LobbyScreen._reopen_joins).
	#
	# Clearing readiness is also what holds the next match: a player still on the results
	# screen cannot ready up, and everyone_ready() is a precondition of starting, so the
	# round cannot begin again until every current player is back in the lobby.
	roster_changed.emit()


func begin_match_chat() -> int:
	_clear_match_chat()
	_chat_view_active = true
	return _chat_context


func is_match_chat_current(context: int) -> bool:
	return _chat_view_active and context == _chat_context


func end_match_chat(context: int) -> void:
	if is_match_chat_current(context):
		_clear_match_chat()


func _clear_match_chat() -> void:
	_chat_context += 1
	_chat_view_active = false
	chat_cleared.emit()


func chat_unavailable_reason() -> String:
	if not _chat_view_active or _is_offline or _peer == null:
		return "Text chat is available only in an online match."
	if Services == null or not Services.is_online():
		return "Sign in to use text chat."
	if not _platform.is_chat_allowed():
		return _platform.chat_restriction_reason()
	var chat := _chat()
	if chat == null or not chat.has_control():
		return "Text chat is unavailable. Leave and rejoin the session to try again."
	return ""


func can_read_chat_from(peer_id: int) -> bool:
	if not chat_unavailable_reason().is_empty() or not players.has(peer_id):
		return false
	if peer_id == local_peer_id():
		return true
	var party := _party()
	return party != null and _chat().can_exchange_text(party.entity_key_for(peer_id))


func _on_party_text_received(entity_key: Dictionary, text: String) -> void:
	if not chat_unavailable_reason().is_empty():
		return
	var party := _party()
	if party == null:
		return
	for state: PlayerState in players.values():
		if party.entity_key_for(state.peer_id) != entity_key:
			continue
		if state.peer_id != local_peer_id() and can_read_chat_from(state.peer_id):
			chat_message_received.emit(state.peer_id, text)
		return
	push_warning("[Net] Ignored text from a sender outside the current roster.")


## Party carries text separately from RPCs. A voice mute does not deny typed text:
## the text privacy verdict independently controls both recipients and ReceiveText.
## Returns false when the message could not be sent, which keeps the entry dialog open.
##
## The message is verified before it is sent, never after (XR-018). A message the
## platform will not accept never becomes a packet, and last_chat_error carries the
## sentence the dialog shows the player.
func send_chat_message(message: String) -> bool:
	last_chat_error = ""
	if not ChatService.valid_text(message):
		return _chat_failed("Messages must contain between 1 and %d characters." % ChatService.MAX_MESSAGE_LENGTH)
	var trimmed := message.strip_edges()
	var unavailable := chat_unavailable_reason()
	if not unavailable.is_empty():
		return _chat_failed(unavailable)
	var chat := _chat()
	var context := _chat_context
	var verdict: Dictionary = await Services.verify_chat_text(trimmed)
	if not is_match_chat_current(context):
		return _chat_failed("The match ended before the message could be sent.")
	if not bool(verdict.get("acceptable", false)):
		var reason := String(verdict.get("message", ""))
		return _chat_failed(reason if not reason.is_empty() else "The message could not be verified. Please try again.")
	unavailable = chat_unavailable_reason()
	if not unavailable.is_empty():
		return _chat_failed(unavailable)
	if not await chat.send_chat_text(trimmed):
		return _chat_failed(chat.last_text_error)
	if not is_match_chat_current(context):
		return _chat_failed("The match ended while the message was being sent.")
	# Party sends to remote controls only. This confirms submission, not delivery.
	chat_message_received.emit(local_peer_id(), trimmed)
	return true


func _chat_failed(reason: String) -> bool:
	last_chat_error = reason
	push_warning("[Net] %s" % reason)
	return false


## Files a reputation report against one player (XR-018). The peer is resolved to an XUID
## here rather than in the UI, so the reporting surface never has to handle identity.
## Returns false when the report did not reach the service, including when the player has
## no XUID to report — a desktop custom-id session, or a peer that reported none.
func report_player(peer_id: int, feedback_type: String) -> bool:
	if Services == null:
		return false
	var state: PlayerState = players.get(peer_id)
	if state == null:
		return false
	var xuid := String(state.xbox_user_id).strip_edges()
	if xuid.is_empty():
		return false
	return await Services.report_player(xuid, feedback_type)


## Opens the system profile card for one player, which is where Xbox offers blocking and
## its own reporting flow. False when there is no XUID or no platform to show it on.
func show_player_profile(peer_id: int) -> bool:
	if Services == null:
		return false
	var state: PlayerState = players.get(peer_id)
	if state == null:
		return false
	var xuid := String(state.xbox_user_id).strip_edges()
	if xuid.is_empty():
		return false
	var moderation := Services.moderation()
	if moderation == null:
		return false
	return await moderation.show_profile_card(Services.xbox_user(), xuid)


## True when this player can be reported: there is an Xbox identity to report from and an
## XUID to report against. The player actions overlay hides the action otherwise, rather
## than offering one that silently goes nowhere.
func can_report_player(peer_id: int) -> bool:
	if _is_offline or Services == null or peer_id == local_peer_id():
		return false
	if not Services.moderation_available():
		return false
	var state: PlayerState = players.get(peer_id)
	return state != null and not String(state.xbox_user_id).strip_edges().is_empty()


func everyone_ready() -> bool:
	if players.is_empty():
		return false
	for id in players:
		if not (players[id] as PlayerState).is_ready:
			return false
	return true


# --- Match state ------------------------------------------------------------

func set_match_state(state: NRTypes.MatchState) -> void:
	if not is_host():
		return
	# Committing to a start closes the local gate. Only STARTING does this: MatchDirector
	# also reports PLAYERS_JOINING once the gameplay scene is up, and that is the loading
	# barrier rather than a return to the lobby.
	#
	# A backstop, not the closure that matters. LobbyScreen._try_auto_start has already
	# awaited close_joins() and confirmed the lobby is locked before reaching here, and
	# this only makes sure a state set from anywhere else cannot leave the gate open.
	# Joins reopen from LobbyScreen._reopen_joins when the host returns.
	if state == NRTypes.MatchState.STARTING:
		_set_accepting_joins(false)
	_set_match_state(state)
	if not _is_offline:
		_receive_match_state.rpc(int(state))


func _set_match_state(state: NRTypes.MatchState) -> void:
	if match_state == state:
		return
	match_state = state
	match_state_changed.emit(state)


@rpc("authority", "call_remote", "reliable")
func _receive_match_state(state: int) -> void:
	_set_match_state(state as NRTypes.MatchState)


func broadcast_countdown(seconds_remaining: int) -> void:
	countdown_changed.emit(seconds_remaining)
	if is_host() and not _is_offline:
		_receive_countdown.rpc(seconds_remaining)


@rpc("authority", "call_remote", "reliable")
func _receive_countdown(seconds_remaining: int) -> void:
	countdown_changed.emit(seconds_remaining)


## The match clock is host-owned: clients advance their own copy between updates and
## snap to this value, so the HUD timer can't sit frozen (or drift) on a client.
func broadcast_match_clock(elapsed: float) -> void:
	if is_host() and not _is_offline:
		_receive_match_clock.rpc(elapsed)


@rpc("authority", "call_remote", "unreliable_ordered")
func _receive_match_clock(elapsed: float) -> void:
	match_clock_received.emit(elapsed)


# --- Game mode --------------------------------------------------------------

## The mode decides the time limit and target score, so clients have to be told
## about it or their HUD timer and win conditions disagree with the host's.
##
## Deathmatch is currently the only mode, so nothing calls this: the host fixes the
## mode in host_match() and a joining peer is told once, in the connect handshake
## (see _receive_game_mode.rpc_id in the peer-connected path). The setter is kept
## because it is the piece a second mode needs — it is the pattern for replicating
## any host-authoritative match setting that can change while players sit in the
## lobby, and _apply_game_mode's game_mode_changed signal is what a UI would listen
## to in order to redraw the rules panel on every peer at once.
func set_game_mode(mode: NRTypes.GameModeType) -> void:
	_apply_game_mode(mode)
	if is_host() and not _is_offline:
		_receive_game_mode.rpc(int(mode))


@rpc("authority", "call_remote", "reliable")
func _receive_game_mode(mode: int) -> void:
	_apply_game_mode(mode as NRTypes.GameModeType)


func _apply_game_mode(mode: NRTypes.GameModeType) -> void:
	if game_mode_type == mode:
		return
	game_mode_type = mode
	game_mode_changed.emit(mode)
	roster_changed.emit()


# --- Simulation traffic -----------------------------------------------------
#
# Host -> clients broadcasts. Each is a no-op on clients; the world node calls them
# only when it holds authority.

func broadcast_match_created(payload: Dictionary) -> void:
	match_created.emit(payload)
	if is_host() and not _is_offline:
		_receive_match_created.rpc(payload)


@rpc("authority", "call_remote", "reliable")
func _receive_match_created(payload: Dictionary) -> void:
	match_created.emit(payload)


func broadcast_match_starting(payload: Dictionary) -> void:
	match_starting.emit(payload)
	if is_host() and not _is_offline:
		_receive_match_starting.rpc(payload)


@rpc("authority", "call_remote", "reliable")
func _receive_match_starting(payload: Dictionary) -> void:
	match_starting.emit(payload)


func broadcast_world_snapshot(payload: Dictionary) -> void:
	if is_host() and not _is_offline:
		_receive_world_snapshot.rpc(payload)


@rpc("authority", "call_remote", "unreliable_ordered")
func _receive_world_snapshot(payload: Dictionary) -> void:
	world_snapshot_received.emit(payload)


## Clients push input to the host. On the host this short-circuits into the same
## signal the RPC raises, so the simulation has one code path for all players.
##
## The packet names its own sender, which is not as redundant as it looks. Everything
## downstream keys a player's ship off whichever peer the transport says a packet came
## from, and input is the only message that arrives INPUT_SEND_HZ times a second per
## player on an unreliable channel — so it is both the most exposed to the transport
## attributing a packet to the wrong peer and the one where doing so is most visible,
## because the result is a player's ship flying on somebody else's stick.
func send_ship_input(movement: Vector2, fire: Vector2, deploy_mine: bool, sequence: int) -> void:
	if is_host():
		ship_input_received.emit(local_peer_id(), movement, fire, deploy_mine, sequence)
	else:
		_receive_ship_input.rpc_id(
			HOST_PEER_ID, local_peer_id(), movement, fire, deploy_mine, sequence
		)


## The claimed id is checked against the transport's sender id rather than replacing it,
## and a packet the two disagree about is dropped.
##
## Dropping is deliberately the answer to both ways they can disagree. A client that
## lies about who it is only ever silences itself, so the claim stays a checksum and
## never becomes a credential — this keeps the same "trust the transport, not the
## client" rule the identity handshake follows. And when it is the transport that got
## it wrong, the cost is one frame of input on a channel that resends the player's
## entire input state INPUT_SEND_HZ times a second, where honouring the mismatch would
## instead hand their ship to another player until the next packet landed.
@rpc("any_peer", "call_remote", "unreliable_ordered")
func _receive_ship_input(
	claimed_peer_id: int,
	movement: Vector2,
	fire: Vector2,
	deploy_mine: bool,
	sequence: int
) -> void:
	if not is_host():
		return
	var sender := multiplayer.get_remote_sender_id()
	if claimed_peer_id != sender:
		_note_misattributed_input(sender, claimed_peer_id)
		return
	ship_input_received.emit(sender, movement, fire, deploy_mine, sequence)


## Records a dropped input packet and reports the running total at most once every
## _MISATTRIBUTED_INPUT_REPORT_INTERVAL seconds.
##
## Counted rather than logged one at a time: these arrive at INPUT_SEND_HZ per player,
## so a transport that has started mis-attributing in earnest would otherwise bury
## every other message in the log. A non-zero total here is the evidence that separates
## a transport-level attribution fault from a gameplay bug.
func _note_misattributed_input(sender_peer_id: int, claimed_peer_id: int) -> void:
	_misattributed_input_count += 1
	var now := Time.get_ticks_msec() / 1000.0
	if now - _misattributed_input_reported_at < _MISATTRIBUTED_INPUT_REPORT_INTERVAL:
		return
	_misattributed_input_reported_at = now
	push_warning(
		(
			"[NetManager] Dropped %d ship input packet(s) that did not agree on their "
			+ "sender. Most recent: transport reported peer %d, packet claimed peer %d."
		)
		% [_misattributed_input_count, sender_peer_id, claimed_peer_id]
	)


func broadcast_projectile_spawned(payload: Dictionary) -> void:
	if is_host() and not _is_offline:
		_receive_projectile_spawned.rpc(payload)


@rpc("authority", "call_remote", "reliable")
func _receive_projectile_spawned(payload: Dictionary) -> void:
	projectile_spawned_received.emit(payload)


func broadcast_projectile_detonated(payload: Dictionary) -> void:
	if is_host() and not _is_offline:
		_receive_projectile_detonated.rpc(payload)


@rpc("authority", "call_remote", "reliable")
func _receive_projectile_detonated(payload: Dictionary) -> void:
	projectile_detonated_received.emit(payload)


func broadcast_power_up_spawned(payload: Dictionary) -> void:
	if is_host() and not _is_offline:
		_receive_power_up_spawned.rpc(payload)


@rpc("authority", "call_remote", "reliable")
func _receive_power_up_spawned(payload: Dictionary) -> void:
	power_up_spawned_received.emit(payload)


func broadcast_power_up_collected(payload: Dictionary) -> void:
	if is_host() and not _is_offline:
		_receive_power_up_collected.rpc(payload)


@rpc("authority", "call_remote", "reliable")
func _receive_power_up_collected(payload: Dictionary) -> void:
	power_up_collected_received.emit(payload)


func broadcast_ship_spawned(payload: Dictionary) -> void:
	if is_host() and not _is_offline:
		_receive_ship_spawned.rpc(payload)


@rpc("authority", "call_remote", "reliable")
func _receive_ship_spawned(payload: Dictionary) -> void:
	ship_spawned_received.emit(payload)


func broadcast_ship_destroyed(payload: Dictionary) -> void:
	if is_host() and not _is_offline:
		_receive_ship_destroyed.rpc(payload)


@rpc("authority", "call_remote", "reliable")
func _receive_ship_destroyed(payload: Dictionary) -> void:
	ship_destroyed_received.emit(payload)


## Announces that an asteroid broke apart: the rock's id plus the full description of
## every fragment it threw off. Reliable, because unlike a snapshot this cannot be
## re-derived -- a client that misses it keeps a rock nobody else has and never learns
## about the fragments, which the snapshot stream then silently skips.
func broadcast_asteroid_split(payload: Dictionary) -> void:
	if is_host() and not _is_offline:
		_receive_asteroid_split.rpc(payload)


@rpc("authority", "call_remote", "reliable")
func _receive_asteroid_split(payload: Dictionary) -> void:
	asteroid_split_received.emit(payload)


func broadcast_score_updated(payload: Dictionary) -> void:
	_apply_score(payload)
	if is_host() and not _is_offline:
		_receive_score_updated.rpc(payload)


@rpc("authority", "call_remote", "reliable")
func _receive_score_updated(payload: Dictionary) -> void:
	_apply_score(payload)


func _apply_score(payload: Dictionary) -> void:
	var peer_id := int(payload.get("peer_id", 0))
	var state: PlayerState = players.get(peer_id, null)
	if state != null:
		state.score = int(payload.get("score", state.score))
	score_updated_received.emit(payload)
	roster_changed.emit()


func broadcast_gameplay_event(event_type: NRTypes.GameplayEventType, position: Vector2) -> void:
	if is_host() and not _is_offline:
		_receive_gameplay_event.rpc(int(event_type), position)


@rpc("authority", "call_remote", "unreliable")
func _receive_gameplay_event(event_type: int, position: Vector2) -> void:
	gameplay_event_received.emit(event_type as NRTypes.GameplayEventType, position)


func broadcast_match_completed(payload: Dictionary) -> void:
	match_completed_received.emit(payload)
	if is_host() and not _is_offline:
		_receive_match_completed.rpc(payload)


@rpc("authority", "call_remote", "reliable")
func _receive_match_completed(payload: Dictionary) -> void:
	match_completed_received.emit(payload)


# --- Helpers ----------------------------------------------------------------

## Roster order: humans first (by peer id, so the host leads), then bots. Bots carry
## negative peer ids to stay clear of Godot's id space, so a plain numeric sort would
## push them above the local player.
func sorted_players() -> Array[PlayerState]:
	var list: Array[PlayerState] = []
	for id in players:
		list.append(players[id])
	list.sort_custom(func(a: PlayerState, b: PlayerState) -> bool:
		if a.is_bot != b.is_bot:
			return b.is_bot
		# Bot ids count *downwards* from BOT_PEER_ID_BASE, so they need the opposite
		# comparison to keep the first-spawned bot at the top of the block.
		if a.is_bot:
			return a.peer_id > b.peer_id
		return a.peer_id < b.peer_id)
	return list


func players_by_score() -> Array[PlayerState]:
	var list := sorted_players()
	list.sort_custom(func(a: PlayerState, b: PlayerState) -> bool: return a.score > b.score)
	return list
