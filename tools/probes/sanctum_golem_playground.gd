extends SceneTree
## 正式圣所 + 30 只泥土傀儡的试玩入口（不是性能探针，不会自动退出）。
## 用途：手动走一圈，确认群体降频/站定跳物理没有把行为压过头。
## R 重开一波，F10 退出；自动化验证可加 -- --probe-seconds=8。

const MainScene := preload("res://scenes/sanctum_main.tscn")
const Creatures := preload("res://scripts/enemies/creature_catalog.gd")
const Terrain := preload("res://scripts/terrain_field.gd")
const Golem := preload("res://scripts/prototypes/procedural_mud_golem.gd")
const PROFILE_PATH := "user://logs/golem_ai_profile.log"
const SPAWN_RING := [8.0, 10.5, 13.0, 15.5]
const COUNT := 30
var _count := 30

var _scene: Node
var _player: Node3D
var _spawned: Array[Node] = []
var _probe_seconds := 0.0
var _started_msec := 0
var _started := false
var _restarting := false
var _invincible := true
var _ai_on := true
var _frozen := false
var _shadows_on := true
var _weather_on := true
var _post_on := true
var _held: Dictionary = {}
var _hint_label: Label
var _last_profile_msec := 0
var _autoplay := false
var _pivot: Node3D
var _ablate_ai_after := -1.0
var _ablate_done := false
var _max_physics_steps := 2
var _pause_batch := false
var _no_weather := false


func _initialize() -> void:
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--probe-seconds="):
			_probe_seconds = maxf(float(arg.trim_prefix("--probe-seconds=")), 0.0)
		elif arg == "--invincible=off":
			_invincible = false
		elif arg == "--autoplay=on":
			_autoplay = true
		elif arg == "--pause-batch=on":
			_pause_batch = true
		elif arg == "--no-weather=on":
			_no_weather = true
		elif arg.begins_with("--ablate-ai-after="):
			_ablate_ai_after = float(arg.trim_prefix("--ablate-ai-after="))
		elif arg.begins_with("--max-physics-steps="):
			_max_physics_steps = clampi(int(arg.trim_prefix("--max-physics-steps=")), 1, 8)
		elif arg.begins_with("--physics-hz="):
			Engine.physics_ticks_per_second = clampi(int(arg.trim_prefix("--physics-hz=")), 15, 120)
		elif arg.begins_with("--max-fps="):
			Engine.max_fps = clampi(int(arg.trim_prefix("--max-fps=")), 0, 240)
		elif arg.begins_with("--count="):
			_count = clampi(int(arg.trim_prefix("--count=")), 1, 200)
		elif arg.begins_with("--ai-stride="):
			Golem.ai_stride = clampi(int(arg.trim_prefix("--ai-stride=")), 1, 4)
	# 低帧螺旋兜底：一帧最多 2 个固定物理步，避免 8 步把 AI 成本再放大 8 倍。
	Engine.max_physics_steps_per_frame = _max_physics_steps
	call_deferred("_run")


func _run() -> void:
	var initial := MainScene.instantiate()
	root.add_child(initial)
	current_scene = initial
	for _frame in 3:
		await process_frame
	var flow := root.get_node_or_null("GameFlow")
	if flow == null:
		push_error("试玩入口：找不到 GameFlow")
		quit(1)
		return
	var old_scene := current_scene
	flow.call("start_run")
	for _frame in 360:
		await process_frame
		if current_scene != null and current_scene != old_scene \
				and not get_nodes_in_group("player").is_empty() \
				and not bool(flow.get("_preparing_run")):
			break
	if current_scene == null or get_nodes_in_group("player").is_empty():
		push_error("试玩入口：正式场景或玩家未就绪")
		quit(1)
		return
	_scene = current_scene
	_player = get_nodes_in_group("player")[0] as Node3D
	_pivot = _player.get_node_or_null("CameraPivot") as Node3D
	_player.set_meta(&"experiment_invincible", _invincible)
	# 只留我们手动放的 30 只；正式波次停掉，避免混入其他兵种。
	for director_name in ["WaveDirector", "SurvivalDirector"]:
		var director := _scene.find_child(director_name, true, false)
		if director != null:
			director.set_process(false)
			director.set_physics_process(false)
	for spawn_point in _scene.find_children("*", "EnemySpawnPoint", true, false):
		spawn_point.set_process(false)
		spawn_point.set_physics_process(false)
	await _clear_enemies()
	await _spawn_golems()
	if _pause_batch:
		var batch := _scene.find_child("MudGolemRenderBatch", true, false)
		if batch != null:
			batch.set_process(false)
			print("[playground] batch process paused")
	if _no_weather:
		var timeline := _scene.find_child("WeatherTimeline", true, false)
		if timeline != null:
			timeline.set_process(false)
			timeline.set_physics_process(false)
			print("[playground] weather process paused")
	_add_hint()
	_started = true
	_started_msec = Time.get_ticks_msec()
	Golem.profile_enabled = true
	Golem.reset_profile()
	_last_profile_msec = _started_msec
	var header := FileAccess.open(PROFILE_PATH, FileAccess.WRITE)
	if header != null:
		header.store_line("# 正式圣所 30 傀儡 AI 分段耗时（aggregate ms/s 与每帧 ms）")
	process_frame.connect(_tick)


