extends RefCounted

const Doubles := preload("res://tools/tests/doubles.gd")
const PregameDoubles := preload("res://tools/tests/pregame_service_doubles.gd")
const GAMEPLAY := preload("res://scenes/ui/screens/gameplay_screen.tscn")
const ROSTER_ROW := preload("res://scenes/ui/elements/nr_roster_row.tscn")
const ROSTER_OVERLAY := preload("res://scenes/ui/elements/nr_roster_overlay.tscn")


class IndicatorAssets extends "res://tools/tests/assets.gd":
	func texture(key: String) -> Texture2D:
		var result := GradientTexture2D.new()
		result.resource_name = key
		return result


class ChatSDK extends Doubles.ChatSDK:
	signal permissions_released()
	var permissions: Dictionary = {}
	var audio_mutes: Dictionary = {}
	var text_mutes: Dictionary = {}
	var hold_permissions := false
	var local_indicator_user: Variant = null
	var remote_indicator_user: Variant = null

	func get_local_chat_indicator(user: Variant = null) -> int:
		local_indicator_user = user
		return super.get_local_chat_indicator(user)

	func get_chat_indicator(entity_key: Dictionary, user: Variant = null) -> int:
		remote_indicator_user = user
		return super.get_chat_indicator(entity_key, user)

	func set_chat_permissions_async(entity_key: Dictionary, value: int) -> Dictionary:
		var result := await super.set_chat_permissions_async(entity_key, value)
		if result.ok:
			permissions[entity_key.id] = value
		if hold_permissions:
			await permissions_released
		return result

	func set_audio_muted_async(entity_key: Dictionary, muted: bool) -> Dictionary:
		var result := await super.set_audio_muted_async(entity_key, muted)
		if result.ok:
			audio_mutes[entity_key.id] = muted
		return result

	func set_text_muted_async(entity_key: Dictionary, muted: bool) -> Dictionary:
		var result := await super.set_text_muted_async(entity_key, muted)
		if result.ok:
			text_mutes[entity_key.id] = muted
		return result


class PrivacySDK extends RefCounted:
	signal released()
	var blocked := false
	var voice: Dictionary = {}
	var text: Dictionary = {}
	var responses: Dictionary = {}
	var muted := PackedStringArray()
	var avoided := PackedStringArray()
	var calls: Array[String] = []

	func get_mute_list_async(_user: Variant) -> Dictionary:
		return {"ok": true, "data": muted}

	func get_avoid_list_async(_user: Variant) -> Dictionary:
		return {"ok": true, "data": avoided}

	func batch_check_permission_async(_user: Variant, permission: String, xuids: PackedStringArray) -> Variant:
		calls.append(permission)
		if blocked:
			await released
		if responses.has(permission):
			return responses[permission]
		var rows: Array = []
		var answers := voice if permission == PrivacyService.PERMISSION_VOICE else text
		for xuid in xuids:
			rows.append({"target_xuid": xuid, "permission": permission,
				"allowed": bool(answers.get(xuid, false))})
		return {"ok": true, "data": rows}


class Privacy extends PrivacyService:
	var sdk := PrivacySDK.new()

	func _gdk_ready() -> Variant:
		return {"privacy": sdk}


class PrivilegeSDK extends RefCounted:
	var granted := false
	var calls: Array[String] = []

	func check_privilege_async(_user: Variant, privilege: int) -> Dictionary:
		calls.append("check:%d" % privilege)
		return {"ok": true, "data": {"has_privilege": granted, "deny_reason": "restricted",
			"needs_user_issue_resolution": not granted}}

	func resolve_privilege_with_ui_async(_user: Variant, privilege: int) -> Dictionary:
		calls.append("resolve:%d" % privilege)
		granted = true
		return {"ok": true}


class Privileges extends PrivilegeService:
	var sdk := PrivilegeSDK.new()

	func _gdk_ready() -> Variant:
		return {"users": sdk}


