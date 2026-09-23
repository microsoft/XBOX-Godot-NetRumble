extends RefCounted

const Doubles := preload("res://tools/tests/doubles.gd")


class Clock extends RefCounted:
	var msec := 0

	func now() -> int:
		return msec


class Peer extends MultiplayerPeerExtension:
	var server := true
	var connected := true

	func _get_connection_status() -> MultiplayerPeer.ConnectionStatus:
		return MultiplayerPeer.CONNECTION_CONNECTED if connected else MultiplayerPeer.CONNECTION_DISCONNECTED

	func _get_unique_id() -> int:
		return 1 if server else 2

	func _is_server() -> bool:
		return server

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

	func get_peer_entity_key(id: int) -> Dictionary:
		return {"id": str(id), "type": "title_player_account"}


class Operation extends RefCounted:
	signal completed(result: Variant)
	var stage := ""
	var data: Variant
	var done := false

	func finish(ok: bool = true) -> void:
		if done:
			return
		done = true
		completed.emit({"ok": ok, "data": data if ok else null,
			"code": "ok" if ok else "injected", "hresult": 0 if ok else -1,
			"message": "Injected " + stage})


class Backend extends RefCounted:
	signal chat_control_added(entity: Dictionary, control: Variant)
	signal chat_control_removed(entity: Dictionary)
	signal audio_muted_changed(entity: Dictionary, muted: bool)
	signal text_message_received(entity: Dictionary, message: Variant)
	var label := ""
	var initialized := false
	var faults: Dictionary = {}
	var calls: Array[Operation] = []
	var networks: Array[Network] = []
	var lobbies: Array[Lobby] = []
	var controls := 0
	var initializations := 0
	var shutdowns := 0
	var unusable_peer := false

	func invoke(stage: String, data: Variant = null) -> Variant:
		var operation := Operation.new()
		operation.stage = stage
		operation.data = data
		calls.append(operation)
		var fault: String = faults.get(stage, "")
		if fault == "hold":
			return operation.completed
		if fault == "async_error" or fault == "async_ok":
			operation.finish.call_deferred(fault == "async_ok")
			return operation.completed
		operation.done = true
		return {"ok": fault != "error", "data": data if fault != "error" else null,
			"code": "injected", "hresult": -1, "message": "Injected " + stage}

	func is_initialized() -> bool:
		return initialized

	func initialize_async(_config: Variant = null, _port: int = 0) -> Variant:
		initializations += 1
		var result: Variant = await invoke(label + "_init")
		initialized = result.ok
		return result

	func shutdown_async() -> Variant:
		shutdowns += 1
		var result: Variant = await invoke(label + "_shutdown")
		if result.ok:
			initialized = false
			controls = 0
			for network: Network in networks:
				network.detach_native()
		return result

	func self_reset() -> void:
		initialized = false
		controls = 0
		for network: Network in networks:
			network.detach_native()
		for lobby: Lobby in lobbies:
			lobby.disconnected = true

	func create_and_join_network_async(_user: Variant, _cfg: Variant) -> Variant:
		var network := Network.new()
		network.backend = self
		network.local_peer.connected = not unusable_peer
		networks.append(network)
		return invoke("create_network", network)

	func join_network_async(_user: Variant, _descriptor: String, _cfg: Variant) -> Variant:
		var network := Network.new()
		network.backend = self
		network.local_peer.server = false
		network.local_peer.connected = not unusable_peer
		networks.append(network)
		return invoke("join_network", network)

	func create_lobby_async(_user: Variant, _cfg: Variant) -> Variant:
		return _lobby("create_lobby")

	func join_lobby_async(_user: Variant, _connection: String, _cfg: Variant) -> Variant:
		return _lobby("join_lobby")

	func _lobby(stage: String) -> Variant:
		var lobby := Lobby.new()
		lobby.backend = self
		lobbies.append(lobby)
		return invoke(stage, lobby)

	func find_lobbies_async(_user: Variant, _cfg: Variant) -> Variant:
		return invoke("find_lobbies", {"lobbies": [{"connection_string": "fixture"}]})

	func create_local_chat_control_async(_user: Variant, _cfg: Variant) -> Variant:
		var result: Variant = await invoke("chat_create")
		if result.ok:
			controls += 1
		return result

	func destroy_local_chat_control_async(_user: Variant) -> Variant:
		var result: Variant = await invoke("chat_destroy")
		if result.ok:
			controls = maxi(0, controls - 1)
		return result

	func get_remote_entity_keys() -> Array:
		return []

	func pending(stage: String) -> Operation:
		for operation: Operation in calls:
			if operation.stage == stage and not operation.done:
				return operation
		return null

	func count(stage: String) -> int:
		var total := 0
		for operation: Operation in calls:
			if operation.stage == stage:
				total += 1
		return total

	func dispose() -> void:
		faults.clear()
		for operation: Operation in calls.duplicate():
			operation.finish(false)
		for network: Network in networks:
			network.backend = null
		for lobby: Lobby in lobbies:
			lobby.backend = null
		calls.clear()
		networks.clear()
		lobbies.clear()


