class_name GameSaveService
extends RefCounted

## One Xbox-owned XGameSaveFiles folder on PC and console.
## Only prepare() awaits the SDK. Every subsequent operation verifies the binding.
const SAVE_FILE_NAME := "profile.json"
const HISTORY_FILE_NAME := "history.json"
const STATS_FILE_NAME := "stats.json"
const SLOT_SUFFIX := ".alt"
const MAX_SEQUENCE := 9007199254740991

enum Status { OK, MISSING, FAILED, STALE }

var _owner: Variant = null
var _generation := -1
var _epoch := 0
var _folder := ""
var _preparing := false
var _preparation_result: Dictionary = {}
var _first_write_pending: Dictionary = {}
signal _prepared()


static func result(status: Status, data: Variant = null, reason: String = "") -> Dictionary:
	return {"status": status, "data": data, "reason": reason}


func prepare(user: Variant, generation: int) -> Dictionary:
	var started := Time.get_ticks_msec()
	print("[SavePrepare] entry preparing=%s bound=%s" % [_preparing, is_bound(user, generation)])
	if _preparing:
		var same_owner: bool = user == _owner and generation == _generation
		var epoch := _epoch
		print("[SavePrepare] waiting for existing preparation")
		await _prepared
		print("[SavePrepare] existing preparation completed elapsed_ms=%d" % (Time.get_ticks_msec() - started))
		if not same_owner or epoch != _epoch or not _signed_in(user):
			return result(Status.STALE, null, "Save preparation was abandoned.")
		return _preparation_result
	if is_bound(user, generation):
		print("[SavePrepare] reusing prepared folder")
		return result(Status.OK)
	_owner = user
	_generation = generation
	_folder = ""
	_first_write_pending.clear()
	var epoch := _epoch
	var gdk: Variant = _gdk()
	var saves: Variant = gdk.get("game_save") if gdk is Object or gdk is Dictionary else null
	if not saves is Object or not saves.has_method("get_folder_async"):
		print("[SavePrepare] rejected: GDK.game_save unavailable")
		return result(Status.FAILED, null, "Xbox Game Saves is unavailable.")
	if not _signed_in(user):
		print("[SavePrepare] rejected: signed-in Xbox user unavailable")
		return result(Status.FAILED, null, "Game Saves requires a signed-in Xbox account.")
	_preparing = true
	print("[SavePrepare] GDK.game_save.get_folder_async calling elapsed_ms=%d" % (Time.get_ticks_msec() - started))
	var pending: Variant = saves.get_folder_async(user)
	print("[SavePrepare] GDK.game_save.get_folder_async returned; awaiting completion elapsed_ms=%d" % (Time.get_ticks_msec() - started))
	var resolved := _folder_result(await pending)
	var ok: bool = resolved.get("ok") is bool and resolved.get("ok") == true
	print("[SavePrepare] GDK.game_save.get_folder_async completed ok=%s %s elapsed_ms=%d" % [
		ok, _diagnostic_result(resolved), Time.get_ticks_msec() - started])
	var outcome: Dictionary
	if epoch != _epoch or user != _owner or generation != _generation or not _signed_in(user):
		outcome = result(Status.STALE, null, "Save preparation was abandoned.")
	elif not ok:
		outcome = result(Status.FAILED, null, "Could not synchronize Xbox Game Saves (%s)." % _diagnostic_result(resolved))
	else:
		var data: Variant = resolved.get("data")
		var path_valid: bool = data is Dictionary and data.get("path") is String and not String(data.path).is_empty()
		print("[SavePrepare] folder result validated ok=%s elapsed_ms=%d" % [path_valid, Time.get_ticks_msec() - started])
		if not path_valid:
			outcome = result(Status.FAILED, null, "Xbox Game Saves returned an invalid folder result.")
		else:
			print("[SavePrepare] checking folder access elapsed_ms=%d" % (Time.get_ticks_msec() - started))
			var directory := DirAccess.open(data.path)
			print("[SavePrepare] folder access checked ok=%s elapsed_ms=%d" % [directory != null, Time.get_ticks_msec() - started])
			if directory == null:
				outcome = result(Status.FAILED, null, "The Game Saves folder is not accessible.")
			else:
				_folder = data.path
				outcome = result(Status.OK)
	_preparation_result = outcome
	_preparing = false
	print("[SavePrepare] exit status=%s elapsed_ms=%d" % [Status.keys()[outcome.status], Time.get_ticks_msec() - started])
	_prepared.emit()
	return outcome


func is_bound(user: Variant, generation: int) -> bool:
	return _signed_in(user) and user == _owner and generation == _generation and not _folder.is_empty()


static func _signed_in(user: Variant) -> bool:
	return user is Object and is_instance_valid(user) and user.get("signed_in") == true


