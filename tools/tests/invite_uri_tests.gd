extends RefCounted

## XR-064 / XR-124: a Multiplayer Activity invite and a shell "Join Game" carry the
## host's PlayFab Lobby connection string inside the activation URI, and Lobby join
## needs it byte for byte. These drive ActivityService's parser with the URI shapes the
## platform documents, escaped every way it might be, and through the dictionary the
## godot_gdk addon actually hands over.

const CONSOLE := "ms-xbl-7C84AA93://inviteAccept"
const PC := "ms-xbl-multiplayer://inviteAccept"
const INVITED := "2814654472473943"
const SENDER := "2535412345678901"
## The shape PFLobbyGetConnectionString returns, with the `+` and `/` a base64 key
## carries about half the time.
const CS := "cv2:7f94a95e-b2f2-4588-a8b5-804835b7d40f.r-20260323|441014|kv1:7cGx+uLs/yOsvHgoZtbDEOKYE1MUh2B794JgXsu3BoyU="
## XboxActivation's _normalize_invite_key aliases; every other key is lower-cased.
const ADDON_KEYS := {
	"invitedXuid": "invited_xuid",
	"senderXuid": "sender_xuid",
	"joinerXuid": "joiner_xuid",
	"joineeXuid": "joinee_xuid",
}

class PendingActivation extends RefCounted:
	signal invite_accepted(invite: Dictionary)
	var calls := 0
	var result: Variant = {"ok": true, "message": ""}

	func accept_pending_invite(uri: String) -> Variant:
		calls += 1
		if result != null and result.ok:
			invite_accepted.emit({"raw_uri": uri})
		return result


class PendingActivity extends ActivityService:
	var runtime: Variant = {"activation": PendingActivation.new()}

	func _connect_activation() -> void:
		pass

	func _gdk() -> Variant:
		return runtime


func run(test: Node) -> void:
	_connection_string_encodings(test)
	_parameter_boundaries(test)
	_host_xuid_fallback(test)
	_preparsed_fallback(test)
	_percent_decoding(test)
	_unusable_uris(test)
	_activation_logging(test)
	_emits_exact_request(test)
	_router_trace(test)
	_join_trace(test)
	_pending_acceptance(test)


func _pending_acceptance(test: Node) -> void:
	print("CASE: pending acceptance diagnostics preserve platform acceptance and accepted-event routing")
	var activity := PendingActivity.new()
	var requests: Array[Dictionary] = []
	activity.join_requested.connect(func(request: Dictionary) -> void: requests.append(request))
	activity.runtime.activation.invite_accepted.connect(activity._on_invite_accepted)
	var uri := CONSOLE + "?connectionString=" + CS.uri_encode()
	activity._on_pending_invite_received({"raw_uri": uri})
	test._check(activity.runtime.activation.calls == 1 and requests.size() == 1 and _cs(requests[0]) == CS,
		"pending acceptance routes the accepted event exactly once with the exact credential")
	activity.runtime.activation.result = {"ok": false, "message": "Injected pending acceptance failure."}
	activity._on_pending_invite_received({"raw_uri": uri})
	test._check(activity.runtime.activation.calls == 2 and requests.size() == 1,
		"failed platform acceptance does not synthesize a join")
	activity._on_pending_invite_received({})
	test._check(activity.runtime.activation.calls == 2, "missing URI never calls native acceptance")
	activity.runtime = null
	activity._on_pending_invite_received({"raw_uri": uri})
	test._check(requests.size() == 1, "missing runtime never synthesizes a join")