class Network extends RefCounted:
	signal state_changed(change: Variant)
	var backend: Backend
	var local_peer: Peer = Peer.new()
	var descriptor := "fixture-descriptor"
	var state := 3
	var leaves := 0

	func leave_async() -> Variant:
		leaves += 1
		if local_peer == null:
			return {"ok": false, "code": "party_resource_not_ready", "hresult": -1,
				"message": "Network has no active resources."}
		var result: Variant = await backend.invoke("network_leave")
		if result.ok:
			detach_native()
		else:
			result.code = "party_resource_not_ready"
			result.data = {"stage": "PartyNetwork::LeaveNetwork"}
		return result

	func detach_native() -> void:
		var peer := local_peer
		local_peer = null
		if peer != null:
			peer.connected = false

	func destroy(before_destroyed: Callable = Callable()) -> void:
		detach_native()
		if before_destroyed.is_valid():
			before_destroyed.call()
		state = PartyService.NETWORK_STATE_DISCONNECTED
		_emit_change(PartyService.NETWORK_CHANGE_DESTROYED)

	func change(kind: int, new_state: int = 3) -> void:
		if kind == PartyService.NETWORK_CHANGE_DESTROYED:
			destroy()
			return
		state = new_state
		if kind == PartyService.NETWORK_CHANGE_STATE \
				and state in [PartyService.NETWORK_STATE_DISCONNECTED, PartyService.NETWORK_STATE_FAILED] \
				and local_peer != null:
			local_peer.connected = false
		_emit_change(kind)

	func _emit_change(kind: int) -> void:
		state_changed.emit({"kind": kind, "network": self, "state": state, "peer_id": 7,
			"reason": "Injected terminal loss", "result": {"ok": false, "message": "Injected recoverable error"}})


class Lobby extends RefCounted:
	var backend: Backend
	var connection_string := "fixture-connection"
	var properties := {PartyService.DESCRIPTOR_KEY: "fixture-descriptor"}
	var search_properties := {
		PartyService.JOIN_CODE_KEY: "ABCDE",
		NRProtocol.LOBBY_KEY: NRProtocol.version_string(),
	}
	var disconnected := false
	var leaves := 0

	func is_disconnected() -> bool:
		return disconnected

	func set_properties_async(data: Dictionary) -> Variant:
		return backend.invoke("clear_descriptor" if data[PartyService.DESCRIPTOR_KEY] == "" else "republish")

	func leave_async() -> Variant:
		leaves += 1
		var result: Variant = await backend.invoke("lobby_leave")
		if result.ok:
			disconnected = true
		return result


class Runtime extends RefCounted:
	var party := Backend.new()
	var multiplayer := Backend.new()
	var root_shutdowns := 0

	func _init() -> void:
		party.label = "party"
		multiplayer.label = "lobby"

	func is_initialized() -> bool:
		return true

	func shutdown_async() -> Dictionary:
		root_shutdowns += 1
		return {"ok": true}


class Chat extends ChatService:
	var sdk: Backend

	func _chat() -> Variant:
		return sdk


class Party extends PartyService:
	var runtime := Runtime.new()
	var clock := Clock.new()

	func _playfab() -> Variant:
		return runtime

	func _make_party_config(_maximum: int, _invitation: String) -> Variant:
		return {}

	func _make_lobby_config() -> Variant:
		return {}

	func _make_search_config(_code: String) -> Variant:
		return {}

	func _now_msec() -> int:
		return clock.msec


class IncompatibleParty extends Party:
	func _bound_network_constant(name: StringName) -> int:
		return -1 if name == &"NETWORK_CHANGE_ERROR" else int(NETWORK_CHANGES[name])


class Privileges extends PrivilegeService:
	signal completed()
	var blocked_privilege := 0
	var calls: Array[int] = []

	func ensure(_user: Variant, privilege: int) -> Dictionary:
		calls.append(privilege)
		if privilege == blocked_privilege:
			await completed
		return {"granted": true}


class QuietAudio extends "res://tools/tests/audio.gd":
	func play_music(_loop: bool = true) -> void:
		pass


var _test: Node
var _party: Party
var _chat: Chat
var _clock: Clock
var _successes := 0
var _disconnects := 0


func run(test: Node) -> void:
	_test = test
	var old_chat: ChatService = Services._chat
	var old_party: PartyService = Services._party
	var audio_script: Script = AudioManager.get_script()
	AudioManager.set_script(QuietAudio)
	NetManager.connection_succeeded.connect(_succeeded)
	NetManager.server_disconnected.connect(_disconnected)
	await _event_contract()
	await _destroyed_network_cleanup()
	await _failures()
	await _before_bind_loss()
	await _cleanup_reset()
	await _cleanup_errors()
	await _native_self_reset()
	await _budgets()
	await _replacement_and_peer_guards()
	await _ui_flows()
	await _regressions()
	await _dispose()
	NetManager.connection_succeeded.disconnect(_succeeded)
	NetManager.server_disconnected.disconnect(_disconnected)
	NetManager._clock = Time.get_ticks_msec
	Services._chat = old_chat
	Services._party = old_party
	AudioManager.set_script(audio_script)


func _succeeded() -> void:
	_successes += 1


func _disconnected() -> void:
	_disconnects += 1


func _check(condition: bool, message: String) -> void:
	_test._check(condition, "multiplayer: " + message)


func _frames(count: int = 3) -> void:
	for index in count:
		await _test.get_tree().process_frame


func _poll() -> void:
	await _test.get_tree().create_timer(0.12).timeout


func _fixture() -> void:
	await _dispose()
	await _test._reset()
	_test._select("multiplayer", _test._folder())
	_check(await Services.sign_in(), "fixture account ready")
	_chat = Chat.new()
	_party = Party.new(_chat)
	_chat.sdk = _party.runtime.party
	_clock = _party.clock
	Services._chat = _chat
	Services._party = _party
	Services._connectivity = ConnectivityService.new()
	Services._connectivity.connectivity_changed.connect(NetManager._on_connectivity_changed)
	_party.network_lost.connect(NetManager._on_party_network_lost)
	_party.party_failed.connect(NetManager._on_party_failed)
	_party.cleanup_status_changed.connect(NetManager._on_party_cleanup_status)
	NetManager._clock = _clock.now
	ScreenManager.set_container(_test)
	_successes = 0
	_disconnects = 0


