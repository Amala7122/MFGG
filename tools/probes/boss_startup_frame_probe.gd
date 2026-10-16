extends SceneTree
## 正式直战台启动诊断：真实渲染帧间隔、主线程耗时与流水线首次编译计数。
const LabScene := preload("res://prototypes/boss_lab/sediment_titan_boss_lab.tscn")
const Artifacts := preload("res://scripts/artifact_paths.gd")
const StaticCache := preload("res://scripts/valley_static_cache.gd")

func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	if DisplayServer.get_name() == "headless":
		push_error("启动帧诊断需要 --graphics。")
		quit(1)
		return
	seed(10420261014)
	var start := Time.get_ticks_usec()
	var lab := LabScene.instantiate()
	root.add_child(lab)
	current_scene = lab
	var timeline := lab.find_child("WeatherTimeline", true, false)
	if timeline != null:
		timeline.set_process(false)
		timeline.set_process_input(false)
	var time_of_day := lab.find_child("TimeOfDay", true, false)
	if time_of_day != null:
		time_of_day.call("set_time", 12, 0, 0)
		time_of_day.call("pause")
	var weather := lab.find_child("WeatherSystem", true, false)
	if weather != null:
		weather.call("set_cloud_coverage", 0.0)
		weather.call("set_cloud_density", 0.0)
		weather.call("set_rain_amount", 0.0)
		weather.call("set_fog_amount", 0.0)
		weather.call("set_snow_amount", 0.0)
		weather.set("_cloud_level", 0.0)
		weather.set("_cloud_density_level", 0.0)
		weather.set("_snow_level", 0.0)
		weather.call("_sync_extra_layers")
		weather.call("_update_environment", 0.0)
		weather.call("_update_snow_layer")
		weather.set_process(false)
	var setup_ms := (Time.get_ticks_usec() - start) / 1000.0
	var pipeline_ids: Dictionary = {}
	for key in ClassDB.class_get_integer_constant_list("Performance"):
		if String(key).contains("PIPELINE"):
			pipeline_ids[key] = ClassDB.class_get_integer_constant("Performance", key)
	var samples: Array[Dictionary] = []
	var previous := Time.get_ticks_usec()
	var nav: Node = lab.get_node("NavRegion")
	var boss: Node
	var without_boss_light := OS.get_cmdline_user_args().has("--without-boss-light")
	var without_leap_fx := OS.get_cmdline_user_args().has("--without-leap-fx")
	var without_air_debris := OS.get_cmdline_user_args().has("--without-air-debris")
	var without_flight_shadow := OS.get_cmdline_user_args().has("--without-flight-shadow")
	var without_ground_dust := OS.get_cmdline_user_args().has("--without-ground-dust")
	for frame in range(600):
		await process_frame
		var now := Time.get_ticks_usec()
		boss = get_first_node_in_group("boss")
		if boss != null and without_boss_light:
			boss._core_light.visible = false
		if boss != null and without_leap_fx:
			boss._air_debris.visible = false
			boss._flight_shadow.visible = false
			for effect in get_nodes_in_group("titan_ground_effect"):
				effect.visible = false
		elif boss != null and without_air_debris:
			boss._air_debris.visible = false
		if boss != null and without_flight_shadow:
			boss._flight_shadow.visible = false
		if without_ground_dust:
			for effect in get_nodes_in_group("titan_ground_effect"):
				effect._dust.visible = false
		var player := get_first_node_in_group("player")
		if player != null:
			player.max_health = 1000000.0
			player.health = player.max_health
			if not lab.has_node("BossTrialLoading"):
				player.set_physics_process(false)
		var stage := "before_boss"
		var preparing := lab.has_node("BossTrialLoading")
		if boss != null:
			if boss.current_state == boss.State.SPAWN:
				stage = "boss_spawn"
			elif boss._brain.history.is_empty():
				stage = "boss_ready"
			elif String(boss._brain.history[0].get("result", "")) == "preparing":
				stage = "first_attack"
			else:
				stage = "steady"
		var pipelines: Dictionary = {}
		for key in pipeline_ids:
			pipelines[key] = Performance.get_monitor(pipeline_ids[key])
		samples.append({"frame": frame, "stage": stage, "wall_ms": (now - previous) / 1000.0,
			"preparing": preparing, "playing": player != null and not paused,
			"boss_state": int(boss.current_state) if boss != null else -1,
			"boss_position": [boss.global_position.x, boss.global_position.y, boss.global_position.z] if boss != null else [],
			"leap_plan_failure": String(boss._leap_plan_failure) if boss != null else "",
			"cpu_process_ms": Performance.get_monitor(Performance.TIME_PROCESS) * 1000.0,
			"cpu_physics_ms": Performance.get_monitor(Performance.TIME_PHYSICS_PROCESS) * 1000.0,
			"nav_ready": nav.is_baked(), "pipelines": pipelines})
		previous = now
	var summaries := _summarize(samples)
	var playing_samples: Array[Dictionary] = []
	var stalls: Array[Dictionary] = []
	for sample in samples:
		if sample.playing and not sample.preparing:
			playing_samples.append(sample)
			if float(sample.wall_ms) >= 50.0:
				stalls.append(sample)
	var report := {"setup_ms": setup_ms, "static_cache_current": StaticCache.current(),
		"without_boss_light": without_boss_light,
		"without_leap_fx": without_leap_fx,
		"without_air_debris": without_air_debris,
		"without_flight_shadow": without_flight_shadow,
		"without_ground_dust": without_ground_dust,
		"phase_frames": summaries, "playing_frames": _summarize(playing_samples),
		"playing_stalls_over_50ms": stalls, "samples": samples}
	var path := Artifacts.ensure_dir("reports").path_join("boss_startup_frames.json")
	var file := FileAccess.open(path, FileAccess.WRITE)
	if file == null:
		push_error("无法保存启动帧报告：" + path)
		quit(1)
		return
	file.store_string(JSON.stringify(report, "\t"))
	file.close()
	print("[Boss 启动帧] setup_ms=", setup_ms, " cache=", report.static_cache_current,
		" playing=", JSON.stringify(report.playing_frames), " stalls=", stalls.size())
	if boss != null:
		boss._stop_action()
		boss.set_physics_process(false)
	current_scene = null
	lab.queue_free()
	await process_frame
	quit()


func _summarize(samples: Array[Dictionary]) -> Dictionary:
	var summaries: Dictionary = {}
	for stage in ["before_boss", "boss_spawn", "boss_ready", "first_attack", "steady"]:
		var values: Array[float] = []
		for sample in samples:
			if sample.stage == stage:
				values.append(sample.wall_ms)
		values.sort()
		if not values.is_empty():
			summaries[stage] = {"frames": values.size(), "p50_ms": values[values.size() / 2],
				"p95_ms": values[mini(floori(values.size() * 0.95), values.size() - 1)], "max_ms": values[-1]}
	return summaries
