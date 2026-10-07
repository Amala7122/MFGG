shader_type spatial;
render_mode cull_disabled;

// 降雪量：0.0 = 无雪，0.2 = 顶面与平缓迎雪面结霜，0.5 = 顺迎雪坡面漫延，0.8 = 全面增厚压顶
uniform float u_snow_amount : hint_range(0.0, 1.0) = 0.0;
// 最大物理厚度外推米数
uniform float u_max_thickness : hint_range(0.0, 0.8) = 0.22;
// 基础冷暖色
uniform vec3 u_color_sunlit : source_color = vec3(0.96, 0.98, 1.0);
uniform vec3 u_color_shadow : source_color = vec3(0.66, 0.76, 0.88);

varying float v_accum_priority;

// 4x4 Bayer 抖动矩阵，与项目 grass.gdshader 统一
float bayer2(vec2 a) {
	a = floor(a);
	return fract(a.x * 0.5 + a.y * a.y * 0.75);
}

float bayer4(vec2 a) {
	return bayer2(0.5 * a) * 0.25 + bayer2(a);
}

void vertex() {
	// 迎雪面累积优先级：
	// 综合法线向上程度 (迎雪坡度) 与相对高度，平坦顶面优先级最高，下垂斜边最低
	float up_slope = clamp(NORMAL.y, 0.0, 1.0);
	float height_norm = clamp(VERTEX.y * 0.45 + 0.45, 0.0, 1.0);
	v_accum_priority = clamp(up_slope * 0.60 + height_norm * 0.40, 0.0, 1.0);

	// 局部厚度生长：随着降雪量增加，迎雪面最先增厚隆起，下坡边缘随后膨胀
	float local_grow = smoothstep(0.12, 0.82, u_snow_amount) * smoothstep(0.15, 0.65, v_accum_priority);

	// 保持坐标单值连续外扩，杜绝低多边形非共享顶点拉扯撕裂
	vec2 radial = length(VERTEX.xz) > 0.0001 ? normalize(VERTEX.xz) : vec2(0.0);
	VERTEX.xz += radial * (u_max_thickness * 0.42 * local_grow);
	VERTEX.y += (VERTEX.y * 0.20 + 0.65) * (u_max_thickness * local_grow);
}

void fragment() {
	if (u_snow_amount <= 0.003) {
		discard;
	}

	// 贴着迎雪面“自上而下”逐渐累积：
	// 门限随 u_snow_amount 下降，雪从顶峰和平缓面首先出现，再逐渐沿着坡度漫延到下边缘
	float spread_threshold = 1.08 - u_snow_amount * 1.25;
	float snow_coverage = smoothstep(spread_threshold, spread_threshold + 0.22, v_accum_priority);

	if (snow_coverage <= 0.005 || snow_coverage < bayer4(FRAGCOORD.xy)) {
		discard;
	}

	// 硬表面低多边形着色：利用法线 Y 分量区分迎天光冷白与侧边冰蓝阴影
	float up_facing = clamp(NORMAL.y, 0.0, 1.0);
	ALBEDO = mix(u_color_shadow, u_color_sunlit, smoothstep(0.15, 0.75, up_facing));
	ROUGHNESS = 0.94;
	SPECULAR = 0.05;
}
