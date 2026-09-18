extends "res://scripts/autoload/services.gd"

const Doubles := preload("res://tools/tests/doubles.gd")
var user_events_runtime: Variant = null


func _user_events_gdk() -> Variant:
	return user_events_runtime if user_events_runtime != null else super._user_events_gdk()


func _ready() -> void:
	_identity = Doubles.Identity.new()
	_game_saves = Doubles.Saves.new()
	_achievements = Doubles.Achievements.new()
	_activity = ActivityService.new()
	_achievement_tracker = AchievementTracker.new()
	_achievement_tracker.progress_changed.connect(_on_achievement_progress)
	_identity.stage_changed.connect(_set_sign_in_stage)


func _warm_account_state() -> void:
	pass
