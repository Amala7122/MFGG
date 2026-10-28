extends SceneTree
## 圣所关卡/美术评审用固定机位截图：正式主场景、真实天气与地图生成。
##
## 只读：不启动波次、不生成玩家、不改配置。输出眼高视角、构图视角、俯视布局，
## 以及一张标出刷怪锚点 / 地形压平区 / 玩家出生点的诊断俯视图。

const Artifacts := preload("res://scripts/artifact_paths.gd")
const Terrain := preload("res://scripts/terrain_field.gd")

const WIDTH := 1920
const HEIGHT := 1080

var _arena: Dictionary = {}


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	var parsed: Variant = JSON.parse_string(
		FileAccess.get_file_as_string("res://data/game_config.json")
	)
	if not parsed is Dictionary:
		push_error("无法读取 game_config.json")
		quit(1)
		return
	_arena = (parsed as Dictionary).get("arenas", {}).get("definitions", {}).get("sanctum", {})
	if _arena.is_empty():
		push_error("缺少 sanctum 竞技场定义")
		quit(1)
		return

	DisplayServer.window_set_size(Vector2i(WIDTH, HEIGHT))
	root.size = Vector2i(WIDTH, HEIGHT)
	var scene := load("res://scenes/sanctum_main.tscn").instantiate() as Node3D
	root.add_child(scene)
	current_scene = scene
	for _frame in 90:
		await process_frame
	# 菜单/开始画面会压暗画面，隐藏所有 CanvasLayer 只留世界。
	for canvas in root.find_children("*", "CanvasLayer", true, false):
		(canvas as CanvasLayer).hide()
	# 冻结昼夜与天气：同一时刻、同一套云，机位之间唯一变量就是位置。
	var weather := scene.get_node_or_null("WeatherEnvironment/WeatherSystem")
	var sky := scene.get_node_or_null("WeatherEnvironment/Sky3D")
	if weather != null:
		weather.set("rain_enabled", false)
		weather.set("fog_enabled", false)
		weather.set("snow_enabled", false)
	if sky != null:
		var clock := sky.get_node_or_null("TimeOfDay")
		if clock != null:
			clock.call("pause")
			clock.set("current_time", 11.83)
		sky.set("current_time", 11.83)
		sky.set("tonemap_exposure", 0.94)
	paused = true

	var camera := Camera3D.new()
	camera.name = "ReviewCamera"
	camera.far = 3000.0
	scene.add_child(camera)
	camera.make_current()

	var views := _views()
	var directory := Artifacts.ensure_dir("screenshots")
	var report: Array = []
	for view in views:
		var spec: Dictionary = view
		if not bool(spec.get("ortho", false)):
			camera.projection = Camera3D.PROJECTION_PERSPECTIVE
			camera.fov = float(spec.get("fov", 68.0))
		else:
			camera.projection = Camera3D.PROJECTION_ORTHOGONAL
			camera.size = float(spec.get("size", 200.0))
		var target: Vector3 = spec.get("target", Vector3.ZERO)
		var position: Vector3 = spec.get("position", Vector3.ZERO)
		camera.global_position = position
		var up: Vector3 = spec.get("up", Vector3.UP)
		camera.look_at(target, up)
		for _frame in 4:
			await RenderingServer.frame_post_draw
		var path := directory.path_join(String(spec.get("name", "view")) + ".png")
		var image := root.get_texture().get_image()
		if image.save_png(path) != OK:
			push_error("截图保存失败：" + path)
			quit(1)
			return
		report.append({"name": spec.get("name"), "path": path,
			"position": position, "target": target, "fov": spec.get("fov", 0)})
		print("[评审截图] ", spec.get("name"), " -> ", path)

	# 诊断俯视：先拍干净的，再拍标记过的。
	await _capture_marked(camera, directory, report)
	var file := FileAccess.open(
		Artifacts.ensure_dir("reports").path_join("sanctum_review.json"), FileAccess.WRITE
	)
	if file != null:
		file.store_string(JSON.stringify({
			"views": report,
			"spawn_origin": _arena.get("map", {}).get("spawn_origin", []),
			"mask_rects": _arena.get("mask_rects", []),
			"mask_circles": _arena.get("mask_circles", []),
			"cover": _arena.get("cover", []),
			"extent": _arena.get("extent", 0.0),
		}, "\t") + "\n")
		file.close()
	quit()


