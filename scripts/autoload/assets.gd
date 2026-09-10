extends Node

## Central asset registry. Every texture, audio stream and palette colour the game
## uses is declared here, so gameplay code never hard-codes a path at runtime and a
## missing asset fails at startup rather than mid-match.
##
## Textures and audio streams are loaded lazily and cached, so gameplay code can ask
## for them by key every frame without paying repeated disk/import lookups.

const TEXTURE_ROOT := "res://assets/textures/"
const AUDIO_ROOT := "res://assets/audio/"

## Texture key -> path relative to TEXTURE_ROOT.
const TEXTURE_PATHS := {
	"Asteroid0": "Gameplay/Asteroids/Asteroid0.png",
	"Asteroid1": "Gameplay/Asteroids/Asteroid1.png",
	"Asteroid2": "Gameplay/Asteroids/Asteroid2.png",
	"Barrier_End": "Gameplay/Barriers/Barrier_End.png",
	"Barrier_Horizontal": "Gameplay/Barriers/Barrier_Horizontal.png",
	"Barrier_Vertical": "Gameplay/Barriers/Barrier_Vertical.png",
	"Particle_Default": "Gameplay/Particles/Particle_Default.png",
	"Particle_Spark": "Gameplay/Particles/Particle_Spark.png",
	"Particle_Smoke": "Gameplay/Particles/Particle_Smoke.png",
	"Projectile_Laser": "Gameplay/Projectiles/Projectile_Laser.png",
	"Projectile_Mine": "Gameplay/Projectiles/Projectile_Mine.png",
	"Projectile_Rocket": "Gameplay/Projectiles/Projectile_Rocket.png",
	"PowerUp_DoubleLaser": "Gameplay/PowerUps/PowerUp_DoubleLaser.png",
	"PowerUp_Rocket": "Gameplay/PowerUps/PowerUp_Rocket.png",
	"PowerUp_TripleLaser": "Gameplay/PowerUps/PowerUp_TripleLaser.png",
	"ShipShield_Base": "Gameplay/Ships/ShipShield/ShipShield_Base.png",
	"ShipShield_Move": "Gameplay/Ships/ShipShield/ShipShield_Move.png",
	"Ship0_Base": "Gameplay/Ships/Ship0/Ship0_Base.png",
	"Ship0_Overlay": "Gameplay/Ships/Ship0/Ship0_Overlay.png",
	"Ship0_Silhouette": "Gameplay/Ships/Ship0/Ship0_Silhouette.png",
	"Ship1_Base": "Gameplay/Ships/Ship1/Ship1_Base.png",
	"Ship1_Overlay": "Gameplay/Ships/Ship1/Ship1_Overlay.png",
	"Ship1_Silhouette": "Gameplay/Ships/Ship1/Ship1_Silhouette.png",
	"Ship2_Base": "Gameplay/Ships/Ship2/Ship2_Base.png",
	"Ship2_Overlay": "Gameplay/Ships/Ship2/Ship2_Overlay.png",
	"Ship2_Silhouette": "Gameplay/Ships/Ship2/Ship2_Silhouette.png",
	"Ship3_Base": "Gameplay/Ships/Ship3/Ship3_Base.png",
	"Ship3_Overlay": "Gameplay/Ships/Ship3/Ship3_Overlay.png",
	"Ship3_Silhouette": "Gameplay/Ships/Ship3/Ship3_Silhouette.png",
	"Controller_BumperLeft": "UI/Controller/Controller_BumperLeft.png",
	"Controller_BumperRight": "UI/Controller/Controller_BumperRight.png",
	"Controller_Xbox": "UI/Controller/Controller_Xbox.png",
	"Loading_Ring": "UI/Loading/Loading_Ring.png",
	"Lobby_BackgroundColor": "UI/LobbyBackground/LobbyBackground_Color.png",
	"Lobby_BackgroundColorSlot": "UI/LobbyBackground/LobbyBackground_ColorSlot.png",
	"Lobby_BackgroundGameType": "UI/LobbyBackground/LobbyBackground_GameType.png",
	"Lobby_BackgroundRoster": "UI/LobbyBackground/LobbyBackground_Roster.png",
	"Lobby_BackgroundRules": "UI/LobbyBackground/LobbyBackground_Rules.png",
	"Lobby_BackgroundSpaceship": "UI/LobbyBackground/LobbyBackground_Spaceship.png",
	"Logo_NetRumble": "UI/Logo/Logo_NetRumble.png",
	"Logo_Xbox": "UI/Logo/Logo_Xbox.png",
	"Microphone_Available": "UI/Microphone/Microphone_Available.png",
	"Microphone_Muted": "UI/Microphone/Microphone_Muted.png",
	"Microphone_Talking": "UI/Microphone/Microphone_Talking.png",
	"ReadyUp_Checkmark": "UI/ReadyUp/ReadyUp_Checkmark.png",
	"ReadyUp_RingBackground": "UI/ReadyUp/ReadyUp_RingBackground.png",
	"ReadyUp_RingOutline": "UI/ReadyUp/ReadyUp_RingOutline.png",
	"Shape_Square": "UI/Shape/Shape_Square.png",
	"Shape_LeftArrow": "UI/Shape/Shape_LeftArrow.png",
	"Shape_RightArrow": "UI/Shape/Shape_RightArrow.png",
}

