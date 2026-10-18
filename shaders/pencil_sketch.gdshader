shader_type canvas_item;
render_mode unshaded;

// 读取屏幕原画缓冲
uniform sampler2D screen_texture : hint_screen_texture, filter_linear;

group_uniforms Style;
// 滤镜混合度 (0.0 = 原画, 1.0 = 纯手绘素描)
uniform float filter_blend : hint_range(0.0, 1.0, 0.01) = 1.0;
// 【黑白素描模式】：true = 纯黑白纸上素描速写, false = 彩铅插画
uniform bool monochrome_mode = false;
// 彩铅模式色彩饱和度 (0.0 = 黑白, 1.0 = 原画无损, 1.2~1.4 = 浓郁彩铅水彩, >1.5 = 艳丽插画)
uniform float color_saturation : hint_range(0.0, 2.5, 0.05) = 1.25;
// 色彩明暗对比度 (适度提升手绘通透感，避免中调发闷)
uniform float color_contrast : hint_range(0.5, 2.0, 0.05) = 1.05;
// 画纸泛黄晕染底色混入度 (0.0 = 纯原色无灰白雾气, 0.05 = 细腻自然纸底, 0.2+ = 复古牛皮纸)
uniform float paper_tint : hint_range(0.0, 0.5, 0.01) = 0.04;

group_uniforms VFX_And_Particle_Protection;
// 【保护粒子与自发光特效】：避免火花/子弹/爆炸被勾上黑圈或被压暗
uniform bool protect_vfx_particles = true;
// 特效识别灵敏度阈值 (低于此值的普通场景正常素描，高于此值的粒子与火光获得保护)
uniform float vfx_threshold : hint_range(0.6, 2.0, 0.02) = 0.92;
// 粒子光效在纸面上的透出亮度
uniform float vfx_glow_intensity : hint_range(0.5, 3.0, 0.1) = 1.2;
// 特效是否保留原色 (true = 像黑白漫画中的金色火花/发光法术保留彩色; false = 亮白发光粒子)
uniform bool keep_vfx_color = true;

// 新工程：红色信号保色启发式，不能区分红色场景材质与技能。
uniform bool preserve_red_signals = true;

group_uniforms Paper_Texture;
// 象牙白素描纸底色 (可调为复古牛皮纸色或冷白纸色)
uniform vec4 paper_color : source_color = vec4(0.95, 0.93, 0.88, 1.0);
// 铅笔石墨炭墨颜色
uniform vec4 pencil_color : source_color = vec4(0.12, 0.11, 0.10, 1.0);
// 【纸张纤维粗糙度】：模拟水彩纸/素描纸的棉浆凹凸纹理
uniform float paper_texture_strength : hint_range(0.0, 0.4, 0.01) = 0.16;
// 【纸张自然斑驳感】：模拟纸浆不均与微微泛黄晕染
uniform float paper_mottling : hint_range(0.0, 0.4, 0.01) = 0.12;
// 【画本暗角效果】：画纸四周自然微微收敛变暗的画幅质感
uniform float paper_vignette : hint_range(0.0, 1.0, 0.05) = 0.32;

group_uniforms Hand_Drawn_Outlines;
// 基础线条粗细 (像素)
uniform float line_thickness : hint_range(0.5, 4.0, 0.1) = 1.3;
// 轮廓勾线强度
uniform float edge_strength : hint_range(0.0, 10.0, 0.1) = 4.2;
// 轮廓线识别阈值
uniform float edge_threshold : hint_range(0.02, 0.5, 0.01) = 0.10;
// 【手绘抖动弯曲度】：线条手抖与微弧度
uniform float line_wobble : hint_range(0.0, 5.0, 0.1) = 1.8;
// 【压感与笔触毛边】：顿挫粗细与飞白断触
uniform float stroke_roughness : hint_range(0.0, 1.0, 0.05) = 0.35;
// 【草稿找形复线】：素描速写的叠笔草稿感
uniform float double_stroke : hint_range(0.0, 1.0, 0.05) = 0.45;

group_uniforms Shading_And_Hatching;
// 是否在深暗部启用细腻铅笔排线
uniform bool enable_hatching = true;
// 阴影排线起始阈值 (亮部留白，仅暗部排线)
uniform float shadow_threshold : hint_range(0.1, 0.6, 0.01) = 0.32;
// 排线疏密
uniform float hatch_density : hint_range(1.0, 10.0, 0.1) = 3.5;
// 漫画手绘阶梯色阶 (0 为连续平滑)
uniform int color_bands : hint_range(0, 8) = 4;


// ── 噪声函数群 ──

float hash21(vec2 p) {
	p = fract(p * vec2(234.34, 435.345));
	p += dot(p, p + 34.23);
	return fract(p.x * p.y);
}

float vnoise(vec2 p) {
	vec2 i = floor(p);
	vec2 f = fract(p);
	vec2 u = f * f * (3.0 - 2.0 * f);
	return mix(
		mix(hash21(i + vec2(0.0, 0.0)), hash21(i + vec2(1.0, 0.0)), u.x),
		mix(hash21(i + vec2(0.0, 1.0)), hash21(i + vec2(1.0, 1.0)), u.x),
		u.y
	);
}

