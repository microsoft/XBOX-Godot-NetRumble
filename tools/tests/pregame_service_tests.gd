extends RefCounted

const Doubles := preload("res://tools/tests/pregame_service_doubles.gd")
const SOURCE_REQUIRED_SURFACES := [
	"PlayFabLobbyJoinConfig.member_properties",
	"PlayFabLobbyJoinConfig.max_member_count",
	"PlayFabLobbyJoinConfig.access_policy",
	"PlayFabLobbyJoinConfig.owner_migration_policy",
	"PlayFabLobbyJoinConfig.restrict_invites_to_lobby_owner",
	"PlayFabLobbyConfig.max_players",
	"PlayFabLobbyConfig.access_policy",
	"PlayFabLobbyConfig.owner_migration_policy",
	"PlayFabLobbyConfig.search_properties",
	"PlayFabLobbyConfig.lobby_properties",
	"PlayFabLobbyConfig.member_properties",
	"PlayFabLobbyConfig.restrict_invites_to_lobby_owner",
	"PlayFabLobbyUpdateConfig.lobby_properties",
	"PlayFabLobbyUpdateConfig.search_properties",
	"PlayFabLobby.lobby_id",
	"PlayFabLobby.connection_string",
	"PlayFabLobby.owner_entity_key",
	"PlayFabLobby.max_member_count",
	"PlayFabLobby.members",
	"PlayFabLobby.properties",
	"PlayFabLobby.search_properties",
	"PlayFabLobby.access_policy",
	"PlayFabLobby.owner_migration_policy",
	"PlayFabLobby.membership_lock",
	"PlayFabLobby.restrict_invites_to_lobby_owner",
	"PlayFabLobby.is_disconnected",
	"PlayFabLobby.is_owner",
	"PlayFabLobby.set_properties_async",
	"PlayFabLobby.set_member_properties_async",
	"PlayFabLobby.set_membership_lock_async",
	"PlayFabLobby.post_update_async",
	"PlayFabLobby.leave_async",
	"PlayFabLobby.state_changed",
	"PlayFabLobbyMember.entity_key",
	"PlayFabLobbyMember.properties",
	"PlayFabLobbyMember.connection_status",
	"PlayFabLobbyStateChange.kind",
	"PlayFabLobbyStateChange.result",
	"PlayFabPartyConfig.max_players",
	"PlayFabPartyConfig.invitation_id",
	"PlayFabPartyConfig.enable_voice_chat",
	"PlayFabPartyConfig.enable_text_chat",
	"PlayFabPartyConfig.enable_transcription",
	"PlayFabPartyConfig.enable_translation",
	"PlayFabPartyConfig.direct_peer_connectivity",
	"PlayFabPartyNetwork.descriptor",
	"PlayFabPartyNetwork.local_peer",
	"PlayFabPartyNetwork.leave_async",
	"PlayFabPartyNetwork.state_changed",
	"PlayFabPartyNetworkStateChange.kind",
	"PlayFabPartyNetworkStateChange.network",
	"PlayFabPartyNetworkStateChange.result",
	"PlayFabPartyNetworkStateChange.peer_id",
	"PlayFabPartyNetworkStateChange.state",
	"PlayFabPartyPeer.get_peer_entity_key",
	"PlayFabPartyPeer.get_connection_status",
	"PlayFabPartyPeer.get_unique_id",
	"PlayFabMatchmakingTicketConfig.queue_name",
	"PlayFabMatchmakingTicketConfig.timeout_seconds",
	"PlayFabMatchmakingTicketConfig.members",
	"PlayFabMatchmakingTicketConfig.members_to_match_with",
	"PlayFabMatchTicket.ticket_id",
	"PlayFabMatchTicket.status",
	"PlayFabMatchTicket.match_id",
	"PlayFabMatchTicket.arranged_lobby_connection_string",
	"PlayFabMatchTicket.cancel_async",
	"PlayFabMatchTicket.state_changed",
	"PlayFabMatchTicketStateChange.result",
	"PlayFabMatchmakingMember.user",
	"PlayFabMatchmakingMember.attributes",
	"PlayFabResult.ok",
	"PlayFabResult.data",
	"PlayFabResult.hresult",
	"PlayFabResult.code",
	"PlayFabResult.message",
	"PlayFabUser.get_entity_key",
	"PlayFab.is_initialized",
	"PlayFabMultiplayer.is_initialized",
	"PlayFabMultiplayer.initialize_async",
	"PlayFabMultiplayer.shutdown_async",
	"PlayFabMultiplayer.create_lobby_async",
	"PlayFabMultiplayer.join_lobby_async",
	"PlayFabMultiplayer.create_match_ticket_async",
	"PlayFabMultiplayer.join_match_ticket_async",
	"PlayFabMultiplayer.join_arranged_lobby_async",
	"PlayFabParty.is_initialized",
	"PlayFabParty.initialize_async",
	"PlayFabParty.shutdown_async",
	"PlayFabParty.create_and_join_network_async",
	"PlayFabParty.join_network_async",
]
const SOURCE_OPTIONAL_SURFACES := [
	"PlayFabPartyNetworkStateChange.reason",
	"PlayFabMatchTicket.properties",
	"PlayFabLobbySearchConfig.filter",
	"PlayFabLobbySearchConfig.max_results",
	"PlayFabLobbySummary.connection_string",
	"PlayFabLobbySummary.member_count",
	"PlayFabLobbySummary.max_member_count",
	"PlayFabLobbySearchResult.lobbies",
	"PlayFabMultiplayer.find_lobbies_async",
]
# Pinned Sample 442d790, PlayFab Multiplayer implementation lines 636-700,
# 2042-2091, 3062-3096 and 3751-3846.
const SOURCE_MATCHMAKING_NATIVE_CODES := [
	"shutting_down",
	"not_initialized",
	"invalid_user",
	"invalid_match_ticket_config",
	"invalid_match_ticket_member",
	"match_ticket_create_start_failed",
	"match_ticket_create_failed",
	"match_ticket_create_cancelled",
	"invalid_join_match_ticket",
	"match_ticket_join_start_failed",
	"match_ticket_join_failed",
	"match_ticket_join_cancelled",
	"invalid_match_ticket",
	"match_ticket_cancel_start_failed",
	"match_ticket_completed_failed",
	"match_ticket_cancel_lost_race",
	"lobby_state_finish_failed",
	"matchmaking_state_finish_failed",
	"cancelled",
]
# Pinned Sample 442d790, PlayFab Multiplayer implementation lines 2056-2091,
# 2238-2769 and 3370-3720; PlayFab Party implementation lines 25-43,
# 2149-2202, 2685-2755, 2872-3180, 3230-3785 and 4620-4758.
const SOURCE_PARTY_NATIVE_CODES := [
	"shutting_down",
	"not_initialized",
	"already_initialized",
	"multiplayer_queue_create_failed",
	"multiplayer_initialize_failed",
	"multiplayer_cleanup_failed",
	"invalid_user",
	"invalid_properties",
	"unsupported_on_gdk_edition",
	"lobby_create_start_failed",
	"lobby_create_failed",
	"invalid_connection_string",
	"lobby_join_start_failed",
	"lobby_join_failed",
	"invalid_arranged_lobby_connection_string",
	"invalid_arranged_lobby_config",
	"arranged_lobby_join_start_failed",
	"arranged_lobby_join_failed",
	"invalid_search",
	"lobby_search_start_failed",
	"lobby_search_failed",
	"invalid_lobby",
	"invalid_update",
	"lobby_update_start_failed",
	"lobby_update_failed",
	"member_update_start_failed",
	"lobby_leave_start_failed",
	"lobby_disconnected",
	"lobby_state_finish_failed",
	"matchmaking_state_finish_failed",
	"party_shutting_down",
	"party_not_initialized",
	"party_already_initialized",
	"party_invalid_options",
	"party_invalid_user",
	"party_network_create_failed",
	"party_network_connect_failed",
	"party_descriptor_invalid",
	"party_transport_create_failed",
	"party_peer_not_connected",
	"party_handshake_endpoint_entity_unavailable",
	"party_handshake_entity_mismatch",
	"party_chat_control_create_failed",
	"party_resource_not_ready",
	"party_state_start_failed",
	"party_state_finish_failed",
	"party_cleanup_failed",
	"cancelled",
]


func run(test: Node) -> void:
	Doubles.Matchmaking.clear_test_instances()
	var previous_party: PartyService = Services._party
	var previous_matchmaking: MatchmakingService = Services._matchmaking
	var previous_chat: ChatService = Services._chat
	var previous_clock: Variant = Services.clock() if Services.has_method("clock") else null

	await _s1_capability_and_profile_gates(test)
	await _s1_required_runtime_surface(test)
	await _s1_optional_capability_degradation(test)
	await _s1_arranged_capacity_contract(test)
	await _s1_default_ticket_clock(test)
	await _s2_group_ticket_shape(test)
	await _s3_level_triggered_ticket_lifecycle(test)
	await _a_mig_early_terminal_results(test)
	await _s3_guest_join_and_late_retirement(test)
	await _s4_failure_cancel_and_timeout(test)
	await _s4_native_cleanup_ownership(test)
	await _s4_matched_cancel_contracts(test)
	await _s4_failure_cause_availability(test)
	await _s4_safe_structured_failure_logging(test)
	await _s4_source_derived_native_code_paths(test)
	await _a_mig_party_handshake_rejections(test)
	await _s4_observe_terminal_before_cancel(test)
	await _s5_scoped_lobby_ownership(test)
	await _s5_hosted_production_paths(test)
	await _s5_unavailable_kind_fence(test)
	await _s5_global_leave_and_overlap(test)
	await _s5_global_leave_waits_for_pending_prepare(test)
	await _s5_recovery_epoch_isolates_late_scoped_work(test)
	await _s5_recovery_settles_scoped_leave_waiters(test)
	await _s5_cleanup_execution_and_idle_debt_facts(test)
	await _s5_native_leave_failure_cleanup_debt(test)
	await _s5_late_result_leave_failure_idle_debt(test)
	await _s5_serialized_operations_stop_after_leave(test)
	await _s5_transport_conflict_cleanup(test)
	await _s5_scoped_cancellation_and_owned_work(test)
	await _s5_contexts_release_after_leave(test)
	await _s6_scoped_deadline_ownership(test)
	await _s6_context_loss_and_admission(test)
	await _s7_arranged_control_and_publication(test)
	await _c_private_promotion_and_readback(test)
	await _c_private_hold_restore_and_round(test)
	await _c_private_invitation(test)
	await _s8_joined_owner_authority_without_flow(test)
	await _s8_legacy_guest_authority_changes(test)
	await _s8_invite_destinations(test)
	await _s9_multiplayer_invalidation(test)
	await _s10_staging_retirement_observation(test)

	var orphaned := Doubles.Matchmaking.orphan_report()
	test._check(orphaned.is_empty(),
		"suite-end matchmaking ownership is empty: %s" % orphaned)
	Doubles.Matchmaking.invalidate_test_instances()
	await _frames(test, 3)
	var remaining := Doubles.Matchmaking.orphan_report()
	test._check(remaining.is_empty(),
		"suite-end invalidation releases every alarm/waiter: %s" % remaining)
	Doubles.Matchmaking.clear_test_instances()

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
			== "Quick Match needs PlayFab addon support for: injected_group_capability.",
		"missing group-ticket capability reason=%s" % service.availability_reason())
	service.fake_group_support = true

	service.fake_arranged_support = false
	test._check(not service.is_available()
		and service.availability_reason()
			== "Quick Match needs arranged-lobby support for: injected_arranged_capability.",
		"missing arranged-lobby capability reason=%s" % service.availability_reason())
	service.fake_arranged_support = true

	for count: int in [3, 5]:
		service.fake_mode_config = _mode_config(count)
		var profile := service.runtime_profile(NRTypes.GameModeType.DEATHMATCH)
		test._check(not bool(profile.get("ok", false))
			and String(profile.get("reason_code", "")) == "profile_count_mismatch"
			and service.availability_reason()
				== "Quick Match needs the capacity-four Deathmatch settings.",
			"configured %d-player Deathmatch is unavailable through the shared profile gate" % count)
	service.fake_mode_config = null
	var missing := service.runtime_profile(NRTypes.GameModeType.DEATHMATCH)
	test._check(not bool(missing.get("ok", false))
		and String(missing.get("reason_code", "")) == "profile_missing"
		and not service.is_available()
		and service.availability_reason()
			== "Quick Match needs the capacity-four Deathmatch settings.",
		"missing Deathmatch reason=%s" % service.availability_reason())
	service.fake_mode_config = _mode_config(4)
	var supported_profile := service.runtime_profile(
		NRTypes.GameModeType.DEATHMATCH)
	test._check(service.is_available() and service.availability_reason().is_empty()
		and bool(supported_profile.get("ok", false))
		and int(supported_profile.get("capacity", 0)) == 4
		and int(supported_profile.get("queue_min_match_size", 0)) == 2
		and int(supported_profile.get("queue_max_match_size", 0)) == 4,
		"configured Deathmatch exposes queue 2-4 and capacity four")
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
	mismatched.capacity = 8
	var mismatch_attempt := service.begin_create(mismatched)
	test._check(mismatch_attempt.outcome == MatchmakingService.Outcome.FAILED,
		"non-four-player profile fails before native create")
	test._check(service.sdk.create_calls.is_empty(),
		"profile drift cannot bypass the unavailable UI")

	service.fake_mode_config = _mode_config(3)
	var mismatched_create := _spec(user, [user.entity_key], 3)
	mismatched_create.capacity = 4
	var mismatched_create_attempt := service.begin_create(mismatched_create)
	var mismatched_join := _join_spec(
		user, [user.entity_key], 4, "mismatched-ticket")
	mismatched_join.capacity = 4
	var mismatched_join_attempt := service.begin_join(mismatched_join)
	test._check(mismatched_create_attempt.outcome == MatchmakingService.Outcome.FAILED
		and mismatched_join_attempt.outcome == MatchmakingService.Outcome.FAILED
		and service.sdk.create_calls.is_empty() and service.sdk.join_calls.is_empty(),
		"caller-supplied four cannot bypass a configured three-player profile")
	service.fake_mode_config = _mode_config(4)


func _s1_required_runtime_surface(test: Node) -> void:
	print("CASE: Quick Match capability probes cover its required SDK surface")
	var baseline := Doubles.SurfaceMatchmaking.new()
	test._check(baseline.is_available(),
		"the verified current addon surface passes: %s" % baseline.availability_reason())

	var alias_only := Doubles.SurfaceMatchmaking.new()
	alias_only.join_alias_only = true
	test._check(not alias_only.is_available()
		and alias_only.missing_join_config_properties().has(
			"PlayFabLobbyJoinConfig.max_member_count"),
		"join config max_players alias cannot satisfy max_member_count")
	var alias_attempt := alias_only.begin_create(
		_spec(Doubles.User.new("surface-alias"), [
			{"id": "surface-alias", "type": "title_player_account"},
		], 15))
	test._check(alias_attempt.outcome == MatchmakingService.Outcome.FAILED,
		"alias-only direct entry fails before ticket creation")
	test._check(alias_only.multiplayer.create_match_calls == 0,
		"alias-only native create calls=%d" % alias_only.multiplayer.create_match_calls)

	for missing_surface: String in SOURCE_REQUIRED_SURFACES:
		_assert_missing_surface(test, missing_surface)


func _assert_missing_surface(test: Node, missing_surface: String) -> void:
	var service := Doubles.SurfaceMatchmaking.new()
	service.missing_surface = missing_surface
	var reason := service.availability_reason()
	test._check(not service.is_available() and reason.contains(missing_surface),
		"missing %s reason=%s" % [missing_surface, reason])
	var user := Doubles.User.new("missing-surface")
	var attempt := service.begin_create(_spec(user, [user.entity_key], 16))
	test._check(attempt.outcome == MatchmakingService.Outcome.FAILED,
		"missing %s direct outcome=%d" % [missing_surface, attempt.outcome])
	test._check(service.multiplayer.create_match_calls == 0,
		"missing %s native creates=%d" % [
			missing_surface, service.multiplayer.create_match_calls])


func _s1_optional_capability_degradation(test: Node) -> void:
	print("CASE: optional diagnostics and code search do not disable Quick Match")
	for optional_surface: String in SOURCE_OPTIONAL_SURFACES:
		var service := Doubles.SurfaceMatchmaking.new()
		service.missing_surface = optional_surface
		test._check(service.is_available(),
			"optional %s leaves Quick Match available: %s" % [
				optional_surface, service.availability_reason()])
	for optional_class: String in Doubles.SurfaceMatchmaking.OPTIONAL_SEARCH_CLASSES:
		var without_class := Doubles.SurfaceMatchmaking.new()
		without_class.missing_class = optional_class
		test._check(without_class.is_available(),
			"missing optional %s leaves Quick Match available: %s" % [
				optional_class, without_class.availability_reason()])

	var party := Doubles.Party.new(ChatService.new())
	var hosted: Dictionary = await party.host(
		Doubles.User.new("optional-reason"), 4, "deathmatch")
	var losses: Array[String] = []
	party.network_lost.connect(func(reason: String, _context: Variant) -> void:
		losses.append(reason))
	var change := Doubles.ChangeWithoutReason.new()
	change.kind = PartyService.NETWORK_CHANGE_STATE
	change.state = PartyService.NETWORK_STATE_DISCONNECTED
	change.network = party._network
	change.result = Doubles.Results.make(
		false, null, "party_network_connect_failed", "Fallback terminal reason.")
	party._network.state_changed.emit(change)
	test._check(bool(hosted.get("ok", false)) and losses == ["Fallback terminal reason."],
		"missing change.reason falls back to structured result text=%s" % [losses])
	await party.leave()

	var matchmaking := Doubles.Matchmaking.new()
	var ticket := Doubles.TicketWithoutProperties.new()
	matchmaking.sdk.queued_create_results.append(Doubles.Results.make(true, ticket))
	var user := Doubles.User.new("optional-properties")
	var attempt := matchmaking.begin_create(_spec(user, [user.entity_key], 17))
	await _frames(test, 2)
	ticket.emit_status(
		MatchmakingService.STATUS_FAILED,
		Doubles.Results.make(
			false,
			null,
			"match_ticket_completed_failed",
			"Terminal detail without ticket properties."))
	test._check(attempt.outcome == MatchmakingService.Outcome.FAILED
		and attempt.diagnostic.contains("match_ticket_completed_failed"),
		"missing ticket.properties preserves result diagnostic without a hard read")


