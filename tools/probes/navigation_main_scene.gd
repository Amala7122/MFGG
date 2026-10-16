extends SceneTree
## 导航俯视观察探针：跑固定帧数、导出报告与（非 headless 时）俯视图截图。
## 参数（放在 -- 之后）：--frames=秒*60 --count=1..256 --ring=1 开启同心环带目标。
## --ring=1 时目标按固定圆轨迹移动，用来观察环被拖动、圈号标注与目标轨迹点。
const Lab := preload("res://prototypes/navigation_lab/navigation_lab.tscn")
const Paths := preload("res://scripts/artifact_paths.gd")
const Controller := preload("res://scripts/combat_spatial_controller.gd")
var lab: Node3D
var frames_to_run := 3600
var pressure_count := 0
var ring_mode := false
var ring_inner := 0.0
var ring_count := 0
var ring_radii_list: Array[float] = []
var ring_drag := ""
var spawn_outside := 0
## 在第 jump_at 帧把目标瞬移 30 米（模拟点击设置目标），用来验证追击者是否立刻改目标。
var jump_at := -1
## 瞬移距离（米）：用来验证「只有被推过边界的圈才动」，默认 30。
var jump_distance := 30.0
func _initialize() -> void:
	call_deferred("_run")
func _run() -> void:
	for argument in OS.get_cmdline_user_args():
		if argument.begins_with("--frames="): frames_to_run = int(argument.trim_prefix("--frames="))
		if argument.begins_with("--count="): pressure_count = clampi(int(argument.trim_prefix("--count=")), 1, 256)
		if argument.begins_with("--ring="): ring_mode = int(argument.trim_prefix("--ring=")) != 0
		if argument.begins_with("--ring-radii="):
			for part in argument.trim_prefix("--ring-radii=").split(",", false):
				ring_radii_list.append(float(part))
		if argument.begins_with("--ring-drag="): ring_drag = argument.trim_prefix("--ring-drag=")
		if argument.begins_with("--spawn-outside="): spawn_outside = int(argument.trim_prefix("--spawn-outside="))
		if argument.begins_with("--jump-at="): jump_at = int(argument.trim_prefix("--jump-at="))
		if argument.begins_with("--jump-distance="): jump_distance = float(argument.trim_prefix("--jump-distance="))
		if argument.begins_with("--ring-inner="): ring_inner = float(argument.trim_prefix("--ring-inner="))
		if argument.begins_with("--ring-count="): ring_count = clampi(int(argument.trim_prefix("--ring-count=")), 2, 6)
	lab = Lab.instantiate()
	root.add_child(lab)
	current_scene = lab
	for frame in range(1200):
		if lab.ready_for_test: break
		await process_frame
	if not lab.ready_for_test:
		push_error("导航观察探针：主场景构建超时")
		quit(1)
		return
	# 环参数必须在观察台 ready 之后再设：_ready 会读回项目默认 ring_goals.json，
	# 早设会被那份默认值覆盖。
	Controller.ring_goal_enabled = ring_mode
	if not ring_drag.is_empty():
		Controller.ring_drag_mode = ring_drag
	if ring_mode and ring_radii_list.size() >= 2:
		var explicit := PackedFloat32Array()
		for value in ring_radii_list:
			explicit.append(value)
		Controller.ring_radii = explicit
	elif ring_mode and ring_inner > 0.0 and ring_count >= 2:
		var radii := PackedFloat32Array()
		var value := ring_inner
		for index in range(ring_count):
			radii.append(value)
			value *= 2.0
		Controller.ring_radii = radii
	if ring_mode:
		Controller.reset_ring_goals()
	# 观察台默认「未开始」，探针要自己放行（start_run 同时放行已经投放的测量体）。
	lab.start_run()
	if spawn_outside > 0:
		# 只投放在第 N 环之外：先设约束再重播（replay 里按环半径剔除候选点）。
		lab.spawn_outside_ring = spawn_outside
		lab.replay()
	if pressure_count > 0: lab._pressure_count(pressure_count)
	var initial: Array = []
	for actor in lab.actors:
		initial.append(actor.snapshot())
	for frame in range(frames_to_run):
		if frame == jump_at and is_instance_valid(lab.target):
			# 模拟左键点击设点：目标瞬移 30 米。
			lab.target.position = lab._marker_position(lab.target.position + Vector3(jump_distance, 0.0, 0.0))
			print("[导航观察] frame=", frame, " 目标瞬移 ", jump_distance, " 米 ->", lab.target.position)
			var rows := Controller.ring_debug_rows(lab.target)
			for row: Dictionary in rows:
				print("[导航观察]   第", int(row["ring"]), "环 R=", "%.0f" % float(row["radius"]),
					" 圆心=", str(row["anchor"]).substr(0, 24), " 已拖动=", int(row["drags"]))
		if jump_at >= 0 and frame >= jump_at - 30 and frame <= jump_at + 90 and frame % 10 == 0:
			var checking := 0
			var arrived_goal := 0
			for actor in lab.actors:
				var spatial: RefCounted = actor.steering.spatial
				if String(spatial.status) == "checking":
					checking += 1
				if not spatial._goal_sample.is_zero_approx() and spatial._goal_sample.distance_to(lab.target.position) < 25.0:
					arrived_goal += 1
			var rows2 := Controller.ring_debug_rows(lab.target)
			var drags := PackedInt32Array()
			for row: Dictionary in rows2:
				drags.append(int(row["drags"]))
			print("[导航观察] frame=", frame, " 在算路=", checking, "/", lab.actors.size(),
				" 目标点已在新位置 25 米内=", arrived_goal, " 各环累计拖动=", str(drags))
		if ring_mode and is_instance_valid(lab.target):
			# 固定圆轨迹（半径 24 米）：目标会依次离开最内环与第二环，用来观察拖动与轨迹点。
			var angle := float(frame) / 60.0 * 0.3
			lab.target.position = lab._marker_position(Vector3(cos(angle) * 24.0, 0.0, sin(angle) * 24.0))
		await physics_frame
		if frame % 600 == 0:
			var arrived := 0
			for actor in lab.actors: arrived += int(actor.reached)
			print("[导航观察] frame=", frame, " reached=", arrived, "/", lab.actors.size())
		if ring_mode and frame % 150 == 0:
			# 分阶段观察：档位分布（0 = 已进第 1 环、走精确目标）与各档位目标点到目标的距离。
			# 期望：全放在最外环之外时，一开始所有人都只在最外环档，进环后才逐级换档。
			var bands := {}
			var segments := {}
			for actor in lab.actors:
				var spatial: RefCounted = actor.steering.spatial
				var band := int(spatial._plan_band)
				bands[band] = int(bands.get(band, 0)) + 1
				if not spatial._goal_sample.is_zero_approx():
					var gap := Vector2(spatial._goal_sample.x - lab.target.position.x, spatial._goal_sample.z - lab.target.position.z).length()
					var bucket := int(gap / 10.0) * 10
					segments[bucket] = int(segments.get(bucket, 0)) + 1
			print("[导航观察] frame=", frame, " 档位分布=", bands, " 目标点到目标距离段(米)=", segments)
	lab.paused_motion = true
	for actor in lab.actors: actor.running = false
	lab.export_report()
	var result := {"initial": initial, "final": [], "frames": frames_to_run, "arena": lab.Arena.resolve_id(), "seed": lab.seed_value, "target": str(lab.target.position),
		"ring": {"enabled": Controller.ring_goal_enabled, "drag_mode": Controller.ring_drag_mode,
			"radii": Array(Controller.ring_radii), "level_tolerance": Controller.ring_level_tolerance,
			"spawn_outside_ring": lab.spawn_outside_ring,
			"plans_with_ring": Controller.ring_used, "blocked_by_level": Controller.ring_level_blocked,
			"precise_inside_ring": Controller.ring_precise_zone, "drags": Controller.ring_drag_events,
			"ring_switches": Controller.ring_switch_events}}
	for actor in lab.actors: result.final.append(actor.snapshot())
	var path := Paths.ensure_dir("reports").path_join("navigation_main_scene.json")
	var file := FileAccess.open(path, FileAccess.WRITE)
	if file == null:
		push_error("导航证据写入失败：" + path)
		quit(1)
		return
	file.store_string(JSON.stringify(result, "\t"))
	file.close()
	if DisplayServer.get_name() != "headless":
		await process_frame
		await RenderingServer.frame_post_draw
		root.get_texture().get_image().save_png(Paths.ensure_dir("screenshots").path_join("navigation_top_view.png"))
	current_scene = null
	lab.queue_free()
	await process_frame
	quit()
