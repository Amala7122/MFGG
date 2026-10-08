shader_type spatial;
render_mode unshaded, cull_disabled, depth_draw_never;

uniform float progress : hint_range(0.0, 1.0) = 0.0;
uniform float locked_phase : hint_range(0.0, 1.0) = 0.0;
uniform bool radial_fill = true;
uniform float radius = 1.0;
uniform float start_z = 0.0;
uniform float end_z = -1.0;

void fragment() {
	// UV 保存贴地网格的局部平面坐标，只改变填充，完整边界和伤害范围不缩放。
	float metric = radial_fill ? length(UV) / max(radius, 0.001)
		: (start_z - UV.y) / max(start_z - end_z, 0.001);
	float filled = 1.0 - smoothstep(progress - 0.012, progress, metric);
	ALBEDO = mix(vec3(0.95, 0.015, 0.006), vec3(1.0, 0.025, 0.008), locked_phase);
	ALPHA = mix(0.055, mix(0.43, 0.56, locked_phase), filled);
}
