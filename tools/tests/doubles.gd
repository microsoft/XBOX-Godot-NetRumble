extends RefCounted


class User extends RefCounted:
	var gamertag := "Test account"
	var has_local_user_handle := true
	var signed_in := true
	var xuid := ""
	var entity_key: Dictionary

	func _init(id: String) -> void:
		xuid = id
		entity_key = {"id": id, "type": "title_player_account"}


class Identity extends IdentityService:
	signal released()
	var target: User
	var calls := 0
	var blocked := false
	var authenticate := true
	var xbox_available := true

	func sign_in() -> bool:
		calls += 1
		var generation := _generation
		if blocked:
			await released
		if not _current(generation):
			return false
		if not authenticate:
			last_error = "Fake authentication refused."
			return false
		playfab_user = User.new(target.xuid)
		playfab_user.has_local_user_handle = false
		gdk_user = target if xbox_available else null
		xbox_user_id = target.xuid
		entity_id = target.xuid
		display_name = "Account " + target.xuid
		return true


class XboxResultDouble extends RefCounted:
	var fields: Dictionary

	func _init(value: Dictionary) -> void:
		fields = value

	func is_ok() -> bool:
		return fields.ok

	func get_data() -> Variant:
		return fields.data

	func get_hresult() -> int:
		return fields.hresult

	func get_code() -> String:
		return fields.code


class SavesSDK extends RefCounted:
	signal released()
	signal folder_completed(result: Variant)
	var calls := 0
	var blocked := false
	var folder_ok := true
	var null_result := false
	var native_result := true
	var response: Variant = null
	var code := "game_save_folder_failed"
	var hresult := -2147467259
	var folder: Variant = ""
	var owners: Array = []

	func get_folder_async(user: Variant) -> Variant:
		calls += 1
		owners.append(user)
		if blocked:
			released.connect(_complete_folder, CONNECT_ONE_SHOT)
			return folder_completed
		return _folder_result()

	func _complete_folder() -> void:
		folder_completed.emit(_folder_result())

	func _folder_result() -> Variant:
		if null_result:
			return null
		if response != null:
			return response
		var value := {"ok": folder_ok, "data": {"path": folder},
			"code": "ok" if folder_ok else code, "hresult": 0 if folder_ok else hresult}
		return XboxResultDouble.new(value) if native_result else value


class Saves extends GameSaveService:
	var sdk := SavesSDK.new()
	var unavailable := false
	var reads: Array[String] = []
	var write_attempts: Array[String] = []
	var on_read: Callable
	var failed_files: Array[String] = []

	func _gdk() -> Variant:
		return null if unavailable else {"game_save": sdk}

	func read(user: Variant, generation: int, file_name: String) -> Dictionary:
		reads.append(file_name)
		if on_read.is_valid():
			on_read.call(file_name)
		return super.read(user, generation, file_name)

	func _write_bytes(path: String, bytes: PackedByteArray) -> Error:
		if path.get_file().trim_suffix(SLOT_SUFFIX) in failed_files:
			return ERR_CANT_OPEN
		return super._write_bytes(path, bytes)

	func write_now(user: Variant, generation: int, file_name: String, data: Variant) -> Dictionary:
		write_attempts.append(file_name)
		return super.write_now(user, generation, file_name, data)


class Achievements extends AchievementService:
	var reports: Array[Dictionary] = []

	func update_progress(user: Variant, achievement_id: String, percent: int) -> void:
		reports.append({"owner": user, "id": achievement_id, "percent": percent})


class IdentitySDK extends RefCounted:
	signal released()
	var blocked_stage := ""
	var calls: Array[String] = []
	var user := User.new("native-identity")
	var default_ok := true
	var users: Variant:
		get: return self
	var accounts: Variant:
		get: return self

	func is_initialized() -> bool:
		return true

	func get_primary_user() -> Variant:
		calls.append("primary")
		return null

	func _step(stage: String) -> void:
		calls.append(stage)
		if blocked_stage == stage:
			await released

	func add_default_user_async() -> Dictionary:
		await _step("default")
		return {"ok": default_ok, "data": user}

	func add_user_with_ui_async() -> Dictionary:
		await _step("ui")
		return {"ok": true, "data": user}

	func sign_in_with_xuser_async(_user: Variant) -> Dictionary:
		await _step("playfab")
		return {"ok": true, "data": user}

	func set_display_name_async(_user: Variant, _data: Dictionary) -> Dictionary:
		await _step("display")
		return {"ok": true}


class PlatformIdentity extends IdentityService:
	var sdk := IdentitySDK.new()

	func _gdk() -> Variant:
		return sdk

	func _playfab() -> Variant:
		return sdk


## A chat control the double holds, keyed as the addon keys it: the local control of the user
## that created it, or a remote control a case seats in the mesh.
class ChatControl extends RefCounted:
	var user: Variant = null
	var entity_key: Dictionary = {}
	var local := false


