extends RefCounted


class Results extends RefCounted:
	const E_FAIL := -2147467259
	const E_ABORT := -2147467260
	const E_INVALIDARG := -2147024809

	static func make(
		ok: bool,
		data: Variant = null,
		code: String = "ok",
		message: String = "Injected result.",
		hresult: int = 0x7FFFFFFFFFFFFFFF
	) -> Dictionary:
		return {
			"ok": ok,
			"data": data,
			"code": code,
			"message": message,
			"hresult": (0 if ok else -2147467259) \
				if hresult == 0x7FFFFFFFFFFFFFFF else hresult,
		}

	static func match_ticket_create_cancelled(
		properties: Dictionary = {}
	) -> Dictionary:
		return make(
			false,
			properties.duplicate(true),
			"match_ticket_create_cancelled",
			"Injected ticket creation was cancelled.",
			E_ABORT)

	static func match_ticket_join_cancelled(ticket: Variant) -> Dictionary:
		return make(
			false,
			ticket,
			"match_ticket_join_cancelled",
			"Injected ticket join was cancelled.",
			E_ABORT)

	static func match_ticket_completed_failed(
		ticket: Variant,
		hresult: int = E_FAIL
	) -> Dictionary:
		return make(
			false,
			ticket,
			"match_ticket_completed_failed",
			"Injected ticket terminal failure.",
			hresult)

	static func match_ticket_create_failed(
		properties: Dictionary = {},
		hresult: int = E_FAIL
	) -> Dictionary:
		return make(
			false,
			properties.duplicate(true),
			"match_ticket_create_failed",
			"Injected ticket creation failure.",
			hresult)

	static func match_ticket_cancel_lost_race(ticket: Variant) -> Dictionary:
		return make(
			false,
			ticket,
			"match_ticket_cancel_lost_race",
			"Injected match completed before cancellation.",
			E_ABORT)

	static func invalid_match_ticket() -> Dictionary:
		return make(
			false,
			null,
			"invalid_match_ticket",
			"Injected ticket is already terminal.",
			E_INVALIDARG)

	static func cancelled_by_shutdown() -> Dictionary:
		return make(
			false,
			null,
			"cancelled",
			"Injected runtime invalidation.",
			E_ABORT)


class Clock extends OnlineFlowClock:
	signal advanced()
	var now := 0

	func now_msec() -> int:
		return now

	func sleep_seconds(seconds: float) -> void:
		var wake_at := now + int(round(maxf(seconds, 0.0) * 1000.0))
		while now < wake_at:
			await advanced

	func _drives_alarms_by_engine() -> bool:
		return false

	func advance(seconds: float) -> void:
		now += int(round(maxf(seconds, 0.0) * 1000.0))
		fire_due_alarms()
		advanced.emit()

	func pending_sleepers() -> int:
		return advanced.get_connections().size()


class User extends RefCounted:
	var entity_key: Dictionary

	func _init(entity_id: String) -> void:
		entity_key = {"id": entity_id, "type": "title_player_account"}

	func get_entity_key() -> Dictionary:
		return entity_key.duplicate()


class Config extends RefCounted:
	var queue_name := ""
	var timeout_seconds := 0
	var members: Array = []
	var members_to_match_with: Array = []
	var max_players := 0
	var max_member_count := 0
	var access_policy := 0
	var owner_migration_policy := 0
	var restrict_invites_to_lobby_owner := false
	var search_properties: Dictionary = {}
	var lobby_properties: Dictionary = {}
	var member_properties: Dictionary = {}
	var membership_lock := 0
	var filter := ""
	var max_results := 0
	var invitation_id := ""
	var enable_voice_chat := false
	var enable_text_chat := false
	var enable_transcription := false
	var enable_translation := false
	var direct_peer_connectivity := 0


class LobbyUpdateConfig extends RefCounted:
	var present: Dictionary = {}
	var _access_policy := -1
	var _lobby_properties: Dictionary = {}
	var _search_properties: Dictionary = {}

	var access_policy: int:
		get:
			return _access_policy
		set(value):
			_access_policy = value
			present["access_policy"] = true

	var lobby_properties: Dictionary:
		get:
			return _lobby_properties
		set(value):
			_lobby_properties = value.duplicate(true)
			present["lobby_properties"] = true

	var search_properties: Dictionary:
		get:
			return _search_properties
		set(value):
			_search_properties = value.duplicate(true)
			present["search_properties"] = true

	func has_field(field: String) -> bool:
		return present.has(field)


class MatchmakingMember extends RefCounted:
	var user: Variant = null
	var attributes: Dictionary = {}


class Change extends RefCounted:
	var kind := 0
	var state := 0
	var peer_id := 0
	var reason := ""
	var result: Variant = null
	var network: Variant = null


class ChangeWithoutReason extends RefCounted:
	var kind := 0
	var state := 0
	var peer_id := 0
	var result: Variant = null
	var network: Variant = null


