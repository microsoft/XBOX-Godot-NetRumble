extends RefCounted

const Doubles := preload("res://tools/tests/doubles.gd")
const MainProbe := preload("res://tools/tests/review_main.gd")


class QuietAudio extends "res://tools/tests/audio.gd":
	func play_music(_loop: bool = true) -> void:
		pass

	func stop_music() -> void:
		pass


class FaultSaves extends Doubles.Saves:
	var fail_writes := true
	var writes := 0

	func write_now(user: Variant, generation: int, file_name: String, data: Variant) -> Dictionary:
		writes += 1
		if fail_writes:
			return {"status": Status.FAILED, "data": {}, "reason": "Injected final-save failure."}
		return super.write_now(user, generation, file_name, data)


class ActivityCall extends RefCounted:
	signal completed(ok: bool)
	var owner: Variant
	var connection := ""
	var restriction := ""
	var maximum := 0
	var count := 0
	var group := ""


class ActivitySDK extends RefCounted:
	signal delete_completed(ok: bool)
	var calls: Array[ActivityCall] = []
	var deletes: Array = []
	var block_delete := false

	func set_activity_async(user: Variant, connection: String, restriction: String,
			maximum: int, count: int, group: String, _cross_platform: bool) -> Dictionary:
		var call := ActivityCall.new()
		call.owner = user
		call.connection = connection
		call.restriction = restriction
		call.maximum = maximum
		call.count = count
		call.group = group
		calls.append(call)
		var ok: bool = await call.completed
		return {"ok": ok, "message": "Injected activity completion."}

	func delete_activity_async(user: Variant) -> Dictionary:
		deletes.append(user)
		if block_delete:
			return {"ok": await delete_completed, "message": "Injected retirement result."}
		return {"ok": true}


class Activity extends ActivityService:
	var sdk := ActivitySDK.new()

	func _multiplayer_activity() -> Variant:
		return sdk


class HostParty extends Doubles.SessionParty:
	var connection := ""

	func host(user: Variant, _maximum: int, _mode: String, _deadline_msec: int = 0) -> Dictionary:
		connection = "connection-" + user.xuid
		return {"ok": true, "peer": OfflineMultiplayerPeer.new(), "code": user.xuid}

	# The hosted session's string. The optional context selects a matchmaking lobby in
	# production; this hosted double only ever has the one.
	func lobby_connection_string(_context: PartyService.LobbyContext = null) -> String:
		return connection


class DeniedPrivileges extends PrivilegeService:
	func ensure(_user: Variant, _privilege: int) -> Dictionary:
		return {"granted": false, "message": "Injected multiplayer denial."}


func run(test: Node) -> void:
	var audio_script: Script = AudioManager.get_script()
	var activity: ActivityService = Services._activity
	AudioManager.set_script(QuietAudio)
	for menu_path: String in [ScreenManager.MAIN_MENU, ScreenManager.GAME_MENU]:
		for inline_dialog: bool in [false, true]:
			await _options_failure_back(test, menu_path, inline_dialog)
	for late: bool in [false, true]:
		await _resume_invite_claim(test, late)
	await _normal_quit(test)
	await _quit_account_replacement(test)
	await _forced_drain(test)
	await _activity_replacement(test, true, false)
	await _activity_replacement(test, false, true)
	for mode: String in ["suspend", "resume-new-session", "suspend-pending", "suspend-account-loss"]:
		await _activity_resume(test, mode)
	for mode: String in ["quit", "quit-timeout", "quit-failure"]:
		await _activity_quit(test, mode)
	await _activity_retiring_replacement(test)
	Services._activity = activity
	AudioManager.set_script(audio_script)
	PlayerProfile.apply_dict(PlayerProfile.to_dict())


func _main(test: Node) -> Node:
	var app := preload("res://scenes/main.tscn").instantiate()
	app.set_script(MainProbe)
	test.add_child(app)
	return app


