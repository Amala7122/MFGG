shader_type spatial;
render_mode blend_mix, depth_draw_opaque, cull_back, diffuse_burley, specular_schlick_ggx;

// 合并网格的顶点属性：
// UV.x = 部件 ID（0 躯干 / 1 晶核 / 2 左拳 / 3 右拳 / 4 左腿 / 5 右腿）
// UV.y = 关节 pivot.x，UV2 = 关节 pivot.yz（visual_root 局部空间）
// INSTANCE_CUSTOM = (walk_phase, attack_phase, flash, move_weight)

uniform float walk_amplitude = 0.55;
uniform float arm_amplitude = 0.5;
uniform float leg_amplitude = 0.65;
uniform float attack_amplitude = 1.8;

varying vec3 v_flash;
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
	v_flash = vec3(INSTANCE_CUSTOM.z, 0.0, 0.0);
	v_part = part;
}

void fragment() {
	vec3 color = vec3(0.28, 0.32, 0.22);
	if (v_part > 0.5 && v_part < 1.5) {
		color = vec3(0.10, 0.85, 0.90);
	} else if (v_part > 1.5 && v_part < 3.5) {
		color = vec3(0.42, 0.44, 0.45);
	} else if (v_part > 3.5) {
		color = vec3(0.24, 0.28, 0.20);
	}
	ALBEDO = color;
	ROUGHNESS = 0.92;
	SPECULAR = 0.15;
	EMISSION = vec3(1.0, 0.18, 0.06) * v_flash.x;
}