class Ticket extends RefCounted:
	signal state_changed(change: Variant)
	signal cancel_released()
	var ticket_id := "ticket-1"
	var status := MatchmakingService.STATUS_WAITING_FOR_PLAYERS
	var match_id := ""
	var arranged_lobby_connection_string := ""
	var properties: Dictionary = {}
	var completion_received := false
	var native_destroyed := false
	var terminal_event_count := 0
	var terminal_delivery_order: StringName = &"completion_first"
	var cancel_calls := 0
	var cancel_fault_unanswered := false
	var cancel_fault_result: Variant = null
	var cancel_terminal_before_start_status := -1
	var runtime_invalidated := false
	var cancel_waiting := false
	var _cancel_started := false
	var _cancel_completed := false
	var _cancel_result: Variant = null
	var _cancel_result_ticket: WeakRef = null
	var _cancel_waiter_count := 0

	func is_complete() -> bool:
		return status >= MatchmakingService.STATUS_MATCHED

	func cancel_async() -> Dictionary:
		if runtime_invalidated or completion_received or native_destroyed:
			return Results.invalid_match_ticket()
		if not _cancel_started:
			if cancel_terminal_before_start_status \
					>= MatchmakingService.STATUS_MATCHED:
				_apply_terminal_snapshot(cancel_terminal_before_start_status)
				completion_received = true
				native_destroyed = true
				return Results.invalid_match_ticket()
			_cancel_started = true
			if not is_complete():
				cancel_calls += 1
		if _cancel_completed:
			return _materialize_cancel_result()
		_cancel_waiter_count += 1
		cancel_waiting = true
		await cancel_released
		return _consume_cancel_result()

	func emit_status(next_status: int, result: Variant = null) -> void:
		if next_status >= MatchmakingService.STATUS_MATCHED:
			publish_terminal(next_status, result)
			return
		publish_nonterminal(next_status)

	func publish_nonterminal(next_status: int) -> void:
		if runtime_invalidated or native_destroyed or completion_received:
			return
		status = next_status
		var change := Change.new()
		change.result = Results.make(true, self)
		state_changed.emit(change)

	func publish_terminal(
		next_status: int,
		terminal_result: Variant = null
	) -> void:
		if runtime_invalidated or native_destroyed or completion_received:
			return
		_apply_terminal_snapshot(next_status)
		var result: Variant = terminal_result \
			if terminal_result != null else _default_terminal_result()
		completion_received = true
		if terminal_delivery_order == &"event_first":
			_emit_terminal(result)
			_complete_cancel_for_terminal(result)
		else:
			_complete_cancel_for_terminal(result)
			_emit_terminal(result)
		native_destroyed = true

	func prime_terminal_snapshot(
		next_status: int,
		_terminal_result: Variant = null
	) -> void:
		if runtime_invalidated or native_destroyed or completion_received:
			return
		_apply_terminal_snapshot(next_status)
		completion_received = true
		native_destroyed = true

	func invalidate_runtime() -> void:
		runtime_invalidated = true
		native_destroyed = true
		if _cancel_started and not _cancel_completed:
			_complete_cancel(Results.cancelled_by_shutdown())

	func release_cancel(result: Variant) -> void:
		if _cancel_started and not _cancel_completed:
			_complete_cancel(result)

	func _apply_terminal_snapshot(next_status: int) -> void:
		status = next_status

	func _default_terminal_result() -> Dictionary:
		match status:
			MatchmakingService.STATUS_FAILED:
				return Results.match_ticket_completed_failed(self)
			_:
				return Results.make(true, self)

	func _emit_terminal(result: Variant) -> void:
		terminal_event_count += 1
		var change := Change.new()
		change.result = result
		state_changed.emit(change)

	func _complete_cancel_for_terminal(terminal_result: Variant) -> void:
		if not _cancel_started or _cancel_completed or cancel_fault_unanswered:
			return
		if cancel_fault_result != null:
			var fault_result: Variant = cancel_fault_result
			cancel_fault_result = null
			_complete_cancel(fault_result)
			return
		match status:
			MatchmakingService.STATUS_CANCELLED:
				_complete_cancel(Results.make(true))
			MatchmakingService.STATUS_MATCHED:
				_complete_cancel(Results.match_ticket_cancel_lost_race(self))
			MatchmakingService.STATUS_FAILED:
				_complete_cancel(terminal_result)

	func _complete_cancel(result: Variant) -> void:
		_store_cancel_result(result)
		_cancel_completed = true
		cancel_released.emit()
		if _cancel_waiter_count == 0:
			_clear_cancel_result()

	func _consume_cancel_result() -> Variant:
		var result: Variant = _materialize_cancel_result()
		var code := String((result as Dictionary).get("code", "")) \
			if typeof(result) == TYPE_DICTIONARY else ""
		_cancel_waiter_count = maxi(_cancel_waiter_count - 1, 0)
		cancel_waiting = _cancel_waiter_count > 0
		if _cancel_waiter_count == 0:
			_clear_cancel_result()
		if code == "match_ticket_cancel_start_failed" \
				or (
					not completion_received
					and not runtime_invalidated
					and not native_destroyed
				):
			_cancel_started = false
			_cancel_completed = false
		return result

	func _store_cancel_result(result: Variant) -> void:
		_cancel_result_ticket = null
		if typeof(result) != TYPE_DICTIONARY:
			_cancel_result = result
			return
		var stored := (result as Dictionary).duplicate(true)
		if stored.get("data") == self:
			_cancel_result_ticket = weakref(self)
			stored["data"] = null
		_cancel_result = stored

	func _materialize_cancel_result() -> Variant:
		if typeof(_cancel_result) != TYPE_DICTIONARY:
			return _cancel_result
		var result := (_cancel_result as Dictionary).duplicate(true)
		if _cancel_result_ticket != null:
			result["data"] = _cancel_result_ticket.get_ref()
		return result

	func _clear_cancel_result() -> void:
		_cancel_result = null
		_cancel_result_ticket = null

	func has_retained_cancel_result() -> bool:
		return _cancel_result != null or _cancel_result_ticket != null


