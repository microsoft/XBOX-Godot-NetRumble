extends RefCounted

const Doubles := preload("res://tools/tests/pregame_service_doubles.gd")


func run(test: Node) -> void:
	var previous_party: PartyService = Services._party
	var previous_matchmaking: MatchmakingService = Services._matchmaking
	var previous_chat: ChatService = Services._chat
	var previous_clock: Variant = Services.clock() if Services.has_method("clock") else null

	await _s1_capability_and_profile_gates(test)
	await _s1_arranged_capacity_contract(test)
	await _s1_default_ticket_clock(test)
	await _s2_group_ticket_shape(test)
	await _s3_level_triggered_ticket_lifecycle(test)
	await _s3_guest_join_and_late_retirement(test)
	await _s4_failure_cancel_and_timeout(test)
	await _s4_native_cleanup_ownership(test)
	await _s4_observe_terminal_before_cancel(test)
	await _s5_scoped_lobby_ownership(test)
	await _s5_hosted_production_paths(test)
	await _s5_unavailable_kind_fence(test)
	await _s5_global_leave_and_overlap(test)
	await _s5_global_leave_waits_for_pending_prepare(test)
	await _s5_recovery_epoch_isolates_late_scoped_work(test)
	await _s5_serialized_operations_stop_after_leave(test)
	await _s5_transport_conflict_cleanup(test)
	await _s5_scoped_cancellation_and_owned_work(test)
	await _s5_contexts_release_after_leave(test)
	await _s6_scoped_deadline_ownership(test)
	await _s6_context_loss_and_admission(test)
	await _s7_arranged_control_and_publication(test)
	await _s8_invite_destinations(test)
	await _s9_multiplayer_invalidation(test)
	await _s10_staging_retirement_observation(test)

	Services._party = previous_party
	Services._matchmaking = previous_matchmaking
	Services._chat = previous_chat
	if previous_clock != null and Services.has_method("use_clock"):
		Services.use_clock(previous_clock)
	await test._reset()


func _s1_capability_and_profile_gates(test: Node) -> void:
	print("CASE: enabled Quick Match availability reports each production dependency exactly")
	var service := Doubles.Matchmaking.new()
	var user := Doubles.User.new("s1-local")
	test._check(MatchmakingService._FLOW_IMPLEMENTED,
		"the controlled Quick Match candidate is enabled")
	test._check(service.is_available() and service.availability_reason().is_empty(),
		"valid addon, queue and four-player profile make Quick Match available")

	service.fake_queue_name = ""
	test._check(not service.is_available()
		and service.availability_reason()
			== "Matchmaking is unavailable: no matchmaking queue is configured.",
		"empty queue reason=%s" % service.availability_reason())
	service.fake_queue_name = MatchmakingService.QUEUE_NAME

	service.fake_playfab_present = false
	test._check(not service.is_available()
		and service.availability_reason()
			== "Matchmaking needs the PlayFab extension, which this build does not have.",
		"missing PlayFab reason=%s" % service.availability_reason())
	service.fake_playfab_present = true

	service.fake_group_support = false
	test._check(not service.is_available()
		and service.availability_reason()
			== "This build's PlayFab addon cannot create group matchmaking tickets.",
		"missing group-ticket capability reason=%s" % service.availability_reason())
	service.fake_group_support = true

	service.fake_arranged_support = false
	test._check(not service.is_available()
		and service.availability_reason()
			== "This build's PlayFab addon cannot configure a matched lobby, so Quick Match is unavailable.",
		"missing arranged-lobby capability reason=%s" % service.availability_reason())
	service.fake_arranged_support = true

	for count: int in [3, 5]:
		service.fake_mode_config = _mode_config(count)
		var profile := service.runtime_profile(NRTypes.GameModeType.DEATHMATCH)
		test._check(not bool(profile.get("ok", false))
			and String(profile.get("reason_code", "")) == "profile_count_mismatch"
			and service.availability_reason()
				== "Quick Match needs the four-player Deathmatch settings.",
			"configured %d-player Deathmatch is unavailable through the shared profile gate" % count)
	service.fake_mode_config = null
	var missing := service.runtime_profile(NRTypes.GameModeType.DEATHMATCH)
	test._check(not bool(missing.get("ok", false))
		and String(missing.get("reason_code", "")) == "profile_missing"
		and not service.is_available()
		and service.availability_reason()
			== "Quick Match needs the four-player Deathmatch settings.",
		"missing Deathmatch reason=%s" % service.availability_reason())
	service.fake_mode_config = _mode_config(4)
	test._check(service.is_available() and service.availability_reason().is_empty()
		and bool(service.runtime_profile(NRTypes.GameModeType.DEATHMATCH).get("ok", false)),
		"configured four-player Deathmatch passes the runtime profile gate")
	var unsupported := service.runtime_profile(99)
	test._check(not bool(unsupported.get("ok", false))
		and String(unsupported.get("reason_code", "")) == "profile_unsupported_mode",
		"unsupported requested mode cannot use Assets' Deathmatch fallback")

	var empty := _spec(user, [], 1)
	var empty_attempt := service.begin_create(empty)
	test._check(empty_attempt.outcome == MatchmakingService.Outcome.FAILED,
		"empty groups fail before native create")
	test._check(service.sdk.create_calls.is_empty(),
		"invalid direct entry never reaches the SDK")

	var mismatched := _spec(user, [user.entity_key], 2)
	mismatched.expected_match_count = 8
	var mismatch_attempt := service.begin_create(mismatched)
	test._check(mismatch_attempt.outcome == MatchmakingService.Outcome.FAILED,
		"non-four-player profile fails before native create")
	test._check(service.sdk.create_calls.is_empty(),
		"profile drift cannot bypass the unavailable UI")

	service.fake_mode_config = _mode_config(3)
	var forged_create := _spec(user, [user.entity_key], 3)
	forged_create.expected_match_count = 4
	var forged_create_attempt := service.begin_create(forged_create)
	var forged_join := _join_spec(user, [user.entity_key], 4, "forged-ticket")
	forged_join.expected_match_count = 4
	var forged_join_attempt := service.begin_join(forged_join)
	test._check(forged_create_attempt.outcome == MatchmakingService.Outcome.FAILED
		and forged_join_attempt.outcome == MatchmakingService.Outcome.FAILED
		and service.sdk.create_calls.is_empty() and service.sdk.join_calls.is_empty(),
		"caller-supplied four cannot bypass a configured three-player profile")
	service.fake_mode_config = _mode_config(4)


func _s1_arranged_capacity_contract(test: Node) -> void:
	print("CASE: Phase 1 arranged capacity is caller-validated, native, and captured")
	var service := Doubles.Party.new(ChatService.new())
	service.configure_clock(service.fake_clock)
	var user := Doubles.User.new("arranged-capacity")
	for count: int in [3, 5]:
		var refused: PartyService.PartyResult = await service.join_arranged(
			user, "capacity-refused-%d" % count, {}, count, 1, count, 1000)
		test._check(not refused.ok()
			and refused.reason_code == &"arranged_profile_mismatch",
			"arranged count %d is refused with code=%s" % [
				count, refused.reason_code])
	test._check(service.pf.multiplayer.arranged_calls.is_empty(),
		"invalid arranged counts make zero native calls=%d" % \
			service.pf.multiplayer.arranged_calls.size())

	var accepted: PartyService.PartyResult = await service.join_arranged(
		user, "capacity-four", {}, 4, 1, 10, 1000)
	var accepted_snapshot := service.snapshot(accepted.context)
	var arranged_call: Dictionary = service.pf.multiplayer.arranged_calls[0]
	test._check(accepted.ok() and accepted.operation != null,
		"validated arranged join returns an owned operation handle")
	test._check(service.pf.multiplayer.arranged_calls.size() == 1
		and int(arranged_call.max_member_count) == 4
		and int(arranged_call.access_policy) == 2
		and int(arranged_call.owner_migration_policy) == 0
		and not bool(arranged_call.restrict_invites_to_lobby_owner),
		"arranged native config is private/four/automatic/unrestricted: %s" % \
			arranged_call)
	test._check(int(accepted_snapshot.expected_count) == 4
		and int(accepted_snapshot.max_members) == 4,
		"arranged snapshot preserves expected=%s native=%s" % [
			accepted_snapshot.expected_count, accepted_snapshot.max_members])
	var prepared: PartyService.PartyResult = await service.prepare_transport(
		accepted.context, user, service.fake_clock.now_msec() + 1000)
	test._check(prepared.ok(),
		"validated arranged capacity reaches transport preparation")
	var create_call: Dictionary = service.pf.party.create_calls.back() \
		if not service.pf.party.create_calls.is_empty() else {}
	test._check(int(create_call.max_players) == 4,
		"arranged transport receives captured capacity max_players=%s" % \
			create_call.get("max_players"))
	await service.leave_transport(accepted.context)
	await service.leave_lobby(accepted.context)

	var tampered: PartyService.PartyResult = await service.join_arranged(
		user, "capacity-tampered", {}, 4, 1, 12, 1000)
	var creates_before := service.pf.party.create_calls.size()
	tampered.context.expected_count = 3
	var tampered_prepare: PartyService.PartyResult = await service.prepare_transport(
		tampered.context, user, service.fake_clock.now_msec() + 1000)
	test._check(not tampered_prepare.ok(),
		"tampered arranged capacity is refused before transport creation")
	test._check(service.pf.party.create_calls.size() == creates_before,
		"tampered capacity native create calls=%d expected=%d" % [
			service.pf.party.create_calls.size(), creates_before])
	await service.leave_lobby(tampered.context)

	var mismatch_service := Doubles.Party.new(ChatService.new())
	mismatch_service.configure_clock(mismatch_service.fake_clock)
	var mismatch_lobby := Doubles.Lobby.new()
	mismatch_lobby.lobby_id = "arranged-capacity-eight"
	mismatch_lobby.connection_string = "arranged-capacity-eight-string"
	mismatch_lobby.owner_entity_key = user.entity_key.duplicate()
	mismatch_lobby.local_entity_key = user.entity_key.duplicate()
	mismatch_lobby.max_member_count = 8
	mismatch_lobby.access_policy = 2
	mismatch_lobby.owner_migration_policy = 0
	mismatch_lobby.restrict_invites_to_lobby_owner = false
	mismatch_lobby.members = [Doubles.Member.new(user.entity_key)]
	mismatch_service.pf.multiplayer.next_arranged_result = Doubles.Results.make(
		true, mismatch_lobby)
	var mismatched: PartyService.PartyResult = await mismatch_service.join_arranged(
		user, "capacity-native-eight", {}, 4, 1, 11, 1000)
	await _frames(test, 2)
	test._check(not mismatched.ok()
		and mismatched.reason_code == &"arranged_configuration_mismatch",
		"native capacity eight is refused code=%s" % mismatched.reason_code)
	test._check(mismatch_lobby.leaves == 1,
		"mismatched arranged lobby leaves=%d" % mismatch_lobby.leaves)
	test._check(mismatch_service._contexts.is_empty(),
		"mismatched arranged context registry=%d" % mismatch_service._contexts.size())
	test._check(mismatch_service._scoped_operations.is_empty(),
		"mismatched arranged scoped operations=%d" % \
			mismatch_service._scoped_operations.size())
	test._check(mismatch_service._owned_operation_count == 0,
		"mismatched arranged owned count=%d" % \
			mismatch_service._owned_operation_count)
	test._check(not mismatch_service.has_owned_work(),
		"mismatched arranged owned work=%s" % mismatch_service.has_owned_work())
	await _drain_clock(test, service.fake_clock, "S1 arranged capacity")
	await _drain_clock(test, mismatch_service.fake_clock, "S1 arranged mismatch")


func _s1_default_ticket_clock(test: Node) -> void:
	print("CASE: standalone matchmaking attempts always own a ticket deadline clock")
	var user := Doubles.User.new("default-clock")
	var standalone := Doubles.Matchmaking.new()
	var standalone_attempt := standalone.begin_create(
		_spec(user, [user.entity_key], 13))
	await _frames(test, 2)
	var production_clock: OnlineFlowClock = standalone_attempt.clock
	test._check(production_clock != null,
		"standalone attempt captures a production clock")
	test._check(standalone_attempt.deadline_alarm != null
		and production_clock.armed_alarm_count() == 1,
		"standalone attempt arms one deadline alarm count=%d" % \
			production_clock.armed_alarm_count())
	standalone.retire(standalone_attempt)
	test._check(standalone_attempt.deadline_alarm == null,
		"standalone retirement clears its alarm handle")
	test._check(production_clock.armed_alarm_count() == 0,
		"standalone retirement disarms the production clock count=%d" % \
			production_clock.armed_alarm_count())
	await _frames(test, 2)
	test._check(not standalone.has_pending_cleanup(),
		"standalone retirement reaches ticket quiescence")

	var configured := Doubles.Matchmaking.new()
	var fake_clock := Doubles.Clock.new()
	configured.configure_clock(fake_clock)
	var configured_attempt := configured.begin_create(
		_spec(user, [user.entity_key], 14))
	await _frames(test, 2)
	test._check(configured_attempt.clock == fake_clock,
		"configured attempt captures the supplied fake clock")
	test._check(fake_clock.armed_alarm_count() == 1,
		"configured fake owns one deadline alarm count=%d" % \
			fake_clock.armed_alarm_count())
	configured.retire(configured_attempt)
	test._check(fake_clock.armed_alarm_count() == 0,
		"configured retirement disarms its fake clock count=%d" % \
			fake_clock.armed_alarm_count())
	await _frames(test, 2)
	test._check(not configured.has_pending_cleanup(),
		"configured attempt returns cleanup ownership to zero")
	await _drain_clock(test, fake_clock, "S1 configured ticket clock")


func _s2_group_ticket_shape(test: Node) -> void:
	print("CASE: pregame S2 groups one through four reach the exact native shape")
	for group_size in range(1, 5):
		var service := Doubles.Matchmaking.new()
		var clock := Doubles.Clock.new()
		service.configure_clock(clock)
		var user := Doubles.User.new("s2-local-%d" % group_size)
		var members: Array[Dictionary] = [user.entity_key.duplicate()]
		for remote_index in range(group_size - 1):
			members.append({
				"id": "s2-remote-%d-%d" % [group_size, remote_index],
				"type": "title_player_account",
			})
		var attempt := service.begin_create(_spec(user, members, group_size))
		await _frames(test, 2)
		test._check(service.sdk.create_calls.size() == 1,
			"group %d reaches one native create" % group_size)
		var call: Dictionary = service.sdk.create_calls[0]
		test._check(call.queue_name == MatchmakingService.QUEUE_NAME,
			"group %d uses the configured queue" % group_size)
		test._check(call.timeout_seconds == 600,
			"group %d uses the approved native timeout" % group_size)
		test._check(call.members.size() == 1
			and call.members_to_match_with.size() == group_size - 1,
			"group %d supplies one local and %d remote premade keys" % [
				group_size, group_size - 1])
		var local_member: Doubles.MatchmakingMember = call.members[0]
		test._check(local_member.user == user and local_member.attributes.is_empty(),
			"group %d uses the production local-member mapping with empty attributes" % group_size)
		if group_size == 4:
			test._check(attempt.outcome == MatchmakingService.Outcome.PENDING,
				"full group is submitted rather than rejected locally")
		service.retire(attempt)
		test._check(clock.armed_alarm_count() == 0,
			"group %d retire cancels its deadline alarm count=%d" % [
				group_size, clock.armed_alarm_count()])
		await _frames(test, 1)
		await _drain_clock(test, clock, "S2 group %d" % group_size)

	var invalid := Doubles.Matchmaking.new()
	var invalid_user := Doubles.User.new("s2-invalid")
	var duplicate := _spec(
		invalid_user,
		[invalid_user.entity_key, invalid_user.entity_key],
		20)
	test._check(invalid.begin_create(duplicate).outcome == MatchmakingService.Outcome.FAILED,
		"duplicate entity keys fail before native create")
	test._check(invalid.sdk.create_calls.is_empty(),
		"duplicate entity keys never reach PlayFab")


