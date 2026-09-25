class_name MatchmakingService
extends RefCounted

## PlayFab Matchmaking service boundary.
##
## Quick Match uses this boundary for group tickets, arranged lobbies, deadline ownership and
## cleanup, so every late result affects only the exact attempt that created it.

const QUEUE_NAME := "godotnr_q"
const PROTOCOL_MEMBER_KEY := "nr_protocol"
const SEARCH_TIMEOUT_SECONDS := 600
const EXPECTED_MATCH_COUNT := 4

const FULL_PARTY_REASON_CODE := &"full_party_queue_max_rejected"
const FULL_PARTY_REASON := "A full group of four cannot match in this four-player queue."
const SEARCH_TIMEOUT_REASON_CODE := &"search_timeout"
const SEARCH_TIMEOUT_REASON := "Matchmaking timed out before the service found a match."

const _FLOW_IMPLEMENTED := true
const _JOIN_CONFIG_CLASS := "PlayFabLobbyJoinConfig"
const _JOIN_CONFIG_SENTINEL := "member_properties"
const _TICKET_CONFIG_CLASS := "PlayFabMatchmakingTicketConfig"
const _MEMBER_CLASS := "PlayFabMatchmakingMember"
const _TICKET_CLASS := "PlayFabMatchTicket"

const REQUIRED_JOIN_CONFIG_CAPABILITIES := [
	["max_member_count", "max_players"],
	["access_policy"],
	["owner_migration_policy"],
]
const REQUIRED_TICKET_CONFIG_PROPERTIES := [
	"queue_name",
	"timeout_seconds",
	"members",
	"members_to_match_with",
]
const REQUIRED_TICKET_PROPERTIES := [
	"ticket_id",
	"status",
	"match_id",
	"arranged_lobby_connection_string",
]
const REQUIRED_TICKET_METHODS := ["cancel_async"]
const REQUIRED_MULTIPLAYER_METHODS := [
	"create_match_ticket_async",
	"join_match_ticket_async",
	"join_arranged_lobby_async",
]

const STATUS_CREATING := 0
const STATUS_JOINING := 1
const STATUS_WAITING_FOR_PLAYERS := 2
const STATUS_WAITING_FOR_MATCH := 3
const STATUS_MATCHED := 4
const STATUS_CANCELLED := 5
const STATUS_FAILED := 6

enum Outcome {
	PENDING,
	MATCHED,
	CANCELLED,
	NO_MATCH,
	FAILED,
	SUPERSEDED,
	QUARANTINED,
	TIMEOUT,
}


class SearchSpec extends RefCounted:
	var user: Variant = null
	var account_generation := -1
	var flow_epoch := 0
	var owner := false
	var mode: NRTypes.GameModeType = NRTypes.GameModeType.DEATHMATCH
	var frozen_members: Array[Dictionary] = []
	var expected_match_count := 4
	var deadline_msec := 0
	var ticket_id := ""


class TicketAttempt extends RefCounted:
	signal progress_changed(attempt)
	signal finished(attempt)
	signal cleanup_changed(attempt)

	var operation_id := 0
	var multiplayer_epoch := 0
	var account_generation := -1
	var flow_epoch := 0
	var owner := false
	var mode: NRTypes.GameModeType = NRTypes.GameModeType.DEATHMATCH
	var user: Variant = null
	var frozen_members: Array[Dictionary] = []
	var expected_match_count := 4
	var deadline_msec := 0
	var clock: OnlineFlowClock = null
	var ticket: Variant = null
	var ticket_id := ""
	var match_id := ""
	var arrangement := ""
	var status := -1
	var outcome := 0
	var reason_code: StringName = &""
	var reason := ""
	var diagnostic := ""
	var cleanup_pending := false
	var native_terminal := false
	var abandon_requested := false
	var retired := false
	var create_in_flight := false
	var cancel_in_flight := false
	var state_callback: Callable = Callable()
	var deadline_alarm: Variant = null

	func is_pending() -> bool:
		return outcome == 0

	func wait() -> Variant:
		if is_pending():
			await finished
		return self

	func settle(
		next_outcome: int,
		next_reason_code: StringName = &"",
		next_reason: String = "",
		next_diagnostic: String = ""
	) -> bool:
		if not is_pending():
			return false
		if deadline_alarm != null:
			if deadline_alarm.has_method("cancel"):
				deadline_alarm.cancel()
			deadline_alarm = null
		outcome = next_outcome
		reason_code = next_reason_code
		reason = next_reason
		diagnostic = next_diagnostic
		finished.emit(self)
		return true


var _clock: OnlineFlowClock = OnlineFlowClock.new()
var _attempts: Array[TicketAttempt] = []
var _next_operation_id := 1
var _multiplayer_epoch := 0
var _missing_properties_cache: PackedStringArray = []
var _missing_properties_cached := false
var _missing_group_cache: PackedStringArray = []
var _missing_group_cached := false


