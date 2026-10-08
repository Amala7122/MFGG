extends SceneTree
## 手动视觉检查：在天气实验场固定机位拍摄稀疏、多云、厚云和夜间状态。
## 运行：godot --path . --script res://tools/probes/cloud_field_capture.gd

const CapturePaths := preload("res://scripts/capture_paths.gd")


func _initialize() -> void:
	change_scene_to_file("res://prototypes/environment/weather_lab.tscn")
	call_deferred("_capture")


func _capture() -> void:
	for _frame in range(30):
		await process_frame
	paused = false
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	var scene := current_scene
	var weather := scene.get_node("WeatherEnvironment/WeatherSystem")
	weather.rain_enabled = false
	weather.fog_enabled = false
	weather.cloud_enabled = true
	weather.set_process(false)
	var field := weather.get_node("ProceduralCloudField")
	field.set_process(false)
	field.set("_layer_offsets", [Vector2.ZERO, Vector2.ZERO] as Array[Vector2])
	field.set("_clock", 0.0)
	var sky := scene.get_node("WeatherEnvironment/Sky3D")
	sky.set("game_time_enabled", false)
	var time := sky.get_node("TimeOfDay")
	time.set("game_time_enabled", false)
	for canvas in root.find_children("*", "CanvasLayer", true, false):
		(canvas as CanvasLayer).hide()
	var camera := Camera3D.new()
	scene.add_child(camera)
	camera.global_position = Vector3(0.0, 12.0, 24.0)
	camera.look_at(Vector3(-90.0, 175.0, -600.0))
	camera.fov = 75.0
	camera.far = 2500.0
	camera.make_current()
	root.size = Vector2i(1280, 720)
	var folder := CapturePaths.ensure_dir("procedural_clouds_v1")
	DirAccess.make_dir_recursive_absolute(folder)
	var shots := [
		["01_sparse", 0.21, 0.0, 8.77],
		["02_cloudy", 0.48, 0.5, 8.77],
		["03_overcast", 0.80, 0.7, 8.77],
		["04_storm", 1.0, 1.0, 8.77],
		["05_night", 0.48, 0.5, 21.33],
		["06_cloud_detail", 0.48, 0.5, 8.77],
		["07_models_on_ground", 0.0, 0.0, 8.77],
		["08_rounded_preserved", 0.0, 0.0, 8.77],
	]
	for shot in shots:
		if shot[0] == "06_cloud_detail":
			camera.look_at(Vector3(-90.0, 430.0, -600.0))
		if shot[0] == "07_models_on_ground":
			camera.global_position = Vector3(0.0, 23.0, 102.0)
			camera.look_at(Vector3(0.0, 3.0, 66.5))
		if shot[0] == "08_rounded_preserved":
			weather.cloud_shape_style = 1
		sky.set("current_time", shot[3])
		time.set("current_time", shot[3])
		weather.cloud_type = 1 if float(shot[1]) > 0.55 else 0
		weather.cloud_coverage = shot[1]
		weather.cloud_density = shot[2]
		weather.set("_cloud_level", shot[1])
		weather.set("_cloud_density_level", shot[2])
		weather.call("_sync_extra_layers")
		weather.call("_update_environment")
		weather.call("_apply_stylized_cloud_field")
		scene.get_node("CloudModelGallery").call("_build")
		field.call("_update_transforms")
		for _frame in range(8):
			await process_frame
		await RenderingServer.frame_post_draw
		var path := folder.path_join(String(shot[0]) + ".png")
		root.get_texture().get_image().save_png(path)
		print("[云场截图] ", path)
	quit()