static func _folder_result(value: Variant) -> Dictionary:
	if value is Dictionary:
		return value
	if value is Object and is_instance_valid(value) and value.has_method("is_ok") and value.has_method("get_data") \
			and value.has_method("get_hresult") and value.has_method("get_code"):
		return {"ok": value.is_ok(), "data": value.get_data(),
			"hresult": value.get_hresult(), "code": value.get_code()}
	return {}


static func _diagnostic_result(value: Dictionary) -> String:
	var code: Variant = value.get("code")
	# Only known addon codes and numeric HRESULTs are safe to log, never native data/messages.
	if code not in ["ok", "cancelled", "not_initialized", "invalid_user", "xbox_services_uninitialized",
			"service_configuration_id_unavailable", "game_save_folder_failed", "game_save_folder_start_failed"]:
		code = "unknown"
	var hr: Variant = value.get("hresult")
	return "code=%s hresult=%s" % [code, ("0x%08X" % (hr & 0xFFFFFFFF)) if hr is int else "unavailable"]


func reset() -> void:
	_epoch += 1
	_owner = null
	_generation = -1
	_folder = ""
	_first_write_pending.clear()


func read(user: Variant, generation: int, file_name: String) -> Dictionary:
	if not is_bound(user, generation):
		return result(Status.STALE, null, "The save account is no longer ready.")
	if not _known_file(file_name):
		return result(Status.FAILED, null, "Unknown save file.")
	var latest := _latest(file_name)
	if latest.status == Status.MISSING:
		return result(Status.MISSING, [] if file_name == HISTORY_FILE_NAME else {})
	if latest.status != Status.OK:
		return result(Status.FAILED, null, latest.reason)
	return result(Status.OK, latest.data.value)


func write_now(user: Variant, generation: int, file_name: String, value: Variant) -> Dictionary:
	if not is_bound(user, generation):
		return result(Status.STALE, null, "The save account is no longer ready.")
	if not valid_payload(file_name, value):
		return result(Status.FAILED, null, "%s has an invalid save format." % file_name)
	var latest := _latest(file_name)
	# The first write can fail before any complete slot exists. Only this live binding
	# may retry the candidate it created; a fresh load of damaged data still fails closed.
	if latest.status == Status.FAILED and _first_write_pending.has(file_name):
		var candidate := _read_slot(file_name, file_name)
		var alternate := _read_slot(file_name, file_name + SLOT_SUFFIX)
		if candidate.status == Status.FAILED and candidate.data != null and alternate.status == Status.MISSING:
			latest = result(Status.MISSING)
	if latest.status not in [Status.OK, Status.MISSING]:
		return result(Status.FAILED, null, latest.reason)
	var sequence := 1
	var slot := file_name
	if latest.status == Status.OK:
		if latest.data.sequence == MAX_SEQUENCE:
			return result(Status.FAILED, null, "The save sequence limit was reached.")
		sequence = int(latest.data.sequence) + 1
		slot = file_name + SLOT_SUFFIX if latest.data.slot == file_name else file_name
	var payload := JSON.stringify(value, "\t")
	var bytes := JSON.stringify({
		"sequence": sequence,
		"payload": payload,
		"sha256": _digest(sequence, payload),
	}, "\t").to_utf8_buffer()
	# Godot's Windows rename deletes an existing destination before moving. Never use
	# it here: only the inactive integrity slot may be truncated, even on a failed write.
	var path := _folder.path_join(slot)
	if latest.status == Status.MISSING:
		_first_write_pending[file_name] = true
	var error := _write_bytes(path, bytes)
	if error != OK:
		return result(Status.FAILED, null, "Could not write %s (error %d). The previous save is unchanged." % [slot, error])
	# Windows FileAccess.flush() does not expose fflush's error. A cached get_error()
	# is insufficient: close and verify the complete candidate through a new handle.
	if not _verify_bytes(path, bytes):
		return result(Status.FAILED, null, "Could not verify the completed write to %s. The previous save is unchanged." % slot)
	_first_write_pending.erase(file_name)
	return result(Status.OK)


func _write_bytes(path: String, bytes: PackedByteArray) -> Error:
	var file := FileAccess.open(path, FileAccess.WRITE)
	if file == null:
		return FileAccess.get_open_error()
	file.store_buffer(bytes)
	file.flush()
	var error := file.get_error()
	file.close()
	return error


func _verify_bytes(path: String, expected: PackedByteArray) -> bool:
	var file := FileAccess.open(path, FileAccess.READ)
	if file == null:
		return false
	var length := file.get_length()
	var actual := file.get_buffer(length)
	var error := file.get_error()
	file.close()
	return error == OK and length == expected.size() and actual == expected


static func _digest(sequence: int, payload: String) -> String:
	return ("%d\n%s" % [sequence, payload]).sha256_text()


