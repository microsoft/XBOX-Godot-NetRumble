extends RefCounted

const Review := preload("res://tools/tests/review_lifecycle.gd")


class Call extends RefCounted:
	signal completed(result: Dictionary)
	var user: Variant
	var score := 0


class Endpoints extends RefCounted:
	var queries: Array[Call] = []
	var reads: Array[Call] = []
	var updates: Array[Call] = []

	func get_leaderboard_async(user: Variant, _name: String, _start: int, _count: int, _version: int) -> Signal:
		var call := Call.new()
		call.user = user
		queries.append(call)
		return call.completed

	func get_leaderboard_around_user_async(user: Variant, _name: String, _count: int, _version: int) -> Signal:
		var call := Call.new()
		call.user = user
		reads.append(call)
		return call.completed

	func submit_score_async(user: Variant, _name: String, score: int) -> Signal:
		var call := Call.new()
		call.user = user
		call.score = score
		updates.append(call)
		return call.completed

	func counts() -> Array:
		return [queries.size(), reads.size(), updates.size()]


class PlayFabDouble extends RefCounted:
	var leaderboards := Endpoints.new()

	func is_initialized() -> bool:
		return true

	func get_title_id() -> String:
		return "ISOLATED"


class Leaderboards extends LeaderboardService:
	var pf := PlayFabDouble.new()

	func _playfab() -> Variant:
		return pf


func run(test: Node) -> void:
	var previous: LeaderboardService = Services._leaderboards
	for boundary: String in ["cancel", "removed", "resume", "shutdown"]:
		for phase: String in ["read", "update"]:
			await _invalidation(test, boundary, phase)
	await _serialization(test)
	await _signed_out_before_notification(test)
	await _match_and_screen(test)
	Services._leaderboards = previous
	await test._reset()


func _ready_account(test: Node) -> Endpoints:
	await test._reset()
	var service := Leaderboards.new()
	Services._leaderboards = service
	test._select("leaderboard-A", test._folder())
	test._check(await Services.sign_in(), "leaderboard fixture has fully loaded account")
	return service.pf.leaderboards


func _reply(rows: Array = [], ok: bool = true) -> Dictionary:
	return {"ok": ok, "data": {"rankings": rows}, "hresult": 0 if ok else -1,
		"code": "ok" if ok else "failed", "message": "Isolated leaderboard result."}


func _row(user: Variant, score: int, name: String = "Known entry") -> Dictionary:
	return {"entity": user.entity_key.duplicate(), "rank": 1, "display_name": name,
		"scores": PackedStringArray([str(score)])}


func _query(results: Array) -> void:
	results.append(await Services.get_leaderboard())


func _submit(score: int, results: Array) -> void:
	results.append(await Services.submit_leaderboard_score(score))