func _s1_arranged_capacity_contract(test: Node) -> void:
	print("CASE: B-ORDER capacity-four arranged bootstrap is independent of selected size")
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
	test._check(int(accepted_snapshot.capacity) == 4
		and int(accepted_snapshot.selected_start_count) == 0
		and int(accepted_snapshot.max_members) == 4
		and (accepted_snapshot.members as Array).size() == 1
		and not bool(accepted_snapshot.membership_locked),
		"arranged snapshot keeps capacity=%s selected=%s native=%s" % [
			accepted_snapshot.capacity,
			accepted_snapshot.selected_start_count,
			accepted_snapshot.max_members,
		])
	var prepared: PartyService.PartyResult = await service.prepare_transport(
		accepted.context, user, service.fake_clock.now_msec() + 1000)
	test._check(prepared.ok(),
		"validated arranged capacity reaches transport preparation")
	var create_call: Dictionary = service.pf.party.create_calls.back() \
		if not service.pf.party.create_calls.is_empty() else {}
	test._check(int(create_call.max_players) == 4,
		"arranged transport receives captured capacity max_players=%s" % \
			create_call.get("max_players"))
	test._check(service.snapshot(accepted.context).members.size() == 1
		and not bool(service.snapshot(accepted.context).membership_locked),
		"B-ORDER owner prepares a capacity-four network while bootstrap has one unlocked member")
	await service.leave_transport(accepted.context)
	await service.leave_lobby(accepted.context)

	var tampered: PartyService.PartyResult = await service.join_arranged(
		user, "capacity-tampered", {}, 4, 1, 12, 1000)
	var creates_before := service.pf.party.create_calls.size()
	tampered.context.capacity = 3
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
	var standalone_ticket := standalone_attempt.ticket as Doubles.Ticket
	standalone.retire(standalone_attempt)
	test._check(standalone_attempt.deadline_alarm == null,
		"standalone retirement clears its alarm handle")
	test._check(production_clock.armed_alarm_count() == 0,
		"standalone retirement disarms the production clock count=%d" % \
			production_clock.armed_alarm_count())
	test._check(standalone.has_pending_cleanup()
		and standalone.sdk.pending_cancel_waiters() == 1,
		"standalone retirement owns its pending native cancel")
	standalone_ticket.publish_terminal(MatchmakingService.STATUS_CANCELLED)
	await _frames(test, 2)
	test._check(not standalone.has_pending_cleanup(),
		"standalone retirement reaches ticket quiescence")
	test._check(standalone.sdk.pending_cancel_waiters() == 0,
		"standalone retirement leaves no native cancel waiter")

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
	var configured_ticket := configured_attempt.ticket as Doubles.Ticket
	configured.retire(configured_attempt)
	test._check(fake_clock.armed_alarm_count() == 0,
		"configured retirement disarms its fake clock count=%d" % \
			fake_clock.armed_alarm_count())
	test._check(configured.has_pending_cleanup()
		and configured.sdk.pending_cancel_waiters() == 1,
		"configured retirement owns its pending native cancel")
	configured_ticket.publish_terminal(MatchmakingService.STATUS_CANCELLED)
	await _frames(test, 2)
	test._check(not configured.has_pending_cleanup(),
		"configured attempt returns cleanup ownership to zero")
	test._check(configured.sdk.pending_cancel_waiters() == 0,
		"configured retirement leaves no native cancel waiter")
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
		var ticket := attempt.ticket as Doubles.Ticket
		service.retire(attempt)
		test._check(clock.armed_alarm_count() == 0,
			"group %d retire cancels its deadline alarm count=%d" % [
				group_size, clock.armed_alarm_count()])
		ticket.publish_terminal(MatchmakingService.STATUS_CANCELLED)
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
	matched.match_id = "match-s3"
	matched.arranged_lobby_connection_string = "arrangement-s3"
	matched.prime_terminal_snapshot(MatchmakingService.STATUS_MATCHED)
	service.sdk.queued_create_results.append(Doubles.Results.make(true, matched))
	var attempt := service.begin_create(_spec(user, [user.entity_key], 30))
	await _frames(test, 2)
	test._check(attempt.outcome == MatchmakingService.Outcome.MATCHED,
		"already-matched snapshot settles without waiting for a future edge")
	test._check(attempt.match_id == "match-s3"
		and attempt.arrangement == "arrangement-s3",
		"matched snapshot copies handoff data")
	matched.publish_terminal(MatchmakingService.STATUS_MATCHED)
	test._check(attempt.outcome == MatchmakingService.Outcome.MATCHED,
		"post-destruction terminal publication emits nothing and cannot settle twice")
	test._check(matched.terminal_event_count == 0 and matched.native_destroyed,
		"primed terminal snapshot has no historical or post-destruction event")
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
	accepted.publish_terminal(
		MatchmakingService.STATUS_FAILED,
		Doubles.Results.match_ticket_completed_failed(
			accepted,
			-2147467259))
	accepted.publish_terminal(MatchmakingService.STATUS_FAILED)
	test._check(joined.outcome == MatchmakingService.Outcome.FAILED,
		"one guest terminal publication settles the attempt once")
	test._check(accepted.terminal_event_count == 1 and accepted.native_destroyed,
		"one guest terminal publication retains its cached snapshot")

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
	await _frames(test, 2)
	late_ticket.publish_terminal(MatchmakingService.STATUS_CANCELLED)
	await _frames(test, 2)
	test._check(retired.outcome == MatchmakingService.Outcome.SUPERSEDED
		and late_ticket.cancel_calls == 1 and current.is_pending()
		and not late.has_pending_cleanup(),
		"a retired blocked join cleans only its late ticket and cannot mutate the current attempt")
	var current_ticket := current.ticket as Doubles.Ticket
	late.retire(current)
	current_ticket.publish_terminal(MatchmakingService.STATUS_CANCELLED)


func _a_mig_early_terminal_results(test: Node) -> void:
	print("CASE: A-MIG-01/02 single terminal snapshots and early cancellation shapes")
	var user := Doubles.User.new("a-mig-early")

	var create_cancelled := Doubles.Matchmaking.new()
	create_cancelled.sdk.queued_create_results.append(
		Doubles.Results.match_ticket_create_cancelled({
			"source": "create-cancelled",
		}))
	var create_attempt := create_cancelled.begin_create(
		_spec(user, [user.entity_key], 36))
	await _frames(test, 2)
	test._check(create_attempt.outcome == MatchmakingService.Outcome.CANCELLED
		and create_attempt.status == MatchmakingService.STATUS_CANCELLED
		and create_attempt.native_terminal
		and not create_attempt.cleanup_pending,
		"A-MIG-02 create cancelled before id settles CANCELLED from its result shape")

	var join_cancelled := Doubles.Matchmaking.new()
	var cancelled_ticket := Doubles.Ticket.new()
	cancelled_ticket.ticket_id = "cancelled-join"
	cancelled_ticket.prime_terminal_snapshot(
		MatchmakingService.STATUS_CANCELLED)
	join_cancelled.sdk.queued_join_results.append(
		Doubles.Results.match_ticket_join_cancelled(cancelled_ticket))
	var join_attempt := join_cancelled.begin_join(_join_spec(
		user,
		[user.entity_key],
		37,
		"cancelled-join"))
	await _frames(test, 2)
	test._check(join_attempt.outcome == MatchmakingService.Outcome.CANCELLED
		and join_attempt.status == MatchmakingService.STATUS_CANCELLED
		and join_attempt.ticket_id == "cancelled-join"
		and join_attempt.native_terminal,
		"A-MIG-02 terminal guest join reconciles the cached cancelled ticket")

	var cancelled_precedence := Doubles.Matchmaking.new()
	var precedence_ticket := Doubles.Ticket.new()
	cancelled_precedence.sdk.queued_create_results.append(
		Doubles.Results.make(true, precedence_ticket))
	var precedence_attempt := cancelled_precedence.begin_create(
		_spec(user, [user.entity_key], 371))
	await _frames(test, 2)
	precedence_ticket.publish_terminal(
		MatchmakingService.STATUS_CANCELLED,
		Doubles.Results.make(
			false,
			precedence_ticket,
			"match_ticket_completed_failed",
			"Injected SDK cancellation HRESULT.",
			-1994169596))
	test._check(precedence_attempt.outcome == MatchmakingService.Outcome.CANCELLED
		and precedence_attempt.status == MatchmakingService.STATUS_CANCELLED
		and precedence_attempt.reason_code == &""
		and cancelled_precedence.fake_warnings.is_empty(),
		"A-MIG-03 Cancelled status wins over a non-OK completion HRESULT")

	var failed_join := Doubles.Matchmaking.new()
	var failed_ticket := Doubles.Ticket.new()
	failed_ticket.ticket_id = "failed-join"
	failed_ticket.prime_terminal_snapshot(MatchmakingService.STATUS_FAILED)
	failed_join.sdk.queued_join_results.append(
		Doubles.Results.make(
			false,
			failed_ticket,
			"match_ticket_join_failed",
			"Injected forwarded join failure.",
			-1994172846))
	var failed_attempt := failed_join.begin_join(_join_spec(
		user,
		[user.entity_key],
		38,
		"failed-join"))
	await _frames(test, 2)
	test._check(failed_attempt.outcome == MatchmakingService.Outcome.FAILED
		and failed_attempt.reason_code == &"ticket_group_too_large"
		and failed_attempt.status == MatchmakingService.STATUS_FAILED,
		"A-MIG-06 terminal join forwards the signed native HRESULT into classification")


func _s4_failure_cancel_and_timeout(test: Node) -> void:
	print("CASE: pregame S4 full-party rejection, cancellation, and timeout stay distinct")
	var user := Doubles.User.new("s4-local")
	var members := _full_group(user, "s4")

	for hresult: int in [-1994172846, 2300794450]:
		var immediate := Doubles.Matchmaking.new()
		immediate.sdk.queued_create_results.append(Doubles.Results.make(
			false,
			null,
			"match_ticket_create_failed",
			"Injected credential SECRET_IMMEDIATE.",
			hresult))
		var immediate_attempt := immediate.begin_create(_spec(user, members, 40))
		await _frames(test, 2)
		_full_party_failure(test, immediate_attempt,
			"immediate signed/unsigned size HRESULT has the specific durable outcome")
		test._check(immediate.fake_warnings.size() == 1
			and immediate.fake_warnings[0].contains("detail=available"),
			"confirmed size HRESULT logs available cause detail=%s" % \
				[immediate.fake_warnings])
		test._check(immediate_attempt.ticket == null
			and not immediate_attempt.cleanup_pending,
			"confirmed no-ticket rejection owns no nonexistent cancellation")

		var terminal := Doubles.Matchmaking.new()
		var failed_ticket := Doubles.Ticket.new()
		terminal.sdk.queued_create_results.append(Doubles.Results.make(true, failed_ticket))
		var terminal_attempt := terminal.begin_create(_spec(user, members, 41))
		await _frames(test, 2)
		failed_ticket.emit_status(
			MatchmakingService.STATUS_FAILED,
			Doubles.Results.match_ticket_completed_failed(
				failed_ticket,
				hresult))
		_full_party_failure(test, terminal_attempt,
			"terminal signed/unsigned size HRESULT has the specific durable outcome")

	var lossy_create := Doubles.Matchmaking.new()
	lossy_create.sdk.queued_create_results.append(Doubles.Results.make(
		false,
		null,
		"match_ticket_create_failed",
		"Injected lossy create detail.",
		-2147467259))
	var lossy_create_attempt := lossy_create.begin_create(
		_spec(user, members, 42))
	await _frames(test, 2)
	_generic_full_party_failure(
		test,
		lossy_create_attempt,
		&"ticket_create_failed",
		"lossy no-id create stays generic with private-route guidance")

	var lossy_terminal := Doubles.Matchmaking.new()
	var lossy_ticket := Doubles.Ticket.new()
	lossy_terminal.sdk.queued_create_results.append(
		Doubles.Results.make(true, lossy_ticket))
	var lossy_terminal_attempt := lossy_terminal.begin_create(
		_spec(user, members, 43))
	await _frames(test, 2)
	lossy_ticket.emit_status(
		MatchmakingService.STATUS_FAILED,
		Doubles.Results.match_ticket_completed_failed(
			lossy_ticket,
			-2147467259))
	_generic_full_party_failure(
		test,
		lossy_terminal_attempt,
		&"matchmaking_failed",
		"lossy terminal failure stays generic with private-route guidance")
	test._check(MatchmakingService.reason_for_code(
		String(MatchmakingService.FULL_PARTY_REASON_CODE))
			== MatchmakingService.FULL_PARTY_REASON,
		"confirmed full-party reason lookup remains unchanged")
	test._check(MatchmakingService.FULL_PARTY_REASON
			== "Matchmaking rejected this full four-player ticket."
		and MatchmakingService.FULL_PARTY_GUIDANCE
			== "Return to the group and ready up to start a private match without searching."
		and not MatchmakingService.FULL_PARTY_GUIDANCE.contains("Host Match"),
		"full-party constants describe the current private route")
	test._check(MatchmakingService.reason_for_code("matchmaking_failed").is_empty(),
		"generic reason codes are carried with explicit text, not inferred")
	var guided_control_text := PartyService.encode_search_control({
		"epoch": 1,
		"phase": "gathering",
		"group": [user.entity_key],
		"reason_code": String(lossy_terminal_attempt.reason_code),
		"reason": lossy_terminal_attempt.reason,
	})
	var guided_control := PartyService.decode_search_control(guided_control_text)
	test._check(bool(guided_control.get("valid", false))
		and String(guided_control.get("reason", ""))
			== lossy_terminal_attempt.reason,
		"search control preserves the complete generic reason and policy guidance")

	var absent_terminal := Doubles.Matchmaking.new()
	var absent_ticket := Doubles.Ticket.new()
	absent_terminal.sdk.queued_create_results.append(
		Doubles.Results.make(true, absent_ticket))
	var absent_attempt := absent_terminal.begin_create(
		_spec(user, members, 44))
	await _frames(test, 2)
	absent_ticket.emit_status(MatchmakingService.STATUS_FAILED)
	_generic_full_party_failure(
		test,
		absent_attempt,
		&"matchmaking_failed",
		"terminal failure without native detail stays generic with private-route guidance")

	for explicit_failure: Dictionary in [
		{"code": "not_initialized", "hresult": -1994183168},
		{"code": "shutting_down", "hresult": -1994183167},
		{"code": "invalid_user", "hresult": -2147024809},
		{"code": "invalid_member", "hresult": -2147024809},
		{"code": "invalid_config", "hresult": -2147024809},
		{"code": "queue_not_found", "hresult": -1994174463},
	]:
		var explicit := Doubles.Matchmaking.new()
		explicit.sdk.queued_create_results.append(Doubles.Results.make(
			false,
			null,
			String(explicit_failure.code),
			"Injected explicit failure.",
			int(explicit_failure.hresult)))
		var explicit_attempt := explicit.begin_create(_spec(user, members, 45))
		await _frames(test, 2)
		test._check(explicit_attempt.reason_code == &"ticket_create_failed",
			"explicit %s reason_code=%s" % [
				explicit_failure.code, explicit_attempt.reason_code])
		test._check(not explicit_attempt.reason.contains(
			MatchmakingService.FULL_PARTY_GUIDANCE),
			"explicit %s is not recast as queue-size failure" % \
				explicit_failure.code)

	var diagnostic_service := Doubles.Matchmaking.new()
	var diagnostic_ticket := Doubles.Ticket.new()
	diagnostic_ticket.properties = {"detail": "no match wording is not a structured outcome"}
	diagnostic_service.sdk.queued_create_results.append(
		Doubles.Results.make(true, diagnostic_ticket))
	var diagnostic_attempt := diagnostic_service.begin_create(
		_spec(user, [user.entity_key], 46))
	await _frames(test, 2)
	diagnostic_ticket.emit_status(
		MatchmakingService.STATUS_FAILED,
		Doubles.Results.make(false, null, "service_failure", "No match text from the service."))
	test._check(diagnostic_attempt.outcome == MatchmakingService.Outcome.FAILED
		and diagnostic_attempt.diagnostic.contains("service_failure")
		and diagnostic_attempt.diagnostic.contains("No match text"),
		"injected malformed terminal result is preserved and arbitrary no-match wording remains FAILED")

	var cancelling := Doubles.Matchmaking.new()
	var cancel_ticket := Doubles.Ticket.new()
	cancelling.sdk.queued_create_results.append(Doubles.Results.make(true, cancel_ticket))
	var cancel_attempt := cancelling.begin_create(_spec(user, [user.entity_key], 47))
	await _frames(test, 2)
	cancelling.request_cancel(cancel_attempt)
	cancel_ticket.publish_terminal(MatchmakingService.STATUS_CANCELLED)
	await _frames(test, 2)
	test._check(cancel_attempt.outcome == MatchmakingService.Outcome.CANCELLED,
		"cancellation settles only after the ticket reaches terminal cancelled")

	var timing := Doubles.Matchmaking.new()
	var clock := Doubles.Clock.new()
	timing.configure_clock(clock)
	var timeout_ticket := Doubles.Ticket.new()
	timing.sdk.queued_create_results.append(Doubles.Results.make(true, timeout_ticket))
	var timeout_spec := _spec(user, [user.entity_key], 48)
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
	timeout_ticket.publish_terminal(MatchmakingService.STATUS_CANCELLED)
	await _frames(test, 2)
	await _assert_matchmaking_case_clean(
		test, timing, clock, "S4 standalone timeout")
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
		ticket.publish_terminal(MatchmakingService.STATUS_MATCHED)
	elif terminal_status == MatchmakingService.STATUS_FAILED:
		ticket.publish_terminal(
			terminal_status,
			Doubles.Results.match_ticket_completed_failed(ticket))
	else:
		ticket.publish_terminal(terminal_status)
	test._check(attempt.outcome == MatchmakingService.Outcome.TIMEOUT,
		"[%s] terminal evidence cannot rewrite TIMEOUT" % label)
	if terminal_status == MatchmakingService.STATUS_MATCHED:
		test._check(attempt.match_id == "cancel-race-match"
			and attempt.arrangement == "cancel-race-arrangement",
			"[matched] terminal cleanup still captures handoff diagnostics")
	test._check(not service.has_pending_cleanup(),
		"[%s] terminal publication resolves the native cancel in the same call" % label)
	await _frames(test, 2)
	test._check(ticket.cancel_calls == 1,
		"[%s] native cancel total=%d" % [label, ticket.cancel_calls])
	test._check(attempt.outcome == MatchmakingService.Outcome.TIMEOUT,
		"[%s] caller outcome remains TIMEOUT after cancel return" % label)
	test._check(not attempt.cleanup_pending,
		"[%s] attempt cleanup_pending=%s" % [
			label, attempt.cleanup_pending])
	test._check(not service.has_pending_cleanup(),
		"[%s] service reaches ticket quiescence" % label)
	test._check(service.sdk.pending_cancel_waiters() == 0,
		"[%s] fake native cancel waiters=%d" % [
			label, service.sdk.pending_cancel_waiters()])
	test._check(clock.armed_alarm_count() == 0,
		"[%s] final alarm count=%d" % [
			label, clock.armed_alarm_count()])
	await _drain_clock(test, clock, "S4 cancel-in-flight " + label)


func _s4_native_cleanup_ownership(test: Node) -> void:
	print("CASE: pregame S4 caller outcomes settle once while native cleanup remains owned")
	var user := Doubles.User.new("cleanup-local")

	var failed_service := Doubles.Matchmaking.new()
	var failed_ticket := Doubles.Ticket.new()
	failed_service.sdk.queued_create_results.append(Doubles.Results.make(true, failed_ticket))
	var failed := failed_service.begin_create(_spec(user, [user.entity_key], 45))
	await _frames(test, 2)
	failed_service.request_cancel(failed)
	failed_ticket.release_cancel(Doubles.Results.make(
		false,
		failed_ticket,
		"match_ticket_cancel_start_failed",
		"Injected cancel observer failure.",
		-2147467259))
	await _frames(test, 2)
	test._check(failed.outcome == MatchmakingService.Outcome.FAILED
		and failed.reason_code == &"cancel_unconfirmed"
		and failed.cleanup_pending and failed.ticket == failed_ticket
		and failed_service.has_pending_cleanup(),
		"failed cancel settles the caller but keeps the live ticket owned")
	failed_service.retire(failed)
	await _frames(test, 2)
	test._check(failed.outcome == MatchmakingService.Outcome.FAILED
		and failed.cleanup_pending
		and failed_ticket.cancel_calls == 2
		and failed_ticket.cancel_waiting,
		"retiring a failed cancel keeps its outcome and performs one service-owned retry")
	failed_ticket.publish_terminal(MatchmakingService.STATUS_CANCELLED)
	test._check(failed.outcome == MatchmakingService.Outcome.FAILED
		and not failed.cleanup_pending and not failed_service.has_pending_cleanup(),
		"later terminal evidence clears cleanup without rewriting the caller outcome")

	var unconfirmed_service := Doubles.Matchmaking.new()
	var unconfirmed_ticket := Doubles.Ticket.new()
	unconfirmed_service.sdk.queued_create_results.append(
		Doubles.Results.make(true, unconfirmed_ticket))
	var unconfirmed := unconfirmed_service.begin_create(
		_spec(user, [user.entity_key], 46))
	await _frames(test, 2)
	unconfirmed_service.request_cancel(unconfirmed)
	unconfirmed_ticket.release_cancel(Doubles.Results.make(
		true,
		unconfirmed_ticket))
	await _frames(test, 2)
	test._check(unconfirmed.outcome == MatchmakingService.Outcome.FAILED
		and unconfirmed.cleanup_pending,
		"success-shaped cancel without terminal status remains unconfirmed and owned")
	unconfirmed_ticket.publish_terminal(MatchmakingService.STATUS_CANCELLED)
	test._check(not unconfirmed.cleanup_pending,
		"unconfirmed cancel ownership clears when terminal status eventually arrives")
	test._check(not unconfirmed_ticket.has_retained_cancel_result(),
		"unconfirmed cancel releases its stored result after the waiter consumes it")

	var race_service := Doubles.Matchmaking.new()
	var race_clock := Doubles.Clock.new()
	race_service.configure_clock(race_clock)
	var race_ticket := Doubles.Ticket.new()
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
	race_ticket.publish_terminal(MatchmakingService.STATUS_MATCHED)
	await _frames(test, 2)
	test._check(race.outcome == MatchmakingService.Outcome.TIMEOUT
		and race.match_id == "late-match" and not race.cleanup_pending
		and not race_service.has_pending_cleanup(),
		"matched-versus-timeout reconciles cleanup without replacing TIMEOUT")
	await _drain_clock(test, race_clock, "S4 timeout/match race")

	var retired_service := Doubles.Matchmaking.new()
	var retired_ticket := Doubles.Ticket.new()
	retired_service.sdk.queued_create_results.append(Doubles.Results.make(true, retired_ticket))
	var retired := retired_service.begin_create(_spec(user, [user.entity_key], 48))
	await _frames(test, 2)
	retired_service.retire(retired)
	test._check(retired.outcome == MatchmakingService.Outcome.SUPERSEDED
		and retired.cleanup_pending and retired_ticket.cancel_calls == 1,
		"retire is synchronous and leaves pending native cleanup owned")
	retired_ticket.publish_terminal(MatchmakingService.STATUS_CANCELLED)
	await _frames(test, 2)
	test._check(not retired.cleanup_pending and not retired_service.has_pending_cleanup(),
		"retired cleanup clears only after native terminal completion")

	var matched_service := Doubles.Matchmaking.new()
	var matched_ticket := Doubles.Ticket.new()
	matched_ticket.match_id = "matched"
	matched_ticket.arranged_lobby_connection_string = "arranged"
	matched_ticket.prime_terminal_snapshot(MatchmakingService.STATUS_MATCHED)
	matched_service.sdk.queued_create_results.append(Doubles.Results.make(true, matched_ticket))
	var matched := matched_service.begin_create(_spec(user, [user.entity_key], 49))
	await _frames(test, 2)
	matched_service.retire(matched)
	test._check(matched.outcome == MatchmakingService.Outcome.MATCHED
		and matched_ticket.cancel_calls == 0 and not matched.cleanup_pending,
		"retiring a natively matched ticket never issues cancellation")


