shader_type spatial;
render_mode cull_back, depth_draw_opaque;

varying vec3 water_position;

void vertex() {
	water_position = VERTEX;
}

void fragment() {
	// Vertex alpha marks turbulence over each rock step, not opacity.
	float whitewater = 1.0 - COLOR.a;
	vec3 base = mix(vec3(0.08, 0.28, 0.35), vec3(0.30, 0.54, 0.62), whitewater);
	float current = sin(water_position.z * 1.42 - TIME * 4.8
		+ sin(water_position.x * 0.57) * 1.3);
	float breakup = current * sin(water_position.x * 1.17
		+ water_position.z * 0.39 - TIME * 2.1);
	float foam = smoothstep(0.05, 0.70, breakup + 0.28 * current) * whitewater;
	float small_foam = smoothstep(0.56, 0.92, sin(water_position.x * 2.4
		- water_position.z * 2.1 + TIME * 5.7)) * whitewater;
	vec3 color = mix(base, vec3(0.85, 0.94, 0.95),
		clamp(0.18 * whitewater + 0.58 * foam + 0.16 * small_foam, 0.0, 0.84));
	float ripple = sin(water_position.x * 0.44 + TIME * 1.4)
		* sin(water_position.z * 0.62 - TIME * 1.15);
	color += vec3(0.025, 0.045, 0.047) * smoothstep(0.60, 0.93, ripple) * (1.0 - whitewater);
	ALBEDO = color;
	ROUGHNESS = mix(0.76, 0.49, whitewater);
	SPECULAR = 0.17;
}
