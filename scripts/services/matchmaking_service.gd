class_name MatchmakingService
extends RefCounted

signal cleanup_state_changed()

## PlayFab Matchmaking service boundary.
##
## Quick Match uses this boundary for group tickets, arranged lobbies, deadline ownership and
## cleanup, so every late result affects only the exact attempt that created it.

const QUEUE_NAME := "godotnr_q"
const PROTOCOL_MEMBER_KEY := "nr_protocol"
const SEARCH_TIMEOUT_SECONDS := 600
const QUEUE_MIN_MATCH_SIZE := 2
const QUEUE_MAX_MATCH_SIZE := 4
const SESSION_CAPACITY := 4

const FULL_PARTY_REASON_CODE := &"full_party_queue_max_rejected"
const FULL_PARTY_REASON := "Matchmaking rejected this full four-player ticket."
const FULL_PARTY_GUIDANCE := "Return to the group and ready up to start a private match without searching."
const TICKET_TOO_LARGE_HRESULT := 0x89235652
const E_FAIL_HRESULT := 0x80004005
const E_ABORT_HRESULT := 0x80004004
const SEARCH_TIMEOUT_REASON_CODE := &"search_timeout"
const SEARCH_TIMEOUT_REASON := "Matchmaking timed out before the service found a match."

const _FLOW_IMPLEMENTED := true
const _JOIN_CONFIG_CLASS := "PlayFabLobbyJoinConfig"
const _JOIN_CONFIG_SENTINEL := "member_properties"
const _TICKET_CONFIG_CLASS := "PlayFabMatchmakingTicketConfig"
const _MEMBER_CLASS := "PlayFabMatchmakingMember"
const _TICKET_CLASS := "PlayFabMatchTicket"
const _LOBBY_CONFIG_CLASS := "PlayFabLobbyConfig"
const _LOBBY_UPDATE_CONFIG_CLASS := "PlayFabLobbyUpdateConfig"
const _LOBBY_CLASS := "PlayFabLobby"
const _LOBBY_MEMBER_CLASS := "PlayFabLobbyMember"
const _LOBBY_STATE_CHANGE_CLASS := "PlayFabLobbyStateChange"
const _PARTY_CONFIG_CLASS := "PlayFabPartyConfig"
const _PARTY_NETWORK_CLASS := "PlayFabPartyNetwork"
const _PARTY_NETWORK_CHANGE_CLASS := "PlayFabPartyNetworkStateChange"
const _PARTY_PEER_CLASS := "PlayFabPartyPeer"
const _TICKET_STATE_CHANGE_CLASS := "PlayFabMatchTicketStateChange"
const _RESULT_CLASS := "PlayFabResult"
const _USER_CLASS := "PlayFabUser"