class Gameplay extends "res://scripts/ui/screens/gameplay_screen.gd":
	var text_opens := 0

	func _ready() -> void:
		_account_generation = Services.account_generation()
		set_process(false)

	func _open_chat() -> void:
		text_opens += 1


func run(test: Node) -> void:
	_device_defaults(test)
	await _privacy_answers(test)
	await _pending_voice_policy(test)
	await _roster_privacy(test)
	print("CASE: gameplay V / D-pad Up toggles voice without opening typed chat or a menu")
	await test._reset()
	test._select("voice-shortcut", test._folder())
	test._check(await Services.sign_in(), "voice shortcut account ready")
	var old_chat: ChatService = Services._chat
	var old_party: PartyService = Services._party
	var chat := Doubles.Chat.new()
	var sdk := ChatSDK.new()
	chat.sdk = sdk
	var party := Doubles.SessionParty.new(chat)
	party._network = Doubles.Network.new()
	Services._chat = chat
	Services._party = party
	NetManager._session_account_generation = Services.account_generation()
	NetManager._platform._chat_allowed = true
	await chat.ensure_control(Services.playfab_user(), {})
	var local_key: Dictionary = Services.playfab_user().entity_key
	var remote := {"id": "voice-remote", "type": "title_player_account"}
	sdk.add_remote_control(remote)
	await chat.set_peer_restrictions(remote, true, true)
	test._check(chat.chat_indicator_for(local_key) == ChatService.ChatIndicator.MUTED
		and sdk.permissions[remote.id] == 6, "voice starts muted with receive audio/text only")

	var screen := GAMEPLAY.instantiate()
	screen.set_script(Gameplay)
	test.add_child(screen)
	var keyboard := InputEventKey.new()
	keyboard.keycode = KEY_V
	keyboard.pressed = true
	var gamepad := InputEventJoypadButton.new()
	gamepad.button_index = JOY_BUTTON_DPAD_UP
	gamepad.pressed = true
	test._check(keyboard.is_action_pressed("toggle_voice_mute")
		and gamepad.is_action_pressed("toggle_voice_mute"), "shipped V / D-pad Up bindings")
	for event in [keyboard, gamepad]:
		screen._unhandled_input(event)
		test._check(not chat.is_self_muted() and sdk.permissions[remote.id] == 7
			and chat.chat_indicator_for(local_key) == ChatService.ChatIndicator.AVAILABLE,
			"shortcut unmutes the actual service and grants SendAudio")
		test._check(screen.text_opens == 0 and screen._chat_entry == null,
			"voice shortcut does not open a dialog")
		screen._unhandled_input(event)
		test._check(chat.is_self_muted() and sdk.permissions[remote.id] == 6,
			"second press remutes without changing ReceiveText")

	keyboard.echo = true
	screen._unhandled_input(keyboard)
	test._check(chat.is_self_muted(), "held keyboard key does not toggle repeatedly")
	keyboard.echo = false
	screen.is_active = false
	screen._unhandled_input(keyboard)
	test._check(chat.is_self_muted(), "covered gameplay does not toggle voice")
	screen.is_active = true
	screen._chat_entry = NRChatEntry.new()
	screen._unhandled_input(keyboard)
	screen._unhandled_input(gamepad)
	test._check(chat.is_self_muted(), "text entry cannot leak typing or navigation into voice")
	screen._chat_entry.free()
	screen._chat_entry = null

	await chat.set_peer_restrictions(remote, false, true)
	screen._unhandled_input(keyboard)
	test._check(not chat.is_self_muted() and sdk.permissions[remote.id] == 4,
		"unmuting cannot lift a platform voice restriction")
	await chat.set_self_muted(true)
	chat.set_chat_allowed(false)
	NetManager._platform._chat_allowed = false
	screen._unhandled_input(keyboard)
	test._check(chat.is_self_muted(), "communications denial cannot be unmuted")
	chat.set_chat_allowed(true)
	NetManager._platform._chat_allowed = true
	party._network = null
	screen._unhandled_input(keyboard)
	test._check(chat.is_self_muted(), "no Party network means no self-unmute")
	party._network = Doubles.Network.new()
	screen._account_generation -= 1
	screen._unhandled_input(keyboard)
	test._check(chat.is_self_muted(), "stale account screen cannot unmute")
	screen._account_generation = Services.account_generation()

	keyboard.keycode = KEY_T
	gamepad.button_index = JOY_BUTTON_Y
	for event in [keyboard, gamepad]:
		test._check(event.is_action_pressed("open_voice_chat"), "shipped typed-chat binding unchanged")
		screen._unhandled_input(event)
	test._check(screen.text_opens == 2 and chat.is_self_muted(),
		"T / Y still opens typed chat without unmuting the microphone")
	await _speaking_indicators(test, chat, sdk, party, screen, remote)
	screen.free()
	await chat.destroy_control()
	party._network = null
	NetManager._session_account_generation = -1
	Services._chat = old_chat
	Services._party = old_party
	await test._reset()