float fbm(vec2 p) {
	return vnoise(p) * 0.65 + vnoise(p * 2.1) * 0.35;
}

float get_luminance(vec3 c) {
	return dot(c, vec3(0.299, 0.587, 0.114));
}

// 提取像素最大单通道强度与发光能量（亮度启发式，不是语义遮罩）
float get_vfx_energy(vec3 c) {
	return max(c.r, max(c.g, c.b));
}

// Sobel 边缘提取
float sample_sobel_edge(sampler2D tex, vec2 center_uv, vec2 step_size, float threshold, float strength) {
	vec3 c_tl = texture(tex, center_uv + vec2(-step_size.x, -step_size.y)).rgb;
	vec3 c_tc = texture(tex, center_uv + vec2(0.0, -step_size.y)).rgb;
	vec3 c_tr = texture(tex, center_uv + vec2(step_size.x, -step_size.y)).rgb;
	vec3 c_ml = texture(tex, center_uv + vec2(-step_size.x, 0.0)).rgb;
	vec3 c_mr = texture(tex, center_uv + vec2(step_size.x, 0.0)).rgb;
	vec3 c_bl = texture(tex, center_uv + vec2(-step_size.x, step_size.y)).rgb;
	vec3 c_bc = texture(tex, center_uv + vec2(0.0, step_size.y)).rgb;
	vec3 c_br = texture(tex, center_uv + vec2(step_size.x, step_size.y)).rgb;

	vec3 gx = (c_tr + 2.0 * c_mr + c_br) - (c_tl + 2.0 * c_ml + c_bl);
	vec3 gy = (c_bl + 2.0 * c_bc + c_br) - (c_tl + 2.0 * c_tc + c_tr);
	float edge_mag = (length(gx) + length(gy)) * strength * 0.25;
	return smoothstep(threshold, threshold + 0.16, edge_mag);
}