func _router_trace(test: Node) -> void:
	print("CASE: invite trace preserves buffering identity and TTL, bounds wait logs and omits credentials")
	var router: Variant = load("res://scripts/autoload/invite_router.gd").new()
	router._joining = true
	var request := {"connection_string": CS, "xuid": SENDER, "raw_uri": CONSOLE + "?secret=private-marker"}
	router._on_join_requested(request)
	var first := int(router._pending_trace_id)
	var arrived := int(router._pending_since_msec)
	test._check(first > 0 and router._pending_request == request, "trace leaves the exact pending request intact")
	test._check(router._last_wait_reason == "joining" and String(router._trace_wait()).is_empty(),
		"repeated readiness notices do not repeat the same wait log")
	var line: String = router._trace("test_snapshot", first, 17)
	_check_redacted(test, PackedStringArray([line]), [CS, SENDER, "private-marker"], "router snapshot")
	test._check(line.contains("attempt=%d join=17" % first)
		and line.contains("credential_chars=%d host_present=true" % CS.length()),
		"router snapshot correlates only local IDs and credential shape")
	router._clear_pending()
	router._active_trace_id = first
	router._keep_pending(request, arrived)
	test._check(router._pending_trace_id == first and router._pending_since_msec == arrived,
		"cleanup rebuffering preserves the diagnostic attempt and original TTL")
	test._check(String(router._trace_wait()).contains("stage=wait_joining") and String(router._trace_wait()).is_empty(),
		"wait logging restarts once for rebuffering, not every readiness callback")
	router._on_join_requested({"connection_string": "new-credential-marker", "xuid": INVITED})
	test._check(router._pending_trace_id > first and router._pending_request.connection_string == "new-credential-marker",
		"a newer invite gets its own attempt and still replaces the pending request")
	router._pending_since_msec -= int((router.PENDING_TTL_SECONDS + 1.0) * 1000.0)
	router._redeem_pending()
	test._check(router._pending_request.is_empty(), "expiration is still consumed without a join")
	router._on_join_requested(request)
	router.decline_pending_invite()
	test._check(router._pending_request.is_empty() and router._pending_trace_id == 0,
		"decline clears diagnostic identity with the invite")
	router.free()


func _join_trace(test: Node) -> void:
	print("CASE: join trace describes terminal outcomes without player-facing or SDK payload values")
	for outcome: JoinRequest.Outcome in [
		JoinRequest.Outcome.SUCCEEDED, JoinRequest.Outcome.CANCELLED,
		JoinRequest.Outcome.SUPERSEDED, JoinRequest.Outcome.FAILED,
	]:
		var request := JoinRequest.new()
		request.id = 31
		var before := request.trace("test_pending")
		test._check(request.is_pending() and before.contains("join=31") and before.contains("outcome=0"),
			"tracing does not settle a pending join")
		test._check(request.settle(outcome, CS + SENDER), "terminal outcome still settles once")
		var after := request.trace("test_terminal")
		_check_redacted(test, PackedStringArray([after]), [CS, SENDER], "join result")
		test._check(after.contains("outcome=%d" % outcome) and after.contains("reason_present=true"),
			"join result reports outcome and reason presence, never the reason")
		test._check(not request.settle(JoinRequest.Outcome.FAILED, "late") and request.outcome == outcome,
			"logging preserves first-outcome ownership")


func _connection_string_encodings(test: Node) -> void:
	print("CASE: invite and shell-join URIs deliver the Lobby connection string byte for byte")
	var upper := CS.uri_encode()
	test._check(upper.contains("%2B") and upper.contains("%7C") and upper.contains("%3D"),
		"fixture escapes '+', '|' and '='")
	var encodings := {
		"uppercase escapes": upper,
		"lowercase escapes": _lowercase_escapes(upper),
		"unescaped": CS,
	}
	for prefix: String in [CONSOLE, PC]:
		for encoding: String in encodings:
			var uri := "%s?invitedUser=%s&sender=%s&connectionString=%s" % [prefix, INVITED, SENDER, encodings[encoding]]
			var label := "%s, %s" % [prefix.get_slice(":", 0), encoding]
			var invite := ActivityService._join_request_from_invite(_addon_invite(uri))
			test._check(_cs(invite) == CS and String(invite.get("xuid", "x")).is_empty(), "accepted invite: " + label)
			test._check(_cs(ActivityService._join_request_from_uri(uri)) == CS, "protocol activation: " + label)

	# The addon's pre-parsed field is what the title used to read. It has to be lossy
	# here, or the checks above would pass without exercising the raw-URI route.
	var lowercase := _addon_invite(CONSOLE + "?connectionString=" + encodings["lowercase escapes"])
	var unescaped := _addon_invite(CONSOLE + "?connectionString=" + CS)
	test._check(String(lowercase["connectionstring"]) != CS, "addon field mangles lowercase escapes")
	test._check(String(unescaped["connectionstring"]) != CS, "addon field turns '+' into a space")