func _privacy_answers(test: Node) -> void:
	print("CASE: XR015 friends-only denies nonfriends without coupling voice mute to text")
	var privacy := Privacy.new()
	var user := Doubles.User.new("privacy-local")
	privacy.sdk.voice = {"friend": true, "nonfriend": false, "muted": false, "avoided": true}
	privacy.sdk.text = {"friend": true, "nonfriend": false, "muted": true, "avoided": true}
	privacy.sdk.muted = PackedStringArray(["muted"])
	privacy.sdk.avoided = PackedStringArray(["avoided"])
	var verdicts := await privacy.evaluate(user, PackedStringArray(["friend", "nonfriend", "muted", "avoided"]))
	test._check(verdicts.friend.voice and verdicts.friend.text
		and not verdicts.nonfriend.voice and not verdicts.nonfriend.text,
		"friends-only platform verdicts admit friends and reject nonfriends")
	test._check(not verdicts.muted.voice and verdicts.muted.text
		and not verdicts.avoided.voice and not verdicts.avoided.text,
		"voice mute preserves allowed text; avoid blocks both channels")
	test._check(not privacy.verdict_for("unknown").voice and not privacy.verdict_for("").voice,
		"uncached and empty identities cannot authorize voice")

	var voice := PrivacyService.PERMISSION_VOICE
	var cases: Array = [
		null,
		{"ok": false, "code": "privacy_batch_check_start_failed", "message": "Simulated service failure."},
		{"ok": true, "data": {}},
		{"ok": true, "data": []},
		{"ok": true, "data": [null]},
		{"ok": true, "data": [{"target_xuid": "friend", "permission": voice}]},
		{"ok": true, "data": [{"target_xuid": "friend", "permission": voice, "allowed": "false"}]},
		{"ok": true, "data": [{"permission": voice, "allowed": true}]},
		{"ok": true, "data": [{"target_xuid": "stranger", "permission": voice, "allowed": true}]},
		{"ok": true, "data": [{"target_xuid": "friend", "permission": PrivacyService.PERMISSION_TEXT, "allowed": true}]},
		{"ok": true, "data": [
			{"target_xuid": "friend", "permission": voice, "allowed": true},
			{"target_xuid": "friend", "permission": voice, "allowed": false}]},
	]
	for response: Variant in cases:
		privacy.clear_cache()
		privacy.sdk.responses[voice] = response
		verdicts = await privacy.evaluate(user, PackedStringArray(["friend"]))
		test._check(not verdicts.friend.voice and verdicts.friend.text and verdicts.friend.forced,
			"failed, incomplete or malformed voice answer grants no audio but preserves allowed text")
		privacy.sdk.responses.clear()
		verdicts = await privacy.evaluate(user, PackedStringArray(["friend"]))
		test._check(verdicts.friend.voice and verdicts.friend.text,
			"voice query failure is not cached as a permanent denial")

	privacy.clear_cache()
	privacy.sdk.blocked = true
	var results: Array = []
	_capture_privacy(privacy, user, results)
	privacy.clear_cache()
	privacy.sdk.blocked = false
	privacy.sdk.released.emit()
	test._check(results == [{}] and not privacy.verdict_for("friend").voice,
		"late platform answer cannot refill an invalidated privacy cache")

	var privileges := Privileges.new()
	var verdict := await privileges.ensure(user, PrivilegeService.COMMUNICATIONS)
	test._check(verdict.granted and privileges.sdk.calls == ["check:252", "resolve:252", "check:252"],
		"communications denial invokes the platform resolution UI and rechecks the privilege")


