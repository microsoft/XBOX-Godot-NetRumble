extends Node

## Local player identity plus persisted settings.
##
## Settings are held in memory and persisted through `to_dict()` / `apply_dict()`. The
## dictionary keys are stable, frozen identifiers — they are the schema of data already
## written to players' cloud saves and must never be renamed.
##
## **Where they are written depends on whether the platform offers a protected store.**
## On console the record is `profile.json` in the PlayFab Game Save synced folder, which
## the platform scopes to one user and protects at rest; nothing is written to `user://`
## at all. Console `user://` is a single storage area shared by the whole title, so a
## settings file there outlives the account that wrote it and is readable by the next one
## — which is the XR-014 plaintext finding and half of XR-052.
##
## Desktop has no synced folder (Game Saves reject a session with no local user handle),
## so desktop keeps a `ConfigFile` at `user://settings.cfg`. That is the development
## configuration and holds no console account's data. See
## `IdentityService.has_protected_storage()`.
##
## Because the console build starts every session from defaults and applies the cloud
## payload once sign-in resolves, there is no longer an owner stamp to check: the file
## that could have belonged to somebody else no longer exists. `adopt_local_cache()`
## survives as the "clear the previous user out of memory" step it always also was.
##
## Instances launched with --pf-user=<name> (the local multi-instance Party test path,
## see IdentityService) get their own settings file. Otherwise every client on one PC
## would share — and overwrite — the same settings and appearance.

signal settings_changed()
signal identity_changed()

const SETTINGS_PATH := "user://settings.cfg"
## Music sits low by default because bug-bash voice-chat sessions run alongside
## Teams; the old 70% bed stayed too loud even after testers halved the app in
## Windows, so the new baseline has to land clearly below that.
const DEFAULT_MUSIC_VOLUME := 0.25
const LEGACY_DEFAULT_MUSIC_VOLUME := 0.7

# --- Identity ---------------------------------------------------------------
var display_name: String = "Player"
var entity_id: String = ""
var xbox_user_id: String = ""
var is_signed_in: bool = false

# --- Settings ---------------------------------------------------------------
var master_volume: float = 1.0
var music_volume: float = DEFAULT_MUSIC_VOLUME
var sfx_volume: float = 1.0
var voice_chat_volume: float = 1.0
var ship_style_id: int = 0
var ship_color_id: int = 0
var fullscreen: bool = false
var show_roster_overlay: bool = true
## Number of AI opponents added to a practice match. Persisted like any other
## gameplay setting so the choice survives between sessions.
var practice_opponents: int = 2
## Normalised (0..1) Power-Up Frequency setting, driving both how often pickups drop
## and how many may sit uncollected. Defaults near the top of the range: the pickup
## table is the main source of variety in a match, so the out-of-the-box pacing is
## generous and the slider exists mostly to calm it down.
var power_up_frequency: float = 0.9

var _dirty := false
var _settings_path: String = SETTINGS_PATH
## The values declared above, captured before anything is loaded over them, so
## reset_to_defaults() cannot drift from the declarations the way a second hand-written
## list of literals would.
var _defaults: Dictionary = {}


func _ready() -> void:
	_defaults = to_dict()
	_settings_path = _resolve_settings_path()
	load_settings()
	_apply_to_audio()


## Namespaces the settings file per --pf-user token so two local instances keep separate
## settings; unmodified for a normal (Xbox-signed-in) launch. Reads the static resolver
## rather than the Services autoload because PlayerProfile is constructed first.
func _resolve_settings_path() -> String:
	var token := IdentityService.resolve_custom_id_token()
	if token.is_empty():
		return SETTINGS_PATH
	return "user://settings_%s.cfg" % token.validate_filename()


func set_identity(gamertag: String, entity: String, xuid: String = "") -> void:
	display_name = gamertag if not gamertag.is_empty() else "Player"
	entity_id = entity
	xbox_user_id = xuid
	is_signed_in = not entity.is_empty() or not xuid.is_empty()
	identity_changed.emit()


func has_pending_changes() -> bool:
	return _dirty


func load_settings() -> void:
	if IdentityService.has_protected_storage():
		return
	var config := ConfigFile.new()
	if config.load(_settings_path) != OK:
		return
	var migrated := _read_config(config)
	_apply_to_audio()
	_dirty = migrated
	settings_changed.emit()


## Restores every declared default. Used before applying a newly signed-in user's saved
## values, so a cloud save that is empty or only partially populated cannot leave the
## previous player's settings standing.
func reset_to_defaults() -> void:
	apply_dict(_defaults)


## Clears whatever is in memory and re-reads the desktop settings file, immediately after
## sign-in resolves the identity and before the cloud payload is applied over the top.
##
## The reset is the load-bearing half on console, where `load_settings()` returns without
## reading anything: it is what stops a previous user's values from surviving into the new
## user's session when their cloud save is empty or only partially populated.
func adopt_local_cache() -> void:
	reset_to_defaults()
	load_settings()


## Persists the settings, and by default mirrors them to the cloud save.
##
## `mirror_to_cloud` exists for one caller: the user-removed handler, which must not start
## asynchronous work the platform may terminate mid-flight. It writes the cloud copy itself,
## synchronously, through `GameSaveService.write_now()`. On console that synchronous write
## *is* the save — this function only clears the dirty flag there.
func save_settings(mirror_to_cloud: bool = true) -> void:
	if not IdentityService.has_protected_storage():
		if not _write_settings_file():
			return
	_dirty = false

	# Best-effort cloud mirror; never blocks or fails local persistence.
	if mirror_to_cloud and Services != null and Services.has_method("save_profile_to_cloud"):
		Services.save_profile_to_cloud(to_dict())


