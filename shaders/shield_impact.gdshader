shader_type spatial;
render_mode blend_add, depth_draw_never, cull_back, unshaded;

// --- 能量护盾核心配置（明亮科幻天蓝/青光力场） ---
uniform vec4 shield_base_color : source_color = vec4(0.38, 0.88, 1.0, 0.22);
uniform vec4 hex_glow_color : source_color = vec4(0.65, 0.96, 1.0, 1.0);
uniform vec4 impact_core_color : source_color = vec4(0.96, 1.0, 1.0, 1.0);

// --- 受击与动画动态参数 ---
uniform vec3 hit_direction_local = vec3(0.0, 0.0, 1.0);
uniform float hit_intensity : hint_range(0.0, 3.0) = 0.0;
uniform float ripple_progress : hint_range(0.0, 4.0) = 0.0;
uniform float shield_alpha : hint_range(0.0, 1.0) = 0.0;

// --- 蜂巢结构与边缘参数（适度缩放，蜂窝更大更清晰） ---
uniform float hex_scale : hint_range(1.0, 15.0) = 3.6;
uniform float hex_line_thickness : hint_range(0.01, 0.20) = 0.045;
uniform float fresnel_power : hint_range(1.0, 6.0) = 2.2;

uniform float glow_multiplier : hint_range(0.0, 3.0) = 1.0;

varying vec3 v_local_pos;
varying vec3 v_local_norm;

void vertex() {
	v_local_pos = VERTEX;
	v_local_norm = normalize(NORMAL);
}

// 2D 蜂巢/正六边形距离场计算
// 返回 vec2(x: 边框线因子 0~1, y: 晶胞中心能量 0~1)
vec2 hex_cell(vec2 uv) {
	vec2 r = vec2(1.0, 1.7320508);
	vec2 h = r * 0.5;
	vec2 a = mod(uv, r) - h;
	vec2 b = mod(uv - h, r) - h;
	vec2 gv = dot(a, a) < dot(b, b) ? a : b;

	// 正六边形边缘距离计算
	vec2 p = abs(gv);
	float d = max(dot(p, normalize(vec2(1.0, 1.7320508))), p.x);

	// 边框发光线（d 接近 0.5 处）
	float edge = smoothstep(0.5 - hex_line_thickness, 0.5, d);
	// 晶胞内部微发光（中心 d=0 处）
	float center = 1.0 - smoothstep(0.0, 0.44, d);
	return vec2(edge, center);
}

void fragment() {
	if (shield_alpha <= 0.001) {
		discard;
	}

	vec3 norm = normalize(v_local_norm);

	// 1. 三向投影（Triplanar）计算蜂巢网格，杜绝球极点拉伸或畸变
	vec3 blend_weights = abs(norm);
	blend_weights = pow(blend_weights, vec3(4.0));
	float sum_w = blend_weights.x + blend_weights.y + blend_weights.z;
	if (sum_w > 0.0001) {
		blend_weights /= sum_w;
	} else {
		blend_weights = vec3(0.333);
	}

	vec2 hex_x = hex_cell(v_local_pos.yz * hex_scale);
	vec2 hex_y = hex_cell(v_local_pos.xz * hex_scale);
	vec2 hex_z = hex_cell(v_local_pos.xy * hex_scale);
	vec2 hex = hex_x * blend_weights.x + hex_y * blend_weights.y + hex_z * blend_weights.z;
	float hex_edge = hex.x;
	float hex_fill = hex.y;

	// 2. 受击接触点与周围蜂巢局部高亮（Focus on Contact Point & Surrounding Hex Cells）
	vec3 hit_dir = normalize(hit_direction_local);
	float dot_impact = dot(norm, hit_dir);
	// 从受击接触点(0弧度)开始的角距离
	float angle = acos(clamp(dot_impact, -1.0, 1.0));

	// 紧贴受击接触点周围几格蜂巢的局部范围（约 35~40 度扇区）
	float contact_cluster = (1.0 - smoothstep(0.0, 0.72, angle));
	// 接触点向外微扩散的冲击微波（局部收敛，不扩散至全球）
	float ripple_wave = exp(-pow(angle - ripple_progress, 2.0) * 16.0) * (1.0 - smoothstep(0.0, 1.1, ripple_progress));
	// 接触点中心能量核爆闪
	float impact_core = (1.0 - smoothstep(0.0, 0.30, angle)) * 2.8;

	// 3. 接触点及其相邻蜂巢高能激活
	float hex_highlight = (hex_edge * 3.0 + hex_fill * 1.0) * (contact_cluster * 1.8 + ripple_wave * 2.2);

	// 4. 全球形护盾明亮半透明球壳（透亮菲涅尔边缘光）
	float fresnel = pow(1.0 - clamp(dot(NORMAL, VIEW), 0.0, 1.0), fresnel_power);
	// 全局微光晶格底纹与球形能量包裹
	float ambient_bubble = (fresnel * 0.92 + 0.14) + hex_edge * 0.08;

	// 5. 颜色合成（明亮通透高科技能量场）
	vec3 col = shield_base_color.rgb * (ambient_bubble + hex_fill * 0.08);
	col += hex_glow_color.rgb * hex_highlight * hit_intensity;
	col += impact_core_color.rgb * (impact_core + ripple_wave * 2.0) * hit_intensity;

	// 6. 不透明度控制
	float alpha_val = (ambient_bubble * shield_base_color.a + (hex_highlight + impact_core) * 0.90) * shield_alpha;

	ALBEDO = col * glow_multiplier;
	ALPHA = clamp(alpha_val, 0.0, 1.0);
}