const REQUIRED_JOIN_CONFIG_PROPERTIES := [
	"member_properties",
	"max_member_count",
	"access_policy",
	"owner_migration_policy",
	"restrict_invites_to_lobby_owner",
]
const REQUIRED_LOBBY_CONFIG_PROPERTIES := [
	"max_players",
	"access_policy",
	"owner_migration_policy",
	"search_properties",
	"lobby_properties",
	"member_properties",
	"restrict_invites_to_lobby_owner",
]
const REQUIRED_LOBBY_UPDATE_PROPERTIES := [
	"access_policy",
	"lobby_properties",
	"search_properties",
]
const REQUIRED_LOBBY_PROPERTIES := [
	"lobby_id",
	"connection_string",
	"owner_entity_key",
	"max_member_count",
	"members",
	"properties",
	"search_properties",
	"access_policy",
	"owner_migration_policy",
	"membership_lock",
	"restrict_invites_to_lobby_owner",
]
const REQUIRED_LOBBY_METHODS := [
	"is_disconnected",
	"is_owner",
	"set_properties_async",
	"set_member_properties_async",
	"set_membership_lock_async",
	"post_update_async",
	"leave_async",
]
const REQUIRED_LOBBY_MEMBER_PROPERTIES := [
	"entity_key",
	"properties",
	"connection_status",
]
const REQUIRED_LOBBY_STATE_CHANGE_PROPERTIES := [
	"kind",
	"result",
]
const REQUIRED_PARTY_CONFIG_PROPERTIES := [
	"max_players",
	"invitation_id",
	"enable_voice_chat",
	"enable_text_chat",
	"enable_transcription",
	"enable_translation",
	"direct_peer_connectivity",
]
const REQUIRED_PARTY_NETWORK_PROPERTIES := [
	"descriptor",
	"local_peer",
]
const REQUIRED_PARTY_NETWORK_METHODS := ["leave_async"]
const REQUIRED_PARTY_NETWORK_CHANGE_PROPERTIES := [
	"kind",
	"network",
	"result",
	"peer_id",
	"state",
]
const REQUIRED_PARTY_PEER_METHODS := [
	"get_peer_entity_key",
	"get_connection_status",
	"get_unique_id",
]
const REQUIRED_MATCHMAKING_MEMBER_PROPERTIES := [
	"user",
	"attributes",
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
const REQUIRED_TICKET_STATE_CHANGE_PROPERTIES := ["result"]
const REQUIRED_RESULT_PROPERTIES := [
	"ok",
	"data",
	"hresult",
	"code",
	"message",
]
const REQUIRED_USER_METHODS := ["get_entity_key"]
const REQUIRED_MULTIPLAYER_METHODS := [
	"is_initialized",
	"initialize_async",
	"shutdown_async",
	"create_lobby_async",
	"join_lobby_async",
	"create_match_ticket_async",
	"join_match_ticket_async",
	"join_arranged_lobby_async",
]
const REQUIRED_PARTY_METHODS := [
	"is_initialized",
	"initialize_async",
	"shutdown_async",
	"create_and_join_network_async",
	"join_network_async",
]
const REQUIRED_PLAYFAB_METHODS := ["is_initialized"]
const SAFE_NATIVE_CODES := [
	"match_ticket_create_failed",
	"match_ticket_join_failed",
	"match_ticket_create_start_failed",
	"match_ticket_join_start_failed",
	"match_ticket_cancel_start_failed",
	"match_ticket_completed_failed",
	"match_ticket_create_cancelled",
	"match_ticket_join_cancelled",
	"match_ticket_cancel_lost_race",
	"invalid_match_ticket_config",
	"invalid_match_ticket_member",
	"invalid_join_match_ticket",
	"invalid_match_ticket",
	"invalid_user",
	"lobby_state_finish_failed",
	"matchmaking_state_finish_failed",
	"not_initialized",
	"shutting_down",
	"cancelled",
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
	var capacity := SESSION_CAPACITY
	var deadline_msec := 0
	var ticket_id := ""


class TicketAttempt extends RefCounted:
	signal progress_changed(attempt)
	signal finished(attempt)
	signal cleanup_changed(attempt)
	signal native_terminal_changed(attempt)

	var operation_id := 0
	var multiplayer_epoch := 0
	var account_generation := -1
	var flow_epoch := 0
	var owner := false
	var mode: NRTypes.GameModeType = NRTypes.GameModeType.DEATHMATCH
	var user: Variant = null
	var frozen_members: Array[Dictionary] = []
	var capacity := SESSION_CAPACITY
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
	var native_terminal_notified := false
	var failure_logs: Dictionary = {}

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
		return "Quick Match needs PlayFab addon support for: %s." % \
			", ".join(missing_group_matchmaking_capabilities())
	if not addon_supports_arranged_config():
		return "Quick Match needs arranged-lobby support for: %s." % \
			", ".join(missing_join_config_properties())
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
	if player_count != SESSION_CAPACITY:
		return _profile_failure(
			mode,
			&"profile_count_mismatch",
			player_count)
	return {
		"ok": true,
		"mode": int(mode),
		"capacity": player_count,
		"player_count": player_count,
		"queue_min_match_size": QUEUE_MIN_MATCH_SIZE,
		"queue_max_match_size": QUEUE_MAX_MATCH_SIZE,
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
	if not _class_exists(_JOIN_CONFIG_CLASS):
		for property_name: String in REQUIRED_JOIN_CONFIG_PROPERTIES:
			missing.append("%s.%s" % [_JOIN_CONFIG_CLASS, property_name])
	else:
		var present := _class_property_names(_JOIN_CONFIG_CLASS)
		for property_name: String in REQUIRED_JOIN_CONFIG_PROPERTIES:
			if not present.has(property_name):
				missing.append("%s.%s" % [_JOIN_CONFIG_CLASS, property_name])

	_missing_properties_cache = missing
	_missing_properties_cached = true
	return missing.duplicate()


func missing_group_matchmaking_capabilities() -> PackedStringArray:
	if _missing_group_cached:
		return _missing_group_cache.duplicate()

	var missing := PackedStringArray()
	var playfab: Variant = _playfab()
	if playfab == null:
		missing.append("PlayFab")
	else:
		for method_name: String in REQUIRED_PLAYFAB_METHODS:
			if not _target_has_method(playfab, method_name):
				missing.append("PlayFab.%s" % method_name)

	var multiplayer: Variant = _multiplayer()
	if multiplayer == null:
		missing.append("PlayFabMultiplayer")
	else:
		for method_name: String in REQUIRED_MULTIPLAYER_METHODS:
			if not _target_has_method(multiplayer, method_name):
				missing.append("PlayFabMultiplayer.%s" % method_name)

	var party: Variant = _party_runtime()
	if party == null:
		missing.append("PlayFabParty")
	else:
		for method_name: String in REQUIRED_PARTY_METHODS:
			if not _target_has_method(party, method_name):
				missing.append("PlayFabParty.%s" % method_name)

	_collect_missing_class_properties(_LOBBY_CONFIG_CLASS, REQUIRED_LOBBY_CONFIG_PROPERTIES, missing)
	_collect_missing_class_properties(_LOBBY_UPDATE_CONFIG_CLASS, REQUIRED_LOBBY_UPDATE_PROPERTIES, missing)
	_collect_missing_class_properties(_LOBBY_CLASS, REQUIRED_LOBBY_PROPERTIES, missing)
	_collect_missing_class_methods(_LOBBY_CLASS, REQUIRED_LOBBY_METHODS, missing)
	_collect_missing_class_signals(_LOBBY_CLASS, ["state_changed"], missing)
	_collect_missing_class_properties(_LOBBY_MEMBER_CLASS, REQUIRED_LOBBY_MEMBER_PROPERTIES, missing)
	_collect_missing_class_properties(
		_LOBBY_STATE_CHANGE_CLASS,
		REQUIRED_LOBBY_STATE_CHANGE_PROPERTIES,
		missing)
	_collect_missing_class_properties(_PARTY_CONFIG_CLASS, REQUIRED_PARTY_CONFIG_PROPERTIES, missing)
	_collect_missing_class_properties(_PARTY_NETWORK_CLASS, REQUIRED_PARTY_NETWORK_PROPERTIES, missing)
	_collect_missing_class_methods(_PARTY_NETWORK_CLASS, REQUIRED_PARTY_NETWORK_METHODS, missing)
	_collect_missing_class_signals(_PARTY_NETWORK_CLASS, ["state_changed"], missing)
	_collect_missing_class_properties(
		_PARTY_NETWORK_CHANGE_CLASS,
		REQUIRED_PARTY_NETWORK_CHANGE_PROPERTIES,
		missing)
	_collect_missing_class_methods(_PARTY_PEER_CLASS, REQUIRED_PARTY_PEER_METHODS, missing)
	_collect_missing_class_properties(_TICKET_CONFIG_CLASS, REQUIRED_TICKET_CONFIG_PROPERTIES, missing)
	_collect_missing_class_properties(_TICKET_CLASS, REQUIRED_TICKET_PROPERTIES, missing)
	_collect_missing_class_methods(_TICKET_CLASS, REQUIRED_TICKET_METHODS, missing)
	_collect_missing_class_properties(_MEMBER_CLASS, REQUIRED_MATCHMAKING_MEMBER_PROPERTIES, missing)
	_collect_missing_class_properties(
		_TICKET_STATE_CHANGE_CLASS,
		REQUIRED_TICKET_STATE_CHANGE_PROPERTIES,
		missing)
	_collect_missing_class_properties(_RESULT_CLASS, REQUIRED_RESULT_PROPERTIES, missing)
	_collect_missing_class_methods(_USER_CLASS, REQUIRED_USER_METHODS, missing)
	if _class_exists(_TICKET_CLASS):
		var signals := _class_signal_names(_TICKET_CLASS)
		if not signals.has("state_changed"):
			missing.append("%s.state_changed" % _TICKET_CLASS)

	_missing_group_cache = missing
	_missing_group_cached = true
	return missing.duplicate()


func blocking_dependency() -> String:
	if not addon_supports_group_matchmaking():
		return "The installed PlayFab addon is missing Quick Match capabilities: %s." % \
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
	cleanup_state_changed.emit()
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
	cleanup_state_changed.emit()
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
	cleanup_state_changed.emit()


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
	cleanup_state_changed.emit()


func has_pending_cleanup() -> bool:
	if has_orphaned_matched_cancel():
		return true
	for attempt: TicketAttempt in _attempts:
		if attempt.create_in_flight or attempt.cancel_in_flight or attempt.cleanup_pending \
			or (attempt.retired and attempt.ticket != null and not attempt.native_terminal):
			return true
	return false


func has_orphaned_matched_cancel() -> bool:
	for attempt: TicketAttempt in _attempts:
		if attempt.multiplayer_epoch == _multiplayer_epoch \
			and attempt.native_terminal \
			and attempt.status == STATUS_MATCHED \
			and attempt.cancel_in_flight:
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


static func failure_outcome(
	result: Variant,
	stage: StringName,
	owner: bool,
	member_count: int
) -> Dictionary:
	var base_code := &"matchmaking_failed"
	var base_reason := "Matchmaking failed before a match was found."
	match stage:
		&"create":
			base_code = &"ticket_create_failed"
			base_reason = "Could not create a matchmaking ticket."
		&"join":
			base_code = &"ticket_join_failed"
			base_reason = "Could not join the group's matchmaking ticket."
	var hresult := int(_failure_value(result, &"hresult", 0)) & 0xFFFFFFFF
	if hresult == TICKET_TOO_LARGE_HRESULT:
		if owner and member_count == QUEUE_MAX_MATCH_SIZE:
			return {
				"reason_code": FULL_PARTY_REASON_CODE,
				"reason": FULL_PARTY_REASON,
				"confirmed_full_party": true,
				"cause_available": true,
				"result_present": result != null,
			}
		return {
			"reason_code": &"ticket_group_too_large",
			"reason": "The matchmaking group is too large for this queue.",
			"confirmed_full_party": false,
			"cause_available": true,
			"result_present": result != null,
		}
	var native_code := String(_failure_value(result, &"code", "")).strip_edges()
	var cause_available := _failure_cause_available(
		result, hresult, native_code)
	if not cause_available and owner and member_count == QUEUE_MAX_MATCH_SIZE:
		base_reason = "%s %s" % [base_reason, FULL_PARTY_GUIDANCE]
	return {
		"reason_code": base_code,
		"reason": base_reason,
		"confirmed_full_party": false,
		"cause_available": cause_available,
		"result_present": result != null,
	}


static func _failure_value(
	result: Variant,
	property: StringName,
	fallback: Variant
) -> Variant:
	if result == null:
		return fallback
	if typeof(result) == TYPE_DICTIONARY:
		return (result as Dictionary).get(property, fallback)
	var value: Variant = result.get(property)
	return fallback if value == null else value


static func _failure_cause_available(
	result: Variant,
	hresult: int,
	native_code: String
) -> bool:
	if result == null:
		return false
	var normalized_code := native_code.strip_edges().to_lower()
	if hresult == TICKET_TOO_LARGE_HRESULT:
		return true
	if hresult == E_FAIL_HRESULT \
			and normalized_code in [
				"",
				"match_ticket_create_failed",
				"match_ticket_completed_failed",
				"match_ticket_join_failed",
			]:
		return false
	if normalized_code in SAFE_NATIVE_CODES:
		return true
	return hresult != 0 and hresult != E_FAIL_HRESULT


func _set_cleanup_pending(attempt: TicketAttempt, pending: bool) -> void:
	if attempt == null or attempt.cleanup_pending == pending:
		return
	attempt.cleanup_pending = pending
	attempt.cleanup_changed.emit(attempt)
	cleanup_state_changed.emit()


func _notify_native_terminal(attempt: TicketAttempt) -> void:
	if attempt == null or attempt.native_terminal_notified:
		return
	attempt.native_terminal_notified = true
	attempt.native_terminal_changed.emit(attempt)
	cleanup_state_changed.emit()


func _normalized_hresult(result: Variant) -> int:
	return int(_object_value(result, &"hresult", 0)) & 0xFFFFFFFF


func _cancel_completion_reason(result: Variant) -> StringName:
	var code := String(_object_value(result, &"code", "")).strip_edges().to_lower()
	var hresult := _normalized_hresult(result)
	if code == "cancelled" and hresult == E_ABORT_HRESULT:
		return &"cancel_released_by_reset"
	if code == "match_ticket_cancel_lost_race" \
			and hresult == E_ABORT_HRESULT:
		return &"cancel_lost_race"
	return &"cancel_observer_aborted"


func _log_ticket_failure(
	attempt: TicketAttempt,
	stage: StringName,
	domain_code: StringName,
	result: Variant,
	status: int
) -> void:
	if attempt == null:
		return
	var key := "%s:%s:%d" % [String(stage), String(domain_code), status]
	if attempt.failure_logs.has(key):
		return
	attempt.failure_logs[key] = true
	var native_code := _safe_native_code(
		String(_object_value(result, &"code", "")))
	var hresult := _normalized_hresult(result)
	var evidence := failure_outcome(
		result,
		stage,
		attempt.owner,
		attempt.frozen_members.size())
	var detail := bool(evidence.get("cause_available", false))
	var result_present := bool(evidence.get("result_present", false))
	var cleanup := "pending" if attempt.cleanup_pending \
		or attempt.create_in_flight or attempt.cancel_in_flight else "clear"
	_emit_warning(
		"[Matchmaking] failure stage=%s op=%d epoch=%d reason=%s native_code=%s hresult=0x%08X status=%d group=%d cleanup=%s result_present=%s detail=%s" % [
			String(stage),
			attempt.operation_id,
			attempt.flow_epoch,
			String(domain_code),
			native_code,
			hresult,
			status,
			attempt.frozen_members.size(),
			cleanup,
			result_present,
			"available" if detail else "unavailable",
		])


func _safe_native_code(code: String) -> String:
	var normalized := code.strip_edges().to_lower()
	return normalized if normalized in SAFE_NATIVE_CODES else "unavailable"


func _emit_warning(message: String) -> void:
	push_warning(message)


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
	attempt.capacity = spec.capacity
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
	if attempt.capacity != int(profile.get("capacity", 0)) \
		or attempt.capacity != SESSION_CAPACITY:
		return _validation_failure(
		"The matchmaking request does not match the configured capacity-four profile.",
			&"profile_request_mismatch")
	if attempt.frozen_members.size() < 1 \
		or attempt.frozen_members.size() > attempt.capacity:
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
	if not addon_supports_arranged_config():
		return blocking_dependency()
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
		"capacity": player_count,
		"player_count": player_count,
		"queue_min_match_size": QUEUE_MIN_MATCH_SIZE,
		"queue_max_match_size": QUEUE_MAX_MATCH_SIZE,
		"reason_code": String(code),
		"reason": "Quick Match needs the capacity-four Deathmatch settings.",
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
			"The PlayFab matchmaking ticket configuration is unavailable.", null, &"create")
		return

	var multiplayer: Variant = _multiplayer()
	if multiplayer == null:
		attempt.create_in_flight = false
		_finish_failed(attempt, &"matchmaking_unavailable",
			"The PlayFab matchmaking service is unavailable.", null, &"create")
		return

	# A full group normally starts without matchmaking. Keep this service-boundary
	# classification for any maximum-sized ticket that still reaches the queue.
	# Microsoft Learn, "Configuring matchmaking queues":
	# "If a ticket already meets the maximum requirement for a match, however, it is rejected."
	# godotnr_q has MaxMatchSize = 4, so this remains a matchmaking failure rather than
	# a signal to choose a different route after the request has already been submitted.
	var result: Variant = await multiplayer.create_match_ticket_async(attempt.user, config)
	attempt.create_in_flight = false
	cleanup_state_changed.emit()
	if not _attempt_epoch_current(attempt):
		_prune_attempts()
		return
	if attempt.retired or not attempt.is_pending() \
		or not _account_is_current(attempt.account_generation):
		_cleanup_late_result(attempt, result)
		return
	if not _result_ok(result):
		if _observe_result_ticket(attempt, result, &"create"):
			return
		if _result_code(result) == "match_ticket_create_cancelled":
			_finish_cancelled(attempt)
			return
		_finish_create_failure(attempt, result)
		return
	var ticket: Variant = _result_data(result)
	if ticket == null:
		_finish_failed(attempt, &"ticket_missing",
			"The match service returned no matchmaking ticket.", result, &"create")
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
			"The PlayFab matchmaking service is unavailable.", null, &"join")
		return
	var local_member: Variant = _make_local_member(attempt.user)
	if local_member == null:
		attempt.create_in_flight = false
		_finish_failed(attempt, &"ticket_member_unavailable",
			"The local matchmaking member could not be created.", null, &"join")
		return
	var result: Variant = await multiplayer.join_match_ticket_async(
		attempt.user,
		attempt.ticket_id,
		_queue_name(),
		[local_member])
	attempt.create_in_flight = false
	cleanup_state_changed.emit()
	if not _attempt_epoch_current(attempt):
		_prune_attempts()
		return
	if attempt.retired or not attempt.is_pending() \
		or not _account_is_current(attempt.account_generation):
		_cleanup_late_result(attempt, result)
		return
	if not _result_ok(result):
		if _observe_result_ticket(attempt, result, &"join"):
			return
		_finish_failed(attempt, &"ticket_join_failed",
			"Could not join the group's matchmaking ticket.", result, &"join")
		return
	var ticket: Variant = _result_data(result)
	if ticket == null:
		_finish_failed(attempt, &"ticket_missing",
			"The match service returned no matchmaking ticket.", result, &"join")
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
	var observed := _observe_terminal_snapshot(
		attempt,
		terminal_result,
		attempt.ticket,
		&"terminal")
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
	terminal_result: Variant = null,
	ticket_snapshot: Variant = null,
	failure_stage: StringName = &"terminal"
) -> Dictionary:
	if attempt == null:
		return {"terminal": false, "changed": false, "status": -1}
	var ticket: Variant = ticket_snapshot if ticket_snapshot != null else attempt.ticket
	if ticket == null:
		return {"terminal": false, "changed": false, "status": -1}
	var status := int(_object_value(ticket, &"status", -1))
	var ticket_id := String(_object_value(ticket, &"ticket_id", attempt.ticket_id))
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
			attempt.match_id = String(_object_value(ticket, &"match_id", ""))
			attempt.arrangement = String(_object_value(
				ticket, &"arranged_lobby_connection_string", ""))
			attempt.native_terminal = true
			_cancel_deadline_alarm(attempt)
			if attempt.cancel_in_flight:
				cleanup_state_changed.emit()
			else:
				_finalize_matched_terminal(attempt)
		STATUS_CANCELLED:
			attempt.native_terminal = true
			_cancel_deadline_alarm(attempt)
			_notify_native_terminal(attempt)
			if attempt.is_pending():
				attempt.settle(Outcome.CANCELLED)
			_complete_native_cleanup(attempt)
		STATUS_FAILED:
			var diagnostic := _ticket_diagnostic(ticket, terminal_result)
			attempt.native_terminal = true
			_cancel_deadline_alarm(attempt)
			var failure := failure_outcome(
				terminal_result,
				failure_stage,
				attempt.owner,
				attempt.frozen_members.size())
			var failure_code := StringName(failure.get(
				"reason_code", &"matchmaking_failed"))
			var failure_reason := String(failure.get(
				"reason", "Matchmaking failed before a match was found."))
			_log_ticket_failure(
				attempt, failure_stage, failure_code, terminal_result, status)
			_notify_native_terminal(attempt)
			if attempt.is_pending():
				attempt.settle(
					Outcome.FAILED,
					failure_code,
					failure_reason,
					diagnostic)
			elif not diagnostic.is_empty():
				attempt.diagnostic = diagnostic if attempt.diagnostic.is_empty() \
					else "%s | terminal=%s" % [attempt.diagnostic, diagnostic]
			_complete_native_cleanup(attempt)
	return {"terminal": true, "changed": changed, "status": status}


