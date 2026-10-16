extends SceneTree
## 同心环目标（用户 2026-10-11 的「铁圈」模型）与精确目标的 A/B 对照。
##
## 四个相位：[精确 / 同心环] × [纯移动测量体 / 绑定 attack_pose 的接战链]，
## 同一场景、同一种子、同一条目标轨迹（走速 5 m/s，冲刺 ×1.7，固定转向种子）。
## 目标轨迹与 tests/test_navigation_moving_target.gd 完全一致，便于两份数据互相印证。
##
## 判据：
##   - 同心环相位的绝对质量不许退化：零速比例 ≤ 0.30、最长连续零速 ≤ 300 帧、
##     真正在追的个体（预热后累计位移 > 20 米）≥ 8，且不少于精确相位；
##   - 同心环相位必须真的少规划：整段规划任务数 ≤ 精确相位 × 0.9；
##   - 同心环必须真的被行使：锚点拖动次数 > 0。
## 与目标的平均距离、任务 P95 只记录不判定（同一改造两次运行也会波动）。
const Lab := preload("res://prototypes/navigation_lab/navigation_lab.tscn")
const Controller := preload("res://scripts/combat_spatial_controller.gd")
const Paths := preload("res://scripts/artifact_paths.gd")
const TERRAIN := preload("res://scripts/terrain_field.gd")
const FRAMES := 1500
const WARMUP := 300
const COHORT_MIN_TRAVEL := 20.0
var failed := false
var lab: Node3D

func _initialize() -> void:
	call_deferred("_run")

func _run() -> void:
	lab = Lab.instantiate()
	lab.count = 24
	lab.full_area = false
	lab.paused_motion = false
	root.add_child(lab)
	current_scene = lab
	for frame in range(2400):
		if lab.ready_for_test:
			break
		await process_frame
	_check(lab.ready_for_test, "导航服务器同步后才能启动测量")
	if not lab.ready_for_test:
		quit(1)
		return
	# 相位：精确目标基线 × 两种环拖动模式（弹开 / 平滑）× 纯移动 / 接战链。
	var modes: Array = [
		{"ring": false, "drag": "snap"},
		{"ring": true, "drag": "snap"},
		{"ring": true, "drag": "smooth"},
	]
	var phases: Array = []
	for mode: Dictionary in modes:
		for melee: bool in [false, true]:
			phases.append(await _phase(mode.ring, melee, mode.drag))
	var precise_pure: Dictionary = phases[0]
	var precise_melee: Dictionary = phases[1]
	var snap_pure: Dictionary = phases[2]
	var snap_melee: Dictionary = phases[3]
	var smooth_pure: Dictionary = phases[4]
	var smooth_melee: Dictionary = phases[5]
	_check(phases.size() == 6 and int(snap_pure.get("frames", 0)) > 0, "六个相位都必须真的跑起来")
	_compare("纯移动·弹开", precise_pure, snap_pure)
	_compare("接战链·弹开", precise_melee, snap_melee)
	_compare("纯移动·平滑", precise_pure, smooth_pure)
	_compare("接战链·平滑", precise_melee, smooth_melee)
	for phase: Dictionary in phases:
		print("[同心环目标] 相位 ring=%s drag=%s melee=%s cohort=%d zero=%.4f longest=%d 规划=%d 请求=%d 拖动=%d 换环=%d 任务P50/P95=%d/%dus 平均距离=%.2f" % [
			str(phase.ring), str(phase.drag), str(phase.melee), int(phase.cohort), float(phase.zero_ratio),
			int(phase.longest_stop_frames), int(phase.jobs), int(phase.replans), int(phase.drags),
			int(phase.switches), int(phase.job_usec_p50), int(phase.job_usec_p95), float(phase.mean_distance)])
		print("[同心环目标]   环：用 %d 层 %d 层级挡回 %d 内环 %d 同步帧 %d 拖动 %d 换环 %d 同步最大间距 %s 等结果帧 %d" % [
			int(phase.ring_used), int(phase.entered_max), int(phase.level_blocked), int(phase.precise_zone),
			int(phase.sync_frames), int(phase.drags), int(phase.switches), str(phase.gap_max), int(phase.stop_wait)])
		print("[同心环目标]   目标来源：环带轨迹 %d · 回退环圆心 %d · 轨迹点数峰值 %d" % [
			int(phase.region_used), int(phase.anchor_fallbacks), int(phase.trail_peak)])
		print("[同心环目标]   收尾状态 %s · 档位 %s" % [str(phase.statuses), str(phase.bands)])
		print("[同心环目标]   零速归类 %s" % str(phase.zero_by_status))
	_report(phases)
	lab.clear_actors()
	current_scene = null
	lab.queue_free()
	await process_frame
	Controller.ring_goal_enabled = false
	Controller.reset_ring_goals()
	print("[同心环目标] ", "FAIL" if failed else "PASS")
	quit(1 if failed else 0)

