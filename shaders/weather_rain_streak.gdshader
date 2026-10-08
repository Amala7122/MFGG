shader_type spatial;
render_mode unshaded, cull_disabled, depth_draw_never;

// 雨线不使用发光白色：白线在夜景里会像满屏激光。颜色保留一点天空蓝，
// 中间实、两侧软，远处自然被深度遮挡。屏幕纹理只用来读取雨滴背后的亮度：
// 夜空上的雨几乎不可见，灯下、亮地面前的雨才会被勾出来。
uniform sampler2D screen_texture : hint_screen_texture, filter_linear_mipmap;
uniform float u_daylight : hint_range(0.0, 1.0) = 1.0;
uniform float u_width_scale : hint_range(0.2, 2.5) = 1.0;
uniform float u_length_scale : hint_range(0.2, 2.0) = 1.0;
uniform float u_length_power : hint_range(0.8, 3.5) = 2.15;
uniform float u_brightness : hint_range(0.0, 1.5) = 1.0;

varying vec4 v_particle_color;
varying float v_drop_random;

float hash11(float value) {
	return fract(sin(value * 91.3458 + 17.217) * 47453.5453);
}

void vertex() {
	v_particle_color = COLOR;
	float seed = float(INSTANCE_ID) + INSTANCE_CUSTOM.x * 4093.0;
	float length_random = hash11(seed + 2.31);
	float width_random = hash11(seed + 7.73);
	v_drop_random = hash11(seed + 13.19);
	// 大多数是短小雨滴，少量才拉成明显雨线。宽度不与长度同比缩放，避免再次
	// 变成一批规格完全相同、只是整体大小不同的“针”。
	float length_scale = mix(0.08, 1.40, pow(length_random, u_length_power))
		* u_length_scale;
	float width_scale = mix(0.72, 1.45, width_random)
		* mix(1.25, 0.72, length_random) * u_width_scale;
	VERTEX.x *= width_scale;
	VERTEX.y *= length_scale;
}

void fragment() {
	float x = abs(UV.x * 2.0 - 1.0);
	float y = UV.y;
	// 头部稍圆、尾部渐细且渐隐；不再是一张边缘笔直的矩形贴片。
	float body_width = mix(0.82, 0.16, smoothstep(0.05, 1.0, y));
	float body = 1.0 - smoothstep(body_width * 0.20, body_width, x);
	float longitudinal = smoothstep(0.0, 0.10, y) * (1.0 - smoothstep(0.62, 1.0, y));
	float head_distance = length(vec2(x, (y - 0.13) * 3.4));
	float head = 1.0 - smoothstep(0.12, 0.78, head_distance);
	float drop_shape = max(body * longitudinal * 0.76, head * 0.92);

	vec3 behind = textureLod(screen_texture, SCREEN_UV, 1.5).rgb;
	float luminance = dot(behind, vec3(0.2126, 0.7152, 0.0722));
	float locally_lit = smoothstep(0.018, 0.24, luminance);
	// 白天允许雨滴在暗色物体前仍保持基本可读；入夜后完全服从局部画面亮度。
	float day_weight = smoothstep(0.04, 0.58, u_daylight);
	float illumination = mix(locally_lit, max(locally_lit, 0.74), day_weight);
	float random_alpha = mix(0.34, 1.0, v_drop_random);
	float alpha = drop_shape * v_particle_color.a * random_alpha * illumination
		* u_brightness;
	if (alpha < 0.015) {
		discard;
	}
	ALBEDO = v_particle_color.rgb * mix(0.82, 1.12, clamp(u_brightness, 0.0, 1.0));
	ALPHA = alpha;
}
