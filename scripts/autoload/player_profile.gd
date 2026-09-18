extends Node

## In-memory account settings; only Services writes their Game Saves payload.
signal settings_changed()
signal identity_changed()

const DEFAULT_MUSIC_VOLUME := 0.25

var display_name: String = "Player"
var entity_id: String = ""
var xbox_user_id: String = ""
var is_signed_in: bool = false

var master_volume: float = 1.0
var music_volume: float = DEFAULT_MUSIC_VOLUME
var sfx_volume: float = 1.0
var voice_chat_volume: float = 1.0
var ship_style_id: int = 0
var ship_color_id: int = 0
var fullscreen: bool = false
var show_roster_overlay: bool = true
var practice_opponents: int = 2
var power_up_frequency: float = 0.9

var _defaults: Dictionary = {}


func _ready() -> void:
	_defaults = to_dict()
	_apply_to_audio()


func set_identity(gamertag: String, entity: String, xuid: String = "") -> void:
	display_name = gamertag if not gamertag.is_empty() else "Player"
	entity_id = entity
	xbox_user_id = xuid
	is_signed_in = not entity.is_empty() or not xuid.is_empty()
	identity_changed.emit()


func reset_to_defaults() -> void:
	apply_dict(_defaults)
	apply_display_settings()


func save_settings() -> bool:
	return Services.save_profile(to_dict())


## Current JSON keys are the account save schema.
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
	music_volume = clampf(float(data.get("musicVolume", music_volume)), 0.0, 1.0)
	sfx_volume = clampf(float(data.get("sfxVolume", sfx_volume)), 0.0, 1.0)
	voice_chat_volume = clampf(float(data.get("voiceChatVolume", voice_chat_volume)), 0.0, 1.0)
	ship_style_id = clampi(int(data.get("selectedShip", ship_style_id)), 0, 3)
	ship_color_id = clampi(int(data.get("selectedColor", ship_color_id)), 0, Assets.player_color_count() - 1)
	fullscreen = bool(data.get("fullscreen", fullscreen))
	show_roster_overlay = bool(data.get("showRosterOverlay", show_roster_overlay))
	practice_opponents = clampi(int(data.get("practiceOpponents", practice_opponents)), 0, NRConst.MAX_PRACTICE_BOTS)
	power_up_frequency = clampf(float(data.get("powerUpFrequency", power_up_frequency)), 0.0, 1.0)
	notify_settings_changed()


func notify_settings_changed() -> void:
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
