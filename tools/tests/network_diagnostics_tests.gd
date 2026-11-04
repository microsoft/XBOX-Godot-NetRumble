extends RefCounted


class Network extends RefCounted:
	var calls := 0
	var statistics := {
		"currently_queued_send_messages": 42,
		"currently_queued_send_message_bytes": 8192,
		"currently_active_send_messages": 3,
		"currently_active_send_message_bytes": 1024,
		"average_relay_server_round_trip_latency_ms": 80,
		"retried_protocol_packets": 12,
		"dropped_protocol_packets": 2,
		"timed_out_send_messages": 1,
		"connection_string": "never-log-this-credential",
	}

	func get_statistics() -> Dictionary:
		calls += 1
		return statistics


class Peer extends MultiplayerPeerExtension:
	var network := Network.new()
	var queued := 7

	func _get_available_packet_count() -> int:
		return queued

	func get_network() -> Variant:
		return network


class ReportingDiagnostics extends NetworkDiagnostics:
	var report_due := false

	func is_due(now_usec: int) -> bool:
		return report_due or super.is_due(now_usec)

	func take_report(now_usec: int, host: bool, player_count: int, peer: MultiplayerPeer) -> Dictionary:
		report_due = false
		return super.take_report(now_usec, host, player_count, peer)


func run(test: Node) -> void:
	print("CASE: network diagnostics aggregate five-second windows without retaining payloads")
	var diagnostics := NetworkDiagnostics.new()
	var peer := Peer.new()
	test._check(not diagnostics.is_due(10_000_000), "no report before the first active frame")
	diagnostics.note_frame(0)
	diagnostics.note_frame(16_000)
	diagnostics.note_tx(&"_receive_world_snapshot", 3)
	diagnostics.note_tx(&"_receive_world_snapshot", 3)
	diagnostics.note_rx(&"_receive_world_snapshot")
	diagnostics.note_rx(&"_receive_ship_destroyed")
	diagnostics.note_snapshot(1200, 32, true)
	diagnostics.note_snapshot(400, 16, true)
	diagnostics.note_snapshot(0, 0, false)
	var payload := {"frame": 1, "objects": [], "secret": "never-log-this-payload"}
	var sample_bytes := var_to_bytes(payload).size()
	diagnostics.sample_snapshot(&"rx", payload)
	payload["extra"] = "sample only once per window"
	diagnostics.sample_snapshot(&"rx", payload)
	test._check(peer.network.calls == 0, "native statistics are not read for each message")
	test._check(not diagnostics.is_due(4_999_999) and diagnostics.is_due(5_000_000),
		"report cadence is five monotonic seconds")
	diagnostics.note_frame(5_000_000)
	var report := diagnostics.take_report(5_000_000, true, 4, peer)
	test._check(report.window_ms == 5000.0 and report.role == "host" and report.players == 4,
		"window has non-identifying role and population")
	test._check(report.tx_attempted == {&"_receive_world_snapshot": 6}
		and report.rx_accepted == {&"_receive_world_snapshot": 1, &"_receive_ship_destroyed": 1},
		"outbound counts multiply by recipients; inbound counts individual messages")
	test._check(report.frame_ms_max == 4984.0 and report.frame_ms_avg == 2500.0
		and report.frames_ge_50ms == 1 and report.rx_between_frames_max == 2,
		"wall-clock stalls and receive bursts are measured")
	test._check(report.snapshot_applied == 2 and report.snapshot_stale == 1
		and is_equal_approx(report.snapshot_apply_ms_total, 1.6)
		and is_equal_approx(report.snapshot_apply_ms_max, 1.2) and report.snapshot_objects_max == 32,
		"snapshot application duration and stale arrivals are separate")
	test._check(report.snapshot_variant_bytes_sample == {&"rx": sample_bytes},
		"snapshot sample is a byte count and only sampled once per window")
	test._check(report.transport.party_statistics == "available"
		and report.transport.receive_queue_sample == 7
		and report.transport.currently_queued_send_messages == 42
		and report.transport.currently_queued_send_message_bytes == 8192
		and peer.network.calls == 1, "native counters are sampled once per report")
	var text := JSON.stringify(report)
	test._check(not text.contains("never-log") and not text.contains("connection_string")
		and not text.contains("secret"), "payloads and unapproved native fields never reach the log")

	print("CASE: diagnostics windows and session teardown cannot leak old measurements")
	diagnostics.note_frame(5_016_000)
	test._check(not diagnostics.is_due(9_999_999) and diagnostics.is_due(10_000_000),
		"taking a report starts a fresh interval")
	var next := diagnostics.take_report(10_000_000, false, 2, null)
	test._check(next.tx_attempted.is_empty() and next.rx_accepted.is_empty()
		and next.snapshot_variant_bytes_sample.is_empty() and next.snapshot_applied == 0
		and next.snapshot_stale == 0 and next.snapshot_apply_ms_total == 0.0,
		"report dictionaries are independent and window counts reset")
	test._check(report.tx_attempted[&"_receive_world_snapshot"] == 6
		and next.frame_ms_max == 16.0 and next.role == "guest",
		"previous report stays intact and next frame timing crosses the report boundary")
	diagnostics.note_rx(&"_receive_ship_input")
	diagnostics.reset()
	diagnostics.note_frame(20_000_000)
	test._check(not diagnostics.is_due(24_999_999), "new session has its own baseline")
	var fresh := diagnostics.take_report(25_000_000, false, 2, null)
	test._check(fresh.rx_accepted.is_empty() and fresh.frame_ms_max == 0.0
		and fresh.rx_between_frames_max == 0, "session reset forgets traffic and timing")

	print("CASE: unavailable Party statistics are explicit, not a zero queue claim")
	test._check(NetworkDiagnostics.transport_sample(null) == {"party_statistics": "unavailable"},
		"no peer is explicitly unavailable")
	var offline := OfflineMultiplayerPeer.new()
	var unsupported := NetworkDiagnostics.transport_sample(offline)
	test._check(unsupported.party_statistics == "unavailable"
		and not unsupported.has("currently_queued_send_messages"),
		"peer without a native network never claims zero queued sends")
	peer.network.statistics = {}
	var missing := NetworkDiagnostics.transport_sample(peer)
	test._check(missing.party_statistics == "unavailable" and missing.receive_queue_sample == 7,
		"empty native result preserves only the observable receive queue")
	peer.network.statistics = {"currently_queued_send_messages": "never-log-this-invalid-value"}
	var invalid := NetworkDiagnostics.transport_sample(peer)
	test._check(not invalid.has("currently_queued_send_messages"),
		"only numeric whitelisted native statistics are retained")
	await _production_wiring(test)