func _finalize_matched_terminal(attempt: TicketAttempt) -> void:
	if attempt == null or not attempt.native_terminal:
		return
	_notify_native_terminal(attempt)
	if attempt.is_pending():
		attempt.settle(Outcome.MATCHED)
	_complete_native_cleanup(attempt)


func _complete_native_cleanup(attempt: TicketAttempt) -> void:
	if attempt == null or not attempt.native_terminal:
		return
	_disconnect_ticket(attempt)
	_cancel_deadline_alarm(attempt)
	attempt.ticket = null
	_set_cleanup_pending(attempt, attempt.cancel_in_flight)
	_prune_attempts()


func _cancel_ticket(attempt: TicketAttempt) -> void:
	if attempt == null or attempt.ticket == null or attempt.cancel_in_flight \
		or not _attempt_epoch_current(attempt):
		return
	if bool(_observe_terminal_snapshot(
		attempt, null, attempt.ticket, &"terminal").get("terminal", false)):
		return
	var captured_ticket: Variant = attempt.ticket
	attempt.cancel_in_flight = true
	_set_cleanup_pending(attempt, true)
	var result: Variant = await captured_ticket.cancel_async()
	attempt.cancel_in_flight = false
	cleanup_state_changed.emit()
	if not _attempt_epoch_current(attempt):
		_prune_attempts()
		return
	var result_ticket: Variant = _ticket_snapshot_from_result(result)
	var snapshot: Variant = result_ticket if result_ticket != null else captured_ticket
	if snapshot != null:
		_observe_terminal_snapshot(attempt, result, snapshot, &"terminal")
	var result_code := _result_code(result)
	if result_code == "invalid_match_ticket" and attempt.native_terminal:
		_complete_native_cleanup(attempt)
		return
	if attempt.native_terminal:
		if not _result_ok(result) and attempt.status == STATUS_MATCHED:
			_log_ticket_failure(
				attempt,
				&"cancel",
				_cancel_completion_reason(result),
				result,
				attempt.status)
		_complete_native_cleanup(attempt)
		return
	if not _result_ok(result):
		var diagnostic := _diagnostic(result)
		if attempt.is_pending():
			_cancel_deadline_alarm(attempt)
			_log_ticket_failure(
				attempt, &"cancel", &"cancel_unconfirmed", result, attempt.status)
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
			_log_ticket_failure(
				attempt, &"cancel", &"cancel_unconfirmed", result, attempt.status)
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
	_log_ticket_failure(
		attempt,
		&"timeout",
		SEARCH_TIMEOUT_REASON_CODE,
		null,
		attempt.status)
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
	var ticket: Variant = _ticket_snapshot_from_result(result)
	if ticket != null:
		var observed := _observe_terminal_snapshot(
			attempt,
			result,
			ticket,
			&"join" if not attempt.owner else &"create")
		if bool(observed.get("terminal", false)):
			_prune_attempts()
			return
	if _result_code(result) == "match_ticket_create_cancelled":
		_finish_cancelled(attempt)
		return
	if _result_ok(result):
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