func _invalidation(test: Node, boundary: String, phase: String) -> void:
	print("CASE: production leaderboard facade invalidation ", boundary, " during ", phase)
	var sdk := await _ready_account(test)
	var user: Variant = Services.playfab_user()
	var queries: Array = []
	var first: Array = []
	var queued: Array = []
	_query(queries)
	_submit(100, first)
	_submit(110, queued)
	test._check(sdk.counts() == [1, 1, 0] and first.is_empty() and queued.is_empty(),
		"query and whole per-entity submission gate await actual fake endpoint Signals")
	if phase == "update":
		sdk.reads[0].completed.emit(_reply())
		test._check(sdk.updates.size() == 1 and queued.is_empty(), "queued call cannot overlap active update")
	match boundary:
		"cancel": Services.cancel_sign_in()
		"removed":
			var xbox: Variant = Services.xbox_user()
			xbox.signed_in = false
			Services._on_user_changed(xbox, "removed")
		"resume": Services.invalidate_saves_for_resume()
		"shutdown": Services.begin_shutdown()
	test._check(Services.get_leaderboard_submission().is_empty()
		and Services._leaderboard_submission.is_empty(), "boundary clears account-owned submission UI immediately")
	test._check(queued.size() == 1 and not queued[0].ok, "boundary wakes and cancels queued SDK work")
	var before := sdk.counts()
	var blocked_query := await Services.get_leaderboard()
	var blocked_submit := await Services.submit_leaderboard_score(900)
	test._check(not blocked_query.ok and blocked_query.entries.is_empty() and not blocked_submit.ok
		and sdk.counts() == before and Services.get_leaderboard_submission().is_empty(),
		"unready/loading/closing facade starts no query/read/upload or pending notice")

	var replacement: Array = []
	if boundary != "shutdown":
		if boundary != "resume":
			test._select("leaderboard-B", test._folder())
		test._check(await Services.sign_in(), "replacement/resumed account fully reloads")
		test._check((Services.playfab_user() == user) == (boundary == "resume"),
			"resume tests exact same PFUser object with changed account generation")
		_submit(120, replacement)
	if phase == "read":
		sdk.reads[0].completed.emit(_reply([_row(user, 90)]))
		test._check(sdk.updates.is_empty(), "invalidated best-score read cannot initiate old upload")
	else:
		sdk.updates[0].completed.emit(_reply())
		test._check(Services._leaderboards._best_scores[user.entity_key.id] == 100,
			"already-started accepted update retains upstream per-entity best")
	sdk.queries[0].completed.emit(_reply([_row(user, 500, "Stale account page")]))
	test._check(queries.size() == 1 and not queries[0].ok and queries[0].entries.is_empty()
		and first.size() == 1 and not first[0].ok, "stale query and submission completions cannot escape facade across generation")
	if boundary != "shutdown":
		test._check(replacement.is_empty() and Services.get_leaderboard_submission().pending
			and sdk.reads.size() == 2, "new generation owns pending notice and released per-entity gate")
		var current: Variant = Services.playfab_user()
		test._check(sdk.reads[1].user == current, "replacement read uses current authenticated entity")
		sdk.reads[1].completed.emit(_reply([_row(current, 100)]))
		sdk.updates.back().completed.emit(_reply())
		test._check(replacement.size() == 1 and replacement[0].ok
			and Services.get_leaderboard_submission().score == 120
			and Services.get_leaderboard_submission().hresult == 0,
			"only replacement accepted score publishes its actual result and HRESULT")
	else:
		test._check(Services.get_leaderboard_submission().is_empty(), "late shutdown acceptance cannot restore notice")
	await test._reset()


func _serialization(test: Node) -> void:
	print("CASE: integrated per-entity published-best gate, successful skips, rollback and latest notice")
	var sdk := await _ready_account(test)
	var user: Variant = Services.playfab_user()
	var first: Array = []
	var second: Array = []
	_submit(100, first)
	_submit(90, second)
	sdk.reads[0].completed.emit(_reply([_row(user, 150)]))
	test._check(first.size() == 1 and first[0].skipped and second.size() == 1 and second[0].skipped
		and sdk.counts() == [0, 1, 0], "server best and queued equal/lower guard skip without updates")
	first.clear()
	second.clear()
	_submit(200, first)
	_submit(250, second)
	test._check(sdk.reads.size() == 2, "higher candidates still serialize the read-before-write phase")
	sdk.reads[1].completed.emit(_reply([_row(user, 100)]))
	test._check(sdk.updates.size() == 1 and sdk.updates[0].score == 200,
		"stale lower read cannot erase known best but eligible score still uploads")
	sdk.updates[0].completed.emit(_reply([], false))
	test._check(first.size() == 1 and not first[0].ok and sdk.reads.size() == 3
		and Services._leaderboards._best_scores[user.entity_key.id] == 150,
		"failed update restores known best and releases the full gate for next candidate")
	test._check(Services.get_leaderboard_submission().pending, "older failure cannot overwrite latest pending notice")
	sdk.reads[2].completed.emit(_reply([_row(user, 180)]))
	sdk.updates[1].completed.emit(_reply())
	test._check(second.size() == 1 and second[0].ok
		and Services._leaderboards._best_scores[user.entity_key.id] == 250
		and Services._leaderboards._writes_in_flight.is_empty(),
		"accepted latest score and serialized gate semantics survive integration")
	await test._reset()