func _s4_matched_cancel_contracts(test: Node) -> void:
	print("CASE: A-MIG-04/05/07 fixed-contract cancel races and injected fallback")
	var user := Doubles.User.new("matched-cancel-contract")

	var fault := Doubles.Matchmaking.new()
	var fault_clock := Doubles.Clock.new()
	fault.configure_clock(fault_clock)
	var fault_cleanup_events: Array[int] = []
	fault.cleanup_state_changed.connect(func() -> void:
		fault_cleanup_events.append(1))
	var fault_ticket := Doubles.Ticket.new()
	fault_ticket.cancel_fault_unanswered = true
	fault.sdk.queued_create_results.append(Doubles.Results.make(true, fault_ticket))
	var fault_attempt := fault.begin_create(
		_spec(user, [user.entity_key], 80))
	var fault_terminal: Array = []
	fault_attempt.native_terminal_changed.connect(
		func(_attempt: Variant) -> void: fault_terminal.append(true))
	await _frames(test, 2)
	fault.request_cancel(fault_attempt)
	await _frames(test, 1)
	fault.retire(fault_attempt)
	fault_ticket.match_id = "fault-match"
	fault_ticket.arranged_lobby_connection_string = "fault-arrangement"
	var terminal_events_before := fault_cleanup_events.size()
	fault_ticket.publish_terminal(MatchmakingService.STATUS_MATCHED)
	test._check(fault_cleanup_events.size() > terminal_events_before,
		"injected unanswered terminal observation publishes cleanup state")
	await _frames(test, 2)
	test._check(fault_attempt.outcome == MatchmakingService.Outcome.SUPERSEDED
		and fault_attempt.cancel_in_flight
		and fault_attempt.cleanup_pending
		and fault.has_orphaned_matched_cancel()
		and fault_terminal.is_empty(),
		"A-MIG-07 injected unanswered observer alone retains orphan cleanup")
	fault.fake_account_current = false
	test._check(fault.has_orphaned_matched_cancel(),
		"injected orphan ownership survives account staleness")
	var invalidation_events_before := fault_cleanup_events.size()
	fault.multiplayer_invalidated(1)
	test._check(fault_cleanup_events.size() > invalidation_events_before,
		"Multiplayer invalidation emits cleanup state synchronously")
	await _frames(test, 3)
	test._check(not fault_attempt.cancel_in_flight
		and not fault_attempt.cleanup_pending
		and not fault.has_pending_cleanup()
		and not fault.has_orphaned_matched_cancel()
		and fault.sdk.pending_cancel_waiters() == 0,
		"confirmed reset discharges only the injected unanswered observer")
	test._check(fault.fake_warnings.size() == 1
		and fault.fake_warnings[0].contains(
			"reason=cancel_released_by_reset")
		and fault.fake_warnings[0].contains("native_code=cancelled")
		and fault.fake_warnings[0].contains("hresult=0x80004004"),
		"injected reset release has distinct provenance=%s" % \
			[fault.fake_warnings])
	await _drain_clock(test, fault_clock, "S4 injected unanswered cancel")

	var failed := Doubles.Matchmaking.new()
	var failed_ticket := Doubles.Ticket.new()
	failed.sdk.queued_create_results.append(Doubles.Results.make(
		true, failed_ticket))
	var failed_attempt := failed.begin_create(
		_spec(user, [user.entity_key], 81))
	await _frames(test, 2)
	failed.request_cancel(failed_attempt)
	await _frames(test, 1)
	var failed_completion := Doubles.Results.match_ticket_completed_failed(
		failed_ticket)
	failed_ticket.publish_terminal(
		MatchmakingService.STATUS_FAILED,
		failed_completion)
	await _frames(test, 3)
	test._check(failed_attempt.outcome == MatchmakingService.Outcome.FAILED
		and not failed_attempt.cancel_in_flight
		and not failed_attempt.cleanup_pending,
		"a FAILED completion remains a ticket failure and reaches quiescence")
	var failed_lost_race := false
	for warning: String in failed.fake_warnings:
		failed_lost_race = failed_lost_race or warning.contains("cancel_lost_race")
	test._check(not failed_lost_race,
		"a FAILED completion is never labelled as a lost cancel race")

	for ordering: String in ["completion_first", "event_first"]:
		for retired_before_match: bool in [false, true]:
			var race := Doubles.Matchmaking.new()
			var race_clock := Doubles.Clock.new()
			race.configure_clock(race_clock)
			var race_ticket := Doubles.Ticket.new()
			race_ticket.terminal_delivery_order = StringName(ordering)
			race.sdk.queued_create_results.append(Doubles.Results.make(
				true, race_ticket))
			var race_attempt := race.begin_create(
				_spec(user, [user.entity_key], 82))
			var terminal_cancel_states: Array[bool] = []
			var finished_cancel_states: Array[bool] = []
			race_attempt.native_terminal_changed.connect(
				func(observed: Variant) -> void:
					terminal_cancel_states.append(bool(observed.cancel_in_flight)))
			race_attempt.finished.connect(
				func(observed: Variant) -> void:
					finished_cancel_states.append(bool(observed.cancel_in_flight)))
			await _frames(test, 2)
			race.request_cancel(race_attempt)
			if retired_before_match:
				race.retire(race_attempt)
			race_ticket.match_id = "race-" + ordering
			race_ticket.arranged_lobby_connection_string = \
				"race-arrangement-" + ordering
			race_ticket.publish_terminal(MatchmakingService.STATUS_MATCHED)
			await _frames(test, 2)
			var expected_outcome := MatchmakingService.Outcome.SUPERSEDED \
				if retired_before_match else MatchmakingService.Outcome.MATCHED
			test._check(race_attempt.outcome == expected_outcome
				and race_attempt.match_id == "race-" + ordering
				and race_attempt.arrangement == "race-arrangement-" + ordering
				and race_attempt.native_terminal
				and not race_attempt.cancel_in_flight
				and not race_attempt.cleanup_pending
				and not race.has_pending_cleanup()
				and not race.has_orphaned_matched_cancel(),
				"A-MIG-04 [%s/retired=%s] normal lost race settles once without recovery" % [
					ordering, retired_before_match])
			test._check(terminal_cancel_states == [false]
				and (
					finished_cancel_states == [false]
					or (retired_before_match and finished_cancel_states == [true])
				),
				"A-MIG-04 [%s/retired=%s] terminal observers see reconciled cancel state" % [
					ordering, retired_before_match])
			test._check(race.fake_warnings.size() == 1
				and race.fake_warnings[0].contains("reason=cancel_lost_race")
				and race.fake_warnings[0].contains(
					"native_code=match_ticket_cancel_lost_race"),
				"A-MIG-04 [%s] contractual lost race is logged once=%s" % [
					ordering, race.fake_warnings])
			test._check(race_ticket.cancel_calls == 1
				and race_ticket.terminal_event_count == 1
				and race_ticket.native_destroyed,
				"A-MIG-01/05 [%s] one cancel start and one terminal publication" % \
					ordering)
			await _drain_clock(test, race_clock, "S4 normal lost race " + ordering)

	var aborted := Doubles.Matchmaking.new()
	var aborted_ticket := Doubles.Ticket.new()
	aborted_ticket.cancel_fault_result = Doubles.Results.make(
		false,
		aborted_ticket,
		"observer_completion_failed",
		"Injected observer completion.",
		-2147024809)
	aborted.sdk.queued_create_results.append(Doubles.Results.make(
		true, aborted_ticket))
	var aborted_attempt := aborted.begin_create(
		_spec(user, [user.entity_key], 83))
	await _frames(test, 2)
	aborted.request_cancel(aborted_attempt)
	aborted_ticket.match_id = "aborted-match"
	aborted_ticket.arranged_lobby_connection_string = "aborted-arrangement"
	aborted_ticket.publish_terminal(MatchmakingService.STATUS_MATCHED)
	await _frames(test, 2)
	test._check(aborted_attempt.outcome == MatchmakingService.Outcome.MATCHED
		and not aborted_attempt.cleanup_pending
		and aborted.fake_warnings.size() == 1
		and aborted.fake_warnings[0].contains(
			"reason=cancel_observer_aborted"),
		"other injected non-OK observers stay neutral and preserve Matched")

	var direct_ticket := Doubles.Ticket.new()
	var concurrent_results: Array = []
	_capture_ticket_cancel(direct_ticket, concurrent_results)
	_capture_ticket_cancel(direct_ticket, concurrent_results)
	await _frames(test, 1)
	test._check(direct_ticket.cancel_calls == 1
		and direct_ticket.cancel_waiting
		and concurrent_results.is_empty(),
		"A-MIG-05 Ticket double coalesces concurrent observers onto one native request")
	direct_ticket.publish_terminal(MatchmakingService.STATUS_CANCELLED)
	await _frames(test, 2)
	test._check(concurrent_results.size() == 2
		and bool((concurrent_results[0] as Dictionary).get("ok", false))
		and bool((concurrent_results[1] as Dictionary).get("ok", false)),
		"A-MIG-05 Ticket double gives both observers the same cancelled completion")
	var invalid_after_terminal: Dictionary = await direct_ticket.cancel_async()
	test._check(not bool(invalid_after_terminal.get("ok", false))
		and String(invalid_after_terminal.get("code", "")) == "invalid_match_ticket"
		and (int(invalid_after_terminal.get("hresult", 0)) & 0xFFFFFFFF)
			== (Doubles.Results.E_INVALIDARG & 0xFFFFFFFF),
		"A-MIG-05 Ticket double returns invalid_match_ticket/E_INVALIDARG after terminal")

	var invalid_race := Doubles.Matchmaking.new()
	var invalid_race_ticket := Doubles.Ticket.new()
	invalid_race_ticket.match_id = "invalid-race-match"
	invalid_race_ticket.arranged_lobby_connection_string = \
		"invalid-race-arrangement"
	invalid_race_ticket.cancel_terminal_before_start_status = \
		MatchmakingService.STATUS_MATCHED
	invalid_race.sdk.queued_create_results.append(
		Doubles.Results.make(true, invalid_race_ticket))
	var invalid_race_attempt := invalid_race.begin_create(
		_spec(user, [user.entity_key], 84))
	await _frames(test, 2)
	invalid_race.request_cancel(invalid_race_attempt)
	await _frames(test, 2)
	test._check(invalid_race_attempt.outcome == MatchmakingService.Outcome.MATCHED
		and invalid_race_attempt.match_id == "invalid-race-match"
		and invalid_race_attempt.arrangement == "invalid-race-arrangement"
		and invalid_race_ticket.cancel_calls == 0
		and not invalid_race_attempt.cleanup_pending
		and invalid_race.fake_warnings.is_empty(),
		"A-MIG-05 invalid-after-terminal reconciles the cached snapshot, not a cancel failure")


func _s4_failure_cause_availability(test: Node) -> void:
	print("CASE: failure cause availability follows pinned result provenance")
	for case_data: Dictionary in [
		{
			"label": "absent result",
			"result": null,
			"stage": &"create",
			"available": false,
		},
		{
			"label": "generic create wrapper",
			"result": Doubles.Results.make(
				false, null, "match_ticket_create_failed", "", -2147467259),
			"stage": &"create",
			"available": false,
		},
		{
			"label": "generic terminal wrapper",
			"result": Doubles.Results.match_ticket_completed_failed(
				null,
				-2147467259),
			"stage": &"terminal",
			"available": false,
		},
		{
			"label": "generic guest join wrapper",
			"result": Doubles.Results.make(
				false, null, "match_ticket_join_failed", "", -2147467259),
			"stage": &"join",
			"available": false,
		},
		{
			"label": "detailed guest join HRESULT",
			"result": Doubles.Results.make(
				false, null, "match_ticket_join_failed", "", -2147024809),
			"stage": &"join",
			"available": true,
		},
		{
			"label": "supported local validation",
			"result": Doubles.Results.make(
				false, null, "invalid_user", "", -2147024809),
			"stage": &"create",
			"available": true,
		},
	]:
		var case_result: Variant = case_data.get("result")
		var case_stage := StringName(case_data.get("stage", &""))
		var expected_available := bool(case_data.get("available", false))
		var outcome := MatchmakingService.failure_outcome(
			case_result,
			case_stage,
			false,
			1)
		test._check(
			bool(outcome.get("cause_available", false))
				== expected_available,
			"[%s] cause_available=%s expected=%s" % [
				case_data.label,
				outcome.get("cause_available", false),
				expected_available,
			])


func _s4_safe_structured_failure_logging(test: Node) -> void:
	print("CASE: matchmaking and Party failures log one safe structured record")
	var user := Doubles.User.new("logging-user")
	var secret := "SECRET_CONNECTION|entity=player-token"

	var create := Doubles.Matchmaking.new()
	create.sdk.queued_create_results.append(Doubles.Results.make(
		false,
		null,
		"match_ticket_create_failed",
		secret,
		-2147467259))
	create.begin_create(_spec(user, [user.entity_key], 90))
	await _frames(test, 2)
	_check_safe_warning(test, create.fake_warnings, [
		"stage=create",
		"native_code=match_ticket_create_failed",
		"hresult=0x80004005",
		"result_present=true",
		"detail=unavailable",
	], secret, "create")

	var joining := Doubles.Matchmaking.new()
	joining.sdk.queued_join_results.append(Doubles.Results.make(
		false,
		null,
		"match_ticket_join_failed",
		secret,
		-2147467259))
	var joining_attempt := joining.begin_join(_join_spec(
		user, [user.entity_key], 91, "logging-ticket"))
	await _frames(test, 2)
	test._check(joining_attempt.reason_code == &"ticket_join_failed",
		"generic guest join wrapper keeps the generic player classification")
	_check_safe_warning(test, joining.fake_warnings, [
		"stage=join",
		"native_code=match_ticket_join_failed",
		"hresult=0x80004005",
		"detail=unavailable",
	], secret, "join")

	var detailed_join := Doubles.Matchmaking.new()
	detailed_join.sdk.queued_join_results.append(Doubles.Results.make(
		false,
		null,
		"match_ticket_join_failed",
		secret,
		-2147024809))
	var detailed_join_attempt := detailed_join.begin_join(_join_spec(
		user, [user.entity_key], 911, "logging-detailed-ticket"))
	await _frames(test, 2)
	test._check(detailed_join_attempt.reason_code == &"ticket_join_failed",
		"detailed guest join failure keeps the same player classification")
	_check_safe_warning(test, detailed_join.fake_warnings, [
		"stage=join",
		"native_code=match_ticket_join_failed",
		"hresult=0x80070057",
		"detail=available",
	], secret, "join-detailed")

	var terminal := Doubles.Matchmaking.new()
	var terminal_ticket := Doubles.Ticket.new()
	terminal_ticket.properties = {"credential": secret}
	terminal.sdk.queued_create_results.append(
		Doubles.Results.make(true, terminal_ticket))
	var terminal_attempt := terminal.begin_create(
		_spec(user, [user.entity_key], 92))
	await _frames(test, 2)
	var terminal_result := Doubles.Results.make(
		false,
		terminal_ticket,
		"match_ticket_completed_failed",
		secret,
		-2147467259)
	terminal_ticket.emit_status(
		MatchmakingService.STATUS_FAILED,
		terminal_result)
	terminal._log_ticket_failure(
		terminal_attempt,
		&"terminal",
		&"matchmaking_failed",
		terminal_result,
		MatchmakingService.STATUS_FAILED)
	_check_safe_warning(test, terminal.fake_warnings, [
		"stage=terminal",
		"native_code=match_ticket_completed_failed",
		"hresult=0x80004005",
		"status=6",
		"detail=unavailable",
	], secret, "terminal")

	var timing := Doubles.Matchmaking.new()
	var timing_clock := Doubles.Clock.new()
	timing.configure_clock(timing_clock)
	var timing_ticket := Doubles.Ticket.new()
	timing.sdk.queued_create_results.append(Doubles.Results.make(
		true, timing_ticket))
	var timing_spec := _spec(user, [user.entity_key], 93)
	timing_spec.deadline_msec = 100
	timing.begin_create(timing_spec)
	await _frames(test, 2)
	timing_clock.advance(0.1)
	await _frames(test, 2)
	_check_safe_warning(test, timing.fake_warnings, [
		"stage=timeout",
		"reason=search_timeout",
		"hresult=0x00000000",
		"detail=unavailable",
	], secret, "timeout")
	timing_ticket.publish_terminal(MatchmakingService.STATUS_CANCELLED)
	await _frames(test, 2)
	await _assert_matchmaking_case_clean(
		test, timing, timing_clock, "S4 logging timeout")

	var cancel := Doubles.Matchmaking.new()
	var cancel_ticket := Doubles.Ticket.new()
	cancel.sdk.queued_create_results.append(Doubles.Results.make(
		true, cancel_ticket))
	var cancel_attempt := cancel.begin_create(
		_spec(user, [user.entity_key], 94))
	await _frames(test, 2)
	cancel.request_cancel(cancel_attempt)
	cancel_ticket.release_cancel(Doubles.Results.make(
		false,
		cancel_ticket,
		"match_ticket_cancel_start_failed",
		secret,
		-2147467259))
	await _frames(test, 2)
	_check_safe_warning(test, cancel.fake_warnings, [
		"stage=cancel",
		"reason=cancel_unconfirmed",
		"native_code=match_ticket_cancel_start_failed",
		"hresult=0x80004005",
		"detail=available",
	], secret, "cancel")
	cancel_ticket.emit_status(MatchmakingService.STATUS_CANCELLED)

	var party := Doubles.Party.new(ChatService.new())
	party.configure_clock(party.fake_clock)
	party.pf.multiplayer.next_arranged_result = Doubles.Results.make(
		false,
		null,
		"arranged_lobby_join_failed",
		secret,
		-2147467259)
	await party.join_arranged(
		Doubles.User.new("logging-party"),
		secret,
		{},
		4,
		1,
		95,
		party.fake_clock.now_msec() + 1000)
	_check_safe_warning(test, party.fake_warnings, [
		"stage=join_arranged",
		"native_code=arranged_lobby_join_failed",
		"hresult=0x80004005",
		"detail=available",
	], secret, "scoped")
	await _drain_clock(test, party.fake_clock, "S4 logging scoped")

	var numeric_party := Doubles.Party.new(ChatService.new())
	numeric_party.configure_clock(numeric_party.fake_clock)
	numeric_party.pf.multiplayer.next_arranged_result = Doubles.Results.make(
		false,
		{"party_error": 1234, "state_change_result": 5678},
		"unknown_sensitive_identifier",
		secret,
		-2147467259)
	await numeric_party.join_arranged(
		Doubles.User.new("logging-party-numeric"),
		secret,
		{},
		4,
		1,
		96,
		numeric_party.fake_clock.now_msec() + 1000)
	_check_safe_warning(test, numeric_party.fake_warnings, [
		"native_code=unavailable",
		"party_error=1234",
		"state_change_result=5678",
		"detail=available",
	], secret, "scoped-numeric")
	await _drain_clock(test, numeric_party.fake_clock, "S4 logging numeric")

	var unknown_party := Doubles.Party.new(ChatService.new())
	unknown_party.configure_clock(unknown_party.fake_clock)
	unknown_party.pf.multiplayer.next_arranged_result = Doubles.Results.make(
		false,
		null,
		"unknown_sensitive_identifier",
		secret,
		-2147467259)
	await unknown_party.join_arranged(
		Doubles.User.new("logging-party-unknown"),
		secret,
		{},
		4,
		1,
		97,
		unknown_party.fake_clock.now_msec() + 1000)
	_check_safe_warning(test, unknown_party.fake_warnings, [
		"native_code=unavailable",
		"party_error=unavailable",
		"state_change_result=unavailable",
		"detail=unavailable",
	], secret, "scoped-unknown")
	await _drain_clock(test, unknown_party.fake_clock, "S4 logging unknown")

	var matcher := Doubles.Matchmaking.new()
	for real_code: String in SOURCE_MATCHMAKING_NATIVE_CODES:
		test._check(matcher._safe_native_code(real_code) == real_code,
			"matchmaking native code survives allowlist: %s" % real_code)
	for production_code: String in MatchmakingService.SAFE_NATIVE_CODES:
		test._check(SOURCE_MATCHMAKING_NATIVE_CODES.has(production_code),
			"matchmaking allowlist code has a pinned-source anchor: %s" % \
				production_code)
	test._check(MatchmakingService.SAFE_NATIVE_CODES.size()
			== SOURCE_MATCHMAKING_NATIVE_CODES.size(),
		"matchmaking allowlist and pinned-source inventory have equal size")
	test._check(matcher._safe_native_code("credential_like_identifier")
			== "unavailable",
		"unknown matchmaking identifier is omitted")

	var party_codes := Doubles.Party.new(ChatService.new())
	for real_code: String in SOURCE_PARTY_NATIVE_CODES:
		var safe_result := Doubles.Results.make(
			false, null, real_code, "", -2147467259)
		test._check(party_codes._safe_result_code(safe_result) == real_code,
			"Party native code survives allowlist: %s" % real_code)
	for production_code: String in PartyService.SAFE_NATIVE_CODES:
		test._check(SOURCE_PARTY_NATIVE_CODES.has(production_code),
			"Party allowlist code has a pinned-source anchor: %s" % \
				production_code)
	test._check(PartyService.SAFE_NATIVE_CODES.size()
			== SOURCE_PARTY_NATIVE_CODES.size(),
		"Party allowlist and pinned-source inventory have equal size")
	test._check(party_codes._safe_result_code(Doubles.Results.make(
		false, null, "credential_like_identifier", "", -2147467259))
			== "unavailable",
		"unknown Party identifier is omitted")