func configure_clock(clock: OnlineFlowClock) -> void:
	if _has_live_attempt():
		push_warning("[Matchmaking] Cannot replace the online-flow clock while work is active.")
		return
	if clock == null:
		push_warning("[Matchmaking] Cannot configure a null online-flow clock.")
		return
	_clock = clock


func is_available() -> bool:
	return availability_reason().is_empty()


func availability_reason() -> String:
	if not _flow_implemented():
		return "Quick Match is not available in this build yet."
	if _queue_name().strip_edges().is_empty():
		return "Matchmaking is unavailable: no matchmaking queue is configured."
	if _playfab() == null:
		return "Matchmaking needs the PlayFab extension, which this build does not have."
	if not addon_supports_group_matchmaking():
		return "This build's PlayFab addon cannot create group matchmaking tickets."
	if not addon_supports_arranged_config():
		return "This build's PlayFab addon cannot configure a matched lobby, so Quick Match is unavailable."
	var profile := runtime_profile(NRTypes.GameModeType.DEATHMATCH)
	if not bool(profile.get("ok", false)):
		return String(profile.get("reason", ""))
	return ""


func runtime_profile(
	mode: NRTypes.GameModeType = NRTypes.GameModeType.DEATHMATCH
) -> Dictionary:
	if mode != NRTypes.GameModeType.DEATHMATCH:
		return _profile_failure(
			mode,
			&"profile_unsupported_mode")
	var config: Variant = _game_mode_config(mode)
	if config == null or int(config.mode_type) != int(mode):
		return _profile_failure(
			mode,
			&"profile_missing")
	var player_count := int(config.player_count)
	if player_count != EXPECTED_MATCH_COUNT:
		return _profile_failure(
			mode,
			&"profile_count_mismatch",
			player_count)
	return {
		"ok": true,
		"mode": int(mode),
		"player_count": player_count,
		"reason_code": "",
		"reason": "",
	}


func addon_supports_arranged_config() -> bool:
	return _playfab() != null and _join_config_recognised() \
		and missing_join_config_properties().is_empty()


func addon_supports_group_matchmaking() -> bool:
	return _playfab() != null and missing_group_matchmaking_capabilities().is_empty()


func missing_join_config_properties() -> PackedStringArray:
	if _missing_properties_cached:
		return _missing_properties_cache.duplicate()

	var missing := PackedStringArray()
	if not ClassDB.class_exists(_JOIN_CONFIG_CLASS):
		for capability: Array in REQUIRED_JOIN_CONFIG_CAPABILITIES:
			missing.append(String(capability[0]))
	else:
		var present := _class_property_names(_JOIN_CONFIG_CLASS)
		for capability: Array in REQUIRED_JOIN_CONFIG_CAPABILITIES:
			var satisfied := false
			for name: String in capability:
				if present.has(name):
					satisfied = true
					break
			if not satisfied:
				missing.append(String(capability[0]))

	_missing_properties_cache = missing
	_missing_properties_cached = true
	return missing.duplicate()


func missing_group_matchmaking_capabilities() -> PackedStringArray:
	if _missing_group_cached:
		return _missing_group_cache.duplicate()

	var missing := PackedStringArray()
	var multiplayer: Variant = _multiplayer()
	if multiplayer == null:
		missing.append("PlayFabMultiplayer")
	else:
		for method_name: String in REQUIRED_MULTIPLAYER_METHODS:
			if not multiplayer.has_method(method_name):
				missing.append(method_name)

	_collect_missing_class_properties(_TICKET_CONFIG_CLASS, REQUIRED_TICKET_CONFIG_PROPERTIES, missing)
	_collect_missing_class_properties(_TICKET_CLASS, REQUIRED_TICKET_PROPERTIES, missing)
	_collect_missing_class_methods(_TICKET_CLASS, REQUIRED_TICKET_METHODS, missing)
	if not ClassDB.class_exists(_MEMBER_CLASS):
		missing.append(_MEMBER_CLASS)
	elif not _class_property_names(_MEMBER_CLASS).has("user"):
		missing.append("%s.user" % _MEMBER_CLASS)
	if ClassDB.class_exists(_TICKET_CLASS):
		var signals := _class_signal_names(_TICKET_CLASS)
		if not signals.has("state_changed"):
			missing.append("%s.state_changed" % _TICKET_CLASS)

	_missing_group_cache = missing
	_missing_group_cached = true
	return missing.duplicate()


