shader_type spatial;
render_mode unshaded, cull_disabled, depth_draw_never;

// INSTANCE_CUSTOM：r=归一化年龄，g=亮度，b=第二道细环的随机相位，
// a=当前雨量等级。雨越大，水花越粗、中心落点越清楚；小雨几乎不留痕。
// 每个落点是一张顺着地形法线铺下去的低成本四边形；只画两道破碎细环，
// 不做写实水花贴图，避免与低多边形世界产生材质语言冲突。
uniform sampler2D screen_texture : hint_screen_texture, filter_linear_mipmap;
varying vec4 v_impact_data;

void vertex() {
	v_impact_data = INSTANCE_CUSTOM;
}

void fragment() {
	float age = v_impact_data.r;
	float rain_level = clamp(v_impact_data.a, 0.0, 1.0);
	if (age >= 1.0) {
		discard;
	}
	vec2 p = UV * 2.0 - 1.0;
	float radius = length(p);
	float growth = smoothstep(0.0, 1.0, age);
	float ring_radius = mix(0.08, 0.92, growth);
	float ring_width = mix(0.070, 0.155, rain_level);
	float ring = 1.0 - smoothstep(ring_width * 0.24, ring_width,
		abs(radius - ring_radius));
	float echo_radius = mix(0.02, 0.68, clamp(age * 1.25 - 0.12, 0.0, 1.0));
	float echo_width = mix(0.045, 0.105, rain_level);
	float echo = (1.0 - smoothstep(echo_width * 0.25, echo_width,
		abs(radius - echo_radius))) * mix(0.22, 0.48, rain_level);
	// 让圆环缺几小段，不像规则 UI 圆圈贴在地上。
	float broken = smoothstep(-0.55, 0.15,
		sin(atan(p.y, p.x) * 5.0 + v_impact_data.b * 6.28318));
	// 暴雨不是只有更多圆环：落地瞬间先给一个短促、实心的亮斑和五瓣冠状水花，
	// 中雨已经可读，豪雨与暴雨才会明显跳出来。
	float early = 1.0 - smoothstep(0.0, 0.24, age);
	float center = (1.0 - smoothstep(0.03, mix(0.19, 0.34, rain_level), radius))
		* early;
	float crown_angle = sin(atan(p.y, p.x) * 5.0 + v_impact_data.b * 6.28318);
	float crown = pow(max(crown_angle, 0.0), 5.0)
		* (1.0 - smoothstep(0.10, 0.62, radius)) * early * rain_level;
	float fade = pow(1.0 - age, 1.8);
	vec3 behind = textureLod(screen_texture, SCREEN_UV, 1.5).rgb;
	float luminance = dot(behind, vec3(0.2126, 0.7152, 0.0722));
	float illumination = smoothstep(0.025, 0.28, luminance);
	float ripple = max(ring * mix(0.48, 1.0, broken), echo);
	float splash = max(center * mix(0.22, 0.90, rain_level), crown * 0.70);
	float alpha = max(ripple, splash) * fade * v_impact_data.g * illumination;
	if (alpha < 0.012) {
		discard;
	}
	ALBEDO = mix(vec3(0.40, 0.59, 0.69), vec3(0.64, 0.82, 0.90), rain_level);
	ALPHA = alpha;
}