func _s4_source_derived_native_code_paths(test: Node) -> void:
	print("CASE: source-derived native codes survive representative service stages")
	var user := Doubles.User.new("native-code-paths")
	var secret := "SECRET_NATIVE_CODE_PATH"

	var ticket := Doubles.Matchmaking.new()
	ticket.sdk.queued_create_results.append(Doubles.Results.make(
		false, null, "invalid_user", secret, -2147024809))
	ticket.begin_create(_spec(user, [user.entity_key], 912))
	await _frames(test, 2)
	_check_safe_warning(test, ticket.fake_warnings, [
		"stage=create",
		"native_code=invalid_user",
		"detail=available",
	], secret, "ticket-validation")

	var party_initialize := Doubles.Party.new(ChatService.new())
	party_initialize.pf.party.initialized = false
	party_initialize.pf.party.next_initialize_result = Doubles.Results.make(
		false, null, "party_already_initialized", secret, -2147467259)
	await party_initialize.host(user, 4, "deathmatch")
	_check_safe_warning(test, party_initialize.fake_warnings, [
		"stage=legacy_party_initialize",
		"native_code=party_already_initialized",
		"detail=available",
	], secret, "Party-initialize")

	for initialize_code: String in [
		"already_initialized",
		"multiplayer_queue_create_failed",
		"multiplayer_initialize_failed",
	]:
		var multiplayer_initialize := Doubles.Party.new(ChatService.new())
		multiplayer_initialize.pf.multiplayer.initialized = false
		multiplayer_initialize.pf.multiplayer.next_initialize_result = \
			Doubles.Results.make(
				false, null, initialize_code, secret, -2147467259)
		await multiplayer_initialize.host(user, 4, "deathmatch")
		_check_safe_warning(test, multiplayer_initialize.fake_warnings, [
			"stage=legacy_lobby_initialize",
			"native_code=" + initialize_code,
			"detail=available",
		], secret, "Multiplayer-initialize-" + initialize_code)

	var lobby_create := Doubles.Party.new(ChatService.new())
	lobby_create.pf.multiplayer.next_create_result = Doubles.Results.make(
		false, null, "invalid_properties", secret, -2147024809)
	await lobby_create.host(user, 4, "deathmatch")
	await _frames(test, 2)
	_check_safe_warning(test, lobby_create.fake_warnings, [
		"stage=legacy_lobby_create",
		"native_code=invalid_properties",
		"detail=available",
	], secret, "Lobby-create-validation")
	await lobby_create.leave()

	var lookup := Doubles.Party.new(ChatService.new())
	lookup.pf.multiplayer.next_find_result = Doubles.Results.make(
		false, null, "invalid_search", secret, -2147024809)
	await lookup.join(user, "ABCDE")
	_check_safe_warning(test, lookup.fake_warnings, [
		"stage=lobby_search",
		"native_code=invalid_search",
		"detail=available",
	], secret, "Lobby-search-validation")

	var lobby_join := Doubles.Party.new(ChatService.new())
	lobby_join.pf.multiplayer.next_join_result = Doubles.Results.make(
		false, null, "lobby_join_failed", secret, -1994169818)
	await lobby_join.join_by_connection_string(
		user, "native-code-connection")
	_check_safe_warning(test, lobby_join.fake_warnings, [
		"stage=lobby_join",
		"native_code=lobby_join_failed",
		"detail=available",
	], secret, "Lobby-join")

	for party_code: String in [
		"party_invalid_options",
		"party_peer_not_connected",
		"party_chat_control_create_failed",
	]:
		var network := Doubles.Party.new(ChatService.new())
		network.pf.party.next_create_result = Doubles.Results.make(
			false, null, party_code, secret, -2147024809)
		await network.host(user, 4, "deathmatch")
		_check_safe_warning(test, network.fake_warnings, [
			"stage=legacy_network_create",
			"native_code=" + party_code,
			"detail=available",
		], secret, "Party-network-" + party_code)


func _a_mig_party_handshake_rejections(test: Node) -> void:
	print("CASE: A-MIG-08 Party handshake rejections are logged once and nonterminal")
	for native_code: String in [
		"party_handshake_entity_mismatch",
		"party_handshake_endpoint_entity_unavailable",
	]:
		var secret := "SECRET_HANDSHAKE_" + native_code
		var hosted := Doubles.Party.new(ChatService.new())
		hosted.configure_clock(hosted.fake_clock)
		var hosted_result: Dictionary = await hosted.host(
			Doubles.User.new("handshake-host-" + native_code),
			4,
			"deathmatch")
		var hosted_failures: Array[bool] = []
		hosted.party_failed.connect(
			func(_reason: String, _context: Variant) -> void:
				hosted_failures.append(true))
		var hosted_change := Doubles.Change.new()
		hosted_change.kind = PartyService.NETWORK_CHANGE_ERROR
		hosted_change.peer_id = 0
		hosted_change.network = hosted._network
		hosted_change.result = Doubles.Results.make(
			false,
			null,
			native_code,
			secret,
			-2147467259)
		hosted._network.state_changed.emit(hosted_change)
		test._check(bool(hosted_result.get("ok", false))
			and hosted.has_network()
			and hosted_failures == [true],
			"[%s/hosted] rejection reports a recoverable failure without ending the session" % \
				native_code)
		_check_safe_warning(test, hosted.fake_warnings, [
			"stage=legacy_network_state",
			"native_code=" + native_code,
		], secret, "handshake-hosted-" + native_code)
		await hosted.leave()

		var scoped := Doubles.Party.new(ChatService.new())
		scoped.configure_clock(scoped.fake_clock)
		var scoped_result: PartyService.PartyResult = await scoped.create_staging(
			Doubles.User.new("handshake-group-" + native_code),
			4,
			"deathmatch",
			1,
			98,
			scoped.fake_clock.now_msec() + 1000)
		var scoped_failures: Array[int] = []
		var scoped_losses: Array[bool] = []
		scoped.party_failed.connect(
			func(_reason: String, context: Variant) -> void:
				scoped_failures.append(
					int(context.context_id) if context != null else 0))
		scoped.context_lost.connect(
			func(_reason: String, _context: Variant) -> void:
				scoped_losses.append(true))
		var scoped_change := Doubles.Change.new()
		scoped_change.kind = PartyService.NETWORK_CHANGE_ERROR
		scoped_change.peer_id = 0
		scoped_change.network = scoped_result.context.network
		scoped_change.result = Doubles.Results.make(
			false,
			null,
			native_code,
			secret,
			-2147467259)
		(scoped_result.context.network as Doubles.Network).state_changed.emit(
			scoped_change)
		test._check(scoped_result.ok()
			and scoped.has_network()
			and scoped_failures == [scoped_result.context.context_id]
			and scoped_losses.is_empty(),
			"[%s/scoped] rejection leaves the matchmaking group and context live" % \
				native_code)
		_check_safe_warning(test, scoped.fake_warnings, [
			"stage=scoped_network_state",
			"native_code=" + native_code,
		], secret, "handshake-scoped-" + native_code)
		await scoped.leave()


func _check_safe_warning(
	test: Node,
	warnings: Array[String],
	required: Array[String],
	forbidden: String,
	label: String
) -> void:
	test._check(warnings.size() == 1,
		"[%s] warning count=%d records=%s" % [
			label, warnings.size(), warnings])
	var warning := warnings[0] if warnings.size() == 1 else ""
	for expected: String in required:
		test._check(warning.contains(expected),
			"[%s] warning includes %s: %s" % [label, expected, warning])
	test._check(not warning.contains(forbidden),
		"[%s] warning redacts seeded credential text" % label)


func _s4_observe_terminal_before_cancel(test: Node) -> void:
	print("CASE: returned terminal ticket snapshots are observed before cancellation")
	var user := Doubles.User.new("observe-terminal")

	var owner_service := Doubles.Matchmaking.new()
	owner_service.sdk.block_create = true
	var owner_ticket := Doubles.Ticket.new()
	owner_ticket.match_id = "owner-match"
	owner_ticket.arranged_lobby_connection_string = "owner-arrangement"
	owner_ticket.prime_terminal_snapshot(MatchmakingService.STATUS_MATCHED)
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
	guest_ticket.match_id = "guest-match"
	guest_ticket.arranged_lobby_connection_string = "guest-arrangement"
	guest_ticket.prime_terminal_snapshot(MatchmakingService.STATUS_MATCHED)
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
		terminal_ticket.prime_terminal_snapshot(terminal_status)
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
	stale_ticket.match_id = "stale-match"
	stale_ticket.arranged_lobby_connection_string = "stale-arrangement"
	stale_ticket.prime_terminal_snapshot(MatchmakingService.STATUS_MATCHED)
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
		losses.append(context == null))
	var destroyed := Doubles.Change.new()
	destroyed.kind = PartyService.NETWORK_CHANGE_DESTROYED
	destroyed.reason = "Injected hosted loss."
	destroyed.network = hosted_network
	hosted_network.state_changed.emit(destroyed)
	test._check(losses == [true], "legacy hosted loss reports a null scoped context")
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
		"cleanup-time replacement is refused once, results=%s" % [replacement_results])
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
		"old context stays retired; registry keys=%s" % [service._contexts.keys()])

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


func _s5_recovery_settles_scoped_leave_waiters(test: Node) -> void:
	print("CASE: confirmed recovery settles first and coalesced scoped-leave callers")
	var service := Doubles.Party.new(ChatService.new())
	service.configure_clock(service.fake_clock)
	var user := Doubles.User.new("leave-recovery")
	var arranged: PartyService.PartyResult = await service.join_arranged(
		user, "leave-recovery-arranged", {}, 4, 1, 78, 1000)
	var prepared: PartyService.PartyResult = await service.prepare_transport(
		arranged.context, user, 1000)
	var lobby: Doubles.Lobby = arranged.context.lobby
	var network: Doubles.Network = arranged.context.network
	lobby.block_leave = true
	network.block_leave = true
	var lobby_first: Array = []
	var lobby_second: Array = []
	var transport_first: Array = []
	var transport_second: Array = []
	var global_results: Array = []
	_capture_scoped_lobby_leave(service, arranged.context, lobby_first)
	_capture_scoped_transport_leave(service, arranged.context, transport_first)
	await _frames(test, 1)
	_capture_scoped_lobby_leave(service, arranged.context, lobby_second)
	_capture_scoped_transport_leave(service, arranged.context, transport_second)
	test._check(service.is_cleanup_pending()
		and service.cleanup_readiness().state == PartyService.CLEANUP_CLEAR,
		"ordinary scoped leaves use their existing wait path, not cleanup recovery")
	_capture_global_leave(service, global_results)
	await _frames(test, 2)
	test._check(lobby.leaves == 1 and network.leaves == 1,
		"first/coalesced callers dispatch one Lobby=%d transport=%d leave" % [
			lobby.leaves, network.leaves])
	test._check(lobby_first.is_empty() and lobby_second.is_empty()
		and transport_first.is_empty() and transport_second.is_empty()
		and global_results.is_empty(),
		"all public waiters remain pending before recovery")
	service.fake_clock.advance(NRConst.MATCH_CLEANUP_SECONDS)
	await _frames(test, 6)
	test._check(global_results.size() == 1,
		"global recovery completes without raw leave signals results=%d" % \
			global_results.size())
	for entry: Dictionary in [
		{"label": "lobby first", "results": lobby_first},
		{"label": "lobby coalesced", "results": lobby_second},
		{"label": "transport first", "results": transport_first},
		{"label": "transport coalesced", "results": transport_second},
	]:
		var results: Array = entry.results
		var result: PartyService.PartyResult = results[0] \
			if results.size() == 1 else null
		test._check(results.size() == 1,
			"%s recovery results=%d" % [entry.label, results.size()])
		test._check(result != null and result.ok(),
			"%s recovery outcome=%s" % [
				entry.label,
				result.outcome if result != null else "missing",
			])
	test._check(service.context_is_quiescent(arranged.context)
		and not service.has_owned_work(),
		"confirmed recovery retires the captured context and lease")
	lobby.block_leave = false
	network.block_leave = false
	lobby.leave_released.emit()
	network.leave_released.emit()
	await _frames(test, 3)
	test._check(lobby_first.size() == 1 and lobby_second.size() == 1
		and transport_first.size() == 1 and transport_second.size() == 1,
		"late raw signals cannot re-settle public callers")
	test._check(lobby.leaves == 1 and network.leaves == 1,
		"late raw signals issue no extra leave calls")
	await _drain_clock(test, service.fake_clock, "S5 recovered leave waiters")

	var descriptor_service := Doubles.Party.new(ChatService.new())
	descriptor_service.configure_clock(descriptor_service.fake_clock)
	var descriptor_arranged: PartyService.PartyResult = await descriptor_service.join_arranged(
			Doubles.User.new("leave-recovery-descriptor"),
			"leave-recovery-descriptor-arranged",
			{},
			4,
			1,
			781,
			1000)
	var descriptor_lobby: Doubles.Lobby = descriptor_arranged.context.lobby
	descriptor_lobby.properties[PartyService.DESCRIPTOR_KEY] = "held-descriptor"
	descriptor_lobby.block_properties = true
	var descriptor_results: Array = []
	var descriptor_global: Array = []
	_capture_scoped_lobby_leave(
		descriptor_service,
		descriptor_arranged.context,
		descriptor_results)
	_capture_global_leave(descriptor_service, descriptor_global)
	descriptor_service.fake_clock.advance(NRConst.MATCH_CLEANUP_SECONDS)
	await _frames(test, 6)
	test._check(descriptor_results.size() == 1
		and (descriptor_results[0] as PartyService.PartyResult).ok()
		and not (descriptor_results[0] as PartyService.PartyResult).cleanup_pending
		and descriptor_service.context_is_quiescent(descriptor_arranged.context),
		"recovery settles a first caller blocked in descriptor clearing")
	test._check(descriptor_lobby.leaves == 0,
		"blocked descriptor continuation has not dispatched native leave")
	descriptor_lobby.block_properties = false
	descriptor_lobby.properties_released.emit()
	await _frames(test, 3)
	test._check(descriptor_lobby.leaves == 0,
		"late descriptor clear cannot start old-lobby leave after recovery")
	test._check(descriptor_global.size() == 1,
		"descriptor-blocked global recovery completes")
	await _drain_clock(
		test, descriptor_service.fake_clock, "S5 descriptor recovery")

	var failed := Doubles.Party.new(ChatService.new())
	failed.configure_clock(failed.fake_clock)
	var failed_arranged: PartyService.PartyResult = await failed.join_arranged(
		Doubles.User.new("leave-recovery-failed"),
		"leave-recovery-failed-arranged",
		{},
		4,
		1,
		79,
		1000)
	var failed_lobby: Doubles.Lobby = failed_arranged.context.lobby
	failed_lobby.block_leave = true
	failed.pf.multiplayer.next_shutdown_result = Doubles.Results.make(
		false, null, "shutdown_failed", "Injected shutdown failure.")
	var failed_first: Array = []
	var failed_second: Array = []
	var failed_global: Array = []
	_capture_scoped_lobby_leave(failed, failed_arranged.context, failed_first)
	await _frames(test, 1)
	_capture_scoped_lobby_leave(failed, failed_arranged.context, failed_second)
	_capture_global_leave(failed, failed_global)
	failed.fake_clock.advance(NRConst.MATCH_CLEANUP_SECONDS)
	await _frames(test, 6)
	test._check(failed_first.size() == 1 and failed_second.size() == 1,
		"failed recovery settles both public Lobby waiters")
	var failed_result: PartyService.PartyResult = failed_first[0] \
		if failed_first.size() == 1 else null
	test._check(failed_result != null and not failed_result.ok()
		and failed_result.reason_code == &"multiplayer_recovery_failed"
		and failed_result.cleanup_pending
		and failed_arranged.context.cleanup_pending
		and not failed.context_is_quiescent(failed_arranged.context)
		and failed.has_owned_work(),
		"failed recovery cannot masquerade as successful release")
	test._check(failed.recovery_error == PartyService.RECOVERY_FAILED,
		"failed recovery keeps restart-required fence")
	failed_lobby.block_leave = false
	failed_lobby.leave_released.emit()
	await _frames(test, 3)
	test._check(failed_first.size() == 1 and failed_second.size() == 1,
		"late failed-recovery native signal cannot re-settle callers")
	await _drain_clock(test, failed.fake_clock, "S5 failed leave recovery")


func _s5_native_leave_failure_cleanup_debt(test: Node) -> void:
	print("CASE: failed native scoped leaves start prompt recovery without losing debt")
	for resource: String in ["lobby", "transport"]:
		for recovery: String in ["success", "failure"]:
			await _native_leave_failure_cleanup_debt_case(
				test, resource, recovery)


func _native_leave_failure_cleanup_debt_case(
	test: Node,
	resource: String,
	recovery: String
) -> void:
	var service := Doubles.Party.new(ChatService.new())
	service.configure_clock(service.fake_clock)
	var user := Doubles.User.new("leave-debt-" + resource + "-" + recovery)
	var arranged: PartyService.PartyResult = await service.join_arranged(
		user,
		"leave-debt-arranged-" + resource + "-" + recovery,
		{},
		4,
		1,
		790,
		service.fake_clock.now_msec() + 1000)
	var prepared: PartyService.PartyResult = await service.prepare_transport(
		arranged.context,
		user,
		service.fake_clock.now_msec() + 1000)
	test._check(arranged.ok() and prepared.ok(),
		"[%s/%s] leave-debt fixture creates both scoped resources" % [
			resource, recovery])
	if not arranged.ok() or not prepared.ok():
		await service.leave()
		return

	var context: PartyService.LobbyContext = arranged.context
	var lobby: Doubles.Lobby = context.lobby
	var network: Doubles.Network = context.network
	var cleanup_events: Array[bool] = []
	service.cleanup_state_changed.connect(func() -> void:
		cleanup_events.append(true))
	var native_failure := Doubles.Results.make(
		false,
		null,
		"lobby_leave_start_failed" if resource == "lobby" \
			else "party_resource_not_ready",
		"Injected native leave failure.",
		-2147467259)
	var failed_result: PartyService.PartyResult = null
	if resource == "lobby":
		lobby.next_leave_result = native_failure
		failed_result = await service.leave_lobby(context)
	else:
		network.next_leave_result = native_failure
		failed_result = await service.leave_transport(context)
	test._check(failed_result != null
		and failed_result.outcome == PartyService.PartyResult.Outcome.SERVICE_ERROR
		and failed_result.cleanup_pending
		and context.cleanup_pending
		and service.has_owned_work()
		and service.is_cleanup_pending()
		and not service.is_cleanup_running()
		and service.has_idle_cleanup_debt()
		and not service.context_is_quiescent(context)
		and service._contexts.get(context.context_id) == context
		and (
			(context.lobby == null and resource == "lobby")
			or (context.network == null and resource == "transport")
		),
		"[%s/%s] failed native leave returns SERVICE_ERROR with retained debt" % [
			resource, recovery])
	var pending_readiness := service.cleanup_readiness()
	test._check(pending_readiness.state == PartyService.CLEANUP_PENDING
		and not String(pending_readiness.reason).is_empty()
		and cleanup_events.size() >= 2,
		"[%s/%s] Party readiness reports pending before caller completion" % [
			resource, recovery])

	var repeated: PartyService.PartyResult
	var sibling: PartyService.PartyResult
	if resource == "lobby":
		repeated = await service.leave_lobby(context)
		sibling = await service.leave_transport(context)
	else:
		repeated = await service.leave_transport(context)
		sibling = await service.leave_lobby(context)
	test._check(repeated != null
		and repeated.outcome == PartyService.PartyResult.Outcome.SERVICE_ERROR
		and repeated.cleanup_pending
		and sibling != null and sibling.ok() and sibling.cleanup_pending
		and context.cleanup_pending
		and not service.context_is_quiescent(context),
		"[%s/%s] repeat and sibling leave cannot erase the failed resource debt" % [
			resource, recovery])
	test._check((lobby.leaves if resource == "lobby" else network.leaves) == 1,
		"[%s/%s] failed native resource is left exactly once" % [
			resource, recovery])
	var idle_drain: Array = []
	_capture_party_drain(
		service,
		service.fake_clock.now_msec() + 1000,
		idle_drain)
	await _frames(test, 1)
	test._check(idle_drain == [true],
		"[%s/%s] drain does not spend its budget on inert failed-leave debt" % [
			resource, recovery])

	if recovery == "failure":
		service.pf.multiplayer.next_shutdown_result = Doubles.Results.make(
			false,
			null,
			"multiplayer_cleanup_failed",
			"Injected recovery failure.")
	var events_before_recovery := cleanup_events.size()
	var recovery_start_msec := service.fake_clock.now_msec()
	var global_results: Array = []
	_capture_global_leave(service, global_results)
	await _frames(test, 6)
	test._check(global_results.size() == 1
		and service.pf.party.shutdown_calls == 1
		and service.pf.multiplayer.shutdown_calls == 1
		and cleanup_events.size() > events_before_recovery
		and service.fake_clock.now_msec() == recovery_start_msec,
		"[%s/%s] debt-only leave reaches existing recovery without grace delay" % [
			resource, recovery])
	var final_readiness := service.cleanup_readiness()
	if recovery == "success":
		test._check(final_readiness.state == PartyService.CLEANUP_CLEAR
			and String(final_readiness.reason).is_empty()
			and service.context_is_quiescent(context)
			and not service.has_owned_work()
			and not service.is_cleanup_pending(),
			"[%s/success] confirmed recovery alone clears the cleanup debt" % \
				resource)
	else:
		test._check(final_readiness.state
				== PartyService.CLEANUP_RESTART_REQUIRED
			and String(final_readiness.reason) == PartyService.RECOVERY_FAILED
			and context.cleanup_pending
			and not service.context_is_quiescent(context)
			and service.has_owned_work()
			and service.is_cleanup_pending()
			and not service.is_cleanup_running()
			and not service.has_idle_cleanup_debt()
			and service._contexts.get(context.context_id) == context,
			"[%s/failure] failed recovery keeps the restart-required debt" % \
				resource)
		var terminal_drain: Array = []
		var terminal_drain_msec := service.fake_clock.now_msec()
		_capture_party_drain(
			service,
			terminal_drain_msec + 1000,
			terminal_drain)
		await _frames(test, 1)
		test._check(terminal_drain == [true]
			and service.fake_clock.now_msec() == terminal_drain_msec,
			"[%s/failure] drain does not wait on terminal tracked debt" % resource)
	test._check(failed_result.outcome
			== PartyService.PartyResult.Outcome.SERVICE_ERROR,
		"[%s/%s] later recovery never rewrites the caller's failed outcome" % [
			resource, recovery])


