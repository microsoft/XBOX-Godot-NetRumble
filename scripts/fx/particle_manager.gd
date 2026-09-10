class_name ParticleManager
extends Node2D

## 2D particle effects and positional audio for gameplay events.
##
## A GameplayEventLibrary resource (`event_library`) maps each GameplayEventType to a
## one-shot particle scene. `_event_sounds` maps the same events to their audio cues.
## Both tables are consulted by `play_event`, so every visual effect and its accompanying
## sound fire together and can be tuned independently.
##
## The effect scenes carry their own burst counts, lifetimes, speeds, tint colours and
## additive/alpha blend choices and can be adjusted in the Godot inspector without
## touching this script.

const DEFAULT_EVENT_LIBRARY: GameplayEventLibrary = preload("res://assets/fx/gameplay_events.tres")
const SHIP_EXPLOSION_SCENE: PackedScene = preload("res://scenes/gameplay/fx/ship_explosion.tscn")

@export var event_library: GameplayEventLibrary = DEFAULT_EVENT_LIBRARY

var _event_sounds: Dictionary = {
	NRTypes.GameplayEventType.LASER_FIRED: ["LaserFire"],
	NRTypes.GameplayEventType.SHIP_SPAWNED: ["PlayerSpawn"],
	NRTypes.GameplayEventType.SHIP_DESTROYED: ["ExplosionShockwave", "ExplosionLarge"],
	NRTypes.GameplayEventType.MINE_DETONATED: ["ExplosionLarge"],
	NRTypes.GameplayEventType.ROCKET_FIRED: ["RocketFire"],
	NRTypes.GameplayEventType.ROCKET_DETONATED: ["ExplosionMedium"],
	NRTypes.GameplayEventType.POWER_UP_SPAWNED: ["PowerUpSpawn"],
	NRTypes.GameplayEventType.POWER_UP_COLLECTED: ["PowerUpTouch"],
	NRTypes.GameplayEventType.BUFF_COLLECTED: ["PowerUpTouch"],
	NRTypes.GameplayEventType.RESTORE_COLLECTED: ["PowerUpTouch"],
	NRTypes.GameplayEventType.ASTEROID_IMPACT: ["AsteroidTouch"],
}


func _ready() -> void:
	if event_library == null:
		event_library = DEFAULT_EVENT_LIBRARY


## Fires the effect scene and sound(s) mapped to an event. `color` tints the
## effect (multiplied over the scene's own modulate colours); white leaves the preset
## colours unchanged.
func play_event(event_type: NRTypes.GameplayEventType, position: Vector2, color: Color = Color.WHITE) -> void:
	var scene := _effect_scene(event_type)
	if scene != null:
		_spawn_effect(scene, position, color, 1.0)

	if _event_sounds.has(event_type):
		for key in _event_sounds[event_type]:
			_play_positional_sound(str(key), position)


## Generic explosion built from the ship-destruction scene and scaled by `scale`.
func explosion(position: Vector2, scale: float, color: Color) -> void:
	_spawn_effect(SHIP_EXPLOSION_SCENE, position, color, scale)


func clear_all() -> void:
	for child in get_children():
		child.queue_free()


func _effect_scene(event_type: NRTypes.GameplayEventType) -> PackedScene:
	if event_library == null:
		return null
	var key := int(event_type)
	if not event_library.effects.has(key):
		return null
	return event_library.effects[key]


func _spawn_effect(scene: PackedScene, position: Vector2, color: Color, scale: float) -> void:
	var effect := scene.instantiate() as Node2D
	if effect == null:
		return
	effect.position = position
	effect.scale = Vector2.ONE * scale
	effect.modulate = color
	add_child(effect)


func _play_positional_sound(key: String, position: Vector2) -> void:
	var stream := Assets.audio_stream(key)
	if stream == null:
		return

	var player := AudioStreamPlayer2D.new()
	player.name = "EventSound_%s" % key
	player.bus = "SFX"
	player.position = position
	player.stream = stream
	player.finished.connect(player.queue_free)
	add_child(player)
	player.play()
