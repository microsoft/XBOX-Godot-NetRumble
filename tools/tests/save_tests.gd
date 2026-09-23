extends Node

const Doubles := preload("res://tools/tests/doubles.gd")
const FILES := ["profile.json", "history.json", "stats.json"]

var _assertions := 0
var _failures: Array[String] = []
var _folder_sequence := 0
var _save_errors: Array[String] = []
var _sign_in_results: Array[bool] = []
var _legacy: Dictionary = {}


func _ready() -> void:
	_run.call_deferred()


func _run() -> void:
	var sandbox := OS.get_environment("NR_SAVE_TEST_ROOT").replace("\\", "/")
	var user_dir := OS.get_user_data_dir().replace("\\", "/")
	if sandbox.is_empty() or not user_dir.begins_with(sandbox + "/"):
		print("SAVE TEST FAIL: user:// is not isolated: ", user_dir)
		get_tree().quit(1)
		return
	_check(not Engine.has_singleton("PlayFab"), "no native PlayFab singleton loaded")
	_check(PlatformAccess.gdk() == null, "no live GDK bootstrap")
	_check(not ProjectSettings.has_setting("playfab/runtime/title_id"), "no shipping SDK configuration")
	_check(not FileAccess.file_exists("res://MicrosoftGame.config"), "no shipping game config copied")
	_check(IdentityService.resolve_custom_id_token() == "A", "token-scoped legacy fixtures exercised")
	Services.save_failed.connect(func(reason: String) -> void: _save_errors.append(reason))
	Services.sign_in_completed.connect(func(success: bool) -> void: _sign_in_results.append(success))
	for name: String in Assets.LEGACY_FILES:
		var path := "user://".path_join(name)
		_legacy[path] = FileAccess.get_file_as_bytes(path)
		_check(not _legacy[path].is_empty(), "legacy fixture exists before autoload startup: " + name)
	_check(is_equal_approx(PlayerProfile.music_volume, 0.25), "startup ignores legacy music value")
	_check(Services.get_match_history().is_empty(), "startup ignores legacy history")

	if OS.get_environment("NR_SAVE_TEST_SUITE") == "Multiplayer":
		await preload("res://tools/tests/multiplayer_failure_tests.gd").new().run(self)
		await _complete()
		return
	await _storage_contract()
	await _storage_single_flight()
	await _xbox_folder_contract()
	await preload("res://tools/tests/save_layout_tests.gd").new().run(self)
	await _account_isolation()
	await _read_failures_and_retry()
	await _initialization_failures()
	await _account_single_flight()
	await _cancellation_and_shutdown()
	await _write_retry()
	await _unconditional_settings()
	await _history_limit()
	await _gameplay_and_invites()
	await _back_during_preparation()
	await _identity_await_boundaries()
	await _chat_account_controls()
	await _party_await_boundaries()
	await _cache_invalidation()
	await _suspend_is_synchronous()
	await preload("res://tools/tests/review_storage.gd").new().run(self)
	await preload("res://tools/tests/review_lifecycle.gd").new().run(self)
	await preload("res://tools/tests/suspend_tests.gd").new().run(self)
	await preload("res://tools/tests/leaderboard_tests.gd").new().run(self)
	await preload("res://tools/tests/pr_feedback_tests.gd").new().run(self)
	await preload("res://tools/tests/join_failure_tests.gd").new().run(self)
	await preload("res://tools/tests/multiplayer_failure_tests.gd").new().run(self)
	_source_guards()
	await _complete()


func _complete() -> void:
	for path: String in _legacy:
		_check(FileAccess.get_file_as_bytes(path) == _legacy[path], "legacy file untouched: " + path)
	await _reset()
	if _failures.is_empty():
		print("SAVE TESTS PASSED: %d assertions" % _assertions)
		get_tree().quit(0)
	else:
		print("SAVE TEST FAIL: %d failures / %d assertions" % [_failures.size(), _assertions])
		get_tree().quit(1)


func _check(condition: bool, description: String) -> void:
	_assertions += 1
	if not condition:
		_failures.append(description)
		print("SAVE TEST FAIL: ", description)


func _status(result: Dictionary, expected: GameSaveService.Status, description: String) -> void:
	_check(result.keys().size() == 3 and result.has("status") and result.has("data") and result.has("reason"),
		description + ": explicit status/data/reason contract")
	_check(result.get("status") == expected, description + ": status " + str(result))
	if expected in [GameSaveService.Status.FAILED, GameSaveService.Status.STALE]:
		_check(not String(result.get("reason", "")).is_empty(), description + ": specific failure reason")


func _folder() -> String:
	_folder_sequence += 1
	var path := ProjectSettings.globalize_path("res://test-data/%d" % _folder_sequence)
	_check(DirAccess.make_dir_recursive_absolute(path) == OK, "create disposable account folder")
	_check(DirAccess.make_dir_absolute(path.path_join(GameSaveService.SAVE_DIRECTORY)) == OK, "create disposable save subdirectory")
	return path


func _put(folder: String, file_name: String, text: String) -> void:
	var sequence := 1
	for slot: String in [file_name, file_name + GameSaveService.SLOT_SUFFIX]:
		var path := folder.path_join(GameSaveService.SAVE_DIRECTORY).path_join(slot)
		if FileAccess.file_exists(path):
			var existing: Variant = JSON.parse_string(FileAccess.get_file_as_string(path))
			if existing is Dictionary and existing.get("sequence") is float:
				sequence = maxi(sequence, int(existing.sequence) + 1)
	var record := {
		"sequence": sequence,
		"payload": text,
		"sha256": ("%d\n%s" % [sequence, text]).sha256_text(),
	}
	var file := FileAccess.open(folder.path_join(GameSaveService.SAVE_DIRECTORY).path_join(file_name), FileAccess.WRITE)
	_check(file != null, "create fixture " + file_name)
	if file != null:
		file.store_string(JSON.stringify(record))
		file.close()


func _json(folder: String, file_name: String, data: Variant) -> void:
	_put(folder, file_name, JSON.stringify(data))


func _saved(folder: String, file_name: String) -> Variant:
	var store := Doubles.Saves.new()
	var user := Doubles.User.new("read-back")
	store.sdk.folder = folder
	_status(await store.prepare(user, 1), GameSaveService.Status.OK, "prepare independent save read-back")
	var read := store.read(user, 1, file_name)
	_status(read, GameSaveService.Status.OK, "independent committed-slot read-back")
	return read.data


func _row(score: int, mode: String = "Deathmatch") -> Dictionary:
	return {"date": "2026-09-17 12:00:00", "game_mode": mode, "score": score, "placement": 1, "player_count": 3}


func _payload(score: int) -> Dictionary:
	return {"game_mode": "Deathmatch", "game_mode_type": 0, "score": score, "placement": 1, "player_count": 3, "human_count": 1}


func _reset() -> void:
	ScreenManager.clear()
	InviteRouter.decline_pending_invite()
	Services.cancel_sign_in()
	await get_tree().process_frame
	_check(not Services.is_signing_in(), "previous sign-in fully drained")
	Services._shutting_down = false
	Services._identity = Doubles.Identity.new()
	Services._identity.stage_changed.connect(Services._set_sign_in_stage)
	Services._game_saves = Doubles.Saves.new()
	Services._achievements.reports.clear()
	Services._connectivity = null
	Services._privileges = null
	_save_errors.clear()
	_sign_in_results.clear()


func _select(id: String, folder: String) -> void:
	Services._identity.target = Doubles.User.new(id)
	Services._game_saves.sdk.folder = folder