func _production_wiring(test: Node) -> void:
	print("CASE: production frame logger, snapshot handler and detach use the diagnostics")
	await test._reset()
	var saved_diagnostics: NetworkDiagnostics = NetManager._network_diagnostics
	var saved_peer: MultiplayerPeer = NetManager._peer
	var saved_offline: bool = NetManager._is_offline
	var diagnostics := ReportingDiagnostics.new()
	var peer := Peer.new()
	NetManager._network_diagnostics = diagnostics
	NetManager._peer = peer
	NetManager._is_offline = false
	NetManager._process(0.0)
	NetManager._note_network_rx(&"_receive_world_snapshot")
	var world := World.new()
	var sync := WorldNetworkSync.new(world)
	sync._on_world_snapshot_received({"frame": 1, "objects": []})
	sync._on_world_snapshot_received({"frame": 1, "objects": []})
	var report := diagnostics.take_report(Time.get_ticks_usec(), false, 2, null)
	test._check(report.rx_accepted == {&"_receive_world_snapshot": 1}
		and report.snapshot_applied == 1 and report.snapshot_stale == 1
		and world.last_world_data_frame == 1, "production receive and snapshot paths are measured")
	diagnostics.reset()
	NetManager._process(0.0)
	diagnostics.report_due = true
	NetManager._process(0.0)
	test._check(peer.network.calls == 1 and not diagnostics.is_due(Time.get_ticks_usec()),
		"production process prints and consumes one due report")
	NetManager._process(0.0)
	test._check(peer.network.calls == 1, "subsequent frames do not spam reports or native reads")
	NetManager._is_offline = true
	diagnostics.reset()
	NetManager._process(0.0)
	test._check(not diagnostics.is_due(Time.get_ticks_usec() + NetworkDiagnostics.REPORT_INTERVAL_USEC),
		"Practice does not start the network logger")
	NetManager._is_offline = false
	diagnostics.note_rx(&"_receive_ship_input")
	NetManager._detach_peer()
	var cleared := diagnostics.take_report(Time.get_ticks_usec(), false, 0, null)
	test._check(cleared.rx_accepted.is_empty(), "transport detach clears the diagnostic window")
	NetManager._network_diagnostics = saved_diagnostics
	NetManager._peer = saved_peer
	NetManager._is_offline = saved_offline
	world.free()
