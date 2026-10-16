extends SceneTree
## 主场景真实碰撞 / 导航回归，不包含攻击或投放逻辑。
const Lab := preload("res://prototypes/navigation_lab/navigation_lab.tscn")
const Query := preload("res://scripts/spatial_query.gd")
const Paths := preload("res://scripts/artifact_paths.gd")
var failed := false
var evidence: Array = []
func _initialize() -> void:
	call_deferred("_run")
func _run() -> void:
	var lab := Lab.instantiate()
	# 保留最初失败样本的 12 个环形起点；大规模覆盖由压力测试独立承担。
	lab.count = 12
	lab.full_area = false
	root.add_child(lab)
	current_scene = lab
	for frame in range(1200):
		if lab.ready_for_test: break
		await process_frame
	_check(lab.ready_for_test, "导航服务器同步后才能启动测量")
	if not lab.ready_for_test:
		quit(1)
		return
	_check(get_nodes_in_group("enemies").is_empty() and get_nodes_in_group("players").is_empty(), "测试入口不投放敌人 / 玩家")
	lab.started = true
	for seed_value: int in [64768, 90210, 314159]:
		lab.seed_value = seed_value
		lab.replay()
		var frames := 0
		for frame in range(3600):
			await physics_frame
			frames = frame
			var arrived := 0
			for actor in lab.actors: arrived += int(actor.reached)
			if arrived == lab.actors.size(): break
		var rows: Array = []
		_check(lab.actors.size() == lab.count, "连通区域中必须完成全部投放")
		for actor in lab.actors:
			rows.append(actor.snapshot())
			_check(actor.reached, "种子 %d / %s 未到达：%s" % [seed_value, actor.name, actor.snapshot()])
		evidence.append({"seed": seed_value, "frames": frames, "spawn_adjustments": lab.spawn_adjustments, "actors": rows})
		print("[主场景导航] seed=", seed_value, " frames=", frames)
	lab.clear_actors()
	await _drop_boundaries()
	var path := Paths.ensure_dir("reports").path_join("navigation_acceptance.json")
	var file := FileAccess.open(path, FileAccess.WRITE)
	if file == null:
		_check(false, "无法写入导航验收证据")
	else:
		file.store_string(JSON.stringify(evidence, "\t"))
	current_scene = null
	lab.queue_free()
	await process_frame
	print("[主场景导航] ", "FAIL" if failed else "PASS")
	quit(1 if failed else 0)

func _check(condition: bool, message: String) -> void:
	if not condition:
		failed = true
		push_error("[主场景导航] " + message)

func _drop_boundaries() -> void:
	for drop: float in [0.2, 0.65]:
		var stage := Node3D.new()
		stage.position.x = 260
		root.add_child(stage)
		_box(stage, Vector3(-2, -0.5, 0), Vector3(4, 1, 4))
		_box(stage, Vector3(2, -0.5 - drop, 0), Vector3(4, 1, 4))
		var body := CharacterBody3D.new()
		var collision := CollisionShape3D.new()
		var capsule := CapsuleShape3D.new()
		capsule.radius = 0.52
		capsule.height = 2
		collision.shape = capsule
		body.add_child(collision)
		body.position = Vector3(-2, 1.05, 0)
		body.collision_layer = 4
		body.collision_mask = 1
		stage.add_child(body)
		await physics_frame
		var allowed := Query.ground_segment(body, body.global_position, stage.to_global(Vector3(2, 1.05 - drop, 0)), 0.3)
		_check(allowed == (drop < 0.3), "地面下探：%.2fm 下降 / 可通行=%s" % [drop, allowed])
		stage.free()

func _box(stage: Node3D, at: Vector3, size: Vector3) -> void:
	var body := StaticBody3D.new()
	body.position = at
	body.collision_layer = 1
	var collision := CollisionShape3D.new()
	var shape := BoxShape3D.new()
	shape.size = size
	collision.shape = shape
	body.add_child(collision)
	stage.add_child(body)
