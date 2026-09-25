extends RefCounted


class Results extends RefCounted:
	static func make(
		ok: bool,
		data: Variant = null,
		code: String = "ok",
		message: String = "Injected result."
	) -> Dictionary:
		return {
			"ok": ok,
			"data": data,
			"code": code,
			"message": message,
			"hresult": 0 if ok else -1,
		}


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


class Ticket extends RefCounted:
	signal state_changed(change: Variant)
	signal cancel_released()
	var ticket_id := "ticket-1"
	var status := MatchmakingService.STATUS_WAITING_FOR_PLAYERS
	var match_id := ""
	var arranged_lobby_connection_string := ""
	var properties: Dictionary = {}
	var cancel_calls := 0
	var cancel_ok := true
	var cancel_confirms_terminal := true
	var block_cancel := false

	func is_complete() -> bool:
		return status >= MatchmakingService.STATUS_MATCHED

	func cancel_async() -> Dictionary:
		cancel_calls += 1
		if status >= MatchmakingService.STATUS_MATCHED:
			return Results.make(
				false,
				self,
				"ticket_already_terminal",
				"Injected terminal ticket cannot be cancelled.")
		if block_cancel:
			await cancel_released
		if cancel_ok and cancel_confirms_terminal:
			status = MatchmakingService.STATUS_CANCELLED
			state_changed.emit(Change.new())
		return Results.make(cancel_ok, self, "cancelled" if cancel_ok else "cancel_failed")

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
		if not queued_create_results.is_empty():
			return queued_create_results.pop_front()
		return Results.make(true, Ticket.new())

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
		if not queued_join_results.is_empty():
			return queued_join_results.pop_front()
		var ticket := Ticket.new()
		ticket.ticket_id = ticket_id
		ticket.status = MatchmakingService.STATUS_WAITING_FOR_MATCH
		return Results.make(true, ticket)

	func join_arranged_lobby_async(
		_user: Variant,
		_arrangement: String,
		_config: Variant
	) -> Dictionary:
		return Results.make(false, null, "not_used")


class Matchmaking extends MatchmakingService:
	var sdk := MatchmakingSDK.new()
	var fake_flow_implemented := true
	var fake_account_current := true
	var fake_mode_config: GameModeConfig = null
	var fake_queue_name := MatchmakingService.QUEUE_NAME
	var fake_playfab_present := true
	var fake_group_support := true
	var fake_arranged_support := true

	func _init() -> void:
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

	func _multiplayer() -> Variant:
		return sdk

	func _account_is_current(_generation: int) -> bool:
		return fake_account_current

	func _new_ticket_config() -> Variant:
		return Config.new()

	func _new_matchmaking_member() -> Variant:
		return MatchmakingMember.new()


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
	var local_peer := Peer.new()
	var leaves := 0
	var block_leave := false

	func leave_async() -> Dictionary:
		leaves += 1
		if block_leave:
			await leave_released
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
	var property_calls := 0
	var lock_calls := 0
	var block_leave := false
	var block_post := false
	var block_lock := false
	var block_member := false
	var next_post_result: Variant = null
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
		if block_post:
			await post_released
		if next_post_result != null:
			var result: Variant = next_post_result
			next_post_result = null
			return result
		if not update.lobby_properties.is_empty():
			properties.merge(update.lobby_properties, true)
		if not update.search_properties.is_empty():
			search_properties.merge(update.search_properties, true)
		return Results.make(true)

	func set_properties_async(values: Dictionary) -> Dictionary:
		property_calls += 1
		properties.merge(values, true)
		return Results.make(true)

	func set_member_properties_async(values: Dictionary) -> Dictionary:
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

	func create_and_join_network_async(user: Variant, config: Variant) -> Dictionary:
		create_calls.append({
			"max_players": int(config.max_players),
			"invitation_id": String(config.invitation_id),
		})
		var network: Network = queued_networks.pop_front() \
			if not queued_networks.is_empty() else Network.new()
		if block_create:
			await create_released
		network.local_peer.keys[1] = user.entity_key.duplicate()
		networks.append(network)
		return Results.make(true, network)

	func join_network_async(user: Variant, descriptor: String, config: Variant) -> Dictionary:
		join_calls.append({
			"descriptor": descriptor,
			"invitation_id": String(config.invitation_id),
		})
		var network: Network = queued_networks.pop_front() \
			if not queued_networks.is_empty() else Network.new()
		if block_join:
			await join_released
		network.local_peer.unique_id = 7
		network.local_peer.keys[7] = user.entity_key.duplicate()
		networks.append(network)
		return Results.make(true, network)


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
	var find_calls: Array[Dictionary] = []
	var join_calls: Array[String] = []
	var arranged_calls: Array[Dictionary] = []
	var lobby_by_connection: Dictionary = {}
	var block_create := false
	var block_arranged := false
	var block_initialize := false
	var next_initialize_result: Variant = null
	var next_shutdown_result: Variant = null
	var shutdown_calls := 0

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
			return result
		var lobby := _lobby_from_config(user, config, "staging-%d" % (lobbies.size() + 1))
		lobbies.append(lobby)
		lobby_by_connection[lobby.connection_string] = lobby
		return Results.make(true, lobby)

	func find_lobbies_async(_user: Variant, config: Variant) -> Dictionary:
		find_calls.append({
			"filter": String(config.filter),
			"max_results": int(config.max_results),
		})
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


class PlayFabDouble extends RefCounted:
	var party := PartySDK.new()
	var multiplayer := MultiplayerSDK.new()

	func is_initialized() -> bool:
		return true


class Party extends PartyService:
	var pf := PlayFabDouble.new()
	var fake_account_current := true
	var fake_clock := Clock.new()

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
		return Config.new()

	func _new_lobby_search_config() -> Variant:
		return Config.new()