func _parameter_boundaries(test: Node) -> void:
	print("CASE: the connection string ends at its own parameter, wherever it sits")
	var encoded := CS.uri_encode()
	var checks := {
		"%s?connectionString=%s&invitedUser=%s&sender=%s" % [CONSOLE, encoded, INVITED, SENDER]: CS,
		"%s?&connectionString=%s" % [PC, encoded]: CS,
		"%s?CONNECTIONSTRING=%s" % [CONSOLE, CS]: CS,
		"%s?connectionString=%s&connectionString=other" % [CONSOLE, encoded]: CS,
		"%s?connectionString=cv2:a|1|kv1:AB==" % CONSOLE: "cv2:a|1|kv1:AB==",
	}
	for uri: String in checks:
		test._check(_cs(ActivityService._join_request_from_uri(uri)) == checks[uri], "boundary: " + uri)
		test._check(_cs(ActivityService._join_request_from_invite(_addon_invite(uri))) == checks[uri],
			"boundary via addon payload: " + uri)


func _host_xuid_fallback(test: Node) -> void:
	print("CASE: an activation with no connection string names the host, never the local player")
	var host_uris := [
		"%s?invitedUser=%s&sender=%s" % [CONSOLE, INVITED, SENDER],
		"ms-xbl-multiplayer://activityHandleJoin?&handle=abc-123&joinerXuid=%s&joineeXuid=%s" % [INVITED, SENDER],
		"ms-xbl-multiplayer://inviteHandleAccept?invitedXuid=%s&senderXuid=%s&handle=abc-123" % [INVITED, SENDER],
	]
	for uri: String in host_uris:
		for request: Dictionary in [
			ActivityService._join_request_from_uri(uri),
			ActivityService._join_request_from_invite(_addon_invite(uri)),
		]:
			test._check(String(request.get("xuid", "")) == SENDER and _cs(request).is_empty(), "host XUID from " + uri)

	var local_only := [
		"%s?invitedUser=%s" % [CONSOLE, INVITED],
		"ms-xbl-multiplayer://activityHandleJoin?handle=abc&joinerXuid=%s&invitedXuid=%s" % [INVITED, INVITED],
		"%s?sender=not-a-xuid" % CONSOLE,
	]
	for uri: String in local_only:
		test._check(ActivityService._join_request_from_uri(uri).is_empty(), "no host in " + uri)
		test._check(ActivityService._join_request_from_invite(_addon_invite(uri)).is_empty(), "no host via addon payload in " + uri)


func _preparsed_fallback(test: Node) -> void:
	print("CASE: a payload without raw_uri falls back to its fields, used as given")
	test._check(_cs(ActivityService._join_request_from_invite({"connectionString": CS})) == CS,
		"pre-parsed connection string is not decoded a second time")
	test._check(_cs(ActivityService._join_request_from_invite({"connection_string": "cv2:a%2Bb"})) == "cv2:a%2Bb",
		"pre-parsed value is used as given")
	test._check(String(ActivityService._join_request_from_invite({"sender_xuid": SENDER}).get("xuid", "")) == SENDER,
		"pre-parsed sender XUID alias")
	test._check(String(ActivityService._join_request_from_invite({"raw_uri": "", "joineeXuid": SENDER}).get("xuid", "")) == SENDER,
		"empty raw_uri falls back to camelCase fields")
	var raw_wins := ActivityService._join_request_from_invite({
		"raw_uri": "%s?sender=%s" % [CONSOLE, SENDER],
		"connectionstring": "stale",
	})
	test._check(String(raw_wins.get("xuid", "")) == SENDER and _cs(raw_wins).is_empty(), "raw_uri takes precedence over fields")
	test._check(ActivityService._join_request_from_invite({"connection_string": 42, "sender": 7}).is_empty(),
		"non-string fields are ignored")