func _write_settings_file() -> bool:
	var config := ConfigFile.new()
	config.set_value("audio", "master_volume", master_volume)
	config.set_value("audio", "music_volume", music_volume)
	config.set_value("audio", "sfx_volume", sfx_volume)
	config.set_value("audio", "voice_chat_volume", voice_chat_volume)
	config.set_value("appearance", "ship_style_id", ship_style_id)
	config.set_value("appearance", "ship_color_id", ship_color_id)
	config.set_value("video", "fullscreen", fullscreen)
	config.set_value("hud", "show_roster_overlay", show_roster_overlay)
	config.set_value("gameplay", "practice_opponents", practice_opponents)
	config.set_value("gameplay", "power_up_frequency", power_up_frequency)

	var err := config.save(_settings_path)
	if err != OK:
		push_warning("PlayerProfile: could not write %s (error %d)" % [_settings_path, err])
		return false
	return true


func _read_config(config: ConfigFile) -> bool:
	master_volume = clampf(config.get_value("audio", "master_volume", master_volume), 0.0, 1.0)
	var loaded_music_volume := clampf(config.get_value("audio", "music_volume", music_volume), 0.0, 1.0)
	music_volume = _migrate_legacy_music_volume(loaded_music_volume)
	sfx_volume = clampf(config.get_value("audio", "sfx_volume", sfx_volume), 0.0, 1.0)
	voice_chat_volume = clampf(config.get_value("audio", "voice_chat_volume", voice_chat_volume), 0.0, 1.0)
	ship_style_id = clampi(config.get_value("appearance", "ship_style_id", ship_style_id), 0, 3)
	ship_color_id = clampi(config.get_value("appearance", "ship_color_id", ship_color_id), 0, Assets.player_color_count() - 1)
	fullscreen = bool(config.get_value("video", "fullscreen", fullscreen))
	show_roster_overlay = bool(config.get_value("hud", "show_roster_overlay", show_roster_overlay))
	practice_opponents = clampi(
		config.get_value("gameplay", "practice_opponents", practice_opponents),
		0, NRConst.MAX_PRACTICE_BOTS)
	power_up_frequency = clampf(
		config.get_value("gameplay", "power_up_frequency", power_up_frequency), 0.0, 1.0)
	return not is_equal_approx(music_volume, loaded_music_volume)


## Cloud-save payload. Key strings are frozen persisted identifiers — renaming any one
## orphans every existing cloud save that used it.
func to_dict() -> Dictionary:
	return {
		"masterVolume": master_volume,
		"musicVolume": music_volume,
		"sfxVolume": sfx_volume,
		"voiceChatVolume": voice_chat_volume,
		"selectedShip": ship_style_id,
		"selectedColor": ship_color_id,
		"fullscreen": fullscreen,
		"showRosterOverlay": show_roster_overlay,
		"practiceOpponents": practice_opponents,
		"powerUpFrequency": power_up_frequency,
	}


func apply_dict(data: Dictionary) -> void:
	master_volume = clampf(float(data.get("masterVolume", master_volume)), 0.0, 1.0)
	var loaded_music_volume := clampf(float(data.get("musicVolume", music_volume)), 0.0, 1.0)
	music_volume = _migrate_legacy_music_volume(loaded_music_volume)
	sfx_volume = clampf(float(data.get("sfxVolume", sfx_volume)), 0.0, 1.0)
	voice_chat_volume = clampf(float(data.get("voiceChatVolume", voice_chat_volume)), 0.0, 1.0)
	ship_style_id = clampi(int(data.get("selectedShip", ship_style_id)), 0, 3)
	ship_color_id = clampi(int(data.get("selectedColor", ship_color_id)), 0, Assets.player_color_count() - 1)
	fullscreen = bool(data.get("fullscreen", fullscreen))
	show_roster_overlay = bool(data.get("showRosterOverlay", show_roster_overlay))
	practice_opponents = clampi(
		int(data.get("practiceOpponents", practice_opponents)), 0, NRConst.MAX_PRACTICE_BOTS)
	power_up_frequency = clampf(float(data.get("powerUpFrequency", power_up_frequency)), 0.0, 1.0)
	if data.has("musicVolume") and not is_equal_approx(music_volume, loaded_music_volume):
		_dirty = true
	_apply_to_audio()
	settings_changed.emit()


## Moves profiles that merely inherited the old loud launch default onto the new one.
## There is no settings-version scheme here: only the exact legacy default is changed,
## leaving players' quieter or louder explicit choices alone.
func _migrate_legacy_music_volume(value: float) -> float:
	if is_equal_approx(value, LEGACY_DEFAULT_MUSIC_VOLUME):
		return DEFAULT_MUSIC_VOLUME
	return value


## Marks the profile dirty and pushes audio values through immediately so option
## sliders are audible while dragging.
func mark_dirty() -> void:
	_dirty = true
	_apply_to_audio()
	settings_changed.emit()


func _apply_to_audio() -> void:
	if AudioManager == null:
		return
	AudioManager.set_master_volume(master_volume)
	AudioManager.set_music_volume(music_volume)
	AudioManager.set_sfx_volume(sfx_volume)


func apply_display_settings() -> void:
	var mode := DisplayServer.WINDOW_MODE_FULLSCREEN if fullscreen else DisplayServer.WINDOW_MODE_WINDOWED
	DisplayServer.window_set_mode(mode)
