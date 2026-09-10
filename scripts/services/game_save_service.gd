class_name GameSaveService
extends RefCounted

## PlayFab Game Save storage for the player profile and match history.
##
## Game Saves provide a per-account cloud-synced folder that follows the player across
## consoles. Persistence is a two-step sequence: call
## PlayFab.game_saves.add_user_with_ui_async to add the user (this triggers the initial
## cloud sync) and retrieve the folder path with PlayFab.game_saves.get_folder. The
## profile and match history are JSON files written directly into that folder.
##
## Writing into the synced folder *is* the persistence step. The platform flushes that folder
## after the title closes, so nothing here calls upload_with_ui_async. That is what lets the
## user-removed path (Services.persist_user_state) write both files synchronously through
## write_now(), with no await for the platform to cut short while it is tearing the process
## down.
##
## Game Saves require an Xbox-backed session with a local user handle; custom-id or
## unpackaged sessions are rejected with xbox_user_required, and on an unconfigured dev
## machine the runtime reports Game Saves unavailable. Every path guards for that and
## degrades to a no-op / empty result.

const SAVE_FILE_NAME := "profile.json"
## Match history lives beside the profile rather than inside it. The profile.json key
## names are the canonical identifiers for each setting in the cloud save; renaming them
## silently drops previously stored values on load because the save is keyed by name.
const HISTORY_FILE_NAME := "history.json"
## Lifetime achievement counters, in the same folder for the same reason: they follow the
## account across consoles, which is the whole point of a lifetime counter. Kept out of
## profile.json because that file is a settings mirror the player's options screen owns,
## and progress is not a setting.
const STATS_FILE_NAME := "stats.json"

var _user_added: bool = false
## The synced folder path, cached the first time it resolves, so write_now() can persist
## without awaiting the add-user round trip again.
var _folder: String = ""


func save(user: Variant, data: Dictionary) -> void:
	var folder: String = await _ensure_user_added(user)
	if folder.is_empty():
		return
	_write_json(folder.path_join(SAVE_FILE_NAME), data)


func load(user: Variant) -> Dictionary:
	var folder: String = await _ensure_user_added(user)
	if folder.is_empty():
		return {}
	var parsed: Variant = _read_json(folder.path_join(SAVE_FILE_NAME))
	return parsed if typeof(parsed) == TYPE_DICTIONARY else {}


func save_history(user: Variant, entries: Array) -> void:
	var folder: String = await _ensure_user_added(user)
	if folder.is_empty():
		return
	_write_json(folder.path_join(HISTORY_FILE_NAME), entries)


func load_history(user: Variant) -> Array:
	var folder: String = await _ensure_user_added(user)
	if folder.is_empty():
		return []
	var parsed: Variant = _read_json(folder.path_join(HISTORY_FILE_NAME))
	return parsed if typeof(parsed) == TYPE_ARRAY else []


func save_stats(user: Variant, stats: Dictionary) -> void:
	var folder: String = await _ensure_user_added(user)
	if folder.is_empty():
		return
	_write_json(folder.path_join(STATS_FILE_NAME), stats)


func load_stats(user: Variant) -> Dictionary:
	var folder: String = await _ensure_user_added(user)
	if folder.is_empty():
		return {}
	var parsed: Variant = _read_json(folder.path_join(STATS_FILE_NAME))
	return parsed if typeof(parsed) == TYPE_DICTIONARY else {}


## Synchronous write into the already-resolved synced folder, for the one caller that
## cannot await: the user-removed handler, which the platform may terminate at any point
## once it returns. Returns false when no folder has resolved yet, which means the session
## never reached Game Saves and there was never anywhere for this to write.
func write_now(file_name: String, value: Variant) -> bool:
	if _folder.is_empty():
		return false
	return _write_json(_folder.path_join(file_name), value)


## True once the synced folder is known, i.e. once write_now() has somewhere to write.
func has_folder() -> bool:
	return not _folder.is_empty()


## Drops the cached user and folder. Called when the signed-in user goes away: the local
## user handle belongs to that user, and a folder resolved for them is not somewhere the
## next user's data may be written.
func reset() -> void:
	_user_added = false
	_folder = ""


## Adds the user to Game Saves once (which performs the initial cloud sync) and returns the
## synced folder path, or "" when Game Saves is unavailable for this session.
func _ensure_user_added(user: Variant) -> String:
	var pf: Variant = _playfab()
	if pf == null or user == null or not user.has_local_user_handle:
		return ""

	var game_saves: Variant = pf.game_saves
	if not _user_added:
		var add_result: Variant = await game_saves.add_user_with_ui_async(user)
		if add_result == null or not add_result.ok:
			push_warning("[Services] Game Saves add-user failed: %s" % _reason(add_result))
			return ""
		_user_added = true

	var folder_result: Variant = game_saves.get_folder(user)
	if folder_result == null or not folder_result.ok:
		return ""
	_folder = String(folder_result.data)
	return _folder


func _write_json(path: String, value: Variant) -> bool:
	var file := FileAccess.open(path, FileAccess.WRITE)
	if file == null:
		push_warning("[Services] Could not write cloud save at %s" % path)
		return false
	file.store_string(JSON.stringify(value, "\t"))
	file.close()
	return true


func _read_json(path: String) -> Variant:
	if not FileAccess.file_exists(path):
		return null
	var file := FileAccess.open(path, FileAccess.READ)
	if file == null:
		return null
	var text := file.get_as_text()
	file.close()
	return JSON.parse_string(text)


func _playfab() -> Variant:
	return PlatformAccess.playfab()


func _reason(result: Variant) -> String:
	return PlatformAccess.reason(result)