func _ready_fault_account(test: Node, id: String) -> FaultSaves:
	var store := FaultSaves.new()
	Services._game_saves = store
	test._select(id, test._folder())
	test._check(await Services.sign_in(), "review lifecycle: " + id + " ready")
	PlayerProfile.music_volume = 0.37
	return store


func _dispose_main(test: Node, app: Node) -> void:
	await test.get_tree().process_frame
	ScreenManager.clear()
	app.queue_free()
	await test.get_tree().process_frame
	ScreenManager.set_container(test)
	await test._reset()


func _normal_quit(test: Node) -> void:
	print("CASE: actual main Quit/window close preserves current data and offers Retry/Back")
	await test._reset()
	var store := await _ready_fault_account(test, "quit-A")
	var app := _main(test)
	app.request_shutdown()
	var dialog: Variant = ScreenManager.current_screen()
	test._check(dialog != null and dialog._ok_button.text == "Retry"
		and dialog._cancel_button.text == "Back" and dialog._cancel_button.visible,
		"failed final save presents actual Retry/Back modal")
	if dialog == null:
		await _dispose_main(test, app)
		return
	test._check(not Services.is_shutting_down() and app.quit_calls == 0
		and PlayerProfile.music_volume == 0.37, "failure retains current profile before shutdown")
	var writes := store.writes
	app.request_shutdown()
	app._notification(Node.NOTIFICATION_WM_CLOSE_REQUEST)
	await test.get_tree().process_frame
	test._check(ScreenManager.current_screen() == dialog and ScreenManager._stack.size() == 1
		and store.writes == writes and app.quit_calls == 0,
		"repeated Quit/window close neither bypasses save nor duplicates modal/write")
	dialog._cancel_button.pressed.emit()
	test._check(not app._shutdown_save_pending and not Services.is_shutting_down()
		and PlayerProfile.music_volume == 0.37 and app.quit_calls == 0,
		"Back cancels normal quit without discarding pending profile")

	app._notification(Node.NOTIFICATION_WM_CLOSE_REQUEST)
	dialog = ScreenManager.current_screen()
	test._check(dialog != null, "window close uses same final-save prompt")
	writes = store.writes
	dialog._ok_button.pressed.emit()
	var retry_dialog: Variant = ScreenManager.current_screen()
	test._check(retry_dialog != null and retry_dialog != dialog and store.writes == writes + 3
		and not Services.is_shutting_down() and PlayerProfile.music_volume == 0.37,
		"unsuccessful Retry repeats real commit and remains cancellable")
	store.fail_writes = false
	retry_dialog._ok_button.pressed.emit()
	test._check(app.quit_calls == 1 and Services.is_shutting_down()
		and store.writes == writes + 6, "successful Retry commits all three payloads before actual quit path")
	var saved := store.read(Services.xbox_user(), Services.account_generation(), GameSaveService.SAVE_FILE_NAME)
	test._check(saved.status == GameSaveService.Status.OK and is_equal_approx(saved.data.musicVolume, 0.37),
		"Retry stored actual profile through GameSaveService, independent of disk layout")
	await _dispose_main(test, app)


