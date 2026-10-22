shader_type spatial;
render_mode diffuse_burley, specular_disabled;

// One shared material per geometry family, with independent hit flashes
// supplied by MultiMesh custom data. No per-enemy material duplication.
uniform vec4 base_color : source_color = vec4(0.28, 0.32, 0.22, 1.0);
uniform float roughness_value : hint_range(0.0, 1.0) = 0.95;
uniform float glow_strength : hint_range(0.0, 5.0) = 0.0;
varying float hit_flash;

void vertex() {
	hit_flash = INSTANCE_CUSTOM.r;
}

void fragment() {
	float amount = clamp(hit_flash, 0.0, 1.0);
	ALBEDO = mix(base_color.rgb, vec3(1.0, 0.025, 0.015), amount);
	ROUGHNESS = roughness_value;
	EMISSION = base_color.rgb * glow_strength + vec3(0.7, 0.02, 0.01) * amount * 0.65;
}