func _s5_cleanup_execution_and_idle_debt_facts(test: Node) -> void:
	print("CASE: cleanup execution, idle debt, and terminal failure are distinct")
	var clean := Doubles.Party.new(ChatService.new())
	test._check(not clean.is_cleanup_running()
		and not clean.has_idle_cleanup_debt(),
		"an idle clean service reports neither running cleanup nor debt")

	var healthy := Doubles.Party.new(ChatService.new())
	healthy.configure_clock(healthy.fake_clock)
	var user := Doubles.User.new("cleanup-facts")
	var arranged: PartyService.PartyResult = await healthy.join_arranged(
		user,
		"cleanup-facts-arranged",
		{},
		4,
		1,
		795,
		healthy.fake_clock.now_msec() + 1000)
	var prepared: PartyService.PartyResult = await healthy.prepare_transport(
		arranged.context,
		user,
		healthy.fake_clock.now_msec() + 1000)
	test._check(arranged.ok() and prepared.ok()
		and healthy.has_owned_work()
		and not healthy.is_cleanup_running()
		and not healthy.has_idle_cleanup_debt(),
		"healthy retained Lobby and transport are owned but are not failed cleanup")

	var healthy_lobby: Doubles.Lobby = arranged.context.lobby
	healthy_lobby.block_leave = true
	var healthy_leave: Array = []
	var healthy_drain: Array = []
	_capture_global_leave(healthy, healthy_leave)
	_capture_party_drain(
		healthy,
		healthy.fake_clock.now_msec() + 1000,
		healthy_drain)
	await _frames(test, 2)
	test._check(healthy.is_cleanup_running()
		and not healthy.has_idle_cleanup_debt()
		and healthy_leave.is_empty()
		and healthy_drain.is_empty()
		and healthy.pf.party.shutdown_calls == 0
		and healthy.pf.multiplayer.shutdown_calls == 0,
		"genuine native leave execution remains waited on without becoming idle debt")
	healthy_lobby.block_leave = false
	healthy_lobby.leave_released.emit()
	healthy.fake_clock.advance(PartyService.POLL_INTERVAL)
	await _frames(test, 4)
	test._check(healthy_leave == [true] and healthy_drain == [true]
		and not healthy.is_cleanup_running()
		and not healthy.has_idle_cleanup_debt()
		and healthy.pf.party.shutdown_calls == 0
		and healthy.pf.multiplayer.shutdown_calls == 0,
		"a genuine native answer completes leave and drain without recovery")

	var establishing := Doubles.Party.new(ChatService.new())
	establishing.configure_clock(establishing.fake_clock)
	establishing.pf.party.block_create = true
	var establishing_results: Array = []
	_capture_create_staging(
		establishing,
		Doubles.User.new("cleanup-establishing"),
		establishing_results)
	await _frames(test, 1)
	test._check(establishing.has_owned_work()
		and not establishing.is_cleanup_running()
		and not establishing.has_idle_cleanup_debt(),
		"ordinary in-flight establishment is owned work, not idle failed cleanup")
	establishing.cancel_pending_join()
	establishing.pf.party.block_create = false
	establishing.pf.party.create_released.emit()
	await _frames(test, 4)
	await establishing.leave()

	var required := Doubles.Party.new(ChatService.new())
	required.configure_clock(required.fake_clock)
	var required_events: Array[bool] = []
	required.cleanup_state_changed.connect(func() -> void:
		required_events.append(true))
	required.require_recovery(&"late_failed_leave")
	test._check(not required.is_cleanup_running()
		and required.has_idle_cleanup_debt()
		and required.cleanup_readiness().state == PartyService.CLEANUP_PENDING
		and not required_events.is_empty(),
		"a required recovery is recoverable idle debt and not running execution")
	await required.leave()
	test._check(not required.is_cleanup_running()
		and not required.has_idle_cleanup_debt()
		and required.cleanup_readiness().state == PartyService.CLEANUP_CLEAR,
		"confirmed recovery clears the required idle debt")


func _s5_late_result_leave_failure_idle_debt(test: Node) -> void:
	print("CASE: late stale leave failures publish idle cleanup debt synchronously")
	for resource: String in ["lobby", "transport"]:
		var service := Doubles.Party.new(ChatService.new())
		service.configure_clock(service.fake_clock)
		var failure := Doubles.Results.make(
			false,
			null,
			"lobby_leave_start_failed" if resource == "lobby" \
				else "party_resource_not_ready",
			"Injected late-result leave failure.",
			-2147467259)
		if resource == "lobby":
			service.pf.multiplayer.block_create = true
			service.pf.multiplayer.next_created_lobby_leave_result = failure
		else:
			service.pf.party.block_create = true
			service.pf.party.next_created_network_leave_result = failure
		var creation_results: Array = []
		_capture_create_staging(
			service,
			Doubles.User.new("late-debt-" + resource),
			creation_results)
		await _frames(test, 1)
		test._check(service.has_owned_work()
			and not service.is_cleanup_running()
			and not service.has_idle_cleanup_debt(),
			"[%s] held SDK creation is ordinary native work before retirement" % \
				resource)

		var initial_leave: Array = []
		_capture_global_leave(service, initial_leave)
		await _frames(test, 1)
		service.fake_clock.advance(NRConst.MATCH_CLEANUP_SECONDS)
		await _frames(test, 6)
		test._check(initial_leave == [true]
			and creation_results.size() == 1
			and not service.is_cleanup_running()
			and not service.has_idle_cleanup_debt(),
			"[%s] old flow cleanup finishes before the late SDK result" % resource)

		var debt_events: Array[bool] = []
		service.cleanup_state_changed.connect(func() -> void:
			debt_events.append(true))
		var events_before_release := debt_events.size()
		if resource == "lobby":
			service.pf.multiplayer.block_create = false
			service.pf.multiplayer.create_released.emit()
		else:
			service.pf.party.block_create = false
			service.pf.party.create_released.emit()
		test._check(debt_events.size() > events_before_release
			and not service.is_cleanup_running()
			and service.has_idle_cleanup_debt()
			and service.cleanup_readiness().state == PartyService.CLEANUP_PENDING
			and service.has_owned_work(),
			"[%s] late leave failure synchronously publishes registered idle debt" % \
				resource)
		await _frames(test, 3)
		var stale_context: PartyService.LobbyContext = \
			(creation_results[0] as PartyService.PartyResult).context
		test._check(stale_context != null
			and not service.context_is_quiescent(stale_context),
			"[%s] old-epoch context remains non-quiescent while debt is idle" % \
				resource)
		await service.leave()
		test._check(not service.is_cleanup_running()
			and not service.has_idle_cleanup_debt()
			and not service.has_owned_work(),
			"[%s] the existing recovery boundary clears late-result debt" % resource)


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
	print("CASE: B-HOST-IDENTITY/B-PRESENT/B-LATE admission uses current member facts")
	var service := Doubles.Party.new(ChatService.new())
	service.configure_clock(service.fake_clock)
	var user := Doubles.User.new("proof-local")
	var staging: PartyService.PartyResult = await service.create_staging(
		user, 4, "deathmatch", 1, 301, service.fake_clock.now_msec() + 1000)
	test._check(staging.ok(), "admission fixture creates staging context")
	if not staging.ok():
		return
	var context: PartyService.LobbyContext = staging.context
	var creator_proof := service.admission_proof(context, 1)
	test._check(not bool(creator_proof.valid)
		and not bool(creator_proof.pending)
		and String(creator_proof.reason_code) == "party_identity_missing",
		"B-HOST-IDENTITY creator admission lookup is empty until the case supplies it")
	(context.peer as Doubles.Peer).keys[1] = user.entity_key.duplicate()
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
	var disconnected_snapshot := service.snapshot(context)
	var disconnected_proof := service.admission_proof(context, 2)
	test._check(not bool(disconnected_proof.valid)
		and not bool(disconnected_proof.pending)
		and String(disconnected_proof.reason_code) == "native_member_disconnected",
		"a disconnected native member is refused, not treated as pending")
	test._check((disconnected_snapshot.members as Array).size() == 2
		and not bool((disconnected_snapshot.members as Array)[1].connected),
		"B-PRESENT snapshot retains disconnected present members")
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
		and bool(outsider_proof.pending)
		and String(outsider_proof.reason_code) == "native_member_pending",
		"B-PRESENT unlocked bootstrap keeps unreplicated native membership pending")
	(context.lobby as Doubles.Lobby).membership_lock = \
		PartyService.MEMBERSHIP_LOCK_LOCKED
	var locked_outsider := service.admission_proof(context, 9)
	test._check(not bool(locked_outsider.valid)
		and not bool(locked_outsider.pending)
		and String(locked_outsider.reason_code) == "native_member_missing",
		"a wrong authenticated key is invalid once the native cohort is complete")

	var losses: Array = []
	service.context_lost.connect(func(reason: String, lost_context: Variant) -> void:
		losses.append({
			"reason": reason,
			"context_id": int(lost_context.context_id) if lost_context != null else 0,
		}))
	var owner_change := Doubles.Change.new()
	owner_change.kind = PartyService.LOBBY_CHANGE_OWNER_CHANGED
	(context.lobby as Doubles.Lobby).owner_entity_key = {
		"id": "replacement-owner",
		"type": "title_player_account",
	}
	(context.lobby as Doubles.Lobby).state_changed.emit(owner_change)
	test._check(losses.size() == 1
		and int(losses[0].context_id) == context.context_id,
		"native owner change emits one scoped terminal loss count=%d" % losses.size())
	test._check(String(losses[0].reason)
			== "The group host changed, so the group was closed.",
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
		peerless_losses.append({
			"reason": reason,
			"context_id": int(lost_context.context_id) if lost_context != null else 0,
		}))
	var disconnected := Doubles.Change.new()
	disconnected.kind = PartyService.LOBBY_CHANGE_DISCONNECTED
	disconnected.result = Doubles.Results.make(
		false, null, "dropped", "Injected native diagnostic.")
	(arranged.context.lobby as Doubles.Lobby).state_changed.emit(disconnected)
	test._check(peerless_losses.size() == 1
		and int(peerless_losses[0].context_id) == arranged.context.context_id
		and String(peerless_losses[0].reason)
			== "The matchmaking lobby connection was lost.",
		"peerless scoped Lobby loss is terminal with a title reason")
	await peerless.leave()

	var arranged_loss := Doubles.Party.new(ChatService.new())
	arranged_loss.configure_clock(arranged_loss.fake_clock)
	var arranged_owner_loss: PartyService.PartyResult = await arranged_loss.join_arranged(
		Doubles.User.new("arranged-owner-loss"),
		"arranged-owner-loss",
		{},
		4,
		1,
		305,
		arranged_loss.fake_clock.now_msec() + 1000)
	var arranged_losses: Array[String] = []
	arranged_loss.context_lost.connect(func(reason: String, _context: Variant) -> void:
		arranged_losses.append(reason))
	var arranged_lobby: Doubles.Lobby = arranged_owner_loss.context.lobby
	arranged_lobby.owner_entity_key = {}
	var arranged_cleared := Doubles.Change.new()
	arranged_cleared.kind = PartyService.LOBBY_CHANGE_OWNER_CHANGED
	arranged_lobby.state_changed.emit(arranged_cleared)
	test._check(arranged_losses.size() == 1,
		"arranged owner clear loss count=%d" % arranged_losses.size())
	test._check(arranged_losses[0]
			== "The match host left or is no longer available, so the match was closed.",
		"arranged owner clear reason=%s" % (
			arranged_losses[0] if arranged_losses.size() == 1 else "missing"))
	test._check(not String(arranged_losses[0] if arranged_losses.size() == 1 else "")
			.contains("PlayFab"),
		"arranged host-loss text contains no service-object jargon")
	await arranged_loss.leave()
	await _drain_clock(test, arranged_loss.fake_clock, "S6 arranged owner loss")

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
	print("CASE: B-START/B-START-MALFORMED/B-REMATCH-PENDING arranged control boundaries")
	var valid_control := PartyService.encode_arranged_control(
		"control-match", 0, PartyService.ARRANGED_PHASE_BOOTSTRAP)
	var decoded := PartyService.decode_arranged_control(valid_control)
	test._check(bool(decoded.valid)
		and String(decoded.match_id) == "control-match"
		and int(decoded.round) == 0
		and String(decoded.phase) == PartyService.ARRANGED_PHASE_BOOTSTRAP
		and int(decoded.start_generation) == 0
		and int(decoded.selected_count) == 0,
		"arranged control round zero round-trips=%s" % decoded)
	var selected_fixture: Array[Dictionary] = [
		{"id": "selected-c", "type": "title_player_account"},
		{"id": "selected-a", "type": "title_player_account"},
		{"id": "selected-b", "type": "title_player_account"},
		{"id": "selected-d", "type": "title_player_account"},
		{"id": "selected-e", "type": "title_player_account"},
	]
	for selected_count: int in [2, 3, 4]:
		var selected: Array[Dictionary] = []
		selected.assign(selected_fixture.slice(0, selected_count))
		var encoded := PartyService.encode_arranged_control(
			"control-match",
			0,
			PartyService.ARRANGED_PHASE_STARTING,
			1,
			selected)
		var reversed: Array[Dictionary] = selected.duplicate(true)
		reversed.reverse()
		var equivalent := PartyService.encode_arranged_control(
			"control-match",
			0,
			PartyService.ARRANGED_PHASE_STARTING,
			1,
			reversed)
		var selected_control := PartyService.decode_arranged_control(encoded)
		test._check(bool(selected_control.valid)
			and int(selected_control.start_generation) == 1
			and int(selected_control.selected_count) == selected_count
			and encoded == equivalent,
			"selected set %d canonical control=%s" % [
				selected_count, selected_control])
	for malformed: Dictionary in [
		{},
		{
			PartyService.MATCH_ID_MEMBER_KEY: "control-match",
			PartyService.ROUND_GENERATION_KEY: "01",
			PartyService.SESSION_PHASE_KEY: PartyService.ARRANGED_PHASE_BOOTSTRAP,
			PartyService.START_GENERATION_KEY: "0",
			PartyService.START_MEMBERS_KEY: "[]",
		},
		{
			PartyService.MATCH_ID_MEMBER_KEY: "control-match",
			PartyService.ROUND_GENERATION_KEY: "0",
			PartyService.SESSION_PHASE_KEY: "unknown",
			PartyService.START_GENERATION_KEY: "0",
			PartyService.START_MEMBERS_KEY: "[]",
		},
		PartyService.encode_arranged_control(
			"control-match",
			0,
			PartyService.ARRANGED_PHASE_STARTING,
			0,
			selected_fixture.slice(0, 2)),
		PartyService.encode_arranged_control(
			"control-match",
			0,
			PartyService.ARRANGED_PHASE_STARTING,
			1,
			[selected_fixture[0]]),
		PartyService.encode_arranged_control(
			"control-match",
			0,
			PartyService.ARRANGED_PHASE_STARTING,
			1,
			[selected_fixture[0], selected_fixture[0]]),
		PartyService.encode_arranged_control(
			"control-match",
			0,
			PartyService.ARRANGED_PHASE_STARTING,
			1,
			selected_fixture),
		PartyService.encode_arranged_control(
			"control-match",
			0,
			PartyService.ARRANGED_PHASE_GAMEPLAY,
			0,
			[]),
		PartyService.encode_arranged_control(
			"control-match",
			1,
			PartyService.ARRANGED_PHASE_REMATCH,
			1,
			[]),
		{
			PartyService.MATCH_ID_MEMBER_KEY: "control-match",
			PartyService.ROUND_GENERATION_KEY: "0",
			PartyService.SESSION_PHASE_KEY: PartyService.ARRANGED_PHASE_STARTING,
			PartyService.START_GENERATION_KEY: "01",
			PartyService.START_MEMBERS_KEY: JSON.stringify(
				selected_fixture.slice(0, 2)),
		},
	]:
		test._check(malformed.is_empty()
			or not bool(PartyService.decode_arranged_control(malformed).valid),
			"malformed arranged control is rejected=%s" % malformed)
	var raw_start_control := {
		PartyService.MATCH_ID_MEMBER_KEY: "control-match",
		PartyService.ROUND_GENERATION_KEY: "0",
		PartyService.SESSION_PHASE_KEY: PartyService.ARRANGED_PHASE_STARTING,
		PartyService.START_GENERATION_KEY: "1",
		PartyService.START_MEMBERS_KEY: "[]",
	}
	var malformed_selected_members: Array[Dictionary] = [
		{
			"id": "duplicate",
			"value": JSON.stringify([selected_fixture[0], selected_fixture[0]]),
		},
		{
			"id": "one-key",
			"value": JSON.stringify(selected_fixture.slice(0, 1)),
		},
		{
			"id": "five-keys",
			"value": JSON.stringify(selected_fixture),
		},
		{
			"id": "invalid-key",
			"value": JSON.stringify([
				selected_fixture[0],
				{"id": "missing-type"},
			]),
		},
		{
			"id": "non-array",
			"value": JSON.stringify({"member": selected_fixture[0]}),
		},
		{
			"id": "non-json",
			"value": "not-json",
		},
	]
	for malformed_case: Dictionary in malformed_selected_members:
		var raw_malformed: Dictionary = raw_start_control.duplicate(true)
		raw_malformed[PartyService.START_MEMBERS_KEY] = \
			String(malformed_case.value)
		var malformed_decoded := PartyService.decode_arranged_control(
			raw_malformed)
		test._check(not bool(malformed_decoded.valid),
			"B-START-MALFORMED raw %s selected set is rejected=%s" % [
				malformed_case.id,
				malformed_decoded,
			])
	for hosted_phase: String in [
		PartyService.ARRANGED_PHASE_REMATCH,
		PartyService.ARRANGED_PHASE_GAMEPLAY,
	]:
		var hosted_control := PartyService.encode_arranged_control(
			"control-match", 1, hosted_phase, 0, [])
		test._check(bool(PartyService.decode_arranged_control(
			hosted_control).valid),
			"hosted round accepts generation-zero empty control phase=%s" % \
				hosted_phase)

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

	var selected_start := PartyService.encode_arranged_control(
		"control-match",
		0,
		PartyService.ARRANGED_PHASE_STARTING,
		1,
		[
			user.entity_key,
			{"id": "selected-guest", "type": "title_player_account"},
		])
	var selected_post: PartyService.PartyResult = await service.post_context_update(
		arranged.context,
		selected_start,
		{},
		{},
		service.fake_clock.now_msec() + 1000)
	var selected_snapshot := service.snapshot(arranged.context)
	(arranged.context.peer as Doubles.Peer).keys[1] = user.entity_key.duplicate()
	var selected_proof := service.joined_owner_proof(arranged.context, 1)
	test._check(selected_post.ok() and lobby.update_calls == 2
		and int(selected_snapshot.selected_start_count) == 2
		and int((selected_snapshot.arranged_control as Dictionary).selected_count) == 2
		and int(selected_proof.selected_count) == 2,
		"Starting read-back exposes selected count through snapshot and owner proof")
	(arranged.context.peer as Doubles.Peer).keys[9] = {
		"id": "late-selected-peer",
		"type": "title_player_account",
	}
	var late_proof := service.admission_proof(arranged.context, 9)
	test._check(not bool(late_proof.valid)
		and not bool(late_proof.pending)
		and String(late_proof.reason_code) == "native_member_missing",
		"B-LATE Starting control makes absent late membership definitive")
	var network: Doubles.Network = arranged.context.network
	network.descriptor = "descriptor-refreshed"
	var descriptor_change := Doubles.Change.new()
	descriptor_change.kind = PartyService.NETWORK_CHANGE_DESCRIPTOR_UPDATED
	network.state_changed.emit(descriptor_change)
	await _frames(test, 3)
	test._check(lobby.update_calls == 3
		and String(lobby.properties.get(PartyService.DESCRIPTOR_KEY, ""))
			== "descriptor-refreshed"
		and String(lobby.properties.get(PartyService.SESSION_PHASE_KEY, ""))
			== PartyService.ARRANGED_PHASE_STARTING
		and String(lobby.properties.get(PartyService.START_GENERATION_KEY, "")) == "1"
		and String(lobby.properties.get(PartyService.START_MEMBERS_KEY, ""))
			== String(selected_start.get(PartyService.START_MEMBERS_KEY, "")),
		"descriptor refresh preserves exact selected Starting control")
	var rematch_control := PartyService.encode_arranged_control(
		"control-match", 1, PartyService.ARRANGED_PHASE_REMATCH)
	var advanced: PartyService.PartyResult = await service.post_context_update(
		arranged.context,
		rematch_control,
		{},
		{},
		service.fake_clock.now_msec() + 1000)
	test._check(advanced.ok() and lobby.update_calls == 4
		and arranged.context.selected_start_count == 0,
		"hosted rematch clears the initial selected count")
	var rematch_pending := service.admission_proof(arranged.context, 9)
	test._check(not bool(rematch_pending.valid)
		and bool(rematch_pending.pending)
		and String(rematch_pending.reason_code) == "native_member_pending",
		"B-REMATCH-PENDING unlocked gathering waits for Party-before-Lobby replication")
	lobby.membership_lock = PartyService.MEMBERSHIP_LOCK_LOCKED
	var rematch_locked := service.admission_proof(arranged.context, 9)
	test._check(not bool(rematch_locked.valid)
		and not bool(rematch_locked.pending)
		and String(rematch_locked.reason_code) == "native_member_missing",
		"B-REMATCH-PENDING locked gathering makes missing membership definitive")
	lobby.membership_lock = PartyService.MEMBERSHIP_LOCK_UNLOCKED
	var closed: PartyService.PartyResult = await service.post_context_update(
		arranged.context,
		PartyService.encode_arranged_control(
			"control-match", 1, PartyService.ARRANGED_PHASE_GAMEPLAY),
		{},
		{},
		service.fake_clock.now_msec() + 1000)
	var rematch_closed := service.admission_proof(arranged.context, 9)
	test._check(closed.ok()
		and not bool(rematch_closed.valid)
		and not bool(rematch_closed.pending)
		and String(rematch_closed.reason_code) == "native_member_missing",
		"B-REMATCH-PENDING Gameplay closes a pending replacement definitively")
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


