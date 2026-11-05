// Lobby ship preview: draws the 64 x 64 ship sprites several times larger than their pixels.
// Bilinear filtering at that scale blurs every edge and shows each source pixel as a stair-step
// along the outline. These sprites are hard shapes with anti-aliased edges (their partial alpha
// sits on the outline), so:
//   - coverage comes from a cubic B-spline of the sprite's alpha, re-thresholded at 0.5 with a
//     one-screen-pixel smoothstep, which turns the soft, stepped edge into a smooth, crisp one;
//   - colour comes from a Catmull-Rom sample of the same 16 texels, which keeps the shading
//     gradients smooth without the extra blur of a B-spline.
// The sprites import with fix_alpha_border, so transparent texels carry their neighbours' colour
// and the colour sample does not darken toward the outline. Every sample is a texelFetch, so the
// node's texture filter does not matter. COLOR from vertex() carries the node's modulate, which
// tints the base layer with the player's colour.
shader_type canvas_item;

varying vec4 tint;

void vertex() {
	tint = COLOR;
}

vec4 bspline_weights(float t) {
	float t2 = t * t;
	float t3 = t2 * t;
	float u = 1.0 - t;
	return vec4(u * u * u, 3.0 * t3 - 6.0 * t2 + 4.0, -3.0 * t3 + 3.0 * t2 + 3.0 * t + 1.0, t3) / 6.0;
}

vec4 catmull_rom_weights(float t) {
	float t2 = t * t;
	float t3 = t2 * t;
	return vec4(
			-0.5 * t3 + t2 - 0.5 * t,
			1.5 * t3 - 2.5 * t2 + 1.0,
			-1.5 * t3 + 2.0 * t2 + 0.5 * t,
			0.5 * t3 - 0.5 * t2);
}

void fragment() {
	ivec2 size = textureSize(TEXTURE, 0);
	vec2 position = UV * vec2(size) - 0.5;
	vec2 cell = floor(position);
	vec2 f = position - cell;
	ivec2 origin = ivec2(cell) - ivec2(1);
	vec4 alpha_x = bspline_weights(f.x);
	vec4 alpha_y = bspline_weights(f.y);
	vec4 colour_x = catmull_rom_weights(f.x);
	vec4 colour_y = catmull_rom_weights(f.y);
	float ax[4] = float[4](alpha_x.x, alpha_x.y, alpha_x.z, alpha_x.w);
	float ay[4] = float[4](alpha_y.x, alpha_y.y, alpha_y.z, alpha_y.w);
	float cx[4] = float[4](colour_x.x, colour_x.y, colour_x.z, colour_x.w);
	float cy[4] = float[4](colour_y.x, colour_y.y, colour_y.z, colour_y.w);

	float alpha = 0.0;
	vec3 rgb = vec3(0.0);
	for (int j = 0; j < 4; j++) {
		for (int i = 0; i < 4; i++) {
			ivec2 texel = clamp(origin + ivec2(i, j), ivec2(0), size - ivec2(1));
			vec4 colour = texelFetch(TEXTURE, texel, 0);
			alpha += colour.a * ax[i] * ay[j];
			rgb += colour.rgb * cx[i] * cy[j];
		}
	}

	float edge = max(fwidth(alpha) * 0.5, 0.0001);
	float coverage = smoothstep(0.5 - edge, 0.5 + edge, alpha);
	COLOR = vec4(clamp(rgb, vec3(0.0), vec3(1.0)), coverage) * tint;
}