func _spawn_golems() -> void:
	var holder := _scene.get_node_or_null("Enemies")
	for index in _count:
		var enemy := Creatures.instantiate({"species": "mud_golem"})
		if enemy == null:
			continue
		enemy.set_meta(&"crowd_seed", 314159 + index)
		# 正式敌人标记：让它走 EnemyAttackQueue（否则试玩里会绕过队列上限）。
		enemy.set_meta(&"formal_enemy", true)
		var angle := TAU * float(index) / float(_count)
		var radius: float = SPAWN_RING[index % SPAWN_RING.size()]
		var x := _player.global_position.x + cos(angle) * radius
		var z := _player.global_position.z + sin(angle) * radius
		enemy.position = Vector3(x, Terrain.height_at(x, z) + 0.6, z)
		enemy.add_to_group("dynamic_enemies")
		if enemy.has_method("set_combat_target"):
			enemy.call("set_combat_target", _player)
		(holder if holder != null else _scene).add_child(enemy)
		_spawned.append(enemy)
		# 分批出场：避免 30 只同帧实例化 + 激活造成一次性的 min 8 尖峰。
		if (index + 1) % 5 == 0:
			await process_frame
	print("[playground] spawned=%d invincible=%s" % [_spawned.size(), _invincible])


func _clear_enemies() -> void:
	for enemy in _spawned:
		if is_instance_valid(enemy):
			enemy.queue_free()
	_spawned.clear()
	for enemy in get_nodes_in_group("enemies"):
		if is_instance_valid(enemy):
			enemy.queue_free()
	for group in ["enemy_projectiles", "enemy_hazards"]:
		for node in get_nodes_in_group(group):
			if is_instance_valid(node) and not node.is_queued_for_deletion():
				node.queue_free()
	for _frame in 4:
		await process_frame


func _restart() -> void:
	if not _started or _restarting:
		return
	_restarting = true
	await _clear_enemies()
	await _spawn_golems()
	_started_msec = Time.get_ticks_msec()
	_restarting = false


func _tick() -> void:
	if not _started:
		return
	if _autoplay:
		Input.action_press("move_right")
		Input.action_press("shoot")
		if _pivot != null:
			_pivot.rotation.y += 0.03
	if _ablate_ai_after > 0.0 and not _ablate_done \
			and (Time.get_ticks_msec() - _started_msec) / 1000.0 >= _ablate_ai_after:
		_ablate_done = true
		for enemy in _spawned:
			if is_instance_valid(enemy):
				enemy.set("ai_enabled", false)
		Golem.reset_profile()
		_last_profile_msec = Time.get_ticks_msec()
		print("[playground] AI off after %.1fs" % _ablate_ai_after)
	if Input.is_key_pressed(KEY_F10):
		quit()
		return
	if Input.is_key_pressed(KEY_R):
		_restart()
	if _pressed_once(KEY_F1):
		_ai_on = not _ai_on
		for enemy in _spawned:
			if is_instance_valid(enemy):
				enemy.set("ai_enabled", _ai_on)
		_update_hint()
	if _pressed_once(KEY_F2):
		_frozen = not _frozen
		for enemy in _spawned:
			if is_instance_valid(enemy):
				enemy.process_mode = Node.PROCESS_MODE_DISABLED if _frozen else Node.PROCESS_MODE_INHERIT
		_update_hint()
	if _pressed_once(KEY_F3):
		_shadows_on = not _shadows_on
		for light in _scene.find_children("*", "DirectionalLight3D", true, false):
			(light as DirectionalLight3D).shadow_enabled = _shadows_on
		_update_hint()
	if _pressed_once(KEY_F4):
		_weather_on = not _weather_on
		var timeline := _scene.find_child("WeatherTimeline", true, false)
		if timeline != null:
			timeline.visible = _weather_on
			timeline.set_process(_weather_on)
		for particles in _scene.find_children("*", "GPUParticles3D", true, false):
			(particles as GPUParticles3D).visible = _weather_on
		for particles in _scene.find_children("*", "CPUParticles3D", true, false):
			(particles as CPUParticles3D).visible = _weather_on
		_update_hint()
	if _pressed_once(KEY_F5):
		_post_on = not _post_on
		var post := root.get_node_or_null("PostProcess")
		if post != null:
			post.visible = _post_on
		_update_hint()
	if _probe_seconds > 0.0 and (Time.get_ticks_msec() - _started_msec) / 1000.0 >= _probe_seconds:
		quit()
	if Time.get_ticks_msec() - _last_profile_msec >= 2000:
		_log_profile()


