extends SceneTree
## 固定主场景、太阳时间和镜头，分别隔离云投影、PCSS、阴影深度与 SSAO。
## 用 tools/run_probe.py --graphics 运行；截图为手动诊断证据，不自动判定观感。

const Artifacts := preload("res://scripts/artifact_paths.gd")
const Terrain := preload("res://scripts/terrain_field.gd")
var _failed := false

func _initialize() -> void:
	change_scene_to_file("res://scenes/hyrule_field.tscn")
	call_deferred("_run")

func _run() -> void:
	if DisplayServer.get_name() == "headless":
		push_error("表面纹路对照需要图形渲染器。")
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
	var time := sky.get_node("TimeOfDay")
	var sun := sky.get_node("SunLight") as DirectionalLight3D
	var dome := sky.get_node("SkyDome")
	var env := (sky as WorldEnvironment).environment
	time.call("pause")
	weather.rain_enabled = false
	weather.fog_enabled = false
	weather.snow_enabled = false
	weather.cloud_enabled = true
	weather.cloud_type = 0
	weather.cloud_coverage = 0.46
	weather.cloud_density = 0.25
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
	if OS.get_cmdline_user_args().has("--overcast-sky"):
		await _capture_overcast_sky(weather, field, sky, camera)
		quit(1 if _failed else 0)
		return
	if OS.get_cmdline_user_args().has("--cloud-layers"):
		await _capture_cloud_layers(weather, field, sky, camera)
		quit(1 if _failed else 0)
		return
	var snapshots: Array[Dictionary] = []
	for hour in [11.83, 17.4]:
		sky.set("current_time", hour)
		time.set("current_time", hour)
		time.call("_update_celestial_coords")
		weather.call("_sync_extra_layers")
		weather.call("_update_environment")
		field.call("_update_transforms")
		var depth := sun.directional_shadow_pancake_size
		var angle := sun.light_angular_distance
		var bias := sun.shadow_bias
		var normal_bias := sun.shadow_normal_bias
		var ssao := env.ssao_enabled
		var old_clouds := scene.find_children("BackdropClouds", "MeshInstance3D", true, false)
		var old_visibility: Array[bool] = []
		for old in old_clouds:
			old_visibility.append(old.visible)
		var legacy_cumulus: bool = bool(dome.get("cumulus_visible"))
		var legacy_cirrus: bool = bool(dome.get("cirrus_visible"))
		for mode in ["baseline", "no_ssao", "no_sun_shadows", "no_cloud_cast", "hard_shadows", "depth_20", "depth_20_no_cloud_cast", "normal_bias_1", "bias_1", "no_legacy_clouds"]:
			sun.shadow_enabled = mode != "no_sun_shadows"
			sun.directional_shadow_pancake_size = 20.0 if mode.begins_with("depth_20") else depth
			sun.light_angular_distance = 0.0 if mode == "hard_shadows" else angle
			sun.shadow_bias = 1.0 if mode == "bias_1" else bias
			sun.shadow_normal_bias = 1.0 if mode == "normal_bias_1" else normal_bias
			env.ssao_enabled = false if mode == "no_ssao" else ssao
			field.call("set_cloud_shadows", mode not in ["no_cloud_cast", "depth_20_no_cloud_cast"])
			dome.set("cumulus_visible", false if mode == "no_legacy_clouds" else legacy_cumulus)
			dome.set("cirrus_visible", false if mode == "no_legacy_clouds" else legacy_cirrus)
			for index in range(old_clouds.size()):
				old_clouds[index].visible = false if mode == "no_legacy_clouds" else old_visibility[index]
			for _frame in range(12):
				await RenderingServer.frame_post_draw
			var path := Artifacts.ensure_dir("screenshots").path_join("%s_%s.png" % [str(hour).replace(".", "_"), mode])
			var error := root.get_texture().get_image().save_png(path)
			if error != OK:
				_failed = true
				push_error("截图写入失败：%s (%d)" % [path, error])
			snapshots.append({"hour": hour, "mode": mode, "screenshot": path,
				"sun_direction": sun.global_basis.z, "sun_energy": sun.light_energy,
				"pancake": sun.directional_shadow_pancake_size, "angle": sun.light_angular_distance,
				"shadow_bias": sun.shadow_bias, "normal_bias": sun.shadow_normal_bias,
				"ssao": env.ssao_enabled, "old_mesh_count": old_clouds.size(),
				"legacy_cumulus": dome.get("cumulus_visible"), "legacy_cirrus": dome.get("cirrus_visible")})
			print("[纹路对照] ", path)
	var report := FileAccess.open(Artifacts.ensure_dir("reports").path_join("conditions.json"), FileAccess.WRITE)
	if report == null:
		push_error("纹路对照条件报告写入失败。")
		_failed = true
	else:
		report.store_string(JSON.stringify({"scene": scene.scene_file_path,
			"gpu": RenderingServer.get_video_adapter_name(), "resolution": root.size,
			"camera": camera.global_transform, "captures": snapshots}, "\t"))
		report.close()
	quit(1 if _failed else 0)