func _s3_level_triggered_ticket_lifecycle(test: Node) -> void:
	print("CASE: pregame S3 snapshot reconciliation and duplicate status idempotence")
	var service := Doubles.Matchmaking.new()
	var user := Doubles.User.new("s3-local")
	var matched := Doubles.Ticket.new()
	matched.status = MatchmakingService.STATUS_MATCHED
	matched.match_id = "match-s3"
	matched.arranged_lobby_connection_string = "arrangement-s3"
	service.sdk.queued_create_results.append(Doubles.Results.make(true, matched))
	var attempt := service.begin_create(_spec(user, [user.entity_key], 30))
	await _frames(test, 2)
	test._check(attempt.outcome == MatchmakingService.Outcome.MATCHED,
		"already-matched snapshot settles without waiting for a future edge")
	test._check(attempt.match_id == "match-s3"
		and attempt.arrangement == "arrangement-s3",
		"matched snapshot copies handoff data")
	matched.emit_status(MatchmakingService.STATUS_MATCHED)
	test._check(attempt.outcome == MatchmakingService.Outcome.MATCHED,
		"duplicate terminal events cannot settle twice")
	service.retire(attempt)

	var duplicate_service := Doubles.Matchmaking.new()
	var duplicate_user := Doubles.User.new("s3-duplicate")
	var members := [duplicate_user.entity_key, {
		"id": "s3-remote",
		"type": "title_player_account",
	}, {
		"id": "s3-remote",
		"type": "title_player_account",
	}]
	var rejected := duplicate_service.begin_create(_spec(duplicate_user, members, 31))
	test._check(rejected.outcome == MatchmakingService.Outcome.FAILED
		and duplicate_service.sdk.create_calls.is_empty(),
		"duplicate premade members cannot create divergent tickets")


func _s3_guest_join_and_late_retirement(test: Node) -> void:
	print("CASE: pregame S3 guest join uses production mapping and owns late cleanup")
	var user := Doubles.User.new("s3-join-local")
	var members: Array = [
		{"id": "s3-join-owner", "type": "title_player_account"},
		user.entity_key.duplicate(),
	]
	var service := Doubles.Matchmaking.new()
	var accepted := Doubles.Ticket.new()
	accepted.ticket_id = "join-ticket"
	accepted.status = MatchmakingService.STATUS_WAITING_FOR_MATCH
	service.sdk.queued_join_results.append(Doubles.Results.make(true, accepted))
	var joined := service.begin_join(_join_spec(user, members, 32, "join-ticket"))
	await _frames(test, 2)
	test._check(service.sdk.join_calls.size() == 1
		and String(service.sdk.join_calls[0].ticket_id) == "join-ticket"
		and String(service.sdk.join_calls[0].queue_name) == MatchmakingService.QUEUE_NAME
		and (service.sdk.join_calls[0].local_members as Array).size() == 1
		and joined.status == MatchmakingService.STATUS_WAITING_FOR_MATCH,
		"guest passes id, queue and one local member, then reconciles the accepted snapshot")
	accepted.emit_status(MatchmakingService.STATUS_FAILED)
	accepted.emit_status(MatchmakingService.STATUS_FAILED)
	test._check(joined.outcome == MatchmakingService.Outcome.FAILED,
		"duplicate guest terminal events settle once")

	var immediate := Doubles.Matchmaking.new()
	immediate.sdk.queued_join_results.append(Doubles.Results.make(
		false, null, "join_rejected", "Injected join rejection."))
	var rejected := immediate.begin_join(_join_spec(user, members, 33, "rejected-ticket"))
	await _frames(test, 2)
	test._check(rejected.outcome == MatchmakingService.Outcome.FAILED
		and immediate.sdk.join_calls.size() == 1,
		"immediate guest join failure settles without a tracked ticket")

	var late := Doubles.Matchmaking.new()
	late.sdk.block_join = true
	var late_ticket := Doubles.Ticket.new()
	late_ticket.ticket_id = "late-ticket"
	late.sdk.queued_join_results.append(Doubles.Results.make(true, late_ticket))
	var retired := late.begin_join(_join_spec(user, members, 34, "late-ticket"))
	await _frames(test, 1)
	late.retire(retired)
	var current := late.begin_create(_spec(user, [user.entity_key], 35))
	late.sdk.block_join = false
	late.sdk.join_released.emit()
	await _frames(test, 3)
	test._check(retired.outcome == MatchmakingService.Outcome.SUPERSEDED
		and late_ticket.cancel_calls == 1 and current.is_pending()
		and not late.has_pending_cleanup(),
		"a retired blocked join cleans only its late ticket and cannot mutate the current attempt")
	late.retire(current)


func _s4_failure_cancel_and_timeout(test: Node) -> void:
	print("CASE: pregame S4 full-party rejection, cancellation, and timeout stay distinct")
	var user := Doubles.User.new("s4-local")
	var members := _full_group(user, "s4")

	var immediate := Doubles.Matchmaking.new()
	immediate.sdk.queued_create_results.append(Doubles.Results.make(
		false, null, "invalid_match_ticket_config", "Injected maximum-size rejection."))
	var immediate_attempt := immediate.begin_create(_spec(user, members, 40))
	await _frames(test, 2)
	_full_party_failure(test, immediate_attempt,
		"immediate full-party rejection has the specific durable outcome")
	test._check(immediate_attempt.ticket == null and not immediate_attempt.cleanup_pending,
		"no-ticket rejection does not wait for a nonexistent cancellation")

	var terminal := Doubles.Matchmaking.new()
	var failed_ticket := Doubles.Ticket.new()
	terminal.sdk.queued_create_results.append(Doubles.Results.make(true, failed_ticket))
	var terminal_attempt := terminal.begin_create(_spec(user, members, 41))
	await _frames(test, 2)
	failed_ticket.emit_status(MatchmakingService.STATUS_FAILED)
	_full_party_failure(test, terminal_attempt,
		"terminal full-party rejection uses the same durable outcome")

	var diagnostic_service := Doubles.Matchmaking.new()
	var diagnostic_ticket := Doubles.Ticket.new()
	diagnostic_ticket.properties = {"detail": "no match wording is not a structured outcome"}
	diagnostic_service.sdk.queued_create_results.append(
		Doubles.Results.make(true, diagnostic_ticket))
	var diagnostic_attempt := diagnostic_service.begin_create(
		_spec(user, [user.entity_key], 44))
	await _frames(test, 2)
	diagnostic_ticket.emit_status(
		MatchmakingService.STATUS_FAILED,
		Doubles.Results.make(false, null, "service_failure", "No match text from the service."))
	test._check(diagnostic_attempt.outcome == MatchmakingService.Outcome.FAILED
		and diagnostic_attempt.diagnostic.contains("service_failure")
		and diagnostic_attempt.diagnostic.contains("No match text"),
		"terminal event result is preserved and arbitrary no-match wording remains FAILED")

	var cancelling := Doubles.Matchmaking.new()
	var cancel_ticket := Doubles.Ticket.new()
	cancelling.sdk.queued_create_results.append(Doubles.Results.make(true, cancel_ticket))
	var cancel_attempt := cancelling.begin_create(_spec(user, [user.entity_key], 42))
	await _frames(test, 2)
	cancelling.request_cancel(cancel_attempt)
	await _frames(test, 2)
	test._check(cancel_attempt.outcome == MatchmakingService.Outcome.CANCELLED,
		"cancellation settles only after the ticket reaches terminal cancelled")

	var timing := Doubles.Matchmaking.new()
	var clock := Doubles.Clock.new()
	timing.configure_clock(clock)
	var timeout_ticket := Doubles.Ticket.new()
	timing.sdk.queued_create_results.append(Doubles.Results.make(true, timeout_ticket))
	var timeout_spec := _spec(user, [user.entity_key], 43)
	timeout_spec.deadline_msec = 600000
	var timeout_attempt := timing.begin_create(timeout_spec)
	await _frames(test, 2)
	test._check(clock.armed_alarm_count() == 1,
		"one ticket deadline alarm is armed, count=%d" % clock.armed_alarm_count())
	clock.advance(599.999)
	await _frames(test, 1)
	test._check(timeout_attempt.outcome == MatchmakingService.Outcome.PENDING,
		"search remains pending just before 600 seconds")
	clock.advance(0.001)
	await _frames(test, 2)
	test._check(timeout_attempt.outcome == MatchmakingService.Outcome.TIMEOUT,
		"local 600-second expiry remains distinct from service no-match")
	test._check(clock.armed_alarm_count() == 0,
		"ticket timeout retires its alarm, count=%d" % clock.armed_alarm_count())
	await _drain_clock(test, clock, "S4 timeout")
	for terminal_case: Dictionary in [
		{"status": MatchmakingService.STATUS_CANCELLED, "label": "cancelled"},
		{"status": MatchmakingService.STATUS_FAILED, "label": "failed"},
		{"status": MatchmakingService.STATUS_MATCHED, "label": "matched"},
	]:
		await _cancel_in_flight_timeout_race(
			test,
			user,
			int(terminal_case.status),
			String(terminal_case.label))


func _cancel_in_flight_timeout_race(
	test: Node,
	user: Doubles.User,
	terminal_status: int,
	label: String
) -> void:
	var service := Doubles.Matchmaking.new()
	var clock := Doubles.Clock.new()
	service.configure_clock(clock)
	var ticket := Doubles.Ticket.new()
	ticket.block_cancel = true
	if terminal_status != MatchmakingService.STATUS_CANCELLED:
		ticket.cancel_ok = false
	service.sdk.queued_create_results.append(Doubles.Results.make(true, ticket))
	var spec := _spec(user, [user.entity_key], 60 + terminal_status)
	spec.deadline_msec = 100
	var attempt := service.begin_create(spec)
	await _frames(test, 2)
	service.request_cancel(attempt)
	await _frames(test, 1)
	test._check(ticket.cancel_calls == 1,
		"[%s] cancellation starts exactly once calls=%d" % [
			label, ticket.cancel_calls])
	test._check(clock.armed_alarm_count() == 1,
		"[%s] original deadline remains armed while cancel is in flight" % label)
	clock.advance(0.1)
	await _frames(test, 2)
	test._check(attempt.outcome == MatchmakingService.Outcome.TIMEOUT,
		"[%s] deadline wins with immutable TIMEOUT outcome=%d" % [
			label, attempt.outcome])
	test._check(ticket.cancel_calls == 1,
		"[%s] timeout issues no second cancel calls=%d" % [
			label, ticket.cancel_calls])
	test._check(clock.armed_alarm_count() == 0,
		"[%s] timeout leaves no armed alarm count=%d" % [
			label, clock.armed_alarm_count()])
	test._check(service.has_pending_cleanup(),
		"[%s] held native cancel remains service-owned" % label)
	if terminal_status == MatchmakingService.STATUS_MATCHED:
		ticket.match_id = "cancel-race-match"
		ticket.arranged_lobby_connection_string = "cancel-race-arrangement"
		ticket.emit_status(MatchmakingService.STATUS_MATCHED)
	else:
		ticket.emit_status(terminal_status)
	test._check(attempt.outcome == MatchmakingService.Outcome.TIMEOUT,
		"[%s] terminal evidence cannot rewrite TIMEOUT" % label)
	if terminal_status == MatchmakingService.STATUS_MATCHED:
		test._check(attempt.match_id == "cancel-race-match"
			and attempt.arrangement == "cancel-race-arrangement",
			"[matched] terminal cleanup still captures handoff diagnostics")
	test._check(service.has_pending_cleanup(),
		"[%s] cancel await remains owned until its native return" % label)
	ticket.block_cancel = false
	ticket.cancel_released.emit()
	await _frames(test, 3)
	test._check(ticket.cancel_calls == 1,
		"[%s] native cancel total=%d" % [label, ticket.cancel_calls])
	test._check(attempt.outcome == MatchmakingService.Outcome.TIMEOUT,
		"[%s] caller outcome remains TIMEOUT after cancel return" % label)
	test._check(not attempt.cleanup_pending,
		"[%s] attempt cleanup_pending=%s" % [
			label, attempt.cleanup_pending])
	test._check(not service.has_pending_cleanup(),
		"[%s] service reaches ticket quiescence" % label)
	test._check(clock.armed_alarm_count() == 0,
		"[%s] final alarm count=%d" % [
			label, clock.armed_alarm_count()])
	await _drain_clock(test, clock, "S4 cancel-in-flight " + label)


func _s4_native_cleanup_ownership(test: Node) -> void:
	print("CASE: pregame S4 caller outcomes settle once while native cleanup remains owned")
	var user := Doubles.User.new("cleanup-local")

	var failed_service := Doubles.Matchmaking.new()
	var failed_ticket := Doubles.Ticket.new()
	failed_ticket.cancel_ok = false
	failed_service.sdk.queued_create_results.append(Doubles.Results.make(true, failed_ticket))
	var failed := failed_service.begin_create(_spec(user, [user.entity_key], 45))
	await _frames(test, 2)
	failed_service.request_cancel(failed)
	await _frames(test, 2)
	test._check(failed.outcome == MatchmakingService.Outcome.FAILED
		and failed.reason_code == &"cancel_unconfirmed"
		and failed.cleanup_pending and failed.ticket == failed_ticket
		and failed_service.has_pending_cleanup(),
		"failed cancel settles the caller but keeps the live ticket owned")
	failed_service.retire(failed)
	await _frames(test, 2)
	test._check(failed.outcome == MatchmakingService.Outcome.FAILED
		and failed.cleanup_pending and failed_ticket.cancel_calls == 2,
		"retiring a failed cancel keeps its outcome and performs one service-owned retry")
	failed_ticket.emit_status(MatchmakingService.STATUS_CANCELLED)
	test._check(failed.outcome == MatchmakingService.Outcome.FAILED
		and not failed.cleanup_pending and not failed_service.has_pending_cleanup(),
		"later terminal evidence clears cleanup without rewriting the caller outcome")

	var unconfirmed_service := Doubles.Matchmaking.new()
	var unconfirmed_ticket := Doubles.Ticket.new()
	unconfirmed_ticket.cancel_confirms_terminal = false
	unconfirmed_service.sdk.queued_create_results.append(
		Doubles.Results.make(true, unconfirmed_ticket))
	var unconfirmed := unconfirmed_service.begin_create(
		_spec(user, [user.entity_key], 46))
	await _frames(test, 2)
	unconfirmed_service.request_cancel(unconfirmed)
	await _frames(test, 2)
	test._check(unconfirmed.outcome == MatchmakingService.Outcome.FAILED
		and unconfirmed.cleanup_pending,
		"success-shaped cancel without terminal status remains unconfirmed and owned")
	unconfirmed_ticket.emit_status(MatchmakingService.STATUS_CANCELLED)
	test._check(not unconfirmed.cleanup_pending,
		"unconfirmed cancel ownership clears when terminal status eventually arrives")

	var race_service := Doubles.Matchmaking.new()
	var race_clock := Doubles.Clock.new()
	race_service.configure_clock(race_clock)
	var race_ticket := Doubles.Ticket.new()
	race_ticket.block_cancel = true
	race_service.sdk.queued_create_results.append(Doubles.Results.make(true, race_ticket))
	var race_spec := _spec(user, [user.entity_key], 47)
	race_spec.deadline_msec = 100
	var race := race_service.begin_create(race_spec)
	await _frames(test, 2)
	race_clock.advance(0.1)
	await _frames(test, 2)
	test._check(race.outcome == MatchmakingService.Outcome.TIMEOUT
		and race.cleanup_pending and race_ticket.cancel_calls == 1,
		"timeout settles once while its native cancel remains in flight")
	race_ticket.match_id = "late-match"
	race_ticket.arranged_lobby_connection_string = "late-arrangement"
	race_ticket.emit_status(MatchmakingService.STATUS_MATCHED)
	race_ticket.block_cancel = false
	race_ticket.cancel_released.emit()
	await _frames(test, 2)
	test._check(race.outcome == MatchmakingService.Outcome.TIMEOUT
		and race.match_id == "late-match" and not race.cleanup_pending
		and not race_service.has_pending_cleanup(),
		"matched-versus-timeout reconciles cleanup without replacing TIMEOUT")
	await _drain_clock(test, race_clock, "S4 timeout/match race")

	var retired_service := Doubles.Matchmaking.new()
	var retired_ticket := Doubles.Ticket.new()
	retired_ticket.block_cancel = true
	retired_service.sdk.queued_create_results.append(Doubles.Results.make(true, retired_ticket))
	var retired := retired_service.begin_create(_spec(user, [user.entity_key], 48))
	await _frames(test, 2)
	retired_service.retire(retired)
	test._check(retired.outcome == MatchmakingService.Outcome.SUPERSEDED
		and retired.cleanup_pending and retired_ticket.cancel_calls == 1,
		"retire is synchronous and leaves blocked native cleanup owned")
	retired_ticket.block_cancel = false
	retired_ticket.cancel_released.emit()
	await _frames(test, 2)
	test._check(not retired.cleanup_pending and not retired_service.has_pending_cleanup(),
		"retired cleanup clears only after native terminal completion")

	var matched_service := Doubles.Matchmaking.new()
	var matched_ticket := Doubles.Ticket.new()
	matched_ticket.status = MatchmakingService.STATUS_MATCHED
	matched_ticket.match_id = "matched"
	matched_ticket.arranged_lobby_connection_string = "arranged"
	matched_service.sdk.queued_create_results.append(Doubles.Results.make(true, matched_ticket))
	var matched := matched_service.begin_create(_spec(user, [user.entity_key], 49))
	await _frames(test, 2)
	matched_service.retire(matched)
	test._check(matched.outcome == MatchmakingService.Outcome.MATCHED
		and matched_ticket.cancel_calls == 0 and not matched.cleanup_pending,
		"retiring a natively matched ticket never issues cancellation")


