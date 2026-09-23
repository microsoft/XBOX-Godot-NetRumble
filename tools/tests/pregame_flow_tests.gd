extends RefCounted

## Phase 0 matchmaking flow cases: F1-F3 and F12-F13 of the pregame design, and the RB2
## quit cases.
##
## Production NetManager, MatchmakingFlow and PlatformSession run unmodified. PartyService
## and MatchmakingService are replaced at their public flow-facing methods -- the scoped
## lobby, transport and ticket calls whose own behavior the service suites cover -- so
## these cases observe what the flow asks for and how NetManager's session model, the
## admission gate and the activity respond. Time is one shared FakeClock; nothing here
## sleeps for a real phase budget, and none of it is evidence about native Party routing.
## The RB2 cases are the exception: they run PartyService's own global leave and scoped
## recovery, with only the SDK's two scoped shutdowns faked, so the quit is shown waiting on
## Party's real cleanup state.
##
## Every member of the doubles below carries a `fake_` prefix so a name PartyService or
## MatchmakingService adds later can never collide with one of them.

const Doubles := preload("res://tools/tests/doubles.gd")
const Review := preload("res://tools/tests/review_lifecycle.gd")
const TransportPeer := preload("res://tools/tests/pregame_transport_peer.gd")

const STAGING_ID := "staging-lobby"
const ARRANGED_ID := "arranged-lobby"
const STAGING_CONNECTION := "staging-connection"
const ARRANGED_CONNECTION := "arranged-connection"


## PartyService at its scoped matchmaking surface. Every call is logged in order, results
## are immediate unless a test blocks them, and the calls that follow a session change
## record the NetManager state they observed -- which is how the handoff reset is shown to
## have finished before the first await rather than merely eventually.
class FlowParty extends PartyService:
	signal fake_leave_released()
	signal fake_prepare_released()
	var fake_calls: Array[String] = []
	var fake_staging := PartyService.LobbyContext.new()
	var fake_arranged := PartyService.LobbyContext.new()
	var fake_local_key: Dictionary = {}
	var fake_peer_keys: Dictionary = {}
	var fake_members: Dictionary = {}
	var fake_owners: Dictionary = {}
	var fake_locked: Dictionary = {}
	var fake_search_control: Dictionary = {}
	var fake_staging_peer: Variant = null
	var fake_arranged_peer: Variant = null
	var fake_join_result: Dictionary = {}
	var fake_created_capacity := 0
	var fake_created_mode := ""
	var fake_published_phase := ""
	var fake_block_leave := false
	var fake_block_prepare := false
	var fake_fail_post := false
	var fake_fail_lock := false
	var fake_fail_unlock := false
	var fake_observed: Array[Dictionary] = []

	func fake_setup(local: Dictionary) -> void:
		fake_local_key = local.duplicate()
		fake_staging.context_id = 101
		fake_staging.kind = PartyService.LOBBY_KIND_STAGING
		fake_arranged.context_id = 202
		fake_arranged.kind = PartyService.LOBBY_KIND_ARRANGED
		fake_owners[fake_staging.context_id] = fake_local_key.duplicate()
		fake_owners[fake_arranged.context_id] = fake_local_key.duplicate()
		fake_members[fake_staging.context_id] = [{"key": fake_local_key.duplicate(), "connected": true, "properties": {}}]
		fake_members[fake_arranged.context_id] = []
		fake_staging_peer = OfflineMultiplayerPeer.new()

	func fake_add_member(context: PartyService.LobbyContext, key: Dictionary, connected: bool = true, properties: Dictionary = {}) -> void:
		var list: Array = fake_members.get(context.context_id, [])
		list.append({"key": key.duplicate(), "connected": connected, "properties": properties.duplicate()})
		fake_members[context.context_id] = list

	func fake_observe(label: String) -> void:
		fake_observed.append({
			"label": label,
			"peer": NetManager._peer,
			"multiplayer_peer": NetManager.multiplayer.multiplayer_peer,
			"session": NetManager.session_id(),
			"players": NetManager.players.size(),
			"local_peer_id": NetManager.local_peer_id(),
			"local_player": NetManager.local_player(),
			"join_code": NetManager.join_code,
			"accepting": NetManager.is_accepting_joins(),
			"request": NetManager._active_join_request,
		})

	func _fake_result(context: PartyService.LobbyContext, ok: bool = true, reason: String = "") -> PartyService.PartyResult:
		var result := PartyService.PartyResult.new()
		result.outcome = PartyService.PartyResult.Outcome.OK if ok else PartyService.PartyResult.Outcome.SERVICE_ERROR
		result.reason = reason
		result.context = context
		return result

	func create_staging(_user: Variant, capacity: int, mode_name: String, _account_generation: int, _flow_epoch: int, _deadline_msec: int = 0) -> PartyService.PartyResult:
		fake_calls.append("create_staging")
		fake_created_capacity = capacity
		fake_created_mode = mode_name
		var result := _fake_result(fake_staging)
		result.peer = fake_staging_peer
		result.owner_key = fake_local_key.duplicate()
		result.local_creator = true
		result.descriptor_ready = true
		result.publication_permit = 7
		return result

	func publish_transport(context: PartyService.LobbyContext, permit: int, phase: String, _extra_lobby_properties: Dictionary = {}, _extra_search_properties: Dictionary = {}, _deadline_msec: int = 0) -> PartyService.PartyResult:
		fake_calls.append("publish:%s:%d" % [phase, permit])
		fake_published_phase = phase
		fake_observe("publish")
		return _fake_result(context)

	func prepare_transport(context: PartyService.LobbyContext, _user: Variant, _deadline_msec: int = 0) -> PartyService.PartyResult:
		fake_calls.append("prepare")
		if fake_block_prepare:
			await fake_prepare_released
		var result := _fake_result(context)
		result.peer = fake_arranged_peer
		result.owner_key = fake_local_key.duplicate()
		result.local_creator = true
		result.descriptor_ready = true
		result.publication_permit = 9
		return result

	func join_transport(context: PartyService.LobbyContext, _user: Variant, _deadline_msec: int = 0) -> PartyService.PartyResult:
		fake_calls.append("join_transport")
		var result := _fake_result(context)
		result.peer = fake_arranged_peer
		return result

	# The arranged join the matched handoff starts. Refused here: Phase 0 cases only need
	# to see that it was reached, and in which order.
	func join_arranged(_user: Variant, arrangement: String, _member_properties: Dictionary, _account_generation: int, _flow_epoch: int, _deadline_msec: int = 0) -> PartyService.PartyResult:
		fake_calls.append("join_arranged:%s" % arrangement)
		return _fake_result(null, false, "Injected arranged join failure.")

	func set_context_locked(context: PartyService.LobbyContext, is_locked: bool, _deadline_msec: int = 0) -> PartyService.PartyResult:
		fake_calls.append("lock:%s" % str(is_locked))
		if (is_locked and fake_fail_lock) or (not is_locked and fake_fail_unlock):
			return _fake_result(context, false, "Injected lock failure.")
		fake_locked[context.context_id] = is_locked
		return _fake_result(context)

	func post_context_update(context: PartyService.LobbyContext, lobby_properties: Dictionary, _search_properties: Dictionary, member_properties: Dictionary, _deadline_msec: int = 0) -> PartyService.PartyResult:
		if fake_fail_post:
			fake_calls.append("post:failed")
			return _fake_result(context, false, "Injected post failure.")
		if lobby_properties.has(PartyService.SEARCH_CONTROL_KEY):
			var control := PartyService.decode_search_control(String(lobby_properties[PartyService.SEARCH_CONTROL_KEY]))
			fake_search_control[context.context_id] = control
			fake_calls.append("post:%s" % String(control.get("phase", "invalid")))
		else:
			fake_calls.append("post:member" if not member_properties.is_empty() else "post")
		return _fake_result(context)

	func leave_lobby(context: PartyService.LobbyContext) -> PartyService.PartyResult:
		fake_calls.append("leave_lobby:%d" % context.context_id)
		if fake_block_leave:
			await fake_leave_released
		return _fake_result(context)

	func leave_transport(context: PartyService.LobbyContext) -> PartyService.PartyResult:
		fake_calls.append("leave_transport:%d" % context.context_id)
		fake_observe("leave_transport")
		return _fake_result(context)

	func snapshot(context: PartyService.LobbyContext) -> Dictionary:
		if context == null:
			return {"members": [], "search_control": {"valid": false}}
		var owner: Dictionary = fake_owners.get(context.context_id, {})
		return {
			"context_id": context.context_id,
			"kind": context.kind,
			"lobby_id": lobby_id(context),
			"local_key": fake_local_key.duplicate(),
			"owner_key": owner.duplicate(),
			"is_local_owner": MatchmakingFlow.fingerprint(owner) == MatchmakingFlow.fingerprint(fake_local_key),
			"members": (fake_members.get(context.context_id, []) as Array).duplicate(true),
			"membership_locked": bool(fake_locked.get(context.context_id, false)),
			"disconnected": false,
			"search_control": (fake_search_control.get(context.context_id, {"valid": false}) as Dictionary).duplicate(true),
		}

	func lobby_id(context: PartyService.LobbyContext) -> String:
		if context == fake_staging:
			return STAGING_ID
		if context == fake_arranged:
			return ARRANGED_ID
		return ""

	func lobby_connection_string(context: PartyService.LobbyContext = null) -> String:
		if context == fake_staging:
			return STAGING_CONNECTION
		if context == fake_arranged:
			return ARRANGED_CONNECTION
		return ""

	func entity_key_for(peer_id: int) -> Dictionary:
		return (fake_peer_keys.get(peer_id, {}) as Dictionary).duplicate()

	func local_entity_key(_context: PartyService.LobbyContext = null) -> Dictionary:
		return fake_local_key.duplicate()

	func join_by_connection_string(_user: Variant, _connection_string: String, _deadline_msec: int = 0) -> Dictionary:
		fake_calls.append("join_by_connection_string")
		return fake_join_result.duplicate()

	func leave(_invalidate_pending: bool = true) -> void:
		fake_calls.append("leave")

	func has_network() -> bool:
		return false

	func has_owned_work() -> bool:
		return false

	func drain_owned_work(_deadline_msec: int) -> void:
		fake_calls.append("drain")


