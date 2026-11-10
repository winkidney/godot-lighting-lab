// Custom full-screen post-processing on a CanvasLayer ColorRect.
// Reads the already tonemapped 3D image (sRGB) and adds lens/film effects that
// Godot's Environment does not provide: vignette, grain, chromatic aberration,
// tint and shadow lift.
shader_type canvas_item;

uniform sampler2D screen_tex : hint_screen_texture, filter_linear_mipmap;
uniform float vignette_strength : hint_range(0.0, 1.5) = 0.0;
uniform float vignette_radius : hint_range(0.2, 1.5) = 0.8;
uniform float vignette_softness : hint_range(0.05, 1.0) = 0.5;
uniform float grain_amount : hint_range(0.0, 0.5) = 0.0;
uniform float chromatic_aberration : hint_range(0.0, 4.0) = 0.0;
uniform vec3 tint_color : source_color = vec3(1.0);
uniform float tint_strength : hint_range(0.0, 1.0) = 0.0;
uniform vec3 lift_color : source_color = vec3(0.0);
uniform float lift_strength : hint_range(0.0, 0.3) = 0.0;

// Dave Hoskins' hash12: stable for large pixel coordinates (a sin() based
// hash loses float precision there and shows diagonal stripes).
float hash(vec2 p) {
	vec3 p3 = fract(vec3(p.xyx) * 0.1031);
	p3 += dot(p3, p3.yzx + 33.33);
	return fract((p3.x + p3.y) * p3.z);
}

void fragment() {
	vec2 uv = SCREEN_UV;
	vec2 c = uv - 0.5;
	float aspect = SCREEN_PIXEL_SIZE.y / SCREEN_PIXEL_SIZE.x;
	float r = length(c * vec2(aspect, 1.0));

	// Chromatic aberration: R and B sampled with opposite radial offsets.
	vec2 off = c * chromatic_aberration * 0.01 * r;
	vec3 col;
	col.r = texture(screen_tex, uv + off).r;
	col.g = texture(screen_tex, uv).g;
	col.b = texture(screen_tex, uv - off).b;

	// Shadow lift: raises the darkest values towards lift_color.
	col += lift_color * lift_strength * (1.0 - col);
	col = mix(col, col * tint_color, tint_strength);

	float vig = smoothstep(vignette_radius, vignette_radius - vignette_softness, r);
	col *= mix(1.0, vig, clamp(vignette_strength, 0.0, 1.0));
	col *= 1.0 - max(vignette_strength - 1.0, 0.0) * (1.0 - vig);

	float frame = mod(floor(TIME * 24.0), 512.0);
	float n = hash(floor(uv / SCREEN_PIXEL_SIZE) + vec2(frame * 13.0, frame * 7.0)) - 0.5;
	float lum = dot(col, vec3(0.2126, 0.7152, 0.0722));
	col += n * grain_amount * (1.0 - 0.6 * lum);

	COLOR = vec4(col, 1.0);
}
