extends Node

## Looping background music plus a pool of voices for one-shot UI and gameplay sounds.
##
## Volume and mute are owned by the audio buses declared in `default_bus_layout.tres`
## (`Master → Music`, `Master → SFX`), so the options sliders drive `AudioServer`
## directly rather than multiplying scalars into every player.

const VOICE_COUNT := 24

const MASTER_BUS := &"Master"
const MUSIC_BUS := &"Music"
const SFX_BUS := &"SFX"

var _music_player: AudioStreamPlayer
var _voices: Array[AudioStreamPlayer] = []
var _next_voice := 0
## Platform-driven mute state, and the player's own mute underneath it. See
## set_system_muted().
var _system_muted := false
var _mute_before_system := false


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS

	_music_player = AudioStreamPlayer.new()
	_music_player.name = "MusicPlayer"
	_music_player.bus = MUSIC_BUS
	add_child(_music_player)

	for i in VOICE_COUNT:
		var voice := AudioStreamPlayer.new()
		voice.name = "Voice%d" % i
		voice.bus = SFX_BUS
		add_child(voice)
		_voices.append(voice)


## Plays a one-shot sound by Assets.AUDIO_PATHS key. `volume_scale` is relative to the
## SFX bus; `pitch_scale` multiplies whatever pitch the stream itself chooses.
func play_sound(key: String, volume_scale: float = 1.0, pitch_scale: float = 1.0) -> void:
	var stream := Assets.audio_stream(key)
	if stream == null:
		return

	var voice := _acquire_voice()
	if voice == null:
		return

	voice.stream = stream
	voice.pitch_scale = pitch_scale
	voice.volume_linear = maxf(volume_scale, 0.0)
	voice.play()


## Picks a free voice, falling back to round-robin stealing when all are busy so a
## burst of explosions never silently drops the most recent sound.
func _acquire_voice() -> AudioStreamPlayer:
	for voice in _voices:
		if not voice.playing:
			return voice
	var stolen := _voices[_next_voice]
	_next_voice = (_next_voice + 1) % _voices.size()
	return stolen


func play_music(loop: bool = true) -> void:
	var stream := load(Assets.MUSIC_PATH) as AudioStream
	if stream == null:
		push_warning("AudioManager: music stream missing at %s" % Assets.MUSIC_PATH)
		return
	if stream is AudioStreamMP3:
		(stream as AudioStreamMP3).loop = loop
	_music_player.stream = stream
	_music_player.play()


func stop_music() -> void:
	_music_player.stop()


func stop_all() -> void:
	stop_music()
	for voice in _voices:
		voice.stop()


# --- Bus-backed volume controls ---------------------------------------------

func set_master_volume(value: float) -> void:
	_set_bus_volume(MASTER_BUS, value)


func set_music_volume(value: float) -> void:
	_set_bus_volume(MUSIC_BUS, value)


func set_sfx_volume(value: float) -> void:
	_set_bus_volume(SFX_BUS, value)


func get_master_volume() -> float:
	return _bus_volume(MASTER_BUS)


func get_music_volume() -> float:
	return _bus_volume(MUSIC_BUS)


func get_sfx_volume() -> float:
	return _bus_volume(SFX_BUS)


func set_muted(value: bool) -> void:
	AudioServer.set_bus_mute(AudioServer.get_bus_index(MASTER_BUS), value)


func is_muted() -> bool:
	return AudioServer.is_bus_mute(AudioServer.get_bus_index(MASTER_BUS))


## Mute driven by the platform rather than by the player, for the constrain path in
## `main.gd` (XR-001).
##
## Kept apart from set_muted() because the two have different owners. The player's own
## mute is a setting; this is a temporary state that has to hand the setting back exactly
## as it found it, so a player who was already muted before the Guide opened is still muted
## after it closes. Nothing here touches PlayerProfile: opening the Guide is not a settings
## change and must never be written to disk as one.
func set_system_muted(value: bool) -> void:
	if value == _system_muted:
		return
	if value:
		_mute_before_system = is_muted()
		_system_muted = true
		set_muted(true)
	else:
		_system_muted = false
		set_muted(_mute_before_system)


func _set_bus_volume(bus: StringName, value: float) -> void:
	AudioServer.set_bus_volume_linear(AudioServer.get_bus_index(bus), clampf(value, 0.0, 1.0))


func _bus_volume(bus: StringName) -> float:
	return AudioServer.get_bus_volume_linear(AudioServer.get_bus_index(bus))