func _views() -> Array:
	return [
		{"name": "01_spawn_eye", "position": Vector3(0.0, 1.75, 46.0),
			"target": Vector3(3.0, 4.5, -20.0), "fov": 70.0},
		{"name": "02_approach_wide", "position": Vector3(0.0, 3.4, 60.0),
			"target": Vector3(3.0, 7.0, -30.0), "fov": 64.0},
		{"name": "03_court_from_south", "position": Vector3(2.0, 1.8, 24.0),
			"target": Vector3(3.0, 6.0, -36.0), "fov": 70.0},
		{"name": "04_court_center", "position": Vector3(0.0, 1.8, -2.0),
			"target": Vector3(3.0, 8.0, -40.0), "fov": 70.0},
		{"name": "05_court_look_south", "position": Vector3(0.0, 1.8, -20.0),
			"target": Vector3(0.0, 3.0, 46.0), "fov": 70.0},
		{"name": "06_gate_low", "position": Vector3(3.0, 1.6, -16.0),
			"target": Vector3(3.0, 9.0, -35.5), "fov": 64.0},
		{"name": "07_gate_threshold", "position": Vector3(3.0, 1.75, -31.0),
			"target": Vector3(3.0, 3.0, -47.0), "fov": 70.0},
		{"name": "08_altar_from_gate", "position": Vector3(3.0, 1.75, -37.5),
			"target": Vector3(3.0, 2.2, -45.0), "fov": 70.0},
		{"name": "09_altar_from_rear", "position": Vector3(3.0, 1.75, -55.0),
			"target": Vector3(3.0, 2.2, -45.0), "fov": 70.0},
		{"name": "10_rear_gate", "position": Vector3(3.0, 1.75, -47.0),
			"target": Vector3(3.0, 9.0, -58.0), "fov": 66.0},
		{"name": "11_east_branch", "position": Vector3(12.0, 1.8, 2.0),
			"target": Vector3(48.0, 4.0, 2.0), "fov": 68.0},
		{"name": "12_west_chapel", "position": Vector3(-10.0, 1.8, 2.0),
			"target": Vector3(-36.0, 3.2, 2.0), "fov": 68.0},
		{"name": "13_red_altar", "position": Vector3(16.0, 1.8, 13.0),
			"target": Vector3(31.0, 2.6, 13.0), "fov": 66.0},
		{"name": "14_hero_three_quarter", "position": Vector3(52.0, 36.0, 46.0),
			"target": Vector3(0.0, 2.0, -22.0), "fov": 58.0},
		{"name": "15_top_ortho_clean", "position": Vector3(3.0, 260.0, -10.0),
			"target": Vector3(3.0, 0.0, -10.0), "ortho": true, "size": 200.0,
			"up": Vector3(0.0, 0.0, -1.0)},
	]


func _capture_marked(camera: Camera3D, directory: String, report: Array) -> void:
	# 刷怪锚点：与 Arena.generate_spawn_anchors 同一算法（15 个，内外环交替）。
	var holder := Node3D.new()
	holder.name = "ReviewMarkers"
	current_scene.add_child(holder)
	var map: Dictionary = _arena.get("map", {})
	var origin: Array = map.get("spawn_origin", [0.0, 46.0])
	_add_marker(holder, Vector3(float(origin[0]), Terrain.height_at(float(origin[0]), float(origin[1])) + 1.0, float(origin[1])),
		Color(0.15, 1.0, 0.35), 1.4)
	var anchors := _anchors()
	for at in anchors:
		_add_marker(holder, Vector3(at.x, Terrain.height_at(at.x, at.y) + 1.2, at.y),
			Color(0.1, 0.85, 1.0), 0.8)
	for rect in _arena.get("mask_rects", []):
		_add_rect_outline(holder, rect)
	for circle in _arena.get("mask_circles", []):
		_add_circle_outline(holder, circle)
	# 掩体位置：黄，和前两者区分。
	for piece in _arena.get("cover", []):
		var at := Vector2(float(piece[0]), float(piece[1]))
		_add_marker(holder, Vector3(at.x, Terrain.height_at(at.x, at.y) + 0.8, at.y),
			Color(1.0, 0.75, 0.05), 0.55)

	camera.projection = Camera3D.PROJECTION_ORTHOGONAL
	camera.size = 200.0
	camera.global_position = Vector3(3.0, 260.0, -10.0)
	camera.look_at(Vector3(3.0, 0.0, -10.0), Vector3(0.0, 0.0, -1.0))
	for _frame in 4:
		await RenderingServer.frame_post_draw
	var path := directory.path_join("16_top_ortho_marked.png")
	if root.get_texture().get_image().save_png(path) != OK:
		push_error("标记俯视截图保存失败：" + path)
	report.append({"name": "16_top_ortho_marked", "path": path})
	print("[评审截图] 16_top_ortho_marked -> ", path)


