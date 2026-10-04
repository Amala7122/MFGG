extends SceneTree
## 固定天气/镜头交替测量真实云影，结果和截图写到工程外的 visual_captures。

const CapturePaths := preload("res://scripts/capture_paths.gd")
const Terrain := preload("res://scripts/terrain_field.gd")
const CloudLighting := preload("res://scripts/cloud_lighting.gd")
const WARMUP_FRAMES := 180
const SAMPLE_FRAMES := 600


func _initialize() -> void:
	change_scene_to_file("res://prototypes/environment/weather_lab.tscn")
	call_deferred("_run")


func _run() -> void:
	for _frame in range(30):
		await process_frame
	paused = true
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	DisplayServer.window_set_vsync_mode(DisplayServer.VSYNC_DISABLED)
	DisplayServer.window_set_size(Vector2i(1920, 1080))
	root.size = Vector2i(1920, 1080)
	Engine.max_fps = 0
	for canvas in root.find_children("*", "CanvasLayer", true, false):
		(canvas as CanvasLayer).hide()
	var weather := current_scene.get_node("WeatherEnvironment/WeatherSystem")
	var field := weather.get_node("ProceduralCloudField")
	weather.cloud_type = 0
	weather.cloud_enabled = true
	weather.rain_enabled = false
	weather.fog_enabled = false
	weather.cloud_density = 0.0
	weather.cloud_size_multiplier = 3.0
	weather.set("_cloud_density_level", 0.0)
	var camera := Camera3D.new()
	current_scene.add_child(camera)
	camera.global_position = Vector3(0, Terrain.height_at(0, 24) + 3.0, 24)
	camera.look_at(Vector3(-15, 3, -80))
	camera.fov = 75.0
	camera.far = 2500.0
	camera.make_current()
	var sun := current_scene.get_node("WeatherEnvironment/Sky3D/SunLight") as DirectionalLight3D
	var viewport := root.get_viewport_rid()
	RenderingServer.viewport_set_measure_render_time(viewport, true)
	var folder := CapturePaths.ensure_dir("cloud_shadows_v1")
	if OS.get_cmdline_user_args().has("--capture-only"):
		await _capture_moving_shadow(weather, field, sun, camera, folder)
		quit()
		return
	var results: Array[Dictionary] = []
	print("[云影基准] GPU=%s 阴影距离=%.1f 分级=%d 分辨率=%s" % [
		RenderingServer.get_video_adapter_name(), sun.directional_shadow_max_distance,
		sun.directional_shadow_mode, root.size])
	for coverage in [0.21, 0.80]:
		weather.cloud_coverage = coverage
		weather.set("_cloud_level", coverage)
		weather.call("_sync_extra_layers")
		weather.call("_update_environment")
		weather.call("_apply_stylized_cloud_field")
		field.call("_update_transforms")
		for trial in range(6):
			var mode: String = ["off", "hard", "soft"][trial % 3]
			var enabled := mode != "off"
			weather.cloud_shadow_enabled = enabled
			weather.call("_apply_stylized_cloud_field")
			if mode == "hard":
				sun.light_angular_distance = 0.0
			for _frame in range(WARMUP_FRAMES):
				await RenderingServer.frame_post_draw
			var gpu: Array[float] = []
			var cpu: Array[float] = []
			var frames: Array[float] = []
			var draws := 0.0
			var triangles := 0.0
			var previous := Time.get_ticks_usec()
			for _frame in range(SAMPLE_FRAMES):
				await RenderingServer.frame_post_draw
				var now := Time.get_ticks_usec()
				frames.append((now - previous) / 1000.0)
				previous = now
				gpu.append(RenderingServer.viewport_get_measured_render_time_gpu(viewport))
				cpu.append(RenderingServer.viewport_get_measured_render_time_cpu(viewport))
				draws += RenderingServer.viewport_get_render_info(viewport, RenderingServer.VIEWPORT_RENDER_INFO_TYPE_SHADOW, RenderingServer.VIEWPORT_RENDER_INFO_DRAW_CALLS_IN_FRAME)
				triangles += RenderingServer.viewport_get_render_info(viewport, RenderingServer.VIEWPORT_RENDER_INFO_TYPE_SHADOW, RenderingServer.VIEWPORT_RENDER_INFO_PRIMITIVES_IN_FRAME)
			var result := {"coverage": coverage, "cloud_scale": 3.0, "real_shadow": enabled,
				"mode": mode, "sun_angle_degrees": sun.light_angular_distance,
				"shadow_depth_padding": sun.directional_shadow_pancake_size,
				"trial": trial, "gpu_ms_median": _median(gpu), "render_cpu_ms_median": _median(cpu),
				"frame_ms_median": _median(frames), "shadow_draws": draws / SAMPLE_FRAMES,
				"shadow_triangles": triangles / SAMPLE_FRAMES}
			results.append(result)
			print("[云影基准] ", JSON.stringify(result))
			if trial < 3:
				root.get_texture().get_image().save_png(folder.path_join("cover_%02d_%s.png" % [roundi(coverage * 100), mode]))
	var report := FileAccess.open(folder.path_join("benchmark.json"), FileAccess.WRITE)
	report.store_string(JSON.stringify({"gpu": RenderingServer.get_video_adapter_name(),
		"resolution": [root.size.x, root.size.y], "shadow_distance": sun.directional_shadow_max_distance,
		"shadow_mode": sun.directional_shadow_mode, "simulation_frozen": true,
		"warmup_frames": WARMUP_FRAMES, "sample_frames": SAMPLE_FRAMES,
		"godot": Engine.get_version_info().string, "results": results}, "\t"))
	report.close()
	await _capture_moving_shadow(weather, field, sun, camera, folder)
	quit()


