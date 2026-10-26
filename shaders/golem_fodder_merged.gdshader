shader_type spatial;
render_mode diffuse_burley, specular_disabled;

// 合并网格的顶点属性：
// UV.x = 部件 ID（0 躯干 / 1 晶核 / 2 左拳 / 3 右拳 / 4 左腿 / 5 右腿）
// UV.y = 关节 pivot.x，UV2 = 关节 pivot.yz（visual_root 局部空间）
// INSTANCE_CUSTOM = (walk_phase, attack_phase, flash, move_weight)
//
// 颜色/粗糙度/晶核 glow/闪红全部对齐 mud_golem_instanced.gdshader：
//   身体 0.28,0.32,0.22 rough .95
//   晶核 0.10,0.85,0.90 rough .90 glow .16
//   石拳 0.42,0.44,0.45 rough .90
//   腿   0.28,0.32,0.22 rough .95

uniform float walk_amplitude = 0.55;
uniform float arm_amplitude = 0.5;
uniform float leg_amplitude = 0.65;
uniform float attack_amplitude = 1.8;
// 与原版 mud_golem_instanced.gdshader 相同的 source_color 语义：
// 由引擎做 sRGB→linear，不能直接写 vec3(0.28,...)（那是 linear，会偏亮）。
uniform vec4 body_color : source_color = vec4(0.28, 0.32, 0.22, 1.0);
uniform vec4 core_color : source_color = vec4(0.10, 0.85, 0.90, 1.0);
uniform vec4 fist_color : source_color = vec4(0.42, 0.44, 0.45, 1.0);
uniform vec4 leg_color : source_color = vec4(0.28, 0.32, 0.22, 1.0);

varying float v_flash;
varying float v_part;

void vertex() {
	float part = floor(UV.x + 0.5);
	vec3 pivot = vec3(UV.y, UV2.x, UV2.y);
	float phase = INSTANCE_CUSTOM.x;
	float attack = INSTANCE_CUSTOM.y;
	float move = INSTANCE_CUSTOM.w;
	float walk = sin(phase * 7.0) * walk_amplitude * move;
	float attack_swing = 0.0;
	if (attack > 0.001) {
		attack_swing = sin(clamp(attack, 0.0, 1.0) * PI) * attack_amplitude;
	}
	float angle = 0.0;
	if (part > 1.5 && part < 3.5) {
		angle = (part < 2.5 ? -walk : walk) + attack_swing;
	} else if (part > 3.5) {
		angle = (part < 4.5 ? walk : -walk) * (leg_amplitude / arm_amplitude);
	}
	if (abs(angle) > 0.0001) {
		float s = sin(angle);
		float c = cos(angle);
		vec3 local = VERTEX - pivot;
		VERTEX = pivot + vec3(local.x, c * local.y - s * local.z, s * local.y + c * local.z);
		NORMAL = vec3(NORMAL.x, c * NORMAL.y - s * NORMAL.z, s * NORMAL.y + c * NORMAL.z);
	}
	if (part < 0.5) {
		VERTEX.y += abs(sin(phase * 7.0)) * 0.03 * move;
	}
	v_flash = clamp(INSTANCE_CUSTOM.z, 0.0, 1.0);
	v_part = part;
}

void fragment() {
	vec4 base = body_color;
	float roughness_value = 0.95;
	float glow = 0.0;
	if (v_part > 0.5 && v_part < 1.5) {
		base = core_color;
		roughness_value = 0.90;
		glow = 0.16;
	} else if (v_part > 1.5 && v_part < 3.5) {
		base = fist_color;
		roughness_value = 0.90;
	} else if (v_part > 3.5) {
		base = leg_color;
	}
	ALBEDO = mix(base.rgb, vec3(1.0, 0.025, 0.015), v_flash);
	ROUGHNESS = roughness_value;
	EMISSION = base.rgb * glow + vec3(0.7, 0.02, 0.01) * v_flash * 0.65;
}