func _c_private_promotion_and_readback(test: Node) -> void:
	print("CASE: C-PRIVATE-PROMOTE/PRESENCE/READBACK keeps one checked private session")
	var session_id := "0123456789abcdef0123456789abcdef"
	var owner := Doubles.User.new("private-promote-owner")
	var selected: Array[Dictionary] = [
		owner.entity_key.duplicate(),
		{"id": "private-promote-b", "type": "title_player_account"},
		{"id": "private-promote-c", "type": "title_player_account"},
		{"id": "private-promote-d", "type": "title_player_account"},
	]
	var reversed: Array[Dictionary] = selected.duplicate(true)
	reversed.reverse()
	var encoded := PartyService.encode_private_control(
		session_id,
		0,
		PartyService.ARRANGED_PHASE_STARTING,
		1,
		selected)
	var equivalent := PartyService.encode_private_control(
		session_id,
		0,
		PartyService.ARRANGED_PHASE_STARTING,
		1,
		reversed)
	var decoded := PartyService.decode_private_control(encoded)
	test._check(bool(decoded.valid)
		and String(decoded.origin) == String(PartyService.PLAY_ORIGIN_PRIVATE)
		and String(decoded.session_id) == session_id
		and int(decoded.round) == 0
		and int(decoded.start_generation) == 1
		and int(decoded.selected_count) == 4
		and encoded == equivalent,
		"C-PRIVATE-PROMOTE private control is canonical=%s" % decoded)
	for invalid_control: Dictionary in [
		PartyService.encode_private_control(
			"ABCDEF0123456789ABCDEF0123456789",
			0,
			PartyService.ARRANGED_PHASE_STARTING,
			1,
			selected),
		PartyService.encode_private_control(
			session_id,
			0,
			PartyService.ARRANGED_PHASE_STARTING,
			0,
			selected),
		PartyService.encode_private_control(
			session_id,
			0,
			PartyService.ARRANGED_PHASE_STARTING,
			1,
			selected.slice(0, 3)),
		PartyService.encode_private_control(
			session_id,
			0,
			PartyService.ARRANGED_PHASE_STARTING,
			1,
			[selected[0], selected[1], selected[2], selected[2]]),
		PartyService.encode_private_control(
			session_id,
			1,
			PartyService.ARRANGED_PHASE_REMATCH,
			1,
			[]),
	]:
		test._check(invalid_control.is_empty(),
			"C-PRIVATE-PROMOTE invalid private control is not encoded")

	var service := Doubles.Party.new(ChatService.new())
	service.configure_clock(service.fake_clock)
	var fixture := await _private_staging_fixture(
		service, owner, "private-promote", selected)
	test._check(not fixture.is_empty(),
		"C-PRIVATE-PROMOTE sealed full group fixture opens")
	if fixture.is_empty():
		return
	var context: PartyService.LobbyContext = fixture.context
	var lobby: Doubles.Lobby = fixture.lobby
	var network: Doubles.Network = fixture.network
	var peer: Doubles.Peer = fixture.peer
	var descriptor := String(network.descriptor)
	var context_id := context.context_id
	var search_control := String(lobby.properties.get(
		PartyService.SEARCH_CONTROL_KEY, ""))
	var update_calls := lobby.update_calls
	var party_create_calls := service.pf.party.create_calls.size()
	var lobby_count := service.pf.multiplayer.lobbies.size()
	var promoted: PartyService.PartyResult = await service.promote_staging_to_private(
		context,
		session_id,
		selected,
		service.fake_clock.now_msec() + 1000)
	var promoted_snapshot := service.snapshot(context)
	test._check(promoted.ok()
		and promoted.context == context
		and promoted.peer == peer
		and promoted.private_session_id == session_id
		and promoted.play_origin == PartyService.PLAY_ORIGIN_PRIVATE,
		"C-PRIVATE-PROMOTE returns the same promoted context")
	test._check(context.context_id == context_id
		and context.lobby == lobby
		and context.network == network
		and context.peer == peer
		and String(network.descriptor) == descriptor
		and lobby.leaves == 0
		and network.leaves == 0,
		"C-PRIVATE-PROMOTE preserves every session resource")
	test._check(service.pf.party.create_calls.size() == party_create_calls
		and service.pf.multiplayer.lobbies.size() == lobby_count
		and service.pf.multiplayer.arranged_calls.is_empty(),
		"C-PRIVATE-PROMOTE creates no replacement lobby, network, or arrangement")
	test._check(lobby.update_calls == update_calls + 1
		and int(promoted_snapshot.access_policy)
			== PartyService.ACCESS_POLICY_PRIVATE
		and String(promoted_snapshot.kind) == PartyService.LOBBY_KIND_PRIVATE
		and promoted_snapshot.play_origin == PartyService.PLAY_ORIGIN_PRIVATE
		and String(promoted_snapshot.private_session_id) == session_id
		and bool((promoted_snapshot.private_control as Dictionary).valid),
		"C-PRIVATE-READBACK derives the committed private session from the lobby")
	test._check(String((promoted_snapshot.properties as Dictionary).get(
		PartyService.SEARCH_CONTROL_KEY, "")) == search_control,
		"C-PRIVATE-PRESENCE leaves the gathering envelope untouched")
	var update_record: Dictionary = lobby.update_records.back()
	var present: Dictionary = update_record.present
	test._check(present.size() == 3
		and present.has("access_policy")
		and present.has("lobby_properties")
		and present.has("search_properties")
		and int(update_record.access_policy)
			== PartyService.ACCESS_POLICY_PRIVATE,
		"C-PRIVATE-PRESENCE sends only access, kind, and private control")
	var recorded_lobby: Dictionary = update_record.lobby_properties
	var recorded_search: Dictionary = update_record.search_properties
	test._check(recorded_lobby.size() == 6
		and recorded_lobby.has(PartyService.PLAY_ORIGIN_KEY)
		and recorded_lobby.has(PartyService.PRIVATE_SESSION_ID_KEY)
		and recorded_lobby.has(PartyService.ROUND_GENERATION_KEY)
		and recorded_lobby.has(PartyService.SESSION_PHASE_KEY)
		and recorded_lobby.has(PartyService.START_GENERATION_KEY)
		and recorded_lobby.has(PartyService.START_MEMBERS_KEY)
		and recorded_search == {
			PartyService.LOBBY_KIND_KEY: PartyService.LOBBY_KIND_PRIVATE,
		},
		"C-PRIVATE-PRESENCE omits capacity and authority configuration")
	await service.leave()
	await _drain_clock(test, service.fake_clock, "C-PRIVATE promotion")

	var readback_cases: Array[Dictionary] = [
		{
			"label": "access",
			"overrides": {"access_policy": PartyService.ACCESS_POLICY_PUBLIC},
		},
		{
			"label": "kind",
			"overrides": {"search_properties": {
				PartyService.LOBBY_KIND_KEY: PartyService.LOBBY_KIND_STAGING,
			}},
		},
		{
			"label": "session",
			"overrides": {"lobby_properties": {
				PartyService.PRIVATE_SESSION_ID_KEY:
					"fedcba9876543210fedcba9876543210",
			}},
		},
		{
			"label": "round",
			"overrides": {"lobby_properties": {
				PartyService.ROUND_GENERATION_KEY: "1",
			}},
		},
		{
			"label": "selected set",
			"overrides": {"lobby_properties": {
				PartyService.START_MEMBERS_KEY:
					JSON.stringify(selected.slice(0, 3)),
			}},
		},
		{
			"label": "owner",
			"overrides": {"owner_entity_key": {
				"id": "private-promote-other-owner",
				"type": "title_player_account",
			}},
		},
		{
			"label": "lock",
			"overrides": {
				"membership_lock": PartyService.MEMBERSHIP_LOCK_UNLOCKED,
			},
		},
		{
			"label": "capacity",
			"overrides": {"max_member_count": 3},
		},
	]
	for readback_case: Dictionary in readback_cases:
		var changed_service := Doubles.Party.new(ChatService.new())
		changed_service.configure_clock(changed_service.fake_clock)
		var changed_owner := Doubles.User.new(
			"private-readback-" + String(readback_case.label))
		var changed_selected := _private_selected_group(
			changed_owner, "private-readback-" + String(readback_case.label))
		var changed_fixture := await _private_staging_fixture(
			changed_service,
			changed_owner,
			"private-readback-" + String(readback_case.label),
			changed_selected)
		var changed_context: PartyService.LobbyContext = changed_fixture.context
		var changed_lobby: Doubles.Lobby = changed_fixture.lobby
		changed_lobby.next_post_overrides = (
			readback_case.overrides as Dictionary
		).duplicate(true)
		var changed_result: PartyService.PartyResult = \
			await changed_service.promote_staging_to_private(
				changed_context,
				session_id,
				changed_selected,
				changed_service.fake_clock.now_msec() + 1000)
		test._check(not changed_result.ok()
			and changed_result.reason_code == &"private_promotion_changed"
			and changed_context.kind == PartyService.LOBBY_KIND_STAGING
			and changed_context.play_origin == &""
			and changed_context.private_session_id.is_empty(),
			"C-PRIVATE-READBACK %s mismatch does not commit local state" % \
				readback_case.label)
		await changed_service.leave()
		await _drain_clock(
			test,
			changed_service.fake_clock,
			"C-PRIVATE readback " + String(readback_case.label))

	var guest_service := Doubles.Party.new(ChatService.new())
	guest_service.configure_clock(guest_service.fake_clock)
	var guest_owner := Doubles.User.new("private-proof-owner")
	var guest_user := Doubles.User.new("private-proof-guest")
	var guest_selected := _private_selected_group(
		guest_owner, "private-proof")
	guest_selected[1] = guest_user.entity_key.duplicate()
	var guest_lobby := _private_lobby_fixture(
		guest_owner.entity_key,
		guest_user.entity_key,
		"private-proof",
		session_id,
		0,
		PartyService.ARRANGED_PHASE_STARTING,
		guest_selected,
		true)
	var guest_context := guest_service._new_context(
		&"staging",
		PartyService.LOBBY_KIND_STAGING,
		guest_user,
		1,
		901)
	guest_context.capacity = MatchmakingService.SESSION_CAPACITY
	guest_service._attach_context_lobby(guest_context, guest_lobby)
	var guest_network := Doubles.Network.new()
	guest_network.local_peer.unique_id = 7
	guest_network.local_peer.keys[1] = guest_owner.entity_key.duplicate()
	test._check(guest_service._attach_context_transport(
		guest_context, guest_network, false),
		"C-PRIVATE-READBACK guest fixture attaches its retained transport")
	var guest_snapshot := guest_service.snapshot(guest_context)
	var guest_proof := guest_service.joined_owner_proof(guest_context, 1)
	test._check(String(guest_snapshot.kind) == PartyService.LOBBY_KIND_PRIVATE
		and guest_snapshot.play_origin == PartyService.PLAY_ORIGIN_PRIVATE
		and String(guest_snapshot.private_session_id) == session_id
		and bool(guest_proof.valid)
		and String(guest_proof.play_origin)
			== String(PartyService.PLAY_ORIGIN_PRIVATE)
		and String(guest_proof.private_session_id) == session_id
		and int(guest_proof.selected_count) == 4,
		"C-PRIVATE-READBACK guest facts follow the committed lobby state")
	await guest_service.leave()
	await _drain_clock(test, guest_service.fake_clock, "C-PRIVATE guest readback")