func _s4_observe_terminal_before_cancel(test: Node) -> void:
	print("CASE: returned terminal ticket snapshots are observed before cancellation")
	var user := Doubles.User.new("observe-terminal")

	var owner_service := Doubles.Matchmaking.new()
	owner_service.sdk.block_create = true
	var owner_ticket := Doubles.Ticket.new()
	owner_ticket.status = MatchmakingService.STATUS_MATCHED
	owner_ticket.match_id = "owner-match"
	owner_ticket.arranged_lobby_connection_string = "owner-arrangement"
	owner_service.sdk.queued_create_results.append(Doubles.Results.make(true, owner_ticket))
	var owner_attempt := owner_service.begin_create(_spec(user, [user.entity_key], 50))
	await _frames(test, 1)
	owner_service.request_cancel(owner_attempt)
	owner_service.sdk.block_create = false
	owner_service.sdk.create_released.emit()
	await _frames(test, 2)
	test._check(owner_ticket.cancel_calls == 0
		and owner_attempt.outcome == MatchmakingService.Outcome.MATCHED
		and owner_attempt.match_id == "owner-match"
		and owner_attempt.arrangement == "owner-arrangement"
		and not owner_attempt.cleanup_pending,
		"owner observes already-Matched create result, copies data and never cancels it")

	var guest_service := Doubles.Matchmaking.new()
	guest_service.sdk.block_join = true
	var guest_ticket := Doubles.Ticket.new()
	guest_ticket.ticket_id = "guest-terminal"
	guest_ticket.status = MatchmakingService.STATUS_MATCHED
	guest_ticket.match_id = "guest-match"
	guest_ticket.arranged_lobby_connection_string = "guest-arrangement"
	guest_service.sdk.queued_join_results.append(Doubles.Results.make(true, guest_ticket))
	var guest_attempt := guest_service.begin_join(_join_spec(
		user,
		[{"id": "owner", "type": "title_player_account"}, user.entity_key],
		51,
		"guest-terminal"))
	await _frames(test, 1)
	guest_service.request_cancel(guest_attempt)
	guest_service.sdk.block_join = false
	guest_service.sdk.join_released.emit()
	await _frames(test, 2)
	test._check(guest_ticket.cancel_calls == 0
		and guest_attempt.outcome == MatchmakingService.Outcome.MATCHED
		and guest_attempt.match_id == "guest-match"
		and not guest_attempt.cleanup_pending,
		"guest observes already-Matched join result without a replayed event or cancel call")

	for terminal_status: int in [
		MatchmakingService.STATUS_CANCELLED,
		MatchmakingService.STATUS_FAILED,
	]:
		var terminal_service := Doubles.Matchmaking.new()
		terminal_service.sdk.block_create = true
		var terminal_ticket := Doubles.Ticket.new()
		terminal_ticket.status = terminal_status
		terminal_service.sdk.queued_create_results.append(
			Doubles.Results.make(true, terminal_ticket))
		var terminal_attempt := terminal_service.begin_create(
			_spec(user, [user.entity_key], 52 + terminal_status))
		await _frames(test, 1)
		terminal_service.request_cancel(terminal_attempt)
		terminal_service.sdk.block_create = false
		terminal_service.sdk.create_released.emit()
		await _frames(test, 2)
		var expected := MatchmakingService.Outcome.CANCELLED \
			if terminal_status == MatchmakingService.STATUS_CANCELLED \
			else MatchmakingService.Outcome.FAILED
		test._check(terminal_ticket.cancel_calls == 0
			and terminal_attempt.outcome == expected
			and not terminal_attempt.cleanup_pending,
			"returned terminal status %d is observed without cancellation" % terminal_status)

	var stale_service := Doubles.Matchmaking.new()
	stale_service.sdk.block_create = true
	var stale_ticket := Doubles.Ticket.new()
	stale_ticket.status = MatchmakingService.STATUS_MATCHED
	stale_ticket.match_id = "stale-match"
	stale_ticket.arranged_lobby_connection_string = "stale-arrangement"
	stale_service.sdk.queued_create_results.append(Doubles.Results.make(true, stale_ticket))
	var stale_attempt := stale_service.begin_create(_spec(user, [user.entity_key], 60))
	await _frames(test, 1)
	stale_service.fake_account_current = false
	stale_service.sdk.block_create = false
	stale_service.sdk.create_released.emit()
	await _frames(test, 2)
	test._check(stale_ticket.cancel_calls == 0
		and stale_attempt.outcome == MatchmakingService.Outcome.SUPERSEDED
		and stale_attempt.match_id == "stale-match"
		and stale_attempt.arrangement == "stale-arrangement"
		and not stale_attempt.cleanup_pending,
		"stale-account terminal result is observed and cleaned without surprise match or cancel")

	var attached_cancel_service := Doubles.Matchmaking.new()
	var attached_cancel_ticket := Doubles.Ticket.new()
	attached_cancel_service.sdk.queued_create_results.append(
		Doubles.Results.make(true, attached_cancel_ticket))
	var attached_cancel := attached_cancel_service.begin_create(
		_spec(user, [user.entity_key], 61))
	await _frames(test, 2)
	attached_cancel_ticket.status = MatchmakingService.STATUS_MATCHED
	attached_cancel_ticket.match_id = "attached-cancel-match"
	attached_cancel_ticket.arranged_lobby_connection_string = "attached-cancel-arrangement"
	attached_cancel_service.request_cancel(attached_cancel)
	await _frames(test, 1)
	test._check(attached_cancel_ticket.cancel_calls == 0
		and attached_cancel.outcome == MatchmakingService.Outcome.MATCHED
		and attached_cancel.match_id == "attached-cancel-match"
		and not attached_cancel.cleanup_pending
		and not attached_cancel_service.has_pending_cleanup(),
		"cancel re-reads an attached Matched snapshot with no signal and never calls native cancel")

	var attached_retire_service := Doubles.Matchmaking.new()
	var attached_retire_ticket := Doubles.Ticket.new()
	attached_retire_service.sdk.queued_create_results.append(
		Doubles.Results.make(true, attached_retire_ticket))
	var attached_retire := attached_retire_service.begin_create(
		_spec(user, [user.entity_key], 62))
	await _frames(test, 2)
	attached_retire_ticket.status = MatchmakingService.STATUS_MATCHED
	attached_retire_ticket.match_id = "attached-retire-match"
	attached_retire_ticket.arranged_lobby_connection_string = "attached-retire-arrangement"
	attached_retire_service.retire(attached_retire)
	await _frames(test, 1)
	test._check(attached_retire_ticket.cancel_calls == 0
		and attached_retire.outcome == MatchmakingService.Outcome.SUPERSEDED
		and attached_retire.match_id == "attached-retire-match"
		and not attached_retire.cleanup_pending
		and not attached_retire_service.has_pending_cleanup(),
		"retire re-reads an attached Matched snapshot with no signal and cleans without cancel")


func _s5_scoped_lobby_ownership(test: Node) -> void:
	print("CASE: pregame S5 staging and arranged lobby handles coexist and clean up by context")
	var chat := ChatService.new()
	var service := Doubles.Party.new(chat)
	var clock := Doubles.Clock.new()
	service.configure_clock(clock)
	var user := Doubles.User.new("s5-local")

	var staging: PartyService.PartyResult = await service.create_staging(
		user, 4, "deathmatch", 1, 50, 20000)
	var staging_ready := staging != null and staging.ok() and staging.context != null
	test._check(staging_ready,
		"staging creates one scoped lobby and transport")
	if not staging_ready:
		return
	var staging_context: PartyService.LobbyContext = staging.context
	test._check(service.snapshot(staging_context).kind == PartyService.LOBBY_KIND_STAGING,
		"staging context retains its kind and native handle")
	var published: PartyService.PartyResult = await service.publish_transport(
		staging_context, staging.publication_permit, "gathering")
	test._check(published != null and published.ok(),
		"descriptor publication is checked after activation permission")

	var arranged: PartyService.PartyResult = await service.join_arranged(
		user,
		"arrangement-s5",
		{
			MatchmakingService.PROTOCOL_MEMBER_KEY: NRProtocol.version_string(),
			PartyService.MATCH_ID_MEMBER_KEY: "match-s5",
		},
		4,
		1,
		50,
		30000)
	var arranged_ready := arranged != null and arranged.ok() \
		and arranged.context != null and arranged.context != staging_context
	test._check(arranged_ready,
		"arranged join creates a second independent lobby context")
	if not arranged_ready:
		await service.leave_transport(staging_context)
		await service.leave_lobby(staging_context)
		return
	test._check(service.lobby_id(staging_context).begins_with("staging-")
		and service.lobby_id(arranged.context).begins_with("arranged-"),
		"both captured lobby handles remain live after arranged join")

	service.pf.multiplayer.next_arranged_result = Doubles.Results.make(
		false, null, "arranged_failed", "Injected arranged failure.")
	var failed: PartyService.PartyResult = await service.join_arranged(
		user, "arrangement-fail", {}, 4, 1, 51, 30000)
	test._check(failed != null and not failed.ok()
		and not service.lobby_id(staging_context).is_empty(),
		"failing arranged join does not leave staging")

	var arranged_lobby: Doubles.Lobby = arranged.context.lobby
	test._check(arranged_lobby != null,
		"arranged context exposes its captured native lobby before cleanup")
	if arranged_lobby == null:
		await service.leave_transport(staging_context)
		await service.leave_lobby(staging_context)
		return
	await service.leave_lobby(arranged.context)
	test._check(arranged_lobby.leaves == 1
		and not service.lobby_id(staging_context).is_empty(),
		"scoped arranged cleanup leaves only its captured native lobby")
	var staging_network: Doubles.Network = staging_context.network
	var staging_lobby: Doubles.Lobby = staging_context.lobby
	var staging_resources_ready := staging_network != null and staging_lobby != null
	test._check(staging_resources_ready,
		"staging context exposes both captured native resources before cleanup")
	if not staging_resources_ready:
		return
	await service.leave_transport(staging_context)
	await service.leave_lobby(staging_context)
	test._check(staging_network.leaves == 1 and staging_lobby.leaves == 1,
		"staging resources each receive exactly one scoped leave")
	test._check(not service.has_owned_work(),
		"all scoped ownership is released after named cleanup")
	await _drain_clock(test, clock, "S5 scoped ownership")


func _s5_hosted_production_paths(test: Node) -> void:
	print("CASE: P0 hosted PartyService host, code join, string join and awaited replacement")
	var user := Doubles.User.new("hosted-owner")
	var service := Doubles.Party.new(ChatService.new())
	var hosted: Dictionary = await service.host(user, 4, "deathmatch")
	test._check(bool(hosted.get("ok", false)) and service.has_network() and service._is_host
		and not service.has_owned_work(), "production host attaches one legacy host transport")
	test._check(service.pf.party.create_calls.size() == 1
		and int(service.pf.party.create_calls[0].max_players) == 4
		and String(service.pf.party.create_calls[0].invitation_id) == String(hosted.code),
		"production host passes capacity and its generated code as the Party invitation")
	var hosted_lobby: Doubles.Lobby = service._lobby
	var hosted_network: Doubles.Network = service._network
	test._check(hosted_lobby != null and hosted_network != null
		and String(hosted_lobby.properties.get(PartyService.DESCRIPTOR_KEY, ""))
			== hosted_network.descriptor,
		"production host advertises the returned network descriptor")

	var losses: Array = []
	service.network_lost.connect(func(_reason: String, context: Variant) -> void:
		losses.append(context))
	var destroyed := Doubles.Change.new()
	destroyed.kind = PartyService.NETWORK_CHANGE_DESTROYED
	destroyed.reason = "Injected hosted loss."
	destroyed.network = hosted_network
	hosted_network.state_changed.emit(destroyed)
	test._check(losses == [null], "legacy hosted loss reports a null scoped context")
	await service.leave()
	test._check(hosted_lobby.leaves == 1, "hosted leave releases the named legacy lobby")

	var joiner := Doubles.Party.new(ChatService.new())
	var guest := Doubles.User.new("hosted-guest")
	var code := "ABCDE"
	var code_lobby := _hosted_lobby("code-host", code, "code-descriptor", "code-lobby")
	joiner.pf.multiplayer.lobby_by_connection[code_lobby.connection_string] = code_lobby
	var joined: Dictionary = await joiner.join(guest, code)
	test._check(bool(joined.get("ok", false)) and not joiner._is_host
		and String(joined.get("code", "")) == code and not joiner.has_owned_work(),
		"production code join follows the legacy hosted tail")
	test._check(joiner.pf.multiplayer.find_calls.size() == 1
		and joiner.pf.party.join_calls.size() == 1
		and String(joiner.pf.party.join_calls[0].descriptor) == "code-descriptor"
		and String(joiner.pf.party.join_calls[0].invitation_id) == code,
		"production code join uses the found descriptor and code invitation")
	var code_network: Doubles.Network = joiner._network
	await joiner.leave()
	test._check(code_lobby.leaves == 1 and code_network.leaves == 1,
		"production code join leaves its exact lobby and network")

	var invitee := Doubles.Party.new(ChatService.new())
	var invite_lobby := _hosted_lobby("invite-host", "FGHJK", "invite-descriptor", "invite-lobby")
	invitee.pf.multiplayer.lobby_by_connection[invite_lobby.connection_string] = invite_lobby
	var invited: Dictionary = await invitee.join_by_connection_string(
		Doubles.User.new("invite-guest"), invite_lobby.connection_string)
	test._check(bool(invited.get("ok", false))
		and invitee.pf.multiplayer.find_calls.is_empty()
		and String(invitee.pf.party.join_calls[0].invitation_id) == "FGHJK",
		"production connection-string join skips search and recovers the hosted code")
	await invitee.leave()

	var serial := Doubles.Party.new(ChatService.new())
	serial.configure_clock(serial.fake_clock)
	var first: Dictionary = await serial.host(Doubles.User.new("serial-first"), 4, "deathmatch")
	var first_network: Doubles.Network = serial._network
	first_network.block_leave = true
	var replacement_results: Array = []
	_capture_host(serial, Doubles.User.new("serial-second"), replacement_results)
	await _frames(test, 2)
	test._check(bool(first.get("ok", false)) and replacement_results.is_empty()
		and first_network.leaves == 1 and serial.pf.party.create_calls.size() == 1,
		"a replacement host waits for the previous native leave before creating")
	first_network.block_leave = false
	first_network.leave_released.emit()
	serial.fake_clock.advance(PartyService.POLL_INTERVAL)
	await _frames(test, 2)
	test._check(replacement_results.size() == 1
		and bool((replacement_results[0] as Dictionary).get("ok", false))
		and serial.pf.party.create_calls.size() == 2,
		"replacement host starts only after the blocked leave settles")
	await _drain_clock(test, serial.fake_clock, "S5 hosted replacement")
	await serial.leave()


