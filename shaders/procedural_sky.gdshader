shader_type sky;
// 程序化阴天分层天空。
//
// ── 为什么不用内置 ProceduralSkyMaterial ────────────────────────
//
// 它只能给出"两段渐变 + 一个太阳盘"，而目标要的是【一张巨大的明暗构图】：
// 顶部深灰蓝 → 中层灰蓝 → 地平线略亮，再叠一层低频云，让天空自己
// 分成大块的亮与暗。这是内置材质做不到的。
//
// ── 为什么不采样任何贴图 ────────────────────────────────────────
//
// 云只用纯数学值噪声（hash → value noise → 3 个八度 fbm）。
// 这样天空不引入任何外部资产，也符合"禁止贴图细节"的约束。
//
// ── 为什么刻意不用 TIME ─────────────────────────────────────────
//
// 视觉迭代靠"同一条件下拍同一张图"来比较。云一动，两个轮次的截图就
// 差在随机相位上，没法判断"是变了还是飘了"。所以云层是静止的。
//
// ── 三件事决定天空读起来对不对 ──────────────────────────────────
//
// 1. 云必须是【低频】的。高频噪声会变成一层灰雾，而不是大块明暗。
// 2. 云必须有【垂直包络】。不做包络的话，地平线会出现一条硬边、
//    天顶会糊成一片，两头都穿帮。
// 3. 地平线必须有一条【亮带】。地景剪影需要一块稳定的高对比底板，
//    这也是"天空比地面亮"这条要求的真正用处。

uniform vec4 u_top_color : source_color = vec4(0.20, 0.25, 0.33, 1.0);
uniform vec4 u_mid_color : source_color = vec4(0.38, 0.44, 0.52, 1.0);
uniform vec4 u_horizon_color : source_color = vec4(0.62, 0.66, 0.70, 1.0);
uniform vec4 u_ground_color : source_color = vec4(0.30, 0.31, 0.31, 1.0);
uniform float u_mid_stop : hint_range(0.01, 0.99) = 0.34;
uniform float u_horizon_width : hint_range(0.001, 0.5) = 0.10;
uniform float u_horizon_gain : hint_range(0.0, 2.0) = 0.35;

uniform vec4 u_cloud_light : source_color = vec4(0.72, 0.74, 0.78, 1.0);
uniform vec4 u_cloud_shadow : source_color = vec4(0.22, 0.26, 0.33, 1.0);
uniform float u_cloud_amount : hint_range(0.0, 1.0) = 0.50;
uniform float u_cloud_scale : hint_range(0.1, 8.0) = 2.60;
uniform float u_cloud_flatten : hint_range(0.10, 1.0) = 0.42;
uniform float u_cloud_threshold : hint_range(0.0, 1.0) = 0.36;
uniform float u_cloud_sharpness : hint_range(0.01, 1.0) = 0.26;
uniform float u_cloud_floor : hint_range(0.0, 0.5) = 0.06;
uniform float u_cloud_ceiling : hint_range(0.2, 1.0) = 0.88;

uniform vec4 u_sun_glow : source_color = vec4(0.86, 0.82, 0.72, 1.0);
uniform float u_sun_glow_power : hint_range(1.0, 64.0) = 14.0;
uniform float u_sun_glow_strength : hint_range(0.0, 1.0) = 0.06;
// 指向太阳的单位向量，由 graphics_director.gd 从场景里的 Sun 节点算出。
// 刻意不读 sky shader 的 LIGHT0_* 内置量：那会引入一处编译期依赖，
// 而这里的太阳本来只是"一片很软的方向性提亮"，不值得为它赌兼容性。
uniform vec3 u_sun_direction = vec3(0.0, 1.0, 0.0);


float hash31(vec3 p) {
	p = fract(p * vec3(0.1031, 0.1030, 0.0973));
	p += dot(p, p.yxz + 33.33);
	return fract((p.x + p.y) * p.z);
}