## MatchmakingService at its flow-facing surface: every attempt is recorded and settled by
## the test, so a case controls exactly when the service answers and with what. The
## profile is the real service's own check, reading the real game mode configuration.
class FlowMatchmaking extends MatchmakingService:
	var fake_creates: Array = []
	var fake_joins: Array = []
	var fake_cancels: Array = []
	var fake_retired: Array = []
	var fake_attempts: Array = []
	var fake_log: Array[String] = []
	var fake_retire_leaves_cleanup := false
	var fake_pending_cleanup := false

	func availability_reason() -> String:
		return ""

	func begin_create(spec: MatchmakingService.SearchSpec) -> MatchmakingService.TicketAttempt:
		fake_creates.append(spec)
		return _fake_attempt(spec, true)

	func begin_join(spec: MatchmakingService.SearchSpec) -> MatchmakingService.TicketAttempt:
		fake_joins.append(spec)
		return _fake_attempt(spec, false)

	func request_cancel(attempt: MatchmakingService.TicketAttempt) -> void:
		fake_cancels.append(attempt)

	# Retirement as the service performs it: marked retired before a still-pending attempt
	# settles as superseded, with native cleanup left owed when a case says so.
	func retire(attempt: MatchmakingService.TicketAttempt) -> void:
		if attempt == null:
			return
		fake_retired.append(attempt)
		fake_log.append("retire:%d" % attempt.flow_epoch)
		if attempt.retired:
			return
		attempt.retired = true
		if attempt.is_pending():
			attempt.cleanup_pending = fake_retire_leaves_cleanup
			attempt.settle(MatchmakingService.Outcome.SUPERSEDED)

	func has_pending_cleanup() -> bool:
		return fake_pending_cleanup

	func drain_owned_work(_deadline_msec: int) -> void:
		pass

	func _fake_attempt(spec: MatchmakingService.SearchSpec, owner: bool) -> MatchmakingService.TicketAttempt:
		var attempt := MatchmakingService.TicketAttempt.new()
		attempt.owner = owner
		attempt.flow_epoch = spec.flow_epoch
		attempt.account_generation = spec.account_generation
		attempt.frozen_members.assign(spec.frozen_members)
		attempt.deadline_msec = spec.deadline_msec
		attempt.ticket_id = spec.ticket_id
		fake_attempts.append(attempt)
		return attempt


## Records every privilege question, in order, into the log a case compares against the
## Party calls that follow it.
class LoggingPrivileges extends PrivilegeService:
	var fake_log: Array[String] = []

	func ensure(_user: Variant, privilege: int) -> Dictionary:
		fake_log.append("privilege:%d" % privilege)
		return {"granted": true}


## One scoped SDK service as PartyService's recovery sees it. Its shutdown confirms at once
## unless a case holds it, in which case it waits for the case's confirmation.
class HeldShutdown extends RefCounted:
	signal fake_confirmed(result: Dictionary)
	var fake_held := false
	var fake_fails := false
	var fake_initialized := true
	var fake_calls := 0

	func is_initialized() -> bool:
		return fake_initialized

	func shutdown_async() -> Dictionary:
		fake_calls += 1
		var result: Dictionary = {"ok": not fake_fails, "message": "Injected scoped shutdown."}
		if fake_held:
			result = await fake_confirmed
		if bool(result.get("ok", false)):
			fake_initialized = false
		return result


## The two scoped services a recovery resets. The RB2 Party has no session, so nothing else
## of the SDK is ever reached.
class HeldRuntime extends RefCounted:
	var party := HeldShutdown.new()
	var multiplayer := HeldShutdown.new()


## Production PartyService teardown -- the global leave, its grace and the scoped Party/Lobby
## recovery -- with only the SDK behind it replaced, and its time read from the case clock.
class RecoveryParty extends PartyService:
	var fake_runtime := HeldRuntime.new()
	var fake_clock: OnlineFlowClock = null

	func _playfab() -> Variant:
		return fake_runtime

	func _now_msec() -> int:
		return fake_clock.now_msec() if fake_clock != null else Time.get_ticks_msec()


var clock: Doubles.FakeClock = null
var party: FlowParty = null
var matchmaking: FlowMatchmaking = null
var activity: Review.Activity = null
var chat: Doubles.Chat = null
var _completed_calls := 0
var _saved_activity: ActivityService = null
var _probe_audio: Script = null


func run(test: Node) -> void:
	_saved_activity = Services._activity
	await _f1_staging_capacity_and_common_ready_path(test)
	await _f1_invite_entry_into_staging(test)
	await _f2_freeze_gates_ticket_creation(test)
	await _f3_social_veto_and_restoration(test)
	await _f12_local_reset_owner(test)
	await _f12_local_reset_guest(test)
	await _f13_transportless_lease_and_lifecycle(test)
	await _f13_quit_waits_for_flow_cleanup(test)
	await _p0_public_fences_hold(test)
	await _p0_profile_gate_refuses_direct_entry(test)
	await _p0_settled_attempts_are_retired(test)
	await _rb2_quit_drains_held_party_recovery(test)
	await _rb2_quit_budget_ends_held_party_recovery(test)
	await _rb2_quit_without_online_work_exits_at_once(test)
	await _rb2_failed_recovery_does_not_hold_quit(test)
	Services._activity = _saved_activity


# --- Harness --------------------------------------------------------------------

func _setup(test: Node, account: String) -> void:
	await test._reset()
	clock = Doubles.FakeClock.new()
	chat = Doubles.Chat.new()
	party = FlowParty.new(chat)
	matchmaking = FlowMatchmaking.new()
	activity = Review.Activity.new()
	_completed_calls = 0
	Services._chat = chat
	Services._party = party
	Services._matchmaking = matchmaking
	Services._activity = activity
	Services.use_clock(clock)
	# NetManager's establishment deadlines and offline grace read its own time seam; it
	# follows the same fake clock so a case's waits and deadlines move together.
	NetManager._clock = clock.now_msec
	test._select(account, test._folder())
	test._check(await Services.sign_in(), "matchmaking flow account ready: " + account)
	party.fake_setup(Services.playfab_user().entity_key)


## Blocked service calls are released first so every retired flow can finish its own
## cleanup, then anything still live is left through the production path, and every timer
## still waiting on this case's clock is run out before the next case gets its own.
func _teardown(test: Node) -> void:
	party.fake_block_leave = false
	party.fake_leave_released.emit()
	NetManager.leave_match()
	party.fake_block_prepare = false
	party.fake_prepare_released.emit()
	for _sweep in 3:
		_complete_activity()
		clock.advance(1000.0)
	_complete_activity()
	await test.get_tree().process_frame
	test._check(not NetManager.has_online_flow() and not NetManager.has_session()
		and NetManager._active_join_request == null, "flow case leaves no flow, session or join request behind")
	Services.use_clock(OnlineFlowClock.new())
	NetManager._clock = Time.get_ticks_msec
	Services._party = null
	Services._chat = null
	Services._matchmaking = null
	Services._privileges = null
	Services._profiles = null
	Services._connectivity = null
	Services._activity = _saved_activity


## Completes, in order, every activity write the double is still holding -- including any
## write a completion itself starts.
func _complete_activity(ok: bool = true) -> void:
	while _completed_calls < activity.sdk.calls.size():
		var pending_call: Review.ActivityCall = activity.sdk.calls[_completed_calls]
		_completed_calls += 1
		pending_call.completed.emit(ok)


func _last_set() -> Review.ActivityCall:
	if activity.sdk.calls.is_empty():
		return null
	return activity.sdk.calls.back()


func _open_group(test: Node) -> MatchmakingFlow:
	var opened: bool = await NetManager.start_matchmaking()
	test._check(opened and NetManager.has_online_flow(), "the owner opens a matchmaking group")
	_complete_activity()
	return NetManager._flow


