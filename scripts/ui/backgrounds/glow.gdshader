// Analytic title/lobby glow. Off/reference keeps the PDF export's staged 8-bit quantization
// exactly. Breathing composites the stops in float, adds screen-fixed TPDF noise, then is rounded
// once; animated t = 0 is therefore intentionally not pixel-equal to the Off state.
shader_type canvas_item;
render_mode unshaded;

uniform vec4 cover_xform = vec4(1.0, 1.0, 0.0, 0.0);
uniform float strength = 1.0;
uniform float size_scale = 1.0;
// 0 selects the staged, noise-free Off reference; 1 selects rounded-once breathing with fixed
// screen-pixel grain.
uniform float dither = 0.0;

const vec2 DESIGN_SIZE = vec2(1920.0, 1080.0);
const vec2 CENTRE = vec2(960.0, 433.392583);
const vec2 RADII = vec2(1338.1524, 609.39245);
const vec3 COLOUR = vec3(0.196078, 0.643137, 0.376471);
const float LIGHT_ALPHA = 0.3;
const float BASE8 = 5.0;
const float BREATHING_QUANTIZE_BIAS = 0.5;

void vertex() {
	UV = UV * cover_xform.xy + cover_xform.zw;
}

uint hash_u32(uint value) {
	value = (value ^ (value >> uint(16))) * uint(73244475);
	value = (value ^ (value >> uint(16))) * uint(73244475);
	return value ^ (value >> uint(16));
}

float hash_unit(uint value) {
	return (float(hash_u32(value) >> uint(8)) + 0.5) / 16777216.0;
}

void fragment() {
	vec2 p = UV * DESIGN_SIZE;
	float r = clamp(1.0 - length((p - CENTRE) / (RADII * size_scale)), 0.0, 1.0);
	if (dither <= 0.0) {
		float a8 = max(floor(LIGHT_ALPHA * r * strength * 255.0), 0.0);
		vec3 c8 = max(floor(COLOUR * r * 255.0), vec3(0.0));
		vec3 out8 = floor((c8 * a8 + BASE8 * (255.0 - a8) + 0.5) / 255.0);
		COLOR = vec4(out8 / 255.0, 1.0);
	} else {
		float a = LIGHT_ALPHA * r * strength;
		vec3 value = COLOUR * r * 255.0 * a + BASE8 * (1.0 - a);
		uvec2 pixel = uvec2(FRAGCOORD.xy);
		uint seed = pixel.x * uint(1597334677) ^ pixel.y * uint(1234567891);
		float tpdf = hash_unit(seed ^ uint(1664525))
				+ hash_unit(seed ^ uint(1013904223)) - 1.0;
		vec3 out8 = floor(value + BREATHING_QUANTIZE_BIAS + tpdf * dither);
		COLOR = vec4(out8 / 255.0, 1.0);
	}
}
