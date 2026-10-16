extends SceneTree
## 精确追击的无界面压力测量；保留原工具路径，单环模型已退役。
##
## 输出：近距回收次数、重生失败、真正的零速比例与最长连续零速、每人累计路程、
## 每帧墙钟耗时分位数，以及所有测量体的追击统计。
## 经 run_probe.py 运行；--frames= --warmup= --seed= 可选。
const Lab := preload("res://prototypes/ring_chase_lab/ring_chase_lab.tscn")
const ProjCache := preload("res://scripts/nav_projection_cache.gd")
const Paths := preload("res://scripts/artifact_paths.gd")
const Terrain := preload("res://scripts/terrain_field.gd")

var lab: Node3D
var frames := 900
var warmup := 120
var seed_value := 90210
## 兼容旧命令的 --precise=1；0 已不支持。
var precise := 1
## A/B：1 = 打开导航投影共享缓存，0 = 每个体每帧直接调原生投影。
var cache := 1
## 1.5 m 为当前观察台默认；31.5 m 仅复现退役前精确对照组的压力回收规则。
var recycle_distance := 1.5
var failed := false
## 可选计时模块：只在注入副本（tools/nav_cost_profile.py）里存在，正式运行不加载。
var profiler: Script
var totals: Dictionary = {}

func _initialize() -> void:
	call_deferred("_run")