func _capture_prepare(store: GameSaveService, user: Variant, generation: int, results: Array) -> void:
	results.append(await store.prepare(user, generation))


func _capture_sign_in(results: Array) -> void:
	results.append(await Services.sign_in())


func _settle(results: Array, count: int) -> void:
	for frame in 120:
		if results.size() == count:
			break
		await get_tree().process_frame
	_check(results.size() == count, "all asynchronous callers settled")


func _storage_contract() -> void:
	print("CASE: real GameSaveService filesystem and result contract")
	var store := Doubles.Saves.new()
	var user := Doubles.User.new("storage")
	var other := Doubles.User.new("other")
	var folder := _folder()
	store.sdk.folder = folder
	_status(store.read(user, 1, FILES[0]), GameSaveService.Status.STALE, "unprepared read")
	_status(await store.prepare(user, 1), GameSaveService.Status.OK, "prepare valid store")
	for file_name: String in FILES:
		var missing := store.read(user, 1, file_name)
		_status(missing, GameSaveService.Status.MISSING, "confirmed missing " + file_name)
		_check(missing.data == ([] if file_name == "history.json" else {}), "missing payload shape")
		var data: Variant = [_row(12)] if file_name == "history.json" else ({"musicVolume": 0.7} if file_name == "profile.json" else {"kills": 12})
		_status(store.write_now(user, 1, file_name, data), GameSaveService.Status.OK, "write " + file_name)
		var read := store.read(user, 1, file_name)
		_status(read, GameSaveService.Status.OK, "read written " + file_name)
		_check(read.data == JSON.parse_string(JSON.stringify(data)), "actual JSON roundtrip " + file_name)
		var before := FileAccess.get_file_as_bytes(folder.path_join(GameSaveService.SAVE_DIRECTORY).path_join(file_name))
		_status(store.write_now(other, 1, file_name, data), GameSaveService.Status.STALE, "wrong owner write")
		_status(store.write_now(user, 2, file_name, data), GameSaveService.Status.STALE, "wrong generation write")
		_status(store.read(other, 1, file_name), GameSaveService.Status.STALE, "wrong owner read")
		_status(store.read(user, 2, file_name), GameSaveService.Status.STALE, "wrong generation read")
		_status(store.write_now(user, 1, file_name, "invalid"), GameSaveService.Status.FAILED, "bad write payload")
		_check(FileAccess.get_file_as_bytes(folder.path_join(GameSaveService.SAVE_DIRECTORY).path_join(file_name)) == before, "rejected writes preserve valid " + file_name)
	_status(store.read(user, 1, "../escape.json"), GameSaveService.Status.FAILED, "unknown read path")
	_status(store.write_now(user, 1, "../escape.json", {}), GameSaveService.Status.FAILED, "unknown write path")
	_check(not FileAccess.file_exists(folder.get_base_dir().path_join("escape.json")), "unknown write cannot escape store")
	store.reset()
	_check(not store.is_bound(user, 1), "reset invalidates binding")
	_status(store.write_now(user, 1, FILES[0], {}), GameSaveService.Status.STALE, "reset write denied")

	var missing_sdk := GameSaveService.new()
	_status(await missing_sdk.prepare(user, 1), GameSaveService.Status.FAILED, "actual absent GDK SDK")
	var custom := Doubles.User.new("custom")
	custom.signed_in = false
	_status(await store.prepare(custom, 2), GameSaveService.Status.FAILED, "signed-out Xbox user")
	_status(await store.prepare(null, 2), GameSaveService.Status.FAILED, "no user")
	_check(store.sdk.calls == 1, "invalid users do not invoke get_folder_async")


func _storage_single_flight() -> void:
	print("CASE: GameSaveService simultaneous preparation and reset")
	var store := Doubles.Saves.new()
	var user := Doubles.User.new("single")
	store.sdk.folder = _folder()
	store.sdk.blocked = true
	var results: Array = []
	_capture_prepare(store, user, 10, results)
	_capture_prepare(store, user, 10, results)
	_check(store.sdk.calls == 1 and results.is_empty(), "two callers share pending SDK call")
	store.sdk.released.emit()
	await _settle(results, 2)
	for result: Dictionary in results:
		_status(result, GameSaveService.Status.OK, "same-owner shared completion")
	_status(await store.prepare(user, 10), GameSaveService.Status.OK, "bound preparation idempotent")
	_check(store.sdk.calls == 1, "idempotence does not resync SDK")

	store.reset()
	results.clear()
	_capture_prepare(store, user, 11, results)
	_capture_prepare(store, user, 11, results)
	store.reset()
	var replacement := Doubles.User.new("replacement")
	_capture_prepare(store, replacement, 12, results)
	_check(store.sdk.calls == 2, "reset does not start concurrent SDK work")
	store.sdk.released.emit()
	await _settle(results, 3)
	for result: Dictionary in results:
		_status(result, GameSaveService.Status.STALE, "reset rejects all old/premature callers")
	_check(not store.is_bound(user, 11) and not store.is_bound(replacement, 12), "late result cannot restore folder")
	store.sdk.blocked = false
	_status(await store.prepare(replacement, 12), GameSaveService.Status.OK, "new owner retries after drain")
	_check(store.sdk.calls == 3 and store.is_bound(replacement, 12), "new owner exclusively bound")


