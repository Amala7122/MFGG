extends SceneTree
## 需要图形渲染：对照相同接收面，检查高空两层不透明云的阴影合并与边缘。

const Library := preload("res://scripts/cloud_mesh_library.gd")
const CloudShader := preload("res://shaders/procedural_cloud.gdshader")
const Lighting := preload("res://scripts/cloud_lighting.gd")
const Weather := preload("res://scripts/weather_system.gd")
const CapturePaths := preload("res://scripts/capture_paths.gd")
var _failed := false


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	if DisplayServer.get_name() == "headless":
		push_error("云影像素检查需要真实图形渲染器，不能使用 --headless。")
		quit(1)
		return
	for _frame in range(3):
		await process_frame
	paused = true
	root.size = Vector2i(800, 600)
	for canvas in root.find_children("*", "CanvasLayer", true, false):
		(canvas as CanvasLayer).hide()
	var scene := Node3D.new()
	root.add_child(scene)
	current_scene = scene
	var environment := WorldEnvironment.new()
	environment.environment = Environment.new()
	environment.environment.background_mode = Environment.BG_COLOR
	environment.environment.background_color = Color(0.3, 0.4, 0.5)
	environment.environment.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	environment.environment.ambient_light_color = Color.WHITE
	environment.environment.ambient_light_energy = 0.35
	scene.add_child(environment)
	var ground := MeshInstance3D.new()
	var plane := PlaneMesh.new()
	plane.size = Vector2(180, 180)
	ground.mesh = plane
	ground.material_override = StandardMaterial3D.new()
	ground.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	scene.add_child(ground)
	var sun := DirectionalLight3D.new()
	scene.add_child(sun)
	var direction := Vector3(0.4, 0.9, 0.1).normalized()
	sun.look_at_from_position(Vector3.ZERO, -direction)
	sun.light_energy = 1.5
	sun.shadow_enabled = true
	sun.shadow_opacity = 1.0
	sun.shadow_blur = 1.0
	sun.shadow_normal_bias = 0.0
	sun.directional_shadow_mode = DirectionalLight3D.SHADOW_ORTHOGONAL
	sun.directional_shadow_max_distance = 90.0
	sun.directional_shadow_fade_start = 0.95
	var material := ShaderMaterial.new()
	material.shader = CloudShader
	var lower := _cloud(scene, material, direction, 300.0)
	var upper := _cloud(scene, material, direction, 415.0)
	var camera := Camera3D.new()
	scene.add_child(camera)
	camera.position = Vector3(0, 32, 40)
	camera.look_at(Vector3.ZERO)
	camera.fov = 65.0
	camera.make_current()
	var weather := Weather.new()
	Lighting.apply_cloud_shadow_softness(weather, sun, 0.0, true, 20.0, 650.0)
	var folder := CapturePaths.ensure_dir("cloud_shadow_layers")
	var images: Dictionary = {}
	for mode in ["clear", "lower", "upper", "overlap", "upper_cross", "cross"]:
		lower.visible = mode in ["lower", "overlap", "cross"]
		upper.visible = mode in ["upper", "overlap", "upper_cross", "cross"]
		upper.position = direction * 415.0 / direction.y
		if mode in ["upper_cross", "cross"]:
			upper.position.x += 25.0
		for _frame in range(12):
			await RenderingServer.frame_post_draw
		var picture := root.get_texture().get_image()
		images[mode] = picture
		picture.save_png(folder.path_join(mode + ".png"))
	var aligned := _check_overlap(images.clear, images.lower, images.upper, images.overlap)
	var crossed := _check_overlap(images.clear, images.lower, images.upper_cross, images.cross)
	# 高云的柔度也应随阳光强弱变化。
	lower.visible = true
	upper.visible = false
	sun.light_energy = 0.3
	Lighting.apply_cloud_shadow_softness(weather, sun, 0.0, true, 20.0, 650.0)
	for _frame in range(12):
		await RenderingServer.frame_post_draw
	root.get_texture().get_image().save_png(folder.path_join("weak_sun.png"))
	var report := FileAccess.open(folder.path_join("checks.json"), FileAccess.WRITE)
	report.store_string(JSON.stringify({"aligned": aligned, "crossed": crossed,
		"weak_sun_angle": sun.light_angular_distance, "depth": sun.directional_shadow_pancake_size}, "\t"))
	report.close()
	weather.free()
	print("[云影渲染测试] %s；重合 %s，交错 %s" % [
		"通过" if not _failed else "失败", JSON.stringify(aligned), JSON.stringify(crossed)])
	quit(1 if _failed else 0)


func _cloud(scene: Node3D, material: ShaderMaterial, direction: Vector3, height: float) -> MeshInstance3D:
	var cloud := MeshInstance3D.new()
	cloud.mesh = Library.get_meshes()[0]
	cloud.material_override = material
	cloud.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_SHADOWS_ONLY
	cloud.scale = Vector3.ONE * 0.30
	cloud.position = direction * height / direction.y
	scene.add_child(cloud)
	return cloud


func _check_overlap(clear: Image, lower: Image, upper: Image, overlap: Image) -> Dictionary:
	var differences: Array[float] = []
	var blocked := 0
	for y in range(120, 520, 4):
		for x in range(100, 700, 4):
			var clean := clear.get_pixel(x, y).get_luminance()
			var low := lower.get_pixel(x, y).get_luminance()
			var high := upper.get_pixel(x, y).get_luminance()
			var combined := overlap.get_pixel(x, y).get_luminance()
			if clean - combined > 0.05:
				blocked += 1
			# 两层都完全遮光的内部区域；排除本来就有不同半影的边缘。
			if clean - low > 0.08 and clean - high > 0.08 and absf(low - high) < 0.008:
				differences.append(minf(low, high) - combined)
	if blocked < 100 or differences.size() < 30:
		_failed = true
		push_error("云影缺少完整遮光区域或重叠核心：blocked=%d core=%d" % [blocked, differences.size()])
		return {"blocked": blocked, "core_samples": differences.size()}
	differences.sort()
	var median := differences[differences.size() / 2]
	if absf(median) > 0.015:
		_failed = true
		push_error("两层完全遮光区域出现重复变暗或漏光：差值=%.4f" % median)
	return {"blocked": blocked, "core_samples": differences.size(), "median_extra_darkness": median}
