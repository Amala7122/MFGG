extends SceneTree
## 正式圣所 + 30 只泥土傀儡的试玩入口（不是性能探针，不会自动退出）。
## 用途：手动走一圈，确认群体降频/站定跳物理没有把行为压过头。
## R 重开一波，F10 退出；自动化验证可加 -- --probe-seconds=8。

const MainScene := preload("res://scenes/sanctum_main.tscn")
const Creatures := preload("res://scripts/enemies/creature_catalog.gd")
const Terrain := preload("res://scripts/terrain_field.gd")
const Golem := preload("res://scripts/prototypes/procedural_mud_golem.gd")
const FlowFieldScript := preload("res://scripts/flow_field.gd")
const NavData := preload("res://scripts/navigation/nav_dataset.gd")
const Species := preload("res://scripts/navigation/fodder_species.gd")
const SpatialController := preload("res://scripts/combat_spatial_controller.gd")
const NAV_PATH := "res://data/navigation/sanctum_nav.json"
const FodderFieldScript := preload("res://scripts/prototypes/fodder_field.gd")
const MovementProfileScript := preload("res://scripts/prototypes/movement_profile.gd")
const CombatFX := preload("res://scripts/combat_fx.gd")
const PROFILE_PATH := "user://logs/golem_ai_profile.log"
const SPAWN_RING := [8.0, 10.5, 13.0, 15.5]
const COUNT := 30
var _count := 30
## 精英数量：完整 CharacterBody3D 敌人，和炮灰场同时存在（0 = 只跑炮灰）。
var _elites := 0
## 接入其它敌人：--body=fast_beast 会切到对应的 nav 数据与通行表。
var _body_id := "mud_golem"
var _nav_path := NAV_PATH
var _runtime_profile = null

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
var _flow
var _flow_build_ms := 0.0
var _nav: Dictionary = {}
var _last_flow_msec := 0
var _last_flow_pos := Vector3.ZERO
var _autoplay := false
var _pivot: Node3D
var _ablate_ai_after := -1.0
var _ablate_done := false
var _max_physics_steps := 2
var _pause_batch := false
var _no_weather := false
var _no_grass := false
var _no_decor := false
var _no_shadows := false
var _no_post := false
var _fodder := false
var _fodder_field
var _fodder_aoe := false
var _last_fodder_aoe := 0
var _fodder_ignore_terrain := false
var _fodder_step := 0.7
var _fodder_slope := 40.0
var _fodder_flow_debug := false
var _fodder_spread_mode := 2
var _map_click := false
var _map_camera: Camera3D
var _map_click_latched := false
var _map_yaw := 0.0
var _map_pitch := 0.98
var _map_distance := 38.0
var _map_last_mouse := Vector2.INF
var _map_status := ""
var _map_status_clock := 0.0
var _map_last_click := Vector2(INF, INF)
var _map_last_reachable := false
var _count_spin: SpinBox
var _count_layer: CanvasLayer
var _map_sweep := false
var _sweep_seconds := 2.5
var _fodder_dump := false
var _player_at := Vector2.INF
var _shot_path := ""
var _shot_at := 4.0
var _shot_done := false
var _death_test := false
var _death_done := false


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
		elif arg == "--no-grass=on":
			_no_grass = true
		elif arg == "--no-decor=on":
			_no_decor = true
		elif arg == "--no-shadows=on":
			_no_shadows = true
		elif arg == "--no-post=on":
			_no_post = true
		elif arg == "--heightmap=on":
			Terrain.collision_backend = "heightmap"
		elif arg == "--merged=on":
			Golem.fodder_visual = true
		elif arg == "--fodder=on":
			_fodder = true
		elif arg == "--fodder-aoe=on":
			_fodder_aoe = true
		elif arg == "--fodder-ignore-terrain=on":
			_fodder_ignore_terrain = true
		elif arg.begins_with("--fodder-step="):
			_fodder_step = float(arg.trim_prefix("--fodder-step="))
		elif arg.begins_with("--fodder-slope="):
			_fodder_slope = float(arg.trim_prefix("--fodder-slope="))
		elif arg == "--fodder-flow-debug=on":
			_fodder_flow_debug = true
		elif arg == "--spread=on":
			_fodder_spread_mode = 1
		elif arg == "--spread=slots":
			_fodder_spread_mode = 2
		elif arg == "--spread=press":
			_fodder_spread_mode = 3
		elif arg == "--map-click=on":
			_map_click = true
		elif arg == "--map-sweep=on":
			_map_sweep = true
		elif arg == "--fodder-dump=on":
			_fodder_dump = true
		elif arg.begins_with("--sweep-seconds="):
			_sweep_seconds = maxf(float(arg.trim_prefix("--sweep-seconds=")), 0.5)
		elif arg.begins_with("--player-at="):
			var parts := arg.trim_prefix("--player-at=").split(",")
			if parts.size() == 2:
				_player_at = Vector2(float(parts[0]), float(parts[1]))
		elif arg.begins_with("--shot="):
			_shot_path = arg.trim_prefix("--shot=")
		elif arg.begins_with("--shot-at="):
			_shot_at = float(arg.trim_prefix("--shot-at="))
		elif arg == "--death-test=on":
			_death_test = true
		elif arg.begins_with("--ablate-ai-after="):
			_ablate_ai_after = float(arg.trim_prefix("--ablate-ai-after="))
		elif arg.begins_with("--max-physics-steps="):
			_max_physics_steps = clampi(int(arg.trim_prefix("--max-physics-steps=")), 1, 8)
		elif arg.begins_with("--physics-hz="):
			Engine.physics_ticks_per_second = clampi(int(arg.trim_prefix("--physics-hz=")), 15, 120)
		elif arg.begins_with("--max-fps="):
			Engine.max_fps = clampi(int(arg.trim_prefix("--max-fps=")), 0, 240)
		elif arg.begins_with("--count="):
			_count = clampi(int(arg.trim_prefix("--count=")), 1, 2000)
		elif arg.begins_with("--elites="):
			_elites = clampi(int(arg.trim_prefix("--elites=")), 0, 40)
		elif arg == "--elite-direct=on":
			Golem.elite_direct_enabled = true
		elif arg.begins_with("--plan-budget-us="):
			SpatialController.frame_budget_usec = clampi(int(arg.trim_prefix("--plan-budget-us=")), 500, 20000)
		elif arg.begins_with("--plan-step-us="):
			SpatialController.step_budget_usec = clampi(int(arg.trim_prefix("--plan-step-us=")), 100, 8000)
		elif arg.begins_with("--ai-stride="):
			Golem.ai_stride = clampi(int(arg.trim_prefix("--ai-stride=")), 1, 4)
		elif arg.begins_with("--body="):
			_body_id = arg.trim_prefix("--body=")
	if _body_id != "mud_golem" and not Species.has_species(_body_id):
		push_error("未登记的敌人种类：%s" % _body_id)
		_body_id = "mud_golem"
	# 低帧螺旋兜底：一帧最多 2 个固定物理步，避免 8 步把 AI 成本再放大 8 倍。
	Engine.max_physics_steps_per_frame = _max_physics_steps
	call_deferred("_run")