func _dispose() -> void:
	ScreenManager.clear()
	if _party == null:
		return
	_party.runtime.party.faults.clear()
	_party.runtime.multiplayer.faults.clear()
	for backend: Backend in [_party.runtime.party, _party.runtime.multiplayer]:
		for operation: Operation in backend.calls.duplicate():
			operation.finish(false)
	if NetManager._active_join_request != null:
		NetManager.cancel_join(NetManager._active_join_request)
	NetManager._abort_host("Fixture ended.")
	await _poll()
	await NetManager.leave_match_and_wait()
	await _chat.destroy_control()
	_party.runtime.party.dispose()
	_party.runtime.multiplayer.dispose()
	Services._party = null
	Services._chat = null
	_party = null
	_chat = null
	await _frames()


func _host(results: Array) -> void:
	results.append(await NetManager.host_match())


func _wait_host(results: Array) -> void:
	for index in 30:
		if not results.is_empty():
			return
		await _poll()
	_check(false, "host result settled")


func _wait_request(request: JoinRequest) -> void:
	for index in 30:
		if not request.is_pending():
			return
		await _poll()
	_check(false, "join result settled")


func _offline() -> void:
	Services._connectivity._on_hint_changed({"network_initialized": false})


func _event_contract() -> void:
	print("CASE: production Party routes all six bound-contract fallback events")
	await _fixture()
	_check(_party._network_changes.values() == [1, 2, 3, 4, 5, 6], "all six addon-free event values match native 1..6")
	var bad := IncompatibleParty.new(_chat)
	_check(not bad._contract_error.is_empty()
		and not (await bad.host(Services.playfab_user(), 4, "Deathmatch")).ok,
		"incompatible loaded contract fails explicitly before SDK dispatch")
	_check(await NetManager.host_match(), "happy-path production host")
	var events: Array[String] = []
	_party.peer_joined.connect(func(_id: int) -> void: events.append("joined"))
	_party.peer_left.connect(func(_id: int) -> void: events.append("left"))
	_party.network_destroyed.connect(func() -> void: events.append("destroyed"))
	var network: Network = _party._network
	network.change(1)
	network.change(2)
	network.change(3)
	network.change(4)
	network.change(6)
	_check(events == ["joined", "left"] and NetManager.has_session()
		and _party.runtime.multiplayer.count("republish") == 1, "state/peers/descriptor/error are not destruction")
	network.change(5)
	_check(events == ["joined", "left", "destroyed"] and not NetManager.has_session()
		and _disconnects == 1, "DESTROYED is terminal exactly once")
	for state in [PartyService.NETWORK_STATE_FAILED, PartyService.NETWORK_STATE_DISCONNECTED]:
		await _fixture()
		_check(await NetManager.host_match(), "host before terminal state")
		_party._network.change(1, state)
		_check(not NetManager.has_session() and _disconnects == 1, "terminal STATE routes loss")


func _failures() -> void:
	print("CASE: sync/async failures use production host/code/invite/leave paths")
	for entry: String in ["host", "code", "invite"]:
		var stages := ["party_init", "lobby_init", "chat_create", "create_network", "create_lobby"] if entry == "host" \
			else ["party_init", "lobby_init", "find_lobbies", "join_lobby", "join_network"]
		for stage: String in stages:
			if entry == "invite" and stage == "find_lobbies":
				continue
			for fault: String in ["error", "async_error"]:
				await _fixture()
				var backend := _party.runtime.multiplayer if stage in ["lobby_init", "find_lobbies", "join_lobby", "create_lobby"] else _party.runtime.party
				backend.faults[stage] = fault
				if entry == "host":
					var results: Array = []
					_host(results)
					await _wait_host(results)
					_check(results == [stage == "chat_create"], entry + " " + stage + " " + fault + " outcome")
				else:
					var request := NetManager.join_by_code("ABCDE") if entry == "code" else NetManager.join_by_invite("fixture")
					await _wait_request(request)
					_check(request.outcome == JoinRequest.Outcome.FAILED and not request.reason.is_empty(), entry + " " + stage + " " + fault + " outcome")
				if stage != "chat_create":
					_check(not NetManager.has_session() and _party._pending_native.is_empty()
						and not _party.has_network() and _party._lobby == null and _successes == 0,
						"failure fully cleaned without success/activity")