## Seats a remote member the way an admitted Party player appears to the staging owner: a
## PlayerState on the roster, the authenticated entity key Party reports for its peer, and
## a connected member of the staging lobby.
func _add_guest(peer_id: int, entity: String, is_ready: bool = false) -> Dictionary:
	var key := {"id": entity, "type": "title_player_account"}
	var state := PlayerState.new()
	state.peer_id = peer_id
	state.display_name = entity
	state.entity_id = entity
	state.is_ready = is_ready
	NetManager.players[peer_id] = state
	party.fake_peer_keys[peer_id] = key
	party.fake_add_member(party.fake_staging, key)
	return key


func _remove_member(context: PartyService.LobbyContext, entity: String) -> void:
	var kept: Array = []
	for member: Dictionary in party.fake_members.get(context.context_id, []):
		if String((member.get("key", {}) as Dictionary).get("id", "")) != entity:
			kept.append(member)
	party.fake_members[context.context_id] = kept


## Every remote member readies through the host's own handler, then the owner readies
## through the lobby's call -- which is what starts the freeze.
func _ready_all() -> void:
	for peer_id: int in NetManager.players.keys():
		if peer_id != NetManager.HOST_PEER_ID:
			NetManager._apply_ready_state(peer_id, true)
	NetManager.set_local_ready(true)


## Every frozen remote member acknowledges the current attempt, then one poll runs.
func _ack_all(flow: MatchmakingFlow) -> void:
	for peer_id: int in flow.frozen_peers.keys():
		if peer_id != NetManager.HOST_PEER_ID:
			flow.on_member_report(peer_id, flow.epoch, MatchmakingFlow.Phase.FREEZING)
	clock.advance(MatchmakingFlow.POLL_SECONDS)


func _attempt() -> MatchmakingService.TicketAttempt:
	if matchmaking.fake_attempts.is_empty():
		return null
	return matchmaking.fake_attempts.back()


func _progress(attempt: MatchmakingService.TicketAttempt, status: int, ticket_id: String) -> void:
	attempt.status = status
	attempt.ticket_id = ticket_id
	attempt.progress_changed.emit(attempt)


func _finish(attempt: MatchmakingService.TicketAttempt, outcome: int, code: StringName = &"", text: String = "") -> void:
	if attempt != null:
		attempt.settle(outcome, code, text)


func _members(spec: MatchmakingService.SearchSpec) -> int:
	return spec.frozen_members.size() if spec != null else 0


## The newest NetManager state a Party call recorded under `label`, or empty.
func _observed(label: String) -> Dictionary:
	for index in range(party.fake_observed.size() - 1, -1, -1):
		if String(party.fake_observed[index].get("label", "")) == label:
			return party.fake_observed[index]
	return {}


## Leaves a flow where the matched handoff leaves it just before the transport swap: its
## arranged lobby joined, armed, the handoff budget running. Phase 1 reaches this through
## the arranged join and the barrier; Phase 0 tests only what happens from here.
func _arm(flow: MatchmakingFlow, arranged_owner: bool) -> void:
	flow.match_id = "matched-%d" % flow.id
	flow.arranged_context = party.fake_arranged
	flow.arranged_owner = arranged_owner
	flow.armed = true
	flow.phase_deadline_msec = clock.deadline_after(MatchmakingFlow.HANDOFF_SECONDS)
	flow._set_phase(MatchmakingFlow.Phase.ARMING_HANDOFF)
	_complete_activity()


# --- F1: four-slot staging and one ready path -------------------------------------

func _f1_staging_capacity_and_common_ready_path(test: Node) -> void:
	print("CASE: F1 four-slot staging with no room code; groups of one to four take one ready/ticket path")
	await _setup(test, "flow-owner")
	var flow := await _open_group(test)
	if flow == null:
		await _teardown(test)
		return
	test._check(flow.is_owner() and flow.phase == MatchmakingFlow.Phase.GATHERING,
		"the production entry leaves the owner's group gathering")
	test._check(party.fake_created_capacity == 4 and party.fake_published_phase == MatchmakingFlow.SESSION_PHASE_GATHERING
		and party.fake_calls.find("create_staging") >= 0
		and party.fake_calls.find("create_staging") < party.fake_calls.find("publish:gathering:7"),
		"the staging lobby is created with four slots and published only after its transport is active")
	var published := _observed("publish")
	test._check(bool(published.get("accepting", false)) and int(published.get("players", 0)) == 1,
		"the owner is registered and the local gate open before the descriptor goes out")
	test._check(NetManager.join_code.is_empty() and NetManager.session_capacity() == 4 and NetManager.is_host()
		and NetManager.has_session() and NetManager.is_accepting_joins(),
		"a staging owner hosts a four-capacity session with no room code")
	var advertised := _last_set()
	test._check(advertised != null and advertised.restriction == ActivityService.JOIN_RESTRICTION
		and advertised.maximum == 4 and advertised.count == 1 and advertised.group == STAGING_ID
		and advertised.connection == STAGING_CONNECTION,
		"the gathering group advertises a followed, four-slot activity grouped by its lobby id")
	var lobby: Variant = load("res://scripts/ui/screens/lobby_screen.gd").new()
	var players_line: String = lobby._players_line()
	test._check(lobby._roster_capacity() == 4 and players_line.begins_with("Group 1/4") and players_line.ends_with("Match 4"),
		"the lobby draws four group slots and tells the group apart from the match")
	lobby.free()
	NetManager.set_local_ready(true)
	test._check(matchmaking.fake_creates.size() == 1 and _members(matchmaking.fake_creates[0]) == 1
		and flow.phase == MatchmakingFlow.Phase.CREATING_TICKET,
		"a solo player readies in the lobby and submits a one-member group ticket")
	var entities: Array[String] = ["size-guest-5", "size-guest-6", "size-guest-8"]
	var peers: Array[int] = [5, 6, 8]
	for index in entities.size():
		_finish(_attempt(), MatchmakingService.Outcome.NO_MATCH)
		_complete_activity()
		_add_guest(peers[index], entities[index])
		NetManager.roster_changed.emit()
		_ready_all()
		_ack_all(flow)
		var size := index + 2
		var spec: MatchmakingService.SearchSpec = matchmaking.fake_creates.back()
		test._check(matchmaking.fake_creates.size() == size and spec.owner and spec.frozen_members.size() == size
			and spec.expected_match_count == 4 and spec.flow_epoch == flow.epoch,
			"a group of %d takes the same freeze and submits one ticket for all of it" % size)
	test._check(flow.phase == MatchmakingFlow.Phase.CREATING_TICKET and NetManager.players.size() == 4,
		"a full group of four is submitted to the queue -- not refused locally and not started privately")
	await _teardown(test)


func _f1_invite_entry_into_staging(test: Node) -> void:
	print("CASE: F1 an invite into a staging lobby is recognized by its lobby kind and joins the group")
	await _setup(test, "flow-invitee")
	var peer: Variant = TransportPeer.new(7)
	party.fake_join_result = {
		"ok": true, "peer": peer, "code": "", "error": "",
		"kind": PartyService.LOBBY_KIND_STAGING, "context": party.fake_staging,
	}
	var request := NetManager.join_by_invite(STAGING_CONNECTION)
	test._check(request.is_pending() and NetManager.has_session() and not NetManager.is_host()
		and not NetManager.has_online_flow() and NetManager.join_code.is_empty(),
		"the staging transport binds as a guest with no room code and waits for the owner's admission")
	peer.connect_remote(NetManager.HOST_PEER_ID)
	NetManager._accept_join()
	test._check(request.admitted and NetManager.is_entering_matchmaking() and activity.sdk.calls.is_empty(),
		"nothing is advertised between the owner's acceptance and this player becoming a member")
	clock.advance(MatchmakingFlow.POLL_SECONDS)
	var flow: MatchmakingFlow = NetManager._flow
	test._check(request.succeeded() and flow != null and not flow.is_owner()
		and flow.phase == MatchmakingFlow.Phase.GATHERING and flow.staging_context == party.fake_staging
		and not NetManager.is_entering_matchmaking(),
		"the owner's admission makes this player a guest member of the group")
	test._check(NetManager.join_code.is_empty() and NetManager.session_capacity() == 4,
		"a guest's group has no room code and four slots")
	var advertised := _last_set()
	test._check(advertised != null and advertised.restriction == ActivityService.JOIN_RESTRICTION
		and advertised.maximum == 4 and advertised.group == STAGING_ID and advertised.connection == STAGING_CONNECTION,
		"every gathering member advertises the same followed, four-slot group")
	await _teardown(test)


# --- F2: the freeze gates ticket creation -----------------------------------------

