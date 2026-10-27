// Shared by the strand and dot-add passes: returns design-space displacement and lighting for a
// three-wave surface. Time arrives only through explicit uniforms.
uniform float t_phase = 0.0;
uniform float ease = 0.0;
const float WF_AMAX = 24.0;
const float WF_BXMAX = 5.0;
const float WF_LIGHT = 0.12;
const float WF_LOOP = 60.0;

float amp_of(float y) {
	float s = clamp((y - 420.0) / 530.0, 0.0, 1.0);
	s = s * s * (3.0 - 2.0 * s);
	return WF_AMAX * (0.10 + 0.90 * s);
}

vec3 wave_field(vec2 p) {
	vec4 waves[3] = vec4[3](
		vec4(1.0 / 1700.0, 1.0 / 650.0, 3.0, 1.00),
		vec4(-1.0 / 2300.0, 1.0 / 900.0, 6.0, 0.30),
		vec4(1.0 / 4200.0, 1.0 / 1600.0, 1.0, 0.45));
	float w0 = TAU / WF_LOOP;
	float h = 0.0;
	float sx = 0.0;
	float norm = 0.0;
	float sx_norm = 0.0;
	for (int i = 0; i < 3; i++) {
		vec4 wv = waves[i];
		float th = TAU * (wv.x * p.x + wv.y * p.y) - wv.z * w0 * t_phase;
		float dir = wv.x / length(wv.xy);
		h += wv.w * cos(th);
		sx += wv.w * dir * sin(th);
		norm += wv.w;
		sx_norm += wv.w * abs(dir);
	}
	h /= norm;
	sx /= sx_norm;
	float a = amp_of(p.y);
	float bx = min(WF_BXMAX, 0.21 * a);
	return vec3(-ease * bx * sx, -ease * a * h, 1.0 + WF_LIGHT * ease * h);
}
