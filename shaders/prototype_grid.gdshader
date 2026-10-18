shader_type spatial;
render_mode cull_back, diffuse_burley, specular_schlick_ggx;

// ============================================================================
// 工业级世界空间三向投影度量网格着色器 (World-Space Triplanar Prototype Grid)
// 专用于游戏开发灰模 (Greybox / Blockout) 阶段：
// 1. 世界坐标无缝连续，无视 UV 拉伸与几何体旋转缩放
// 2. 1 米精细度量小网格 + 5 米结构主基准粗线 + 微棋盘明暗交替
// 3. fwidth 抗锯齿边缘采样，远景无高频摩尔纹与噪点闪烁
// 4. 哑光陶泥漫反射，强化接触暗部与几何体三维体量感
// ============================================================================

uniform vec3 u_base_color : source_color = vec3(0.68, 0.70, 0.73);
uniform vec3 u_checker_color : source_color = vec3(0.60, 0.62, 0.65);
uniform float u_checker_strength : hint_range(0.0, 1.0) = 0.22;

uniform vec3 u_line_color : source_color = vec3(0.38, 0.40, 0.44);
uniform vec3 u_major_line_color : source_color = vec3(0.18, 0.20, 0.24);

uniform float u_grid_size = 1.0;
uniform float u_major_grid_step = 5.0;
uniform float u_line_width : hint_range(0.005, 0.1) = 0.025;
uniform float u_major_line_width : hint_range(0.01, 0.2) = 0.055;

uniform float u_roughness : hint_range(0.0, 1.0) = 0.88;
uniform float u_metallic : hint_range(0.0, 1.0) = 0.0;
uniform float u_specular : hint_range(0.0, 1.0) = 0.2;

varying vec3 v_world_pos;
varying vec3 v_world_normal;

void vertex() {
	v_world_pos = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
	v_world_normal = normalize(MODEL_NORMAL_MATRIX * NORMAL);
}

float get_grid_line(float coord, float spacing, float width) {
	float c = coord / spacing;
	float dist = abs(fract(c - 0.5) - 0.5);
	float fw = max(fwidth(c), 0.0002);
	float half_w = (width / spacing) * 0.5;
	return 1.0 - smoothstep(half_w - fw * 0.5, half_w + fw * 0.5, dist);
}

float get_grid_2d(vec2 uv, float spacing, float width) {
	float lx = get_grid_line(uv.x, spacing, width);
	float ly = get_grid_line(uv.y, spacing, width);
	return max(lx, ly);
}

float get_checker_2d(vec2 uv, float spacing) {
	vec2 c = floor(uv / spacing);
	return mod(c.x + c.y, 2.0);
}

void fragment() {
	// 三向投影权重 (锐化过渡边缘，防止斜面模糊过渡带过宽)
	vec3 weights = pow(abs(v_world_normal), vec3(4.0));
	weights /= (weights.x + weights.y + weights.z + 0.00001);

	// 三向平面 UV 映射
	vec2 uv_y = v_world_pos.xz; // 顶面 / 地面
	vec2 uv_x = v_world_pos.zy; // X 轴朝向墙面
	vec2 uv_z = v_world_pos.xy; // Z 轴朝向墙面

	// 1 米度量小网格
	float grid_1m_x = get_grid_2d(uv_x, u_grid_size, u_line_width);
	float grid_1m_y = get_grid_2d(uv_y, u_grid_size, u_line_width);
	float grid_1m_z = get_grid_2d(uv_z, u_grid_size, u_line_width);
	float grid_1m = grid_1m_x * weights.x + grid_1m_y * weights.y + grid_1m_z * weights.z;

	// 5 米结构大网格
	float major_step = u_grid_size * u_major_grid_step;
	float grid_5m_x = get_grid_2d(uv_x, major_step, u_major_line_width);
	float grid_5m_y = get_grid_2d(uv_y, major_step, u_major_line_width);
	float grid_5m_z = get_grid_2d(uv_z, major_step, u_major_line_width);
	float grid_5m = grid_5m_x * weights.x + grid_5m_y * weights.y + grid_5m_z * weights.z;

	// 1 米交替微棋盘
	float chk_x = get_checker_2d(uv_x, u_grid_size);
	float chk_y = get_checker_2d(uv_y, u_grid_size);
	float chk_z = get_checker_2d(uv_z, u_grid_size);
	float checker = chk_x * weights.x + chk_y * weights.y + chk_z * weights.z;

	// 颜色合成
	vec3 col = mix(u_base_color, u_checker_color, checker * u_checker_strength);
	col = mix(col, u_line_color, clamp(grid_1m, 0.0, 1.0));
	col = mix(col, u_major_line_color, clamp(grid_5m, 0.0, 1.0));

	// 细微斜面明暗过渡 (增强地形陡坡与侧面剪影感)
	float slope = clamp(v_world_normal.y, 0.0, 1.0);
	col *= mix(0.90, 1.02, slope);

	ALBEDO = col;
	ROUGHNESS = u_roughness;
	METALLIC = u_metallic;
	SPECULAR = u_specular;
}