func _f2_freeze_gates_ticket_creation(test: Node) -> void:
	print("CASE: F2 the exact admitted/native group, readiness and every acknowledgement gate the ticket")
	await _setup(test, "flow-freeze")
	var flow := await _open_group(test)
	if flow == null:
		await _teardown(test)
		return
	var key5 := _add_guest(5, "freeze-guest-5")
	var key6 := _add_guest(6, "freeze-guest-6")
	NetManager.roster_changed.emit()
	NetManager._apply_ready_state(5, true)
	NetManager.set_local_ready(true)
	test._check(flow.phase == MatchmakingFlow.Phase.GATHERING and matchmaking.fake_creates.is_empty(),
		"one unready member holds the whole group in Gathering")
	var lurker := {"id": "freeze-lurker", "type": "title_player_account"}
	party.fake_add_member(party.fake_staging, lurker)
	NetManager._apply_ready_state(6, true)
	test._check(flow.phase == MatchmakingFlow.Phase.GATHERING and matchmaking.fake_creates.is_empty(),
		"a lobby member who never became an admitted player blocks the freeze rather than being left out")
	_remove_member(party.fake_staging, "freeze-lurker")
	NetManager._on_context_changed(party.fake_staging)
	test._check(flow.phase == MatchmakingFlow.Phase.FREEZING and not NetManager.is_accepting_joins()
		and bool(party.fake_locked.get(party.fake_staging.context_id, false))
		and party.fake_calls.has("post:freezing") and matchmaking.fake_creates.is_empty(),
		"the exact ready group freezes: admission closed, envelope posted and lobby locked before any ticket")
	var epoch := flow.epoch
	NetManager.roster_changed.emit()
	NetManager._on_context_changed(party.fake_staging)
	test._check(flow.epoch == epoch and flow.phase == MatchmakingFlow.Phase.FREEZING,
		"duplicate roster and lobby signals cannot start a second attempt")
	var guest: PlayerState = NetManager.players[5]
	var colour := guest.ship_color_id
	NetManager._apply_appearance(5, colour + 1, guest.ship_style_id)
	test._check(guest.ship_color_id == colour and not NetManager.can_customize(),
		"a frozen group's appearance is held on the host whatever a member sends")
	flow.on_member_report(5, epoch, MatchmakingFlow.Phase.FREEZING)
	clock.advance(MatchmakingFlow.POLL_SECONDS)
	test._check(matchmaking.fake_creates.is_empty() and flow.phase == MatchmakingFlow.Phase.FREEZING,
		"a missing acknowledgement holds the ticket back")
	flow.on_member_report(6, epoch - 1, MatchmakingFlow.Phase.FREEZING)
	flow.on_member_report(9, epoch, MatchmakingFlow.Phase.FREEZING)
	clock.advance(MatchmakingFlow.POLL_SECONDS)
	test._check(matchmaking.fake_creates.is_empty(),
		"an acknowledgement for another attempt, or from outside the group, is ignored")
	flow.on_member_report(6, epoch, MatchmakingFlow.Phase.FREEZING)
	clock.advance(MatchmakingFlow.POLL_SECONDS)
	test._check(matchmaking.fake_creates.size() == 1 and flow.phase == MatchmakingFlow.Phase.CREATING_TICKET,
		"the last acknowledgement releases exactly one ticket")
	if matchmaking.fake_creates.size() == 1:
		var spec: MatchmakingService.SearchSpec = matchmaking.fake_creates[0]
		var expected: Array[String] = [MatchmakingFlow.fingerprint(party.fake_local_key),
			MatchmakingFlow.fingerprint(key5), MatchmakingFlow.fingerprint(key6)]
		var actual: Array[String] = []
		for key: Dictionary in spec.frozen_members:
			actual.append(MatchmakingFlow.fingerprint(key))
		expected.sort()
		actual.sort()
		test._check(actual == expected and spec.flow_epoch == epoch and spec.owner,
			"the ticket names exactly the frozen admitted group, the local player included")
	_finish(_attempt(), MatchmakingService.Outcome.NO_MATCH)
	_complete_activity()
	_ready_all()
	test._check(flow.phase == MatchmakingFlow.Phase.FREEZING, "the restored group freezes again")
	party.fake_add_member(party.fake_staging, lurker)
	NetManager._on_context_changed(party.fake_staging)
	test._check(flow.phase == MatchmakingFlow.Phase.GATHERING and matchmaking.fake_creates.size() == 1,
		"native membership diverging from the frozen group stops the freeze with no ticket")
	_remove_member(party.fake_staging, "freeze-lurker")
	_complete_activity()
	_ready_all()
	test._check(flow.phase == MatchmakingFlow.Phase.FREEZING, "the group freezes a third time")
	NetManager._apply_ready_state(6, false)
	test._check(flow.phase == MatchmakingFlow.Phase.GATHERING and matchmaking.fake_creates.size() == 1
		and not (NetManager.players[5] as PlayerState).is_ready and not NetManager.local_player().is_ready,
		"an unready landing mid-freeze stops it, creates no ticket and returns everyone to unready")
	_complete_activity()
	_ready_all()
	test._check(flow.phase == MatchmakingFlow.Phase.FREEZING, "the group freezes a fourth time")
	NetManager.players.erase(6)
	_remove_member(party.fake_staging, "freeze-guest-6")
	NetManager.roster_changed.emit()
	test._check(flow.phase == MatchmakingFlow.Phase.GATHERING and matchmaking.fake_creates.size() == 1
		and flow.reason == MatchmakingFlow.TEXT_GROUP_CHANGED,
		"a member leaving while the lobby locks stops the freeze and says why")
	await _teardown(test)


# --- F3: the social veto and restoration ------------------------------------------

func _f3_social_veto_and_restoration(test: Node) -> void:
	print("CASE: F3 a frozen group's activity is retired, cannot be republished, and is restored exactly")
	await _setup(test, "flow-social")
	var flow := await _open_group(test)
	if flow == null:
		await _teardown(test)
		return
	var platform: PlatformSession = NetManager._platform
	_add_guest(5, "social-guest-5")
	NetManager.roster_changed.emit()
	platform.publish_activity()
	_complete_activity(false)
	test._check(platform._activity_update_queued and platform._activity_retry_pending,
		"a coalesced refresh and a publish retry are both waiting when the group freezes")
	var deletes := activity.sdk.deletes.size()
	_ready_all()
	test._check(flow.phase == MatchmakingFlow.Phase.FREEZING and not platform.wants_activity()
		and activity.sdk.deletes.size() == deletes + 1, "freezing retires this member's activity")
	var sets := activity.sdk.calls.size()
	_ack_all(flow)
	test._check(flow.phase == MatchmakingFlow.Phase.CREATING_TICKET, "the frozen group's ticket is being created")
	NetManager.roster_changed.emit()
	clock.advance(1.0)
	NetManager._set_accepting_joins(true)
	NetManager._set_accepting_joins(false)
	platform.begin_activity_handover()
	platform.publish_activity()
	platform.end_activity_handover()
	_complete_activity()
	test._check(activity.sdk.calls.size() == sets and not platform.wants_activity(),
		"the queued refresh, the retry, an admission change and a handover cannot republish a searching group")
	var attempt := _attempt()
	_progress(attempt, MatchmakingService.STATUS_WAITING_FOR_MATCH, "ticket-1")
	var control: Dictionary = party.fake_search_control.get(party.fake_staging.context_id, {})
	test._check(flow.phase == MatchmakingFlow.Phase.SEARCHING
		and String(control.get("phase", "")) == MatchmakingFlow.ENVELOPE_SEARCHING
		and String(control.get("ticket_id", "")) == "ticket-1",
		"the usable ticket id is published once the service reports it")
	_finish(attempt, MatchmakingService.Outcome.NO_MATCH)
	control = party.fake_search_control.get(party.fake_staging.context_id, {})
	var restored := _last_set()
	test._check(flow.phase == MatchmakingFlow.Phase.GATHERING and NetManager.is_accepting_joins()
		and not bool(party.fake_locked.get(party.fake_staging.context_id, true))
		and not (NetManager.players[5] as PlayerState).is_ready and not NetManager.local_player().is_ready,
		"no match returns the same group to Gathering: unlocked, reopened and all unready")
	test._check(String(control.get("phase", "")) == MatchmakingFlow.ENVELOPE_GATHERING
		and String(control.get("ticket_id", "")).is_empty()
		and String(control.get("reason_code", "")) == String(MatchmakingFlow.REASON_NO_MATCH)
		and flow.reason == MatchmakingFlow.TEXT_NO_MATCH,
		"the ticket id is withdrawn and the reason is kept for every member to read")
	test._check(activity.sdk.calls.size() == sets + 1 and restored != null
		and restored.restriction == ActivityService.JOIN_RESTRICTION and restored.maximum == 4 and restored.count == 2
		and restored.group == STAGING_ID and restored.connection == STAGING_CONNECTION,
		"the restored group is advertised once more: followed, four slots, the same lobby")
	_complete_activity()
	_ready_all()
	_ack_all(flow)
	party.fake_fail_unlock = true
	_finish(_attempt(), MatchmakingService.Outcome.FAILED, MatchmakingFlow.REASON_SEARCH_FAILED, "Injected service failure.")
	test._check(flow.phase == MatchmakingFlow.Phase.RESTORING_STAGING and flow.restoration_failed
		and not NetManager.is_accepting_joins() and not platform.wants_activity()
		and flow.reason == "Injected service failure.",
		"an unconfirmed unlock keeps the group closed and unadvertised, with the reason")
	party.fake_fail_unlock = false
	NetManager.retry_matchmaking_restore()
	_complete_activity()
	test._check(flow.phase == MatchmakingFlow.Phase.GATHERING and not flow.restoration_failed
		and NetManager.is_accepting_joins() and platform.wants_activity(),
		"Retry reopens the group once the unlock is confirmed")
	flow.arranged_context = party.fake_arranged
	flow._set_phase(MatchmakingFlow.Phase.REMATCH_GATHERING)
	var rematch := _last_set()
	test._check(rematch != null and rematch.restriction == ActivityService.AUDIENCE_INVITE_ONLY and rematch.maximum == 4
		and rematch.group == ARRANGED_ID and rematch.connection == ARRANGED_CONNECTION,
		"an arranged rematch advertises the invite-only audience for its own lobby")
	await _teardown(test)