func blocking_dependency() -> String:
	if not addon_supports_group_matchmaking():
		return "The installed PlayFab addon is missing group matchmaking capabilities: %s." % \
			", ".join(missing_group_matchmaking_capabilities())
	if not _join_config_recognised():
		return "Could not inspect %s. The addon contract may have changed." % _JOIN_CONFIG_CLASS
	var missing := missing_join_config_properties()
	if not missing.is_empty():
		return "Arranged-lobby initialization is missing: %s." % ", ".join(missing)
	return ""


func begin_create(spec: SearchSpec) -> TicketAttempt:
	var attempt := _new_attempt(spec, true)
	var validation := _validate_attempt(attempt, true)
	if not bool(validation.get("ok", false)):
		attempt.settle(
			Outcome.FAILED,
			StringName(validation.get("reason_code", "invalid_search_spec")),
			String(validation.get("reason", "The matchmaking request is invalid.")))
		return attempt
	_attempts.append(attempt)
	_arm_deadline(attempt)
	_create_ticket(attempt)
	return attempt


func begin_join(spec: SearchSpec) -> TicketAttempt:
	var attempt := _new_attempt(spec, false)
	var validation := _validate_attempt(attempt, false)
	if not bool(validation.get("ok", false)):
		attempt.settle(
			Outcome.FAILED,
			StringName(validation.get("reason_code", "invalid_search_spec")),
			String(validation.get("reason", "The matchmaking request is invalid.")))
		return attempt
	_attempts.append(attempt)
	_arm_deadline(attempt)
	_join_ticket(attempt)
	return attempt


func request_cancel(attempt: TicketAttempt) -> void:
	if attempt == null or attempt.native_terminal or not _attempt_epoch_current(attempt):
		return
	attempt.abandon_requested = true
	if attempt.ticket != null and not attempt.cancel_in_flight:
		_cancel_ticket(attempt)


## Synchronous by design: suspend and account-loss paths cannot await. Native work that
## returns later remains owned by this service and cleans up only its captured ticket.
func retire(attempt: TicketAttempt) -> void:
	if attempt == null or attempt.retired:
		return
	attempt.retired = true
	_cancel_deadline_alarm(attempt)
	if attempt.is_pending():
		attempt.settle(Outcome.SUPERSEDED)
	if attempt.native_terminal:
		_complete_native_cleanup(attempt)
	elif attempt.ticket != null:
		_set_cleanup_pending(attempt, true)
		if not attempt.cancel_in_flight:
			_cleanup_retired_ticket(attempt)
	else:
		_set_cleanup_pending(
			attempt,
			attempt.create_in_flight or attempt.cancel_in_flight)
	_prune_attempts()


func multiplayer_invalidated(recovery_epoch: int) -> void:
	if recovery_epoch <= _multiplayer_epoch:
		return
	_multiplayer_epoch = recovery_epoch
	for attempt: TicketAttempt in _attempts.duplicate():
		if attempt.multiplayer_epoch >= recovery_epoch:
			continue
		_cancel_deadline_alarm(attempt)
		attempt.retired = true
		attempt.abandon_requested = true
		if attempt.is_pending():
			attempt.settle(
				Outcome.FAILED,
				&"multiplayer_invalidated",
				"Matchmaking stopped while multiplayer services recovered.")
		_disconnect_ticket(attempt)
		attempt.ticket = null
		attempt.native_terminal = true
		attempt.create_in_flight = false
		attempt.cancel_in_flight = false
		_set_cleanup_pending(attempt, false)
	_prune_attempts()


func has_pending_cleanup() -> bool:
	for attempt: TicketAttempt in _attempts:
		if attempt.create_in_flight or attempt.cancel_in_flight or attempt.cleanup_pending \
			or (attempt.retired and attempt.ticket != null and not attempt.native_terminal):
			return true
	return false


func drain_owned_work(deadline_msec: int) -> void:
	while has_pending_cleanup() and (deadline_msec <= 0 or _now_msec(_clock) < deadline_msec):
		await _sleep_with_clock(_clock, 0.05)


static func reason_for_code(code: String) -> String:
	match code:
		FULL_PARTY_REASON_CODE:
			return FULL_PARTY_REASON
		SEARCH_TIMEOUT_REASON_CODE:
			return SEARCH_TIMEOUT_REASON
		_:
			return ""


func _set_cleanup_pending(attempt: TicketAttempt, pending: bool) -> void:
	if attempt == null or attempt.cleanup_pending == pending:
		return
	attempt.cleanup_pending = pending
	attempt.cleanup_changed.emit(attempt)