class TicketWithoutProperties extends RefCounted:
	signal state_changed(change: Variant)
	var ticket_id := "ticket-without-properties"
	var status := MatchmakingService.STATUS_WAITING_FOR_PLAYERS
	var match_id := ""
	var arranged_lobby_connection_string := ""

	func cancel_async() -> Dictionary:
		status = MatchmakingService.STATUS_CANCELLED
		state_changed.emit(Change.new())
		return Results.make(true, self, "cancelled")

	func emit_status(next_status: int, result: Variant = null) -> void:
		status = next_status
		var change := Change.new()
		change.result = result
		state_changed.emit(change)


class MatchmakingSDK extends RefCounted:
	signal create_released()
	signal join_released()
	var create_calls: Array[Dictionary] = []
	var join_calls: Array[Dictionary] = []
	var queued_create_results: Array = []
	var queued_join_results: Array = []
	var block_create := false
	var block_join := false
	var tracked_tickets: Array[Ticket] = []

	func create_match_ticket_async(user: Variant, config: Variant) -> Dictionary:
		create_calls.append({
			"user": user,
			"queue_name": String(config.queue_name),
			"timeout_seconds": int(config.timeout_seconds),
			"members": config.members.duplicate(),
			"members_to_match_with": config.members_to_match_with.duplicate(true),
		})
		if block_create:
			await create_released
		var result: Dictionary
		if not queued_create_results.is_empty():
			result = queued_create_results.pop_front()
		else:
			result = Results.make(true, Ticket.new())
		_track_ticket(result)
		return result

	func join_match_ticket_async(
		user: Variant,
		ticket_id: String,
		queue_name: String,
		local_members: Array
	) -> Dictionary:
		join_calls.append({
			"user": user,
			"ticket_id": ticket_id,
			"queue_name": queue_name,
			"local_members": local_members.duplicate(),
		})
		if block_join:
			await join_released
		var result: Dictionary
		if not queued_join_results.is_empty():
			result = queued_join_results.pop_front()
		else:
			var ticket := Ticket.new()
			ticket.ticket_id = ticket_id
			ticket.status = MatchmakingService.STATUS_WAITING_FOR_MATCH
			result = Results.make(true, ticket)
		_track_ticket(result)
		return result

	func join_arranged_lobby_async(
		_user: Variant,
		_arrangement: String,
		_config: Variant
	) -> Dictionary:
		return Results.make(false, null, "not_used")

	func invalidate_runtime() -> void:
		for ticket: Ticket in tracked_tickets:
			ticket.invalidate_runtime()

	func pending_cancel_waiters() -> int:
		var count := 0
		for ticket: Ticket in tracked_tickets:
			if ticket.cancel_waiting:
				count += 1
		return count

	func retained_cancel_results() -> int:
		var count := 0
		for ticket: Ticket in tracked_tickets:
			if ticket.has_retained_cancel_result():
				count += 1
		return count

	func _track_ticket(result: Dictionary) -> void:
		var data: Variant = result.get("data")
		if data is Ticket and not tracked_tickets.has(data):
			tracked_tickets.append(data)


