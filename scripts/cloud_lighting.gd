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
