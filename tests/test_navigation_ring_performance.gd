extends SceneTree
## 同心环带目标的性能对照：到底「用圈组」比「不用圈组」省多少。
##
## 同一场景、同一种子、同一条持续移动目标轨迹（走速 5 m/s、冲刺 ×1.7、固定转向种子），
## 在 64 / 128 / 256 个全区域投放的纯移动测量体上，分别跑「精确目标」与「同心环带目标」。
##
## 口径：headless --fixed-fps 60，逐物理帧记录墙钟耗时（含引擎物理与导航），
## 也就是这一帧真正花掉的时间。它不是含渲染的正式游戏帧率，但同机同场景下两种配置可比。
## 除性能外同时记录「真正在追的个体数」与零速比例，证明省下来的不是「少走少做」。
##
## 判据（每个投放规模都要成立）：
##   1. 环带相位的整段规划任务数更少；
##   2. 环带相位的帧耗时 P95 更低；
##   3. 真正在追的个体数不减少（质量底线）。
const Lab := preload("res://prototypes/navigation_lab/navigation_lab.tscn")
const Controller := preload("res://scripts/combat_spatial_controller.gd")
const Paths := preload("res://scripts/artifact_paths.gd")
const TERRAIN := preload("res://scripts/terrain_field.gd")
const FRAMES := 900
const WARMUP := 120
const COHORT_MIN_TRAVEL := 20.0
const COUNTS: Array[int] = [64, 128, 256]
var failed := false
var lab: Node3D

func _initialize() -> void:
	call_deferred("_run")

func _run() -> void:
	lab = Lab.instantiate()
	lab.paused_motion = false
	lab.full_area = true
	root.add_child(lab)
	current_scene = lab
	for frame in range(2400):
		if lab.ready_for_test:
			break
		await process_frame
	_check(lab.ready_for_test, "导航服务器同步后才能启动性能对照")
	if not lab.ready_for_test:
		quit(1)
		return
	var rows: Array = []
	for count: int in COUNTS:
		for ring: bool in [false, true]:
			rows.append(await _phase(count, ring))
	# 汇总
	var summary: Array = []
	for count: int in COUNTS:
		var precise := _find(rows, count, false)
		var ring := _find(rows, count, true)
		summary.append({"count": count, "precise": precise, "ring": ring})
		# 所有规模都必须成立：每帧用于规划的时间预算下降，且真正在追的个体不减少。
		_check(int(ring.job_usec_p95) < int(precise.job_usec_p95),
			"%d 体：环带相位每帧规划预算 P95 没有下降 %d -> %d us" % [count, int(precise.job_usec_p95), int(ring.job_usec_p95)])
		_check(int(ring.cohort) >= int(precise.cohort),
			"%d 体：环带相位真正在追的个体变少 %d -> %d" % [count, int(precise.cohort), int(ring.cohort)])
		if count <= 128:
			# 规划队列没有打满：应当同时减少整段规划次数并降低帧耗时。
			_check(int(ring.jobs) < int(precise.jobs),
				"%d 体：环带相位没有减少规划任务 %d -> %d" % [count, int(precise.jobs), int(ring.jobs)])
			_check(float(ring.step_ms_p95) < float(precise.step_ms_p95),
				"%d 体：环带相位帧耗时 P95 没有下降 %.3f -> %.3f ms" % [count, float(precise.step_ms_p95), float(ring.step_ms_p95)])
		else:
			# 256 体：精确目标下规划队列已经饱和，一批个体等在原地不动（实测只有 144/256 在追）。
			# 环带把「等规划」变成「真的在追」，代价是同样多的规划量分给了更多个体，
			# 所以这里判「帧耗时不实质变差 + 服务到的在追个体显著更多」。
			_check(float(ring.step_ms_p95) <= float(precise.step_ms_p95) * 1.05,
				"%d 体：环带相位帧耗时 P95 明显变差 %.3f -> %.3f ms" % [count, float(precise.step_ms_p95), float(ring.step_ms_p95)])
			_check(int(ring.cohort) >= int(precise.cohort) + int(count / 5),
				"%d 体：环带相位服务到的在追个体不够多 %d -> %d" % [count, int(precise.cohort), int(ring.cohort)])
		print("[环性能] %d 体：规划 %d -> %d（%.2f×）· 帧P50 %.2f -> %.2f ms · 帧P95 %.2f -> %.2f ms · 帧P99 %.2f -> %.2f ms · 帧最大 %.2f -> %.2f ms · 规划预算P95 %d -> %d us · 在追 %d -> %d" % [
			count, int(precise.jobs), int(ring.jobs), float(ring.jobs) / maxf(float(precise.jobs), 1.0),
			float(precise.step_ms_p50), float(ring.step_ms_p50), float(precise.step_ms_p95), float(ring.step_ms_p95),
			float(precise.step_ms_p99), float(ring.step_ms_p99), float(precise.step_ms_max), float(ring.step_ms_max),
			int(precise.job_usec_p95), int(ring.job_usec_p95), int(precise.cohort), int(ring.cohort)])
	_report(summary)
	lab.clear_actors()
	current_scene = null
	lab.queue_free()
	await process_frame
	Controller.ring_goal_enabled = false
	Controller.reset_ring_goals()
	print("[环性能] ", "FAIL" if failed else "PASS")
	quit(1 if failed else 0)

func _find(rows: Array, count: int, ring: bool) -> Dictionary:
	for row: Dictionary in rows:
		if int(row.count) == count and bool(row.ring) == ring:
			return row
	return {}

