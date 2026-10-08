extends RefCounted
## 编辑器预览与运行时天气共用的远景云调色，避免预览夜晚仍是白云。


static func tint_for_sun(sun: DirectionalLight3D, storm: float = 0.0) -> Color:
	var daylight := smoothstep(-0.10, 0.16, sun.global_basis.z.normalized().y) \
		if is_instance_valid(sun) else 0.0
	var day_tint := sun.light_color.lerp(Color(0.82, 0.86, 0.91), 0.70) \
		if is_instance_valid(sun) else Color.WHITE
	var cloud_tint := Color(0.13, 0.18, 0.27).lerp(day_tint, daylight)
	var storm_tint := Color(0.08, 0.10, 0.13).lerp(Color(0.34, 0.38, 0.43), daylight)
	return cloud_tint.lerp(storm_tint, clampf(storm, 0.0, 1.0))


## 阳光强弱是美术映射；PCSS 根据实际投影距离扩大半影，使高云比近地物体更柔。
## 强光也保留非零光源角径。能量使用固定参照，不能每帧用自身归一化。
static func cloud_shadow_angle(sun_direction: Vector3, energy: float,
		strong_angle: float, weak_angle: float, reference_energy: float) -> float:
	var minimum := maxf(strong_angle, 0.1)
	var maximum := maxf(weak_angle, minimum)
	var strength := clampf(maxf(energy, 0.0) * clampf(sun_direction.y, 0.0, 1.0)
		/ maxf(reference_energy, 0.05), 0.0, 1.0)
	return lerpf(maximum, minimum, smoothstep(0.0, 1.0, strength))


static func apply_cloud_shadow_softness(weather: Node, sun: DirectionalLight3D,
		baseline_angle: float, cloud_visible: bool,
		baseline_depth: float = 20.0, cloud_ceiling: float = 650.0) -> void:
	if not is_instance_valid(sun):
		return
	if not cloud_visible or not bool(weather.get("cloud_shadow_enabled")) \
			or sun.light_energy <= 0.001 or sun.global_basis.z.y <= 0.0:
		sun.light_angular_distance = baseline_angle
		sun.directional_shadow_pancake_size = baseline_depth
		return
	sun.light_angular_distance = maxf(baseline_angle, cloud_shadow_angle(
		sun.global_basis.z.normalized(), sun.light_energy,
		float(weather.get("cloud_shadow_strong_sun_angle")),
		float(weather.get("cloud_shadow_weak_sun_angle")),
		float(weather.get("cloud_shadow_reference_energy"))))
	# 默认 pancake 只保留近景深度；高云会被压在同一深度边界，导致点状黑带。
	# 扩展的是沿阳光的深度，接收阴影的镜头距离仍保持原画质设置。
	var depth := clampf(cloud_ceiling / maxf(sun.global_basis.z.normalized().y, 0.15)
		+ 100.0, 600.0, 3000.0)
	sun.directional_shadow_pancake_size = maxf(baseline_depth, depth)