func _account_isolation() -> void:
	print("CASE: A -> fresh B -> A -> populated B; authoritative empty payloads")
	await _reset()
	var a := _folder()
	var b := _folder()
	var defaults: Dictionary = PlayerProfile.to_dict()
	_select("A", a)
	_check(await Services.sign_in(), "A becomes ready")
	PlayerProfile.apply_dict({
		"masterVolume": 0.2, "musicVolume": 0.7, "sfxVolume": 0.3, "voiceChatVolume": 0.4,
		"selectedShip": 3, "selectedColor": 2, "fullscreen": false, "showRosterOverlay": false,
		"practiceOpponents": 1, "powerUpFrequency": 0.1,
	})
	var a_profile: Dictionary = PlayerProfile.to_dict()
	_check(PlayerProfile.save_settings(), "A saves actual PlayerProfile")
	_check(Services.report_match_result(_payload(101)), "A completed match persists")
	Services.achievement_tracker().note_kill()
	Services.achievement_tracker().note_death()
	Services.achievement_tracker().note_asteroid_destroyed()
	Services.achievement_tracker().note_weapon_fired(0)
	Services.achievement_tracker().note_buff_collected(0)
	var a_stats := Services.achievement_tracker().to_dict()
	_check(Services.persist_for_suspend(), "A suspend persists counters")
	var a_bytes: Dictionary = {}
	for file_name: String in FILES:
		a_bytes[file_name] = FileAccess.get_file_as_bytes(a.path_join(file_name))
	var snapshot := Services.get_match_history()
	snapshot[0].score = -999
	snapshot.clear()
	_check(Services.get_match_history()[0].score == 101, "history returns deep snapshots")
	var generation := Services.account_generation()
	await _reset()
	_check(not Services.is_current_account(generation), "A generation invalidated")
	_check(not PlayerProfile.is_signed_in and PlayerProfile.to_dict() == defaults, "identity/profile reset")
	_check(Services._achievement_tracker._match_deaths == 0 and Services._achievement_tracker._reported.is_empty(),
		"match counters and cached achievement reports reset")
	_select("B", b)
	_check(await Services.sign_in(), "fresh B becomes ready")
	_check(Services.get_match_history().is_empty(), "fresh B never sees A history")
	_check(is_equal_approx(PlayerProfile.music_volume, 0.25) and PlayerProfile.ship_style_id == 0, "fresh B has default settings")
	_check(PlayerProfile.to_dict() == defaults, "every fresh B preference is a default, not A's setting")
	_check(Services.achievement_tracker().kills == 0 and Services.achievement_tracker().matches_completed == 0, "fresh B zero counters")
	for counter: Variant in Services.achievement_tracker().to_dict().values():
		_check(counter == 0, "every fresh B lifetime counter/bitset is zero")
	_check(Services._achievements.reports.is_empty(), "A achievements not reported for fresh B")
	for file_name: String in FILES:
		_check(not FileAccess.file_exists(b.path_join(file_name)), "missing file not synthesized on load")
		_check(FileAccess.get_file_as_bytes(a.path_join(file_name)) == a_bytes[file_name], "B load preserves A " + file_name)
	PlayerProfile.music_volume = 0.4
	_check(PlayerProfile.save_settings(), "B saves its own settings")
	_check(Services.report_match_result(_payload(202)), "B records own match")
	await _reset()
	_select("A", a)
	_check(await Services.sign_in(), "A reloads")
	_check(Services.get_match_history().size() == 1 and Services.get_match_history()[0].score == 101, "A original row recoverable")
	_check(is_equal_approx(PlayerProfile.music_volume, 0.7), "explicit saved music 0.7 stays 0.7")
	_check(is_equal_approx(AudioManager.volumes.Music, 0.7), "actual profile applies loaded music to audio seam")
	_check(Services.achievement_tracker().kills == 1, "A counters recovered")
	_check(PlayerProfile.to_dict() == a_profile, "all A preferences recovered")
	_check(Services.achievement_tracker().to_dict() == a_stats, "all A counters and bitsets recovered")
	await _reset()
	_select("B", b)
	_check(await Services.sign_in(), "populated B reloads")
	_check(Services.get_match_history().size() == 1 and Services.get_match_history()[0].score == 202, "populated B excludes A rows")
	_check(is_equal_approx(PlayerProfile.music_volume, 0.4) and PlayerProfile.ship_style_id == 0, "populated B settings exclude A")
	_check(Services.achievement_tracker().matches_completed == 1 and Services.achievement_tracker().kills == 0, "populated B counters replace A")
	for report: Dictionary in Services._achievements.reports:
		_check(report.owner == Services.xbox_user(), "achievement report belongs to current B")
	await _reset()
	for file_name: String in FILES:
		_json(b, file_name, [] if file_name == "history.json" else {})
	_select("B", b)
	_check(await Services.sign_in(), "valid explicitly empty payloads accepted")
	_check(Services.get_match_history().is_empty() and Services.achievement_tracker().matches_completed == 0, "empty history/stats authoritative")
	_check(is_equal_approx(PlayerProfile.music_volume, 0.25), "empty profile restores defaults")


func _read_failures_and_retry() -> void:
	print("CASE: malformed JSON/current shapes and real read failures never publish or overwrite")
	var invalid: Array[Dictionary] = [
		{"file": "profile.json", "text": "{"},
		{"file": "profile.json", "text": "[]"},
		{"file": "profile.json", "text": '{"musicVolume":"loud"}'},
		{"file": "profile.json", "text": '{"selectedShip":1.5}'},
		{"file": "profile.json", "text": '{"fullscreen":1}'},
		{"file": "profile.json", "text": '{"oldSetting":true}'},
		{"file": "history.json", "text": "{"},
		{"file": "history.json", "text": '{"entries":[]}'},
		{"file": "history.json", "text": "[{}]"},
		{"file": "history.json", "text": '[{"date":"today","game_mode":"D","score":1.5,"placement":1,"player_count":2}]'},
		{"file": "stats.json", "text": "{"},
		{"file": "stats.json", "text": "[]"},
		{"file": "stats.json", "text": '{"kills":-1}'},
		{"file": "stats.json", "text": '{"kills":true}'},
		{"file": "stats.json", "text": '{"kills":0.5}'},
		{"file": "stats.json", "text": '{"oldCounter":2}'},
	]
	for sample: Dictionary in invalid:
		await _reset()
		var folder := _folder()
		_json(folder, "profile.json", {"musicVolume": 0.9})
		_json(folder, "history.json", [_row(99)])
		_json(folder, "stats.json", {"kills": 90})
		_put(folder, sample.file, sample.text)
		var before: Dictionary = {}
		for file_name: String in FILES:
			before[file_name] = FileAccess.get_file_as_bytes(folder.path_join(GameSaveService.SAVE_DIRECTORY).path_join(file_name))
		_select("bad-read", folder)
		_check(not await Services.sign_in(), "invalid payload denies readiness: " + sample.text)
		_check(Services.is_online() and not Services.is_account_ready(), "authentication alone is not readiness")
		_check(Services.sign_in_error().contains(sample.file), "failure names malformed file")
		_check(Services.get_match_history().is_empty() and not PlayerProfile.is_signed_in, "no partial publication")
		_check(is_equal_approx(PlayerProfile.music_volume, 0.25) and Services._achievement_tracker.kills == 0,
			"valid staged profile/counters not published on later failure")
		_check(Services._achievements.reports.is_empty(), "failed load reports no achievements")
		_check(not Services.persist_for_suspend(), "failed load cannot persist defaults")
		_check(not PlayerProfile.save_settings(), "failed load denies profile write")
		await _assert_denied()
		for file_name: String in FILES:
			_check(FileAccess.get_file_as_bytes(folder.path_join(GameSaveService.SAVE_DIRECTORY).path_join(file_name)) == before[file_name], "failed load leaves bytes untouched")
		_json(folder, sample.file, [] if sample.file == "history.json" else {})
		_check(await Services.sign_in(), "Retry reads repaired current payload")
		_check(Services._identity.calls == 1, "Retry reuses authenticated identity")
		_check(Services._game_saves.sdk.calls == 1, "read retry reuses verified folder")

	for file_name: String in FILES:
		await _reset()
		var folder := _folder()
		var blocked_path := folder.path_join(GameSaveService.SAVE_DIRECTORY).path_join(file_name)
		_check(DirAccess.make_dir_absolute(blocked_path) == OK, "inject directory at save path")
		_select("read-failure", folder)
		_check(not await Services.sign_in(), "directory read fails, not missing: " + file_name)
		_check(Services.sign_in_error().contains("not a file"), "real read failure surfaced")
		_check(DirAccess.dir_exists_absolute(blocked_path), "failure leaves directory untouched")
		_check(DirAccess.remove_absolute(blocked_path) == OK, "remove test fault")
		_check(await Services.sign_in(), "Retry after real read fault")

	await _reset()
	var vanished := _folder()
	_select("vanished", vanished)
	var store: Doubles.Saves = Services._game_saves
	store.on_read = func(_name: String) -> void:
		DirAccess.remove_absolute(vanished.path_join(GameSaveService.SAVE_DIRECTORY))
	_check(not await Services.sign_in(), "folder disappearing between prepare/read is failure")
	_check(Services.sign_in_error().contains("not accessible"), "folder access failure is explicit")
	_check(Services.sign_in_error().contains("stage=read")
		and Services.sign_in_error().contains("directory_exists=false"), "read folder diagnostics survive sign-in error")
	_check(not Services.sign_in_error().contains(vanished), "read folder diagnostics omit account path")
	store.on_read = Callable()


