extends "res://scripts/autoload/audio_manager.gd"

var volumes := {"Master": 1.0, "Music": 0.25, "SFX": 1.0}


func _ready() -> void:
	pass


func play_sound(_key: String, _volume_scale: float = 1.0, _pitch_scale: float = 1.0) -> void:
	pass


func _set_bus_volume(bus: StringName, value: float) -> void:
	volumes[String(bus)] = value