func _capture_moving_shadow(weather: Node, field: Node3D, sun: DirectionalLight3D, camera: Camera3D, folder: String) -> void:
	weather.cloud_coverage = 0.35
	weather.cloud_density = 0.2
	weather.cloud_size_multiplier = 0.5
	weather.cloud_wind_speed = 7.5
	weather.cloud_shadow_enabled = true
	weather.set("_cloud_level", 0.35)
	weather.set("_cloud_density_level", 0.2)
	weather.call("_sync_extra_layers")
	weather.call("_update_environment")
	weather.call("_apply_stylized_cloud_field")
	camera.global_position = Vector3(0, 35, 30)
	camera.look_at(Vector3(0, 0, -10))
	var observer := Vector2(camera.position.x, camera.position.z)
	var toward_sun := sun.global_basis.z.normalized()
	var nearest := -1
	var best_distance := INF
	var shift := Vector2.ZERO
	# 诊断机位孤立已有一团云，将其投影边缘移到视野中；不修改基础网格。
	for index in range(field.get("_clouds").size()):
		var transform: Transform3D = field.call("get_cloud_transform", index, observer)
		if transform.basis.x.length() < 0.1:
			continue
		var foot := transform.origin - toward_sun * transform.origin.y / maxf(toward_sun.y, 0.1)
		var correction := Vector2(80, -10) - Vector2(foot.x, foot.z)
		if correction.length_squared() < best_distance:
			best_distance = correction.length_squared()
			nearest = index
			shift = correction
	if nearest >= 0:
		var clouds: Array = field.get("_clouds")
		var offsets: Array[Vector2] = field.get("_layer_offsets")
		var selected: Dictionary = clouds[nearest]
		var transform: Transform3D = field.call("get_cloud_transform", nearest, observer)
		var batch := field.get_child(int(selected.batch)) as MultiMeshInstance3D
		var vertices: PackedVector3Array = batch.multimesh.mesh.surface_get_arrays(0)[Mesh.ARRAY_VERTEX]
		var minimum := Vector2(INF, INF)
		var maximum := Vector2(-INF, -INF)
		for vertex in vertices:
			var point := transform * vertex
			var foot := point - toward_sun * point.y / maxf(toward_sun.y, 0.1)
			minimum = minimum.min(Vector2(foot.x, foot.z))
			maximum = maximum.max(Vector2(foot.x, foot.z))
		shift = Vector2(-15.0 - (minimum.x + maximum.x) * 0.5, -15.0 - (minimum.y + maximum.y) * 0.5)
		offsets[int(clouds[nearest].layer)] += shift
		field.set("_layer_offsets", offsets)
	field.call("_update_transforms")
	var energy := sun.light_energy
	for shot in ["isolated_edge_hard", "isolated_depth_20", "isolated_edge_strong", "isolated_edge_weak", "isolated_motion_12_seconds"]:
		sun.light_energy = energy * 0.20 if shot == "isolated_edge_weak" else energy
		CloudLighting.apply_cloud_shadow_softness(weather, sun, 0.0, true, 20.0, field.call("get_cloud_height_ceiling"))
		if shot == "isolated_edge_hard":
			sun.light_angular_distance = 0.0
		if shot == "isolated_depth_20":
			sun.directional_shadow_pancake_size = 20.0
		if shot == "isolated_motion_12_seconds":
			field.call("_process", 12.0)
		_isolate_cloud(field, nearest)
		for _frame in range(8):
			await RenderingServer.frame_post_draw
		root.get_texture().get_image().save_png(folder.path_join(shot + ".png"))
		print("[云影边缘/移动截图] ", folder.path_join(shot + ".png"), " angle=", sun.light_angular_distance)


func _isolate_cloud(field: Node3D, selected: int) -> void:
	var clouds: Array = field.get("_clouds")
	for index in range(clouds.size()):
		if index == selected:
			continue
		var cloud: Dictionary = clouds[index]
		var batch := field.get_child(int(cloud.batch)) as MultiMeshInstance3D
		batch.multimesh.set_instance_transform(int(cloud.slot), Transform3D(Basis.from_scale(Vector3.ZERO), Vector3.ZERO))


func _median(values: Array[float]) -> float:
	values.sort()
	return values[values.size() / 2]