func _run() -> void:
	if _body_id != "mud_golem" and not _prepare_species(_body_id):
		push_error("敌人种类准备失败：%s" % _body_id)
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
	if is_finite(_player_at.x):
		_player.global_position = Vector3(_player_at.x,
			Terrain.height_at(_player_at.x, _player_at.y) + 1.0, _player_at.y)
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
	_apply_scene_ablations()
	if not _fodder:
		var nav := _nav_data()
		_flow = FlowFieldScript.new()
		_flow.configure(nav.flow, float(nav.grid.half_extent))
		_flow.set_height_profile(null, NavData.load_profile(nav))
		_flow.rebuild(_player.global_position)
		_flow_build_ms = _flow.rebuild_usec / 1000.0
		Golem.flow_field = _flow
		_last_flow_pos = _player.global_position
		_last_flow_msec = Time.get_ticks_msec()
		print("[flow] mask_ms=%.1f rebuild_ms=%.1f reachable=%d" % [
			_flow.mask_build_usec / 1000.0, _flow_build_ms, _flow.reachable_cells])
	if _fodder:
		_fodder_field = FodderFieldScript.new()
		_fodder_field.top_level = true
		_fodder_field.species_id = _body_id
		_scene.add_child(_fodder_field)
		_fodder_field.setup(_player, null, _count, _player.global_position, _make_fodder_profile(), _nav_data())
		if _fodder_flow_debug:
			_fodder_field.toggle_flow_debug()
		_fodder_field.set_spread_mode(_fodder_spread_mode)
		print("[fodder] units=%d spread=%d" % [_fodder_field.units(), _fodder_spread_mode])
		if _elites > 0:
			await _spawn_elites(_elites)
	else:
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
	if _fodder:
		_add_count_panel()
	if _map_click:
		_setup_map_camera()
	_started = true
	_started_msec = Time.get_ticks_msec()
	if _fodder_dump:
		await create_timer(5.0).timeout
		if _fodder_field != null:
			_fodder_field.dump_stuck_units()
		quit()
		return
	if _map_sweep:
		await _run_map_sweep()
		quit()
		return
	Golem.profile_enabled = not _fodder
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
		enemy.set_meta(&"enemy_entry", {"species": "mud_golem", "title": "泥土傀儡", "tuning": {}})
		# 正式敌人标记：让它走 EnemyAttackQueue（否则试玩里会绕过队列上限）。
		enemy.set_meta(&"formal_enemy", true)
		# 大群围殴：3.5m 内停止寻路，只面向/踏步/等出手，省掉无效移动。
		if _count > 40:
			enemy.set_meta(&"blob_hold", true)
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


