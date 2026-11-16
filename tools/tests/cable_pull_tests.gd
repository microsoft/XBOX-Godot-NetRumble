extends RefCounted

## Network loss injected at each transition a cable pull can land in: inside the Party
## notice itself, while the lobby closes the match to start it, while the gameplay screen
## builds its world, and during the start countdown. Every case asserts that the loss is not
## acted on inside the notice that reported it, and that the player ends on the main menu
## behind exactly one error dialog, with no session and nothing of the match left behind.

const MP := preload("res://tools/tests/multiplayer_failure_tests.gd")
## Actions the live world polls each tick. The test project carries no input map, so the
## run registers them and removes them again.
const WORLD_ACTIONS: Array[StringName] = [
	&"click", &"deploy_mine", &"move_left", &"move_right", &"move_up", &"move_down",
	&"fire_left", &"fire_right", &"fire_up", &"fire_down",
]


## Lobby rosters and chat policy query chat controls; chat controls are not under test here.
class Chat extends MP.Chat:
	func chat_indicator_for(_entity_key: Dictionary) -> ChatIndicator:
		return ChatIndicator.NONE

	func _local_chat_control() -> Variant:
		return null


## Holds the match-start lobby lock open until a case releases it, so a loss can land
## while the lobby is waiting on close_joins().
class Party extends MP.Party:
	signal lock_released()
	var hold_lock := false

	func set_lobby_locked(_locked: bool) -> Dictionary:
		if hold_lock:
			await lock_released
		return {"ok": true}


var _test: Node
var _party: Party
var _chat: Chat
var _disconnects := 0
var _world: Node2D
var _background: CanvasLayer


func run(test: Node) -> void:
	_test = test
	var old_chat: ChatService = Services._chat
	var old_party: PartyService = Services._party
	var old_world := ScreenManager.world_container
	var old_background := ScreenManager.background_container
	var audio_script: Script = AudioManager.get_script()
	AudioManager.set_script(MP.QuietAudio)
	_world = Node2D.new()
	_background = CanvasLayer.new()
	test.add_child(_background)
	test.add_child(_world)
	ScreenManager.set_world_containers(_world, _background)
	var added_actions: Array[StringName] = []
	for action in WORLD_ACTIONS:
		if not InputMap.has_action(action):
			InputMap.add_action(action)
			added_actions.append(action)
	NetManager.server_disconnected.connect(_disconnected)
	await _party_notice_loss()
	await _transport_host_loss()
	await _loss_while_closing_joins()
	await _loss_during_world_init()
	await _session_end_during_world_init()
	await _loss_during_countdown()
	await _client_host_loss()
	await _lobby_notice_continuity()
	await _dispose()
	NetManager.server_disconnected.disconnect(_disconnected)
	NetManager._clock = Time.get_ticks_msec
	for action in added_actions:
		InputMap.erase_action(action)
	ScreenManager.set_world_containers(old_world, old_background)
	_world.queue_free()
	_background.queue_free()
	Services._chat = old_chat
	Services._party = old_party
	AudioManager.set_script(audio_script)


func _disconnected() -> void:
	_disconnects += 1


func _check(condition: bool, message: String) -> void:
	_test._check(condition, "cable pull: " + message)


func _frames(count: int = 3) -> void:
	for index in count:
		await _test.get_tree().process_frame


func _poll() -> void:
	await _test.get_tree().create_timer(0.12).timeout


func _fixture() -> void:
	await _dispose()
	await _test._reset()
	_test._select("cable-pull", _test._folder())
	_check(await Services.sign_in(), "fixture account ready")
	_chat = Chat.new()
	_party = Party.new(_chat)
	_chat.sdk = _party.runtime.party
	Services._chat = _chat
	Services._party = _party
	Services._connectivity = ConnectivityService.new()
	Services._connectivity.connectivity_changed.connect(NetManager._on_connectivity_changed)
	NetManager._connect_party(_party)
	NetManager._clock = _party.clock.now
	ScreenManager.set_container(_test)
	_disconnects = 0