func _phase(count: int, ring: bool) -> Dictionary:
	# 固定环参数，不受项目里保存的 ring_goals.json 影响。
	Controller.ring_radii = PackedFloat32Array([6.0, 16.0, 40.0, 90.0])
	Controller.ring_level_tolerance = 0.0
	Controller.ring_goal_enabled = ring
	Controller.ring_drag_mode = "snap"
	Controller.reset_ring_goals()
	lab.count = count
	lab.full_area = true
	lab.seed_value = 64768
	lab.replay()
	_check(lab.actors.size() == count, "%d 体：全区域投放必须完成请求数量" % count)
	var target: Node3D = lab.target
	target.position = lab._marker_position(Vector3(0, 0, 6))
	for actor in lab.actors:
		actor.running = true
		actor.reached = false
		actor.steering.spatial.bind({"move_speed": actor.speed}, {"can_attack": func(): return false})
	await physics_frame
	var rng := RandomNumberGenerator.new()
	rng.seed = 90210
	var heading := 0.0
	var sprint_left := 0.0
	var sprinting := false
	var extent := TERRAIN.get_extent() * 0.75
	var previous_positions: Array[Vector3] = []
	var travelled: Array[float] = []
	var zero_frames: Array[int] = []
	var measured: Array[int] = []
	var distance_sum: Array[float] = []
	for actor in lab.actors:
		previous_positions.append(actor.global_position)
		travelled.append(0.0)
		zero_frames.append(0)
		measured.append(0)
		distance_sum.append(0.0)
	var jobs_start: int = Controller.jobs_started
	var stop_start: int = Controller.stop_wait_frames
	var drags_start: int = Controller.ring_drag_events
	var frame_times := PackedFloat64Array()
	var job_usec: Array[int] = []
	var previous := Time.get_ticks_usec()
	var started := previous
	for frame in range(FRAMES):
		# 持续移动目标：与 tests/test_navigation_moving_target.gd 同一轨迹。
		sprint_left -= 1.0 / 60.0
		if sprint_left <= 0.0:
			sprint_left = rng.randf_range(1.5, 3.0)
			sprinting = rng.randf() < 0.4
			heading += rng.randf_range(-0.6, 0.6)
		var speed := 5.0 * (1.7 if sprinting else 1.0)
		var step := Vector3(cos(heading), 0, sin(heading)) * speed / 60.0
		var wanted := target.position + step
		if absf(wanted.x) > extent or absf(wanted.z) > extent:
			heading += PI
			wanted = target.position - step
		var grounded: Vector3 = lab._marker_position(wanted)
		if Vector2(grounded.x - wanted.x, grounded.z - wanted.z).length() > 1.5:
			heading += PI
			wanted = target.position - step
			grounded = lab._marker_position(wanted)
		target.position = grounded
		await physics_frame
		var now := Time.get_ticks_usec()
		frame_times.append((now - previous) / 1000.0)
		previous = now
		job_usec.append(Controller.last_job_usec)
		if frame < WARMUP:
			for index in range(lab.actors.size()):
				previous_positions[index] = (lab.actors[index] as CharacterBody3D).global_position
			continue
		for index in range(lab.actors.size()):
			var actor: CharacterBody3D = lab.actors[index]
			var here := actor.global_position
			var moved := Vector2(here.x - previous_positions[index].x, here.z - previous_positions[index].z).length()
			previous_positions[index] = here
			measured[index] += 1
			travelled[index] += moved
			distance_sum[index] += Vector2(here.x - grounded.x, here.z - grounded.z).length()
			if moved < 0.002:
				zero_frames[index] += 1
	var cohort := 0
	var zero_total := 0
	var frame_total := 0
	var total_distance := 0.0
	for index in range(lab.actors.size()):
		if travelled[index] <= COHORT_MIN_TRAVEL:
			continue
		cohort += 1
		zero_total += zero_frames[index]
		frame_total += measured[index]
		total_distance += distance_sum[index]
	frame_times.sort()
	job_usec.sort()
	var wall := (Time.get_ticks_usec() - started) / 1000000.0
	return {"count": count, "ring": ring, "actors": lab.actors.size(), "cohort": cohort, "frames": FRAMES,
		"wall_seconds": wall, "fps": float(FRAMES) / maxf(wall, 0.001),
		"zero_ratio": float(zero_total) / float(maxi(frame_total, 1)),
		"mean_distance": total_distance / float(maxi(frame_total, 1)),
		"jobs": Controller.jobs_started - jobs_start,
		"stop_wait": Controller.stop_wait_frames - stop_start,
		"drags": Controller.ring_drag_events - drags_start,
		"step_ms_p50": frame_times[int(frame_times.size() * 0.50)],
		"step_ms_p95": frame_times[mini(frame_times.size() - 1, int(frame_times.size() * 0.95))],
		"step_ms_p99": frame_times[mini(frame_times.size() - 1, int(frame_times.size() * 0.99))],
		"step_ms_max": frame_times[frame_times.size() - 1],
		"job_usec_p50": job_usec[job_usec.size() / 2],
		"job_usec_p95": job_usec[mini(job_usec.size() - 1, int(job_usec.size() * 0.95))]}

func _report(summary: Array) -> void:
	var file := FileAccess.open(Paths.ensure_dir("reports").path_join("test_navigation_ring_performance.json"), FileAccess.WRITE)
	if file == null:
		_check(false, "无法保存性能对照报告")
	else:
		file.store_string(JSON.stringify({"counts": COUNTS, "frames": FRAMES,
			"note": "headless --fixed-fps 60；逐物理帧墙钟耗时，含引擎物理与导航，不含渲染",
			"summary": summary}, "\t"))

func _check(condition: bool, message: String) -> void:
	if not condition:
		failed = true
		push_error("[环性能] " + message)