class Matchmaking extends MatchmakingService:
	static var test_instances: Array[WeakRef] = []

	var sdk := MatchmakingSDK.new()
	var fake_flow_implemented := true
	var fake_account_current := true
	var fake_mode_config: GameModeConfig = null
	var fake_queue_name := MatchmakingService.QUEUE_NAME
	var fake_playfab_present := true
	var fake_group_support := true
	var fake_arranged_support := true
	var fake_warnings: Array[String] = []

	func _init() -> void:
		test_instances.append(weakref(self))
		var config := GameModeConfig.new()
		config.mode_type = NRTypes.GameModeType.DEATHMATCH
		config.player_count = 4
		fake_mode_config = config

	func _flow_implemented() -> bool:
		return fake_flow_implemented

	func _game_mode_config(_mode: NRTypes.GameModeType) -> Variant:
		return fake_mode_config

	func _queue_name() -> String:
		return fake_queue_name

	func _playfab() -> Variant:
		return {"multiplayer": sdk} if fake_playfab_present else null

	func addon_supports_group_matchmaking() -> bool:
		return fake_group_support

	func addon_supports_arranged_config() -> bool:
		return fake_arranged_support

	func missing_group_matchmaking_capabilities() -> PackedStringArray:
		return PackedStringArray() if fake_group_support \
			else PackedStringArray(["injected_group_capability"])

	func missing_join_config_properties() -> PackedStringArray:
		return PackedStringArray() if fake_arranged_support \
			else PackedStringArray(["injected_arranged_capability"])

	func _multiplayer() -> Variant:
		return sdk

	func _account_is_current(_generation: int) -> bool:
		return fake_account_current

	func _new_ticket_config() -> Variant:
		return Config.new()

	func _new_matchmaking_member() -> Variant:
		return MatchmakingMember.new()

	func _emit_warning(message: String) -> void:
		fake_warnings.append(message)

	func multiplayer_invalidated(recovery_epoch: int) -> void:
		sdk.invalidate_runtime()
		super.multiplayer_invalidated(recovery_epoch)

	static func orphan_report() -> PackedStringArray:
		var report := PackedStringArray()
		for index in range(test_instances.size() - 1, -1, -1):
			var service: Matchmaking = \
				test_instances[index].get_ref() as Matchmaking
			if service == null:
				test_instances.remove_at(index)
				continue
			var alarms := service._clock.armed_alarm_count() \
				if service._clock != null else 0
			var waiters := service.sdk.pending_cancel_waiters()
			var retained := service.sdk.retained_cancel_results()
			if alarms > 0 or waiters > 0 or retained > 0 \
					or service.has_pending_cleanup():
				report.append(
					"instance=%d alarms=%d waiters=%d retained=%d cleanup=%s attempts=%d" % [
						service.get_instance_id(),
						alarms,
						waiters,
						retained,
						service.has_pending_cleanup(),
						service._attempts.size(),
					])
		return report

	static func invalidate_test_instances() -> void:
		for reference: WeakRef in test_instances:
			var service: Matchmaking = reference.get_ref() as Matchmaking
			if service != null:
				service.multiplayer_invalidated(service._multiplayer_epoch + 1)

	static func clear_test_instances() -> void:
		test_instances.clear()


class SurfaceRuntime extends RefCounted:
	var create_match_calls := 0
	func is_initialized() -> bool:
		return true

	func initialize_async(_config: Variant = null, _port: int = 0) -> Dictionary:
		return Results.make(true)

	func shutdown_async() -> Dictionary:
		return Results.make(true)

	func create_lobby_async(_user: Variant, _config: Variant) -> Dictionary:
		return Results.make(true)

	func join_lobby_async(_user: Variant, _connection: String, _config: Variant) -> Dictionary:
		return Results.make(true)

	func find_lobbies_async(_user: Variant, _config: Variant) -> Dictionary:
		return Results.make(true)

	func create_match_ticket_async(_user: Variant, _config: Variant) -> Dictionary:
		create_match_calls += 1
		return Results.make(true)

	func join_match_ticket_async(
		_user: Variant,
		_ticket_id: String,
		_queue: String,
		_members: Array
	) -> Dictionary:
		return Results.make(true)

	func join_arranged_lobby_async(
		_user: Variant,
		_arrangement: String,
		_config: Variant
	) -> Dictionary:
		return Results.make(true)

	func create_and_join_network_async(_user: Variant, _config: Variant) -> Dictionary:
		return Results.make(true)

	func join_network_async(
		_user: Variant,
		_descriptor: String,
		_config: Variant
	) -> Dictionary:
		return Results.make(true)


