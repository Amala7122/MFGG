extends SceneTree
## 全区域分层、多目标、多体密度；不修改地图，不预筛掉通行规划失败的路线。
const Lab := preload("res://prototypes/navigation_lab/navigation_lab.tscn")
const Query := preload("res://scripts/spatial_query.gd")
const Style := preload("res://scripts/navigation_path.gd")
const Paths := preload("res://scripts/artifact_paths.gd")
var failed := false
var lab: Node3D
var anchors: Array[Vector3] = []
var coverage: Array = []
var scenarios: Array = []
var target_nodes: Array[Node3D] = []

func _initialize() -> void:
	call_deferred("_run")

func _run() -> void:
	lab = Lab.instantiate()
	root.add_child(lab)
	current_scene = lab
	for frame in range(1200):
		if lab.ready_for_test: break
		await process_frame
	_check(lab.ready_for_test, "主场景必须完成烘焙与同步")
	if not lab.ready_for_test:
		quit(1)
		return
	lab.set_process(false)
	# 观察台默认「未开始」（等用户确认参数），压力测试要自己放行。
	lab.started = true
	lab.paused_motion = false
	lab.clear_actors()
	await _sample_area()
	_check(coverage.size() == 64 and anchors.size() >= 48, "必须查询完整 8×8 区域并取得足够多的有效身体落脚点")
	if anchors.size() < 2:
		quit(1)
		return
	var saved := Style.settings()
	for specification: Dictionary in _specifications():
		Style.apply({"corner_rounding": 2.0, "lane_offset": 1.0, "goal_replan_distance": 0.8} if specification.mode == "wide_style" else saved)
		await _scenario(specification)
	Style.apply(saved)
	var report := {"grid": [8, 8], "extent": lab.Terrain.get_extent(), "coverage": coverage, "scenarios": scenarios,
		"timing_note": "headless fixed-fps=60；帧间墙钟耗时包含引擎物理和导航，不代表含渲染的正式游戏帧率", "passed": not failed}
	var file := FileAccess.open(Paths.ensure_dir("reports").path_join(_report_name()), FileAccess.WRITE)
	if file == null: _check(false, "不能保存压力测试证据")
	else: file.store_string(JSON.stringify(report, "\t"))
	current_scene = null
	lab.queue_free()
	await process_frame
	print("[导航压力] ", "FAIL" if failed else "PASS")
	quit(1 if failed else 0)

func _report_name() -> String:
	return "navigation_stress.json"

func _specifications() -> Array:
	return [
		{"count": 64, "mode": "converge", "seed": 64768},
		{"count": 128, "mode": "cross", "seed": 90210},
		{"count": 256, "mode": "cross", "seed": 314159},
		{"count": 128, "mode": "wide_style", "seed": 90210},
		{"count": 128, "mode": "moving", "seed": 271828},
		{"count": 256, "mode": "lab_full_area", "seed": 161803}
	]

func _sample_area() -> void:
	var probe: CharacterBody3D = lab.spawn_actor(Vector3(0, 2, 0), 0)
	probe.running = false
	var extent: float = lab.Terrain.get_extent()
	var cell := extent * 2.0 / 8.0
	var map := lab.get_world_3d().navigation_map
	for z in range(8):
		for x in range(8):
			var requested := Vector3(-extent + cell * (x + 0.5), 0, -extent + cell * (z + 0.5))
			var accepted := false
			for offset: Vector3 in [Vector3.ZERO, Vector3.RIGHT, Vector3.LEFT, Vector3.FORWARD, Vector3.BACK]:
				var point := NavigationServer3D.map_get_closest_point(map, requested + offset * cell * 0.3)
				if Vector2(point.x - requested.x, point.z - requested.z).length() > cell * 0.48: continue
				var hit := Query.floor_at(probe, point, 1.5)
				if hit.is_empty() or not Query.full_support(probe, hit): continue
				var pose := probe.global_transform
				pose.origin = Query.ground_pose(probe, hit)
				if not Query.motion_clear(probe, pose, Vector3.ZERO): continue
				anchors.append(pose.origin)
				coverage.append({"cell": [x, z], "requested": _vector(requested), "pose": _vector(pose.origin), "valid_spawn": true})
				accepted = true
				break
			if not accepted:
				coverage.append({"cell": [x, z], "requested": _vector(requested), "valid_spawn": false, "reason": "未找到有真实支撑和身体净空的导航面"})
	print("[导航压力] 区域取样 ", anchors.size(), "/64；拒绝项原样保留在报告")
	lab.clear_actors()
	await physics_frame

func _connected(origin: Vector3, destination: Vector3) -> bool:
	var map := lab.get_world_3d().navigation_map
	var from := NavigationServer3D.map_get_closest_point(map, origin - Vector3.UP)
	var end := NavigationServer3D.map_get_closest_point(map, destination - Vector3.UP)
	var path := NavigationServer3D.map_get_path(map, from, end, true)
	return not path.is_empty() and path[path.size() - 1].distance_to(end) < 0.4