# --- F12: the handoff's local reset -------------------------------------------------

func _f12_local_reset_owner(test: Node) -> void:
	print("CASE: F12 the handoff ends the staging session completely before any await (arranged owner)")
	await _setup(test, "reset-owner")
	var privileges := LoggingPrivileges.new()
	privileges.fake_log = party.fake_calls
	Services._privileges = privileges
	var profiles := ProfileService.new()
	Services._profiles = profiles
	var flow := await _open_group(test)
	if flow == null:
		await _teardown(test)
		return
	_add_guest(7, "reset-staging-guest")
	NetManager.roster_changed.emit()
	profiles._gamertag_by_peer[7] = "Verified Staging Guest"
	var staging_session := NetManager.session_id()
	var control_generation := chat._control_generation
	_arm(flow, true)
	test._check(not NetManager._platform.wants_activity(), "the armed group's activity is already retired")
	var arranged_peer: Variant = TransportPeer.new(NetManager.HOST_PEER_ID)
	party.fake_arranged_peer = arranged_peer
	party.fake_calls.clear()
	var sets := activity.sdk.calls.size()
	await flow.switch_transport()
	var observed := _observed("leave_transport")
	test._check(not observed.is_empty() and observed.get("peer") == null and observed.get("multiplayer_peer") == null
		and int(observed.get("session", -1)) == 0 and int(observed.get("players", -1)) == 0
		and observed.get("local_player") == null and String(observed.get("join_code", "x")).is_empty()
		and not bool(observed.get("accepting", true)) and observed.get("request") == null,
		"the old session was over before the first await: no peer, no session id, empty roster, closed gate")
	test._check(profiles._gamertag_by_peer.is_empty() and chat._control_generation > control_generation,
		"verified names under reused peer ids and the old chat session were cleared")
	test._check(party.fake_calls.size() >= 3
		and party.fake_calls[0] == "leave_transport:%d" % party.fake_staging.context_id
		and party.fake_calls[1] == "privilege:%d" % PrivilegeService.COMMUNICATIONS
		and party.fake_calls[2] == "prepare",
		"the old transport is left, then chat privilege is resolved again, then the arranged network is prepared")
	test._check(flow.is_current() and flow.staging_context == party.fake_staging
		and flow.arranged_context == party.fake_arranged and NetManager._entry_error() == NetManager.FLOW_BUSY,
		"the flow kept its identity, both lobby contexts and the entry lease across the gap")
	test._check(NetManager.session_id() != 0 and NetManager.session_id() != staging_session and NetManager.is_host()
		and NetManager.players.keys() == [NetManager.HOST_PEER_ID] and NetManager.local_player() != null
		and NetManager.local_player().entity_id == "reset-owner" and NetManager.is_accepting_joins()
		and NetManager._active_join_request == null and flow.phase == MatchmakingFlow.Phase.ADMITTING_COHORT,
		"the arranged owner is peer 1 of a fresh session holding only itself, gate open, no self-admission request")
	var bootstrap := _observed("publish")
	test._check(bool(bootstrap.get("accepting", false))
		and party.fake_published_phase == MatchmakingFlow.SESSION_PHASE_BOOTSTRAP
		and String(party.fake_calls.back()) == "publish:bootstrap:9",
		"the bootstrap descriptor is published only after the new gate is open")
	test._check(activity.sdk.calls.size() == sets and not NetManager._platform.wants_activity()
		and not NetManager.everyone_ready(), "the bootstrap is never advertised and no staging readiness survives")
	arranged_peer.connect_remote(5)
	test._check(arranged_peer.sent.size() > 0 and NetManager.players.keys() == [NetManager.HOST_PEER_ID],
		"a newcomer's roster replay is built from the fresh roster alone")
	await _teardown(test)


func _f12_local_reset_guest(test: Node) -> void:
	print("CASE: F12 a staging guest's reset leaves no stale local player, and admission uses a fresh request")
	await _setup(test, "reset-guest")
	var privileges := LoggingPrivileges.new()
	privileges.fake_log = party.fake_calls
	Services._privileges = privileges
	var staging_peer: Variant = TransportPeer.new(7)
	test._check(NetManager._bind_peer(staging_peer), "the guest binds its staging transport")
	NetManager._is_offline = false
	staging_peer.connect_remote(NetManager.HOST_PEER_ID)
	var host := PlayerState.new()
	host.peer_id = NetManager.HOST_PEER_ID
	host.display_name = "Staging Owner"
	NetManager.players[NetManager.HOST_PEER_ID] = host
	var flow := NetManager._new_flow(MatchmakingFlow.Role.GUEST, NRTypes.GameModeType.DEATHMATCH)
	flow.start_guest(party.fake_staging)
	test._check(NetManager.local_peer_id() == 7 and NetManager.local_player() != null
		and NetManager.local_player().peer_id == 7 and NetManager.players.size() == 2,
		"the staging guest holds the old owner at peer 1 and itself at peer 7")
	_arm(flow, false)
	var arranged_peer: Variant = TransportPeer.new(9)
	party.fake_arranged_peer = arranged_peer
	party.fake_calls.clear()
	flow.switch_transport()
	var observed := _observed("leave_transport")
	test._check(int(observed.get("local_peer_id", 0)) == NetManager.HOST_PEER_ID and observed.get("local_player") == null
		and int(observed.get("players", -1)) == 0 and observed.get("request") == null,
		"with no peer bound local_peer_id() falls back to 1, yet local_player() is null -- never the old owner")
	test._check(party.fake_calls.size() >= 3
		and party.fake_calls[0] == "leave_transport:%d" % party.fake_staging.context_id
		and party.fake_calls[1] == "privilege:%d" % PrivilegeService.COMMUNICATIONS
		and party.fake_calls[2] == "join_transport",
		"the old transport is left, chat privilege is resolved again, then the arranged network is joined")
	var request: JoinRequest = NetManager._active_join_request
	test._check(request != null and request.is_flow_owned() and request.flow_id == flow.id and request.is_pending()
		and not request.admitted and flow.admission_request == request and not NetManager.is_host()
		and NetManager.local_peer_id() == 9 and flow.phase == MatchmakingFlow.Phase.ADMITTING_COHORT,
		"a fresh flow-owned admission request exists on the new session only")
	test._check(not NetManager.start_offline() and NetManager.last_error == NetManager.FLOW_BUSY,
		"the lease still refuses Practice while the guest waits for admission")
	arranged_peer.connect_remote(NetManager.HOST_PEER_ID)
	NetManager._accept_join()
	test._check(request != null and request.admitted and request.session_id == NetManager.session_id(),
		"the acceptance is stamped against the new live session")
	clock.advance(MatchmakingFlow.POLL_SECONDS)
	test._check(request != null and request.succeeded() and NetManager._active_join_request == null
		and NetManager.players.keys() == [9],
		"the flow consumes its own admission, and the new roster holds nothing from staging")
	await _teardown(test)


# --- F13: the lease, lifecycle and cleanup with no transport bound ------------------

