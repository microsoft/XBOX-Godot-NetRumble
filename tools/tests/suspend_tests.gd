extends RefCounted

const Fixture := preload("res://tools/tests/suspend_fixture.gd")


func run(test: Node) -> void:
	var audio_script: Script = AudioManager.get_script()
	var activity: ActivityService = Services._activity
	AudioManager.set_script(Fixture.Review.QuietAudio)
	for failed: Array in [[], ["profile.json"], ["history.json"], ["stats.json"], Fixture.FILES]:
		await _current_state_suspend(test, failed)
	for boundary: String in ["suspend", "quit"]:
		await _appearance_retry(test, boundary)
	await _resume_reacquires(test)
	for mode: String in ["match", "menu", "invite", "owner-loss"]:
		await _resume_frontend(test, mode)
	for mode: String in ["save", "quit"]:
		await _resume_dialogs(test, mode)
	for mode: String in ["unready", "missing-owner", "missing-folder", "account-loss"]:
		await _unready_suspend(test, mode)
	await _reload_terminated(test, "success")
	await _reload_terminated(test, "partial")
	Services._activity = activity
	AudioManager.set_script(audio_script)
	PlayerProfile.apply_dict(PlayerProfile.to_dict())


func _dispose(test: Node, fixture: RefCounted) -> void:
	fixture.store.watching = false
	ScreenManager.clear()
	# Do not let a deliberately deferred ordinary error dialog outlive this probe.
	fixture.app.free()
	ScreenManager.set_container(test)
	await NetManager.finish_suspend_teardown()
	await test._reset()
	Services._party = null
	Services._chat = null


func _current_state_suspend(test: Node, failed: Array) -> void:
	print("CASE: actual main Constrain/Suspend, Options open, unfinished counters, pending history; failures=", failed)
	await test._reset()
	var fixture := Fixture.new()
	test._check(await fixture.open(test, test._folder()), "suspend fixture ready with current changes in all three categories")
	if fixture.app == null:
		return
	fixture.store.failed_files.assign(failed)
	fixture.arm()
	var disk_before := fixture.disk_bytes()
	var sdk_before := fixture.sdk_calls()
	var frame := Engine.get_process_frames()
	fixture.app.notification(Node.NOTIFICATION_APPLICATION_FOCUS_OUT)
	test._check(fixture.app.is_constrained() and fixture.menu._in_options,
		"real Constrain leaves changed Options open")
	test._check(fixture.store.events.is_empty() and fixture.disk_bytes() == disk_before,
		"Constrain alone writes no settings, history or stats")
	test._check(fixture.memory_all() == fixture.pending, "Constrain preserves every current payload")
	var deferred := [false]
	(func() -> void: deferred[0] = true).call_deferred()
	fixture.app.notification(Node.NOTIFICATION_APPLICATION_PAUSED)
	test._check(Engine.get_process_frames() == frame and not deferred[0],
		"full main suspend returns in same frame without running deferred work")
	test._check(fixture.sdk_calls() == sdk_before,
		"suspend starts no authentication, storage setup, Party/chat/activity/achievement SDK work")
	test._check(ScreenManager.current_screen() == fixture.menu and fixture.menu._in_options,
		"suspend neither leaves Options to save nor waits for failure UI")
	test._check(fixture.store.events == ["begin:profile.json", "end:profile.json",
		"begin:history.json", "end:history.json", "begin:stats.json", "end:stats.json", "teardown"]
		and fixture.store.before_teardown, "every attempted payload finishes before actual session teardown")
	var expected := fixture.pending.duplicate(true)
	for name: String in Fixture.FILES:
		if name in failed:
			expected[name] = fixture.committed[name]
	test._check(fixture.store.teardown_data == expected,
		"successful bytes already readable at first local teardown operation; failed payload keeps prior data")
	test._check(fixture.memory_all() == fixture.pending, "all working payloads remain intact for next explicit save")
	test._check(fixture.read_all() == expected, "full-handler return has exact expected committed payloads")
	test._check(not NetManager.has_session() and fixture.app._match_dropped_by_suspend
		and fixture.app.quit_calls == 0 and not Services.is_shutting_down(),
		"suspend abandons the session without normal shutdown or synthetic match completion")
	test._check(Services.get_match_history().size() == 2
		and Services.achievement_tracker().matches_completed == 2,
		"unfinished match never creates a third completion/history row")
	fixture.store.failed_files.clear()
	fixture.arm()
	fixture.app.notification(Node.NOTIFICATION_APPLICATION_PAUSED)
	var retry_events: Array[String] = []
	for name: String in Fixture.FILES:
		retry_events.append("begin:" + name)
		retry_events.append("end:" + name)
	retry_events.append("teardown")
	test._check(fixture.store.events == retry_events and fixture.read_all() == fixture.pending,
		"repeat suspend writes all categories including prior successes without duplicating history")
	fixture.arm()
	disk_before = fixture.disk_bytes()
	fixture.app.notification(Node.NOTIFICATION_APPLICATION_PAUSED)
	test._check(fixture.store.events == retry_events and fixture.disk_bytes() != disk_before
		and fixture.read_all() == fixture.pending, "unchanged repeat suspend writes new revisions of all payloads")
	await _dispose(test, fixture)


