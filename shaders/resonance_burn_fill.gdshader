shader_type spatial;
render_mode unshaded, cull_disabled, depth_draw_never;

void fragment() {
	float ember = sin(UV.x * 4.0 + TIME * 3.0) * sin(UV.y * 3.0 - TIME * 2.0);
	ALBEDO = mix(vec3(0.85, 0.16, 0.015), vec3(1.0, 0.52, 0.055), ember * 0.5 + 0.5);
	ALPHA = 0.24 + ember * 0.06;
}