func _finish_cancelled(attempt: TicketAttempt) -> void:
	if attempt == null:
		return
	attempt.status = STATUS_CANCELLED
	attempt.native_terminal = true
	_cancel_deadline_alarm(attempt)
	_notify_native_terminal(attempt)
	if attempt.is_pending():
		attempt.settle(Outcome.CANCELLED)
	_complete_native_cleanup(attempt)


func _finish_create_failure(attempt: TicketAttempt, result: Variant) -> void:
	var failure := failure_outcome(
		result,
		&"create",
		attempt.owner,
		attempt.frozen_members.size())
	_finish_failed(
		attempt,
		StringName(failure.get("reason_code", &"ticket_create_failed")),
		String(failure.get("reason", "Could not create a matchmaking ticket.")),
		result,
		&"create")


func _finish_failed(
	attempt: TicketAttempt,
	code: StringName,
	message: String,
	result: Variant,
	stage: StringName = &"failure"
) -> void:
	_cancel_deadline_alarm(attempt)
	if attempt.ticket == null and not attempt.create_in_flight and not attempt.cancel_in_flight:
		attempt.native_terminal = true
		_set_cleanup_pending(attempt, false)
	_log_ticket_failure(attempt, stage, code, result, attempt.status)
	attempt.settle(Outcome.FAILED, code, message, _diagnostic(result))
	_prune_attempts()