func _appearance_retry(test: Node, boundary: String) -> void:
	print("CASE: actual NetManager appearance failure recovered by unconditional ", boundary)
	await test._reset()
	var fixture := Fixture.new()
	test._check(await fixture.open(test, test._folder()), "appearance fixture ready")
	if fixture.app == null:
		return
	test._check(Services.persist_for_suspend(), "all initial fixture data committed before appearance-only change")
	var before := fixture.disk_bytes()
	fixture.store.failed_files.assign(["profile.json"])
	fixture.store.write_attempts.clear()
	var errors: Array[String] = []
	var on_error := func(reason: String) -> void: errors.append(reason)
	Services.save_failed.connect(on_error)
	NetManager.set_local_appearance(2, 3)
	test._check(fixture.store.write_attempts == ["profile.json"] and errors.size() == 1,
		"actual appearance setter attempts initial write and surfaces injected failure")
	test._check(PlayerProfile.ship_color_id == 2 and PlayerProfile.ship_style_id == 3
		and NetManager.local_player().ship_color_id == 2 and NetManager.local_player().ship_style_id == 3,
		"failed appearance save preserves current profile and roster without a mutation marker")
	test._check(fixture.disk_bytes() == before, "failed appearance write protects all committed bytes")
	fixture.store.failed_files.clear()
	fixture.store.write_attempts.clear()
	fixture.arm()
	if boundary == "suspend":
		fixture.app.notification(Node.NOTIFICATION_APPLICATION_FOCUS_OUT)
		test._check(fixture.store.write_attempts.is_empty(), "Constrain does not retry failed appearance")
		fixture.app.notification(Node.NOTIFICATION_APPLICATION_PAUSED)
	else:
		fixture.app.request_shutdown()
	test._check(fixture.store.write_attempts == Fixture.FILES,
		"next " + boundary + " writes profile/history/stats, not only failed appearance")
	var saved := fixture.store.read(Services.xbox_user(), Services.account_generation(), "profile.json")
	test._check(saved.status == GameSaveService.Status.OK and saved.data.selectedShip == 3
		and saved.data.selectedColor == 2, boundary + " recovers appearance through production integrity writes")
	test._check(errors.size() == 1, "successful full retry adds no new failure signal")
	if boundary == "suspend":
		test._check(fixture.store.before_teardown
			and fixture.store.teardown_data["profile.json"].selectedShip == 3,
			"appearance recovery completed before actual suspend teardown")
	else:
		test._check(fixture.app.quit_calls == 1 and Services.is_shutting_down(),
			"appearance recovery completed before normal quit")
	Services.save_failed.disconnect(on_error)
	await _dispose(test, fixture)