func _s5_unavailable_kind_fence(test: Node) -> void:
	print("CASE: unavailable Matchmaking kinds leave the joined lobby before Party work")
	var previous_matchmaking: MatchmakingService = Services._matchmaking
	var unavailable := Doubles.Matchmaking.new()
	unavailable.fake_group_support = false
	Services._matchmaking = unavailable
	for kind: String in [PartyService.LOBBY_KIND_STAGING, PartyService.LOBBY_KIND_ARRANGED]:
		var service := Doubles.Party.new(ChatService.new())
		service.configure_clock(service.fake_clock)
		var lobby := _hosted_lobby("kind-owner", "", "kind-descriptor", "kind-" + kind)
		lobby.search_properties.erase(PartyService.JOIN_CODE_KEY)
		lobby.search_properties[PartyService.LOBBY_KIND_KEY] = kind
		service.pf.multiplayer.lobby_by_connection[lobby.connection_string] = lobby
		var result: Dictionary = await service.join_by_connection_string(
			Doubles.User.new("kind-guest"), lobby.connection_string)
		var error := String(result.get("error", ""))
		test._check(not bool(result.get("ok", false)),
			"unavailable %s ingress fails ok=%s" % [kind, result.get("ok")])
		test._check(error == Services.quick_match_unavailable_reason(),
			"unavailable %s reason=%s" % [kind, error])
		test._check(String(result.get("kind", "")) == kind,
			"unavailable %s preserves detected kind=%s" % [kind, result.get("kind")])
		test._check(result.get("context") == null,
			"unavailable %s context=%s" % [kind, result.get("context")])
		test._check(result.get("peer") == null,
			"unavailable %s peer=%s" % [kind, result.get("peer")])
		test._check(String(result.get("code", "")).is_empty(),
			"unavailable %s code=%s" % [kind, result.get("code")])
		test._check(service.pf.party.join_calls.is_empty(),
			"unavailable %s Party joins=%d" % [kind, service.pf.party.join_calls.size()])
		test._check(lobby.leaves == 1,
			"unavailable %s lobby leaves=%d" % [kind, lobby.leaves])
		test._check(lobby.update_calls == 0 and lobby.property_calls == 0,
			"unavailable %s lobby updates=%d property_writes=%d" % [
				kind, lobby.update_calls, lobby.property_calls])
		test._check(not service.has_owned_work(),
			"unavailable %s owned_work=%s" % [kind, service.has_owned_work()])
		test._check(not service.has_network(),
			"unavailable %s has_network=%s" % [kind, service.has_network()])
	Services._matchmaking = previous_matchmaking
	test._check(true, "hosted lobby without string_key4 remains covered by production joins")


func _s5_global_leave_and_overlap(test: Node) -> void:
	print("CASE: terminal global leave drains legacy and scoped resources, coalescing overlap")
	var service := Doubles.Party.new(ChatService.new())
	service.configure_clock(service.fake_clock)
	var user := Doubles.User.new("global-owner")
	var hosted: Dictionary = await service.host(user, 4, "deathmatch")
	var hosted_lobby: Doubles.Lobby = service._lobby
	var hosted_network: Doubles.Network = service._network
	var arranged: PartyService.PartyResult = await service.join_arranged(
		user, "global-arrangement", {}, 4, 1, 70, 30000)
	test._check(bool(hosted.get("ok", false)) and arranged.ok(),
		"global leave fixture owns one legacy session and one scoped lobby")
	var scoped_lobby: Doubles.Lobby = arranged.context.lobby
	scoped_lobby.block_leave = true
	var global_results: Array = []
	var scoped_results: Array = []
	_capture_global_leave(service, global_results)
	await _frames(test, 2)
	_capture_scoped_lobby_leave(service, arranged.context, scoped_results)
	await _frames(test, 2)
	test._check(global_results.is_empty() and scoped_results.is_empty()
		and scoped_lobby.leaves == 1 and service.has_owned_work(),
		"overlapping global/scoped leave waits on the one captured native operation")
	scoped_lobby.block_leave = false
	scoped_lobby.leave_released.emit()
	for _attempt in 32:
		if not global_results.is_empty() and not scoped_results.is_empty():
			break
		service.fake_clock.advance(PartyService.POLL_INTERVAL)
		await _frames(test, 2)
	test._check(global_results.size() == 1,
		"global/scoped overlap global_results=%d" % global_results.size())
	test._check(scoped_results.size() == 1,
		"global/scoped overlap scoped_results=%d" % scoped_results.size())
	test._check(hosted_lobby.leaves == 1,
		"global/scoped overlap hosted_lobby_leaves=%d" % hosted_lobby.leaves)
	test._check(hosted_network.leaves == 1,
		"global/scoped overlap hosted_network_leaves=%d" % hosted_network.leaves)
	test._check(scoped_lobby.leaves == 1,
		"global/scoped overlap scoped_lobby_leaves=%d" % scoped_lobby.leaves)
	test._check(not service.has_owned_work(),
		"global/scoped overlap owned_work=%s contexts=%d" % [
			service.has_owned_work(), service._contexts.size()])
	await _drain_clock(test, service.fake_clock, "S5 global/scoped overlap")


func _s5_global_leave_waits_for_pending_prepare(test: Node) -> void:
	print("CASE: global leave and hosted replacement wait for stale prepare cleanup")
	var service := Doubles.Party.new(ChatService.new())
	service.configure_clock(service.fake_clock)
	var user := Doubles.User.new("quiescence-owner")
	var arranged: PartyService.PartyResult = await service.join_arranged(
		user, "quiescence-arrangement", {}, 4, 1, 75, 0)
	var returned_network := Doubles.Network.new()
	returned_network.block_leave = true
	service.pf.party.queued_networks.append(returned_network)
	service.pf.party.block_create = true
	var prepare_results: Array = []
	var global_results: Array = []
	var replacement_results: Array = []
	_capture_prepare(service, arranged.context, user, prepare_results)
	await _frames(test, 1)
	_capture_global_leave(service, global_results)
	_capture_host(service, Doubles.User.new("quiescence-replacement"), replacement_results)
	await _frames(test, 2)
	var retired_prepare: PartyService.PartyResult = prepare_results[0] \
		if prepare_results.size() == 1 else null
	test._check(retired_prepare != null and not retired_prepare.ok()
		and retired_prepare.operation != null
		and retired_prepare.operation.cleanup_pending
		and global_results.is_empty()
		and replacement_results.size() == 1
		and not bool((replacement_results[0] as Dictionary).get("ok", false))
		and service.pf.party.create_calls.size() == 1,
		"retired prepare settles while cleanup keeps global leave active and refuses replacement")
	service.pf.party.block_create = false
	service.pf.party.create_released.emit()
	await _frames(test, 2)
	test._check(prepare_results.size() == 1 and global_results.is_empty()
		and replacement_results.size() == 1 and returned_network.leaves == 1
		and retired_prepare.operation.cleanup_pending and service.has_owned_work(),
		"returned stale network cleanup remains owned while its leave is blocked")
	returned_network.block_leave = false
	returned_network.leave_released.emit()
	service.fake_clock.advance(PartyService.POLL_INTERVAL)
	await _frames(test, 4)
	test._check(prepare_results.size() == 1,
		"stale prepare results=%d" % prepare_results.size())
	var prepare_result: PartyService.PartyResult = prepare_results[0] \
		if prepare_results.size() == 1 else null
	test._check(prepare_result != null and not prepare_result.ok(),
		"stale prepare result_ok=%s" % (
			prepare_result.ok() if prepare_result != null else "missing"))
	test._check(global_results.size() == 1,
		"global leave results=%d" % global_results.size())
	test._check(replacement_results.size() == 1
		and not bool((replacement_results[0] as Dictionary).get("ok", false)),
		"cleanup-time replacement is refused once, results=%s" % replacement_results)
	test._check(returned_network.leaves == 1,
		"stale returned network leaves=%d" % returned_network.leaves)
	test._check(service._contexts.is_empty(),
		"remaining scoped contexts=%d" % service._contexts.size())
	test._check(not service.has_owned_work(),
		"remaining owned work=%s" % service.has_owned_work())
	var retry: Dictionary = await service.host(
		Doubles.User.new("quiescence-retry"), 4, "deathmatch")
	test._check(bool(retry.get("ok", false)) and service.pf.party.create_calls.size() == 2,
		"manual retry succeeds after cleanup quiesces")
	await _drain_clock(test, service.fake_clock, "S5 stale prepare cleanup")
	await service.leave()


func _s5_recovery_epoch_isolates_late_scoped_work(test: Node) -> void:
	print("CASE: successful service recovery fences old scoped callbacks from new work")
	var service := Doubles.Party.new(ChatService.new())
	service.configure_clock(service.fake_clock)
	var user := Doubles.User.new("recovery-epoch")
	var old: PartyService.PartyResult = await service.join_arranged(
		user, "old-recovery-arrangement", {}, 4, 1, 76, 0)
	var old_context: PartyService.LobbyContext = old.context
	var old_lobby: Doubles.Lobby = old_context.lobby
	old_lobby.block_leave = true
	var old_network := Doubles.Network.new()
	service.pf.party.queued_networks.append(old_network)
	service.pf.party.block_create = true
	var prepare_results: Array = []
	var global_results: Array = []
	var coalesced_results: Array = []
	_capture_prepare(service, old_context, user, prepare_results)
	await _frames(test, 1)
	_capture_global_leave(service, global_results)
	await _frames(test, 1)
	_capture_scoped_lobby_leave(service, old_context, coalesced_results)
	await _frames(test, 1)
	service.fake_clock.advance(NRConst.MATCH_CLEANUP_SECONDS)
	await _frames(test, 4)
	test._check(global_results.size() == 1,
		"recovery epoch global leave results=%d" % global_results.size())
	test._check(coalesced_results.size() == 1,
		"recovery epoch coalesced leave results=%d" % coalesced_results.size())
	var retired_prepare: PartyService.PartyResult = prepare_results[0] \
		if prepare_results.size() == 1 else null
	test._check(retired_prepare != null and not retired_prepare.ok()
		and retired_prepare.operation != null
		and not retired_prepare.operation.cleanup_pending,
		"confirmed reset settles and discharges old prepare results=%d" % \
			prepare_results.size())
	test._check(service._contexts.is_empty() and service._owned_operation_count == 0,
		"confirmed reset removes old contexts=%d and count=%d" % [
			service._contexts.size(), service._owned_operation_count])
	test._check(service.context_is_quiescent(old_context),
		"confirmed recovery invalidation discharges the old context")
	test._check(service.pf.party.shutdown_calls == 1
		and service.pf.multiplayer.shutdown_calls == 1,
		"confirmed reset shuts down Party=%d Lobby=%d once" % [
			service.pf.party.shutdown_calls, service.pf.multiplayer.shutdown_calls])

	service.pf.party.block_create = false
	var replacement: PartyService.PartyResult = await service.create_staging(
		Doubles.User.new("recovery-new"), 4, "deathmatch", 1, 77, 0)
	test._check(replacement.ok(),
		"manual retry after confirmed recovery opens a new scoped context")
	var replacement_lobby: Doubles.Lobby = replacement.context.lobby
	replacement_lobby.block_post = true
	var replacement_post: Array = []
	_capture_context_post(
		service, replacement.context, {"new_epoch": "blocked"}, replacement_post)
	await _frames(test, 1)
	test._check(service._owned_operation_count == 1 and replacement_post.is_empty(),
		"new recovery epoch owns one blocked operation count=%d" % service._owned_operation_count)

	service.pf.party.create_released.emit()
	await _frames(test, 3)
	test._check(prepare_results.size() == 1,
		"old prepare settles after reset results=%d" % prepare_results.size())
	test._check(old_network.leaves == 1,
		"old returned network cleaned exactly once leaves=%d" % old_network.leaves)
	test._check(service._owned_operation_count == 1,
		"old callback cannot decrement new epoch count=%d" % service._owned_operation_count)
	test._check(service._contexts.size() == 1
		and service._contexts.has(replacement.context.context_id)
		and not service._contexts.has(old_context.context_id),
		"old context stays retired; registry keys=%s" % service._contexts.keys())

	old_lobby.block_leave = false
	old_lobby.leave_released.emit()
	replacement_lobby.block_post = false
	replacement_lobby.post_released.emit()
	service.fake_clock.advance(PartyService.POLL_INTERVAL)
	await _frames(test, 3)
	test._check(replacement_post.size() == 1 and service._owned_operation_count == 0,
		"new epoch work settles independently results=%d count=%d" % [
			replacement_post.size(), service._owned_operation_count])
	await service.leave()
	test._check(service.pf.party.shutdown_calls == 1
		and service.pf.multiplayer.shutdown_calls == 1
		and service._contexts.is_empty() and not service.has_owned_work(),
		"next leave needs no repeated recovery and reaches quiescence")
	await _drain_clock(test, service.fake_clock, "S5 recovery epoch")


func _s5_serialized_operations_stop_after_leave(test: Node) -> void:
	print("CASE: queued context post and lock revalidate after a leave")
	for operation_name: String in ["post", "lock"]:
		var service := Doubles.Party.new(ChatService.new())
		var operation_clock := Doubles.Clock.new()
		service.configure_clock(operation_clock)
		var staging: PartyService.PartyResult = await service.create_staging(
			Doubles.User.new("serialize-" + operation_name), 4, "deathmatch", 1, 80, 0)
		if not staging.ok():
			test._check(false, "serialized operation fixture opened")
			continue
		var lobby: Doubles.Lobby = staging.context.lobby
		var first: Array = []
		var second: Array = []
		if operation_name == "post":
			lobby.block_post = true
			_capture_context_post(service, staging.context, {"first": "1"}, first)
			await _frames(test, 1)
			_capture_context_post(service, staging.context, {"second": "2"}, second)
		else:
			lobby.block_lock = true
			_capture_context_lock(service, staging.context, true, first)
			await _frames(test, 1)
			_capture_context_lock(service, staging.context, false, second)
		await _frames(test, 1)
		await service.leave_lobby(staging.context)
		await service.leave_transport(staging.context)
		test._check(service.has_owned_work(),
			"pending %s remains owned after both context resources leave" % operation_name)
		if operation_name == "post":
			lobby.block_post = false
			lobby.post_released.emit()
		else:
			lobby.block_lock = false
			lobby.lock_released.emit()
		operation_clock.advance(PartyService.POLL_INTERVAL)
		await _frames(test, 3)
		var call_count := lobby.update_calls if operation_name == "post" else lobby.lock_calls
		test._check(first.size() == 1 and second.size() == 1 and call_count == 1
			and not (second[0] as PartyService.PartyResult).ok(),
			"queued %s makes no second native call after its context leaves" % operation_name)
		test._check(not service.has_owned_work(),
			"completed pending %s retires its now-empty context" % operation_name)
		var replacement: PartyService.PartyResult = await service.create_staging(
			Doubles.User.new("replacement-" + operation_name), 4, "deathmatch", 1, 81, 0)
		var replacement_lobby: Doubles.Lobby = replacement.context.lobby \
			if replacement.ok() and replacement.context != null else null
		test._check(replacement_lobby != null and replacement_lobby.update_calls == 0
			and replacement_lobby.lock_calls == 0,
			"stale queued %s has no effect on a replacement context" % operation_name)
		await service.leave()
		await _drain_clock(test, operation_clock, "S5 serialized " + operation_name)


func _s5_transport_conflict_cleanup(test: Node) -> void:
	print("CASE: competing transport attachment leaves the rejected network exactly once")
	var service := Doubles.Party.new(ChatService.new())
	var user := Doubles.User.new("conflict-owner")
	var arranged: PartyService.PartyResult = await service.join_arranged(
		user, "conflict-arrangement", {}, 4, 1, 90, 30000)
	var rejected := Doubles.Network.new()
	service.pf.party.queued_networks.append(rejected)
	service.pf.party.block_create = true
	var results: Array = []
	_capture_prepare(service, arranged.context, user, results)
	await _frames(test, 1)
	var existing := Doubles.Network.new()
	service._attach_network(existing, true)
	service.pf.party.block_create = false
	service.pf.party.create_released.emit()
	await _frames(test, 3)
	test._check(results.size() == 1 and not (results[0] as PartyService.PartyResult).ok()
		and service._network == existing and rejected.leaves == 1
		and (results[0] as PartyService.PartyResult).publication_permit == 0,
		"attachment refusal preserves the existing transport and cleans the returned network")
	await service.leave()


