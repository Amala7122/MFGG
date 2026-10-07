shader_type spatial;
render_mode unshaded, cull_disabled, depth_draw_never;

uniform float sweep_arc = 4.712389;
uniform float sweep_progress : hint_range(0.0, 1.0) = 0.0;
uniform float opacity : hint_range(0.0, 1.0) = 0.8;

void fragment() {
	// UV 是锁定攻击姿态下的地表坐标；只显示手臂已经扫过的笔迹。
	float angle = atan(UV.x, -UV.y);
	if ((angle + sweep_arc * 0.5) / sweep_arc > sweep_progress) {
		discard;
	}
	ALBEDO = vec3(0.19, 0.14, 0.09);
	ROUGHNESS = 1.0;
	ALPHA = opacity;
}