func _resume_reacquires(test: Node) -> void:
	print("CASE: real main resume invalidates Xbox provider and repeats folder sync plus all loads")
	await test._reset()
	var fixture := Fixture.new()
	test._check(await fixture.open(test, test._folder()), "resume account ready")
	if fixture.app == null:
		return
	fixture.app.notification(Node.NOTIFICATION_APPLICATION_PAUSED)
	var generation := Services.account_generation()
	var calls := fixture.store.sdk.calls
	fixture.store.reads.clear()
	fixture.app.notification(Node.NOTIFICATION_APPLICATION_RESUMED)
	test._check(not Services.is_account_ready() and not Services.is_current_account(generation)
		and fixture.store.sdk.calls == calls, "resume synchronously blocks stale provider without native work in notification")
	fixture.store.sdk.folder_ok = false
	test._check(not await Services.sign_in() and not Services.is_account_ready(),
		"failed resume synchronization stays blocked and retryable")
	var before: Dictionary = fixture.memory_all()
	var folder: String = test._folder()
	test._json(folder, "profile.json", {"musicVolume": 0.7})
	test._json(folder, "history.json", [test._row(73)])
	test._json(folder, "stats.json", {"kills": "invalid"})
	fixture.store.sdk.folder = folder
	fixture.store.sdk.folder_ok = true
	fixture.store.sdk.blocked = true
	var results: Array = []
	test._capture_sign_in(results)
	test._check(results.is_empty() and not Services.is_account_ready(), "resume readiness waits for native Signal")
	fixture.store.sdk.released.emit()
	test._check(results == [false] and not Services.is_account_ready()
		and fixture.store.reads == Fixture.FILES and fixture.memory_all() == before,
		"invalid final resumed payload prevents publication of even the valid settings and history")
	test._check(not PlayerProfile.save_settings() and not NetManager.start_offline(),
		"failed resumed load cannot write old memory or start gameplay")
	test._json(folder, "stats.json", {"kills": 8})
	fixture.store.reads.clear()
	results.clear()
	test._capture_sign_in(results)
	test._check(results == [true] and fixture.store.reads == Fixture.FILES
		and fixture.store.sdk.calls == calls + 2, "resume Retry reloads all three through the reacquired provider")
	test._check(PlayerProfile.music_volume == 0.7 and Services.get_match_history()[0].score == 73
		and Services.achievement_tracker().kills == 8, "resume publishes authoritative freshly synchronized data")
	test._check(fixture.identity.calls == 1, "resume storage acquisition retains existing authentication")
	await _dispose(test, fixture)


func _frames(test: Node) -> void:
	await test.get_tree().process_frame
	await test.get_tree().process_frame


func _resume_frontend(test: Node, mode: String) -> void:
	print("CASE: actual resume acquisition handoff, notice and invite priority: ", mode)
	await test._reset()
	var fixture := Fixture.new()
	test._check(await fixture.open(test, test._folder()), "resume frontend account ready")
	if fixture.app == null:
		return
	if mode == "menu":
		await NetManager.leave_match_and_wait()
	fixture.app.notification(Node.NOTIFICATION_APPLICATION_PAUSED)
	fixture.app.notification(Node.NOTIFICATION_APPLICATION_RESUMED)
	await _frames(test)
	var acquire: Variant = ScreenManager.current_screen()
	test._check(acquire != null and acquire.scene_file_path == ScreenManager.ACQUIRE_USER
		and not Services.is_account_ready(), "resume routes to gated acquisition, not a stale menu")
	if acquire == null or acquire.scene_file_path != ScreenManager.ACQUIRE_USER:
		await _dispose(test, fixture)
		return
	var folder: String = test._folder()
	test._json(folder, "profile.json", {"musicVolume": 0.43})
	test._json(folder, "history.json", [test._row(81)])
	test._json(folder, "stats.json", {"kills": 19})
	fixture.store.sdk.folder = folder
	fixture.store.sdk.blocked = true
	fixture.store.write_attempts.clear()
	acquire._acquire_user()
	test._check(not Services.is_account_ready() and not NetManager.start_offline()
		and acquire._state == acquire.State.SIGNING_IN, "actual acquisition remains blocked on resumed native Signal")
	if mode == "owner-loss":
		fixture.identity.target.signed_in = false
		Services._on_user_changed(fixture.identity.target, "removed")
		fixture.store.sdk.released.emit()
		await _frames(test)
		test._check(not Services.is_account_ready() and PlayerProfile.music_volume == 0.25
			and Services._history.is_empty() and Services._achievement_tracker.kills == 0,
			"account loss during resume cannot publish new data or previous memory")
		test._check(fixture.store.write_attempts.is_empty() and fixture.app._resume_generation == -1
			and not fixture.app._match_dropped_by_suspend, "owner loss cancels resume notice without stale writes")
		await _dispose(test, fixture)
		return
	var privileges: Fixture.Doubles.Privileges
	if mode == "invite":
		privileges = Fixture.Doubles.Privileges.new()
		Services._privileges = privileges
		InviteRouter._on_join_requested({"connection_string": "resume-invite"})
		test._check(InviteRouter.has_pending_invite() and not InviteRouter._joining,
			"resume invite remains buffered until acquisition hands off")
	fixture.store.sdk.released.emit()
	test._check(Services.is_account_ready() and PlayerProfile.music_volume == 0.43
		and Services.get_match_history()[0].score == 81 and Services.achievement_tracker().kills == 19,
		"actual acquisition publishes fresh synchronized state transactionally")
	test._check(fixture.store.write_attempts.is_empty(), "resume never writes pre-suspend memory over synchronized data")
	acquire._hand_off()
	await _frames(test)
	var current: Variant = ScreenManager.current_screen()
	if mode == "match":
		test._check(current != null and current.scene_file_path == ScreenManager.DIALOG_BOX
			and current._title == "Match Ended", "abandoned-match notice survives reload and actual acquire handoff")
		if current != null and current.scene_file_path == ScreenManager.DIALOG_BOX:
			current._ok_button.pressed.emit()
		await _frames(test)
		test._check(ScreenManager.current_screen().scene_file_path == ScreenManager.MAIN_MENU
			and not fixture.app._match_dropped_by_suspend, "match notice is shown once, never resumes the match")
	elif mode == "menu":
		test._check(current != null and current.scene_file_path == ScreenManager.MAIN_MENU,
			"menu-only resume reloads without a fabricated Match Ended notice")
	else:
		test._check(InviteRouter._joining and not InviteRouter.has_pending_invite() and current != null
			and current.scene_file_path == ScreenManager.LOADING and not fixture.app._match_dropped_by_suspend,
			"invite routing owns the frontend rather than being covered by a resume notice")
		Services.cancel_sign_in()
		privileges.released.emit()
	await _dispose(test, fixture)