func _xbox_folder_contract() -> void:
	print("CASE: XGameSaveFiles dictionary/native results, signed-out completions and Xbox-only binding")
	var inaccessible := Doubles.Saves.new()
	var owner := Doubles.User.new("folder-diagnostics")
	var absent := _folder().path_join("absent")
	inaccessible.sdk.folder = absent
	var failed := await inaccessible.prepare(owner, 1)
	_status(failed, GameSaveService.Status.FAILED, "inaccessible SDK folder fails preparation")
	_check(failed.reason.contains("stage=create-directory") and failed.reason.contains("error=")
		and failed.reason.contains("directory_exists=false"), "prepare reports independent folder diagnostics")
	_check(not failed.reason.contains(absent) and not inaccessible.is_bound(owner, 1),
		"folder diagnostics do not expose path or bypass readiness")
	_check(not DirAccess.dir_exists_absolute(absent), "folder diagnostic does not create the missing directory")
	var existing := _folder()
	var diagnostic := GameSaveService._folder_access_failure(existing, "prepare", ERR_INVALID_PARAMETER)
	_check(diagnostic.contains("error=%d" % ERR_INVALID_PARAMETER)
		and diagnostic.contains("directory_exists=true"), "diagnostic distinguishes open rejection from existing directory")
	_check(not diagnostic.contains(existing), "existing directory diagnostic omits account path")
	for response: Variant in [null, false, "bad", {}, {"ok": true}, {"ok": "yes", "data": {"path": _folder()}},
			{"ok": true, "data": _folder()}, {"ok": true, "data": []}, {"ok": true, "data": {}},
			{"ok": true, "data": {"path": 4}}, {"ok": true, "data": {"path": ""}},
			{"ok": false, "code": "service_configuration_id_unavailable", "hresult": -2147467259},
			{"ok": false, "code": "cancelled", "hresult": -2147467260}]:
		var store := Doubles.Saves.new()
		store.sdk.response = response
		store.sdk.null_result = response == null
		var user := Doubles.User.new("folder-contract")
		var outcome := await store.prepare(user, 1)
		_status(outcome, GameSaveService.Status.FAILED, "invalid or failed GDK folder result")
		_check(not store.is_bound(user, 1) and not outcome.reason.is_empty(), "failure never publishes folder/defaults")
		if response is Dictionary and response.get("code") == "service_configuration_id_unavailable":
			_check(outcome.reason.contains("service_configuration_id_unavailable")
				and outcome.reason.contains("0x80004005"), "safe SCID error code/HRESULT survives result conversion")
	for native: bool in [false, true]:
		var store := Doubles.Saves.new()
		var user := Doubles.User.new("folder-result")
		user.has_local_user_handle = false
		store.sdk.folder = _folder()
		store.sdk.native_result = native
		_status(await store.prepare(user, 1), GameSaveService.Status.OK, "dictionary/native {path} result accepted")
		_check(store.sdk.owners == [user], "GDK folder request receives Xbox owner without PF local handle")
		user.signed_in = false
		_check(not store.is_bound(user, 1), "signed-out Xbox handle invalidates even a previously verified folder")
		_status(store.read(user, 1, "profile.json"), GameSaveService.Status.STALE, "signed-out read rejected")
		_status(store.write_now(user, 1, "profile.json", {}), GameSaveService.Status.STALE, "signed-out write rejected")
		user.signed_in = true
		store.reset()
		store.sdk.blocked = true
		var results: Array = []
		_capture_prepare(store, user, 2, results)
		_check(results.is_empty(), "native-like returned Signal holds preparation pending")
		user.signed_in = false
		store.sdk.released.emit()
		await _settle(results, 1)
		_status(results[0], GameSaveService.Status.STALE, "signed-out native completion never binds")

	await _reset()
	_select("xbox-owner", _folder())
	_check(await Services.sign_in(), "separate Xbox/PF objects complete full readiness")
	_check(Services.xbox_user() != Services.playfab_user()
		and not Services.playfab_user().has_local_user_handle, "identity double cannot hide PF ownership mistakes")
	var store: Doubles.Saves = Services._game_saves
	var generation := Services.account_generation()
	_check(store.sdk.owners == [Services.xbox_user()] and Services._ready_owner == Services.xbox_user(),
		"Services readiness and native folder resolution belong to Xbox user")
	_check(Services.persist_for_suspend(), "Xbox-bound full save writes all three")
	for name: String in FILES:
		_status(store.read(Services.playfab_user(), generation, name), GameSaveService.Status.STALE, "PF owner read denied")
		_status(store.write_now(Services.playfab_user(), generation, name, {}), GameSaveService.Status.STALE, "PF owner write denied")
	Services._identity.gdk_user = Doubles.User.new("replacement")
	_check(not Services.is_account_ready() and not Services.persist_for_suspend(), "Xbox replacement invalidates readiness even with unchanged PF user")

	await _reset()
	_select("stale-xbox", _folder())
	store = Services._game_saves
	store.sdk.blocked = true
	var pending: Array = []
	_capture_sign_in(pending)
	Services._identity.gdk_user = Doubles.User.new("replacement-during-native")
	store.sdk.released.emit()
	await _settle(pending, 1)
	_check(pending == [false] and store.reads.is_empty() and not Services.is_account_ready(),
		"Xbox replacement during returned Signal cannot load or publish despite unchanged PF auth")


func _initialization_failures() -> void:
	print("CASE: GDK SDK/SCID/folder failures; Retry after authentication")
	for fault: String in ["sdk", "scid", "services", "null-result", "folder-result", "empty-folder", "wrong-folder-type", "absent-folder", "custom", "auth", "signed-out"]:
		await _reset()
		var folder := _folder()
		_select("init-" + fault, folder)
		var store: Doubles.Saves = Services._game_saves
		match fault:
			"sdk": store.unavailable = true
			"scid", "services":
				store.sdk.folder_ok = false
				store.sdk.code = "service_configuration_id_unavailable" if fault == "scid" else "xbox_services_uninitialized"
			"null-result": store.sdk.null_result = true
			"folder-result": store.sdk.folder_ok = false
			"empty-folder": store.sdk.folder = ""
			"wrong-folder-type": store.sdk.folder = {}
			"absent-folder": store.sdk.folder = folder.path_join(GameSaveService.SAVE_DIRECTORY).path_join("absent")
			"custom": Services._identity.xbox_available = false
			"signed-out": Services._identity.target.signed_in = false
			"auth": Services._identity.authenticate = false
		_check(not await Services.sign_in(), "initialization fault denied: " + fault)
		_check(not Services.sign_in_error().is_empty(), "initialization fault explains failure")
		_check(store.reads.is_empty(), "no reads before successful preparation")
		await _assert_denied()
		store.unavailable = false
		store.sdk.null_result = false
		store.sdk.folder_ok = true
		store.sdk.folder = folder
		Services._identity.target.signed_in = true
		Services._identity.xbox_available = true
		if fault == "custom":
			Services._identity.gdk_user = Services._identity.target
		Services._identity.authenticate = true
		_check(await Services.sign_in(), "initialization Retry succeeds: " + fault)
		_check(Services._identity.calls == (2 if fault == "auth" else 1), "auth-only early return cannot skip save retry")
		_check(store.reads == FILES, "all three synchronous reads after prepare")