## 精英：完整 CharacterBody3D 敌人，用当前种类，和炮灰场共存。
func _spawn_elites(amount: int) -> void:
	var holder := _scene.get_node_or_null("Enemies")
	for index in amount:
		var enemy := Creatures.instantiate({"species": _body_id, "title": "精英"})
		if enemy == null:
			continue
		enemy.set_meta(&"formal_enemy", true)
		var angle := TAU * float(index) / float(maxi(amount, 1))
		var radius := 10.0 + float(index % 3) * 2.0
		var x := _player.global_position.x + cos(angle) * radius
		var z := _player.global_position.z + sin(angle) * radius
		enemy.position = Vector3(x, Terrain.height_at(x, z) + 0.6, z)
		enemy.add_to_group("dynamic_enemies")
		if enemy.has_method("set_combat_target"):
			enemy.call("set_combat_target", _player)
		(holder if holder != null else _scene).add_child(enemy)
		_spawned.append(enemy)
		if (index + 1) % 5 == 0:
			await process_frame
	print("[playground] elites=%d species=%s" % [_spawned.size(), _body_id])


func _apply_scene_ablations() -> void:
	var grass := _scene.get_node_or_null("Grass")
	if grass != null:
		var grass_instances := 0
		var grass_vertices := 0
		for node in grass.find_children("*", "MultiMeshInstance3D", true, false):
			var multimesh := (node as MultiMeshInstance3D).multimesh
			if multimesh == null or not (node as Node3D).is_visible_in_tree():
				continue
			grass_instances += multimesh.visible_instance_count
			if multimesh.mesh != null and multimesh.mesh.get_surface_count() > 0:
				grass_vertices += multimesh.visible_instance_count * multimesh.mesh.surface_get_array_len(0)
		print("[env] grass_instances=%d grass_vertices=%d" % [grass_instances, grass_vertices])
		if _no_grass:
			grass.visible = false
			grass.set_process(false)
	if _no_decor:
		for node_name in ["WorldDecor", "Cover"]:
			var decor := _scene.get_node_or_null(node_name)
			if decor != null:
				decor.visible = false
	if _no_shadows:
		for light in _scene.find_children("*", "DirectionalLight3D", true, false):
			(light as DirectionalLight3D).shadow_enabled = false
	if _no_post:
		var post := root.get_node_or_null("PostProcess")
		if post != null:
			post.visible = false


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


func _nav_data() -> Dictionary:
	if _nav.is_empty():
		_nav = NavData.load_file(_nav_path)
	return _nav


func _make_fodder_profile():
	if _runtime_profile != null:
		return _runtime_profile
	var profile = NavData.load_profile(_nav_data())
	if profile == null:
		return null
	profile = profile.duplicate()
	if _fodder_ignore_terrain:
		profile.id = "spider_test"
	profile.step_height = _fodder_step
	profile.max_slope_deg = _fodder_slope
	profile.ignore_terrain = _fodder_ignore_terrain
	return profile


func _clear_fodder() -> void:
	if is_instance_valid(_fodder_field):
		_fodder_field.queue_free()
	_fodder_field = null
	for node in get_nodes_in_group("fodder_debris"):
		if is_instance_valid(node):
			node.queue_free()
	for _frame in 2:
		await process_frame


