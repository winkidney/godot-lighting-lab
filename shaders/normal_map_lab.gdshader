// Lit material with hand-written tangent-space normal mapping.
shader_type spatial;

#include "res://shaders/normal_common.gdshaderinc"

uniform vec3 albedo : source_color = vec3(0.8);
uniform float roughness : hint_range(0.0, 1.0) = 0.55;
uniform float metallic : hint_range(0.0, 1.0) = 0.0;

void fragment() {
	vec2 uv = UV * uv_tiling * uv_aspect;
	ALBEDO = albedo;
	ROUGHNESS = roughness;
	METALLIC = metallic;
	NORMAL = perturb_normal(normalize(NORMAL), safe_normalize(TANGENT), safe_normalize(BINORMAL), uv, VERTEX);
}