class SurfaceMatchmaking extends MatchmakingService:
	const OPTIONAL_SURFACE_PROPERTIES := {
		"PlayFabLobbySearchConfig": ["filter", "max_results"],
		"PlayFabLobbySummary": [
			"connection_string",
			"member_count",
			"max_member_count",
		],
		"PlayFabLobbySearchResult": ["lobbies"],
	}
	const OPTIONAL_SEARCH_CLASSES := [
		"PlayFabLobbySearchConfig",
		"PlayFabLobbySummary",
		"PlayFabLobbySearchResult",
	]

	var root := SurfaceRuntime.new()
	var multiplayer := SurfaceRuntime.new()
	var party := SurfaceRuntime.new()
	var fake_mode_config: GameModeConfig = null
	var missing_surface := ""
	var missing_class := ""
	var join_alias_only := false

	func _init() -> void:
		var config := GameModeConfig.new()
		config.mode_type = NRTypes.GameModeType.DEATHMATCH
		config.player_count = 4
		fake_mode_config = config

	func _game_mode_config(_mode: NRTypes.GameModeType) -> Variant:
		return fake_mode_config

	func _playfab() -> Variant:
		return root

	func _multiplayer() -> Variant:
		return multiplayer

	func _party_runtime() -> Variant:
		return party

	func _class_exists(class_name_value: String) -> bool:
		if class_name_value == missing_class:
			return false
		return not _surface_properties(class_name_value).is_empty() \
			or not _surface_methods(class_name_value).is_empty() \
			or not _surface_signals(class_name_value).is_empty()

	func _class_property_names(class_name_value: String) -> Dictionary:
		var names := _names_dictionary(_surface_properties(class_name_value))
		if join_alias_only and class_name_value == "PlayFabLobbyJoinConfig":
			names.erase("max_member_count")
			names["max_players"] = true
		_remove_missing_surface(names, class_name_value)
		return names

	func _class_method_names(class_name_value: String) -> Dictionary:
		var names := _names_dictionary(_surface_methods(class_name_value))
		_remove_missing_surface(names, class_name_value)
		return names

	func _class_signal_names(class_name_value: String) -> Dictionary:
		var names := _names_dictionary(_surface_signals(class_name_value))
		_remove_missing_surface(names, class_name_value)
		return names

	func _target_has_method(target: Variant, method_name: String) -> bool:
		var owner := ""
		if target == root:
			owner = "PlayFab"
		elif target == multiplayer:
			owner = "PlayFabMultiplayer"
		elif target == party:
			owner = "PlayFabParty"
		if missing_surface == "%s.%s" % [owner, method_name]:
			return false
		return super._target_has_method(target, method_name)

	func _remove_missing_surface(names: Dictionary, class_name_value: String) -> void:
		var prefix := class_name_value + "."
		if missing_surface.begins_with(prefix):
			names.erase(missing_surface.trim_prefix(prefix))

	func _names_dictionary(names: Array) -> Dictionary:
		var result := {}
		for name: String in names:
			result[name] = true
		return result

	func _surface_properties(class_name_value: String) -> Array:
		match class_name_value:
			"PlayFabLobbyJoinConfig":
				return MatchmakingService.REQUIRED_JOIN_CONFIG_PROPERTIES
			"PlayFabLobbyConfig":
				return MatchmakingService.REQUIRED_LOBBY_CONFIG_PROPERTIES
			"PlayFabLobbyUpdateConfig":
				return MatchmakingService.REQUIRED_LOBBY_UPDATE_PROPERTIES
			"PlayFabLobbySearchConfig":
				return OPTIONAL_SURFACE_PROPERTIES[class_name_value]
			"PlayFabLobby":
				return MatchmakingService.REQUIRED_LOBBY_PROPERTIES
			"PlayFabLobbyMember":
				return MatchmakingService.REQUIRED_LOBBY_MEMBER_PROPERTIES
			"PlayFabLobbySummary":
				return OPTIONAL_SURFACE_PROPERTIES[class_name_value]
			"PlayFabLobbySearchResult":
				return OPTIONAL_SURFACE_PROPERTIES[class_name_value]
			"PlayFabLobbyStateChange":
				return MatchmakingService.REQUIRED_LOBBY_STATE_CHANGE_PROPERTIES
			"PlayFabPartyConfig":
				return MatchmakingService.REQUIRED_PARTY_CONFIG_PROPERTIES
			"PlayFabPartyNetwork":
				return MatchmakingService.REQUIRED_PARTY_NETWORK_PROPERTIES
			"PlayFabPartyNetworkStateChange":
				return MatchmakingService.REQUIRED_PARTY_NETWORK_CHANGE_PROPERTIES + [
					"reason",
				]
			"PlayFabMatchmakingTicketConfig":
				return MatchmakingService.REQUIRED_TICKET_CONFIG_PROPERTIES
			"PlayFabMatchTicket":
				return MatchmakingService.REQUIRED_TICKET_PROPERTIES + ["properties"]
			"PlayFabMatchTicketStateChange":
				return MatchmakingService.REQUIRED_TICKET_STATE_CHANGE_PROPERTIES
			"PlayFabMatchmakingMember":
				return MatchmakingService.REQUIRED_MATCHMAKING_MEMBER_PROPERTIES
			"PlayFabResult":
				return MatchmakingService.REQUIRED_RESULT_PROPERTIES
		return []

	func _surface_methods(class_name_value: String) -> Array:
		match class_name_value:
			"PlayFabLobby":
				return MatchmakingService.REQUIRED_LOBBY_METHODS
			"PlayFabPartyNetwork":
				return MatchmakingService.REQUIRED_PARTY_NETWORK_METHODS
			"PlayFabPartyPeer":
				return MatchmakingService.REQUIRED_PARTY_PEER_METHODS
			"PlayFabMatchTicket":
				return MatchmakingService.REQUIRED_TICKET_METHODS
			"PlayFabUser":
				return MatchmakingService.REQUIRED_USER_METHODS
		return []

	func _surface_signals(class_name_value: String) -> Array:
		match class_name_value:
			"PlayFabLobby", "PlayFabPartyNetwork", "PlayFabMatchTicket":
				return ["state_changed"]
		return []


class Peer extends MultiplayerPeerExtension:
	var unique_id := 1
	var keys: Dictionary = {}
	var connected := true

	func _get_connection_status() -> MultiplayerPeer.ConnectionStatus:
		return MultiplayerPeer.CONNECTION_CONNECTED if connected \
			else MultiplayerPeer.CONNECTION_DISCONNECTED

	func _get_unique_id() -> int:
		return unique_id

	func _is_server() -> bool:
		return unique_id == 1

	func _poll() -> void:
		pass

	func _close() -> void:
		connected = false

	func _get_available_packet_count() -> int:
		return 0

	func _get_max_packet_size() -> int:
		return 4096

	func _get_packet_peer() -> int:
		return 1

	func _get_packet_channel() -> int:
		return 0

	func _get_packet_mode() -> MultiplayerPeer.TransferMode:
		return MultiplayerPeer.TRANSFER_MODE_RELIABLE

	func _is_server_relay_supported() -> bool:
		return false

	func _set_target_peer(_id: int) -> void:
		pass

	func _set_transfer_channel(_channel: int) -> void:
		pass

	func _set_transfer_mode(_mode: MultiplayerPeer.TransferMode) -> void:
		pass

	func _put_packet_script(_packet: PackedByteArray) -> Error:
		return OK

	func get_peer_entity_key(peer_id: int) -> Dictionary:
		return (keys.get(peer_id, {}) as Dictionary).duplicate()


