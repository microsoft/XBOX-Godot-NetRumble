// The subtract pass removes every atlas dot at its rest position. The add pass draws the same
// patch after wave displacement, so both passes cancel when displacement and lighting are neutral.
shader_type canvas_item;
render_mode blend_sub;

uniform sampler2D atlas : filter_linear, repeat_disable;
uniform vec2 atlas_size = vec2(1024.0, 547.0);
uniform sampler2D inst_data : filter_nearest, repeat_disable;
varying vec2 atlas_uv;

void vertex() {
	vec4 a = texelFetch(inst_data, ivec2(INSTANCE_ID, 0), 0);
	float w = a.z;
	float h = a.w;
	atlas_uv = (a.xy + VERTEX * vec2(w, h)) / atlas_size;
}

void fragment() {
	COLOR = vec4(texture(atlas, atlas_uv).rgb, 1.0);
}