func _new_attempt(spec: SearchSpec, owner: bool) -> TicketAttempt:
	var attempt := TicketAttempt.new()
	attempt.operation_id = _next_operation_id
	_next_operation_id += 1
	attempt.multiplayer_epoch = _multiplayer_epoch
	attempt.owner = owner
	attempt.clock = _clock
	if spec == null:
		return attempt
	attempt.user = spec.user
	attempt.account_generation = spec.account_generation
	attempt.flow_epoch = spec.flow_epoch
	attempt.mode = spec.mode
	attempt.frozen_members = _copy_member_keys(spec.frozen_members)
	attempt.expected_match_count = spec.expected_match_count
	attempt.deadline_msec = spec.deadline_msec
	attempt.ticket_id = spec.ticket_id.strip_edges()
	if attempt.deadline_msec <= 0:
		attempt.deadline_msec = _now_msec(attempt.clock) + SEARCH_TIMEOUT_SECONDS * 1000
	return attempt


func _validate_attempt(attempt: TicketAttempt, owner: bool) -> Dictionary:
	if attempt.user == null:
		return _validation_failure("A signed-in PlayFab user is required.")
	if attempt.account_generation < 0 or attempt.flow_epoch <= 0:
		return _validation_failure("The matchmaking attempt identity is invalid.")
	var profile := runtime_profile(attempt.mode)
	if not bool(profile.get("ok", false)):
		return profile
	if attempt.expected_match_count != int(profile.get("player_count", 0)) \
		or attempt.expected_match_count != EXPECTED_MATCH_COUNT:
		return _validation_failure(
			"The matchmaking request does not match the configured four-player profile.",
			&"profile_request_mismatch")
	if attempt.frozen_members.size() < 1 or attempt.frozen_members.size() > EXPECTED_MATCH_COUNT:
		return _validation_failure("Matchmaking groups must contain between one and four players.")
	if _now_msec(attempt.clock) >= attempt.deadline_msec:
		return _validation_failure("The matchmaking deadline has already expired.")
	if not owner and attempt.ticket_id.is_empty():
		return _validation_failure("A guest needs a matchmaking ticket id.")
	var local_key := _user_entity_key(attempt.user)
	if local_key.is_empty():
		return _validation_failure("The signed-in PlayFab user has no entity identity.")
	var seen: Dictionary = {}
	var local_count := 0
	for key: Dictionary in attempt.frozen_members:
		var normalized := _copy_entity_key(key)
		if normalized.is_empty():
			return _validation_failure("The matchmaking group contains an invalid entity identity.")
		var fingerprint := _entity_fingerprint(normalized)
		if seen.has(fingerprint):
			return _validation_failure("The matchmaking group contains a duplicate entity identity.")
		seen[fingerprint] = true
		if _entity_fingerprint(local_key) == fingerprint:
			local_count += 1
	if local_count != 1:
		return _validation_failure(
			"The local PlayFab user must appear exactly once in the matchmaking group.")
	var capability_reason := _capability_reason()
	if not capability_reason.is_empty():
		return _validation_failure(capability_reason, &"matchmaking_capability_missing")
	return {"ok": true}


func _capability_reason() -> String:
	if _queue_name().strip_edges().is_empty():
		return "No matchmaking queue is configured."
	if not addon_supports_group_matchmaking():
		return "The installed PlayFab addon cannot create group matchmaking tickets."
	return ""


func _flow_implemented() -> bool:
	return _FLOW_IMPLEMENTED


func _game_mode_config(mode: NRTypes.GameModeType) -> Variant:
	return Assets.game_mode(mode) if Assets != null else null


func _queue_name() -> String:
	return QUEUE_NAME


func _profile_failure(
	mode: NRTypes.GameModeType,
	code: StringName,
	player_count: int = 0
) -> Dictionary:
	return {
		"ok": false,
		"mode": int(mode),
		"player_count": player_count,
		"reason_code": String(code),
		"reason": "Quick Match needs the four-player Deathmatch settings.",
	}


func _validation_failure(
	message: String,
	code: StringName = &"invalid_search_spec"
) -> Dictionary:
	return {
		"ok": false,
		"reason_code": String(code),
		"reason": message,
	}


func _create_ticket(attempt: TicketAttempt) -> void:
	if not _attempt_epoch_current(attempt):
		return
	attempt.create_in_flight = true
	var config: Variant = _make_ticket_config(attempt)
	if config == null:
		attempt.create_in_flight = false
		_finish_failed(attempt, &"ticket_config_unavailable",
			"The PlayFab matchmaking ticket configuration is unavailable.", null)
		return

	var multiplayer: Variant = _multiplayer()
	if multiplayer == null:
		attempt.create_in_flight = false
		_finish_failed(attempt, &"matchmaking_unavailable",
			"The PlayFab matchmaking service is unavailable.", null)
		return

	# REVIEW: Full-party submission is deliberate for xplat parity.
	# Microsoft Learn, "Configuring matchmaking queues":
	# "If a ticket already meets the maximum requirement for a match, however, it is rejected."
	# godotnr_q has MaxMatchSize = 4: a full party of four is submitted and will be rejected.
	# Follow-up proposal: "Private Start" starts a full party directly, with no ticket.
	# Until that change is approved, recover this rejection to gathering; do not silently host.
	var result: Variant = await multiplayer.create_match_ticket_async(attempt.user, config)
	attempt.create_in_flight = false
	if not _attempt_epoch_current(attempt):
		_prune_attempts()
		return
	if attempt.retired or not attempt.is_pending() \
		or not _account_is_current(attempt.account_generation):
		_cleanup_late_result(attempt, result)
		return
	if not _result_ok(result):
		_finish_create_failure(attempt, result)
		return
	var ticket: Variant = _result_data(result)
	if ticket == null:
		_finish_failed(attempt, &"ticket_missing",
			"The match service returned no matchmaking ticket.", result)
		return
	_attach_ticket(attempt, ticket)
	_reconcile_ticket(attempt)
	if attempt.abandon_requested and not attempt.native_terminal:
		_cancel_ticket(attempt)