## PlayFabPartyChat as ChatService uses it. One local control per user that created one,
## found by that user; remote controls only where a case seats them. A call with no local
## control, or naming a key no control in the mesh has, fails as the addon's does.
class ChatSDK extends RefCounted:
	const E_NOT_VALID_STATE := -2147019873
	const E_INVALIDARG := -2147024809
	signal released()
	signal destroy_released()
	signal chat_control_added()
	signal chat_control_removed()
	signal audio_muted_changed(entity_key: Dictionary, muted: bool)
	signal text_message_received()
	var blocked := false
	## Holds a destruction at the SDK boundary until destroy_released, as a native
	## destruction still completing does.
	var hold_destroy := false
	var calls: Array[String] = []
	var controls: Array[ChatControl] = []

	func create_local_chat_control_async(user: Variant, _cfg: Variant) -> Dictionary:
		calls.append("create:" + user.xuid)
		if blocked:
			await released
		var control: ChatControl = get_local_chat_control(user)
		if control == null:
			control = ChatControl.new()
			control.user = user
			control.local = true
			var key: Variant = user.get("entity_key")
			control.entity_key = (key as Dictionary).duplicate() if typeof(key) == TYPE_DICTIONARY else {}
			controls.append(control)
		return {"ok": true, "data": control}

	func destroy_local_chat_control_async(user: Variant) -> Dictionary:
		calls.append("destroy:" + user.xuid)
		if hold_destroy:
			await destroy_released
		var control: ChatControl = get_local_chat_control(user)
		if control != null:
			controls.erase(control)
		return {"ok": true, "data": null}

	func get_local_chat_control(user: Variant) -> ChatControl:
		if user == null:
			return null
		for control: ChatControl in controls:
			if control.local and control.user == user:
				return control
		return null

	func get_chat_control(entity_key: Dictionary) -> ChatControl:
		for control: ChatControl in controls:
			if not control.entity_key.is_empty() \
					and String(control.entity_key.get("id", "")) == String(entity_key.get("id", "")) \
					and String(control.entity_key.get("type", "")) == String(entity_key.get("type", "")):
				return control
		return null

	func get_remote_entity_keys() -> Array:
		var keys: Array = []
		for control: ChatControl in controls:
			if not control.local:
				keys.append(control.entity_key.duplicate())
		return keys

	## Seats a remote player's chat control in the mesh, as the addon surfaces one.
	func add_remote_control(entity_key: Dictionary) -> void:
		if get_chat_control(entity_key) != null:
			return
		var control := ChatControl.new()
		control.entity_key = entity_key.duplicate()
		controls.append(control)

	func set_audio_muted_async(entity_key: Dictionary, muted: bool) -> Dictionary:
		var refused := _refusal("set_audio_muted_async", [entity_key])
		if not refused.is_empty():
			return refused
		audio_muted_changed.emit(entity_key, muted)
		return {"ok": true, "data": null}

	func set_text_muted_async(entity_key: Dictionary, _muted: bool) -> Dictionary:
		var refused := _refusal("set_text_muted_async", [entity_key])
		return refused if not refused.is_empty() else {"ok": true, "data": null}

	func set_chat_permissions_async(entity_key: Dictionary, _permissions: int) -> Dictionary:
		var refused := _refusal("set_chat_permissions_async", [entity_key])
		return refused if not refused.is_empty() else {"ok": true, "data": null}

	func send_text_async(_message: String, target_entity_keys: Array = [], _config: Variant = null) -> Dictionary:
		var refused := _refusal("send_text_async", target_entity_keys)
		return refused if not refused.is_empty() else {"ok": true, "data": null}

	## The addon's refusals, in its order: no local control on a network, then a key naming no
	## control in the mesh.
	func _refusal(method: String, entity_keys: Array) -> Dictionary:
		var local := false
		for control: ChatControl in controls:
			local = local or control.local
		if not local:
			return {"ok": false, "code": "party_peer_not_connected", "hresult": E_NOT_VALID_STATE,
				"message": "PlayFabPartyChat.%s() requires a connected Party network with a local chat control." % method}
		for key_value: Variant in entity_keys:
			var key: Dictionary = key_value as Dictionary if typeof(key_value) == TYPE_DICTIONARY else {}
			if get_chat_control(key) == null:
				return {"ok": false, "code": "party_peer_not_connected", "hresult": E_INVALIDARG,
					"message": "PlayFabPartyChat.%s() unknown entity key %s." % [method, String(key.get("id", ""))]}
		return {}


class Chat extends ChatService:
	var sdk := ChatSDK.new()

	func _chat() -> Variant:
		return sdk


class Network extends RefCounted:
	signal state_changed()
	var local_peer := OfflineMultiplayerPeer.new()
	var descriptor := "test-descriptor"
	var leaves := 0

	func leave_async() -> Dictionary:
		leaves += 1
		return {"ok": true}