func _f13_transportless_lease_and_lifecycle(test: Node) -> void:
	print("CASE: F13 lease, invite confirmation, suspend report and offline grace all hold with no peer bound")
	await _setup(test, "lease-owner")
	ScreenManager.set_container(test)
	var flow := await _open_group(test)
	if flow == null:
		await _teardown(test)
		return
	_arm(flow, true)
	party.fake_arranged_peer = TransportPeer.new(NetManager.HOST_PEER_ID)
	party.fake_block_prepare = true
	flow.switch_transport()
	test._check(not NetManager.has_session() and NetManager.has_online_flow() and NetManager.is_online_flow_live()
		and flow.phase == MatchmakingFlow.Phase.SWITCHING_TRANSPORT, "the flow is live with no transport bound")
	test._check(not NetManager.start_offline() and NetManager.last_error == NetManager.FLOW_BUSY,
		"Practice is refused while the flow holds the lease")
	test._check(not await NetManager.host_match() and NetManager.last_error == NetManager.FLOW_BUSY,
		"Host Match is refused")
	var join := NetManager.join_by_code("ABCDE")
	test._check(join.outcome == JoinRequest.Outcome.FAILED and join.reason == NetManager.FLOW_BUSY,
		"Join by code is refused")
	test._check(not await NetManager.start_matchmaking() and NetManager.last_error == NetManager.FLOW_BUSY
		and NetManager._flow == flow and flow.is_live(), "a second group is refused, and the first survives every refusal")

	var menu := NRScreen.new()
	menu.scene_file_path = ScreenManager.MAIN_MENU
	ScreenManager._stack.append(menu)
	party.fake_block_leave = true
	InviteRouter._on_join_requested({"connection_string": "friend-lobby"})
	var confirm: Variant = ScreenManager.current_screen()
	var confirming: bool = confirm != null and confirm.scene_file_path == ScreenManager.DIALOG_BOX
	test._check(confirming and confirm._title == "Join Match" and InviteRouter._joining,
		"an invite during the transportless handoff still asks before leaving the group")
	if confirming:
		confirm._ok_button.pressed.emit()
	clock.advance(MatchmakingFlow.CANCEL_GRACE_SECONDS)
	test._check(NetManager.has_online_flow() and not NetManager.is_online_flow_live()
		and flow.phase == MatchmakingFlow.Phase.QUARANTINED and InviteRouter.has_pending_invite()
		and not InviteRouter._joining and not InviteRouter._ready_to_join()
		and not party.fake_calls.has("join_by_connection_string"),
		"while the old group's cleanup is quarantined, the invite is kept rather than spent on an entry refusal")
	party.fake_block_leave = false
	party.fake_leave_released.emit()
	test._check(not NetManager.has_online_flow() and InviteRouter._ready_to_join(),
		"once the flow's cleanup settles, the kept invite may be redeemed")
	InviteRouter.decline_pending_invite()
	ScreenManager._stack.erase(menu)
	menu.queue_free()
	ScreenManager.clear()
	party.fake_block_prepare = false
	party.fake_prepare_released.emit()

	var second := await _open_group(test)
	if second == null:
		await _teardown(test)
		return
	_arm(second, true)
	party.fake_block_prepare = true
	second.switch_transport()
	party.fake_calls.clear()
	test._check(not NetManager.has_session() and second.is_live(), "a second group is mid-handoff with no peer bound")
	test._check(NetManager.abandon_for_suspend(), "suspend reports the interrupted group even with no peer bound")
	test._check(second.retired and NetManager.has_online_flow() and not NetManager.is_online_flow_live()
		and party.fake_calls.is_empty(), "suspend retires the flow synchronously and starts no native work")
	await NetManager.finish_suspend_teardown()
	test._check(not NetManager.has_online_flow()
		and party.fake_calls.has("leave_lobby:%d" % party.fake_arranged.context_id)
		and party.fake_calls.has("leave_lobby:%d" % party.fake_staging.context_id),
		"resume releases both lobbies through their own contexts, then the lease")
	party.fake_block_prepare = false
	party.fake_prepare_released.emit()

	var connectivity := ConnectivityService.new()
	Services._connectivity = connectivity
	var disconnects: Array[String] = []
	var observe_disconnect := func() -> void: disconnects.append(NetManager.last_disconnect_reason)
	NetManager.server_disconnected.connect(observe_disconnect)
	for started_before_swap: bool in [false, true]:
		var grace_flow := await _open_group(test)
		if grace_flow == null:
			break
		_arm(grace_flow, true)
		party.fake_block_prepare = true
		connectivity._online = false
		if started_before_swap:
			NetManager._on_connectivity_changed(false)
		grace_flow.switch_transport()
		if not started_before_swap:
			NetManager._on_connectivity_changed(false)
		test._check(not NetManager.has_session() and grace_flow.is_live(),
			"the flow is live and transportless while the offline grace runs")
		clock.advance(NetManager._CONNECTIVITY_GRACE_SECONDS)
		test._check(grace_flow.retired and not NetManager.has_online_flow()
			and disconnects.size() == (2 if started_before_swap else 1)
			and NetManager.last_disconnect_reason == connectivity.offline_reason(),
			"sustained offline ends the flow with the offline reason (grace started %s the swap)"
				% ("before" if started_before_swap else "after"))
		connectivity._online = true
		party.fake_block_prepare = false
		party.fake_prepare_released.emit()
	NetManager.server_disconnected.disconnect(observe_disconnect)
	Services._connectivity = null
	await _teardown(test)


func _f13_quit_waits_for_flow_cleanup(test: Node) -> void:
	print("CASE: F13 quit with no peer bound waits for the flow's own cleanup inside the one quit budget")
	await _setup(test, "quit-flow")
	var flow := await _open_group(test)
	if flow == null:
		await _teardown(test)
		return
	_arm(flow, true)
	party.fake_arranged_peer = TransportPeer.new(NetManager.HOST_PEER_ID)
	party.fake_block_prepare = true
	flow.switch_transport()
	test._check(not NetManager.has_session() and NetManager.has_pending_online_work(),
		"a transportless flow still counts as online work to drain")
	# The real quit path stops all audio; the harness's audio stub has no players to stop.
	var audio_script: Script = AudioManager.get_script()
	AudioManager.set_script(Review.QuietAudio)
	var app := preload("res://scenes/main.tscn").instantiate()
	app.set_script(Review.MainProbe)
	test.add_child(app)
	party.fake_block_leave = true
	party.fake_calls.clear()
	app.request_shutdown()
	test._check(app._quit_pending and app.quit_calls == 0
		and party.fake_calls.has("leave_lobby:%d" % party.fake_arranged.context_id),
		"quit waits on the flow's scoped cleanup instead of the fire-and-forget leave")
	party.fake_block_leave = false
	party.fake_leave_released.emit()
	test._check(app.quit_calls == 1 and not NetManager.has_online_flow()
		and party.fake_calls.has("leave_transport:%d" % party.fake_staging.context_id)
		and party.fake_calls.has("drain"),
		"the drain finishes the flow's lobbies and transport, then Party's owned work, then quits")
	party.fake_block_prepare = false
	party.fake_prepare_released.emit()
	await test.get_tree().process_frame
	ScreenManager.clear()
	app.queue_free()
	await test.get_tree().process_frame
	ScreenManager.set_container(test)
	Services._shutting_down = false
	AudioManager.set_script(audio_script)
	PlayerProfile.apply_dict(PlayerProfile.to_dict())
	await _teardown(test)


# --- P0 fences: what keeps the unfinished flow out of players' reach ----------------

## The public fences around the kept Phase 1 skeleton, asserted with the production
## MatchmakingService: the feature flag is off, the menu offers no matchmaking row, the
## owner entry refuses before any staging work, and an invitation that resolves to a
## staging lobby is refused and its lobby left. The last is NetManager's defense in
## depth only -- PartyService refuses a matchmaking-kind lobby before any Party work of
## its own, and that ingress fence is proven by the service suite, not here.
func _p0_public_fences_hold(test: Node) -> void:
	print("CASE: P0 fences hold: flag off, no matchmaking menu row, owner and invited-guest entry refused")
	await _setup(test, "fence-player")
	var production := MatchmakingService.new()
	Services._matchmaking = production
	var unavailable := "Quick Match is not available in this build yet."
	test._check(not MatchmakingService._FLOW_IMPLEMENTED and not production.is_available()
		and not Services.quick_match_available() and Services.quick_match_unavailable_reason() == unavailable,
		"the flow flag stays off, so the production service reports Quick Match unavailable")
	test._check(NRProtocol.RPC_SET_VERSION == 3 and NetManager.has_method("_receive_flow_phase")
		and NetManager.has_method("_submit_flow_ack") and NetManager.has_method("_submit_flow_leave"),
		"the three flow RPCs stay declared while the feature is off, so the RPC set version stays 3")

	test._check(not await NetManager.start_matchmaking() and NetManager.last_error == unavailable
		and not NetManager.has_online_flow() and not NetManager.has_session()
		and not party.fake_calls.has("create_staging"),
		"the owner entry is refused with the unavailable reason before any staging work")

	party.fake_join_result = {
		"ok": true, "peer": TransportPeer.new(7), "code": "", "error": "",
		"kind": PartyService.LOBBY_KIND_STAGING, "context": party.fake_staging,
	}
	var request := NetManager.join_by_invite(STAGING_CONNECTION)
	await test.get_tree().process_frame
	test._check(request.outcome == JoinRequest.Outcome.FAILED and request.reason == unavailable
		and not NetManager.has_online_flow() and not NetManager.has_session()
		and NetManager._pending_join_context == null
		and party.fake_calls.has("leave_lobby:%d" % party.fake_staging.context_id)
		and party.fake_calls.has("leave_transport:%d" % party.fake_staging.context_id),
		"an invitation that resolves to a staging lobby is refused, bound to nothing, and its lobby is left")

	# The real main menu, as a player sees it: the shipped rows are there and nothing
	# offers matchmaking, at the top level or in the Join submenu.
	var audio_script: Script = AudioManager.get_script()
	AudioManager.set_script(Review.QuietAudio)
	var app := preload("res://scenes/main.tscn").instantiate()
	app.set_script(Review.MainProbe)
	test.add_child(app)
	var menu: Variant = ScreenManager.push(ScreenManager.MAIN_MENU)
	var labels := _row_labels(menu)
	if menu != null:
		menu._build_join_menu()
		labels.append_array(_row_labels(menu))
	var offers_matchmaking := false
	for label: String in labels:
		var lowered := label.to_lower()
		if lowered.contains("quick") or lowered.contains("matchmak") or lowered.contains("find match") \
				or lowered.contains("search"):
			offers_matchmaking = true
	test._check(labels.has("Host Match") and labels.has("Join Match") and labels.has("Lobby Code")
		and not offers_matchmaking,
		"the main menu and its Join submenu offer no matchmaking row")
	await test.get_tree().process_frame
	ScreenManager.clear()
	app.queue_free()
	await test.get_tree().process_frame
	ScreenManager.set_container(test)
	AudioManager.set_script(audio_script)
	PlayerProfile.apply_dict(PlayerProfile.to_dict())
	await _teardown(test)


