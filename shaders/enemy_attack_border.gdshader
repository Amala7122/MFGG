shader_type spatial;
render_mode unshaded, cull_disabled;

uniform vec4 border_color : source_color = vec4(1.0, 0.26, 0.06, 1.0);
uniform bool solid_footprint = false;

void fragment() {
	// UV.y 从真实危险外沿指向范围内部；深色外沿与亮色内沿同时保持清晰。
	float inner = smoothstep(0.24, 0.34, UV.y);
	ALBEDO = mix(vec3(0.14, 0.008, 0.004), border_color.rgb, inner);
	if (solid_footprint) {
		// 黑外沿/浅色内沿都在真实危险面内，不向安全侧扩张。
		ALBEDO = mix(vec3(0.035, 0.008, 0.004), vec3(1.0, 0.74, 0.46), inner);
	}
}