func _join_ticket(attempt: TicketAttempt) -> void:
	if not _attempt_epoch_current(attempt):
		return
	attempt.create_in_flight = true
	var multiplayer: Variant = _multiplayer()
	if multiplayer == null:
		attempt.create_in_flight = false
		_finish_failed(attempt, &"matchmaking_unavailable",
			"The PlayFab matchmaking service is unavailable.", null)
		return
	var local_member: Variant = _make_local_member(attempt.user)
	if local_member == null:
		attempt.create_in_flight = false
		_finish_failed(attempt, &"ticket_member_unavailable",
			"The local matchmaking member could not be created.", null)
		return
	var result: Variant = await multiplayer.join_match_ticket_async(
		attempt.user,
		attempt.ticket_id,
		_queue_name(),
		[local_member])
	attempt.create_in_flight = false
	if not _attempt_epoch_current(attempt):
		_prune_attempts()
		return
	if attempt.retired or not attempt.is_pending() \
		or not _account_is_current(attempt.account_generation):
		_cleanup_late_result(attempt, result)
		return
	if not _result_ok(result):
		_finish_failed(attempt, &"ticket_join_failed",
			"Could not join the group's matchmaking ticket.", result)
		return
	var ticket: Variant = _result_data(result)
	if ticket == null:
		_finish_failed(attempt, &"ticket_missing",
			"The match service returned no matchmaking ticket.", result)
		return
	_attach_ticket(attempt, ticket)
	_reconcile_ticket(attempt)
	if attempt.abandon_requested and not attempt.native_terminal:
		_cancel_ticket(attempt)


func _make_ticket_config(attempt: TicketAttempt) -> Variant:
	var config: Variant = _new_ticket_config()
	var local_member: Variant = _make_local_member(attempt.user)
	if config == null or local_member == null:
		return null
	var local_key := _user_entity_key(attempt.user)
	var remotes: Array[Dictionary] = []
	for key: Dictionary in attempt.frozen_members:
		var normalized := _copy_entity_key(key)
		if _entity_fingerprint(normalized) != _entity_fingerprint(local_key):
			remotes.append(normalized)
	config.queue_name = _queue_name()
	config.timeout_seconds = SEARCH_TIMEOUT_SECONDS
	config.members = [local_member]
	config.members_to_match_with = remotes
	return config


func _make_local_member(user: Variant) -> Variant:
	var member: Variant = _new_matchmaking_member()
	if member == null:
		return null
	member.user = user
	member.attributes = {}
	return member


func _new_ticket_config() -> Variant:
	return ClassDB.instantiate(_TICKET_CONFIG_CLASS)


func _new_matchmaking_member() -> Variant:
	return ClassDB.instantiate(_MEMBER_CLASS)


func _attach_ticket(attempt: TicketAttempt, ticket: Variant) -> void:
	if not _attempt_epoch_current(attempt):
		return
	attempt.ticket = ticket
	attempt.ticket_id = String(_object_value(ticket, &"ticket_id", attempt.ticket_id))
	var callback := Callable(self, "_on_ticket_changed").bind(attempt)
	attempt.state_callback = callback
	if ticket.has_signal("state_changed") and not ticket.is_connected("state_changed", callback):
		ticket.connect("state_changed", callback)


func _disconnect_ticket(attempt: TicketAttempt) -> void:
	if attempt.ticket == null or not attempt.state_callback.is_valid():
		return
	if attempt.ticket.has_signal("state_changed") \
			and attempt.ticket.is_connected("state_changed", attempt.state_callback):
		attempt.ticket.disconnect("state_changed", attempt.state_callback)
	attempt.state_callback = Callable()


func _on_ticket_changed(change: Variant, attempt: TicketAttempt) -> void:
	if attempt == null:
		return
	_reconcile_ticket(attempt, _object_value(change, &"result", null))