class Network extends RefCounted:
	signal state_changed(change: Variant)
	signal leave_released()
	var descriptor := "descriptor-1"
	var local_peer: Variant = Peer.new()
	var leaves := 0
	var block_leave := false
	var next_leave_result: Variant = null

	func leave_async() -> Dictionary:
		leaves += 1
		if block_leave:
			await leave_released
		if next_leave_result != null:
			var result: Variant = next_leave_result
			next_leave_result = null
			return result
		if local_peer != null:
			local_peer.connected = false
			local_peer = null
		return Results.make(true)


class Member extends RefCounted:
	var entity_key: Dictionary
	var properties: Dictionary
	var connection_status := 1

	func _init(key: Dictionary, values: Dictionary = {}) -> void:
		entity_key = key.duplicate()
		properties = values.duplicate(true)


class Lobby extends RefCounted:
	signal state_changed(change: Variant)
	signal leave_released()
	signal post_released()
	signal lock_released()
	signal member_released()
	signal properties_released()
	var lobby_id := ""
	var connection_string := ""
	var owner_entity_key: Dictionary = {}
	var max_member_count := 4
	var members: Array = []
	var properties: Dictionary = {}
	var search_properties: Dictionary = {}
	var access_policy := 0
	var owner_migration_policy := 2
	var restrict_invites_to_lobby_owner := false
	var membership_lock := 0
	var local_entity_key: Dictionary = {}
	var disconnected := false
	var leaves := 0
	var update_calls := 0
	var update_records: Array[Dictionary] = []
	var property_calls := 0
	var member_calls := 0
	var lock_calls := 0
	var block_leave := false
	var block_post := false
	var block_lock := false
	var block_member := false
	var block_properties := false
	var next_leave_result: Variant = null
	var next_post_result: Variant = null
	var next_post_overrides: Dictionary = {}
	var next_lock_result: Variant = null
	var next_member_result: Variant = null

	func is_owner(user: Variant) -> bool:
		return user != null and user.entity_key == owner_entity_key

	func is_disconnected() -> bool:
		return disconnected

	func set_membership_lock_async(value: int) -> Dictionary:
		lock_calls += 1
		if block_lock:
			await lock_released
		if next_lock_result != null:
			var result: Variant = next_lock_result
			next_lock_result = null
			return result
		membership_lock = value
		return Results.make(true)

	func post_update_async(update: Variant) -> Dictionary:
		update_calls += 1
		var access_present: bool = update != null \
			and update.has_method("has_field") \
			and bool(update.has_field("access_policy"))
		var lobby_present: bool = update != null \
			and update.has_method("has_field") \
			and bool(update.has_field("lobby_properties"))
		var search_present: bool = update != null \
			and update.has_method("has_field") \
			and bool(update.has_field("search_properties"))
		update_records.append({
			"present": update.present.duplicate()
				if update != null and update.get("present") != null else {},
			"access_policy": int(update.access_policy) if access_present else -1,
			"lobby_properties": update.lobby_properties.duplicate(true)
				if lobby_present else {},
			"search_properties": update.search_properties.duplicate(true)
				if search_present else {},
		})
		if block_post:
			await post_released
		if next_post_result != null:
			var result: Variant = next_post_result
			next_post_result = null
			return result
		if access_present:
			access_policy = int(update.access_policy)
		if lobby_present:
			properties.merge(update.lobby_properties, true)
		if search_present:
			search_properties.merge(update.search_properties, true)
		if not next_post_overrides.is_empty():
			if next_post_overrides.has("access_policy"):
				access_policy = int(next_post_overrides.access_policy)
			if next_post_overrides.has("lobby_properties"):
				properties.merge(
					next_post_overrides.lobby_properties as Dictionary, true)
			if next_post_overrides.has("search_properties"):
				search_properties.merge(
					next_post_overrides.search_properties as Dictionary, true)
			if next_post_overrides.has("owner_entity_key"):
				owner_entity_key = (
					next_post_overrides.owner_entity_key as Dictionary
				).duplicate()
			if next_post_overrides.has("max_member_count"):
				max_member_count = int(next_post_overrides.max_member_count)
			if next_post_overrides.has("membership_lock"):
				membership_lock = int(next_post_overrides.membership_lock)
			next_post_overrides = {}
		return Results.make(true)

	func set_properties_async(values: Dictionary) -> Dictionary:
		property_calls += 1
		if block_properties:
			await properties_released
		properties.merge(values, true)
		return Results.make(true)

	func set_member_properties_async(values: Dictionary) -> Dictionary:
		member_calls += 1
		if block_member:
			await member_released
		if next_member_result != null:
			var result: Variant = next_member_result
			next_member_result = null
			return result
		for member: Member in members:
			if member.entity_key == local_entity_key:
				member.properties.merge(values, true)
				break
		return Results.make(true)

	func leave_async() -> Dictionary:
		leaves += 1
		if block_leave:
			await leave_released
		if next_leave_result != null:
			var result: Variant = next_leave_result
			next_leave_result = null
			return result
		disconnected = true
		return Results.make(true)