func _dispose() -> void:
	ScreenManager.clear()
	if _party == null:
		return
	_party.hold_lock = false
	_party.lock_released.emit()
	for backend: MP.Backend in [_party.runtime.party, _party.runtime.multiplayer]:
		for operation: MP.Operation in backend.calls.duplicate():
			operation.finish(false)
	if NetManager._active_join_request != null:
		NetManager.cancel_join(NetManager._active_join_request)
	await _poll()
	await NetManager.leave_match_and_wait()
	await _chat.destroy_control()
	_party.runtime.party.dispose()
	_party.runtime.multiplayer.dispose()
	Services._party = null
	Services._chat = null
	_party = null
	_chat = null
	# A roster change queues a half-second activity refresh; let it run out so the last case
	# leaves nothing sleeping on the clock at exit.
	for index in 10:
		if not NetManager._platform._activity_update_queued:
			break
		await _poll()
	await _frames()


func _join() -> bool:
	var request := NetManager.join_by_invite("fixture")
	NetManager._on_connected_to_server()
	NetManager._accept_join()
	for index in 30:
		if not request.is_pending():
			break
		await _poll()
	return request.succeeded()


func _terminal_kinds() -> Array:
	return [
		[PartyService.NETWORK_CHANGE_STATE, PartyService.NETWORK_STATE_DISCONNECTED, "DISCONNECTED"],
		[PartyService.NETWORK_CHANGE_STATE, PartyService.NETWORK_STATE_FAILED, "FAILED"],
		[PartyService.NETWORK_CHANGE_DESTROYED, PartyService.NETWORK_STATE_DISCONNECTED, "DESTROYED"],
	]


## Pulls the cable the way Party reports it: a terminal change on the bound network.
func _pull(kind: Array) -> void:
	_party._network.change(int(kind[0]), int(kind[1]))


## What NetManager has done by the time the native notice finishes, recorded by a listener
## connected after PartyService's own.
func _record_inside_notice(network: MP.Network, seen: Array) -> Callable:
	var record := func(_change: Variant) -> void:
		seen.append({
			"session": NetManager.has_session(),
			"leaves": network.leaves,
			"bound": NetManager.multiplayer.multiplayer_peer != null and not (NetManager.multiplayer.multiplayer_peer is OfflineMultiplayerPeer),
			"disconnects": _disconnects,
		})
	network.state_changed.connect(record)
	return record


func _party_notice_loss() -> void:
	print("CASE: a Party network loss is acted on after the native notice returns, never inside it")
	for role: String in ["host", "guest"]:
		for kind: Array in _terminal_kinds():
			await _fixture()
			var label := "%s %s" % [role, kind[2]]
			_check(await NetManager.host_match() if role == "host" else await _join(), label + " session established")
			var network: MP.Network = _party._network
			var seen: Array = []
			var record := _record_inside_notice(network, seen)
			_pull(kind)
			network.state_changed.disconnect(record)
			_check(seen.size() == 1 and bool(seen[0].session) and int(seen[0].leaves) == 0
				and bool(seen[0].bound) and int(seen[0].disconnects) == 0,
				label + ": no leave, peer detach or disconnect inside the notice: %s" % [seen])
			await _poll()
			_check(not NetManager.has_session() and _disconnects == 1,
				label + ": the session ends exactly once after the notice")
			var expected_leaves := 0 if int(kind[0]) == PartyService.NETWORK_CHANGE_DESTROYED else 1
			_check(network.leaves == expected_leaves, label + ": the lost network is left %d time(s)" % expected_leaves)


func _transport_host_loss() -> void:
	print("CASE: the host vanishing from a guest's transport is acted on after the transport notice")
	await _fixture()
	_check(await _join(), "guest session established")
	var peer: MultiplayerPeer = NetManager.multiplayer.multiplayer_peer
	var network: MP.Network = _party._network
	peer.peer_connected.emit(NetManager.HOST_PEER_ID)
	await _frames(1)
	peer.peer_disconnected.emit(NetManager.HOST_PEER_ID)
	_check(NetManager.has_session() and NetManager.multiplayer.multiplayer_peer == peer
		and network.leaves == 0 and _disconnects == 0,
		"the transport is not detached and Party is not left inside the peer notice")
	await _poll()
	_check(not NetManager.has_session() and _disconnects == 1
		and NetManager.last_disconnect_reason == "The host left the match.",
		"the host's departure ends the guest's session once, after the notice")


## Hosts a two-player match whose remote player is ready and loaded, and shows the lobby.
func _ready_lobby() -> NRScreen:
	_check(await NetManager.host_match(), "host session established")
	var guest := PlayerState.new()
	guest.peer_id = 2
	guest.display_name = "Fixture Guest"
	guest.is_ready = true
	guest.in_game = true
	NetManager.players[2] = guest
	return ScreenManager.replace_all(ScreenManager.LOBBY)