func _destroyed_network_cleanup() -> void:
	print("CASE: destroyed wrappers need no second leave, service reset or chat recreation")
	for entry: String in ["host", "invite", "peer-first"]:
		await _fixture()
		if entry == "host":
			_check(await NetManager.host_match(), "host before native destruction")
		else:
			var request := NetManager.join_by_invite("fixture")
			NetManager._on_connected_to_server()
			NetManager._accept_join()
			await _wait_request(request)
			_check(request.succeeded(), "guest before native destruction")
		var network: Network = _party._network
		var lobby: Lobby = _party._lobby
		var chat_user: Variant = _chat._chat_user
		_party.runtime.party.faults["party_shutdown"] = "error"
		_party.runtime.multiplayer.faults["lobby_shutdown"] = "error"
		if entry == "peer-first":
			network.destroy(func() -> void:
				_check(network.local_peer == null and network.state == 3,
					"native detachment precedes peer disconnect and DISCONNECTED snapshot")
				NetManager._on_peer_disconnected(NetManager.HOST_PEER_ID))
		else:
			network.destroy()
		await _poll()
		_check(not NetManager.has_session() and _disconnects == 1 and lobby.leaves == 1,
			entry + " destruction ends the session once and still leaves its lobby")
		_check(network.leaves == 0 and _party.runtime.party.shutdowns == 0
			and _party.runtime.multiplayer.shutdowns == 0 and not _party._cleanup_failed
			and _party.recovery_error.is_empty(), entry + " confirmed destruction never attempts leave or recovery")
		_check(_chat.has_control() and _chat._chat_user == chat_user
			and _party.runtime.party.controls == 1, "ordinary destruction retains the valid per-user chat control")
		_check(await NetManager.host_match(), "manual retry is not blocked by unnecessary recovery")
		var replacement: Variant = _party._network
		var session := NetManager.session_id()
		_party._on_network_state_changed({"kind": PartyService.NETWORK_CHANGE_DESTROYED,
			"network": network, "state": PartyService.NETWORK_STATE_DISCONNECTED,
			"reason": "Delayed old destruction", "result": null})
		_check(_party._network == replacement and NetManager.session_id() == session and NetManager.has_session(),
			"an old destruction notification cannot clear a replacement instance")
		_check(_party.runtime.party.count("chat_create") == 1
			and _party.runtime.party.initializations == 1 and _party.runtime.multiplayer.initializations == 1,
			"manual retry reuses live services and chat")
	await _fixture()
	_check(await NetManager.host_match(), "host before replacement inside destruction notification")
	var old_network: Network = _party._network
	var replacement_results: Array = []
	_party.network_destroyed.connect(func() -> void: _host(replacement_results), CONNECT_ONE_SHOT)
	old_network.destroy()
	await _wait_host(replacement_results)
	_check(replacement_results == [true] and _party._network != old_network
		and NetManager.has_session() and _disconnects == 0,
		"old destruction cannot emit session loss against a reentrant replacement")
	_check(old_network.leaves == 0 and _party.runtime.party.shutdowns == 0
		and _party.runtime.multiplayer.shutdowns == 0, "reentrant replacement still needs no native recovery")
	for entry: String in ["host", "code", "invite"]:
		await _fixture()
		var stage := "create_network" if entry == "host" else "join_network"
		_party.runtime.party.faults[stage] = "hold"
		var results: Array = []
		var request: JoinRequest
		if entry == "host":
			_host(results)
		else:
			request = NetManager.join_by_code("ABCDE") if entry == "code" else NetManager.join_by_invite("fixture")
		var pending := _party.runtime.party.pending(stage)
		_offline()
		await _poll()
		pending.data.destroy()
		pending.finish()
		if request == null:
			await _wait_host(results)
			_check(results == [false], "late destroyed host result stays failed")
		else:
			await _wait_request(request)
			_check(request.outcome == JoinRequest.Outcome.FAILED, "late destroyed join result stays failed")
		_check(pending.data.leaves == 0 and _party.runtime.party.shutdowns == 0
			and _party.runtime.multiplayer.shutdowns == 0 and _chat.has_control(),
			"late result cleanup recognizes an already-detached exact instance")
	await _fixture()
	_party.runtime.party.faults["create_network"] = "hold"
	var results: Array = []
	_host(results)
	var pending := _party.runtime.party.pending("create_network")
	pending.data.destroy()
	pending.finish()
	await _wait_host(results)
	_check(results == [false] and not NetManager.has_session() and pending.data.leaves == 0
		and _party.runtime.party.shutdowns == 0 and _party.runtime.multiplayer.shutdowns == 0,
		"a result destroyed before attachment is rejected without redundant leave or recovery")
	for terminal_state in [PartyService.NETWORK_STATE_FAILED, PartyService.NETWORK_STATE_DISCONNECTED]:
		for fail_leave: bool in [false, true]:
			await _fixture()
			_check(await NetManager.host_match(), "host before terminal state without destruction")
			var network: Network = _party._network
			if fail_leave:
				_party.runtime.party.faults["network_leave"] = "error"
			network.change(PartyService.NETWORK_CHANGE_STATE, terminal_state)
			await _poll()
			_check(network.leaves == 1 and _party.runtime.party.shutdowns == int(fail_leave)
				and _party.runtime.multiplayer.shutdowns == int(fail_leave),
				"terminal state alone still leaves resources; real resource-not-ready failure still escalates")


func _before_bind_loss() -> void:
	print("CASE: loss before peer binding, late successful resources, first terminal reason")
	for entry: String in ["host", "code", "invite"]:
		for stage: String in (["create_network", "create_lobby"] if entry == "host" else ["join_lobby", "join_network"]):
			await _fixture()
			var backend := _party.runtime.multiplayer if stage in ["create_lobby", "join_lobby"] else _party.runtime.party
			backend.faults[stage] = "hold"
			var results: Array = []
			var request: JoinRequest
			if entry == "host":
				_host(results)
			else:
				request = NetManager.join_by_code("ABCDE") if entry == "code" else NetManager.join_by_invite("fixture")
			_check(NetManager._peer == null and backend.pending(stage) != null, entry + " parked before binding at " + stage)
			_offline()
			NetManager._on_party_network_lost("Second terminal reason")
			await _poll()
			_check(_party._leaving and (results.is_empty() if request == null else request.is_pending()),
				"loss starts cleanup promptly but result waits for unexposed native operation")
			var operation := backend.pending(stage)
			operation.finish()
			if request == null:
				await _wait_host(results)
				_check(results == [false] and NetManager.last_error == "This console is not connected to a network.", "host keeps first loss reason")
			else:
				await _wait_request(request)
				_check(request.reason == "This console is not connected to a network.", "join keeps first loss reason")
			_check(operation.data.leaves == 1 and _successes == 0 and _disconnects == 0
				and not NetManager.has_session(), "late exact resource left once; no success or duplicate established dialog")
	await _fixture()
	Services._connectivity._online = false
	_check(not await NetManager.host_match() and _party.runtime.party.calls.is_empty(), "offline snapshot blocks a missed leading edge")
	for kind in [1, 5]:
		await _fixture()
		_party.runtime.multiplayer.faults["create_lobby"] = "hold"
		var results: Array = []
		_host(results)
		var network: Network = _party._network
		network.change(kind, PartyService.NETWORK_STATE_FAILED)
		await _poll()
		_check(_party._leaving and results.is_empty(), "native terminal event starts cleanup before binding")
		_party.runtime.multiplayer.pending("create_lobby").finish()
		await _wait_host(results)
		_check(results == [false] and NetManager.last_error == "Injected terminal loss"
			and network.leaves == (0 if kind == PartyService.NETWORK_CHANGE_DESTROYED else 1),
			"only undestroyed terminal resources need leave; late advertisement is never bound")