class PartySDK extends RefCounted:
	signal released()
	var blocked := false
	var creates := 0
	var network := Network.new()

	func create_and_join_network_async(_user: Variant, _cfg: Variant) -> Dictionary:
		creates += 1
		if blocked:
			await released
		return {"ok": true, "data": network}


class SessionParty extends PartyService:
	signal initialized()
	var block_init := false
	var sdk := PartySDK.new()
	var attachments := 0
	var advertisements := 0
	var leaves := 0

	func _ensure_initialized(_operation: int) -> String:
		if block_init:
			await initialized
		return ""

	func leave(invalidate_pending: bool = true) -> void:
		leaves += 1
		if invalidate_pending:
			cancel_pending_join()
		_network = null

	func _make_party_config(_max_players: int, _invitation: String) -> Variant:
		return {}

	func _playfab() -> Variant:
		return {"party": sdk}

	func _attach_network(network: Variant, _host: bool) -> void:
		attachments += 1
		_network = network
		_peer = OfflineMultiplayerPeer.new()

	func _create_lobby(_user: Variant, _descriptor: String, _max: int, _mode: String, _operation: int) -> String:
		advertisements += 1
		return ""


class Privileges extends PrivilegeService:
	signal released()
	var calls := 0

	func ensure(_user: Variant, _privilege: int) -> Dictionary:
		calls += 1
		await released
		return {"granted": true}


class SocialSDK extends RefCounted:
	signal released()
	var group := RefCounted.new()
	var destroyed: Array = []

	func get_friends_async(_user: Variant) -> Dictionary:
		await released
		return {"ok": true, "data": group}

	func destroy_social_group(value: Variant) -> void:
		destroyed.append(value)


class Social extends SocialService:
	var sdk := SocialSDK.new()

	func _social() -> Variant:
		return sdk


class ProfilesSDK extends RefCounted:
	signal released()
	var calls: Array[String] = []

	func get_title_players_from_xbox_live_ids_async(_user: Variant, _request: Dictionary) -> Dictionary:
		calls.append("mapping")
		await released
		return {"ok": true, "data": {}}

	func get_profiles_async(_user: Variant, _ids: PackedStringArray) -> Dictionary:
		calls.append("gamertags")
		await released
		return {"ok": true, "data": []}


class Profiles extends ProfileService:
	var sdk := ProfilesSDK.new()

	func _accounts() -> Variant:
		return sdk

	func _profile() -> Variant:
		return sdk


## One pending wait on a FakeClock.
class ClockSleeper extends RefCounted:
	signal released()
	var at := 0
	var order := 0


## A discrete-event stand-in for OnlineFlowClock. Time moves only when advance() says so;
## each sleeper wakes, in wake-time order, with the clock set to its own wake time, so a
## poll loop that re-sleeps inside one advance still observes every step it would have.
## Alarms armed on it are events in the same order: each fires with the clock set to its
## own due time, before any sleeper due at that same instant. A deadline is expired at
## equality, exactly like the production clock.
class FakeClock extends OnlineFlowClock:
	## Upper bound on wake-ups inside one advance, so a loop that sleeps for zero seconds
	## without ever re-checking its deadline fails loudly instead of hanging the suite.
	const MAX_WAKES_PER_ADVANCE := 100000
	var now := 0
	var _sleepers: Array[ClockSleeper] = []
	var _sequence := 0

	func now_msec() -> int:
		return now

	## This clock's alarms follow its own time: advance() fires them, never an engine timer.
	func _drives_alarms_by_engine() -> bool:
		return false

	func sleep_seconds(seconds: float) -> void:
		_sequence += 1
		var sleeper := ClockSleeper.new()
		sleeper.at = now + int(round(maxf(seconds, 0.0) * 1000.0))
		sleeper.order = _sequence
		_sleepers.append(sleeper)
		await sleeper.released

	func advance(seconds: float) -> void:
		var target := now + int(round(maxf(seconds, 0.0) * 1000.0))
		var wakes := 0
		while wakes < MAX_WAKES_PER_ADVANCE:
			var next: ClockSleeper = null
			for sleeper: ClockSleeper in _sleepers:
				if sleeper.at > target:
					continue
				if next == null or sleeper.at < next.at or (sleeper.at == next.at and sleeper.order < next.order):
					next = sleeper
			var alarm_due := next_alarm_due_msec()
			if alarm_due >= 0 and alarm_due <= target and (next == null or alarm_due <= next.at):
				now = maxi(now, alarm_due)
				wakes += 1
				fire_due_alarms()
				continue
			if next == null:
				break
			_sleepers.erase(next)
			now = maxi(now, next.at)
			wakes += 1
			next.released.emit()
		if wakes >= MAX_WAKES_PER_ADVANCE:
			push_warning("[FakeClock] advance() stopped after %d wake-ups." % wakes)
		now = maxi(now, target)

	func pending() -> int:
		return _sleepers.size()