func _scenario(specification: Dictionary) -> void:
	lab.clear_actors()
	for target in target_nodes: target.free()
	target_nodes.clear()
	var expected: Array[bool] = []
	var source_indices: Array[int] = []
	var initial: Array = []
	var rng := RandomNumberGenerator.new()
	rng.seed = int(specification.seed)
	var offset := rng.randi_range(1, anchors.size() - 1)
	var central_hit := Query.floor_at(lab, lab.target.position, 0.6)
	for i in range(int(specification.count)):
		var source_index := i % anchors.size()
		var destination_index := (anchors.size() - 1 - source_index + offset) % anchors.size()
		if destination_index == source_index: destination_index = (source_index + int(anchors.size() / 2)) % anchors.size()
		var destination := anchors[destination_index]
		var actor: CharacterBody3D = lab.spawn_actor(anchors[source_index] - Vector3.UP * 1.1, i)
		# 同一分区内的多个体使用不同的真实落脚点，而非重叠复制压力。
		if i >= anchors.size():
			for attempt in range(8):
				var angle := rng.randf() * TAU
				var requested := anchors[source_index] - Vector3.UP + Vector3(cos(angle), 0, sin(angle)) * rng.randf_range(0.4, 1.8)
				var hit := Query.floor_at(actor, requested, 1.5)
				if hit.is_empty() or not Query.full_support(actor, hit): continue
				var pose := actor.global_transform
				pose.origin = Query.ground_pose(actor, hit)
				if not Query.motion_clear(actor, pose, Vector3.ZERO): continue
				actor.position = pose.origin
				actor._previous = actor.position
				break
		actor.speed = 4.0
		var goal: Vector3 = lab.target.position if specification.mode == "converge" else destination - Vector3.UP * 0.985
		if specification.mode == "converge": goal.y = central_hit.position.y + 0.06
		var target := Node3D.new()
		target.position = goal
		lab.add_child(target)
		actor.target = target
		target_nodes.append(target)
		source_indices.append(source_index)
		expected.append(_connected(actor.global_position, goal + Vector3.UP * 0.985))
		initial.append({"source": _vector(actor.position), "goal": _vector(goal), "expected_reachable": expected[-1]})
	if specification.mode == "lab_full_area":
		lab.clear_actors()
		lab.seed_value = int(specification.seed)
		lab._pressure_count(int(specification.count))
		_check(lab.actors.size() == int(specification.count), "观察台全区域投放必须完成请求数量，不能静默丢弃")
		expected.clear()
		initial.clear()
		for actor: CharacterBody3D in lab.actors:
			expected.append(_connected(actor.global_position, Query.body_on_floor(actor, Query.support(actor.target, false))))
			initial.append({"source": _vector(actor.position), "goal": _vector(actor.target.position), "expected_reachable": expected[-1]})
	var frame_times := PackedFloat64Array()
	var started := Time.get_ticks_usec()
	var previous := started
	var max_job_usec := 0
	var frame_count := 0
	var changed := false
	var goal_changes := 0
	for frame in range(9000 if specification.mode == "soak" else 5400):
		await physics_frame
		var now := Time.get_ticks_usec()
		frame_times.append((now - previous) / 1000.0)
		previous = now
		max_job_usec = maxi(max_job_usec, int(lab.actors[0].steering.spatial.last_job_usec))
		frame_count = frame
		if (specification.mode == "moving" and frame == 900) or (specification.mode == "soak" and frame in [900, 1800, 2700, 3600]):
			goal_changes += 1
			for i in range(lab.actors.size()):
				var actor: CharacterBody3D = lab.actors[i]
				var destination := anchors[(source_indices[i] + offset + int(anchors.size() / 2) + (goal_changes * 13 if specification.mode == "soak" else 0)) % anchors.size()]
				actor.target.position = destination - Vector3.UP * 0.985
				actor.reached = false
				expected[i] = _connected(actor.global_position, destination)
			changed = true
		var pending := 0
		var unexpected := 0
		for i in range(lab.actors.size()):
			pending += int(expected[i] and not lab.actors[i].reached)
			unexpected += int(not expected[i] and lab.actors[i].reached)
		if frame % 600 == 0:
			print("[导航压力] ", specification.count, " / ", specification.mode, " frame=", frame, " pending=", pending, " wall=", (now - started) / 1000000.0)
		if pending == 0 and unexpected == 0 and (specification.mode != "moving" or changed) and (specification.mode != "soak" or goal_changes == 4) and frame >= 600: break
	var rows: Array = []
	var reached := 0
	var unreachable := 0
	for i in range(lab.actors.size()):
		var actor: CharacterBody3D = lab.actors[i]
		var state: Dictionary = actor.snapshot()
		state["expected_reachable"] = expected[i]
		state["goal"] = _vector(actor.target.position)
		rows.append(state)
		reached += int(actor.reached)
		unreachable += int(not expected[i])
		_check(actor.reached == expected[i], "%s %d / %s 未通过：%s" % [specification.mode, specification.count, actor.name, state])
		_check(not Query.support(actor, false).is_empty(), "测量体不得失去地面掉出场景")
	frame_times.sort()
	var distinct := {}
	for sample: Dictionary in initial: distinct[str(sample.source)] = true
	scenarios.append({"specification": specification, "settings": Style.settings(), "initial": initial, "final": rows, "frames": frame_count + 1,
		"reached": reached, "expected_unreachable": unreachable, "distinct_starts": distinct.size(), "goal_changes": goal_changes, "wall_seconds": (Time.get_ticks_usec() - started) / 1000000.0,
		"step_ms_p50": frame_times[int(frame_times.size() * 0.50)], "step_ms_p95": frame_times[int(frame_times.size() * 0.95)],
		"step_ms_p99": frame_times[int(frame_times.size() * 0.99)], "step_ms_max": frame_times[-1], "max_navigation_job_usec": max_job_usec})
	print("[导航压力结果] ", specification.count, " / ", specification.mode, " reached=", reached, " unreachable=", unreachable, " frames=", frame_count + 1)
	lab.clear_actors()
	await physics_frame

func _vector(value: Vector3) -> Array:
	return [value.x, value.y, value.z]

func _check(condition: bool, message: String) -> void:
	if not condition:
		failed = true
		push_error("[导航压力] " + message)