func _capture_overcast_sky(weather: Node, field: Node, sky: Node, camera: Camera3D) -> void:
	var time := sky.get_node("TimeOfDay")
	var dome := sky.get_node("SkyDome")
	var material := dome.get("sky_material") as ShaderMaterial
	sky.set("current_time", 12.1)
	time.set("current_time", 12.1)
	time.call("_update_celestial_coords")
	weather.set("cloud_type", 1)
	weather.set("cloud_coverage", 1.0)
	weather.set("cloud_density", 0.86)
	weather.set("_cloud_level", 1.0)
	weather.set("_cloud_density_level", 0.86)
	weather.call("_sync_extra_layers")
	camera.look_at(Vector3(-15, 130, -160))
	var captures: Array[Dictionary] = []
	for mode in ["baseline", "visible", "mie", "day_tint"]:
		weather.call("_update_environment")
		field.set("visible", false)
		if mode == "visible":
			material.set_shader_parameter("sky_visible", true)
		if mode == "mie":
			material.set_shader_parameter("atm_sun_mie_intensity", 1.0)
		if mode == "day_tint":
			material.set_shader_parameter("atm_day_tint", Color(0.76, 0.87, 0.96))
			material.set_shader_parameter("atm_horizon_light_tint", Color(0.96, 0.70, 0.52))
		for _frame in range(12):
			await RenderingServer.frame_post_draw
		var path := Artifacts.ensure_dir("screenshots").path_join("overcast_" + mode + ".png")
		_failed = root.get_texture().get_image().save_png(path) != OK or _failed
		var parameters: Dictionary = {}
		for key in ["sky_visible", "atm_day_tint", "atm_night_tint", "atm_horizon_light_tint", "atm_sun_intensity", "atm_sun_mie_intensity", "atm_beta_ray", "atm_beta_mie", "atm_level_params", "color_correction"]:
			parameters[key] = material.get_shader_parameter(key)
		captures.append({"mode": mode, "screenshot": path, "parameters": parameters,
			"sun_direction": (sky.get_node("SunLight") as DirectionalLight3D).global_basis.z,
			"sky_enabled": sky.get("sky_enabled"), "sky_contribution": sky.get("sky_contribution")})
	var report := FileAccess.open(Artifacts.ensure_dir("reports").path_join("overcast_sky.json"), FileAccess.WRITE)
	if report == null:
		_failed = true
		push_error("阴天天空诊断报告写入失败")
	else:
		report.store_string(JSON.stringify(captures, "\t"))
		report.close()


func _capture_cloud_layers(weather: Node, field: Node, sky: Node, camera: Camera3D) -> void:
	# 匹配反馈图的午间仰视和中高覆盖率；不声称复刻随机预报的全部雨雾数值。
	var time := sky.get_node("TimeOfDay")
	var dome := sky.get_node("SkyDome")
	var material := dome.get("sky_material") as ShaderMaterial
	if material == null:
		push_error("云层对照未找到实际天空材质。")
		_failed = true
		return
	sky.set("current_time", 12.1)
	time.set("current_time", 12.1)
	time.call("_update_celestial_coords")
	weather.set("cloud_coverage", 0.82)
	weather.set("cloud_density", 0.47)
	weather.set("_cloud_level", 0.82)
	weather.set("_cloud_density_level", 0.47)
	weather.call("_sync_extra_layers")
	weather.call("_update_environment")
	camera.look_at(Vector3(-15, 130, -160))
	field.call("_update_transforms")
	var legacy_cumulus: bool = bool(dome.get("cumulus_visible"))
	var legacy_cirrus: bool = bool(dome.get("cirrus_visible"))
	var captures: Array[Dictionary] = []
	for mode in ["runtime_clouds", "sky_only", "legacy_flags_off"]:
		field.set("visible", mode != "sky_only")
		dome.set("cumulus_visible", false if mode == "legacy_flags_off" else legacy_cumulus)
		dome.set("cirrus_visible", false if mode == "legacy_flags_off" else legacy_cirrus)
		for _frame in range(12):
			await RenderingServer.frame_post_draw
		var path := Artifacts.ensure_dir("screenshots").path_join("cloud_layers_" + mode + ".png")
		var error := root.get_texture().get_image().save_png(path)
		if error != OK:
			_failed = true
			push_error("云层对照截图写入失败：%s (%d)" % [path, error])
		captures.append({"mode": mode, "screenshot": path,
			"mesh_visible": field.get("visible"), "cloud_coverage": 0.82, "cloud_density": 0.47,
			"legacy_cumulus": dome.get("cumulus_visible"), "legacy_cirrus": dome.get("cirrus_visible"),
			"shader_legacy_cumulus": material.get_shader_parameter("cumulus_visible"),
			"shader_legacy_cirrus": material.get_shader_parameter("cirrus_visible"),
			"old_mesh_count": current_scene.find_children("BackdropClouds", "MeshInstance3D", true, false).size()})
		print("[云层对照] ", path)
	var report := FileAccess.open(Artifacts.ensure_dir("reports").path_join("cloud_layers.json"), FileAccess.WRITE)
	if report == null:
		push_error("云层对照报告写入失败。")
		_failed = true
	else:
		report.store_string(JSON.stringify({"scene": current_scene.scene_file_path,
			"gpu": RenderingServer.get_video_adapter_name(), "hour": 12.1,
			"camera": camera.global_transform, "captures": captures}, "\t"))
		report.close()
