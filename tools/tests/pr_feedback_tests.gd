extends RefCounted

const Doubles := preload("res://tools/tests/doubles.gd")
const Fixture := preload("res://tools/tests/suspend_fixture.gd")


class ColdSDK extends Doubles.IdentitySDK:
	signal user_changed(user: Variant, kind: String)
	signal initializing()
	var initialized := false
	var init_ok := true

	func is_initialized() -> bool:
		return initialized

	func initialize() -> Dictionary:
		calls.append("initialize")
		initialized = init_ok
		initializing.emit()
		return {"ok": init_ok, "message": "Injected initialization result."}


class DelayedParty extends Doubles.SessionParty:
	signal leave_completed()
	var block_leave := false

	func leave(invalidate_pending: bool = true) -> void:
		if block_leave:
			leaves += 1
			await leave_completed
		else:
			await super.leave(invalidate_pending)


class DelayedChatSDK extends Doubles.ChatSDK:
	signal destroy_completed()
	var block_destroy := true

	func destroy_local_chat_control_async(user: Variant) -> Dictionary:
		calls.append("destroy:" + user.xuid)
		if block_destroy:
			await destroy_completed
		return {"ok": true}


class Friend extends RefCounted:
	var owner: Variant

	func get_xuid() -> String:
		return "friend-" + owner.xuid

	func get_gamertag() -> String:
		return "Friend " + owner.xuid

	func get_display_name() -> String:
		return get_gamertag()


class Group extends RefCounted:
	var owner: Variant


class GroupCall extends RefCounted:
	signal completed(result: Dictionary)
	var group := Group.new()


class SocialSDK extends RefCounted:
	var calls: Array[GroupCall] = []
	var destroyed: Array = []
	var reads: Array = []

	func get_friends_async(user: Variant) -> Signal:
		var call := GroupCall.new()
		call.group.owner = user
		calls.append(call)
		return call.completed

	func destroy_social_group(group: Variant) -> void:
		destroyed.append(group)

	func get_group_users(group: Variant) -> Dictionary:
		reads.append(group)
		var friend := Friend.new()
		friend.owner = group.owner
		return {"ok": true, "data": [friend]}


class Social extends SocialService:
	var sdk := SocialSDK.new()

	func _social() -> Variant:
		return sdk


func run(test: Node) -> void:
	await _cold_identity(test)
	for mode: String in ["A-first", "B-first", "A-failed"]:
		await _social_replacement(test, mode)
	var audio_script: Script = AudioManager.get_script()
	var activity: ActivityService = Services._activity
	AudioManager.set_script(Fixture.Review.QuietAudio)
	for mode: String in ["party", "chat", "back", "repeat", "quit"]:
		await _resume_wait(test, mode)
	Services._activity = activity
	AudioManager.set_script(audio_script)
	PlayerProfile.apply_dict(PlayerProfile.to_dict())


func _frames(test: Node) -> void:
	await test.get_tree().process_frame
	await test.get_tree().process_frame