func _reconcile_ticket(attempt: TicketAttempt, terminal_result: Variant = null) -> void:
	if attempt == null or attempt.ticket == null or not _attempt_epoch_current(attempt):
		return
	var observed := _observe_terminal_snapshot(attempt, terminal_result)
	if bool(observed.get("terminal", false)):
		return
	var changed := bool(observed.get("changed", false))
	var status := int(observed.get("status", -1))
	var account_current := _account_is_current(attempt.account_generation)
	if status < STATUS_MATCHED and not account_current and not attempt.retired:
		retire(attempt)
		return
	if changed and attempt.is_pending() and not attempt.retired:
		attempt.progress_changed.emit(attempt)


func _observe_terminal_snapshot(
	attempt: TicketAttempt,
	terminal_result: Variant = null
) -> Dictionary:
	if attempt == null or attempt.ticket == null:
		return {"terminal": false, "changed": false, "status": -1}
	var status := int(_object_value(attempt.ticket, &"status", -1))
	var ticket_id := String(_object_value(attempt.ticket, &"ticket_id", attempt.ticket_id))
	var changed := status != attempt.status or ticket_id != attempt.ticket_id
	attempt.status = status
	attempt.ticket_id = ticket_id
	if status < STATUS_MATCHED:
		return {"terminal": false, "changed": changed, "status": status}
	var account_current := _account_is_current(attempt.account_generation)
	if not account_current and not attempt.retired \
		and attempt.is_pending():
		attempt.retired = true
		attempt.settle(Outcome.SUPERSEDED)
	if changed and attempt.is_pending() and not attempt.retired:
		attempt.progress_changed.emit(attempt)
	match status:
		STATUS_MATCHED:
			attempt.match_id = String(_object_value(attempt.ticket, &"match_id", ""))
			attempt.arrangement = String(_object_value(
				attempt.ticket, &"arranged_lobby_connection_string", ""))
			attempt.native_terminal = true
			_cancel_deadline_alarm(attempt)
			if attempt.is_pending():
				attempt.settle(Outcome.MATCHED)
			_complete_native_cleanup(attempt)
		STATUS_CANCELLED:
			attempt.native_terminal = true
			_cancel_deadline_alarm(attempt)
			if attempt.is_pending():
				attempt.settle(Outcome.CANCELLED)
			_complete_native_cleanup(attempt)
		STATUS_FAILED:
			var diagnostic := _ticket_diagnostic(attempt.ticket, terminal_result)
			attempt.native_terminal = true
			_cancel_deadline_alarm(attempt)
			if attempt.is_pending():
				if attempt.owner and attempt.frozen_members.size() == EXPECTED_MATCH_COUNT:
					attempt.settle(
						Outcome.FAILED,
						FULL_PARTY_REASON_CODE,
						FULL_PARTY_REASON,
						diagnostic)
				else:
					attempt.settle(
						Outcome.FAILED,
						&"matchmaking_failed",
						"Matchmaking failed before a match was found.",
						diagnostic)
			elif not diagnostic.is_empty():
				attempt.diagnostic = diagnostic if attempt.diagnostic.is_empty() \
					else "%s | terminal=%s" % [attempt.diagnostic, diagnostic]
			_complete_native_cleanup(attempt)
	return {"terminal": true, "changed": changed, "status": status}


func _complete_native_cleanup(attempt: TicketAttempt) -> void:
	if attempt == null or not attempt.native_terminal:
		return
	_disconnect_ticket(attempt)
	_cancel_deadline_alarm(attempt)
	attempt.ticket = null
	_set_cleanup_pending(attempt, false)
	_prune_attempts()


func _cancel_ticket(attempt: TicketAttempt) -> void:
	if attempt == null or attempt.ticket == null or attempt.cancel_in_flight \
		or not _attempt_epoch_current(attempt):
		return
	if bool(_observe_terminal_snapshot(attempt).get("terminal", false)):
		return
	attempt.cancel_in_flight = true
	_set_cleanup_pending(attempt, true)
	var result: Variant = await attempt.ticket.cancel_async()
	attempt.cancel_in_flight = false
	if not _attempt_epoch_current(attempt):
		_prune_attempts()
		return
	if attempt.native_terminal:
		_complete_native_cleanup(attempt)
		return
	if not _result_ok(result):
		var diagnostic := _diagnostic(result)
		if attempt.is_pending():
			_cancel_deadline_alarm(attempt)
			attempt.settle(
				Outcome.FAILED,
				&"cancel_unconfirmed",
				"The match service did not confirm cancellation.",
				diagnostic)
		elif attempt.diagnostic.is_empty():
			attempt.diagnostic = diagnostic
		_set_cleanup_pending(attempt, true)
		return
	_reconcile_ticket(attempt, result)
	if not attempt.native_terminal:
		if attempt.is_pending():
			_cancel_deadline_alarm(attempt)
			attempt.settle(
				Outcome.FAILED,
				&"cancel_unconfirmed",
				"The match service did not confirm cancellation.",
				_diagnostic(result))
		_set_cleanup_pending(attempt, true)


