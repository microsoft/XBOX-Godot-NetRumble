// The base pass draws the raster and replaces its rest strand contribution with an
// inverse-mapped, wave-displaced sample. The subtract/add dot passes cancel exactly at rest.
shader_type canvas_item;

#include "res://scripts/ui/backgrounds/wave_field.gdshaderinc"
uniform sampler2D strands : filter_linear, repeat_disable;
const float BAND_TOP = 352.0;

void fragment() {
	vec4 bw = texture(TEXTURE, UV);
	vec2 p = UV * vec2(1920.0, 1080.0);
	vec3 rgb = bw.rgb;
	if (p.y >= BAND_TOP - 30.0) {
		vec2 size = vec2(1920.0, 1080.0 - BAND_TOP);
		vec2 q = p;
		for (int i = 0; i < 4; i++) {
			q = p - wave_field(q).xy;
		}
		vec3 f = wave_field(q);
		vec4 sr = texture(strands, (p - vec2(0.0, BAND_TOP)) / size);
		vec3 s_rest = vec3(sr.a, sr.r, sr.a);
		vec4 sm = texture(strands, (q - vec2(0.0, BAND_TOP)) / size);
		vec3 s_moved = vec3(sm.a, sm.r, sm.a);
		rgb = rgb - s_rest + s_moved * f.z;
	}
	COLOR = vec4(rgb, 1.0);
}
