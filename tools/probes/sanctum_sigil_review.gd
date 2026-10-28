extends SceneTree
## 主祭坛圣徽固定机位截图：检查鲸形标志的轮廓、黑白对比与嵌入石框的关系。
## 只加载正式场景，不生成地图、不启动战斗。

const Artifacts := preload("res://scripts/artifact_paths.gd")
const LEVEL := preload("res://prototypes/sanctum_arena/sanctum_arena.tscn")

const WIDTH := 1600
const HEIGHT := 900


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
	camera.name = "SigilReviewCamera"
	camera.far = 2600.0
	camera.near = 0.05
	scene.add_child(camera)
	camera.make_current()
	var directory := Artifacts.ensure_dir("screenshots")
	var report: Array = []
	for view in _views():
		var spec: Dictionary = view
		camera.projection = Camera3D.PROJECTION_PERSPECTIVE
		camera.fov = float(spec.get("fov", 50.0))
		camera.global_position = spec.position
		camera.look_at(spec.target, Vector3.UP)
		for _frame in 4:
			await RenderingServer.frame_post_draw
		var path := directory.path_join(String(spec.name) + ".png")
		if root.get_texture().get_image().save_png(path) != OK:
			push_error("截图失败：" + path)
			quit(1)
			return
		report.append({"name": spec.name, "path": path})
		print("[圣徽截图] ", spec.name, " -> ", path)
	var file := FileAccess.open(
		Artifacts.ensure_dir("reports").path_join("sanctum_sigil_review.json"), FileAccess.WRITE)
	if file != null:
		file.store_string(JSON.stringify({"views": report,
			"scene": "res://prototypes/sanctum_arena/sanctum_arena.tscn"}, "\t") + "\n")
		file.close()
	quit()


func _views() -> Array:
	return [
		# 中殿纵深：圣徽、圣晶、祭坛一起读。
		{"name": "01_nave_sign", "position": Vector3(0, 1.7, -13.0),
			"target": Vector3(0, 4.9, -35.3), "fov": 60},
		# 玩家走到祭坛前的真实视角：圣晶会挡住中下部，检查还剩下多少轮廓。
		{"name": "02_altar_eye", "position": Vector3(0, 1.7, -25.5),
			"target": Vector3(0, 4.4, -35.3), "fov": 52},
		# 与标志同高、避开圣晶的正面：用于和参考图逐项对照轮廓。
		{"name": "03_sign_flat", "position": Vector3(0, 4.6, -28.0),
			"target": Vector3(0, 4.9, -35.3), "fov": 40},
		{"name": "04_sign_three_quarter", "position": Vector3(3.8, 4.2, -28.5),
			"target": Vector3(0, 4.9, -35.3), "fov": 42},
		{"name": "05_sign_close", "position": Vector3(0.5, 4.9, -31.8),
			"target": Vector3(0, 4.9, -35.3), "fov": 45},
		# 祭坛全景：确认石框、金环、雪花石底板与墙面的关系。
		{"name": "06_altar_wide", "position": Vector3(2.2, 2.2, -21.5),
			"target": Vector3(0, 3.4, -33.0), "fov": 60},
		# 祭坛陈设：亚麻台布、深红前帷、六支蜡烛与圣晶石座。
		{"name": "07_altar_side", "position": Vector3(4.2, 2.4, -26.0),
			"target": Vector3(0, 1.5, -31.5), "fov": 52},
		# 石框左下角的修缮细节：补石与铁锔子。
		{"name": "08_staple_detail", "position": Vector3(2.4, 3.6, -31.4),
			"target": Vector3(-1.5, 3.1, -35.2), "fov": 36},
	]