## Audio key -> path relative to AUDIO_ROOT.
const AUDIO_PATHS := {
	"AsteroidTouch": "Asteroid/Asteroid_Touch.wav",
	"ExplosionLarge": "Explosion/Explosion_Large.wav",
	"ExplosionMedium": "Explosion/Explosion_Medium.wav",
	"ExplosionShockwave": "Explosion/Explosion_Shockwave.wav",
	"LaserFire": "Laser/laser_fire.tres",
	"MenuScroll": "Menu/Menu_Scroll.wav",
	"MenuSelect": "Menu/Menu_Select.wav",
	"PlayerSpawn": "Player/Player_Spawn.wav",
	"PowerUpSpawn": "PowerUp/PowerUp_Spawn.wav",
	"PowerUpTouch": "PowerUp/PowerUp_Touch.wav",
	"Rocket": "Rocket/Rocket.wav",
	"RocketFire": "Rocket/rocket_fire.tres",
}

const MUSIC_PATH := "res://assets/audio/Music/OneStepBeyond.mp3"

## Per-player ship tints and their names, and the selectable game modes. Both are
## `.tres` resources under `assets/tuning/` so they can be edited in the inspector.
const PLAYER_PALETTE: PlayerPalette = preload("res://assets/tuning/player_palette.tres")

const GAME_MODES: Dictionary = {
	NRTypes.GameModeType.DEATHMATCH: preload("res://assets/tuning/mode_deathmatch.tres"),
}

## Power-up type -> definition. The table itself lives in `PickupLibrary` (it is
## built in code rather than from `.tres` files, because there are thirty-two
## pickups and they have to be balanced against each other as a set); this stays as
## the lookup everyone already calls.

var _texture_cache: Dictionary = {}
var _stream_cache: Dictionary = {}


## Returns the cached texture for a TEXTURE_PATHS key, or null if the key or the
## underlying file is missing.
func texture(key: String) -> Texture2D:
	if _texture_cache.has(key):
		return _texture_cache[key]
	if not TEXTURE_PATHS.has(key):
		push_error("Assets.texture: unknown texture key '%s'" % key)
		return null
	var path: String = TEXTURE_ROOT + str(TEXTURE_PATHS[key])
	var tex := load(path) as Texture2D
	if tex == null:
		push_error("Assets.texture: failed to load '%s'" % path)
	_texture_cache[key] = tex
	return tex


func ship_texture(style_id: int, suffix: String = "Base") -> Texture2D:
	return texture("Ship%d_%s" % [clampi(style_id, 0, 3), suffix])



## Returns the cached AudioStream for an AUDIO_PATHS key, or null if missing.
func audio_stream(key: String) -> AudioStream:
	if _stream_cache.has(key):
		return _stream_cache[key]
	if not AUDIO_PATHS.has(key):
		push_error("Assets.audio_stream: unknown audio key '%s'" % key)
		return null
	var path: String = AUDIO_ROOT + str(AUDIO_PATHS[key])
	var stream := load(path) as AudioStream
	if stream == null:
		push_error("Assets.audio_stream: failed to load '%s'" % path)
	_stream_cache[key] = stream
	return stream


func player_color(color_id: int) -> Color:
	return PLAYER_PALETTE.color_at(color_id)


func player_color_name(color_id: int) -> String:
	return PLAYER_PALETTE.name_at(color_id)


## Number of selectable ship colours.
func player_color_count() -> int:
	return PLAYER_PALETTE.size()


## Configuration for a game mode, or the deathmatch default for an unknown type.
func game_mode(mode_type: NRTypes.GameModeType) -> GameModeConfig:
	return GAME_MODES.get(mode_type, GAME_MODES[NRTypes.GameModeType.DEATHMATCH])


## Definition for a power-up type, or the double-laser default for an unknown type.
func power_up_definition(power_up_type: NRTypes.PowerUpType) -> PowerUpDefinition:
	return PickupLibrary.get_definition(power_up_type)

