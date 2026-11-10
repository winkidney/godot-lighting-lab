// Shared normal-mapping code for normal_map_lab (lit) and normal_debug
// (visualisation). Mirrors what Godot's StandardMaterial3D does internally,
// but every step is explicit so each stage can be inspected or broken on purpose.

uniform bool use_normal_map = false;
// hint_normal: sampled as raw linear data (correct for normal maps).
uniform sampler2D normal_tex : hint_normal, filter_linear_mipmap_anisotropic, repeat_enable;
// Same texture, but declared as colour data: the GPU applies sRGB -> linear on
// sampling, which is the classic "normal map imported as a colour texture" bug.
uniform sampler2D normal_tex_srgb : source_color, filter_linear_mipmap_anisotropic, repeat_enable;
uniform sampler2D height_tex : hint_default_black, filter_linear_mipmap, repeat_enable;
uniform float normal_strength : hint_range(0.0, 4.0) = 1.0;
uniform bool flip_green = false;
uniform bool wrong_color_space = false;
uniform bool bump_mode = false;
uniform float bump_scale : hint_range(0.0, 0.3) = 0.04;
uniform float uv_tiling : hint_range(0.25, 8.0) = 2.0;
// Per-object UV aspect fix so texels stay square (e.g. a 9 x 3.4 m wall).
uniform vec2 uv_aspect = vec2(1.0);

vec3 safe_normalize(vec3 v) {
	float len = length(v);
	return len > 1e-6 ? v / len : vec3(0.0);
}

// Raw texel of the tangent-space normal map, in [0, 1].
vec3 sample_normal_texel(vec2 uv) {
	return wrong_color_space ? texture(normal_tex_srgb, uv).rgb : texture(normal_tex, uv).rgb;
}

// Returns the perturbed normal in view space.
// N, T, B are the interpolated geometric normal / tangent / binormal (view space).
vec3 perturb_normal(vec3 N, vec3 T, vec3 B, vec2 uv, vec3 vertex_vs) {
	if (!use_normal_map) {
		return N;
	}
	if (bump_mode) {
		// Bump mapping from a height map with screen-space derivatives
		// (Mikkelsen 2010): no tangents and no normal map needed.
		float h = texture(height_tex, uv).r * bump_scale;
		vec3 dpdx = dFdx(vertex_vs);
		vec3 dpdy = dFdy(vertex_vs);
		float dhdx = dFdx(h);
		float dhdy = dFdy(h);
		vec3 r1 = cross(dpdy, N);
		vec3 r2 = cross(N, dpdx);
		float det = dot(dpdx, r1);
		vec3 grad = sign(det) * (dhdx * r1 + dhdy * r2);
		return normalize(abs(det) * N - grad);
	}
	vec3 n = sample_normal_texel(uv);
	n.xy = n.xy * 2.0 - 1.0;
	if (flip_green) {
		n.y = -n.y;
	}
	// Rebuild Z from XY like Godot does (normal maps may be stored as RG only).
	n.z = sqrt(max(0.0, 1.0 - dot(n.xy, n.xy)));
	// Tangent space -> view space through the TBN basis, then blend by strength.
	vec3 mapped = T * n.x + B * n.y + N * n.z;
	return safe_normalize(mix(N, mapped, normal_strength));
}
