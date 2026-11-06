extends RefCounted


class Result extends RefCounted:
	var ok := true
	var data: Variant
	var code := "ok"
	var hresult := 0
	var message := ""


class Achievement extends RefCounted:
	var id: String
	var progress_percent: int
	var unlocked: bool

	func _init(value: String, percent: int, earned: bool = false) -> void:
		id = value
		progress_percent = percent
		unlocked = earned


class Request extends RefCounted:
	signal completed(result: Variant)
	var user: Variant
	var id := ""
	var percent := 0


class Endpoints extends RefCounted:
	var queries: Array[Request] = []
	var updates: Array[Request] = []
	var invites: Array[Request] = []
	var cache: Dictionary = {}

	# Mirrors the addon contract: a successful query populates the per-user cache read
	# via get_cached_achievements(). The result's data is cleared so callers can't rely on it.
	func query_player_achievements_async(user: Variant) -> Signal:
		var request := Request.new()
		request.user = user
		request.completed.connect(func(result: Variant) -> void:
			if result != null and result.ok:
				cache[user] = result.data if result.data is Array else []
				result.data = null)
		queries.append(request)
		return request.completed

	func get_cached_achievements(user: Variant) -> Array:
		return cache.get(user, [])

	func update_achievement_async(user: Variant, id: String, percent: int) -> Signal:
		var request := Request.new()
		request.user = user
		request.id = id
		request.percent = percent
		updates.append(request)
		return request.completed

	func show_invite_ui_async(user: Variant) -> Signal:
		var request := Request.new()
		request.user = user
		invites.append(request)
		return request.completed


class Reports extends AchievementService:
	var sdk := Endpoints.new()
	var warnings: Array[String] = []
	var available := true

	func _gdk() -> Variant:
		return {"achievements": sdk} if available else null

	func _warn(message: String) -> void:
		warnings.append(message)


class Activity extends ActivityService:
	var sdk := Endpoints.new()
	var warnings: Array[String] = []

	func _connect_activation() -> void:
		pass

	func _multiplayer_activity() -> Variant:
		return sdk

	func _warn_invite_ui(message: String) -> void:
		warnings.append(message)


func run(test: Node) -> void:
	_cached_progress(test)
	_serialized_progress(test)
	_read_failures(test)
	_submission_races(test)
	_separate_users(test)
	_replacement_queue(test)
	await _account_boundaries(test)
	_invite_outcomes(test)


func _ok(data: Variant = null) -> Result:
	var result := Result.new()
	result.data = data
	return result


func _error(hr: int, code: String = "achievement_update_submit_failed") -> Result:
	var result := Result.new()
	result.ok = false
	result.hresult = hr
	result.code = code
	result.message = "Injected failure 0x%08X" % (hr & 0xFFFFFFFF)
	return result


func _cached_progress(test: Node) -> void:
	print("CASE: achievement replay skips only confirmed equal, higher or unlocked Xbox progress")
	var user := RefCounted.new()
	for entry: Achievement in [
		Achievement.new("6", 20), Achievement.new("6", 40),
		Achievement.new("6", 100), Achievement.new("6", 0, true),
	]:
		var service := Reports.new()
		service.update_progress(user, "6", 20)
		test._check(service.sdk.queries.size() == 1 and service.sdk.updates.is_empty(),
			"progress waits for Xbox's initial cache before sending anything")
		service.sdk.queries[0].completed.emit(_ok([entry]))
		test._check(service.sdk.updates.is_empty() and service.warnings.is_empty()
			and service._pending.is_empty(), "replayed cached progress is a clean no-op")

	var service := Reports.new()
	service.update_progress(null, "6", 20)
	service.update_progress(user, "", 20)
	service.update_progress(user, "6", 0)
	service.update_progress(user, "6", -1)
	service.available = false
	service.update_progress(user, "6", 20)
	test._check(service.sdk.queries.is_empty() and service._pending.is_empty(),
		"no user, no platform or no progress starts no query or update")