func _s5_scoped_cancellation_and_owned_work(test: Node) -> void:
	print("CASE: scoped cancellation keeps late native cleanup owned and revokes publication")
	var service := Doubles.Party.new(ChatService.new())
	var user := Doubles.User.new("cancel-scope")
	var late_network := Doubles.Network.new()
	late_network.block_leave = true
	service.pf.party.queued_networks.append(late_network)
	service.pf.party.block_create = true
	var results: Array = []
	_capture_create_staging(service, user, results)
	await _frames(test, 1)
	service.cancel_pending_join()
	service.pf.party.block_create = false
	service.pf.party.create_released.emit()
	await _frames(test, 2)
	test._check(results.is_empty() and service.has_owned_work() and late_network.leaves == 1,
		"a cancelled blocked create retains ownership while its late network leave is blocked")
	late_network.block_leave = false
	late_network.leave_released.emit()
	await _frames(test, 3)
	test._check(results.size() == 1 and not (results[0] as PartyService.PartyResult).ok()
		and not service.has_owned_work(),
		"late scoped success cleans only its returned network and then releases ownership")

	var account_service := Doubles.Party.new(ChatService.new())
	account_service.pf.multiplayer.block_arranged = true
	var account_results: Array = []
	_capture_arranged_join(account_service, Doubles.User.new("stale-account"), account_results)
	await _frames(test, 1)
	account_service.fake_account_current = false
	account_service.pf.multiplayer.block_arranged = false
	account_service.pf.multiplayer.arranged_released.emit()
	await _frames(test, 3)
	var stale_lobby: Doubles.Lobby = account_service.pf.multiplayer.lobbies.back() \
		if not account_service.pf.multiplayer.lobbies.is_empty() else null
	test._check(account_results.size() == 1,
		"account-stale results=%d" % account_results.size())
	var stale_result: PartyService.PartyResult = account_results[0] \
		if account_results.size() == 1 else null
	test._check(stale_result != null and not stale_result.ok(),
		"account-stale result_ok=%s" % (
			stale_result.ok() if stale_result != null else "missing"))
	test._check(stale_lobby != null,
		"account-stale returned_lobby=%s" % stale_lobby)
	test._check(stale_lobby != null and stale_lobby.leaves == 1,
		"account-stale lobby_leaves=%d" % (
			stale_lobby.leaves if stale_lobby != null else -1))
	test._check(not account_service.has_owned_work(),
		"account-stale owned_work=%s contexts=%d" % [
			account_service.has_owned_work(), account_service._contexts.size()])

	var removed_service := Doubles.Party.new(ChatService.new())
	removed_service.pf.multiplayer.block_arranged = true
	var removed_results: Array = []
	_capture_arranged_join(removed_service, Doubles.User.new("removed-context"), removed_results)
	await _frames(test, 1)
	test._check(not removed_service._contexts.is_empty(),
		"blocked arranged join exposes its owned context before removal")
	if removed_service._contexts.is_empty():
		return
	var pending_context: PartyService.LobbyContext = removed_service._contexts.values()[0]
	await removed_service.leave_lobby(pending_context)
	await removed_service.leave_transport(pending_context)
	removed_service.pf.multiplayer.block_arranged = false
	removed_service.pf.multiplayer.arranged_released.emit()
	await _frames(test, 3)
	var removed_lobby: Doubles.Lobby = removed_service.pf.multiplayer.lobbies.back() \
		if not removed_service.pf.multiplayer.lobbies.is_empty() else null
	test._check(removed_results.size() == 1
		and not (removed_results[0] as PartyService.PartyResult).ok()
		and removed_lobby != null and removed_lobby.leaves == 1
		and not removed_service.has_owned_work(),
		"context removal invalidates the blocked continuation and owns its late lobby cleanup")

	var permit_service := Doubles.Party.new(ChatService.new())
	var opened: PartyService.PartyResult = await permit_service.create_staging(
		Doubles.User.new("permit-owner"), 4, "deathmatch", 1, 92, 0)
	permit_service.cancel_pending_join()
	var published: PartyService.PartyResult = await permit_service.publish_transport(
		opened.context, opened.publication_permit, "gathering")
	test._check(not published.ok() and opened.context.lobby.update_calls == 0,
		"a revoked publication permit cannot write a descriptor")
	await permit_service.leave()


func _s5_contexts_release_after_leave(test: Node) -> void:
	print("CASE: fully left scoped contexts retain no result/callback reference cycle")
	var references: Array = await _fully_left_context_weakrefs()
	await _frames(test, 1)
	for entry: Dictionary in references:
		var reference: WeakRef = entry.ref
		test._check(reference.get_ref() == null,
			"a fully left %s context is freed: no context->result cycle" % entry.kind)


func _fully_left_context_weakrefs() -> Array:
	var service := Doubles.Party.new(ChatService.new())
	var user := Doubles.User.new("weak-context")
	var staging: PartyService.PartyResult = await service.create_staging(
		user, 4, "deathmatch", 1, 100, 0)
	var arranged: PartyService.PartyResult = await service.join_arranged(
		user, "weak-arrangement", {}, 4, 1, 100, 0)
	if not staging.ok() or not arranged.ok():
		await service.leave()
		return []
	var staging_context: PartyService.LobbyContext = staging.context
	var arranged_context: PartyService.LobbyContext = arranged.context
	var references: Array = [
		{"kind": "staging", "ref": weakref(staging_context)},
		{"kind": "arranged", "ref": weakref(arranged_context)},
	]
	await service.leave_transport(staging_context)
	await service.leave_lobby(staging_context)
	await service.leave_transport(arranged_context)
	await service.leave_lobby(arranged_context)
	return references


func _s6_scoped_deadline_ownership(test: Node) -> void:
	print("CASE: Phase 1 scoped deadlines settle callers and retain late native cleanup")
	var user := Doubles.User.new("deadline-owner")

	var initializing := Doubles.Party.new(ChatService.new())
	initializing.configure_clock(initializing.fake_clock)
	initializing.pf.party.initialized = false
	initializing._party_initialized = false
	initializing.pf.party.block_initialize = true
	var initialization_results: Array = []
	_capture_create_staging_deadline(
		initializing, user, initializing.fake_clock.now_msec() + 100,
		initialization_results)
	await _frames(test, 1)
	initializing.fake_clock.advance(0.1)
	await _frames(test, 2)
	var initialization_timeout: PartyService.PartyResult = initialization_results[0] \
		if initialization_results.size() == 1 else null
	test._check(initialization_timeout != null
		and initialization_timeout.outcome == PartyService.PartyResult.Outcome.TIMEOUT,
		"blocked initialization times out results=%d outcome=%s" % [
			initialization_results.size(),
			initialization_timeout.outcome if initialization_timeout != null else "missing"])
	test._check(initialization_timeout != null
		and initialization_timeout.operation != null
		and initialization_timeout.operation.cleanup_pending,
		"timed-out initialization remains cleanup-owned")
	initializing.pf.party.block_initialize = false
	initializing.pf.party.initialize_released.emit()
	await _frames(test, 3)
	test._check(initialization_timeout != null
		and not initialization_timeout.operation.cleanup_pending
		and not initializing.has_owned_work(),
		"late initialization cannot resurrect staging and releases ownership")
	await _drain_clock(test, initializing.fake_clock, "S6 initialization deadline")

	var creating := Doubles.Party.new(ChatService.new())
	creating.configure_clock(creating.fake_clock)
	var late_create_network := Doubles.Network.new()
	late_create_network.block_leave = true
	creating.pf.party.queued_networks.append(late_create_network)
	creating.pf.party.block_create = true
	var create_results: Array = []
	_capture_create_staging_deadline(
		creating, user, creating.fake_clock.now_msec() + 100, create_results)
	await _frames(test, 1)
	creating.fake_clock.advance(0.1)
	await _frames(test, 2)
	var create_timeout: PartyService.PartyResult = create_results[0] \
		if create_results.size() == 1 else null
	test._check(create_timeout != null
		and create_timeout.outcome == PartyService.PartyResult.Outcome.TIMEOUT
		and create_timeout.operation.cleanup_pending,
		"blocked network create returns timeout with owned cleanup")
	creating.pf.party.block_create = false
	creating.pf.party.create_released.emit()
	await _frames(test, 2)
	test._check(late_create_network.leaves == 1
		and create_timeout.operation.cleanup_pending,
		"late created network is left once while blocked leaves=%d" % \
			late_create_network.leaves)
	late_create_network.block_leave = false
	late_create_network.leave_released.emit()
	await _frames(test, 3)
	test._check(not create_timeout.operation.cleanup_pending
		and not creating.has_owned_work(),
		"late create cleanup reaches quiescence")
	await _drain_clock(test, creating.fake_clock, "S6 create deadline")

	var descriptor_service := Doubles.Party.new(ChatService.new())
	descriptor_service.configure_clock(descriptor_service.fake_clock)
	var descriptor_network := Doubles.Network.new()
	descriptor_network.descriptor = ""
	descriptor_service.pf.party.queued_networks.append(descriptor_network)
	var descriptor_results: Array = []
	_capture_create_staging_deadline(
		descriptor_service,
		user,
		descriptor_service.fake_clock.now_msec() + 100,
		descriptor_results)
	await _frames(test, 1)
	descriptor_service.fake_clock.advance(0.1)
	await _frames(test, 4)
	var descriptor_timeout: PartyService.PartyResult = descriptor_results[0] \
		if descriptor_results.size() == 1 else null
	test._check(descriptor_timeout != null
		and descriptor_timeout.outcome == PartyService.PartyResult.Outcome.TIMEOUT,
		"missing descriptor respects the caller deadline")
	test._check(descriptor_network.leaves == 1,
		"descriptor timeout leaves its created network once leaves=%d" % \
			descriptor_network.leaves)
	await _drain_clock(test, descriptor_service.fake_clock, "S6 descriptor deadline")

	var joining := Doubles.Party.new(ChatService.new())
	joining.configure_clock(joining.fake_clock)
	var late_lobby := _arranged_lobby_fixture(
		user.entity_key, user.entity_key, "deadline-arranged-lobby")
	late_lobby.block_leave = true
	joining.pf.multiplayer.next_arranged_result = Doubles.Results.make(true, late_lobby)
	joining.pf.multiplayer.block_arranged = true
	var arranged_results: Array = []
	_capture_arranged_join_deadline(
		joining,
		user,
		joining.fake_clock.now_msec() + 100,
		arranged_results)
	await _frames(test, 1)
	joining.fake_clock.advance(0.1)
	await _frames(test, 2)
	var arranged_timeout: PartyService.PartyResult = arranged_results[0] \
		if arranged_results.size() == 1 else null
	test._check(arranged_timeout != null
		and arranged_timeout.outcome == PartyService.PartyResult.Outcome.TIMEOUT
		and arranged_timeout.operation.cleanup_pending,
		"blocked arranged join returns a cleanup-owned timeout")
	joining.pf.multiplayer.block_arranged = false
	joining.pf.multiplayer.arranged_released.emit()
	await _frames(test, 2)
	test._check(late_lobby.leaves == 1 and arranged_timeout.operation.cleanup_pending,
		"late arranged lobby cleanup is owned leaves=%d" % late_lobby.leaves)
	late_lobby.block_leave = false
	late_lobby.leave_released.emit()
	await _frames(test, 3)
	test._check(not arranged_timeout.operation.cleanup_pending
		and not joining.has_owned_work(),
		"late arranged join cleanup reaches quiescence")
	await _drain_clock(test, joining.fake_clock, "S6 arranged join deadline")

	var operations := Doubles.Party.new(ChatService.new())
	operations.configure_clock(operations.fake_clock)
	var arranged: PartyService.PartyResult = await operations.join_arranged(
		user, "deadline-operations", {
			MatchmakingService.PROTOCOL_MEMBER_KEY: NRProtocol.version_string(),
			PartyService.MATCH_ID_MEMBER_KEY: "deadline-match",
		}, 4, 1, 201, operations.fake_clock.now_msec() + 1000)
	test._check(arranged.ok(), "deadline operation fixture joins arranged lobby")
	if not arranged.ok():
		return
	var context: PartyService.LobbyContext = arranged.context

	var late_prepare_network := Doubles.Network.new()
	late_prepare_network.block_leave = true
	operations.pf.party.queued_networks.append(late_prepare_network)
	operations.pf.party.block_create = true
	var prepare_results: Array = []
	_capture_prepare_deadline(
		operations,
		context,
		user,
		operations.fake_clock.now_msec() + 100,
		prepare_results)
	await _frames(test, 1)
	operations.fake_clock.advance(0.1)
	await _frames(test, 2)
	var prepare_timeout: PartyService.PartyResult = prepare_results[0] \
		if prepare_results.size() == 1 else null
	test._check(prepare_timeout != null
		and prepare_timeout.outcome == PartyService.PartyResult.Outcome.TIMEOUT,
		"blocked arranged transport create respects its deadline")
	operations.pf.party.block_create = false
	operations.pf.party.create_released.emit()
	await _frames(test, 2)
	test._check(late_prepare_network.leaves == 1
		and prepare_timeout.operation.cleanup_pending,
		"late prepared network remains owned while leave is blocked")
	late_prepare_network.block_leave = false
	late_prepare_network.leave_released.emit()
	await _frames(test, 3)
	test._check(not prepare_timeout.operation.cleanup_pending,
		"late prepare cleanup settles its operation handle")

	var lobby: Doubles.Lobby = context.lobby
	lobby.properties[PartyService.DESCRIPTOR_KEY] = "deadline-join-descriptor"
	lobby.properties[PartyService.SESSION_PHASE_KEY] = PartyService.ARRANGED_PHASE_BOOTSTRAP
	var late_join_network := Doubles.Network.new()
	late_join_network.block_leave = true
	operations.pf.party.queued_networks.append(late_join_network)
	operations.pf.party.block_join = true
	var join_results: Array = []
	_capture_join_transport_deadline(
		operations,
		context,
		user,
		operations.fake_clock.now_msec() + 100,
		join_results)
	await _frames(test, 1)
	operations.fake_clock.advance(0.1)
	await _frames(test, 2)
	var join_timeout: PartyService.PartyResult = join_results[0] \
		if join_results.size() == 1 else null
	test._check(join_timeout != null
		and join_timeout.outcome == PartyService.PartyResult.Outcome.TIMEOUT,
		"blocked arranged transport join respects its deadline")
	operations.pf.party.block_join = false
	operations.pf.party.join_released.emit()
	await _frames(test, 2)
	test._check(late_join_network.leaves == 1
		and join_timeout.operation.cleanup_pending,
		"late joined network remains cleanup-owned")
	late_join_network.block_leave = false
	late_join_network.leave_released.emit()
	await _frames(test, 3)

	lobby.block_lock = true
	var lock_results: Array = []
	_capture_context_lock_deadline(
		operations,
		context,
		true,
		operations.fake_clock.now_msec() + 100,
		lock_results)
	await _frames(test, 1)
	operations.fake_clock.advance(0.1)
	await _frames(test, 2)
	var lock_timeout: PartyService.PartyResult = lock_results[0] \
		if lock_results.size() == 1 else null
	test._check(lock_timeout != null
		and lock_timeout.outcome == PartyService.PartyResult.Outcome.TIMEOUT
		and lock_timeout.operation.cleanup_pending,
		"blocked membership lock returns a cleanup-owned timeout")
	lobby.block_lock = false
	lobby.lock_released.emit()
	await _frames(test, 3)
	test._check(not lock_timeout.operation.cleanup_pending,
		"late lock completion releases its operation handle")

	lobby.block_post = true
	var post_results: Array = []
	_capture_context_post_deadline(
		operations,
		context,
		{"deadline_post": "1"},
		operations.fake_clock.now_msec() + 100,
		post_results)
	await _frames(test, 1)
	operations.fake_clock.advance(0.1)
	await _frames(test, 2)
	var post_timeout: PartyService.PartyResult = post_results[0] \
		if post_results.size() == 1 else null
	test._check(post_timeout != null
		and post_timeout.outcome == PartyService.PartyResult.Outcome.TIMEOUT
		and post_timeout.operation.cleanup_pending,
		"blocked lobby post returns a cleanup-owned timeout")
	lobby.block_post = false
	lobby.post_released.emit()
	await _frames(test, 3)
	test._check(not post_timeout.operation.cleanup_pending,
		"late post completion releases its operation handle")
	await operations.leave()
	await _drain_clock(test, operations.fake_clock, "S6 scoped operation deadlines")