func _cleanup_reset() -> void:
	print("CASE: shared cleanup budget, scoped resets, stale results and lazy chat recreation")
	for stage: String in ["clear_descriptor", "lobby_leave", "network_leave", "create_network", "chat_create"]:
		await _fixture()
		var backend := _party.runtime.multiplayer if stage in ["clear_descriptor", "lobby_leave"] else _party.runtime.party
		backend.faults[stage] = "hold"
		var results: Array = []
		if stage in ["create_network", "chat_create"]:
			_host(results)
			_offline()
		else:
			_check(await NetManager.host_match(), "host before stuck cleanup")
			NetManager.leave_match()
		await _poll()
		var old := backend.pending(stage)
		_check(old != null and _party._leaving, stage + " retains cleanup ownership")
		if stage == "clear_descriptor":
			_check(_party.runtime.multiplayer.count("lobby_leave") == 1
				and _party.runtime.party.count("network_leave") == 1, "stuck descriptor never blocks either leave")
		_clock.msec = 14999
		await _poll()
		_check(_party.runtime.party.shutdowns == 0, "shared grace does not expire early")
		_clock.msec = 15000
		await _poll()
		_check(_party.runtime.party.shutdowns == 1 and _party.runtime.multiplayer.shutdowns == 1
			and _party.runtime.root_shutdowns == 0 and Services.is_account_ready()
			and not _party._party_initialized and not _party._multiplayer_initialized
			and not _chat.has_control() and not _party.is_cleanup_pending(), "only Party/Lobby reset; account and root survive")
		if not results.is_empty():
			_check(results == [false], "failed host settles after reset")
		backend.faults.clear()
		Services._connectivity._set_online(true)
		_check(await NetManager.host_match(), "manual retry succeeds without signing in again")
		var replacement: Network = _party._network
		var control_creates := _party.runtime.party.count("chat_create")
		old.finish()
		await _frames()
		_check(_party._network == replacement and replacement.leaves == 0 and _chat.has_control()
			and _party.runtime.party.count("chat_create") == control_creates
			and control_creates == 2, "late old result cannot attach/leave replacement or destroy its recreated chat")
	await _fixture()
	_party.runtime.party.faults["create_network"] = "hold"
	_party.runtime.party.faults["party_shutdown"] = "error"
	var results: Array = []
	_host(results)
	_offline()
	await _poll()
	_clock.msec = 15000
	await _wait_host(results)
	_check(not _party.recovery_error.is_empty() and _party.runtime.multiplayer.shutdowns == 1
		and _party.is_cleanup_pending(), "failed recovery still attempts Lobby and explicitly blocks online")
	Services._connectivity._set_online(true)
	_check(not await NetManager.host_match()
		and NetManager.join_by_code("ABCDE").outcome == JoinRequest.Outcome.FAILED,
		"unsafe recovery cannot produce success-shaped retries")


func _budgets() -> void:
	print("CASE: absolute 45-second establishment includes privileges and admission")
	for entry: String in ["host", "code", "invite"]:
		for privilege in [PrivilegeService.MULTIPLAYER, PrivilegeService.COMMUNICATIONS]:
			await _fixture()
			var gate := Privileges.new()
			gate.blocked_privilege = privilege
			Services._privileges = gate
			var results: Array = []
			var request: JoinRequest
			if entry == "host":
				_host(results)
			else:
				request = NetManager.join_by_code("ABCDE") if entry == "code" else NetManager.join_by_invite("fixture")
			_clock.msec = 44999
			await _poll()
			_check(results.is_empty() if request == null else request.is_pending(), "establishment still pending at 44.999s")
			_clock.msec = 45000
			if request == null:
				await _wait_host(results)
				_check(results == [false] and NetManager.last_error.contains("timed out"), "host times out privilege await")
			else:
				await _wait_request(request)
				_check(request.reason.contains("timed out"), "join times out privilege await")
			gate.completed.emit()
			await _frames()
			_check(_party.runtime.party.count("create_network") == 0 and _party.runtime.party.count("join_network") == 0,
				"late privilege result never starts native work")
	await _fixture()
	_party.runtime.multiplayer.faults["find_lobbies"] = "hold"
	var request := NetManager.join_by_code("ABCDE")
	_clock.msec = 44000
	_party.runtime.multiplayer.pending("find_lobbies").finish()
	_check(NetManager._peer != null and request.is_pending(), "transport attached near absolute deadline")
	_clock.msec = 45000
	await _wait_request(request)
	_check(request.reason.contains("timed out") and not NetManager.has_session(), "admission does not renew establishment budget")
	for entry: String in ["host", "code", "invite"]:
		await _fixture()
		var stage := "create_network" if entry == "host" else "join_network"
		_party.runtime.party.faults[stage] = "hold"
		var completions: Array = []
		var late_request: JoinRequest
		if entry == "host":
			_host(completions)
		else:
			late_request = NetManager.join_by_code("ABCDE") if entry == "code" else NetManager.join_by_invite("fixture")
		var late := _party.runtime.party.pending(stage)
		_clock.msec = 45000
		late.finish()
		_check(not _party.has_network() and late.data.leaves == 1
			and _party.runtime.multiplayer.count("create_lobby") == 0,
			"native completion at absolute deadline cannot attach or advertise between polls")
		if late_request == null:
			await _wait_host(completions)
		else:
			await _wait_request(late_request)
		_check(_successes == 0, "late completion at deadline never publishes success")
	await _fixture()
	_party.runtime.party.faults["create_network"] = "hold"
	var results: Array = []
	_host(results)
	_clock.msec = 45000
	await _poll()
	_check(results.is_empty() and _party._leaving and _party.runtime.party.shutdowns == 0,
		"establishment timeout starts a separate cleanup budget")
	_clock.msec = 59999
	await _poll()
	_check(results.is_empty() and _party.runtime.party.shutdowns == 0, "cleanup has its own full 14.999 seconds")
	_clock.msec = 60000
	await _wait_host(results)
	_check(results == [false] and _party.runtime.party.shutdowns == 1,
		"stuck creation reaches scoped reset exactly at shared cleanup deadline")