func _serialized_progress(test: Node) -> void:
	print("CASE: overlapping achievement reports coalesce without overlapping native writes")
	var service := Reports.new()
	var sdk := service.sdk
	var user := RefCounted.new()
	service.update_progress(user, "6", 20)
	service.update_progress(user, "6", 40)
	service.update_progress(user, "6", 30)
	service.update_progress(user, "8", 12)
	test._check(sdk.queries.size() == 1, "same-user reports share the pending cache query")
	sdk.queries[0].completed.emit(_ok([Achievement.new("6", 0), Achievement.new("8", 0)]))
	test._check(sdk.updates.size() == 1 and sdk.updates[0].id == "6"
		and sdk.updates[0].percent == 40 and sdk.updates[0].user == user,
		"first update uses the highest queued percentage and its original user")
	service.update_progress(user, "6", 80)
	service.update_progress(user, "6", 60)
	sdk.updates[0].completed.emit(_ok(Achievement.new("6", 40)))
	test._check(sdk.updates.size() == 2 and sdk.updates[1].id == "8"
		and sdk.updates[1].percent == 12, "second achievement waits for the first native completion")
	sdk.updates[1].completed.emit(_ok(Achievement.new("8", 12)))
	test._check(sdk.queries.size() == 2 and sdk.updates.size() == 2,
		"reports arriving during a write re-read Xbox rather than trusting a submitted value")
	sdk.queries[1].completed.emit(_ok([Achievement.new("6", 40)]))
	test._check(sdk.updates.size() == 3 and sdk.updates[2].percent == 80,
		"late progress keeps its maximum rather than rolling back to a later lower report")
	sdk.updates[2].completed.emit(_ok(Achievement.new("6", 80)))
	test._check(service._pending.is_empty() and service.warnings.is_empty(),
		"completed queue releases its user and logs no failure")
	service.update_progress(user, "6", 200)
	sdk.queries[2].completed.emit(_ok([Achievement.new("6", 80)]))
	test._check(sdk.updates[3].percent == 100, "progress still clamps to a full unlock")
	sdk.updates[3].completed.emit(_ok(Achievement.new("6", 100, true)))


func _read_failures(test: Node) -> void:
	print("CASE: achievement query failures and unpublished ids remain explicit failures")
	for reply: Variant in [null, _error(0x80004005, "achievement_cache_read_failed"), _ok(), _ok([])]:
		var service := Reports.new()
		var read_ok: bool = reply != null and reply.ok
		service.update_progress(RefCounted.new(), "6", 20)
		service.sdk.queries[0].completed.emit(reply)
		test._check(service.sdk.updates.is_empty() and service.warnings.size() == 1
			and service._pending.is_empty(), "failed/malformed/missing-id read never authorizes a write")
		if read_ok:
			test._check(service.warnings[0].contains("missing from Xbox's cache"),
				"missing configured achievement names the configuration problem")


func _submission_races(test: Node) -> void:
	print("CASE: a redundant-progress HRESULT is harmless only after Xbox confirms the requested state")
	for hr: int in [0x8000FFFF, -2147418113, 0x80070057, -2147024809, 0x8007139F]:
		for confirmed: bool in [true, false]:
			var service := Reports.new()
			var percent := 100 if (hr & 0xFFFFFFFF) == 0x8000FFFF else 20
			service.update_progress(RefCounted.new(), "6", percent)
			service.sdk.queries[0].completed.emit(_ok([Achievement.new("6", 0)]))
			service.sdk.updates[0].completed.emit(_error(hr))
			test._check(service.sdk.queries.size() == 2 and service.warnings.is_empty(),
				"candidate redundant rejection refreshes the cache before deciding")
			service.sdk.queries[1].completed.emit(_ok([Achievement.new("6", percent if confirmed else 0)]))
			test._check(service.warnings.size() == (0 if confirmed else 1)
				and service._pending.is_empty(), "unconfirmed HRESULT is never silently treated as success")
			if not confirmed:
				test._check(service.warnings[0].contains("0x%08X" % (hr & 0xFFFFFFFF)),
					"genuine failure retains the native HRESULT")

	for reply: Variant in [
		null, _error(0x80004005), _error(0x80070057, "invalid_user"),
	]:
		var service := Reports.new()
		var user := RefCounted.new()
		service.update_progress(user, "6", 20)
		service.sdk.queries[0].completed.emit(_ok([Achievement.new("6", 0)]))
		service.sdk.updates[0].completed.emit(reply)
		test._check(service.warnings.size() == 1 and service.sdk.queries.size() == 1,
			"null, unrelated HRESULT and invalid-user failures are not swallowed")
		service.update_progress(user, "6", 20)
		service.sdk.queries[1].completed.emit(_ok([Achievement.new("6", 0)]))
		test._check(service.sdk.updates.size() == 2, "a failed write does not create a false high-water mark")
		service.sdk.updates[1].completed.emit(_ok(Achievement.new("6", 20)))

	var service := Reports.new()
	service.update_progress(RefCounted.new(), "6", 20)
	service.sdk.queries[0].completed.emit(_ok([Achievement.new("6", 0)]))
	service.sdk.updates[0].completed.emit(_error(0x80070057))
	service.sdk.queries[1].completed.emit(_error(0x80004005, "achievement_cache_read_failed"))
	test._check(service.warnings.size() == 1 and service.warnings[0].contains("0x80070057"),
		"failed race recheck preserves the submitted update's error")