## This is the sole current disk format, not a legacy importer. The payload keeps its
## gameplay schema; the envelope detects torn writes and orders two redundant slots.
## A complete new slot may survive a process exit before write_now() returns.
func _latest(file_name: String) -> Dictionary:
	var slots: Array[Dictionary] = [
		_read_slot(file_name, file_name),
		_read_slot(file_name, file_name + SLOT_SUFFIX),
	]
	var newest: Dictionary = {}
	var incomplete := ""
	for slot: Dictionary in slots:
		if slot.status == Status.FAILED:
			# An unreadable slot might be newer. Never guess over an access failure.
			if slot.data == null:
				return slot
			incomplete = String(slot.reason)
		elif slot.status == Status.OK:
			if not newest.is_empty() and newest.data.sequence == slot.data.sequence:
				if newest.data.sha256 != slot.data.sha256:
					return result(Status.FAILED, null, "%s has conflicting save slots." % file_name)
			if newest.is_empty() or newest.data.sequence < slot.data.sequence:
				newest = slot
	if not newest.is_empty():
		if not incomplete.is_empty():
			push_warning("[Game Saves] %s Using the intact save slot." % incomplete)
		return newest
	if not incomplete.is_empty():
		return result(Status.FAILED, null, incomplete)
	return result(Status.MISSING)


func _read_slot(file_name: String, slot: String) -> Dictionary:
	var directory := DirAccess.open(_folder)
	if directory == null:
		return result(Status.FAILED, null, "The Game Saves folder is not accessible.")
	if directory.dir_exists(slot):
		return result(Status.FAILED, null, "%s is not a file." % slot)
	if not directory.file_exists(slot):
		return result(Status.MISSING)
	var file := FileAccess.open(_folder.path_join(slot), FileAccess.READ)
	if file == null:
		return result(Status.FAILED, null, "Could not read %s (error %d)." % [slot, FileAccess.get_open_error()])
	var text := file.get_as_text()
	var error := file.get_error()
	file.close()
	if error != OK:
		return result(Status.FAILED, null, "Could not read %s (error %d)." % [slot, error])
	var damaged := result(Status.FAILED, {"incomplete": true}, "%s has an incomplete or invalid save record." % slot)
	var json := JSON.new()
	if json.parse(text) != OK or not json.data is Dictionary:
		return damaged
	var record: Dictionary = json.data
	if record.size() != 3 or not _integer(record.get("sequence")) \
			or record.sequence < 1 or record.sequence > MAX_SEQUENCE \
			or not record.get("payload") is String or not record.get("sha256") is String:
		return damaged
	var sequence := int(record.sequence)
	if record.sha256 != _digest(sequence, record.payload):
		return damaged
	var payload := JSON.new()
	if payload.parse(record.payload) != OK or not valid_payload(file_name, payload.data):
		return result(Status.FAILED, null, "%s contains an invalid current-format payload." % slot)
	return result(Status.OK, {"slot": slot, "sequence": sequence, "sha256": record.sha256, "value": payload.data})


static func _known_file(file_name: String) -> bool:
	return file_name in [SAVE_FILE_NAME, HISTORY_FILE_NAME, STATS_FILE_NAME]


static func _number(value: Variant) -> bool:
	return (value is int or value is float) and is_finite(float(value))


static func _integer(value: Variant) -> bool:
	return _number(value) and float(value) == floor(float(value)) and abs(float(value)) < 9223372036854775807.0


static func valid_payload(file_name: String, value: Variant) -> bool:
	if file_name == HISTORY_FILE_NAME:
		if not value is Array:
			return false
		for row: Variant in value:
			if not row is Dictionary:
				return false
			for key: String in ["date", "game_mode"]:
				if not row.get(key) is String:
					return false
			for key: String in ["score", "placement", "player_count"]:
				if not _integer(row.get(key)):
					return false
		return true
	if not value is Dictionary:
		return false
	if file_name == SAVE_FILE_NAME:
		for key: String in value:
			match key:
				"masterVolume", "musicVolume", "sfxVolume", "voiceChatVolume", "powerUpFrequency":
					if not _number(value[key]):
						return false
				"selectedShip", "selectedColor", "practiceOpponents":
					if not _integer(value[key]):
						return false
				"fullscreen", "showRosterOverlay":
					if not value[key] is bool:
						return false
				_:
					return false
		return true
	if file_name == STATS_FILE_NAME:
		for key: String in value:
			if key not in ["matches_completed", "wins", "flawless_wins", "kills", "deaths", "asteroids_destroyed", "weapons_fired", "buffs_collected", "modes_completed"]:
				return false
			if not _integer(value[key]) or value[key] < 0:
				return false
		return true
	return false


func _gdk() -> Variant:
	return PlatformAccess.gdk_ready()