func _s6_context_loss_and_admission(test: Node) -> void:
	print("CASE: Phase 1 scoped lobby loss and synchronous admission proof")
	var service := Doubles.Party.new(ChatService.new())
	service.configure_clock(service.fake_clock)
	var user := Doubles.User.new("proof-local")
	var staging: PartyService.PartyResult = await service.create_staging(
		user, 4, "deathmatch", 1, 301, service.fake_clock.now_msec() + 1000)
	test._check(staging.ok(), "admission fixture creates staging context")
	if not staging.ok():
		return
	var context: PartyService.LobbyContext = staging.context
	var local_proof := service.admission_proof(context, 1)
	test._check(bool(local_proof.valid)
		and bool(local_proof.native_present)
		and bool(local_proof.native_connected)
		and String((local_proof.entity_key as Dictionary).id) == "proof-local",
		"staging local admission is authenticated from Party and native snapshots")

	var remote_key := {
		"id": "proof-remote",
		"type": "title_player_account",
	}
	(context.peer as Doubles.Peer).keys[2] = remote_key.duplicate()
	var pending_proof := service.admission_proof(context, 2)
	test._check(not bool(pending_proof.valid) and bool(pending_proof.pending)
		and String(pending_proof.reason_code) == "native_member_pending",
		"Party identity waits while native membership has not replicated")
	var remote_member := Doubles.Member.new(remote_key, {
		MatchmakingService.PROTOCOL_MEMBER_KEY: NRProtocol.version_string(),
	})
	remote_member.connection_status = 0
	(context.lobby as Doubles.Lobby).members.append(remote_member)
	var disconnected_proof := service.admission_proof(context, 2)
	test._check(not bool(disconnected_proof.valid)
		and not bool(disconnected_proof.pending)
		and String(disconnected_proof.reason_code) == "native_member_disconnected",
		"a disconnected native member is refused, not treated as pending")
	remote_member.connection_status = 1
	var remote_proof := service.admission_proof(context, 2)
	test._check(bool(remote_proof.valid)
		and String((remote_proof.entity_key as Dictionary).id) == "proof-remote",
		"matching connected native and Party identity is admitted")
	var outsider_key := {
		"id": "proof-outsider",
		"type": "title_player_account",
	}
	(context.peer as Doubles.Peer).keys[9] = outsider_key
	(context.lobby as Doubles.Lobby).members.append(Doubles.Member.new({
		"id": "proof-member-3",
		"type": "title_player_account",
	}))
	(context.lobby as Doubles.Lobby).members.append(Doubles.Member.new({
		"id": "proof-member-4",
		"type": "title_player_account",
	}))
	var outsider_proof := service.admission_proof(context, 9)
	test._check(not bool(outsider_proof.valid)
		and not bool(outsider_proof.pending)
		and String(outsider_proof.reason_code) == "native_member_missing",
		"a wrong authenticated key is invalid once the native cohort is complete")

	var losses: Array = []
	service.context_lost.connect(func(reason: String, lost_context: Variant) -> void:
		losses.append({"reason": reason, "context": lost_context}))
	var owner_change := Doubles.Change.new()
	owner_change.kind = PartyService.LOBBY_CHANGE_OWNER_CHANGED
	(context.lobby as Doubles.Lobby).owner_entity_key = {
		"id": "replacement-owner",
		"type": "title_player_account",
	}
	(context.lobby as Doubles.Lobby).state_changed.emit(owner_change)
	test._check(losses.size() == 1 and losses[0].context == context,
		"native owner change emits one scoped terminal loss count=%d" % losses.size())
	test._check(String(losses[0].reason).contains("owner changed"),
		"owner-change loss uses a title-owned reason=%s" % losses[0].reason)
	await service.leave()

	var peerless := Doubles.Party.new(ChatService.new())
	peerless.configure_clock(peerless.fake_clock)
	var arranged: PartyService.PartyResult = await peerless.join_arranged(
		Doubles.User.new("peerless-local"),
		"peerless-arranged",
		{},
		4,
		1,
		302,
		peerless.fake_clock.now_msec() + 1000)
	var peerless_losses: Array = []
	peerless.context_lost.connect(func(reason: String, lost_context: Variant) -> void:
		peerless_losses.append({"reason": reason, "context": lost_context}))
	var disconnected := Doubles.Change.new()
	disconnected.kind = PartyService.LOBBY_CHANGE_DISCONNECTED
	disconnected.result = Doubles.Results.make(
		false, null, "dropped", "Injected native diagnostic.")
	(arranged.context.lobby as Doubles.Lobby).state_changed.emit(disconnected)
	test._check(peerless_losses.size() == 1
		and peerless_losses[0].context == arranged.context
		and String(peerless_losses[0].reason)
			== "The matchmaking lobby connection was lost.",
		"peerless scoped Lobby loss is terminal with a title reason")
	await peerless.leave()

	var staging_retirement := Doubles.Party.new(ChatService.new())
	staging_retirement.configure_clock(staging_retirement.fake_clock)
	var retiring: PartyService.PartyResult = await staging_retirement.create_staging(
		Doubles.User.new("expected-staging-retirement"),
		4,
		"deathmatch",
		1,
		303,
		staging_retirement.fake_clock.now_msec() + 1000)
	var retiring_lobby: Doubles.Lobby = retiring.context.lobby
	var retirement_losses: Array = []
	staging_retirement.context_lost.connect(
		func(_reason: String, _context: Variant) -> void:
			retirement_losses.append(true))
	await staging_retirement.leave_transport(retiring.context)
	await staging_retirement.leave_lobby(retiring.context)
	var late_expected_disconnect := Doubles.Change.new()
	late_expected_disconnect.kind = PartyService.LOBBY_CHANGE_DISCONNECTED
	retiring_lobby.state_changed.emit(late_expected_disconnect)
	test._check(retirement_losses.is_empty(),
		"deliberate staging transport/lobby retirement suppresses context_lost")
	test._check(not staging_retirement.has_owned_work(),
		"deliberate staging retirement reaches quiescence")
	await _drain_clock(
		test, staging_retirement.fake_clock, "S6 deliberate staging retirement")

	var expected_leave := Doubles.Party.new(ChatService.new())
	expected_leave.configure_clock(expected_leave.fake_clock)
	var expected: PartyService.PartyResult = await expected_leave.join_arranged(
		Doubles.User.new("expected-leave"),
		"expected-leave-arranged",
		{},
		4,
		1,
		305,
		expected_leave.fake_clock.now_msec() + 1000)
	var expected_losses: Array = []
	expected_leave.context_lost.connect(func(_reason: String, _context: Variant) -> void:
		expected_losses.append(true))
	await expected_leave.leave_lobby(expected.context)
	test._check(expected_losses.is_empty(),
		"owned scoped leave suppresses terminal loss signals")
	await _drain_clock(test, expected_leave.fake_clock, "S6 expected leave")

	var guest_service := Doubles.Party.new(ChatService.new())
	guest_service.configure_clock(guest_service.fake_clock)
	var guest := Doubles.User.new("proof-guest")
	var host_key := {
		"id": "proof-host",
		"type": "title_player_account",
	}
	var guest_lobby := _arranged_lobby_fixture(
		host_key, guest.entity_key, "proof-guest-arranged")
	guest_lobby.members[0].properties = {
		MatchmakingService.PROTOCOL_MEMBER_KEY: NRProtocol.version_string(),
		PartyService.MATCH_ID_MEMBER_KEY: "proof-match",
	}
	guest_lobby.members[1].properties = {
		MatchmakingService.PROTOCOL_MEMBER_KEY: NRProtocol.version_string(),
		PartyService.MATCH_ID_MEMBER_KEY: "proof-match",
	}
	guest_service.pf.multiplayer.next_arranged_result = Doubles.Results.make(
		true, guest_lobby)
	var guest_arranged: PartyService.PartyResult = await guest_service.join_arranged(
		guest,
		"proof-guest-arrangement",
		guest_lobby.members[1].properties,
		4,
		1,
		304,
		guest_service.fake_clock.now_msec() + 1000)
	guest_lobby.properties[PartyService.DESCRIPTOR_KEY] = "proof-guest-descriptor"
	guest_lobby.properties[PartyService.SESSION_PHASE_KEY] = \
		PartyService.ARRANGED_PHASE_BOOTSTRAP
	var guest_network := Doubles.Network.new()
	guest_network.local_peer.unique_id = 7
	guest_network.local_peer.keys[1] = host_key.duplicate()
	guest_network.local_peer.keys[7] = guest.entity_key.duplicate()
	guest_service.pf.party.queued_networks.append(guest_network)
	var joined: PartyService.PartyResult = await guest_service.join_transport(
		guest_arranged.context,
		guest,
		guest_service.fake_clock.now_msec() + 1000)
	var host_proof := guest_service.admission_proof(guest_arranged.context, 1)
	test._check(joined.ok() and bool(host_proof.valid)
		and String((host_proof.entity_key as Dictionary).id) == "proof-host",
		"arranged guest can authenticate peer 1 from cached host/native facts")
	await guest_service.leave()
	await _drain_clock(test, guest_service.fake_clock, "S6 guest proof")


func _s7_arranged_control_and_publication(test: Node) -> void:
	print("CASE: Phase 1 arranged control is atomic and descriptor refresh preserves it")
	var valid_control := PartyService.encode_arranged_control(
		"control-match", 0, PartyService.ARRANGED_PHASE_BOOTSTRAP)
	var decoded := PartyService.decode_arranged_control(valid_control)
	test._check(bool(decoded.valid)
		and String(decoded.match_id) == "control-match"
		and int(decoded.round) == 0
		and String(decoded.phase) == PartyService.ARRANGED_PHASE_BOOTSTRAP,
		"arranged control round zero round-trips=%s" % decoded)
	for malformed: Dictionary in [
		{},
		{
			PartyService.MATCH_ID_MEMBER_KEY: "control-match",
			PartyService.ROUND_GENERATION_KEY: "01",
			PartyService.SESSION_PHASE_KEY: PartyService.ARRANGED_PHASE_BOOTSTRAP,
		},
		{
			PartyService.MATCH_ID_MEMBER_KEY: "control-match",
			PartyService.ROUND_GENERATION_KEY: "0",
			PartyService.SESSION_PHASE_KEY: "unknown",
		},
	]:
		test._check(not bool(PartyService.decode_arranged_control(malformed).valid),
			"malformed arranged control is rejected=%s" % malformed)

	var service := Doubles.Party.new(ChatService.new())
	service.configure_clock(service.fake_clock)
	var user := Doubles.User.new("control-owner")
	var arranged: PartyService.PartyResult = await service.join_arranged(
		user,
		"control-arrangement",
		{
			MatchmakingService.PROTOCOL_MEMBER_KEY: NRProtocol.version_string(),
			PartyService.MATCH_ID_MEMBER_KEY: "control-match",
		},
		4,
		1,
		401,
		service.fake_clock.now_msec() + 1000)
	arranged.context.role = &"guest"
	var prepared: PartyService.PartyResult = await service.prepare_transport(
		arranged.context, user, service.fake_clock.now_msec() + 1000)
	test._check(prepared.ok() and prepared.local_creator
		and prepared.peer.get_unique_id() == 1,
		"actual arranged owner creates peer 1 even with stale staging guest role")
	var published: PartyService.PartyResult = await service.publish_transport(
		arranged.context,
		prepared.publication_permit,
		PartyService.ARRANGED_PHASE_BOOTSTRAP,
		valid_control,
		{},
		service.fake_clock.now_msec() + 1000)
	var lobby: Doubles.Lobby = arranged.context.lobby
	test._check(published.ok() and lobby.update_calls == 1
		and String(lobby.properties.get(PartyService.MATCH_ID_MEMBER_KEY, ""))
			== "control-match"
		and String(lobby.properties.get(PartyService.ROUND_GENERATION_KEY, "")) == "0"
		and String(lobby.properties.get(PartyService.SESSION_PHASE_KEY, ""))
			== PartyService.ARRANGED_PHASE_BOOTSTRAP,
		"descriptor and arranged control publish in one checked batch")

	var wrong_phase: PartyService.PartyResult = await service.publish_transport(
		arranged.context,
		prepared.publication_permit,
		PartyService.ARRANGED_PHASE_GAMEPLAY,
		valid_control,
		{},
		service.fake_clock.now_msec() + 1000)
	test._check(not wrong_phase.ok()
		and wrong_phase.reason_code == &"arranged_control_invalid"
		and lobby.update_calls == 1,
		"phase/control mismatch is refused before a native update")

	var rematch_control := PartyService.encode_arranged_control(
		"control-match", 1, PartyService.ARRANGED_PHASE_REMATCH)
	var advanced: PartyService.PartyResult = await service.post_context_update(
		arranged.context,
		rematch_control,
		{},
		{},
		service.fake_clock.now_msec() + 1000)
	test._check(advanced.ok() and lobby.update_calls == 2,
		"later arranged round control updates through the serialized owner path")
	var network: Doubles.Network = arranged.context.network
	network.descriptor = "descriptor-refreshed"
	var descriptor_change := Doubles.Change.new()
	descriptor_change.kind = PartyService.NETWORK_CHANGE_DESCRIPTOR_UPDATED
	network.state_changed.emit(descriptor_change)
	await _frames(test, 3)
	test._check(lobby.update_calls == 3
		and String(lobby.properties.get(PartyService.DESCRIPTOR_KEY, ""))
			== "descriptor-refreshed"
		and String(lobby.properties.get(PartyService.MATCH_ID_MEMBER_KEY, ""))
			== "control-match"
		and String(lobby.properties.get(PartyService.ROUND_GENERATION_KEY, "")) == "1"
		and String(lobby.properties.get(PartyService.SESSION_PHASE_KEY, ""))
			== PartyService.ARRANGED_PHASE_REMATCH,
		"descriptor refresh preserves the latest valid match, round, and phase metadata")
	await service.leave()
	await _drain_clock(test, service.fake_clock, "S7 arranged publication")

	var queued := Doubles.Party.new(ChatService.new())
	queued.configure_clock(queued.fake_clock)
	var staging: PartyService.PartyResult = await queued.create_staging(
		Doubles.User.new("permit-queued"),
		4,
		"deathmatch",
		1,
		402,
		queued.fake_clock.now_msec() + 1000)
	var staging_lobby: Doubles.Lobby = staging.context.lobby
	staging_lobby.block_post = true
	var first_results: Array = []
	var publish_results: Array = []
	_capture_context_post_deadline(
		queued,
		staging.context,
		{"first": "1"},
		queued.fake_clock.now_msec() + 1000,
		first_results)
	await _frames(test, 1)
	_capture_publish_transport(
		queued,
		staging.context,
		staging.publication_permit,
		"gathering",
		{},
		{},
		queued.fake_clock.now_msec() + 1000,
		publish_results)
	await _frames(test, 1)
	staging.context.active_permit += 1
	staging_lobby.block_post = false
	staging_lobby.post_released.emit()
	queued.fake_clock.advance(PartyService.POLL_INTERVAL)
	await _frames(test, 4)
	var revoked: PartyService.PartyResult = publish_results[0] \
		if publish_results.size() == 1 else null
	test._check(first_results.size() == 1
		and revoked != null
		and revoked.reason_code == &"publication_revoked",
		"queued publication rechecks its permit results=%d code=%s" % [
			publish_results.size(),
			revoked.reason_code if revoked != null else "missing"])
	test._check(staging_lobby.update_calls == 1
		and String(staging_lobby.properties.get(
			PartyService.DESCRIPTOR_KEY, "")).is_empty(),
		"revoked queued publication makes no second native update calls=%d" % \
			staging_lobby.update_calls)
	await queued.leave()
	await _drain_clock(test, queued.fake_clock, "S7 revoked publication")

	var unusable := Doubles.Party.new(ChatService.new())
	unusable.configure_clock(unusable.fake_clock)
	var unusable_user := Doubles.User.new("unusable-peer")
	var unusable_arranged: PartyService.PartyResult = await unusable.join_arranged(
		unusable_user,
		"unusable-peer-arranged",
		{},
		4,
		1,
		403,
		unusable.fake_clock.now_msec() + 1000)
	var disconnected_network := Doubles.Network.new()
	disconnected_network.local_peer.connected = false
	unusable.pf.party.queued_networks.append(disconnected_network)
	var unusable_result: PartyService.PartyResult = await unusable.prepare_transport(
		unusable_arranged.context,
		unusable_user,
		unusable.fake_clock.now_msec() + 1000)
	test._check(not unusable_result.ok()
		and disconnected_network.leaves == 1
		and not unusable.has_network(),
		"unusable returned peer is refused and its network is left exactly once")
	await unusable.leave()
	await _drain_clock(test, unusable.fake_clock, "S7 unusable peer")