func _restart() -> void:
	if not _started or _restarting:
		return
	_restarting = true
	await _clear_enemies()
	await _clear_fodder()
	if _fodder:
		_fodder_field = FodderFieldScript.new()
		_fodder_field.top_level = true
		_fodder_field.species_id = _body_id
		_scene.add_child(_fodder_field)
		_fodder_field.setup(_player, _flow, _count, _player.global_position, _make_fodder_profile(), _nav_data())
		if _fodder_flow_debug:
			_fodder_field.toggle_flow_debug()
		_fodder_field.set_spread_mode(_fodder_spread_mode)
		print("[fodder] restart units=%d spread=%d" % [
			_fodder_field.units(), _fodder_spread_mode])
		if _elites > 0:
			await _spawn_elites(_elites)
	else:
		await _spawn_golems()
	_started_msec = Time.get_ticks_msec()
	_restarting = false


func _run_map_sweep() -> void:
	print("[sweep] begin seconds=%.1f points=25" % _sweep_seconds)
	var failures := 0
	for row in 5:
		for column in 5:
			var x := float(column - 2) * 24.0
			var z := float(row - 2) * 24.0
			_player.global_position = Vector3(x, Terrain.height_at(x, z) + 0.2, z)
			var initial_nearest := _sweep_nearest(x, z)
			for _frame in int(_sweep_seconds * 30.0):
				await physics_frame
			var near := 0
			var nearest := INF
			for position in _fodder_field.live_positions():
				var distance := Vector2(position.x - x, position.z - z).length()
				nearest = minf(nearest, distance)
				if distance <= 4.0:
					near += 1
			var progress := initial_nearest - nearest
			var failed := nearest > 4.0 and progress < 1.5
			if failed:
				failures += 1
			print("[sweep] point=(%.1f, %.1f) start=%.1f end=%.1f progress=%.1f near4=%d fail=%s" % [
				x, z, initial_nearest, nearest, progress, near, str(failed)])
	print("[sweep] failures=%d/25" % failures)
	quit(0 if failures == 0 else 1)


func _sweep_nearest(x: float, z: float) -> float:
	var nearest := INF
	for position in _fodder_field.live_positions():
		nearest = minf(nearest, Vector2(position.x - x, position.z - z).length())
	return nearest


func _tick() -> void:
	if not _started:
		return
	if _map_click:
		_handle_map_orbit()
		_update_map_camera()
		_try_map_click()
		_update_map_status()
	if _autoplay:
		Input.action_press("move_right")
		Input.action_press("shoot")
		if _pivot != null:
			_pivot.rotation.y += 0.03
	if _flow != null:
		if _flow.poll_rebuild():
			_flow_build_ms = _flow.rebuild_usec / 1000.0
		var flow_now := Time.get_ticks_msec()
		var flow_moved := _player.global_position.distance_to(_last_flow_pos)
		# 玩家不动就不重建；只在他真正移动时更新流场，避免周期性尖峰。
		if flow_moved > 2.0 or (flow_now - _last_flow_msec >= 3000 and flow_moved > 0.5):
			_flow.request_rebuild(_player.global_position)
			_last_flow_msec = flow_now
			_last_flow_pos = _player.global_position
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
	if _pressed_once(KEY_F6):
		if _fodder_field != null:
			_fodder_field.toggle_flow_debug()
		_update_hint()
	if _pressed_once(KEY_F7):
		_save_manual_shot()
	if _pressed_once(KEY_F8):
		if _fodder_field != null:
			_fodder_field.queue_pacing = not _fodder_field.queue_pacing
			print("[fodder] queue_pacing=%s（门洞/接战让行实验，默认关）"
				% str(_fodder_field.queue_pacing))
		_update_hint()
	if _pressed_once(KEY_F9):
		if _fodder_field != null:
			_fodder_spread_mode = (_fodder_spread_mode + 1) % 4
			_fodder_field.set_spread_mode(_fodder_spread_mode)
			print("[fodder] spread_mode=%d（0=关 1=摊开 2=站位 3=压上）" % _fodder_spread_mode)
		_update_hint()
	if _pressed_once(KEY_F11):
		Golem.elite_direct_enabled = not Golem.elite_direct_enabled
		print("[elite] direct=%s（中距直线快路，默认关）" % str(Golem.elite_direct_enabled))
		_update_hint()
	if _pressed_once(KEY_PAGEDOWN):
		_cycle_species(1)
	if _pressed_once(KEY_PAGEUP):
		_cycle_species(-1)
	# 精英和炮灰同场时，把炮灰的流场借给泥偶精英，否则它们只能等共享规划预算。
	if _elites > 0 and _fodder_field != null and _fodder_field.flow != null:
		Golem.flow_field = _fodder_field.flow
	if not _shot_done and _shot_path != "" \
			and (Time.get_ticks_msec() - _started_msec) / 1000.0 >= _shot_at:
		_shot_done = true
		var image := root.get_texture().get_image()
		if image != null:
			image.save_png(_shot_path)
			print("[shot] %s" % _shot_path)
	if _probe_seconds > 0.0 and (Time.get_ticks_msec() - _started_msec) / 1000.0 >= _probe_seconds:
		quit()
	if _fodder_aoe and _fodder_field != null:
		var aoe_now := Time.get_ticks_msec()
		if aoe_now - _last_fodder_aoe >= 1500 and is_instance_valid(_player):
			_last_fodder_aoe = aoe_now
			var aoe_hits: int = CombatFX.apply_radial_damage(
				_player, _player.global_position, 9.0, 200.0, 6.0, false)
			print("[fodder_aoe] hits=%d debris=%d" % [
				aoe_hits, get_nodes_in_group("fodder_debris").size()])
	if _death_test and not _death_done and _spawned.size() > 0 \
			and (Time.get_ticks_msec() - _started_msec) >= 2000:
		_death_done = true
		var victim: Node = _spawned[0]
		if is_instance_valid(victim):
			victim.call("take_damage", 999999.0)
			await process_frame
			print("[death] debris=%d nodes=%d" % [
				get_nodes_in_group("mud_golem_debris").size(),
				int(Performance.get_monitor(Performance.OBJECT_NODE_COUNT))])
	if Time.get_ticks_msec() - _last_profile_msec >= 2000:
		_log_profile()


