extends SceneTree
## 实际主场景像素回归：低太阳高度的表面纹路，以及程序云后方的重复云幕。
## 不强制修改正式阴影参数；固定时间、镜头和云位移，通过统一验收入口运行。

const Artifacts := preload("res://scripts/artifact_paths.gd")
const Terrain := preload("res://scripts/terrain_field.gd")
var _failed := false
var _captures: Array[Dictionary] = []


func _initialize() -> void:
	change_scene_to_file("res://scenes/hyrule_field.tscn")
	call_deferred("_run")


func _run() -> void:
	if DisplayServer.get_name() == "headless":
		push_error("天气像素回归需要真实图形渲染器。")
		quit(1)
		return
	for _frame in range(30):
		await process_frame
	paused = true
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	DisplayServer.window_set_size(Vector2i(1920, 1080))
	root.size = Vector2i(1920, 1080)
	for canvas in root.find_children("*", "CanvasLayer", true, false):
		(canvas as CanvasLayer).hide()
	var scene := current_scene
	var weather := scene.get_node("WeatherEnvironment/WeatherSystem")
	var field := weather.get_node("ProceduralCloudField")
	var sky := scene.get_node("WeatherEnvironment/Sky3D")
	var sun := sky.get_node("SunLight") as DirectionalLight3D
	var time := sky.get_node("TimeOfDay")
	time.call("pause")
	weather.set("rain_enabled", false)
	weather.set("fog_enabled", false)
	weather.set("snow_enabled", false)
	weather.set("cloud_enabled", true)
	weather.set("cloud_shadow_enabled", true)
	weather.set("cloud_type", 0)
	weather.set("cloud_coverage", 0.46)
	weather.set("cloud_density", 0.25)
	weather.set("_cloud_level", 0.46)
	weather.set("_cloud_density_level", 0.25)
	field.set("_layer_offsets", [Vector2.ZERO, Vector2.ZERO] as Array[Vector2])
	field.set("_clock", 0.0)
	var camera := Camera3D.new()
	scene.add_child(camera)
	camera.global_position = Vector3(0, Terrain.height_at(0, 24) + 3.0, 24)
	camera.look_at(Vector3(-15, 3, -80))
	camera.fov = 75.0
	camera.far = 2500.0
	camera.make_current()
	var road_checks: Array[Dictionary] = []
	for hour in [11.83, 17.4]:
		_set_hour(sky, hour)
		_refresh(weather, field)
		_check(sun.shadow_enabled, "正式太阳阴影仍开启")
		_check((field.get_child(0) as MultiMeshInstance3D).cast_shadow == GeometryInstance3D.SHADOW_CASTING_SETTING_ON,
			"程序云批次仍参与真实投影")
		var picture: Image = await _capture("ground_" + str(hour).replace(".", "_"))
		var grain := _road_grain(picture)
		_check(grain < 0.5, "%.2f 时道路的密集纹路应消失，实际相邻像素亮度差 %.4f/255" % [hour, grain])
		road_checks.append({"hour": hour, "adjacent_luminance_difference_255": grain,
			"sun_angle": sun.light_angular_distance, "shadow_depth": sun.directional_shadow_pancake_size})
		if hour > 17.0:
			sun.shadow_enabled = false
			var no_shadows: Image = await _capture("ground_without_sun_shadows")
			var difference := _difference(picture, no_shadows, Rect2i(300, 570, 1300, 480))
			_check(int(difference.changed_samples) > 100, "修正后仍有实际近景投影，不能通过关闭全部阴影消除纹路")
			sun.shadow_enabled = true

	_set_hour(sky, 12.1)
	camera.look_at(Vector3(-15, 130, -160))
	weather.set("cloud_coverage", 0.82)
	weather.set("cloud_density", 0.47)
	weather.set("_cloud_level", 0.82)
	weather.set("_cloud_density_level", 0.47)
	_refresh(weather, field)
	var visible_clouds: Image = await _capture("sky_program_clouds")
	field.set("visible", false)
	var dense_background: Image = await _capture("sky_background_high_coverage")
	var cloud_difference := _difference(visible_clouds, dense_background, Rect2i(200, 140, 1500, 420))
	_check(int(cloud_difference.changed_samples) > 500, "移除模糊云幕后程序云团仍实际显示")
	weather.set("cloud_coverage", 0.46)
	weather.set("_cloud_level", 0.46)
	_refresh(weather, field)
	field.set("visible", false)
	var sparse_background: Image = await _capture("sky_background_low_coverage")
	var backdrop_difference := _difference(dense_background, sparse_background, Rect2i(200, 140, 1500, 420))
	_check(float(backdrop_difference.mean_luminance_difference) < 0.002,
		"同一多云照明下，隐藏程序云后覆盖率变化不能生成另一层模糊云")
	weather.set("cloud_type", 1)
	weather.set("cloud_coverage", 1.0)
	weather.set("cloud_density", 0.86)
	weather.set("_cloud_level", 1.0)
	weather.set("_cloud_density_level", 0.86)
	_refresh(weather, field)
	await _capture("sky_overcast")
	field.set("visible", false)
	var overcast_background: Image = await _capture("sky_overcast_background")
	var daytime_background := _mean_luminance(overcast_background, Rect2i(200, 140, 1500, 420))
	_check(daytime_background > 0.04, "午间阴天的天空背景不能因重复压暗变为纯黑")
	var report := FileAccess.open(Artifacts.ensure_dir("reports").path_join("weather_visual_regressions.json"), FileAccess.WRITE)
	if report == null:
		_check(false, "天气回归报告写入失败")
	else:
		report.store_string(JSON.stringify({"passed": not _failed, "gpu": RenderingServer.get_video_adapter_name(),
			"scene": scene.scene_file_path, "road_checks": road_checks,
			"visible_cloud_difference": cloud_difference, "background_difference": backdrop_difference,
			"overcast_background_luminance": daytime_background,
			"captures": _captures}, "\t"))
		report.close()
	print("[天气像素回归] %s；道路 %s，天空背景 %s" % [
		"通过" if not _failed else "失败", JSON.stringify(road_checks), JSON.stringify(backdrop_difference)])
	quit(1 if _failed else 0)


