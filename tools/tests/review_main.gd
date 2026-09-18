extends "res://scripts/main.gd"

var quit_calls := 0


func _ready() -> void:
	ScreenManager.set_container(_screen_container)
	_connect_lifecycle_signals()


func _quit_immediately() -> void:
	_quit_pending = false
	quit_calls += 1
