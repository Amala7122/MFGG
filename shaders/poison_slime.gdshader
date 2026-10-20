shader_type spatial;
render_mode unshaded, cull_disabled, depth_draw_never;
uniform float radius = 4.0;
uniform float age = 0.0;
uniform float opacity : hint_range(0.0, 1.0) = 1.0;

void fragment() {
	float r = length(UV) / max(radius, 0.001);
	float vein = sin(UV.x * 3.1 + sin(UV.y * 2.3) + age * 0.8)
		* sin(UV.y * 3.7 - cos(UV.x * 1.9) - age * 0.6);
	float membrane = smoothstep(0.83, 0.98, r);
	float foam = smoothstep(0.72, 0.93, vein);
	ALBEDO = mix(vec3(0.045, 0.19, 0.012), vec3(0.18, 0.56, 0.018), vein * 0.25 + 0.55);
	ALBEDO = mix(ALBEDO, vec3(0.54, 0.86, 0.045), max(membrane * 0.85, foam * 0.8));
	ALPHA = (0.88 + membrane * 0.10) * opacity;
}