func _cleanup_errors() -> void:
	print("CASE: leave failures, already-disconnected resources and serialized reset confirmation")
	for stage: String in ["clear_descriptor", "lobby_leave", "network_leave"]:
		for fault: String in ["error", "async_error"]:
			await _fixture()
			_check(await NetManager.host_match(), "host before " + stage + " failure")
			var backend := _party.runtime.party if stage == "network_leave" else _party.runtime.multiplayer
			backend.faults[stage] = fault
			await NetManager.leave_match_and_wait()
			_check(_party.runtime.multiplayer.count("lobby_leave") == 1
				and _party.runtime.party.count("network_leave") == 1, "failed cleanup step does not prevent either leave")
			_check(_party.runtime.party.shutdowns == (0 if stage == "clear_descriptor" else 1),
				"descriptor error is best effort; leave error requires confirmed reset")
	await _fixture()
	_check(await NetManager.host_match(), "host before disconnected cleanup")
	var lobby: Lobby = _party._lobby
	lobby.disconnected = true
	await NetManager.leave_match_and_wait()
	await NetManager.leave_match_and_wait()
	_check(lobby.leaves == 0 and _party.runtime.party.count("network_leave") == 1,
		"already-disconnected lobby and repeat leave are idempotent")
	await _fixture()
	_party.runtime.party.faults["create_network"] = "hold"
	_party.runtime.party.faults["party_shutdown"] = "hold"
	_party.runtime.multiplayer.faults["lobby_shutdown"] = "hold"
	var results: Array = []
	_host(results)
	_offline()
	await _poll()
	_clock.msec = 15000
	await _poll()
	_check(_party.runtime.party.shutdowns == 1 and _party.runtime.multiplayer.shutdowns == 0,
		"scoped shutdowns are serialized")
	var rejected: Array = []
	_host(rejected)
	_check(rejected == [false] and NetManager.join_by_invite("fixture").outcome == JoinRequest.Outcome.FAILED,
		"online entry blocked during reset")
	_party.runtime.party.pending("party_shutdown").finish()
	await _frames()
	_check(results.is_empty() and _party.runtime.multiplayer.shutdowns == 1
		and _party.is_cleanup_pending(), "Party shutdown alone cannot release cleanup")
	_party.runtime.multiplayer.pending("lobby_shutdown").finish()
	await _wait_host(results)
	_check(results == [false] and not _party.is_cleanup_pending(), "both confirmations release cleanup")


