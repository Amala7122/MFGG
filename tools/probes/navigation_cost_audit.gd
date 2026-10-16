extends SceneTree
## 只读性能诊断：固定全区域投放与持续移动目标，保留全部个体的质量指标。
## 经 run_probe.py 运行；--count=256 --frames=900 --warmup=120 --ui=1 --ring=1。
## 可选计时模块只在诊断副本中生成，正式运行代码无需加载它。
const Lab := preload("res://prototypes/navigation_lab/navigation_lab.tscn")
const Controller := preload("res://scripts/combat_spatial_controller.gd")
const Paths := preload("res://scripts/artifact_paths.gd")
const Terrain := preload("res://scripts/terrain_field.gd")
var lab: Node3D
var profiler: Script
var count := 256
var frames := 900
var warmup := 120
var with_ui := true
var rings := true
var seed_value := 64768
var samples: Array = []
var totals: Dictionary = {}

func _initialize() -> void:
	call_deferred("_run")

func _run() -> void:
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--count="): count = int(arg.get_slice("=", 1))
		if arg.begins_with("--frames="): frames = int(arg.get_slice("=", 1))
		if arg.begins_with("--warmup="): warmup = int(arg.get_slice("=", 1))
		if arg.begins_with("--ui="): with_ui = int(arg.get_slice("=", 1)) != 0
		if arg.begins_with("--ring="): rings = int(arg.get_slice("=", 1)) != 0
		if arg.begins_with("--seed="): seed_value = int(arg.get_slice("=", 1))
	if ResourceLoader.exists("res://scripts/nav_audit_metrics.gd"):
		profiler = load("res://scripts/nav_audit_metrics.gd")
	lab = Lab.instantiate()
	lab.count = 0
	lab.keyboard_target = false
	root.add_child(lab)
	current_scene = lab
	for frame in range(2400):
		if lab.ready_for_test: break
		await process_frame
	if not lab.ready_for_test:
		push_error("导航诊断：地图未就绪")
		quit(1)
		return
	Controller.ring_goal_enabled = rings
	Controller.ring_radii = PackedFloat32Array([6.0, 16.0, 40.0, 90.0])
	Controller.ring_level_tolerance = 0.0
	Controller.ring_drag_mode = "snap"
	lab.target.position = lab._marker_position(Vector3(0, 0, 6))
	lab.count = count
	lab.seed_value = seed_value
	lab.full_area = true
	lab.replay()
	lab.start_run()
	lab.set_process(with_ui)
	if lab.actors.size() != count:
		push_error("导航诊断：投放数不足 %d/%d" % [lab.actors.size(), count])
		quit(1)
		return
	# 验证目标传递，直接观察规划器字段，不执行额外路径搜索。
	var actor: CharacterBody3D = lab.actors[0]
	var expected: Vector3 = lab.target.position + Vector3(12, 0, 0)
	var check: RefCounted = actor.steering.spatial._planner(lab.target, expected, false)
	var goal_check := {"requested": str(expected), "actual": str(check.goal),
		"error_xz": Vector2(check.goal.x - expected.x, check.goal.z - expected.z).length(),
		"override_flag": check.has_goal_override}
	var rng := RandomNumberGenerator.new()
	rng.seed = 90210
	var heading := 0.0
	var sprint_left := 0.0
	var sprinting := false
	var extent := Terrain.get_extent() * 0.75
	var previous_positions: Array[Vector3] = []
	var distances: Array[float] = []
	var zeros: Array[int] = []
	var longest: Array[int] = []
	var current_stops: Array[int] = []
	for item in lab.actors:
		previous_positions.append(item.global_position)
		distances.append(0.0)
		zeros.append(0)
		longest.append(0)
		current_stops.append(0)
	var jobs_start := Controller.jobs_started
	var started := Time.get_ticks_usec()
	var previous := started
	for frame in range(frames):
		if profiler != null:
			profiler.set("enabled", frame >= warmup)
		sprint_left -= 1.0 / 60.0
		if sprint_left <= 0.0:
			sprint_left = rng.randf_range(1.5, 3.0)
			sprinting = rng.randf() < 0.4
			heading += rng.randf_range(-0.6, 0.6)
		var speed := 5.0 * (1.7 if sprinting else 1.0)
		var step := Vector3(cos(heading), 0, sin(heading)) * speed / 60.0
		var wanted: Vector3 = lab.target.position + step
		if absf(wanted.x) > extent or absf(wanted.z) > extent:
			heading += PI
			wanted = lab.target.position - step
		var grounded: Vector3 = lab._marker_position(wanted)
		if Vector2(grounded.x - wanted.x, grounded.z - wanted.z).length() > 1.5:
			heading += PI
			grounded = lab._marker_position(lab.target.position - step)
		lab.target.position = grounded
		await physics_frame
		var now := Time.get_ticks_usec()
		var row := {"frame": frame, "ms": (now - previous) / 1000.0,
			"job_us": Controller.last_job_usec, "queue": Controller._jobs.size()}
		previous = now
		if profiler != null:
			var costs: Dictionary = profiler.call("take_frame")
			row["costs"] = costs
			if frame >= warmup:
				for key: String in costs:
					var value: Array = costs[key]
					if not totals.has(key): totals[key] = [0, 0, 0, 0]
					for i in range(3): totals[key][i] += value[i]
					totals[key][3] = maxi(totals[key][3], value[3])
		if frame >= warmup: samples.append(row)
		for i in range(count):
			var here: Vector3 = lab.actors[i].global_position
			var moved := Vector2(here.x - previous_positions[i].x, here.z - previous_positions[i].z).length()
			previous_positions[i] = here
			if frame < warmup: continue
			distances[i] += moved
			if moved < 0.002:
				zeros[i] += 1
				current_stops[i] += 1
				longest[i] = maxi(longest[i], current_stops[i])
			else: current_stops[i] = 0
	if profiler != null: profiler.set("enabled", false)
	var actor_rows: Array = []
	var active := 0
	var zero_total := 0
	for i in range(count):
		if distances[i] > 20.0: active += 1
		zero_total += zeros[i]
		actor_rows.append({"id": i, "travelled": distances[i], "zero_frames": zeros[i],
			"longest_zero": longest[i], "state": lab.actors[i].snapshot()})
	var times: Array = []
	var job_times: Array = []
	for row: Dictionary in samples:
		times.append(row.ms)
		job_times.append(row.job_us)
	times.sort()
	job_times.sort()
	var report := {"engine": Engine.get_version_info(), "count": count, "frames": frames,
		"warmup": warmup, "ui": with_ui, "ring": rings, "seed": seed_value,
		"goal_check": goal_check, "active_over_20m": active,
		"all_actor_zero_ratio": float(zero_total) / maxf(count * (frames - warmup), 1),
		"ms_p50": _pct(times, 0.50), "ms_p95": _pct(times, 0.95), "ms_p99": _pct(times, 0.99),
		"ms_mean": _mean(times), "job_us_p95": _pct(job_times, 0.95),
		"jobs": Controller.jobs_started - jobs_start, "full_ticks": Controller.full_ticks,
		"cheap_ticks": Controller.throttled_ticks, "metrics": totals,
		"metrics_columns": ["calls", "inclusive_us", "exclusive_us", "max_call_us"],
		"actors": actor_rows, "samples": samples}
	var file := FileAccess.open(Paths.ensure_dir("reports").path_join("navigation_cost_audit.json"), FileAccess.WRITE)
	if file == null:
		push_error("导航诊断报告保存失败")
		quit(1)
		return
	file.store_string(JSON.stringify(report, "\t"))
	file.close()
	print("[导航成本] count=%d ui=%s p50=%.2f p95=%.2f p99=%.2f mean=%.2f active=%d goal_error=%.2f" % [
		count, with_ui, report.ms_p50, report.ms_p95, report.ms_p99, report.ms_mean, active, goal_check.error_xz])
	lab.clear_actors()
	current_scene = null
	lab.queue_free()
	await process_frame
	quit(0)

func _pct(values: Array, fraction: float) -> float:
	return float(values[mini(values.size() - 1, int(values.size() * fraction))]) if not values.is_empty() else 0.0

func _mean(values: Array) -> float:
	var total := 0.0
	for value in values: total += float(value)
	return total / maxf(values.size(), 1)
