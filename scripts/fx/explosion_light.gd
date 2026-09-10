class_name ExplosionLight
extends PointLight2D

## A light that flares and dies with the explosion it belongs to.
##
## Explosions are one-shot particle scenes, and particles alone do not light anything
## around them: a ship blowing up would leave the asteroids beside it as dark as they
## were a frame earlier. This hangs a real [PointLight2D] on the burst so the
## detonation actually illuminates the world -- which is the whole point of the
## `light()` pass added to space_object.gdshader.
##
## The curve is a fast attack into a long decay rather than a linear fade: an
## explosion's flash is over in a couple of frames but its glow lingers, and a linear
## ramp reads as a lamp being switched off.

## Peak brightness, reached `attack` seconds in.
@export var peak_energy: float = 6.0
@export var attack: float = 0.06
@export var decay: float = 0.9
## Radius in world pixels at peak. The shared light texture is 256px across, so the
## texture scale is this divided by 128.
@export var light_radius: float = 420.0
## How much the light grows over its life, as a fraction of `light_radius`.
@export var expansion: float = 0.6

var _elapsed: float = 0.0


func _ready() -> void:
	texture = FXLighting.radial_light_texture()
	blend_mode = Light2D.BLEND_MODE_ADD
	shadow_enabled = false
	energy = 0.0
	texture_scale = light_radius / 128.0


func _process(delta: float) -> void:
	_elapsed += delta
	if _elapsed < attack:
		energy = peak_energy * (_elapsed / maxf(attack, 0.0001))
	else:
		var t := clampf((_elapsed - attack) / maxf(decay, 0.0001), 0.0, 1.0)
		# Squared falloff: bright for the first third of the decay, then away quickly.
		energy = peak_energy * (1.0 - t) * (1.0 - t)
		if t >= 1.0:
			set_process(false)
			visible = false
	var growth := 1.0 + expansion * clampf(_elapsed / maxf(attack + decay, 0.0001), 0.0, 1.0)
	texture_scale = light_radius * growth / 128.0