func _percent_decoding(test: Node) -> void:
	print("CASE: percent-decoding is one strict pass that leaves '+' alone")
	var cases := {
		"a+b": "a+b",
		"a%2Bb": "a+b",
		"a%2bb": "a+b",
		"%3a%7C%3D": ":|=",
		"%C3%A9": "é",
		"%c3%a9": "é",
		"%C3%aB": "ë",
		"%c3%Ab": "ë",
		"%2541": "%41",
		"%%41": "%A",
		"100%": "100%",
		"%G1": "%G1",
		"ab%4": "ab%4",
		"plain": "plain",
		"": "",
	}
	for input: String in cases:
		test._check(ActivityService._percent_decode(input) == cases[input], "decode '%s'" % input)


func _unusable_uris(test: Node) -> void:
	print("CASE: URIs with nothing to join yield no request")
	for uri: String in [
		"",
		CONSOLE,
		CONSOLE + "?",
		CONSOLE + "?connectionString=",
		CONSOLE + "?connectionString",
		CONSOLE + "?=value",
		"ms-xbl-7C84AA93://default",
	]:
		test._check(ActivityService._join_request_from_uri(uri).is_empty(), "nothing to join in '%s'" % uri)
		test._check(ActivityService._join_request_from_invite(_addon_invite(uri)).is_empty(),
			"nothing to join via addon payload in '%s'" % uri)


func _activation_logging(test: Node) -> void:
	print("CASE: activation logs keep the payload's shape but none of its values")
	var key := CS.get_slice("kv1:", 1)
	var lobby_id := CS.get_slice(":", 1).get_slice(".", 0)
	var secrets: Array[String] = [key, key.uri_encode(), _lowercase_escapes(key.uri_encode()), lobby_id, INVITED, SENDER]
	var encodings := {
		"uppercase escapes": CS.uri_encode(),
		"lowercase escapes": _lowercase_escapes(CS.uri_encode()),
		"unescaped": CS,
	}
	for encoding: String in encodings:
		var uri := "%s?invitedUser=%s&sender=%s&connectionString=%s" % [CONSOLE, INVITED, SENDER, encodings[encoding]]
		for payload: Dictionary in [_addon_invite(uri), {"raw_uri": uri}]:
			var logged := ActivityService._activation_log_lines("Accepted invite", payload, ActivityService._join_request_from_invite(payload))
			_check_redacted(test, logged, secrets, encoding)
			test._check(logged[0] == "[Activity] Accepted invite URI: %s?invitedUser=<16 chars>&sender=<16 chars>&connectionString=<%d chars>" % [
				CONSOLE, String(encodings[encoding]).length()], "URI line keeps keys and value lengths: " + logged[0])
			test._check(logged[1].ends_with("-> connection string (%d chars)" % CS.length()), "parsed line: " + logged[1])

	var no_uri := {"connectionString": CS, "sender_xuid": SENDER}
	var lines := ActivityService._activation_log_lines("Pending invite", no_uri, ActivityService._join_request_from_invite(no_uri))
	_check_redacted(test, lines, secrets, "payload without a URI")
	test._check(lines[0] == "[Activity] Pending invite URI: (none); payload keys: connectionString, sender_xuid",
		"a payload without a URI still gets a URI line: " + lines[0])
	lines = ActivityService._activation_log_lines("Pending invite", {}, {})
	test._check(lines[0] == "[Activity] Pending invite URI: (none); payload keys: (none)" and lines[1].ends_with("-> nothing usable"),
		"an empty payload: " + str(lines))

	var host_only := "%s?invitedUser=%s&sender=%s" % [CONSOLE, INVITED, SENDER]
	lines = ActivityService._activation_log_lines("Protocol activation", {"raw_uri": host_only}, ActivityService._join_request_from_uri(host_only))
	_check_redacted(test, lines, secrets, "host XUID only")
	test._check(lines[1].ends_with("-> host XUID (16 digits)"), "parsed line names a host XUID without printing it: " + lines[1])

	# uri_decode() mangles an escape with a lowercase hex digit in either place, so the
	# summary has to flag %aB and %Ab as well as %3a.
	for uri: String in [CONSOLE + "?x=%3a", CONSOLE + "?x=%C3%aB", CONSOLE + "?x=%C3%Ab"]:
		test._check(ActivityService._describe_activation(uri, {}).contains("lowercase escapes yes"), "lowercase escape flagged in " + uri)
	for uri: String in [CONSOLE + "?x=%3A%7C%2B%C3%AB", CONSOLE + "?x=100%", CONSOLE + "?x=%zz", CONSOLE + "?x=abc"]:
		test._check(ActivityService._describe_activation(uri, {}).contains("lowercase escapes no"), "no lowercase escape in " + uri)