func _arm_deadline(attempt: TicketAttempt) -> void:
	if attempt == null or not attempt.is_pending() \
		or attempt.retired or not _attempt_epoch_current(attempt):
		return
	if attempt.clock == null:
		attempt.clock = OnlineFlowClock.new()
	attempt.deadline_alarm = attempt.clock.alarm_at(
		attempt.deadline_msec,
		_on_ticket_deadline.bind(attempt.operation_id))


func _on_ticket_deadline(operation_id: int) -> void:
	var attempt := _attempt_for_operation(operation_id)
	if attempt == null:
		return
	attempt.deadline_alarm = null
	if not attempt.is_pending() or attempt.retired or not _attempt_epoch_current(attempt):
		return
	_set_cleanup_pending(
		attempt,
		attempt.ticket != null or attempt.create_in_flight)
	attempt.settle(Outcome.TIMEOUT, SEARCH_TIMEOUT_REASON_CODE, SEARCH_TIMEOUT_REASON)
	if attempt.ticket != null and not attempt.cancel_in_flight:
		_cancel_after_timeout(attempt)


func _cancel_deadline_alarm(attempt: TicketAttempt) -> void:
	if attempt == null or attempt.deadline_alarm == null:
		return
	if attempt.deadline_alarm.has_method("cancel"):
		attempt.deadline_alarm.cancel()
	attempt.deadline_alarm = null


func _attempt_for_operation(operation_id: int) -> TicketAttempt:
	for attempt: TicketAttempt in _attempts:
		if attempt.operation_id == operation_id:
			return attempt
	return null


func _attempt_epoch_current(attempt: TicketAttempt) -> bool:
	return attempt != null and attempt.multiplayer_epoch == _multiplayer_epoch


func _cancel_after_timeout(attempt: TicketAttempt) -> void:
	_cancel_ticket(attempt)


func _cleanup_retired_ticket(attempt: TicketAttempt) -> void:
	if attempt.ticket == null:
		_set_cleanup_pending(
			attempt,
			attempt.create_in_flight or attempt.cancel_in_flight)
		return
	_cancel_ticket(attempt)


func _cleanup_late_result(attempt: TicketAttempt, result: Variant) -> void:
	if not _attempt_epoch_current(attempt):
		_prune_attempts()
		return
	if _result_ok(result):
		var ticket: Variant = _result_data(result)
		if ticket != null:
			_attach_ticket(attempt, ticket)
			_set_cleanup_pending(attempt, true)
			_reconcile_ticket(attempt)
			if not attempt.native_terminal and not attempt.cancel_in_flight:
				_cleanup_retired_ticket(attempt)
	else:
		attempt.native_terminal = true
		_set_cleanup_pending(attempt, false)
	_prune_attempts()


func _finish_create_failure(attempt: TicketAttempt, result: Variant) -> void:
	if attempt.owner and attempt.frozen_members.size() == EXPECTED_MATCH_COUNT:
		_finish_failed(attempt, FULL_PARTY_REASON_CODE, FULL_PARTY_REASON, result)
	else:
		_finish_failed(attempt, &"ticket_create_failed",
			"Could not create a matchmaking ticket.", result)


func _finish_failed(
	attempt: TicketAttempt,
	code: StringName,
	message: String,
	result: Variant
) -> void:
	_cancel_deadline_alarm(attempt)
	if attempt.ticket == null and not attempt.create_in_flight and not attempt.cancel_in_flight:
		attempt.native_terminal = true
		_set_cleanup_pending(attempt, false)
	attempt.settle(Outcome.FAILED, code, message, _diagnostic(result))
	_prune_attempts()


func _prune_attempts() -> void:
	for index in range(_attempts.size() - 1, -1, -1):
		var attempt := _attempts[index]
		if attempt.create_in_flight or attempt.cancel_in_flight or attempt.cleanup_pending:
			continue
		if attempt.ticket != null:
			continue
		if attempt.is_pending():
			continue
		_cancel_deadline_alarm(attempt)
		_attempts.remove_at(index)


func _has_live_attempt() -> bool:
	for attempt: TicketAttempt in _attempts:
		if attempt.is_pending() or attempt.create_in_flight \
			or attempt.cancel_in_flight or attempt.cleanup_pending:
			return true
	return false


func _ticket_diagnostic(ticket: Variant, terminal_result: Variant = null) -> String:
	var result_diagnostic := _diagnostic(terminal_result)
	var properties: Variant = _object_value(ticket, &"properties", {})
	var property_diagnostic := JSON.stringify(properties) \
		if typeof(properties) == TYPE_DICTIONARY else String(properties)
	if result_diagnostic.is_empty():
		return property_diagnostic
	if property_diagnostic.is_empty() or property_diagnostic == "{}":
		return result_diagnostic
	return "%s | ticket_properties=%s" % [result_diagnostic, property_diagnostic]