void fragment() {
	vec2 uv = SCREEN_UV;
	vec4 orig = texture(screen_texture, uv);

	// 分辨率无关的基准坐标 (基准 1080p)
	float res_scale = (1.0 / SCREEN_PIXEL_SIZE.y) / 1080.0;
	vec2 screen_coord = FRAGCOORD.xy / max(res_scale, 0.01);

	// ── 0. 粒子与自发光特效识别（VFX Detection） ──
	// 命中火花、激光、爆炸等发光特效通常带有极高的单通道能量或 HDR 强度
	float vfx_energy = get_vfx_energy(orig.rgb);
	float is_vfx = 0.0;
	if (protect_vfx_particles) {
		is_vfx = smoothstep(vfx_threshold - 0.1, vfx_threshold + 0.15, vfx_energy);
	}

	// ── 1. 物理素描纸质感生成 ──
	float fiber1 = vnoise(screen_coord * 0.14);
	float fiber2 = vnoise(screen_coord * 0.32 + vec2(17.8, 43.1));
	float paper_bump = (fiber1 * 0.6 + fiber2 * 0.4 - 0.5) * paper_texture_strength;
	float mottle = (fbm(screen_coord * 0.0035) - 0.5) * paper_mottling;

	vec2 v_uv = uv * (1.0 - uv);
	float v_val = v_uv.x * v_uv.y * 16.0;
	float vignette_factor = mix(1.0, clamp(pow(v_val, 0.2), 0.0, 1.0), paper_vignette);

	vec3 real_paper = paper_color.rgb * (1.0 + paper_bump + mottle) * vignette_factor;

	// ── 2. 手绘线条与压感系统 ──
	float pressure = mix(0.7, 1.35, fbm(screen_coord * 0.04));
	vec2 dynamic_texel = SCREEN_PIXEL_SIZE * (line_thickness * pressure);

	vec2 wobble_offset = vec2(
		fbm(screen_coord * 0.018),
		fbm(screen_coord * 0.018 + vec2(47.2, 23.5))
	) - 0.5;
	vec2 primary_uv = uv + wobble_offset * SCREEN_PIXEL_SIZE * (line_wobble * 2.2);

	// 植被/草地自适应描边优化：识别草绿自然区域，适度收敛微弱噪点，防止草丛内部碎线杂乱
	float veg_factor = clamp((orig.g - max(orig.r, orig.b) * 1.04) * 8.0, 0.0, 1.0);
	float effective_threshold = edge_threshold * (1.0 + veg_factor * 0.5);
	float effective_strength = edge_strength * (1.0 - veg_factor * 0.3);

	float primary_edge = sample_sobel_edge(
		screen_texture, primary_uv, dynamic_texel, effective_threshold, effective_strength
	);

	float secondary_edge = 0.0;
	if (double_stroke > 0.01) {
		vec2 ghost_offset = vec2(
			fbm(screen_coord * 0.024 + vec2(19.3, 81.7)),
			fbm(screen_coord * 0.024 + vec2(92.4, 34.6))
		) - 0.5;
		vec2 ghost_uv = uv + ghost_offset * SCREEN_PIXEL_SIZE * (line_wobble * 3.6);
		secondary_edge = sample_sobel_edge(
			screen_texture, ghost_uv, dynamic_texel * 0.85, effective_threshold * 1.15, effective_strength * 0.65
		);
	}

	float graphite_tooth = hash21(FRAGCOORD.xy * 0.75);
	float skip_mask = mix(1.0, graphite_tooth * 1.35, stroke_roughness);

	float combined_edge = max(primary_edge, secondary_edge * double_stroke);
	float edge = clamp(combined_edge * skip_mask, 0.0, 1.0);

	// 【核心修复】：对于发光粒子和火花，主动削减黑边！防止火花被画成一圈圈黑圆环
	if (protect_vfx_particles) {
		edge *= (1.0 - is_vfx * 0.95);
	}

	// ── 3. 明暗光影与五大调子提取 ──
	float lum = clamp(get_luminance(orig.rgb), 0.0, 1.0);
	if (color_bands > 0) {
		lum = floor(lum * float(color_bands) + 0.5) / float(color_bands);
	}

	// ── 4. 暗部自然铅笔排线 ──
	float hatch_mask = 1.0;
	if (enable_hatching && lum < shadow_threshold) {
		vec2 fc = screen_coord * (hatch_density * 0.8);
		vec2 p = fc + wobble_offset * 12.0;

		float line1 = abs(fract((p.x + p.y) * 0.5) - 0.5) * 2.0;
		float stroke1 = smoothstep(0.2, 0.5, line1);

		float stroke2 = 1.0;
		if (lum < shadow_threshold * 0.5) {
			float line2 = abs(fract((p.x - p.y) * 0.5) - 0.5) * 2.0;
			stroke2 = smoothstep(0.2, 0.5, line2);
		}

		float shadow_factor = (1.0 - smoothstep(0.05, shadow_threshold, lum));
		hatch_mask = mix(1.0, min(stroke1, stroke2), shadow_factor * 0.85);
	}

	// ── 5. 纸面绘图渲染 ──
	vec3 sketch_output;

	if (monochrome_mode) {
		// ══ 黑白纸面素描模式 ══
		float graphite_shading = (1.0 - smoothstep(0.08, 0.85, lum));
		float graphite_deposit = clamp(graphite_shading + paper_bump * 1.8 * graphite_shading, 0.0, 1.0);
		float total_darkness = max(graphite_deposit * 0.75, (1.0 - min(hatch_mask, 1.0 - edge)));
		sketch_output = mix(real_paper, pencil_color.rgb, total_darkness);
	} else {
		// ══ 彩铅绘本模式 ══
		// 1. 保留原本鲜活色彩，并叠加上微弱纸张纤维纹理与暗角
		vec3 colored = orig.rgb * (1.0 + paper_bump + mottle) * vignette_factor;

		// 2. 纸面底色柔和融合 (避免粗暴混入 30% 象牙白造成泛白灰蒙脱色，可自由调节 0.0 ~ 0.5)
		if (paper_tint > 0.001) {
			colored = mix(colored, real_paper, paper_tint);
		}

		// 3. 饱和度精准控制 (1.0 为无损还原，>1.0 可强化彩铅的浓郁艳丽感)
		float gray = get_luminance(colored);
		colored = mix(vec3(gray), colored, color_saturation);

		// 4. 对比度微调，消除中调发灰，提升手绘通透感
		if (abs(color_contrast - 1.0) > 0.01) {
			colored = clamp((colored - 0.5) * color_contrast + 0.5, 0.0, 1.0);
		}

		// 5. 铅笔线条与暗部排线叠加
		float stroke_tone = clamp(min(hatch_mask, 1.0 - edge), 0.0, 1.0);
		sketch_output = mix(pencil_color.rgb, colored, stroke_tone);
	}

	// ── 6. 【发光粒子原色透出与光辉还原】 ──
	if (protect_vfx_particles && is_vfx > 0.01) {
		vec3 vfx_color;
		if (keep_vfx_color) {
			// 保留火花/激光原本的耀眼色彩（如金黄火花、炽红能量），如同漫画手稿里的彩色荧光墨
			vfx_color = orig.rgb * vfx_glow_intensity;
		} else {
			// 纯白明亮火花
			vfx_color = vec3(vfx_energy * vfx_glow_intensity);
		}
		// 自然叠印在素描纸上
		sketch_output = mix(sketch_output, vfx_color, is_vfx);
	}

	// 红色外沿 / 高饱和填充保留原色及原亮度；不能恢复被场景遮挡的预警。
	if (preserve_red_signals) {
		float red_fraction = (orig.r - max(orig.g, orig.b)) / max(orig.r, 0.001);
		float red_mask = smoothstep(0.42, 0.60, red_fraction) * smoothstep(0.025, 0.065, orig.r);
		sketch_output = mix(sketch_output, orig.rgb, red_mask);
	}

	// ── 7. 最终输出与平滑过渡 ──
	COLOR = mix(orig, vec4(sketch_output, 1.0), filter_blend);
}