func _capture_privacy(privacy: Privacy, user: Variant, results: Array) -> void:
	results.append(await privacy.evaluate(user, PackedStringArray(["friend"])))


func _pending_voice_policy(test: Node) -> void:
	print("CASE: XR015 pending, revoked and removed relationships never grant Party audio")
	var chat := Doubles.Chat.new()
	var sdk := ChatSDK.new()
	chat.sdk = sdk
	await chat.ensure_control(Doubles.User.new("policy-local"), {})
	var first := {"id": "policy-first", "type": "title_player_account"}
	var second := {"id": "policy-second", "type": "title_player_account"}
	for key: Dictionary in [first, second]:
		sdk.add_remote_control(key)
		await chat._on_chat_control_added(key, sdk.get_chat_control(key))
		test._check(sdk.permissions[key.id] == 0 and sdk.audio_mutes[key.id] and sdk.text_mutes[key.id],
			"chat-control arrival before a verdict is muted with no transport permissions")
	await chat.set_self_muted(false)
	test._check(sdk.permissions[first.id] == 0 and sdk.permissions[second.id] == 0,
		"self-unmute cannot authorize unknown relationships")
	await chat.set_peer_restrictions(first, false, true)
	await chat.set_peer_muted(first, false)
	test._check(sdk.permissions[first.id] == 4 and sdk.audio_mutes[first.id] and not sdk.text_mutes[first.id],
		"platform voice denial survives local unmute without removing ReceiveText")
	await chat.set_peer_restrictions(first, true, true)
	await chat.set_peer_restrictions(second, true, false)
	test._check(sdk.permissions[first.id] == 7 and sdk.permissions[second.id] == 3,
		"each channel opens only with its own affirmative verdict")
	sdk.hold_permissions = true
	chat.invalidate_peer_policy()
	test._check(sdk.permissions[first.id] == 0 and sdk.permissions[second.id] == 0
		and not chat.can_exchange_voice(first) and not chat.can_exchange_text(first),
		"invalidation closes every native relationship before any completion is delivered")
	sdk.hold_permissions = false
	sdk.permissions_released.emit()
	await chat.set_peer_restrictions(first, true, true)
	await chat.set_peer_restrictions(second, true, true)
	chat.retain_peers([first])
	test._check(sdk.permissions[first.id] == 7 and sdk.permissions[second.id] == 0,
		"roster removal revokes lingering control audio without silencing retained peers")
	chat.invalidate_session()
	test._check(sdk.permissions[first.id] == 0, "session invalidation revokes retained control audio")
	await chat.destroy_control()

	chat = Doubles.Chat.new()
	sdk = ChatSDK.new()
	chat.sdk = sdk
	await chat.set_peer_restrictions(first, false, true)
	await chat.ensure_control(Doubles.User.new("late-control"), {})
	sdk.add_remote_control(first)
	await chat._on_chat_control_added(first, sdk.get_chat_control(first))
	test._check(sdk.permissions[first.id] == 4 and sdk.audio_mutes[first.id],
		"verdict arriving before a chat control is enforced when the control appears")
	await chat.destroy_control()


