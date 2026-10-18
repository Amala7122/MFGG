shader_type spatial;
render_mode unshaded, cull_back, shadows_disabled;

// 原Aura球壳只绘制最外沿；中心透明，不能用整球深色遮住浅色弹芯。
void fragment() {
	float facing = abs(dot(normalize(NORMAL), normalize(VIEW)));
	ALBEDO = vec3(0.07);
	ALPHA = 1.0 - smoothstep(0.30, 0.55, facing);
}