func _account_single_flight() -> void:
	print("CASE: Services single flight spans auth, prepare and all synchronous reads")
	await _reset()
	_select("single-account", _folder())
	Services._identity.blocked = true
	Services._game_saves.sdk.blocked = true
	var results: Array = []
	_capture_sign_in(results)
	_capture_sign_in(results)
	_check(Services._identity.calls == 1 and Services.is_signing_in(), "concurrent authentication single-flight")
	_check(Services._game_saves.sdk.calls == 0, "save preparation waits for auth")
	Services._identity.released.emit()
	_check(Services._game_saves.sdk.calls == 1 and results.is_empty(), "both callers remain pending during saves")
	_check(not Services.is_account_ready(), "not ready during sync")
	Services._game_saves.on_read = func(_name: String) -> void:
		_check(Services.is_signing_in() and not Services.is_account_ready(), "single-flight remains held through read")
		_check(not PlayerProfile.is_signed_in, "profile not published before all reads")
	Services._game_saves.sdk.released.emit()
	await _settle(results, 2)
	_check(results == [true, true], "both callers succeed after complete transaction")
	_check(_sign_in_results == [true], "one sign-in completion event")
	_check(Services._game_saves.reads == FILES, "exact profile/history/stats read sequence")
	_check(await Services.sign_in(), "ready sign-in idempotent")
	_check(Services._identity.calls == 1 and Services._game_saves.sdk.calls == 1, "idempotence skips redundant SDK work")
	Services._game_saves.on_read = Callable()

	await _reset()
	_select("shared-failure", _folder())
	Services._game_saves.sdk.blocked = true
	Services._game_saves.sdk.folder_ok = false
	results.clear()
	for caller in 3:
		_capture_sign_in(results)
	_check(Services._identity.calls == 1 and Services._game_saves.sdk.calls == 1, "repeated Retry shares failing sync")
	Services._game_saves.sdk.released.emit()
	await _settle(results, 3)
	_check(results == [false, false, false] and _sign_in_results == [false], "shared failure reaches every waiter once")
	_check(Services._game_saves.reads.is_empty() and not Services.is_account_ready(), "failed shared sync publishes nothing")
	Services._game_saves.sdk.blocked = false
	Services._game_saves.sdk.folder_ok = true
	_check(await Services.sign_in(), "shared failure can Retry after authenticated sync failure")
	_check(Services._identity.calls == 1 and Services._game_saves.sdk.calls == 2, "Retry only repeats failed preparation")


func _cancellation_and_shutdown() -> void:
	print("CASE: cancel, removal and shutdown invalidate pending auth/save completions")
	for phase: String in ["auth", "prepare"]:
		for action: String in ["cancel", "removed", "shutdown"]:
			await _reset()
			var folder := _folder()
			_json(folder, "profile.json", {"musicVolume": 0.9})
			_select("cancel-" + phase, folder)
			var identity: Doubles.Identity = Services._identity
			var store: Doubles.Saves = Services._game_saves
			identity.blocked = phase == "auth"
			store.sdk.blocked = phase == "prepare"
			var results: Array = []
			_capture_sign_in(results)
			_capture_sign_in(results)
			var old_generation := Services.account_generation()
			match action:
				"cancel": Services.cancel_sign_in()
				"removed": Services._on_user_changed(identity.target, "removed")
				"shutdown": Services.begin_shutdown()
			_check(Services.is_signing_in(), "invalidated call remains draining: " + action)
			_check(not Services.is_current_account(old_generation), "generation invalidated: " + action)
			_capture_sign_in(results)
			_check(identity.calls == 1 and store.sdk.calls == (1 if phase == "prepare" else 0), "new caller cannot overlap draining SDK")
			if phase == "auth":
				identity.released.emit()
			else:
				store.sdk.released.emit()
			await _settle(results, 3)
			_check(results == [false, false, false], "late completion rejected by every caller")
			_check(not Services.is_account_ready() and not Services.is_signing_in(), "drain ends without readiness")
			_check(store.reads.is_empty() and store._folder.is_empty(), "no stale reads or restored folder")
			_check(not PlayerProfile.is_signed_in and is_equal_approx(PlayerProfile.music_volume, 0.25), "no late profile publication")
			_check(Services._achievements.reports.is_empty(), "no late achievement publication")
			await _assert_denied()


func _write_retry() -> void:
	print("CASE: failed replacement preserves valid files and working data until same-owner retry")
	await _reset()
	var folder := _folder()
	_select("write-A", folder)
	_check(await Services.sign_in(), "writer ready")
	_check(PlayerProfile.save_settings(), "seed valid profile")
	_check(Services.report_match_result(_payload(1)), "seed valid history/stats")
	var before: Dictionary = {}
	for file_name: String in FILES:
		before[file_name] = FileAccess.get_file_as_bytes(folder.path_join(GameSaveService.SAVE_DIRECTORY).path_join(file_name))
		_check(DirAccess.make_dir_absolute(folder.path_join(GameSaveService.SAVE_DIRECTORY).path_join(file_name + GameSaveService.SLOT_SUFFIX)) == OK, "inject real inactive-slot access failure")
	PlayerProfile.music_volume = 0.6
	_check(not PlayerProfile.save_settings() and PlayerProfile.music_volume == 0.6, "profile write failure retains current settings")
	_check(not Services.report_match_result(_payload(2)), "match write failure returned")
	_check(Services.get_match_history()[0].score == 2 and Services.achievement_tracker().matches_completed == 2,
		"history/stats failure retains working data")
	var pending_profile := PlayerProfile.to_dict()
	var pending_history := Services.get_match_history()
	var pending_stats := Services.achievement_tracker().to_dict()
	_check(not Services.persist_for_suspend(), "synchronous suspend reports failure without clearing")
	_check(PlayerProfile.to_dict() == pending_profile and Services.get_match_history() == pending_history
		and Services.achievement_tracker().to_dict() == pending_stats, "suspend retains every failed payload")
	_check(_save_errors.size() == 6, "each failed write emits a visible save_failed signal")
	for file_name: String in FILES:
		_check(FileAccess.get_file_as_bytes(folder.path_join(GameSaveService.SAVE_DIRECTORY).path_join(file_name)) == before[file_name], "failed write preserves valid bytes: " + file_name)
	_check(DirAccess.remove_absolute(folder.path_join(GameSaveService.SAVE_DIRECTORY).path_join("profile.json" + GameSaveService.SLOT_SUFFIX)) == OK, "remove only profile fault")
	_check(not Services.persist_for_suspend(), "partial retry still reports history/stats failure")
	_check((await _saved(folder, "profile.json")).musicVolume == 0.6
		and Services.get_match_history() == pending_history and Services.achievement_tracker().to_dict() == pending_stats,
		"partial retry commits profile and retains failed history/stats")
	for file_name: String in ["history.json", "stats.json"]:
		_check(FileAccess.get_file_as_bytes(folder.path_join(GameSaveService.SAVE_DIRECTORY).path_join(file_name)) == before[file_name], "partial retry protects failed file")
		_check(DirAccess.remove_absolute(folder.path_join(GameSaveService.SAVE_DIRECTORY).path_join(file_name + GameSaveService.SLOT_SUFFIX)) == OK, "remove remaining write fault")
	_check(Services.persist_for_suspend(), "same-owner suspend retry succeeds")
	_check(PlayerProfile.to_dict() == pending_profile and Services.get_match_history() == pending_history
		and Services.achievement_tracker().to_dict() == pending_stats, "successful retry preserves working payloads")
	_check(Services._game_saves.sdk.calls == 1, "synchronous saves never re-enter get_folder_async")
	_check((await _saved(folder, "profile.json")).musicVolume == 0.6, "retry writes latest profile")
	_check((await _saved(folder, "history.json"))[0].score == 2, "retry writes retained newest history")
	_check((await _saved(folder, "stats.json")).matches_completed == 2, "retry writes retained counters")

	Services._game_saves.failed_files.append("profile.json")
	PlayerProfile.music_volume = 0.8
	_check(not PlayerProfile.save_settings(), "departing owner's save failure returned")
	var saved_profile := FileAccess.get_file_as_bytes(folder.path_join(GameSaveService.SAVE_DIRECTORY).path_join("profile.json"))
	var old_user: Variant = Services.xbox_user()
	var old_generation := Services.account_generation()
	var old_store: GameSaveService = Services._game_saves
	await _reset()
	var b := _folder()
	_select("write-B", b)
	_check(await Services.sign_in(), "B ready after A write failure")
	_check(is_equal_approx(PlayerProfile.music_volume, 0.25), "A unsaved settings discarded at owner boundary")
	_status(old_store.write_now(old_user, old_generation, "profile.json", {"musicVolume": 0.8}),
		GameSaveService.Status.STALE, "old writer cannot retry after account loss")
	_check(FileAccess.get_file_as_bytes(folder.path_join(GameSaveService.SAVE_DIRECTORY).path_join("profile.json")) == saved_profile, "account loss never writes removed user")
	_check(not FileAccess.file_exists(b.path_join("profile.json")), "no transfer of A unsaved payload into B")

	var store := Doubles.Saves.new()
	var user := Doubles.User.new("rename")
	store.sdk.folder = _folder()
	_status(await store.prepare(user, 1), GameSaveService.Status.OK, "rename test prepared")
	_check(DirAccess.make_dir_absolute(store.sdk.folder.path_join(GameSaveService.SAVE_DIRECTORY).path_join("profile.json")) == OK, "block atomic rename destination")
	_status(store.write_now(user, 1, "profile.json", {}), GameSaveService.Status.FAILED, "real replacement failure")
	_check(DirAccess.dir_exists_absolute(store.sdk.folder.path_join(GameSaveService.SAVE_DIRECTORY).path_join("profile.json")), "replacement failure preserves destination")