func _compare(title: String, precise: Dictionary, ring: Dictionary) -> void:
	_check(float(ring.zero_ratio) <= 0.30, "%s：同心环相位零速比例过高 %.4f" % [title, ring.zero_ratio])
	_check(int(ring.longest_stop_frames) <= 300, "%s：同心环相位最长连续零速过长 %d 帧" % [title, ring.longest_stop_frames])
	_check(int(ring.cohort) >= 8, "%s：同心环相位真正在追的个体太少 %d" % [title, int(ring.cohort)])
	_check(int(ring.cohort) >= int(precise.cohort),
		"%s：同心环反而让真正在追的个体变少 %d -> %d" % [title, int(precise.cohort), int(ring.cohort)])
	_check(int(ring.drags) > 0, "%s：同心环相位一次锚点拖动都没有，模型没有被行使" % title)
	_check(int(ring.jobs) <= int(precise.jobs) * 0.9 + 1,
		"%s：同心环没有减少整段规划 %d -> %d" % [title, int(precise.jobs), int(ring.jobs)])
	print("[同心环目标] %s：规划 %d -> %d（%.2f×），请求 %d -> %d，零速 %.4f -> %.4f，最长停顿 %d -> %d 帧，在追 %d -> %d，任务 P95 %d -> %d us，平均距离 %.2f -> %.2f" % [
		title, int(precise.jobs), int(ring.jobs), float(ring.jobs) / maxf(float(precise.jobs), 1.0),
		int(precise.replans), int(ring.replans), float(precise.zero_ratio), float(ring.zero_ratio),
		int(precise.longest_stop_frames), int(ring.longest_stop_frames), int(precise.cohort), int(ring.cohort),
		int(precise.job_usec_p95), int(ring.job_usec_p95), float(precise.mean_distance), float(ring.mean_distance)])