func _prune_attempts() -> void:
	var removed := false
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
		removed = true
	if removed:
		cleanup_state_changed.emit()


func _has_live_attempt() -> bool:
	for attempt: TicketAttempt in _attempts:
		if attempt.is_pending() or attempt.create_in_flight \
			or attempt.cancel_in_flight or attempt.cleanup_pending:
			return true
	return false


func _ticket_diagnostic(ticket: Variant, terminal_result: Variant = null) -> String:
	var result_diagnostic := _diagnostic(terminal_result)
	var properties: Variant = _object_value(ticket, &"properties", {}) \
		if _object_has_property(ticket, &"properties") else {}
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
	return _class_exists(_JOIN_CONFIG_CLASS) \
		and _class_property_names(_JOIN_CONFIG_CLASS).has(_JOIN_CONFIG_SENTINEL)


func _class_exists(class_name_value: String) -> bool:
	return ClassDB.class_exists(class_name_value)


func _class_property_names(class_name_value: String) -> Dictionary:
	var names: Dictionary = {}
	if not _class_exists(class_name_value):
		return names
	for property: Dictionary in ClassDB.class_get_property_list(class_name_value, false):
		names[String(property.get("name", ""))] = true
	return names


func _class_method_names(class_name_value: String) -> Dictionary:
	var names: Dictionary = {}
	if not _class_exists(class_name_value):
		return names
	for method: Dictionary in ClassDB.class_get_method_list(class_name_value, false):
		names[String(method.get("name", ""))] = true
	return names