func _unconditional_settings() -> void:
	print("CASE: unchanged explicit settings/Options saves write; notifications do not save")
	await _reset()
	var folder := _folder()
	_select("explicit-settings", folder)
	var store: Doubles.Saves = Services._game_saves
	_check(await Services._identity.sign_in(), "identity alone present for Options load gate")
	_check(not NROptionsRows.save() and not PlayerProfile.save_settings()
		and store.write_attempts.is_empty(), "settings and Options refuse auth-only state without writes")
	_check(await Services.sign_in(), "explicit save account fully ready")
	var signals := [0]
	var changed := func() -> void: signals[0] += 1
	PlayerProfile.settings_changed.connect(changed)
	PlayerProfile.music_volume = 0.7
	PlayerProfile.notify_settings_changed()
	_check(signals[0] == 1 and is_equal_approx(AudioManager.volumes.Music, 0.7)
		and store.write_attempts.is_empty(), "notification helper updates audio and UI without persistence")
	for attempt in 2:
		store.write_attempts.clear()
		_check(PlayerProfile.save_settings() and store.write_attempts == ["profile.json"],
			"explicit save writes even unchanged: " + str(attempt))
	for attempt in 2:
		store.write_attempts.clear()
		_check(NROptionsRows.save() and store.write_attempts == ["profile.json"],
			"Options save writes even unchanged: " + str(attempt))
	_check(signals[0] == 1, "persistence does not spuriously emit a settings change")
	PlayerProfile.settings_changed.disconnect(changed)
	_check((await _saved(folder, "profile.json")).musicVolume == 0.7, "notification refactor preserves explicit music 0.7")
	store.failed_files.assign(["profile.json"])
	store.write_attempts.clear()
	_check(not NROptionsRows.save() and store.write_attempts == ["profile.json"],
		"unchanged Options save returns storage error instead of success")
	store.failed_files.clear()
	store.write_attempts.clear()
	_check(NROptionsRows.save() and store.write_attempts == ["profile.json"], "unchanged Options save can retry")
	var tracker := Services.achievement_tracker()
	var reports_before: int = Services._achievements.reports.size()
	tracker.note_kill()
	_check(Services._achievements.reports.size() > reports_before, "tracker mutation still publishes achievement progress")
	reports_before = Services._achievements.reports.size()
	for attempt in 2:
		store.write_attempts.clear()
		_check(Services.persist_for_suspend() and store.write_attempts == FILES,
			"explicit full save writes all three even unchanged: " + str(attempt))
	_check(Services._achievements.reports.size() == reports_before, "repeated persistence does not repeat achievement reports")
	store.write_attempts.clear()
	_check(Services.report_match_result(_payload(42)) and store.write_attempts == ["history.json", "stats.json"],
		"match result writes only its two existing relevant payloads")
	store.write_attempts.clear()
	Services.cancel_sign_in()
	_check(not NROptionsRows.save() and not Services.persist_for_suspend()
		and store.write_attempts.is_empty(), "account loss blocks unchanged explicit saves")


func _history_limit() -> void:
	print("CASE: newest 50 completed matches on write and load")
	await _reset()
	var folder := _folder()
	_select("history", folder)
	_check(await Services.sign_in(), "history owner ready")
	for index in 55:
		_check(Services.report_match_result(_payload(index)), "completed match " + str(index))
	var history := Services.get_match_history()
	_check(history.size() == 50 and history.front().score == 54 and history.back().score == 5, "in-memory newest 50 exact bound")
	var saved: Array = await _saved(folder, "history.json")
	_check(saved.size() == 50 and saved.front().score == 54 and saved.back().score == 5, "persisted current array schema has newest 50")
	_check(Services.achievement_tracker().matches_completed == 55, "history bound does not truncate lifetime counters")
	var rows: Array = []
	for index in range(59, -1, -1):
		rows.append(_row(index))
	_json(folder, "history.json", rows)
	await _reset()
	_select("history", folder)
	_check(await Services.sign_in(), "load longer valid history")
	history = Services.get_match_history()
	_check(history.size() == 50 and history.front().score == 59 and history.back().score == 10, "load retains newest 50 without schema migration")


func _assert_denied() -> void:
	_check(not NetManager.start_offline(), "actual direct offline entry denied")
	_check(NetManager.last_error == NetManager.ACCOUNT_NOT_READY, "offline denial explains readiness")
	_check(not await NetManager.host_match(), "actual direct host entry denied")
	_check(NetManager.last_error == NetManager.ACCOUNT_NOT_READY, "host denial explains readiness")
	for request: JoinRequest in [NetManager.join_by_code("ABCDE"), NetManager.join_by_invite("fake-connection")]:
		await request.wait()
		_check(request.outcome == JoinRequest.Outcome.FAILED and request.reason == NetManager.ACCOUNT_NOT_READY,
			"actual code/invite entry returns failed JoinRequest")
		_check(not NetManager.joined_session_is_live(request), "denied request cannot own live session")
	var resolved: Dictionary = await NetManager._resolve_signed_in_user()
	_check(resolved.user == null and resolved.error == NetManager.ACCOUNT_NOT_READY, "existing authenticated user cannot bypass readiness")
	_check(not NetManager.has_session() and NetManager.players.is_empty(), "denials never create simulation or roster")