func _quit_account_replacement(test: Node) -> void:
	print("CASE: old quit dialog cannot shut down or unlock replacement account's quit")
	await test._reset()
	await _ready_fault_account(test, "quit-old")
	var app := _main(test)
	app.request_shutdown()
	var old_dialog: Variant = ScreenManager.current_screen()
	test._check(old_dialog != null, "old account's failed quit waits for a modal")
	if old_dialog == null:
		await _dispose_main(test, app)
		return
	# Replacement readiness now waits for teardown. Retain the old signal explicitly
	# across that frame rather than relying on a queued-for-deletion modal surviving.
	ScreenManager._stack.erase(old_dialog)
	old_dialog.reparent(test)
	old_dialog.hide()
	Services.cancel_sign_in()
	await _ready_fault_account(test, "quit-new")
	app.request_shutdown()
	var new_dialog: Variant = ScreenManager.current_screen()
	test._check(new_dialog != old_dialog and app._shutdown_save_pending, "replacement owns a new pending quit")
	# Complete the captured old modal before deferred routing removes it. This models
	# a stale UI completion without pressing the new account's foreground buttons.
	old_dialog.dismissed.emit(true)
	old_dialog.free()
	test._check(app.quit_calls == 0 and not Services.is_shutting_down()
		and app._shutdown_save_pending and PlayerProfile.music_volume == 0.37,
		"old Retry neither quits B nor releases B's single-flight guard")
	app._notification(Node.NOTIFICATION_WM_CLOSE_REQUEST)
	test._check(ScreenManager.current_screen() == new_dialog and app.quit_calls == 0,
		"close after stale A completion still cannot bypass B's failure")
	new_dialog._cancel_button.pressed.emit()
	test._check(not app._shutdown_save_pending and app.quit_calls == 0,
		"B's own Back releases its quit request")
	await _dispose_main(test, app)


func _forced_drain(test: Node) -> void:
	print("CASE: sign-in shutdown retains separate forced-drain deadline")
	await test._reset()
	test._select("quit-signing-in", test._folder())
	Services._identity.blocked = true
	var results: Array = []
	test._capture_sign_in(results)
	var app := _main(test)
	app.request_shutdown()
	test._check(Services.is_shutting_down() and app._quit_pending
		and not app._shutdown_save_pending and ScreenManager.current_screen() == null,
		"unready in-flight sign-in enters drain without a save modal")
	app._quit_deadline_msec = 0
	app._process(0.0)
	test._check(app.quit_calls == 1, "deadline can still force exit during platform drain")
	Services._identity.released.emit()
	await test.get_tree().process_frame
	test._check(results == [false] and app.quit_calls == 1, "late sign-in cannot repeat expired quit")
	await _dispose_main(test, app)


func _activity_replacement(test: Node, old_ok: bool, refresh_b: bool) -> void:
	print("CASE: actual PlatformSession serializes stale A completion and B publication (old ok=%s)" % old_ok)
	await test._reset()
	var previous_activity: ActivityService = Services._activity
	var activity := Activity.new()
	Services._activity = activity
	Services._party = HostParty.new(null)
	test._select("activity-A", test._folder())
	test._check(await Services.sign_in(), "activity A ready")
	test._check(await NetManager.host_match(), "A hosts through actual NetManager")
	var platform: PlatformSession = NetManager._platform
	test._check(activity.sdk.calls.size() == 1 and platform._activity_writing, "A publication delayed at actual SDK boundary")
	var a: ActivityCall = activity.sdk.calls[0]
	Services.cancel_sign_in()
	await test.get_tree().process_frame
	test._check(platform._activity_remote == PlatformSession._Remote.UNKNOWN
		and not platform._activity_published, "actual removal invalidates A advertisement")
	test._select("activity-B", test._folder())
	test._check(await Services.sign_in(), "activity B ready while A SDK call pending")
	test._check(await NetManager.host_match(), "B hosts while previous account writer drains")
	NetManager.roster_changed.emit()
	await test.get_tree().create_timer(0.6).timeout
	test._check(activity.sdk.calls.size() == 1 and platform._activity_dirty,
		"B host and coalesced roster refresh wait behind single A writer")
	a.completed.emit(old_ok)
	test._check(activity.sdk.calls.size() == 2, "A completion automatically starts queued B publication")
	if activity.sdk.calls.size() != 2:
		Services.cancel_sign_in()
		await test.get_tree().process_frame
		Services._activity = previous_activity
		Services._party = null
		return
	var b: ActivityCall = activity.sdk.calls[1]
	test._check(b.owner == Services.xbox_user() and b.owner != a.owner
		and b.connection == "connection-activity-B" and b.group == "activity-B" and b.count == 1,
		"resumed writer uses B owner and B hosted session, never stale A payload")
	test._check(platform._activity_writing and platform._activity_remote != PlatformSession._Remote.PUBLISHED
		and not platform._activity_retry_pending and platform._activity_retries_used == 0
		and activity.sdk.deletes.is_empty(), "stale A result cannot confirm, clear, or schedule retry for B")
	if refresh_b:
		var player := PlayerState.new()
		player.peer_id = 2
		NetManager.players[2] = player
		NetManager.roster_changed.emit()
		await test.get_tree().create_timer(0.6).timeout
		test._check(activity.sdk.calls.size() == 2 and platform._activity_dirty,
			"B roster change queues without overlapping its pending SDK write")
	b.completed.emit(true)
	if refresh_b:
		test._check(activity.sdk.calls.size() == 3 and activity.sdk.calls[2].count == 2,
			"B completion publishes exactly one newer roster snapshot")
		if activity.sdk.calls.size() == 3:
			activity.sdk.calls[2].completed.emit(true)
	test._check(not platform._activity_writing and not platform._activity_dirty
		and platform._activity_remote == PlatformSession._Remote.PUBLISHED,
		"only B confirmation settles current desired activity")
	var expected := 3 if refresh_b else 2
	await test.get_tree().create_timer(1.1).timeout
	test._check(activity.sdk.calls.size() == expected and activity.sdk.deletes.is_empty()
		and not platform._activity_retry_pending, "settled writer neither duplicates publication nor loops/retries stale A")
	Services.cancel_sign_in()
	await test.get_tree().process_frame
	Services._activity = previous_activity
	Services._party = null
	await test._reset()