func _dialogs() -> Array[NRScreen]:
	var found: Array[NRScreen] = []
	for child: Node in _test.get_children():
		if child is NRScreen and child.scene_file_path == ScreenManager.DIALOG_BOX and not child.is_queued_for_deletion():
			found.append(child)
	return found


## One error dialog, dismissed, lands on the main menu with nothing of the match left.
func _expect_menu(label: String) -> void:
	await _poll()
	var dialogs := _dialogs()
	_check(dialogs.size() == 1, label + ": exactly one error dialog (got %d)" % dialogs.size())
	_check(not NetManager.has_session() and _disconnects == 1, label + ": the session ended once")
	if not dialogs.is_empty():
		dialogs[0].dismissed.emit(false)
	await _poll()
	var screen := ScreenManager.current_screen()
	_check(screen != null and screen.scene_file_path == ScreenManager.MAIN_MENU and ScreenManager.get_stack_size() == 1,
		label + ": the player is returned to the main menu")
	_check(_world.get_child_count() == 0 and _background.get_child_count() == 0,
		label + ": no world, starfield or camera outlives the match")


func _loss_while_closing_joins() -> void:
	print("CASE: a loss while the lobby closes the match to start it never reaches gameplay")
	for kind: Array in _terminal_kinds():
		await _fixture()
		_party.hold_lock = true
		await _ready_lobby()
		NetManager.set_local_ready(true)
		await _frames(1)
		_pull(kind)
		await _poll()
		_party.hold_lock = false
		_party.lock_released.emit()
		await _expect_menu("close_joins " + String(kind[2]))


func _loss_during_world_init() -> void:
	print("CASE: a native loss while the gameplay screen builds its world is routed by gameplay")
	for kind: Array in _terminal_kinds():
		await _fixture()
		await _ready_lobby()
		var pulled := [false]
		_world.child_entered_tree.connect(func(_node: Node) -> void:
			if not pulled[0]:
				pulled[0] = true
				_pull(kind), CONNECT_ONE_SHOT)
		NetManager.set_local_ready(true)
		await _frames(1)
		_check(pulled[0], "world init %s: the loss landed inside the handoff" % kind[2])
		await _expect_menu("world init " + String(kind[2]))


func _session_end_during_world_init() -> void:
	print("CASE: a session ended synchronously while gameplay builds its world still reaches the menu")
	await _fixture()
	await _ready_lobby()
	_world.child_entered_tree.connect(func(_node: Node) -> void:
		NetManager._on_server_disconnected("Injected end during world init."), CONNECT_ONE_SHOT)
	NetManager.set_local_ready(true)
	await _frames(1)
	await _expect_menu("synchronous end during world init")


func _loss_during_countdown() -> void:
	print("CASE: a loss during the start countdown is routed once to the menu")
	for kind: Array in _terminal_kinds():
		await _fixture()
		await _ready_lobby()
		NetManager.set_local_ready(true)
		var gameplay: Variant = null
		for index in 60:
			gameplay = ScreenManager.current_screen()
			if gameplay != null and gameplay.scene_file_path == ScreenManager.GAMEPLAY and gameplay._director != null \
					and gameplay._director.match_state == NRTypes.MatchState.STARTING:
				break
			await _frames(1)
		_check(gameplay != null and gameplay.scene_file_path == ScreenManager.GAMEPLAY and gameplay._director != null
			and gameplay._director.match_state == NRTypes.MatchState.STARTING,
			"countdown %s: the match reached its start countdown" % kind[2])
		_pull(kind)
		await _expect_menu("countdown " + String(kind[2]))


func _guest_screen(state: NRTypes.MatchState) -> Variant:
	_check(await _join(), "guest session established")
	_party._lobby.members.append({
		"entity_key": {"id": "2", "type": "title_player_account"},
		"connection_status": 1, "properties": {},
	})
	var host := PlayerState.new()
	host.peer_id = NetManager.HOST_PEER_ID
	host.display_name = "Fixture Host"
	host.in_game = true
	NetManager.players[host.peer_id] = host
	NetManager.multiplayer.multiplayer_peer.peer_connected.emit(host.peer_id)
	if state == NRTypes.MatchState.LOADING:
		return ScreenManager.replace_all(ScreenManager.LOBBY)
	var gameplay: Variant = ScreenManager.replace_all(ScreenManager.GAMEPLAY)
	NetManager._set_match_state(state)
	if state == NRTypes.MatchState.STARTING:
		NetManager._receive_countdown(3)
		_check(gameplay._countdown_label.text == "3", "guest displays the host countdown")
	return gameplay