func _phase(ring: bool, melee: bool, drag: String = "snap") -> Dictionary:
	# 固定环参数，不受项目里保存的 ring_goals.json 影响，保证 A/B 可复现。
	Controller.ring_radii = PackedFloat32Array([6.0, 16.0, 40.0, 90.0])
	Controller.ring_level_tolerance = 0.0
	Controller.ring_goal_enabled = ring
	Controller.ring_drag_mode = drag
	Controller.reset_ring_goals()
	lab.seed_value = 64768
	lab.replay()
	_check(lab.actors.size() == lab.count, "连通区域中必须完成全部投放")
	var target: Node3D = lab.target
	target.position = lab._marker_position(Vector3(0, 0, 6))
	for actor in lab.actors:
		actor.running = true
		actor.reached = false
		if melee:
			var goal: Node3D = target
			actor.steering.spatial.bind({"move_speed": actor.speed}, {
				"can_attack": func() -> bool: return false,
				"attack_pose": func(pose: Transform3D) -> bool: return pose.origin.distance_to(goal.global_position) < 2.0,
			})
		else:
			actor.steering.spatial.bind({"move_speed": actor.speed}, {"can_attack": func() -> bool: return false})
	await physics_frame
	var rng := RandomNumberGenerator.new()
	rng.seed = 90210
	var heading := 0.0
	var sprint_left := 0.0
	var sprinting := false
	var extent := TERRAIN.get_extent() * 0.75
	var previous: Array[Vector3] = []
	var zero_frames: Array[int] = []
	var run_frames: Array[int] = []
	## 零速帧按控制状态归类：直接指出「站着不动」是等规划、无路线还是脱困。
	var zero_by_status := {}
	var longest: Array[int] = []
	var measured: Array[int] = []
	var travelled: Array[float] = []
	var distance_sum: Array[float] = []
	for actor in lab.actors:
		previous.append(actor.global_position)
		zero_frames.append(0)
		run_frames.append(0)
		longest.append(0)
		measured.append(0)
		travelled.append(0.0)
		distance_sum.append(0.0)
	var requests_start := 0
	for actor in lab.actors:
		requests_start += int(actor.steering.path_requests)
	var frames := 0
	var job_usec: Array[int] = []
	var jobs_start: int = Controller.jobs_started
	var drags_start: int = Controller.ring_drag_events
	var switches_start: int = Controller.ring_switch_events
	for frame in range(FRAMES):
		# 玩家持续移动：走速 5 m/s，冲刺 ×1.7，带转向；固定种子（与持续移动回归一致）。
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
		frames += 1
		job_usec.append(Controller.last_job_usec)
		if frame < WARMUP:
			for index in range(lab.actors.size()):
				previous[index] = (lab.actors[index] as CharacterBody3D).global_position
			continue
		for index in range(lab.actors.size()):
			var actor: CharacterBody3D = lab.actors[index]
			var here := actor.global_position
			var moved := Vector2(here.x - previous[index].x, here.z - previous[index].z).length()
			previous[index] = here
			measured[index] += 1
			travelled[index] += moved
			distance_sum[index] += Vector2(here.x - grounded.x, here.z - grounded.z).length()
			if moved >= 0.002:
				longest[index] = maxi(longest[index], run_frames[index])
				run_frames[index] = 0
				continue
			zero_frames[index] += 1
			run_frames[index] += 1
			var spatial: RefCounted = actor.steering.spatial
			var label := String(spatial.status)
			if not String(spatial.last_failure).is_empty():
				label += "/" + String(spatial.last_failure)
			zero_by_status[label] = int(zero_by_status.get(label, 0)) + 1
	var requests := 0
	var cohort := 0
	var zero_total := 0
	var frame_total := 0
	var longest_all := 0
	var total_distance := 0.0
	for actor in lab.actors:
		requests += int(actor.steering.path_requests)
	requests -= requests_start
	for index in range(lab.actors.size()):
		longest[index] = maxi(longest[index], run_frames[index])
		if travelled[index] <= COHORT_MIN_TRAVEL:
			continue
		cohort += 1
		zero_total += zero_frames[index]
		frame_total += measured[index]
		longest_all = maxi(longest_all, longest[index])
		total_distance += distance_sum[index]
	job_usec.sort()
	# 诊断：相位结束时各控制状态与档位分布，用来判断「走停」发生在哪一环。
	var statuses := {}
	var bands := {}
	for actor in lab.actors:
		var spatial: RefCounted = actor.steering.spatial
		statuses[String(spatial.status)] = int(statuses.get(String(spatial.status), 0)) + 1
		var band := int(spatial._plan_band)
		bands[str(band)] = int(bands.get(str(band), 0)) + 1
	var state: RefCounted = Controller.ring_state(target)
	var gap_max: Array = []
	if state != null:
		for value in state.gap_max:
			gap_max.append(snappedf(float(value), 0.1))
	return {"ring": ring, "drag": Controller.ring_drag_mode, "melee": melee, "actors": lab.actors.size(), "cohort": cohort, "frames": frames,
		"statuses": statuses, "bands": bands, "gap_max": gap_max, "zero_by_status": zero_by_status,
		"ring_used": Controller.ring_used, "level_blocked": Controller.ring_level_blocked,
		"region_used": Controller.ring_region_used, "anchor_fallbacks": Controller.ring_anchor_fallbacks,
		"band_fallbacks": Controller.band_fallbacks,
		"trail_peak": state.trail_peak if state != null else 0,
		"precise_zone": Controller.ring_precise_zone, "entered_max": Controller.ring_entered_max,
		"stop_wait": Controller.stop_wait_frames,
		"sync_frames": state.sync_frames if state != null else 0,
		"zero_ratio": float(zero_total) / float(maxi(frame_total, 1)),
		"longest_stop_frames": longest_all,
		"replans": requests,
		"mean_distance": total_distance / float(maxi(frame_total, 1)),
		"jobs": Controller.jobs_started - jobs_start,
		"drags": Controller.ring_drag_events - drags_start,
		"switches": Controller.ring_switch_events - switches_start,
		"job_usec_p50": job_usec[job_usec.size() / 2] if not job_usec.is_empty() else 0,
		"job_usec_p95": job_usec[mini(job_usec.size() - 1, int(float(job_usec.size()) * 0.95))] if not job_usec.is_empty() else 0}

func _report(phases: Array) -> void:
	var file := FileAccess.open(Paths.ensure_dir("reports").path_join("test_navigation_ring_goal.json"), FileAccess.WRITE)
	if file == null:
		_check(false, "无法保存同心环目标回归报告")
	else:
		file.store_string(JSON.stringify(phases, "\t"))

func _check(condition: bool, message: String) -> void:
	if not condition:
		failed = true
		push_error("[同心环目标] " + message)
