extends SceneTree
## 「圣所回廊试作」固定机位截图：正式场景本身，不生成地图、不启动战斗。

const Artifacts := preload("res://scripts/artifact_paths.gd")
const LEVEL := preload("res://prototypes/sanctum_arena/sanctum_arena.tscn")

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
			camera.size = float(spec.get("size", 120.0))
		else:
			camera.projection = Camera3D.PROJECTION_PERSPECTIVE
			camera.fov = float(spec.get("fov", 70.0))
		camera.global_position = spec.position
		camera.look_at(spec.target, spec.get("up", Vector3.UP))
		for _frame in 4:
			await RenderingServer.frame_post_draw
		var path := directory.path_join(String(spec.name) + ".png")
		if root.get_texture().get_image().save_png(path) != OK:
			push_error("截图失败：" + path)
			quit(1)
			return
		report.append({"name": spec.name, "path": path})
		print("[圣所回廊截图] ", spec.name, " -> ", path)
	var file := FileAccess.open(
		Artifacts.ensure_dir("reports").path_join("sanctum_arena_review.json"), FileAccess.WRITE)
	if file != null:
		file.store_string(JSON.stringify({"views": report,
			"scene": "res://prototypes/sanctum_arena/sanctum_arena.tscn"}, "\t") + "\n")
		file.close()
	quit()


func _views() -> Array:
	return [
		{"name": "01_spawn", "position": Vector3(0, 1.7, 54), "target": Vector3(0, 4.5, 30), "fov": 70},
		{"name": "02_gate", "position": Vector3(0, 1.7, 39), "target": Vector3(0, 6.5, 30), "fov": 64},
		{"name": "03_landing", "position": Vector3(0, 1.7, 27), "target": Vector3(0, 3.5, -4), "fov": 72},
		{"name": "04_court", "position": Vector3(0, 1.7, 21), "target": Vector3(0, 5.5, -4), "fov": 70},
		{"name": "05_court_over", "position": Vector3(9, 4.4, 19), "target": Vector3(-2, -0.5, 9), "fov": 66},
		{"name": "06_cloister", "position": Vector3(-25, 1.7, 17), "target": Vector3(0, -0.5, 8), "fov": 70},
		{"name": "07_inner_gate", "position": Vector3(0, 1.7, 4), "target": Vector3(0, 7.5, -4), "fov": 70},
		{"name": "08_nave", "position": Vector3(0, 1.7, -8), "target": Vector3(0, 4.5, -31), "fov": 68},
		{"name": "08b_nave_offset", "position": Vector3(2.6, 1.7, -8), "target": Vector3(0, 4.5, -31), "fov": 68},
		{"name": "09_altar", "position": Vector3(0, 1.7, -23), "target": Vector3(0, 3.4, -32), "fov": 66},
		{"name": "10_hero", "position": Vector3(34, 24, 46), "target": Vector3(0, 0, -4), "fov": 55},
		{"name": "11_chapel", "position": Vector3(-25, 1.7, 12), "target": Vector3(-29, 2.2, 12), "fov": 68},
		{"name": "13_garth_west", "position": Vector3(-22.5, 1.7, -6), "target": Vector3(-24, 2.2, -24), "fov": 70},
		{"name": "14_garth_east", "position": Vector3(22.5, 1.7, -34), "target": Vector3(24, 2.2, -12), "fov": 70},
		{"name": "15_postern_east", "position": Vector3(27.5, 1.7, 26), "target": Vector3(33.5, 1.6, 26), "fov": 66},
		{"name": "16_altar_close", "position": Vector3(0, 1.7, -26), "target": Vector3(0, 3.3, -33), "fov": 62},
		{"name": "17_east_chapel_stair", "position": Vector3(11, 0.2, 18), "target": Vector3(21.5, 1.2, 9.5), "fov": 70},
		{"name": "18_west_range", "position": Vector3(-28.8, 1.6, -22.5), "target": Vector3(-26.4, 1.3, -19.3), "fov": 70},
		{"name": "19_east_refectory", "position": Vector3(28.8, 1.6, -20.5), "target": Vector3(26.2, 1.3, -17.2), "fov": 70},
		{"name": "20_chapter_house", "position": Vector3(-28.5, 1.7, -31.5), "target": Vector3(-25.7, 2.0, -29.0), "fov": 70},
		{"name": "21_hospice", "position": Vector3(-10.0, 1.6, 47.5), "target": Vector3(-7.4, 1.3, 45.4), "fov": 70},
		{"name": "22_stable", "position": Vector3(9.5, 1.6, 48.5), "target": Vector3(7.3, 1.3, 45.4), "fov": 70},
		{"name": "23_cemetery", "position": Vector3(4.0, 1.7, -36.0), "target": Vector3(-18.0, 1.2, -39.0), "fov": 70},
		{"name": "24_breach", "position": Vector3(17.0, 1.7, 17.0), "target": Vector3(23.0, 1.6, 9.0), "fov": 70},
		{"name": "12_top", "position": Vector3(0, 90, 10), "target": Vector3(0, 0, 10),
			"ortho": true, "size": 118, "up": Vector3(0, 0, -1)},
	]
