extends "res://scripts/autoload/assets.gd"

const LEGACY_FILES := [
	"settings.cfg", "settings_A.cfg", "match_history.json",
	"match_history_A.json", "achievement_stats.json", "achievement_stats_A.json",
]


func _enter_tree() -> void:
	var sandbox := OS.get_environment("NR_SAVE_TEST_ROOT").replace("\\", "/")
	if sandbox.is_empty() or not OS.get_user_data_dir().replace("\\", "/").begins_with(sandbox + "/"):
		push_error("Test user directory is not inside the disposable sandbox.")
		return
	# Seed before PlayerProfile's _ready, so startup reads are covered too.
	for file_name: String in LEGACY_FILES:
		var file := FileAccess.open("user://".path_join(file_name), FileAccess.WRITE)
		if file == null:
			push_error("Could not seed legacy test fixture " + file_name)
			continue
		if file_name.ends_with(".cfg"):
			file.store_string("[audio]\nmusic_volume=0.95\n")
		elif file_name.begins_with("match_history"):
			file.store_string('{"entries":[{"date":"2026-01-01","game_mode":"Deathmatch","score":999,"placement":1,"player_count":3}]}')
		else:
			file.store_string('{"kills":999,"matches_completed":999}')
		file.close()


func texture(_key: String) -> Texture2D:
	return GradientTexture2D.new()


func audio_stream(_key: String) -> AudioStream:
	return null