func _native_self_reset() -> void:
	print("CASE: autonomous native reset reconciles readiness and retained chat before manual retry")
	for entry: String in ["host", "code", "invite"]:
		for reset_both: bool in [false, true]:
			await _fixture()
			var stage := "create_network" if entry == "host" else "join_network"
			_party.runtime.party.faults[stage] = "hold"
			var results: Array = []
			var request: JoinRequest
			if entry == "host":
				_host(results)
			else:
				request = NetManager.join_by_code("ABCDE") if entry == "code" else NetManager.join_by_invite("fixture")
			var pending := _party.runtime.party.pending(stage)
			_check(pending != null and not _party.has_network() and _chat.has_control(),
				entry + " native reset fixture has a pending unexposed network and retained chat")
			_party.runtime.party.self_reset()
			if reset_both:
				_party.runtime.multiplayer.self_reset()
			pending.finish(false)
			if request == null:
				await _wait_host(results)
				_check(results == [false], "autonomous reset fails pending host")
			else:
				await _wait_request(request)
				_check(request.outcome == JoinRequest.Outcome.FAILED, "autonomous reset fails pending join")
			_check(not _party._party_initialized and _party._multiplayer_initialized == not reset_both
				and not _chat.has_control(), "cleanup reconciles both cached readiness flags and obsolete native chat")
			_party.runtime.party.faults.clear()
			if entry == "host":
				_check(await NetManager.host_match(), "manual host retry after native self-reset")
			else:
				request = NetManager.join_by_code("ABCDE") if entry == "code" else NetManager.join_by_invite("fixture")
				NetManager._on_connected_to_server()
				NetManager._accept_join()
				await _wait_request(request)
				_check(request.succeeded(), "manual join retry after native self-reset")
			_check(_party.runtime.party.initializations == 2
				and _party.runtime.multiplayer.initializations == (2 if reset_both else 1)
				and _party.runtime.party.count("chat_create") == 2
				and _party.runtime.party.controls == 1 and _chat.has_control(),
				"retry initializes only missing services and creates a fresh native chat control")
			_check(_party.runtime.root_shutdowns == 0 and _party.runtime.party.shutdowns == 0
				and _party.runtime.multiplayer.shutdowns == 0 and Services.is_account_ready(),
				"confirmed autonomous reset needs no root or additional scoped shutdown")
	for entry: String in ["host", "invite"]:
		await _fixture()
		var stage := "create_lobby" if entry == "host" else "join_lobby"
		_party.runtime.multiplayer.faults[stage] = "hold"
		var results: Array = []
		var request: JoinRequest
		if entry == "host":
			_host(results)
		else:
			request = NetManager.join_by_invite("fixture")
		_party.runtime.multiplayer.self_reset()
		_party.runtime.multiplayer.pending(stage).finish(false)
		if request == null:
			await _wait_host(results)
		else:
			await _wait_request(request)
		_check(_party._party_initialized and not _party._multiplayer_initialized,
			"Lobby-only autonomous reset reconciles independently of Party")
		_party.runtime.multiplayer.faults.clear()
		_check(await NetManager.host_match() and _party.runtime.party.initializations == 1
			and _party.runtime.multiplayer.initializations == 2
			and _party.runtime.party.count("chat_create") == 1 and _chat.has_control(),
			"Lobby-only retry reuses initialized Party and its valid chat")
	for stage: String in ["party_init", "lobby_init", "create_network"]:
		await _fixture()
		var backend := _party.runtime.multiplayer if stage == "lobby_init" else _party.runtime.party
		backend.faults[stage] = "error"
		_check(not await NetManager.host_match(), stage + " fails initial host")
		_check(_party._party_initialized == _party.runtime.party.initialized
			and _party._multiplayer_initialized == _party.runtime.multiplayer.initialized,
			"partial initial setup preserves actual native service readiness")
		backend.faults.clear()
		_check(await NetManager.host_match(), "manual retry after partial " + stage)
		_check(_party.runtime.party.initializations == (2 if stage == "party_init" else 1)
			and _party.runtime.multiplayer.initializations == (2 if stage == "lobby_init" else 1)
			and _party.runtime.party.controls == 1, "partial retry initializes only missing service without duplicate chat")
	await _fixture()
	_party.runtime.multiplayer.faults["lobby_init"] = "hold"
	var results: Array = []
	_host(results)
	_party.runtime.party.self_reset()
	_party.runtime.multiplayer.pending("lobby_init").finish()
	await _wait_host(results)
	_check(results == [false] and not _party._party_initialized and _party._multiplayer_initialized
		and _party.runtime.party.count("create_network") == 0,
		"Party reset during Lobby initialization fails current attempt before network dispatch")
	_party.runtime.multiplayer.faults.clear()
	_check(await NetManager.host_match() and _party.runtime.party.initializations == 2
		and _party.runtime.multiplayer.initializations == 1,
		"manual retry reconciles cross-service initialization reset without automatic retry")
	await _fixture()
	_check(await NetManager.host_match(), "host before between-matches native reset")
	await NetManager.leave_match_and_wait()
	_party.runtime.party.self_reset()
	_check(await NetManager.host_match() and _party.runtime.party.initializations == 2
		and _party.runtime.multiplayer.initializations == 1 and _party.runtime.party.controls == 1
		and _party.runtime.party.count("chat_create") == 2,
		"entry reconciles an autonomous reset occurring after previous cleanup")


func _replacement_and_peer_guards() -> void:
	print("CASE: superseded joins, stale cancel, null/disconnected peers and admission deadline race")
	await _fixture()
	_party.runtime.party.faults["join_network"] = "hold"
	var old := NetManager.join_by_code("ABCDE")
	var old_loading: Variant = ScreenManager.push(ScreenManager.LOADING, {"allow_cancel": true})
	old_loading.follow_join(old)
	var pending := _party.runtime.party.pending("join_network")
	var replacement := NetManager.join_by_invite("fixture")
	var new_loading: Variant = ScreenManager.push(ScreenManager.LOADING, {"allow_cancel": true})
	new_loading.follow_join(replacement)
	NetManager.cancel_join(old)
	_party.runtime.party.faults.clear()
	pending.finish()
	await _wait_request(old)
	_check(old.was_superseded() and replacement.is_pending() and NetManager._peer != null,
		"replacement waits for old exact resource before attaching")
	ScreenManager.remove(old_loading)
	_check(ScreenManager.current_screen() == new_loading, "old loading removal leaves replacement visible")
	NetManager._on_connected_to_server()
	NetManager._accept_join()
	await _wait_request(replacement)
	_check(replacement.succeeded() and NetManager.joined_session_is_live(replacement)
		and pending.data.leaves == 1, "replacement admission survives old teardown/cancel")
	for entry: String in ["host", "code", "invite"]:
		await _fixture()
		_party.runtime.party.unusable_peer = true
		if entry == "host":
			_check(not await NetManager.host_match(), "disconnected host peer rejected")
		else:
			var request := NetManager.join_by_code("ABCDE") if entry == "code" else NetManager.join_by_invite("fixture")
			await _wait_request(request)
			_check(request.outcome == JoinRequest.Outcome.FAILED, entry + " disconnected peer rejected")
		_check(_successes == 0 and not NetManager.has_session(), "no disconnected-peer success")
	await _fixture()
	_check(not NetManager._bind_peer(null), "null peer rejected at production bind gate")
	var request := NetManager.join_by_invite("fixture")
	NetManager._on_connected_to_server()
	NetManager._accept_join()
	_clock.msec = 45000
	await _wait_request(request)
	_check(request.outcome == JoinRequest.Outcome.FAILED and request.reason.contains("timed out"),
		"absolute deadline wins admission not consumed before expiry")