func _roster_privacy(test: Node) -> void:
	print("CASE: XR015 actual roster policy restricts every remote, including third-party-hosted sessions")
	await test._reset()
	test._select("privacy-roster", test._folder())
	test._check(await Services.sign_in(), "privacy roster account ready")
	var old_chat: ChatService = Services._chat
	var old_party: PartyService = Services._party
	var old_privacy: PrivacyService = Services._privacy
	var chat := Doubles.Chat.new()
	var sdk := ChatSDK.new()
	chat.sdk = sdk
	var party := Doubles.SessionParty.new(chat)
	party._network = Doubles.Network.new()
	var peer := PregameDoubles.Peer.new()
	party._peer = peer
	var privacy := Privacy.new()
	Services._chat = chat
	Services._party = party
	Services._privacy = privacy
	NetManager._is_offline = false
	NetManager._platform._chat_allowed = true
	await chat.ensure_control(Services.playfab_user(), {})
	await chat.set_self_muted(false)
	var keys: Array[Dictionary] = []
	for id: int in [2, 3, 4]:
		var key := {"id": "privacy-peer-%d" % id, "type": "title_player_account"}
		keys.append(key)
		peer.keys[id] = key
		sdk.add_remote_control(key)
		await chat._on_chat_control_added(key, sdk.get_chat_control(key))
		var state := PlayerState.new()
		state.peer_id = id
		state.entity_id = key.id
		state.xbox_user_id = "friend" if id == 2 else ("nonfriend" if id == 3 else "")
		NetManager.players[id] = state
	privacy.sdk.voice = {"friend": true}
	privacy.sdk.text = {"friend": true}
	privacy.sdk.blocked = true
	NetManager._platform.apply_chat_restrictions()
	test._check(sdk.permissions[keys[0].id] == 0 and sdk.permissions[keys[1].id] == 0,
		"roster awaiting Xbox privacy grants no Party audio")
	privacy.sdk.blocked = false
	privacy.sdk.released.emit()
	test._check(sdk.permissions[keys[0].id] == 7 and sdk.permissions[keys[1].id] == 0
		and sdk.permissions[keys[2].id] == 0,
		"production roster mapping admits a friend, denies a nonfriend and denies an absent XUID")
	test._check(not NetManager._platform.can_mute_peer(3)
		and NetManager._platform.is_peer_voice_restricted(3),
		"restricted nonfriend cannot be locally unmuted")
	NetManager.players.erase(2)
	await NetManager._platform.apply_chat_restrictions()
	test._check(sdk.permissions[keys[0].id] == 0,
		"production roster removal closes an already-authorized remote control")
	await chat.set_peer_restrictions(keys[1], true, true)
	Services._shutting_down = true
	await NetManager._platform.apply_chat_restrictions()
	test._check(sdk.permissions[keys[1].id] == 0,
		"an unavailable account cannot become an unchecked privacy grant during teardown")
	Services._shutting_down = false
	await chat.destroy_control()
	party._network = null
	party._peer = null
	NetManager.players.clear()
	NetManager._is_offline = true
	Services._chat = old_chat
	Services._party = old_party
	Services._privacy = old_privacy
	await test._reset()


