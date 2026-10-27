// Lobby ship card fill, drawn behind the ShipBackground Panel by NRShipCard
// (scripts/ui/elements/nr_ship_card.gd).
//
// The card's stack, bottom to top, all normal blending in sRGB with unpremultiplied stops:
//   P1 opaque #050505; P2, P3, P4 radial gradients centred at the card's top centre.
// Each layer is composited with 8-bit truncation (a8 = floor(a 255), c8 = floor(c 255),
// dst = floor((c8 a8 + dst (255 - a8)) / 255)), so the card keeps the design's 8-bit colour
// values. The gradients are fractions of the rect, so a resized card scales.
//
// Alpha is the silhouette of the Panel's StyleBoxFlat (square top corners, rounded bottom corners,
// including its anti-aliasing), so the Panel's 1 px outline sits exactly on the fill's edge. The
// fill quad extends aa_size / 2 past the Panel on every side, as StyleBoxFlat's ramp does. The
// Panel clips its children and its own StyleBoxFlat with one scissor (its rect, rounded to whole
// pixels), so the outline and this fill always lose exactly the same part of that outer ramp. At
// whole-pixel alignment (1080p) the clipped part has zero coverage for both anyway.
//
// Static: no time, no textures. Every uniform has a working default, so a bare 589 x 427 ColorRect
// with this shader draws the real card (used to warm the pipeline before the lobby shows).
shader_type canvas_item;
render_mode unshaded;

// The Panel's size in its local units, and its StyleBoxFlat's corner settings.
uniform vec2 rect_size = vec2(589.0, 427.0);
uniform float corner_radius = 12.0;  // bottom corners; top corners are square
uniform float aa_size = 1.0;         // StyleBoxFlat.anti_aliasing_size
uniform float corner_detail = 8.0;   // StyleBoxFlat.corner_detail

const float BASE8 = 5.0;
const vec3 TEAL = vec3(0.0, 0.431373, 0.647059);
const vec3 P2_CENTRE = vec3(0.0, 0.145098, 0.149020);
const vec3 P4_CENTRE = vec3(0.435294, 0.862745, 0.580392);
// Radii as fractions of the rect: P2 287.04 x 427, P3/P4 294.5 x 427 on a 589 x 427 card.
const vec2 P2_RADII = vec2(287.04 / 589.0, 1.0);
const vec2 P34_RADII = vec2(0.5, 1.0);

varying vec2 local_pos;

void vertex() {
	local_pos = VERTEX - vec2(0.5 * aa_size);  // Panel-local position
}

// One layer over dst with 8-bit truncation. The numerator is an integer, so the
// +0.5 keeps the division exact under GPU rounding.
vec3 over8(vec3 dst8, float alpha, vec3 colour) {
	float a8 = floor(clamp(alpha, 0.0, 1.0) * 255.0);
	vec3 c8 = floor(colour * 255.0);
	return floor((c8 * a8 + dst8 * (255.0 - a8) + 0.5) / 255.0);
}

// Coverage of the StyleBoxFlat silhouette: a linear ramp of width aa_size centred on the edges;
// at the bottom corners, the same polygon ring StyleBoxFlat builds (corner_detail segments between
// radii R - aa and R around a centre inset by R - aa / 2), interpolated across each segment strip.
float silhouette(vec2 q) {
	float inner = min(min(q.x, rect_size.x - q.x), min(q.y, rect_size.y - q.y));
	float coverage = clamp(inner / aa_size + 0.5, 0.0, 1.0);
	float inset = corner_radius - 0.5 * aa_size;
	vec2 d = vec2(abs(q.x - 0.5 * rect_size.x) - (0.5 * rect_size.x - inset), q.y - (rect_size.y - inset));
	if (corner_radius > 0.0 && d.x > 0.0 && d.y > 0.0) {
		float step_angle = 0.5 * PI / corner_detail;
		float segment = clamp(floor(atan(d.y, d.x) / step_angle), 0.0, corner_detail - 1.0);
		float mid = (segment + 0.5) * step_angle;
		float half_cos = cos(0.5 * step_angle);
		float along_normal = dot(d, vec2(cos(mid), sin(mid)));
		coverage = clamp((corner_radius * half_cos - along_normal) / (aa_size * half_cos), 0.0, 1.0);
	}
	return coverage;
}

void fragment() {
	vec2 uv = local_pos / rect_size;  // gradients in fractions of the card, centre at (0.5, 0)
	float t2 = length(vec2(uv.x - 0.5, uv.y) / P2_RADII);
	float t34 = length(vec2(uv.x - 0.5, uv.y) / P34_RADII);
	vec3 dst = vec3(BASE8);
	// P2: alpha 0.10 * 0.6 (1 - t), colour (0, 37, 38) -> teal.
	dst = over8(dst, t2 <= 1.0 ? 0.06 * (1.0 - t2) : 0.0, mix(P2_CENTRE, TEAL, min(t2, 1.0)));
	// P3: alpha 0.20 * m(t), m = 0.19 flat to t = 0.0001, then linear to 0 at t = 0.6; teal.
	float m = t34 <= 0.0001 ? 0.19 : (t34 <= 0.6 ? 0.19 - 0.316719 * (t34 - 0.0001) : 0.0);
	dst = over8(dst, 0.20 * max(m, 0.0), TEAL);
	// P4: alpha 0.20 * 0.45 (1 - t), colour (111, 220, 148) -> teal.
	dst = over8(dst, t34 <= 1.0 ? 0.09 * (1.0 - t34) : 0.0, mix(P4_CENTRE, TEAL, min(t34, 1.0)));
	COLOR = vec4(dst / 255.0, silhouette(local_pos));
}