float value_noise3(vec3 p) {
	vec3 i = floor(p);
	vec3 f = fract(p);
	// 平滑插值：不平滑会看到网格状的人工痕迹。
	f = f * f * (3.0 - 2.0 * f);
	float n000 = hash31(i);
	float n100 = hash31(i + vec3(1.0, 0.0, 0.0));
	float n010 = hash31(i + vec3(0.0, 1.0, 0.0));
	float n110 = hash31(i + vec3(1.0, 1.0, 0.0));
	float n001 = hash31(i + vec3(0.0, 0.0, 1.0));
	float n101 = hash31(i + vec3(1.0, 0.0, 1.0));
	float n011 = hash31(i + vec3(0.0, 1.0, 1.0));
	float n111 = hash31(i + vec3(1.0, 1.0, 1.0));
	float x00 = mix(n000, n100, f.x);
	float x10 = mix(n010, n110, f.x);
	float x01 = mix(n001, n101, f.x);
	float x11 = mix(n011, n111, f.x);
	return mix(mix(x00, x10, f.y), mix(x01, x11, f.y), f.z);
}


// 三个八度足够形成大块明暗；再加八度只会细化成"雾"而不是"云"。
float fbm3(vec3 p) {
	float total = 0.0;
	float amplitude = 0.5;
	for (int i = 0; i < 3; i++) {
		total += amplitude * value_noise3(p);
		p *= 2.03;
		amplitude *= 0.5;
	}
	return total;
}


void sky() {
	vec3 dir = normalize(EYEDIR);
	float height = dir.y;

	// 【取样必须在球面方向上做，不能用 xz/y 的平面投影】
	// 平面投影会把噪声的网格沿天顶方向收敛成放射状直线，云变成一片
	// 硬边三角楔（实测截图里就是"玻璃碎片"的样子）。
	// 直接拿方向向量取样没有奇点、没有接缝；把 y 压扁则让云呈"层状"，
	// 而不是一个个孤立的球团 —— 阴天要的正是一整片厚而平的云盖。
	vec3 sample_pos = dir * vec3(u_cloud_scale, u_cloud_scale * u_cloud_flatten, u_cloud_scale);

	// 【云必须用两条独立的噪声，不能用一条】
	// 最初用同一个 shape 同时驱动"哪里有云"和"这块云是亮是暗"，结果是：
	// 暗的那部分（shape 小）权重也小，被乘成几乎不可见；画面只剩几团
	// 与天空本身明度差不多的浅云，看起来就像"云根本没生效"。
	// 现在分成两层 —— coverage 决定云的存在，tonality 只决定云内的大块明暗。
	float coverage = smoothstep(
		u_cloud_threshold, u_cloud_threshold + u_cloud_sharpness, fbm3(sample_pos)
	);
	float tonality = smoothstep(0.22, 0.78, fbm3(sample_pos * 0.55 + vec3(19.7, 47.3, 11.1)));

	// 垂直包络：中天空最厚，近地平线与近天顶都收掉。
	float envelope = smoothstep(u_cloud_floor, u_cloud_floor + 0.25, height)
		* (1.0 - smoothstep(u_cloud_ceiling - 0.25, u_cloud_ceiling, height));

	vec3 cloud = mix(u_cloud_shadow.rgb, u_cloud_light.rgb, tonality);
	float cloud_weight = clamp(coverage * envelope * u_cloud_amount, 0.0, 1.0);

	// 三段垂直分层。地平线以下用地面色，避免从低角度往外看时
	// 看到一片"亮天空贴在地平面下"。
	vec3 base;
	if (height >= 0.0) {
		float t = clamp(height, 0.0, 1.0);
		vec3 lower = mix(u_horizon_color.rgb, u_mid_color.rgb, smoothstep(0.0, u_mid_stop, t));
		vec3 upper = mix(u_mid_color.rgb, u_top_color.rgb, smoothstep(u_mid_stop, 1.0, t));
		base = t < u_mid_stop ? lower : upper;
		float band = 1.0 - smoothstep(0.0, u_horizon_width, t);
		base = mix(base, u_horizon_color.rgb, band * u_horizon_gain);
	} else {
		base = mix(u_horizon_color.rgb, u_ground_color.rgb, smoothstep(0.0, -0.25, height));
	}

	vec3 color = mix(base, cloud, cloud_weight);

	// 阴天的太阳不是圆盘，只是一片很软的方向性提亮。
	float sun = max(dot(dir, normalize(u_sun_direction)), 0.0);
	color += u_sun_glow.rgb * pow(sun, u_sun_glow_power) * u_sun_glow_strength;

	// 【注意】sky shader 的 COLOR 是 vec3，不是 vec4 —— 透明由单独的
	// ALPHA 输出控制。写成 vec4 会直接编译失败（4.7 实测）。
	COLOR = color;
	ALPHA = 1.0;
}