func _log_profile() -> void:
	var now := Time.get_ticks_msec()
	var seconds := maxf((now - _last_profile_msec) / 1000.0, 0.001)
	if _elites > 0 and not _spawned.is_empty():
		var near := 0
		var total := 0.0
		for enemy in _spawned:
			if is_instance_valid(enemy):
				var distance := (enemy as Node3D).global_position.distance_to(_player.global_position)
				total += distance
				if distance <= 6.0:
					near += 1
		print("[elites] near6=%d/%d avg_dist=%.1f flow=%s" % [
			near, _spawned.size(), total / float(maxi(_spawned.size(), 1)),
			str(Golem.flow_field != null)])
	if _fodder_field != null:
		print("[fodder] units=%d alive=%d active=%d attacks=%d hits=%d kills=%d rays=%d resolve=%d inside=%d blocked=%d stalled=%d stepup=%d spawn_move=%d unstuck=%d surface_ms=%.1f fps=%.1f process_ms=%.1f physics_ms=%.1f draw=%d prim=%d nodes=%d" % [
			_fodder_field.units(), _fodder_field.alive_count, _fodder_field.active_attackers,
			_fodder_field.total_attacks, _fodder_field.hits_taken, _fodder_field.kills,
			_fodder_field.ray_queries, _fodder_field.resolve_hits, _fodder_field.resolve_inside,
			_fodder_field.blocked_hits, _fodder_field.stalled_units, _fodder_field.step_up_count,
			_fodder_field.spawn_relocations, _fodder_field.unstuck_count,
			_fodder_field.surface_build_ms,
			Engine.get_frames_per_second(),
			Performance.get_monitor(Performance.TIME_PROCESS) * 1000.0,
			Performance.get_monitor(Performance.TIME_PHYSICS_PROCESS) * 1000.0,
			int(Performance.get_monitor(Performance.RENDER_TOTAL_DRAW_CALLS_IN_FRAME)),
			int(Performance.get_monitor(Performance.RENDER_TOTAL_PRIMITIVES_IN_FRAME)),
			int(Performance.get_monitor(Performance.OBJECT_NODE_COUNT))])
		_fodder_field.reset_stats()
		_last_profile_msec = now
		return
	var frames := maxi(Golem.prof_frames, 1)
	var attackers := 0
	var pending := 0
	if _scene != null:
		var queue := _scene.get_node_or_null("EnemyAttackQueue")
		if queue != null:
			var snapshot: Dictionary = queue.call("snapshot")
			attackers = int(snapshot.get("total", 0))
			pending = int(snapshot.get("pending", 0))
	var line := "[golem_ai] enemies=%d attackers=%d pending=%d flow_ms=%.2f try=%d reach=%d can=%d grant=%d fps=%.1f process_ms=%.1f physics_ms=%.1f nav_ms=%.1f draw=%d prim=%d nodes=%d tick_ms_s=%.1f crowd_ms_s=%.1f attack_ms_s=%.1f gate_ms_s=%.1f total_ms_s=%.1f tick_ms_frame=%.2f crowd_ms_frame=%.2f attack_ms_frame=%.2f gate_ms_frame=%.2f total_ms_frame=%.2f rest_ms_frame=%.2f" % [
		_spawned.size(), attackers, pending, _flow_build_ms, Golem.dbg_attempt, Golem.dbg_in_reach, Golem.dbg_can, Golem.dbg_grant, Engine.get_frames_per_second(),
		Performance.get_monitor(Performance.TIME_PROCESS) * 1000.0,
		Performance.get_monitor(Performance.TIME_PHYSICS_PROCESS) * 1000.0,
		Performance.get_monitor(Performance.TIME_NAVIGATION_PROCESS) * 1000.0,
		int(Performance.get_monitor(Performance.RENDER_TOTAL_DRAW_CALLS_IN_FRAME)),
		int(Performance.get_monitor(Performance.RENDER_TOTAL_PRIMITIVES_IN_FRAME)),
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


func _save_manual_shot() -> void:
	var directory := "D:/Godot/lab/_tests/pathlab_shots"
	DirAccess.make_dir_recursive_absolute(directory)
	var stamp := Time.get_datetime_string_from_system().replace(":", "-")
	var path := "%s/pathlab_%s.png" % [directory, stamp]
	var image := root.get_texture().get_image()
	if image == null:
		print("[shot] failed: no viewport texture")
		return
	var error := image.save_png(path)
	if error != OK:
		print("[shot] failed: %s error=%d" % [path, error])
		return
	DisplayServer.clipboard_set(path)
	print("[shot] %s" % path)


func _pressed_once(key: Key) -> bool:
	var down := Input.is_key_pressed(key)
	var was := bool(_held.get(key, false))
	_held[key] = down
	return down and not was


func _setup_map_camera() -> void:
	# 观察/传送模式：玩家只作为敌人目标，不再处理移动、射击、相机和鼠标捕获。
	_player.process_mode = Node.PROCESS_MODE_DISABLED
	MouseControl.mode = Input.MOUSE_MODE_VISIBLE
	_force_sunny()
	_map_camera = Camera3D.new()
	_map_camera.name = "MapClickCamera"
	_map_camera.fov = 55.0
	_scene.add_child(_map_camera)
	_update_map_camera()


func _force_sunny() -> void:
	var weather := _find_script_node("res://scripts/weather_system.gd")
	if weather != null:
		for method in ["set_cloud_coverage", "set_rain_amount", "set_snow_amount", "set_fog_amount"]:
			weather.call(method, 0.0)
		weather.set_process(false)
		weather.set_physics_process(false)
	var timeline := _find_script_node("res://scripts/weather_timeline.gd")
	if timeline != null:
		timeline.set_process(false)
		timeline.set_physics_process(false)
		var debug_label = timeline.get("_debug_label")
		if debug_label is Label:
			debug_label.visible = false
	var time_of_day := _find_script_node("res://addons/sky_3d/src/TimeOfDay.gd")
	if time_of_day != null:
		time_of_day.set("current_time", 12.0)
		time_of_day.set_process(false)
	print("[pathlab] weather frozen sunny")


func _find_script_node(path: String) -> Node:
	for node in _scene.find_children("*", "Node", true, false):
		var script = node.get_script()
		if script != null and String(script.resource_path) == path:
			return node
	return null


func _handle_map_orbit() -> void:
	var mouse := root.get_viewport().get_mouse_position()
	if Input.is_mouse_button_pressed(MOUSE_BUTTON_RIGHT):
		if _map_last_mouse != Vector2.INF:
			var delta := mouse - _map_last_mouse
			_map_yaw -= delta.x * 0.008
			_map_pitch = clampf(_map_pitch + delta.y * 0.006, 0.18, 1.45)
		_map_last_mouse = mouse
	else:
		_map_last_mouse = Vector2.INF
	if Input.is_mouse_button_pressed(MOUSE_BUTTON_WHEEL_UP):
		_map_distance = clampf(_map_distance - 2.0, 12.0, 70.0)
	if Input.is_mouse_button_pressed(MOUSE_BUTTON_WHEEL_DOWN):
		_map_distance = clampf(_map_distance + 2.0, 12.0, 70.0)


func _update_map_camera() -> void:
	if _map_camera == null or not is_instance_valid(_player):
		return
	MouseControl.mode = Input.MOUSE_MODE_VISIBLE
	var focus := _player.global_position + Vector3(0.0, 1.0, 0.0)
	var offset := Vector3(
		sin(_map_yaw) * cos(_map_pitch),
		sin(_map_pitch),
		cos(_map_yaw) * cos(_map_pitch)) * _map_distance
	_map_camera.global_position = focus + offset
	_map_camera.look_at(focus, Vector3.UP)
	_map_camera.current = true


func _try_map_click() -> void:
	var pressed := Input.is_mouse_button_pressed(MOUSE_BUTTON_LEFT)
	if pressed and not _map_click_latched and _map_camera != null:
		if root.get_viewport().gui_get_hovered_control() != null:
			_map_click_latched = true
			return
		var mouse := root.get_viewport().get_mouse_position()
		var from := _map_camera.project_ray_origin(mouse)
		var to := from + _map_camera.project_ray_normal(mouse) * 300.0
		var query := PhysicsRayQueryParameters3D.create(from, to, 1)
		var hit: Dictionary = _scene.get_world_3d().direct_space_state.intersect_ray(query)
		if not hit.is_empty():
			if absf(hit.position.x) > 80.0 or absf(hit.position.z) > 80.0:
				_map_status = "click outside baked map (±80m): (%.1f, %.1f)" % [
					hit.position.x, hit.position.z]
				_update_hint()
				_map_click_latched = true
				return
			var previous_target: Vector3 = hit.position
			var reachable: bool = _fodder_field != null and _fodder_field.is_world_reachable(previous_target)
			var nearest_point := previous_target
			if not reachable and _fodder_field != null:
				nearest_point = _fodder_field.nearest_reachable(previous_target)
			_map_last_click = Vector2(previous_target.x, previous_target.z)
			_map_last_reachable = reachable
			_map_status = "click=(%.1f, %.1f) reachable=%s nearest=(%.1f, %.1f)" % [
				_map_last_click.x, _map_last_click.y, str(reachable),
				nearest_point.x, nearest_point.z]
			var coordinate_text := "%.2f, %.2f" % [_map_last_click.x, _map_last_click.y]
			DisplayServer.clipboard_set(coordinate_text)
			print("[pathlab] click target=(%.2f, %.2f) reachable=%s coordinate_copied=%s" % [
				previous_target.x, previous_target.z, str(reachable), coordinate_text])
			_player.global_position = hit.position + Vector3.UP * 0.1
			_update_map_camera()
			_map_status_clock = 0.0
			_update_hint()
	_map_click_latched = pressed


func _update_map_status() -> void:
	if _fodder_field == null or not is_instance_valid(_player):
		return
	_map_status_clock += 1.0 / 30.0
	if _map_status_clock < 0.5:
		return
	_map_status_clock = 0.0
	var near := 0
	var nearest := INF
	for position in _fodder_field.live_positions():
		var distance := Vector2(position.x - _player.global_position.x,
			position.z - _player.global_position.z).length()
		nearest = minf(nearest, distance)
		if distance <= 4.0:
			near += 1
	var text := "player=(%.1f, %.1f) y=%.2f  near4=%d nearest=%.1f" % [
		_player.global_position.x, _player.global_position.z,
		_player.global_position.y, near, nearest]
	if _map_last_click.x != INF:
		text += "  click=(%.1f, %.1f) reachable=%s" % [
			_map_last_click.x, _map_last_click.y, str(_map_last_reachable)]
	if _map_status != text:
		_map_status = text
		_update_hint()


func _add_count_panel() -> void:
	_count_layer = CanvasLayer.new()
	_count_layer.layer = 20
	root.add_child(_count_layer)
	var panel := PanelContainer.new()
	panel.position = Vector2(24, 168)
	panel.custom_minimum_size = Vector2(360, 44)
	_count_layer.add_child(panel)
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 6)
	panel.add_child(row)
	var label := Label.new()
	label.text = "Fodder 数量"
	label.add_theme_font_size_override("font_size", 14)
	row.add_child(label)
	_count_spin = SpinBox.new()
	_count_spin.min_value = 1
	_count_spin.max_value = 1000
	_count_spin.step = 1
	_count_spin.value = _count
	_count_spin.custom_minimum_size = Vector2(90, 0)
	row.add_child(_count_spin)
	var minus := Button.new()
	minus.text = "-100"
	minus.pressed.connect(func() -> void:
		_count_spin.value = maxf(1, _count_spin.value - 100))
	row.add_child(minus)
	var plus := Button.new()
	plus.text = "+100"
	plus.pressed.connect(func() -> void:
		_count_spin.value = minf(1000, _count_spin.value + 100))
	row.add_child(plus)
	var apply := Button.new()
	apply.text = "应用"
	apply.pressed.connect(func() -> void:
		_set_fodder_count(int(_count_spin.value)))
	row.add_child(apply)


