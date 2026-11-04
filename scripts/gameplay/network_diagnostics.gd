class_name NetworkDiagnostics
extends RefCounted

## Aggregate counters only. Never retain message contents or account/session identifiers.
const REPORT_INTERVAL_USEC := 5_000_000
const STALL_USEC := 50_000
const PARTY_STATISTICS: PackedStringArray = [
	"currently_queued_send_messages", "currently_queued_send_message_bytes",
	"currently_active_send_messages", "currently_active_send_message_bytes",
	"average_relay_server_round_trip_latency_ms", "retried_protocol_packets",
	"dropped_protocol_packets", "timed_out_send_messages",
]

var _started_usec := -1
var _last_frame_usec := -1
var _frames := 0
var _frame_total_usec := 0
var _frame_max_usec := 0
var _stalls := 0
var _tx: Dictionary = {}
var _rx: Dictionary = {}
var _rx_since_frame := 0
var _rx_between_frames_max := 0
var _snapshot_samples: Dictionary = {}
var _snapshot_count := 0
var _snapshot_stale := 0
var _snapshot_total_usec := 0
var _snapshot_max_usec := 0
var _snapshot_objects_max := 0


func reset() -> void:
	_started_usec = -1
	_last_frame_usec = -1
	_clear_window()


func _clear_window() -> void:
	_frames = 0
	_frame_total_usec = 0
	_frame_max_usec = 0
	_stalls = 0
	_tx.clear()
	_rx.clear()
	_rx_since_frame = 0
	_rx_between_frames_max = 0
	_snapshot_samples.clear()
	_snapshot_count = 0
	_snapshot_stale = 0
	_snapshot_total_usec = 0
	_snapshot_max_usec = 0
	_snapshot_objects_max = 0


func note_frame(now_usec: int) -> void:
	if _started_usec < 0:
		_started_usec = now_usec
	if _last_frame_usec >= 0:
		var elapsed := maxi(now_usec - _last_frame_usec, 0)
		_frames += 1
		_frame_total_usec += elapsed
		_frame_max_usec = maxi(_frame_max_usec, elapsed)
		if elapsed >= STALL_USEC:
			_stalls += 1
	_last_frame_usec = now_usec
	_rx_between_frames_max = maxi(_rx_between_frames_max, _rx_since_frame)
	_rx_since_frame = 0


func note_tx(kind: StringName, recipients: int) -> void:
	_tx[kind] = int(_tx.get(kind, 0)) + recipients


func note_rx(kind: StringName) -> void:
	_rx[kind] = int(_rx.get(kind, 0)) + 1
	_rx_since_frame += 1


func sample_snapshot(direction: StringName, payload: Dictionary) -> void:
	if not _snapshot_samples.has(direction):
		# One serialization per direction per window, not per packet. Not a wire-byte count.
		_snapshot_samples[direction] = var_to_bytes(payload).size()


func note_snapshot(elapsed_usec: int, objects: int, applied: bool) -> void:
	if not applied:
		_snapshot_stale += 1
		return
	_snapshot_count += 1
	_snapshot_total_usec += elapsed_usec
	_snapshot_max_usec = maxi(_snapshot_max_usec, elapsed_usec)
	_snapshot_objects_max = maxi(_snapshot_objects_max, objects)


func is_due(now_usec: int) -> bool:
	return _started_usec >= 0 and now_usec - _started_usec >= REPORT_INTERVAL_USEC


func take_report(now_usec: int, host: bool, player_count: int, peer: MultiplayerPeer) -> Dictionary:
	var report := {
		"window_ms": float(now_usec - _started_usec) / 1000.0,
		"role": "host" if host else "guest",
		"players": player_count,
		"frame_ms_avg": float(_frame_total_usec) / float(maxi(_frames, 1)) / 1000.0,
		"frame_ms_max": float(_frame_max_usec) / 1000.0,
		"frames_ge_50ms": _stalls,
		"tx_attempted": _tx.duplicate(),
		"rx_accepted": _rx.duplicate(),
		"rx_between_frames_max": maxi(_rx_between_frames_max, _rx_since_frame),
		"snapshot_variant_bytes_sample": _snapshot_samples.duplicate(),
		"snapshot_applied": _snapshot_count,
		"snapshot_stale": _snapshot_stale,
		"snapshot_apply_ms_total": float(_snapshot_total_usec) / 1000.0,
		"snapshot_apply_ms_max": float(_snapshot_max_usec) / 1000.0,
		"snapshot_objects_max": _snapshot_objects_max,
		"transport": transport_sample(peer),
	}
	_clear_window()
	_started_usec = now_usec
	return report


static func transport_sample(peer: MultiplayerPeer) -> Dictionary:
	var sample := {"party_statistics": "unavailable"}
	if peer == null:
		return sample
	sample["receive_queue_sample"] = peer.get_available_packet_count()
	if not peer.has_method(&"get_network"):
		return sample
	var network: Variant = peer.call(&"get_network")
	if not (network is Object) or not network.has_method(&"get_statistics"):
		return sample
	var statistics: Variant = network.call(&"get_statistics")
	if not (statistics is Dictionary) or statistics.is_empty():
		return sample
	sample["party_statistics"] = "available"
	for key in PARTY_STATISTICS:
		var value: Variant = statistics.get(key)
		if value is int or value is float:
			sample[key] = value
	return sample