func _gameplay_and_invites() -> void:
	print("CASE: actual NetManager gates, Practice, account loss and InviteRouter readiness")
	await _reset()
	await _assert_denied()
	_select("gate", _folder())
	_check(await Services._identity.sign_in(), "authenticated identity without save readiness")
	_check(Services.playfab_user() != null, "existing user present for strict denial branch")
	await _assert_denied()
	InviteRouter._pending_request = {"connection_string": "fake-connection"}
	InviteRouter._pending_since_msec = Time.get_ticks_msec()
	_check(not InviteRouter._ready_to_join(), "invite waits for account readiness")
	_check(await Services.sign_in(), "gate account ready")
	_check(not InviteRouter._ready_to_join(), "ready invite still waits for front-end")
	var screen := NRScreen.new()
	screen.scene_file_path = ScreenManager.ACQUIRE_USER
	ScreenManager._stack.append(screen)
	_check(not InviteRouter._ready_to_join(), "invite cannot race acquire-user handoff")
	screen.scene_file_path = ScreenManager.MAIN_MENU
	_check(InviteRouter._ready_to_join(), "pending invite eligible with ready account/front-end")
	InviteRouter._joining = true
	_check(not InviteRouter._ready_to_join(), "invite routing single-flight")
	InviteRouter._joining = false
	ScreenManager._stack.clear()
	screen.free()
	InviteRouter.decline_pending_invite()
	_check(not InviteRouter.has_pending_invite(), "declining invite clears buffer")
	_check(NetManager.start_offline(), "actual ready Practice entry works")
	_check(NetManager.is_offline() and NetManager.has_session() and NetManager.is_host(), "Practice owns actual account-bound session")
	_check(NetManager.local_player().entity_id == "gate", "Practice roster belongs to ready account")
	var generation := Services.account_generation()
	NetManager._on_connectivity_changed(false)
	_check(Services.is_current_account(generation), "network hint does not invalidate ready save store")
	_check(Services.report_match_result(_payload(9)), "identified offline account retains persistence")
	var folder: String = Services._game_saves.sdk.folder
	var saved := FileAccess.get_file_as_bytes(folder.path_join(GameSaveService.SAVE_DIRECTORY).path_join("history.json"))
	Services.achievement_tracker().note_kill()
	PlayerProfile.music_volume = 0.81
	Services._identity.target.signed_in = false
	Services._on_user_changed(Services._identity.target, "removed")
	_check(not Services.is_account_ready() and not NetManager.has_session(), "account loss synchronously detaches Practice")
	_check(NetManager.players.is_empty() and Services.get_match_history().is_empty(), "account loss clears session/history")
	_check(not PlayerProfile.is_signed_in and PlayerProfile.music_volume == 0.25, "account loss clears identity and current profile")
	_check(Services._achievement_tracker.kills == 0, "account loss clears tracker")
	_check(FileAccess.get_file_as_bytes(folder.path_join(GameSaveService.SAVE_DIRECTORY).path_join("history.json")) == saved, "removal does not initiate save")
	await get_tree().process_frame
	await _assert_denied()


func _back_during_preparation() -> void:
	print("CASE: actual acquire-user Back rejects late completion and buffered invite")
	await _reset()
	_select("back", _folder())
	Services._game_saves.sdk.blocked = true
	ScreenManager.set_container(self)
	var screen: Variant = ScreenManager.push(ScreenManager.ACQUIRE_USER)
	_check(screen != null, "instantiate actual acquire-user scene")
	if screen == null:
		return
	InviteRouter._pending_request = {"connection_string": "fake-connection"}
	InviteRouter._pending_since_msec = Time.get_ticks_msec()
	screen._acquire_user()
	_check(Services.is_signing_in(), "screen starts real production sign-in")
	screen._stage_started_msec = Time.get_ticks_msec() - 26000
	screen._process(0.0)
	var buttons: Array[Node] = screen._menu_list.find_children("*", "Button", true, false)
	var labels: Array[String] = []
	for button: Button in buttons:
		labels.append(button.text)
		if button.text == "Retry":
			_check(button.disabled, "stalled Retry disabled while SDK drains")
	_check(labels.has("Back") and not labels.has("Continue Offline") and not labels.has("Practice"), "stall UI offers Back, no gameplay bypass")
	screen._on_back()
	_check(screen._state == screen.State.WAITING_FOR_INPUT and Services.is_signing_in(), "Back returns to prompt while SDK drains")
	_check(not InviteRouter.has_pending_invite(), "Back declines pending activation")
	Services._game_saves.sdk.released.emit()
	await get_tree().process_frame
	await get_tree().process_frame
	_check(not Services.is_account_ready() and not Services.is_signing_in(), "Back rejects late ready result")
	_check(ScreenManager.current_screen() == screen and screen._state == screen.State.WAITING_FOR_INPUT, "late completion cannot hand off UI")
	_check(Services._game_saves._folder.is_empty(), "Back cannot restore stale folder")
	ScreenManager.clear()
	await get_tree().process_frame


func _source_guards() -> void:
	print("CASE: narrow source guard supplements executed production behavior")
	var forbidden := [
		"SETTINGS_PATH", "adopt_local_cache", "_migrate_legacy_music_volume",
		"LEGACY_DEFAULT_MUSIC_VOLUME", "HISTORY_ENTRIES_KEY", "has_protected_storage",
		"user://", "ConfigFile.new(",
		"PFGameSaveFiles", "game_saves.add_user", "has_local_user_handle",
	]
	for path: String in [
		"res://scripts/autoload/player_profile.gd", "res://scripts/autoload/services.gd",
		"res://scripts/services/game_save_service.gd", "res://scripts/services/identity_service.gd",
	]:
		var source := FileAccess.get_file_as_string(path)
		var code := ""
		for line: String in source.split("\n"):
			if not line.strip_edges().begins_with("#"):
				code += line + "\n"
		for token: String in forbidden:
			_check(not code.contains(token), "no account-cache/migration token %s in %s" % [token, path])


func _capture_identity(identity: IdentityService, results: Array) -> void:
	results.append(await identity.sign_in())


func _identity_await_boundaries() -> void:
	print("CASE: production IdentityService invalidation at every authentication await")
	OS.set_environment("PF_CUSTOM_ID", "")
	for stage: String in ["default", "ui", "playfab", "display"]:
		for shutting_down: bool in [false, true]:
			var identity := Doubles.PlatformIdentity.new()
			identity.sdk.blocked_stage = stage
			identity.sdk.default_ok = stage != "ui"
			var subscribed: Array[bool] = []
			identity.platform_ready.connect(func() -> void:
				subscribed.append(identity.sdk.calls.is_empty()), CONNECT_ONE_SHOT)
			var results: Array = []
			_capture_identity(identity, results)
			_check(results.is_empty() and subscribed == [true], "user-change hook precedes account acquisition")
			_check(identity.sdk.calls.back() == stage, "authentication reached blocked " + stage)
			var calls := identity.sdk.calls.duplicate()
			if shutting_down:
				identity.begin_shutdown()
			else:
				identity.sign_out()
			identity.sdk.released.emit()
			await _settle(results, 1)
			_check(results == [false] and identity.sdk.calls == calls, "invalidated auth starts no later SDK stage")
			if not shutting_down:
				_check(identity.playfab_user == null and identity.gdk_user == null and identity.xbox_user_id.is_empty(),
					"late auth cannot restore signed-out identity")
	var valid := Doubles.PlatformIdentity.new()
	_check(await valid.sign_in(), "actual Xbox/PlayFab identity chain succeeds through mocks")
	_check(valid.sdk.calls == ["primary", "default", "playfab", "display"], "canonical successful authentication order")
	_check(valid.playfab_user == valid.sdk.user and valid.xbox_user_id == valid.sdk.user.xuid, "identity assembled from resolved platform user")
	valid.sign_out()
	OS.set_environment("PF_CUSTOM_ID", "A")