func _set_fodder_count(value: int) -> void:
	var target := clampi(value, 1, 1000)
	if not _fodder or _restarting or target == _count:
		return
	_restarting = true
	_count = target
	await _clear_fodder()
	_fodder_field = FodderFieldScript.new()
	_fodder_field.top_level = true
	_fodder_field.species_id = _body_id
	_scene.add_child(_fodder_field)
	_fodder_field.setup(_player, null, _count, _player.global_position, _make_fodder_profile(), _nav_data())
	_fodder_field.set_spread_mode(_fodder_spread_mode)
	_started_msec = Time.get_ticks_msec()
	_restarting = false
	print("[pathlab] fodder_count=%d" % _count)
	_update_hint()


func _add_hint() -> void:
	var layer := CanvasLayer.new()
	layer.name = "PlaygroundHint"
	_hint_label = Label.new()
	_hint_label.add_theme_font_size_override("font_size", 12)
	_hint_label.position = Vector2(24, 24)
	_hint_label.modulate = Color(0.95, 0.92, 0.82, 0.9)
	layer.add_child(_hint_label)
	root.add_child(layer)
	_update_hint()


## 程序内换敌人：查 FodderSpecies 登记表，换 nav/profile/通行表并重建数据场。
## 没有预烘焙数据的种类：用默认地图配置 + 运行时生成的 profile，让 FodderField 现烘通行表。
func _prepare_species(id: String) -> bool:
	_body_id = id
	var nav_file := Species.nav_path(id)
	_runtime_profile = null
	if nav_file.is_empty():
		var base := NavData.load_file(NAV_PATH)
		if base.is_empty():
			return false
		var nav := base.duplicate(true)
		nav["walkability"] = "res://data/navigation/__runtime_%s.json" % id
		_nav = nav
		_runtime_profile = Species.runtime_profile(id)
		if _runtime_profile == null:
			return false
		print("[fodder] species=%s 无预烘焙表，运行时烘焙" % id)
		return true
	_nav = {}
	_nav_path = nav_file
	return true