func _anchors() -> Array:
	var spec: Dictionary = _arena.get("spawn_anchors", {})
	var count := int(spec.get("count", 0))
	var inner := float(spec.get("radius_min", 20.0))
	var outer := float(spec.get("radius_max", 40.0))
	var rng := RandomNumberGenerator.new()
	# 与 Arena._rng 一致：SEED_BASE + id.hash()。
	rng.seed = 90210 + "sanctum".hash()
	var out: Array = []
	for index in count:
		var angle := TAU * float(index) / float(maxi(count, 1))
		var ring := inner if index % 2 == 0 else outer
		var radius := ring * rng.randf_range(0.94, 1.06)
		var at := Vector2(cos(angle) * radius, sin(angle) * radius)
		# 被压平区挡住时，生成器沿射线每次外推 2 米，最多 12 次。
		for _push in 12:
			if not _masked(at):
				break
			radius += 2.0
			at = Vector2(cos(angle) * radius, sin(angle) * radius)
		out.append(at)
	return out


func _masked(at: Vector2) -> bool:
	for rect in _arena.get("mask_rects", []):
		if at.x > float(rect[0]) and at.x < float(rect[1]) \
			and at.y > float(rect[2]) and at.y < float(rect[3]):
			return true
	for circle in _arena.get("mask_circles", []):
		if at.distance_to(Vector2(float(circle[0]), float(circle[1]))) < float(circle[2]):
			return true
	return false


func _add_marker(holder: Node3D, at: Vector3, color: Color, radius: float) -> void:
	var mesh := SphereMesh.new()
	mesh.radius = radius
	mesh.height = radius * 2.0
	mesh.radial_segments = 8
	mesh.rings = 4
	var material := StandardMaterial3D.new()
	material.albedo_color = color
	material.emission_enabled = true
	material.emission = color
	material.emission_energy_multiplier = 2.0
	material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	var node := MeshInstance3D.new()
	node.mesh = mesh
	node.material_override = material
	node.position = at
	node.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	holder.add_child(node)


func _add_rect_outline(holder: Node3D, rect: Array) -> void:
	var x0 := float(rect[0])
	var x1 := float(rect[1])
	var z0 := float(rect[2])
	var z1 := float(rect[3])
	var color := Color(1.0, 0.2, 0.85)
	_add_bar(holder, Vector3((x0 + x1) * 0.5, 1.6, z0), Vector3(x1 - x0, 0.08, 0.22), color)
	_add_bar(holder, Vector3((x0 + x1) * 0.5, 1.6, z1), Vector3(x1 - x0, 0.08, 0.22), color)
	_add_bar(holder, Vector3(x0, 1.6, (z0 + z1) * 0.5), Vector3(0.22, 0.08, z1 - z0), color)
	_add_bar(holder, Vector3(x1, 1.6, (z0 + z1) * 0.5), Vector3(0.22, 0.08, z1 - z0), color)


func _add_circle_outline(holder: Node3D, circle: Array) -> void:
	var center := Vector2(float(circle[0]), float(circle[1]))
	var radius := float(circle[2])
	var segments := 48
	var color := Color(1.0, 0.2, 0.85)
	for index in segments:
		var angle := TAU * float(index) / float(segments)
		var at := center + Vector2(cos(angle), sin(angle)) * radius
		_add_bar(holder, Vector3(at.x, 1.6, at.y), Vector3(0.22, 0.08, radius * TAU / segments * 1.15),
			color, -angle)


func _add_bar(holder: Node3D, at: Vector3, size: Vector3, color: Color, yaw: float = 0.0) -> void:
	var mesh := BoxMesh.new()
	mesh.size = size
	var material := StandardMaterial3D.new()
	material.albedo_color = color
	material.emission_enabled = true
	material.emission = color
	material.emission_energy_multiplier = 2.0
	material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	var node := MeshInstance3D.new()
	node.mesh = mesh
	node.material_override = material
	node.position = at
	node.rotation.y = yaw
	node.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	holder.add_child(node)