## The captions of a menu screen's current button rows.
func _row_labels(menu: Variant) -> Array[String]:
	var labels: Array[String] = []
	if menu == null:
		return labels
	for row: Control in menu._menu_list.rows():
		if row is NRButton:
			labels.append(String((row as NRButton).text))
	return labels


## The requested mode's real configuration decides, not a constant restated by the caller.
## The shipped Deathmatch resource itself is retuned for the case -- read through
## Assets.game_mode(), exactly as the service reads it -- and restored afterwards. A
## Deathmatch set to three or five players is refused at the owner entry before any
## staging work, and a retune after the group opened stops the next ticket before it is
## created. Codes and reasons come from the service's own answer; a missing configuration
## is the service suite's case, reached through its resource seam.
func _p0_profile_gate_refuses_direct_entry(test: Node) -> void:
	print("CASE: P0 profile gate: the mode's real configuration admits the group and every ticket")
	await _setup(test, "profile-owner")
	var deathmatch := Assets.game_mode(NRTypes.GameModeType.DEATHMATCH)
	var configured := deathmatch.player_count
	for retuned: int in [3, 5]:
		deathmatch.player_count = retuned
		var profile: Dictionary = matchmaking.runtime_profile(NRTypes.GameModeType.DEATHMATCH)
		var opened: bool = await NetManager.start_matchmaking()
		test._check(not opened and not bool(profile.get("ok", true))
			and not String(profile.get("reason_code", "")).is_empty()
			and not NetManager.last_error.is_empty() and NetManager.last_error == String(profile.get("reason", ""))
			and not NetManager.has_online_flow() and not party.fake_calls.has("create_staging")
			and matchmaking.fake_creates.is_empty(),
			"a Deathmatch configured for %d players is refused at entry, before any staging or ticket work" % retuned)
	deathmatch.player_count = configured
	var flow := await _open_group(test)
	if flow == null:
		await _teardown(test)
		return
	test._check(configured == 4 and flow.match_size == configured,
		"the shipped configuration admits the group with its four-player match size")
	NetManager.set_local_ready(true)
	var spec: MatchmakingService.SearchSpec = null
	if not matchmaking.fake_creates.is_empty():
		spec = matchmaking.fake_creates[0]
	test._check(spec != null and spec.mode == NRTypes.GameModeType.DEATHMATCH and spec.expected_match_count == configured,
		"the owner's ticket carries the requested mode and the configured player count")
	_finish(_attempt(), MatchmakingService.Outcome.NO_MATCH)
	_complete_activity()
	deathmatch.player_count = 5
	var retuned_profile: Dictionary = matchmaking.runtime_profile(NRTypes.GameModeType.DEATHMATCH)
	NetManager.set_local_ready(true)
	deathmatch.player_count = configured
	test._check(matchmaking.fake_creates.size() == 1 and flow.phase == MatchmakingFlow.Phase.GATHERING
		and flow.reason_code == StringName(String(retuned_profile.get("reason_code", "")))
		and flow.reason == String(retuned_profile.get("reason", "")) and NetManager.is_accepting_joins(),
		"a retune after the group opened stops the next ticket, with the service's code and reason")
	await _teardown(test)


## Every attempt the flow lets go of goes back to the service's typed retire(): after its
## outcome or match data are copied, before observation stops. An attempt whose native
## cleanup is still owed -- a cancellation the service could not confirm -- keeps the
## group closed and visibly cancelling, and a leaving flow keeps the lease, until the
## service reports the ticket safe. A new search waits for it too.
func _p0_settled_attempts_are_retired(test: Node) -> void:
	print("CASE: P0 settled attempts are retired; unresolved cancellation holds the group and the lease")
	await _setup(test, "retire-owner")
	var flow := await _open_group(test)
	if flow == null:
		await _teardown(test)
		return
	matchmaking.fake_log = party.fake_calls
	var staging_id := party.fake_staging.context_id

	party.fake_calls.clear()
	NetManager.set_local_ready(true)
	var no_match := _attempt()
	_finish(no_match, MatchmakingService.Outcome.NO_MATCH)
	var retire_mark := "retire:%d" % no_match.flow_epoch
	test._check(matchmaking.fake_retired.has(no_match) and flow.ticket == null
		and party.fake_calls.find(retire_mark) >= 0
		and party.fake_calls.find(retire_mark) < party.fake_calls.find("post:gathering"),
		"a no-match result is retired after its outcome is copied and before the group is restored")
	_complete_activity()

	NetManager.set_local_ready(true)
	var cancelled := _attempt()
	_progress(cancelled, MatchmakingService.STATUS_WAITING_FOR_MATCH, "ticket-unresolved")
	NetManager.cancel_matchmaking_search()
	test._check(matchmaking.fake_cancels.has(cancelled) and flow.phase == MatchmakingFlow.Phase.CANCELLING,
		"Cancel Search asks the service to cancel and waits for its answer")
	cancelled.cleanup_pending = true
	cancelled.settle(MatchmakingService.Outcome.FAILED, &"cancel_unconfirmed", "The match service did not confirm cancellation.")
	var creates := matchmaking.fake_creates.size()
	NetManager.set_local_ready(true)
	test._check(matchmaking.fake_retired.has(cancelled) and flow.phase == MatchmakingFlow.Phase.CANCELLING
		and flow.cancel_unresolved and not NetManager.is_accepting_joins()
		and bool(party.fake_locked.get(staging_id, false)) and NetManager.is_online_flow_live()
		and matchmaking.fake_creates.size() == creates and not NetManager.can_customize(),
		"an unconfirmed cancellation keeps the group closed and visibly cancelling, with no new search")
	cancelled.cleanup_pending = false
	clock.advance(MatchmakingFlow.POLL_SECONDS)
	test._check(flow.phase == MatchmakingFlow.Phase.GATHERING and not flow.cancel_unresolved
		and NetManager.is_accepting_joins() and not bool(party.fake_locked.get(staging_id, true))
		and flow.reason == MatchmakingFlow.TEXT_CANCELLED,
		"once the service reports the ticket safe, the group is restored with the reason it already had")
	_complete_activity()

	NetManager.set_local_ready(true)
	var matched := _attempt()
	matched.match_id = "match-p0"
	matched.arrangement = "arrangement-p0"
	party.fake_calls.clear()
	matched.settle(MatchmakingService.Outcome.MATCHED)
	var matched_mark := "retire:%d" % matched.flow_epoch
	test._check(matchmaking.fake_retired.has(matched) and flow.match_id == "match-p0"
		and flow.arrangement == "arrangement-p0" and party.fake_calls.find(matched_mark) >= 0
		and party.fake_calls.find(matched_mark) < party.fake_calls.find("join_arranged:arrangement-p0"),
		"a match is retired after its handoff data are copied and before the arranged join starts")
	test._check(not NetManager.has_online_flow() and NetManager.last_disconnect_reason == "Injected arranged join failure.",
		"a refused arranged join still ends the group with its reason")

	matchmaking.fake_pending_cleanup = true
	test._check(not await NetManager.start_matchmaking()
		and NetManager.last_error == NetManager._PREVIOUS_SEARCH_FINISHING and not NetManager.has_online_flow(),
		"a new search waits while the service still owes cleanup for an earlier ticket")
	matchmaking.fake_pending_cleanup = false

	var leaving := await _open_group(test)
	if leaving == null:
		await _teardown(test)
		return
	NetManager.set_local_ready(true)
	var owed := _attempt()
	matchmaking.fake_retire_leaves_cleanup = true
	NetManager.leave_match()
	test._check(owed.retired and owed.outcome == MatchmakingService.Outcome.SUPERSEDED
		and NetManager.has_online_flow() and not NetManager.is_online_flow_live()
		and NetManager._entry_error() == NetManager._PREVIOUS_SESSION_FINISHING and not NetManager.start_offline(),
		"a leaving group whose ticket cleanup is still owed keeps the online-entry lease")
	clock.advance(MatchmakingFlow.CANCEL_GRACE_SECONDS)
	test._check(leaving.phase == MatchmakingFlow.Phase.QUARANTINED and NetManager.has_online_flow(),
		"past the cancellation grace the held lease is shown as quarantine")
	owed.cleanup_pending = false
	clock.advance(MatchmakingFlow.POLL_SECONDS)
	test._check(not NetManager.has_online_flow(), "the lease is released once the service reports the ticket safe")
	matchmaking.fake_retire_leaves_cleanup = false
	await _teardown(test)