func _cycle_species(step: int) -> void:
	if not _fodder or _restarting:
		return
	var next_id := Species.next_id(_body_id, step)
	if not _prepare_species(next_id):
		return
	_restarting = true
	await _clear_fodder()
	await _clear_enemies()
	_fodder_field = FodderFieldScript.new()
	_fodder_field.top_level = true
	_fodder_field.species_id = _body_id
	_scene.add_child(_fodder_field)
	_fodder_field.setup(_player, null, _count, _player.global_position,
		_make_fodder_profile(), _nav_data())
	_fodder_field.set_spread_mode(_fodder_spread_mode)
	if _elites > 0:
		await _spawn_elites(_elites)
	_started_msec = Time.get_ticks_msec()
	_restarting = false
	print("[fodder] species=%s nav=%s elites=%d" % [_body_id, _nav_path, _elites])
	_update_hint()


func _update_hint() -> void:
	if _hint_label == null:
		return
	var spread_names := ["关", "摊开", "站位", "压上"]
	_hint_label.text = ("%d 只%s · 无敌:%s · 步≤%d · R 重开 · F10 退出\n"
		+ "F1 AI:%s  F2 冻结:%s  F3 影:%s  F4 天气:%s  F5 后:%s\n"
		+ "F6 流场:%s  F7 截图  F8 让行:%s  F9 铺开:%s  F11 精英直线:%s\n"
		+ "PgUp/PgDn 换敌人"
		+ ("\n" + _map_status if _map_click else "")) % [
		_count,
		Species.label(_body_id) if _fodder else "泥偶",
		"开" if _invincible else "关",
		_max_physics_steps,
		"开" if _ai_on else "关",
		"是" if _frozen else "否",
		"开" if _shadows_on else "关",
		"开" if _weather_on else "关",
		"开" if _post_on else "关",
		"开" if _fodder_field != null and _fodder_field._flow_debug else "关",
		"开" if _fodder_field != null and _fodder_field.queue_pacing else "关",
		spread_names[clampi(_fodder_spread_mode, 0, 3)],
		"开" if Golem.elite_direct_enabled else "关"]
