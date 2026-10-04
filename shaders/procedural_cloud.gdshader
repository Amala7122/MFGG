shader_type spatial;
render_mode unshaded, fog_disabled;

uniform vec4 cloud_tint : source_color = vec4(0.78, 0.82, 0.86, 1.0);
uniform vec4 overcast_tint : source_color = vec4(0.67, 0.71, 0.75, 1.0);
uniform float cloud_density = 0.5;
uniform float overcast_blend = 0.0;
uniform float cloud_time = 0.0;
uniform float deformation_amount = 0.0;
varying float tint_variation;

void vertex() {
	// 可选轻微 GPU 变形；零值完全关闭，不重建或上传网格。
	float phase = INSTANCE_CUSTOM.x * 6.283185;
	float edge = smoothstep(0.0, 40.0, abs(VERTEX.x));
	VERTEX.y += sin(VERTEX.x * 0.027 + phase + cloud_time * 0.12)
		* deformation_amount * 20.0 * edge;
	tint_variation = INSTANCE_CUSTOM.y;
}

void fragment() {
	vec3 bank = pow(COLOR.rgb, vec3(2.2)) * cloud_tint.rgb;
	bank *= mix(1.0, 0.85, cloud_density) * mix(0.96, 1.04, tint_variation);
	vec3 deck = overcast_tint.rgb * mix(1.03, 0.90, cloud_density);
	ALBEDO = mix(bank, deck, overcast_blend * 0.75);
	METALLIC = 0.0;
	ROUGHNESS = 1.0;
}
