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
const ServiceDoubles := preload("res://tools/tests/pregame_service_doubles.gd")

const STAGING_ID := "staging-lobby"
const ARRANGED_ID := "arranged-lobby"
const STAGING_CONNECTION := "staging-connection"
const ARRANGED_CONNECTION := "arranged-connection"
const ARRANGED_OWNER_ID := "arranged-owner"


## PartyService at its scoped matchmaking surface. Every call is logged in order, results
## are immediate unless a test blocks them, and the calls that follow a session change
## record the NetManager state they observed -- which is how the handoff reset is shown to
## have finished before the first await rather than merely eventually.
class FlowParty extends PartyService:
	signal fake_leave_released()
	signal fake_prepare_released()
	signal fake_join_transport_released()
	signal fake_lock_released()
	signal fake_create_released()
	signal fake_promote_released()
	signal fake_restore_private_released()
	var fake_calls: Array[String] = []
	var fake_staging := PartyService.LobbyContext.new()
	var fake_arranged := PartyService.LobbyContext.new()
	var fake_local_key: Dictionary = {}
	var fake_peer_keys: Dictionary = {}
	var fake_members: Dictionary = {}
	var fake_owners: Dictionary = {}
	var fake_locked: Dictionary = {}
	var fake_search_control: Dictionary = {}
	var fake_lobby_properties: Dictionary = {}
	var fake_staging_peer: Variant = null
	var fake_arranged_peer: Variant = null
	var fake_join_result: Dictionary = {}
	var fake_created_capacity := 0
	var fake_created_mode := ""
	var fake_published_phase := ""
	var fake_block_leave := false
	var fake_block_prepare := false
	var fake_block_join_transport := false
	var fake_block_lock := false
	var fake_block_create := false
	var fake_create_timeout := false
	var fake_fail_post := false
	var fake_fail_lock := false
	var fake_fail_unlock := false
	## A lock the native call answers OK while the lobby still reads unlocked afterwards.
	var fake_lock_unconfirmed := false
	## Fails only the owner's publication of the first match's chosen players.
	var fake_fail_start_control := false
	var fake_observed: Array[Dictionary] = []
	## The arranged join succeeds only when a case asks for it; Phase 0 cases see it refused.
	var fake_arranged_join_ok := false
	## The service's reason code on a refused arranged join.
	var fake_arranged_join_code: StringName = &""
	var fake_arranged_owner: Dictionary = {}
	var fake_arranged_operation: Variant = null
	var fake_join_arranged_calls: Array[Dictionary] = []
	## The room's capacity the arranged lobby reports: a ceiling, never the start count.
	var fake_capacity := 4
	var fake_max_members := 4
	var fake_proof_pending: Dictionary = {}
	## Fields merged into one peer's admission proof, to model what the fakes above cannot:
	## an invalid proof that keeps the expected key, a malformed property bag.
	var fake_proof_override: Dictionary = {}
	var fake_last_connection_string := ""
	var fake_deadlines: Dictionary = {}
	var fake_connect_on_publish := 0
	var fake_owned_work := false
	## What an owned lobby leave answers, by context id: "null" or "fail". OK otherwise.
	var fake_leave_results: Dictionary = {}
	var fake_transport_leave_fail := false
	## Whether a context's captured work is quiescent, by context id. Quiescent otherwise.
	var fake_quiescent: Dictionary = {}
	var fake_fail_marker_post := false
	## The hosted lobby's owner facts, for a guest whose joined lobby is the hosted one: its
	## current owner, the owner it was joined under, and whether that owner is connected.
	var fake_hosted_owner: Dictionary = {}
	var fake_hosted_owner_baseline: Dictionary = {}
	var fake_hosted_owner_connected := true
	## The protocol a staging or hosted lobby advertises; empty means this build's.
	var fake_lobby_protocol := ""
	## Lobbies whose own local connection is gone, by context id (0 for the hosted lobby),
	## as the service's proof reports them: its retained facts unchanged.
	var fake_lobby_disconnected: Dictionary = {}
	## The private start's service surface. A switch is held until released, or answered with
	## one of the service's own failure codes by its suffix -- "failed", "changed", "busy" or
	## "timeout"; empty is OK. The restoration and the round control answer the same way. The
	## double only records, applies or refuses: every decision is the flow's.
	var fake_block_promote := false
	var fake_promote_result := ""
	var fake_promote_calls: Array[Dictionary] = []
	var fake_block_restore_private := false
	var fake_restore_private_result := ""
	var fake_restore_private_calls: Array[String] = []
	var fake_private_round_result := ""
	## The lobby's access policy, by context id: "private" once a switch applied, public otherwise.
	var fake_access: Dictionary = {}

	func fake_setup(local: Dictionary) -> void:
		fake_local_key = local.duplicate()
		fake_staging.context_id = 101
		fake_staging.kind = PartyService.LOBBY_KIND_STAGING
		fake_arranged.context_id = 202
		fake_arranged.kind = PartyService.LOBBY_KIND_ARRANGED
		fake_owners[fake_staging.context_id] = fake_local_key.duplicate()
		fake_owners[fake_arranged.context_id] = fake_local_key.duplicate()
		# The group's creator carries its protocol in its own member entry, as it does natively.
		fake_members[fake_staging.context_id] = [{"key": fake_local_key.duplicate(), "connected": true,
			"properties": {MatchmakingService.PROTOCOL_MEMBER_KEY: NRProtocol.version_string()}}]
		fake_members[fake_arranged.context_id] = []
		fake_staging_peer = OfflineMultiplayerPeer.new()

	func fake_add_member(context: PartyService.LobbyContext, key: Dictionary, connected: bool = true, properties: Dictionary = {}) -> void:
		var list: Array = fake_members.get(context.context_id, [])
		list.append({"key": key.duplicate(), "connected": connected, "properties": properties.duplicate()})
		fake_members[context.context_id] = list

	## Adds `key` to the lobby or replaces its entry, the way a native member update lands.
	func fake_set_member(context: PartyService.LobbyContext, key: Dictionary, connected: bool = true, properties: Dictionary = {}) -> void:
		var list: Array = fake_members.get(context.context_id, [])
		var mark := MatchmakingFlow.fingerprint(key)
		for index in list.size():
			var existing: Dictionary = list[index]
			if MatchmakingFlow.fingerprint(existing.get("key", {})) == mark:
				list[index] = {"key": key.duplicate(), "connected": connected, "properties": properties.duplicate(true)}
				fake_members[context.context_id] = list
				return
		list.append({"key": key.duplicate(), "connected": connected, "properties": properties.duplicate(true)})
		fake_members[context.context_id] = list

	func fake_remove_member(context: PartyService.LobbyContext, key: Dictionary) -> void:
		var kept: Array = []
		var mark := MatchmakingFlow.fingerprint(key)
		for member: Dictionary in fake_members.get(context.context_id, []):
			if MatchmakingFlow.fingerprint(member.get("key", {})) != mark:
				kept.append(member)
		fake_members[context.context_id] = kept

	func _fake_member(context: PartyService.LobbyContext, key: Dictionary) -> Dictionary:
		var mark := MatchmakingFlow.fingerprint(key)
		for member: Dictionary in fake_members.get(context.context_id, []):
			if MatchmakingFlow.fingerprint(member.get("key", {})) == mark:
				return member
		return {}

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

	func create_staging(_user: Variant, capacity: int, mode_name: String, _account_generation: int, _flow_epoch: int, deadline_msec: int = 0) -> PartyService.PartyResult:
		fake_calls.append("create_staging")
		fake_deadlines["create_staging"] = deadline_msec
		fake_created_capacity = capacity
		fake_created_mode = mode_name
		if fake_block_create:
			await fake_create_released
		if fake_create_timeout:
			var timed_out := _fake_result(null, false, "Injected staging deadline.")
			timed_out.outcome = PartyService.PartyResult.Outcome.TIMEOUT
			return timed_out
		var result := _fake_result(fake_staging)
		result.peer = fake_staging_peer
		result.owner_key = fake_local_key.duplicate()
		result.local_creator = true
		result.descriptor_ready = true
		result.publication_permit = 7
		return result

	func publish_transport(context: PartyService.LobbyContext, permit: int, phase: String, extra_lobby_properties: Dictionary = {}, _extra_search_properties: Dictionary = {}, deadline_msec: int = 0) -> PartyService.PartyResult:
		fake_calls.append("publish:%s:%d" % [phase, permit])
		fake_deadlines["publish"] = deadline_msec
		fake_published_phase = phase
		var properties: Dictionary = fake_lobby_properties.get(context.context_id, {})
		properties.merge(extra_lobby_properties, true)
		fake_lobby_properties[context.context_id] = properties
		fake_observe("publish")
		# A joiner that finds the descriptor the instant it is written.
		if fake_connect_on_publish != 0 and fake_arranged_peer != null and context == fake_arranged:
			fake_arranged_peer.connect_remote(fake_connect_on_publish)
			fake_observe("publish_connect")
		return _fake_result(context)

	func prepare_transport(context: PartyService.LobbyContext, _user: Variant, deadline_msec: int = 0) -> PartyService.PartyResult:
		fake_calls.append("prepare")
		fake_deadlines["prepare"] = deadline_msec
		if fake_block_prepare:
			await fake_prepare_released
		var result := _fake_result(context)
		result.peer = fake_arranged_peer
		result.owner_key = fake_local_key.duplicate()
		result.local_creator = true
		result.descriptor_ready = true
		result.publication_permit = 9
		return result

	## Joins the arranged network. A held join completes only when a case calls
	## fake_release_join(), which then announces the network's host the way the addon does. An
	## unheld join leaves that announcement to the case, made right after the call returns: the
	## same order.
	func join_transport(context: PartyService.LobbyContext, _user: Variant, deadline_msec: int = 0) -> PartyService.PartyResult:
		fake_calls.append("join_transport")
		fake_deadlines["join_transport"] = deadline_msec
		if fake_block_join_transport:
			await fake_join_transport_released
		var result := _fake_result(context)
		result.peer = fake_arranged_peer
		# The arranged network was created by the arranged lobby's owner, so that owner is peer
		# 1 on it. A case can still say otherwise afterwards.
		if context != null:
			fake_peer_keys[NetManager.HOST_PEER_ID] = (fake_owners.get(context.context_id, {}) as Dictionary).duplicate()
		return result

	## Completes a held join, and the moment its caller has resumed from it announces the host --
	## peer 1 -- on the joined network, in the one step, as the addon does.
	func fake_release_join() -> void:
		fake_block_join_transport = false
		fake_join_transport_released.emit()
		if fake_arranged_peer != null:
			fake_arranged_peer.connect_remote(NetManager.HOST_PEER_ID)

	# The arranged join the matched handoff starts. Refused unless a case asks for it, so
	# Phase 0 cases still only see that it was reached, and in which order. When it
	# succeeds, this member appears in the arranged lobby with the properties it joined with.
	func join_arranged(_user: Variant, arrangement: String, member_properties: Dictionary, capacity: int, _account_generation: int, _flow_epoch: int, deadline_msec: int = 0) -> PartyService.PartyResult:
		fake_calls.append("join_arranged:%s" % arrangement)
		fake_deadlines["join_arranged"] = deadline_msec
		fake_join_arranged_calls.append({
			"arrangement": arrangement,
			"capacity": capacity,
			"properties": member_properties.duplicate(true),
		})
		if not fake_arranged_join_ok:
			var refused := _fake_result(null, false, "Injected arranged join failure.")
			refused.reason_code = fake_arranged_join_code
			refused.operation = fake_arranged_operation
			return refused
		fake_set_member(fake_arranged, fake_local_key, true, member_properties)
		var result := _fake_result(fake_arranged)
		result.owner_key = fake_arranged_owner.duplicate()
		return result

	func set_context_locked(context: PartyService.LobbyContext, is_locked: bool, _deadline_msec: int = 0) -> PartyService.PartyResult:
		fake_calls.append("lock:%s" % str(is_locked))
		if fake_block_lock:
			await fake_lock_released
		if (is_locked and fake_fail_lock) or (not is_locked and fake_fail_unlock):
			return _fake_result(context, false, "Injected lock failure.")
		if not (is_locked and fake_lock_unconfirmed):
			fake_locked[context.context_id] = is_locked
		return _fake_result(context)

	func post_context_update(context: PartyService.LobbyContext, lobby_properties: Dictionary, _search_properties: Dictionary, member_properties: Dictionary, _deadline_msec: int = 0) -> PartyService.PartyResult:
		if fake_fail_post:
			fake_calls.append("post:failed")
			return _fake_result(context, false, "Injected post failure.")
		if fake_fail_start_control and String(lobby_properties.get(PartyService.SESSION_PHASE_KEY, "")) == PartyService.ARRANGED_PHASE_STARTING:
			fake_calls.append("post:starting:failed")
			return _fake_result(context, false, "Injected start publication failure.")
		if fake_fail_marker_post and member_properties.has(PartyService.STAGING_RETIRED_MEMBER_KEY):
			fake_calls.append("post:retired:failed")
			return _fake_result(context, false, "Injected retirement report failure.")
		if lobby_properties.has(PartyService.SEARCH_CONTROL_KEY):
			var control := PartyService.decode_search_control(String(lobby_properties[PartyService.SEARCH_CONTROL_KEY]))
			fake_search_control[context.context_id] = control
			fake_calls.append("post:%s" % String(control.get("phase", "invalid")))
		elif lobby_properties.has(PartyService.SESSION_PHASE_KEY):
			var properties: Dictionary = fake_lobby_properties.get(context.context_id, {})
			properties.merge(lobby_properties, true)
			fake_lobby_properties[context.context_id] = properties
			fake_calls.append("post:%s" % String(lobby_properties[PartyService.SESSION_PHASE_KEY]))
		else:
			fake_calls.append("post:member" if not member_properties.is_empty() else "post")
		if not member_properties.is_empty():
			var local := _fake_member(context, fake_local_key)
			var merged: Dictionary = (local.get("properties", {}) as Dictionary).duplicate(true)
			merged.merge(member_properties, true)
			fake_set_member(context, fake_local_key, bool(local.get("connected", true)), merged)
		return _fake_result(context)

	## The owner's switch of its group's lobby to a private match. On OK it applies exactly what
	## the service writes -- the service's own private control encoding, the private kind and
	## access -- to the same context; otherwise it answers with the service's typed failure.
	func promote_staging_to_private(context: PartyService.LobbyContext, session_id: String, selected_members: Array[Dictionary], deadline_msec: int = 0) -> PartyService.PartyResult:
		fake_calls.append("promote")
		fake_deadlines["promote"] = deadline_msec
		fake_promote_calls.append({"session_id": session_id, "members": selected_members.duplicate(true)})
		if fake_block_promote:
			await fake_promote_released
		if not fake_promote_result.is_empty():
			var refused := _fake_result(context, false, "Injected private start failure.")
			refused.reason_code = StringName("private_promotion_" + fake_promote_result)
			if fake_promote_result == "timeout":
				refused.outcome = PartyService.PartyResult.Outcome.TIMEOUT
			return refused
		var properties: Dictionary = fake_lobby_properties.get(context.context_id, {})
		properties.merge(PartyService.encode_private_control(session_id, 0, PartyService.ARRANGED_PHASE_STARTING, 1, selected_members), true)
		fake_lobby_properties[context.context_id] = properties
		fake_access[context.context_id] = "private"
		context.kind = PartyService.LOBBY_KIND_PRIVATE
		context.play_origin = PartyService.PLAY_ORIGIN_PRIVATE
		context.private_session_id = session_id
		context.selected_start_count = 4
		var result := _fake_result(context)
		result.play_origin = PartyService.PLAY_ORIGIN_PRIVATE
		result.private_session_id = session_id
		return result

	## The service's checked restoration of a switch that did not commit. On OK its one update
	## lands first -- the private control cleared, the group's kind, access and Gathering envelope
	## back -- and its checked unlock after it: a held restoration is held at that unlock, the
	## envelope already in the lobby. A refusal changes nothing.
	func restore_private_to_gathering(context: PartyService.LobbyContext, expected_session_id: String, gathering_search_control: String, _deadline_msec: int = 0) -> PartyService.PartyResult:
		fake_calls.append("restore_private")
		fake_restore_private_calls.append(expected_session_id)
		if not fake_restore_private_result.is_empty():
			if fake_block_restore_private:
				await fake_restore_private_released
			var refused := _fake_result(context, false, "Injected restoration failure.")
			refused.reason_code = StringName("private_restore_" + fake_restore_private_result)
			return refused
		var properties: Dictionary = fake_lobby_properties.get(context.context_id, {})
		for key: String in [PartyService.PLAY_ORIGIN_KEY, PartyService.PRIVATE_SESSION_ID_KEY,
				PartyService.ROUND_GENERATION_KEY, PartyService.START_GENERATION_KEY, PartyService.START_MEMBERS_KEY]:
			properties.erase(key)
		properties[PartyService.SESSION_PHASE_KEY] = MatchmakingFlow.SESSION_PHASE_GATHERING
		fake_lobby_properties[context.context_id] = properties
		fake_search_control[context.context_id] = PartyService.decode_search_control(gathering_search_control)
		fake_access.erase(context.context_id)
		context.kind = PartyService.LOBBY_KIND_STAGING
		if fake_block_restore_private:
			await fake_restore_private_released
		fake_locked[context.context_id] = false
		context.play_origin = &""
		context.private_session_id = ""
		context.selected_start_count = 0
		return _fake_result(context)

	## A private match's round control, published the way the service encodes it.
	func set_private_round_control(context: PartyService.LobbyContext, session_id: String, play_round: int, round_phase: String, _deadline_msec: int = 0) -> PartyService.PartyResult:
		fake_calls.append("private_round:%s" % round_phase)
		if not fake_private_round_result.is_empty():
			var refused := _fake_result(context, false, "Injected round failure.")
			refused.reason_code = StringName("private_round_" + fake_private_round_result)
			return refused
		var properties: Dictionary = fake_lobby_properties.get(context.context_id, {})
		properties.merge(PartyService.encode_private_control(session_id, play_round, round_phase), true)
		fake_lobby_properties[context.context_id] = properties
		return _fake_result(context)

	func leave_lobby(context: PartyService.LobbyContext) -> PartyService.PartyResult:
		fake_calls.append("leave_lobby:%d" % context.context_id)
		if fake_block_leave:
			await fake_leave_released
		match String(fake_leave_results.get(context.context_id, "")):
			"null":
				return null
			"fail":
				return _fake_result(context, false, "Injected lobby leave failure.")
		return _fake_result(context)

	func leave_transport(context: PartyService.LobbyContext) -> PartyService.PartyResult:
		fake_calls.append("leave_transport:%d" % context.context_id)
		fake_observe("leave_transport")
		if fake_transport_leave_fail:
			return _fake_result(context, false, "Injected transport leave failure.")
		return _fake_result(context)

	func context_is_quiescent(context: PartyService.LobbyContext) -> bool:
		return context != null and bool(fake_quiescent.get(context.context_id, true))

	func snapshot(context: PartyService.LobbyContext) -> Dictionary:
		if context == null:
			return {"members": [], "search_control": {"valid": false}, "arranged_control": {"valid": false},
				"private_control": {"valid": false}}
		var owner: Dictionary = fake_owners.get(context.context_id, {})
		var properties: Dictionary = (fake_lobby_properties.get(context.context_id, {}) as Dictionary).duplicate(true)
		# The owner's round control is decoded by the service's own reader, exactly as the
		# service reports it -- a matchmade one and a private one alike.
		var control := PartyService.decode_arranged_control(properties)
		var private_control := PartyService.decode_private_control(properties)
		var play_origin: StringName = &""
		var private_session_id := ""
		if context.kind == PartyService.LOBBY_KIND_ARRANGED:
			play_origin = PartyService.PLAY_ORIGIN_MATCHMADE
		if context.kind == PartyService.LOBBY_KIND_PRIVATE and bool(private_control.get("valid", false)):
			play_origin = PartyService.PLAY_ORIGIN_PRIVATE
			private_session_id = String(private_control.get("session_id", ""))
		var current: Dictionary = private_control if play_origin == PartyService.PLAY_ORIGIN_PRIVATE else control
		return {
			"context_id": context.context_id,
			"kind": context.kind,
			"lobby_id": lobby_id(context),
			"local_key": fake_local_key.duplicate(),
			"owner_key": owner.duplicate(),
			"is_local_owner": MatchmakingFlow.fingerprint(owner) == MatchmakingFlow.fingerprint(fake_local_key),
			"members": (fake_members.get(context.context_id, []) as Array).duplicate(true),
			"max_members": fake_max_members,
			"capacity": fake_capacity,
			"selected_start_count": int(current.get("selected_count", 0)) if bool(current.get("valid", false)) else 0,
			"play_origin": play_origin,
			"private_session_id": private_session_id,
			"access_policy": PartyService.ACCESS_POLICY_PRIVATE if String(fake_access.get(context.context_id, "")) == "private" \
				else PartyService.ACCESS_POLICY_PUBLIC,
			"recovery_epoch": 0,
			"membership_locked": bool(fake_locked.get(context.context_id, false)),
			"disconnected": false,
			"properties": properties,
			"phase": String(properties.get(PartyService.SESSION_PHASE_KEY, "")),
			"search_control": (fake_search_control.get(context.context_id, {"valid": false}) as Dictionary).duplicate(true),
			"arranged_control": control,
			"private_control": private_control,
		}

	## What the transport and the native lobby say about one peer, built from the same
	## fakes the snapshot reads and shaped like the service's own proof: pending while a case
	## holds it so, and invalid -- disconnected or missing -- for a key that is not a connected
	## member. A key not yet in the lobby is pending, as the service reports it, only while the
	## lobby is unlocked and taking arrivals: before its owner has published anything past
	## bootstrap, or in an open rematch round -- a private match's included. This player's own
	## peer has no key unless a case gives it one.
	func admission_proof(context: PartyService.LobbyContext, peer_id: int) -> Dictionary:
		var key: Dictionary = (fake_peer_keys.get(peer_id, {}) as Dictionary).duplicate()
		var member: Dictionary = _fake_member(context, key) if not key.is_empty() else {}
		var pending := bool(fake_proof_pending.get(peer_id, false))
		if not pending and not key.is_empty() and member.is_empty() and context != null:
			var unlocked: bool = not bool(fake_locked.get(context.context_id, false))
			if context.kind == PartyService.LOBBY_KIND_PRIVATE:
				var private_control := PartyService.decode_private_control(fake_lobby_properties.get(context.context_id, {}))
				pending = unlocked and bool(private_control.get("valid", false)) \
					and String(private_control.get("phase", "")) == PartyService.ARRANGED_PHASE_REMATCH
			else:
				var control := PartyService.decode_arranged_control(fake_lobby_properties.get(context.context_id, {}))
				pending = unlocked and (not bool(control.get("valid", false)) \
					or String(control.get("phase", "")) in [PartyService.ARRANGED_PHASE_BOOTSTRAP, PartyService.ARRANGED_PHASE_REMATCH])
		var connected := not member.is_empty() and bool(member.get("connected", false))
		var reason := ""
		if pending:
			reason = "native_member_pending"
		elif key.is_empty():
			reason = "party_identity_missing"
		elif member.is_empty():
			reason = "native_member_missing"
		elif not connected:
			reason = "native_member_disconnected"
		var proof := {
			"valid": not pending and connected,
			"pending": pending,
			"reason_code": reason,
			"context_id": context.context_id if context != null else 0,
			"recovery_epoch": 0,
			"peer_id": peer_id,
			"entity_key": key,
			"native_present": not member.is_empty(),
			"native_connected": connected,
			"member_properties": (member.get("properties", {}) as Dictionary).duplicate(true),
			"owner_key": (fake_owners.get(context.context_id if context != null else 0, {}) as Dictionary).duplicate(),
			"capacity": fake_capacity,
			"selected_start_count": 0,
			"local_creator": false,
			"transport_attached": true,
		}
		proof.merge(fake_proof_override.get(peer_id, {}), true)
		return proof

	## The joined lobby's owner proof, shaped like the service's and judged in the same order
	## with the same reason codes, over the same fakes the snapshot reads. A null context is
	## the hosted lobby. `fake_proof_pending` and `fake_proof_override` for the peer hold a
	## case's facts back or bend them, as they do the member proof. A unit double for
	## NetManager's consumers only: the service's own proof is exercised against the real
	## PartyService.
	func joined_owner_proof(context: PartyService.LobbyContext = null, peer_id: int = 1) -> Dictionary:
		var context_id := context.context_id if context != null else 0
		var proof := {
			"valid": false, "pending": false, "reason_code": "", "context": context,
			"context_id": context_id, "recovery_epoch": 0,
			"peer_id": peer_id, "peer_key": {}, "owner_key": {}, "native_present": false,
			"native_connected": false, "protocol": "", "kind": context.kind if context != null else "",
			"play_origin": "", "private_session_id": "",
			"match_id": "", "round": 0, "phase": "",
			"start_generation": 0, "selected_members": [], "selected_count": 0,
			"local_lobby_connected": not bool(fake_lobby_disconnected.get(context_id, false)),
			"captured_owner_key": fake_hosted_owner_baseline.duplicate() if context == null else context.owner_key.duplicate(),
		}
		proof["reason_code"] = _fake_owner_verdict(context, peer_id, proof)
		if bool(fake_proof_pending.get(peer_id, false)):
			proof["pending"] = true
			proof["reason_code"] = "owner_pending"
		# A lobby whose own connection is gone is reported last, as the service does: after any
		# contradiction or missing fact its retained facts still show.
		if String(proof["reason_code"]).is_empty() and not bool(proof["pending"]) \
				and not bool(proof["local_lobby_connected"]):
			proof["reason_code"] = "local_lobby_disconnected"
		proof["valid"] = String(proof["reason_code"]).is_empty() and not bool(proof["pending"])
		proof.merge(fake_proof_override.get(peer_id, {}), true)
		return proof

	## Fills `proof` with what the fakes say and returns the first reason it is not valid.
	func _fake_owner_verdict(context: PartyService.LobbyContext, peer_id: int, proof: Dictionary) -> String:
		var peer_key: Dictionary = (fake_peer_keys.get(peer_id, {}) as Dictionary).duplicate()
		proof["peer_key"] = peer_key
		if peer_key.is_empty():
			proof["pending"] = true
			return "party_identity_pending"
		var owner: Dictionary = fake_hosted_owner.duplicate() if context == null \
			else (fake_owners.get(context.context_id, {}) as Dictionary).duplicate()
		var captured: Dictionary = fake_hosted_owner_baseline.duplicate() if context == null else context.owner_key.duplicate()
		proof["owner_key"] = owner
		if owner.is_empty():
			proof["pending"] = captured.is_empty()
			return "owner_pending" if captured.is_empty() else "owner_changed"
		if not captured.is_empty() and MatchmakingFlow.fingerprint(captured) != MatchmakingFlow.fingerprint(owner):
			return "owner_changed"
		if MatchmakingFlow.fingerprint(peer_key) != MatchmakingFlow.fingerprint(owner):
			return "owner_peer_mismatch"
		var member: Dictionary = {}
		if context == null:
			member = {"key": owner.duplicate(), "connected": fake_hosted_owner_connected, "properties": {}}
		else:
			member = _fake_member(context, owner)
			if member.is_empty():
				proof["pending"] = (fake_members.get(context.context_id, []) as Array).is_empty()
				return "owner_member_pending" if bool(proof["pending"]) else "owner_member_missing"
		proof["native_present"] = true
		proof["native_connected"] = bool(member.get("connected", false))
		if not bool(proof["native_connected"]):
			return "owner_disconnected"
		var protocol := fake_lobby_protocol if not fake_lobby_protocol.is_empty() else NRProtocol.version_string()
		if context != null and context.kind == PartyService.LOBBY_KIND_PRIVATE:
			# A private match's lobby: its own control, read by the service's decoder, and the
			# owner's protocol from its own member entry.
			proof["play_origin"] = String(PartyService.PLAY_ORIGIN_PRIVATE)
			var private_properties: Dictionary = fake_lobby_properties.get(context.context_id, {})
			var private_control: Dictionary = PartyService.decode_private_control(private_properties)
			if not bool(private_control.get("valid", false)):
				var has_private: bool = private_properties.has(PartyService.PLAY_ORIGIN_KEY) \
					or private_properties.has(PartyService.PRIVATE_SESSION_ID_KEY)
				proof["pending"] = not has_private
				return "private_control_invalid" if has_private else "private_control_pending"
			proof["private_session_id"] = String(private_control.get("session_id", ""))
			proof["round"] = int(private_control.get("round", 0))
			proof["phase"] = String(private_control.get("phase", ""))
			proof["start_generation"] = int(private_control.get("start_generation", 0))
			proof["selected_members"] = (private_control.get("selected_members", []) as Array).duplicate(true)
			proof["selected_count"] = int(private_control.get("selected_count", 0))
			var raw_owner_properties: Variant = member.get("properties", {})
			var owner_properties: Dictionary = raw_owner_properties as Dictionary \
				if typeof(raw_owner_properties) == TYPE_DICTIONARY else {}
			protocol = String(owner_properties.get(MatchmakingService.PROTOCOL_MEMBER_KEY, ""))
		if context != null and context.kind == PartyService.LOBBY_KIND_ARRANGED:
			proof["play_origin"] = String(PartyService.PLAY_ORIGIN_MATCHMADE)
			var lobby_properties: Dictionary = fake_lobby_properties.get(context.context_id, {})
			var control: Dictionary = PartyService.decode_arranged_control(lobby_properties)
			if not bool(control.get("valid", false)):
				var has_control := lobby_properties.has(PartyService.MATCH_ID_MEMBER_KEY) \
					or lobby_properties.has(PartyService.ROUND_GENERATION_KEY) or lobby_properties.has(PartyService.SESSION_PHASE_KEY) \
					or lobby_properties.has(PartyService.START_GENERATION_KEY) or lobby_properties.has(PartyService.START_MEMBERS_KEY)
				proof["pending"] = not has_control
				return "arranged_control_invalid" if has_control else "arranged_control_pending"
			proof["match_id"] = String(control.get("match_id", ""))
			proof["round"] = int(control.get("round", 0))
			proof["phase"] = String(control.get("phase", ""))
			proof["start_generation"] = int(control.get("start_generation", 0))
			proof["selected_members"] = (control.get("selected_members", []) as Array).duplicate(true)
			proof["selected_count"] = int(control.get("selected_count", 0))
			var raw_properties: Variant = member.get("properties", {})
			var properties: Dictionary = raw_properties as Dictionary if typeof(raw_properties) == TYPE_DICTIONARY else {}
			protocol = String(properties.get(MatchmakingService.PROTOCOL_MEMBER_KEY, ""))
			var owner_match := String(properties.get(PartyService.MATCH_ID_MEMBER_KEY, ""))
			if owner_match.is_empty():
				proof["pending"] = true
				return "owner_match_pending"
			if owner_match != String(proof["match_id"]):
				return "owner_match_mismatch"
		proof["protocol"] = protocol
		if protocol.is_empty():
			proof["pending"] = true
			return "owner_protocol_pending"
		if not NRProtocol.is_compatible(protocol):
			return "owner_protocol_mismatch"
		return ""

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

	func join_by_connection_string(_user: Variant, connection_string: String, _deadline_msec: int = 0) -> Dictionary:
		fake_calls.append("join_by_connection_string")
		fake_last_connection_string = connection_string
		return fake_join_result.duplicate()

	func leave(_invalidate_pending: bool = true) -> void:
		fake_calls.append("leave")

	func has_network() -> bool:
		return false

	func has_owned_work() -> bool:
		return fake_owned_work

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
	## A ticket the service refuses before any exists: {"code": StringName, "text": String}.
	var fake_reject_create: Dictionary = {}
	## A result shaped the way the addon hands the service a failed creation. When set, the
	## owner's ticket fails with whatever the service's own classifier makes of it.
	var fake_create_result: Variant = null
	## Whether the service starts a native cancel when a live attempt is stopped or retired:
	## the attempt then carries that waiter, and owes native cleanup until it resolves.
	var fake_cancel_waits := false
	## Injected broken native observer: a cancel this double starts is never answered, so a
	## match that wins the race leaves the waiter in flight -- the orphan the bounded recovery
	## exists for. Off by default: the supported addon answers that race with its lost-race
	## result, and nothing is owed.
	var fault_cancel_unanswered := false
	## The service's reason Quick Match is unavailable; empty while it is available. Each
	## production reason is the service suite's case: this lets a flow case prove that the
	## entry points repeat whichever reason the service gives.
	var fake_unavailable_reason := ""

	func availability_reason() -> String:
		return fake_unavailable_reason

	func begin_create(spec: MatchmakingService.SearchSpec) -> MatchmakingService.TicketAttempt:
		fake_creates.append(spec)
		var attempt := _fake_attempt(spec, true)
		if not fake_reject_create.is_empty():
			attempt.settle(MatchmakingService.Outcome.FAILED, fake_reject_create.get("code", &""),
				String(fake_reject_create.get("text", "")))
		elif fake_create_result != null:
			fake_classify(attempt, fake_create_result, &"create")
		return attempt

	## Settles `attempt` failed the way the service classifies `result` at `stage`: its own
	## classifier, over the same owner flag and group size.
	func fake_classify(attempt: MatchmakingService.TicketAttempt, result: Variant, stage: StringName) -> void:
		var outcome := MatchmakingService.failure_outcome(result, stage, attempt.owner, attempt.frozen_members.size())
		attempt.settle(MatchmakingService.Outcome.FAILED, StringName(outcome.get("reason_code", "")),
			String(outcome.get("reason", "")))

	func begin_join(spec: MatchmakingService.SearchSpec) -> MatchmakingService.TicketAttempt:
		fake_joins.append(spec)
		return _fake_attempt(spec, false)

	# The service side of a confirmed Multiplayer reset. Records the order it was reached
	# in -- the flow must already have been retired by then -- and discharges what the old
	# runtime owed: a cancel waiter left unanswered goes with the runtime.
	func multiplayer_invalidated(recovery_epoch: int) -> void:
		var flow: MatchmakingFlow = NetManager._flow
		fake_log.append("invalidated:%d:%s" % [recovery_epoch, "retired" if flow == null or flow.retired else "live"])
		for attempt: MatchmakingService.TicketAttempt in fake_attempts:
			if attempt.cancel_in_flight or attempt.cleanup_pending:
				attempt.cancel_in_flight = false
				attempt.native_terminal = true
				attempt.cleanup_pending = false
				attempt.cleanup_changed.emit(attempt)

	func request_cancel(attempt: MatchmakingService.TicketAttempt) -> void:
		fake_cancels.append(attempt)
		_fake_start_cancel(attempt)

	# Retirement as the service performs it: marked retired before a still-pending attempt
	# settles as superseded, with native cleanup left owed when a case says so -- or while a
	# native cancel it starts has not answered.
	func retire(attempt: MatchmakingService.TicketAttempt) -> void:
		if attempt == null:
			return
		fake_retired.append(attempt)
		fake_log.append("retire:%d" % attempt.flow_epoch)
		if attempt.retired:
			return
		attempt.retired = true
		if attempt.is_pending():
			if fake_retire_leaves_cleanup:
				attempt.cleanup_pending = true
			_fake_start_cancel(attempt)
			attempt.settle(MatchmakingService.Outcome.SUPERSEDED)

	## A native cancel starting for a live ticket: the waiter the service holds until the
	## binding answers, and the cleanup it owes meanwhile.
	func _fake_start_cancel(attempt: MatchmakingService.TicketAttempt) -> void:
		if not fake_cancel_waits or attempt == null or attempt.native_terminal or attempt.cancel_in_flight:
			return
		attempt.cancel_in_flight = true
		attempt.cleanup_pending = true

	## Whether a native cancel this double started is still unanswered.
	func fake_cancel_outstanding() -> bool:
		for attempt: MatchmakingService.TicketAttempt in fake_attempts:
			if attempt.cancel_in_flight:
				return true
		return false

	## A case's own flag, or a cancel still in flight: the service's first reason for owing
	## cleanup. The service's own bounded drain waits on it, on the case clock, until it
	## resolves or the caller's deadline passes.
	func has_pending_cleanup() -> bool:
		return fake_pending_cleanup or fake_cancel_outstanding()

	## A matched ticket whose cancel this double started and has not answered: only an injected
	## unanswered observer, or a lost-race answer a case holds back, stays this way.
	func has_orphaned_matched_cancel() -> bool:
		for attempt: MatchmakingService.TicketAttempt in fake_attempts:
			if attempt.native_terminal and attempt.cancel_in_flight \
					and attempt.status == MatchmakingService.STATUS_MATCHED:
				return true
		return false

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
	signal fake_released()
	var fake_log: Array[String] = []
	## Holds every check until `fake_released`, as a slow platform prompt does.
	var fake_hold := false

	func ensure(_user: Variant, privilege: int) -> Dictionary:
		fake_log.append("privilege:%d" % privilege)
		if fake_hold:
			await fake_released
		return {"granted": true}


## The world MatchDirector drives, reduced to what its start decisions touch: a case reads
## how many times the match was actually started.
class FakeWorld extends Node:
	var fake_started := 0

	func initialize(_authority: bool, _mode: NRTypes.GameModeType, _states: Array) -> void:
		pass

	func tick(_delta: float) -> void:
		pass

	func start_match() -> void:
		fake_started += 1

	func set_simulation_running(_running: bool) -> void:
		pass

	func get_ship_for(_peer_id: int) -> Variant:
		return null

	func remove_ship_for(_peer_id: int) -> void:
		pass


## Counts the alarms that reached it. `note` is bound to a payload so a case can prove the
## alarm let go of what its callable held; `mark` records the order things happened in.
class AlarmProbe extends RefCounted:
	var fake_hits := 0

	func hit() -> void:
		fake_hits += 1

	func note(_payload: RefCounted) -> void:
		fake_hits += 1

	func mark(marks: Array[String], label: String) -> void:
		marks.append(label)


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


## The service suite's peer double, also recording what NetManager sends over it and able to
## announce a remote peer, so a composed case can count what reaches peer 1 on the transport
## the real PartyService joined.
class RecordingPeer extends ServiceDoubles.Peer:
	var sent: Array[PackedByteArray] = []
	## The target of each packet in `sent`, index for index (0 for everyone).
	var targets: Array[int] = []
	## Peers this host dropped from its own peers, in order.
	var disconnected: Array[int] = []
	var _target := 0

	func _set_target_peer(id: int) -> void:
		_target = id

	func _put_packet_script(packet: PackedByteArray) -> Error:
		sent.append(packet)
		targets.append(_target)
		return OK

	func _disconnect_peer(peer_id: int, _force: bool) -> void:
		disconnected.append(peer_id)
		peer_disconnected.emit(peer_id)

	func connect_remote(peer_id: int) -> void:
		peer_connected.emit(peer_id)


## Everything the engine logs while a case listens -- messages, errors and warnings -- so a
## case can read the whole of what reached the log, not only what one service chose to say.
class LogTap extends Logger:
	var lines: PackedStringArray = PackedStringArray()
	var _lock := Mutex.new()

	func _log_message(message: String, _error: bool) -> void:
		_lock.lock()
		lines.append(message)
		_lock.unlock()

	func _log_error(_function: String, _file: String, _line: int, code: String, rationale: String,
			_editor_notify: bool, _error_type: int, _script_backtraces: Array[ScriptBacktrace]) -> void:
		_lock.lock()
		lines.append("%s %s" % [code, rationale])
		_lock.unlock()


## The service suite's Party SDK with its scoped shutdown able to be held at the SDK boundary,
## as a native shutdown still completing is. `shutdown_starts` counts shutdowns asked for,
## held or not.
class HeldPartySDK extends ServiceDoubles.PartySDK:
	signal shutdown_released()
	var hold_shutdown := false
	var shutdown_starts := 0

	func shutdown_async() -> Dictionary:
		shutdown_starts += 1
		if hold_shutdown:
			await shutdown_released
		return super.shutdown_async()


var clock: Doubles.FakeClock = null
var party: FlowParty = null
var matchmaking: FlowMatchmaking = null
var activity: Review.Activity = null
var chat: Doubles.Chat = null
## The composed cases' production services over the service suite's SDK doubles, on the
## Party double's own clock.
var real_party: ServiceDoubles.Party = null
var real_matchmaking: ServiceDoubles.Matchmaking = null
var real_clock: ServiceDoubles.Clock = null
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
	await _p1_unavailable_matchmaking_explains_at_every_entry(test)
	await _p1_available_matchmaking_opens_a_group_from_the_row(test)
	await _p0_profile_gate_refuses_direct_entry(test)
	await _p0_settled_attempts_are_retired(test)
	await _p1_entry_refuses_before_unsafe_work(test)
	await _b_order_owner_waits_only_for_its_own_premade(test)
	await _b_premade_solo_owner_opens_alone_and_starts_with_one_arrival(test)
	await _f5_guest_turned_owner_opens_admission_before_its_descriptor(test)
	await _f6_host_admits_only_the_proven_arrivals(test)
	await _f6_host_never_greets_unproven_peers(test)
	await _f6_guest_answers_only_the_pinned_host(test)
	await _f7_first_start_needs_the_chosen_players_through_running(test)
	await _f7_first_start_rereads_native_identity(test)
	await _f7_first_start_waits_for_every_staging_retirement(test)
	await _b_present_two_three_or_four_start_as_soon_as_ready(test)
	await _b_present_member_not_ready_blocks_the_choice(test)
	await _q1_an_incompatible_present_member_fails_the_start(test)
	await _q2_an_arrived_premade_may_start_alone(test)
	await _b_order_a_change_during_the_start_fails_it_unrecomputed(test)
	await _b_late_arrivals_are_turned_away_and_told_why(test)
	await _q3_guest_start_follows_the_published_choice(test)
	await _b_start_guest_needs_its_admission_and_a_proven_owner(test)
	await _b_premade_handoff_waits_for_complete_facts(test)
	await _b_premade_rechecked_once_the_network_is_ready(test)
	await _b_recipients_shared_updates_reach_only_admitted_players(test)
	await _b_refused_peer_removal_is_scoped_to_its_refusal(test)
	await _f10_rematch_replacement_waits_for_its_lobby_membership(test)
	await _f8_deadline_alarms_fire_once_and_cancel_cleanly(test)
	await _f8_split_budgets_do_not_renew(test)
	await _f9_lobby_loss_and_recovery_routing(test)
	await _f9_staging_owner_leaves_its_lobby_last(test)
	await _f10_host_returns_to_an_arranged_rematch(test)
	await _f10_guest_waits_for_host_return(test)
	await _f10_rematch_invite_joins_through_netmanager(test)
	await _r1_pending_rematch_trusts_only_the_proven_owner(test)
	await _r1_rematch_admission_rechecks_owner_and_round(test)
	await _r1_hosted_join_trusts_only_the_hosted_owner(test)
	await _r1_admitted_hosted_session_proves_its_owner_at_every_message(test)
	await _r1_pending_hosted_proof_settles_from_the_join_poll(test)
	await _r1_admitted_scoped_sessions_prove_their_owner_without_a_loss_notice(test)
	await _f11_guest_reducer_replays_missed_state(test)
	await _f11_owner_answers_state_requests(test)
	await _f11_invite_destinations_and_exact_credentials(test)
	await _f14_full_group_failed_private_start_restores_everyone_honestly(test)
	await _c_consent_every_change_resets_readiness(test)
	await _c_consent_member_acknowledges_and_never_resends_ready(test)
	await _c_private_restores_or_ends_cleanly(test)
	await _c_private_recipients_reach_exactly_the_four(test)
	await _c_private_member_follows_the_private_start(test)
	await _c_rematch_private_session_returns_and_admits_replacements(test)
	await _c_rematch_private_invite_joins_as_a_replacement(test)
	await _c_consent_restoration_is_acknowledged_again(test)
	await _c_private_member_catches_up_on_its_first_start(test)
	await _c_rematch_original_member_rejoins_its_round(test)
	await _c_wake_full_group_after_cleanup(test)
	await _r7_match_after_a_stopped_search_never_starts_or_wedges(test)
	await _r7_injected_unanswered_cancel_is_recovered_once(test)
	await _r7_leave_and_replacement_let_the_search_go(test)
	await _r7_quit_is_bounded_while_a_cancel_is_unanswered(test)
	await _r7_failed_recovery_is_terminal_and_keeps_the_lease(test)
	await _c1_admitted_hosted_session_outlives_only_its_local_lobby_connection(test)
	await _c1_scoped_local_lobby_loss_stays_terminal(test)
	await _c2_scoped_leave_waiters_settle_from_recovery(test)
	await _c3_orphaned_cancel_survives_account_removal_and_suspend(test)
	await _m1_answered_lost_race_needs_no_reset(test)
	await _m2_creation_cancelled_before_an_id_restores_the_group(test)
	await _c_m1_rematch_replacement_waits_over_the_real_services(test)
	await _c_auto_full_group_starts_privately_over_the_real_services(test)
	await _c_rematch_private_invite_over_the_real_services(test)
	await _c9_scoped_network_error_is_logged_once_and_safely(test)
	await _d1_failed_native_leave_keeps_cleanup_and_the_invitation(test)
	await _d1_flowless_cleanup_keeps_the_invitation_after_account_change(test)
	await _d2_matched_during_the_final_teardown_await_is_recovered_first(test)
	await _d4_flowless_practice_after_an_account_switch(test)
	await _d7_hosted_owner_proven_after_the_join_keeps_only_local_continuity(test)
	await _f5_late_leave_failure_without_an_owner_is_recovered_once(test)
	await _f5_debt_raised_while_cleanup_runs_joins_that_cleanup(test)
	await _f5_live_replacement_keeps_the_seat_until_it_leaves(test)
	await _f5_quit_with_idle_debt_leaves_and_recovers_first(test)
	await _f5_terminal_recovery_failure_stays_restart_required(test)
	await _f5_invitation_waits_for_unowned_debt(test)
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
	# Bound the way the services bind the party they build, so a case can emit the
	# service-wide notices rather than call their handlers.
	Services.bind_party_signals()
	Services._matchmaking = matchmaking
	Services.bind_matchmaking_signals()
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
	party.fake_block_lock = false
	party.fake_lock_released.emit()
	party.fake_block_create = false
	party.fake_create_released.emit()
	NetManager.leave_match()
	party.fake_block_prepare = false
	party.fake_prepare_released.emit()
	party.fake_block_join_transport = false
	party.fake_join_transport_released.emit()
	party.fake_block_promote = false
	party.fake_promote_released.emit()
	party.fake_block_restore_private = false
	party.fake_restore_private_released.emit()
	for _sweep in 3:
		_complete_activity()
		clock.advance(1000.0)
	_complete_activity()
	# Whatever is still asleep or armed on this case's clock, a native cancel the double
	# never answered, or a Party recovery still asked for would never be woken again: it
	# would outlive the case, holding whatever it captured.
	test._check(clock.pending() == 0 and clock.armed_alarm_count() == 0,
		"flow case leaves nothing asleep or armed on its clock: %d asleep, %d armed" % [clock.pending(), clock.armed_alarm_count()])
	test._check(not matchmaking.fake_cancel_outstanding() and not party.is_cleanup_pending(),
		"flow case leaves no native cancel unanswered and no Party recovery asked for")
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
## a connected member of the staging lobby carrying this build's protocol, as a member that
## joined the group does.
func _add_guest(peer_id: int, entity: String, is_ready: bool = false) -> Dictionary:
	var key := {"id": entity, "type": "title_player_account"}
	var state := PlayerState.new()
	state.peer_id = peer_id
	state.display_name = entity
	state.entity_id = entity
	state.is_ready = is_ready
	NetManager.players[peer_id] = state
	party.fake_peer_keys[peer_id] = key
	party.fake_add_member(party.fake_staging, key, true, {MatchmakingService.PROTOCOL_MEMBER_KEY: NRProtocol.version_string()})
	return key


func _remove_member(context: PartyService.LobbyContext, entity: String) -> void:
	var kept: Array = []
	for member: Dictionary in party.fake_members.get(context.context_id, []):
		if String((member.get("key", {}) as Dictionary).get("id", "")) != entity:
			kept.append(member)
	party.fake_members[context.context_id] = kept


## Every remote member acknowledges the group as it is now and readies through the host's own
## handler, then the owner readies through the lobby's call -- which is what starts the freeze,
## or a full group's private start.
func _ready_all() -> void:
	_consent_all()
	for peer_id: int in NetManager.players.keys():
		if peer_id != NetManager.HOST_PEER_ID:
			NetManager._apply_ready_state(peer_id, true)
	NetManager.set_local_ready(true)


## Every remote member acknowledges the owner's current Gathering composition, as its own client
## does on adopting it: only then does its Ready count.
func _consent_all() -> void:
	var flow: MatchmakingFlow = NetManager._flow
	if flow == null or not flow.is_owner() or flow.phase != MatchmakingFlow.Phase.GATHERING:
		return
	for peer_id: int in NetManager.players.keys():
		if peer_id != NetManager.HOST_PEER_ID:
			flow.on_member_report(peer_id, flow.epoch, MatchmakingFlow.Phase.GATHERING)


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
## arranged lobby joined, with this player, the arranged owner and `cohort` present in it,
## armed, the handoff budget running, and the lobby still open. The arranged owner is this
## player when `arranged_owner`, otherwise a remote owner whose member protocol is this
## build's. This member's own frozen premade is itself and `premade` -- unless a real freeze
## already fixed it and no `premade` is given.
func _arm(flow: MatchmakingFlow, arranged_owner: bool, cohort: Array = [], premade: Array = []) -> void:
	flow.match_id = "matched-%d" % flow.id
	flow.arranged_context = party.fake_arranged
	flow.arranged_owner = arranged_owner
	var owner_key: Dictionary = party.fake_local_key.duplicate() if arranged_owner else _key(ARRANGED_OWNER_ID)
	flow.arranged_owner_key = owner_key
	party.fake_owners[party.fake_arranged.context_id] = owner_key.duplicate()
	# The owner PartyService captured when this member joined the arranged lobby.
	party.fake_arranged.owner_key = owner_key.duplicate()
	# A remote owner has already published its control batch with its descriptor: this
	# match, the first round, bootstrapping.
	if not arranged_owner:
		party.fake_lobby_properties[party.fake_arranged.context_id] = _arranged_control(
			flow.match_id, 0, PartyService.ARRANGED_PHASE_BOOTSTRAP)
	party.fake_set_member(party.fake_arranged, party.fake_local_key, true, _arranged_props(flow.match_id))
	if not arranged_owner:
		party.fake_set_member(party.fake_arranged, owner_key, true, _arranged_props(flow.match_id))
	for entity: String in cohort:
		party.fake_set_member(party.fake_arranged, _key(entity), true, _arranged_props(flow.match_id))
	if flow.frozen_keys.is_empty() or not premade.is_empty():
		var frozen: Array[Dictionary] = [party.fake_local_key.duplicate()]
		for entity: String in premade:
			frozen.append(_key(entity))
		flow.frozen_keys = frozen
	flow.armed = true
	flow.synced = true
	flow._finish_sync()
	flow.phase_deadline_msec = clock.deadline_after(MatchmakingFlow.HANDOFF_SECONDS)
	flow._set_phase(MatchmakingFlow.Phase.ARMING_HANDOFF)
	_complete_activity()


func _key(entity: String) -> Dictionary:
	return {"id": entity, "type": "title_player_account"}


## Makes `owner_key` the owner of the lobby a guest joins, as the join found it: the owner
## PartyService captured on entry, the lobby's native owner and a connected member with
## `properties` -- and peer 1 on this guest's transport. A null context is the hosted lobby.
func _prove_owner(context: PartyService.LobbyContext, owner_key: Dictionary, properties: Dictionary = {}) -> void:
	party.fake_peer_keys[NetManager.HOST_PEER_ID] = owner_key.duplicate()
	if context == null:
		party.fake_hosted_owner = owner_key.duplicate()
		party.fake_hosted_owner_baseline = owner_key.duplicate()
		return
	party.fake_owners[context.context_id] = owner_key.duplicate()
	context.owner_key = owner_key.duplicate()
	party.fake_set_member(context, owner_key, true, properties)


## The arranged owner's checked control batch for `match_id`, round and phase -- and, for the
## first match's start, its start generation and chosen players -- in the service's own encoding.
func _arranged_control(match_id: String, match_round: int, phase: String, start_generation: int = 0,
		selected: Array[Dictionary] = []) -> Dictionary:
	return PartyService.encode_arranged_control(match_id, match_round, phase, start_generation, selected)


## The member properties an arranged member carries once it has joined -- and, when
## `acknowledged`, once it has armed and published its handoff acknowledgement; and, when
## `retired`, once its old staging lobby and transport were left and it said so.
func _arranged_props(match_id: String, acknowledged: bool = true, protocol: String = "", retired: bool = false) -> Dictionary:
	var properties := {
		MatchmakingService.PROTOCOL_MEMBER_KEY: NRProtocol.version_string() if protocol.is_empty() else protocol,
		PartyService.MATCH_ID_MEMBER_KEY: match_id,
	}
	if acknowledged:
		properties[PartyService.HANDOFF_READY_MEMBER_KEY] = match_id
	if retired:
		properties[PartyService.STAGING_RETIRED_MEMBER_KEY] = match_id
	return properties


# --- F1: four-slot staging and one ready path -------------------------------------

func _f1_staging_capacity_and_common_ready_path(test: Node) -> void:
	print("CASE: F1/C-AUTO four-slot staging with no room code; groups of one to three take one ready/ticket path, and a full four starts privately instead")
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
	test._check(lobby._roster_capacity() == 4 and players_line.begins_with("Group 1/4") and players_line.ends_with("Match 2-4"),
		"the lobby draws four group slots and tells the group apart from a match of two to four: %s" % players_line)
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
		var size := index + 2
		if size < MatchmakingFlow.CAPACITY:
			_ack_all(flow)
			var spec: MatchmakingService.SearchSpec = matchmaking.fake_creates.back()
			test._check(matchmaking.fake_creates.size() == size and spec.owner and spec.frozen_members.size() == size
				and spec.capacity == 4 and spec.flow_epoch == flow.epoch,
				"a group of %d takes the same freeze and submits one ticket for all of it" % size)
	test._check(flow.phase == MatchmakingFlow.Phase.PRIVATE_PREPARING and NetManager.players.size() == 4
		and matchmaking.fake_creates.size() == 3,
		"a full group of four, all ready, submits no ticket: it starts a private match instead (phase %d)" % flow.phase)
	lobby = load("res://scripts/ui/screens/lobby_screen.gd").new()
	players_line = lobby._players_line()
	var status: String = lobby._flow_status_text()
	test._check(players_line.begins_with("Group 4/4") and players_line.ends_with("Private match")
		and status == "Starting a private match\u2026",
		"the lobby says the full group is starting a private match: %s / %s" % [players_line, status])
	lobby.free()
	await _teardown(test)


func _f1_invite_entry_into_staging(test: Node) -> void:
	print("CASE: F1 an invite into a staging lobby is recognized by its lobby kind and joins the group")
	await _setup(test, "flow-invitee")
	var peer: Variant = TransportPeer.new(7)
	_prove_owner(party.fake_staging, _key("f1-group-owner"))
	party.fake_join_result = {
		"ok": true, "peer": peer, "code": "", "error": "",
		"kind": PartyService.LOBBY_KIND_STAGING, "destination": "staging_gathering", "context": party.fake_staging,
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
	_consent_all()
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
	flow._enter_matchmade_session()
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
	_arm(flow, true, ["reset-staging-guest"])
	test._check(not NetManager._platform.wants_activity(), "the armed group's activity is already retired")
	var arranged_peer: Variant = TransportPeer.new(NetManager.HOST_PEER_ID)
	party.fake_arranged_peer = arranged_peer
	party.fake_calls.clear()
	var sets := activity.sdk.calls.size()
	flow.switch_transport()
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
	test._check(flow.is_current() and flow.arranged_context == party.fake_arranged
		and NetManager._entry_error() == NetManager.FLOW_BUSY,
		"the flow kept its identity, its arranged lobby and the entry lease across the gap")
	test._check(NetManager.session_id() != 0 and NetManager.session_id() != staging_session and NetManager.is_host()
		and NetManager.players.keys() == [NetManager.HOST_PEER_ID] and NetManager.local_player() != null
		and NetManager.local_player().entity_id == "reset-owner" and NetManager.is_accepting_joins()
		and NetManager._active_join_request == null and flow.phase == MatchmakingFlow.Phase.ADMITTING_COHORT,
		"the arranged owner is peer 1 of a fresh session holding only itself, gate open, no self-admission request")
	var bootstrap := _observed("publish")
	var published_at := party.fake_calls.find("publish:bootstrap:9")
	test._check(bool(bootstrap.get("accepting", false))
		and party.fake_published_phase == MatchmakingFlow.SESSION_PHASE_BOOTSTRAP and published_at >= 0,
		"the bootstrap descriptor is published only after the new gate is open")
	test._check(not party.fake_calls.has("leave_lobby:%d" % party.fake_staging.context_id),
		"while its staging guest is still in the old lobby, the owner keeps it: leaving first would clear the owner under that guest")
	test._check(not flow.staging_retiring and not flow.staging_retired and flow.staging_context == party.fake_staging,
		"waiting for it is preparation, not retirement: the old lobby is still the group's")
	party.fake_remove_member(party.fake_staging, _key("reset-staging-guest"))
	clock.advance(MatchmakingFlow.POLL_SECONDS)
	var retired_at := party.fake_calls.find("leave_lobby:%d" % party.fake_staging.context_id)
	test._check(retired_at > published_at and flow.staging_context == null,
		"once the guest has left, the owner retires the old staging lobby (publish %d, retire %d)" % [published_at, retired_at])
	test._check(flow.staging_retired and flow.retirement_reported,
		"its retirement is confirmed and reported: retired %s, reported %s" % [flow.staging_retired, flow.retirement_reported])
	test._check(activity.sdk.calls.size() == sets and not NetManager._platform.wants_activity()
		and not NetManager.everyone_ready(), "the bootstrap is never advertised and no staging readiness survives")
	party.fake_peer_keys[5] = _key("reset-staging-guest")
	arranged_peer.connect_remote(5)
	test._check(arranged_peer.sent.size() > 0 and NetManager.players.keys() == [NetManager.HOST_PEER_ID],
		"a proven newcomer's roster replay is built from the fresh roster alone")
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


# --- Entry fences: the service's availability decides what the one row does ---------

## Whatever makes Quick Match unavailable -- a missing addon capability, a profile that is
## not four players, no queue, no PlayFab -- the service's reason is the one answer at every
## public entry. The one Matchmaking row still sits directly above Host Match and stays in
## the menu's focus loop; pressing it shows that exact reason instead of starting anything;
## the owner entry refuses before any staging work; and an invitation that resolves to a
## staging gathering is refused and its lobby left. The service suite proves each production
## reason; this case proves the entry points repeat whichever one the service gives. The
## invitation refusal is NetManager's defense in depth only -- PartyService refuses a
## matchmaking-kind lobby before any Party work of its own while Quick Match is unavailable,
## and that ingress fence is the service suite's case. The wire contract does not depend on
## availability: protocol 3.4, with all four flow RPCs declared in every build.
func _p1_unavailable_matchmaking_explains_at_every_entry(test: Node) -> void:
	print("CASE: P1 unavailable Quick Match: the focusable row explains, and owner and invited-guest entry refuse, with the service's reason")
	await _setup(test, "unavailable-player")
	var unavailable := "This build's PlayFab addon cannot create group matchmaking tickets."
	matchmaking.fake_unavailable_reason = unavailable
	test._check(not Services.quick_match_available(), "a reason from the service makes Quick Match unavailable")
	test._check(Services.quick_match_unavailable_reason() == unavailable,
		"and it is the reason every entry shows: %s" % Services.quick_match_unavailable_reason())
	test._check(NRProtocol.RPC_SET_VERSION == 4 and NRProtocol.WIRE_VERSION == 3
		and NRProtocol.version_string() == "3.4",
		"the wire contract is protocol 3.4: %s" % NRProtocol.version_string())
	test._check(NetManager.has_method("_receive_flow_phase") and NetManager.has_method("_submit_flow_ack")
		and NetManager.has_method("_submit_flow_leave") and NetManager.has_method("_request_flow_state"),
		"all four flow RPCs are declared whatever availability says, so the RPC set is the same in every build")

	test._check(not await NetManager.start_matchmaking(), "the owner entry is refused")
	test._check(NetManager.last_error == unavailable, "with the service's reason: %s" % NetManager.last_error)
	test._check(not NetManager.has_online_flow() and not NetManager.has_session()
		and not party.fake_calls.has("create_staging"),
		"before any staging work: flow %s, session %s, calls %s"
			% [NetManager.has_online_flow(), NetManager.has_session(), str(party.fake_calls)])

	party.fake_join_result = {
		"ok": true, "peer": TransportPeer.new(7), "code": "", "error": "",
		"kind": PartyService.LOBBY_KIND_STAGING, "destination": "staging_gathering", "context": party.fake_staging,
	}
	var request := NetManager.join_by_invite(STAGING_CONNECTION)
	await test.get_tree().process_frame
	test._check(request.outcome == JoinRequest.Outcome.FAILED,
		"an invitation into a staging gathering is refused: outcome %d" % request.outcome)
	test._check(request.reason == unavailable, "with the same reason: %s" % request.reason)
	test._check(not NetManager.has_online_flow() and not NetManager.has_session()
		and NetManager._pending_join_context == null,
		"it is bound to nothing: flow %s, session %s, pending context %s"
			% [NetManager.has_online_flow(), NetManager.has_session(), NetManager._pending_join_context != null])
	test._check(party.fake_calls.has("leave_lobby:%d" % party.fake_staging.context_id)
		and party.fake_calls.has("leave_transport:%d" % party.fake_staging.context_id),
		"and the lobby it entered is left: %s" % str(party.fake_calls))

	var audio_script: Script = AudioManager.get_script()
	AudioManager.set_script(Review.QuietAudio)
	var app := preload("res://scenes/main.tscn").instantiate()
	app.set_script(Review.MainProbe)
	test.add_child(app)
	var menu: Variant = ScreenManager.push(ScreenManager.MAIN_MENU)
	_check_matchmaking_row(test, menu, "unavailable")
	if menu != null:
		menu._on_matchmaking()
	var explained: Variant = ScreenManager.current_screen()
	var shown: bool = explained != null and explained.scene_file_path == ScreenManager.DIALOG_BOX
	test._check(shown and explained._title == "Matchmaking Unavailable",
		"pressing it answers with the unavailable dialog: %s" % (explained._title if shown else "no dialog"))
	test._check(shown and explained._message == unavailable,
		"showing the service's exact reason: %s" % (explained._message if shown else "no dialog"))
	test._check(not NetManager.has_online_flow() and not NetManager.has_session()
		and not party.fake_calls.has("create_staging"),
		"and starts no online work: flow %s, session %s, calls %s"
			% [NetManager.has_online_flow(), NetManager.has_session(), str(party.fake_calls)])
	if shown:
		explained._ok_button.pressed.emit()
	await test.get_tree().process_frame
	var join_rows: Array[String] = []
	if menu != null and is_instance_valid(menu):
		menu._build_join_menu()
		join_rows = _row_labels(menu)
	var join_offers := false
	for label: String in join_rows:
		if label.to_lower().contains("matchmak") or label.to_lower().contains("quick"):
			join_offers = true
	test._check(join_rows.has("Lobby Code") and not join_offers,
		"the Join submenu offers no second matchmaking entry: %s" % str(join_rows))
	await _close_menu_probe(test, app, audio_script)
	await _teardown(test)


## Once the service reports no reason, the same row opens a group. Its press runs the
## permission check and reaches staging creation behind "Opening the group", for a four-slot
## group this player owns -- held there, so the case proves the entry without opening a
## lobby screen. An invitation into a staging lobby then meets the destination policy
## instead of the availability refusal: a staging lobby offered as anything but a gathering
## is refused and left, and a staging gathering binds as a guest waiting for the owner's
## admission, which F1 carries on into the group.
func _p1_available_matchmaking_opens_a_group_from_the_row(test: Node) -> void:
	print("CASE: P1 available Quick Match: the row opens a group, and staging invitations follow the destination policy")
	await _setup(test, "available-player")
	test._check(Services.quick_match_available(), "with no reason from the service, Quick Match is available")
	test._check(Services.quick_match_unavailable_reason().is_empty(),
		"and there is nothing to explain: '%s'" % Services.quick_match_unavailable_reason())

	var audio_script: Script = AudioManager.get_script()
	AudioManager.set_script(Review.QuietAudio)
	var app := preload("res://scenes/main.tscn").instantiate()
	app.set_script(Review.MainProbe)
	test.add_child(app)
	var menu: Variant = ScreenManager.push(ScreenManager.MAIN_MENU)
	_check_matchmaking_row(test, menu, "available")
	party.fake_block_create = true
	if menu != null:
		menu._on_matchmaking()
	for _frame in 10:
		if party.fake_calls.has("create_staging"):
			break
		await test.get_tree().process_frame
	test._check(party.fake_calls.has("create_staging"),
		"pressing the row starts the flow: the owner entry reached staging creation")
	test._check(party.fake_created_capacity == MatchmakingFlow.CAPACITY,
		"for a group of %d slots: %d" % [MatchmakingFlow.CAPACITY, party.fake_created_capacity])
	var flow: MatchmakingFlow = NetManager._flow
	test._check(flow != null and flow.is_owner(), "that this player owns: %s" % ("owner" if flow != null and flow.is_owner() else "no owned flow"))
	test._check(NetManager.has_online_flow(), "and that holds the online lease")
	var opening: Variant = ScreenManager.current_screen()
	var loading: bool = opening != null and opening.scene_file_path == ScreenManager.LOADING
	test._check(loading and opening._message == "Opening the group",
		"behind its loading screen: %s" % (opening._message if loading else "no loading screen"))
	# Leaving while the group opens ends the start; whatever the menu answers is dismissed.
	# Ten frames of real time would cover a cleanup poll, so the case clock moves one too.
	NetManager.leave_match()
	party.fake_block_create = false
	party.fake_create_released.emit()
	clock.advance(MatchmakingFlow.POLL_SECONDS)
	for _frame in 10:
		await test.get_tree().process_frame
		var current: Variant = ScreenManager.current_screen()
		if current != null and current.scene_file_path == ScreenManager.DIALOG_BOX:
			current._ok_button.pressed.emit()
	test._check(not NetManager.has_online_flow() and not NetManager.has_session(),
		"leaving while it opens ends the start, with no group or session left: flow %s, session %s"
			% [NetManager.has_online_flow(), NetManager.has_session()])
	test._check(ScreenManager.current_screen() == menu, "and the player is back on the menu")

	party.fake_calls.clear()
	party.fake_join_result = {
		"ok": true, "peer": TransportPeer.new(7), "code": "", "error": "",
		"kind": PartyService.LOBBY_KIND_STAGING, "destination": "", "context": party.fake_staging,
	}
	var misrouted := NetManager.join_by_invite(STAGING_CONNECTION)
	await test.get_tree().process_frame
	test._check(misrouted.outcome == JoinRequest.Outcome.FAILED,
		"a staging lobby not offered as a gathering is refused: outcome %d" % misrouted.outcome)
	test._check(misrouted.reason == NetManager._INVITE_DESTINATION_REFUSED,
		"by the destination policy, not by availability: %s" % misrouted.reason)
	test._check(not NetManager.has_session() and NetManager._pending_join_context == null,
		"it is bound to nothing: session %s, pending context %s"
			% [NetManager.has_session(), NetManager._pending_join_context != null])
	test._check(party.fake_calls.has("leave_lobby:%d" % party.fake_staging.context_id),
		"and its lobby is left: %s" % str(party.fake_calls))

	party.fake_calls.clear()
	party.fake_join_result = {
		"ok": true, "peer": TransportPeer.new(7), "code": "", "error": "",
		"kind": PartyService.LOBBY_KIND_STAGING, "destination": "staging_gathering", "context": party.fake_staging,
	}
	var invited := NetManager.join_by_invite(STAGING_CONNECTION)
	test._check(invited.is_pending() and NetManager.has_session() and not NetManager.is_host(),
		"a staging gathering binds as a guest waiting for the owner's admission: pending %s, session %s, host %s"
			% [invited.is_pending(), NetManager.has_session(), NetManager.is_host()])
	test._check(NetManager._pending_join_destination == "staging_gathering",
		"as an entry into the group: '%s'" % NetManager._pending_join_destination)
	test._check(NetManager._pending_join_context == party.fake_staging, "holding the group's staging lobby")
	test._check(not party.fake_calls.has("leave_lobby:%d" % party.fake_staging.context_id),
		"which is kept, not left: %s" % str(party.fake_calls))
	NetManager.cancel_join(invited)
	for _poll in 3:
		if not invited.is_pending():
			break
		clock.advance(MatchmakingFlow.POLL_SECONDS)
		await test.get_tree().process_frame
	test._check(invited.outcome == JoinRequest.Outcome.CANCELLED,
		"and cancelling that entry ends it: outcome %d" % invited.outcome)
	await _close_menu_probe(test, app, audio_script)
	await _teardown(test)


## The top-level rows as a player sees them: the one Matchmaking row directly above Host
## Match, enabled and in the menu's focus loop, whether or not Quick Match is available.
func _check_matchmaking_row(test: Node, menu: Variant, label: String) -> void:
	var top := _row_labels(menu)
	var matchmaking_rows := 0
	for caption: String in top:
		var lowered := caption.to_lower()
		if lowered.contains("quick") or lowered.contains("matchmak") or lowered.contains("find match") \
				or lowered.contains("search"):
			matchmaking_rows += 1
	test._check(top.has("Host Match") and top.has("Join Match"),
		"%s: the shipped rows are still offered: %s" % [label, str(top)])
	test._check(matchmaking_rows == 1,
		"%s: exactly one matchmaking row is offered: %d in %s" % [label, matchmaking_rows, str(top)])
	test._check(top.find("Matchmaking") >= 0 and top.find("Matchmaking") == top.find("Host Match") - 1,
		"%s: the Matchmaking row sits directly above Host Match: %s" % [label, str(top)])
	var row: Variant = menu._matchmaking_row if menu != null else null
	test._check(row != null and not bool(row.disabled), "%s: the Matchmaking row is enabled" % label)
	test._check(row != null and bool(menu._menu_list._is_focusable(row)),
		"%s: and takes focus in the menu's loop" % label)


## Takes down the real main scene a case opened and puts back the audio it silenced.
func _close_menu_probe(test: Node, app: Node, audio_script: Script) -> void:
	await test.get_tree().process_frame
	ScreenManager.clear()
	app.queue_free()
	await test.get_tree().process_frame
	ScreenManager.set_container(test)
	AudioManager.set_script(audio_script)
	PlayerProfile.apply_dict(PlayerProfile.to_dict())


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
	test._check(configured == 4 and flow.capacity == configured,
		"the shipped configuration admits the group with its four-player room capacity")
	NetManager.set_local_ready(true)
	var spec: MatchmakingService.SearchSpec = null
	if not matchmaking.fake_creates.is_empty():
		spec = matchmaking.fake_creates[0]
	test._check(spec != null and spec.mode == NRTypes.GameModeType.DEATHMATCH and spec.capacity == configured,
		"the owner's ticket carries the requested mode and the configured room capacity")
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


# --- Phase 1 harness helpers -------------------------------------------------------

## A solo owner's group, searching: ready, frozen, its ticket published.
func _searching_owner(test: Node) -> MatchmakingFlow:
	var flow := await _open_group(test)
	if flow == null:
		return null
	NetManager.set_local_ready(true)
	var attempt := _attempt()
	test._check(attempt != null, "the solo owner's ready creates a ticket")
	if attempt == null:
		return null
	_progress(attempt, MatchmakingService.STATUS_WAITING_FOR_MATCH, "ticket-%d" % flow.id)
	return flow


## Settles the newest attempt as matched into `match_id`.
func _match(match_id: String) -> void:
	var attempt := _attempt()
	if attempt == null:
		return
	attempt.match_id = match_id
	attempt.arrangement = "arrangement-" + match_id
	attempt.settle(MatchmakingService.Outcome.MATCHED)


## The service observing native Matched on `attempt`, the way it surfaces the supported addon's
## single terminal batch. A cancel this double started is answered as the lost race, and the
## service holds its terminal notice until that answer has cleared the waiter -- whether the
## answer came first (`answer` `&"completion_first"`, the addon's own order) or the terminal
## event did (`&"event_first"`), in the same step -- so the caller sees the notice with nothing
## in flight, and the service's cleanup then settles once. With the double's injected
## `fault_cancel_unanswered` the waiter stays in flight and the service holds the notice back:
## only the ticket's native status says it matched. `notice_first` orders the once-only terminal
## notice against the caller's settlement.
func _native_match(attempt: MatchmakingService.TicketAttempt, match_id: String, notice_first: bool = false,
		answer: StringName = &"completion_first") -> void:
	if attempt == null:
		return
	var waiting := attempt.cancel_in_flight
	var answered := waiting and (matchmaking == null or not matchmaking.fault_cancel_unanswered)
	if answered and answer == &"completion_first":
		attempt.cancel_in_flight = false
	attempt.status = MatchmakingService.STATUS_MATCHED
	attempt.match_id = match_id
	attempt.arrangement = "arrangement-" + match_id
	attempt.native_terminal = true
	if waiting and not answered:
		return
	attempt.cancel_in_flight = false
	_notify_matched(attempt, notice_first)
	if answered:
		attempt.cleanup_pending = false
		attempt.cleanup_changed.emit(attempt)


## The service's once-only terminal notice and the caller's settlement for a matched attempt, in
## the order a case asks for.
func _notify_matched(attempt: MatchmakingService.TicketAttempt, notice_first: bool) -> void:
	var notify := not attempt.native_terminal_notified
	attempt.native_terminal_notified = true
	if notice_first and notify:
		attempt.native_terminal_changed.emit(attempt)
	if attempt.is_pending():
		attempt.settle(MatchmakingService.Outcome.MATCHED)
	if not notice_first and notify:
		attempt.native_terminal_changed.emit(attempt)


## The service's local search deadline on `attempt`: TIMEOUT for the caller, and the native
## cancel it starts for the live ticket still owed.
func _time_out(attempt: MatchmakingService.TicketAttempt) -> void:
	if attempt == null:
		return
	attempt.cancel_in_flight = true
	attempt.cleanup_pending = true
	attempt.settle(MatchmakingService.Outcome.TIMEOUT, MatchmakingService.SEARCH_TIMEOUT_REASON_CODE,
		MatchmakingService.SEARCH_TIMEOUT_REASON)


## An injected unanswered cancel that answers after all, late: the lost-race answer arriving
## after the terminal event. The waiter clears, the service delivers the terminal notice it held
## back and the caller's settlement, and then reconciles the matched ticket's cleanup.
func _late_lost_race_answer(attempt: MatchmakingService.TicketAttempt) -> void:
	if attempt == null:
		return
	attempt.cancel_in_flight = false
	_notify_matched(attempt, true)
	attempt.cleanup_pending = false
	attempt.cleanup_changed.emit(attempt)


## A staging guest on peer `peer_id` of the owner's staging transport, adopted into a guest
## flow the way an admitted invite leaves it. The staging owner is peer 1 and the lobby's
## native owner; whatever the staging envelope already holds is what adoption finds.
func _staging_guest(test: Node, peer_id: int) -> MatchmakingFlow:
	var staging_peer: Variant = TransportPeer.new(peer_id)
	test._check(NetManager._bind_peer(staging_peer), "the guest binds its staging transport")
	NetManager._is_offline = false
	var owner_key := _key("staging-owner")
	party.fake_owners[party.fake_staging.context_id] = owner_key.duplicate()
	party.fake_staging.owner_key = owner_key.duplicate()
	party.fake_peer_keys[NetManager.HOST_PEER_ID] = owner_key.duplicate()
	# Each member carries this build's protocol in its own entry, as the group's creator and a
	# joining member write it.
	var member_properties := {MatchmakingService.PROTOCOL_MEMBER_KEY: NRProtocol.version_string()}
	party.fake_members[party.fake_staging.context_id] = [
		{"key": owner_key.duplicate(), "connected": true, "properties": member_properties.duplicate()},
		{"key": party.fake_local_key.duplicate(), "connected": true, "properties": member_properties.duplicate()},
	]
	# The scope an ordinary staging join captures as it binds: peer 1 answers as the
	# staging lobby's owner, or not at all.
	NetManager._capture_authority_scope(&"staging", party.fake_staging, {}, "", 0)
	staging_peer.connect_remote(NetManager.HOST_PEER_ID)
	var host := PlayerState.new()
	host.peer_id = NetManager.HOST_PEER_ID
	host.display_name = "Staging Owner"
	NetManager.players[NetManager.HOST_PEER_ID] = host
	# The admission an ordinary staging join completes on this session, as its consumption
	# records it.
	NetManager._flow_admitted_session = NetManager._session_generation
	var flow := NetManager._new_flow(MatchmakingFlow.Role.GUEST, NRTypes.GameModeType.DEATHMATCH)
	flow.start_guest(party.fake_staging)
	return flow


## Brings a staging guest into the owner's search at `epoch`: frozen, the ticket published in
## the lobby envelope with this guest in its group, the owner's broadcast carrying the budget,
## and the service accepting this member into the ticket.
func _guest_search(epoch: int, ticket_id: String, remaining_ms: int) -> MatchmakingService.TicketAttempt:
	NetManager._receive_flow_phase(epoch, MatchmakingFlow.Phase.FREEZING, {})
	var group: Array[Dictionary] = [party.fake_local_key.duplicate(), _key("staging-owner")]
	party.fake_search_control[party.fake_staging.context_id] = {
		"valid": true, "schema": PartyService.SEARCH_CONTROL_SCHEMA, "epoch": epoch,
		"phase": MatchmakingFlow.ENVELOPE_SEARCHING, "group": group, "ticket_id": ticket_id,
		"reason_code": "", "reason": "",
	}
	NetManager._receive_flow_phase(epoch, MatchmakingFlow.Phase.SEARCHING, {"remaining_ms": remaining_ms})
	var attempt := _attempt()
	if attempt != null:
		_progress(attempt, MatchmakingService.STATUS_WAITING_FOR_MATCH, ticket_id)
	return attempt


## An arranged owner's fresh session, open and admitting, with this player and `cohort`
## present in the arranged lobby and nobody chosen yet: where F6, F7, F10 and the start cases
## begin. The owner's own old group -- only itself here -- is already retired and reported.
func _host_cohort(test: Node, cohort: Array) -> MatchmakingFlow:
	var flow := await _open_group(test)
	if flow == null:
		return null
	_arm(flow, true, cohort)
	party.fake_arranged_peer = TransportPeer.new(NetManager.HOST_PEER_ID)
	await flow.switch_transport()
	test._check(flow.phase == MatchmakingFlow.Phase.ADMITTING_COHORT and NetManager.is_host()
		and not NetManager._cohort_policy.is_empty() and flow.selected_keys.is_empty(),
		"the arranged host is admitting arrivals, nobody chosen yet (phase %d)" % flow.phase)
	return flow


## A cohort member reaching the arranged host's network, as the transport announces it.
func _connect_member(peer_id: int, entity: String) -> void:
	party.fake_peer_keys[peer_id] = _key(entity)
	party.fake_arranged_peer.connect_remote(peer_id)


## The remote calls among the packets a transport recorded. SceneMultiplayer precedes the
## first call to each peer with a one-time announcement of the calling node's path, which
## is not a call: the low three bits of a packet's first byte are its command, and a
## remote call is command 0.
func _rpc_calls(peer: Variant) -> int:
	var calls := 0
	for packet: PackedByteArray in peer.sent:
		if packet.size() > 0 and (packet[0] & 7) == 0:
			calls += 1
	return calls


## A peer's identity submission, through the host's production decision body.
func _identify(peer_id: int, entity: String) -> void:
	var state := PlayerState.new()
	state.peer_id = peer_id
	state.display_name = entity
	state.entity_id = entity
	NetManager._admit_identity(peer_id, state.to_dict(), NRProtocol.version_string())


## Connects and identifies `entities` as peers `first_peer`, `first_peer` + 1...
func _admit_cohort(entities: Array, first_peer: int = 2) -> void:
	for index in entities.size():
		_connect_member(first_peer + index, String(entities[index]))
		_identify(first_peer + index, String(entities[index]))


## The remote calls a transport recorded addressed to `peer_id` alone, counted as
## _rpc_calls() counts them.
func _calls_to(peer: Variant, peer_id: int) -> int:
	var calls := 0
	for index in peer.sent.size():
		var packet: PackedByteArray = peer.sent[index]
		if packet.size() > 0 and (packet[0] & 7) == 0 and int(peer.targets[index]) == peer_id:
			calls += 1
	return calls


## Every present arrival of `entities` done with its old group, then connected and identified
## as peers `first_peer`, `first_peer` + 1...: once the last is admitted, the arranged host's
## own decision may start the first match.
func _start_with(flow: MatchmakingFlow, entities: Array, first_peer: int = 2) -> void:
	_report_retired(flow, entities)
	_admit_cohort(entities, first_peer)


## The owner of a group of this player and `guests` -- peers 7, 8... -- searching together on
## one ticket.
func _searching_group(test: Node, guests: Array) -> MatchmakingFlow:
	var flow := await _open_group(test)
	if flow == null:
		return null
	for index in guests.size():
		_add_guest(7 + index, String(guests[index]))
	NetManager.roster_changed.emit()
	_ready_all()
	_ack_all(flow)
	var attempt := _attempt()
	test._check(attempt != null and flow.frozen_keys.size() == guests.size() + 1,
		"the group of %d froze and submitted one ticket" % (guests.size() + 1))
	if attempt == null:
		return null
	_progress(attempt, MatchmakingService.STATUS_WAITING_FOR_MATCH, "ticket-%d" % flow.id)
	return flow


## A staging guest carried into the arranged session and admitted there, waiting for the
## owner's first start: the owner's bootstrap control is up, and this member's own premade --
## itself and `premade`, all present and armed in the arranged lobby -- is complete.
func _arranged_guest(test: Node, account: String, premade: Array = []) -> MatchmakingFlow:
	await _setup(test, account)
	var flow := _staging_guest(test, 7)
	_arm(flow, false, premade, premade)
	var arranged_peer: Variant = TransportPeer.new(9)
	party.fake_arranged_peer = arranged_peer
	flow.switch_transport()
	arranged_peer.connect_remote(NetManager.HOST_PEER_ID)
	NetManager._accept_join()
	clock.advance(MatchmakingFlow.POLL_SECONDS)
	test._check(flow.is_current() and flow.phase == MatchmakingFlow.Phase.ADMITTING_COHORT
		and NetManager._active_join_request == null and flow.staging_retired,
		"[%s] the guest is admitted, its old group retired, and it waits for the owner's start" % account)
	return flow


## The arranged owner's published first start for `flow`'s match: generation 1 and `chosen`.
func _publish_start(flow: MatchmakingFlow, chosen: Array[Dictionary]) -> void:
	party.fake_lobby_properties[party.fake_arranged.context_id] = _arranged_control(
		flow.match_id, 0, PartyService.ARRANGED_PHASE_STARTING, 1, chosen)


## The arranged lobby shows `entities` having retired their old staging resources: each
## member's own `nr_staging_retired` marker for `marker_match`, or this flow's match.
func _report_retired(flow: MatchmakingFlow, entities: Array, marker_match: String = "") -> void:
	var value := marker_match if not marker_match.is_empty() else flow.match_id
	for entity: Variant in entities:
		var props := _arranged_props(flow.match_id)
		props[PartyService.STAGING_RETIRED_MEMBER_KEY] = value
		party.fake_set_member(party.fake_arranged, _key(String(entity)), true, props)
	NetManager._on_context_changed(party.fake_arranged)


func _start_matchmaking_into(box: Array) -> void:
	box[0] = await NetManager.start_matchmaking()


# --- S1/F11: entry refuses before unsafe work -------------------------------------------

func _p1_entry_refuses_before_unsafe_work(test: Node) -> void:
	print("CASE: S1/F11 Matchmaking entry refuses before any work while scoped work drains, Party recovery stands or the console is offline")
	await _setup(test, "entry-refusals")
	party.fake_owned_work = true
	var drained: bool = await NetManager.start_matchmaking()
	test._check(not drained and NetManager.last_error == NetManager._PREVIOUS_SESSION_FINISHING,
		"a retired group's scoped Party work still draining refuses a new group: %s" % NetManager.last_error)
	party.fake_owned_work = false
	party.recovery_error = PartyService.RECOVERY_FAILED
	var recovering: bool = await NetManager.start_matchmaking()
	test._check(not recovering and NetManager.last_error == PartyService.RECOVERY_FAILED,
		"a failed Party recovery keeps its restart-required refusal: %s" % NetManager.last_error)
	party.recovery_error = ""
	var connectivity := ConnectivityService.new()
	connectivity._set_online(false)
	Services._connectivity = connectivity
	var offline: bool = await NetManager.start_matchmaking()
	test._check(not offline and NetManager.last_error == connectivity.offline_reason(),
		"a definitively offline console is refused at the entry: %s" % NetManager.last_error)
	Services._connectivity = null
	test._check(not NetManager.has_online_flow() and not party.fake_calls.has("create_staging"),
		"no refusal started a flow or any staging work")
	await _teardown(test)


# --- B-ORDER / B-PREMADE: each premade arms itself; the arranged lobby stays open -------

## The owner of a two-player group becomes the arranged owner. After its own arranged join it
## arms and says so, then waits only for its own premade -- never for four, a count or any
## other group's players. A slow member of its premade holds the old network: it is left only
## once that member is in the arranged lobby and armed. Then the fresh network is prepared,
## local admission opens and the descriptor goes out, all with the arranged lobby unlocked,
## and nothing renews the handoff budget.
func _b_order_owner_waits_only_for_its_own_premade(test: Node) -> void:
	print("CASE: B-ORDER/B-PREMADE the arranged owner waits only for its own premade, leaves its old network only then, and opens the fresh one unlocked")
	await _setup(test, "order-owner")
	var flow := await _searching_group(test, ["order-guest"])
	if flow == null:
		await _teardown(test)
		return
	party.fake_arranged_join_ok = true
	party.fake_arranged_owner = party.fake_local_key.duplicate()
	party.fake_owners[party.fake_arranged.context_id] = party.fake_local_key.duplicate()
	party.fake_arranged_peer = TransportPeer.new(NetManager.HOST_PEER_ID)
	party.fake_calls.clear()
	var matched_at := clock.now_msec()
	_match("match-order")
	var join_call: Dictionary = party.fake_join_arranged_calls.back() if not party.fake_join_arranged_calls.is_empty() else {}
	test._check(int(join_call.get("capacity", 0)) == 4 and not join_call.has("expected_count"),
		"the arranged join carries the room's capacity, not a match size: %s" % str(join_call))
	var join_budget := int(party.fake_deadlines.get("join_arranged", 0)) - matched_at
	test._check(join_budget == 30000, "the arranged join has its own 30-second budget: %d ms" % join_budget)
	test._check(flow.phase == MatchmakingFlow.Phase.ARMING_HANDOFF and flow.armed and flow.arranged_owner,
		"after its own arranged join the owner is armed (phase %d)" % flow.phase)
	var handoff_budget := flow.phase_deadline_msec - clock.now_msec()
	test._check(handoff_budget == 90000, "the premade, transport and admission budget is a separate 90 seconds: %d ms" % handoff_budget)
	var local_member := party._fake_member(party.fake_arranged, party.fake_local_key)
	var acknowledged := String((local_member.get("properties", {}) as Dictionary).get(PartyService.HANDOFF_READY_MEMBER_KEY, ""))
	test._check(acknowledged == "match-order", "its acknowledgement is published after its arranged join: '%s'" % acknowledged)
	var budget := flow.phase_deadline_msec
	clock.advance(1.0)
	test._check(flow.phase == MatchmakingFlow.Phase.ARMING_HANDOFF
		and not party.fake_calls.has("leave_transport:%d" % party.fake_staging.context_id)
		and not party.fake_calls.has("prepare"),
		"while its own group's other member has not arrived, the old network is kept and nothing is prepared")
	party.fake_set_member(party.fake_arranged, _key("order-guest"), true, _arranged_props("match-order", false))
	clock.advance(MatchmakingFlow.POLL_SECONDS)
	test._check(flow.phase == MatchmakingFlow.Phase.ARMING_HANDOFF
		and not party.fake_calls.has("leave_transport:%d" % party.fake_staging.context_id),
		"arrived but not yet armed, that member still holds the old network")
	party.fake_set_member(party.fake_arranged, _key("order-guest"), true, _arranged_props("match-order"))
	clock.advance(MatchmakingFlow.POLL_SECONDS)
	var left_at := party.fake_calls.find("leave_transport:%d" % party.fake_staging.context_id)
	var prepared_at := party.fake_calls.find("prepare")
	var published_at := party.fake_calls.find("publish:bootstrap:9")
	test._check(left_at >= 0 and prepared_at > left_at and published_at > prepared_at,
		"with its own group armed -- and nobody else -- it leaves its old network, then prepares and publishes the fresh one (leave %d, prepare %d, publish %d)" % [left_at, prepared_at, published_at])
	test._check(not party.fake_calls.has("lock:true") and not bool(party.fake_locked.get(party.fake_arranged.context_id, false)),
		"the arranged lobby is not locked while players are still arriving")
	var published := _observed("publish")
	test._check(bool(published.get("accepting", false)) and int(published.get("local_peer_id", 0)) == NetManager.HOST_PEER_ID,
		"its local admission was open, as peer 1, before the descriptor went out")
	var control := PartyService.decode_arranged_control(party.fake_lobby_properties.get(party.fake_arranged.context_id, {}))
	test._check(bool(control.get("valid", false)) and String(control.get("phase", "")) == PartyService.ARRANGED_PHASE_BOOTSTRAP
		and int(control.get("start_generation", -1)) == 0 and int(control.get("selected_count", -1)) == 0,
		"the descriptor's control says bootstrap, with no start chosen: %s" % str(control))
	test._check(not NetManager._cohort_policy.is_empty() and (NetManager._cohort_policy.get("selected", {}) as Dictionary).is_empty()
		and int(NetManager._cohort_policy.get("generation", -1)) == 0,
		"admission is open to arrivals, with nobody chosen")
	var slice := int(party.fake_deadlines.get("prepare", 0)) - clock.now_msec()
	test._check(slice > 0 and slice <= 30000, "the owner's network preparation gets a 30-second slice of the 90: %d ms" % slice)
	test._check(budget == flow.phase_deadline_msec, "no member update renewed the handoff budget")
	test._check(flow.phase == MatchmakingFlow.Phase.ADMITTING_COHORT and NetManager.is_host(),
		"the owner is peer 1 of the fresh network, admitting (phase %d)" % flow.phase)
	await _teardown(test)


## A solo searcher's premade is itself: matched, it arms, leaves its old network and prepares
## the fresh one with only itself in the arranged lobby -- no other group need be there. Alone
## it never starts; one arrival from any group makes two, and those two start.
func _b_premade_solo_owner_opens_alone_and_starts_with_one_arrival(test: Node) -> void:
	print("CASE: B-PREMADE a solo arranged owner opens the fresh network alone, never starts alone, and starts once one other player is ready")
	await _setup(test, "solo-owner")
	var flow := await _searching_owner(test)
	if flow == null:
		await _teardown(test)
		return
	party.fake_arranged_join_ok = true
	party.fake_arranged_owner = party.fake_local_key.duplicate()
	party.fake_owners[party.fake_arranged.context_id] = party.fake_local_key.duplicate()
	party.fake_arranged_peer = TransportPeer.new(NetManager.HOST_PEER_ID)
	party.fake_calls.clear()
	_match("match-solo")
	test._check(party.fake_calls.has("prepare") and party.fake_calls.has("publish:bootstrap:9")
		and flow.phase == MatchmakingFlow.Phase.ADMITTING_COHORT and NetManager.players.size() == 1,
		"its own premade complete at once, it prepares and publishes the fresh network holding only itself (phase %d)" % flow.phase)
	test._check((party.fake_members.get(party.fake_arranged.context_id, []) as Array).size() == 1,
		"with no other group represented in the arranged lobby")
	test._check(flow.staging_retired and flow.retirement_reported, "its own old group is retired and reported")
	clock.advance(60.0)
	test._check(flow.is_current() and _commit_not_started(flow),
		"one present player never starts, however long it waits inside the budget")
	_start_with(flow, ["solo-b"])
	test._check(NetManager.match_state == NRTypes.MatchState.STARTING and flow.selected_keys.size() == 2,
		"one arrival from any group makes two present and ready, and they start: %d chosen" % flow.selected_keys.size())
	await _teardown(test)


# --- F5: the gate opens before the descriptor ------------------------------------------

func _f5_guest_turned_owner_opens_admission_before_its_descriptor(test: Node) -> void:
	print("CASE: F5 an arranged owner that was a staging guest opens admission as peer 1 before its descriptor, lobby unlocked, with nothing advertised")
	await _setup(test, "f5-guest")
	var flow := _staging_guest(test, 7)
	var attempt := _guest_search(1, "ticket-f5", 500000)
	test._check(attempt != null and flow.phase == MatchmakingFlow.Phase.SEARCHING,
		"the staging guest is in the owner's search (phase %d)" % flow.phase)
	if attempt == null:
		await _teardown(test)
		return
	party.fake_arranged_join_ok = true
	party.fake_arranged_owner = party.fake_local_key.duplicate()
	party.fake_owners[party.fake_arranged.context_id] = party.fake_local_key.duplicate()
	for entity: String in ["staging-owner", "f5-c", "f5-d"]:
		party.fake_set_member(party.fake_arranged, _key(entity), true, _arranged_props("match-f5"))
	var arranged_peer: Variant = TransportPeer.new(NetManager.HOST_PEER_ID)
	party.fake_arranged_peer = arranged_peer
	party.fake_peer_keys[5] = _key("f5-c")
	party.fake_connect_on_publish = 5
	_complete_activity()
	var sets := activity.sdk.calls.size()
	party.fake_calls.clear()
	attempt.match_id = "match-f5"
	attempt.arrangement = "arrangement-f5"
	attempt.settle(MatchmakingService.Outcome.MATCHED)
	test._check(flow.role == MatchmakingFlow.Role.GUEST and flow.arranged_owner,
		"the service-elected arranged owner was a staging guest")
	test._check(party.fake_calls.has("prepare") and not party.fake_calls.has("join_transport"),
		"it creates the fresh network rather than joining one")
	var published := _observed("publish")
	test._check(bool(published.get("accepting", false)), "its local admission was open before the descriptor went out")
	test._check(int(published.get("local_peer_id", 0)) == NetManager.HOST_PEER_ID and int(published.get("players", 0)) == 1,
		"as peer 1, holding only itself: peer %d, %d players" % [int(published.get("local_peer_id", 0)), int(published.get("players", 0))])
	test._check(not NetManager._cohort_policy.is_empty() and (NetManager._cohort_policy.get("selected", {}) as Dictionary).is_empty(),
		"admission of any proven arrival was in place before publication, with nobody chosen")
	test._check(not NetManager._arranged_candidates.has(5) and arranged_peer.sent.size() > 0,
		"a matched player reaching the network at publication is greeted at once, not refused as late")
	test._check(not party.fake_calls.has("lock:true"), "the arranged lobby stays unlocked")
	test._check(activity.sdk.calls.size() == sets and not NetManager._platform.wants_activity(),
		"the bootstrap is never advertised")
	await _teardown(test)


# --- F6: real candidate admission --------------------------------------------------------

func _f6_host_admits_only_the_proven_arrivals(test: Node) -> void:
	print("CASE: F6-H the arranged host greets and admits only proven arrivals; admission alone chooses nothing until every present player is ready")
	await _setup(test, "f6-host")
	var flow := await _host_cohort(test, ["f6-b", "f6-c", "f6-d"])
	if flow == null:
		await _teardown(test)
		return
	var peer: Variant = party.fake_arranged_peer
	var sent: int = peer.sent.size()
	party.fake_proof_pending[3] = true
	_connect_member(3, "f6-c")
	test._check(NetManager._arranged_candidates.has(3), "a candidate whose membership has not replicated waits")
	test._check(peer.sent.size() == sent, "and is sent nothing: %d packets" % (peer.sent.size() - sent))
	_connect_member(2, "f6-b")
	test._check(not NetManager._arranged_candidates.has(2) and peer.sent.size() > sent, "a proven arrival is greeted")
	_identify(2, "f6-b")
	test._check(NetManager.players.has(2) and NetManager.players.size() == 2, "its identity puts it on the roster")
	test._check(_commit_not_started(flow) and NetManager.is_accepting_joins(),
		"two admitted while two more present players are not ready start nothing (phase %d)" % flow.phase)
	party.fake_proof_pending.erase(3)
	NetManager._on_context_changed(party.fake_arranged)
	test._check(not NetManager._arranged_candidates.has(3), "once its membership replicates the waiting candidate is greeted")
	_identify(3, "f6-c")
	test._check(_commit_not_started(flow), "three admitted with a fourth present player not ready still wait")
	_connect_member(4, "f6-d")
	_identify(4, "f6-d")
	test._check(_commit_not_started(flow) and NetManager._commit_alarm == null,
		"every present player admitted, yet with their old groups unconfirmed nobody is chosen and no commit budget runs")
	var chosen_at := clock.now_msec()
	_report_retired(flow, ["f6-b", "f6-c", "f6-d"])
	test._check(not NetManager.is_accepting_joins(), "once every present player's retirement is in, admission closes")
	test._check(NetManager.everyone_ready() and flow.selected_keys.size() == 4, "the four present players were chosen and readied once, by the host")
	var commit_budget: int = NetManager._commit_alarm.deadline_msec - chosen_at if NetManager._commit_alarm != null else -1
	test._check(commit_budget == 30000, "the choice starts the commit's own 30-second budget: %d ms" % commit_budget)
	test._check(party.fake_calls.has("lock:true"), "the commit locked the lobby")
	test._check(NetManager.match_state == NRTypes.MatchState.STARTING,
		"and the match started through the ordinary STARTING path: state %d" % NetManager.match_state)
	await _teardown(test)


## An arranged peer the host cannot prove -- not a member of the arranged lobby, or a second
## peer for a player already admitted -- is never greeted, admitted to nothing and sent
## nothing, not even what the host shares with its players, and it cannot end the match for
## everyone: the proven present players still start, hearing everything as usual. Once it is
## turned away it stops being one of the host's peers; the admitted player it duplicates, and
## the host itself, never do. (A present member on another protocol is a player, and fails the
## start: see Q1.)
func _f6_host_never_greets_unproven_peers(test: Node) -> void:
	print("CASE: F6-H an outsider or a duplicate peer is never greeted, hears nothing shared, is dropped once refused, and never ends the first match")
	for scenario: String in ["outsider", "duplicate"]:
		await _setup(test, "f6-refuse-" + scenario)
		var flow := await _host_cohort(test, ["r-b", "r-c"])
		if flow == null:
			await _teardown(test)
			continue
		var peer: Variant = party.fake_arranged_peer
		_admit_cohort(["r-b"])
		var heard_before := _calls_to(peer, 2)
		match scenario:
			"outsider":
				_connect_member(6, "r-outsider")
				test._check(_calls_to(peer, 6) == 0 and NetManager._arranged_candidates.has(6),
					"[outsider] a peer the open lobby does not list yet waits, sent nothing")
			"duplicate":
				_connect_member(6, "r-b")
				test._check(_calls_to(peer, 6) == 0 and not NetManager._arranged_candidates.has(6),
					"[duplicate] a second peer for an admitted player is turned away, sent nothing")
		_start_with(flow, ["r-c"], 3)
		_report_retired(flow, ["r-b"])
		test._check(flow.is_current() and NetManager.match_state == NRTypes.MatchState.STARTING and flow.selected_keys.size() == 3,
			"[%s] the three proven present players start: %d chosen" % [scenario, flow.selected_keys.size()])
		NetManager._on_context_changed(party.fake_arranged)
		test._check(not NetManager._arranged_candidates.has(6) and not NetManager.players.has(6) and _calls_to(peer, 6) == 0,
			"[%s] the unproven peer never reached the roster and was never greeted: %d calls reached it" % [scenario, _calls_to(peer, 6)])
		test._check(_calls_to(peer, 2) > heard_before,
			"[%s] while the admitted players heard the admissions, readiness and start: %d calls" % [scenario, _calls_to(peer, 2) - heard_before])
		await test.get_tree().process_frame
		test._check(peer.disconnected == [6] and NetManager.players.has(2) and flow.is_current()
			and flow.selected_keys.size() == 3,
			"[%s] once refused it is dropped from the host's peers -- only it: %s" % [scenario, str(peer.disconnected)])
		await _teardown(test)


func _f6_guest_answers_only_the_pinned_host(test: Node) -> void:
	print("CASE: F6-G an arranged guest sends its identity only to a proven current arranged owner; pending facts wait silently, known disagreement ends the attempt")
	var proven_now := ["pinned"]
	var refused_now := ["other_peer", "protocol", "invalid_kept_key", "disconnected", "owner_changed", "owner_cleared", "other_match"]
	var pending_first := ["pending_owner", "no_protocol", "empty_protocol", "malformed"]
	for scenario: String in proven_now + refused_now + pending_first:
		await _setup(test, "f6-guest-" + scenario)
		var flow := _staging_guest(test, 7)
		_arm(flow, false)
		var arranged_peer: Variant = TransportPeer.new(9)
		party.fake_arranged_peer = arranged_peer
		flow.switch_transport()
		var request: JoinRequest = NetManager._active_join_request
		test._check(request != null and request.is_pending() and not request.admitted,
			"[%s] attaching the transport answers nothing" % scenario)
		if request == null:
			await _teardown(test)
			continue
		arranged_peer.connect_remote(NetManager.HOST_PEER_ID)
		test._check(request.is_pending(), "[%s] nor does reaching the host" % scenario)
		var owner_key := _key(ARRANGED_OWNER_ID)
		party.fake_peer_keys[NetManager.HOST_PEER_ID] = owner_key.duplicate()
		match scenario:
			"other_peer":
				party.fake_peer_keys[NetManager.HOST_PEER_ID] = _key("other-peer")
			"protocol":
				party.fake_set_member(party.fake_arranged, owner_key, true, _arranged_props(flow.match_id, true, "1.3"))
			"invalid_kept_key":
				party.fake_proof_override[NetManager.HOST_PEER_ID] = {"valid": false, "reason_code": "native_member_missing"}
			"disconnected":
				party.fake_set_member(party.fake_arranged, owner_key, false, _arranged_props(flow.match_id))
			"owner_changed":
				party.fake_owners[party.fake_arranged.context_id] = _key("other-owner")
			"owner_cleared":
				party.fake_owners[party.fake_arranged.context_id] = {}
			"other_match":
				party.fake_set_member(party.fake_arranged, owner_key, true, _arranged_props("another-match"))
			"pending_owner":
				party.fake_proof_pending[NetManager.HOST_PEER_ID] = true
			"no_protocol":
				party.fake_set_member(party.fake_arranged, owner_key, true, {PartyService.MATCH_ID_MEMBER_KEY: flow.match_id})
			"empty_protocol":
				var empty := _arranged_props(flow.match_id)
				empty[MatchmakingService.PROTOCOL_MEMBER_KEY] = ""
				party.fake_set_member(party.fake_arranged, owner_key, true, empty)
			"malformed":
				party.fake_proof_override[NetManager.HOST_PEER_ID] = {"valid": false, "pending": true, "reason_code": "owner_properties_malformed"}
		var sent: int = arranged_peer.sent.size()
		var calls := _rpc_calls(arranged_peer)
		NetManager._request_player_identity()
		if scenario in proven_now:
			test._check(_rpc_calls(arranged_peer) == calls + 1 and flow.is_current(),
				"[%s] the proven owner is answered with exactly one identity call: %d calls" % [scenario, _rpc_calls(arranged_peer) - calls])
			NetManager._on_context_changed(party.fake_arranged)
			NetManager._on_connected_to_server()
			test._check(_rpc_calls(arranged_peer) == calls + 1,
				"[%s] a later lobby update or transport event sends it no second time: %d calls" % [scenario, _rpc_calls(arranged_peer) - calls])
			NetManager._accept_join()
			clock.advance(MatchmakingFlow.POLL_SECONDS)
			test._check(request.succeeded(), "[%s] and only the owner's acceptance admits" % scenario)
		elif scenario in refused_now:
			test._check(arranged_peer.sent.size() == sent, "[%s] nothing is sent: %d packets" % [scenario, arranged_peer.sent.size() - sent])
			test._check(flow.retired and request.outcome != JoinRequest.Outcome.SUCCEEDED,
				"[%s] and the attempt ends: %s" % [scenario, NetManager.last_disconnect_reason])
		else:
			test._check(arranged_peer.sent.size() == sent and flow.is_current() and request.is_pending(),
				"[%s] facts not settled yet send nothing and keep waiting: %d packets" % [scenario, arranged_peer.sent.size() - sent])
			match scenario:
				"pending_owner":
					party.fake_proof_pending.erase(NetManager.HOST_PEER_ID)
					NetManager._on_context_changed(party.fake_arranged)
					test._check(_rpc_calls(arranged_peer) == calls + 1,
						"[%s] the lobby update settles the proof and sends the identity once, with no second request: %d calls" % [scenario, _rpc_calls(arranged_peer) - calls])
					NetManager._on_context_changed(party.fake_arranged)
					NetManager._on_connected_to_server()
					test._check(_rpc_calls(arranged_peer) == calls + 1,
						"[%s] and a later settle sends nothing more: %d calls" % [scenario, _rpc_calls(arranged_peer) - calls])
					NetManager._accept_join()
					clock.advance(MatchmakingFlow.POLL_SECONDS)
					test._check(request.succeeded(), "[%s] and the ordinary admission completes" % scenario)
				"malformed":
					party.fake_proof_override.erase(NetManager.HOST_PEER_ID)
					party.fake_set_member(party.fake_arranged, owner_key, false, _arranged_props(flow.match_id))
					NetManager._on_context_changed(party.fake_arranged)
					test._check(arranged_peer.sent.size() == sent and flow.retired,
						"[%s] turning invalid ends the attempt without sending: %s" % [scenario, NetManager.last_disconnect_reason])
				_:
					clock.advance(MatchmakingFlow.HANDOFF_SECONDS)
					test._check(arranged_peer.sent.size() == sent and flow.retired and not request.succeeded(),
						"[%s] a wait that never settles expires without sending: %s" % [scenario, NetManager.last_disconnect_reason])
		await _teardown(test)


# --- F7: the first start runs with exactly the chosen players, through MatchDirector ------

func _f7_first_start_needs_the_chosen_players_through_running(test: Node) -> void:
	print("CASE: F7/B-START the first match loads and counts down only with the chosen players; one lost cancels it rather than starting with fewer; RUNNING ends the rule")
	for scenario: String in ["complete", "loading", "countdown", "disconnect"]:
		await _setup(test, "f7-" + scenario)
		var flow := await _host_cohort(test, ["s-b", "s-c"])
		if flow == null:
			await _teardown(test)
			continue
		_start_with(flow, ["s-b", "s-c"])
		test._check(NetManager.match_state == NRTypes.MatchState.STARTING and NetManager.initial_cohort_pending()
			and flow.selected_keys.size() == 3,
			"[%s] the three present players were chosen and the first match started with the rule armed" % scenario)
		if scenario == "disconnect":
			party.fake_arranged_peer.disconnect_remote(3)
			test._check(flow.retired and NetManager.last_disconnect_reason == MatchmakingFlow.TEXT_MATCH_MEMBER_LOST,
				"[disconnect] a chosen player leaving before the match runs ends it, never a match of two: %s" % NetManager.last_disconnect_reason)
			await _teardown(test)
			continue
		var world := FakeWorld.new()
		var director := MatchDirector.new()
		test.add_child(director)
		director.setup(world, NRTypes.GameModeType.DEATHMATCH)
		director.set_physics_process(false)
		for peer_id: int in NetManager.players:
			(NetManager.players[peer_id] as PlayerState).in_game = true
		match scenario:
			"complete":
				director._handle_players_loading(0.016)
				test._check(world.fake_started == 1 and director.match_state == NRTypes.MatchState.STARTING,
					"[complete] exactly the chosen three, loaded, start the countdown")
				director._on_starting_timeout()
				test._check(director.match_state == NRTypes.MatchState.RUNNING, "[complete] and the match runs")
				test._check(not NetManager.initial_cohort_pending() and NetManager._commit_alarm == null,
					"[complete] RUNNING ends the chosen-players rule and its budget")
				test._check(flow.phase == MatchmakingFlow.Phase.GAMEPLAY, "[complete] the flow is in gameplay (phase %d)" % flow.phase)
			"loading":
				NetManager.players.erase(3)
				director._handle_players_loading(0.016)
				test._check(world.fake_started == 0, "[loading] two loaded players cannot hide the missing third")
				test._check(flow.retired and NetManager.last_disconnect_reason == MatchmakingFlow.TEXT_MATCH_MEMBER_LOST,
					"[loading] the first match is cancelled: %s" % NetManager.last_disconnect_reason)
			"countdown":
				director._handle_players_loading(0.016)
				NetManager.players.erase(3)
				director._on_starting_timeout()
				test._check(director.match_state != NRTypes.MatchState.RUNNING, "[countdown] a player lost in the countdown stops it short of RUNNING")
				test._check(flow.retired and NetManager.last_disconnect_reason == MatchmakingFlow.TEXT_MATCH_MEMBER_LOST,
					"[countdown] and cancels the match: %s" % NetManager.last_disconnect_reason)
		director.free()
		world.free()
		await _teardown(test)


## The first start's guard re-reads Party's authenticated identity and the native lobby at
## every edge. Here only native member and proof data change -- all four Party peers, their
## cached admissions, the roster and the loaded flags stay intact, and no lobby event is
## delivered -- and each change still stops the match, at loading and at the final countdown.
func _f7_first_start_rereads_native_identity(test: Node) -> void:
	print("CASE: F7 the first start's guard re-reads native membership and authenticated identity at loading and at the countdown")
	var mutations := ["removed", "disconnected", "owner_changed", "owner_cleared", "remapped", "protocol", "match"]
	for point: String in ["loading", "countdown"]:
		for mutation: String in mutations:
			var label := "%s-%s" % [point, mutation]
			await _setup(test, "f7-native-" + label)
			var flow := await _host_cohort(test, ["n-b", "n-c", "n-d"])
			if flow == null:
				await _teardown(test)
				continue
			_start_with(flow, ["n-b", "n-c", "n-d"])
			test._check(NetManager.match_state == NRTypes.MatchState.STARTING and NetManager.initial_cohort_intact(),
				"[%s] the first match was committed with its chosen players proven" % label)
			var world := FakeWorld.new()
			var director := MatchDirector.new()
			test.add_child(director)
			director.setup(world, NRTypes.GameModeType.DEATHMATCH)
			director.set_physics_process(false)
			for peer_id: int in NetManager.players:
				(NetManager.players[peer_id] as PlayerState).in_game = true
			if point == "countdown":
				director._handle_players_loading(0.016)
				test._check(world.fake_started == 1, "[%s] the countdown began with the chosen players intact" % label)
			_mutate_native_cohort(flow, mutation)
			test._check(NetManager.players.size() == 4 and not NetManager.initial_cohort_intact(),
				"[%s] with the roster untouched (%d players) the guard alone sees the change" % [label, NetManager.players.size()])
			if point == "loading":
				director._handle_players_loading(0.016)
				test._check(world.fake_started == 0, "[%s] the world is never started" % label)
			else:
				director._on_starting_timeout()
				test._check(director.match_state != NRTypes.MatchState.RUNNING, "[%s] the countdown never reaches RUNNING" % label)
			test._check(flow.retired and NetManager.last_disconnect_reason == MatchmakingFlow.TEXT_MATCH_MEMBER_LOST,
				"[%s] the first match is cancelled: %s" % [label, NetManager.last_disconnect_reason])
			director.free()
			world.free()
			await _teardown(test)


## Changes only what Party and the native lobby say about one chosen player or the owner --
## never the transport peers, the cached admissions, the roster or the loaded flags -- and
## delivers no lobby event.
func _mutate_native_cohort(flow: MatchmakingFlow, mutation: String) -> void:
	var member := _key("n-d")
	match mutation:
		"removed":
			party.fake_remove_member(party.fake_arranged, member)
		"disconnected":
			party.fake_set_member(party.fake_arranged, member, false, _arranged_props(flow.match_id, true, "", true))
		"owner_changed":
			party.fake_owners[party.fake_arranged.context_id] = _key("other-owner")
		"owner_cleared":
			party.fake_owners[party.fake_arranged.context_id] = {}
		"remapped":
			party.fake_peer_keys[4] = _key("n-c")
		"protocol":
			party.fake_set_member(party.fake_arranged, member, true, _arranged_props(flow.match_id, true, "1.3", true))
		"match":
			party.fake_set_member(party.fake_arranged, member, true, _arranged_props("another-match", true, "", true))


## The first match starts only once every present player's staging retirement is confirmed.
## Admission completes first -- so every member can begin its own cleanup -- and the arranged
## owner then waits for its own confirmed retirement and every present player's marker, inside
## the budgets it already has. The commit budget is taken at the choice, not at admission.
func _f7_first_start_waits_for_every_staging_retirement(test: Node) -> void:
	print("CASE: F7 the first match is chosen only after every present player's staging retirement: 2+2, 3+1, markers, failures, the final lock and both budgets")
	await _setup(test, "f7-retire-2x2")
	var host := await _open_group(test)
	if host != null:
		_add_guest(7, "a-guest")
		NetManager.roster_changed.emit()
		_arm(host, true, ["a-guest", "c-owner", "c-guest"], ["a-guest"])
		party.fake_arranged_peer = TransportPeer.new(NetManager.HOST_PEER_ID)
		host.switch_transport()
		test._check(host.is_current() and not host.staging_retired,
			"[2+2] the arranged owner, also its premade's staging owner, waits for its own staging guest")
		_admit_cohort(["a-guest", "c-owner", "c-guest"])
		test._check(_commit_not_started(host) and NetManager._commit_alarm == null,
			"[2+2] all four admitted, nothing is chosen and no commit budget runs while their retirements are unconfirmed")
		_report_retired(host, ["c-guest"])
		test._check(_commit_not_started(host), "[2+2] one member retired: the other premade's owner is still in its old lobby")
		party.fake_remove_member(party.fake_staging, _key("a-guest"))
		clock.advance(MatchmakingFlow.POLL_SECONDS)
		test._check(host.staging_retired and host.retirement_reported,
			"[2+2] the owner's own guest has gone, so its own retirement is confirmed and reported")
		test._check(_commit_not_started(host), "[2+2] its own cleanup succeeding does not prove the other premade's")
		_report_retired(host, ["a-guest"])
		test._check(_commit_not_started(host), "[2+2] nor do three of four markers")
		var chosen_at := clock.now_msec()
		_report_retired(host, ["c-owner"])
		test._check(party.fake_calls.count("lock:true") == 1 and NetManager.match_state == NRTypes.MatchState.STARTING
			and host.selected_keys.size() == 4,
			"[2+2] the last retirement chooses the four and starts the match exactly once: %d locks, state %d" % [party.fake_calls.count("lock:true"), NetManager.match_state])
		test._check(NetManager.everyone_ready() and not NetManager.is_accepting_joins(),
			"[2+2] only now are the four readied and admission closed")
		var deadline: int = NetManager._commit_alarm.deadline_msec if NetManager._commit_alarm != null else -1
		test._check(deadline == chosen_at + 30000,
			"[2+2] and the commit runs on the one budget taken at the choice: %d" % (deadline - chosen_at))
		_report_retired(host, ["c-owner"])
		test._check(party.fake_calls.count("lock:true") == 1, "[2+2] a later lobby update commits nothing twice")
	await _teardown(test)

	await _setup(test, "f7-retire-3x1")
	var guest_owner := _staging_guest(test, 7)
	_arm(guest_owner, true, ["staging-owner", "solo-e", "solo-f"], ["staging-owner"])
	party.fake_arranged_peer = TransportPeer.new(NetManager.HOST_PEER_ID)
	guest_owner.switch_transport()
	# The owner's own peer has no key in this fixture.
	party.fake_peer_keys.erase(NetManager.HOST_PEER_ID)
	test._check(guest_owner.arranged_owner and guest_owner.role == MatchmakingFlow.Role.GUEST
		and guest_owner.staging_retired and guest_owner.retirement_reported,
		"[3+1] an arranged owner that was a staging guest retires its own staging lobby at once")
	_admit_cohort(["staging-owner", "solo-e", "solo-f"])
	_report_retired(guest_owner, ["solo-e", "solo-f"])
	test._check(_commit_not_started(guest_owner),
		"[3+1] its own cleanup done, the start still waits for its premade's staging owner")
	_report_retired(guest_owner, ["staging-owner"])
	test._check(party.fake_calls.count("lock:true") == 1 and NetManager.match_state == NRTypes.MatchState.STARTING,
		"[3+1] and starts once that owner's retirement is in: %d locks" % party.fake_calls.count("lock:true"))
	await _teardown(test)

	await _setup(test, "f7-retire-markers")
	var marked := await _host_cohort(test, ["x-b", "x-c", "x-d"])
	if marked != null:
		_report_retired(marked, ["x-b", "x-c"])
		_report_retired(marked, ["x-d"], "stale-match")
		_admit_cohort(["x-b", "x-c", "x-d"])
		test._check(_commit_not_started(marked), "[markers] a marker for another match does not count")
		var props := _arranged_props(marked.match_id, true, "", true)
		party.fake_set_member(party.fake_arranged, _key("x-d"), true, props)
		party.fake_add_member(party.fake_arranged, _key("x-d"), true, props)
		NetManager._on_context_changed(party.fake_arranged)
		test._check(_commit_not_started(marked) and marked.is_current(),
			"[markers] a member listed twice natively is never a set to start with: it waits")
		party.fake_remove_member(party.fake_arranged, _key("x-d"))
		party.fake_set_member(party.fake_arranged, _key("x-d"), true, props)
		NetManager._on_context_changed(party.fake_arranged)
		test._check(party.fake_calls.count("lock:true") == 1 and NetManager.match_state == NRTypes.MatchState.STARTING,
			"[markers] every present player with a current marker starts once")
	await _teardown(test)

	var twice := await _arranged_guest(test, "f7-retire-premade-twice", ["twice-mate"])
	if twice != null:
		party.fake_add_member(party.fake_arranged, _key("twice-mate"), true, _arranged_props(twice.match_id))
		NetManager._on_context_changed(party.fake_arranged)
		test._check(twice.is_current() and twice.phase == MatchmakingFlow.Phase.ADMITTING_COHORT,
			"[twice] a member of this player's own premade listed twice natively is a lobby still settling: it waits")
		party.fake_remove_member(party.fake_arranged, _key("twice-mate"))
		NetManager._on_context_changed(party.fake_arranged)
		test._check(twice.retired and NetManager.last_disconnect_reason == MatchmakingFlow.TEXT_MATCH_MEMBER_LOST,
			"[twice] and once that member is gone, the loss is final: %s" % NetManager.last_disconnect_reason)
	await _teardown(test)

	await _setup(test, "f7-retire-report-fails")
	var reporting := await _open_group(test)
	if reporting != null:
		_arm(reporting, true, ["r-b", "r-c", "r-d"])
		party.fake_arranged_peer = TransportPeer.new(NetManager.HOST_PEER_ID)
		party.fake_fail_marker_post = true
		await reporting.switch_transport()
		test._check(reporting.retired and NetManager.last_disconnect_reason == "Injected retirement report failure.",
			"[report] a retirement the arranged lobby never heard about fails the handoff: %s" % NetManager.last_disconnect_reason)
		test._check(reporting.staging_retired and not reporting.retirement_reported
			and NetManager.match_state != NRTypes.MatchState.STARTING, "[report] and nothing starts")
	await _teardown(test)

	await _setup(test, "f7-retire-lock-loss")
	var locking := await _host_cohort(test, ["k-b", "k-c", "k-d"])
	if locking != null:
		_report_retired(locking, ["k-b", "k-c", "k-d"])
		party.fake_block_lock = true
		_admit_cohort(["k-b", "k-c", "k-d"])
		test._check(locking.phase == MatchmakingFlow.Phase.COMMITTING_START and party.fake_calls.has("lock:true"),
			"[lock] with every prerequisite true the start asks for the lock (phase %d)" % locking.phase)
		party.fake_remove_member(party.fake_arranged, _key("k-d"))
		party.fake_block_lock = false
		party.fake_lock_released.emit()
		test._check(locking.retired and NetManager.match_state != NRTypes.MatchState.STARTING,
			"[lock] a native loss during the final lock stops the start: %s" % NetManager.last_disconnect_reason)
	await _teardown(test)

	await _setup(test, "f7-retire-arrivals")
	var waiting := await _host_cohort(test, ["w-b", "w-c", "w-d"])
	if waiting != null:
		_admit_cohort(["w-b", "w-c", "w-d"])
		var remaining := float(waiting.phase_deadline_msec - clock.now_msec()) / 1000.0
		clock.advance(remaining - 0.1)
		test._check(_commit_not_started(waiting) and waiting.is_current() and NetManager._commit_alarm == null,
			"[arrivals] waiting on markers chooses nothing, even near the handoff budget's end")
		clock.advance(0.1)
		test._check(waiting.retired and NetManager.last_disconnect_reason == MatchmakingFlow.TEXT_MATCH_LATE,
			"[arrivals] the handoff budget ends the wait for players to be ready: %s" % NetManager.last_disconnect_reason)
	await _teardown(test)

	await _setup(test, "f7-retire-commit-budget")
	var committing := await _host_cohort(test, ["t-b"])
	if committing != null:
		party.fake_block_lock = true
		_start_with(committing, ["t-b"])
		test._check(committing.phase == MatchmakingFlow.Phase.COMMITTING_START and committing.selected_keys.size() == 2,
			"[commit] the two are chosen and the start waits on its lock (phase %d)" % committing.phase)
		clock.advance(MatchmakingFlow.COMMIT_SECONDS - 0.1)
		test._check(committing.is_current() and NetManager.match_state != NRTypes.MatchState.STARTING,
			"[commit] still waiting just short of the commit budget")
		clock.advance(0.1)
		test._check(committing.retired and NetManager.last_disconnect_reason == NetManager._COMMIT_TIMEOUT,
			"[commit] the one budget taken at the choice ends it, never renewed: %s" % NetManager.last_disconnect_reason)
	await _teardown(test)


## Whether the first match's start has not begun: nobody chosen or readied, no start lock, no
## start, the flow still admitting arrivals.
func _commit_not_started(flow: MatchmakingFlow) -> bool:
	return flow.is_current() and flow.phase == MatchmakingFlow.Phase.ADMITTING_COHORT \
		and flow.selected_keys.is_empty() and not NetManager.everyone_ready() \
		and not party.fake_calls.has("lock:true") and NetManager.match_state != NRTypes.MatchState.STARTING


# --- B-PRESENT: the players who have arrived start --------------------------------------

## The arranged host starts with the members present in the arranged lobby the moment they are
## two to four and every one is connected, admitted and done with its old group: two start
## without waiting for a third, and three and four the same way. The choice, the lock, the
## published choice and the start all happen at the moment the last present player became
## ready -- no count, settle timer or fourth arrival is waited for -- and only the one commit
## budget taken at the choice runs on.
func _b_present_two_three_or_four_start_as_soon_as_ready(test: Node) -> void:
	print("CASE: B-PRESENT two, three or four present and ready players start at once, with no wait for more and no settle timer")
	for size: int in [2, 3, 4]:
		await _setup(test, "present-%d" % size)
		var others: Array = []
		for index in size - 1:
			others.append("present-%d-%d" % [size, index])
		var flow := await _host_cohort(test, others)
		if flow == null:
			await _teardown(test)
			continue
		_report_retired(flow, others)
		_admit_cohort(others.slice(0, others.size() - 1))
		var lobby: Variant = load("res://scripts/ui/screens/lobby_screen.gd").new()
		var arriving: String = lobby._players_line()
		test._check(_commit_not_started(flow) and arriving == "Players %d/4" % (size - 1),
			"[%d] one present player not yet admitted holds the start; the lobby counts the arrivals: %s" % [size, arriving])
		var ready_at := clock.now_msec()
		_admit_cohort([others.back()], 2 + others.size() - 1)
		test._check(NetManager.match_state == NRTypes.MatchState.STARTING and clock.now_msec() == ready_at,
			"[%d] the last present player's admission starts the match at that moment" % size)
		test._check(flow.selected_keys.size() == size and int(flow.presentation().get("selected_count", 0)) == size,
			"[%d] with exactly the %d present players chosen" % [size, size])
		var starting: String = lobby._players_line()
		lobby.free()
		test._check(starting == "Starting with %d players" % size, "[%d] and the lobby says so: %s" % [size, starting])
		var lock_at := party.fake_calls.find("lock:true")
		var control_at := party.fake_calls.find("post:%s" % PartyService.ARRANGED_PHASE_STARTING)
		test._check(lock_at >= 0 and control_at > lock_at and party.fake_calls.count("lock:true") == 1,
			"[%d] the lobby is locked once, and the choice published after the lock (lock %d, publish %d)" % [size, lock_at, control_at])
		var control := PartyService.decode_arranged_control(party.fake_lobby_properties.get(party.fake_arranged.context_id, {}))
		test._check(String(control.get("phase", "")) == PartyService.ARRANGED_PHASE_STARTING
			and int(control.get("start_generation", 0)) == 1 and int(control.get("selected_count", 0)) == size
			and MatchmakingFlow.selection_includes(control.get("selected_members", []), flow.selected_keys),
			"[%d] the published choice is this start's generation and set: %s" % [size, str(control)])
		test._check(NetManager._cohort_alarm == null and NetManager._commit_alarm != null
			and NetManager._commit_alarm.deadline_msec == ready_at + 30000,
			"[%d] no arrival timer is left running, and the one commit budget started at the choice" % size)
		test._check(NetManager.everyone_ready() and not NetManager.is_accepting_joins(),
			"[%d] the chosen players were readied once and admission closed" % size)
		await _teardown(test)


## A present member not yet ready blocks the choice: still connecting natively, on the network
## but not yet admitted, admitted but its old group not yet retired, or its proof still
## settling. It is never left out to make the count pass -- once ready, the start includes it.
## A member that leaves before the choice, from the lobby or from the network, only shrinks who
## is present: the others start without it, and nothing fails.
func _b_present_member_not_ready_blocks_the_choice(test: Node) -> void:
	print("CASE: B-PRESENT a present member still connecting, unadmitted, unretired or unproven blocks the start and is never skipped; one that leaves only shrinks the set")
	for scenario: String in ["connecting", "unadmitted", "unretired", "unproven", "leaves", "admitted_leaves"]:
		await _setup(test, "blocked-" + scenario)
		var flow := await _host_cohort(test, ["blk-b", "blk-c"])
		if flow == null:
			await _teardown(test)
			continue
		_start_with(flow, ["blk-b"])
		match scenario:
			"connecting":
				party.fake_set_member(party.fake_arranged, _key("blk-c"), false, _arranged_props(flow.match_id, true, "", true))
				NetManager._on_context_changed(party.fake_arranged)
			"unadmitted":
				_report_retired(flow, ["blk-c"])
				_connect_member(3, "blk-c")
			"unretired", "admitted_leaves":
				_admit_cohort(["blk-c"], 3)
			"unproven":
				_report_retired(flow, ["blk-c"])
				party.fake_proof_pending[3] = true
				_connect_member(3, "blk-c")
			"leaves":
				_report_retired(flow, ["blk-c"])
		test._check(_commit_not_started(flow), "[%s] a present member not yet ready holds the start: nobody is chosen" % scenario)
		clock.advance(30.0)
		test._check(_commit_not_started(flow), "[%s] and waiting changes nothing" % scenario)
		match scenario:
			"connecting":
				party.fake_set_member(party.fake_arranged, _key("blk-c"), true, _arranged_props(flow.match_id, true, "", true))
				_admit_cohort(["blk-c"], 3)
			"unadmitted":
				_identify(3, "blk-c")
			"unretired":
				_report_retired(flow, ["blk-c"])
			"unproven":
				party.fake_proof_pending.erase(3)
				NetManager._on_context_changed(party.fake_arranged)
				_identify(3, "blk-c")
			"leaves":
				party.fake_remove_member(party.fake_arranged, _key("blk-c"))
				NetManager._on_context_changed(party.fake_arranged)
			"admitted_leaves":
				party.fake_arranged_peer.disconnect_remote(3)
				test._check(flow.is_current() and NetManager.players.size() == 2 and _commit_not_started(flow),
					"[admitted_leaves] an admitted arrival outside this host's premade leaving fails nothing; while the lobby still lists it, nobody is chosen")
				party.fake_remove_member(party.fake_arranged, _key("blk-c"))
				NetManager._on_context_changed(party.fake_arranged)
		var expected := 2 if scenario in ["leaves", "admitted_leaves"] else 3
		test._check(NetManager.match_state == NRTypes.MatchState.STARTING and flow.selected_keys.size() == expected,
			"[%s] once it is ready -- or gone -- the start goes ahead with %d, never without a present player: %d chosen" % [scenario, expected, flow.selected_keys.size()])
		await _teardown(test)


# --- Q1 / Q2: who may start the first match ------------------------------------------

## A present member on another protocol or another match -- or a room of another size -- fails
## the first start at once: the compatible players present are never started without it.
func _q1_an_incompatible_present_member_fails_the_start(test: Node) -> void:
	print("CASE: Q1 a present member on another protocol or match, or a room of another size, fails the first start at once; no compatible subset starts")
	for scenario: String in ["protocol", "match", "capacity"]:
		await _setup(test, "q1-" + scenario)
		var flow := await _host_cohort(test, ["q1-b"])
		if flow == null:
			await _teardown(test)
			continue
		_admit_cohort(["q1-b"])
		var peer: Variant = party.fake_arranged_peer
		match scenario:
			"protocol":
				party.fake_set_member(party.fake_arranged, _key("q1-c"), true, _arranged_props(flow.match_id, true, "1.3", true))
				_connect_member(6, "q1-c")
				test._check(_calls_to(peer, 6) == 0 and not NetManager.players.has(6),
					"[protocol] its peer is sent nothing and admitted to nothing")
			"match":
				party.fake_set_member(party.fake_arranged, _key("q1-c"), true, _arranged_props("another-match", true, "", true))
			"capacity":
				party.fake_max_members = 5
		_report_retired(flow, ["q1-b"])
		test._check(flow.retired and NetManager.last_disconnect_reason == MatchmakingFlow.TEXT_MATCH_INCOMPATIBLE,
			"[%s] the first start fails at once: %s" % [scenario, NetManager.last_disconnect_reason])
		test._check(not party.fake_calls.has("lock:true") and NetManager.match_state != NRTypes.MatchState.STARTING,
			"[%s] and the host with its compatible, ready arrival is never started without it" % scenario)
		await _teardown(test)


## One premade of two or three that arrives on its own may start alone after Matched: no other
## group's player need be present. Its owner here is also the group's staging owner, whose old
## lobby is left last.
func _q2_an_arrived_premade_may_start_alone(test: Node) -> void:
	print("CASE: Q2 a premade of two or of three that arrives alone starts alone; no outside player is required")
	for size: int in [2, 3]:
		await _setup(test, "q2-%d" % size)
		var flow := await _open_group(test)
		if flow == null:
			await _teardown(test)
			continue
		var premade: Array = []
		for index in size - 1:
			var entity := "q2-%d-%d" % [size, index]
			premade.append(entity)
			_add_guest(7 + index, entity)
		NetManager.roster_changed.emit()
		_arm(flow, true, premade, premade)
		party.fake_arranged_peer = TransportPeer.new(NetManager.HOST_PEER_ID)
		flow.switch_transport()
		for entity: String in premade:
			party.fake_remove_member(party.fake_staging, _key(entity))
		clock.advance(MatchmakingFlow.POLL_SECONDS)
		test._check(flow.staging_retired and flow.retirement_reported,
			"[%d] its staging guests gone, the owner retires its old group last" % size)
		_start_with(flow, premade)
		test._check(NetManager.match_state == NRTypes.MatchState.STARTING and flow.selected_keys.size() == size
			and MatchmakingFlow.selection_includes(flow.selected_keys, flow.frozen_keys),
			"[%d] the premade alone is chosen and starts: %d players" % [size, flow.selected_keys.size()])
		await _teardown(test)


# --- B-ORDER: the start is one checked step on a fixed choice -----------------------------

## The choice is fixed before the lock is asked for. A chosen player lost, the owner changed,
## the lock refused or not confirmed, or the choice not published, each fails the start -- and
## it is never recalculated into a smaller set or given a new budget. A member outside the
## choice that slipped into the lobby before the lock is simply late: it is refused, and the
## start goes ahead with the choice unchanged.
func _b_order_a_change_during_the_start_fails_it_unrecomputed(test: Node) -> void:
	print("CASE: B-ORDER a chosen player lost, an owner change, a refused or unconfirmed lock or a failed publication fails the start without recomputing; a late member is only refused")
	var reasons := {
		"member_lost": MatchmakingFlow.TEXT_MATCH_MEMBER_LOST,
		"owner_changed": MatchmakingFlow.TEXT_MATCH_HOST_CHANGED,
		"lock_refused": "Injected lock failure.",
		"lock_unconfirmed": MatchmakingFlow.TEXT_MATCH_UNSEALED,
		"publish_failed": "Injected start publication failure.",
	}
	for scenario: String in reasons.keys() + ["late_member"]:
		await _setup(test, "seal-" + scenario.replace("_", "-"))
		var flow := await _host_cohort(test, ["seal-b", "seal-c"])
		if flow == null:
			await _teardown(test)
			continue
		_report_retired(flow, ["seal-b", "seal-c"])
		match scenario:
			"lock_refused":
				party.fake_fail_lock = true
			"lock_unconfirmed":
				party.fake_lock_unconfirmed = true
			"publish_failed":
				party.fake_fail_start_control = true
			_:
				party.fake_block_lock = true
		_admit_cohort(["seal-b", "seal-c"])
		test._check(party.fake_calls.count("lock:true") == 1 and flow.selected_keys.size() == 3,
			"[%s] the three ready players are chosen before the lock is asked for" % scenario)
		match scenario:
			"member_lost":
				party.fake_remove_member(party.fake_arranged, _key("seal-c"))
			"owner_changed":
				party.fake_owners[party.fake_arranged.context_id] = _key("other-owner")
			"late_member":
				party.fake_set_member(party.fake_arranged, _key("seal-late"), true, _arranged_props(flow.match_id, true, "", true))
		if party.fake_block_lock:
			party.fake_block_lock = false
			party.fake_lock_released.emit()
		if scenario == "late_member":
			test._check(NetManager.match_state == NRTypes.MatchState.STARTING and flow.selected_keys.size() == 3,
				"[late_member] a member outside the choice changes nothing: the three start")
			var peer: Variant = party.fake_arranged_peer
			_connect_member(6, "seal-late")
			test._check(_calls_to(peer, 6) == 1 and not NetManager.players.has(6),
				"[late_member] reaching the network it is refused once and never admitted: %d calls" % _calls_to(peer, 6))
		else:
			test._check(flow.retired and NetManager.last_disconnect_reason == String(reasons[scenario]),
				"[%s] the start fails with its reason: %s" % [scenario, NetManager.last_disconnect_reason])
			test._check(party.fake_calls.count("lock:true") == 1 and NetManager.match_state != NRTypes.MatchState.STARTING
				and not party.fake_calls.has("post:%s" % PartyService.ARRANGED_PHASE_STARTING),
				"[%s] nothing was recomputed, locked again, published or started" % scenario)
		await _teardown(test)


# --- B-LATE: arrivals after the choice ----------------------------------------------------

## Two players start while further matched players are still on their way. One arriving after
## the choice is told the match has already started and gets nothing else -- no greeting, no
## roster and no place in it -- while the two carry on. On the late player's own side, the
## published choice without it ends its attempt before it reaches the fresh network, and so
## does a session already past its first round. A join that failed before any lobby could be
## read says the cause is unknown.
func _b_late_arrivals_are_turned_away_and_told_why(test: Node) -> void:
	print("CASE: B-LATE two start while others are delayed; a late arrival is refused with no roster or admission; the late side reads the cutoff, a later round or an unknown cause")
	await _setup(test, "late-host")
	var flow := await _host_cohort(test, ["late-b"])
	if flow != null:
		_start_with(flow, ["late-b"])
		test._check(NetManager.match_state == NRTypes.MatchState.STARTING and flow.selected_keys.size() == 2,
			"two present and ready players start while the rest of the match is still on its way")
		party.fake_set_member(party.fake_arranged, _key("late-c"), true, _arranged_props(flow.match_id))
		NetManager._on_context_changed(party.fake_arranged)
		test._check(flow.is_current() and flow.selected_keys.size() == 2,
			"a matched player appearing in the lobby after the choice changes nothing")
		var peer: Variant = party.fake_arranged_peer
		_connect_member(5, "late-c")
		test._check(_calls_to(peer, 5) == 1 and not NetManager.players.has(5) and not NetManager._arranged_candidates.has(5),
			"reaching the network, it is sent one refusal and nothing else: %d calls" % _calls_to(peer, 5))
		_identify(5, "late-c")
		test._check(not NetManager.players.has(5) and NetManager.players.size() == 2 and flow.is_current()
			and NetManager.match_state == NRTypes.MatchState.STARTING,
			"an identity it sends anyway admits nothing, and the two carry on")
	await _teardown(test)

	for scenario: String in ["cutoff", "later_round"]:
		await _setup(test, "late-guest-" + scenario.replace("_", "-"))
		var guest := _staging_guest(test, 7)
		_arm(guest, false)
		if scenario == "cutoff":
			var others: Array[Dictionary] = [_key(ARRANGED_OWNER_ID), _key("late-other")]
			_publish_start(guest, others)
		else:
			party.fake_lobby_properties[party.fake_arranged.context_id] = _arranged_control(
				guest.match_id, 1, PartyService.ARRANGED_PHASE_REMATCH)
		party.fake_calls.clear()
		await guest._arm_handoff()
		test._check(guest.retired and NetManager.last_disconnect_reason == MatchmakingFlow.TEXT_MATCH_ALREADY_STARTED,
			"[%s] the late player is told the match is already under way: %s" % [scenario, NetManager.last_disconnect_reason])
		test._check(not party.fake_calls.has("join_transport") and not party.fake_calls.has("prepare"),
			"[%s] it never reaches the fresh network" % scenario)
		await _teardown(test)

	for code: StringName in [&"arranged_join_failed", &"arranged_join_timeout", &"arranged_join_unavailable"]:
		await _setup(test, "late-unknown-" + String(code).replace("_", "-"))
		var searching := await _searching_owner(test)
		if searching == null:
			await _teardown(test)
			continue
		party.fake_arranged_join_code = code
		_match("match-unknown")
		var expected := "Injected arranged join failure." if code == &"arranged_join_unavailable" else MatchmakingFlow.TEXT_MATCH_JOIN_UNPROVEN
		test._check(searching.retired and NetManager.last_disconnect_reason == expected,
			"[%s] a join that failed before any lobby was read gives %s: %s" % [code,
				"its own reason" if code == &"arranged_join_unavailable" else "the unknown cause", NetManager.last_disconnect_reason])
		await _teardown(test)


# --- Q3 / B-START: a guest follows the owner's published choice ----------------------------

## A matchmade guest's first start follows only the owner's published choice, and only when it
## names this player and its whole premade. A start that arrives before the choice has
## replicated is held -- anything after it queued behind it -- until the choice lands; its
## expiry is fixed at that first receipt, at the earlier of the handoff deadline and the
## receipt plus 30 seconds, and nothing received later renews it. A choice without this player
## is the cutoff; one without its premade is a mismatch. Either way nothing is applied.
func _q3_guest_start_follows_the_published_choice(test: Node) -> void:
	print("CASE: Q3/B-START a guest follows the first start only once the published choice names it and its premade; a held start expires at the earlier of the handoff deadline and receipt + 30 s, never renewed")
	var scenarios := ["choice_first", "start_first", "excluded", "premade_excluded", "handoff_first", "commit_first", "no_renewal", "just_in_time"]
	for scenario: String in scenarios:
		var premade: Array = ["q3-mate"] if scenario == "premade_excluded" else []
		var flow := await _arranged_guest(test, "q3-" + scenario.replace("_", "-"), premade)
		if flow == null:
			await _teardown(test)
			continue
		var states: Array[int] = []
		var failures: Array[String] = []
		var record_state := func(state: int) -> void: states.append(state)
		var record_failure := func() -> void: failures.append(NetManager.last_disconnect_reason)
		NetManager.match_state_changed.connect(record_state)
		NetManager.server_disconnected.connect(record_failure)
		var named: Array[Dictionary] = [_key(ARRANGED_OWNER_ID), party.fake_local_key.duplicate()]
		var starting := int(NRTypes.MatchState.STARTING)
		match scenario:
			"choice_first":
				_publish_start(flow, named)
				NetManager._on_context_changed(party.fake_arranged)
				NetManager._receive_match_state(NRTypes.MatchState.STARTING)
				test._check(states == [starting] and flow.phase == MatchmakingFlow.Phase.COMMITTING_START
					and flow.selected_keys.size() == 2 and flow.start_generation == 1 and NetManager._pending_start.is_empty(),
					"[choice_first] the choice already naming it, the start is followed at once: %s" % str(states))
			"start_first":
				NetManager._receive_match_state(NRTypes.MatchState.STARTING)
				NetManager._receive_match_state(NRTypes.MatchState.PLAYERS_JOINING)
				NetManager._receive_match_state(NRTypes.MatchState.RUNNING)
				test._check(states.is_empty() and not NetManager._pending_start.is_empty()
					and flow.phase == MatchmakingFlow.Phase.ADMITTING_COHORT,
					"[start_first] a start ahead of its published choice is held, with what follows queued behind it")
				clock.advance(5.0)
				_publish_start(flow, named)
				NetManager._on_context_changed(party.fake_arranged)
				test._check(states == [starting, int(NRTypes.MatchState.PLAYERS_JOINING), int(NRTypes.MatchState.RUNNING)],
					"[start_first] the choice landing releases them once, in the order they arrived: %s" % str(states))
				test._check(flow.phase == MatchmakingFlow.Phase.GAMEPLAY and NetManager._pending_start.is_empty()
					and NetManager._pending_start_alarm == null,
					"[start_first] and the held start's expiry is gone (phase %d)" % flow.phase)
				clock.advance(60.0)
				NetManager._on_context_changed(party.fake_arranged)
				test._check(flow.is_current() and failures.is_empty() and states.size() == 3,
					"[start_first] nothing expires or repeats afterwards")
			"excluded", "premade_excluded":
				var chosen: Array[Dictionary] = named
				if scenario == "excluded":
					chosen = [_key(ARRANGED_OWNER_ID), _key("q3-other")]
				_publish_start(flow, chosen)
				NetManager._receive_match_state(NRTypes.MatchState.STARTING)
				var expected := MatchmakingFlow.TEXT_MATCH_ALREADY_STARTED if scenario == "excluded" else MatchmakingFlow.TEXT_MATCH_MISMATCH
				test._check(flow.retired and failures == [expected] and not states.has(starting),
					"[%s] the start is refused, once, and never applied: %s" % [scenario, str(failures)])
			"handoff_first", "commit_first", "no_renewal":
				if scenario == "handoff_first":
					flow.phase_deadline_msec = clock.deadline_after(10.0)
				var expiry := 10.0 if scenario == "handoff_first" else MatchmakingFlow.COMMIT_SECONDS
				NetManager._receive_match_state(NRTypes.MatchState.STARTING)
				if scenario == "no_renewal":
					clock.advance(20.0)
					NetManager._receive_match_state(NRTypes.MatchState.STARTING)
					clock.advance(5.0)
					NetManager._receive_match_state(NRTypes.MatchState.RUNNING)
					clock.advance(expiry - 25.1)
				else:
					clock.advance(expiry - 0.1)
				test._check(flow.is_current() and failures.is_empty() and not NetManager._pending_start.is_empty(),
					"[%s] the held start still waits just short of its fixed expiry" % scenario)
				clock.advance(0.1)
				test._check(flow.retired and failures == [MatchmakingFlow.TEXT_MATCH_LATE] and not states.has(starting),
					"[%s] at %.0f seconds it ends, once, having applied nothing: %s" % [scenario, expiry, str(failures)])
			"just_in_time":
				NetManager._receive_match_state(NRTypes.MatchState.STARTING)
				clock.advance(MatchmakingFlow.COMMIT_SECONDS - 0.1)
				_publish_start(flow, named)
				NetManager._on_context_changed(party.fake_arranged)
				test._check(states == [starting] and NetManager._pending_start.is_empty(),
					"[just_in_time] a choice landing just before the expiry releases the start once: %s" % str(states))
				clock.advance(10.0)
				test._check(flow.is_current() and failures.is_empty() and states == [starting],
					"[just_in_time] and the expiry never fires afterwards")
		NetManager.match_state_changed.disconnect(record_state)
		NetManager.server_disconnected.disconnect(record_failure)
		await _teardown(test)


# --- The first start and the handoff: admission, complete facts and recipients -------------

## A matchmade guest follows the first start only on the session its own admission completed,
## and only while the host is proven the owner of the lobby it joined. A published choice that
## names this player proves only that it was chosen: a start that arrives before this session's
## admission completes is held -- on its original expiry -- and follows once, in order, when the
## admission is taken; a connection this host never admitted holds it to that expiry and follows
## nothing. A choice that becomes visible in the same lobby update that clears or disconnects the
## owner applies nothing: the owner's loss ends the attempt first.
func _b_start_guest_needs_its_admission_and_a_proven_owner(test: Node) -> void:
	print("CASE: B-START-ADMISSION a guest follows the first start only after its own admission completes and with its host proven; a never-admitted connection and a same-update owner loss apply nothing")
	for scenario: String in ["admitted_later", "never_admitted", "owner_cleared", "owner_disconnected"]:
		await _setup(test, "hold-" + scenario.replace("_", "-"))
		var flow := _staging_guest(test, 7)
		_arm(flow, false)
		var arranged_peer: Variant = TransportPeer.new(9)
		party.fake_arranged_peer = arranged_peer
		flow.switch_transport()
		arranged_peer.connect_remote(NetManager.HOST_PEER_ID)
		if scenario in ["owner_cleared", "owner_disconnected"]:
			NetManager._accept_join()
			clock.advance(MatchmakingFlow.POLL_SECONDS)
		test._check(flow.is_current() and flow.phase == MatchmakingFlow.Phase.ADMITTING_COHORT,
			"[%s] the guest is on the match's network, waiting for the host's start (phase %d)" % [scenario, flow.phase])
		var states: Array[int] = []
		var failures: Array[String] = []
		var record_state := func(state: int) -> void: states.append(state)
		var record_failure := func() -> void: failures.append(NetManager.last_disconnect_reason)
		NetManager.match_state_changed.connect(record_state)
		NetManager.server_disconnected.connect(record_failure)
		var named: Array[Dictionary] = [_key(ARRANGED_OWNER_ID), party.fake_local_key.duplicate()]
		var starting := int(NRTypes.MatchState.STARTING)
		var running := int(NRTypes.MatchState.RUNNING)
		match scenario:
			"admitted_later", "never_admitted":
				_publish_start(flow, named)
				NetManager._on_context_changed(party.fake_arranged)
				NetManager._receive_match_state(NRTypes.MatchState.STARTING)
				NetManager._receive_match_state(NRTypes.MatchState.RUNNING)
				test._check(states.is_empty() and not NetManager._pending_start.is_empty() and flow.selected_keys.is_empty(),
					"[%s] a choice naming this player is not its admission: the start is held and nothing is adopted" % scenario)
				var deadline := int(NetManager._pending_start.get("deadline", 0))
				if scenario == "admitted_later":
					clock.advance(1.0)
					test._check(states.is_empty(), "[admitted_later] the admission poll applies nothing before the admission completes")
					NetManager._accept_join()
					clock.advance(MatchmakingFlow.POLL_SECONDS)
					test._check(states == [starting, running] and flow.phase == MatchmakingFlow.Phase.GAMEPLAY
						and NetManager._pending_start.is_empty() and failures.is_empty(),
						"[admitted_later] once this session's admission completes, the held states follow once, in order: %s" % str(states))
				else:
					test._check(deadline > 0, "[never_admitted] its expiry was fixed at the first receipt")
					clock.advance(float(deadline - clock.now_msec()) / 1000.0 - 0.1)
					NetManager._on_context_changed(party.fake_arranged)
					test._check(states.is_empty() and flow.is_current() and failures.is_empty(),
						"[never_admitted] a connection never admitted follows nothing, however often the lobby moves")
					clock.advance(0.1)
					test._check(flow.retired and failures == [MatchmakingFlow.TEXT_MATCH_LATE]
						and not states.has(starting) and not states.has(running),
						"[never_admitted] and its hold ends on its original expiry, having applied nothing: %s" % str(failures))
			"owner_cleared", "owner_disconnected":
				NetManager._receive_match_state(NRTypes.MatchState.STARTING)
				test._check(states.is_empty() and not NetManager._pending_start.is_empty(),
					"[%s] an admitted guest holds a start whose choice has not replicated" % scenario)
				_publish_start(flow, named)
				if scenario == "owner_cleared":
					party.fake_owners[party.fake_arranged.context_id] = {}
				else:
					party.fake_set_member(party.fake_arranged, _key(ARRANGED_OWNER_ID), false, _arranged_props(flow.match_id))
				NetManager._on_context_changed(party.fake_arranged)
				test._check(not states.has(starting) and not states.has(running) and flow.retired and failures.size() == 1,
					"[%s] the choice and the owner's loss arrive together: the loss ends the attempt and nothing is applied: %s %s" % [
						scenario, str(states), str(failures)])
		NetManager.match_state_changed.disconnect(record_state)
		NetManager.server_disconnected.disconnect(record_failure)
		await _teardown(test)


## Nothing of the old group is dismantled until this member's own premade and the pinned owner
## are ready in the arranged lobby with complete facts: every premade member present, connected,
## armed and carrying a compatible protocol and this match's id; the owner present, connected and
## carrying the same. What has not replicated holds the old network, within the handoff budget;
## an owner seen and then disconnected ends the handoff before any replacement is joined, even
## after the old network is gone. The facts are read again after every await before the
## replacement network. No other group is waited for.
func _b_premade_handoff_waits_for_complete_facts(test: Node) -> void:
	print("CASE: B-PREMADE-FACTS the old network is kept until the own premade and the pinned owner have complete facts; a known owner loss ends the handoff; the facts are read again after every await")
	for missing: String in ["protocol", "match", "both"]:
		await _setup(test, "facts-member-" + missing)
		var flow := await _searching_group(test, ["facts-guest"])
		if flow == null:
			await _teardown(test)
			continue
		party.fake_arranged_join_ok = true
		party.fake_arranged_owner = party.fake_local_key.duplicate()
		party.fake_owners[party.fake_arranged.context_id] = party.fake_local_key.duplicate()
		party.fake_arranged_peer = TransportPeer.new(NetManager.HOST_PEER_ID)
		party.fake_calls.clear()
		var match_id := "match-facts-" + missing
		_match(match_id)
		var partial := {PartyService.HANDOFF_READY_MEMBER_KEY: match_id}
		if missing == "match":
			partial[MatchmakingService.PROTOCOL_MEMBER_KEY] = NRProtocol.version_string()
		elif missing == "protocol":
			partial[PartyService.MATCH_ID_MEMBER_KEY] = match_id
		party.fake_set_member(party.fake_arranged, _key("facts-guest"), true, partial)
		clock.advance(10.0)
		test._check(flow.is_current() and flow.phase == MatchmakingFlow.Phase.ARMING_HANDOFF and not flow.staging_reset
			and not party.fake_calls.has("leave_transport:%d" % party.fake_staging.context_id) and not party.fake_calls.has("prepare"),
			"[%s] an armed premade member without its %s keeps the old network whole and prepares nothing" % [missing, missing])
		if missing == "both":
			clock.advance(MatchmakingFlow.HANDOFF_SECONDS)
			test._check(flow.retired and NetManager.last_disconnect_reason == MatchmakingFlow.TEXT_MATCH_LATE
				and not flow.staging_reset and not party.fake_calls.has("prepare"),
				"[both] facts that never arrive end the handoff at its budget, with no replacement: %s" % NetManager.last_disconnect_reason)
		else:
			party.fake_set_member(party.fake_arranged, _key("facts-guest"), true, _arranged_props(match_id))
			clock.advance(MatchmakingFlow.POLL_SECONDS)
			var left_at := party.fake_calls.find("leave_transport:%d" % party.fake_staging.context_id)
			test._check(left_at >= 0 and party.fake_calls.find("prepare") > left_at
				and flow.phase == MatchmakingFlow.Phase.ADMITTING_COHORT,
				"[%s] once the facts are complete the old network is left and the fresh one prepared (phase %d)" % [missing, flow.phase])
		await _teardown(test)

	for scenario: String in ["owner_facts", "owner_lost", "owner_never_seen", "held_owner_lost", "held_facts"]:
		await _setup(test, "facts-" + scenario.replace("_", "-"))
		var privileges := LoggingPrivileges.new()
		privileges.fake_log = party.fake_calls
		Services._privileges = privileges
		var guest := _staging_guest(test, 7)
		var mate: Array = ["facts-mate"] if scenario == "owner_lost" else []
		_arm(guest, false, [], mate)
		party.fake_arranged_peer = TransportPeer.new(9)
		var owner_key := _key(ARRANGED_OWNER_ID)
		match scenario:
			"owner_facts":
				party.fake_set_member(party.fake_arranged, owner_key, true, {PartyService.MATCH_ID_MEMBER_KEY: guest.match_id})
			"owner_never_seen":
				party.fake_set_member(party.fake_arranged, owner_key, false, _arranged_props(guest.match_id))
			"held_owner_lost", "held_facts":
				privileges.fake_hold = true
		party.fake_calls.clear()
		guest._arm_handoff()
		match scenario:
			"owner_facts", "owner_never_seen":
				clock.advance(5.0)
				test._check(guest.is_current() and guest.phase == MatchmakingFlow.Phase.ARMING_HANDOFF and not guest.staging_reset
					and not party.fake_calls.has("join_transport"),
					"[%s] an owner not yet connected with complete facts keeps the old network whole" % scenario)
				party.fake_set_member(party.fake_arranged, owner_key, true, _arranged_props(guest.match_id))
				clock.advance(MatchmakingFlow.POLL_SECONDS)
				test._check(guest.staging_reset and party.fake_calls.has("join_transport"),
					"[%s] once it is, the handoff goes on and the match's network is joined" % scenario)
			"owner_lost":
				clock.advance(MatchmakingFlow.POLL_SECONDS)
				test._check(guest.is_current() and not guest.staging_reset, "[owner_lost] its own group's other member holds the handoff")
				party.fake_set_member(party.fake_arranged, owner_key, false, _arranged_props(guest.match_id))
				clock.advance(MatchmakingFlow.POLL_SECONDS)
				test._check(guest.retired and NetManager.last_disconnect_reason == MatchmakingFlow.TEXT_MATCH_HOST_LEFT
					and not guest.staging_reset and not party.fake_calls.has("join_transport"),
					"[owner_lost] an owner seen and then disconnected ends the handoff before anything is dismantled: %s" % NetManager.last_disconnect_reason)
			"held_owner_lost", "held_facts":
				test._check(guest.staging_reset and party.fake_calls.has("leave_transport:%d" % party.fake_staging.context_id)
					and not party.fake_calls.has("join_transport"),
					"[%s] with everything ready the old network is left; the privilege check is still answering" % scenario)
				if scenario == "held_owner_lost":
					party.fake_set_member(party.fake_arranged, owner_key, false, _arranged_props(guest.match_id))
				else:
					party.fake_set_member(party.fake_arranged, owner_key, true, {PartyService.MATCH_ID_MEMBER_KEY: guest.match_id})
				privileges.fake_hold = false
				privileges.fake_released.emit()
				if scenario == "held_owner_lost":
					test._check(guest.retired and NetManager.last_disconnect_reason == MatchmakingFlow.TEXT_MATCH_HOST_LEFT
						and not party.fake_calls.has("join_transport"),
						"[held_owner_lost] read again after the await, the lost owner stops the handoff: nothing is joined: %s" % NetManager.last_disconnect_reason)
				else:
					test._check(guest.is_current() and not party.fake_calls.has("join_transport"),
						"[held_facts] read again after the await, an owner missing its facts is waited for, not joined")
					party.fake_set_member(party.fake_arranged, owner_key, true, _arranged_props(guest.match_id))
					clock.advance(MatchmakingFlow.POLL_SECONDS)
					test._check(party.fake_calls.has("join_transport"), "[held_facts] and joined once they are complete")
		privileges.fake_hold = false
		privileges.fake_released.emit()
		await _teardown(test)


## The match network becomes this player's session only while its own premade and the pinned
## owner still hold once that network has been created or joined: the arranged lobby does not
## stand still meanwhile. A premade member lost, or an owner gone from the lobby while its network
## stays up, ends the handoff with nothing of the new network used -- no peer taken on, no
## descriptor published, no admission asked for -- and the flow's cleanup leaves it. The owner
## waits for facts that went incomplete before its network is taken on. A guest takes its joined
## network on at once -- the host's connection is announced right after the join -- and waits for
## those facts before its admission is taken: an acceptance that arrives meanwhile is kept, and
## taken once they are complete.
func _b_premade_rechecked_once_the_network_is_ready(test: Node) -> void:
	print("CASE: B-PREMADE-NETWORK the own premade and the pinned owner are read again once the match network is created or joined; a loss meanwhile uses nothing of it; incomplete facts hold the owner's network, and a guest's admission, until they are complete")
	for scenario: String in ["member_lost", "member_incomplete"]:
		await _setup(test, "network-owner-" + scenario.replace("_", "-"))
		var flow := await _searching_group(test, ["net-guest"])
		if flow == null:
			await _teardown(test)
			continue
		party.fake_arranged_join_ok = true
		party.fake_arranged_owner = party.fake_local_key.duplicate()
		party.fake_owners[party.fake_arranged.context_id] = party.fake_local_key.duplicate()
		var arranged_peer: Variant = TransportPeer.new(NetManager.HOST_PEER_ID)
		party.fake_arranged_peer = arranged_peer
		party.fake_block_prepare = true
		var phases: Array[int] = []
		var record_phase := func() -> void: phases.append(int(flow.phase))
		flow.changed.connect(record_phase)
		party.fake_calls.clear()
		var match_id := "match-network-" + scenario.replace("_", "-")
		_match(match_id)
		party.fake_set_member(party.fake_arranged, _key("net-guest"), true, _arranged_props(match_id))
		clock.advance(MatchmakingFlow.POLL_SECONDS)
		test._check(flow.phase == MatchmakingFlow.Phase.SWITCHING_TRANSPORT and flow.staging_reset
			and party.fake_calls.has("prepare") and NetManager._peer != arranged_peer,
			"[%s] the old network is left and the match network is being created (phase %d)" % [scenario, flow.phase])
		if scenario == "member_lost":
			party.fake_remove_member(party.fake_arranged, _key("net-guest"))
		else:
			party.fake_set_member(party.fake_arranged, _key("net-guest"), true,
				{PartyService.HANDOFF_READY_MEMBER_KEY: match_id, PartyService.MATCH_ID_MEMBER_KEY: match_id})
		party.fake_block_prepare = false
		party.fake_prepare_released.emit()
		var unused: bool = not phases.has(int(MatchmakingFlow.Phase.ADMITTING_COHORT)) and NetManager._peer != arranged_peer \
			and _publications() == 0 and NetManager._cohort_policy.is_empty()
		if scenario == "member_lost":
			test._check(flow.retired and NetManager.last_disconnect_reason == MatchmakingFlow.TEXT_MATCH_MEMBER_LOST
				and unused and not NetManager.has_session(),
				"[member_lost] a premade member lost while the network was created ends the handoff; the network is never taken on or published: %s" % NetManager.last_disconnect_reason)
		else:
			test._check(flow.is_current() and flow.phase == MatchmakingFlow.Phase.SWITCHING_TRANSPORT and unused,
				"[member_incomplete] a premade member whose facts went incomplete is waited for; the network is not taken on or published yet")
			party.fake_set_member(party.fake_arranged, _key("net-guest"), true, _arranged_props(match_id))
			clock.advance(MatchmakingFlow.POLL_SECONDS)
			test._check(flow.phase == MatchmakingFlow.Phase.ADMITTING_COHORT and NetManager._peer == arranged_peer
				and _publications() == 1,
				"[member_incomplete] once they are complete the network becomes the session and is published (phase %d)" % flow.phase)
		flow.changed.disconnect(record_phase)
		await _teardown(test)

	for scenario: String in ["owner_disconnected", "mate_lost", "owner_incomplete", "mate_incomplete"]:
		await _setup(test, "network-guest-" + scenario.replace("_", "-"))
		var guest := _staging_guest(test, 7)
		_arm(guest, false, ["net-mate"], ["net-mate"])
		var arranged_peer: Variant = TransportPeer.new(9)
		party.fake_arranged_peer = arranged_peer
		party.fake_block_join_transport = true
		var phases: Array[int] = []
		var record_phase := func() -> void: phases.append(int(guest.phase))
		guest.changed.connect(record_phase)
		party.fake_calls.clear()
		guest._arm_handoff()
		test._check(guest.phase == MatchmakingFlow.Phase.SWITCHING_TRANSPORT and guest.staging_reset
			and party.fake_calls.has("join_transport") and NetManager._peer != arranged_peer,
			"[%s] the old network is left and the match network is being joined (phase %d)" % [scenario, guest.phase])
		var owner_key := _key(ARRANGED_OWNER_ID)
		match scenario:
			"owner_disconnected":
				party.fake_set_member(party.fake_arranged, owner_key, false, _arranged_props(guest.match_id))
			"mate_lost":
				party.fake_remove_member(party.fake_arranged, _key("net-mate"))
			"owner_incomplete":
				party.fake_set_member(party.fake_arranged, owner_key, true, {PartyService.MATCH_ID_MEMBER_KEY: guest.match_id})
			"mate_incomplete":
				party.fake_set_member(party.fake_arranged, _key("net-mate"), true,
					{PartyService.HANDOFF_READY_MEMBER_KEY: guest.match_id, PartyService.MATCH_ID_MEMBER_KEY: guest.match_id})
		party.fake_release_join()
		match scenario:
			"owner_disconnected", "mate_lost":
				var unused: bool = not phases.has(int(MatchmakingFlow.Phase.ADMITTING_COHORT)) and NetManager._peer != arranged_peer \
					and NetManager._active_join_request == null
				var reason := MatchmakingFlow.TEXT_MATCH_HOST_LEFT if scenario == "owner_disconnected" \
					else MatchmakingFlow.TEXT_MATCH_MEMBER_LOST
				test._check(guest.retired and NetManager.last_disconnect_reason == reason and unused and not NetManager.has_session(),
					"[%s] the joined network is never taken on and no admission is asked for: %s" % [scenario, NetManager.last_disconnect_reason])
			"owner_incomplete", "mate_incomplete":
				var request: JoinRequest = NetManager._active_join_request
				test._check(guest.phase == MatchmakingFlow.Phase.ADMITTING_COHORT and NetManager._peer == arranged_peer
					and NetManager.multiplayer.get_peers().has(NetManager.HOST_PEER_ID) and request != null,
					"[%s] the joined network is this player's session at once, so the host's connection announced right after the join is registered" % scenario)
				if scenario == "mate_incomplete":
					NetManager._accept_join()
					test._check(request != null and request.admitted, "[mate_incomplete] the host's acceptance is recorded")
				clock.advance(MatchmakingFlow.POLL_SECONDS)
				test._check(guest.is_current() and request != null and NetManager._active_join_request == request
					and request.is_pending() and not guest.staging_retired,
					"[%s] while those facts are incomplete the admission is not taken" % scenario)
				if scenario == "owner_incomplete":
					party.fake_set_member(party.fake_arranged, owner_key, true, _arranged_props(guest.match_id))
				else:
					party.fake_set_member(party.fake_arranged, _key("net-mate"), true, _arranged_props(guest.match_id))
				clock.advance(MatchmakingFlow.POLL_SECONDS)
				if scenario == "owner_incomplete":
					NetManager._accept_join()
					clock.advance(MatchmakingFlow.POLL_SECONDS)
				test._check(guest.is_current() and guest.phase == MatchmakingFlow.Phase.ADMITTING_COHORT
					and NetManager._active_join_request == null and guest.staging_retired,
					"[%s] once they are complete the guest is admitted and its old group retired" % scenario)
		guest.changed.disconnect(record_phase)
		await _teardown(test)


## How many times a network's descriptor was published since the case last cleared the call log.
func _publications() -> int:
	var count := 0
	for entry: String in party.fake_calls:
		if entry.begins_with("publish:"):
			count += 1
	return count


## Shared session state goes to admitted players and nobody else: a peer still waiting for its
## proof, and a peer turned away, hear none of the host's roster, readiness, gate, countdown or
## start, while admitted players hear all of it. The welcome, replay and acceptance still go to
## the one player they are for, and a refusal to a compatible peer is its single message. A
## refused peer then stops being one of the host's peers -- never an admitted player, the one a
## duplicate copies, or the host. The same holds for an ordinary hosted match, which keeps its
## own room-code advice; a matchmade session reached late, even after its first match runs, says
## the match is already under way. A newcomer is sent the roster only once it is admitted, so a
## player who leaves before then is never left on its roster.
func _b_recipients_shared_updates_reach_only_admitted_players(test: Node) -> void:
	print("CASE: B-RECIPIENTS shared updates reach admitted players only; pending and refused peers hear nothing shared; refused peers are dropped, never an admitted one; hosted and late-matchmade refusals keep their own words; a newcomer's roster is exact after a departure")
	await _setup(test, "recipients-matchmade")
	var flow := await _host_cohort(test, ["rc-b", "rc-c", "rc-d"])
	if flow != null:
		var peer: Variant = party.fake_arranged_peer
		_admit_cohort(["rc-b"])
		party.fake_proof_pending[3] = true
		_connect_member(3, "rc-c")
		_connect_member(5, "rc-b")
		var heard := _calls_to(peer, 2)
		_admit_cohort(["rc-d"], 4)
		NetManager.broadcast_countdown(5)
		test._check(_calls_to(peer, 3) == 0 and _calls_to(peer, 5) == 0,
			"a pending peer and a refused duplicate hear none of the admission or countdown: %d, %d" % [_calls_to(peer, 3), _calls_to(peer, 5)])
		test._check(_calls_to(peer, 2) > heard and _calls_to(peer, 4) > 0,
			"while the admitted players hear them as usual: %d, %d" % [_calls_to(peer, 2) - heard, _calls_to(peer, 4)])
		await test.get_tree().process_frame
		test._check(peer.disconnected == [5] and NetManager.players.has(2) and NetManager._arranged_candidates.has(3),
			"the refused duplicate is dropped; its admitted counterpart and the pending peer are not: %s" % str(peer.disconnected))
		party.fake_proof_pending.erase(3)
		NetManager._on_context_changed(party.fake_arranged)
		var greeted := _calls_to(peer, 3)
		test._check(greeted > 0 and not NetManager._arranged_candidates.has(3), "once its proof settles the pending peer is greeted")
		_identify(3, "rc-c")
		NetManager.broadcast_countdown(4)
		test._check(NetManager.players.has(3) and _calls_to(peer, 3) > greeted, "and, admitted, it hears what the others hear")
		var shared_before := _calls_to(peer, 2)
		_report_retired(flow, ["rc-b", "rc-c", "rc-d"])
		test._check(NetManager.match_state == NRTypes.MatchState.STARTING and flow.selected_keys.size() == 4
			and _calls_to(peer, 2) > shared_before,
			"the four start, and the chosen players hear the start")
		party.fake_set_member(party.fake_arranged, _key("rc-late"), true, _arranged_props(flow.match_id, true, "", true))
		_connect_member(7, "rc-late")
		NetManager.broadcast_countdown(3)
		test._check(_calls_to(peer, 7) == 1 and NetManager._closed_session_refusal_text() == MatchmakingFlow.TEXT_MATCH_ALREADY_STARTED,
			"a late arrival gets its one refusal and nothing shared: %d calls" % _calls_to(peer, 7))
		await test.get_tree().process_frame
		test._check(peer.disconnected == [5, 7] and flow.is_current() and NetManager.initial_cohort_intact(),
			"it is dropped too, and the chosen players' start is untouched: %s" % str(peer.disconnected))
		NetManager.set_match_state(NRTypes.MatchState.RUNNING)
		NetManager.consume_initial_cohort()
		party.fake_set_member(party.fake_arranged, _key("rc-later"), true, _arranged_props(flow.match_id, true, "", true))
		_connect_member(8, "rc-later")
		test._check(_calls_to(peer, 8) == 1 and not NetManager.players.has(8)
			and NetManager._closed_session_refusal_text() == MatchmakingFlow.TEXT_MATCH_ALREADY_STARTED,
			"after the first match runs a late arrival still reads that the match is under way, never room-code advice")
	await _teardown(test)

	await _setup(test, "recipients-hosted")
	var hosted: Variant = TransportPeer.new(NetManager.HOST_PEER_ID)
	test._check(NetManager._bind_peer(hosted), "a hosted match's host binds its transport")
	NetManager._is_offline = false
	NetManager._register_local_player(NetManager.HOST_PEER_ID)
	NetManager._set_accepting_joins(true)
	party.fake_peer_keys[2] = _key("h-b")
	hosted.connect_remote(2)
	_identify(2, "h-b")
	party.fake_peer_keys[3] = _key("h-c")
	hosted.connect_remote(3)
	var welcomed := _calls_to(hosted, 3)
	var before_ready := _calls_to(hosted, 2)
	NetManager._apply_ready_state(2, true)
	test._check(welcomed > 0 and _calls_to(hosted, 3) == welcomed and _calls_to(hosted, 2) > before_ready,
		"[hosted] a greeted peer not yet admitted hears no readiness change; the admitted guest does")
	_identify(3, "h-c")
	test._check(NetManager.players.has(3) and _calls_to(hosted, 3) > welcomed, "[hosted] its admission replays the roster to it and accepts it")
	NetManager._set_accepting_joins(false)
	party.fake_peer_keys[4] = _key("h-late")
	hosted.connect_remote(4)
	test._check(_calls_to(hosted, 4) == 1 and NetManager._closed_session_refusal_text() == NetManager.JOIN_REJECTED_IN_PROGRESS,
		"[hosted] a newcomer to a closed hosted match gets its one refusal, with the hosted match's own words")
	await test.get_tree().process_frame
	test._check(hosted.disconnected == [4] and NetManager.players.size() == 3,
		"[hosted] and is dropped from the host's peers; the admitted guests are not: %s" % str(hosted.disconnected))
	await _teardown(test)

	await _setup(test, "recipients-hosted-departure")
	var room: Variant = TransportPeer.new(NetManager.HOST_PEER_ID)
	test._check(NetManager._bind_peer(room), "[departure] a hosted match's host binds its transport")
	NetManager._is_offline = false
	NetManager._register_local_player(NetManager.HOST_PEER_ID)
	NetManager._set_accepting_joins(true)
	party.fake_peer_keys[2] = _key("d-b")
	room.connect_remote(2)
	_identify(2, "d-b")
	party.fake_peer_keys[3] = _key("d-c")
	room.connect_remote(3)
	var welcome := _calls_to(room, 3)
	test._check(welcome == 2,
		"[departure] the welcome is the mode and the identity request, and no roster: %d calls" % welcome)
	room.disconnect_remote(2)
	test._check(not NetManager.players.has(2) and _calls_to(room, 3) == welcome,
		"[departure] a player who leaves before the newcomer is admitted was never shown to it, and it is told nothing")
	_identify(3, "d-c")
	var admitted := _calls_to(room, 3) - welcome
	test._check(NetManager.players.has(3) and NetManager.players.size() == 2 and admitted == NetManager.players.size() + 2,
		"[departure] admitted, it is sent exactly the players still there -- one entry each, its own included -- with the mode and its acceptance: %d calls for %d players" % [admitted, NetManager.players.size()])
	await _teardown(test)


## A refused peer's removal is scoped to exactly that refusal. A new connection under the same
## id before the end of the frame is judged afresh and not removed; a session that ended
## meanwhile removes nothing; a full match refuses a proven compatible arrival in its own words;
## and a refused peer's own departure changes no roster, no chosen player and nobody's session.
func _b_refused_peer_removal_is_scoped_to_its_refusal(test: Node) -> void:
	print("CASE: B-RECIPIENTS a refusal's removal never reaches a reconnected peer, another session, an admitted player or the chosen players")
	for scenario: String in ["reconnected", "session_ended", "full", "departure"]:
		await _setup(test, "scoped-" + scenario.replace("_", "-"))
		var flow := await _host_cohort(test, ["sc-b", "sc-c", "sc-d"])
		if flow == null:
			await _teardown(test)
			continue
		var peer: Variant = party.fake_arranged_peer
		_admit_cohort(["sc-b"])
		match scenario:
			"reconnected":
				_connect_member(6, "sc-b")
				peer.disconnect_remote(6)
				_connect_member(6, "sc-c")
				test._check(not NetManager._arranged_candidates.has(6) and _calls_to(peer, 6) > 0,
					"[reconnected] a new connection under the refused id is judged afresh and greeted")
				await test.get_tree().process_frame
				test._check(peer.disconnected.is_empty(), "[reconnected] the earlier refusal removes nothing: %s" % str(peer.disconnected))
			"session_ended":
				_connect_member(6, "sc-b")
				NetManager.leave_match()
				await test.get_tree().process_frame
				test._check(peer.disconnected.is_empty(), "[session_ended] a refusal on a session that has ended removes nothing")
			"full":
				_admit_cohort(["sc-c", "sc-d"], 3)
				party.fake_set_member(party.fake_arranged, _key("sc-e"), true, _arranged_props(flow.match_id))
				_connect_member(6, "sc-e")
				test._check(_calls_to(peer, 6) == 1 and not NetManager.players.has(6) and flow.is_current(),
					"[full] a proven arrival past capacity gets its one refusal and no place")
				await test.get_tree().process_frame
				test._check(peer.disconnected == [6], "[full] and is dropped: %s" % str(peer.disconnected))
			"departure":
				_admit_cohort(["sc-c", "sc-d"], 3)
				_report_retired(flow, ["sc-b", "sc-c", "sc-d"])
				test._check(NetManager.match_state == NRTypes.MatchState.STARTING and flow.selected_keys.size() == 4,
					"[departure] the four start")
				_connect_member(6, "sc-b")
				var heard := _calls_to(peer, 2)
				await test.get_tree().process_frame
				test._check(peer.disconnected == [6] and _calls_to(peer, 2) == heard and NetManager.players.size() == 4
					and flow.is_current() and NetManager.initial_cohort_intact(),
					"[departure] the refused duplicate's removal tells nobody anything and touches no chosen player")
		await _teardown(test)


## A rematch replacement whose connection reaches the host before the host's view of the lobby
## lists it waits, hearing nothing shared, and is greeted once when its membership arrives. A
## round that closes meanwhile, or a wait that runs past its budget, admits nobody late.
func _f10_rematch_replacement_waits_for_its_lobby_membership(test: Node) -> void:
	print("CASE: F10/M1 a rematch replacement seen on the network before the lobby lists it waits, then is greeted once; a closed round or an expired wait admits nobody")
	for scenario: String in ["admitted", "closed", "expired"]:
		await _setup(test, "m1-" + scenario)
		var flow := await _host_cohort(test, ["m1-b"])
		if flow == null:
			await _teardown(test)
			continue
		_start_with(flow, ["m1-b"])
		NetManager.set_match_state(NRTypes.MatchState.RUNNING)
		NetManager.consume_initial_cohort()
		NetManager.reset_for_next_match()
		NetManager.flow_returned_to_lobby()
		var opened: bool = await NetManager.open_joins()
		test._check(opened and flow.phase == MatchmakingFlow.Phase.REMATCH_GATHERING, "[%s] the rematch round is open" % scenario)
		var peer: Variant = party.fake_arranged_peer
		_connect_member(9, "m1-new")
		NetManager._apply_ready_state(2, true)
		test._check(NetManager._arranged_candidates.has(9) and _calls_to(peer, 9) == 0,
			"[%s] a replacement the lobby does not list yet waits, hearing nothing shared" % scenario)
		match scenario:
			"admitted":
				party.fake_set_member(party.fake_arranged, _key("m1-new"), true, _arranged_props(flow.match_id))
				NetManager._on_context_changed(party.fake_arranged)
				var greeted := _calls_to(peer, 9)
				NetManager._on_context_changed(party.fake_arranged)
				test._check(greeted > 0 and _calls_to(peer, 9) == greeted,
					"[admitted] once its membership arrives it is greeted, once: %d calls" % greeted)
				_identify(9, "m1-new")
				test._check(NetManager.players.has(9), "[admitted] and admitted through the ordinary handshake")
			"closed":
				var closed: bool = await NetManager.close_joins()
				test._check(closed and not NetManager.is_accepting_joins(), "[closed] the round closes while it waits")
				party.fake_set_member(party.fake_arranged, _key("m1-new"), true, _arranged_props(flow.match_id))
				NetManager._on_context_changed(party.fake_arranged)
				test._check(not NetManager.players.has(9) and _calls_to(peer, 9) == 1,
					"[closed] its membership arriving afterwards admits nothing: it gets one refusal")
			"expired":
				clock.advance(NRConst.MATCH_ESTABLISHMENT_SECONDS)
				party.fake_set_member(party.fake_arranged, _key("m1-new"), true, _arranged_props(flow.match_id))
				NetManager._on_context_changed(party.fake_arranged)
				test._check(not NetManager.players.has(9) and not NetManager._arranged_candidates.has(9) and _calls_to(peer, 9) == 0,
					"[expired] a membership that arrives after its wait ran out admits nothing")
		if scenario != "admitted":
			await test.get_tree().process_frame
			test._check(peer.disconnected == [9], "[%s] and the peer is dropped: %s" % [scenario, str(peer.disconnected)])
		await _teardown(test)


func _capture_open_joins(box: Array) -> void:
	box[0] = await NetManager.open_joins()


## M1 over the real services: in an open rematch round, a replacement whose Party connection
## reaches the host before the host's view of the lobby lists it waits -- greeted by nothing
## and hearing nothing shared -- and is greeted once, and admitted, when its membership arrives.
func _c_m1_rematch_replacement_waits_over_the_real_services(test: Node) -> void:
	print("CASE: C-M1 over the real services a rematch replacement connected before its lobby membership waits, hears nothing shared, then is greeted once and admitted")
	await _setup_composed(test, "c-m1")
	var flow := await _composed_searching_group(test)
	var ticket := _composed_ticket()
	if flow == null or ticket == null:
		await _teardown_composed(test)
		return
	var network := ServiceDoubles.Network.new()
	var peer := RecordingPeer.new()
	network.local_peer = peer
	real_party.pf.party.queued_networks.append(network)
	ticket.match_id = "c-m1-match"
	ticket.arranged_lobby_connection_string = "c-m1-arrangement"
	ticket.publish_terminal(MatchmakingService.STATUS_MATCHED)
	var admitting: bool = await _composed_until(test, func() -> bool:
		return flow.retired or (flow.phase == MatchmakingFlow.Phase.ADMITTING_COHORT and flow.retirement_reported), 80)
	test._check(admitting and flow.is_current() and NetManager.is_host() and NetManager._peer == peer,
		"the matched solo owner opens its fresh network over the real services (phase %d): %s" % [flow.phase, NetManager.last_disconnect_reason])
	if not admitting or not flow.is_current():
		await _teardown_composed(test)
		return
	var lobby: ServiceDoubles.Lobby = real_party.pf.multiplayer.lobbies.back()
	var mate := _key("c-m1-b")
	lobby.members.append(ServiceDoubles.Member.new(mate, _arranged_props(flow.match_id, true, "", true)))
	lobby.state_changed.emit(ServiceDoubles.Change.new())
	peer.keys[2] = mate.duplicate()
	peer.connect_remote(2)
	_identify(2, "c-m1-b")
	var started: bool = await _composed_until(test, func() -> bool:
		return flow.retired or NetManager.match_state == NRTypes.MatchState.STARTING, 40)
	test._check(started and flow.is_current() and flow.selected_keys.size() == 2,
		"the first match starts with the two who arrived: %s" % NetManager.last_disconnect_reason)
	if not started or not flow.is_current():
		await _teardown_composed(test)
		return
	NetManager.set_match_state(NRTypes.MatchState.RUNNING)
	NetManager.consume_initial_cohort()
	NetManager.reset_for_next_match()
	NetManager.flow_returned_to_lobby()
	var reopened: Array = [null]
	_capture_open_joins(reopened)
	await _composed_until(test, func() -> bool: return reopened[0] != null, 20)
	test._check(reopened[0] == true and flow.phase == MatchmakingFlow.Phase.REMATCH_GATHERING and NetManager.is_accepting_joins(),
		"the rematch round opens through the real lobby: %s" % NetManager.last_admission_error)
	var replacement := _key("c-m1-new")
	peer.keys[3] = replacement.duplicate()
	peer.connect_remote(3)
	NetManager._apply_ready_state(2, true)
	test._check(NetManager._arranged_candidates.has(3) and _calls_to(peer, 3) == 0 and not NetManager.players.has(3),
		"a replacement on the network before the lobby lists it waits, greeted by nothing and hearing nothing shared")
	lobby.members.append(ServiceDoubles.Member.new(replacement, _arranged_props(flow.match_id, false)))
	lobby.state_changed.emit(ServiceDoubles.Change.new())
	var greeted := _calls_to(peer, 3)
	lobby.state_changed.emit(ServiceDoubles.Change.new())
	test._check(greeted > 0 and _calls_to(peer, 3) == greeted and not NetManager._arranged_candidates.has(3),
		"its membership arriving greets it once, without it reconnecting: %d calls" % greeted)
	_identify(3, "c-m1-new")
	test._check(NetManager.players.has(3) and peer.disconnected.is_empty(),
		"and it is admitted through the ordinary handshake; nobody was dropped")
	await _teardown_composed(test)


## C-AUTO over the real services: a full group of four, every member acknowledging the group and
## ready, starts a private match through the real PartyService in its own lobby -- no ticket, no
## arrangement, no new lobby or network -- on the same network, peer, session and roster, and the
## lobby reads back as that private match's: private access and kind, and its control naming the
## four for the session the flow keeps.
func _c_auto_full_group_starts_privately_over_the_real_services(test: Node) -> void:
	print("CASE: C-AUTO over the real services a full ready group starts privately in its own lobby and network: zero ticket, arrangement, lobby or network creates")
	await _setup_composed(test, "c-auto")
	var network := ServiceDoubles.Network.new()
	var peer := RecordingPeer.new()
	network.local_peer = peer
	real_party.pf.party.queued_networks.append(network)
	var flow := await _composed_group(test)
	if flow == null:
		await _teardown_composed(test)
		return
	var lobby: ServiceDoubles.Lobby = real_party.pf.multiplayer.lobbies.back()
	var lobbies := real_party.pf.multiplayer.lobbies.size()
	var networks := real_party.pf.party.networks.size()
	var session := NetManager.session_id()
	var entities: Array[String] = ["ca-b", "ca-c", "ca-d"]
	for index in entities.size():
		var key := _key(entities[index])
		lobby.members.append(ServiceDoubles.Member.new(key, {
			MatchmakingService.PROTOCOL_MEMBER_KEY: NRProtocol.version_string(),
			PartyService.MATCH_ORIGIN_MEMBER_KEY: PartyService.MATCH_ORIGIN_VALUE,
		}))
		peer.keys[5 + index] = key.duplicate()
		peer.connect_remote(5 + index)
		_identify(5 + index, entities[index])
	lobby.state_changed.emit(ServiceDoubles.Change.new())
	test._check(NetManager.players.size() == 4 and flow.phase == MatchmakingFlow.Phase.GATHERING,
		"the group of four gathers over the real services (phase %d)" % flow.phase)
	_ready_all()
	var locked: bool = await _composed_until(test, func() -> bool:
		return lobby.membership_lock != 0 or flow.phase != MatchmakingFlow.Phase.PRIVATE_PREPARING, 20)
	test._check(locked and flow.phase == MatchmakingFlow.Phase.PRIVATE_PREPARING,
		"all four ready start the private match: its lobby is locked (phase %d)" % flow.phase)
	for index in entities.size():
		flow.on_member_report(5 + index, flow.epoch, MatchmakingFlow.Phase.PRIVATE_PREPARING)
	var switched: bool = await _composed_until(test, func() -> bool:
		return String(lobby.search_properties.get(PartyService.LOBBY_KIND_KEY, "")) == PartyService.LOBBY_KIND_PRIVATE \
			or flow.phase != MatchmakingFlow.Phase.PRIVATE_PREPARING, 40)
	test._check(switched and flow.phase == MatchmakingFlow.Phase.PRIVATE_PREPARING
		and lobby.access_policy == PartyService.ACCESS_POLICY_PRIVATE,
		"the real service switches the same lobby to a private match: private access and kind (phase %d)" % flow.phase)
	for index in entities.size():
		flow.on_member_report(5 + index, flow.epoch, MatchmakingFlow.Phase.COMMITTING_START)
	var started: bool = await _composed_until(test, func() -> bool:
		return NetManager.match_state == NRTypes.MatchState.STARTING or flow.retired, 40)
	test._check(started and flow.is_current() and flow.phase == MatchmakingFlow.Phase.COMMITTING_START
		and flow.session_origin == PartyService.PLAY_ORIGIN_PRIVATE and flow.play_context != null
		and flow.staging_context == null,
		"the private match commits and its first match starts: %s" % NetManager.last_disconnect_reason)
	test._check(real_matchmaking.sdk.create_calls.is_empty() and real_party.pf.multiplayer.arranged_calls.is_empty()
		and real_party.pf.multiplayer.lobbies.size() == lobbies and real_party.pf.party.networks.size() == networks
		and NetManager._peer == peer and NetManager.session_id() == session and NetManager.players.size() == 4,
		"no ticket, no arrangement, no new lobby or network: the same peer, session and four players")
	var control := PartyService.decode_private_control(lobby.properties)
	test._check(bool(control.get("valid", false)) and String(control.get("session_id", "")) == flow.session_id
		and flow.session_id.length() == 32 and int(control.get("selected_count", 0)) == 4,
		"the lobby's control names the four for the session the flow keeps: %s" % str(control))
	await _teardown_composed(test)


## C-REMATCH over the real services: an invitation into a private match's open rematch round,
## its credential carrying the characters a console invitation carries, reaches the real lobby
## join exactly; the real service reads the lobby as that private session's open round; and the
## round's owner admits the player as that session's replacement -- never as a group's member --
## with no ticket, no arrangement and no lobby or network of its own.
func _c_rematch_private_invite_over_the_real_services(test: Node) -> void:
	print("CASE: C-REMATCH over the real services an intact private rematch invitation joins exactly as that private session's replacement")
	await _setup_composed(test, "c-rematch-real")
	var owner := _key("c-rematch-real-owner")
	var hosted := _composed_hosted_lobby(owner, _PRIVATE_CONNECTION)
	var lobby: ServiceDoubles.Lobby = hosted["lobby"]
	var peer: RecordingPeer = hosted["peer"]
	lobby.max_member_count = MatchmakingFlow.CAPACITY
	lobby.access_policy = PartyService.ACCESS_POLICY_PRIVATE
	lobby.owner_migration_policy = PartyService.OWNER_MIGRATION_NONE
	lobby.membership_lock = PartyService.MEMBERSHIP_LOCK_UNLOCKED
	lobby.search_properties = {
		PartyService.LOBBY_KIND_KEY: PartyService.LOBBY_KIND_PRIVATE,
		PartyService.GAME_MODE_KEY: "deathmatch",
		NRProtocol.LOBBY_KEY: NRProtocol.version_string(),
	}
	lobby.properties.merge(PartyService.encode_private_control(_PRIVATE_SESSION, 1, PartyService.ARRANGED_PHASE_REMATCH), true)
	var lobbies := real_party.pf.multiplayer.lobbies.size()
	var request := NetManager.join_by_invite(_PRIVATE_CONNECTION)
	var bound: bool = await _composed_until(test, func() -> bool:
		return NetManager._peer == peer or not request.is_pending(), 20)
	test._check(bound and request.is_pending() and NetManager._peer == peer
		and real_party.pf.multiplayer.join_calls == [_PRIVATE_CONNECTION]
		and StringName(NetManager._authority_scope.get("kind", &"")) == &"private_rematch"
		and String(NetManager._authority_scope.get("session_id", "")) == _PRIVATE_SESSION,
		"the credential reaches the real lobby join unchanged, and the session answers to that private round's owner: %s" % request.reason)
	if not bound or NetManager._peer != peer:
		await _teardown_composed(test)
		return
	peer.connect_remote(NetManager.HOST_PEER_ID)
	NetManager._request_player_identity()
	test._check(_rpc_calls(peer) == 1, "the real proof answers the private round's owner once")
	_host_replays_and_accepts("Private Host")
	var admitted: bool = await _composed_until(test, func() -> bool:
		return NetManager._flow != null or not request.is_pending(), 20)
	var flow: MatchmakingFlow = NetManager._flow
	test._check(admitted and request.succeeded() and flow != null,
		"the owner's ordinary admission makes this player a replacement: %s" % request.reason)
	if flow != null:
		test._check(flow.entry_kind == MatchmakingFlow.ENTRY_PRIVATE_REMATCH and flow.phase == MatchmakingFlow.Phase.REMATCH_GATHERING
			and flow.session_origin == PartyService.PLAY_ORIGIN_PRIVATE and flow.session_id == _PRIVATE_SESSION
			and flow.play_context != null and flow.staging_context == null and flow.arranged_context == null
			and flow.match_round == 1,
			"adopted as a guest of the private session's round 1, never as a group's member (phase %d)" % flow.phase)
	var local := {}
	for member: Variant in lobby.members:
		if (member as ServiceDoubles.Member).entity_key == lobby.local_entity_key:
			local = (member as ServiceDoubles.Member).properties
	test._check(String(local.get(PartyService.PRIVATE_SESSION_ID_KEY, "")) == _PRIVATE_SESSION
		and String(local.get(MatchmakingService.PROTOCOL_MEMBER_KEY, "")) == NRProtocol.version_string(),
		"its lobby membership names the private session it joined: %s" % str(local))
	test._check(real_matchmaking.sdk.create_calls.is_empty() and real_party.pf.multiplayer.arranged_calls.is_empty()
		and real_party.pf.multiplayer.lobbies.size() == lobbies,
		"no ticket, no arrangement and no lobby of its own")
	await _teardown_composed(test)


# --- F8: deadlines ------------------------------------------------------------------------

func _f8_deadline_alarms_fire_once_and_cancel_cleanly(test: Node) -> void:
	print("CASE: F8 a deadline alarm fires once at its deadline -- never early, never inside the call -- and a cancelled one holds nothing")
	var fake := Doubles.FakeClock.new()
	var probe := AlarmProbe.new()
	var alarm := fake.alarm_at(600000, probe.hit)
	test._check(alarm.is_armed() and probe.fake_hits == 0 and fake.armed_alarm_count() == 1,
		"armed, and nothing fired inside alarm_at()")
	fake.advance(599.999)
	test._check(probe.fake_hits == 0 and alarm.is_armed(), "at %d ms it has not fired" % fake.now_msec())
	fake.advance(0.001)
	test._check(probe.fake_hits == 1 and not alarm.is_armed(), "at %d ms it fired" % fake.now_msec())
	test._check(fake.armed_alarm_count() == 0, "a fired alarm is no longer counted: %d" % fake.armed_alarm_count())
	fake.advance(1000.0)
	test._check(probe.fake_hits == 1, "and it never fires again: %d" % probe.fake_hits)
	var cancelled := fake.alarm_after(5.0, probe.hit)
	cancelled.cancel()
	cancelled.cancel()
	fake.advance(10.0)
	test._check(probe.fake_hits == 1 and not cancelled.is_armed() and fake.armed_alarm_count() == 0,
		"a cancelled alarm never fires, and cancelling twice is harmless")
	var expired := fake.alarm_at(fake.now_msec() - 1, probe.hit)
	test._check(probe.fake_hits == 1 and expired.is_armed(), "an already-expired deadline does not fire inside alarm_at()")
	fake.advance(0.001)
	test._check(probe.fake_hits == 2 and not expired.is_armed(), "it fires on the clock's next wake")
	var raced := fake.alarm_after(1.0, probe.hit)
	fake.advance(1.0)
	raced.cancel()
	test._check(probe.fake_hits == 3, "cancelling after the fire changes nothing: %d" % probe.fake_hits)
	var marks: Array[String] = []
	var tie := fake.alarm_after(1.0, probe.mark.bind(marks, "alarm"))
	_sleep_then_mark(fake, 1.0, marks, "sleeper")
	fake.advance(1.0)
	test._check(marks.size() == 2 and marks[0] == "alarm" and marks[1] == "sleeper" and not tie.is_armed(),
		"due at the same instant as a sleeper, the alarm fires first: %s" % str(marks))
	var payload := RefCounted.new()
	var watched: WeakRef = weakref(payload)
	var held := _alarm_bound_to(fake, probe, payload)
	payload = null
	test._check(_still_alive(watched), "an armed alarm holds what its callable was bound to")
	held.cancel()
	test._check(not _still_alive(watched), "cancelling released it at once, with 30 seconds still to go")
	test._check(fake.armed_alarm_count() == 0 and fake.pending() == 0,
		"and nothing of it is left waiting on the clock: %d armed, %d asleep" % [fake.armed_alarm_count(), fake.pending()])
	fake.advance(60.0)
	test._check(probe.fake_hits == 3, "so nothing fires when its deadline passes: %d" % probe.fake_hits)

	var engine_clock := OnlineFlowClock.new()
	var engine_payload := RefCounted.new()
	var engine_watched: WeakRef = weakref(engine_payload)
	var on_engine := _alarm_bound_to(engine_clock, probe, engine_payload)
	engine_payload = null
	var engine_timer: SceneTreeTimer = on_engine._timer
	test._check(engine_timer != null and engine_clock.armed_alarm_count() == 1,
		"on the production clock an armed alarm waits on one engine timer of its own")
	if engine_timer != null:
		test._check(engine_timer.timeout.get_connections().size() == 1,
			"connected once: %d" % engine_timer.timeout.get_connections().size())
	on_engine.cancel()
	test._check(engine_clock.armed_alarm_count() == 0 and on_engine._timer == null,
		"cancelling takes it off the production clock at once")
	if engine_timer != null:
		test._check(engine_timer.timeout.get_connections().is_empty(),
			"its engine timer no longer calls back: %d" % engine_timer.timeout.get_connections().size())
	test._check(not _still_alive(engine_watched), "and what its callable held is released, 30 seconds early")


## Arms a 30-second alarm on `on_clock` whose callable is bound to `payload`, from a frame of
## its own: a Callable left in the case's own frame would keep the payload alive until the
## case returns, whatever the alarm did.
func _alarm_bound_to(on_clock: OnlineFlowClock, probe: AlarmProbe, payload: RefCounted) -> OnlineFlowClock.Alarm:
	return on_clock.alarm_after(30.0, probe.note.bind(payload))


## Whether `watched` still reaches its object, read in a frame of its own for the same reason.
func _still_alive(watched: WeakRef) -> bool:
	return watched.get_ref() != null


func _sleep_then_mark(on_clock: OnlineFlowClock, seconds: float, marks: Array[String], label: String) -> void:
	await on_clock.sleep_seconds(seconds)
	marks.append(label)


func _f8_split_budgets_do_not_renew(test: Node) -> void:
	print("CASE: F8 the 45-second entry, the 90-second handoff and owned late handles each hold on their own")
	await _setup(test, "f8-entry")
	party.fake_block_create = true
	var started_at := clock.now_msec()
	var box := [null]
	_start_matchmaking_into(box)
	for _frame in 10:
		if party.fake_calls.has("create_staging"):
			break
		await test.get_tree().process_frame
	var entry_budget := int(party.fake_deadlines.get("create_staging", 0)) - started_at
	test._check(entry_budget == 45000, "the staging creation carries the 45-second entry budget: %d ms" % entry_budget)
	clock.advance(MatchmakingFlow.ENTRY_SECONDS)
	party.fake_block_create = false
	party.fake_create_released.emit()
	await test.get_tree().process_frame
	test._check(not NetManager.has_online_flow() or NetManager._flow.retired, "a group whose creation outlived the entry budget never opens")
	test._check(NetManager.last_error == MatchmakingFlow.TEXT_ENTRY_TIMEOUT, "with the entry reason: %s" % NetManager.last_error)
	test._check(party.fake_calls.has("leave_lobby:%d" % party.fake_staging.context_id),
		"the late staging result was released through its own handle")
	await _teardown(test)

	await _setup(test, "f8-cancelled")
	party.fake_block_create = true
	var cancelled := [null]
	_start_matchmaking_into(cancelled)
	for _frame in 10:
		if party.fake_calls.has("create_staging"):
			break
		await test.get_tree().process_frame
	NetManager.leave_match()
	party.fake_block_create = false
	party.fake_create_released.emit()
	await test.get_tree().process_frame
	test._check(cancelled[0] == false, "Back while the group is opening ends the start: %s" % str(cancelled[0]))
	test._check(party.fake_calls.has("leave_lobby:%d" % party.fake_staging.context_id),
		"and the lobby that opened too late is released through its own handle")
	test._check(not NetManager.has_session(), "no session is left behind")
	await _teardown(test)

	await _setup(test, "f8-handoff")
	var alone := await _searching_owner(test)
	if alone == null:
		await _teardown(test)
		return
	party.fake_arranged_join_ok = true
	party.fake_arranged_owner = party.fake_local_key.duplicate()
	party.fake_owners[party.fake_arranged.context_id] = party.fake_local_key.duplicate()
	party.fake_arranged_peer = TransportPeer.new(NetManager.HOST_PEER_ID)
	_match("match-alone")
	clock.advance(MatchmakingFlow.HANDOFF_SECONDS - 1.0)
	test._check(alone.is_current() and alone.phase == MatchmakingFlow.Phase.ADMITTING_COHORT,
		"alone at 89 seconds, the owner still waits for anyone to arrive (phase %d)" % alone.phase)
	clock.advance(1.0)
	test._check(alone.retired and NetManager.last_disconnect_reason == MatchmakingFlow.TEXT_MATCH_LATE,
		"at 90 seconds the handoff ends: %s" % NetManager.last_disconnect_reason)
	await _teardown(test)

	await _setup(test, "f8-owned")
	var owed := await _searching_owner(test)
	if owed == null:
		await _teardown(test)
		return
	var operation := PartyService.ScopedOperation.new()
	operation.cleanup_pending = true
	party.fake_arranged_operation = operation
	_match("match-owed")
	test._check(owed.retired and NetManager.has_online_flow(),
		"a failed arranged join whose native completion is still owed keeps the lease")
	clock.advance(MatchmakingFlow.CANCEL_GRACE_SECONDS)
	var refused: bool = await NetManager.start_matchmaking()
	test._check(owed.phase == MatchmakingFlow.Phase.QUARANTINED and not refused,
		"it is shown as quarantine, and no new group starts meanwhile (phase %d)" % owed.phase)
	operation.cleanup_pending = false
	clock.advance(MatchmakingFlow.POLL_SECONDS)
	test._check(not NetManager.has_online_flow(), "the lease is released once that operation's cleanup settles")
	await _teardown(test)


# --- F9: lobby loss and service recovery ---------------------------------------------------

func _f9_lobby_loss_and_recovery_routing(test: Node) -> void:
	print("CASE: F9 a lost staging lobby ends the group until the flow retires it, armed or not; a lost arranged lobby always ends it; only the old transport's loss is expected once armed; a confirmed reset retires the flow first")
	await _setup(test, "f9-staging")
	var gathering := await _open_group(test)
	if gathering != null:
		NetManager._on_context_lost("Injected lobby loss.", party.fake_staging)
		test._check(gathering.retired and NetManager.last_disconnect_reason == "Injected lobby loss.",
			"before arming, a lost staging lobby ends the group: %s" % NetManager.last_disconnect_reason)
	await _teardown(test)

	await _setup(test, "f9-armed-staging")
	var armed := _staging_guest(test, 7)
	_arm(armed, false)
	NetManager._on_context_lost("Injected lobby loss.", party.fake_staging)
	test._check(armed.retired, "after arming, an unexpected staging lobby loss still ends the group (phase %d)" % armed.phase)
	test._check(NetManager.last_disconnect_reason == "Injected lobby loss.",
		"with the lobby's own reason: %s" % NetManager.last_disconnect_reason)
	test._check(not armed.staging_reset, "the armed old-transport branch is not taken for a lobby loss")
	await _teardown(test)

	await _setup(test, "f9-arranged")
	var matched := _staging_guest(test, 7)
	_arm(matched, false)
	NetManager._on_context_lost("Injected match lobby loss.", party.fake_arranged)
	test._check(matched.retired and NetManager.last_disconnect_reason == "Injected match lobby loss.",
		"a lost arranged lobby ends the match: %s" % NetManager.last_disconnect_reason)
	await _teardown(test)

	await _setup(test, "f9-old-transport")
	var swapping := _staging_guest(test, 7)
	_arm(swapping, false)
	NetManager._on_party_network_lost("Injected staging network loss.", party.fake_staging)
	test._check(swapping.is_current() and swapping.phase == MatchmakingFlow.Phase.ARMING_HANDOFF,
		"once armed, the old staging transport going away is the expected exception (phase %d)" % swapping.phase)
	test._check(swapping.staging_reset and not NetManager.has_session(),
		"it only ends the old session locally, early: reset %s" % str(swapping.staging_reset))
	test._check(NetManager.last_disconnect_reason.is_empty(), "and no player is told the match ended: '%s'" % NetManager.last_disconnect_reason)
	await _teardown(test)

	await _setup(test, "f9-retired")
	var losses: Array[String] = []
	var observe_loss := func(reason: String, _context: Variant) -> void: losses.append(reason)
	party.context_lost.connect(observe_loss)
	var joining := _staging_guest(test, 7)
	_arm(joining, false)
	var retired_peer: Variant = TransportPeer.new(9)
	party.fake_arranged_peer = retired_peer
	joining.switch_transport()
	retired_peer.connect_remote(NetManager.HOST_PEER_ID)
	NetManager._accept_join()
	clock.advance(MatchmakingFlow.POLL_SECONDS)
	test._check(party.fake_calls.has("leave_lobby:%d" % party.fake_staging.context_id) and joining.staging_context == null,
		"admitted, the guest retires its staging lobby on purpose")
	test._check(losses.is_empty(), "a deliberate retirement reports no lobby loss: %s" % str(losses))
	test._check(joining.is_current() and joining.phase == MatchmakingFlow.Phase.ADMITTING_COHORT,
		"and the flow carries on into the arranged session (phase %d)" % joining.phase)
	NetManager._on_context_lost("Late report for the retired lobby.", party.fake_staging)
	test._check(joining.is_current(), "a late report for a lobby the flow has retired is not the flow's loss")
	party.context_lost.disconnect(observe_loss)
	await _teardown(test)

	await _setup(test, "f9-reset")
	var searching := await _searching_owner(test)
	if searching != null:
		party.multiplayer_invalidated.emit(3)
		test._check(searching.retired, "a confirmed Multiplayer reset retires the flow synchronously")
		test._check(matchmaking.fake_log.has("invalidated:3:retired"),
			"before the service discharges the old tickets: %s" % str(matchmaking.fake_log))
		await test.get_tree().process_frame
		await test.get_tree().process_frame
		test._check(NetManager.last_disconnect_reason == NetManager.MULTIPLAYER_RECOVERED_REASON,
			"the players are told why: %s" % NetManager.last_disconnect_reason)
	await _teardown(test)

	await _setup(test, "f9-staging-owner")
	var guest := _staging_guest(test, 7)
	party.fake_owners[party.fake_staging.context_id] = _key("other-owner")
	NetManager._on_context_changed(party.fake_staging)
	test._check(guest.retired and NetManager.last_disconnect_reason == MatchmakingFlow.TEXT_OWNER_CHANGED,
		"a staging lobby whose native owner is no longer the host is not silently adopted: %s" % NetManager.last_disconnect_reason)
	await _teardown(test)

	await _setup(test, "f9-arranged-owner")
	var player := _staging_guest(test, 7)
	_arm(player, false)
	var arranged_peer: Variant = TransportPeer.new(9)
	party.fake_arranged_peer = arranged_peer
	player.switch_transport()
	arranged_peer.connect_remote(NetManager.HOST_PEER_ID)
	NetManager._accept_join()
	clock.advance(MatchmakingFlow.POLL_SECONDS)
	party.fake_owners[party.fake_arranged.context_id] = _key("other-owner")
	NetManager._on_context_changed(party.fake_arranged)
	test._check(player.retired and NetManager.last_disconnect_reason == MatchmakingFlow.TEXT_MATCH_HOST_CHANGED,
		"an arranged owner change is terminal, never adopted: %s" % NetManager.last_disconnect_reason)
	await _teardown(test)


## PlayFab clears a lobby's owner field the moment its owner leaves, which every member still
## inside rightly reads as the group's owner lost. So the group's staging owner leaves its
## old lobby last -- but waiting for its guests is preparation, not retirement: the lobby is
## still the group's until the owned leave itself begins, and retirement is complete only on
## a current OK leave with the old context quiescent. Nothing short of that marks it retired
## or starts the match.
func _f9_staging_owner_leaves_its_lobby_last(test: Node) -> void:
	print("CASE: F9 the staging owner leaves last; its wait is not retirement, and only a checked, bounded, quiescent leave retires the old lobby")
	for loss: String in ["owner_cleared", "disconnected"]:
		var waiting := await _staging_owner_waiting(test, "f9-wait-loss-" + loss, true)
		if waiting == null:
			await _teardown(test)
			continue
		test._check(not party.fake_calls.has("leave_lobby:%d" % party.fake_staging.context_id)
			and not waiting.staging_retiring and waiting.phase == MatchmakingFlow.Phase.ADMITTING_COHORT,
			"[%s] with its guest still connected the owner holds the old lobby, not yet retiring it" % loss)
		if loss == "owner_cleared":
			party.fake_owners[party.fake_staging.context_id] = {}
		NetManager._on_context_lost("Injected %s." % loss, party.fake_staging)
		test._check(waiting.retired and NetManager.last_disconnect_reason == "Injected %s." % loss,
			"[%s] an unexpected loss during the wait ends the flow: %s" % [loss, NetManager.last_disconnect_reason])
		test._check(not waiting.staging_retired and NetManager.match_state != NRTypes.MatchState.STARTING,
			"[%s] nothing was retired and nothing started" % loss)
		await _teardown(test)

	var flow := await _staging_owner_waiting(test, "f9-owner-last", true)
	if flow != null:
		clock.advance(MatchmakingFlow.POLL_SECONDS * 3.0)
		test._check(not party.fake_calls.has("leave_lobby:%d" % party.fake_staging.context_id) and not flow.staging_retiring,
			"waiting inside the budget never makes the owner leave first")
		party.fake_block_leave = true
		party.fake_set_member(party.fake_staging, _key("last-staging-guest"), false)
		clock.advance(MatchmakingFlow.POLL_SECONDS)
		test._check(party.fake_calls.has("leave_lobby:%d" % party.fake_staging.context_id) and flow.staging_retiring,
			"a member no longer connected does not hold the lobby: the owned leave begins, and only now is it retiring")
		test._check(not flow.staging_retired and flow.staging_context == party.fake_staging,
			"while that leave is unanswered nothing is retired and the old context stays tracked")
		party.fake_block_leave = false
		party.fake_leave_released.emit()
		test._check(flow.staging_retired and flow.retirement_reported and flow.staging_context == null and flow.is_current(),
			"an OK leave on a quiescent context retires it: retired %s, reported %s" % [flow.staging_retired, flow.retirement_reported])
		var marker := String((party._fake_member(party.fake_arranged, party.fake_local_key).get("properties", {}) as Dictionary).get(
			PartyService.STAGING_RETIRED_MEMBER_KEY, ""))
		test._check(marker == flow.match_id, "and this member's own retirement marker is in the arranged lobby: '%s'" % marker)
	await _teardown(test)

	var expiring := await _staging_owner_waiting(test, "f9-wait-expiry", false)
	if expiring != null:
		test._check(expiring.is_current() and not expiring.staging_retiring,
			"a staging owner admitted as an arranged guest still waits for its own guest")
		clock.advance(MatchmakingFlow.HANDOFF_SECONDS)
		test._check(expiring.retired and NetManager.last_disconnect_reason == MatchmakingFlow.TEXT_GROUP_NOT_RETIRED,
			"a wait that outlives the handoff budget fails instead of leaving anyway: %s" % NetManager.last_disconnect_reason)
		test._check(not expiring.staging_retired and not expiring.staging_retiring, "and nothing was retired")
	await _teardown(test)

	var held := await _staging_owner_waiting(test, "f9-held-leave", false)
	if held != null:
		party.fake_block_leave = true
		party.fake_remove_member(party.fake_staging, _key("last-staging-guest"))
		clock.advance(MatchmakingFlow.POLL_SECONDS)
		test._check(held.staging_retiring and not held.staging_retired and held.is_current(),
			"an admitted guest's owned leave is in flight")
		clock.advance(MatchmakingFlow.HANDOFF_SECONDS)
		test._check(held.retired and NetManager.last_disconnect_reason == MatchmakingFlow.TEXT_GROUP_NOT_RETIRED,
			"an alarm bounds the native leave itself: %s" % NetManager.last_disconnect_reason)
		test._check(not held.staging_retired, "and an unanswered leave retired nothing")
		party.fake_block_leave = false
		party.fake_leave_released.emit()
		test._check(not held.staging_retired and not held.retirement_reported, "its late answer changes nothing")
	await _teardown(test)

	for answer: String in ["null", "fail"]:
		var answered := await _staging_owner_waiting(test, "f9-leave-" + answer, true)
		if answered == null:
			await _teardown(test)
			continue
		party.fake_leave_results[party.fake_staging.context_id] = answer
		party.fake_remove_member(party.fake_staging, _key("last-staging-guest"))
		clock.advance(MatchmakingFlow.POLL_SECONDS)
		test._check(answered.retired and not answered.staging_retired,
			"[%s] only a nonnull OK leave retires the old lobby: %s" % [answer, NetManager.last_disconnect_reason])
		test._check(NetManager.match_state != NRTypes.MatchState.STARTING, "[%s] and nothing started" % answer)
		await _teardown(test)

	var busy := await _staging_owner_waiting(test, "f9-not-quiescent", false)
	if busy != null:
		party.fake_quiescent[party.fake_staging.context_id] = false
		party.fake_remove_member(party.fake_staging, _key("last-staging-guest"))
		clock.advance(MatchmakingFlow.POLL_SECONDS)
		test._check(busy.is_current() and not busy.staging_retired,
			"an OK leave with captured staging work still owed is not yet retirement")
		clock.advance(MatchmakingFlow.HANDOFF_SECONDS)
		test._check(busy.retired and not busy.staging_retired and NetManager.last_disconnect_reason == MatchmakingFlow.TEXT_GROUP_NOT_RETIRED,
			"and it fails when the budget ends first: %s" % NetManager.last_disconnect_reason)
	await _teardown(test)

	var invalidated := await _staging_owner_waiting(test, "f9-invalidated", true)
	if invalidated != null:
		NetManager.leave_match()
		party.fake_remove_member(party.fake_staging, _key("last-staging-guest"))
		clock.advance(MatchmakingFlow.POLL_SECONDS)
		test._check(invalidated.retired and not invalidated.staging_retired and not invalidated.retirement_reported,
			"a flow already ended while waiting retires nothing and reports nothing")
	await _teardown(test)

	await _setup(test, "f9-old-transport-fails")
	var failing := await _open_group(test)
	if failing != null:
		_arm(failing, true)
		party.fake_arranged_peer = TransportPeer.new(NetManager.HOST_PEER_ID)
		party.fake_transport_leave_fail = true
		party.fake_calls.clear()
		failing.switch_transport()
		test._check(failing.retired and NetManager.last_disconnect_reason == "Injected transport leave failure.",
			"a failed old-network leave ends the handoff: %s" % NetManager.last_disconnect_reason)
		test._check(not party.fake_calls.has("prepare") and not party.fake_calls.has("join_transport"),
			"no replacement network is created on the assumption it succeeded")
		test._check(not failing.staging_retired and NetManager.match_state != NRTypes.MatchState.STARTING,
			"nothing was retired and nothing started")
	await _teardown(test)


## A staging owner whose own staging guest is still connected in the old lobby, driven to
## where its retirement waits for that guest: as the arranged owner right after publishing,
## or as an arranged guest right after its admission.
func _staging_owner_waiting(test: Node, account: String, arranged_owner: bool) -> MatchmakingFlow:
	await _setup(test, account)
	var flow := await _open_group(test)
	if flow == null:
		return null
	_add_guest(7, "last-staging-guest")
	NetManager.roster_changed.emit()
	var cohort: Array = ["last-staging-guest"] if arranged_owner else []
	_arm(flow, arranged_owner, cohort)
	var peer: Variant = TransportPeer.new(NetManager.HOST_PEER_ID if arranged_owner else 9)
	party.fake_arranged_peer = peer
	flow.switch_transport()
	if not arranged_owner:
		peer.connect_remote(NetManager.HOST_PEER_ID)
		NetManager._accept_join()
		clock.advance(MatchmakingFlow.POLL_SECONDS)
	test._check(flow.is_current() and flow.phase == MatchmakingFlow.Phase.ADMITTING_COHORT,
		"[%s] the staging owner reached the arranged session (phase %d)" % [account, flow.phase])
	return flow


# --- F10: gameplay, return and the arranged rematch -----------------------------------------

## A first match that started with two keeps the same session of four afterwards. Back in the
## lobby the host reopens it for a hosted round -- no ticket and no new search -- replacements
## fill it up to four, and a round of two or more starts through the ordinary hosted path.
func _f10_host_returns_to_an_arranged_rematch(test: Node) -> void:
	print("CASE: F10/B-RETURN a first match of two returns into the same session of four; replacements fill it to four with no ticket, and a hosted round of two or more starts")
	await _setup(test, "f10-host")
	var flow := await _host_cohort(test, ["m-b"])
	if flow == null:
		await _teardown(test)
		return
	_start_with(flow, ["m-b"])
	test._check(NetManager.match_state == NRTypes.MatchState.STARTING and flow.selected_keys.size() == 2,
		"the first match starts with the two who arrived")
	NetManager.set_match_state(NRTypes.MatchState.RUNNING)
	NetManager.consume_initial_cohort()
	test._check(flow.phase == MatchmakingFlow.Phase.GAMEPLAY, "the first match runs (phase %d)" % flow.phase)
	var creates := matchmaking.fake_creates.size()
	var joins := matchmaking.fake_joins.size()
	NetManager.reset_for_next_match()
	NetManager.flow_returned_to_lobby()
	test._check(flow.phase == MatchmakingFlow.Phase.REMATCH_GATHERING and flow.match_round == 1
		and NetManager.session_capacity() == 4,
		"back in the lobby the host opens round %d of the same session of four" % flow.match_round)
	test._check(not NetManager.everyone_ready(), "every human is unready after the return")
	party.fake_calls.clear()
	var opened: bool = await NetManager.open_joins()
	test._check(opened and NetManager.is_accepting_joins(), "the arranged session reopens: %s" % NetManager.last_admission_error)
	var control := PartyService.decode_arranged_control(party.fake_lobby_properties.get(party.fake_arranged.context_id, {}))
	test._check(bool(control.get("valid", false)) and String(control.get("phase", "")) == PartyService.ARRANGED_PHASE_REMATCH
		and int(control.get("round", -1)) == 1 and int(control.get("start_generation", -1)) == 0
		and int(control.get("selected_count", -1)) == 0,
		"the rematch phase and round were published, with no start set: %s" % str(control))
	var published_at := party.fake_calls.find("post:%s" % PartyService.ARRANGED_PHASE_REMATCH)
	var unlocked_at := party.fake_calls.find("lock:false")
	test._check(published_at >= 0 and unlocked_at > published_at,
		"the phase is published before the unlock (post %d, unlock %d)" % [published_at, unlocked_at])
	test._check(matchmaking.fake_creates.size() == creates and matchmaking.fake_joins.size() == joins, "no ticket was created or joined")
	for entity: String in ["m-new", "m-new2"]:
		party.fake_set_member(party.fake_arranged, _key(entity), true, _arranged_props(flow.match_id))
	party.fake_set_member(party.fake_arranged, _key("m-old"), true, _arranged_props(flow.match_id, true, "1.3"))
	var before: int = party.fake_arranged_peer.sent.size()
	_connect_member(10, "m-old")
	test._check(party.fake_arranged_peer.sent.size() == before and flow.is_current(),
		"a replacement on another protocol is sent nothing, and the session carries on")
	_connect_member(9, "m-new")
	test._check(party.fake_arranged_peer.sent.size() > before, "a replacement whose protocol is proven is greeted in the rematch round")
	_identify(9, "m-new")
	_admit_cohort(["m-new2"], 11)
	test._check(NetManager.players.size() == 4 and NetManager.players.has(9) and NetManager.players.has(11),
		"replacements fill the session up to its four through the ordinary host handshake: %d players" % NetManager.players.size())
	party.fake_arranged_peer.disconnect_remote(11)
	party.fake_arranged_peer.disconnect_remote(10)
	test._check(flow.is_current() and NetManager.players.size() == 3,
		"after the first match, departures follow the hosted rules: %d players" % NetManager.players.size())
	for peer_id: int in NetManager.players.keys():
		NetManager._apply_ready_state(peer_id, true)
	var sealed: bool = await NetManager.close_joins()
	test._check(sealed and not NetManager.is_accepting_joins(), "three ready players close the session for the next round")
	control = PartyService.decode_arranged_control(party.fake_lobby_properties.get(party.fake_arranged.context_id, {}))
	test._check(String(control.get("phase", "")) == PartyService.ARRANGED_PHASE_GAMEPLAY and int(control.get("round", -1)) == 1,
		"the gameplay phase is published so a rematch invite is refused meanwhile: %s" % str(control))
	NetManager.set_match_state(NRTypes.MatchState.STARTING)
	test._check(flow.phase == MatchmakingFlow.Phase.GAMEPLAY and not NetManager.initial_cohort_pending(),
		"the round of three starts as a hosted rematch, outside the first match's rule (phase %d)" % flow.phase)
	test._check(matchmaking.fake_creates.size() == creates, "still no ticket")
	await _teardown(test)


func _f10_guest_waits_for_host_return(test: Node) -> void:
	print("CASE: F10 a guest back before its host waits at most 45 seconds, and moves on when the host's rematch phase lands")
	for scenario: String in ["returns", "never"]:
		await _setup(test, "f10-guest-" + scenario)
		var flow := _staging_guest(test, 7)
		_arm(flow, false)
		var arranged_peer: Variant = TransportPeer.new(9)
		party.fake_arranged_peer = arranged_peer
		flow.switch_transport()
		arranged_peer.connect_remote(NetManager.HOST_PEER_ID)
		NetManager._accept_join()
		clock.advance(MatchmakingFlow.POLL_SECONDS)
		NetManager._set_match_state(NRTypes.MatchState.STARTING)
		NetManager._set_match_state(NRTypes.MatchState.RUNNING)
		test._check(flow.phase == MatchmakingFlow.Phase.GAMEPLAY, "[%s] the guest played the match (phase %d)" % [scenario, flow.phase])
		# The first match's own control stands through it: the owner's published choice, round 0.
		var chosen: Array[Dictionary] = [_key(ARRANGED_OWNER_ID), party.fake_local_key.duplicate()]
		_publish_start(flow, chosen)
		NetManager.flow_returned_to_lobby()
		test._check(not flow.host_returned and NetManager._host_return_alarm != null,
			"[%s] back first, it waits for the host" % scenario)
		if scenario == "returns":
			clock.advance(20.0)
			party.fake_lobby_properties[party.fake_arranged.context_id] = PartyService.encode_arranged_control(
				flow.match_id, 1, PartyService.ARRANGED_PHASE_REMATCH)
			NetManager._on_context_changed(party.fake_arranged)
			test._check(flow.phase == MatchmakingFlow.Phase.REMATCH_GATHERING and flow.host_returned and flow.match_round == 1,
				"[returns] the host's rematch phase moves it into round %d" % flow.match_round)
			test._check(NetManager._host_return_alarm == null, "[returns] and ends the wait")
			clock.advance(60.0)
			test._check(flow.is_current(), "[returns] the ended wait never fires")
		else:
			clock.advance(MatchmakingFlow.HOST_RETURN_SECONDS - 0.1)
			test._check(flow.is_current(), "[never] still waiting just short of 45 seconds")
			clock.advance(0.1)
			test._check(flow.retired and NetManager.last_disconnect_reason == MatchmakingFlow.TEXT_HOST_DID_NOT_RETURN,
				"[never] at 45 seconds it leaves: %s" % NetManager.last_disconnect_reason)
		await _teardown(test)


func _f10_rematch_invite_joins_through_netmanager(test: Node) -> void:
	print("CASE: F10 an intact invite into a rematch lobby joins as a replacement with no ticket or arranged join; other arranged destinations are refused")
	await _setup(test, "f10-replacement")
	var peer: Variant = TransportPeer.new(8)
	_prove_owner(party.fake_arranged, _key(ARRANGED_OWNER_ID), _arranged_props("match-r"))
	party.fake_lobby_properties[party.fake_arranged.context_id] = _arranged_control("match-r", 2, PartyService.ARRANGED_PHASE_REMATCH)
	party.fake_join_result = {
		"ok": true, "peer": peer, "code": "", "error": "",
		"kind": PartyService.LOBBY_KIND_ARRANGED, "destination": "arranged_rematch",
		"context": party.fake_arranged, "match_id": "match-r", "round": 2,
		"owner_key": _key(ARRANGED_OWNER_ID), "capacity": 4, "selected_start_count": 0,
	}
	var request := NetManager.join_by_invite(ARRANGED_CONNECTION)
	test._check(request.is_pending() and party.fake_last_connection_string == ARRANGED_CONNECTION,
		"the invite's credential reaches PartyService unchanged: '%s'" % party.fake_last_connection_string)
	peer.connect_remote(NetManager.HOST_PEER_ID)
	NetManager._accept_join()
	clock.advance(MatchmakingFlow.POLL_SECONDS)
	var flow: MatchmakingFlow = NetManager._flow
	test._check(request.succeeded() and flow != null, "the host's ordinary admission makes this player a replacement")
	if flow != null:
		test._check(flow.entry_kind == MatchmakingFlow.ENTRY_ARRANGED_REMATCH and flow.phase == MatchmakingFlow.Phase.REMATCH_GATHERING,
			"adopted as an arranged rematch guest (phase %d)" % flow.phase)
		test._check(flow.arranged_context == party.fake_arranged and flow.staging_context == null
			and flow.match_round == 2 and not flow.arranged_owner, "holding the arranged lobby as arranged, never as staging")
	test._check(matchmaking.fake_creates.is_empty() and matchmaking.fake_joins.is_empty()
		and party.fake_join_arranged_calls.is_empty(), "no ticket and no arranged join")
	await _teardown(test)

	for scenario: String in ["service_refused", "unknown_destination"]:
		await _setup(test, "f10-refused-" + scenario)
		var expected := NetManager._INVITE_DESTINATION_REFUSED
		if scenario == "service_refused":
			expected = "That arranged match is not accepting rematch players."
			party.fake_join_result = {
				"ok": false, "error": expected, "kind": PartyService.LOBBY_KIND_ARRANGED,
				"context": null, "peer": null, "code": "",
			}
		else:
			party.fake_join_result = {
				"ok": true, "peer": TransportPeer.new(8), "code": "", "error": "",
				"kind": PartyService.LOBBY_KIND_ARRANGED, "destination": "", "context": party.fake_arranged,
			}
		var refused := NetManager.join_by_invite(ARRANGED_CONNECTION)
		clock.advance(MatchmakingFlow.POLL_SECONDS)
		await test.get_tree().process_frame
		test._check(refused.outcome == JoinRequest.Outcome.FAILED and refused.reason == expected,
			"[%s] refused with a durable reason: %s" % [scenario, refused.reason])
		test._check(not NetManager.has_online_flow() and not NetManager.has_session(), "[%s] nothing was adopted" % scenario)
		if scenario == "unknown_destination":
			test._check(party.fake_calls.has("leave_lobby:%d" % party.fake_arranged.context_id),
				"[unknown] the candidate lobby is released through its own handle")
		await _teardown(test)


# --- R1: whose messages a guest acts on ---------------------------------------------------

## The pending join an intact rematch invitation leaves: the arranged lobby entered as a
## replacement's candidate, bound with no flow yet, its owner pinned as `owner_key` and its
## round 2 still gathering. `pending_proof` holds the owner's facts back from the start, as
## a lobby whose owner has not replicated to this member yet is. Returns the transport.
func _pending_rematch(test: Node, owner_key: Dictionary, pending_proof: bool = false) -> Variant:
	var peer: Variant = TransportPeer.new(8)
	_prove_owner(party.fake_arranged, owner_key, _arranged_props("match-r"))
	party.fake_lobby_properties[party.fake_arranged.context_id] = _arranged_control("match-r", 2, PartyService.ARRANGED_PHASE_REMATCH)
	if pending_proof:
		party.fake_proof_pending[NetManager.HOST_PEER_ID] = true
	party.fake_join_result = {
		"ok": true, "peer": peer, "code": "", "error": "",
		"kind": PartyService.LOBBY_KIND_ARRANGED, "destination": "arranged_rematch",
		"context": party.fake_arranged, "match_id": "match-r", "round": 2,
		"owner_key": owner_key.duplicate(), "capacity": 4, "selected_start_count": 0,
	}
	var request := NetManager.join_by_invite(ARRANGED_CONNECTION)
	test._check(request.is_pending() and NetManager.has_session() and not NetManager.has_online_flow(),
		"the rematch replacement is bound with no flow yet")
	peer.connect_remote(NetManager.HOST_PEER_ID)
	return peer


## What an arranged host sends a newcomer it has greeted: another player's roster entry,
## its admission state and a match state. None of it may land before peer 1 is proven.
func _send_unproven_authority() -> void:
	var stranger := PlayerState.new()
	stranger.peer_id = 3
	stranger.display_name = "R1 Stranger"
	NetManager._receive_roster_entry(stranger.to_dict())
	NetManager._receive_join_admission(true)
	NetManager._receive_match_state(NRTypes.MatchState.RUNNING)


## The host's answer to a proven newcomer's identity: the whole roster and the mode again,
## then its acceptance -- the replay a message dropped before the proof is recovered from.
func _host_replays_and_accepts(host_name: String) -> void:
	var host := PlayerState.new()
	host.peer_id = NetManager.HOST_PEER_ID
	host.display_name = host_name
	var other := PlayerState.new()
	other.peer_id = 3
	other.display_name = "R1 Other"
	NetManager._receive_roster_entry(host.to_dict())
	NetManager._receive_roster_entry(other.to_dict())
	NetManager._receive_game_mode(int(NRTypes.GameModeType.DEATHMATCH))
	NetManager._accept_join()


## Before any flow exists, a rematch replacement's pending join trusts peer 1 only as the
## proven current owner of the arranged lobby it joined. Until then it sends no identity and
## lets nothing peer 1 sends land -- roster, admission state, match state or an acceptance.
## A wrong, changed, cleared or disconnected owner, another protocol, another match or a
## reset runtime ends the join through its own cleanup with a reason this title owns, and
## nothing admitted, succeeded or adopted. A proof that settles later answers the host's one
## original request, once; the host's replay then gives the whole roster and mode, and its
## acceptance is the one admission that adopts the rematch.
func _r1_pending_rematch_trusts_only_the_proven_owner(test: Node) -> void:
	print("CASE: R1 a pending rematch replacement sends nothing to peer 1 and takes nothing from it until peer 1 is the joined lobby's proven owner")
	var owner_key := _key(ARRANGED_OWNER_ID)
	var refusals := {
		"other_peer": NetManager._REMATCH_HOST_CHANGED,
		"owner_changed": NetManager._REMATCH_HOST_CHANGED,
		"owner_cleared": NetManager._REMATCH_HOST_CHANGED,
		"disconnected": NetManager._REMATCH_HOST_LEFT,
		"recovered": NetManager._REMATCH_HOST_LEFT,
		"protocol": MatchmakingFlow.TEXT_MATCH_INCOMPATIBLE,
		"other_match": MatchmakingFlow.TEXT_MATCH_INCOMPATIBLE,
	}
	for scenario: String in refusals.keys() + ["pending"]:
		await _setup(test, "r1-" + scenario)
		var peer: Variant = _pending_rematch(test, owner_key, scenario == "pending")
		var request: JoinRequest = NetManager._active_join_request
		match scenario:
			"other_peer":
				party.fake_peer_keys[NetManager.HOST_PEER_ID] = _key("other-peer")
			"owner_changed":
				party.fake_owners[party.fake_arranged.context_id] = _key("other-owner")
			"owner_cleared":
				party.fake_owners[party.fake_arranged.context_id] = {}
			"disconnected":
				party.fake_set_member(party.fake_arranged, owner_key, false, _arranged_props("match-r"))
			"recovered":
				party.fake_proof_override[NetManager.HOST_PEER_ID] = {"recovery_epoch": 7}
			"protocol":
				party.fake_set_member(party.fake_arranged, owner_key, true, _arranged_props("match-r", true, "1.3"))
			"other_match":
				party.fake_set_member(party.fake_arranged, owner_key, true, _arranged_props("another-match"))
		var calls := _rpc_calls(peer)
		NetManager._request_player_identity()
		_send_unproven_authority()
		NetManager._accept_join()
		test._check(_rpc_calls(peer) == calls, "[%s] no identity is sent: %d calls" % [scenario, _rpc_calls(peer) - calls])
		test._check(not NetManager.players.has(3), "[%s] peer 1's roster entry does not land" % scenario)
		test._check(not NetManager.is_accepting_joins(), "[%s] nor its admission state" % scenario)
		test._check(NetManager.match_state != NRTypes.MatchState.RUNNING, "[%s] nor its match state" % scenario)
		test._check(request != null and not request.admitted, "[%s] and its acceptance admits nothing" % scenario)
		if scenario != "pending":
			clock.advance(MatchmakingFlow.POLL_SECONDS)
			await test.get_tree().process_frame
			test._check(request.outcome == JoinRequest.Outcome.FAILED,
				"[%s] the join ends through its own cleanup: outcome %d" % [scenario, request.outcome])
			test._check(request.reason == String(refusals[scenario]), "[%s] with this title's reason: %s" % [scenario, request.reason])
			test._check(not NetManager.has_online_flow() and not NetManager.has_session(), "[%s] and nothing is adopted" % scenario)
			await _teardown(test)
			continue
		test._check(request.is_pending() and not NetManager.has_online_flow(), "[pending] the join keeps waiting, with no flow")
		party.fake_proof_pending.erase(NetManager.HOST_PEER_ID)
		NetManager._on_context_changed(party.fake_arranged)
		test._check(_rpc_calls(peer) == calls + 1,
			"[pending] once the lobby settles the proof, the host's one request is answered: %d calls" % (_rpc_calls(peer) - calls))
		NetManager._on_context_changed(party.fake_arranged)
		NetManager._on_connected_to_server()
		test._check(_rpc_calls(peer) == calls + 1, "[pending] and never a second time: %d calls" % (_rpc_calls(peer) - calls))
		test._check(not request.admitted, "[pending] the acceptance that came before the proof still admitted nothing")
		_host_replays_and_accepts("R1 Host")
		test._check(request.admitted, "[pending] the proven owner's acceptance admits")
		clock.advance(MatchmakingFlow.POLL_SECONDS)
		var flow: MatchmakingFlow = NetManager._flow
		test._check(request.succeeded() and flow != null and flow.entry_kind == MatchmakingFlow.ENTRY_ARRANGED_REMATCH,
			"[pending] and that one admission adopts the rematch")
		test._check(NetManager.players.has(NetManager.HOST_PEER_ID) and NetManager.players.has(3),
			"[pending] holding the whole current roster from the replay: %s" % str(NetManager.players.keys()))
		await _teardown(test)


## An acceptance is taken on the owner and round of the moment it is consumed, not on an
## earlier proof: an owner that changes, or a round that begins, between the host's
## acceptance and its consumption ends the join with nothing adopted. A request from a
## session that has already ended sends nothing.
func _r1_rematch_admission_rechecks_owner_and_round(test: Node) -> void:
	print("CASE: R1 a rematch replacement's admission is re-proven at consumption; an ended session's request sends nothing")
	var owner_key := _key(ARRANGED_OWNER_ID)
	for scenario: String in ["owner_moved", "round_began"]:
		await _setup(test, "r1-late-" + scenario)
		var peer: Variant = _pending_rematch(test, owner_key)
		var request: JoinRequest = NetManager._active_join_request
		var calls := _rpc_calls(peer)
		NetManager._request_player_identity()
		test._check(_rpc_calls(peer) == calls + 1, "[%s] the proven owner is answered once" % scenario)
		_host_replays_and_accepts("R1 Host")
		test._check(request.admitted, "[%s] and its acceptance is recorded" % scenario)
		if scenario == "owner_moved":
			party.fake_owners[party.fake_arranged.context_id] = _key("other-owner")
		else:
			party.fake_lobby_properties[party.fake_arranged.context_id] = _arranged_control("match-r", 2, PartyService.ARRANGED_PHASE_GAMEPLAY)
		clock.advance(MatchmakingFlow.POLL_SECONDS)
		clock.advance(MatchmakingFlow.POLL_SECONDS)
		await test.get_tree().process_frame
		var expected: String = NetManager._REMATCH_HOST_CHANGED if scenario == "owner_moved" else NetManager._REMATCH_MOVED
		test._check(request.outcome == JoinRequest.Outcome.FAILED and request.reason == expected,
			"[%s] consuming it proves the owner and round again: %s" % [scenario, request.reason])
		test._check(not NetManager.has_online_flow(), "[%s] and no rematch is adopted" % scenario)
		await _teardown(test)

	await _setup(test, "r1-ended")
	var ended: Variant = _pending_rematch(test, owner_key)
	NetManager.leave_match()
	await test.get_tree().process_frame
	var before: int = ended.sent.size()
	NetManager._request_player_identity()
	NetManager._accept_join()
	test._check(ended.sent.size() == before and not NetManager.has_session() and not NetManager.has_online_flow(),
		"a request from a session that already ended sends nothing and adopts nothing: %d packets" % (ended.sent.size() - before))
	await _teardown(test)


## The ordinary online entry follows the same rule: a hosted lobby's guest answers and is
## admitted only by the lobby's own owner.
func _r1_hosted_join_trusts_only_the_hosted_owner(test: Node) -> void:
	print("CASE: R1 a hosted guest answers and is admitted only by the proven owner of the lobby it joined")
	for scenario: String in ["proven", "other_peer"]:
		await _setup(test, "r1-hosted-" + scenario)
		_prove_owner(null, _key("r1-host"))
		if scenario == "other_peer":
			party.fake_peer_keys[NetManager.HOST_PEER_ID] = _key("r1-other-peer")
		var peer: Variant = TransportPeer.new(6)
		party.fake_join_result = {"ok": true, "peer": peer, "code": "ABCDE", "error": "", "kind": "", "context": null}
		var request := NetManager.join_by_invite("r1-hosted-connection")
		peer.connect_remote(NetManager.HOST_PEER_ID)
		var calls := _rpc_calls(peer)
		NetManager._request_player_identity()
		if scenario == "proven":
			test._check(_rpc_calls(peer) == calls + 1, "[proven] the hosted owner is answered once")
			_host_replays_and_accepts("R1 Hosted Owner")
			clock.advance(MatchmakingFlow.POLL_SECONDS)
			test._check(request.succeeded() and not NetManager.has_online_flow(), "[proven] and admits this player")
		else:
			NetManager._accept_join()
			clock.advance(MatchmakingFlow.POLL_SECONDS)
			await test.get_tree().process_frame
			test._check(_rpc_calls(peer) == calls, "[other_peer] another peer 1 is sent nothing")
			test._check(request.outcome == JoinRequest.Outcome.FAILED and request.reason == NetManager._HOST_CHANGED_BEFORE_JOIN,
				"[other_peer] and the join ends with its reason: %s" % request.reason)
		await _teardown(test)


## What only a host may send an admitted guest -- a new player's roster entry, then a running
## match, twice over -- with a watch on it. Reports whether any of it was applied and how
## many times the session ended while it arrived.
func _send_host_state(peer_id: int) -> Dictionary:
	var seen := {"applied": false, "ends": 0}
	var on_roster := func() -> void:
		if NetManager.players.has(peer_id):
			seen["applied"] = true
	var on_state := func(state: int) -> void:
		if state == NRTypes.MatchState.RUNNING:
			seen["applied"] = true
	var on_end := func() -> void:
		seen["ends"] = int(seen["ends"]) + 1
	NetManager.roster_changed.connect(on_roster)
	NetManager.match_state_changed.connect(on_state)
	NetManager.server_disconnected.connect(on_end)
	for _repeat in 2:
		var stranger := PlayerState.new()
		stranger.peer_id = peer_id
		stranger.display_name = "R1 Late Stranger"
		NetManager._receive_roster_entry(stranger.to_dict())
		NetManager._receive_match_state(NRTypes.MatchState.RUNNING)
	NetManager.roster_changed.disconnect(on_roster)
	NetManager.match_state_changed.disconnect(on_state)
	NetManager.server_disconnected.disconnect(on_end)
	if NetManager.players.has(peer_id) or NetManager.match_state == NRTypes.MatchState.RUNNING:
		seen["applied"] = true
	return seen


## Admission is not a lease on the host's authority. With the Party transport, the roster and
## the session all unchanged, a hosted lobby whose owner moved on, went away or is no longer
## connected has no host this guest answers to: peer 1's next message is not applied, and the
## session ends once with this title's reason. Before that, the proven owner's own messages
## still land. An owner PartyService never captured -- not replicated when the lobby was
## joined -- is held to the owner this session proved.
func _r1_admitted_hosted_session_proves_its_owner_at_every_message(test: Node) -> void:
	print("CASE: R1 an admitted hosted guest proves its lobby's owner at every message; a changed, cleared or disconnected owner ends the session once")
	var outcomes := {
		"owner_changed": NetManager._HOST_CHANGED,
		"owner_cleared": NetManager._HOST_CHANGED,
		"owner_cleared_uncaptured": NetManager._HOST_CHANGED,
		"owner_disconnected": NetManager._HOST_LEFT_BEFORE_JOIN,
	}
	for mutation: String in outcomes.keys():
		await _setup(test, "r1-admitted-" + mutation)
		var owner := _key("r1-host")
		_prove_owner(null, owner)
		if mutation == "owner_cleared_uncaptured":
			party.fake_hosted_owner_baseline = {}
		var peer: Variant = TransportPeer.new(6)
		party.fake_join_result = {"ok": true, "peer": peer, "code": "ABCDE", "error": "", "kind": "", "context": null}
		var request := NetManager.join_by_invite("r1-admitted-connection")
		peer.connect_remote(NetManager.HOST_PEER_ID)
		NetManager._request_player_identity()
		_host_replays_and_accepts("R1 Hosted Owner")
		clock.advance(MatchmakingFlow.POLL_SECONDS)
		test._check(request.succeeded() and NetManager.has_session(), "[%s] the hosted guest is admitted" % mutation)
		var ally := PlayerState.new()
		ally.peer_id = 4
		ally.display_name = "R1 Ally"
		NetManager._receive_roster_entry(ally.to_dict())
		test._check(NetManager.players.has(4), "[%s] the proven owner's messages still land after admission" % mutation)
		match mutation:
			"owner_changed":
				party.fake_hosted_owner = _key("r1-other-owner")
			"owner_cleared", "owner_cleared_uncaptured":
				party.fake_hosted_owner = {}
			"owner_disconnected":
				party.fake_hosted_owner_connected = false
		var seen := _send_host_state(5)
		test._check(not bool(seen["applied"]), "[%s] peer 1's roster entry and match state are not applied" % mutation)
		test._check(int(seen["ends"]) == 1 and not NetManager.has_session(),
			"[%s] and the session ends once: %d ends" % [mutation, int(seen["ends"])])
		test._check(NetManager.last_disconnect_reason == String(outcomes[mutation]),
			"[%s] with this title's reason: %s" % [mutation, NetManager.last_disconnect_reason])
		await _teardown(test)


## A hosted lobby's facts can replicate with no notice this title receives. A legitimate host
## whose owner facts are not there yet is sent nothing; once only those facts arrive -- no
## lobby notice, no transport event, no second request -- the join's own poll answers the one
## request, once, and the host's replay and acceptance complete exactly one admission.
func _r1_pending_hosted_proof_settles_from_the_join_poll(test: Node) -> void:
	print("CASE: R1 a pending hosted owner proof is retried by the join's own poll and completes one identity, replay and admission")
	await _setup(test, "r1-hosted-pending")
	var owner := _key("r1-host")
	party.fake_peer_keys[NetManager.HOST_PEER_ID] = owner.duplicate()
	party.fake_hosted_owner = {}
	party.fake_hosted_owner_baseline = {}
	var peer: Variant = TransportPeer.new(6)
	party.fake_join_result = {"ok": true, "peer": peer, "code": "ABCDE", "error": "", "kind": "", "context": null}
	var request := NetManager.join_by_invite("r1-pending-connection")
	peer.connect_remote(NetManager.HOST_PEER_ID)
	var calls := _rpc_calls(peer)
	NetManager._request_player_identity()
	clock.advance(MatchmakingFlow.POLL_SECONDS * 3.0)
	test._check(_rpc_calls(peer) == calls and request.is_pending(),
		"an owner not replicated yet is sent nothing, and the join keeps waiting: %d calls" % (_rpc_calls(peer) - calls))
	party.fake_hosted_owner = owner.duplicate()
	clock.advance(MatchmakingFlow.POLL_SECONDS)
	test._check(_rpc_calls(peer) == calls + 1,
		"once only the owner facts arrive, the join's poll answers the one request: %d calls" % (_rpc_calls(peer) - calls))
	clock.advance(MatchmakingFlow.POLL_SECONDS * 3.0)
	NetManager._on_connected_to_server()
	test._check(_rpc_calls(peer) == calls + 1, "and never a second time: %d calls" % (_rpc_calls(peer) - calls))
	_host_replays_and_accepts("R1 Hosted Owner")
	clock.advance(MatchmakingFlow.POLL_SECONDS)
	test._check(request.succeeded() and not NetManager.has_online_flow(), "the host's acceptance is one admission")
	test._check(NetManager.players.has(NetManager.HOST_PEER_ID) and NetManager.players.has(3),
		"holding the roster the host replayed: %s" % str(NetManager.players.keys()))
	await _teardown(test)


## A scoped session is held to the same rule without waiting for any loss notice. A staging
## guest whose lobby's owner changed takes nothing more from peer 1 at its next message; one
## whose owner is no longer connected is ended by the next notice about that lobby, which the
## flow's own owner check would not; an adopted rematch replacement ends at peer 1's next
## message when its arranged lobby's owner changes. Each ends once, with its reason.
func _r1_admitted_scoped_sessions_prove_their_owner_without_a_loss_notice(test: Node) -> void:
	print("CASE: R1 admitted staging and rematch sessions prove their lobby's owner at every message and notice, with no loss notice needed")
	for path: String in ["staging_message", "staging_notice", "rematch_message"]:
		await _setup(test, "r1-scoped-" + path)
		var flow: MatchmakingFlow = null
		var context: PartyService.LobbyContext = null
		var expected := ""
		if path == "rematch_message":
			_pending_rematch(test, _key(ARRANGED_OWNER_ID))
			var request: JoinRequest = NetManager._active_join_request
			NetManager._request_player_identity()
			_host_replays_and_accepts("R1 Host")
			clock.advance(MatchmakingFlow.POLL_SECONDS)
			flow = NetManager._flow
			context = party.fake_arranged
			expected = NetManager._MATCH_HOST_CHANGED
			test._check(request != null and request.succeeded() and flow != null,
				"[%s] the replacement is admitted and its rematch adopted" % path)
		else:
			flow = _staging_guest(test, 7)
			context = party.fake_staging
			expected = MatchmakingFlow.TEXT_OWNER_CHANGED if path == "staging_message" else MatchmakingFlow.TEXT_GROUP_HOST_LEFT
		if flow == null:
			await _teardown(test)
			continue
		var ally := PlayerState.new()
		ally.peer_id = 4
		ally.display_name = "R1 Ally"
		NetManager._receive_roster_entry(ally.to_dict())
		test._check(NetManager.players.has(4) and flow.is_current(), "[%s] the proven owner's messages land" % path)
		var seen: Dictionary = {}
		if path == "staging_notice":
			party.fake_set_member(context, _key("staging-owner"), false)
			NetManager._on_context_changed(context)
			test._check(flow.retired and NetManager.last_disconnect_reason == expected,
				"[%s] the notice ends the flow: %s" % [path, NetManager.last_disconnect_reason])
			seen = _send_host_state(5)
			test._check(int(seen["ends"]) == 0, "[%s] and nothing after it ends it again" % path)
		else:
			party.fake_owners[context.context_id] = _key("r1-other-owner")
			seen = _send_host_state(5)
			test._check(int(seen["ends"]) == 1 and flow.retired,
				"[%s] peer 1's next message ends the flow once: %d ends" % [path, int(seen["ends"])])
			test._check(NetManager.last_disconnect_reason == expected,
				"[%s] with its reason: %s" % [path, NetManager.last_disconnect_reason])
		test._check(not bool(seen["applied"]), "[%s] and peer 1's roster entry and match state are not applied" % path)
		await _teardown(test)


# --- R7: a match that lands on a search already let go of -------------------------------

## A stopped search whose ticket the service matches anyway, in each order the events can
## arrive: the owner's Cancel before the match, its notice before the settlement, the
## lost-race answer before or after the terminal notice, and a local timeout before a late
## match. The old group joins nothing, restores nothing and requeues nothing; it ends with its
## reason. The lost-race answer completes the cancel without any recovery: the group's ordinary
## cleanup then finishes and the lease goes with it, Party is asked for no additional recovery
## leave or reset, the account and its saves are untouched, and the next Quick Match starts
## without a restart. A match that lands before any stop is simply the group's match.
func _r7_match_after_a_stopped_search_never_starts_or_wedges(test: Node) -> void:
	print("CASE: R7 a match that overtakes a cancel or a timeout ends the old group without joining, reopening or wedging it, and asks for no reset")
	test._check(NetManager._flow_end_code(MatchmakingFlow.TEXT_MATCH_ABANDONED) == "match_abandoned",
		"a flow's end is logged under a stable key for this title's own reason")
	test._check(NetManager._flow_end_code("Injected transport words 0x80004005 for entity A1B2") == "other",
		"and never with a service's or transport's own words")
	for order: String in ["cancel_then_match", "notice_first", "event_first", "timeout_then_match", "match_then_cancel"]:
		await _setup(test, "r7-" + order)
		matchmaking.fake_cancel_waits = true
		var flow := await _searching_owner(test)
		var attempt := _attempt()
		if flow == null or attempt == null:
			await _teardown(test)
			continue
		if order == "match_then_cancel":
			party.fake_arranged_join_ok = true
			party.fake_arranged_owner = party.fake_local_key.duplicate()
			party.fake_owners[party.fake_arranged.context_id] = party.fake_local_key.duplicate()
			# A solo group's own premade is complete at once, so the match carries it straight on
			# to the fresh network it now creates.
			party.fake_arranged_peer = TransportPeer.new(NetManager.HOST_PEER_ID)
			_native_match(attempt, "r7-first")
			flow.cancel_search()
			test._check(matchmaking.fake_cancels.is_empty() and not attempt.cancel_in_flight,
				"[%s] a ticket matched before any stop is never cancelled" % order)
			test._check(flow.is_current() and party.fake_calls.has("join_arranged:arrangement-r7-first"),
				"[%s] it is the group's match, and its arrangement is joined (phase %d)" % [order, flow.phase])
			await _teardown(test)
			continue
		if order == "timeout_then_match":
			_time_out(attempt)
			test._check(flow.is_current() and flow.phase == MatchmakingFlow.Phase.CANCELLING,
				"[%s] a timed-out ticket whose cancel is owed holds the group closed (phase %d)" % [order, flow.phase])
			_native_match(attempt, "r7-late")
		else:
			flow.cancel_search()
			test._check(attempt.cancel_in_flight and flow.phase == MatchmakingFlow.Phase.CANCELLING,
				"[%s] the owner's Cancel starts a native cancel (phase %d)" % [order, flow.phase])
			_native_match(attempt, "r7-won", order == "notice_first",
				&"event_first" if order == "event_first" else &"completion_first")
		test._check(flow.retired and NetManager.last_disconnect_reason == MatchmakingFlow.TEXT_MATCH_ABANDONED,
			"[%s] the old group ends with its reason: %s" % [order, NetManager.last_disconnect_reason])
		test._check(party.fake_join_arranged_calls.is_empty(), "[%s] the match it let go of is never joined" % order)
		var control: Dictionary = party.fake_search_control.get(party.fake_staging.context_id, {})
		test._check(String(control.get("phase", "")) != MatchmakingFlow.ENVELOPE_GATHERING and matchmaking.fake_creates.size() == 1,
			"[%s] nor is the group reopened or searched again" % order)
		test._check(not attempt.cancel_in_flight and not attempt.cleanup_pending and not matchmaking.has_orphaned_matched_cancel(),
			"[%s] the lost-race answer resolves the cancel: nothing is owed" % order)
		var leaves := party.fake_calls.count("leave")
		clock.advance(MatchmakingFlow.POLL_SECONDS)
		await test.get_tree().process_frame
		test._check(not NetManager.has_online_flow() and not NetManager.has_pending_online_work(),
			"[%s] so the lease goes once the group's ordinary cleanup has finished" % order)
		clock.advance(MatchmakingFlow.CANCEL_GRACE_SECONDS * 3.0)
		await test.get_tree().process_frame
		test._check(party.fake_calls.count("leave") == leaves and not party.is_cleanup_pending(),
			"[%s] and Party is asked for no additional recovery leave or reset" % order)
		test._check(Services.is_account_ready(), "[%s] the account and its saves are untouched" % order)
		var reopened: bool = await NetManager.start_matchmaking()
		test._check(reopened, "[%s] and the next Quick Match starts without a restart: %s" % [order, NetManager.last_error])
		await _teardown(test)


## The safety net, with an injected native cancel observer that never answers. A match that
## lands on the stopped search still ends the old group with its reason and joins nothing, and
## the lease is held while the unanswered cancel is owed. An answer that arrives late, before
## the cancellation grace, needs no recovery at all: the group's ordinary cleanup then finishes
## and the lease goes with it. One that does not is handed to Party's bounded leave, whose
## confirmed reset discharges it; the account and its saves are untouched, and the next Quick
## Match starts without a restart.
func _r7_injected_unanswered_cancel_is_recovered_once(test: Node) -> void:
	print("CASE: R7 an injected unanswered cancel on a matched ticket holds the lease, and is recovered once through Party's bounded leave unless a late answer arrives first")
	for order: String in ["cancel_then_match", "timeout_then_match", "late_answer"]:
		await _setup(test, "r7-injected-" + order)
		matchmaking.fake_cancel_waits = true
		matchmaking.fault_cancel_unanswered = true
		var flow := await _searching_owner(test)
		var attempt := _attempt()
		if flow == null or attempt == null:
			await _teardown(test)
			continue
		if order == "timeout_then_match":
			_time_out(attempt)
			_native_match(attempt, "r7-injected-late")
		else:
			flow.cancel_search()
			_native_match(attempt, "r7-injected-won")
		test._check(attempt.native_terminal_notified == false and flow.is_current(),
			"[%s] with its cancel unanswered the service holds its terminal notice back" % order)
		# The ticket's native status is enough: the group reads it at its next poll.
		clock.advance(MatchmakingFlow.POLL_SECONDS)
		test._check(flow.retired and NetManager.last_disconnect_reason == MatchmakingFlow.TEXT_MATCH_ABANDONED,
			"[%s] the old group ends with its reason: %s" % [order, NetManager.last_disconnect_reason])
		test._check(party.fake_join_arranged_calls.is_empty(), "[%s] the match it let go of is never joined" % order)
		test._check(attempt.cancel_in_flight and matchmaking.has_orphaned_matched_cancel(),
			"[%s] the injected observer leaves the cancel unanswered" % order)
		test._check(NetManager.has_online_flow() and NetManager.has_pending_online_work(),
			"[%s] while the ticket's native cleanup is owed, the lease is held" % order)
		var leaves := party.fake_calls.count("leave")
		if order == "late_answer":
			_late_lost_race_answer(attempt)
			clock.advance(MatchmakingFlow.POLL_SECONDS)
			await test.get_tree().process_frame
			test._check(not NetManager.has_online_flow(), "[%s] an answer that arrives late needs no recovery: the ordinary cleanup finishes and the lease goes" % order)
			clock.advance(MatchmakingFlow.CANCEL_GRACE_SECONDS * 2.0)
			test._check(party.fake_calls.count("leave") == leaves, "[%s] with no recovery at all" % order)
		else:
			clock.advance(MatchmakingFlow.CANCEL_GRACE_SECONDS + MatchmakingFlow.POLL_SECONDS * 3.0)
			test._check(party.fake_calls.count("leave") > leaves and party.is_cleanup_pending(),
				"[%s] the unanswered cancel is handed to Party's bounded recovery" % order)
			test._check(NetManager.has_online_flow(), "[%s] and the lease stays held until that recovery is confirmed" % order)
			party.set("_recovery_required", false)
			party.multiplayer_invalidated.emit(1)
			clock.advance(MatchmakingFlow.POLL_SECONDS)
			await test.get_tree().process_frame
			test._check(not NetManager.has_online_flow() and not attempt.cancel_in_flight,
				"[%s] the confirmed reset discharges the old ticket and releases the lease" % order)
		test._check(Services.is_account_ready(), "[%s] the account and its saves are untouched" % order)
		var reopened: bool = await NetManager.start_matchmaking()
		test._check(reopened, "[%s] and the next Quick Match starts without a restart: %s" % [order, NetManager.last_error])
		await _teardown(test)


## A guest that leaves mid-search, and an owner that accepts an invitation elsewhere, have
## let the search go too: a match that lands afterwards joins nothing. The lost-race answer
## resolves the cancel, so the lease goes and the invitation is redeemed once, with no
## recovery. With an injected observer that never answers, the lease holds until Party's
## bounded recovery settles the ticket's cleanup, and the invitation waits, under the time it
## arrived with, until the old group is gone.
func _r7_leave_and_replacement_let_the_search_go(test: Node) -> void:
	print("CASE: R7 a guest's Leave and an owner's accepted invitation are binding; a later match joins nothing and wedges nothing")
	for injected: bool in [false, true]:
		var label := "injected unanswered cancel" if injected else "answered"
		await _setup(test, "r7-guest-leave-%s" % ("injected" if injected else "answered"))
		matchmaking.fake_cancel_waits = true
		matchmaking.fault_cancel_unanswered = injected
		var guest := _staging_guest(test, 7)
		var attempt := _guest_search(4, "r7-guest-ticket", 300000)
		test._check(attempt != null and guest.phase == MatchmakingFlow.Phase.SEARCHING,
			"[%s] the guest has joined the owner's ticket (phase %d)" % [label, guest.phase])
		if attempt != null:
			NetManager.leave_match()
			test._check(guest.retired and attempt.cancel_in_flight and NetManager.has_online_flow(),
				"[%s] its Leave retires the flow and starts the ticket's native cancel, with the lease still held" % label)
			_native_match(attempt, "r7-after-leave")
			test._check(party.fake_join_arranged_calls.is_empty(), "[%s] a match landing after the Leave is never joined" % label)
			var leaves := party.fake_calls.count("leave")
			if injected:
				clock.advance(MatchmakingFlow.CANCEL_GRACE_SECONDS + MatchmakingFlow.POLL_SECONDS * 3.0)
				test._check(party.fake_calls.count("leave") > leaves,
					"[%s] the unanswered cancel is handed to Party's bounded recovery" % label)
				party.set("_recovery_required", false)
				party.multiplayer_invalidated.emit(1)
				clock.advance(MatchmakingFlow.POLL_SECONDS)
				await test.get_tree().process_frame
				test._check(not NetManager.has_online_flow(), "[%s] and the confirmed reset releases the lease" % label)
			else:
				clock.advance(MatchmakingFlow.POLL_SECONDS)
				await test.get_tree().process_frame
				test._check(not NetManager.has_online_flow(), "[%s] after the lost-race answer the ordinary cleanup finishes and the lease goes" % label)
				clock.advance(MatchmakingFlow.CANCEL_GRACE_SECONDS * 3.0)
				test._check(party.fake_calls.count("leave") == leaves, "[%s] with no recovery at all" % label)
		await _teardown(test)

		await _setup(test, "r7-replacement-%s" % ("injected" if injected else "answered"))
		ScreenManager.set_container(test)
		matchmaking.fake_cancel_waits = true
		matchmaking.fault_cancel_unanswered = injected
		var flow := await _searching_owner(test)
		var owned := _attempt()
		if flow != null and owned != null:
			var menu := NRScreen.new()
			menu.scene_file_path = ScreenManager.MAIN_MENU
			ScreenManager._stack.append(menu)
			party.fake_join_result = {"ok": false, "error": "Injected join failure.", "kind": "", "context": null, "peer": null, "code": ""}
			InviteRouter._on_join_requested({"connection_string": "r7-invite"})
			for _frame in 3:
				await test.get_tree().process_frame
			var dialog: Variant = ScreenManager.current_screen()
			if dialog != null and dialog.has_signal("dismissed"):
				dialog.dismissed.emit(true)
			for _frame in 3:
				await test.get_tree().process_frame
			test._check(flow.retired and owned.cancel_in_flight, "[%s] accepting the invitation is the group's binding Leave" % label)
			_native_match(owned, "r7-after-invite")
			test._check(party.fake_join_arranged_calls.is_empty(), "[%s] a match landing then is never joined" % label)
			if injected:
				clock.advance(MatchmakingFlow.CANCEL_GRACE_SECONDS + MatchmakingFlow.POLL_SECONDS * 3.0)
				for _frame in 2:
					await test.get_tree().process_frame
				test._check(InviteRouter.has_pending_invite() and not party.fake_calls.has("join_by_connection_string"),
					"[%s] the invitation is kept, not joined, while the old ticket is owed" % label)
				party.set("_recovery_required", false)
				party.multiplayer_invalidated.emit(1)
			clock.advance(MatchmakingFlow.POLL_SECONDS)
			for _frame in 3:
				await test.get_tree().process_frame
			test._check(not NetManager.has_online_flow() and party.fake_calls.count("join_by_connection_string") == 1,
				"[%s] once the lease is released, the invitation is redeemed once: %d joins" % [label, party.fake_calls.count("join_by_connection_string")])
			if not injected:
				test._check(not party.is_cleanup_pending(), "[%s] and no recovery was asked for" % label)
			var failed: Variant = ScreenManager.current_screen()
			if failed != null and failed.scene_file_path == ScreenManager.DIALOG_BOX:
				failed._ok_button.pressed.emit()
			await test.get_tree().process_frame
			ScreenManager._stack.erase(menu)
			menu.queue_free()
		ScreenManager.clear()
		await _teardown(test)


## Quitting just after a match overtook a cancel. Answered, the lost race needs no recovery:
## once the group's ordinary cleanup has finished there is nothing to drain, and the quit exits
## at once. With an injected observer that never answers, the drain waits on that cleanup like
## any other, bounded by the one quit budget, and the exit happens once.
func _r7_quit_is_bounded_while_a_cancel_is_unanswered(test: Node) -> void:
	print("CASE: R7 quitting after a match overtook a cancel exits at once when the race is answered, and once within the one quit budget when an injected cancel is not")
	for injected: bool in [false, true]:
		var label := "injected unanswered cancel" if injected else "answered"
		await _setup(test, "r7-quit-%s" % ("injected" if injected else "answered"))
		matchmaking.fake_cancel_waits = true
		matchmaking.fault_cancel_unanswered = injected
		var flow := await _searching_owner(test)
		var attempt := _attempt()
		if flow == null or attempt == null:
			await _teardown(test)
			continue
		flow.cancel_search()
		_native_match(attempt, "r7-quit")
		if not injected:
			clock.advance(MatchmakingFlow.POLL_SECONDS)
			await test.get_tree().process_frame
			test._check(flow.retired and not NetManager.has_pending_online_work(),
				"[%s] once the group's ordinary cleanup has finished, the answered race leaves no online work to drain" % label)
			var quit_now := _open_quit_probe(test)
			quit_now.request_shutdown()
			test._check(quit_now.quit_calls == 1 and not quit_now._quit_pending, "[%s] and the quit exits at once" % label)
			test._check(not party.is_cleanup_pending(), "[%s] asking for no reset" % label)
			await _end_rb2_case(test, quit_now)
			continue
		# The service holds the notice of a match whose cancel is unanswered; the group reads the
		# ticket's native status at its next poll.
		clock.advance(MatchmakingFlow.POLL_SECONDS)
		test._check(flow.retired and NetManager.has_pending_online_work(),
			"[%s] the abandoned group's unanswered cancel counts as online work to drain" % label)
		var app := _open_quit_probe(test)
		app.request_shutdown()
		var budget: int = app._quit_deadline_msec
		test._check(app._quit_pending and app.quit_calls == 0, "[%s] the quit waits in the drain" % label)
		clock.advance(float(budget - clock.now_msec()) / 1000.0 + PartyService.POLL_INTERVAL)
		test._check(app.quit_calls == 1, "[%s] and exits once, no later than its budget: %d exits" % [label, app.quit_calls])
		party.set("_recovery_required", false)
		party.multiplayer_invalidated.emit(1)
		clock.advance(MatchmakingFlow.POLL_SECONDS)
		await _end_rb2_case(test, app)


## An injected cancel observer that never answers, and then a Party recovery of it that fails:
## the runtime needs a restart. The old group joins nothing and searches nothing again. The
## lease stays held, so nothing that cleanup guarded is released, and no further reset is
## asked for. Every entry the lease refuses -- Quick Match, Host, Join, Practice and an
## invitation -- says the restart is needed rather than that something is still finishing,
## while the outcome that ended the group stays what it was. The quit still exits once, on
## its budget.
func _r7_failed_recovery_is_terminal_and_keeps_the_lease(test: Node) -> void:
	print("CASE: R7 a failed recovery of an injected unanswered cancel keeps the lease, stops asking, reports the restart it needs, and quits once")
	await _setup(test, "r7-failed-recovery")
	ScreenManager.set_container(test)
	matchmaking.fake_cancel_waits = true
	matchmaking.fault_cancel_unanswered = true
	var flow := await _searching_owner(test)
	var attempt := _attempt()
	if flow == null or attempt == null:
		ScreenManager.clear()
		await _teardown(test)
		return
	flow.cancel_search()
	_native_match(attempt, "r7-failed")
	# The group reads the ticket's native status at its next poll and ends there.
	clock.advance(MatchmakingFlow.POLL_SECONDS)
	test._check(flow.retired, "the match ends the group at its next poll, with its cancel still unanswered")
	var leaves := party.fake_calls.count("leave")
	clock.advance(MatchmakingFlow.CANCEL_GRACE_SECONDS + MatchmakingFlow.POLL_SECONDS * 3.0)
	test._check(party.fake_calls.count("leave") == leaves + 1 and party.is_cleanup_pending(),
		"the unanswered cancel is handed to Party's bounded recovery once")
	# The scoped shutdown fails: Party latches its restart-required reason and reports it.
	party.recovery_error = PartyService.RECOVERY_FAILED
	NetManager._on_party_cleanup_status(PartyService.RECOVERY_FAILED)
	test._check(flow.cleanup_error == PartyService.RECOVERY_FAILED
		and String(NetManager.flow_snapshot().get("cleanup_error", "")) == PartyService.RECOVERY_FAILED,
		"the retired flow reports the restart the failure needs")
	test._check(NetManager.last_disconnect_reason == MatchmakingFlow.TEXT_MATCH_ABANDONED,
		"while the outcome that ended the group stays its own: %s" % NetManager.last_disconnect_reason)
	clock.advance(MatchmakingFlow.CANCEL_GRACE_SECONDS * 4.0)
	test._check(party.fake_calls.count("leave") == leaves + 1,
		"no further reset is asked for once the failure is terminal: %d" % (party.fake_calls.count("leave") - leaves))
	test._check(NetManager.has_online_flow() and NetManager.has_pending_online_work() and attempt.cancel_in_flight,
		"the lease stays held over the cancel that is still unanswered")
	test._check(party.fake_join_arranged_calls.is_empty() and matchmaking.fake_creates.size() == 1,
		"the match it let go of is never joined, and nothing is searched again")
	var matchmaking_started: bool = await NetManager.start_matchmaking()
	test._check(not matchmaking_started and NetManager.last_error == PartyService.RECOVERY_FAILED,
		"Quick Match is refused with the restart it needs: %s" % NetManager.last_error)
	var hosted: bool = await NetManager.host_match()
	test._check(not hosted and NetManager.last_error == PartyService.RECOVERY_FAILED,
		"so is Host Match: %s" % NetManager.last_error)
	test._check(not NetManager.start_offline() and NetManager.last_error == PartyService.RECOVERY_FAILED,
		"and Practice, which the lease also holds: %s" % NetManager.last_error)
	var refused_join := NetManager.join_by_invite("r7-failed-join")
	test._check(refused_join.outcome == JoinRequest.Outcome.FAILED and refused_join.reason == PartyService.RECOVERY_FAILED,
		"a join gives the same reason: %s" % refused_join.reason)
	var menu := NRScreen.new()
	menu.scene_file_path = ScreenManager.MAIN_MENU
	ScreenManager._stack.append(menu)
	InviteRouter._on_join_requested({"connection_string": "r7-failed-invite"})
	for _frame in 3:
		await test.get_tree().process_frame
	var refusal: Variant = ScreenManager.current_screen()
	var shown: bool = refusal != null and refusal.scene_file_path == ScreenManager.DIALOG_BOX
	test._check(shown and refusal._message == PartyService.RECOVERY_FAILED,
		"an invitation is answered with it too: %s" % (refusal._message if shown else "no dialog"))
	test._check(not InviteRouter.has_pending_invite() and not party.fake_calls.has("join_by_connection_string"),
		"and is not kept for a release that will not come")
	if shown:
		refusal._ok_button.pressed.emit()
	for _frame in 2:
		await test.get_tree().process_frame
	ScreenManager._stack.erase(menu)
	menu.queue_free()
	ScreenManager.clear()
	var app := _open_quit_probe(test)
	app.request_shutdown()
	var budget: int = app._quit_deadline_msec
	test._check(app._quit_pending and app.quit_calls == 0, "the quit waits in the drain")
	clock.advance(float(budget - clock.now_msec()) / 1000.0 + PartyService.POLL_INTERVAL)
	test._check(app.quit_calls == 1, "and exits once, no later than its budget: %d exits" % app.quit_calls)
	# The case is over. What the failure latched belongs to a runtime a restart discards.
	party.recovery_error = ""
	party.set("_recovery_required", false)
	matchmaking.multiplayer_invalidated(2)
	clock.advance(MatchmakingFlow.POLL_SECONDS)
	await _end_rb2_case(test, app)


# --- F11: guest replay, owner answers, destinations ------------------------------------------

func _f11_guest_reducer_replays_missed_state(test: Node) -> void:
	print("CASE: F11 a guest adopts missed owner state from the snapshot and a correlated reply, joins once, and never extends the budget")
	await _setup(test, "f11-searching")
	var group: Array[Dictionary] = [party.fake_local_key.duplicate(), _key("staging-owner")]
	party.fake_search_control[party.fake_staging.context_id] = {
		"valid": true, "schema": PartyService.SEARCH_CONTROL_SCHEMA, "epoch": 3,
		"phase": MatchmakingFlow.ENVELOPE_SEARCHING, "group": group, "ticket_id": "ticket-f11",
		"reason_code": "", "reason": "",
	}
	var flow := _staging_guest(test, 7)
	test._check(flow.synced and flow.phase == MatchmakingFlow.Phase.JOINING_TICKET and flow.epoch == 3,
		"the snapshot alone moves the guest into the owner's search (phase %d, epoch %d)" % [flow.phase, flow.epoch])
	test._check(matchmaking.fake_joins.is_empty() and flow._sync_pending_id > 0,
		"without a budget it asks the owner instead of inventing one")
	var sent_at := flow._sync_sent_msec
	var request_id := flow._sync_pending_id
	clock.advance(2.0)
	NetManager._receive_flow_phase(3, MatchmakingFlow.Phase.SEARCHING, {"request_id": request_id + 1, "remaining_ms": 400000})
	test._check(matchmaking.fake_joins.is_empty(), "an unmatched reply is ignored")
	NetManager._receive_flow_phase(3, MatchmakingFlow.Phase.SEARCHING, {"request_id": request_id, "remaining_ms": 400000})
	test._check(matchmaking.fake_joins.size() == 1, "the correlated reply lets it join the owner's ticket")
	test._check(flow.search_deadline_msec == sent_at + 400000,
		"its budget is anchored to when the request was sent: %d, expected %d" % [flow.search_deadline_msec, sent_at + 400000])
	NetManager._receive_flow_phase(3, MatchmakingFlow.Phase.SEARCHING, {"remaining_ms": 500000})
	test._check(matchmaking.fake_joins.size() == 1, "a later broadcast does not join again")
	test._check(flow.search_deadline_msec == sent_at + 400000, "nor extend the budget: %d" % flow.search_deadline_msec)
	NetManager._receive_flow_phase(3, MatchmakingFlow.Phase.FREEZING, {})
	test._check(flow.phase != MatchmakingFlow.Phase.FREEZING, "a reordered freeze does not move it back (phase %d)" % flow.phase)
	await _teardown(test)

	await _setup(test, "f11-gathering")
	party.fake_search_control[party.fake_staging.context_id] = {
		"valid": true, "schema": PartyService.SEARCH_CONTROL_SCHEMA, "epoch": 2,
		"phase": MatchmakingFlow.ENVELOPE_GATHERING, "group": [], "ticket_id": "",
		"reason_code": String(MatchmakingFlow.REASON_PRIVATE_FAILED), "reason": MatchmakingFlow.TEXT_PRIVATE_FAILED,
	}
	var restored := _staging_guest(test, 7)
	test._check(restored.synced and restored.phase == MatchmakingFlow.Phase.GATHERING,
		"a gathering envelope establishes the guest's state (phase %d)" % restored.phase)
	test._check(restored.reason == MatchmakingFlow.TEXT_PRIVATE_FAILED, "with the retained outcome: '%s'" % restored.reason)
	test._check(NetManager.can_customize(), "and Ready is offered")
	await _teardown(test)

	await _setup(test, "f11-silent")
	var entering := _staging_guest(test, 7)
	test._check(not entering.synced and not NetManager.can_customize() and entering._sync_pending_id > 0,
		"with nothing to go on, Ready waits for the owner's answer")
	NetManager._receive_flow_phase(0, MatchmakingFlow.Phase.GATHERING, {})
	test._check(not entering.synced, "an unsolicited epoch-zero broadcast establishes nothing")
	NetManager._receive_flow_phase(0, MatchmakingFlow.Phase.GATHERING, {"request_id": entering._sync_pending_id})
	test._check(entering.synced and NetManager.can_customize(), "the owner's correlated answer establishes the initial gathering")
	await _teardown(test)

	await _setup(test, "f11-timeout")
	var waiting := _staging_guest(test, 7)
	clock.advance(MatchmakingFlow.SYNC_SECONDS - 0.1)
	test._check(waiting.is_current() and not waiting.synced, "still waiting just short of 15 seconds")
	clock.advance(0.1)
	test._check(waiting.retired and NetManager.last_disconnect_reason == MatchmakingFlow.TEXT_HOST_SILENT,
		"an owner that never answers ends the entry: %s" % NetManager.last_disconnect_reason)
	await _teardown(test)

	await _setup(test, "f11-outsider")
	var others: Array[Dictionary] = [_key("staging-owner"), _key("someone-else")]
	party.fake_search_control[party.fake_staging.context_id] = {
		"valid": true, "schema": PartyService.SEARCH_CONTROL_SCHEMA, "epoch": 1,
		"phase": MatchmakingFlow.ENVELOPE_SEARCHING, "group": others, "ticket_id": "ticket-closed",
		"reason_code": "", "reason": "",
	}
	var outsider := _staging_guest(test, 7)
	NetManager._receive_flow_phase(1, MatchmakingFlow.Phase.SEARCHING, {"remaining_ms": 300000})
	test._check(matchmaking.fake_joins.is_empty() and outsider.ticket == null,
		"a member outside the frozen group never joins that ticket")
	await _teardown(test)


func _f11_owner_answers_state_requests(test: Node) -> void:
	print("CASE: F11 the staging owner's decision body answers a proven member's state request once, with its remaining budget, and nobody else; a later member under a reused peer id starts afresh")
	await _setup(test, "f11-owner")
	var staging_peer: Variant = TransportPeer.new(NetManager.HOST_PEER_ID)
	party.fake_staging_peer = staging_peer
	var flow := await _searching_owner(test)
	if flow == null:
		await _teardown(test)
		return
	_add_guest(7, "f11-guest")
	staging_peer.connect_remote(7)
	staging_peer.connect_remote(9)
	var sent: int = staging_peer.sent.size()
	NetManager._flow_answer_state_request(7, 1)
	test._check(staging_peer.sent.size() == sent + 1, "a proven member's request is answered: %d packets" % (staging_peer.sent.size() - sent))
	NetManager._flow_answer_state_request(7, 1)
	test._check(staging_peer.sent.size() == sent + 1, "the same request id is not answered twice")
	NetManager._flow_answer_state_request(9, 1)
	test._check(staging_peer.sent.size() == sent + 1, "a peer that is not a proven member is not answered")
	var replay := flow.replay_state()
	var detail: Dictionary = replay.get("detail", {})
	test._check(int(replay.get("phase", -1)) == MatchmakingFlow.Phase.SEARCHING and int(detail.get("remaining_ms", -1)) > 0,
		"the answer is the owner's search with the time it has left: %s" % str(replay))
	staging_peer.disconnect_remote(7)
	test._check(not NetManager._flow_state_answers.has(7), "a departed guest's replay dedup leaves with it")
	party.fake_remove_member(party.fake_staging, _key("f11-guest"))
	_add_guest(7, "f11-new-guest")
	staging_peer.connect_remote(7)
	sent = staging_peer.sent.size()
	NetManager._flow_answer_state_request(7, 1)
	test._check(staging_peer.sent.size() == sent + 1,
		"a new member seated under the same peer id has its first request answered: %d packets" % (staging_peer.sent.size() - sent))
	NetManager._flow_answer_state_request(7, 1)
	test._check(staging_peer.sent.size() == sent + 1, "and its own repeat is still deduplicated")
	party.fake_peer_keys[7] = _key("f11-guest")
	NetManager._flow_answer_state_request(7, 2)
	test._check(staging_peer.sent.size() == sent + 1, "a request proving the departed member's key revives nothing")
	await _teardown(test)


func _f11_invite_destinations_and_exact_credentials(test: Node) -> void:
	print("CASE: F11 an invite into the lobby already held is acknowledged without teardown, and a supplied credential reaches the join exactly, once")
	await _setup(test, "f11-duplicate")
	ScreenManager.set_container(test)
	var flow := await _open_group(test)
	if flow == null:
		await _teardown(test)
		return
	var menu := NRScreen.new()
	menu.scene_file_path = ScreenManager.MAIN_MENU
	ScreenManager._stack.append(menu)
	party.fake_calls.clear()
	InviteRouter._on_join_requested({"connection_string": STAGING_CONNECTION})
	test._check(ScreenManager.current_screen() == menu, "no confirmation is asked for the group this player is already in")
	test._check(flow.is_current() and NetManager.is_online_flow_live(), "and the group is not torn down")
	test._check(not party.fake_calls.has("join_by_connection_string"), "nor rejoined")
	test._check(not InviteRouter._joining and not InviteRouter.has_pending_invite(), "the duplicate is spent")
	ScreenManager._stack.erase(menu)
	menu.queue_free()
	ScreenManager.clear()
	await _teardown(test)

	await _setup(test, "f11-exact")
	ScreenManager.set_container(test)
	var exact := "cv2:7f94a95e.r-20260323|441014|kv1:7cGx+uLs/yOs%3a="
	party.fake_join_result = {"ok": false, "error": "Injected join failure.", "kind": "", "context": null, "peer": null, "code": ""}
	var start := NRScreen.new()
	start.scene_file_path = ScreenManager.MAIN_MENU
	ScreenManager._stack.append(start)
	InviteRouter._on_join_requested({"connection_string": exact, "xuid": "2535412345678901"})
	for _frame in 5:
		await test.get_tree().process_frame
	clock.advance(MatchmakingFlow.POLL_SECONDS)
	await test.get_tree().process_frame
	test._check(party.fake_last_connection_string == exact,
		"the credential reached the join unchanged: '%s'" % party.fake_last_connection_string)
	test._check(party.fake_calls.count("join_by_connection_string") == 1,
		"a supplied credential that fails is not retried another way: %d joins" % party.fake_calls.count("join_by_connection_string"))
	var failed: Variant = ScreenManager.current_screen()
	if failed != null and failed.scene_file_path == ScreenManager.DIALOG_BOX:
		failed._ok_button.pressed.emit()
	await test.get_tree().process_frame
	ScreenManager._stack.erase(start)
	start.queue_free()
	ScreenManager.clear()
	await _teardown(test)


# --- F14 / C-AUTO / C-CONSENT / C-PRIVATE / C-REMATCH: a full group's private match -----------

const _P4_GUESTS := ["p4-b", "p4-c", "p4-d"]
const _P4_PEERS := [5, 6, 7]
const _PRIVATE_SESSION := "0123456789abcdef0123456789abcdef"
const _PRIVATE_CONNECTION := "cv2:9c1d4b.r-20260929|551027|kv1:Pr1v+aTe/Zq%3a="


## A full group of four gathering: this player and three admitted members on a staging
## transport that records what reaches each of them, every one unready. Null when the group did
## not open.
func _full_group(test: Node, account: String) -> MatchmakingFlow:
	await _setup(test, account)
	party.fake_staging_peer = TransportPeer.new(NetManager.HOST_PEER_ID)
	var flow := await _open_group(test)
	if flow == null:
		return null
	for index in _P4_GUESTS.size():
		var peer_id := int(_P4_PEERS[index])
		_add_guest(peer_id, String(_P4_GUESTS[index]))
		party.fake_staging_peer.connect_remote(peer_id)
	NetManager.roster_changed.emit()
	return flow


## The same group with every member's Ready given to it as it is now: its owner has just started
## the private match -- the private envelope posted and the lobby locked -- and waits for the
## members' acknowledgements.
func _private_group(test: Node, account: String) -> MatchmakingFlow:
	var flow := await _full_group(test, account)
	if flow == null:
		return null
	_ready_all()
	test._check(flow.phase == MatchmakingFlow.Phase.PRIVATE_PREPARING and party.fake_calls.has("post:private")
		and party.fake_calls.has("lock:true") and not NetManager.is_accepting_joins(),
		"[%s] the full group, all ready, starts its private match: envelope posted, lobby locked, admission closed (phase %d)" % [account, flow.phase])
	return flow


## Every remote member of the private start reports `reported` for the current attempt, then
## one poll runs.
func _ack_private(flow: MatchmakingFlow, reported: int) -> void:
	for peer_id: int in flow.frozen_peers.keys():
		if peer_id != NetManager.HOST_PEER_ID:
			flow.on_member_report(peer_id, flow.epoch, reported)
	clock.advance(MatchmakingFlow.POLL_SECONDS)


## Takes the private group's start through the switch and every member's acknowledgement of it
## to the commit: the first match is starting.
func _commit_private_group(test: Node, flow: MatchmakingFlow, label: String) -> bool:
	_ack_private(flow, MatchmakingFlow.Phase.PRIVATE_PREPARING)
	_ack_private(flow, MatchmakingFlow.Phase.COMMITTING_START)
	var committed: bool = flow.is_current() and flow.phase == MatchmakingFlow.Phase.COMMITTING_START \
		and NetManager.match_state == NRTypes.MatchState.STARTING
	test._check(committed, "[%s] the private start commits and the first match is starting (phase %d): %s" % [
		label, flow.phase, NetManager.last_disconnect_reason])
	return committed


func _is_ready(peer_id: int) -> bool:
	var state: PlayerState = NetManager.players.get(peer_id, null)
	return state != null and state.is_ready


## The group a private start that could not be made is left in: gathering again with its reason,
## every member unready, the lobby unlocked -- by the service's own restoration once the switch
## was asked for, by the group's own unlock before -- and admission and activity open again.
## Nothing was taken on as a play session.
func _expect_private_restored(test: Node, flow: MatchmakingFlow, label: String, text: String, via_service: bool) -> void:
	_complete_activity()
	var unready := true
	for peer_id: int in NetManager.players:
		unready = unready and not (NetManager.players[peer_id] as PlayerState).is_ready
	test._check(flow.is_current() and flow.phase == MatchmakingFlow.Phase.GATHERING and flow.reason == text and unready,
		"[%s] the group gathers again, unready, with its reason: '%s' (phase %d)" % [label, flow.reason, flow.phase])
	test._check(NetManager.is_accepting_joins() and not bool(party.fake_locked.get(party.fake_staging.context_id, true))
		and NetManager._platform.wants_activity(),
		"[%s] unlocked, admitting and advertised again" % label)
	test._check(party.fake_calls.has("restore_private") == via_service and party.fake_calls.has("lock:false") != via_service,
		"[%s] restored by %s" % [label, "the service's own restoration" if via_service else "the group's own unlock"])
	test._check(flow.staging_context == party.fake_staging and flow.play_context == null and flow.session_origin == &"",
		"[%s] nothing was taken on as a play session" % label)


## A full group never reaches a ticket. When the switch of its lobby to a private match was refused
## with nothing left outstanding -- it failed, the lobby changed under it, or the group was not
## sealed for it -- the service's own restoration puts the group back, and every member is left
## the way a stopped search leaves it: unready, unlocked, reopened and advertised, the reason
## carried in the envelope to every member, and nothing searched or retried on its own. A switch
## refused because another change of the lobby was still under way cannot be undone at once; that
## ends the group instead (see _c_private_restores_or_ends_cleanly()).
func _f14_full_group_failed_private_start_restores_everyone_honestly(test: Node) -> void:
	print("CASE: F14/C-PRIVATE a full group whose private start was refused with nothing outstanding is restored through the service's restoration; it never searches or retries")
	for form: String in ["failed", "changed", "unsealed"]:
		var flow := await _private_group(test, "f14-" + form)
		if flow == null:
			await _teardown(test)
			continue
		party.fake_promote_result = form
		_ack_private(flow, MatchmakingFlow.Phase.PRIVATE_PREPARING)
		var asked: String = String((party.fake_promote_calls[0] as Dictionary).get("session_id", "")) if not party.fake_promote_calls.is_empty() else ""
		test._check(party.fake_calls.count("promote") == 1 and asked.length() == 32
			and party.fake_restore_private_calls == [asked],
			"[%s] a switch that did not succeed is followed by the service's restoration of that same session" % form)
		_expect_private_restored(test, flow, form, MatchmakingFlow.TEXT_PRIVATE_FAILED, true)
		test._check(flow.reason_code == MatchmakingFlow.REASON_PRIVATE_FAILED,
			"[%s] the outcome is the title's own: %s" % [form, flow.reason_code])
		var control: Dictionary = party.fake_search_control.get(party.fake_staging.context_id, {})
		test._check(String(control.get("phase", "")) == MatchmakingFlow.ENVELOPE_GATHERING
			and String(control.get("reason", "")) == flow.reason,
			"[%s] the envelope says the group is gathering and carries the reason: '%s'" % [form, String(control.get("reason", ""))])
		test._check(matchmaking.fake_creates.is_empty() and party.fake_calls.count("promote") == 1,
			"[%s] nothing is searched and nothing retried automatically" % form)
		await _teardown(test)


## Readiness is consent to the group as it is. Every change of who is in it -- a join, a
## departure, one member swapped for another -- makes everyone unready under a new attempt number,
## and a member's Ready counts only once that member has acknowledged the change. A Ready given
## before the acknowledgement is refused, however it is ordered against the reset; stale, future
## and repeated acknowledgements change nothing. A group that grows to four never starts privately
## on readiness given at three, and one that shrinks to three never searches on readiness it gave
## at four. A member's own lobby connection coming and going is not a change of who is in it.
func _c_consent_every_change_resets_readiness(test: Node) -> void:
	print("CASE: C-CONSENT every change of who is in the group resets readiness; a Ready counts only after the change is acknowledged; 3 to 4 and 4 to 3 never start on old readiness")
	await _setup(test, "c-consent")
	var flow := await _open_group(test)
	if flow == null:
		await _teardown(test)
		return
	_add_guest(5, "cc-b")
	_add_guest(6, "cc-c")
	NetManager.roster_changed.emit()
	var three := flow.epoch
	_consent_all()
	NetManager._apply_ready_state(5, true)
	NetManager._apply_ready_state(6, true)
	test._check(_is_ready(5) and _is_ready(6) and flow.phase == MatchmakingFlow.Phase.GATHERING,
		"members that acknowledged the group of three are ready; the owner is not, so nothing starts")
	_add_guest(8, "cc-d")
	NetManager.roster_changed.emit()
	test._check(flow.epoch == three + 1 and not _is_ready(5) and not _is_ready(6) and flow.gathering_acks.is_empty(),
		"[3 to 4] a fourth member joining is a new attempt: everyone is unready and no acknowledgement stands (epoch %d)" % flow.epoch)
	# A Ready sent before its sender saw the change reaches the owner first, on the same ordered
	# channel as that sender's acknowledgement of it.
	NetManager._apply_ready_state(5, true)
	test._check(not _is_ready(5), "[stale Ready] a Ready given before the member acknowledged the change is refused")
	flow.on_member_report(5, flow.epoch - 1, MatchmakingFlow.Phase.GATHERING)
	flow.on_member_report(5, flow.epoch + 1, MatchmakingFlow.Phase.GATHERING)
	test._check(not flow.gathering_acks.has(5), "[acknowledgements] one for an earlier or a later group records nothing")
	flow.on_member_report(5, flow.epoch, MatchmakingFlow.Phase.GATHERING)
	flow.on_member_report(5, flow.epoch, MatchmakingFlow.Phase.GATHERING)
	test._check(int(flow.gathering_acks.get(5, -1)) == flow.epoch and flow.gathering_acks.size() == 1,
		"[acknowledgements] the current one is recorded once, however often it arrives")
	NetManager._apply_ready_state(5, true)
	test._check(_is_ready(5), "[ack then Ready] once the member acknowledged the change, its next Ready counts")
	NetManager._apply_ready_state(6, true)
	NetManager._apply_ready_state(8, true)
	NetManager.set_local_ready(true)
	test._check(flow.phase == MatchmakingFlow.Phase.GATHERING and not _is_ready(6) and not _is_ready(8)
		and matchmaking.fake_creates.is_empty() and not party.fake_calls.has("promote"),
		"[3 to 4] with two members' consent to the four still missing, nothing starts: no ticket and no private match")
	NetManager.players.erase(8)
	_remove_member(party.fake_staging, "cc-d")
	NetManager.roster_changed.emit()
	test._check(not _is_ready(5) and not NetManager.local_player().is_ready and flow.phase == MatchmakingFlow.Phase.GATHERING
		and matchmaking.fake_creates.is_empty(),
		"[4 to 3] the group back to three is unready again and never searches on the readiness it gave at four")
	_ready_all()
	_ack_all(flow)
	test._check(matchmaking.fake_creates.size() == 1 and _members(matchmaking.fake_creates[0]) == 3,
		"[4 to 3] once the three acknowledge and ready again, they search as three")
	_finish(_attempt(), MatchmakingService.Outcome.NO_MATCH)
	_complete_activity()
	_consent_all()
	NetManager._apply_ready_state(5, true)
	NetManager._apply_ready_state(6, true)
	var before_swap := flow.epoch
	NetManager.players.erase(6)
	_remove_member(party.fake_staging, "cc-c")
	_add_guest(9, "cc-e")
	NetManager.roster_changed.emit()
	test._check(flow.epoch == before_swap + 1 and not _is_ready(5),
		"[swap] one member swapped for another is a change of who is in the group: everyone is unready again")
	_consent_all()
	NetManager._apply_ready_state(5, true)
	var before_flap := flow.epoch
	var properties := {MatchmakingService.PROTOCOL_MEMBER_KEY: NRProtocol.version_string()}
	party.fake_set_member(party.fake_staging, _key("cc-b"), false, properties)
	NetManager._on_context_changed(party.fake_staging)
	party.fake_set_member(party.fake_staging, _key("cc-b"), true, properties)
	NetManager._on_context_changed(party.fake_staging)
	test._check(flow.epoch == before_flap and _is_ready(5),
		"[connection] a member's lobby connection coming and going resets nobody")
	await _teardown(test)


## A member acknowledges each Gathering it adopts and each of its owner's own Gathering messages,
## and never sends an earlier Ready again: after the group changes, the owner's reset lands and
## only the player readying again counts.
func _c_consent_member_acknowledges_and_never_resends_ready(test: Node) -> void:
	print("CASE: C-CONSENT a member acknowledges each of its owner's Gathering messages and never resends an earlier Ready")
	await _setup(test, "c-consent-member")
	var flow := _staging_guest(test, 7)
	var peer: Variant = NetManager._peer
	NetManager._register_local_player(7)
	var before := _calls_to(peer, NetManager.HOST_PEER_ID)
	NetManager._receive_flow_phase(3, MatchmakingFlow.Phase.GATHERING, {})
	test._check(flow.epoch == 3 and flow.phase == MatchmakingFlow.Phase.GATHERING
		and _calls_to(peer, NetManager.HOST_PEER_ID) == before + 1,
		"the member adopts the group's Gathering and acknowledges it once: %d calls" % (_calls_to(peer, NetManager.HOST_PEER_ID) - before))
	NetManager.set_local_ready(true)
	var readied := _calls_to(peer, NetManager.HOST_PEER_ID)
	test._check(readied == before + 2 and NetManager.local_player().is_ready, "its player readies: one Ready is sent")
	NetManager._receive_ready_state(7, false)
	NetManager._receive_flow_phase(4, MatchmakingFlow.Phase.GATHERING, {})
	test._check(flow.epoch == 4 and not NetManager.local_player().is_ready
		and _calls_to(peer, NetManager.HOST_PEER_ID) == readied + 1,
		"the group changed: the reset lands and the change is acknowledged once: %d calls" % (
			_calls_to(peer, NetManager.HOST_PEER_ID) - readied))
	NetManager._receive_flow_phase(4, MatchmakingFlow.Phase.GATHERING, {})
	NetManager._receive_flow_phase(3, MatchmakingFlow.Phase.GATHERING, {})
	test._check(flow.epoch == 4 and not NetManager.local_player().is_ready
		and _calls_to(peer, NetManager.HOST_PEER_ID) == readied + 2,
		"the owner's own Gathering again is acknowledged again, an earlier one is not, and the earlier Ready is never sent: %d calls" % (
			_calls_to(peer, NetManager.HOST_PEER_ID) - readied))
	await _teardown(test)


## A private start that cannot be made never falls back to a search, and never leaves a lobby
## it cannot prove. Before the lobby's switch is asked for, a missing acknowledgement, a lock that
## is not confirmed, a member leaving or the owner's Cancel restore the group itself. Once the
## switch is asked for Cancel no longer applies; a failure, a member leaving meanwhile or the
## commit's acknowledgements running out of budget are undone only through the service's
## restoration, and an answer it cannot prove -- a switch whose completion is still owed, one
## refused while another change of the lobby was still under way, a restoration that fails --
## ends the group through the ordinary cleanup, as leaving does. A player lost after the commit
## ends the first match, never a smaller one.
func _c_private_restores_or_ends_cleanly(test: Node) -> void:
	print("CASE: C-PRIVATE every private start failure restores the group or ends it cleanly: never a search, a new network or a smaller match")
	for scenario: String in ["ack_timeout", "lock_failed", "member_left", "owner_cancel", "timeout_unsafe", "busy_unsafe",
			"restore_failed", "held_member_left", "commit_ack_timeout", "leave_while_switching", "member_lost_after_commit"]:
		var flow := await _full_group(test, "c-private-" + scenario.replace("_", "-"))
		if flow == null:
			await _teardown(test)
			continue
		match scenario:
			"lock_failed":
				party.fake_fail_lock = true
			"timeout_unsafe":
				party.fake_promote_result = "timeout"
				party.fake_restore_private_result = "unsafe"
			"busy_unsafe":
				party.fake_promote_result = "busy"
				party.fake_restore_private_result = "unsafe"
			"restore_failed":
				party.fake_promote_result = "failed"
				party.fake_restore_private_result = "failed"
			"held_member_left", "leave_while_switching":
				party.fake_block_promote = true
		_ready_all()
		match scenario:
			"ack_timeout":
				clock.advance(MatchmakingFlow.PRIVATE_PREPARE_SECONDS)
				_expect_private_restored(test, flow, scenario, MatchmakingFlow.TEXT_PRIVATE_FAILED, false)
			"lock_failed":
				_expect_private_restored(test, flow, scenario, MatchmakingFlow.TEXT_PRIVATE_FAILED, false)
			"member_left":
				NetManager.players.erase(7)
				_remove_member(party.fake_staging, "p4-d")
				NetManager.roster_changed.emit()
				_expect_private_restored(test, flow, scenario, MatchmakingFlow.TEXT_PRIVATE_GROUP_CHANGED, false)
			"owner_cancel":
				test._check(bool(NetManager.flow_snapshot().get("cancellable", false)),
					"[owner_cancel] before the switch is asked for, the owner may cancel")
				NetManager.cancel_matchmaking_search()
				_expect_private_restored(test, flow, scenario, MatchmakingFlow.TEXT_PRIVATE_CANCELLED, false)
			"timeout_unsafe", "busy_unsafe", "restore_failed":
				_ack_private(flow, MatchmakingFlow.Phase.PRIVATE_PREPARING)
				test._check(flow.retired and NetManager.last_disconnect_reason == MatchmakingFlow.TEXT_PRIVATE_NOT_STARTED
					and party.fake_calls.count("restore_private") == 1,
					"[%s] a switch the service cannot prove back ends the group through the ordinary cleanup: %s" % [
						scenario, NetManager.last_disconnect_reason])
			"held_member_left":
				_ack_private(flow, MatchmakingFlow.Phase.PRIVATE_PREPARING)
				test._check(party.fake_calls.has("promote") and not bool(NetManager.flow_snapshot().get("cancellable", true)),
					"[held_member_left] once the switch is asked for, Cancel no longer applies")
				NetManager.cancel_matchmaking_search()
				NetManager.players.erase(7)
				_remove_member(party.fake_staging, "p4-d")
				NetManager.roster_changed.emit()
				test._check(flow.phase == MatchmakingFlow.Phase.PRIVATE_PREPARING and not party.fake_calls.has("restore_private"),
					"[held_member_left] a change during the switch is kept for the transaction; nothing is undone under it")
				party.fake_block_promote = false
				party.fake_promote_released.emit()
				_expect_private_restored(test, flow, scenario, MatchmakingFlow.TEXT_PRIVATE_GROUP_CHANGED, true)
			"commit_ack_timeout":
				_ack_private(flow, MatchmakingFlow.Phase.PRIVATE_PREPARING)
				clock.advance(MatchmakingFlow.PRIVATE_PREPARE_SECONDS)
				_expect_private_restored(test, flow, scenario, MatchmakingFlow.TEXT_PRIVATE_FAILED, true)
			"leave_while_switching":
				_ack_private(flow, MatchmakingFlow.Phase.PRIVATE_PREPARING)
				NetManager.leave_match()
				party.fake_block_promote = false
				party.fake_promote_released.emit()
				test._check(flow.retired and not NetManager.has_session() and not party.fake_calls.has("restore_private")
					and party.fake_calls.has("leave_lobby:%d" % party.fake_staging.context_id),
					"[leave_while_switching] leaving mid-switch ends the group through its own cleanup; nothing is restored or started")
			"member_lost_after_commit":
				if _commit_private_group(test, flow, scenario):
					party.fake_staging_peer.disconnect_remote(6)
					test._check(flow.retired and NetManager.last_disconnect_reason == MatchmakingFlow.TEXT_MATCH_MEMBER_LOST,
						"[member_lost_after_commit] one of the four lost before the match runs ends it, never a match of three: %s" % [
							NetManager.last_disconnect_reason])
		test._check(matchmaking.fake_creates.is_empty() and party.fake_join_arranged_calls.is_empty()
			and not party.fake_calls.has("prepare") and party.fake_calls.count("create_staging") == 1,
			"[%s] never a search, an arrangement or a new lobby or network" % scenario)
		await _teardown(test)


## From the private start's dispatch through its first RUNNING, every shared update reaches
## exactly the four's remote members -- readiness, the gate, the phase, the commit with its
## session, the start and the match's run -- and nobody else. A stray connection meanwhile,
## while the group prepares and while the match plays, gets the closed gate's one refusal in
## in-progress words with no room-code advice, and is dropped from this host's peers; none of the
## four ever is.
func _c_private_recipients_reach_exactly_the_four(test: Node) -> void:
	print("CASE: C-PRIVATE every shared update from the private start through RUNNING reaches exactly the four; a stray peer gets one refusal and is dropped; none of the four is")
	var flow := await _full_group(test, "c-private-recipients")
	if flow == null:
		await _teardown(test)
		return
	var peer: Variant = party.fake_staging_peer
	var from: int = peer.sent.size()
	_ready_all()
	party.fake_peer_keys[9] = _key("p4-stray")
	peer.connect_remote(9)
	test._check(_calls_to(peer, 9) == 1 and NetManager._closed_session_refusal_text() == MatchmakingFlow.TEXT_MATCH_ALREADY_STARTED,
		"a peer reaching the preparing group gets its one refusal, with no room-code advice: %d calls" % _calls_to(peer, 9))
	await test.get_tree().process_frame
	var committed := _commit_private_group(test, flow, "recipients")
	if committed:
		NetManager.set_match_state(NRTypes.MatchState.RUNNING)
		NetManager.consume_initial_cohort()
		party.fake_peer_keys[10] = _key("p4-stray-2")
		peer.connect_remote(10)
		await test.get_tree().process_frame
	var reached := {}
	var strays := 0
	for index in range(from, peer.sent.size()):
		var packet: PackedByteArray = peer.sent[index]
		if packet.size() == 0 or (packet[0] & 7) != 0:
			continue
		var target := int(peer.targets[index])
		if target == 9 or target == 10:
			strays += 1
		else:
			reached[target] = int(reached.get(target, 0)) + 1
	test._check(committed and reached.size() == 3 and reached.has(5) and reached.has(6) and reached.has(7)
		and int(reached.get(5, 0)) == int(reached.get(6, -1)) and int(reached.get(6, 0)) == int(reached.get(7, -1)),
		"every shared update reached exactly the four's three remote members, each the same: %s" % str(reached))
	test._check(strays == 2 and peer.disconnected == [9, 10] and NetManager.players.size() == 4,
		"each stray got only its refusal and was dropped; none of the four was: %s" % str(peer.disconnected))
	await _teardown(test)


## A member follows its owner's private start: it freezes and acknowledges the preparation, reads
## the private control the owner's switch publishes in the lobby and acknowledges it, then takes
## the commit -- the group's lobby as its play session, answering to the same owner there -- and
## follows the first start only with its own admission on this session and the owner proven. A
## control that leaves it out, a restoration, an admission not proven on this session and a
## silent owner each end or undo it cleanly, and nothing is taken on before the commit. Back
## from the match, it waits for the owner's round control of the same session.
func _c_private_member_follows_the_private_start(test: Node) -> void:
	print("CASE: C-PRIVATE a member follows the private start: acknowledged preparation, read control, commit, admission-gated start; exclusion, restoration, no admission and silence end or undo it")
	for scenario: String in ["committed", "excluded", "restored", "unadmitted", "silent"]:
		await _setup(test, "c-private-member-" + scenario)
		var members: Array[Dictionary] = [_key("staging-owner"), party.fake_local_key.duplicate(), _key("p4-x"), _key("p4-y")]
		party.fake_search_control[party.fake_staging.context_id] = {
			"valid": true, "schema": PartyService.SEARCH_CONTROL_SCHEMA, "epoch": 5,
			"phase": MatchmakingFlow.ENVELOPE_PRIVATE, "group": members, "ticket_id": "",
			"reason_code": "", "reason": "",
		}
		var flow := _staging_guest(test, 7)
		var peer: Variant = NetManager._peer
		NetManager._receive_flow_phase(5, MatchmakingFlow.Phase.PRIVATE_PREPARING, {})
		test._check(flow.phase == MatchmakingFlow.Phase.PRIVATE_PREPARING and flow.frozen_keys.size() == 4
			and _calls_to(peer, NetManager.HOST_PEER_ID) == 1 and not NetManager.can_customize(),
			"[%s] the member freezes, knows its group of four and acknowledges once (phase %d)" % [scenario, flow.phase])
		if scenario == "silent":
			clock.advance(MatchmakingFlow.PRIVATE_PREPARE_SECONDS)
			test._check(flow.is_current() and _calls_to(peer, NetManager.HOST_PEER_ID) == 2,
				"[silent] past its own bound it asks the owner for its state")
			clock.advance(MatchmakingFlow.SYNC_SECONDS)
			test._check(flow.retired and NetManager.last_disconnect_reason == MatchmakingFlow.TEXT_HOST_SILENT,
				"[silent] an owner that does not answer ends the group: %s" % NetManager.last_disconnect_reason)
			await _teardown(test)
			continue
		var selected: Array[Dictionary] = []
		if scenario == "excluded":
			selected.assign([_key("staging-owner"), _key("p4-x"), _key("p4-y"), _key("p4-z")])
		else:
			selected.assign(members)
		party.fake_lobby_properties[party.fake_staging.context_id] = PartyService.encode_private_control(
			_PRIVATE_SESSION, 0, PartyService.ARRANGED_PHASE_STARTING, 1, selected)
		party.fake_staging.kind = PartyService.LOBBY_KIND_PRIVATE
		NetManager._on_context_changed(party.fake_staging)
		if scenario == "excluded":
			test._check(flow.retired and NetManager.last_disconnect_reason == MatchmakingFlow.TEXT_MATCH_MISMATCH,
				"[excluded] a published start that leaves this member out ends its attempt: %s" % NetManager.last_disconnect_reason)
			await _teardown(test)
			continue
		test._check(flow.phase == MatchmakingFlow.Phase.PRIVATE_PREPARING and flow.play_context == null
			and _calls_to(peer, NetManager.HOST_PEER_ID) == 2,
			"[%s] the member reads the private control and acknowledges it once; nothing is taken on yet" % scenario)
		if scenario == "restored":
			var detail := {"reason_code": String(MatchmakingFlow.REASON_PRIVATE_FAILED), "reason": MatchmakingFlow.TEXT_PRIVATE_FAILED}
			NetManager._receive_flow_phase(5, MatchmakingFlow.Phase.RESTORING_STAGING, detail)
			NetManager._receive_flow_phase(5, MatchmakingFlow.Phase.GATHERING, detail)
			test._check(flow.phase == MatchmakingFlow.Phase.GATHERING and flow.staging_context == party.fake_staging
				and flow.play_context == null and flow.reason == MatchmakingFlow.TEXT_PRIVATE_FAILED
				and _calls_to(peer, NetManager.HOST_PEER_ID) == 3,
				"[restored] the owner's restoration returns it to the group with the reason, acknowledged; there was nothing to undo")
			await _teardown(test)
			continue
		NetManager._receive_flow_phase(5, MatchmakingFlow.Phase.COMMITTING_START, {"session_id": _PRIVATE_SESSION})
		test._check(flow.phase == MatchmakingFlow.Phase.COMMITTING_START and flow.session_origin == PartyService.PLAY_ORIGIN_PRIVATE
			and flow.session_id == _PRIVATE_SESSION and flow.play_context == party.fake_staging and flow.staging_context == null
			and StringName(NetManager._authority_scope.get("kind", &"")) == &"private",
			"[%s] the commit makes the group's lobby its play session, answering to the same owner there" % scenario)
		if scenario == "unadmitted":
			NetManager._flow_admitted_session = 0
		NetManager._receive_match_state(NRTypes.MatchState.STARTING)
		if scenario == "unadmitted":
			test._check(NetManager.match_state != NRTypes.MatchState.STARTING and not NetManager._pending_start.is_empty(),
				"[unadmitted] a member whose admission on this session is not proven holds the start")
			clock.advance(MatchmakingFlow.COMMIT_SECONDS)
			test._check(flow.retired and NetManager.last_disconnect_reason == MatchmakingFlow.TEXT_MATCH_LATE
				and NetManager.match_state != NRTypes.MatchState.STARTING,
				"[unadmitted] and the hold ends on its own budget, having applied nothing: %s" % NetManager.last_disconnect_reason)
			await _teardown(test)
			continue
		NetManager._receive_match_state(NRTypes.MatchState.RUNNING)
		test._check(NetManager.match_state == NRTypes.MatchState.RUNNING and flow.phase == MatchmakingFlow.Phase.GAMEPLAY
			and flow.selected_keys.size() == 4,
			"[committed] the member follows the first start with the four and plays (phase %d)" % flow.phase)
		NetManager.flow_returned_to_lobby()
		test._check(not flow.host_returned and NetManager._host_return_alarm != null,
			"[committed] back first, it waits for the owner")
		party.fake_lobby_properties[party.fake_staging.context_id] = PartyService.encode_private_control(
			_PRIVATE_SESSION, 1, PartyService.ARRANGED_PHASE_REMATCH)
		NetManager._on_context_changed(party.fake_staging)
		test._check(flow.phase == MatchmakingFlow.Phase.REMATCH_GATHERING and flow.host_returned and flow.match_round == 1
			and NetManager._host_return_alarm == null,
			"[committed] the owner's round control moves it into round %d of the same private session" % flow.match_round)
		await _teardown(test)


## After the first private match the same session returns: round 1 of the same private lobby,
## its round control published and only then the lobby unlocked, advertised invite-only, every
## human unready. A departure there resets nobody else's readiness and a newcomer arrives
## unready. A replacement whose connection arrives before its lobby membership waits, hearing
## nothing shared, and is greeted once when the membership lands with this session's id, then
## admitted through the ordinary handshake; one carrying another session's id is sent nothing and
## dropped. A hosted round of two to four then starts with no ticket and no second switch.
func _c_rematch_private_session_returns_and_admits_replacements(test: Node) -> void:
	print("CASE: C-REMATCH the same private session returns for hosted rounds of 2-4: round control then unlock, invite-only activity, humans unready, no readiness reset, pending replacements hear nothing shared, no ticket")
	var flow := await _private_group(test, "c-rematch")
	if flow == null or not _commit_private_group(test, flow, "rematch"):
		await _teardown(test)
		return
	var session := flow.session_id
	NetManager.set_match_state(NRTypes.MatchState.RUNNING)
	NetManager.consume_initial_cohort()
	NetManager.reset_for_next_match()
	NetManager.flow_returned_to_lobby()
	test._check(flow.phase == MatchmakingFlow.Phase.REMATCH_GATHERING and flow.match_round == 1
		and flow.session_id == session and flow.play_context == party.fake_staging and not NetManager.everyone_ready(),
		"back in the lobby the owner opens round %d of the same private session; every human is unready" % flow.match_round)
	party.fake_calls.clear()
	var opened: bool = await NetManager.open_joins()
	var control := PartyService.decode_private_control(party.fake_lobby_properties.get(party.fake_staging.context_id, {}))
	var published_at := party.fake_calls.find("private_round:%s" % PartyService.ARRANGED_PHASE_REMATCH)
	var unlocked_at := party.fake_calls.find("lock:false")
	test._check(opened and NetManager.is_accepting_joins() and published_at >= 0 and unlocked_at > published_at
		and String(control.get("session_id", "")) == session and int(control.get("round", -1)) == 1,
		"the round control is published for the same session before the unlock: %s" % str(control))
	_complete_activity()
	var advertised := _last_set()
	test._check(advertised != null and advertised.restriction == ActivityService.AUDIENCE_INVITE_ONLY
		and advertised.connection == STAGING_CONNECTION and advertised.maximum == 4,
		"the private session is advertised invite-only, on its own lobby, for four")
	var peer: Variant = party.fake_staging_peer
	NetManager._apply_ready_state(5, true)
	peer.disconnect_remote(7)
	test._check(not NetManager.players.has(7) and _is_ready(5),
		"a departure between rounds resets nobody else's readiness")
	party.fake_peer_keys[9] = _key("p4-new")
	peer.connect_remote(9)
	NetManager._apply_ready_state(6, true)
	test._check(NetManager._arranged_candidates.has(9) and _calls_to(peer, 9) == 0,
		"a replacement on the network before the lobby lists it waits, hearing nothing shared")
	party.fake_set_member(party.fake_staging, _key("p4-new"), true, {
		MatchmakingService.PROTOCOL_MEMBER_KEY: NRProtocol.version_string(),
		PartyService.PRIVATE_SESSION_ID_KEY: session,
	})
	NetManager._on_context_changed(party.fake_staging)
	var greeted := _calls_to(peer, 9)
	NetManager._on_context_changed(party.fake_staging)
	test._check(greeted > 0 and _calls_to(peer, 9) == greeted, "its membership arriving greets it once: %d calls" % greeted)
	_identify(9, "p4-new")
	test._check(NetManager.players.has(9) and not _is_ready(9) and _is_ready(5) and _is_ready(6),
		"it is admitted through the ordinary handshake, unready; the others keep their readiness")
	party.fake_peer_keys[10] = _key("p4-other")
	party.fake_set_member(party.fake_staging, _key("p4-other"), true, {
		MatchmakingService.PROTOCOL_MEMBER_KEY: NRProtocol.version_string(),
		PartyService.PRIVATE_SESSION_ID_KEY: "fedcba9876543210fedcba9876543210",
	})
	peer.connect_remote(10)
	await test.get_tree().process_frame
	test._check(not NetManager.players.has(10) and _calls_to(peer, 10) == 0 and peer.disconnected.has(10),
		"a member carrying another session's id is sent nothing and dropped")
	for peer_id: int in NetManager.players.keys():
		NetManager._apply_ready_state(peer_id, true)
	var sealed: bool = await NetManager.close_joins()
	test._check(sealed and party.fake_calls.has("private_round:%s" % PartyService.ARRANGED_PHASE_GAMEPLAY)
		and party.fake_calls.has("lock:true"),
		"the ready players close the private session for the next round")
	NetManager.set_match_state(NRTypes.MatchState.STARTING)
	test._check(flow.phase == MatchmakingFlow.Phase.GAMEPLAY and not NetManager.initial_cohort_pending()
		and matchmaking.fake_creates.is_empty() and party.fake_calls.count("promote") == 0,
		"a hosted round of %d starts in the same session, with no ticket and no second switch" % NetManager.players.size())
	await _teardown(test)


## An intact invitation into a private match's rematch round joins as that match's replacement:
## the credential reaches the join exactly, the owner is proven the owner of that private
## session's round, and the player is adopted as a guest of the private session -- never as a
## group's staging member -- with no ticket, arrangement or switch.
func _c_rematch_private_invite_joins_as_a_replacement(test: Node) -> void:
	print("CASE: C-REMATCH an intact private rematch invitation joins exactly as that private session's replacement")
	await _setup(test, "c-rematch-invite")
	var peer: Variant = TransportPeer.new(8)
	var owner := _key("private-owner")
	_prove_owner(party.fake_staging, owner, {MatchmakingService.PROTOCOL_MEMBER_KEY: NRProtocol.version_string()})
	party.fake_staging.kind = PartyService.LOBBY_KIND_PRIVATE
	party.fake_lobby_properties[party.fake_staging.context_id] = PartyService.encode_private_control(
		_PRIVATE_SESSION, 1, PartyService.ARRANGED_PHASE_REMATCH)
	party.fake_join_result = {
		"ok": true, "peer": peer, "code": "", "error": "",
		"kind": PartyService.LOBBY_KIND_PRIVATE, "destination": "private_rematch",
		"context": party.fake_staging, "play_origin": String(PartyService.PLAY_ORIGIN_PRIVATE),
		"private_session_id": _PRIVATE_SESSION, "round": 1, "owner_key": owner.duplicate(),
		"capacity": 4, "selected_start_count": 0,
	}
	var request := NetManager.join_by_invite(_PRIVATE_CONNECTION)
	test._check(request.is_pending() and party.fake_last_connection_string == _PRIVATE_CONNECTION
		and StringName(NetManager._authority_scope.get("kind", &"")) == &"private_rematch",
		"the invitation's credential reaches the join unchanged and the session answers to that private round's owner")
	peer.connect_remote(NetManager.HOST_PEER_ID)
	NetManager._accept_join()
	clock.advance(MatchmakingFlow.POLL_SECONDS)
	var flow: MatchmakingFlow = NetManager._flow
	test._check(request.succeeded() and flow != null, "the owner's ordinary admission makes this player a replacement")
	if flow != null:
		test._check(flow.entry_kind == MatchmakingFlow.ENTRY_PRIVATE_REMATCH and flow.phase == MatchmakingFlow.Phase.REMATCH_GATHERING
			and flow.session_origin == PartyService.PLAY_ORIGIN_PRIVATE and flow.session_id == _PRIVATE_SESSION
			and flow.play_context == party.fake_staging and flow.staging_context == null and flow.match_round == 1,
			"adopted as a guest of the private session's round, never as a group's staging member (phase %d)" % flow.phase)
	test._check(matchmaking.fake_creates.is_empty() and matchmaking.fake_joins.is_empty()
		and party.fake_join_arranged_calls.is_empty() and not party.fake_calls.has("promote"),
		"no ticket, no arrangement and no switch")
	await _teardown(test)


## Readiness after a restoration, message by message, with the owner's and a member's own
## production bodies taking turns over one transcript. The owner, restoring with its unlock still
## held, has already put the group's Gathering envelope in the lobby: the member adopts it and
## acknowledges, but the owner, not gathering yet, keeps nothing; a Ready from the member meanwhile
## is not taken, and the member is told the readiness the owner holds. Once the unlock lands the
## owner is gathering again and says so: that message of its own is acknowledged again by the
## member, which was already gathering, and only then does the member's next Ready count. The same
## holds after a cancelled, a failed and a timed-out search and after a private start the service
## restored; the owner's answer to the member's own request is acknowledged the same way, while a
## repeat of that answer or an earlier attempt's Gathering is not.
func _c_consent_restoration_is_acknowledged_again(test: Node) -> void:
	print("CASE: C-CONSENT after every restoration a member acknowledges its owner's own Gathering again, so its next Ready counts; nothing is taken while the owner is still restoring")
	for scenario: String in ["cancel", "failure", "timeout", "private"]:
		var transcript := await _restoration_owner_transcript(test, scenario)
		if transcript.is_empty():
			continue
		await _restoration_member_transcript(test, scenario, transcript)


## The owner's half of the restoration transcript: its group stopped by `scenario` and restored
## with the unlock held, then released. Returns what it produced for the member, in order: the
## Gathering envelope, the readiness it held for the member while restoring, the Gathering it
## broadcast once gathering, and its answer to a state request. Empty when it never got there.
func _restoration_owner_transcript(test: Node, scenario: String) -> Dictionary:
	var account := "c-restore-%s-owner" % scenario
	var flow: MatchmakingFlow = null
	if scenario == "private":
		flow = await _private_group(test, account)
	else:
		await _setup(test, account)
		party.fake_staging_peer = TransportPeer.new(NetManager.HOST_PEER_ID)
		flow = await _open_group(test)
		if flow != null:
			_add_guest(5, "restore-b")
			party.fake_staging_peer.connect_remote(5)
			NetManager.roster_changed.emit()
			_ready_all()
			_ack_all(flow)
			var searching := _attempt()
			if searching != null:
				_progress(searching, MatchmakingService.STATUS_WAITING_FOR_MATCH, "ticket-restore")
	if flow == null:
		await _teardown(test)
		return {}
	var started: bool = flow.phase == MatchmakingFlow.Phase.PRIVATE_PREPARING if scenario == "private" \
		else flow.phase == MatchmakingFlow.Phase.SEARCHING
	test._check(started, "[%s] the owner's group is searching or starting its private match (phase %d)" % [scenario, flow.phase])
	if not started:
		await _teardown(test)
		return {}
	var creates := matchmaking.fake_creates.size()
	var promotes := party.fake_calls.count("promote")
	match scenario:
		"cancel":
			party.fake_block_lock = true
			flow.cancel_search()
			_finish(_attempt(), MatchmakingService.Outcome.CANCELLED)
		"failure":
			party.fake_block_lock = true
			_finish(_attempt(), MatchmakingService.Outcome.FAILED, MatchmakingFlow.REASON_SEARCH_FAILED,
				MatchmakingFlow.TEXT_SEARCH_FAILED)
		"timeout":
			party.fake_block_lock = true
			var timed_out := _attempt()
			_time_out(timed_out)
			timed_out.cancel_in_flight = false
			timed_out.cleanup_pending = false
			timed_out.cleanup_changed.emit(timed_out)
			clock.advance(MatchmakingFlow.POLL_SECONDS)
		"private":
			party.fake_promote_result = "failed"
			party.fake_block_restore_private = true
			_ack_private(flow, MatchmakingFlow.Phase.PRIVATE_PREPARING)
			promotes = party.fake_calls.count("promote")
	var envelope: Dictionary = (party.fake_search_control.get(party.fake_staging.context_id, {}) as Dictionary).duplicate(true)
	var epoch := flow.epoch
	var restoring: bool = flow.phase == MatchmakingFlow.Phase.RESTORING_STAGING \
		and String(envelope.get("phase", "")) == MatchmakingFlow.ENVELOPE_GATHERING and int(envelope.get("epoch", 0)) == epoch
	test._check(restoring, "[%s] the owner is restoring, its unlock held, with the Gathering envelope for attempt %d already in the lobby (phase %d)" % [
		scenario, epoch, flow.phase])
	var peer: Variant = party.fake_staging_peer
	var kept: int = int(flow.gathering_acks.get(5, -1))
	flow.on_member_report(5, epoch, MatchmakingFlow.Phase.GATHERING)
	test._check(int(flow.gathering_acks.get(5, -1)) == kept and kept != epoch,
		"[%s] the member's acknowledgement of that envelope reaches an owner still restoring, which keeps nothing for this attempt" % scenario)
	var held: bool = _is_ready(5)
	var told := _calls_to(peer, 5)
	NetManager._apply_ready_state(5, true)
	test._check(_is_ready(5) == held and _calls_to(peer, 5) == told + 1 and flow.phase == MatchmakingFlow.Phase.RESTORING_STAGING
		and matchmaking.fake_creates.size() == creates and party.fake_calls.count("promote") == promotes,
		"[%s] a Ready meanwhile is not taken, the member alone is told the readiness held for it, and nothing starts" % scenario)
	if scenario == "private":
		party.fake_block_restore_private = false
		party.fake_restore_private_released.emit()
	else:
		party.fake_block_lock = false
		party.fake_lock_released.emit()
	test._check(flow.phase == MatchmakingFlow.Phase.GATHERING and flow.epoch == epoch and flow.gathering_acks.is_empty()
		and not _is_ready(5) and NetManager.is_accepting_joins(),
		"[%s] the unlock lands: the owner gathers again on the same attempt, nothing acknowledged yet, the member unready" % scenario)
	var gathering := {"reason_code": String(flow.reason_code), "reason": flow.reason}
	var reply := flow.replay_state()
	flow.on_member_report(5, epoch, MatchmakingFlow.Phase.GATHERING)
	flow.on_member_report(5, epoch, MatchmakingFlow.Phase.GATHERING)
	flow.on_member_report(5, epoch - 1, MatchmakingFlow.Phase.GATHERING)
	test._check(int(flow.gathering_acks.get(5, -1)) == epoch and flow.gathering_acks.size() == 1,
		"[%s] the member's acknowledgement of the owner's own Gathering is kept, once; an earlier attempt's is not" % scenario)
	NetManager._apply_ready_state(5, true)
	test._check(_is_ready(5) and flow.phase == MatchmakingFlow.Phase.GATHERING
		and matchmaking.fake_creates.size() == creates and party.fake_calls.count("promote") == promotes,
		"[%s] the member's next Ready counts; nothing starts until the whole group is ready" % scenario)
	await _teardown(test)
	return {"envelope": envelope, "epoch": epoch, "held": held, "gathering": gathering, "reply": reply}


## The member's half of the restoration transcript, through its own production bodies: the
## envelope first, then the owner's answer to its Ready, the owner's reset and its own Gathering;
## then an answer to its own request, a repeat of that answer and an earlier attempt's Gathering.
## It never sends an earlier Ready again.
func _restoration_member_transcript(test: Node, scenario: String, transcript: Dictionary) -> void:
	await _setup(test, "c-restore-%s-member" % scenario)
	var epoch := int(transcript.get("epoch", 0))
	party.fake_search_control[party.fake_staging.context_id] = (transcript.get("envelope", {}) as Dictionary).duplicate(true)
	var flow := _staging_guest(test, 5)
	var peer: Variant = NetManager._peer
	NetManager._register_local_player(5)
	test._check(flow.phase == MatchmakingFlow.Phase.GATHERING and flow.epoch == epoch and _calls_to(peer, NetManager.HOST_PEER_ID) == 1,
		"[%s] the member adopts the owner's Gathering envelope and acknowledges it once (phase %d)" % [scenario, flow.phase])
	NetManager.set_local_ready(true)
	test._check(_calls_to(peer, NetManager.HOST_PEER_ID) == 2, "[%s] its Ready goes to an owner still restoring" % scenario)
	NetManager._receive_ready_state(5, bool(transcript.get("held", false)))
	NetManager._receive_ready_state(5, false)
	var gathering: Dictionary = (transcript.get("gathering", {}) as Dictionary).duplicate(true)
	NetManager._receive_flow_phase(epoch, MatchmakingFlow.Phase.GATHERING, gathering)
	test._check(flow.phase == MatchmakingFlow.Phase.GATHERING and flow.epoch == epoch and not NetManager.local_player().is_ready
		and _calls_to(peer, NetManager.HOST_PEER_ID) == 3,
		"[%s] the owner's own Gathering is acknowledged again though the member was already gathering; its earlier Ready is not resent" % scenario)
	NetManager.set_local_ready(true)
	test._check(NetManager.local_player().is_ready and _calls_to(peer, NetManager.HOST_PEER_ID) == 4,
		"[%s] its player readies again: one new Ready" % scenario)
	NetManager._receive_ready_state(5, false)
	flow._request_sync(&"entry")
	var request_id := flow._sync_pending_id
	test._check(request_id > 0 and _calls_to(peer, NetManager.HOST_PEER_ID) == 5, "[%s] it asks the owner for its state" % scenario)
	var reply: Dictionary = transcript.get("reply", {})
	var answer: Dictionary = (reply.get("detail", {}) as Dictionary).duplicate(true)
	answer["request_id"] = request_id
	NetManager._receive_flow_phase(int(reply.get("epoch", 0)), int(reply.get("phase", -1)), answer)
	test._check(_calls_to(peer, NetManager.HOST_PEER_ID) == 6 and flow.phase == MatchmakingFlow.Phase.GATHERING,
		"[%s] the owner's answer, Gathering on this attempt, is acknowledged too" % scenario)
	NetManager._receive_flow_phase(int(reply.get("epoch", 0)), int(reply.get("phase", -1)), answer)
	NetManager._receive_flow_phase(epoch - 1, MatchmakingFlow.Phase.GATHERING, {})
	test._check(_calls_to(peer, NetManager.HOST_PEER_ID) == 6 and flow.epoch == epoch and not NetManager.local_player().is_ready,
		"[%s] a repeat of that answer and an earlier attempt's Gathering are acknowledged by nothing, and no Ready is resent" % scenario)
	await _teardown(test)


## A member of a private start that missed its owner's commit, its first STARTING or both -- the
## owner could not be proven when they arrived -- catches up from the owner's answer to its own
## request, and only then. The owner answers through its own production body, from the play
## session's lobby, only one of the four on the peer it held and on the attempt it committed in,
## once per request and never once the first match runs; its reply constructor gives the session,
## the first round and start and the match state it has reached. The member takes nothing while
## its owner cannot be proven -- not the published control, not an acknowledgement, not a state --
## and asks once the owner is proven again, within its own bound. It then takes the commit once
## and applies the first STARTING and the owner's loading state, in order, through its own
## admission; an answer the live messages overtook changes nothing, a session other than the one
## it read is refused, and an answer for another round is not taken. Its bounds are never renewed:
## an owner that answers still preparing once the bound has passed has not started the match, and
## one that never answers is silent.
func _c_private_member_catches_up_on_its_first_start(test: Node) -> void:
	print("CASE: C-PRIVATE a member that missed its private start's commit or first STARTING catches up once, from its owner's own answer, only while that owner is proven and within its own bounds")
	var owner := await _private_catch_up_owner(test)
	if owner.is_empty():
		return
	var epoch := int(owner.get("epoch", 0))
	var session := String(owner.get("session", ""))
	var committed: Dictionary = owner.get("committed", {})
	var preparing: Dictionary = owner.get("preparing", {})
	var cancelled: Dictionary = owner.get("cancelled", {})
	for scenario: String in ["pending_control", "disproven_control", "commit_and_start_missed", "start_missed",
			"unadmitted", "overtaken_commit", "overtaken_start", "other_session", "other_round", "owner_lost",
			"bound_expired", "still_preparing", "answer_dropped", "answer_dropped_start", "answer_dropped_expired",
			"cancelled_start"]:
		var flow := await _private_member(test, "c-catch-up-" + scenario.replace("_", "-"), epoch, session)
		var peer: Variant = NetManager._peer
		var seen: Array[int] = []
		var record := func(state: NRTypes.MatchState) -> void: seen.append(int(state))
		NetManager.match_state_changed.connect(record)
		var players := NetManager.players.size()
		match scenario:
			"pending_control":
				party.fake_peer_keys.erase(NetManager.HOST_PEER_ID)
				NetManager._on_context_changed(party.fake_staging)
				test._check(flow.phase == MatchmakingFlow.Phase.PRIVATE_PREPARING and flow._adopted_session_id.is_empty()
					and _calls_to(peer, NetManager.HOST_PEER_ID) == 1,
					"[pending_control] the published control is not taken, nor acknowledged, while the owner cannot be proven")
				party.fake_peer_keys[NetManager.HOST_PEER_ID] = _key("staging-owner")
				NetManager._on_context_changed(party.fake_staging)
				NetManager._on_context_changed(party.fake_staging)
				test._check(flow._adopted_session_id == session and _calls_to(peer, NetManager.HOST_PEER_ID) == 2,
					"[pending_control] once the owner is proven it is taken and acknowledged, once")
			"disproven_control":
				party.fake_peer_keys[NetManager.HOST_PEER_ID] = _key("someone-else")
				NetManager._on_context_changed(party.fake_staging)
				test._check(flow.retired and _calls_to(peer, NetManager.HOST_PEER_ID) == 1,
					"[disproven_control] a control arriving under a host that is not the lobby's owner ends the attempt, unacknowledged: %s" % NetManager.last_disconnect_reason)
			"commit_and_start_missed":
				_take_private_control(test, flow, scenario)
				party.fake_peer_keys.erase(NetManager.HOST_PEER_ID)
				NetManager._receive_flow_phase(epoch, MatchmakingFlow.Phase.COMMITTING_START, {"session_id": session})
				NetManager._receive_match_state(NRTypes.MatchState.STARTING)
				test._check(flow.phase == MatchmakingFlow.Phase.PRIVATE_PREPARING and seen.is_empty()
					and _calls_to(peer, NetManager.HOST_PEER_ID) == 2,
					"[%s] neither the commit nor the start is taken while the owner cannot be proven, and nothing is asked yet" % scenario)
				party.fake_peer_keys[NetManager.HOST_PEER_ID] = _key("staging-owner")
				NetManager._on_context_changed(party.fake_staging)
				test._check(_calls_to(peer, NetManager.HOST_PEER_ID) == 3 and flow._sync_pending_id > 0,
					"[%s] the owner proven again, the member asks for its state, once" % scenario)
				_answer_private_member(flow, epoch, committed)
				test._check(flow.phase == MatchmakingFlow.Phase.COMMITTING_START and flow.session_id == session
					and StringName(NetManager._authority_scope.get("kind", &"")) == &"private" and flow.initial_start_seen
					and seen == [int(NRTypes.MatchState.STARTING), int(NRTypes.MatchState.PLAYERS_JOINING)],
					"[%s] the answer is taken once: the commit, then the first STARTING and the owner's loading state, in order: %s" % [scenario, str(seen)])
				test._check(flow.phase_deadline_msec == clock.now_msec() + int(MatchmakingFlow.COMMIT_SECONDS * 1000.0)
					and NetManager.players.size() == players and NetManager._flow_admitted_session == NetManager._session_generation,
					"[%s] the commit's own budget starts at that first commit, and the roster and admission are as they were" % scenario)
				var deadline := flow.phase_deadline_msec
				clock.advance(1.0)
				NetManager._receive_flow_phase(epoch, MatchmakingFlow.Phase.COMMITTING_START, {"session_id": session})
				test._check(flow.phase_deadline_msec == deadline and seen.size() == 2,
					"[%s] a later copy of the commit renews nothing and applies nothing" % scenario)
			"start_missed":
				_take_private_control(test, flow, scenario)
				NetManager._receive_flow_phase(epoch, MatchmakingFlow.Phase.COMMITTING_START, {"session_id": session})
				var deadline := flow.phase_deadline_msec
				party.fake_peer_keys.erase(NetManager.HOST_PEER_ID)
				NetManager._receive_match_state(NRTypes.MatchState.STARTING)
				test._check(flow.phase == MatchmakingFlow.Phase.COMMITTING_START and seen.is_empty() and not flow.initial_start_seen,
					"[%s] the commit was taken; the start is not, while the owner cannot be proven" % scenario)
				clock.advance(2.0)
				party.fake_peer_keys[NetManager.HOST_PEER_ID] = _key("staging-owner")
				NetManager._on_context_changed(party.fake_staging)
				test._check(_calls_to(peer, NetManager.HOST_PEER_ID) == 3 and flow._sync_pending_id > 0,
					"[%s] the owner proven again, the member asks for its state" % scenario)
				_answer_private_member(flow, epoch, committed)
				test._check(flow.initial_start_seen and flow.phase_deadline_msec == deadline
					and seen == [int(NRTypes.MatchState.STARTING), int(NRTypes.MatchState.PLAYERS_JOINING)],
					"[%s] the first STARTING and the loading state are applied once, in order, and the commit's budget is not renewed: %s" % [scenario, str(seen)])
			"unadmitted":
				_take_private_control(test, flow, scenario)
				NetManager._flow_admitted_session = 0
				party.fake_peer_keys.erase(NetManager.HOST_PEER_ID)
				NetManager._receive_flow_phase(epoch, MatchmakingFlow.Phase.COMMITTING_START, {"session_id": session})
				party.fake_peer_keys[NetManager.HOST_PEER_ID] = _key("staging-owner")
				NetManager._on_context_changed(party.fake_staging)
				_answer_private_member(flow, epoch, committed)
				test._check(flow.phase == MatchmakingFlow.Phase.COMMITTING_START and seen.is_empty()
					and not NetManager._pending_start.is_empty(),
					"[unadmitted] without its own admission on this session the member takes the commit but holds the start")
				clock.advance(MatchmakingFlow.COMMIT_SECONDS)
				test._check(flow.retired and seen.is_empty() and NetManager.last_disconnect_reason == MatchmakingFlow.TEXT_MATCH_LATE,
					"[unadmitted] and the hold ends on its own fixed deadline, having applied nothing: %s" % NetManager.last_disconnect_reason)
			"overtaken_commit":
				_take_private_control(test, flow, scenario)
				clock.advance(MatchmakingFlow.PRIVATE_PREPARE_SECONDS)
				var asked := flow._sync_pending_id
				test._check(asked > 0 and _calls_to(peer, NetManager.HOST_PEER_ID) == 3,
					"[%s] past its bound the member asks the owner for its state" % scenario)
				NetManager._receive_flow_phase(epoch, MatchmakingFlow.Phase.COMMITTING_START, {"session_id": session})
				NetManager._receive_match_state(NRTypes.MatchState.STARTING)
				var answer: Dictionary = (committed.get("detail", {}) as Dictionary).duplicate(true)
				answer["request_id"] = asked
				NetManager._receive_flow_phase(epoch, int(committed.get("phase", -1)), answer)
				test._check(flow.phase == MatchmakingFlow.Phase.COMMITTING_START and seen == [int(NRTypes.MatchState.STARTING)],
					"[%s] the live commit and start arrive first; the answer that follows changes nothing: %s" % [scenario, str(seen)])
			"overtaken_start":
				_take_private_control(test, flow, scenario)
				NetManager._receive_flow_phase(epoch, MatchmakingFlow.Phase.COMMITTING_START, {"session_id": session})
				flow._request_sync(&"private")
				NetManager._receive_match_state(NRTypes.MatchState.STARTING)
				_answer_private_member(flow, epoch, committed)
				test._check(flow.initial_start_seen and seen == [int(NRTypes.MatchState.STARTING)] and flow._sync_pending_id == 0,
					"[%s] a start applied while the member's request was out is not applied again by the answer: %s" % [scenario, str(seen)])
			"other_session", "other_round":
				_take_private_control(test, flow, scenario)
				party.fake_peer_keys.erase(NetManager.HOST_PEER_ID)
				NetManager._receive_flow_phase(epoch, MatchmakingFlow.Phase.COMMITTING_START, {"session_id": session})
				party.fake_peer_keys[NetManager.HOST_PEER_ID] = _key("staging-owner")
				NetManager._on_context_changed(party.fake_staging)
				var wrong: Dictionary = committed.duplicate(true)
				var detail: Dictionary = (wrong.get("detail", {}) as Dictionary)
				if scenario == "other_session":
					detail["session_id"] = "fedcba9876543210fedcba9876543210"
				else:
					detail["round"] = 1
				_answer_private_member(flow, epoch, wrong)
				if scenario == "other_session":
					test._check(flow.retired and seen.is_empty() and NetManager.last_disconnect_reason == MatchmakingFlow.TEXT_MATCH_MISMATCH,
						"[other_session] an answer naming another session than the one read from the lobby ends the attempt, applying nothing: %s" % NetManager.last_disconnect_reason)
				else:
					test._check(flow.is_current() and flow.phase == MatchmakingFlow.Phase.PRIVATE_PREPARING and seen.is_empty(),
						"[other_round] an answer for another round is not taken")
			"owner_lost":
				_take_private_control(test, flow, scenario)
				party.fake_peer_keys.erase(NetManager.HOST_PEER_ID)
				NetManager._receive_flow_phase(epoch, MatchmakingFlow.Phase.COMMITTING_START, {"session_id": session})
				party.fake_peer_keys[NetManager.HOST_PEER_ID] = _key("staging-owner")
				NetManager._on_context_changed(party.fake_staging)
				party.fake_owners[party.fake_staging.context_id] = _key("usurper")
				_answer_private_member(flow, epoch, committed)
				test._check(flow.retired and seen.is_empty() and flow.phase != MatchmakingFlow.Phase.COMMITTING_START,
					"[owner_lost] an answer arriving once the owner changed is not taken: %s" % NetManager.last_disconnect_reason)
			"bound_expired":
				_take_private_control(test, flow, scenario)
				party.fake_peer_keys.erase(NetManager.HOST_PEER_ID)
				NetManager._receive_flow_phase(epoch, MatchmakingFlow.Phase.COMMITTING_START, {"session_id": session})
				clock.advance(MatchmakingFlow.PRIVATE_PREPARE_SECONDS)
				test._check(flow.is_current() and _calls_to(peer, NetManager.HOST_PEER_ID) == 3,
					"[%s] at its own bound the member asks once, whatever it could prove" % scenario)
				clock.advance(MatchmakingFlow.SYNC_SECONDS)
				test._check(flow.retired and seen.is_empty() and _calls_to(peer, NetManager.HOST_PEER_ID) == 3
					and NetManager.last_disconnect_reason == MatchmakingFlow.TEXT_HOST_SILENT,
					"[%s] an owner never answered is silent: the attempt ends on the bounds it already had, nothing renewed: %s" % [scenario, NetManager.last_disconnect_reason])
			"still_preparing":
				_take_private_control(test, flow, scenario)
				clock.advance(MatchmakingFlow.PRIVATE_PREPARE_SECONDS)
				var armed := clock.armed_alarm_count()
				_answer_private_member(flow, epoch, preparing)
				test._check(flow.retired and NetManager.last_disconnect_reason == MatchmakingFlow.TEXT_PRIVATE_NOT_STARTED
					and _calls_to(peer, NetManager.HOST_PEER_ID) == 3 and flow._private_bound_alarm == null
					and clock.armed_alarm_count() <= armed,
					"[%s] an owner still preparing once the bound has passed has not started the match; nothing is asked or armed again: %s" % [
						scenario, NetManager.last_disconnect_reason])
			"answer_dropped", "answer_dropped_start", "answer_dropped_expired":
				_take_private_control(test, flow, scenario)
				party.fake_peer_keys.erase(NetManager.HOST_PEER_ID)
				if scenario == "answer_dropped_start":
					party.fake_peer_keys[NetManager.HOST_PEER_ID] = _key("staging-owner")
					NetManager._receive_flow_phase(epoch, MatchmakingFlow.Phase.COMMITTING_START, {"session_id": session})
					party.fake_peer_keys.erase(NetManager.HOST_PEER_ID)
					NetManager._receive_match_state(NRTypes.MatchState.STARTING)
				else:
					NetManager._receive_flow_phase(epoch, MatchmakingFlow.Phase.COMMITTING_START, {"session_id": session})
				party.fake_peer_keys[NetManager.HOST_PEER_ID] = _key("staging-owner")
				NetManager._on_context_changed(party.fake_staging)
				var first := flow._sync_pending_id
				var until := flow._sync_deadline_msec
				test._check(first > 0 and _calls_to(peer, NetManager.HOST_PEER_ID) == 3 and seen.is_empty(),
					"[%s] the owner proven again, the member asks for what it missed" % scenario)
				party.fake_peer_keys.erase(NetManager.HOST_PEER_ID)
				_answer_private_member(flow, epoch, committed)
				test._check(seen.is_empty() and flow._sync_pending_id == first and not flow.initial_start_seen,
					"[%s] the owner's answer arrives while the owner cannot be proven again: nothing is taken" % scenario)
				clock.advance(2.0)
				if scenario == "answer_dropped_expired":
					clock.advance(MatchmakingFlow.SYNC_SECONDS)
					test._check(flow.retired and seen.is_empty() and _calls_to(peer, NetManager.HOST_PEER_ID) == 3
						and NetManager.last_disconnect_reason == MatchmakingFlow.TEXT_HOST_SILENT,
						"[%s] the owner never proven again, nothing is asked again and the request's own deadline ends the attempt: %s" % [
							scenario, NetManager.last_disconnect_reason])
				else:
					var alarms := clock.armed_alarm_count()
					party.fake_peer_keys[NetManager.HOST_PEER_ID] = _key("staging-owner")
					NetManager._on_context_changed(party.fake_staging)
					var second := flow._sync_pending_id
					test._check(second > first and _calls_to(peer, NetManager.HOST_PEER_ID) == 4 and flow._sync_deadline_msec == until
						and clock.armed_alarm_count() == alarms,
						"[%s] the owner proven again before that request's deadline, the request is asked again once, under a new id, on the same deadline" % scenario)
					var stale: Dictionary = (committed.get("detail", {}) as Dictionary).duplicate(true)
					stale["request_id"] = first
					NetManager._receive_flow_phase(epoch, int(committed.get("phase", -1)), stale)
					test._check(seen.is_empty() and flow._sync_pending_id == second,
						"[%s] a late answer to the old id is not taken" % scenario)
					_answer_private_member(flow, epoch, committed)
					test._check(flow.phase == MatchmakingFlow.Phase.COMMITTING_START and flow.initial_start_seen
						and seen == [int(NRTypes.MatchState.STARTING), int(NRTypes.MatchState.PLAYERS_JOINING)],
						"[%s] the answer to it is taken once: the first STARTING and the owner's loading state, in order: %s" % [scenario, str(seen)])
					NetManager._on_context_changed(party.fake_staging)
					test._check(_calls_to(peer, NetManager.HOST_PEER_ID) == 4 and seen.size() == 2,
						"[%s] and nothing more is asked or applied" % scenario)
			"cancelled_start":
				_take_private_control(test, flow, scenario)
				party.fake_peer_keys.erase(NetManager.HOST_PEER_ID)
				NetManager._receive_flow_phase(epoch, MatchmakingFlow.Phase.COMMITTING_START, {"session_id": session})
				party.fake_peer_keys[NetManager.HOST_PEER_ID] = _key("staging-owner")
				NetManager._on_context_changed(party.fake_staging)
				_answer_private_member(flow, epoch, cancelled)
				test._check(flow.is_current() and flow.phase == MatchmakingFlow.Phase.PRIVATE_PREPARING and seen.is_empty()
					and flow.session_origin == &"",
					"[%s] an answer about a first match already cancelled while it loaded is not taken: no commit, no state" % scenario)
		NetManager.match_state_changed.disconnect(record)
		await _teardown(test)


## The owner's side of the private catch-up, through its own production bodies: its answer while
## still preparing, and once committed -- loading its first match -- the answer to one of its four.
## Returns the attempt, the session and both answers as its reply constructor built them.
func _private_catch_up_owner(test: Node) -> Dictionary:
	var flow := await _private_group(test, "c-catch-up-owner")
	if flow == null:
		await _teardown(test)
		return {}
	var preparing := flow.replay_state()
	if not _commit_private_group(test, flow, "catch-up owner"):
		await _teardown(test)
		return {}
	var peer: Variant = party.fake_staging_peer
	NetManager.set_match_state(NRTypes.MatchState.PLAYERS_JOINING)
	var before := _calls_to(peer, 5)
	NetManager._flow_answer_state_request(5, 1, flow.epoch)
	var answered := _calls_to(peer, 5) - before
	NetManager._flow_answer_state_request(5, 1, flow.epoch)
	NetManager._flow_answer_state_request(5, 2, flow.epoch - 1)
	test._check(answered == 1 and _calls_to(peer, 5) == before + 1 and flow.staging_context == null
		and flow.play_context == party.fake_staging,
		"one of the four is answered once, on the play session's own lobby; a repeat, or another attempt's request, is not")
	party.fake_peer_keys[6] = _key("not-one-of-the-four")
	var other := _calls_to(peer, 6)
	NetManager._flow_answer_state_request(6, 1, flow.epoch)
	test._check(_calls_to(peer, 6) == other, "a peer the transport no longer knows as one of the four is not answered")
	party.fake_peer_keys[6] = _key("p4-c")
	var committed := flow.replay_state()
	var detail: Dictionary = committed.get("detail", {})
	test._check(int(preparing.get("phase", -1)) == MatchmakingFlow.Phase.PRIVATE_PREPARING
		and int(committed.get("phase", -1)) == MatchmakingFlow.Phase.COMMITTING_START
		and String(detail.get("session_id", "")) == flow.session_id and int(detail.get("round", -1)) == 0
		and int(detail.get("start_generation", 0)) == 1
		and int(detail.get("match_state", -1)) == int(NRTypes.MatchState.PLAYERS_JOINING),
		"the owner's answer carries the committed session, the first round and start and the state it reached: %s" % str(committed))
	var result := {"epoch": flow.epoch, "session": flow.session_id, "preparing": preparing, "committed": committed}
	NetManager.set_match_state(NRTypes.MatchState.MATCH_COMPLETE)
	result["cancelled"] = flow.replay_state()
	var cancelled_at := _calls_to(peer, 7)
	NetManager._flow_answer_state_request(7, 2, flow.epoch)
	test._check(_calls_to(peer, 7) == cancelled_at and flow.phase == MatchmakingFlow.Phase.COMMITTING_START
		and NetManager.initial_cohort_pending(),
		"a first match cancelled while it loads -- the private start still committed -- is not answered about")
	NetManager.set_match_state(NRTypes.MatchState.RUNNING)
	var late := _calls_to(peer, 7)
	NetManager._flow_answer_state_request(7, 3, flow.epoch)
	test._check(_calls_to(peer, 7) == late, "once the first match runs, nobody is answered about its start")
	await _teardown(test)
	return result


## One of the four following its owner's private start at `epoch` for `session`: frozen and its
## preparation acknowledged, with the owner's switch now published in the lobby -- not yet read.
func _private_member(test: Node, account: String, epoch: int, session: String) -> MatchmakingFlow:
	await _setup(test, account)
	var members: Array[Dictionary] = [_key("staging-owner"), party.fake_local_key.duplicate(), _key("p4-x"), _key("p4-y")]
	party.fake_search_control[party.fake_staging.context_id] = {
		"valid": true, "schema": PartyService.SEARCH_CONTROL_SCHEMA, "epoch": epoch,
		"phase": MatchmakingFlow.ENVELOPE_PRIVATE, "group": members, "ticket_id": "",
		"reason_code": "", "reason": "",
	}
	var flow := _staging_guest(test, 7)
	NetManager._register_local_player(7)
	party.fake_lobby_properties[party.fake_staging.context_id] = PartyService.encode_private_control(
		session, 0, PartyService.ARRANGED_PHASE_STARTING, 1, members)
	party.fake_staging.kind = PartyService.LOBBY_KIND_PRIVATE
	return flow


## The member reads the owner's published control while its owner is proven, and acknowledges it.
func _take_private_control(test: Node, flow: MatchmakingFlow, label: String) -> void:
	NetManager._on_context_changed(party.fake_staging)
	test._check(flow.phase == MatchmakingFlow.Phase.PRIVATE_PREPARING and not flow._adopted_session_id.is_empty()
		and _calls_to(NetManager._peer, NetManager.HOST_PEER_ID) == 2,
		"[%s] the member reads the owner's switch and acknowledges it" % label)


## Delivers `reply` -- as the owner's reply constructor built it -- as the answer to the member's
## request in flight, through the member's own consumption of the owner's phase message.
func _answer_private_member(flow: MatchmakingFlow, epoch: int, reply: Dictionary) -> void:
	var answer: Dictionary = (reply.get("detail", {}) as Dictionary).duplicate(true)
	answer["request_id"] = flow._sync_pending_id
	NetManager._receive_flow_phase(epoch, int(reply.get("phase", -1)), answer)


## A full group's private match past its first RUNNING, back in the lobby with its first rematch
## round open: the round control published, the lobby unlocked, every human unready. Null when it
## did not get there.
func _private_round_one(test: Node, account: String) -> MatchmakingFlow:
	var flow := await _private_group(test, account)
	if flow == null or not _commit_private_group(test, flow, account):
		return null
	NetManager.set_match_state(NRTypes.MatchState.RUNNING)
	NetManager.consume_initial_cohort()
	NetManager.reset_for_next_match()
	NetManager.flow_returned_to_lobby()
	var opened: bool = await NetManager.open_joins()
	test._check(opened and flow.phase == MatchmakingFlow.Phase.REMATCH_GATHERING and flow.match_round == 1
		and not bool(party.fake_locked.get(party.fake_staging.context_id, true)),
		"[%s] round 1 of the private session is open (phase %d)" % [account, flow.phase])
	return flow if opened else null


## One of the four a private match started with rejoins an open round of that same session: its
## Party peer comes back while its lobby membership stayed, with no session id in its entry -- it
## joined the group before there was a session -- and it is greeted once and admitted through the
## ordinary handshake. The same absence is refused from anyone who was not one of the four, and an
## id naming another session is refused even from one of them; so is one of them already on the
## roster, one arriving while the lobby names another session or has another owner, and one
## arriving once the round is closed. Nobody refused is sent anything or kept.
func _c_rematch_original_member_rejoins_its_round(test: Node) -> void:
	print("CASE: C-REMATCH one of a private match's four whose peer comes back to an open round is admitted without a session id; nobody else is")
	for scenario: String in ["original", "mismatched", "outsider", "duplicate", "other_session", "other_owner", "closed"]:
		var flow := await _private_round_one(test, "c-rejoin-" + scenario.replace("_", "-"))
		if flow == null:
			await _teardown(test)
			continue
		var peer: Variant = party.fake_staging_peer
		var protocol := {MatchmakingService.PROTOCOL_MEMBER_KEY: NRProtocol.version_string()}
		var entity := "p4-d"
		if scenario != "outsider" and scenario != "duplicate":
			peer.disconnect_remote(7)
		match scenario:
			"mismatched":
				var named: Dictionary = protocol.duplicate()
				named[PartyService.PRIVATE_SESSION_ID_KEY] = "fedcba9876543210fedcba9876543210"
				party.fake_set_member(party.fake_staging, _key("p4-d"), true, named)
			"outsider":
				entity = "p4-outsider"
				party.fake_set_member(party.fake_staging, _key(entity), true, protocol)
			"duplicate":
				entity = "p4-b"
			"other_session":
				party.fake_lobby_properties[party.fake_staging.context_id] = PartyService.encode_private_control(
					"fedcba9876543210fedcba9876543210", 1, PartyService.ARRANGED_PHASE_REMATCH)
			"other_owner":
				party.fake_owners[party.fake_staging.context_id] = _key("usurper")
			"closed":
				var closed: bool = await NetManager.close_joins()
				test._check(closed and bool(party.fake_locked.get(party.fake_staging.context_id, false)),
					"[closed] the round is closed and the lobby locked")
		var rejoining := 11
		party.fake_peer_keys[rejoining] = _key(entity)
		peer.connect_remote(rejoining)
		var greeted := _calls_to(peer, rejoining)
		if scenario == "original":
			test._check(greeted > 0 and not NetManager._arranged_candidates.has(rejoining),
				"[original] one of the four coming back to its open round is greeted, with no session id of its own: %d calls" % greeted)
			_identify(rejoining, entity)
			test._check(NetManager.players.has(rejoining) and not _is_ready(rejoining) and NetManager.players.size() == 4
				and _calls_to(peer, rejoining) > greeted,
				"[original] and admitted through the ordinary handshake, unready, the roster whole again")
		else:
			await test.get_tree().process_frame
			test._check(greeted == 0 and not NetManager.players.has(rejoining) and peer.disconnected.has(rejoining),
				"[%s] it is sent nothing, not admitted, and dropped" % scenario)
			test._check(NetManager.players.has(5) and NetManager.players.has(6) and not peer.disconnected.has(5)
				and not peer.disconnected.has(6),
				"[%s] and the players already here are untouched" % scenario)
		await _teardown(test)


## A full group, all four ready and consenting, that is waiting only on an earlier search's
## cleanup starts its private match once the service reports that cleanup changed -- through the
## service's own notice, with nobody readying again and nothing else changing -- once, on the
## notice's deferred look. Several notices make one look; and a notice whose group has since
## changed, lost its owner, been left or already started makes no second start, and no ticket.
func _c_wake_full_group_after_cleanup(test: Node) -> void:
	print("CASE: C-AUTO a full ready group waiting only on earlier cleanup starts privately once the service reports it, once; never after its group, owner or phase moved on")
	for scenario: String in ["settled", "repeated", "composition", "owner_lost", "left", "moved"]:
		var flow := await _full_group(test, "c-wake-" + scenario.replace("_", "-"))
		if flow == null:
			await _teardown(test)
			continue
		var owed := MatchmakingService.TicketAttempt.new()
		owed.cleanup_pending = true
		flow._unresolved_attempts.append(owed)
		_ready_all()
		test._check(flow.phase == MatchmakingFlow.Phase.GATHERING and not party.fake_calls.has("post:private")
			and _is_ready(5) and _is_ready(6) and _is_ready(7) and NetManager.local_player().is_ready,
			"[%s] the four are ready and consenting, and wait for the earlier search's cleanup" % scenario)
		owed.cleanup_pending = false
		owed.cleanup_changed.emit(owed)
		matchmaking.cleanup_state_changed.emit()
		match scenario:
			"repeated":
				matchmaking.cleanup_state_changed.emit()
				party.cleanup_state_changed.emit()
			"composition":
				NetManager.players.erase(7)
				_remove_member(party.fake_staging, "p4-d")
				NetManager.roster_changed.emit()
			"owner_lost":
				party.fake_owners[party.fake_staging.context_id] = _key("usurper")
				NetManager._on_context_changed(party.fake_staging)
			"left":
				NetManager.leave_match()
			"moved":
				NetManager.roster_changed.emit()
		test._check(scenario == "moved" or not party.fake_calls.has("post:private"),
			"[%s] nothing is started inside the notice itself" % scenario)
		await test.get_tree().process_frame
		var starts := party.fake_calls.count("post:private")
		match scenario:
			"settled", "repeated", "moved":
				test._check(starts == 1 and flow.phase == MatchmakingFlow.Phase.PRIVATE_PREPARING,
					"[%s] the private match starts once (phase %d, %d starts)" % [scenario, flow.phase, starts])
			"composition":
				test._check(starts == 0 and flow.phase == MatchmakingFlow.Phase.GATHERING and not _is_ready(5),
					"[composition] a group that changed since the notice is unready again and starts nothing")
			"owner_lost", "left":
				test._check(starts == 0 and flow.retired, "[%s] a group that ended starts nothing" % scenario)
		matchmaking.cleanup_state_changed.emit()
		await test.get_tree().process_frame
		test._check(party.fake_calls.count("post:private") == starts and matchmaking.fake_creates.is_empty(),
			"[%s] a later notice starts nothing again, and nothing is ever searched" % scenario)
		await _teardown(test)


# --- Composed: the production services over the service suite's SDK doubles ------------------
#
# These cases run the real PartyService and MatchmakingService -- their proofs, scoped leaves,
# recovery and ticket cleanup -- under the production NetManager, Services and flow. Only SDK
# facts, call ordering and controlled native completions are set: no proof, recovery or
# invalidation is re-implemented or emitted by the case.

func _setup_composed(test: Node, account: String) -> void:
	await test._reset()
	chat = Doubles.Chat.new()
	real_party = ServiceDoubles.Party.new(chat)
	real_matchmaking = ServiceDoubles.Matchmaking.new()
	real_clock = real_party.fake_clock
	activity = Review.Activity.new()
	_completed_calls = 0
	Services._chat = chat
	Services._party = real_party
	Services.bind_party_signals()
	Services._matchmaking = real_matchmaking
	Services.bind_matchmaking_signals()
	Services._activity = activity
	Services.use_clock(real_clock)
	NetManager._clock = real_clock.now_msec
	_bind_composed_party(true)
	# One Multiplayer runtime: its scoped shutdown answers the tickets' held cancels inside the
	# call, as the runtime's own shutdown does, before the service reports the reset.
	real_party.pf.multiplayer.shutdown_hook = real_matchmaking.sdk.invalidate_runtime
	test._select(account, test._folder())
	var signed_in: Array = [null]
	_capture_sign_in(signed_in)
	test._check(await _composed_until(test, func() -> bool: return signed_in[0] != null) and bool(signed_in[0]),
		"composed account ready: " + account)


## Runs the composed clock on one step at a time, a frame after each, until `done` holds or
## `steps` run out. A step that never settles is then a named failure, not a hang.
func _composed_until(test: Node, done: Callable, steps: int = 40, seconds: float = MatchmakingFlow.POLL_SECONDS) -> bool:
	for _step in steps:
		if bool(done.call()):
			return true
		real_clock.advance(seconds)
		await test.get_tree().process_frame
	return bool(done.call())


func _capture_sign_in(box: Array) -> void:
	box[0] = await Services.sign_in()


func _capture_quick_match(box: Array) -> void:
	box[0] = await NetManager.start_matchmaking()


func _capture_host_match(box: Array) -> void:
	box[0] = await NetManager.host_match()


## The composed PartyService's notices, bound to NetManager as the title binds its own.
func _bind_composed_party(bind: bool) -> void:
	var links: Array = [
		[real_party.network_lost, NetManager._on_party_network_lost],
		[real_party.party_failed, NetManager._on_party_failed],
		[real_party.cleanup_status_changed, NetManager._on_party_cleanup_status],
		[real_party.context_updated, NetManager._on_context_changed],
		[real_party.context_lost, NetManager._on_context_lost],
	]
	for link: Array in links:
		var notice: Signal = link[0]
		var handler: Callable = link[1]
		if bind and not notice.is_connected(handler):
			notice.connect(handler)
		elif not bind and notice.is_connected(handler):
			notice.disconnect(handler)


## Lets every held SDK completion go, leaves what is live, runs out the clock, and discards
## a runtime a case left restart-required by one real, successful recovery -- so nothing the
## case started outlives it. A cancel still waiting on a live ticket is answered the way the
## addon answers it, by that ticket's terminal publication; an injected unanswered observer is
## left to the teardown's recovery, whose shutdown releases it.
func _teardown_composed(test: Node) -> void:
	for lobby: ServiceDoubles.Lobby in real_party.pf.multiplayer.lobbies:
		lobby.block_leave = false
		lobby.leave_released.emit()
		lobby.block_properties = false
		lobby.properties_released.emit()
	for network: ServiceDoubles.Network in real_party.pf.party.networks:
		network.block_leave = false
		network.leave_released.emit()
	_answer_waiting_cancels()
	real_party.pf.multiplayer.block_create = false
	real_party.pf.multiplayer.create_released.emit()
	real_party.pf.party.block_create = false
	real_party.pf.party.create_released.emit()
	real_party.pf.multiplayer.next_shutdown_result = null
	real_party.pf.multiplayer.shutdown_hook = real_matchmaking.sdk.invalidate_runtime
	NetManager.leave_match()
	if not real_party.recovery_error.is_empty():
		real_party.recovery_error = ""
		real_party.require_recovery(&"case_teardown")
		real_party.leave()
	for _sweep in 6:
		_answer_waiting_cancels()
		_complete_activity()
		real_clock.advance(20.0)
		await test.get_tree().process_frame
	if NetManager.has_online_flow():
		# A flow still holding its lease over work the case left owed stops watching it with
		# its account, as it does in the title.
		Services.invalidate_saves_for_resume()
		for _sweep in 2:
			real_clock.advance(1.0)
			await test.get_tree().process_frame
	test._check(not NetManager.has_online_flow() and not NetManager.has_session()
		and NetManager._active_join_request == null and not NetManager.is_account_teardown_pending(),
		"composed case leaves no flow, session, join or teardown behind")
	test._check(real_clock.pending_sleepers() == 0 and real_clock.armed_alarm_count() == 0
		and not real_matchmaking.has_pending_cleanup() and not real_party.is_cleanup_pending(),
		"composed case leaves nothing asleep, armed or owed: %d asleep, %d armed, matchmaking cleanup %s, Party cleanup %s" % [
			real_clock.pending_sleepers(), real_clock.armed_alarm_count(),
			real_matchmaking.has_pending_cleanup(), real_party.is_cleanup_pending()])
	real_party.pf.multiplayer.shutdown_hook = Callable()
	_bind_composed_party(false)
	Services.use_clock(OnlineFlowClock.new())
	NetManager._clock = Time.get_ticks_msec
	Services._party = null
	Services._chat = null
	Services._matchmaking = null
	Services._activity = _saved_activity
	real_party = null
	real_matchmaking = null
	real_clock = null


## Every cancel still waiting on a live ticket, answered as the service confirms it: by the
## ticket's terminal Cancelled publication, with any injected fault on that live ticket lifted
## first, since the case that set it is over. A ticket already published -- an injected
## observer left unanswered after its match -- is not touched: the teardown's reset releases it.
func _answer_waiting_cancels() -> void:
	if real_matchmaking == null:
		return
	for ticket: ServiceDoubles.Ticket in real_matchmaking.sdk.tracked_tickets.duplicate():
		if ticket.cancel_waiting and not ticket.completion_received:
			ticket.cancel_fault_unanswered = false
			ticket.publish_terminal(MatchmakingService.STATUS_CANCELLED)


## A hosted lobby at `connection`, owned by `owner`, with the transport a join finds behind it:
## peer 1 is the owner and this player peer 7. Returns the SDK handles the case may change.
func _composed_hosted_lobby(owner: Dictionary, connection: String) -> Dictionary:
	var lobby := ServiceDoubles.Lobby.new()
	lobby.lobby_id = connection + "-lobby"
	lobby.connection_string = connection
	lobby.owner_entity_key = owner.duplicate()
	lobby.search_properties = {
		PartyService.JOIN_CODE_KEY: "ABCDE",
		PartyService.GAME_MODE_KEY: "deathmatch",
		NRProtocol.LOBBY_KEY: NRProtocol.version_string(),
	}
	lobby.properties = {PartyService.DESCRIPTOR_KEY: connection + "-descriptor"}
	lobby.members = [ServiceDoubles.Member.new(owner, {
		MatchmakingService.PROTOCOL_MEMBER_KEY: NRProtocol.version_string(),
	})]
	var network := ServiceDoubles.Network.new()
	var peer := RecordingPeer.new()
	peer.keys[1] = owner.duplicate()
	network.local_peer = peer
	real_party.pf.multiplayer.lobby_by_connection[connection] = lobby
	real_party.pf.party.queued_networks.append(network)
	# The host's chat control is in the mesh a guest joins, as Party surfaces it.
	chat.sdk.add_remote_control(owner)
	return {"lobby": lobby, "network": network, "peer": peer}


## The owner's own group, open over the real services, or null.
func _composed_group(test: Node) -> MatchmakingFlow:
	var opened: Array = [null]
	_capture_quick_match(opened)
	await _composed_until(test, func() -> bool: return opened[0] != null, 20)
	_complete_activity()
	var flow: MatchmakingFlow = NetManager._flow
	var started: bool = opened[0] != null and bool(opened[0])
	test._check(started and flow != null and flow.staging_context != null,
		"the owner's group opens over the real PartyService: %s" % NetManager.last_error)
	return flow if started and flow != null and flow.staging_context != null else null


## That group readied and searching on a real ticket, or null.
func _composed_searching_group(test: Node) -> MatchmakingFlow:
	var flow := await _composed_group(test)
	if flow == null:
		return null
	NetManager.set_local_ready(true)
	await _composed_until(test, func() -> bool: return _composed_ticket() != null, 20)
	var ticket := _composed_ticket()
	test._check(ticket != null, "the ready group's ticket is created through the real service")
	if ticket == null:
		return null
	ticket.publish_nonterminal(MatchmakingService.STATUS_WAITING_FOR_MATCH)
	await test.get_tree().process_frame
	return flow


func _composed_ticket() -> ServiceDoubles.Ticket:
	if real_matchmaking == null or real_matchmaking.sdk.tracked_tickets.is_empty():
		return null
	return real_matchmaking.sdk.tracked_tickets.back()


func _capture_scoped_leave(context: PartyService.LobbyContext, box: Array) -> void:
	box[0] = await real_party.leave_lobby(context)


func _capture_awaited_leave(done: Array) -> void:
	await NetManager.leave_match_and_wait()
	done[0] = true


func _capture_suspend_teardown(done: Array) -> void:
	await NetManager.finish_suspend_teardown()
	done[0] = true


## Item 1, over the real PartyService: an admitted ordinary hosted guest whose own lobby
## connection drops while Party runs on keeps playing under the host it proved, and a lobby
## that reconnects is proven in full again. A different peer 1, a lost transport or a cleared
## owner still end the session once, and a join not yet admitted is refused at once -- no
## identity is sent and the join's deadline is not waited out.
func _c1_admitted_hosted_session_outlives_only_its_local_lobby_connection(test: Node) -> void:
	print("CASE: C1 over the real PartyService an admitted hosted guest outlives only its own lobby connection; a join, a changed host or a lost transport do not")
	var owner := _key("c1-host")
	var outcomes := {
		"continues": "",
		"reconnected_changed": NetManager._HOST_CHANGED,
		"host_key_changed": NetManager._HOST_CHANGED,
		"transport_lost": NetManager._HOST_LEFT_BEFORE_JOIN,
		"owner_cleared": NetManager._HOST_CHANGED,
		"before_admission": NetManager._HOST_LEFT_BEFORE_JOIN,
	}
	for scenario: String in outcomes.keys():
		await _setup_composed(test, "c1-" + scenario)
		var connection := "c1-%s-connection" % scenario
		var hosted := _composed_hosted_lobby(owner, connection)
		var lobby: ServiceDoubles.Lobby = hosted["lobby"]
		var peer: RecordingPeer = hosted["peer"]
		var request := NetManager.join_by_invite(connection)
		await test.get_tree().process_frame
		test._check(NetManager._peer == peer and request.is_pending(),
			"[%s] the real join binds the transport it found and waits for the host" % scenario)
		if NetManager._peer != peer:
			await _teardown_composed(test)
			continue
		peer.connect_remote(NetManager.HOST_PEER_ID)
		if scenario == "before_admission":
			lobby.disconnected = true
			var started := real_clock.now_msec()
			real_clock.advance(MatchmakingFlow.POLL_SECONDS)
			await test.get_tree().process_frame
			NetManager._request_player_identity()
			test._check(request.outcome == JoinRequest.Outcome.FAILED and request.reason == String(outcomes[scenario]),
				"[%s] a join whose lobby connection is gone is refused: %s" % [scenario, request.reason])
			test._check(real_clock.now_msec() - started < 1000 and _rpc_calls(peer) == 0 and not NetManager.has_session(),
				"[%s] at once, with no identity sent and nothing adopted" % scenario)
			await _teardown_composed(test)
			continue
		NetManager._request_player_identity()
		test._check(_rpc_calls(peer) == 1, "[%s] the real proof answers the host once" % scenario)
		_host_replays_and_accepts("C1 Host")
		real_clock.advance(MatchmakingFlow.POLL_SECONDS)
		await test.get_tree().process_frame
		test._check(request.succeeded() and NetManager.has_session(), "[%s] and the guest is admitted" % scenario)
		lobby.disconnected = true
		var kept := _send_host_state(5)
		test._check(bool(kept["applied"]) and int(kept["ends"]) == 0 and NetManager.has_session(),
			"[%s] with only its own lobby connection gone, the admitted session carries on under its host" % scenario)
		match scenario:
			"reconnected_changed":
				lobby.disconnected = false
				lobby.owner_entity_key = _key("c1-other-owner")
			"host_key_changed":
				peer.keys[1] = _key("c1-other")
			"transport_lost":
				peer.connected = false
			"owner_cleared":
				lobby.disconnected = false
				lobby.owner_entity_key = {}
		if scenario != "continues":
			var seen := _send_host_state(6)
			test._check(not bool(seen["applied"]) and int(seen["ends"]) == 1 and not NetManager.has_session(),
				"[%s] and then ends once, applying nothing: %d ends" % [scenario, int(seen["ends"])])
			test._check(NetManager.last_disconnect_reason == String(outcomes[scenario]),
				"[%s] with this title's reason: %s" % [scenario, NetManager.last_disconnect_reason])
		await _teardown_composed(test)


## Item 1's other half: a matchmaking lobby whose own connection is gone stays lost. Over the
## owner facts the service reports -- PartyService's own proof of them is the service suite's
## case -- a staging guest's group ends, and an adopted rematch replacement's match ends, once
## each, applying nothing peer 1 sends.
func _c1_scoped_local_lobby_loss_stays_terminal(test: Node) -> void:
	print("CASE: C1 a staging or rematch session whose own lobby connection is gone ends once; the hosted exception is not theirs")
	for path: String in ["staging", "rematch"]:
		await _setup(test, "c1-scoped-" + path)
		var flow: MatchmakingFlow = null
		var context: PartyService.LobbyContext = null
		var expected := ""
		if path == "rematch":
			_pending_rematch(test, _key(ARRANGED_OWNER_ID))
			NetManager._request_player_identity()
			_host_replays_and_accepts("C1 Host")
			clock.advance(MatchmakingFlow.POLL_SECONDS)
			flow = NetManager._flow
			context = party.fake_arranged
			expected = NetManager._MATCH_HOST_LEFT
		else:
			flow = _staging_guest(test, 7)
			context = party.fake_staging
			expected = MatchmakingFlow.TEXT_GROUP_HOST_LEFT
		test._check(flow != null and flow.is_current(), "[%s] the session is admitted" % path)
		if flow == null:
			await _teardown(test)
			continue
		party.fake_lobby_disconnected[context.context_id] = true
		var seen := _send_host_state(5)
		test._check(not bool(seen["applied"]) and int(seen["ends"]) == 1 and flow.retired,
			"[%s] peer 1's next message ends it once, applying nothing: %d ends" % [path, int(seen["ends"])])
		test._check(NetManager.last_disconnect_reason == expected,
			"[%s] with its reason: %s" % [path, NetManager.last_disconnect_reason])
		await _teardown(test)


## Item 2, over the real PartyService: every waiter on a flow's scoped leaves -- the flow's
## own first leave, a coalesced public caller, the quit drain and account teardown -- settles
## from the global cleanup's confirmed reset while both native leaves are still held; the
## lease goes with them. Releasing the old native signals afterwards settles nothing twice,
## calls nothing again and touches no replacement. A native answer, at once or before the
## grace, needs no reset at all; a reset that fails never looks like a release.
func _c2_scoped_leave_waiters_settle_from_recovery(test: Node) -> void:
	print("CASE: C2 over the real PartyService every scoped-leave waiter settles from the confirmed reset, once; a failed reset is no release")
	for scenario: String in ["recovered", "recovered_account", "native_at_once", "native_delayed", "failed_recovery"]:
		await _setup_composed(test, "c2-" + scenario)
		var flow := await _composed_group(test)
		if flow == null:
			await _teardown_composed(test)
			continue
		var context: PartyService.LobbyContext = flow.staging_context
		var lobby: ServiceDoubles.Lobby = real_party.pf.multiplayer.lobbies.back()
		var network: ServiceDoubles.Network = real_party.pf.party.networks.back()
		var held := scenario != "native_at_once"
		lobby.block_leave = held
		network.block_leave = held
		if scenario == "failed_recovery":
			real_party.pf.multiplayer.next_shutdown_result = ServiceDoubles.Results.make(
				false, null, "shutting_down", "Injected scoped shutdown failure.", -2147467260)
		NetManager.leave_match()
		var direct: Array = [null]
		if held:
			_capture_scoped_leave(context, direct)
		var quit_done: Array = [false]
		if scenario == "recovered":
			_capture_awaited_leave(quit_done)
		if scenario == "recovered_account":
			NetManager._on_account_lost()
		await test.get_tree().process_frame
		if scenario == "native_delayed":
			lobby.leave_released.emit()
			network.leave_released.emit()
			real_clock.advance(MatchmakingFlow.POLL_SECONDS)
			await test.get_tree().process_frame
		elif held:
			test._check(NetManager.has_online_flow() and direct[0] == null,
				"[%s] while both native leaves are held, the lease and every waiter wait" % scenario)
			real_clock.advance(NRConst.MATCH_CLEANUP_SECONDS + 1.0)
			await test.get_tree().process_frame
		var shutdowns := real_party.pf.multiplayer.shutdown_calls
		var result: PartyService.PartyResult = direct[0]
		if scenario == "failed_recovery":
			test._check(result != null and not result.ok() and NetManager.has_online_flow()
				and NetManager.retained_cleanup_failure() == PartyService.RECOVERY_FAILED,
				"[%s] the waiters settle as failed and the lease stays held, restart-required" % scenario)
		else:
			if held:
				test._check(result != null and result.ok(), "[%s] the coalesced public caller settles OK" % scenario)
			test._check(not NetManager.has_online_flow(), "[%s] and the lease is released" % scenario)
			test._check(shutdowns == (1 if scenario.begins_with("recovered") else 0),
				"[%s] from %s: %d resets" % [scenario, "the one confirmed reset" if scenario.begins_with("recovered") else "the native answer", shutdowns])
		if scenario == "recovered":
			test._check(bool(quit_done[0]), "[%s] the quit drain's wait has finished too" % scenario)
		if scenario == "recovered_account":
			test._check(not NetManager.is_account_teardown_pending(), "[%s] and so has the account teardown" % scenario)
		test._check(lobby.leaves == 1 and network.leaves == 1,
			"[%s] each native leave was called once: %d, %d" % [scenario, lobby.leaves, network.leaves])
		if scenario == "recovered":
			var replacement := await _composed_group(test)
			lobby.leave_released.emit()
			network.leave_released.emit()
			real_clock.advance(MatchmakingFlow.POLL_SECONDS)
			await test.get_tree().process_frame
			test._check(direct[0] == result and lobby.leaves == 1 and network.leaves == 1,
				"[%s] the old native answers settle nothing twice and call nothing again" % scenario)
			test._check(replacement != null and replacement == NetManager._flow and replacement.is_live()
				and not real_party.snapshot(replacement.staging_context).is_empty(),
				"[%s] and leave the replacement group untouched" % scenario)
		await _teardown_composed(test)


## Items 3 and 7, over the real services, with an injected native cancel observer that never
## answers: a cancel in flight on a ticket the service then matches is an obligation of the
## runtime, not of the flow or the account. Removing the account or suspending before the
## flow's grace, a match landing while the teardown is already running, or one landing after
## that teardown has finished, still gets exactly one confirmed reset -- the held cancel is
## answered inside the shutdown and logged as released by that reset, not as a lost race -- no
## old session is adopted, nothing old is owed afterwards, and the next account starts Quick
## Match without a restart. Entry while the old cleanup is owed waits for it: the next sign-in
## finishes the old session, reset included, first, and a search still being cancelled says
## so. A late answer from the old runtime changes nothing. A reset that fails is the
## restart-required refusal, and is not asked for again. Every wait is bounded on the composed
## clock, so a step that never settles fails by name.
func _c3_orphaned_cancel_survives_account_removal_and_suspend(test: Node) -> void:
	print("CASE: C3 over the real services an injected unanswered matched cancel survives account removal and suspend: one reset, nothing adopted, Quick Match again")
	for scenario: String in ["account_removed", "suspended", "matched_during_teardown", "matched_after_teardown", "failed_recovery"]:
		await _setup_composed(test, "c3-" + scenario)
		var flow := await _composed_searching_group(test)
		var ticket := _composed_ticket()
		if flow == null or ticket == null:
			await _teardown_composed(test)
			continue
		var lobby: ServiceDoubles.Lobby = real_party.pf.multiplayer.lobbies.back()
		ticket.cancel_fault_unanswered = true
		flow.cancel_search()
		await test.get_tree().process_frame
		test._check(ticket.cancel_waiting and real_matchmaking.has_pending_cleanup(),
			"[%s] the owner's cancel is in flight" % scenario)
		if scenario == "failed_recovery":
			real_party.pf.multiplayer.shutdown_hook = Callable()
			real_party.pf.multiplayer.next_shutdown_result = ServiceDoubles.Results.make(
				false, null, "shutting_down", "Injected scoped shutdown failure.", -2147467260)
		# Held so the old group's scoped leave is still owed while the account goes: the reset
		# that settles it is then the only way forward.
		if scenario == "account_removed" or scenario == "matched_during_teardown":
			lobby.block_leave = true
		if scenario in ["account_removed", "suspended", "failed_recovery"]:
			ticket.publish_terminal(MatchmakingService.STATUS_MATCHED)
			await test.get_tree().process_frame
			# The service holds the notice of a match whose cancel is unanswered; the group reads the
			# ticket's native status at its next poll.
			real_clock.advance(MatchmakingFlow.POLL_SECONDS)
			await test.get_tree().process_frame
			test._check(flow.retired and real_matchmaking.has_orphaned_matched_cancel() and NetManager.has_online_flow(),
				"[%s] the match lands on the stopped search: the group ends, its lease held over the orphaned cancel" % scenario)
		# Before the flow's own grace has run, the title suspends and resumes, or the account goes.
		if scenario == "suspended":
			NetManager.abandon_for_suspend()
			Services.invalidate_saves_for_resume()
			var resumed: Array = [false]
			_capture_suspend_teardown(resumed)
			test._check(await _composed_until(test, func() -> bool: return bool(resumed[0]), 60, 1.0),
				"[%s] the resume's deferred teardown finishes" % scenario)
		else:
			Services.cancel_sign_in()
			await test.get_tree().process_frame
		if scenario == "matched_during_teardown":
			ticket.publish_terminal(MatchmakingService.STATUS_MATCHED)
			await test.get_tree().process_frame
			test._check(NetManager.is_account_teardown_pending() and real_matchmaking.has_orphaned_matched_cancel(),
				"[%s] the match lands after the teardown's first look, while it still runs" % scenario)
			lobby.leave_released.emit()
		var signed_in: Array = [null]
		if scenario == "account_removed":
			_capture_sign_in(signed_in)
			await test.get_tree().process_frame
			test._check(signed_in[0] == null and NetManager.is_account_teardown_pending()
				and Services.sign_in_stage == "Finishing the previous session"
				and real_party.pf.multiplayer.shutdown_calls == 0,
				"[%s] the next account's sign-in waits while the old session's reset is still owed" % scenario)
		test._check(await _composed_until(test, func() -> bool: return not NetManager.is_account_teardown_pending(), 60, 1.0),
			"[%s] the teardown finishes on its bounded cleanup" % scenario)
		if signed_in[0] == null and not Services.is_account_ready():
			_capture_sign_in(signed_in)
		var account_back: bool = await _composed_until(test, func() -> bool: return Services.is_account_ready(), 40)
		test._check(account_back, "[%s] the next account signs in" % scenario)
		if scenario == "matched_after_teardown":
			test._check(real_party.pf.multiplayer.shutdown_calls == 0 and real_matchmaking.has_pending_cleanup()
				and not real_matchmaking.has_orphaned_matched_cancel(),
				"[%s] the teardown found only a search still being cancelled, and reset nothing" % scenario)
			var waiting: Array = [null]
			_capture_quick_match(waiting)
			await _composed_until(test, func() -> bool: return waiting[0] != null, 20)
			test._check(waiting[0] == false and NetManager.last_error == NetManager._PREVIOUS_SEARCH_FINISHING,
				"[%s] the next account's Quick Match waits, told the previous search is still finishing: %s" % [scenario, NetManager.last_error])
			ticket.publish_terminal(MatchmakingService.STATUS_MATCHED)
			await _composed_until(test, func() -> bool: return real_party.pf.multiplayer.shutdown_calls > 0 and not real_matchmaking.has_pending_cleanup(), 20)
		test._check(real_party.pf.multiplayer.shutdown_calls == 1,
			"[%s] exactly one reset is run: %d" % [scenario, real_party.pf.multiplayer.shutdown_calls])
		test._check(real_party.pf.multiplayer.arranged_calls.is_empty() and not NetManager.has_online_flow(),
			"[%s] no arranged match is joined and nothing of the old group is held" % scenario)
		if scenario == "failed_recovery":
			test._check(real_party.recovery_error == PartyService.RECOVERY_FAILED,
				"[%s] the failed reset latches the restart it needs" % scenario)
			var refused: Array = [null]
			_capture_quick_match(refused)
			await _composed_until(test, func() -> bool: return refused[0] != null, 20)
			test._check(refused[0] == false and NetManager.last_error == PartyService.RECOVERY_FAILED,
				"[%s] and Quick Match says a restart is needed: %s" % [scenario, NetManager.last_error])
			var hosted: Array = [null]
			_capture_host_match(hosted)
			await _composed_until(test, func() -> bool: return hosted[0] != null, 20)
			test._check(hosted[0] == false and NetManager.last_error == PartyService.RECOVERY_FAILED,
				"[%s] so does Host Match: %s" % [scenario, NetManager.last_error])
			real_clock.advance(MatchmakingFlow.CANCEL_GRACE_SECONDS * 3.0)
			await test.get_tree().process_frame
			test._check(real_party.pf.multiplayer.shutdown_calls == 1, "[%s] and no reset is asked for again" % scenario)
			await _teardown_composed(test)
			continue
		test._check(not real_matchmaking.has_pending_cleanup() and not real_matchmaking.has_orphaned_matched_cancel(),
			"[%s] the confirmed reset leaves nothing of the old ticket owed" % scenario)
		var released_by_reset := false
		var lost_race := false
		for line: String in real_matchmaking.fake_warnings:
			released_by_reset = released_by_reset or line.contains("cancel_released_by_reset")
			lost_race = lost_race or line.contains("cancel_lost_race")
		test._check(released_by_reset and not lost_race,
			"[%s] and the held cancel is logged as released by that reset, not as a lost race" % scenario)
		# The old runtime's late answers: a terminal publication for its destroyed ticket, which the
		# addon no longer delivers and which settles nothing, and a lobby leave the reset already
		# settled.
		ticket.publish_terminal(MatchmakingService.STATUS_CANCELLED)
		lobby.block_leave = false
		lobby.leave_released.emit()
		await test.get_tree().process_frame
		test._check(not real_matchmaking.has_pending_cleanup() and not real_party.is_cleanup_pending()
			and real_party.pf.multiplayer.shutdown_calls == 1 and lobby.leaves == 1,
			"[%s] late old answers change nothing and call nothing again: %d leaves" % [scenario, lobby.leaves])
		var reopened: Array = [null]
		_capture_quick_match(reopened)
		await _composed_until(test, func() -> bool: return reopened[0] != null, 20)
		_complete_activity()
		test._check(reopened[0] == true and NetManager.is_online_flow_live(),
			"[%s] and starts Quick Match without a restart: %s" % [scenario, NetManager.last_error])
		await _teardown_composed(test)


## Migration, over the real services: the supported addon answers a cancel that lost its race
## to a match. The owner cancels, and the service then matches the ticket -- the answer
## delivered before the terminal notice, as the addon delivers it, or just after it -- or the
## account goes or the title suspends with the cancel still waiting and the match lands after
## that. The group, if it is still there, ends with its reason and joins nothing; the answer
## resolves the cancel, so nothing is owed, no reset is ever asked for, the cancel is logged as
## a lost race, and Quick Match starts again. An invitation accepted by the next account while
## that cancel was still waiting is joined once the answer lands, under the time it arrived.
func _m1_answered_lost_race_needs_no_reset(test: Node) -> void:
	print("CASE: M1 over the real services a cancel that loses its race to a match is answered: nothing owed, no reset, the group joins nothing, and Quick Match starts again")
	for scenario: String in ["completion_first", "event_first", "account_removed", "suspended", "invitation_waits"]:
		await _setup_composed(test, "m1-" + scenario)
		var menu: NRScreen = _composed_menu(test) if scenario == "invitation_waits" else null
		var flow := await _composed_searching_group(test)
		var ticket := _composed_ticket()
		if flow == null or ticket == null:
			if menu != null:
				await _end_composed_menu(test, menu)
			await _teardown_composed(test)
			continue
		if scenario == "event_first":
			ticket.terminal_delivery_order = &"event_first"
		flow.cancel_search()
		await test.get_tree().process_frame
		test._check(ticket.cancel_waiting and ticket.cancel_calls == 1 and real_matchmaking.has_pending_cleanup(),
			"[%s] the owner's cancel is one native request, waiting on the service's answer" % scenario)
		var target := "m1-%s-target" % scenario
		var arrived_since := 0
		if scenario in ["completion_first", "event_first"]:
			ticket.publish_terminal(MatchmakingService.STATUS_MATCHED)
			test._check(flow.retired and NetManager.last_disconnect_reason == MatchmakingFlow.TEXT_MATCH_ABANDONED,
				"[%s] the old group ends with its reason: %s" % [scenario, NetManager.last_disconnect_reason])
		else:
			if scenario == "suspended":
				NetManager.abandon_for_suspend()
				Services.invalidate_saves_for_resume()
				var resumed: Array = [false]
				_capture_suspend_teardown(resumed)
				test._check(await _composed_until(test, func() -> bool: return bool(resumed[0]), 60, 1.0),
					"[%s] the resume's deferred teardown finishes" % scenario)
			else:
				Services.cancel_sign_in()
				await test.get_tree().process_frame
				test._check(await _composed_until(test, func() -> bool: return not NetManager.is_account_teardown_pending(), 60, 1.0),
					"[%s] the old account's teardown finishes" % scenario)
			if not Services.is_account_ready():
				var signed_in: Array = [null]
				_capture_sign_in(signed_in)
				test._check(await _composed_until(test, func() -> bool: return Services.is_account_ready(), 40),
					"[%s] the next account signs in" % scenario)
			test._check(real_party.pf.multiplayer.shutdown_calls == 0 and ticket.cancel_waiting,
				"[%s] with the cancel still waiting, nothing has been reset" % scenario)
			if scenario == "invitation_waits":
				_composed_hosted_lobby(_key("m1-host"), target)
				InviteRouter._on_join_requested({"connection_string": target})
				arrived_since = InviteRouter._pending_since_msec
				for _frame in 3:
					await test.get_tree().process_frame
				test._check(InviteRouter.has_pending_invite() and not real_party.pf.multiplayer.join_calls.has(target),
					"[%s] an invitation waits for the old ticket's cleanup" % scenario)
			ticket.publish_terminal(MatchmakingService.STATUS_MATCHED)
		test._check(not ticket.cancel_waiting and not real_matchmaking.has_orphaned_matched_cancel(),
			"[%s] the lost-race answer resolves the cancel" % scenario)
		if scenario == "invitation_waits":
			await _composed_until(test, func() -> bool: return real_party.pf.multiplayer.join_calls.has(target), 20)
			test._check(real_party.pf.multiplayer.join_calls.count(target) == 1 and not InviteRouter.has_pending_invite()
				and arrived_since > 0,
				"[%s] the invitation is then joined once, with its exact connection string" % scenario)
			await _end_composed_menu(test, menu)
		for _step in 3:
			real_clock.advance(MatchmakingFlow.CANCEL_GRACE_SECONDS)
			await test.get_tree().process_frame
		test._check(not real_matchmaking.has_pending_cleanup() and not NetManager.has_online_flow()
			and real_party.pf.multiplayer.shutdown_calls == 0 and real_party.pf.party.shutdown_calls == 0
			and not real_party.is_cleanup_pending(),
			"[%s] nothing is owed and no reset is ever asked for" % scenario)
		test._check(real_party.pf.multiplayer.arranged_calls.is_empty(), "[%s] the match it let go of is never joined" % scenario)
		var lost_race := false
		var released_by_reset := false
		for line: String in real_matchmaking.fake_warnings:
			lost_race = lost_race or line.contains("cancel_lost_race")
			released_by_reset = released_by_reset or line.contains("cancel_released_by_reset")
		test._check(lost_race and not released_by_reset,
			"[%s] and the cancel is logged as a lost race, not as released by a reset" % scenario)
		if scenario != "invitation_waits":
			var reopened: Array = [null]
			_capture_quick_match(reopened)
			await _composed_until(test, func() -> bool: return reopened[0] != null, 20)
			_complete_activity()
			test._check(reopened[0] == true and NetManager.is_online_flow_live(),
				"[%s] and Quick Match starts again: %s" % [scenario, NetManager.last_error])
		await _teardown_composed(test)


## Migration, over the real services: a ticket creation the service cancels before it returns
## an id -- after the owner's Cancel, or on its own -- comes back as a cancellation, never as a
## failure. The group gathers again, unready and reopened, with no ticket owed and nothing
## reset; the owner's Cancel keeps its own reason.
func _m2_creation_cancelled_before_an_id_restores_the_group(test: Node) -> void:
	print("CASE: M2 over the real services a ticket creation cancelled before its id restores the group as a cancellation, never a failure")
	for scenario: String in ["owner_cancel", "service_cancel"]:
		await _setup_composed(test, "m2-" + scenario)
		var flow := await _composed_group(test)
		if flow == null:
			await _teardown_composed(test)
			continue
		real_matchmaking.sdk.block_create = true
		real_matchmaking.sdk.queued_create_results.append(ServiceDoubles.Results.match_ticket_create_cancelled())
		NetManager.set_local_ready(true)
		var creating: bool = await _composed_until(test, func() -> bool: return real_matchmaking.sdk.create_calls.size() == 1, 20)
		test._check(creating and flow.phase == MatchmakingFlow.Phase.CREATING_TICKET,
			"[%s] the ticket's creation is under way (phase %d)" % [scenario, flow.phase])
		if scenario == "owner_cancel":
			flow.cancel_search()
		real_matchmaking.sdk.block_create = false
		real_matchmaking.sdk.create_released.emit()
		var gathered: bool = await _composed_until(test, func() -> bool: return flow.phase == MatchmakingFlow.Phase.GATHERING, 20)
		_complete_activity()
		var own_state := NetManager.local_player()
		test._check(gathered and flow.is_live() and own_state != null and not own_state.is_ready,
			"[%s] the group gathers again, unready (phase %d)" % [scenario, flow.phase])
		test._check(flow.reason_code != &"ticket_create_failed",
			"[%s] as a cancellation, not a failure: %s '%s'" % [scenario, flow.reason_code, flow.reason])
		if scenario == "owner_cancel":
			test._check(flow.reason_code == MatchmakingFlow.REASON_CANCELLED and flow.reason == MatchmakingFlow.TEXT_CANCELLED,
				"[%s] the owner's Cancel keeps its own reason: '%s'" % [scenario, flow.reason])
		test._check(not real_matchmaking.has_pending_cleanup() and real_party.pf.multiplayer.shutdown_calls == 0,
			"[%s] with no ticket owed and nothing reset" % scenario)
		await _teardown_composed(test)


## Item 9, over the real PartyService: a Party network's recoverable error, carrying sensitive
## words in its message and data, reaches the log as PartyService's one safe record and nothing
## else -- NetManager adds no second diagnostic and keeps none of the SDK's words -- and the
## group or hosted session carries on. The host's refusal of a peer's handshake -- either
## rejection, with no peer id -- is such an error, on the group's transport and on a hosted
## session's network alike, and its record names it by its allowlisted code.
func _c9_scoped_network_error_is_logged_once_and_safely(test: Node) -> void:
	print("CASE: C9 a Party network's recoverable error, including a refused peer handshake, is logged once, safely, and the group or hosted session carries on")
	var forms := [
		["scoped", "party_network_connect_failed"],
		["scoped", "party_handshake_entity_mismatch"],
		["scoped", "party_handshake_endpoint_entity_unavailable"],
		["hosted", "party_handshake_entity_mismatch"],
		["hosted", "party_handshake_endpoint_entity_unavailable"],
	]
	for form: Array in forms:
		var path := String(form[0])
		var code := String(form[1])
		var label := "%s %s" % [path, code]
		await _setup_composed(test, "c9-%s-%s" % [path, code])
		var flow: MatchmakingFlow = null
		if path == "scoped":
			flow = await _composed_group(test)
			if flow == null:
				await _teardown_composed(test)
				continue
		else:
			var hosted: Array = [null]
			_capture_host_match(hosted)
			await _composed_until(test, func() -> bool: return hosted[0] != null, 20)
			test._check(hosted[0] == true and NetManager.has_session(), "[%s] a hosted session is up: %s" % [label, NetManager.last_error])
			if hosted[0] != true:
				await _teardown_composed(test)
				continue
		var network: ServiceDoubles.Network = real_party.pf.party.networks.back()
		var sentinel := "C9-SENTINEL-alpha C9-SENTINEL-bravo C9-SENTINEL-entity"
		var change := ServiceDoubles.Change.new()
		change.kind = PartyService.NETWORK_CHANGE_ERROR
		change.network = network
		change.peer_id = 0
		change.reason = sentinel
		change.result = ServiceDoubles.Results.make(
			false, {"party_error": 12, "state_change_result": 3, "note": sentinel},
			code, sentinel, -2147467259)
		var recorded := real_party.fake_warnings.size()
		var tap := LogTap.new()
		OS.add_logger(tap)
		network.state_changed.emit(change)
		OS.remove_logger(tap)
		var records: Array = real_party.fake_warnings.slice(recorded)
		var stage := "scoped_network_state" if path == "scoped" else "legacy_network_state"
		test._check(records.size() == 1 and String(records[0]).begins_with("[Party] failure stage=" + stage)
			and String(records[0]).contains("native_code=" + code),
			"[%s] PartyService logs its one structured record, under its allowlisted code: %s" % [label, str(records)])
		var leaked := false
		var repeated := false
		for line: String in Array(tap.lines) + records:
			leaked = leaked or line.contains("C9-SENTINEL")
			repeated = repeated or line.contains("non-fatal") or line.contains("[NetManager]")
		test._check(not leaked, "[%s] no log line carries the SDK's words" % label)
		test._check(not repeated, "[%s] and nothing after it claims a second failure" % label)
		test._check(not NetManager.last_error.contains("C9-SENTINEL") and NetManager.last_error == NetManager._CONTEXT_RECOVERABLE_FAILURE,
			"[%s] what is kept for the player is this title's text: %s" % [label, NetManager.last_error])
		if path == "scoped":
			test._check(flow.is_live() and NetManager.has_online_flow() and NetManager.has_session(),
				"[%s] and the group carries on" % label)
		else:
			test._check(NetManager.has_session() and NetManager.is_host(),
				"[%s] and the hosted session carries on" % label)
			NetManager.leave_match()
			await _composed_until(test, func() -> bool: return not real_party.is_cleanup_running() and not NetManager.has_session(), 20, 1.0)
		await _teardown_composed(test)


# --- Delta: cleanup readiness, the final teardown look, Practice, hosted continuity ---------

## A main menu under the router, as the title has one, for the composed invitation cases.
func _composed_menu(test: Node) -> NRScreen:
	ScreenManager.set_container(test)
	var menu := NRScreen.new()
	menu.scene_file_path = ScreenManager.MAIN_MENU
	ScreenManager._stack.append(menu)
	return menu


## Dismisses what an invitation case left open and stops a join it started -- waiting, on the
## composed clock, for that join to settle -- then empties the stack, so nothing it began is
## still waiting when the next case starts.
func _end_composed_menu(test: Node, menu: NRScreen) -> void:
	InviteRouter.decline_pending_invite()
	var joining: JoinRequest = NetManager._active_join_request
	if joining != null:
		NetManager.cancel_join(joining)
		await _composed_until(test, func() -> bool: return not joining.is_pending(), 40, 1.0)
	for _dialog in 3:
		var dialog: Variant = _composed_dialog()
		if dialog == null:
			break
		dialog.dismissed.emit(false)
		await test.get_tree().process_frame
	await test.get_tree().process_frame
	ScreenManager._stack.erase(menu)
	menu.queue_free()
	ScreenManager.clear()


## The dialog on top of the stack, or null.
func _composed_dialog() -> Variant:
	var screen: NRScreen = ScreenManager.current_screen()
	return screen if screen != null and screen.scene_file_path == ScreenManager.DIALOG_BOX else null


func _capture_transport_leave(context: PartyService.LobbyContext, box: Array) -> void:
	box[0] = await real_party.leave_transport(context)


## Delta item 1, over the real services: a group's lobby or Party transport whose native leave
## fails still owes its cleanup. The failed leave says so itself; the group keeps its lease;
## online entry stays refused; and an invitation accepted for the group is kept -- neither
## dispatched nor spent -- under the time it arrived, with no new network made, until Party's
## reset has confirmed both services. A confirmed reset then joins the invitation once, with its
## exact connection string. A newer invitation that arrived meanwhile is the one joined, and one
## that expired meanwhile is discarded. A failed reset answers the invitation once with the
## restart it needs and is not asked for again. Party asks for that reset as soon as the failed
## leave is known, so the case holds its Party shutdown at the SDK boundary while it looks at
## the window before the reset answers, then lets it answer.
func _d1_failed_native_leave_keeps_cleanup_and_the_invitation(test: Node) -> void:
	print("CASE: D1 over the real services a failed native lobby or transport leave keeps the group's cleanup, its lease and a kept invitation until the reset settles; a failed reset answers the invitation once")
	for form: String in ["lobby-reset", "transport-reset", "lobby-failed_reset", "transport-failed_reset", "lobby-newer", "transport-expired"]:
		await _setup_composed(test, "d1-" + form)
		var held_sdk := HeldPartySDK.new()
		real_party.pf.party = held_sdk
		var menu := _composed_menu(test)
		var flow := await _composed_group(test)
		if flow == null:
			await _end_composed_menu(test, menu)
			await _teardown_composed(test)
			continue
		var lobby_failure := form.begins_with("lobby")
		var context: PartyService.LobbyContext = flow.staging_context
		var staging_lobby: ServiceDoubles.Lobby = real_party.pf.multiplayer.lobbies.back()
		var staging_network: ServiceDoubles.Network = real_party.pf.party.networks.back()
		var target := "d1-%s-target" % form
		if form != "lobby-newer":
			_composed_hosted_lobby(_key("d1-host"), target)
		if lobby_failure:
			staging_lobby.next_leave_result = ServiceDoubles.Results.make(
				false, null, "lobby_leave_start_failed", "Injected lobby leave failure.", -2147467259)
		else:
			staging_network.next_leave_result = ServiceDoubles.Results.make(
				false, null, "party_resource_not_ready", "Injected transport leave failure.", -2147467259)
		if form.ends_with("failed_reset"):
			real_party.pf.multiplayer.next_shutdown_result = ServiceDoubles.Results.make(
				false, null, "shutting_down", "Injected scoped shutdown failure.", -2147467260)
		held_sdk.hold_shutdown = true
		var party_joins := real_party.pf.party.join_calls.size()
		var party_creates := real_party.pf.party.create_calls.size()
		var arrived_from := Time.get_ticks_msec()
		InviteRouter._on_join_requested({"connection_string": target})
		var arrived_to := Time.get_ticks_msec()
		var confirm: Variant = _composed_dialog()
		test._check(confirm != null and confirm._title == "Join Match",
			"[%s] an invitation for the live group asks before leaving it" % form)
		if confirm != null:
			confirm._ok_button.pressed.emit()
		var kept: bool = await _composed_until(test, func() -> bool: return InviteRouter.has_pending_invite(), 40, 0.5)
		var kept_since := InviteRouter._pending_since_msec
		test._check(kept and kept_since >= arrived_from and kept_since <= arrived_to and not InviteRouter._joining,
			"[%s] the invitation is kept, under the time it arrived, while the group's cleanup is owed" % form)
		test._check(held_sdk.shutdown_starts == 1 and real_party.pf.multiplayer.shutdown_calls == 0
			and real_party.is_cleanup_running(),
			"[%s] Party's reset is under way, held at the SDK boundary, while the window is looked at" % form)
		var direct: Array = [null]
		if lobby_failure:
			_capture_scoped_leave(context, direct)
		else:
			_capture_transport_leave(context, direct)
		var failed_leave: PartyService.PartyResult = direct[0]
		test._check(failed_leave != null and not failed_leave.ok() and failed_leave.cleanup_pending,
			"[%s] the failed leave reports its cleanup still owed" % form)
		test._check(NetManager.has_online_flow() and not NetManager.is_online_flow_live()
			and not real_party.context_is_quiescent(context) and real_party.has_owned_work(),
			"[%s] the group keeps its lease over a context that is not quiescent" % form)
		test._check(not real_party.pf.multiplayer.join_calls.has(target)
			and real_party.pf.party.join_calls.size() == party_joins and real_party.pf.party.create_calls.size() == party_creates,
			"[%s] nothing is joined and no network is made while it is unsafe" % form)
		test._check(StringName(NetManager.online_cleanup_readiness().get("state")) == NetManager.ONLINE_CLEANUP_PENDING,
			"[%s] online entry reads the cleanup as still settling" % form)
		var hosted: Array = [null]
		_capture_host_match(hosted)
		await _composed_until(test, func() -> bool: return hosted[0] != null, 10)
		test._check(hosted[0] == false and NetManager.last_error == NetManager._PREVIOUS_SESSION_FINISHING,
			"[%s] a direct Host Match is refused, not queued: %s" % [form, NetManager.last_error])
		if form == "lobby-newer":
			target = "d1-lobby-newer-replacement"
			_composed_hosted_lobby(_key("d1-newer-host"), target)
			InviteRouter._on_join_requested({"connection_string": target})
			test._check(InviteRouter.has_pending_invite() and String(InviteRouter._pending_request.get("connection_string", "")) == target,
				"[%s] a newer invitation replaces the kept one and waits the same way" % form)
			kept_since = InviteRouter._pending_since_msec
		if form == "transport-expired":
			InviteRouter._pending_since_msec -= int((InviteRouter.PENDING_TTL_SECONDS + 1.0) * 1000.0)
			kept_since = InviteRouter._pending_since_msec
		held_sdk.hold_shutdown = false
		held_sdk.shutdown_released.emit()
		await _composed_until(test, func() -> bool: return real_party.pf.multiplayer.shutdown_calls > 0, 40, 1.0)
		test._check(real_party.pf.party.shutdown_calls == 1 and real_party.pf.multiplayer.shutdown_calls == 1,
			"[%s] Party's reset asks both services once" % form)
		if form.ends_with("failed_reset"):
			await _composed_until(test, func() -> bool: return _composed_dialog() != null, 20)
			var refusal: Variant = _composed_dialog()
			test._check(real_party.recovery_error == PartyService.RECOVERY_FAILED and NetManager.has_online_flow()
				and not real_party.context_is_quiescent(context),
				"[%s] a failed reset keeps the lease and the owed cleanup" % form)
			test._check(refusal != null and refusal._title == "Cannot Join" and refusal._message == PartyService.RECOVERY_FAILED
				and not InviteRouter.has_pending_invite() and not real_party.pf.multiplayer.join_calls.has(target),
				"[%s] and answers the invitation once with the restart it needs" % form)
			if refusal != null:
				refusal._ok_button.pressed.emit()
			real_clock.advance(MatchmakingFlow.CANCEL_GRACE_SECONDS * 3.0)
			await test.get_tree().process_frame
			test._check(real_party.pf.multiplayer.shutdown_calls == 1 and _composed_dialog() == null,
				"[%s] the reset is not asked for again and nothing is answered twice" % form)
			await _end_composed_menu(test, menu)
			await _teardown_composed(test)
			continue
		if form == "transport-expired":
			await _composed_until(test, func() -> bool: return not NetManager.has_online_flow(), 20)
			for _frame in 3:
				await test.get_tree().process_frame
			test._check(not InviteRouter.has_pending_invite() and not real_party.pf.multiplayer.join_calls.has(target),
				"[%s] an invitation that expired while it waited is discarded, not joined" % form)
			await _end_composed_menu(test, menu)
			await _teardown_composed(test)
			continue
		test._check(InviteRouter._pending_since_msec == kept_since or not InviteRouter.has_pending_invite(),
			"[%s] the kept invitation keeps the time it arrived" % form)
		await _composed_until(test, func() -> bool: return real_party.pf.multiplayer.join_calls.has(target), 20)
		test._check(not NetManager.has_online_flow() and real_party.context_is_quiescent(context),
			"[%s] the confirmed reset settles the owed cleanup and releases the lease" % form)
		test._check(real_party.pf.multiplayer.join_calls.count(target) == 1 and not InviteRouter.has_pending_invite(),
			"[%s] then the invitation is joined once, with its exact connection string: %s" % [form, str(real_party.pf.multiplayer.join_calls)])
		if form == "lobby-newer":
			test._check(not real_party.pf.multiplayer.join_calls.has("d1-lobby-newer-target"),
				"[%s] and the older invitation is never joined" % form)
		await _end_composed_menu(test, menu)
		await _teardown_composed(test)


## Delta item 1's flowless case: after an account change, an old ticket's cancellation is still
## settling with no group left to own it. Direct entry is refused, and an invitation is kept --
## not dispatched into a refusal -- until that cleanup settles, then joined once.
func _d1_flowless_cleanup_keeps_the_invitation_after_account_change(test: Node) -> void:
	print("CASE: D1 after an account change an invitation waits for an old ticket's cleanup with no group left to own it, then is joined once; direct entry is refused meanwhile")
	await _setup_composed(test, "d1-flowless")
	var menu := _composed_menu(test)
	var flow := await _composed_searching_group(test)
	var ticket := _composed_ticket()
	if flow == null or ticket == null:
		await _end_composed_menu(test, menu)
		await _teardown_composed(test)
		return
	flow.cancel_search()
	await test.get_tree().process_frame
	test._check(ticket.cancel_waiting, "the owner's cancel waits on the service's answer")
	Services.cancel_sign_in()
	await test.get_tree().process_frame
	test._check(await _composed_until(test, func() -> bool: return not NetManager.is_account_teardown_pending(), 60, 1.0),
		"the old account's teardown finishes")
	var signed_in: Array = [null]
	_capture_sign_in(signed_in)
	test._check(await _composed_until(test, func() -> bool: return Services.is_account_ready(), 40), "the next account signs in")
	var readiness := NetManager.online_cleanup_readiness()
	test._check(not NetManager.has_online_flow() and real_matchmaking.has_pending_cleanup()
		and StringName(readiness.get("state")) == NetManager.ONLINE_CLEANUP_PENDING
		and String(readiness.get("reason")) == NetManager._PREVIOUS_SEARCH_FINISHING,
		"with no group left, the old ticket's cleanup still reads as settling: %s" % String(readiness.get("reason")))
	var joined := NetManager.join_by_code("ABCDE")
	test._check(joined.outcome == JoinRequest.Outcome.FAILED and joined.reason == NetManager._PREVIOUS_SEARCH_FINISHING,
		"a direct join is refused, for the player to try again: %s" % joined.reason)
	var target := "d1-flowless-target"
	_composed_hosted_lobby(_key("d1-flowless-host"), target)
	InviteRouter._on_join_requested({"connection_string": target})
	for _frame in 3:
		await test.get_tree().process_frame
	test._check(InviteRouter.has_pending_invite() and not real_party.pf.multiplayer.join_calls.has(target)
		and _composed_dialog() == null,
		"an invitation waits for that cleanup instead of being spent on the refusal")
	ticket.publish_terminal(MatchmakingService.STATUS_CANCELLED)
	await _composed_until(test, func() -> bool: return real_party.pf.multiplayer.join_calls.has(target), 20)
	test._check(not real_matchmaking.has_pending_cleanup() and real_party.pf.multiplayer.join_calls.count(target) == 1
		and not InviteRouter.has_pending_invite() and real_party.pf.multiplayer.shutdown_calls == 0,
		"once the ticket's cleanup settles, the invitation is joined once, with no reset needed")
	await _end_composed_menu(test, menu)
	await _teardown_composed(test)


## Delta item 2, over the real services: a match that lands on an old ticket while the account
## teardown's last step -- the chat control's destruction -- is still finishing. Answered as the
## lost race, it leaves nothing owed: the teardown finishes with no reset. With an injected
## observer that never answers, it is recovered before that teardown counts as finished, with
## no entry needed to trigger it, and the reset is confirmed while the teardown is still under
## way. A failed reset keeps the restart-required refusal and is not asked for again. A late
## answer from the old runtime changes nothing, and the next account signs in as usual.
func _d2_matched_during_the_final_teardown_await_is_recovered_first(test: Node) -> void:
	print("CASE: D2 a match on an old ticket during the teardown's final chat destruction needs no reset when answered; an injected unanswered one is recovered before the teardown finishes, and a failed reset stays restart-required")
	for scenario: String in ["answered", "recovered", "failed_recovery"]:
		var injected := scenario != "answered"
		await _setup_composed(test, "d2-" + scenario)
		var flow := await _composed_searching_group(test)
		var ticket := _composed_ticket()
		if flow == null or ticket == null:
			await _teardown_composed(test)
			continue
		if not chat.has_control():
			chat.set_chat_allowed(true)
			await chat.ensure_control(Services.playfab_user(), {})
		test._check(chat.has_control(), "[%s] the account holds a chat control the teardown destroys last" % scenario)
		ticket.cancel_fault_unanswered = injected
		flow.cancel_search()
		await test.get_tree().process_frame
		if scenario == "failed_recovery":
			real_party.pf.multiplayer.shutdown_hook = Callable()
			real_party.pf.multiplayer.next_shutdown_result = ServiceDoubles.Results.make(
				false, null, "shutting_down", "Injected scoped shutdown failure.", -2147467260)
		chat.sdk.hold_destroy = true
		var seen := {"teardown_at_reset": false, "teardown_at_failure": false}
		var on_reset := func(_epoch: int) -> void:
			seen["teardown_at_reset"] = NetManager.is_account_teardown_pending()
		var on_status := func(message: String) -> void:
			if message == PartyService.RECOVERY_FAILED:
				seen["teardown_at_failure"] = NetManager.is_account_teardown_pending()
		real_party.multiplayer_invalidated.connect(on_reset)
		real_party.cleanup_status_changed.connect(on_status)
		Services.cancel_sign_in()
		var held: bool = await _composed_until(test, func() -> bool: return chat.sdk.calls.size() > 0 and chat.sdk.calls.back().begins_with("destroy:"), 40, 1.0)
		test._check(held and NetManager.is_account_teardown_pending() and real_party.pf.multiplayer.shutdown_calls == 0
			and not real_matchmaking.has_orphaned_matched_cancel(),
			"[%s] the teardown reaches the chat control's destruction with nothing owed yet" % scenario)
		ticket.publish_terminal(MatchmakingService.STATUS_MATCHED)
		for _frame in 2:
			await test.get_tree().process_frame
		if not injected:
			test._check(not real_matchmaking.has_orphaned_matched_cancel() and not ticket.cancel_waiting
				and NetManager.is_account_teardown_pending() and real_party.pf.multiplayer.shutdown_calls == 0,
				"[%s] the match lands while that destruction is still finishing, and answers the cancel" % scenario)
			chat.sdk.hold_destroy = false
			chat.sdk.destroy_released.emit()
			test._check(await _composed_until(test, func() -> bool: return not NetManager.is_account_teardown_pending(), 40, 1.0),
				"[%s] the teardown then finishes on its own" % scenario)
			real_party.multiplayer_invalidated.disconnect(on_reset)
			real_party.cleanup_status_changed.disconnect(on_status)
			var lost_race := false
			var released_by_reset := false
			for line: String in real_matchmaking.fake_warnings:
				lost_race = lost_race or line.contains("cancel_lost_race")
				released_by_reset = released_by_reset or line.contains("cancel_released_by_reset")
			test._check(real_party.pf.multiplayer.shutdown_calls == 0 and not real_matchmaking.has_pending_cleanup()
				and lost_race and not released_by_reset,
				"[%s] with no reset at all: the cancel is logged as a lost race, nothing is owed" % scenario)
			var answered_in: Array = [null]
			_capture_sign_in(answered_in)
			test._check(await _composed_until(test, func() -> bool: return Services.is_account_ready(), 40),
				"[%s] the next account signs in" % scenario)
			var answered_quick: Array = [null]
			_capture_quick_match(answered_quick)
			await _composed_until(test, func() -> bool: return answered_quick[0] != null, 20)
			_complete_activity()
			test._check(answered_quick[0] == true and NetManager.is_online_flow_live() and real_party.pf.multiplayer.shutdown_calls == 0,
				"[%s] and starts Quick Match with nothing old owed and nothing reset: %s" % [scenario, NetManager.last_error])
			await _teardown_composed(test)
			continue
		test._check(real_matchmaking.has_orphaned_matched_cancel() and NetManager.is_account_teardown_pending()
			and real_party.pf.multiplayer.shutdown_calls == 0,
			"[%s] the match lands while that destruction is still finishing, its injected cancel unanswered" % scenario)
		chat.sdk.hold_destroy = false
		chat.sdk.destroy_released.emit()
		test._check(await _composed_until(test, func() -> bool: return not NetManager.is_account_teardown_pending(), 40, 1.0),
			"[%s] the teardown then finishes on its own" % scenario)
		real_party.multiplayer_invalidated.disconnect(on_reset)
		real_party.cleanup_status_changed.disconnect(on_status)
		test._check(real_party.pf.multiplayer.shutdown_calls == 1,
			"[%s] exactly one reset is run: %d" % [scenario, real_party.pf.multiplayer.shutdown_calls])
		if scenario == "recovered":
			test._check(bool(seen["teardown_at_reset"]) and not real_matchmaking.has_pending_cleanup(),
				"[%s] and it is confirmed before the teardown counts as finished" % scenario)
		else:
			test._check(bool(seen["teardown_at_failure"]) and real_party.recovery_error == PartyService.RECOVERY_FAILED,
				"[%s] and its failure is known before the teardown counts as finished" % scenario)
		ticket.publish_terminal(MatchmakingService.STATUS_CANCELLED)
		chat.sdk.destroy_released.emit()
		var signed_in: Array = [null]
		_capture_sign_in(signed_in)
		test._check(await _composed_until(test, func() -> bool: return Services.is_account_ready(), 40),
			"[%s] the next account signs in" % scenario)
		var quick: Array = [null]
		_capture_quick_match(quick)
		await _composed_until(test, func() -> bool: return quick[0] != null, 20)
		_complete_activity()
		if scenario == "recovered":
			test._check(quick[0] == true and NetManager.is_online_flow_live() and real_party.pf.multiplayer.shutdown_calls == 1,
				"[%s] and starts Quick Match with nothing old owed: %s" % [scenario, NetManager.last_error])
		else:
			real_clock.advance(MatchmakingFlow.CANCEL_GRACE_SECONDS * 3.0)
			await test.get_tree().process_frame
			test._check(quick[0] == false and NetManager.last_error == PartyService.RECOVERY_FAILED
				and real_party.pf.multiplayer.shutdown_calls == 1,
				"[%s] and Quick Match says a restart is needed, with no reset asked for again: %s" % [scenario, NetManager.last_error])
		await _teardown_composed(test)


## Delta item 4: flowless Practice after an account switch. With the old ticket's cleanup still
## settling, or Party's recovery of an injected unanswered cancel latched as failed, a ready
## account starts Practice. That makes no online call and asks for no reset, while Host, Quick
## Match and a join are still refused with the same reason as before.
func _d4_flowless_practice_after_an_account_switch(test: Node) -> void:
	print("CASE: D4 after an account switch Practice starts with online cleanup still settling or restart-required; online entry stays refused and nothing online is asked for")
	for scenario: String in ["pending", "failed"]:
		await _setup_composed(test, "d4-" + scenario)
		var flow := await _composed_searching_group(test)
		var ticket := _composed_ticket()
		if flow == null or ticket == null:
			await _teardown_composed(test)
			continue
		ticket.cancel_fault_unanswered = scenario == "failed"
		flow.cancel_search()
		await test.get_tree().process_frame
		if scenario == "failed":
			real_party.pf.multiplayer.shutdown_hook = Callable()
			real_party.pf.multiplayer.next_shutdown_result = ServiceDoubles.Results.make(
				false, null, "shutting_down", "Injected scoped shutdown failure.", -2147467260)
			ticket.publish_terminal(MatchmakingService.STATUS_MATCHED)
			await test.get_tree().process_frame
		Services.cancel_sign_in()
		await test.get_tree().process_frame
		test._check(await _composed_until(test, func() -> bool: return not NetManager.is_account_teardown_pending(), 60, 1.0),
			"[%s] the old account's teardown finishes" % scenario)
		var signed_in: Array = [null]
		_capture_sign_in(signed_in)
		test._check(await _composed_until(test, func() -> bool: return Services.is_account_ready(), 40),
			"[%s] the next account signs in" % scenario)
		var expected := NetManager._PREVIOUS_SEARCH_FINISHING if scenario == "pending" else PartyService.RECOVERY_FAILED
		var shutdowns := real_party.pf.multiplayer.shutdown_calls
		var creates := real_party.pf.party.create_calls.size()
		var lobby_joins := real_party.pf.multiplayer.join_calls.size()
		test._check(not NetManager.has_online_flow() and not NetManager.is_account_teardown_pending(),
			"[%s] no group or teardown holds the lease" % scenario)
		var practiced := NetManager.start_offline()
		test._check(practiced and NetManager.is_offline() and NetManager.has_session(),
			"[%s] a ready account starts Practice: %s" % [scenario, NetManager.last_error])
		real_clock.advance(MatchmakingFlow.CANCEL_GRACE_SECONDS * 3.0)
		await test.get_tree().process_frame
		test._check(real_party.pf.multiplayer.shutdown_calls == shutdowns and real_party.pf.party.create_calls.size() == creates
			and real_party.pf.multiplayer.join_calls.size() == lobby_joins,
			"[%s] Practice asks for no reset and makes no online call" % scenario)
		NetManager.leave_match()
		await test.get_tree().process_frame
		var hosted: Array = [null]
		_capture_host_match(hosted)
		await _composed_until(test, func() -> bool: return hosted[0] != null, 10)
		test._check(hosted[0] == false and NetManager.last_error == expected,
			"[%s] Host Match is still refused: %s" % [scenario, NetManager.last_error])
		var quick: Array = [null]
		_capture_quick_match(quick)
		await _composed_until(test, func() -> bool: return quick[0] != null, 10)
		test._check(quick[0] == false and NetManager.last_error == expected,
			"[%s] so is Quick Match: %s" % [scenario, NetManager.last_error])
		var joined := NetManager.join_by_code("ABCDE")
		test._check(joined.outcome == JoinRequest.Outcome.FAILED and joined.reason == expected,
			"[%s] and a join: %s" % [scenario, joined.reason])
		await _teardown_composed(test)


## Delta item 7, over the real PartyService: a hosted lobby joined before its owner had
## replicated, whose owner this guest then proves and is admitted under. When only its own
## lobby connection drops, the session carries on under that host. An owner cleared with that
## drop, a different owner, or a different peer 1 each end it once, applying nothing more.
func _d7_hosted_owner_proven_after_the_join_keeps_only_local_continuity(test: Node) -> void:
	print("CASE: D7 over the real PartyService a hosted owner proven after the join carries its session through a local-only lobby drop; an owner cleared with it, another owner or another peer 1 end it once")
	var owner := _key("d7-host")
	var outcomes := {
		"local_only": "",
		"owner_cleared": NetManager._HOST_CHANGED,
		"other_owner": NetManager._HOST_CHANGED,
		"other_peer": NetManager._HOST_CHANGED,
	}
	for scenario: String in outcomes.keys():
		await _setup_composed(test, "d7-" + scenario)
		var connection := "d7-%s-connection" % scenario
		var hosted := _composed_hosted_lobby(owner, connection)
		var lobby: ServiceDoubles.Lobby = hosted["lobby"]
		var peer: RecordingPeer = hosted["peer"]
		lobby.owner_entity_key = {}
		var request := NetManager.join_by_invite(connection)
		await test.get_tree().process_frame
		test._check(NetManager._peer == peer and request.is_pending(),
			"[%s] the join binds with no owner known yet" % scenario)
		if NetManager._peer != peer:
			await _teardown_composed(test)
			continue
		peer.connect_remote(NetManager.HOST_PEER_ID)
		NetManager._request_player_identity()
		test._check(_rpc_calls(peer) == 0, "[%s] nothing is sent before the owner is known" % scenario)
		lobby.owner_entity_key = owner.duplicate()
		real_clock.advance(MatchmakingFlow.POLL_SECONDS)
		await test.get_tree().process_frame
		test._check(_rpc_calls(peer) == 1, "[%s] once the owner arrives, the host is answered once" % scenario)
		_host_replays_and_accepts("D7 Host")
		real_clock.advance(MatchmakingFlow.POLL_SECONDS)
		await test.get_tree().process_frame
		test._check(request.succeeded() and NetManager.has_session(), "[%s] and the guest is admitted" % scenario)
		match scenario:
			"owner_cleared":
				lobby.owner_entity_key = {}
			"other_owner":
				lobby.owner_entity_key = _key("d7-other-owner")
			"other_peer":
				peer.keys[1] = _key("d7-other-peer")
		lobby.disconnected = true
		var seen := _send_host_state(5)
		if scenario == "local_only":
			test._check(bool(seen["applied"]) and int(seen["ends"]) == 0 and NetManager.has_session(),
				"[%s] with only its own lobby connection gone, the session carries on under that host" % scenario)
		else:
			test._check(not bool(seen["applied"]) and int(seen["ends"]) == 1 and not NetManager.has_session(),
				"[%s] the session ends once, applying nothing: %d ends" % [scenario, int(seen["ends"])])
			test._check(NetManager.last_disconnect_reason == String(outcomes[scenario]),
				"[%s] with this title's reason: %s" % [scenario, NetManager.last_disconnect_reason])
		await _teardown_composed(test)


# --- F5: debt that outlives its owner, and the quit that meets it --------------------------

## Starts Quick Match with the group's opening held at its lobby or its Party network, and a
## late leave failure set for the one that is held. True once the opening is waiting on it.
func _hold_group_opening(test: Node, resource: String, opened: Array) -> bool:
	var failure := ServiceDoubles.Results.make(false, null,
		"lobby_leave_start_failed" if resource == "lobby" else "party_resource_not_ready",
		"Injected late leave failure.", -2147467259)
	if resource == "lobby":
		real_party.pf.multiplayer.next_created_lobby_leave_result = failure
		real_party.pf.multiplayer.block_create = true
	else:
		real_party.pf.party.next_created_network_leave_result = failure
		real_party.pf.party.block_create = true
	_capture_quick_match(opened)
	var held: bool = await _composed_until(test, func() -> bool: return _late_opening_held(resource), 20)
	test._check(held and opened[0] == null and NetManager.has_online_flow(),
		"[%s] the group's opening is held at its %s" % [resource, resource])
	return held and opened[0] == null


## The group's opening held at its lobby or its Party network while the owner leaves. The
## flow and its global cleanup finish -- that cleanup resets the runtime at its deadline, over
## the opening still outstanding -- and, when `release` is set, the held opening then answers
## late: the native leave of its stale lobby or transport fails. Nothing owns what that leaves.
## The held opening stands in for any failed leave left with no owner; the runtime's own
## ordering can differ.
## Returns the Lobby shutdowns counted before the late answer, or -1 if the setup failed.
func _composed_late_leave_failure(test: Node, resource: String, release: bool = true) -> int:
	var opened: Array = [null]
	var held: bool = await _hold_group_opening(test, resource, opened)
	if not held:
		return -1
	NetManager.leave_match()
	var settled: bool = await _composed_until(test, func() -> bool: return _late_opening_settled(opened), 40, 1.0)
	test._check(settled and opened[0] == false,
		"[%s] the owner's leave ends the group and its cleanup finishes" % resource)
	if not settled:
		return -1
	var shutdowns := real_party.pf.multiplayer.shutdown_calls
	if release:
		_release_late_opening(resource)
	return shutdowns


## Whether the group's opening is waiting on its held lobby or Party network creation.
func _late_opening_held(resource: String) -> bool:
	var held: Signal = real_party.pf.multiplayer.create_released if resource == "lobby" \
		else real_party.pf.party.create_released
	return not held.get_connections().is_empty()


func _release_late_opening(resource: String) -> void:
	if resource == "lobby":
		real_party.pf.multiplayer.block_create = false
		real_party.pf.multiplayer.create_released.emit()
	else:
		real_party.pf.party.block_create = false
		real_party.pf.party.create_released.emit()


func _late_opening_settled(opened: Array) -> bool:
	return opened[0] != null and not NetManager.has_online_flow() and not real_party.is_cleanup_running()


func _party_debt_settled() -> bool:
	return not real_party.has_idle_cleanup_debt() and not real_party.is_cleanup_running()


## The debt a late failure leaves, read the moment it lands: owed, nothing running, no group or
## session holding the seat, and online entry reading it as cleanup still settling.
func _check_idle_debt(test: Node, label: String) -> void:
	test._check(real_party.has_idle_cleanup_debt() and not real_party.is_cleanup_running(),
		"[%s] the late failure leaves debt that nothing is running yet" % label)
	test._check(not NetManager.has_online_flow() and not NetManager.has_session()
		and StringName(NetManager.online_cleanup_readiness().get("state")) == NetManager.ONLINE_CLEANUP_PENDING,
		"[%s] with no group or session to own it, and online entry waiting on it" % label)


## F5 case 1. The late failure is recovered with no player action: the next idle frame asks
## Party's existing recovery once, both services confirm, the old context is gone, and Host
## Match, Quick Match and a join all work again.
func _f5_late_leave_failure_without_an_owner_is_recovered_once(test: Node) -> void:
	print("CASE: F5-debt a late lobby or transport leave that fails after its group's cleanup finished is recovered once with no player action; online entry then works")
	for resource: String in ["lobby", "transport"]:
		await _setup_composed(test, "f5-late-" + resource)
		var shutdowns := await _composed_late_leave_failure(test, resource)
		if shutdowns < 0:
			await _teardown_composed(test)
			continue
		_check_idle_debt(test, resource)
		test._check(real_party.pf.multiplayer.shutdown_calls == shutdowns,
			"[%s] nothing is reset inside the failure itself" % resource)
		await _composed_until(test, func() -> bool: return _party_debt_settled(), 20)
		test._check(real_party.pf.multiplayer.shutdown_calls == shutdowns + 1,
			"[%s] the next idle frame asks the existing recovery once: %d resets" % [resource, real_party.pf.multiplayer.shutdown_calls - shutdowns])
		test._check(not real_party.has_owned_work() and real_party.recovery_error.is_empty()
			and StringName(NetManager.online_cleanup_readiness().get("state")) == NetManager.ONLINE_CLEANUP_CLEAR,
			"[%s] the confirmed reset leaves the old context quiescent and online entry clear" % resource)
		var hosted: Array = [null]
		_capture_host_match(hosted)
		await _composed_until(test, func() -> bool: return hosted[0] != null, 20)
		test._check(hosted[0] == true and NetManager.is_host(),
			"[%s] Host Match then works: %s" % [resource, NetManager.last_error])
		NetManager.leave_match()
		await _composed_until(test, func() -> bool: return not real_party.is_cleanup_running() and not NetManager.has_session(), 20, 1.0)
		var quick: Array = [null]
		_capture_quick_match(quick)
		await _composed_until(test, func() -> bool: return quick[0] != null, 20)
		_complete_activity()
		test._check(quick[0] == true and NetManager.is_online_flow_live(),
			"[%s] so does Quick Match: %s" % [resource, NetManager.last_error])
		NetManager.leave_match()
		await _composed_until(test, func() -> bool: return not real_party.is_cleanup_running() and not NetManager.has_online_flow(), 40, 1.0)
		var target := "f5-late-%s-target" % resource
		_composed_hosted_lobby(_key("f5-host"), target)
		var joined := NetManager.join_by_invite(target)
		await _composed_until(test, func() -> bool: return real_party.pf.multiplayer.join_calls.has(target), 20)
		test._check(joined.is_pending() and real_party.pf.multiplayer.join_calls.count(target) == 1,
			"[%s] and so does a join: %s" % [resource, joined.reason])
		NetManager.cancel_join(joined)
		await _composed_until(test, func() -> bool: return not joined.is_pending(), 40, 1.0)
		await _teardown_composed(test)


## F5 case 2. A failed leave raised while Party's own cleanup is already running is that
## cleanup's to recover: the running leave takes it into its one recovery, on its own
## deadline, and nothing asks for a second reset.
func _f5_debt_raised_while_cleanup_runs_joins_that_cleanup(test: Node) -> void:
	print("CASE: F5-debt a failed leave raised while Party's cleanup runs is recovered by that cleanup, once, on its own deadline")
	await _setup_composed(test, "f5-running")
	var opened: Array = [null]
	var held: bool = await _hold_group_opening(test, "lobby", opened)
	if not held:
		await _teardown_composed(test)
		return
	var left_at := real_clock.now_msec()
	NetManager.leave_match()
	real_clock.advance(2.0)
	await test.get_tree().process_frame
	test._check(real_party.is_cleanup_running() and real_party.pf.multiplayer.shutdown_calls == 0,
		"the owner's leave is still running its cleanup")
	_release_late_opening("lobby")
	test._check(real_party.is_cleanup_running() and not real_party.has_idle_cleanup_debt(),
		"the late failure lands inside that running cleanup, not as debt for anyone else")
	var reset_at := 0
	for _step in 30:
		if reset_at == 0 and real_party.pf.multiplayer.shutdown_calls > 0:
			reset_at = real_clock.now_msec()
		if not real_party.is_cleanup_running():
			break
		real_clock.advance(0.5)
		await test.get_tree().process_frame
	if reset_at == 0 and real_party.pf.multiplayer.shutdown_calls > 0:
		reset_at = real_clock.now_msec()
	for _frame in 3:
		await test.get_tree().process_frame
	test._check(real_party.pf.multiplayer.shutdown_calls == 1 and real_party.pf.party.shutdown_calls == 1,
		"the running cleanup recovers it with its one reset: %d resets" % real_party.pf.multiplayer.shutdown_calls)
	test._check(reset_at > 0 and reset_at - left_at <= int(NRConst.MATCH_CLEANUP_SECONDS * 1000.0),
		"on the deadline it started with, which the late failure did not renew: %d ms" % (reset_at - left_at))
	test._check(not real_party.has_idle_cleanup_debt() and not real_party.has_owned_work()
		and StringName(NetManager.online_cleanup_readiness().get("state")) == NetManager.ONLINE_CLEANUP_CLEAR,
		"nothing is left owed and online entry is clear")
	await _teardown_composed(test)


## F5 case 3. A late failure that lands while another online session holds the seat resets
## nothing: the session carries on, and the debt stays visible until that session's own leave
## -- the existing safe boundary -- recovers it, once.
func _f5_live_replacement_keeps_the_seat_until_it_leaves(test: Node) -> void:
	print("CASE: F5-debt a late failure while another session holds the seat resets nothing; that session's own leave discharges it once")
	await _setup_composed(test, "f5-replacement")
	var shutdowns := await _composed_late_leave_failure(test, "transport", false)
	if shutdowns < 0:
		await _teardown_composed(test)
		return
	var target := "f5-replacement-target"
	var hosted_lobby := _composed_hosted_lobby(_key("f5-replacement-host"), target)
	var peer: RecordingPeer = hosted_lobby["peer"]
	var request := NetManager.join_by_invite(target)
	var bound: bool = await _composed_until(test, func() -> bool: return NetManager._peer == peer, 20)
	test._check(bound and request.is_pending(), "the replacement join binds its transport")
	peer.connect_remote(NetManager.HOST_PEER_ID)
	NetManager._request_player_identity()
	_host_replays_and_accepts("F5 Host")
	await _composed_until(test, func() -> bool: return request.succeeded(), 20)
	test._check(request.succeeded() and NetManager.has_session(), "another session holds the seat")
	_release_late_opening("transport")
	test._check(real_party.has_idle_cleanup_debt() and not real_party.is_cleanup_running(),
		"the late failure leaves its debt")
	for _step in 5:
		real_clock.advance(MatchmakingFlow.POLL_SECONDS)
		await test.get_tree().process_frame
	test._check(real_party.pf.multiplayer.shutdown_calls == shutdowns and NetManager.has_session()
		and request.succeeded() and real_party.has_idle_cleanup_debt(),
		"the live session is not reset, and the debt stays visible")
	NetManager.leave_match()
	await _composed_until(test, func() -> bool: return not real_party.is_cleanup_running() and not real_party.has_idle_cleanup_debt(), 40, 1.0)
	test._check(real_party.pf.multiplayer.shutdown_calls == shutdowns + 1 and not real_party.has_owned_work(),
		"that session's own leave recovers it, once: %d resets" % (real_party.pf.multiplayer.shutdown_calls - shutdowns))
	test._check(StringName(NetManager.online_cleanup_readiness().get("state")) == NetManager.ONLINE_CLEANUP_CLEAR,
		"and online entry is clear")
	await _teardown_composed(test)


## Closes a composed case's quit probe the way the RB2 cases close theirs, then tears the
## composed services down.
func _end_composed_quit(test: Node, app: Node) -> void:
	await test.get_tree().process_frame
	ScreenManager.clear()
	app.queue_free()
	await test.get_tree().process_frame
	ScreenManager.set_container(test)
	Services._shutting_down = false
	AudioManager.set_script(_probe_audio)
	PlayerProfile.apply_dict(PlayerProfile.to_dict())
	await _teardown_composed(test)


## Answers the platform calls a quit waits on, then reads whether it has exited.
func _quit_exited(app: Node) -> bool:
	_complete_activity()
	return app.quit_calls > 0


## F5 case 4. Quitting with unowned failed-leave debt, before the idle frame that would have
## recovered it: the quit runs the ordinary leave and its recovery at once, inside its one
## budget. With the reset confirmed promptly the quit exits once without waiting the budget
## out. With the reset held, frames keep coming only until that same budget ends, the quit
## exits once, and the late confirmation cannot quit again.
func _f5_quit_with_idle_debt_leaves_and_recovers_first(test: Node) -> void:
	print("CASE: F5-debt quitting with unowned failed-leave debt runs the leave and its recovery at once, within the one budget, and quits once")
	for scenario: String in ["prompt", "held"]:
		await _setup_composed(test, "f5-quit-" + scenario)
		var held_sdk := HeldPartySDK.new()
		real_party.pf.party = held_sdk
		var shutdowns := await _composed_late_leave_failure(test, "transport")
		if shutdowns < 0:
			await _teardown_composed(test)
			continue
		var starts := held_sdk.shutdown_starts
		_check_idle_debt(test, scenario)
		held_sdk.hold_shutdown = scenario == "held"
		var app := _open_quit_probe(test)
		var asked_at := real_clock.now_msec()
		app.request_shutdown()
		var budget: int = app._quit_deadline_msec
		test._check(held_sdk.shutdown_starts == starts + 1,
			"[%s] the quit's own leave asks the recovery at once, before its budget is spent" % scenario)
		if scenario == "prompt":
			var exited: bool = await _composed_until(test, func() -> bool: return _quit_exited(app), 10, 0.0)
			test._check(exited and app.quit_calls == 1 and real_clock.now_msec() == asked_at
				and app._quit_deadline_msec == budget and not real_party.has_idle_cleanup_debt(),
				"[prompt] the confirmed reset lets the quit exit once, with none of its budget waited out")
		else:
			test._check(app._quit_pending and app.quit_calls == 0 and real_party.is_cleanup_running(),
				"[held] the quit waits on the recovery it started")
			real_clock.advance(float(budget - 1 - real_clock.now_msec()) / 1000.0)
			await test.get_tree().process_frame
			test._check(app.quit_calls == 0 and app._quit_deadline_msec == budget,
				"[held] frames keep coming until one millisecond before the same budget ends")
			real_clock.advance(PartyService.POLL_INTERVAL)
			var cut_off: bool = await _composed_until(test, func() -> bool: return _quit_exited(app), 10, 0.0)
			test._check(cut_off and app.quit_calls == 1 and real_party.is_cleanup_running(),
				"[held] then the quit exits once, on that budget, leaving the held recovery as it is")
			held_sdk.hold_shutdown = false
			held_sdk.shutdown_released.emit()
			for _frame in 2:
				await test.get_tree().process_frame
			test._check(app.quit_calls == 1 and not real_party.is_cleanup_running() and not real_party.has_idle_cleanup_debt(),
				"[held] the late confirmation finishes the recovery without quitting again")
		held_sdk.hold_shutdown = false
		held_sdk.shutdown_released.emit()
		for _frame in 2:
			await test.get_tree().process_frame
		test._check(held_sdk.shutdown_starts == starts + 1,
			"[%s] the idle frame that follows asks for no second reset" % scenario)
		await _end_composed_quit(test, app)


## F5 case 5. The recovery of unowned debt fails: online entry says a restart is needed, the
## old context stays owed, nothing reads as clear and no reset is asked for again. The quit
## is not held by the failure as if it were a recovery still running.
func _f5_terminal_recovery_failure_stays_restart_required(test: Node) -> void:
	print("CASE: F5-debt a failed recovery of unowned debt stays restart-required, is not retried, and does not hold the quit")
	await _setup_composed(test, "f5-terminal")
	var shutdowns := await _composed_late_leave_failure(test, "lobby", false)
	if shutdowns < 0:
		await _teardown_composed(test)
		return
	real_party.pf.multiplayer.shutdown_hook = Callable()
	real_party.pf.multiplayer.next_shutdown_result = ServiceDoubles.Results.make(
		false, null, "shutting_down", "Injected scoped shutdown failure.", -2147467260)
	_release_late_opening("lobby")
	_check_idle_debt(test, "terminal")
	await _composed_until(test, func() -> bool: return not real_party.recovery_error.is_empty(), 20)
	test._check(real_party.recovery_error == PartyService.RECOVERY_FAILED and real_party.has_owned_work()
		and not real_party.is_cleanup_running() and not real_party.has_idle_cleanup_debt(),
		"the failed reset latches the restart it needs, the old context still owed and nothing running")
	test._check(StringName(NetManager.online_cleanup_readiness().get("state")) == NetManager.ONLINE_CLEANUP_RESTART_REQUIRED,
		"online entry reads it as restart-required, never clear")
	var hosted: Array = [null]
	_capture_host_match(hosted)
	await _composed_until(test, func() -> bool: return hosted[0] != null, 10)
	test._check(hosted[0] == false and NetManager.last_error == PartyService.RECOVERY_FAILED,
		"Host Match says a restart is needed: %s" % NetManager.last_error)
	var failed_resets := real_party.pf.multiplayer.shutdown_calls
	real_clock.advance(MatchmakingFlow.CANCEL_GRACE_SECONDS * 3.0)
	for _frame in 3:
		await test.get_tree().process_frame
	test._check(real_party.pf.multiplayer.shutdown_calls == failed_resets,
		"and no reset is asked for again")
	var app := _open_quit_probe(test)
	var asked_at := real_clock.now_msec()
	app.request_shutdown()
	var budget: int = app._quit_deadline_msec
	var exited: bool = await _composed_until(test, func() -> bool: return _quit_exited(app), 10, 0.0)
	test._check(exited and app.quit_calls == 1 and real_clock.now_msec() == asked_at and app._quit_deadline_msec == budget,
		"the quit exits once, with none of its budget spent waiting on the failure as a recovery still running")
	test._check(real_party.pf.multiplayer.shutdown_calls == failed_resets and real_party.recovery_error == PartyService.RECOVERY_FAILED,
		"and asks for no reset of its own, leaving the restart-required refusal in place")
	await _end_composed_quit(test, app)


## F5 case 6. An invitation that arrives during unowned failed-leave debt is kept, under the
## time it arrived and with its exact string, and nothing joins its target while the debt
## stands. A confirmed recovery then joins it once; a failed one answers it once with the
## restart it needs; a newer invitation that arrived meanwhile is the one joined; one that
## expired meanwhile is discarded. An account change before the recovery hands the debt to
## that account's teardown, which recovers it once; the kept invitation, still as it arrived,
## is joined once by the next account.
func _f5_invitation_waits_for_unowned_debt(test: Node) -> void:
	print("CASE: F5-debt an invitation during unowned failed-leave debt waits for its recovery: joined once on success, answered once on failure; newer, expired and account rules hold")
	for scenario: String in ["recovered", "failed", "newer", "expired", "account"]:
		await _setup_composed(test, "f5-invite-" + scenario)
		var menu := _composed_menu(test)
		var shutdowns := await _composed_late_leave_failure(test, "transport", false)
		if shutdowns < 0:
			await _end_composed_menu(test, menu)
			await _teardown_composed(test)
			continue
		if scenario == "failed":
			real_party.pf.multiplayer.shutdown_hook = Callable()
			real_party.pf.multiplayer.next_shutdown_result = ServiceDoubles.Results.make(
				false, null, "shutting_down", "Injected scoped shutdown failure.", -2147467260)
		var target := "f5-invite-%s-target" % scenario
		if scenario != "newer":
			_composed_hosted_lobby(_key("f5-invite-host"), target)
		_release_late_opening("transport")
		var arrived_from := Time.get_ticks_msec()
		InviteRouter._on_join_requested({"connection_string": target})
		var arrived_to := Time.get_ticks_msec()
		var kept_since := InviteRouter._pending_since_msec
		test._check(InviteRouter.has_pending_invite() and kept_since >= arrived_from and kept_since <= arrived_to
			and String(InviteRouter._pending_request.get("connection_string", "")) == target
			and not real_party.pf.multiplayer.join_calls.has(target) and _composed_dialog() == null,
			"[%s] the invitation is kept, exactly as it arrived, while the debt stands" % scenario)
		if scenario == "newer":
			target = "f5-invite-newer-replacement"
			_composed_hosted_lobby(_key("f5-invite-newer-host"), target)
			InviteRouter._on_join_requested({"connection_string": target})
			test._check(String(InviteRouter._pending_request.get("connection_string", "")) == target,
				"[newer] a newer invitation replaces the kept one")
		if scenario == "expired":
			InviteRouter._pending_since_msec -= int((InviteRouter.PENDING_TTL_SECONDS + 1.0) * 1000.0)
		if scenario == "account":
			Services.cancel_sign_in()
			var torn_down: bool = await _composed_until(test, func() -> bool: return not NetManager.is_account_teardown_pending(), 60, 1.0)
			test._check(torn_down and real_party.pf.multiplayer.shutdown_calls == shutdowns + 1 and _party_debt_settled()
				and not real_party.pf.multiplayer.join_calls.has(target),
				"[account] the account's teardown takes the debt into its own recovery, once, and joins nothing")
			test._check(InviteRouter.has_pending_invite() and InviteRouter._pending_since_msec == kept_since
				and String(InviteRouter._pending_request.get("connection_string", "")) == target,
				"[account] the invitation stays kept, as it arrived, for the next account")
			var signed_in: Array = [null]
			_capture_sign_in(signed_in)
			test._check(await _composed_until(test, func() -> bool: return Services.is_account_ready(), 40),
				"[account] the next account signs in")
		if scenario == "failed":
			await _composed_until(test, func() -> bool: return _composed_dialog() != null, 20)
			var refusal: Variant = _composed_dialog()
			test._check(refusal != null and refusal._title == "Cannot Join" and refusal._message == PartyService.RECOVERY_FAILED
				and not InviteRouter.has_pending_invite() and not real_party.pf.multiplayer.join_calls.has(target),
				"[failed] a failed recovery answers the invitation once, with the restart it needs")
			if refusal != null:
				refusal._ok_button.pressed.emit()
			for _frame in 3:
				await test.get_tree().process_frame
			test._check(_composed_dialog() == null, "[failed] and answers it only once")
		elif scenario == "expired":
			await _composed_until(test, func() -> bool: return _party_debt_settled(), 20)
			for _frame in 3:
				await test.get_tree().process_frame
			test._check(real_party.pf.multiplayer.shutdown_calls == shutdowns + 1 and InviteRouter._pending_request.is_empty()
				and not real_party.pf.multiplayer.join_calls.has(target) and _composed_dialog() == null,
				"[expired] an invitation that expired while the debt stood is discarded once it settles, not joined")
		else:
			await _composed_until(test, func() -> bool: return real_party.pf.multiplayer.join_calls.has(target), 20)
			test._check(real_party.pf.multiplayer.shutdown_calls == shutdowns + 1
				and real_party.pf.multiplayer.join_calls.count(target) == 1 and not InviteRouter.has_pending_invite(),
				"[%s] the confirmed recovery comes first, then one join with the exact string: %s" % [scenario, str(real_party.pf.multiplayer.join_calls)])
			if scenario == "newer":
				test._check(not real_party.pf.multiplayer.join_calls.has("f5-invite-newer-target"),
					"[newer] and the older invitation is never joined")
		await _end_composed_menu(test, menu)
		await _teardown_composed(test)


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
