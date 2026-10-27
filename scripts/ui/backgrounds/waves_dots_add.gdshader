// The add pass draws every atlas dot at its wave-displaced position and applies surface lighting.
// Together with the rest-position subtract pass, it reproduces the source raster at rest.
shader_type canvas_item;
render_mode blend_add;

#include "res://scripts/ui/backgrounds/wave_field.gdshaderinc"
uniform sampler2D atlas : filter_linear, repeat_disable;
uniform vec2 atlas_size = vec2(1024.0, 547.0);
uniform sampler2D inst_data : filter_nearest, repeat_disable;
varying vec2 patch_uv;
varying flat vec4 rect;
varying float lit;

void vertex() {
	vec4 a = texelFetch(inst_data, ivec2(INSTANCE_ID, 0), 0);
	rect = a;
	vec3 f = wave_field(texelFetch(inst_data, ivec2(INSTANCE_ID, 1), 0).xy);
	lit = f.z;
	vec2 dl = f.xy / a.zw;
	vec2 lo = min(vec2(0.0), dl);
	vec2 hi = max(vec2(1.0), vec2(1.0) + dl);
	vec2 local = mix(lo, hi, VERTEX);
	patch_uv = local - dl;
	VERTEX = local;
}

void fragment() {
	vec3 rgb = vec3(0.0);
	if (all(greaterThanEqual(patch_uv, vec2(0.0))) && all(lessThanEqual(patch_uv, vec2(1.0)))) {
		rgb = texture(atlas, (rect.xy + patch_uv * rect.zw) / atlas_size).rgb * lit;
	}
	COLOR = vec4(rgb, 1.0);
}
