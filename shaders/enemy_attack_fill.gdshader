shader_type spatial;
render_mode unshaded, cull_disabled, depth_draw_never;

uniform float progress : hint_range(0.0, 1.0) = 0.0;
uniform float locked_phase : hint_range(0.0, 1.0) = 0.0;
uniform bool radial_fill = true;
uniform float radius = 1.0;
uniform float start_z = 0.0;
uniform float end_z = -1.0;
uniform float opacity_scale : hint_range(0.0,1.0) = 1.0;
uniform bool solid_footprint = false;

void fragment() {
	// UV 保存贴地网格的局部平面坐标，只改变填充，完整边界和伤害范围不缩放。
	float metric = radial_fill ? length(UV) / max(radius, 0.001)
		: (start_z - UV.y) / max(start_z - end_z, 0.001);
	float filled = 1.0 - smoothstep(progress - 0.012, progress, metric);
	ALBEDO = mix(vec3(0.95, 0.015, 0.006), vec3(1.0, 0.025, 0.008), locked_phase);
	// 未填充区域从第一帧就表示完整危险范围，亮填充只表示剩余时间。
	ALPHA = mix(0.16, mix(0.48, 0.60, locked_phase), filled) * opacity_scale;
	if (solid_footprint) {
		// 整片从第一帧就是危险区；斜纹提供形状线索，禁止以扩散面积冒充倒计时。
		float stripe = smoothstep(0.68, 0.72, fract((UV.x + UV.y) / 1.6));
		float urgency = smoothstep(0.0, 1.0, progress);
		ALBEDO = mix(vec3(0.82, 0.025, 0.008), vec3(0.20, 0.008, 0.004), stripe)
			* (0.88 + 0.12 * urgency);
		ALPHA = mix(0.70, 0.87, stripe) * opacity_scale;
	}
}
