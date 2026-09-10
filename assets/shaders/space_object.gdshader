shader_type canvas_item;

// Consistent lighting for the world's solid bodies (asteroids, power-ups, mines).
//
// The sample's art is flat and unlit: every rock is drawn with the same baked
// highlight, so a field of asteroids reads as a collection of stickers rather than
// as lit objects, and a spinning rock carries its highlight around with it.
//
// Rather than author normal maps for every texture (and add a Light2D pass the rest
// of the game does not use), this fakes a normal per fragment by treating the sprite
// quad as a hemisphere: UV distance from the centre gives the x/y of the normal, and
// z falls out of the unit-sphere identity. That is a very good match for asteroids
// and pickups, which are all roughly ball-shaped.
//
// The crucial part is that the normal is rotated into *world* space with MODEL_MATRIX
// before it is lit. Asteroids spin (Asteroid.tick drives `set_facing`), and a normal
// left in local space would carry its highlight around with the rock. Rotating it
// nails the light to one place in the world no matter how the body tumbles -- which
// is what makes every object look lit by the same source.
//
// That source is shared through a single ShaderMaterial
// (assets/materials/space_object_lighting.tres) which every entity scene points at,
// so there is exactly one light in the world and moving it moves every shadow.

group_uniforms Light;
/// Direction the light *travels*, in world space. The default is a sun above and to
/// the left, so lit edges face up-left and shadows fall down-right.
uniform vec2 light_direction = vec2(0.55, 0.83);
/// How much of the light comes straight out of the screen. 0 is fully edge-on (a hard
/// terminator down the middle of every body), 1 is straight down the camera (no
/// shading at all).
uniform float light_elevation : hint_range(0.0, 1.0) = 0.45;
/// Floor brightness on the unlit side. Pure black shadows read as holes in space.
uniform float ambient : hint_range(0.0, 1.0) = 0.28;
/// Colour the shadow side is tinted towards, keeping it cool rather than merely dark.
uniform vec4 shadow_tint : source_color = vec4(0.36, 0.42, 0.62, 1.0);

group_uniforms Shape;
/// How spherical the fake normal is. 1.0 is a full hemisphere; lower values flatten
/// the body, which suits flatter sprites such as the mine.
uniform float sphericity : hint_range(0.0, 1.0) = 1.0;

group_uniforms Highlights;
uniform float specular_strength : hint_range(0.0, 2.0) = 0.35;
uniform float specular_power : hint_range(1.0, 64.0) = 12.0;
/// A thin lit fringe along the silhouette on the lit side, which is what sells a
/// sprite as a round body rather than a shaded disc.
uniform float rim_strength : hint_range(0.0, 2.0) = 0.45;
uniform float rim_power : hint_range(1.0, 8.0) = 3.0;
uniform vec4 rim_color : source_color = vec4(1.0, 0.96, 0.88, 1.0);

group_uniforms DynamicLights;
/// How strongly a passing Light2D -- a weapon bolt, an explosion, a pickup -- adds to
/// the body. Above 1.0 so a shot flying past visibly flares the rock it lights.
uniform float dynamic_light_strength : hint_range(0.0, 4.0) = 1.6;
/// Floor applied to the dynamic light's own lambert term. Without it the half of a
/// body facing away from a passing bolt stays completely unlit, which reads as the
/// body being cut in two rather than as it being lit from one side.
uniform float dynamic_light_ambient : hint_range(0.0, 1.0) = 0.35;
/// Height of the dynamic lights above the play plane, in pixels. Canvas lights are
/// flat, so a light exactly on top of a body would have a zero-length direction
/// vector; lifting them off the plane gives the falloff somewhere to happen.
uniform float dynamic_light_height = 120.0;

// The sprite's world-space rotation basis. MODEL_MATRIX is a vertex-stage builtin in
// canvas_item shaders, so the basis has to be extracted there and handed forward
// rather than read straight out of fragment().
varying flat vec2 basis_x;
varying flat vec2 basis_y;