func _class_signal_names(class_name_value: String) -> Dictionary:
	var names: Dictionary = {}
	if not _class_exists(class_name_value):
		return names
	for signal_info: Dictionary in ClassDB.class_get_signal_list(class_name_value, false):
		names[String(signal_info.get("name", ""))] = true
	return names


func _collect_missing_class_properties(
	class_name_value: String,
	required: Array,
	missing: PackedStringArray
) -> void:
	if not _class_exists(class_name_value):
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
	if not _class_exists(class_name_value):
		if not missing.has(class_name_value):
			missing.append(class_name_value)
		return
	var present := _class_method_names(class_name_value)
	for method_name: String in required:
		if not present.has(method_name):
			missing.append("%s.%s" % [class_name_value, method_name])


func _collect_missing_class_signals(
	class_name_value: String,
	required: Array,
	missing: PackedStringArray
) -> void:
	if not _class_exists(class_name_value):
		if not missing.has(class_name_value):
			missing.append(class_name_value)
		return
	var present := _class_signal_names(class_name_value)
	for signal_name: String in required:
		if not present.has(signal_name):
			missing.append("%s.%s" % [class_name_value, signal_name])


func _target_has_method(target: Variant, method_name: String) -> bool:
	return target is Object and target.has_method(method_name)


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


