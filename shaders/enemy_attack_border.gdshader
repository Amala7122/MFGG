shader_type spatial;
render_mode unshaded, cull_disabled;

uniform vec4 border_color : source_color = vec4(1.0, 0.26, 0.06, 1.0);

void fragment() {
	// UV.y 从真实危险外沿指向范围内部；深色外沿与亮色内沿同时保持清晰。
	float inner = smoothstep(0.24, 0.34, UV.y);
	ALBEDO = mix(vec3(0.14, 0.008, 0.004), border_color.rgb, inner);
}