func _account_is_current(generation: int) -> bool:
	return Services == null or not Services.has_method("is_current_account") \
		or Services.is_current_account(generation)


func _join_config_recognised() -> bool:
	return ClassDB.class_exists(_JOIN_CONFIG_CLASS) \
		and _class_property_names(_JOIN_CONFIG_CLASS).has(_JOIN_CONFIG_SENTINEL)


func _class_property_names(class_name_value: String) -> Dictionary:
	var names: Dictionary = {}
	if not ClassDB.class_exists(class_name_value):
		return names
	for property: Dictionary in ClassDB.class_get_property_list(class_name_value, false):
		names[String(property.get("name", ""))] = true
	return names


func _class_method_names(class_name_value: String) -> Dictionary:
	var names: Dictionary = {}
	if not ClassDB.class_exists(class_name_value):
		return names
	for method: Dictionary in ClassDB.class_get_method_list(class_name_value, false):
		names[String(method.get("name", ""))] = true
	return names


func _class_signal_names(class_name_value: String) -> Dictionary:
	var names: Dictionary = {}
	if not ClassDB.class_exists(class_name_value):
		return names
	for signal_info: Dictionary in ClassDB.class_get_signal_list(class_name_value, false):
		names[String(signal_info.get("name", ""))] = true
	return names


func _collect_missing_class_properties(
	class_name_value: String,
	required: Array,
	missing: PackedStringArray
) -> void:
	if not ClassDB.class_exists(class_name_value):
		missing.append(class_name_value)
		return
	var present := _class_property_names(class_name_value)
	for property_name: String in required:
		if not present.has(property_name):
			missing.append("%s.%s" % [class_name_value, property_name])


func _collect_missing_class_methods(
	class_name_value: String,
	required: Array,
	missing: PackedStringArray
) -> void:
	if not ClassDB.class_exists(class_name_value):
		if not missing.has(class_name_value):
			missing.append(class_name_value)
		return
	var present := _class_method_names(class_name_value)
	for method_name: String in required:
		if not present.has(method_name):
			missing.append("%s.%s" % [class_name_value, method_name])


func _copy_member_keys(values: Array[Dictionary]) -> Array[Dictionary]:
	var copy: Array[Dictionary] = []
	for value: Dictionary in values:
		copy.append(_copy_entity_key(value))
	return copy


func _copy_entity_key(value: Dictionary) -> Dictionary:
	var entity_id := String(value.get("id", "")).strip_edges()
	var entity_type := String(value.get("type", "")).strip_edges()
	if entity_id.is_empty() or entity_type.is_empty():
		return {}
	return {"id": entity_id, "type": entity_type}


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


func _entity_fingerprint(key: Dictionary) -> String:
	return "%s\u001f%s" % [String(key.get("id", "")), String(key.get("type", ""))]


func _multiplayer() -> Variant:
	var pf: Variant = _playfab()
	if pf == null:
		return null
	if typeof(pf) == TYPE_DICTIONARY:
		return (pf as Dictionary).get("multiplayer")
	return pf.get("multiplayer")


func _playfab() -> Variant:
	return PlatformAccess.playfab()


func _result_ok(result: Variant) -> bool:
	return bool(_object_value(result, &"ok", false))


func _result_data(result: Variant) -> Variant:
	return _object_value(result, &"data", null)


func _diagnostic(result: Variant) -> String:
	if result == null:
		return ""
	var code := String(_object_value(result, &"code", ""))
	var message := String(_object_value(result, &"message", ""))
	var hresult := int(_object_value(result, &"hresult", 0))
	var parts := PackedStringArray()
	if not code.is_empty():
		parts.append(code)
	if hresult != 0:
		parts.append("0x%08X" % (hresult & 0xFFFFFFFF))
	if not message.is_empty():
		parts.append(message)
	return ": ".join(parts)


func _object_value(value: Variant, property: StringName, fallback: Variant) -> Variant:
	if value == null:
		return fallback
	if typeof(value) == TYPE_DICTIONARY:
		return (value as Dictionary).get(property, fallback)
	var resolved: Variant = value.get(property)
	return fallback if resolved == null else resolved


func _now_msec(clock: OnlineFlowClock) -> int:
	return clock.now_msec() if clock != null else Time.get_ticks_msec()


func _sleep_with_clock(clock: OnlineFlowClock, seconds: float) -> void:
	if clock != null:
		await clock.sleep_seconds(seconds)
		return
	var loop := Engine.get_main_loop() as SceneTree
	if loop != null:
		await loop.create_timer(seconds).timeout