func _cold_identity(test: Node) -> void:
	OS.set_environment("PF_CUSTOM_ID", "")
	for mode: String in ["default", "playfab", "success", "warm", "failure", "cancel-init", "cancel-ready",
			"before-default", "before-playfab", "before-display"]:
		print("CASE: production fallback initialization and early user-event subscription: ", mode)
		await test._reset()
		var identity := Doubles.PlatformIdentity.new()
		var sdk := ColdSDK.new()
		sdk.initialized = mode == "warm"
		sdk.init_ok = mode != "failure"
		sdk.blocked_stage = mode if mode in ["default", "playfab"] else ""
		identity.sdk = sdk
		Services._identity = identity
		Services.user_events_runtime = sdk
		Services._user_changed_connected = false
		identity.platform_ready.connect(Services._connect_user_changed)
		identity.stage_changed.connect(Services._set_sign_in_stage)
		Services._game_saves.sdk.folder = test._folder()
		if mode == "cancel-init":
			sdk.initializing.connect(Services.cancel_sign_in)
		if mode == "cancel-ready":
			identity.platform_ready.connect(Services.cancel_sign_in)
		var stages := {
			"before-default": "Signing in to Xbox",
			"before-playfab": "Signing in to PlayFab",
			"before-display": "Publishing your gamertag to PlayFab",
		}
		if stages.has(mode):
			identity.stage_changed.connect(func(stage: String) -> void:
				if stage == stages[mode]:
					sdk.user_changed.emit(sdk.user, "removed"))
		var results: Array = []
		test._capture_sign_in(results)
		if mode in ["default", "playfab"]:
			test._check(results.is_empty() and Services._user_changed_connected
				and sdk.user_changed.get_connections().size() == 1 and sdk.calls[0] == "initialize",
				"cold fallback hooks actual Services user-change handler before awaited Xbox/PF acquisition")
			var calls := sdk.calls.duplicate()
			sdk.user_changed.emit(sdk.user, "removed")
			test._check(identity.gdk_user == null and identity.playfab_user == null,
				"native removal during acquisition invalidates identity immediately")
			sdk.released.emit()
			await test._settle(results, 1)
			test._check(results == [false] and sdk.calls == calls and Services._game_saves.sdk.calls == 0,
				"late acquisition completion starts no later SDK stage or save preparation")
		elif stages.has(mode):
			test._check(results == [false] and not sdk.calls.has(mode.trim_prefix("before-"))
				and Services._game_saves.sdk.calls == 0,
				"removal at acquisition stage boundary prevents the next native call")
		elif mode in ["success", "warm"]:
			test._check(results == [true] and Services.is_account_ready()
				and sdk.user_changed.get_connections().size() == 1,
				"cold and already-initialized paths subscribe once and complete readiness")
			test._check(sdk.calls.has("initialize") == (mode == "success"),
				"fallback initializes only an uninitialized runtime")
		else:
			test._check(results == [false] and sdk.calls == ["initialize"]
				and Services._game_saves.sdk.calls == 0, "failed or canceled startup makes no Xbox user call")
			test._check(Services._user_changed_connected == (mode == "cancel-ready"),
				"platform-ready is emitted only after successful still-current initialization")
		if sdk.user_changed.is_connected(Services._on_user_changed):
			sdk.user_changed.disconnect(Services._on_user_changed)
		Services._user_changed_connected = false
		Services.user_events_runtime = null
		await test._reset()
	OS.set_environment("PF_CUSTOM_ID", "A")


func _friends(social: SocialService, user: Variant, results: Array) -> void:
	results.append(await social.friends(user))


func _complete(call: GroupCall, ok: bool = true) -> void:
	call.completed.emit({"ok": ok, "data": call.group if ok else null, "message": "Injected social result."})


func _social_replacement(test: Node, mode: String) -> void:
	print("CASE: production social single-flight ownership across clear: ", mode)
	var social := Social.new()
	var a := Doubles.User.new("social-A")
	var b := Doubles.User.new("social-B")
	var first: Array = []
	var first_waiter: Array = []
	var second: Array = []
	var second_waiter: Array = []
	_friends(social, a, first)
	_friends(social, a, first_waiter)
	test._check(social.sdk.calls.size() == 1 and first.is_empty() and first_waiter.is_empty(),
		"same-generation friends readers share one outstanding native group load")
	social.clear()
	test._check(first_waiter == [[]] and not social._loading, "clear releases old generation waiters and its load guard")
	_friends(social, b, second)
	_friends(social, b, second_waiter)
	test._check(social.sdk.calls.size() == 2 and social._loading and second.is_empty() and second_waiter.is_empty(),
		"B starts immediately while A's SDK call remains unresolved; B readers remain single-flight")
	if mode == "B-first":
		_complete(social.sdk.calls[1])
	_complete(social.sdk.calls[0], mode != "A-failed")
	test._check(first == [[]] and social._owner == b
		and social._loading == (mode != "B-first"), "late A success/failure cannot release B's guard or replace ownership")
	if mode != "B-first":
		test._check(second.is_empty() and second_waiter.is_empty() and social.sdk.reads.is_empty(),
			"stale A completion cannot wake B waiters or expose an old native group")
		_complete(social.sdk.calls[1])
	test._check(second.size() == 1 and second_waiter == second and second[0][0].xuid == "friend-social-B"
		and social._friends_group == social.sdk.calls[1].group and not social._loading,
		"B readers receive only the current account's actual group data")
	test._check(social.sdk.destroyed == ([] if mode == "A-failed" else [social.sdk.calls[0].group]),
		"only stale A's successfully created group is destroyed")
	var third: Array = []
	_friends(social, a, third)
	test._check(social.sdk.calls.size() == 3 and social.sdk.destroyed.has(social.sdk.calls[1].group),
		"changing owner without explicit clear cannot reuse another account's group")
	_complete(social.sdk.calls[2], false)
	test._check(third == [[]] and not social._loading and social._friends_group == null,
		"current failure releases guard and reports no cached previous-account friends")
	_friends(social, a, third)
	test._check(social.sdk.calls.size() == 4, "failed current load remains retryable")
	_complete(social.sdk.calls[3])
	test._check(third.size() == 2 and third[1][0].xuid == "friend-social-A", "Retry returns newly loaded current group")
	social.clear()