func _ui_flows() -> void:
	print("CASE: real host/code/friend/invite loading screens own cleanup and one outcome")
	for entry: String in ["host", "code", "friend", "invite", "cancel"]:
		await _fixture()
		_party.runtime.party.faults["create_network" if entry == "host" else "join_network"] = "hold"
		var menu: Variant = ScreenManager.push(ScreenManager.MAIN_MENU)
		match entry:
			"host": menu._on_play()
			"code", "cancel": menu._on_join_code_submitted("ABCDE")
			"friend": menu._on_friend_join_requested("fixture")
			"invite": InviteRouter._join({"connection_string": "fixture"})
		await _frames()
		var loading: Variant = ScreenManager.current_screen()
		_check(loading != null and loading.scene_file_path == ScreenManager.LOADING, entry + " actual loading screen")
		if entry == "cancel":
			loading._on_cancel_pressed()
		else:
			_offline()
		await _poll()
		_check(ScreenManager.current_screen() == loading and loading._message_label.text.contains("Cleaning")
			and loading._cancel_requested and loading._cancel_button.disabled, entry + " retains loading and disables repeat cancel")
		loading._on_cancel_pressed()
		_party.runtime.party.faults["party_shutdown"] = "hold"
		_clock.msec = 15000
		await _poll()
		_check(ScreenManager.current_screen() == loading and loading._message_label.text.contains("Recovering"),
			entry + " loading remains through scoped shutdown")
		_party.runtime.party.pending("party_shutdown").finish()
		await _poll()
		await _frames()
		var current: Variant = ScreenManager.current_screen()
		_check(current != loading and _successes == 0 and _disconnects == 0, entry + " dismisses only after its failure finalizes")
		if entry == "cancel":
			_check(current == menu, "explicit cancel returns silently")
		else:
			_check(current != null and current.has_signal("dismissed"), entry + " has one final failure dialog")
			var dialogs := 0
			for screen: Variant in ScreenManager._stack:
				if screen.has_signal("dismissed"):
					dialogs += 1
			_check(dialogs == 1, entry + " no duplicate dialog")
			current.dismissed.emit(false)
		await _frames()
	await _fixture()
	_party.runtime.party.faults["join_network"] = "hold"
	_party.runtime.party.faults["party_shutdown"] = "error"
	var menu: Variant = ScreenManager.push(ScreenManager.MAIN_MENU)
	menu._on_join_code_submitted("ABCDE")
	var replaced := NetManager._active_join_request
	InviteRouter._join({"connection_string": "fixture"})
	await _poll()
	_clock.msec = 15000
	await _poll()
	await _frames()
	var dialogs := 0
	for screen: Variant in ScreenManager._stack:
		if screen.has_signal("dismissed"):
			dialogs += 1
	_check(replaced.was_superseded() and dialogs == 1,
		"failed shared recovery keeps superseded code silent; only replacement invite reports error")
	var dialog: Variant = ScreenManager.current_screen()
	if dialog != null and dialog.has_signal("dismissed"):
		dialog.dismissed.emit(false)


func _regressions() -> void:
	print("CASE: admission/loss races, established grace, Practice, account and suspend fencing")
	await _fixture()
	var request := NetManager.join_by_invite("fixture")
	NetManager._on_connected_to_server()
	NetManager._accept_join()
	await _wait_request(request)
	_check(request.succeeded() and NetManager.joined_session_is_live(request), "production guest admission succeeds")
	await NetManager.leave_match_and_wait()
	request = NetManager.join_by_code("ABCDE")
	NetManager._on_connected_to_server()
	NetManager._accept_join()
	NetManager._on_party_network_lost("Lost after admission")
	NetManager._on_party_network_lost("Duplicate terminal event")
	NetManager._on_server_disconnected("Duplicate transport event")
	await _wait_request(request)
	_check(request.reason == "Lost after admission" and not request.succeeded() and _disconnects == 0,
		"loss wins unconsumed admission without duplicate dialog")
	await _fixture()
	request = NetManager.join_by_code("ABCDE")
	NetManager._on_connection_failed()
	await _wait_request(request)
	_check(request.reason == "Connection to host failed." and _disconnects == 0,
		"transport connection failure promptly answers its pending join")
	await _fixture()
	_check(await NetManager.host_match(), "established session")
	_offline()
	await _poll()
	_check(NetManager.has_session(), "established session retains eight-second grace")
	Services._connectivity._set_online(true)
	await _poll()
	_check(NetManager.has_session(), "connectivity flap does not end established session")
	_offline()
	_clock.msec = 7999
	await _poll()
	_check(NetManager.has_session(), "established grace remains open at 7.999 seconds")
	_clock.msec = 8000
	await _poll()
	_check(not NetManager.has_session() and _disconnects == 1, "sustained hint loss ends at eight seconds")
	await NetManager.leave_match_and_wait()
	_check(NetManager.start_offline(), "Practice starts")
	_offline()
	_check(NetManager.is_offline() and NetManager.has_session(), "Practice survives connectivity loss")
	for lifecycle: String in ["account", "suspend", "quit"]:
		await _fixture()
		_party.runtime.party.faults["create_network"] = "hold"
		var results: Array = []
		_host(results)
		var old := _party.runtime.party.pending("create_network")
		match lifecycle:
			"account": Services.cancel_sign_in()
			"suspend": NetManager.abandon_for_suspend()
			"quit": Services.begin_shutdown()
		await _poll()
		old.finish()
		if lifecycle == "suspend":
			await NetManager.finish_suspend_teardown()
		await _wait_host(results)
		_check(results == [false] and old.data.leaves == 1 and not NetManager.has_session()
			and _successes == 0, lifecycle + " fences late native host")