func _resume_dialogs(test: Node, mode: String) -> void:
	print("CASE: resume releases prior-generation save/quit modal guards: ", mode)
	await test._reset()
	var fixture := Fixture.new()
	test._check(await fixture.open(test, test._folder()), "resume dialog account ready")
	if fixture.app == null:
		return
	await NetManager.leave_match_and_wait()
	fixture.store.failed_files.assign(["profile.json"])
	if mode == "save":
		test._check(not PlayerProfile.save_settings(), "open ordinary save failure")
	else:
		fixture.app.request_shutdown()
	await _frames(test)
	var old_dialog: Variant = ScreenManager.current_screen()
	test._check(old_dialog != null and old_dialog.scene_file_path == ScreenManager.DIALOG_BOX
		and (fixture.app._save_dialog_open if mode == "save" else fixture.app._shutdown_save_pending),
		"real prior-generation modal has a pending guard")
	if old_dialog == null or old_dialog.scene_file_path != ScreenManager.DIALOG_BOX:
		await _dispose(test, fixture)
		return
	fixture.app.notification(Node.NOTIFICATION_APPLICATION_PAUSED)
	fixture.app.notification(Node.NOTIFICATION_APPLICATION_RESUMED)
	test._check(not fixture.app._save_dialog_open and not fixture.app._shutdown_save_pending
		and fixture.app._save_failure_pending.is_empty(), "resume resets all abandoned account-dialog guards")
	old_dialog.dismissed.emit(true)
	test._check(fixture.app.quit_calls == 0 and not Services.is_shutting_down(),
		"late old modal acceptance cannot save or quit the resumed generation")
	await _frames(test)
	var acquire: Variant = ScreenManager.current_screen()
	test._check(acquire != null and acquire.scene_file_path == ScreenManager.ACQUIRE_USER,
		"resume removes obsolete modal and exposes acquisition")
	if acquire == null or acquire.scene_file_path != ScreenManager.ACQUIRE_USER:
		await _dispose(test, fixture)
		return
	fixture.store.failed_files.clear()
	acquire._acquire_user()
	test._check(Services.is_account_ready(), "resumed account can reload after old modal removal")
	acquire._hand_off()
	await _frames(test)
	fixture.store.failed_files.assign(["profile.json"])
	if mode == "save":
		test._check(not PlayerProfile.save_settings(), "new generation save failure returned")
	else:
		fixture.app.request_shutdown()
	await _frames(test)
	var new_dialog: Variant = ScreenManager.current_screen()
	test._check(new_dialog != null and new_dialog.scene_file_path == ScreenManager.DIALOG_BOX
		and new_dialog._title == "Could Not Save", "new generation save/quit errors still open a real modal")
	if new_dialog != null and new_dialog.scene_file_path == ScreenManager.DIALOG_BOX:
		if mode == "quit":
			test._check(new_dialog._ok_button.text == "Retry" and new_dialog._cancel_button.text == "Back",
				"new quit decision remains Retry/Back rather than a stuck guard")
			new_dialog._cancel_button.pressed.emit()
		else:
			new_dialog._ok_button.pressed.emit()
	test._check(not fixture.app._save_dialog_open and not fixture.app._shutdown_save_pending
		and fixture.app.quit_calls == 0, "new modal closes and releases its own guard")
	await _dispose(test, fixture)


