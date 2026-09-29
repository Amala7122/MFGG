shader_type spatial;
render_mode unshaded, cull_disabled, fog_disabled;

uniform float cloud_time = 0.0;
uniform vec4 cloud_tint : source_color = vec4(0.13, 0.18, 0.27, 1.0);

void vertex() {
	// 同一世界坐标得到同一位移：低模面之间不会因形变裂开。
	float phase = VERTEX.x * 0.008 + VERTEX.z * 0.011;
	VERTEX.x += sin(phase + cloud_time * 0.11) * 6.0;
	VERTEX.y += sin(phase * 1.37 + cloud_time * 0.16) * 5.0;
	VERTEX.z += cos(phase * 0.81 + cloud_time * 0.09) * 4.0;
}

void fragment() {
	// 顶点色是美术面色；不再叠加方向光形成“悬浮实体”的硬亮暗面。
	ALBEDO = pow(COLOR.rgb, vec3(2.2)) * cloud_tint.rgb;
	ROUGHNESS = 1.0;
}
