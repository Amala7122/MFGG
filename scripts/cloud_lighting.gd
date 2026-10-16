extends RefCounted
## 编辑器预览与运行时天气共用的云调色与真实投影设置。

# Sky3D 的散射计算会相乘两组 source_color，不能用近黑色重复压暗。
const OVERCAST_DAY_TINT := Color(0.78, 0.83, 0.89, 1.0)
const OVERCAST_HORIZON_TINT := Color(0.78, 0.80, 0.83, 1.0)


static func tint_for_sun(sun: DirectionalLight3D, storm: float = 0.0) -> Color:
	var daylight := smoothstep(-0.10, 0.16, sun.global_basis.z.normalized().y) \
		if is_instance_valid(sun) else 0.0
	var day_tint := sun.light_color.lerp(Color(0.82, 0.86, 0.91), 0.70) \
		if is_instance_valid(sun) else Color.WHITE
	var cloud_tint := Color(0.13, 0.18, 0.27).lerp(day_tint, daylight)
	var storm_tint := Color(0.08, 0.10, 0.13).lerp(Color(0.34, 0.38, 0.43), daylight)
	return cloud_tint.lerp(storm_tint, clampf(storm, 0.0, 1.0))


static func apply_cloud_shadow_settings(weather: Node, sun: DirectionalLight3D,
		baseline_angle: float, cloud_visible: bool,
		baseline_depth: float = 20.0, cloud_ceiling: float = 650.0) -> void:
	if not is_instance_valid(sun):
		return
	if not cloud_visible or not bool(weather.get("cloud_shadow_enabled")) \
			or sun.light_energy <= 0.001 or sun.global_basis.z.y <= 0.0:
		sun.light_angular_distance = baseline_angle
		sun.directional_shadow_pancake_size = baseline_depth
		return
	# 高云需要大投影深度；此时 PCSS 的距离相关采样会让近景表面出现密集纹路。
	# 使用现有画质/天气的 shadow_blur 过滤，保留物体与云的真实投影。
	sun.light_angular_distance = 0.0
	# 默认 pancake 只保留近景深度；高云会被压在同一深度边界，导致点状黑带。
	# 扩展的是沿阳光的深度，接收阴影的镜头距离仍保持原画质设置。
	var depth := clampf(cloud_ceiling / maxf(sun.global_basis.z.normalized().y, 0.15)
		+ 100.0, 600.0, 3000.0)
	sun.directional_shadow_pancake_size = maxf(baseline_depth, depth)