func _frames(test: Node) -> void:
	await test.get_tree().process_frame
	await test.get_tree().process_frame


func _press_row(test: Node, rows: NRMenuList, label: String) -> void:
	for row: Control in rows._rows:
		if row is NRButton and row.text == label:
			row.pressed.emit()
			return
	test._check(false, "missing actual menu action: " + label)


func _options_failure_back(test: Node, menu_path: String, inline_dialog: bool) -> void:
	print("CASE: actual Options Back escapes failed save; menu=", menu_path, " inline=", inline_dialog)
	await test._reset()
	var store := await _ready_fault_account(test, "options-back")
	var app := _main(test)
	var in_match := menu_path == ScreenManager.GAME_MENU
	if in_match:
		test._check(NetManager.start_offline(), "Options fixture starts actual Practice")
	var menu: Variant = ScreenManager.push(menu_path)
	var rows: NRMenuList = menu._menu if in_match else menu._menu_list
	_press_row(test, rows, "Options")
	var show_inline := func(_reason: String) -> void: app._show_save_failure(Services.account_generation())
	if inline_dialog:
		Services.save_failed.connect(show_inline)
	var writes := store.writes
	_press_row(test, rows, "Back")
	test._check(not menu._in_options and store.writes == writes + 1
		and PlayerProfile.music_volume == 0.37, "Back attempts unchanged current settings, returns rows and retains failed values")
	await _frames(test)
	var dialog: Variant = ScreenManager.current_screen()
	test._check(dialog != null and dialog.scene_file_path == ScreenManager.DIALOG_BOX
		and dialog._title == "Could Not Save", "Back navigation does not pop either inline or deferred failure dialog")
	if dialog != null and dialog.scene_file_path == ScreenManager.DIALOG_BOX:
		test._check(dialog.is_ancestor_of(test.get_viewport().gui_get_focus_owner()),
			"rebuilt Options parent cannot steal controller focus from save error")
		dialog._ok_button.pressed.emit()
	test._check(ScreenManager.current_screen() == menu and not menu._in_options,
		"dismissing failure returns to actual main/pause actions, not trapped Options")
	if inline_dialog:
		Services.save_failed.disconnect(show_inline)
	if in_match:
		_press_row(test, rows, "Leave Match")
		dialog = ScreenManager.current_screen()
		test._check(dialog != null and dialog._title == "Leave Match", "Leave is reachable after Options failure")
		if dialog != null:
			dialog._cancel_button.pressed.emit()
		_press_row(test, rows, "Resume")
		test._check(ScreenManager.current_screen() == null and NetManager.has_session(), "Resume remains reachable without saving again")
	store.fail_writes = false
	test._check(Services.persist_for_suspend(), "later explicit boundary saves retained settings without another edit")
	var saved := store.read(Services.xbox_user(), Services.account_generation(), "profile.json")
	test._check(saved.status == GameSaveService.Status.OK and saved.data.musicVolume == 0.37,
		"later retry persists retained actual settings")
	# A stale screen cannot use the relaxed navigation rule to bypass ownership.
	if in_match:
		menu = ScreenManager.push(menu_path)
		rows = menu._menu
	_press_row(test, rows, "Options")
	Services.invalidate_saves_for_resume()
	writes = store.writes
	menu._on_options_back()
	test._check(menu._in_options and store.writes == writes, "unready/stale account still blocks Options writes and navigation")
	await _dispose_main(test, app)