static func _check_redacted(test: Node, lines: PackedStringArray, secrets: Array[String], label: String) -> void:
	var text := "\n".join(lines)
	for secret: String in secrets:
		test._check(not text.contains(secret), "%s: log omits '%s'" % [label, secret.left(12)])


func _emits_exact_request(test: Node) -> void:
	print("CASE: an accepted invite and a protocol join reach join_requested with the exact connection string")
	var activity := ActivityService.new()
	var requests: Array[Dictionary] = []
	activity.join_requested.connect(func(request: Dictionary) -> void: requests.append(request))
	var lowercase := _lowercase_escapes(CS.uri_encode())
	var uri := "%s?invitedUser=%s&sender=%s&connectionString=%s" % [CONSOLE, INVITED, SENDER, lowercase]
	activity._on_invite_accepted(_addon_invite(uri))
	activity._on_protocol_activated(uri.replace(CONSOLE, PC))
	test._check(requests.size() == 2, "both activations emitted a join request")
	for request: Dictionary in requests:
		test._check(_cs(request) == CS, "emitted connection string is exact")

	var summary := ActivityService._describe_activation(uri, ActivityService._join_request_from_uri(uri))
	test._check(summary.contains("lowercase escapes yes") and summary.contains("connection string (%d chars)" % CS.length()),
		"activation log names the escaping and the parsed result: " + summary)


static func _cs(request: Dictionary) -> String:
	return String(request.get("connection_string", ""))


static func _lowercase_escapes(encoded: String) -> String:
	var result := ""
	var index := 0
	while index < encoded.length():
		if encoded[index] == "%" and index + 2 < encoded.length():
			result += "%" + encoded.substr(index + 1, 2).to_lower()
			index += 3
		else:
			result += encoded[index]
			index += 1
	return result


## The dictionary the godot_gdk addon's XboxActivation hands over for an invite
## (make_invite_dictionary_internal), including the String.uri_decode() of every value
## that the parser has to route around.
static func _addon_invite(uri: String) -> Dictionary:
	var data := {"raw_uri": uri, "activation_type": "accepted_game_invite"}
	var trimmed := uri.strip_edges()
	var scheme_end := trimmed.find("://")
	data["scheme"] = trimmed.substr(0, scheme_end) if scheme_end >= 0 else ""
	var remainder := trimmed.substr(scheme_end + 3) if scheme_end >= 0 else trimmed
	var query_start := remainder.find("?")
	data["action"] = (remainder.substr(0, query_start) if query_start >= 0 else remainder).to_lower()
	var query := remainder.substr(query_start + 1) if query_start >= 0 else ""
	if query.begins_with("&"):
		query = query.substr(1)
	for pair: String in query.split("&", false):
		var equals := pair.find("=")
		var key := pair.substr(0, equals) if equals >= 0 else pair
		var value := pair.substr(equals + 1) if equals >= 0 else ""
		data[ADDON_KEYS.get(key, key.to_lower())] = value.uri_decode()
	return data
