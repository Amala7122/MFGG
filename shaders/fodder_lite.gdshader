shader_type spatial;
render_mode blend_mix, depth_draw_opaque, cull_back, diffuse_burley, specular_schlick_ggx;

uniform vec4 base_color : source_color = vec4(0.28, 0.32, 0.22, 1.0);
uniform vec4 core_color : source_color = vec4(0.10, 0.85, 0.90, 1.0);
uniform float bob_amplitude = 0.045;
uniform float bob_speed = 7.0;

varying vec3 v_flash;
varying float v_core;

void vertex() {
	float phase = INSTANCE_CUSTOM.x;
	float t = TIME * bob_speed + phase;
	// 整只炮灰一个网格：只做整体起伏和轻微左右摆，不再拆 6 个肢体节点。
	VERTEX.y += sin(t) * bob_amplitude;
	VERTEX.x += cos(t * 0.5) * bob_amplitude * 0.25;
	v_flash = vec3(INSTANCE_CUSTOM.y, 0.0, 0.0);
	v_core = INSTANCE_CUSTOM.z;
}

void fragment() {
	vec3 color = mix(base_color.rgb, core_color.rgb, step(0.5, v_core));
	ALBEDO = color;
	ROUGHNESS = 0.92;
	SPECULAR = 0.15;
	EMISSION = vec3(1.0, 0.18, 0.06) * v_flash.x;
}