func _resume_invite_claim(test: Node, late: bool) -> void:
	print("CASE: actual Cannot Join modal interrupted by resume; late completion=", late)
	await test._reset()
	var store := await _ready_fault_account(test, "invite-resume")
	store.fail_writes = false
	var app := _main(test)
	ScreenManager.push(ScreenManager.MAIN_MENU)
	Services._privileges = DeniedPrivileges.new()
	InviteRouter._on_join_requested({"connection_string": "denied-first"})
	var old_dialog: Variant = ScreenManager.current_screen()
	var old_generation := Services.account_generation()
	test._check(old_dialog != null and old_dialog.scene_file_path == ScreenManager.DIALOG_BOX
		and old_dialog._title == "Cannot Join" and InviteRouter._joining, "actual denied invite awaits its outcome modal")
	if old_dialog == null or old_dialog.scene_file_path != ScreenManager.DIALOG_BOX:
		await _dispose_main(test, app)
		return
	InviteRouter._on_join_requested({"connection_string": "newer-buffered"})
	test._check(InviteRouter.has_pending_invite(), "newer invite buffers behind old outcome")
	if late:
		# Retain the old UI signal for an explicit late-answer test; the other case lets
		# replace_all free it, reproducing the orphaned-await defect.
		ScreenManager._stack.erase(old_dialog)
		old_dialog.reparent(test)
		old_dialog.hide()
	app.notification(Node.NOTIFICATION_APPLICATION_PAUSED)
	app.notification(Node.NOTIFICATION_APPLICATION_RESUMED)
	test._check(not InviteRouter._joining and InviteRouter.has_pending_invite()
		and InviteRouter._joining_generation != old_generation, "resume revokes old claim without discarding newer invite")
	await _frames(test)
	var acquire: Variant = ScreenManager.current_screen()
	var privileges := Doubles.Privileges.new()
	Services._privileges = privileges
	test._check(acquire != null and acquire.scene_file_path == ScreenManager.ACQUIRE_USER, "resume waits on actual acquisition")
	if acquire == null or acquire.scene_file_path != ScreenManager.ACQUIRE_USER:
		if late:
			old_dialog.free()
		await _dispose_main(test, app)
		return
	acquire._acquire_user()
	acquire._hand_off()
	test._check(InviteRouter._joining and privileges.calls == 1 and not InviteRouter.has_pending_invite()
		and ScreenManager.current_screen().scene_file_path == ScreenManager.LOADING,
		"new buffered invitation drains into actual joining flow after reacquisition")
	InviteRouter._on_join_requested({"connection_string": "newest-buffered"})
	if late:
		old_dialog.dismissed.emit(true)
		old_dialog.free()
	else:
		InviteRouter._finish_join(old_generation)
	test._check(InviteRouter._joining and InviteRouter.has_pending_invite() and privileges.calls == 1,
		"stale outcome cannot release replacement claim or consume its newer pending invitation")
	Services.cancel_sign_in()
	privileges.released.emit()
	await _dispose_main(test, app)