func _run() -> void:
	for argument in OS.get_cmdline_user_args():
		if argument.begins_with("--frames="): frames = int(argument.trim_prefix("--frames="))
		if argument.begins_with("--warmup="): warmup = int(argument.trim_prefix("--warmup="))
		if argument.begins_with("--seed="): seed_value = int(argument.trim_prefix("--seed="))
		if argument.begins_with("--precise="): precise = int(argument.trim_prefix("--precise="))
		if argument.begins_with("--cache="): cache = int(argument.trim_prefix("--cache="))
		if argument.begins_with("--recycle-distance="): recycle_distance = float(argument.trim_prefix("--recycle-distance="))
	if not is_equal_approx(recycle_distance, 1.5) and not is_equal_approx(recycle_distance, 31.5):
		push_error("精确追击探针回收距离只支持默认 1.5 m 或旧压力对照 31.5 m")
		quit(1)
		return
	if precise != 1:
		push_error("环目标模型已退役，本探针只支持精确追击")
		quit(1)
		return
	if ResourceLoader.exists("res://scripts/nav_audit_metrics.gd"):
		profiler = load("res://scripts/nav_audit_metrics.gd")
	lab = Lab.instantiate()
	lab.recycle_near_distance = recycle_distance
	root.add_child(lab)
	current_scene = lab
	for frame in range(2400):
		if lab.ready_for_test:
			break
		await process_frame
	if not lab.ready_for_test:
		push_error("精确追击探针：地图未就绪")
		quit(1)
		return
	lab.probe_driven = true
	ProjCache.enabled = cache != 0
	ProjCache.reset_counters()
	var count: int = lab.actors.size()
	if count <= 0:
		push_error("精确追击探针：没有投放追击者")
		quit(1)
		return
	var rng := RandomNumberGenerator.new()
	rng.seed = seed_value
	var heading := 0.0
	var sprint_left := 0.0
	var sprinting := false
	var extent := Terrain.get_extent() * 0.7
	var previous: Array[Vector3] = []
	var zeros: Array[int] = []
	var runs: Array[int] = []
	var longest: Array[int] = []
	var travel: Array[float] = []
	var cycles: Array[int] = []
	var last_position: Array[Vector3] = []
	for actor: CharacterBody3D in lab.actors:
		previous.append(actor.global_position)
		last_position.append(actor.global_position)
		zeros.append(0)
		runs.append(0)
		longest.append(0)
		travel.append(0.0)
		cycles.append(0)
	var entered_start: int = lab.entered
	var times: Array[float] = []
	var marker_travel := 0.0
	var marker_previous: Vector3 = lab.marker.global_position
	var measured := 0
	## 两个停滞口径的累计帧数：窗口净位移（判定用）与逐帧位移（仅对照）。
	var window_zero_total := 0
	var frame_zero_total := 0
	for frame in range(frames):
		if profiler != null:
			profiler.set("enabled", frame >= warmup)
		# 标记（主角）持续走位：追击者直接规划到目标精确位置。
		sprint_left -= 1.0 / 60.0
		if sprint_left <= 0.0:
			sprint_left = rng.randf_range(1.5, 3.0)
			sprinting = rng.randf() < 0.4
			heading += rng.randf_range(-0.6, 0.6)
		var speed: float = float(lab.MARKER_SPEED) * (float(lab.MARKER_SPRINT) if sprinting else 1.0)
		var step := Vector3(cos(heading), 0.0, sin(heading)) * speed / 60.0
		var wanted: Vector3 = lab.marker.global_position + step
		if absf(wanted.x) > extent or absf(wanted.z) > extent:
			heading += PI
			wanted = lab.marker.global_position - step
		var snapped := NavigationServer3D.map_get_closest_point(lab.get_world_3d().navigation_map, wanted)
		var grounded: Vector3 = lab._surface(snapped)
		if not grounded.is_zero_approx():
			lab.marker.global_position = grounded
		marker_travel += Vector2(lab.marker.global_position.x - marker_previous.x,
			lab.marker.global_position.z - marker_previous.z).length()
		marker_previous = lab.marker.global_position

		var started := Time.get_ticks_usec()
		await physics_frame
		var frame_ms := float(Time.get_ticks_usec() - started) / 1000.0
		if frame >= warmup:
			times.append(frame_ms)
			measured += 1
			if profiler != null:
				var costs: Dictionary = profiler.call("take_frame")
				for key: String in costs:
					var value: Array = costs[key]
					if not totals.has(key):
						totals[key] = [0, 0, 0, 0]
					for slot in range(3):
						totals[key][slot] += value[slot]
					totals[key][3] = maxi(totals[key][3], value[3])
		elif profiler != null:
			profiler.call("take_frame")

		for index in range(count):
			var actor: CharacterBody3D = lab.actors[index]
			if not is_instance_valid(actor):
				continue
			var here: Vector3 = actor.global_position
			var moved := Vector2(here.x - last_position[index].x, here.z - last_position[index].z).length()
			# 重生会有大幅位移：按位移推断一次回收；可能包含掉队，不代表到达目标。
			if moved > 5.0:
				cycles[index] += 1
				runs[index] = 0
				zeros[index] += 0
				last_position[index] = here
				previous[index] = here
				continue
			last_position[index] = here
			if frame < warmup:
				previous[index] = here
				continue
			travel[index] += moved
			# 停滞口径用「窗口净位移」（actor.stalled），与观察台红杆、正式 NavSteering 脱困判据一致。
			# 逐帧位移 < 0.002 的旧口径会把贴墙抖动算成「在动」，这就是它一直显示 0 的原因，
			# 因此这里两个口径都统计，判定只用窗口口径。
			if actor.stalled:
				zeros[index] += 1
				runs[index] += 1
				longest[index] = maxi(longest[index], runs[index])
				window_zero_total += 1
			else:
				runs[index] = 0
			if moved < 0.002:
				frame_zero_total += 1
	for index in range(count):
		longest[index] = maxi(longest[index], runs[index])
	# 「真正在追」的门槛按帧数缩放：3 秒的实际位移就算在追，避免短跑时误判。
	var actor_speed: float = 4.0 if count == 0 else float(lab.actors[0].speed)
	var cohort_min := maxf(5.0, actor_speed * float(measured) / 60.0 * 0.2)
	var zero_total := 0
	var cohort := 0
	var cohort_zero := 0
	var cohort_frames := 0
	var longest_all := 0
	var total_travel := 0.0
	for index in range(count):
		zero_total += zeros[index]
		total_travel += travel[index]
		longest_all = maxi(longest_all, longest[index])
		if travel[index] <= cohort_min:
			continue
		cohort += 1
		cohort_zero += zeros[index]
		cohort_frames += measured
	times.sort()
	var report := {
		"frames": frames, "warmup": warmup, "seed": seed_value, "count": count,
		"precise_goal": true, "mode": "precise",
		"projection_cache": cache != 0,
		"cache_hits": ProjCache.hits, "cache_misses": ProjCache.misses,
		"entered": lab.entered - entered_start, "unreachable": lab.unreachable,
		"recycled_near": lab.entered - entered_start,
		"recycle_note": "entered 为旧报告兼容字段，只表示近距回收，不是路径成功率；31.5 m 仅为旧压力对照",
		"dropped": lab.dropped,
		"stall_events": lab.stall_events, "stalled_windows": lab.stalled_windows,
		"stall_reasons": lab.stall_reasons,
		"marker_travel": marker_travel,
		"recycle_near_distance": lab.recycle_near_distance,
		"zero_ratio_all": float(zero_total) / maxf(float(count * measured), 1.0),
		"cohort": cohort,
		"cohort_min_travel": cohort_min,
		"zero_ratio_cohort": float(cohort_zero) / maxf(float(cohort_frames), 1.0),
		"longest_zero_frames": longest_all,
		"zero_ratio_window": float(window_zero_total) / maxf(float(count * measured), 1.0),
		"zero_ratio_frame": float(frame_zero_total) / maxf(float(count * measured), 1.0),
		"total_travel": total_travel,
		"ms_p50": _percentile(times, 0.50), "ms_p95": _percentile(times, 0.95),
		"ms_p99": _percentile(times, 0.99),
		"metrics": totals,
		"metrics_columns": ["calls", "inclusive_us", "exclusive_us", "max_call_us"],
		"actors": [],
	}
	for index in range(count):
		report.actors.append({"id": index, "travel": travel[index], "zero_frames": zeros[index],
			"longest_zero": longest[index], "cycles": cycles[index]})
	var path := Paths.ensure_dir("reports").path_join("ring_chase_lab.json")
	var file := FileAccess.open(path, FileAccess.WRITE)
	if file == null:
		push_error("精确追击报告写入失败：" + path)
		quit(1)
		return
	file.store_string(JSON.stringify(report, "\t"))
	file.close()
	if marker_travel < 10.0 or cohort != count:
		failed = true
		push_error("[精确追击] 必须行使持续移动目标且所有追击者累计有足够位移")
	if report.zero_ratio_window > 0.10:
		failed = true
		push_error("[精确追击] 窗口净位移判定的零速比例过高 %.4f" % report.zero_ratio_window)
	# 门槛取 2.5 秒：比任何合理寻路停顿都长，只用来抓真正的长期站住。
	if longest_all > 150:
		failed = true
		push_error("[精确追击] 最长连续零速过长 %d 帧" % longest_all)
	# 停滞只统计不回收；保留原压测门槛，不把回收事件作为路径成功率。
	if lab.stall_events > maxi(1, report.entered / 10):
		failed = true
		push_error("[精确追击] 停滞 %d 次，超过近距回收 %d 次的一成；原因 %s" % [
			lab.stall_events, report.entered, str(lab.stall_reasons)])
	print("[精确追击] %d 体 %d 帧：近距回收 %d · 掉队回收 %d · 停滞 %d %s · 重生失败 %d · 在追 %d/%d · 零速 窗口%.3f/逐帧%.3f · 最长零速 %d 帧 · 标记走了 %.1f m · p50 %.2fms p95 %.2fms" % [
		count, frames, report.entered, lab.dropped, lab.stall_events, str(lab.stall_reasons),
		report.unreachable, cohort, count,
		report.zero_ratio_window, report.zero_ratio_frame, report.longest_zero_frames, marker_travel,
		report.ms_p50, report.ms_p95])
	print("[精确追击] 报告：", path)
	print("[精确追击] ", "FAIL" if failed else "PASS")
	lab.queue_free()
	await process_frame
	quit(1 if failed else 0)

func _percentile(values: Array, fraction: float) -> float:
	if values.is_empty():
		return 0.0
	return float(values[mini(values.size() - 1, int(float(values.size()) * fraction))])