func _s8_invite_destinations(test: Node) -> void:
	print("CASE: Phase 1 invite destinations preserve opaque strings and fence Party entry")
	var previous_matchmaking: MatchmakingService = Services._matchmaking
	Services._matchmaking = Doubles.Matchmaking.new()

	var owner := Doubles.User.new("invite-owner")
	var guest := Doubles.User.new("invite-rematch-guest")
	var exact_connection := "opaque+value%2fwith|slash/:=lower"
	var rematch_lobby := _arranged_lobby_fixture(
		owner.entity_key, guest.entity_key, "invite-rematch")
	rematch_lobby.connection_string = exact_connection
	rematch_lobby.search_properties[PartyService.LOBBY_KIND_KEY] = \
		PartyService.LOBBY_KIND_ARRANGED
	rematch_lobby.properties.merge(PartyService.encode_arranged_control(
		"invite-match", 3, PartyService.ARRANGED_PHASE_REMATCH), true)
	rematch_lobby.properties[PartyService.DESCRIPTOR_KEY] = "invite-rematch-descriptor"
	rematch_lobby.members[0].properties = {
		MatchmakingService.PROTOCOL_MEMBER_KEY: NRProtocol.version_string(),
		PartyService.MATCH_ID_MEMBER_KEY: "invite-match",
	}
	rematch_lobby.members[1].properties = {}
	var rematch_service := Doubles.Party.new(ChatService.new())
	rematch_service.configure_clock(rematch_service.fake_clock)
	rematch_service.pf.multiplayer.lobby_by_connection[exact_connection] = rematch_lobby
	var rematch: Dictionary = await rematch_service.join_by_connection_string(
		guest, exact_connection, rematch_service.fake_clock.now_msec() + 45000)
	test._check(bool(rematch.get("ok", false))
		and String(rematch.get("destination", "")) == "arranged_rematch"
		and String(rematch.get("kind", "")) == PartyService.LOBBY_KIND_ARRANGED
		and String(rematch.get("match_id", "")) == "invite-match"
		and int(rematch.get("round", -1)) == 3
		and int(rematch.get("expected_count", 0)) == 4,
		"valid arranged rematch returns its named destination=%s" % rematch)
	test._check(rematch_service.pf.multiplayer.join_calls == [exact_connection]
		and rematch_service.pf.multiplayer.find_calls.is_empty(),
		"#16 connection string reaches Lobby byte-for-byte calls=%s" % \
			rematch_service.pf.multiplayer.join_calls)
	test._check(rematch_service.pf.party.join_calls.size() == 1
		and String(rematch_service.pf.party.join_calls[0].invitation_id)
			== PartyService.MATCHMAKING_INVITATION_ID
		and rematch_service.pf.multiplayer.arranged_calls.is_empty(),
		"rematch adapter uses NetRumble Party authentication and no arranged join API")
	test._check(String(rematch_lobby.members[1].properties.get(
		MatchmakingService.PROTOCOL_MEMBER_KEY, "")) == NRProtocol.version_string()
		and String(rematch_lobby.members[1].properties.get(
			PartyService.MATCH_ID_MEMBER_KEY, "")) == "invite-match",
		"rematch candidate writes protocol and match metadata before Party entry")
	await rematch_service.leave()
	await _drain_clock(test, rematch_service.fake_clock, "S8 rematch destination")

	var staging_owner := Doubles.User.new("invite-staging-owner")
	var staging_guest := Doubles.User.new("invite-staging-guest")
	var staging_lobby := _staging_lobby_fixture(
		staging_owner.entity_key,
		"invite-staging",
		"gathering",
		false)
	var staging_service := Doubles.Party.new(ChatService.new())
	staging_service.configure_clock(staging_service.fake_clock)
	staging_service.pf.multiplayer.lobby_by_connection[
		staging_lobby.connection_string] = staging_lobby
	var staging_join: Dictionary = await staging_service.join_by_connection_string(
		staging_guest,
		staging_lobby.connection_string,
		staging_service.fake_clock.now_msec() + 45000)
	test._check(bool(staging_join.get("ok", false))
		and String(staging_join.get("destination", "")) == "staging_gathering",
		"Gathering staging invite returns the staging destination")
	await staging_service.leave()
	await _drain_clock(test, staging_service.fake_clock, "S8 staging destination")

	for refusal: Dictionary in [
		{"phase": "searching", "locked": false, "label": "searching"},
		{"phase": "gathering", "locked": true, "label": "locked"},
	]:
		var refused_service := Doubles.Party.new(ChatService.new())
		refused_service.configure_clock(refused_service.fake_clock)
		var refused_lobby := _staging_lobby_fixture(
			staging_owner.entity_key,
			"invite-staging-" + String(refusal.label),
			String(refusal.phase),
			bool(refusal.locked))
		refused_service.pf.multiplayer.lobby_by_connection[
			refused_lobby.connection_string] = refused_lobby
		var refused: Dictionary = await refused_service.join_by_connection_string(
			staging_guest,
			refused_lobby.connection_string,
			refused_service.fake_clock.now_msec() + 45000)
		test._check(not bool(refused.get("ok", false))
			and String(refused.get("kind", "")) == PartyService.LOBBY_KIND_STAGING,
			"%s staging invite is refused with kind=%s" % [
				refusal.label, refused.get("kind")])
		test._check(refused_service.pf.party.join_calls.is_empty()
			and refused_lobby.leaves == 1
			and not refused_service.has_network(),
			"%s staging refusal occurs before Party and releases candidate once" % \
				refusal.label)
		await _drain_clock(
			test, refused_service.fake_clock, "S8 staging refusal " + String(refusal.label))

	for phase: String in [
		PartyService.ARRANGED_PHASE_BOOTSTRAP,
		PartyService.ARRANGED_PHASE_GAMEPLAY,
	]:
		var phase_service := Doubles.Party.new(ChatService.new())
		phase_service.configure_clock(phase_service.fake_clock)
		var phase_lobby := _arranged_lobby_fixture(
			owner.entity_key, guest.entity_key, "invite-arranged-" + phase)
		phase_lobby.search_properties[PartyService.LOBBY_KIND_KEY] = \
			PartyService.LOBBY_KIND_ARRANGED
		phase_lobby.properties.merge(PartyService.encode_arranged_control(
			"invite-match", 3, phase), true)
		phase_lobby.properties[PartyService.DESCRIPTOR_KEY] = "phase-descriptor"
		phase_lobby.members[0].properties = {
			MatchmakingService.PROTOCOL_MEMBER_KEY: NRProtocol.version_string(),
			PartyService.MATCH_ID_MEMBER_KEY: "invite-match",
		}
		phase_service.pf.multiplayer.lobby_by_connection[
			phase_lobby.connection_string] = phase_lobby
		var phase_result: Dictionary = await phase_service.join_by_connection_string(
			guest,
			phase_lobby.connection_string,
			phase_service.fake_clock.now_msec() + 45000)
		test._check(not bool(phase_result.get("ok", false))
			and phase_service.pf.party.join_calls.is_empty()
			and phase_lobby.leaves == 1,
			"arranged %s invite is refused before Party" % phase)
		await _drain_clock(test, phase_service.fake_clock, "S8 arranged " + phase)

	var protocol_service := Doubles.Party.new(ChatService.new())
	protocol_service.configure_clock(protocol_service.fake_clock)
	var protocol_lobby := _arranged_lobby_fixture(
		owner.entity_key, guest.entity_key, "invite-arranged-protocol")
	protocol_lobby.search_properties[PartyService.LOBBY_KIND_KEY] = \
		PartyService.LOBBY_KIND_ARRANGED
	protocol_lobby.properties.merge(PartyService.encode_arranged_control(
		"invite-match", 4, PartyService.ARRANGED_PHASE_REMATCH), true)
	protocol_lobby.properties[PartyService.DESCRIPTOR_KEY] = "protocol-descriptor"
	protocol_lobby.members[0].properties = {
		MatchmakingService.PROTOCOL_MEMBER_KEY: "0.0",
		PartyService.MATCH_ID_MEMBER_KEY: "invite-match",
	}
	protocol_service.pf.multiplayer.lobby_by_connection[
		protocol_lobby.connection_string] = protocol_lobby
	var protocol_result: Dictionary = await protocol_service.join_by_connection_string(
		guest,
		protocol_lobby.connection_string,
		protocol_service.fake_clock.now_msec() + 45000)
	test._check(not bool(protocol_result.get("ok", false))
		and protocol_service.pf.party.join_calls.is_empty()
		and protocol_lobby.leaves == 1,
		"incompatible rematch owner protocol is refused before Party")
	await _drain_clock(test, protocol_service.fake_clock, "S8 protocol refusal")

	var hosted_service := Doubles.Party.new(ChatService.new())
	hosted_service.configure_clock(hosted_service.fake_clock)
	var hosted_lobby := _hosted_lobby(
		"destination-host", "QWERT", "destination-descriptor", "destination-hosted")
	hosted_service.pf.multiplayer.lobby_by_connection[
		hosted_lobby.connection_string] = hosted_lobby
	var hosted: Dictionary = await hosted_service.join_by_connection_string(
		Doubles.User.new("destination-hosted-guest"),
		hosted_lobby.connection_string,
		hosted_service.fake_clock.now_msec() + 45000)
	test._check(bool(hosted.get("ok", false))
		and String(hosted.get("destination", "missing")).is_empty(),
		"ordinary hosted invite keeps the empty destination")
	await hosted_service.leave()
	await _drain_clock(test, hosted_service.fake_clock, "S8 hosted destination")

	Services._matchmaking = previous_matchmaking


func _s9_multiplayer_invalidation(test: Node) -> void:
	print("CASE: Phase 1 confirmed Multiplayer reset invalidates only old ticket epochs")
	var matchmaking := Doubles.Matchmaking.new()
	var clock := Doubles.Clock.new()
	matchmaking.configure_clock(clock)
	var user := Doubles.User.new("invalidation-ticket")
	matchmaking.sdk.block_create = true
	var old_attempt := matchmaking.begin_create(
		_spec(user, [user.entity_key], 501))
	await _frames(test, 1)
	test._check(clock.armed_alarm_count() == 1,
		"old ticket epoch owns one deadline alarm")
	matchmaking.multiplayer_invalidated(1)
	test._check(old_attempt.outcome == MatchmakingService.Outcome.FAILED
		and old_attempt.reason_code == &"multiplayer_invalidated"
		and old_attempt.native_terminal
		and not old_attempt.cleanup_pending,
		"confirmed reset settles old pending caller without native cancellation")
	test._check(clock.armed_alarm_count() == 0,
		"confirmed reset cancels old ticket alarm count=%d" % \
			clock.armed_alarm_count())

	matchmaking.sdk.block_create = false
	var current_ticket := Doubles.Ticket.new()
	current_ticket.ticket_id = "current-runtime-ticket"
	matchmaking.sdk.queued_create_results.append(Doubles.Results.make(
		true, current_ticket))
	var current_attempt := matchmaking.begin_create(
		_spec(user, [user.entity_key], 502))
	await _frames(test, 2)
	test._check(current_attempt.is_pending()
		and current_attempt.ticket == current_ticket
		and clock.armed_alarm_count() == 1,
		"new runtime starts independent ticket work")
	var old_ticket := Doubles.Ticket.new()
	old_ticket.ticket_id = "old-runtime-ticket"
	matchmaking.sdk.queued_create_results.append(Doubles.Results.make(true, old_ticket))
	matchmaking.sdk.create_released.emit()
	await _frames(test, 3)
	test._check(old_attempt.outcome == MatchmakingService.Outcome.FAILED
		and old_ticket.cancel_calls == 0
		and current_attempt.ticket == current_ticket
		and current_attempt.is_pending(),
		"late old-runtime callback neither cancels nor mutates new work")
	matchmaking.retire(current_attempt)
	await _frames(test, 2)
	test._check(clock.armed_alarm_count() == 0,
		"retiring the new attempt leaves no armed alarm")
	await _drain_clock(test, clock, "S9 ticket invalidation")

	var recovered := Doubles.Party.new(ChatService.new())
	recovered.configure_clock(recovered.fake_clock)
	var recovered_context: PartyService.PartyResult = await recovered.join_arranged(
		Doubles.User.new("invalidation-party"),
		"invalidation-arranged",
		{},
		4,
		1,
		503,
		recovered.fake_clock.now_msec() + 1000)
	var recovered_lobby: Doubles.Lobby = recovered_context.context.lobby
	recovered_lobby.block_leave = true
	var invalidations: Array = []
	recovered.multiplayer_invalidated.connect(func(epoch: int) -> void:
		invalidations.append(epoch))
	var recovered_leave: Array = []
	_capture_global_leave(recovered, recovered_leave)
	await _frames(test, 1)
	recovered.fake_clock.advance(NRConst.MATCH_CLEANUP_SECONDS)
	await _frames(test, 4)
	test._check(invalidations == [1]
		and recovered_leave.size() == 1
		and recovered._contexts.is_empty(),
		"successful Party/Lobby recovery emits once after scoped retirement=%s" % \
			invalidations)
	recovered_lobby.block_leave = false
	recovered_lobby.leave_released.emit()
	await _frames(test, 2)
	await _drain_clock(test, recovered.fake_clock, "S9 successful recovery")

	var failed := Doubles.Party.new(ChatService.new())
	failed.configure_clock(failed.fake_clock)
	var failed_context: PartyService.PartyResult = await failed.join_arranged(
		Doubles.User.new("invalidation-failed"),
		"invalidation-failed-arranged",
		{},
		4,
		1,
		504,
		failed.fake_clock.now_msec() + 1000)
	var failed_lobby: Doubles.Lobby = failed_context.context.lobby
	failed_lobby.block_leave = true
	failed.pf.multiplayer.next_shutdown_result = Doubles.Results.make(
		false, null, "shutdown_failed", "Injected shutdown failure.")
	var failed_invalidations: Array = []
	failed.multiplayer_invalidated.connect(func(epoch: int) -> void:
		failed_invalidations.append(epoch))
	var failed_leave: Array = []
	_capture_global_leave(failed, failed_leave)
	await _frames(test, 1)
	failed.fake_clock.advance(NRConst.MATCH_CLEANUP_SECONDS)
	await _frames(test, 4)
	test._check(failed_invalidations.is_empty()
		and failed.recovery_error == PartyService.RECOVERY_FAILED,
		"failed Multiplayer recovery emits no invalidation and remains fenced")
	failed_lobby.block_leave = false
	failed_lobby.leave_released.emit()
	await _frames(test, 2)
	await _drain_clock(test, failed.fake_clock, "S9 failed recovery")

	var party_only := Doubles.Party.new(ChatService.new())
	var party_only_invalidations: Array = []
	party_only.multiplayer_invalidated.connect(func(epoch: int) -> void:
		party_only_invalidations.append(epoch))
	await party_only.pf.party.shutdown_async()
	test._check(party_only_invalidations.is_empty(),
		"Party-only shutdown is not evidence that tickets were invalidated")


