shader_type spatial;
render_mode unshaded, cull_disabled, depth_draw_never;

uniform float daylight = 1.0;

void fragment() {
	vec2 p = UV * 2.0 - 1.0;
	float diamond = abs(p.x) + abs(p.y);
	float soft_edge = 1.0 - smoothstep(0.55, 0.98, diamond);
	ALBEDO = vec3(0.78, 0.84, 0.89);
	ALPHA = soft_edge * mix(0.08, 0.72, daylight);
}