func _signed_out_before_notification(test: Node) -> void:
	print("CASE: SDK best-score read completes after Xbox signed-out state, before removal notification")
	var sdk := await _ready_account(test)
	var first: Array = []
	var queued: Array = []
	_submit(100, first)
	_submit(200, queued)
	var user: Variant = Services.xbox_user()
	user.signed_in = false
	sdk.reads[0].completed.emit(_reply())
	test._check(first.size() == 1 and not first[0].ok and queued.size() == 1 and not queued[0].ok
		and sdk.counts() == [0, 1, 0], "service rechecks facade owner readiness after seed/gate awaits before any new SDK work")
	test._check(Services.get_leaderboard_submission().is_empty(), "signed-out state cannot expose a pending submission")
	Services._on_user_changed(user, "removed")
	test._check(Services._leaderboard_submission.is_empty(), "event cleanup clears retained notice without needing another SDK completion")
	await test._reset()


func _match_and_screen(test: Node) -> void:
	print("CASE: actual match reporting idempotence, Practice exclusion and generation-bound leaderboard UI")
	var sdk := await _ready_account(test)
	test._check(NetManager.start_offline(), "identified Practice starts with ready saves")
	var payload := {"game_mode": "Deathmatch", "standings": [{"peer_id": 1, "placement": 1}]}
	var director := preload("res://scripts/gameplay/match_director.gd").new()
	NetManager.local_player().score = 50
	director._report_result(payload)
	var stats := Services.achievement_tracker().to_dict().duplicate(true)
	director._report_result(payload)
	test._check(Services.get_match_history().size() == 1 and sdk.counts() == [0, 0, 0]
		and Services.achievement_tracker().to_dict() == stats, "duplicate Practice completion persists one result and never posts GlobalScore")
	director.free()
	await NetManager.leave_match_and_wait()
	Services._party = Review.HostParty.new(null)
	test._check(await NetManager.host_match(), "actual online host uses fake Party, not a Practice fallback")
	director = preload("res://scripts/gameplay/match_director.gd").new()
	NetManager.local_player().score = 140
	director._report_result(payload)
	director._report_result(payload)
	test._check(Services.get_match_history().size() == 2 and sdk.reads.size() == 1,
		"duplicate online completion posts exactly one candidate without awaiting SDK")
	sdk.reads[0].completed.emit(_reply())
	sdk.updates[0].completed.emit(_reply())
	test._check(Services.get_leaderboard_submission().score == 140, "online final local score reaches accepted notice")
	director.free()
	await NetManager.leave_match_and_wait()
	var menu: Variant = ScreenManager.push(ScreenManager.MAIN_MENU)
	var button: NRButton
	for row: Control in menu._menu_list.rows():
		if row is NRButton and row.text == "Leaderboards":
			button = row
	test._check(button != null, "upstream Leaderboards button retained on ready menu")
	if button == null:
		await test._reset()
		Services._party = null
		return
	button.pressed.emit()
	var screen: Variant = ScreenManager.current_screen()
	test._check(screen.scene_file_path == ScreenManager.LEADERBOARDS and sdk.queries.size() == 1,
		"actual leaderboard screen starts live top-ten query")
	var user: Variant = Services.playfab_user()
	Services.invalidate_saves_for_resume()
	var depth := ScreenManager.get_stack_size()
	button.pressed.emit()
	test._check(ScreenManager.get_stack_size() == depth, "old menu button cannot bypass resume readiness gate")
	test._check(await Services.sign_in() and user == Services.playfab_user(), "UI resume reload preserves PFUser but changes generation")
	sdk.queries[0].completed.emit(_reply([_row(user, 999, "Stale account page")]))
	var stale_visible := false
	for row: Control in screen._list.rows():
		stale_visible = stale_visible or (row is NRButton and row.text.contains("Stale account page"))
	test._check(not stale_visible and Services.get_leaderboard_submission().is_empty(),
		"old live screen cannot display a same-PFUser stale query or prior submission")
	button.pressed.emit()
	test._check(ScreenManager.get_stack_size() == depth, "old menu remains generation-bound even after readiness returns")
	ScreenManager.replace_all(ScreenManager.MAIN_MENU)
	ScreenManager.current_screen()._on_leaderboards()
	sdk.queries[1].completed.emit(_reply([_row(user, 140)]))
	screen = ScreenManager.current_screen()
	test._check(not screen._loading and screen._list.rows()[1].text.contains("Known entry")
		and sdk.updates.size() == 1, "fresh ready screen reads top ten; refresh/navigation never uploads or reads history as fallback")
	await test._reset()
	Services._party = null