func _c_private_hold_restore_and_round(test: Node) -> void:
	print("CASE: C-PRIVATE-HOLD/RESTORE/ROUND owns completion and retained rounds")
	var session_id := "1023456789abcdef1023456789abcdef"
	var hold_service := Doubles.Party.new(ChatService.new())
	hold_service.configure_clock(hold_service.fake_clock)
	var hold_owner := Doubles.User.new("private-hold-owner")
	var hold_selected := _private_selected_group(
		hold_owner, "private-hold")
	var hold_fixture := await _private_staging_fixture(
		hold_service, hold_owner, "private-hold", hold_selected)
	var hold_context: PartyService.LobbyContext = hold_fixture.context
	var hold_lobby: Doubles.Lobby = hold_fixture.lobby
	hold_lobby.block_post = true
	var hold_results: Array = []
	_capture_private_promotion(
		hold_service,
		hold_context,
		session_id,
		hold_selected,
		hold_service.fake_clock.now_msec() + 100,
		hold_results)
	await _frames(test, 1)
	test._check(hold_results.is_empty()
		and hold_lobby.update_calls == 1
		and hold_context.pending_operations == 1,
		"C-PRIVATE-HOLD held promotion remains owned")
	hold_service.fake_clock.advance(0.1)
	await _frames(test, 2)
	var hold_timeout: PartyService.PartyResult = hold_results[0] \
		if hold_results.size() == 1 else null
	test._check(hold_timeout != null
		and hold_timeout.reason_code == &"private_promotion_timeout"
		and hold_timeout.cleanup_pending
		and hold_timeout.operation != null
		and hold_timeout.operation.cleanup_pending,
		"C-PRIVATE-HOLD timeout exposes its owed completion")
	var gathering_control := PartyService.encode_search_control({
		"epoch": 902,
		"phase": "gathering",
		"group": hold_selected,
	})
	var hold_updates := hold_lobby.update_calls
	var unsafe_while_owed: PartyService.PartyResult = \
		await hold_service.restore_private_to_gathering(
			hold_context,
			session_id,
			gathering_control,
			hold_service.fake_clock.now_msec() + 1000)
	test._check(unsafe_while_owed.reason_code == &"private_restore_unsafe"
		and hold_lobby.update_calls == hold_updates,
		"C-PRIVATE-RESTORE owed completion causes no restoration call")
	hold_lobby.block_post = false
	hold_lobby.post_released.emit()
	await _frames(test, 3)
	test._check(not hold_timeout.operation.cleanup_pending
		and hold_context.pending_operations == 0
		and hold_context.kind == PartyService.LOBBY_KIND_STAGING
		and String(hold_lobby.search_properties.get(
			PartyService.LOBBY_KIND_KEY, "")) == PartyService.LOBBY_KIND_PRIVATE,
		"C-PRIVATE-HOLD late native completion stays owned without local commit")
	await hold_service.leave()
	await _drain_clock(test, hold_service.fake_clock, "C-PRIVATE hold")

	var restore_service := Doubles.Party.new(ChatService.new())
	restore_service.configure_clock(restore_service.fake_clock)
	var restore_owner := Doubles.User.new("private-restore-owner")
	var restore_selected := _private_selected_group(
		restore_owner, "private-restore")
	var restore_fixture := await _private_staging_fixture(
		restore_service,
		restore_owner,
		"private-restore",
		restore_selected)
	var restore_context: PartyService.LobbyContext = restore_fixture.context
	var restore_lobby: Doubles.Lobby = restore_fixture.lobby
	var restore_network: Doubles.Network = restore_fixture.network
	var promoted: PartyService.PartyResult = \
		await restore_service.promote_staging_to_private(
			restore_context,
			session_id,
			restore_selected,
			restore_service.fake_clock.now_msec() + 1000)
	var restore_updates := restore_lobby.update_calls
	var restore_locks := restore_lobby.lock_calls
	var restored: PartyService.PartyResult = \
		await restore_service.restore_private_to_gathering(
			restore_context,
			session_id,
			gathering_control,
			restore_service.fake_clock.now_msec() + 1000)
	var restored_snapshot := restore_service.snapshot(restore_context)
	test._check(promoted.ok() and restored.ok()
		and restore_context.lobby == restore_lobby
		and restore_context.network == restore_network
		and restore_context.kind == PartyService.LOBBY_KIND_STAGING
		and restore_context.play_origin == &""
		and restore_context.private_session_id.is_empty(),
		"C-PRIVATE-RESTORE returns the same context to Gathering")
	test._check(restore_lobby.update_calls == restore_updates + 1
		and restore_lobby.lock_calls == restore_locks + 1
		and int(restored_snapshot.access_policy)
			== PartyService.ACCESS_POLICY_PUBLIC
		and String(restored_snapshot.kind) == PartyService.LOBBY_KIND_STAGING
		and not bool(restored_snapshot.membership_locked)
		and not bool((restored_snapshot.private_control as Dictionary).valid)
		and String((restored_snapshot.properties as Dictionary).get(
			PartyService.SEARCH_CONTROL_KEY, "")) == gathering_control,
		"C-PRIVATE-RESTORE checks public Gathering and unlock read-back")
	var restore_record: Dictionary = restore_lobby.update_records.back()
	test._check((restore_record.present as Dictionary).size() == 3
		and int(restore_record.access_policy)
			== PartyService.ACCESS_POLICY_PUBLIC
		and String((restore_record.search_properties as Dictionary).get(
			PartyService.LOBBY_KIND_KEY, ""))
			== PartyService.LOBBY_KIND_STAGING
		and String((restore_record.lobby_properties as Dictionary).get(
			PartyService.PLAY_ORIGIN_KEY, "missing")).is_empty()
		and String((restore_record.lobby_properties as Dictionary).get(
			PartyService.PRIVATE_SESSION_ID_KEY, "missing")).is_empty(),
		"C-PRIVATE-RESTORE explicitly clears private control in one update")
	await restore_service.leave()
	await _drain_clock(test, restore_service.fake_clock, "C-PRIVATE restore")

	var failed_service := Doubles.Party.new(ChatService.new())
	failed_service.configure_clock(failed_service.fake_clock)
	var failed_owner := Doubles.User.new("private-failed-owner")
	var failed_selected := _private_selected_group(
		failed_owner, "private-failed")
	var failed_fixture := await _private_staging_fixture(
		failed_service,
		failed_owner,
		"private-failed",
		failed_selected)
	var failed_context: PartyService.LobbyContext = failed_fixture.context
	var failed_lobby: Doubles.Lobby = failed_fixture.lobby
	failed_lobby.next_post_result = Doubles.Results.make(
		false, null, "lobby_update_failed", "Private update failed.")
	var failed_promotion: PartyService.PartyResult = \
		await failed_service.promote_staging_to_private(
			failed_context,
			session_id,
			failed_selected,
			failed_service.fake_clock.now_msec() + 1000)
	var failed_restore: PartyService.PartyResult = \
		await failed_service.restore_private_to_gathering(
			failed_context,
			session_id,
			gathering_control,
			failed_service.fake_clock.now_msec() + 1000)
	test._check(failed_promotion.reason_code == &"private_promotion_failed"
		and failed_restore.ok()
		and failed_context.kind == PartyService.LOBBY_KIND_STAGING
		and failed_lobby.update_calls == 2
		and failed_lobby.lock_calls == 1,
		"C-PRIVATE-RESTORE confirmed failed promotion restores and unlocks")
	await failed_service.leave()
	await _drain_clock(test, failed_service.fake_clock, "C-PRIVATE failed promotion")

	var unsafe_service := Doubles.Party.new(ChatService.new())
	unsafe_service.configure_clock(unsafe_service.fake_clock)
	var unsafe_owner := Doubles.User.new("private-unsafe-owner")
	var unsafe_selected := _private_selected_group(
		unsafe_owner, "private-unsafe")
	var unsafe_fixture := await _private_staging_fixture(
		unsafe_service,
		unsafe_owner,
		"private-unsafe",
		unsafe_selected)
	var unsafe_context: PartyService.LobbyContext = unsafe_fixture.context
	var unsafe_lobby: Doubles.Lobby = unsafe_fixture.lobby
	var unsafe_promoted: PartyService.PartyResult = \
		await unsafe_service.promote_staging_to_private(
			unsafe_context,
			session_id,
			unsafe_selected,
			unsafe_service.fake_clock.now_msec() + 1000)
	unsafe_lobby.properties[PartyService.PRIVATE_SESSION_ID_KEY] = \
		"2023456789abcdef2023456789abcdef"
	var unsafe_calls := unsafe_lobby.update_calls
	var unsafe_restore: PartyService.PartyResult = \
		await unsafe_service.restore_private_to_gathering(
			unsafe_context,
			session_id,
			gathering_control,
			unsafe_service.fake_clock.now_msec() + 1000)
	test._check(unsafe_promoted.ok()
		and unsafe_restore.reason_code == &"private_restore_unsafe"
		and unsafe_lobby.update_calls == unsafe_calls
		and unsafe_context.kind == PartyService.LOBBY_KIND_PRIVATE,
		"C-PRIVATE-RESTORE ambiguous private state has no side effects")
	await unsafe_service.leave()
	await _drain_clock(test, unsafe_service.fake_clock, "C-PRIVATE unsafe restore")

	var restore_fail_service := Doubles.Party.new(ChatService.new())
	restore_fail_service.configure_clock(restore_fail_service.fake_clock)
	var restore_fail_owner := Doubles.User.new("private-restore-fail-owner")
	var restore_fail_selected := _private_selected_group(
		restore_fail_owner, "private-restore-fail")
	var restore_fail_fixture := await _private_staging_fixture(
		restore_fail_service,
		restore_fail_owner,
		"private-restore-fail",
		restore_fail_selected)
	var restore_fail_context: PartyService.LobbyContext = \
		restore_fail_fixture.context
	var restore_fail_lobby: Doubles.Lobby = restore_fail_fixture.lobby
	await restore_fail_service.promote_staging_to_private(
		restore_fail_context,
		session_id,
		restore_fail_selected,
		restore_fail_service.fake_clock.now_msec() + 1000)
	restore_fail_lobby.next_post_result = Doubles.Results.make(
		false, null, "lobby_update_failed", "Restore failed.")
	var restore_failed: PartyService.PartyResult = \
		await restore_fail_service.restore_private_to_gathering(
			restore_fail_context,
			session_id,
			gathering_control,
			restore_fail_service.fake_clock.now_msec() + 1000)
	test._check(restore_failed.reason_code == &"private_restore_failed"
		and restore_fail_lobby.lock_calls == 0
		and restore_fail_context.kind == PartyService.LOBBY_KIND_PRIVATE,
		"C-PRIVATE-RESTORE failed update never unlocks optimistically")
	await restore_fail_service.leave()
	await _drain_clock(
		test, restore_fail_service.fake_clock, "C-PRIVATE failed restore")

	var round_service := Doubles.Party.new(ChatService.new())
	round_service.configure_clock(round_service.fake_clock)
	var round_owner := Doubles.User.new("private-round-owner")
	var round_selected := _private_selected_group(
		round_owner, "private-round")
	var round_fixture := await _private_staging_fixture(
		round_service, round_owner, "private-round", round_selected)
	var round_context: PartyService.LobbyContext = round_fixture.context
	var round_lobby: Doubles.Lobby = round_fixture.lobby
	var round_network: Doubles.Network = round_fixture.network
	await round_service.promote_staging_to_private(
		round_context,
		session_id,
		round_selected,
		round_service.fake_clock.now_msec() + 1000)
	var round_create_calls := round_service.pf.party.create_calls.size()
	var round_lobby_count := round_service.pf.multiplayer.lobbies.size()
	var rematch: PartyService.PartyResult = \
		await round_service.set_private_round_control(
			round_context,
			session_id,
			1,
			PartyService.ARRANGED_PHASE_REMATCH,
			round_service.fake_clock.now_msec() + 1000)
	var rematch_snapshot := round_service.snapshot(round_context)
	test._check(rematch.ok()
		and round_context.network == round_network
		and int((rematch_snapshot.private_control as Dictionary).round) == 1
		and String((rematch_snapshot.private_control as Dictionary).phase)
			== PartyService.ARRANGED_PHASE_REMATCH
		and int((rematch_snapshot.private_control as Dictionary).selected_count) == 0
		and round_context.selected_start_count == 0,
		"C-PRIVATE-ROUND publishes generation-zero empty retained control")
	test._check(round_service.pf.party.create_calls.size() == round_create_calls
		and round_service.pf.multiplayer.lobbies.size() == round_lobby_count
		and round_service.pf.multiplayer.arranged_calls.is_empty(),
		"C-PRIVATE-ROUND rebuilds no lobby, network, or arrangement")
	round_lobby.membership_lock = PartyService.MEMBERSHIP_LOCK_UNLOCKED
	(round_context.peer as Doubles.Peer).keys[9] = {
		"id": "private-round-candidate",
		"type": "title_player_account",
	}
	var private_pending := round_service.admission_proof(round_context, 9)
	test._check(not bool(private_pending.valid)
		and bool(private_pending.pending)
		and String(private_pending.reason_code) == "native_member_pending",
		"C-PRIVATE-ROUND unlocked rematch waits for current membership")
	round_lobby.membership_lock = PartyService.MEMBERSHIP_LOCK_LOCKED
	var private_locked := round_service.admission_proof(round_context, 9)
	test._check(not bool(private_locked.valid)
		and not bool(private_locked.pending)
		and String(private_locked.reason_code) == "native_member_missing",
		"C-PRIVATE-ROUND lock makes missing membership definitive")
	round_lobby.membership_lock = PartyService.MEMBERSHIP_LOCK_UNLOCKED
	var gameplay: PartyService.PartyResult = \
		await round_service.set_private_round_control(
			round_context,
			session_id,
			1,
			PartyService.ARRANGED_PHASE_GAMEPLAY,
			round_service.fake_clock.now_msec() + 1000)
	var private_closed := round_service.admission_proof(round_context, 9)
	test._check(gameplay.ok()
		and not bool(private_closed.valid)
		and not bool(private_closed.pending)
		and String(private_closed.reason_code) == "native_member_missing",
		"C-PRIVATE-ROUND Gameplay closes a pending replacement")
	var round_updates := round_lobby.update_calls
	var invalid_round: PartyService.PartyResult = \
		await round_service.set_private_round_control(
			round_context,
			session_id,
			0,
			PartyService.ARRANGED_PHASE_REMATCH,
			round_service.fake_clock.now_msec() + 1000)
	test._check(invalid_round.reason_code == &"private_round_invalid"
		and round_lobby.update_calls == round_updates,
		"C-PRIVATE-ROUND invalid retained control makes no native call")
	await round_service.leave()
	await _drain_clock(test, round_service.fake_clock, "C-PRIVATE round")


func _c_private_invitation(test: Node) -> void:
	print("CASE: C-PRIVATE-INVITE accepts only an open retained private round")
	var previous_matchmaking: MatchmakingService = Services._matchmaking
	Services._matchmaking = Doubles.Matchmaking.new()
	var session_id := "3023456789abcdef3023456789abcdef"
	var owner := Doubles.User.new("private-invite-owner")
	var guest := Doubles.User.new("private-invite-guest")
	var exact_connection := "private+opaque%2fvalue|slash/:=lower"
	var lobby := _private_lobby_fixture(
		owner.entity_key,
		guest.entity_key,
		"private-invite",
		session_id,
		2,
		PartyService.ARRANGED_PHASE_REMATCH,
		[],
		false)
	lobby.connection_string = exact_connection
	var network := Doubles.Network.new()
	network.local_peer.keys[1] = owner.entity_key.duplicate()
	var service := Doubles.Party.new(ChatService.new())
	service.configure_clock(service.fake_clock)
	service.pf.multiplayer.lobby_by_connection[exact_connection] = lobby
	service.pf.party.queued_networks.append(network)
	var joined: Dictionary = await service.join_by_connection_string(
		guest,
		exact_connection,
		service.fake_clock.now_msec() + 45000)
	test._check(bool(joined.get("ok", false))
		and String(joined.get("destination", "")) == "private_rematch"
		and String(joined.get("kind", "")) == PartyService.LOBBY_KIND_PRIVATE
		and String(joined.get("play_origin", ""))
			== String(PartyService.PLAY_ORIGIN_PRIVATE)
		and String(joined.get("private_session_id", "")) == session_id
		and int(joined.get("round", -1)) == 2
		and int(joined.get("capacity", 0)) == 4
		and int(joined.get("selected_start_count", -1)) == 0
		and (joined.get("owner_key", {}) as Dictionary) == owner.entity_key,
		"C-PRIVATE-INVITE returns the private-rematch result shape=%s" % joined)
	test._check(service.pf.multiplayer.join_calls == [exact_connection]
		and service.pf.multiplayer.find_calls.is_empty(),
		"C-PRIVATE-INVITE preserves the exact connection string")
	test._check(service.pf.party.join_calls.size() == 1
		and String(service.pf.party.join_calls[0].invitation_id)
			== PartyService.MATCHMAKING_INVITATION_ID
		and service.pf.multiplayer.arranged_calls.is_empty(),
		"C-PRIVATE-INVITE uses the retained Party network without an arrangement")
	test._check(lobby.member_calls == 1
		and lobby.update_calls == 0
		and String(lobby.members[1].properties.get(
			MatchmakingService.PROTOCOL_MEMBER_KEY, ""))
			== NRProtocol.version_string()
		and String(lobby.members[1].properties.get(
			PartyService.PRIVATE_SESSION_ID_KEY, "")) == session_id
		and not lobby.members[1].properties.has(
			PartyService.MATCH_ID_MEMBER_KEY)
		and not lobby.members[1].properties.has(
			PartyService.MATCH_ORIGIN_MEMBER_KEY),
		"C-PRIVATE-INVITE writes only protocol and private session metadata")
	var joined_context: PartyService.LobbyContext = joined.context
	var joined_snapshot := service.snapshot(joined_context)
	var joined_proof := service.joined_owner_proof(joined_context, 1)
	test._check(joined_snapshot.play_origin == PartyService.PLAY_ORIGIN_PRIVATE
		and String(joined_snapshot.private_session_id) == session_id
		and bool(joined_proof.valid)
		and String(joined_proof.play_origin)
			== String(PartyService.PLAY_ORIGIN_PRIVATE)
		and String(joined_proof.private_session_id) == session_id
		and int(joined_proof.round) == 2,
		"C-PRIVATE-INVITE guest snapshot and owner proof retain private identity")
	await service.leave()
	await _drain_clock(test, service.fake_clock, "C-PRIVATE invite")

	var ordered_lobby := _private_lobby_fixture(
		owner.entity_key,
		guest.entity_key,
		"private-invite-order",
		session_id,
		3,
		PartyService.ARRANGED_PHASE_REMATCH,
		[],
		false)
	ordered_lobby.block_member = true
	var ordered_network := Doubles.Network.new()
	ordered_network.local_peer.keys[1] = owner.entity_key.duplicate()
	var ordered_service := Doubles.Party.new(ChatService.new())
	ordered_service.configure_clock(ordered_service.fake_clock)
	ordered_service.pf.multiplayer.lobby_by_connection[
		ordered_lobby.connection_string] = ordered_lobby
	ordered_service.pf.party.queued_networks.append(ordered_network)
	var ordered_results: Array = []
	_capture_connection_join(
		ordered_service,
		guest,
		ordered_lobby.connection_string,
		ordered_service.fake_clock.now_msec() + 45000,
		ordered_results)
	await _frames(test, 1)
	test._check(ordered_results.is_empty()
		and ordered_lobby.member_calls == 1
		and ordered_service.pf.party.join_calls.is_empty(),
		"C-PRIVATE-INVITE member metadata completes before Party entry")
	ordered_lobby.block_member = false
	ordered_lobby.member_released.emit()
	await _frames(test, 3)
	test._check(ordered_results.size() == 1
		and bool((ordered_results[0] as Dictionary).get("ok", false))
		and ordered_lobby.member_calls == 1
		and ordered_lobby.update_calls == 0
		and ordered_service.pf.party.join_calls.size() == 1,
		"C-PRIVATE-INVITE successful Party return performs no later lobby write")
	await ordered_service.leave()
	await _drain_clock(
		test, ordered_service.fake_clock, "C-PRIVATE invite ordering")

	for refusal_label: String in [
		"locked",
		"starting",
		"gameplay",
		"public",
		"migration",
		"protocol",
		"owner disconnected",
		"malformed",
		"stale session",
	]:
		var refusal_service := Doubles.Party.new(ChatService.new())
		refusal_service.configure_clock(refusal_service.fake_clock)
		var refusal_lobby := _private_lobby_fixture(
			owner.entity_key,
			guest.entity_key,
			"private-refusal-" + refusal_label.replace(" ", "-"),
			session_id,
			2,
			PartyService.ARRANGED_PHASE_REMATCH,
			[],
			false)
		match refusal_label:
			"locked":
				refusal_lobby.membership_lock = \
					PartyService.MEMBERSHIP_LOCK_LOCKED
			"starting":
				var starting_selected := _private_selected_group(
					owner, "private-refusal-starting")
				starting_selected[1] = guest.entity_key.duplicate()
				refusal_lobby.properties.merge(
					PartyService.encode_private_control(
						session_id,
						0,
						PartyService.ARRANGED_PHASE_STARTING,
						1,
						starting_selected),
					true)
			"gameplay":
				refusal_lobby.properties.merge(
					PartyService.encode_private_control(
						session_id,
						2,
						PartyService.ARRANGED_PHASE_GAMEPLAY),
					true)
			"public":
				refusal_lobby.access_policy = \
					PartyService.ACCESS_POLICY_PUBLIC
			"migration":
				refusal_lobby.owner_migration_policy = \
					PartyService.OWNER_MIGRATION_AUTOMATIC
			"protocol":
				refusal_lobby.members[0].properties[
					MatchmakingService.PROTOCOL_MEMBER_KEY] = "0.0"
			"owner disconnected":
				refusal_lobby.members[0].connection_status = 0
			"malformed":
				refusal_lobby.properties[
					PartyService.PRIVATE_SESSION_ID_KEY] = "invalid"
			"stale session":
				refusal_lobby.members[1].properties = {
					MatchmakingService.PROTOCOL_MEMBER_KEY:
						NRProtocol.version_string(),
					PartyService.PRIVATE_SESSION_ID_KEY:
						"4023456789abcdef4023456789abcdef",
				}
		refusal_service.pf.multiplayer.lobby_by_connection[
			refusal_lobby.connection_string] = refusal_lobby
		var refused: Dictionary = \
			await refusal_service.join_by_connection_string(
				guest,
				refusal_lobby.connection_string,
				refusal_service.fake_clock.now_msec() + 45000)
		test._check(not bool(refused.get("ok", false))
			and String(refused.get("kind", ""))
				== PartyService.LOBBY_KIND_PRIVATE
			and refusal_service.pf.party.join_calls.is_empty()
			and refusal_service.pf.multiplayer.arranged_calls.is_empty()
			and refusal_lobby.leaves == 1,
			"C-PRIVATE-INVITE %s is refused before Party entry" % \
				refusal_label)
		await _drain_clock(
			test,
			refusal_service.fake_clock,
			"C-PRIVATE refusal " + refusal_label)

	Services._matchmaking = previous_matchmaking


func _s8_joined_owner_authority_without_flow(test: Node) -> void:
	print("CASE: joined lobby authority is available before any MatchmakingFlow exists")
	var service := Doubles.Party.new(ChatService.new())
	service.configure_clock(service.fake_clock)
	var owner := Doubles.User.new("owner-proof-host")
	var guest := Doubles.User.new("owner-proof-guest")
	var lobby := _arranged_lobby_fixture(
		owner.entity_key, guest.entity_key, "owner-proof-arranged")
	lobby.search_properties[PartyService.LOBBY_KIND_KEY] = \
		PartyService.LOBBY_KIND_ARRANGED
	lobby.properties.merge(PartyService.encode_arranged_control(
		"owner-proof-match", 4, PartyService.ARRANGED_PHASE_REMATCH), true)
	lobby.properties[PartyService.DESCRIPTOR_KEY] = "owner-proof-descriptor"
	lobby.members[0].properties = {
		MatchmakingService.PROTOCOL_MEMBER_KEY: NRProtocol.version_string(),
		PartyService.MATCH_ID_MEMBER_KEY: "owner-proof-match",
	}
	lobby.members[1].properties = {
		MatchmakingService.PROTOCOL_MEMBER_KEY: NRProtocol.version_string(),
		PartyService.MATCH_ID_MEMBER_KEY: "owner-proof-match",
	}
	service.pf.multiplayer.next_arranged_result = Doubles.Results.make(true, lobby)
	var arranged: PartyService.PartyResult = await service.join_arranged(
		guest,
		"owner-proof-arrangement",
		lobby.members[1].properties,
		4,
		1,
		701,
		service.fake_clock.now_msec() + 1000)
	var network := Doubles.Network.new()
	network.local_peer.unique_id = 7
	network.local_peer.keys[1] = owner.entity_key.duplicate()
	network.local_peer.keys[7] = guest.entity_key.duplicate()
	service.pf.party.queued_networks.append(network)
	var joined: PartyService.PartyResult = await service.join_transport(
		arranged.context, guest, service.fake_clock.now_msec() + 1000)
	test._check(joined.ok(),
		"pending-rematch fixture joins the arranged transport")

	network.local_peer.keys.erase(1)
	var pending := service.joined_owner_proof(arranged.context, 1)
	test._check(not bool(pending.valid) and bool(pending.pending)
		and String(pending.reason_code) == "party_identity_pending",
		"the guest waits while the joined-lobby owner is not ready: %s" % \
			pending.reason_code)
	network.local_peer.keys[1] = owner.entity_key.duplicate()
	var proven := service.joined_owner_proof(arranged.context, 1)
	test._check(bool(proven.valid) and not bool(proven.pending)
		and bool(proven.local_lobby_connected),
		"the pending rematch accepts the current joined-lobby owner")
	test._check((proven.owner_key as Dictionary) == owner.entity_key
		and (proven.peer_key as Dictionary) == owner.entity_key,
		"the accepted owner remains the current lobby owner=%s" % proven.owner_key)
	test._check(String(proven.protocol) == NRProtocol.version_string()
		and String(proven.match_id) == "owner-proof-match"
		and int(proven.round) == 4
		and String(proven.phase) == PartyService.ARRANGED_PHASE_REMATCH,
		"arranged admission retains the current protocol and round=%s" % proven)
	arranged.context.recovery_epoch -= 1
	var stale_recovery := service.joined_owner_proof(arranged.context, 1)
	test._check(not bool(stale_recovery.valid)
		and String(stale_recovery.reason_code) == "context_unavailable",
		"a stale recovery context is refused")
	arranged.context.recovery_epoch += 1

	var other_owner := {
		"id": "owner-proof-other-owner",
		"type": "title_player_account",
	}
	lobby.owner_entity_key = other_owner
	network.local_peer.keys[1] = other_owner
	lobby.members[0].entity_key = other_owner
	var changed := service.joined_owner_proof(arranged.context, 1)
	test._check(not bool(changed.valid) and not bool(changed.pending)
		and String(changed.reason_code) == "owner_changed",
		"a later owner change is refused: %s" % \
			changed.reason_code)
	await service.leave()
	await _drain_clock(test, service.fake_clock, "S8 arranged owner authority")

	var staging_service := Doubles.Party.new(ChatService.new())
	staging_service.configure_clock(staging_service.fake_clock)
	var staging_user := Doubles.User.new("owner-proof-staging")
	var staging: PartyService.PartyResult = await staging_service.create_staging(
		staging_user,
		4,
		"deathmatch",
		1,
		702,
		staging_service.fake_clock.now_msec() + 1000)
	(staging.context.peer as Doubles.Peer).keys[1] = \
		staging_user.entity_key.duplicate()
	var staging_proof := staging_service.joined_owner_proof(staging.context, 1)
	test._check(bool(staging_proof.valid)
		and bool(staging_proof.local_lobby_connected)
		and String(staging_proof.protocol) == NRProtocol.version_string(),
		"staging admission accepts the compatible lobby protocol")
	await staging_service.leave()
	await _drain_clock(test, staging_service.fake_clock, "S8 staging authority")

	var hosted_service := Doubles.Party.new(ChatService.new())
	hosted_service.configure_clock(hosted_service.fake_clock)
	var hosted_user := Doubles.User.new("owner-proof-hosted")
	var hosted: Dictionary = await hosted_service.host(
		hosted_user, 4, "deathmatch")
	var hosted_network: Doubles.Network = hosted_service.pf.party.networks[0]
	(hosted_network.local_peer as Doubles.Peer).keys[1] = \
		hosted_user.entity_key.duplicate()
	var hosted_proof := hosted_service.joined_owner_proof(null, 1)
	test._check(bool(hosted.get("ok", false)) and bool(hosted_proof.valid)
		and bool(hosted_proof.local_lobby_connected)
		and String(hosted_proof.protocol) == NRProtocol.version_string(),
		"hosted admission accepts the compatible lobby protocol")
	await hosted_service.leave()
	await _drain_clock(test, hosted_service.fake_clock, "S8 hosted authority")