class PartySDK extends RefCounted:
	signal initialize_released()
	signal create_released()
	signal join_released()
	var initialized := true
	var networks: Array[Network] = []
	var create_calls: Array[Dictionary] = []
	var join_calls: Array[Dictionary] = []
	var queued_networks: Array[Network] = []
	var block_create := false
	var block_join := false
	var block_initialize := false
	var next_created_network_leave_result: Variant = null
	var next_create_result: Variant = null
	var next_join_result: Variant = null
	var next_initialize_result: Variant = null
	var next_shutdown_result: Variant = null
	var shutdown_calls := 0

	func is_initialized() -> bool:
		return initialized

	func initialize_async(_config: Variant, _port: int) -> Dictionary:
		if block_initialize:
			await initialize_released
		if next_initialize_result != null:
			var result: Variant = next_initialize_result
			next_initialize_result = null
			return result
		initialized = true
		return Results.make(true)

	func shutdown_async() -> Dictionary:
		shutdown_calls += 1
		if next_shutdown_result != null:
			var result: Variant = next_shutdown_result
			next_shutdown_result = null
			return result
		initialized = false
		for network: Network in networks:
			if network.local_peer != null:
				network.local_peer.connected = false
				network.local_peer = null
		return Results.make(true)

	func create_and_join_network_async(_user: Variant, config: Variant) -> Dictionary:
		create_calls.append({
			"max_players": int(config.max_players),
			"invitation_id": String(config.invitation_id),
		})
		if next_create_result != null:
			var result: Variant = next_create_result
			next_create_result = null
			return result
		var network: Network = queued_networks.pop_front() \
			if not queued_networks.is_empty() else Network.new()
		_apply_next_network_leave_result(network)
		if block_create:
			await create_released
		networks.append(network)
		return Results.make(true, network)

	func join_network_async(_user: Variant, descriptor: String, config: Variant) -> Dictionary:
		join_calls.append({
			"descriptor": descriptor,
			"invitation_id": String(config.invitation_id),
		})
		if next_join_result != null:
			var result: Variant = next_join_result
			next_join_result = null
			return result
		var network: Network = queued_networks.pop_front() \
			if not queued_networks.is_empty() else Network.new()
		_apply_next_network_leave_result(network)
		if block_join:
			await join_released
		network.local_peer.unique_id = 7
		networks.append(network)
		return Results.make(true, network)

	func _apply_next_network_leave_result(network: Network) -> void:
		if network == null or next_created_network_leave_result == null:
			return
		network.next_leave_result = next_created_network_leave_result
		next_created_network_leave_result = null


class LobbySummary extends RefCounted:
	var connection_string := ""


class LobbySearchResult extends RefCounted:
	var lobbies: Array = []


