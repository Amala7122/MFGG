shader_type spatial;
render_mode diffuse_burley, specular_disabled;

// 通用合并网格着色器（炮灰/人群）。
// 顶点属性：
//   UV.x  = pivot.x, UV.y = pivot.y, UV2.x = pivot.z（visual_root 局部空间）
//   UV2.y = 角色：0 躯干 / 1 发光核心 / 2 头 / 3 尾或背囊 / 10、11 前肢 / 12..19 腿
//   COLOR.rgb = 反照率（已转线性），COLOR.a = 自发光强度
// INSTANCE_CUSTOM = (walk_phase, attack_phase, flash, move_weight)
//
// 关节摆动按角色：前肢（10/11）叠加攻击前挥，腿（12+）只走路摆；奇偶决定左右反相。
// 躯干上下起伏、头轻点、尾/背囊绕 Y 摆——所有种类共用这一套，不再按部件 ID 写死。

uniform float walk_amplitude = 0.5;
uniform float attack_amplitude = 1.6;

varying float v_flash;
varying vec3 v_color;
varying float v_glow;

void vertex() {
	float role = floor(UV2.y + 0.5);
	vec3 pivot = vec3(UV.x, UV.y, UV2.x);
	float phase = INSTANCE_CUSTOM.x;
	float attack = INSTANCE_CUSTOM.y;
	float move = INSTANCE_CUSTOM.w;
	float walk = sin(phase * 7.0) * walk_amplitude * move;
	float attack_swing = 0.0;
	if (attack > 0.001) {
		attack_swing = sin(clamp(attack, 0.0, 1.0) * PI) * attack_amplitude;
	}
	float angle = 0.0;
	if (role > 9.5) {
		float sign = (mod(role, 2.0) < 0.5) ? 1.0 : -1.0;
		angle = sign * walk;
		if (role < 11.5) {
			angle += attack_swing;
		}
	}
	if (abs(angle) > 0.0001) {
		float s = sin(angle);
		float c = cos(angle);
		vec3 local = VERTEX - pivot;
		VERTEX = pivot + vec3(local.x, c * local.y - s * local.z, s * local.y + c * local.z);
		NORMAL = vec3(NORMAL.x, c * NORMAL.y - s * NORMAL.z, s * NORMAL.y + c * NORMAL.z);
	}
	if (role < 0.5) {
		VERTEX.y += abs(sin(phase * 7.0)) * 0.03 * move;
	} else if (role > 2.5 && role < 3.5) {
		float sway = sin(phase * 5.0) * 0.18 * move;
		float s = sin(sway);
		float c = cos(sway);
		vec3 local = VERTEX - pivot;
		VERTEX = pivot + vec3(c * local.x + s * local.z, local.y, -s * local.x + c * local.z);
	} else if (role > 1.5 && role < 2.5) {
		VERTEX.y += abs(sin(phase * 7.0)) * 0.02 * move;
	}
	v_flash = clamp(INSTANCE_CUSTOM.z, 0.0, 1.0);
	v_color = COLOR.rgb;
	v_glow = COLOR.a;
}

void fragment() {
	ALBEDO = mix(v_color, vec3(1.0, 0.025, 0.015), v_flash);
	ROUGHNESS = 0.92;
	EMISSION = v_color * v_glow + vec3(0.7, 0.02, 0.01) * v_flash * 0.65;
}
