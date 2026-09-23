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


class ChatSDK extends RefCounted:
	signal released()
	signal chat_control_added()
	signal chat_control_removed()
	signal audio_muted_changed()
	signal text_message_received()
	var blocked := false
	var calls: Array[String] = []

	func create_local_chat_control_async(user: Variant, _cfg: Variant) -> Dictionary:
		calls.append("create:" + user.xuid)
		if blocked:
			await released
		return {"ok": true}

	func destroy_local_chat_control_async(user: Variant) -> Dictionary:
		calls.append("destroy:" + user.xuid)
		return {"ok": true}


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