func _s8_legacy_guest_authority_changes(test: Node) -> void:
	print("CASE: legacy guest handles local Lobby disconnect and owner changes")
	var previous_matchmaking: MatchmakingService = Services._matchmaking
	Services._matchmaking = Doubles.Matchmaking.new()
	for scenario: String in [
		"owner_cleared",
		"owner_changed",
		"owner_disconnected",
		"owner_removed",
		"protocol",
		"peer_mismatch",
		"local_disconnected",
		"local_disconnected_owner_changed",
		"local_disconnected_peer_mismatch",
		"local_disconnected_identity_pending",
		"local_disconnected_transport_missing",
		"scoped_attached",
	]:
		var fixture: Dictionary = await _legacy_guest_session_fixture(
			Doubles.User.new("legacy-proof-" + scenario),
			"legacy-proof-" + scenario)
		var service: Doubles.Party = fixture.service
		var lobby: Doubles.Lobby = fixture.lobby
		var network: Doubles.Network = fixture.network
		var owner: Dictionary = fixture.owner
		test._check(bool((fixture.joined as Dictionary).get("ok", false)),
			"[%s] legacy guest fixture joined" % scenario)
		match scenario:
			"owner_cleared":
				lobby.owner_entity_key = {}
			"owner_changed":
				lobby.owner_entity_key = {
					"id": "legacy-proof-other-owner",
					"type": "title_player_account",
				}
			"owner_disconnected":
				(lobby.members[0] as Doubles.Member).connection_status = 0
			"owner_removed":
				lobby.members.remove_at(0)
			"protocol":
				lobby.search_properties[NRProtocol.LOBBY_KEY] = "1.3"
			"peer_mismatch":
				network.local_peer.keys[1] = {
					"id": "legacy-proof-other-peer",
					"type": "title_player_account",
				}
			"local_disconnected":
				lobby.disconnected = true
			"local_disconnected_owner_changed":
				lobby.disconnected = true
				lobby.owner_entity_key = {
					"id": "legacy-proof-other-owner",
					"type": "title_player_account",
				}
			"local_disconnected_peer_mismatch":
				lobby.disconnected = true
				network.local_peer.keys[1] = {
					"id": "legacy-proof-other-peer",
					"type": "title_player_account",
				}
			"local_disconnected_identity_pending":
				lobby.disconnected = true
				network.local_peer.keys.erase(1)
			"local_disconnected_transport_missing":
				lobby.disconnected = true
				service._network = null
			"scoped_attached":
				service._attached_context = PartyService.LobbyContext.new()
		var proof := service.joined_owner_proof(null, 1)
		var expected := {
			"owner_cleared": "owner_changed",
			"owner_changed": "owner_changed",
			"owner_disconnected": "owner_disconnected",
			"owner_removed": "owner_member_missing",
			"protocol": "owner_protocol_mismatch",
			"peer_mismatch": "owner_peer_mismatch",
			"local_disconnected": "local_lobby_disconnected",
			"local_disconnected_owner_changed": "owner_changed",
			"local_disconnected_peer_mismatch": "owner_peer_mismatch",
			"local_disconnected_identity_pending": "party_identity_pending",
			"local_disconnected_transport_missing": "transport_unavailable",
			"scoped_attached": "context_unavailable",
		}
		var expected_pending := scenario == "local_disconnected_identity_pending"
		test._check(not bool(proof.valid) and bool(proof.pending) == expected_pending,
			"[%s] legacy guest is refused valid=%s pending=%s expected_pending=%s" % [
				scenario, proof.valid, proof.pending, expected_pending])
		test._check(String(proof.reason_code) == String(expected[scenario]),
			"[%s] legacy guest reason=%s" % [scenario, proof.reason_code])
		if scenario.begins_with("local_disconnected"):
			test._check(not bool(proof.local_lobby_connected),
				"[%s] every disconnected proof exposes local Lobby state" % scenario)
		if scenario == "local_disconnected":
			test._check(not bool(proof.local_lobby_connected)
				and (proof.peer_key as Dictionary) == owner
				and (proof.captured_owner_key as Dictionary) == owner,
				"local-only disconnect remains distinct from a host change")
		if scenario == "scoped_attached":
			service._attached_context = null
		if scenario == "local_disconnected_transport_missing":
			service._network = network
		await service.leave()
		await _drain_clock(test, service.fake_clock, "S8 legacy authority " + scenario)
	Services._matchmaking = previous_matchmaking


func _legacy_guest_session_fixture(
	guest: Doubles.User,
	label: String
) -> Dictionary:
	var service := Doubles.Party.new(ChatService.new())
	service.configure_clock(service.fake_clock)
	var owner := Doubles.User.new(label + "-owner")
	var lobby := _hosted_lobby(
		String(owner.entity_key.id),
		"ABCDE",
		label + "-descriptor",
		label + "-lobby")
	lobby.connection_string = label + "-connection"
	var network := Doubles.Network.new()
	network.local_peer.unique_id = 7
	network.local_peer.keys[1] = owner.entity_key.duplicate()
	network.local_peer.keys[7] = guest.entity_key.duplicate()
	service.pf.party.queued_networks.append(network)
	service.pf.multiplayer.lobby_by_connection[lobby.connection_string] = lobby
	var joined: Dictionary = await service.join_by_connection_string(
		guest,
		lobby.connection_string,
		service.fake_clock.now_msec() + 1000)
	return {
		"service": service,
		"lobby": lobby,
		"network": network,
		"owner": owner.entity_key.duplicate(),
		"joined": joined,
	}


func _s8_invite_destinations(test: Node) -> void:
	print("CASE: B-LATE arranged destinations distinguish rematch, cutoff, and unknown failure")
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
		and int(rematch.get("capacity", 0)) == 4
		and int(rematch.get("selected_start_count", -1)) == 0,
		"valid arranged rematch returns its named destination=%s" % rematch)
	test._check(rematch_service.pf.multiplayer.join_calls == [exact_connection]
		and rematch_service.pf.multiplayer.find_calls.is_empty(),
		"#16 connection string reaches Lobby byte-for-byte calls=%s" % \
			[rematch_service.pf.multiplayer.join_calls])
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

	for phase_case: Dictionary in [
		{
			"phase": PartyService.ARRANGED_PHASE_BOOTSTRAP,
			"round": 0,
			"generation": 0,
			"selected": [],
		},
		{
			"phase": PartyService.ARRANGED_PHASE_STARTING,
			"round": 0,
			"generation": 1,
			"selected": [owner.entity_key, guest.entity_key],
		},
		{
			"phase": PartyService.ARRANGED_PHASE_GAMEPLAY,
			"round": 3,
			"generation": 0,
			"selected": [],
		},
	]:
		var phase := String(phase_case.phase)
		var phase_selected: Array[Dictionary] = []
		phase_selected.assign(phase_case.selected)
		var phase_service := Doubles.Party.new(ChatService.new())
		phase_service.configure_clock(phase_service.fake_clock)
		var phase_lobby := _arranged_lobby_fixture(
			owner.entity_key, guest.entity_key, "invite-arranged-" + phase)
		phase_lobby.search_properties[PartyService.LOBBY_KIND_KEY] = \
			PartyService.LOBBY_KIND_ARRANGED
		phase_lobby.properties.merge(PartyService.encode_arranged_control(
			"invite-match",
			int(phase_case.round),
			phase,
			int(phase_case.generation),
			phase_selected), true)
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

	var unknown_join := Doubles.Party.new(ChatService.new())
	unknown_join.configure_clock(unknown_join.fake_clock)
	unknown_join.pf.multiplayer.next_arranged_result = Doubles.Results.make(
		false,
		null,
		"arranged_lobby_join_failed",
		"Injected unproven arranged join failure.",
		-2147467259)
	var unknown_result: PartyService.PartyResult = await unknown_join.join_arranged(
		guest,
		"unknown-arrangement",
		{},
		MatchmakingService.SESSION_CAPACITY,
		1,
		499,
		unknown_join.fake_clock.now_msec() + 1000)
	test._check(not unknown_result.ok()
		and unknown_result.reason_code == &"arranged_join_failed",
		"B-LATE unproven native arranged failure keeps the stable unknown-cause code")

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
	current_ticket.publish_terminal(MatchmakingService.STATUS_CANCELLED)
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
			[invalidations])
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

	var required := Doubles.Party.new(ChatService.new())
	required.configure_clock(required.fake_clock)
	var required_invalidations: Array[int] = []
	required.multiplayer_invalidated.connect(func(epoch: int) -> void:
		required_invalidations.append(epoch))
	required.require_recovery(&"matched_cancel_waiter")
	required.require_recovery(&"duplicate_request")
	test._check(required.is_cleanup_pending(),
		"required recovery fences online entry immediately")
	test._check(required.pf.party.shutdown_calls == 0
		and required.pf.multiplayer.shutdown_calls == 0,
		"require_recovery starts no native work before global leave")
	await required.leave()
	test._check(required.pf.party.shutdown_calls == 1
		and required.pf.multiplayer.shutdown_calls == 1,
		"next global leave resets Party=%d Multiplayer=%d only" % [
			required.pf.party.shutdown_calls,
			required.pf.multiplayer.shutdown_calls])
	test._check(required_invalidations == [1],
		"required recovery emits one Multiplayer invalidation=%s" % \
			[required_invalidations])
	test._check(not required.is_cleanup_pending()
		and required.recovery_error.is_empty(),
		"confirmed required recovery clears its fence")
	await _drain_clock(test, required.fake_clock, "S9 required recovery")

	var previous_party: PartyService = Services._party
	var previous_matchmaking: MatchmakingService = Services._matchmaking
	var composed_party := Doubles.Party.new(ChatService.new())
	var composed_matchmaking := Doubles.Matchmaking.new()
	var composed_clock := Doubles.Clock.new()
	composed_party.configure_clock(composed_clock)
	composed_matchmaking.configure_clock(composed_clock)
	Services._party = composed_party
	Services._matchmaking = composed_matchmaking
	Services.bind_party_signals()
	var composed_ticket := Doubles.Ticket.new()
	composed_ticket.cancel_fault_unanswered = true
	composed_matchmaking.sdk.queued_create_results.append(
		Doubles.Results.make(true, composed_ticket))
	var composed_attempt := composed_matchmaking.begin_create(
		_spec(Doubles.User.new("composed-recovery"), [{
			"id": "composed-recovery",
			"type": "title_player_account",
		}], 505))
	await _frames(test, 2)
	composed_matchmaking.request_cancel(composed_attempt)
	composed_matchmaking.retire(composed_attempt)
	composed_ticket.match_id = "composed-match"
	composed_ticket.arranged_lobby_connection_string = "composed-arrangement"
	composed_ticket.emit_status(MatchmakingService.STATUS_MATCHED)
	await _frames(test, 1)
	test._check(composed_matchmaking.has_orphaned_matched_cancel(),
		"composed fixture exposes the real orphaned Matched cancel")
	var composed_order: Array[String] = []
	var composed_observer_recorded: Array[bool] = [false]
	composed_matchmaking.cleanup_state_changed.connect(func() -> void:
		if not composed_observer_recorded[0]:
			composed_observer_recorded[0] = true
			composed_order.append("cancel_observer_resumed"))
	composed_party.pf.multiplayer.shutdown_hook = func() -> void:
		composed_order.append("cancel_released")
		composed_matchmaking.sdk.invalidate_runtime()
	composed_party.multiplayer_invalidated.connect(func(_epoch: int) -> void:
		composed_order.append("multiplayer_invalidated"))
	composed_party.require_recovery(&"matchmaking_cancel_unresolved")
	await composed_party.leave()
	await _frames(test, 3)
	test._check(composed_order == [
		"cancel_released",
		"cancel_observer_resumed",
		"multiplayer_invalidated",
	], "cancel observer resumes synchronously inside shutdown before invalidation=%s" % \
		[composed_order])
	test._check(not composed_matchmaking.has_pending_cleanup()
		and not composed_matchmaking.has_orphaned_matched_cancel(),
		"composed confirmed recovery discharges the old ticket epoch")
	test._check(composed_matchmaking.fake_warnings.size() == 1
		and composed_matchmaking.fake_warnings[0].contains(
			"reason=cancel_released_by_reset"),
		"composed reset release keeps distinct log provenance=%s" % \
			[composed_matchmaking.fake_warnings])
	composed_party.pf.multiplayer.shutdown_hook = Callable()
	Services._party = previous_party
	Services._matchmaking = previous_matchmaking
	await _drain_clock(test, composed_clock, "S9 composed recovery")


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
		active_losses.append({
			"reason": reason,
			"context_id": int(context.context_id) if context != null else 0,
		}))
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
	test._check(int(active_loss.get("context_id", 0))
			== active_result.context.context_id,
		"active loss retains its captured context id=%s" % \
			active_loss.get("context_id"))
	test._check(String(active_loss.get("reason", ""))
			== "The group host left or is no longer available, so the group was closed.",
		"active owner clear reports the host-loss reason=%s" % \
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
		retirement_losses.append({
			"reason": reason,
			"context_id": int(lost_context.context_id) if lost_context != null else 0,
		}))
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


func _private_selected_group(
	owner: Doubles.User,
	prefix: String
) -> Array[Dictionary]:
	return [
		owner.entity_key.duplicate(),
		{"id": prefix + "-b", "type": "title_player_account"},
		{"id": prefix + "-c", "type": "title_player_account"},
		{"id": prefix + "-d", "type": "title_player_account"},
	]


func _private_staging_fixture(
	service: Doubles.Party,
	owner: Doubles.User,
	label: String,
	selected: Array[Dictionary]
) -> Dictionary:
	var opened: PartyService.PartyResult = await service.create_staging(
		owner,
		MatchmakingService.SESSION_CAPACITY,
		"deathmatch",
		1,
		900,
		service.fake_clock.now_msec() + 1000)
	if not opened.ok():
		return {}
	var context: PartyService.LobbyContext = opened.context
	var lobby: Doubles.Lobby = context.lobby
	var network: Doubles.Network = context.network
	var members: Array = []
	for key: Dictionary in selected:
		members.append(Doubles.Member.new(key, {
			MatchmakingService.PROTOCOL_MEMBER_KEY:
				NRProtocol.version_string(),
			PartyService.MATCH_ORIGIN_MEMBER_KEY:
				PartyService.MATCH_ORIGIN_VALUE,
		}))
	lobby.members = members
	lobby.local_entity_key = owner.entity_key.duplicate()
	lobby.membership_lock = PartyService.MEMBERSHIP_LOCK_LOCKED
	lobby.properties[PartyService.SESSION_PHASE_KEY] = "private"
	lobby.properties[PartyService.SEARCH_CONTROL_KEY] = \
		PartyService.encode_search_control({
			"epoch": 900,
			"phase": "private",
			"group": selected,
		})
	return {
		"context": context,
		"lobby": lobby,
		"network": network,
		"peer": context.peer,
		"label": label,
	}


func _private_lobby_fixture(
	owner_key: Dictionary,
	local_key: Dictionary,
	lobby_id: String,
	session_id: String,
	round: int,
	phase: String,
	selected: Array[Dictionary],
	locked: bool
) -> Doubles.Lobby:
	var lobby := Doubles.Lobby.new()
	lobby.lobby_id = lobby_id
	lobby.connection_string = "connection-" + lobby_id
	lobby.owner_entity_key = owner_key.duplicate()
	lobby.local_entity_key = local_key.duplicate()
	lobby.max_member_count = MatchmakingService.SESSION_CAPACITY
	lobby.access_policy = PartyService.ACCESS_POLICY_PRIVATE
	lobby.owner_migration_policy = PartyService.OWNER_MIGRATION_NONE
	lobby.restrict_invites_to_lobby_owner = false
	lobby.membership_lock = PartyService.MEMBERSHIP_LOCK_LOCKED \
		if locked else PartyService.MEMBERSHIP_LOCK_UNLOCKED
	lobby.search_properties = {
		PartyService.LOBBY_KIND_KEY: PartyService.LOBBY_KIND_PRIVATE,
		PartyService.GAME_MODE_KEY: "deathmatch",
		NRProtocol.LOBBY_KEY: NRProtocol.version_string(),
	}
	lobby.properties = {
		PartyService.DESCRIPTOR_KEY: "descriptor-" + lobby_id,
	}
	var control := PartyService.encode_private_control(
		session_id,
		round,
		phase,
		1 if round == 0 else 0,
		selected)
	lobby.properties.merge(control, true)
	var member_keys: Array[Dictionary] = []
	if selected.is_empty():
		member_keys.append(owner_key.duplicate())
		if owner_key != local_key:
			member_keys.append(local_key.duplicate())
	else:
		member_keys.assign(selected)
	for key: Dictionary in member_keys:
		var properties := {
			MatchmakingService.PROTOCOL_MEMBER_KEY:
				NRProtocol.version_string(),
		}
		if selected.is_empty() and key == local_key:
			properties = {}
		lobby.members.append(Doubles.Member.new(key, properties))
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


func _capture_private_promotion(
	service: Doubles.Party,
	context: PartyService.LobbyContext,
	session_id: String,
	selected: Array[Dictionary],
	deadline_msec: int,
	results: Array
) -> void:
	results.append(await service.promote_staging_to_private(
		context,
		session_id,
		selected,
		deadline_msec))


func _capture_connection_join(
	service: Doubles.Party,
	user: Doubles.User,
	connection_string: String,
	deadline_msec: int,
	results: Array
) -> void:
	results.append(await service.join_by_connection_string(
		user,
		connection_string,
		deadline_msec))


func _capture_party_drain(
	service: Doubles.Party,
	deadline_msec: int,
	results: Array
) -> void:
	await service.drain_owned_work(deadline_msec)
	results.append(true)


func _capture_ticket_cancel(
	ticket: Doubles.Ticket,
	results: Array
) -> void:
	results.append(await ticket.cancel_async())


func _capture_scoped_lobby_leave(
	service: Doubles.Party,
	context: PartyService.LobbyContext,
	results: Array
) -> void:
	results.append(await service.leave_lobby(context))


func _capture_scoped_transport_leave(
	service: Doubles.Party,
	context: PartyService.LobbyContext,
	results: Array
) -> void:
	results.append(await service.leave_transport(context))


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
	spec.capacity = MatchmakingService.SESSION_CAPACITY
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


func _generic_full_party_failure(
	test: Node,
	attempt: MatchmakingService.TicketAttempt,
	expected_code: StringName,
	description: String
) -> void:
	test._check(attempt.outcome == MatchmakingService.Outcome.FAILED,
		"%s outcome=%d" % [description, attempt.outcome])
	test._check(attempt.reason_code == expected_code,
		"%s reason_code=%s" % [description, attempt.reason_code])
	test._check(attempt.reason.contains(MatchmakingService.FULL_PARTY_GUIDANCE),
		"%s guidance=%s" % [description, attempt.reason])
	test._check(attempt.reason_code != MatchmakingService.FULL_PARTY_REASON_CODE,
		"%s does not claim confirmed queue-size cause" % description)


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


func _assert_matchmaking_case_clean(
	test: Node,
	service: Doubles.Matchmaking,
	clock: Doubles.Clock,
	label: String
) -> void:
	test._check(service.sdk.pending_cancel_waiters() == 0,
		"%s: no native cancel observer remains pending (waiters=%d)" % [
			label, service.sdk.pending_cancel_waiters()])
	test._check(service.sdk.retained_cancel_results() == 0,
		"%s: no cancel result retains a Ticket (retained=%d)" % [
			label, service.sdk.retained_cancel_results()])
	test._check(not service.has_pending_cleanup(),
		"%s: MatchmakingService owns no pending cleanup" % label)
	await _drain_clock(test, clock, label)
