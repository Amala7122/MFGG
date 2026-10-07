shader_type spatial;
render_mode unshaded, cull_disabled, fog_disabled;

uniform float cloud_time = 0.0;
uniform float cloud_coverage = 0.0;
uniform float cloud_density = 0.5;
uniform float overcast_blend = 0.0;
uniform vec4 cloud_tint : source_color = vec4(0.13, 0.18, 0.27, 1.0);
uniform vec4 overcast_tint : source_color = vec4(0.46, 0.50, 0.55, 1.0);

void vertex() {
	// 保留旧低模云的慢漂移。进入转阴阶段后不是直接淡掉，而是把同一批云
	// 横向摊开、减少上下鼓动，让独立云团逐渐接近一整层云底的形态。
	float melt = clamp(overcast_blend, 0.0, 1.0);
	float phase = VERTEX.x * 0.008 + VERTEX.z * 0.011;
	float horizontal_spread = mix(6.0, 14.0, melt);
	float vertical_relief = mix(5.0, 1.25, melt);
	float depth_spread = mix(4.0, 8.0, melt);
	VERTEX.x += sin(phase + cloud_time * 0.11) * horizontal_spread;
	VERTEX.y += sin(phase * 1.37 + cloud_time * 0.16) * vertical_relief;
	VERTEX.z += cos(phase * 0.81 + cloud_time * 0.09) * depth_spread;
}

void fragment() {
	// 旧云本身就是低反光的美术色块。整个融化过程只在漫射色之间插值，
	// 不引入太阳高光、银边或体积 Mie 亮斑，避免变成天空里的塑料块。
	vec3 bank_color = pow(COLOR.rgb, vec3(2.2)) * cloud_tint.rgb;
	float density_darkening = mix(1.0, 0.82, clamp(cloud_density, 0.0, 1.0));
	bank_color *= density_darkening;
	vec3 deck_color = overcast_tint.rgb * mix(1.03, 0.90, clamp(cloud_density, 0.0, 1.0));
	ALBEDO = mix(bank_color, deck_color, clamp(overcast_blend, 0.0, 1.0) * 0.90);
	METALLIC = 0.0;
	ROUGHNESS = 1.0;
}
