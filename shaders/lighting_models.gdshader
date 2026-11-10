// Classic lighting models implemented in Godot's light() function, so every
// real light in the scene (with attenuation and shadows) drives them.
// light() runs once per light per pixel; the results are summed by the engine.
shader_type spatial;

// 0 Lambert, 1 Half-Lambert (wrap), 2 Phong, 3 Blinn-Phong, 4 Toon
uniform int model = 0;
// 0 full, 1 diffuse only, 2 specular only, 3 fresnel/rim term, 4 N·L, 5 N·H
uniform int term_view = 0;
uniform vec3 albedo : source_color = vec3(0.8, 0.35, 0.25);
uniform float shininess : hint_range(1.0, 1024.0) = 48.0;
uniform float specular_strength : hint_range(0.0, 4.0) = 0.6;
uniform bool energy_conserving = false;
uniform float wrap : hint_range(0.0, 1.0) = 0.5;
uniform int toon_steps : hint_range(1, 8) = 3;
uniform float toon_smooth : hint_range(0.0, 0.2) = 0.02;
uniform float rim_strength : hint_range(0.0, 2.0) = 0.0;
uniform float rim_power : hint_range(0.5, 16.0) = 4.0;

void fragment() {
	// For the term views we want pure numbers on screen: white albedo, AO = 0
	// removes ambient diffuse, SPECULAR = METALLIC = 0 removes ambient specular.
	bool raw = term_view != 0;
	ALBEDO = raw ? vec3(1.0) : albedo;
	ROUGHNESS = 1.0;
	SPECULAR = raw ? 0.0 : 0.5;
	METALLIC = 0.0;
	AO = raw ? 0.0 : 1.0;
	AO_LIGHT_AFFECT = 0.0;
}

// The term views show raw numbers; pre-convert so the screen (which applies
// linear -> sRGB) displays value 0.5 as mid grey instead of 188/255.
vec3 to_linear(vec3 c) {
	c = clamp(c, 0.0, 1.0);
	return mix(c / 12.92, pow((c + 0.055) / 1.055, vec3(2.4)), step(vec3(0.04045), c));
}

void light() {
	vec3 N = NORMAL;
	vec3 L = LIGHT;
	vec3 V = VIEW;
	vec3 H = normalize(L + V);
	float n_dot_l = dot(N, L);
	float n_dot_h = max(dot(N, H), 0.0);
	float n_dot_v = max(dot(N, V), 0.0);
	// LIGHT_COLOR already contains energy * PI, hence the / PI.
	vec3 radiance = LIGHT_COLOR * ATTENUATION / PI;
	float lit = step(0.0, n_dot_l);

	float diff = 0.0;
	float spec = 0.0;
	if (model == 0) {
		diff = max(n_dot_l, 0.0);
		spec = 0.0;
	} else if (model == 1) {
		// Valve's Half-Lambert generalised: remap [-1,1] -> [1-wrap, 1], square.
		float w = n_dot_l * wrap + (1.0 - wrap);
		diff = max(w, 0.0) * max(w, 0.0);
	} else if (model == 2) {
		diff = max(n_dot_l, 0.0);
		vec3 R = reflect(-L, N);
		float norm = energy_conserving ? (shininess + 2.0) / 2.0 : 1.0;
		spec = pow(max(dot(R, V), 0.0), shininess) * norm * lit;
	} else if (model == 3) {
		diff = max(n_dot_l, 0.0);
		float norm = energy_conserving ? (shininess + 8.0) / 8.0 : 1.0;
		spec = pow(n_dot_h, shininess) * norm * lit;
	} else {
		float s = float(toon_steps);
		float x = max(n_dot_l, 0.0) * s;
		diff = n_dot_l > 0.0 ? (floor(x) + smoothstep(0.0, max(toon_smooth * s, 1e-4), fract(x))) / s : 0.0;
		spec = smoothstep(0.5 - toon_smooth, 0.5 + toon_smooth, pow(n_dot_h, shininess)) * lit;
	}
	float rim = rim_strength * pow(1.0 - n_dot_v, rim_power);

	if (term_view == 0) {
		DIFFUSE_LIGHT += radiance * diff;
		SPECULAR_LIGHT += radiance * (spec * specular_strength + rim);
	} else if (term_view == 1) {
		DIFFUSE_LIGHT += radiance * diff;
	} else if (term_view == 2) {
		DIFFUSE_LIGHT += radiance * spec * specular_strength;
	} else if (LIGHT_IS_DIRECTIONAL) {
		// Raw geometric terms: only the key (directional) light, no colour.
		float t = term_view == 3 ? pow(1.0 - n_dot_v, rim_power) : (term_view == 4 ? max(n_dot_l, 0.0) : n_dot_h);
		DIFFUSE_LIGHT += to_linear(vec3(t));
	}
}