func _set_hour(sky: Node, hour: float) -> void:
	sky.set("current_time", hour)
	var time := sky.get_node("TimeOfDay")
	time.set("current_time", hour)
	time.call("_update_celestial_coords")


func _refresh(weather: Node, field: Node) -> void:
	weather.call("_sync_extra_layers")
	weather.call("_update_environment")
	field.call("_update_transforms")


func _capture(name: String) -> Image:
	for _frame in range(12):
		await RenderingServer.frame_post_draw
	var picture := root.get_texture().get_image()
	var path := Artifacts.ensure_dir("screenshots").path_join(name + ".png")
	_check(picture.save_png(path) == OK, "截图写入 " + path)
	_captures.append({"name": name, "screenshot": path})
	return picture


func _road_grain(picture: Image) -> float:
	# 与诊断图相同的平坦道路内部，排除阴影边缘、装饰和路肩。
	var total := 0.0
	var samples := 0
	for y in range(980, 1060):
		for x in range(860, 950):
			var value := picture.get_pixel(x, y).get_luminance()
			total += absf(value - picture.get_pixel(x + 1, y).get_luminance())
			total += absf(value - picture.get_pixel(x, y + 1).get_luminance())
			samples += 2
	return total * 255.0 / samples


func _difference(first: Image, second: Image, region: Rect2i) -> Dictionary:
	var total := 0.0
	var samples := 0
	var changed := 0
	for y in range(region.position.y, region.end.y, 4):
		for x in range(region.position.x, region.end.x, 4):
			var delta := absf(first.get_pixel(x, y).get_luminance() - second.get_pixel(x, y).get_luminance())
			total += delta
			samples += 1
			if delta > 0.02:
				changed += 1
	return {"mean_luminance_difference": total / samples, "changed_samples": changed, "samples": samples}


func _mean_luminance(picture: Image, region: Rect2i) -> float:
	var total := 0.0
	var samples := 0
	for y in range(region.position.y, region.end.y, 4):
		for x in range(region.position.x, region.end.x, 4):
			total += picture.get_pixel(x, y).get_luminance()
			samples += 1
	return total / samples


func _check(condition: bool, message: String) -> void:
	if not condition:
		_failed = true
		push_error(message)
