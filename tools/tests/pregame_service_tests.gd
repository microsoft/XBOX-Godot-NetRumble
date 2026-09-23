extends RefCounted

const Doubles := preload("res://tools/tests/pregame_service_doubles.gd")


func run(test: Node) -> void:
	var previous_party: PartyService = Services._party
	var previous_matchmaking: MatchmakingService = Services._matchmaking
	var previous_chat: ChatService = Services._chat
	var previous_clock: Variant = Services.clock() if Services.has_method("clock") else null

	await _s1_capability_and_profile_gates(test)
	await _s2_group_ticket_shape(test)
	await _s3_level_triggered_ticket_lifecycle(test)
	await _s3_guest_join_and_late_retirement(test)
	await _s4_failure_cancel_and_timeout(test)
	await _s4_native_cleanup_ownership(test)
	await _s4_observe_terminal_before_cancel(test)
	await _s5_scoped_lobby_ownership(test)
	await _s5_hosted_production_paths(test)
	await _s5_disabled_kind_fence(test)
	await _s5_global_leave_and_overlap(test)
	await _s5_global_leave_waits_for_pending_prepare(test)
	await _s5_recovery_epoch_isolates_late_scoped_work(test)
	await _s5_serialized_operations_stop_after_leave(test)
	await _s5_transport_conflict_cleanup(test)
	await _s5_scoped_cancellation_and_owned_work(test)
	await _s5_contexts_release_after_leave(test)

	Services._party = previous_party
	Services._matchmaking = previous_matchmaking
	Services._chat = previous_chat
	if previous_clock != null and Services.has_method("use_clock"):
		Services.use_clock(previous_clock)
	await test._reset()


func _s1_capability_and_profile_gates(test: Node) -> void:
	print("CASE: pregame S1 unavailable flow and direct profile validation")
	var production := MatchmakingService.new()
	test._check(not production.is_available(),
		"Phase 0 keeps Quick Match unavailable")
	test._check(production.availability_reason() == "Quick Match is not available in this build yet.",
		"Phase 0 exposes the durable unavailable reason")

	var service := Doubles.Matchmaking.new()
	var user := Doubles.User.new("s1-local")
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
		and String(missing.get("reason_code", "")) == "profile_missing",
		"missing Deathmatch configuration is unavailable")
	service.fake_mode_config = _mode_config(4)
	test._check(service.availability_reason().is_empty()
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
	clock.advance(599.999)
	await _frames(test, 1)
	test._check(timeout_attempt.outcome == MatchmakingService.Outcome.PENDING,
		"search remains pending just before 600 seconds")
	clock.advance(0.001)
	await _frames(test, 2)
	test._check(timeout_attempt.outcome == MatchmakingService.Outcome.TIMEOUT,
		"local 600-second expiry remains distinct from service no-match")
	await _drain_clock(test, clock, "S4 timeout")


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
		user, "arrangement-fail", {}, 1, 51, 30000)
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


func _s5_disabled_kind_fence(test: Node) -> void:
	print("CASE: disabled matchmaking kinds leave the joined lobby before Party work")
	var previous_matchmaking: MatchmakingService = Services._matchmaking
	Services._matchmaking = MatchmakingService.new()
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
			"disabled %s ingress fails ok=%s" % [kind, result.get("ok")])
		test._check(error == Services.quick_match_unavailable_reason(),
			"disabled %s reason=%s" % [kind, error])
		test._check(String(result.get("kind", "")) == kind,
			"disabled %s preserves detected kind=%s" % [kind, result.get("kind")])
		test._check(result.get("context") == null,
			"disabled %s context=%s" % [kind, result.get("context")])
		test._check(result.get("peer") == null,
			"disabled %s peer=%s" % [kind, result.get("peer")])
		test._check(String(result.get("code", "")).is_empty(),
			"disabled %s code=%s" % [kind, result.get("code")])
		test._check(service.pf.party.join_calls.is_empty(),
			"disabled %s Party joins=%d" % [kind, service.pf.party.join_calls.size()])
		test._check(lobby.leaves == 1,
			"disabled %s lobby leaves=%d" % [kind, lobby.leaves])
		test._check(lobby.update_calls == 0 and lobby.property_calls == 0,
			"disabled %s lobby updates=%d property_writes=%d" % [
				kind, lobby.update_calls, lobby.property_calls])
		test._check(not service.has_owned_work(),
			"disabled %s owned_work=%s" % [kind, service.has_owned_work()])
		test._check(not service.has_network(),
			"disabled %s has_network=%s" % [kind, service.has_network()])
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
		user, "global-arrangement", {}, 1, 70, 30000)
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
		user, "quiescence-arrangement", {}, 1, 75, 0)
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
	test._check(prepare_results.is_empty() and global_results.is_empty()
		and replacement_results.size() == 1
		and not bool((replacement_results[0] as Dictionary).get("ok", false))
		and service.pf.party.create_calls.size() == 1,
		"blocked prepare keeps global leave active and refuses replacement network creation")
	service.pf.party.block_create = false
	service.pf.party.create_released.emit()
	await _frames(test, 2)
	test._check(prepare_results.is_empty() and global_results.is_empty()
		and replacement_results.size() == 1 and returned_network.leaves == 1
		and service.has_owned_work(),
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
		user, "old-recovery-arrangement", {}, 1, 76, 0)
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
	test._check(prepare_results.is_empty(),
		"old prepare remains delayed through confirmed reset results=%d" % prepare_results.size())
	test._check(service._contexts.is_empty() and service._owned_operation_count == 0,
		"confirmed reset removes old contexts=%d and count=%d" % [
			service._contexts.size(), service._owned_operation_count])
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
		user, "conflict-arrangement", {}, 1, 90, 30000)
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
		user, "weak-arrangement", {}, 1, 100, 0)
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


func _capture_arranged_join(
	service: Doubles.Party,
	user: Doubles.User,
	results: Array
) -> void:
	results.append(await service.join_arranged(
		user, "stale-arrangement", {}, 1, 93, 30000))


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