func _unready_suspend(test: Node, mode: String) -> void:
	print("CASE: actual main Suspend fails closed without new setup: ", mode)
	await test._reset()
	var fixture := Fixture.new()
	test._check(await fixture.open(test, test._folder()), "unready suspend starts from changed owned data")
	if fixture.app == null:
		return
	var disk_before := fixture.disk_bytes()
	match mode:
		"unready":
			Services._ready_owner = null
		"missing-owner":
			fixture.identity.gdk_user = null
		"missing-folder":
			fixture.store.reset()
		"account-loss":
			fixture.identity.target.signed_in = false
			Services._on_user_changed(fixture.identity.target, "removed")
	fixture.arm()
	var sdk_before := fixture.sdk_calls()
	var frame := Engine.get_process_frames()
	fixture.app.notification(Node.NOTIFICATION_APPLICATION_FOCUS_OUT)
	fixture.app.notification(Node.NOTIFICATION_APPLICATION_PAUSED)
	test._check(Engine.get_process_frames() == frame and fixture.sdk_calls() == sdk_before,
		mode + ": suspend returns synchronously without acquiring an account/folder or SDK teardown")
	test._check(fixture.store.events == ["teardown"] and fixture.disk_bytes() == disk_before,
		mode + ": no attempt writes or overwrites another account's data")
	test._check(not Services.is_account_ready() and not NetManager.has_session(),
		mode + ": remains blocked with local session detached")
	if mode == "account-loss":
		test._check(Services.get_match_history().is_empty()
			and Services._achievement_tracker.kills == 0 and PlayerProfile.music_volume == 0.25,
			"account loss clears memory rather than saving stale data on suspend")
	else:
		test._check(fixture.memory_all() == fixture.pending, mode + ": skipped working data remains intact")
	await _dispose(test, fixture)


func _reload_terminated(test: Node, mode: String) -> void:
	print("CASE: fresh process reload after full main suspend immediately killed: ", mode)
	await test._reset()
	var folder := OS.get_environment("NR_SAVE_TEST_ROOT").path_join("test-data/suspend-" + mode)
	test._select("suspend-fixture", folder)
	test._check(await Services.sign_in(), "fresh sign-in loads killed suspend writer's committed files")
	test._check(is_equal_approx(PlayerProfile.music_volume, 0.26),
		"terminated Options edit reloads without Back, resume, Quit or another frame")
	var history := Services.get_match_history()
	test._check(history.size() == (1 if mode == "partial" else 2)
		and int(history[0].score) == (11 if mode == "partial" else 22),
		"fresh reload recovers pending history or prior history when its write failed")
	var stats := Services.achievement_tracker().to_dict()
	test._check(stats.matches_completed == 2 and stats.kills == 1 and stats.deaths == 1
		and stats.asteroids_destroyed == 1 and stats.weapons_fired == 2 and stats.buffs_collected == 2,
		"fresh reload recovers unfinished lifetime counters without fabricating a completion")
	test._check(not NetManager.has_session() and Services.achievement_tracker()._match_deaths == 0,
		"reload does not resurrect match state")