func _host_activity(test: Node) -> Activity:
	var activity := Activity.new()
	Services._activity = activity
	Services._party = HostParty.new(null)
	test._select("retirement-owner", test._folder())
	test._check(await Services.sign_in() and await NetManager.host_match(), "real ready account hosts advertised lobby")
	test._check(activity.sdk.calls.size() == 1, "actual activity publication reaches SDK")
	if activity.sdk.calls.size() > 0:
		var call: ActivityCall = activity.sdk.calls[0]
		test._check(call.restriction == ActivityService.JOIN_RESTRICTION and call.restriction == "followed"
			and call.maximum == Assets.game_mode(NetManager.game_mode_type).player_count
			and call.group == NetManager.join_code and not call.group.is_empty(),
			"hosted activity keeps its followed audience, mode capacity and join-code group id")
	return activity


func _confirm_activity(test: Node, activity: Activity) -> void:
	# Hosting can queue a roster refresh behind the first publication.
	for index in 4:
		if not NetManager._platform._activity_writing or index >= activity.sdk.calls.size():
			break
		activity.sdk.calls[index].completed.emit(true)
	test._check(not NetManager._platform._activity_writing
		and NetManager._platform._activity_remote == PlatformSession._Remote.PUBLISHED,
		"initial advertised lobby and any queued roster refresh are confirmed")


func _activity_resume(test: Node, mode: String) -> void:
	print("CASE: owner-bound activity retirement through actual main suspend/resume: ", mode)
	await test._reset()
	var activity := await _host_activity(test)
	var owner: Variant = Services.xbox_user()
	var platform: PlatformSession = NetManager._platform
	if mode != "suspend-pending":
		_confirm_activity(test, activity)
	var publications := activity.sdk.calls.size()
	var app := _main(test)
	activity.sdk.block_delete = true
	app.notification(Node.NOTIFICATION_APPLICATION_PAUSED)
	test._check(activity.sdk.deletes.is_empty() and activity.sdk.calls.size() == publications
		and platform._activity_owner == owner and platform._activity_remote != PlatformSession._Remote.CLEARED,
		"suspend retains unresolved owner retirement but starts no native activity work")
	if mode == "suspend-account-loss":
		Services.cancel_sign_in()
	app.notification(Node.NOTIFICATION_APPLICATION_RESUMED)
	if mode == "suspend-account-loss":
		test._check(activity.sdk.deletes.is_empty() and platform._activity_owner == null,
			"resume never deletes a removed account's activity using another identity")
		test._select("replacement-owner", test._folder())
		test._check(await Services.sign_in() and await NetManager.host_match(), "replacement account hosts independently")
		for index in range(publications, activity.sdk.calls.size() + 2):
			if index < activity.sdk.calls.size():
				activity.sdk.calls[index].completed.emit(true)
		test._check(activity.sdk.deletes.is_empty() and platform._activity_owner == Services.xbox_user()
			and platform._activity_remote == PlatformSession._Remote.PUBLISHED, "old pending retirement cannot delete replacement activity")
	elif mode == "suspend-pending":
		test._check(activity.sdk.deletes.is_empty() and platform._activity_writing,
			"resume waits behind pre-suspend publisher rather than overlapping native writes")
		activity.sdk.calls[0].completed.emit(true)
		test._check(activity.sdk.deletes == [owner] and platform._activity_remote != PlatformSession._Remote.CLEARED,
			"stale publish completion releases writer into same-owner pending retirement")
		activity.sdk.delete_completed.emit(true)
	else:
		test._check(activity.sdk.deletes == [owner] and not Services.is_account_ready()
			and platform._activity_writing and platform._activity_remote != PlatformSession._Remote.CLEARED,
			"resume starts owner-bound deletion despite reload readiness being false, without claiming success")
		if mode == "resume-new-session":
			test._check(await Services.sign_in() and await NetManager.host_match(), "same owner starts a newer session while delete drains")
			Services._party.connection = "newer-session"
			test._check(activity.sdk.calls.size() == publications, "new session waits behind serialized retirement")
		activity.sdk.delete_completed.emit(true)
		if mode == "resume-new-session":
			test._check(activity.sdk.calls.size() == publications + 1 and activity.sdk.calls[publications].connection == "newer-session",
				"retirement finishes before newest session publication, never deletes it afterward")
			activity.sdk.calls[publications].completed.emit(true)
			test._check(platform._activity_remote == PlatformSession._Remote.PUBLISHED
				and activity.sdk.deletes.size() == 1, "newer session's activity survives old retirement")
	if mode in ["suspend", "suspend-pending"]:
		test._check(not platform._activity_writing and platform._activity_remote == PlatformSession._Remote.CLEARED,
			"only confirmed resume deletion records remote activity cleared")
	await _dispose_main(test, app)
	Services._party = null


