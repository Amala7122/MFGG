shader_type spatial;
render_mode cull_disabled, diffuse_burley;

// ============================================================================
// 工业界标准：低多边形渗流积雪着色器 (Low-Poly Percolation Snow Shader)
// 核心机制：
// 1. 世界空间迎雪面检测与休止角 (World Up Slope & Angle of Repose)
// 2. 连续 3D 世界空间噪声调制 (World Space 3D Noise)
// 3. 渗流阈值演变：稀疏小雪斑 -> 斑块扩张融合 -> 完整连片雪被
// 4. 几何厚度沿世界天顶外推抬升 (World-Up Height Extrusion)
// ============================================================================

// --- 积雪控制 ---
uniform float u_snow_amount : hint_range(0.0, 1.0) = 0.0;
uniform float u_max_thickness : hint_range(0.0, 0.4) = 0.16;
uniform float u_slope_threshold : hint_range(0.0, 1.0) = 0.32; // 休止角：低于此陡度无法积雪
uniform float u_noise_scale : hint_range(0.1, 10.0) = 1.6;

// --- 材质基底与雪色 ---
uniform vec3 u_base_color : source_color = vec3(0.36, 0.38, 0.40);
uniform float u_base_roughness : hint_range(0.0, 1.0) = 0.90;
uniform vec3 u_snow_color_sunlit : source_color = vec3(0.96, 0.98, 1.0);
uniform vec3 u_snow_color_shadow : source_color = vec3(0.66, 0.76, 0.88);
uniform float u_snow_roughness : hint_range(0.0, 1.0) = 0.94;

varying vec3 v_world_pos;
varying vec3 v_world_normal;
varying float v_snow_mask;

// --- 纯数学三维噪声（无外部纹理依赖，世界空间连续无拉伸） ---
vec3 hash33(vec3 p) {
	p = fract(p * vec3(0.1031, 0.1030, 0.0973));
	p += dot(p, p.yxz + 33.33);
	return fract((p.xxy + p.yxx) * p.zyx);
}

float noise3D(vec3 p) {
	vec3 i = floor(p);
	vec3 f = fract(p);
	f = f * f * (3.0 - 2.0 * f); // Hermite 平滑
	
	float n000 = dot(hash33(i + vec3(0.0, 0.0, 0.0)) - 0.5, f - vec3(0.0, 0.0, 0.0));
	float n100 = dot(hash33(i + vec3(1.0, 0.0, 0.0)) - 0.5, f - vec3(1.0, 0.0, 0.0));
	float n010 = dot(hash33(i + vec3(0.0, 1.0, 0.0)) - 0.5, f - vec3(0.0, 1.0, 0.0));
	float n110 = dot(hash33(i + vec3(1.0, 1.0, 0.0)) - 0.5, f - vec3(1.0, 1.0, 0.0));
	float n001 = dot(hash33(i + vec3(0.0, 0.0, 1.0)) - 0.5, f - vec3(0.0, 0.0, 1.0));
	float n101 = dot(hash33(i + vec3(1.0, 0.0, 1.0)) - 0.5, f - vec3(1.0, 0.0, 1.0));
	float n011 = dot(hash33(i + vec3(0.0, 1.0, 1.0)) - 0.5, f - vec3(0.0, 1.0, 1.0));
	float n111 = dot(hash33(i + vec3(1.0, 1.0, 1.0)) - 0.5, f - vec3(1.0, 1.0, 1.0));
	
	float nx00 = mix(n000, n100, f.x);
	float nx10 = mix(n010, n110, f.x);
	float nx01 = mix(n001, n101, f.x);
	float nx11 = mix(n011, n111, f.x);
	
	float nxy0 = mix(nx00, nx10, f.y);
	float nxy1 = mix(nx01, nx11, f.y);
	
	return mix(nxy0, nxy1, f.z) + 0.5;
}

float fbm3D(vec3 p) {
	float val = 0.0;
	val += 0.65 * noise3D(p);
	val += 0.35 * noise3D(p * 2.6 + vec3(1.7, 4.1, 2.3));
	return val;
}

