extends MultiplayerPeerExtension

## The minimal transport the matchmaking harness binds to the production NetManager.
##
## It reports a chosen unique id and a connected status, announces whichever remote peers a
## test names -- so SceneMultiplayer's own peer bookkeeping and NetManager's peer signals run
## for real -- and records every packet NetManager sends. Nothing is ever delivered: an RPC
## body a test exercises is still NetManager's own, invoked by the test, and none of this
## is evidence about native Party routing or timing.

var unique_id := 1
var status: MultiplayerPeer.ConnectionStatus = MultiplayerPeer.CONNECTION_CONNECTED
var sent: Array[PackedByteArray] = []
var _channel := 0
var _mode: MultiplayerPeer.TransferMode = MultiplayerPeer.TRANSFER_MODE_RELIABLE
var _refusing := false


func _init(id: int = 1) -> void:
	unique_id = id


## Announces a remote peer, as a transport does when one connects.
func connect_remote(peer_id: int) -> void:
	peer_connected.emit(peer_id)


## Announces that a remote peer went away.
func disconnect_remote(peer_id: int) -> void:
	peer_disconnected.emit(peer_id)


func _get_packet_script() -> PackedByteArray:
	return PackedByteArray()


func _put_packet_script(p_buffer: PackedByteArray) -> Error:
	sent.append(p_buffer)
	return OK


func _get_available_packet_count() -> int:
	return 0


func _get_max_packet_size() -> int:
	return 65536


func _get_packet_channel() -> int:
	return 0


func _get_packet_mode() -> MultiplayerPeer.TransferMode:
	return MultiplayerPeer.TRANSFER_MODE_RELIABLE


func _set_transfer_channel(p_channel: int) -> void:
	_channel = p_channel


func _get_transfer_channel() -> int:
	return _channel


func _set_transfer_mode(p_mode: MultiplayerPeer.TransferMode) -> void:
	_mode = p_mode


func _get_transfer_mode() -> MultiplayerPeer.TransferMode:
	return _mode


func _set_target_peer(_p_peer: int) -> void:
	pass


func _get_packet_peer() -> int:
	return 0


func _is_server() -> bool:
	return unique_id == 1


func _poll() -> void:
	pass


func _close() -> void:
	status = MultiplayerPeer.CONNECTION_DISCONNECTED


func _disconnect_peer(p_peer: int, _p_force: bool) -> void:
	peer_disconnected.emit(p_peer)


func _get_unique_id() -> int:
	return unique_id


func _get_connection_status() -> MultiplayerPeer.ConnectionStatus:
	return status


func _is_server_relay_supported() -> bool:
	return false


func _set_refuse_new_connections(p_enable: bool) -> void:
	_refusing = p_enable


func _is_refusing_new_connections() -> bool:
	return _refusing
