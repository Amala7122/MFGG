extends SceneTree
## 寂石圣所地形优先体块：固定机位截图。只加载静态场景，不生成地形。

const Artifacts := preload("res://scripts/artifact_paths.gd")
const LEVEL := preload("res://prototypes/jishi_terrain/jishi_terrain.tscn")
const WIDTH := 1920
const HEIGHT := 1080


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	DisplayServer.window_set_size(Vector2i(WIDTH, HEIGHT))
	root.size = Vector2i(WIDTH, HEIGHT)
	var scene := LEVEL.instantiate() as Node3D
	root.add_child(scene)
	current_scene = scene
	for _frame in 60:
		await process_frame
	for canvas in root.find_children("*", "CanvasLayer", true, false):
		(canvas as CanvasLayer).hide()
	paused = true
	var camera := Camera3D.new()
	camera.name = "ReviewCamera"
	camera.far = 2600.0
	scene.add_child(camera)
	camera.make_current()
	var directory := Artifacts.ensure_dir("screenshots")
	var report: Array = []
	for view in _views():
		var spec: Dictionary = view
		if bool(spec.get("ortho", false)):
			camera.projection = Camera3D.PROJECTION_ORTHOGONAL
			camera.size = float(spec.get("size", 200.0))
		else:
			camera.projection = Camera3D.PROJECTION_PERSPECTIVE
			camera.fov = float(spec.get("fov", 70.0))
		camera.global_position = spec.position
		camera.look_at(spec.target, spec.get("up", Vector3.UP))
		for _frame in 4:
			await RenderingServer.frame_post_draw
		var path := directory.path_join(String(spec.name) + ".png")
		if root.get_texture().get_image().save_png(path) != OK:
			push_error("capture failed: " + path)
			quit(1)
			return
		report.append({"name": spec.name, "path": path})
		print("[JishiTerrain] ", spec.name, " -> ", path)
	var file := FileAccess.open(
		Artifacts.ensure_dir("reports").path_join("jishi_terrain_review.json"), FileAccess.WRITE)
	if file != null:
		file.store_string(JSON.stringify({"views": report,
			"scene": "res://prototypes/jishi_terrain/jishi_terrain.tscn"}, "\t") + "\n")
		file.close()
	quit()


func _views() -> Array:
	return [
		{"name": "01_approach", "position": Vector3(-15, 10, 108), "target": Vector3(8, 30, 4), "fov": 68},
		{"name": "02_switchback", "position": Vector3(-20, 18, 82), "target": Vector3(0, 30, 34), "fov": 70},
		{"name": "03_hero", "position": Vector3(-50, 45, 135), "target": Vector3(0, 30, 0), "fov": 55},
		{"name": "04_west_cloister", "position": Vector3(-95, 55, 35), "target": Vector3(-43, 31, -8), "fov": 66},
		{"name": "05_east_service", "position": Vector3(90, 45, 35), "target": Vector3(42, 31, -8), "fov": 66},
		{"name": "06_top", "position": Vector3(0, 250, 0), "target": Vector3(0, 0, 0),
			"ortho": true, "size": 240, "up": Vector3(0, 0, -1)},
		{"name": "07_gate", "position": Vector3(-10, 40, 65), "target": Vector3(-4, 31, 30), "fov": 70},
		{"name": "08_open_side", "position": Vector3(-110, 55, 90), "target": Vector3(0, 30, 0), "fov": 58},
	]