func _press(test: Node, list: NRMenuList, text: String) -> void:
	for row: Control in list.rows():
		if row is NRButton and row.text == text:
			row.pressed.emit()
			return
	test._check(false, "missing actual acquisition action: " + text)


func _resume_wait(test: Node, mode: String) -> void:
	print("CASE: actual resume acquisition waits for delayed Party/chat teardown: ", mode)
	await test._reset()
	var fixture := Fixture.new()
	test._check(await fixture.open(test, test._folder()), "resume-wait fixture ready")
	var chat := Doubles.Chat.new()
	var sdk := DelayedChatSDK.new()
	sdk.block_destroy = mode != "party"
	chat.sdk = sdk
	await chat.ensure_control(Services.playfab_user(), {})
	var party := DelayedParty.new(chat)
	party.block_leave = mode == "party"
	Services._party = party
	Services._chat = chat
	var before := [party.leaves, sdk.calls.duplicate(), fixture.store.sdk.calls]
	fixture.app.notification(Node.NOTIFICATION_APPLICATION_PAUSED)
	test._check([party.leaves, sdk.calls, fixture.store.sdk.calls] == before,
		"synchronous Suspend starts no native teardown or acquisition work")
	fixture.app.notification(Node.NOTIFICATION_APPLICATION_RESUMED)
	await _frames(test)
	var acquire: Variant = ScreenManager.current_screen()
	test._check(acquire != null and acquire.scene_file_path == ScreenManager.ACQUIRE_USER,
		"resume exposes acquisition rather than blocking the main notification on teardown")
	acquire._acquire_user()
	test._check(not Services.is_account_ready() and Services.is_signing_in()
		and acquire._state == acquire.State.SIGNING_IN
		and acquire._detail_label.text == "Finishing the previous session"
		and fixture.store.sdk.calls == before[2], "readiness cannot overtake previous-session cleanup; stage is explicit")
	test._check(not NetManager.start_offline() and not await NetManager.host_match(),
		"existing gameplay safety gates remain closed during cleanup")
	acquire._stage_started_msec = Time.get_ticks_msec() - 26000
	acquire._process(0.0)
	test._check(acquire._stalled and acquire._menu_list.visible,
		"stalled teardown exposes existing Back/Quit actions rather than an endless dead spinner")
	if mode == "back":
		_press(test, acquire._menu_list, "Back")
		await _frames(test)
		test._check(not Services.is_signing_in() and not Services.is_account_ready()
			and NetManager.is_account_teardown_pending(), "Back cancels readiness wait without bypassing or duplicating native teardown")
	elif mode == "repeat":
		fixture.app.notification(Node.NOTIFICATION_APPLICATION_PAUSED)
		fixture.app.notification(Node.NOTIFICATION_APPLICATION_RESUMED)
		await _frames(test)
		acquire = ScreenManager.current_screen()
		acquire._acquire_user()
		test._check(Services.is_signing_in() and not Services.is_account_ready()
			and sdk.calls.count("destroy:suspend-fixture") == 1,
			"repeated suspend/resume replaces acquisition generation without duplicating old cleanup")
	elif mode == "quit":
		_press(test, acquire._menu_list, "Quit")
		var dialog: Variant = ScreenManager.current_screen()
		dialog._ok_button.pressed.emit()
		await _frames(test)
		test._check(fixture.app._quit_pending and fixture.app.quit_calls == 0 and not chat.has_control()
			and NetManager.is_account_teardown_pending(), "Quit drains old native destroy even though control handle is already cleared")
		fixture.app._quit_deadline_msec = 0
		fixture.app._process(0.0)
		test._check(fixture.app.quit_calls == 1, "existing shared deadline still exits a hung cleanup")
	party.block_leave = false
	party.leave_completed.emit()
	sdk.block_destroy = false
	sdk.destroy_completed.emit()
	await _frames(test)
	if mode == "back":
		test._check(not Services.is_account_ready() and fixture.store.sdk.calls == before[2],
			"late teardown cannot finish abandoned acquisition or start new save setup")
		acquire = ScreenManager.current_screen()
		acquire._acquire_user()
	if mode == "quit":
		test._check(fixture.app.quit_calls == 1 and not Services.is_account_ready(), "late cleanup cannot repeat quit or publish readiness")
	else:
		test._check(Services.is_account_ready() and not NetManager.is_account_teardown_pending()
			and fixture.store.sdk.calls == before[2] + 1, "only completed cleanup permits one full save reacquisition")
		acquire._hand_off()
		test._check(NetManager.start_offline(), "first Practice request after actual handoff succeeds without previous-session error")
	ScreenManager.clear()
	fixture.app.free()
	ScreenManager.set_container(test)
	await test._reset()
	Services._party = null
	Services._chat = null