func _client_host_loss() -> void:
	print("CASE: lobby and network host departures return guests to the menu during lobby, loading, countdown and play")
	for state: NRTypes.MatchState in [NRTypes.MatchState.LOADING, NRTypes.MatchState.PLAYERS_JOINING,
			NRTypes.MatchState.STARTING, NRTypes.MatchState.RUNNING]:
		for loss: String in ["transport", "network_peer", "owner_removed", "owner_changed", "owner_cleared", "owner_disconnected"]:
			await _fixture()
			await _guest_screen(state)
			var label := "guest state=%d loss=%s" % [state, loss]
			_check(not NetManager.is_host(), label + ": this is a client, not the host")
			match loss:
				"transport":
					NetManager.multiplayer.multiplayer_peer.peer_disconnected.emit(NetManager.HOST_PEER_ID)
				"network_peer":
					_party._network.state_changed.emit({
						"kind": PartyService.NETWORK_CHANGE_PEER_LEFT,
						"network": _party._network, "peer_id": NetManager.HOST_PEER_ID,
					})
				_:
					match loss:
						"owner_removed":
							_party._lobby.members.remove_at(0)
						"owner_changed":
							_party._lobby.owner_entity_key = {"id": "2", "type": "title_player_account"}
						"owner_cleared":
							_party._lobby.owner_entity_key = {}
						"owner_disconnected":
							_party._lobby.members[0]["connection_status"] = 0
					_party._lobby.state_changed.emit({"kind": PartyService.LOBBY_CHANGE_OWNER_CHANGED})
			_check(NetManager.has_session() and _disconnects == 0,
				label + ": teardown waits for the native notice")
			await _expect_menu(label)

	print("CASE: a guest in the countdown also returns on every terminal network notice or server disconnect")
	for kind: Array in _terminal_kinds():
		await _fixture()
		await _guest_screen(NRTypes.MatchState.STARTING)
		_pull(kind)
		await _expect_menu("guest countdown " + String(kind[2]))
	await _fixture()
	await _guest_screen(NRTypes.MatchState.STARTING)
	NetManager.multiplayer.server_disconnected.emit()
	await _expect_menu("guest countdown server disconnect")


func _lobby_notice_continuity() -> void:
	print("CASE: healthy lobby updates and a local-only lobby drop preserve a countdown; host loss behind a popup is deduplicated")
	await _fixture()
	await _guest_screen(NRTypes.MatchState.STARTING)
	ScreenManager.push(ScreenManager.GAME_MENU)
	var lobby: MP.Lobby = _party._lobby
	lobby.state_changed.emit({"kind": PartyService.LOBBY_CHANGE_OWNER_CHANGED})
	await _frames()
	_check(NetManager.has_session() and _disconnects == 0, "a healthy host survives a lobby update")
	lobby.disconnected = true
	lobby.state_changed.emit({"kind": PartyService.LOBBY_CHANGE_DISCONNECTED})
	await _frames()
	_check(NetManager.has_session() and _disconnects == 0,
		"an admitted client losing only its lobby connection preserves its Party session")
	lobby.members[0]["connection_status"] = 0
	lobby.state_changed.emit({"kind": PartyService.LOBBY_CHANGE_OWNER_CHANGED})
	var network: MP.Network = _party._network
	network.state_changed.emit({
		"kind": PartyService.NETWORK_CHANGE_PEER_LEFT, "network": network,
		"peer_id": NetManager.HOST_PEER_ID,
	})
	NetManager.multiplayer.multiplayer_peer.peer_disconnected.emit(NetManager.HOST_PEER_ID)
	await _expect_menu("host loss behind countdown popup from lobby and both peer notices")
	_check(not lobby.state_changed.is_connected(_party._on_lobby_changed.bind(lobby)),
		"leaving disconnects the lobby observer")
	await _poll()
	_check(await _join(), "a replacement session can be joined")
	lobby.state_changed.emit({"kind": PartyService.LOBBY_CHANGE_OWNER_CHANGED})
	await _frames()
	_check(NetManager.has_session() and _disconnects == 1,
		"the retired lobby cannot end its replacement session")