func _party_runtime() -> Variant:
	var pf: Variant = _playfab()
	if pf == null:
		return null
	if typeof(pf) == TYPE_DICTIONARY:
		return (pf as Dictionary).get("party")
	return pf.get("party")


func _playfab() -> Variant:
	return PlatformAccess.playfab()


func _result_ok(result: Variant) -> bool:
	return bool(_object_value(result, &"ok", false))


func _result_data(result: Variant) -> Variant:
	return _object_value(result, &"data", null)


func _result_code(result: Variant) -> String:
	return String(_object_value(result, &"code", "")).strip_edges().to_lower()


func _observe_result_ticket(
	attempt: TicketAttempt,
	result: Variant,
	failure_stage: StringName
) -> bool:
	var ticket: Variant = _ticket_snapshot_from_result(result)
	if ticket == null:
		return false
	var observed := _observe_terminal_snapshot(
		attempt,
		result,
		ticket,
		failure_stage)
	return bool(observed.get("terminal", false))


func _ticket_snapshot_from_result(result: Variant) -> Variant:
	var data: Variant = _result_data(result)
	if not (data is Object) or not _object_has_property(data, &"status") \
		or not _object_has_property(data, &"ticket_id"):
		return null
	return data


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


func _object_has_property(value: Variant, property: StringName) -> bool:
	if value == null:
		return false
	if typeof(value) == TYPE_DICTIONARY:
		return (value as Dictionary).has(property)
	for property_info: Dictionary in value.get_property_list():
		if StringName(property_info.get("name", "")) == property:
			return true
	return false


func _now_msec(clock: OnlineFlowClock) -> int:
	return clock.now_msec() if clock != null else Time.get_ticks_msec()


func _sleep_with_clock(clock: OnlineFlowClock, seconds: float) -> void:
	if clock != null:
		await clock.sleep_seconds(seconds)
		return
	var loop := Engine.get_main_loop() as SceneTree
	if loop != null:
		await loop.create_timer(seconds).timeout