/// The fake hemisphere normal, rotated into world space. Shared by fragment() and
/// light() so a passing bolt lights a body with exactly the same surface the sun
/// shades it with.
vec3 body_normal(vec2 uv) {
	vec2 offset = clamp((uv - vec2(0.5)) * 2.0, vec2(-1.0), vec2(1.0));
	float radius_squared = min(dot(offset, offset), 1.0);
	float depth = sqrt(1.0 - radius_squared);
	vec3 local_normal = normalize(vec3(offset * sphericity, max(depth, 0.001)));
	return vec3(
		local_normal.x * basis_x + local_normal.y * basis_y,
		local_normal.z);
}


void vertex() {
	// Entity sprite scale is uniform and positive, so normalising the basis vectors
	// leaves pure rotation behind.
	basis_x = normalize(vec2(MODEL_MATRIX[0].x, MODEL_MATRIX[0].y));
	basis_y = normalize(vec2(MODEL_MATRIX[1].x, MODEL_MATRIX[1].y));
}


void fragment() {
	// COLOR arrives as texture * modulate, so an entity's own tinting (the power-up
	// pulse, a projectile's owner colour) is already folded in.
	vec4 base = COLOR;

	// Fake hemisphere normal, already rotated into world space using the basis handed
	// over from vertex(). Rotating it is what nails the highlight to one place in the
	// world no matter how the body tumbles.
	vec3 world_normal = body_normal(UV);

	vec3 to_light = normalize(vec3(-light_direction, max(light_elevation, 0.001)));
	float lambert = max(dot(world_normal, to_light), 0.0);

	// Half-vector specular against a camera looking straight down +Z.
	vec3 half_vector = normalize(to_light + vec3(0.0, 0.0, 1.0));
	float specular = pow(max(dot(world_normal, half_vector), 0.0), specular_power) * specular_strength;

	// Rim only on the lit hemisphere, otherwise it outlines the shadow side too.
	float rim = pow(1.0 - world_normal.z, rim_power) * lambert * rim_strength;

	float exposure = ambient + (1.0 - ambient) * lambert;
	vec3 shaded = mix(base.rgb * shadow_tint.rgb, base.rgb, lambert) * exposure;
	shaded += (specular + rim) * rim_color.rgb * base.a;

	COLOR = vec4(shaded, base.a);
}


// Additive pass run once per Light2D touching this body -- the weapon bolts, the
// explosions and the pickups all carry one.
//
// Dropping `render_mode unshaded` is what enables this: the sun-shaded result from
// fragment() is still the base pass, and each light now adds on top of it instead of
// being discarded. The lights use the same faked hemisphere normal as the sun does,
// so a bolt streaking past a rock lights the side of it facing the bolt and leaves
// the far side in shadow, which is what sells the shot as a real light source rather
// than as a sprite with a glow stuck behind it.
void light() {
	vec3 world_normal = body_normal(UV);

	// LIGHT_POSITION and LIGHT_VERTEX are both in canvas space. Canvas lights are
	// flat, so the light is treated as floating above the play plane to give the
	// direction vector a z component to work with.
	vec3 to_light = normalize(vec3(
		LIGHT_POSITION.xy - LIGHT_VERTEX.xy,
		max(dynamic_light_height, 1.0)));
	float lambert = max(dot(world_normal, to_light), 0.0);
	float exposure = dynamic_light_ambient + (1.0 - dynamic_light_ambient) * lambert;

	// LIGHT_COLOR already carries the light texture's falloff, so the shot fades out
	// with distance without this having to model attenuation itself.
	LIGHT = vec4(
		LIGHT_COLOR.rgb * COLOR.rgb * LIGHT_ENERGY * exposure * dynamic_light_strength,
		LIGHT_COLOR.a * COLOR.a);
}