func _capture_control(chat: ChatService, user: Variant, results: Array) -> void:
	await chat.ensure_control(user, {})
	results.append(true)


func _chat_account_controls() -> void:
	print("CASE: actual ChatService cannot reuse or restore a departed user's control")
	var chat := Doubles.Chat.new()
	var a := Doubles.User.new("chat-A")
	var b := Doubles.User.new("chat-B")
	await chat.ensure_control(a, {})
	await chat.ensure_control(a, {})
	_check(chat.sdk.calls == ["create:chat-A"], "same-owner control reused across matches")
	await chat.ensure_control(b, {})
	_check(chat.sdk.calls == ["create:chat-A", "destroy:chat-A", "create:chat-B"], "new owner destroys old control before creating its own")
	_check(chat._chat_user == b, "retained chat control bound to B")
	await chat.destroy_control()
	chat.sdk.blocked = true
	var results: Array = []
	_capture_control(chat, a, results)
	chat.invalidate_session()
	chat.sdk.released.emit()
	await _settle(results, 1)
	_check(chat._chat_user == null and chat.sdk.calls.back() == "destroy:chat-A", "late created control is destroyed, never published")


func _capture_host(party: PartyService, user: Variant, results: Array) -> void:
	results.append(await party.host(user, 4, "Deathmatch"))


func _capture_net_host(results: Array) -> void:
	results.append(await NetManager.host_match())


func _party_await_boundaries() -> void:
	print("CASE: actual Party host and NetManager reject account loss across SDK awaits")
	await _reset()
	_select("host", _folder())
	_check(await Services.sign_in(), "host test ready")
	var user: Variant = Services.playfab_user()
	for stage: String in ["init", "chat", "network"]:
		var chat := Doubles.Chat.new()
		var party := Doubles.SessionParty.new(chat)
		party.block_init = stage == "init"
		chat.sdk.blocked = stage == "chat"
		party.sdk.blocked = stage == "network"
		var results: Array = []
		_capture_host(party, user, results)
		_check(results.is_empty(), "host blocked at " + stage)
		party.cancel_pending_join()
		match stage:
			"init": party.initialized.emit()
			"chat": chat.sdk.released.emit()
			"network": party.sdk.released.emit()
		await _settle(results, 1)
		_check(not results[0].ok and party.attachments == 0 and party.advertisements == 0, "stale host cannot attach or advertise")
		_check(party.sdk.creates == (1 if stage == "network" else 0), "host starts no next SDK stage after cancellation")
		if stage == "network":
			_check(party.sdk.network.leaves == 1, "late host network cleaned up by exact instance")
		await chat.destroy_control()
	var ready_chat := Doubles.Chat.new()
	var ready_party := Doubles.SessionParty.new(ready_chat)
	var hosted := await ready_party.host(user, 4, "Deathmatch")
	_check(hosted.ok and ready_party.attachments == 1 and ready_party.advertisements == 1, "successful host still builds and advertises")
	var wrong := Doubles.User.new("wrong")
	_check(not (await ready_party.host(wrong, 4, "Deathmatch")).ok, "Party direct host rejects wrong account")
	_check(not (await ready_party.join(wrong, "ABCDE")).ok, "Party direct code join rejects wrong account")
	_check(not (await ready_party.join_by_connection_string(wrong, "fake")).ok, "Party direct invite rejects wrong account")
	await ready_chat.destroy_control()
	Services._privileges = Doubles.Privileges.new()
	var privileges: Doubles.Privileges = Services._privileges
	var results: Array = []
	_capture_net_host(results)
	_check(results.is_empty() and privileges.calls == 1, "NetManager existing-user host awaits privilege check")
	Services.cancel_sign_in()
	privileges.released.emit()
	await _settle(results, 1)
	_check(results == [false] and not NetManager.has_session(), "account loss after privilege await cannot host")
	Services._privileges = null
	await get_tree().process_frame


func _capture_social(social: SocialService, sdk: Variant, user: Variant, results: Array) -> void:
	results.append(await social._ensure_group(sdk, user))


func _capture_profiles(profiles: ProfileService, user: Variant, results: Array) -> void:
	await profiles.resolve(user, user, [{"peer_id": 2, "entity_id": "peer", "xuid": "peer-xuid"}])
	results.append(true)


func _capture_gamertags(profiles: ProfileService, user: Variant, results: Array) -> void:
	await profiles._load_gamertags(user, PackedStringArray(["peer-xuid"]))
	results.append(true)


func _cache_invalidation() -> void:
	print("CASE: departed account's social and profile callbacks cannot refill caches")
	var user := Doubles.User.new("cache-A")
	var social := Doubles.Social.new()
	var results: Array = []
	_capture_social(social, social.sdk, user, results)
	social.clear()
	social.sdk.released.emit()
	await _settle(results, 1)
	_check(results == [false] and social._friends_group == null, "late friends group not cached")
	_check(social.sdk.destroyed == [social.sdk.group], "late group released rather than leaked")
	var profiles := Doubles.Profiles.new()
	results.clear()
	_capture_profiles(profiles, user, results)
	profiles.clear()
	profiles.sdk.released.emit()
	await _settle(results, 1)
	_check(profiles.sdk.calls == ["mapping"] and profiles._entity_by_xuid.is_empty() and profiles._gamertag_by_peer.is_empty(),
		"late mapping cannot start profile lookup or republish peer names")
	results.clear()
	_capture_gamertags(profiles, user, results)
	profiles.clear()
	profiles.sdk.released.emit()
	await _settle(results, 1)
	_check(profiles._gamertag_by_xuid.is_empty(), "late gamertags cannot refill account cache")


func _suspend_is_synchronous() -> void:
	print("CASE: suspend detaches without starting asynchronous SDK teardown")
	await _reset()
	_select("suspend", _folder())
	_check(await Services.sign_in(), "suspend account ready")
	_check(NetManager.start_offline(), "Practice started before suspend")
	var chat := Doubles.Chat.new()
	var party := Doubles.SessionParty.new(chat)
	Services._party = party
	Services._chat = chat
	_check(NetManager.abandon_for_suspend(), "suspend reports abandoned session")
	_check(party.leaves == 0 and not NetManager.has_session(), "suspend returns with no SDK leave call")
	_check(Services.is_account_ready(), "suspend retains account-owned folder")
	_check(not NetManager.start_offline(), "cannot start session until deferred teardown completes")
	await NetManager.finish_suspend_teardown()
	_check(party.leaves == 1 and not NetManager._account_teardown_pending, "resume drains SDK teardown")
	_check(NetManager.start_offline(), "same-owner Practice works after resume")
	Services._privileges = Doubles.Privileges.new()
	var privileges: Doubles.Privileges = Services._privileges
	var results: Array = []
	_capture_net_host(results)
	_check(results.is_empty(), "host waits for privilege before suspension")
	NetManager.abandon_for_suspend()
	await NetManager.finish_suspend_teardown()
	privileges.released.emit()
	await _settle(results, 1)
	_check(results == [false] and party.sdk.creates == 0, "resume cannot resurrect pre-suspend host after late privilege completion")
	Services._privileges = null
	Services._party = null
	Services._chat = null