func _speaking_indicators(test: Node, chat: Doubles.Chat, sdk: ChatSDK,
		party: Doubles.SessionParty, screen: Gameplay, remote: Dictionary) -> void:
	print("CASE: actual Party activity repaints local and remote squawkers without privacy work")
	await chat.set_peer_restrictions(remote, true, true)
	await chat.set_self_muted(false)
	var local := PlayerState.new()
	local.peer_id = 1
	local.entity_id = Services.playfab_user().entity_key.id
	local.display_name = "Local voice"
	var other := PlayerState.new()
	other.peer_id = 2
	other.entity_id = remote.id
	other.display_name = "Remote voice"
	NetManager.players[1] = local
	NetManager.players[2] = other
	var peer := PregameDoubles.Peer.new()
	peer.keys = {1: Services.playfab_user().entity_key, 2: remote}
	party._peer = peer
	NetManager._peer = peer
	NetManager._is_offline = false
	NetManager._chat_indicator_elapsed = 0.0
	NetManager._last_chat_indicators.clear()
	var assets_script: Script = Assets.get_script()
	Assets.set_script(IndicatorAssets)
	var row: NRRosterRow = ROSTER_ROW.instantiate()
	test.add_child(row)
	screen._roster = ROSTER_OVERLAY.instantiate()
	screen._roster_anchor.add_child(screen._roster)
	var changes: Array[int] = [0]
	var policy_changes: Array[int] = [0]
	var repaint := func() -> void:
		changes[0] += 1
		row.set_state(local)
	var policy_changed := func() -> void: policy_changes[0] += 1
	NetManager.chat_indicators_changed.connect(repaint)
	NetManager.chat_indicators_changed.connect(screen._refresh_roster)
	chat.chat_changed.connect(policy_changed)
	var policy_generation: int = chat._peer_policy_generation
	var permissions := sdk.permissions.duplicate()

	NetManager._process(0.1)
	test._check(changes[0] == 1 and row._mic.texture.resource_name == "Microphone_Available",
		"first poll paints silent lobby microphone")
	sdk.local_indicator = 1
	sdk.remote_indicators[remote.id] = 1
	var reads: int = sdk.indicator_reads
	NetManager._process(0.05)
	test._check(changes[0] == 1 and sdk.indicator_reads == reads,
		"voice activity reads are throttled to 100 ms")
	NetManager._process(0.05)
	test._check(changes[0] == 2 and row._mic.texture.resource_name == "Microphone_Talking",
		"local Party capture lights the actual lobby squawker without roster changes")
	test._check(screen._roster._rows.get_child_count() == 2,
		"both gameplay roster entries are exercised")
	for entry: Control in screen._roster._rows.get_children():
		var mic: TextureRect = entry.get_node("Mic")
		test._check(mic.texture.resource_name == "Microphone_Talking",
			"gameplay squawkers light for local and remote Party speech")
	NetManager._process(0.1)
	test._check(changes[0] == 2, "unchanged activity does not rebuild either roster")
	sdk.local_indicator = 0
	sdk.remote_indicators[remote.id] = 0
	NetManager._process(0.1)
	test._check(changes[0] == 3 and row._mic.texture.resource_name == "Microphone_Available",
		"silence clears the lobby squawker")
	for entry: Control in screen._roster._rows.get_children():
		var mic: TextureRect = entry.get_node("Mic")
		test._check(mic.texture.resource_name == "Microphone_Available",
			"silence clears gameplay squawkers")
	test._check(policy_changes[0] == 0 and chat._peer_policy_generation == policy_generation
		and sdk.permissions == permissions, "speech repaint does not emit chat policy changes or write permissions")
	test._check(sdk.local_indicator_user == Services.playfab_user()
		and sdk.remote_indicator_user == Services.playfab_user(),
		"local and remote activity are queried for the owning local user")
	sdk.remote_indicators[remote.id] = 1
	test._check(chat.chat_indicator_for(Services.playfab_user().entity_key) == ChatService.ChatIndicator.AVAILABLE
		and chat.chat_indicator_for(remote) == ChatService.ChatIndicator.TALKING,
		"remote speech is independent of local capture")
	sdk.local_indicator = 1
	sdk.remote_indicators[remote.id] = 0
	test._check(chat.chat_indicator_for(Services.playfab_user().entity_key) == ChatService.ChatIndicator.TALKING
		and chat.chat_indicator_for(remote) == ChatService.ChatIndicator.AVAILABLE,
		"local capture is independent of remote speech")

	sdk.local_indicator = 1
	sdk.remote_indicators[remote.id] = 1
	await chat.set_self_muted(true)
	test._check(chat.chat_indicator_for(Services.playfab_user().entity_key) == ChatService.ChatIndicator.MUTED,
		"title self-mute wins over native capture activity")
	await chat.set_self_muted(false)
	sdk.local_indicator = 2
	test._check(chat.chat_indicator_for(Services.playfab_user().entity_key) == ChatService.ChatIndicator.MUTED,
		"native local input mute is not shown as talking")
	await chat.set_peer_muted(remote, true)
	test._check(chat.chat_indicator_for(remote) == ChatService.ChatIndicator.MUTED,
		"player mute wins over remote native activity")
	await chat.set_peer_muted(remote, false)
	await chat.set_peer_restrictions(remote, false, true)
	test._check(chat.chat_indicator_for(remote) == ChatService.ChatIndicator.MUTED,
		"platform voice restriction wins over remote native activity")
	await chat.set_peer_restrictions(remote, true, true)
	for indicator: int in [2, 3, 5]:
		sdk.remote_indicators[remote.id] = indicator
		test._check(chat.chat_indicator_for(remote) == ChatService.ChatIndicator.MUTED,
			"Party incoming-disabled and local/remote mute indicators stay muted")
	sdk.controls.erase(sdk.get_chat_control(remote))
	test._check(chat.chat_indicator_for(remote) == ChatService.ChatIndicator.NONE,
		"removed chat control never keeps a talking icon")
	chat.set_chat_allowed(false)
	test._check(chat.chat_indicator_for(Services.playfab_user().entity_key) == ChatService.ChatIndicator.NONE,
		"communications denial hides even an active capture indicator")
	chat.set_chat_allowed(true)
	var before: int = sdk.indicator_reads
	NetManager._session_account_generation -= 1
	NetManager._process(0.1)
	test._check(sdk.indicator_reads == before, "stale session account does not query native voice")
	NetManager._session_account_generation = Services.account_generation()
	NetManager._is_offline = true
	NetManager._process(0.1)
	test._check(sdk.indicator_reads == before and NetManager._last_chat_indicators.is_empty(),
		"Practice does not query native voice or keep a cached squawker")
	NetManager._is_offline = false
	NetManager._detach_peer()
	test._check(NetManager._last_chat_indicators.is_empty()
		and is_zero_approx(NetManager._chat_indicator_elapsed), "session detach clears squawker polling state")
	NetManager._process(0.1)
	test._check(sdk.indicator_reads == before, "detached session does not query voice")

	NetManager.chat_indicators_changed.disconnect(repaint)
	NetManager.chat_indicators_changed.disconnect(screen._refresh_roster)
	chat.chat_changed.disconnect(policy_changed)
	row.free()
	Assets.set_script(assets_script)
	party._peer = null
	NetManager.players.clear()


func _device_defaults(test: Node) -> void:
	print("CASE: shared Party addon selects audio defaults from the title's runtime platform")
	var chat := ChatService.new()
	var party := PregameDoubles.Party.new(chat)
	for console: bool in [false, true]:
		party.fake_console = console
		for allowed: bool in [false, true]:
			chat.set_chat_allowed(allowed)
			for capacity: int in [0, 4, 8]:
				var cfg: PregameDoubles.Config = party._make_party_config(capacity, "VOICE")
				test._check(cfg.audio_device_default_mode == (2 if console else 1),
					"console uses PlatformUserDefault; PC uses SystemDefault, never compile-target Auto")
				test._check(cfg.enable_voice_chat == allowed and cfg.enable_text_chat == allowed,
					"device selection does not bypass communications privilege")
				test._check(cfg.invitation_id == "VOICE" and cfg.max_players == capacity
					and cfg.direct_peer_connectivity == 0
					and not cfg.enable_transcription and not cfg.enable_translation,
					"host/join capacities and the remaining Party configuration are preserved")