# --- RB2: a quit with only Party's own cleanup or recovery left ----------------------

## Installs production PartyService teardown in place of the flow double, on the case clock.
func _install_recovery_party() -> RecoveryParty:
	var recovery := RecoveryParty.new(chat)
	recovery.fake_clock = clock
	recovery.configure_clock(clock)
	Services._party = recovery
	return recovery


## Ends a hosted session the way a failed leave does: an earlier leave step failed, so the
## next global leave falls back to the scoped Party/Lobby recovery. Nothing else is left
## behind -- no peer, no flow, no scoped context and no owned Party work.
func _begin_recovery(recovery: RecoveryParty) -> void:
	recovery._cleanup_failed = true
	NetManager.leave_match()


## The real main scene with the quit probe, silenced, so request_shutdown() runs the
## production quit path and the final exit is counted rather than performed.
func _open_quit_probe(test: Node) -> Node:
	_probe_audio = AudioManager.get_script()
	AudioManager.set_script(Review.QuietAudio)
	var app := preload("res://scenes/main.tscn").instantiate()
	app.set_script(Review.MainProbe)
	test.add_child(app)
	return app


## Closes the probe and puts the flow double back before the harness teardown, which
## leaves through it.
func _end_rb2_case(test: Node, app: Node) -> void:
	await test.get_tree().process_frame
	ScreenManager.clear()
	app.queue_free()
	await test.get_tree().process_frame
	ScreenManager.set_container(test)
	Services._shutting_down = false
	AudioManager.set_script(_probe_audio)
	PlayerProfile.apply_dict(PlayerProfile.to_dict())
	Services._party = party
	await _teardown(test)


## Party's own recovery is the only online work left, yet the quit takes the awaited drain:
## frames keep coming on the one budget, and the quit exits once, after the confirmation.
func _rb2_quit_drains_held_party_recovery(test: Node) -> void:
	print("CASE: RB2 quit with only Party's held recovery left waits in the drain and exits once it confirms")
	await _setup(test, "quit-recovery")
	var recovery := _install_recovery_party()
	recovery.fake_runtime.party.fake_held = true
	_begin_recovery(recovery)
	test._check(recovery.is_cleanup_pending() and recovery.recovery_error.is_empty(),
		"Party's recovery is running and has not failed")
	test._check(recovery.fake_runtime.party.fake_calls == 1 and recovery.fake_runtime.multiplayer.fake_calls == 0,
		"the scoped Party shutdown is held at the SDK boundary")
	test._check(not NetManager.has_session() and not NetManager.has_online_flow()
		and NetManager._pending_join_context == null, "no peer, flow or scoped lobby is left to report the recovery")
	test._check(not recovery.has_owned_work(), "Party reports no owned scoped work")
	test._check(NetManager.has_pending_online_work(), "Party's own recovery counts as online work to drain")
	var app := _open_quit_probe(test)
	app.request_shutdown()
	var budget: int = app._quit_deadline_msec
	test._check(app._quit_pending, "the quit is deferred into the drain")
	test._check(app.quit_calls == 0, "the quit does not exit while the recovery is held")
	await test.get_tree().process_frame
	clock.advance(1.0)
	test._check(app._quit_pending and app.quit_calls == 0, "frames keep coming and the drain keeps waiting")
	test._check(app._quit_deadline_msec == budget, "the drain does not renew the quit budget")
	recovery.fake_runtime.party.fake_held = false
	recovery.fake_runtime.party.fake_confirmed.emit({"ok": true, "message": "Injected scoped shutdown."})
	test._check(recovery.fake_runtime.multiplayer.fake_calls == 1, "the Lobby shutdown follows the Party confirmation")
	test._check(not recovery.is_cleanup_pending() and recovery.recovery_error.is_empty(),
		"both confirmations finish Party's recovery")
	clock.advance(PartyService.POLL_INTERVAL)
	test._check(app.quit_calls == 1, "the drain's next poll sees the confirmation and the quit exits once")
	test._check(app._quit_deadline_msec == budget, "the whole quit ran on the one budget")
	await _end_rb2_case(test, app)


## A recovery that never confirms cannot hold the quit past its one budget: the drain waits
## to the budget's last poll, the quit then exits once, and the late confirmation finishes
## Party's recovery without quitting again.
func _rb2_quit_budget_ends_held_party_recovery(test: Node) -> void:
	print("CASE: RB2 a Party recovery that never confirms is cut off by the one quit budget and cannot quit twice")
	await _setup(test, "quit-recovery-budget")
	var recovery := _install_recovery_party()
	recovery.fake_runtime.party.fake_held = true
	_begin_recovery(recovery)
	test._check(NetManager.has_pending_online_work(), "the held recovery counts as online work to drain")
	var app := _open_quit_probe(test)
	app.request_shutdown()
	var budget: int = app._quit_deadline_msec
	test._check(app._quit_pending and app.quit_calls == 0, "the quit waits in the drain")
	# The budget is an absolute deadline on the clock the drain polls, so the case moves that
	# clock to one millisecond short of it, then across it.
	clock.advance(float(budget - 1 - clock.now_msec()) / 1000.0)
	test._check(app.quit_calls == 0, "one millisecond before the budget ends the drain is still waiting")
	test._check(recovery.is_cleanup_pending(), "the recovery is still held at that point")
	clock.advance(PartyService.POLL_INTERVAL)
	test._check(app.quit_calls == 1, "the drain stops at the budget and the quit exits")
	test._check(recovery.is_cleanup_pending(), "the exit leaves the recovery held rather than faking it complete")
	test._check(app._quit_deadline_msec == budget, "the budget that ended was the caller's own")
	recovery.fake_runtime.party.fake_held = false
	recovery.fake_runtime.party.fake_confirmed.emit({"ok": true, "message": "Injected scoped shutdown."})
	test._check(not recovery.is_cleanup_pending(), "the late confirmation still finishes Party's recovery")
	test._check(app.quit_calls == 1, "the late confirmation cannot quit a second time")
	await _end_rb2_case(test, app)


## The baseline: with nothing online at all the drain returns at once, and the quit is not
## held -- it takes the fire-and-forget leave and exits, starting no Party work.
func _rb2_quit_without_online_work_exits_at_once(test: Node) -> void:
	print("CASE: RB2 baseline: with no online work the drain returns at once and the quit exits at once")
	await _setup(test, "quit-idle")
	var recovery := _install_recovery_party()
	test._check(not recovery.is_cleanup_pending(), "Party has no cleanup or recovery running")
	test._check(not NetManager.has_pending_online_work(), "nothing online is pending")
	var drained := [false]
	var drain := func() -> void:
		await NetManager.drain_online_work(clock.deadline_after(8.0))
		drained[0] = true
	drain.call()
	test._check(bool(drained[0]), "the drain returns at once, without waiting on the clock")
	var app := _open_quit_probe(test)
	app.request_shutdown()
	test._check(app.quit_calls == 1, "the quit exits at once")
	test._check(not app._quit_pending, "no drain is left pending behind the exit")
	test._check(recovery.fake_runtime.party.fake_calls == 0 and recovery.fake_runtime.multiplayer.fake_calls == 0,
		"neither the drain nor the quit started a Party recovery")
	await _end_rb2_case(test, app)


## A failed recovery is terminal until the title restarts, so it is not waited on: the quit
## exits at once, starts no second recovery, and leaves the restart-required refusal in place.
func _rb2_failed_recovery_does_not_hold_quit(test: Node) -> void:
	print("CASE: RB2 a failed Party recovery keeps its restart-required refusal and does not hold the quit")
	await _setup(test, "quit-recovery-failed")
	var recovery := _install_recovery_party()
	recovery.fake_runtime.party.fake_fails = true
	_begin_recovery(recovery)
	test._check(recovery.recovery_error == PartyService.RECOVERY_FAILED,
		"the failed Party shutdown leaves the restart-required recovery error")
	test._check(recovery.is_cleanup_pending(), "the failure keeps Party's cleanup fence closed")
	test._check(not NetManager.has_pending_online_work(), "a failed recovery is not counted as work a drain could finish")
	var shutdowns := recovery.fake_runtime.party.fake_calls + recovery.fake_runtime.multiplayer.fake_calls
	var app := _open_quit_probe(test)
	app.request_shutdown()
	test._check(app.quit_calls == 1, "the quit exits at once")
	test._check(recovery.fake_runtime.party.fake_calls + recovery.fake_runtime.multiplayer.fake_calls == shutdowns,
		"the quit started no second recovery")
	test._check(recovery.recovery_error == PartyService.RECOVERY_FAILED, "the restart-required refusal is left in place")
	await _end_rb2_case(test, app)
