class_name FXLighting
extends RefCounted

## Shared, lazily-built light art.
##
## Every lit projectile, explosion and pickup wants the same thing: a soft radial
## falloff to hang on a [PointLight2D]. Rather than ship another PNG (and rather than
## let a few hundred pooled projectiles each build their own gradient), the texture is
## generated once on first use and handed out by reference.
##
## It is 256px across, so a light's world-space radius is `texture_scale * 128`.

const TEXTURE_SIZE := 256

static var _radial: GradientTexture2D = null


static func radial_light_texture() -> GradientTexture2D:
	if _radial != null:
		return _radial
	var gradient := Gradient.new()
	gradient.offsets = PackedFloat32Array([0.0, 0.35, 1.0])
	gradient.colors = PackedColorArray([
		Color(1.0, 1.0, 1.0, 1.0),
		# The mid stop is what gives the falloff a hot core rather than a linear
		# ramp, which is the difference between a shot that looks like it is glowing
		# and one that looks like it has a grey disc stuck to it.
		Color(1.0, 1.0, 1.0, 0.45),
		Color(1.0, 1.0, 1.0, 0.0),
	])
	_radial = GradientTexture2D.new()
	_radial.gradient = gradient
	_radial.width = TEXTURE_SIZE
	_radial.height = TEXTURE_SIZE
	_radial.fill = GradientTexture2D.FILL_RADIAL
	_radial.fill_from = Vector2(0.5, 0.5)
	_radial.fill_to = Vector2(1.0, 0.5)
	return _radial