// 4x4 Bayer 抖动矩阵
float bayer2(vec2 a) {
	a = floor(a);
	return fract(a.x * 0.5 + a.y * a.y * 0.75);
}

float bayer4(vec2 a) {
	return bayer2(0.5 * a) * 0.25 + bayer2(a);
}

void vertex() {
	v_world_pos = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
	v_world_normal = normalize(MODEL_NORMAL_MATRIX * NORMAL);

	if (u_snow_amount > 0.02) {
		// 1. 迎雪坡度检测（世界向上向量点乘）
		float up_slope = clamp(v_world_normal.y, 0.0, 1.0);
		float angle_factor = smoothstep(u_slope_threshold, u_slope_threshold + 0.32, up_slope);

		// 2. 宏观世界空间噪声
		float v_noise = fbm3D(v_world_pos * (u_noise_scale * 0.7));
		float potential = angle_factor * 0.72 + v_noise * 0.28;

		// 3. 动态渗流阈值：雪越多，被积雪攻陷的区域越大
		float threshold = mix(1.10, 0.15, smoothstep(0.02, 0.90, u_snow_amount));
		float v_snow = smoothstep(threshold, threshold + 0.18, potential);

		// 4. 几何物理厚度抬升（沿世界天顶 Y 向上顶高，形成多边形积雪隆起）
		vec3 world_lift = vec3(0.0, 1.0, 0.0) * (u_max_thickness * v_snow);
		VERTEX += (inverse(MODEL_MATRIX) * vec4(world_lift, 0.0)).xyz;
	}
}

void fragment() {
	// 1. 迎雪面休止角判定：陡峭悬崖（slope 小）自然滑落，永远裸露
	float up_slope = clamp(v_world_normal.y, 0.0, 1.0);
	float angle_factor = smoothstep(u_slope_threshold, u_slope_threshold + 0.28, up_slope);

	// 2. 微观多尺度噪声（微观粗糙凹坑）
	float noise = fbm3D(v_world_pos * u_noise_scale);

	// 3. 势能场构建
	float potential = angle_factor * 0.68 + noise * 0.32;

	// 4. 核心：动态渗流阈值演变 (Threshold Percolation)
	// u_snow_amount 很小 (0.05)：threshold 极高 (~1.1)，只有少数凹坑波峰能越过阈值，生成孤立小雪斑
	// u_snow_amount 递增 (0.35)：threshold 下降，斑块向外扩张、彼此接触相撞、融合为大雪块
	// u_snow_amount 饱和 (0.75+)：平缓面彻底融合成完整厚雪被，陡峭面依然露石
	float threshold = mix(1.12, 0.10, smoothstep(0.01, 0.88, u_snow_amount));

	// 低多边形晶体边缘：带有一点阶梯切沿，而不是模糊喷枪淡化
	float snow_mask = smoothstep(threshold - 0.05, threshold + 0.06, potential);

	// 萌生期边缘细微晶粒抖动
	if (u_snow_amount < 0.20 && snow_mask > 0.01 && snow_mask < 0.95) {
		float dither = bayer4(FRAGCOORD.xy);
		snow_mask = smoothstep(dither * 0.4, dither * 0.4 + 0.3, snow_mask);
	}

	// 5. 积雪边缘切沿厚度微阴影（提升 3D 体积感）
	float edge_rim = smoothstep(0.01, 0.20, snow_mask) * (1.0 - smoothstep(0.80, 0.99, snow_mask));
	vec3 edge_shade = vec3(1.0) - vec3(0.12, 0.10, 0.08) * edge_rim;

	// 6. 硬表面双色调 Flat-Shading（迎光冷白，背光冰蓝）
	float sunlit = clamp(v_world_normal.y * 0.45 + 0.55, 0.0, 1.0);
	vec3 snow_color = mix(u_snow_color_shadow, u_snow_color_sunlit, sunlit) * edge_shade;

	ALBEDO = mix(u_base_color, snow_color, snow_mask);
	ROUGHNESS = mix(u_base_roughness, u_snow_roughness, snow_mask);
	SPECULAR = mix(0.15, 0.04, snow_mask);
}