func _activity_quit(test: Node, mode: String) -> void:
	print("CASE: normal quit drains owner-bound activity inside shared deadline: ", mode)
	await test._reset()
	var activity := await _host_activity(test)
	var owner: Variant = Services.xbox_user()
	_confirm_activity(test, activity)
	activity.sdk.block_delete = true
	var app := _main(test)
	app.request_shutdown()
	test._check(Services.is_shutting_down() and not Services.is_account_ready()
		and activity.sdk.deletes == [owner] and app._quit_pending and app.quit_calls == 0,
		"shutdown revokes gameplay but waits for actual authenticated-owner delete")
	var deadline: int = app._quit_deadline_msec
	if mode == "quit-timeout":
		app._quit_deadline_msec = 0
		app._process(0.0)
		test._check(app.quit_calls == 1, "unresponsive activity deletion cannot exceed normal shutdown drain")
	activity.sdk.delete_completed.emit(mode != "quit-failure")
	await _frames(test)
	test._check(app.quit_calls == 1 and activity.sdk.deletes.size() == 1,
		"activity completion neither duplicates deletion nor quits twice after timeout")
	test._check(NetManager._platform._activity_remote == (
		PlatformSession._Remote.UNKNOWN if mode == "quit-failure" else PlatformSession._Remote.CLEARED),
		"failed retirement remains unresolved; only confirmed deletion is cleared")
	test._check(mode == "quit-timeout" or app._quit_deadline_msec == deadline,
		"activity drain shares existing deadline rather than renewing it")
	await _dispose_main(test, app)
	Services._party = null


func _activity_retiring_replacement(test: Node) -> void:
	print("CASE: departing A deletion completion cannot clear B or strand B publication")
	await test._reset()
	var activity := await _host_activity(test)
	var owner: Variant = Services.xbox_user()
	_confirm_activity(test, activity)
	var publications := activity.sdk.calls.size()
	activity.sdk.block_delete = true
	NetManager.leave_match()
	test._check(activity.sdk.deletes == [owner], "A actual leave requests retirement")
	Services.cancel_sign_in()
	await test.get_tree().process_frame
	test._select("retirement-B", test._folder())
	test._check(await Services.sign_in() and await NetManager.host_match(), "B host queues behind old delete")
	test._check(activity.sdk.calls.size() == publications, "B does not overlap old native retirement")
	activity.sdk.delete_completed.emit(true)
	test._check(activity.sdk.calls.size() == publications + 1 and activity.sdk.calls[publications].owner == Services.xbox_user()
		and NetManager._platform._activity_remote != PlatformSession._Remote.CLEARED,
		"stale A delete completion releases writer but cannot confirm anything for B")
	activity.sdk.calls[publications].completed.emit(true)
	test._check(activity.sdk.deletes == [owner] and NetManager._platform._activity_remote == PlatformSession._Remote.PUBLISHED,
		"B publication converges without a wrong-owner or later stale delete")
	await test._reset()
	Services._party = null
