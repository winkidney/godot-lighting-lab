// Unshaded visualisation of every vector involved in normal mapping.
// Vectors are encoded as colour = v * 0.5 + 0.5 (so +X red, +Y green, +Z blue).
shader_type spatial;
render_mode unshaded;

#include "res://shaders/normal_common.gdshaderinc"

// 1 world normal, 2 view normal, 3 tangent, 4 binormal, 5 UV,
// 6 normal-map texel, 7 perturbed normal (world), 8 N·L
uniform int debug_mode = 1;
uniform vec3 light_dir_world = vec3(0.5, 0.7, 0.5);

vec3 encode(vec3 v) {
	return v * 0.5 + 0.5;
}

// ALBEDO is converted linear -> sRGB on output; pre-convert so the screen
// shows the exact encoded value (e.g. flat normal = 0.5, 0.5, 1.0).
vec3 to_linear(vec3 c) {
	c = clamp(c, 0.0, 1.0);
	return mix(c / 12.92, pow((c + 0.055) / 1.055, vec3(2.4)), step(vec3(0.04045), c));
}

void fragment() {
	vec2 uv = UV * uv_tiling * uv_aspect;
	vec3 N = normalize(NORMAL);
	vec3 T = safe_normalize(TANGENT);
	vec3 B = safe_normalize(BINORMAL);
	mat3 view_to_world = mat3(INV_VIEW_MATRIX);
	vec3 c = vec3(1.0, 0.0, 1.0);
	if (debug_mode == 1) {
		c = encode(view_to_world * N);
	} else if (debug_mode == 2) {
		c = encode(N);
	} else if (debug_mode == 3) {
		c = encode(view_to_world * T);
	} else if (debug_mode == 4) {
		c = encode(view_to_world * B);
	} else if (debug_mode == 5) {
		c = vec3(fract(uv), 0.0);
	} else if (debug_mode == 6) {
		c = use_normal_map ? sample_normal_texel(uv) : vec3(0.5, 0.5, 1.0);
	} else if (debug_mode == 7) {
		c = encode(view_to_world * perturb_normal(N, T, B, uv, VERTEX));
	} else if (debug_mode == 8) {
		vec3 P = view_to_world * perturb_normal(N, T, B, uv, VERTEX);
		c = vec3(max(dot(P, normalize(light_dir_world)), 0.0));
	}
	ALBEDO = to_linear(c);
}