class MultiplayerSDK extends RefCounted:
	signal initialize_released()
	signal create_released()
	signal arranged_released()
	var initialized := true
	var lobbies: Array[Lobby] = []
	var next_create_result: Variant = null
	var next_arranged_result: Variant = null
	var next_join_result: Variant = null
	var next_find_result: Variant = null
	var find_calls: Array[Dictionary] = []
	var join_calls: Array[String] = []
	var arranged_calls: Array[Dictionary] = []
	var lobby_by_connection: Dictionary = {}
	var block_create := false
	var block_arranged := false
	var block_initialize := false
	var next_created_lobby_leave_result: Variant = null
	var next_initialize_result: Variant = null
	var next_shutdown_result: Variant = null
	var shutdown_calls := 0
	var shutdown_hook: Callable = Callable()

	func is_initialized() -> bool:
		return initialized

	func initialize_async() -> Dictionary:
		if block_initialize:
			await initialize_released
		if next_initialize_result != null:
			var result: Variant = next_initialize_result
			next_initialize_result = null
			return result
		initialized = true
		return Results.make(true)

	func shutdown_async() -> Dictionary:
		shutdown_calls += 1
		if shutdown_hook.is_valid():
			shutdown_hook.call()
		if next_shutdown_result != null:
			var result: Variant = next_shutdown_result
			next_shutdown_result = null
			return result
		initialized = false
		for lobby: Lobby in lobbies:
			lobby.disconnected = true
		return Results.make(true)

	func create_lobby_async(user: Variant, config: Variant) -> Dictionary:
		if block_create:
			await create_released
		if next_create_result != null:
			var result: Variant = next_create_result
			next_create_result = null
			_apply_result_lobby_leave(result)
			return result
		var lobby := _lobby_from_config(user, config, "staging-%d" % (lobbies.size() + 1))
		_apply_next_lobby_leave_result(lobby)
		lobbies.append(lobby)
		lobby_by_connection[lobby.connection_string] = lobby
		return Results.make(true, lobby)

	func find_lobbies_async(_user: Variant, config: Variant) -> Dictionary:
		find_calls.append({
			"filter": String(config.filter),
			"max_results": int(config.max_results),
		})
		if next_find_result != null:
			var result: Variant = next_find_result
			next_find_result = null
			return result
		var found := LobbySearchResult.new()
		for connection_string: String in lobby_by_connection:
			var summary := LobbySummary.new()
			summary.connection_string = connection_string
			found.lobbies.append(summary)
		return Results.make(true, found)

	func join_lobby_async(user: Variant, connection_string: String, _config: Variant) -> Dictionary:
		join_calls.append(connection_string)
		if next_join_result != null:
			var result: Variant = next_join_result
			next_join_result = null
			_apply_result_lobby_leave(result)
			return result
		var lobby: Lobby = lobby_by_connection.get(connection_string)
		if lobby == null:
			return Results.make(false, null, "missing_lobby", "Injected lobby was not found.")
		var has_local := false
		for member: Member in lobby.members:
			if member.entity_key == user.entity_key:
				has_local = true
		if not has_local:
			lobby.members.append(Member.new(user.entity_key))
		lobby.local_entity_key = user.entity_key.duplicate()
		_apply_next_lobby_leave_result(lobby)
		return Results.make(true, lobby)

	func join_arranged_lobby_async(
		user: Variant,
		_arrangement: String,
		config: Variant
	) -> Dictionary:
		arranged_calls.append({
			"max_member_count": int(config.max_member_count),
			"access_policy": int(config.access_policy),
			"owner_migration_policy": int(config.owner_migration_policy),
			"restrict_invites_to_lobby_owner":
				bool(config.restrict_invites_to_lobby_owner),
			"member_properties": config.member_properties.duplicate(true),
		})
		if block_arranged:
			await arranged_released
		if next_arranged_result != null:
			var result: Variant = next_arranged_result
			next_arranged_result = null
			_apply_result_lobby_leave(result)
			return result
		var lobby := Lobby.new()
		lobby.lobby_id = "arranged-%d" % (lobbies.size() + 1)
		lobby.connection_string = "connection-" + lobby.lobby_id
		lobby.owner_entity_key = user.entity_key.duplicate()
		lobby.max_member_count = config.max_member_count
		lobby.access_policy = config.access_policy
		lobby.owner_migration_policy = config.owner_migration_policy
		lobby.restrict_invites_to_lobby_owner = config.restrict_invites_to_lobby_owner
		lobby.local_entity_key = user.entity_key.duplicate()
		lobby.members = [Member.new(user.entity_key, config.member_properties)]
		_apply_next_lobby_leave_result(lobby)
		lobbies.append(lobby)
		lobby_by_connection[lobby.connection_string] = lobby
		return Results.make(true, lobby)

	func _lobby_from_config(user: Variant, config: Variant, id: String) -> Lobby:
		var lobby := Lobby.new()
		lobby.lobby_id = id
		lobby.connection_string = "connection-" + id
		lobby.owner_entity_key = user.entity_key.duplicate()
		lobby.max_member_count = config.max_players
		lobby.access_policy = config.access_policy
		lobby.owner_migration_policy = config.owner_migration_policy
		lobby.restrict_invites_to_lobby_owner = config.restrict_invites_to_lobby_owner
		lobby.local_entity_key = user.entity_key.duplicate()
		lobby.search_properties = config.search_properties.duplicate(true)
		lobby.properties = config.lobby_properties.duplicate(true)
		lobby.members = [Member.new(user.entity_key, config.member_properties)]
		return lobby

	func _apply_result_lobby_leave(result: Variant) -> void:
		if typeof(result) != TYPE_DICTIONARY:
			return
		var data: Variant = (result as Dictionary).get("data")
		if data is Lobby:
			_apply_next_lobby_leave_result(data as Lobby)

	func _apply_next_lobby_leave_result(lobby: Lobby) -> void:
		if lobby == null or next_created_lobby_leave_result == null:
			return
		lobby.next_leave_result = next_created_lobby_leave_result
		next_created_lobby_leave_result = null


class PlayFabDouble extends RefCounted:
	var party := PartySDK.new()
	var multiplayer := MultiplayerSDK.new()

	func is_initialized() -> bool:
		return true


class Party extends PartyService:
	var pf := PlayFabDouble.new()
	var fake_account_current := true
	var fake_clock := Clock.new()
	var fake_warnings: Array[String] = []

	func _now_msec() -> int:
		return fake_clock.now_msec()

	func _playfab() -> Variant:
		return pf

	func _account_is_current(_generation: int) -> bool:
		return fake_account_current

	func _user_is_ready(user: Variant) -> bool:
		return fake_account_current and user != null

	func _is_join_operation_current(operation: int) -> bool:
		return fake_account_current and (operation == 0 or operation == _join_operation_token)

	func _new_party_config() -> Variant:
		return Config.new()

	func _new_lobby_config() -> Variant:
		return Config.new()

	func _new_lobby_join_config() -> Variant:
		return Config.new()

	func _new_lobby_update_config() -> Variant:
		return LobbyUpdateConfig.new()

	func _new_lobby_search_config() -> Variant:
		return Config.new()

	func _emit_warning(message: String) -> void:
		fake_warnings.append(message)