func _separate_users(test: Node) -> void:
	print("CASE: achievement queues and Xbox cache snapshots stay scoped to their original users")
	var service := Reports.new()
	var a := RefCounted.new()
	var b := RefCounted.new()
	service.update_progress(a, "6", 20)
	service.update_progress(b, "6", 20)
	test._check(service.sdk.queries.size() == 2, "different users never share a query")
	service.sdk.queries[0].completed.emit(_ok([Achievement.new("6", 100, true)]))
	service.sdk.queries[1].completed.emit(_ok([Achievement.new("6", 0)]))
	test._check(service.sdk.updates.size() == 1 and service.sdk.updates[0].user == b,
		"A's unlocked state cannot suppress B's update")
	service.sdk.updates[0].completed.emit(_ok(Achievement.new("6", 20)))


func _replacement_queue(test: Node) -> void:
	print("CASE: an invalidated achievement query cannot erase a replacement queue for the same XboxUser")
	var service := Reports.new()
	var user := RefCounted.new()
	service.update_progress(user, "6", 20)
	service.invalidate_pending_reports()
	service.update_progress(user, "6", 40)
	service.sdk.queries[0].completed.emit(_ok([Achievement.new("6", 0)]))
	test._check(service.sdk.updates.is_empty() and service._pending.has(user),
		"late old query starts no update and retains the new generation's queue")
	service.sdk.queries[1].completed.emit(_ok([Achievement.new("6", 0)]))
	test._check(service.sdk.updates.size() == 1 and service.sdk.updates[0].percent == 40,
		"replacement queue alone reports its progress")
	service.sdk.updates[0].completed.emit(_ok(Achievement.new("6", 40)))


func _account_boundaries(test: Node) -> void:
	for boundary: String in ["cancel", "removed", "resume", "shutdown"]:
		for phase: String in ["read", "write", "recheck"]:
			print("CASE: queued achievement reports stop at account ", boundary, " during ", phase)
			await test._reset()
			test._select("achievement-boundary", test._folder())
			test._check(await Services.sign_in(), "achievement fixture has a ready account")
			var previous: AchievementService = Services._achievements
			var service := Reports.new()
			Services._achievements = service
			var user: Variant = Services.xbox_user()
			Services._on_achievement_progress("6", 20)
			if phase != "read":
				service.sdk.queries[0].completed.emit(_ok([Achievement.new("6", 0)]))
				service.update_progress(user, "6", 40)
			if phase == "recheck":
				service.sdk.updates[0].completed.emit(_error(0x80070057))
			match boundary:
				"cancel": Services.cancel_sign_in()
				"removed":
					user.signed_in = false
					Services._on_user_changed(user, "removed")
				"resume": Services.invalidate_saves_for_resume()
				"shutdown": Services.begin_shutdown()
			var counts := [service.sdk.queries.size(), service.sdk.updates.size()]
			if phase == "read":
				service.sdk.queries[0].completed.emit(_ok([Achievement.new("6", 0)]))
			elif phase == "write":
				service.sdk.updates[0].completed.emit(_ok(Achievement.new("6", 20)))
			else:
				service.sdk.queries[1].completed.emit(_ok([Achievement.new("6", 0)]))
			test._check(counts == [service.sdk.queries.size(), service.sdk.updates.size()]
				and service._pending.is_empty() and service.warnings.is_empty(),
				"expired account context starts no queued native call and emits no stale warning")
			Services._achievements = previous
	await test._reset()


func _invite_outcomes(test: Node) -> void:
	print("CASE: only a native cancelled/E_ABORT invite result is an expected non-error")
	for reply: Variant in [
		_ok(), _error(0x80004004, "cancelled"), _error(-2147467260, "cancelled"),
		null, _error(0x80004005, "cancelled"),
		_error(0x80004004, "multiplayer_activity_invite_ui_result_failed"),
	]:
		var service := Activity.new()
		service.show_invite_ui(RefCounted.new())
		test._check(service.sdk.invites.size() == 1, "invite call awaits the native completion")
		service.sdk.invites[0].completed.emit(reply)
		var expected := 1
		if reply != null and (reply.ok or (reply.code == "cancelled"
				and (reply.hresult & 0xFFFFFFFF) == 0x80004004)):
			expected = 0
		test._check(service.warnings.size() == expected,
			"invite cancellation is quiet while genuine/null failures remain warnings")