func _log_profile() -> void:
	var now := Time.get_ticks_msec()
	var seconds := maxf((now - _last_profile_msec) / 1000.0, 0.001)
	var frames := maxi(Golem.prof_frames, 1)
	var attackers := 0
	var pending := 0
	if _scene != null:
		var queue := _scene.get_node_or_null("EnemyAttackQueue")
		if queue != null:
			var snapshot: Dictionary = queue.call("snapshot")
			attackers = int(snapshot.get("total", 0))
			pending = int(snapshot.get("pending", 0))
	var line := "[golem_ai] enemies=%d attackers=%d pending=%d try=%d reach=%d can=%d grant=%d fps=%.1f process_ms=%.1f physics_ms=%.1f nav_ms=%.1f draw=%d nodes=%d tick_ms_s=%.1f crowd_ms_s=%.1f attack_ms_s=%.1f gate_ms_s=%.1f total_ms_s=%.1f tick_ms_frame=%.2f crowd_ms_frame=%.2f attack_ms_frame=%.2f gate_ms_frame=%.2f total_ms_frame=%.2f rest_ms_frame=%.2f" % [
		_spawned.size(), attackers, pending, Golem.dbg_attempt, Golem.dbg_in_reach, Golem.dbg_can, Golem.dbg_grant, Engine.get_frames_per_second(),
		Performance.get_monitor(Performance.TIME_PROCESS) * 1000.0,
		Performance.get_monitor(Performance.TIME_PHYSICS_PROCESS) * 1000.0,
		Performance.get_monitor(Performance.TIME_NAVIGATION_PROCESS) * 1000.0,
		int(Performance.get_monitor(Performance.RENDER_TOTAL_DRAW_CALLS_IN_FRAME)),
		int(Performance.get_monitor(Performance.OBJECT_NODE_COUNT)),
		Golem.prof_tick_us / 1000.0 / seconds,
		Golem.prof_crowd_us / 1000.0 / seconds,
		Golem.prof_attack_us / 1000.0 / seconds,
		Golem.prof_gate_us / 1000.0 / seconds,
		Golem.prof_total_us / 1000.0 / seconds,
		Golem.prof_tick_us / 1000.0 / frames,
		Golem.prof_crowd_us / 1000.0 / frames,
		Golem.prof_attack_us / 1000.0 / frames,
		Golem.prof_gate_us / 1000.0 / frames,
		Golem.prof_total_us / 1000.0 / frames,
		maxf((Golem.prof_total_us - Golem.prof_tick_us - Golem.prof_crowd_us - Golem.prof_attack_us - Golem.prof_gate_us) / 1000.0 / frames, 0.0)]
	var file := FileAccess.open(PROFILE_PATH, FileAccess.READ_WRITE)
	if file == null:
		file = FileAccess.open(PROFILE_PATH, FileAccess.WRITE)
	else:
		file.seek_end()
	if file != null:
		file.store_line(line)
	print(line)
	Golem.reset_profile()
	_last_profile_msec = now


func _pressed_once(key: Key) -> bool:
	var down := Input.is_key_pressed(key)
	var was := bool(_held.get(key, false))
	_held[key] = down
	return down and not was


func _add_hint() -> void:
	var layer := CanvasLayer.new()
	layer.name = "PlaygroundHint"
	_hint_label = Label.new()
	_hint_label.add_theme_font_size_override("font_size", 16)
	_hint_label.position = Vector2(24, 24)
	_hint_label.modulate = Color(0.95, 0.92, 0.82, 0.9)
	layer.add_child(_hint_label)
	root.add_child(layer)
	_update_hint()


func _update_hint() -> void:
	if _hint_label == null:
		return
	_hint_label.text = ("正式圣所 · %d 只泥土傀儡 · 无敌：%s · 物理步数上限 %d\n"
		+ "R 重开 · F10 退出\n"
		+ "F1 AI：%s · F2 冻结：%s · F3 阴影：%s · F4 天气粒子：%s · F5 后处理：%s") % [
		_count,
		"开" if _invincible else "关",
		_max_physics_steps,
		"开" if _ai_on else "关",
		"是" if _frozen else "否",
		"开" if _shadows_on else "关",
		"开" if _weather_on else "关",
		"开" if _post_on else "关"]