func _s10_staging_retirement_observation(test: Node) -> void:
	print("CASE: staging retirement reports quiescence and suppresses loss only inside owned leave")
	var active := Doubles.Party.new(ChatService.new())
	active.configure_clock(active.fake_clock)
	var active_result: PartyService.PartyResult = await active.create_staging(
		Doubles.User.new("retirement-active"),
		4,
		"deathmatch",
		1,
		601,
		active.fake_clock.now_msec() + 1000)
	var active_losses: Array = []
	active.context_lost.connect(func(reason: String, context: Variant) -> void:
		active_losses.append({"reason": reason, "context": context}))
	var active_lobby: Doubles.Lobby = active_result.context.lobby
	active_lobby.owner_entity_key = {}
	var owner_cleared := Doubles.Change.new()
	owner_cleared.kind = PartyService.LOBBY_CHANGE_OWNER_CHANGED
	active_lobby.state_changed.emit(owner_cleared)
	var active_disconnected := Doubles.Change.new()
	active_disconnected.kind = PartyService.LOBBY_CHANGE_DISCONNECTED
	active_disconnected.result = Doubles.Results.make(
		false, null, "active_disconnect", "Injected active disconnect.")
	active_lobby.state_changed.emit(active_disconnected)
	test._check(active_losses.size() == 1,
		"active owner-clear/disconnect emits one terminal loss count=%d" % \
			active_losses.size())
	var active_loss: Dictionary = active_losses[0] \
		if active_losses.size() == 1 else {}
	test._check(active_loss.get("context") == active_result.context,
		"active loss retains its captured context=%s" % active_loss.get("context"))
	test._check(String(active_loss.get("reason", "")).contains("owner changed"),
		"active owner clear reports the owner-change reason=%s" % \
			active_loss.get("reason", "missing"))
	await active.leave()
	await _drain_clock(test, active.fake_clock, "S10 active owner clear")

	var retiring := Doubles.Party.new(ChatService.new())
	retiring.configure_clock(retiring.fake_clock)
	var user := Doubles.User.new("retirement-owned")
	var staging: PartyService.PartyResult = await retiring.create_staging(
		user, 4, "deathmatch", 1, 602, retiring.fake_clock.now_msec() + 1000)
	var context: PartyService.LobbyContext = staging.context
	var lobby: Doubles.Lobby = context.lobby
	lobby.block_post = true
	var post_results: Array = []
	_capture_context_post_deadline(
		retiring,
		context,
		{"retirement_probe": "held"},
		retiring.fake_clock.now_msec() + 1000,
		post_results)
	await _frames(test, 1)
	test._check(not retiring.context_is_quiescent(context),
		"held staging post keeps the context nonquiescent")
	lobby.block_post = false
	lobby.post_released.emit()
	await _frames(test, 3)
	test._check(post_results.size() == 1
		and (post_results[0] as PartyService.PartyResult).ok(),
		"held staging post completes once results=%d" % post_results.size())
	test._check(not retiring.context_is_quiescent(context),
		"a live staging Lobby/network is not quiescent after its post")

	var retirement_losses: Array = []
	retiring.context_lost.connect(func(reason: String, lost_context: Variant) -> void:
		retirement_losses.append({"reason": reason, "context": lost_context}))
	lobby.block_leave = true
	var leave_results: Array = []
	_capture_scoped_lobby_leave(retiring, context, leave_results)
	await _frames(test, 2)
	test._check(lobby.leaves == 1 and leave_results.is_empty(),
		"owned native leave is held leaves=%d results=%d" % [
			lobby.leaves, leave_results.size()])
	test._check(not retiring.context_is_quiescent(context),
		"held native leave keeps the context nonquiescent")
	lobby.owner_entity_key = {}
	var leaving_owner_cleared := Doubles.Change.new()
	leaving_owner_cleared.kind = PartyService.LOBBY_CHANGE_OWNER_CHANGED
	lobby.state_changed.emit(leaving_owner_cleared)
	var leaving_disconnected := Doubles.Change.new()
	leaving_disconnected.kind = PartyService.LOBBY_CHANGE_DISCONNECTED
	leaving_disconnected.result = Doubles.Results.make(
		false, null, "leaving_disconnect", "Injected leaving disconnect.")
	lobby.state_changed.emit(leaving_disconnected)
	test._check(retirement_losses.is_empty(),
		"owner-clear and DISCONNECTED inside owned leave emit no context_lost")
	lobby.block_leave = false
	lobby.leave_released.emit()
	await _frames(test, 3)
	test._check(leave_results.size() == 1,
		"owned staging leave results=%d" % leave_results.size())
	var leave_result: PartyService.PartyResult = leave_results[0] \
		if leave_results.size() == 1 else null
	test._check(leave_result != null and leave_result.ok(),
		"owned staging leave outcome=%s" % (
			leave_result.outcome if leave_result != null else "missing"))
	test._check(not retiring.context_is_quiescent(context),
		"captured staging transport still prevents quiescence")
	await retiring.leave_transport(context)
	test._check(retiring.context_is_quiescent(context),
		"confirmed Lobby and transport retirement reaches context quiescence")
	test._check(lobby.leaves == 1,
		"owned staging Lobby leaves exactly once leaves=%d" % lobby.leaves)
	await _drain_clock(test, retiring.fake_clock, "S10 owned retirement")

	var marker_service := Doubles.Party.new(ChatService.new())
	marker_service.configure_clock(marker_service.fake_clock)
	var marker_user := Doubles.User.new("retirement-marker")
	var arranged: PartyService.PartyResult = await marker_service.join_arranged(
		marker_user,
		"retirement-marker-arranged",
		{
			MatchmakingService.PROTOCOL_MEMBER_KEY: NRProtocol.version_string(),
			PartyService.MATCH_ID_MEMBER_KEY: "retirement-match",
		},
		4,
		1,
		603,
		marker_service.fake_clock.now_msec() + 1000)
	var initial_snapshot := marker_service.snapshot(arranged.context)
	var initial_members: Array = initial_snapshot.members
	test._check(initial_members.size() == 1,
		"arranged initial member count=%d" % initial_members.size())
	var initial_properties: Dictionary = initial_members[0].properties \
		if initial_members.size() == 1 else {}
	test._check(not initial_properties.has(PartyService.STAGING_RETIRED_MEMBER_KEY),
		"arranged initial member has no staging-retired marker")
	var marker_post: PartyService.PartyResult = await marker_service.post_context_update(
		arranged.context,
		{},
		{},
		{PartyService.STAGING_RETIRED_MEMBER_KEY: "retirement-match"},
		marker_service.fake_clock.now_msec() + 1000)
	test._check(marker_post.ok(),
		"local staging-retired marker post is checked")
	var marked_snapshot := marker_service.snapshot(arranged.context)
	var marked_members: Array = marked_snapshot.members
	test._check(marked_members.size() == 1,
		"marked arranged member count=%d" % marked_members.size())
	var marked_properties: Dictionary = marked_members[0].properties \
		if marked_members.size() == 1 else {}
	test._check(String(marked_properties.get(
		PartyService.STAGING_RETIRED_MEMBER_KEY, "")) == "retirement-match",
		"local marker stores the current match id")

	var failed: PartyService.PartyResult = await marker_service.join_arranged(
		Doubles.User.new("retirement-marker-failed"),
		"retirement-marker-failed-arranged",
		{},
		4,
		1,
		604,
		marker_service.fake_clock.now_msec() + 1000)
	var failed_lobby: Doubles.Lobby = failed.context.lobby
	failed_lobby.next_member_result = Doubles.Results.make(
		false, null, "member_post_failed", "Injected member post failure.")
	var failed_post: PartyService.PartyResult = await marker_service.post_context_update(
		failed.context,
		{},
		{},
		{PartyService.STAGING_RETIRED_MEMBER_KEY: "retirement-failed"},
		marker_service.fake_clock.now_msec() + 1000)
	test._check(not failed_post.ok()
		and failed_post.reason_code == &"member_update_failed",
		"failed marker post remains visible code=%s" % failed_post.reason_code)
	var failed_snapshot := marker_service.snapshot(failed.context)
	var failed_members: Array = failed_snapshot.members
	test._check(failed_members.size() == 1,
		"failed marker member count=%d" % failed_members.size())
	var failed_properties: Dictionary = failed_members[0].properties \
		if failed_members.size() == 1 else {}
	test._check(not failed_properties.has(PartyService.STAGING_RETIRED_MEMBER_KEY),
		"failed marker post does not claim retirement")

	var stale: PartyService.PartyResult = await marker_service.join_arranged(
		Doubles.User.new("retirement-marker-stale"),
		"retirement-marker-stale-arranged",
		{},
		4,
		1,
		605,
		marker_service.fake_clock.now_msec() + 1000)
	var stale_lobby: Doubles.Lobby = stale.context.lobby
	stale_lobby.block_member = true
	var stale_results: Array = []
	_capture_member_post(
		marker_service,
		stale.context,
		{PartyService.STAGING_RETIRED_MEMBER_KEY: "stale-match"},
		marker_service.fake_clock.now_msec() + 1000,
		stale_results)
	await _frames(test, 1)
	await marker_service.leave_lobby(stale.context)
	var replacement: PartyService.PartyResult = await marker_service.join_arranged(
		Doubles.User.new("retirement-marker-replacement"),
		"retirement-marker-replacement-arranged",
		{},
		4,
		1,
		606,
		marker_service.fake_clock.now_msec() + 1000)
	stale_lobby.block_member = false
	stale_lobby.member_released.emit()
	await _frames(test, 3)
	test._check(stale_results.size() == 1
		and not (stale_results[0] as PartyService.PartyResult).ok(),
		"stale marker operation settles without success results=%d" % \
			stale_results.size())
	var replacement_snapshot := marker_service.snapshot(replacement.context)
	var replacement_members: Array = replacement_snapshot.members
	test._check(replacement_members.size() == 1,
		"replacement marker member count=%d" % replacement_members.size())
	var replacement_properties: Dictionary = replacement_members[0].properties \
		if replacement_members.size() == 1 else {}
	test._check(not replacement_properties.has(
		PartyService.STAGING_RETIRED_MEMBER_KEY),
		"stale marker completion cannot mark the replacement match")
	test._check(marker_service.context_is_quiescent(stale.context),
		"stale context reaches quiescence after its captured callback settles")
	await marker_service.leave()
	await _drain_clock(test, marker_service.fake_clock, "S10 retirement markers")


func _hosted_lobby(
	owner_id: String,
	code: String,
	descriptor: String,
	lobby_id: String
) -> Doubles.Lobby:
	var owner := Doubles.User.new(owner_id)
	var lobby := Doubles.Lobby.new()
	lobby.lobby_id = lobby_id
	lobby.connection_string = "connection-" + lobby_id
	lobby.owner_entity_key = owner.entity_key.duplicate()
	lobby.search_properties = {
		PartyService.JOIN_CODE_KEY: code,
		PartyService.GAME_MODE_KEY: "deathmatch",
		NRProtocol.LOBBY_KEY: NRProtocol.version_string(),
	}
	lobby.properties = {PartyService.DESCRIPTOR_KEY: descriptor}
	lobby.members = [Doubles.Member.new(owner.entity_key, {
		MatchmakingService.PROTOCOL_MEMBER_KEY: NRProtocol.version_string(),
	})]
	return lobby


func _arranged_lobby_fixture(
	owner_key: Dictionary,
	local_key: Dictionary,
	lobby_id: String
) -> Doubles.Lobby:
	var lobby := Doubles.Lobby.new()
	lobby.lobby_id = lobby_id
	lobby.connection_string = "connection-" + lobby_id
	lobby.owner_entity_key = owner_key.duplicate()
	lobby.local_entity_key = local_key.duplicate()
	lobby.max_member_count = 4
	lobby.access_policy = 2
	lobby.owner_migration_policy = 0
	lobby.restrict_invites_to_lobby_owner = false
	lobby.members = [Doubles.Member.new(owner_key)]
	if owner_key != local_key:
		lobby.members.append(Doubles.Member.new(local_key))
	return lobby


func _staging_lobby_fixture(
	owner_key: Dictionary,
	lobby_id: String,
	phase: String,
	locked: bool
) -> Doubles.Lobby:
	var lobby := Doubles.Lobby.new()
	lobby.lobby_id = lobby_id
	lobby.connection_string = "connection-" + lobby_id
	lobby.owner_entity_key = owner_key.duplicate()
	lobby.local_entity_key = owner_key.duplicate()
	lobby.max_member_count = 4
	lobby.access_policy = 0
	lobby.owner_migration_policy = 2
	lobby.restrict_invites_to_lobby_owner = false
	lobby.membership_lock = PartyService.MEMBERSHIP_LOCK_LOCKED \
		if locked else PartyService.MEMBERSHIP_LOCK_UNLOCKED
	lobby.search_properties = {
		PartyService.LOBBY_KIND_KEY: PartyService.LOBBY_KIND_STAGING,
		PartyService.GAME_MODE_KEY: "deathmatch",
		NRProtocol.LOBBY_KEY: NRProtocol.version_string(),
	}
	lobby.properties = {
		PartyService.DESCRIPTOR_KEY: "descriptor-" + lobby_id,
		PartyService.SESSION_PHASE_KEY: phase,
		PartyService.SEARCH_CONTROL_KEY: PartyService.encode_search_control({
			"epoch": 1,
			"phase": phase,
			"group": [owner_key],
		}),
	}
	lobby.members = [Doubles.Member.new(owner_key, {
		MatchmakingService.PROTOCOL_MEMBER_KEY: NRProtocol.version_string(),
		PartyService.MATCH_ORIGIN_MEMBER_KEY: PartyService.MATCH_ORIGIN_VALUE,
	})]
	return lobby


func _mode_config(player_count: int) -> GameModeConfig:
	var config := GameModeConfig.new()
	config.mode_type = NRTypes.GameModeType.DEATHMATCH
	config.player_count = player_count
	return config


func _capture_host(
	service: Doubles.Party,
	user: Doubles.User,
	results: Array
) -> void:
	results.append(await service.host(user, 4, "deathmatch"))


func _capture_global_leave(service: Doubles.Party, results: Array) -> void:
	await service.leave()
	results.append(true)


func _capture_scoped_lobby_leave(
	service: Doubles.Party,
	context: PartyService.LobbyContext,
	results: Array
) -> void:
	results.append(await service.leave_lobby(context))


func _capture_context_post(
	service: Doubles.Party,
	context: PartyService.LobbyContext,
	properties: Dictionary,
	results: Array
) -> void:
	results.append(await service.post_context_update(context, properties, {}, {}, 0))


func _capture_context_lock(
	service: Doubles.Party,
	context: PartyService.LobbyContext,
	locked: bool,
	results: Array
) -> void:
	results.append(await service.set_context_locked(context, locked, 0))


func _capture_prepare(
	service: Doubles.Party,
	context: PartyService.LobbyContext,
	user: Doubles.User,
	results: Array
) -> void:
	results.append(await service.prepare_transport(context, user, 0))


func _capture_create_staging(
	service: Doubles.Party,
	user: Doubles.User,
	results: Array
) -> void:
	results.append(await service.create_staging(user, 4, "deathmatch", 1, 91, 0))


func _capture_create_staging_deadline(
	service: Doubles.Party,
	user: Doubles.User,
	deadline_msec: int,
	results: Array
) -> void:
	results.append(await service.create_staging(
		user, 4, "deathmatch", 1, 190, deadline_msec))


func _capture_arranged_join(
	service: Doubles.Party,
	user: Doubles.User,
	results: Array
) -> void:
	results.append(await service.join_arranged(
		user, "stale-arrangement", {}, 4, 1, 93, 30000))


func _capture_arranged_join_deadline(
	service: Doubles.Party,
	user: Doubles.User,
	deadline_msec: int,
	results: Array
) -> void:
	results.append(await service.join_arranged(
		user, "deadline-arrangement", {}, 4, 1, 191, deadline_msec))


func _capture_prepare_deadline(
	service: Doubles.Party,
	context: PartyService.LobbyContext,
	user: Doubles.User,
	deadline_msec: int,
	results: Array
) -> void:
	results.append(await service.prepare_transport(
		context, user, deadline_msec))


func _capture_join_transport_deadline(
	service: Doubles.Party,
	context: PartyService.LobbyContext,
	user: Doubles.User,
	deadline_msec: int,
	results: Array
) -> void:
	results.append(await service.join_transport(
		context, user, deadline_msec))


func _capture_context_lock_deadline(
	service: Doubles.Party,
	context: PartyService.LobbyContext,
	locked: bool,
	deadline_msec: int,
	results: Array
) -> void:
	results.append(await service.set_context_locked(
		context, locked, deadline_msec))


func _capture_context_post_deadline(
	service: Doubles.Party,
	context: PartyService.LobbyContext,
	properties: Dictionary,
	deadline_msec: int,
	results: Array
) -> void:
	results.append(await service.post_context_update(
		context, properties, {}, {}, deadline_msec))


func _capture_member_post(
	service: Doubles.Party,
	context: PartyService.LobbyContext,
	properties: Dictionary,
	deadline_msec: int,
	results: Array
) -> void:
	results.append(await service.post_context_update(
		context, {}, {}, properties, deadline_msec))


func _capture_publish_transport(
	service: Doubles.Party,
	context: PartyService.LobbyContext,
	permit: int,
	phase: String,
	lobby_properties: Dictionary,
	search_properties: Dictionary,
	deadline_msec: int,
	results: Array
) -> void:
	results.append(await service.publish_transport(
		context,
		permit,
		phase,
		lobby_properties,
		search_properties,
		deadline_msec))


func _spec(
	user: Doubles.User,
	members: Array,
	epoch: int
) -> MatchmakingService.SearchSpec:
	var spec := MatchmakingService.SearchSpec.new()
	spec.user = user
	spec.account_generation = 1
	spec.flow_epoch = epoch
	spec.owner = true
	spec.expected_match_count = 4
	spec.deadline_msec = Time.get_ticks_msec() + 600000
	for member: Variant in members:
		spec.frozen_members.append((member as Dictionary).duplicate())
	return spec


func _join_spec(
	user: Doubles.User,
	members: Array,
	epoch: int,
	ticket_id: String
) -> MatchmakingService.SearchSpec:
	var spec := _spec(user, members, epoch)
	spec.owner = false
	spec.ticket_id = ticket_id
	return spec


func _full_group(user: Doubles.User, prefix: String) -> Array:
	var members: Array = [user.entity_key.duplicate()]
	for index in 3:
		members.append({
			"id": "%s-remote-%d" % [prefix, index],
			"type": "title_player_account",
		})
	return members


func _full_party_failure(
	test: Node,
	attempt: MatchmakingService.TicketAttempt,
	description: String
) -> void:
	test._check(attempt.outcome == MatchmakingService.Outcome.FAILED
		and attempt.reason_code == MatchmakingService.FULL_PARTY_REASON_CODE
		and attempt.reason == MatchmakingService.FULL_PARTY_REASON,
		description)


func _frames(test: Node, count: int) -> void:
	for _frame in count:
		await test.get_tree().process_frame


func _drain_clock(test: Node, clock: Doubles.Clock, label: String) -> void:
	for _attempt in 4:
		if clock.pending_sleepers() == 0:
			break
		clock.advance(PartyService.LOBBY_LOCK_TIMEOUT + 1.0)
		await _frames(test, 3)
	test._check(clock.pending_sleepers() == 0,
		"%s: no coroutine left asleep on the test clock (pending=%d)" % [
			label, clock.pending_sleepers()])
	test._check(clock.armed_alarm_count() == 0,
		"%s: no deadline alarm remains armed (count=%d)" % [
			label, clock.armed_alarm_count()])
