extends SceneTree
## 正式战斗链的可重复敌群性能计量。
##
## 经 run_probe.py 在隔离副本中启动正式圣所、正式玩家、正式敌人图鉴与
## EnemyDeployment。关闭自动波次后固定投放指定数量，保留敌人模型、动画、
## CharacterBody3D、导航、攻击与特效，只让玩家保持静止且不会死亡。
##
## 典型用法：
##   --count=18  --warmup=300 --frames=900 --seed=64768
##   --count=100 --warmup=300 --frames=900 --seed=64768

const MainScene := preload("res://scenes/hyrule_field.tscn")
const Config := preload("res://scripts/game_config.gd")
const Arena := preload("res://scripts/arena.gd")
const Terrain := preload("res://scripts/terrain_field.gd")
const DeploymentScript := preload("res://scripts/enemy_deployment.gd")
const SpatialController := preload("res://scripts/combat_spatial_controller.gd")
const Artifacts := preload("res://scripts/artifact_paths.gd")
const NativeSteering := preload("res://tools/probes/horde_native_steering.gd")

const LEVEL := 4
const DEFAULT_COUNT := 100
const DEFAULT_WARMUP := 300
const DEFAULT_FRAMES := 900
const DEFAULT_SEED := 64768
const SPAWN_ATTEMPTS_PER_ENEMY := 120
const STILL_THRESHOLD_M := 0.002

class BareMovementAudit extends Node:
	var bodies: Array[Node3D] = []
	var target: Node3D
	var enabled := false
	var measured_usec := 0
	var move_usec := 0
	var ticks := 0

	func _physics_process(delta: float) -> void:
		var begin := Time.get_ticks_usec()
		for value in bodies:
			var body := value as CharacterBody3D
			if not is_instance_valid(body) or not is_instance_valid(target):
				continue
			var offset := target.global_position - body.global_position
			offset.y = 0.0
			var requested := Vector3.ZERO
			if offset.length() > 2.0:
				requested = body.get("_steering").ground_velocity(target.global_position, offset.normalized() * 4.0, delta)
			body.velocity.x = move_toward(body.velocity.x, requested.x, 25.0 * delta)
			body.velocity.z = move_toward(body.velocity.z, requested.z, 25.0 * delta)
			body.velocity.y = -0.5 if body.is_on_floor() else body.velocity.y - 20.0 * delta
			body.floor_snap_length = 0.3
			var move_begin := Time.get_ticks_usec()
			body.move_and_slide()
			if enabled:
				move_usec += Time.get_ticks_usec() - move_begin
		if enabled:
			measured_usec += Time.get_ticks_usec() - begin
			ticks += 1

var _count := DEFAULT_COUNT
var _warmup := DEFAULT_WARMUP
var _frames := DEFAULT_FRAMES
var _seed := DEFAULT_SEED
var _scene: Node
var _player: Node3D
var _camera: Camera3D
var _spawner: Node
var _arena: Dictionary = {}
var _anchors: Array = []
var _entries_by_kind := {"melee": [], "ranged": []}
var _spawned: Array[Node3D] = []
var _kinds: Array[String] = []
var _exit_records: Array[Dictionary] = []
var _phase := "setup"
var _phase_frame := 0
var _native_paths := false
var _no_attacks := false
var _no_animation := false
var _no_visuals := false
var _bare_movement := false
var _movement_audit: BareMovementAudit


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	_parse_arguments()
	if _count <= 0 or _warmup < 0 or _frames <= 0:
		push_error("海量敌人性能计量：参数无效 count=%d warmup=%d frames=%d" % [
			_count, _warmup, _frames,
		])
		quit(1)
		return
	if not await _start_formal_scene():
		quit(1)
		return
	if not await _spawn_population():
		quit(1)
		return

	print("[海量性能] 战斗链就绪：敌人=%d，预热=%d帧，采样=%d帧" % [
		_spawned.size(), _warmup, _frames,
	])
	_phase = "warmup"
	for frame in _warmup:
		_phase_frame = frame
		await process_frame

	var frame_ms: Array[float] = []
	var process_ms: Array[float] = []
	var physics_ms: Array[float] = []
	var draw_calls: Array[float] = []
	var primitives: Array[float] = []
	var visible_counts: Array[float] = []
	var enemy_counts: Array[float] = []
	var queue_lengths: Array[float] = []
	var previous_positions: Array[Vector3] = []
	var travelled: Array[float] = []
	var still_frames: Array[int] = []
	var longest_still: Array[int] = []
	var current_still: Array[int] = []
	for enemy in _spawned:
		previous_positions.append(enemy.global_position)
		travelled.append(0.0)
		still_frames.append(0)
		longest_still.append(0)
		current_still.append(0)

	var jobs_started_at_begin := SpatialController.jobs_started
	var full_ticks_at_begin := SpatialController.full_ticks
	var throttled_ticks_at_begin := SpatialController.throttled_ticks
	var deferrals_at_begin := SpatialController.plan_deferrals
	var native_queries_at_begin := NativeSteering.native_queries
	var native_usec_at_begin := NativeSteering.native_query_usec
	var previous_usec := Time.get_ticks_usec()
	_phase = "measurement"
	if _movement_audit != null:
		_movement_audit.enabled = true
	for frame in _frames:
		_phase_frame = frame
		await process_frame
		var now_usec := Time.get_ticks_usec()
		frame_ms.append(float(now_usec - previous_usec) / 1000.0)
		previous_usec = now_usec
		process_ms.append(Performance.get_monitor(Performance.TIME_PROCESS) * 1000.0)
		physics_ms.append(Performance.get_monitor(Performance.TIME_PHYSICS_PROCESS) * 1000.0)
		draw_calls.append(Performance.get_monitor(Performance.RENDER_TOTAL_DRAW_CALLS_IN_FRAME))
		primitives.append(Performance.get_monitor(Performance.RENDER_TOTAL_PRIMITIVES_IN_FRAME))
		enemy_counts.append(float(_living_spawn_count()))
		queue_lengths.append(float(SpatialController._jobs.size()))
		# 视锥计数每 10 帧采一次，避免诊断本身变成显著开销。
		if frame % 10 == 0:
			visible_counts.append(float(_visible_enemy_count()))
		for index in _spawned.size():
			var enemy := _spawned[index]
			if not is_instance_valid(enemy):
				continue
			var here := enemy.global_position
			var moved := Vector2(
				here.x - previous_positions[index].x,
				here.z - previous_positions[index].z
			).length()
			previous_positions[index] = here
			travelled[index] += moved
			if moved < STILL_THRESHOLD_M:
				still_frames[index] += 1
				current_still[index] += 1
				longest_still[index] = maxi(longest_still[index], current_still[index])
			else:
				current_still[index] = 0

	await RenderingServer.frame_post_draw
	var screenshot_path := Artifacts.ensure_dir("screenshots").path_join(
		"horde_performance_%03d.png" % _count
	)
	var image := root.get_texture().get_image()
	if image == null or image.is_empty() or image.save_png(screenshot_path) != OK:
		push_error("海量敌人性能计量：截图保存失败 %s" % screenshot_path)
		quit(1)
		return

	var final_distances: Array[float] = []
	var actor_rows: Array[Dictionary] = []
	var long_still_far_melee := 0
	for index in _spawned.size():
		var enemy := _spawned[index]
		if not is_instance_valid(enemy):
			continue
		var distance := Vector2(
			enemy.global_position.x - _player.global_position.x,
			enemy.global_position.z - _player.global_position.z
		).length()
		final_distances.append(distance)
		var suspicious := _kinds[index] == "melee" and distance > 10.0 \
			and longest_still[index] >= 120
		if suspicious:
			long_still_far_melee += 1
		actor_rows.append({
			"index": index,
			"kind": _kinds[index],
			"travelled_m": travelled[index],
			"still_ratio": float(still_frames[index]) / float(_frames),
			"longest_still_frames": longest_still[index],
			"final_distance_to_player_m": distance,
			"long_still_far_melee": suspicious,
		})

	var frame_stats := _stats(frame_ms)
	var population_stable := _living_spawn_count() == _count \
		and int(_stats(enemy_counts).min) == _count
	var report := {
		"purpose": "正式单人战斗链的固定敌群性能计量；不修改正式刷怪上限",
		"conditions": {
			"requested_count": _count,
			"steering": "native_cached_paths" if _native_paths else "formal_spatial_controller",
			"diagnostic_ablations": {
				"attacks_disabled": _no_attacks,
				"animation_disabled": _no_animation,
				"enemy_visuals_hidden": _no_visuals,
				"bare_movement_only": _bare_movement,
			},
			"spawned_count": _spawned.size(),
			"weapon_level": LEVEL,
			"seed": _seed,
			"warmup_frames": _warmup,
			"measured_frames": _frames,
			"player_motion": "stationary",
			"player_survival": "experiment_invincible meta",
			"enemy_survival": "experiment_invincible meta; falling and other removals remain observable",
			"enemy_systems": ["formal models", "animation", "CharacterBody3D", "navigation", "attacks", "effects"],
			"automatic_spawning": false,
			"weather": "fixed clear",
			"time_of_day": "12:00 fixed",
			"graphics_tier": Config.get_string("graphics.active", "high"),
			"arena": String(_arena.get("_id", Arena.resolve_id())),
			"viewport": root.get_visible_rect().size,
			"window_pixels": DisplayServer.window_get_size(),
			"viewport_texture_size_api": Vector2i(root.get_texture().get_width(), root.get_texture().get_height()),
			"captured_image_pixels": image.get_size(),
			"render_scale_3d": root.scaling_3d_scale,
			"measurement_mode": "wall-clock render-frame intervals under run_probe fixed simulation",
		},
		"hardware": {
			"engine": Engine.get_version_info(),
			"renderer": RenderingServer.get_video_adapter_name(),
			"processor": OS.get_processor_name(),
		},
		"frame_ms": frame_stats,
		"fps": {
			"mean_from_frame_time": 1000.0 / maxf(float(frame_stats.mean), 0.001),
			"one_percent_low": 1000.0 / maxf(float(frame_stats.p99), 0.001),
			"five_percent_low": 1000.0 / maxf(float(frame_stats.p95), 0.001),
		},
		"budget": {
			"over_16_67_ms_frames": _count_over(frame_ms, 16.67),
			"over_33_33_ms_frames": _count_over(frame_ms, 33.33),
			"over_50_ms_frames": _count_over(frame_ms, 50.0),
		},
		"engine_monitors": {
			"process_ms": _stats(process_ms),
			"physics_ms": _stats(physics_ms),
			"draw_calls": _stats(draw_calls),
			"primitives": _stats(primitives),
			"node_count_end": int(Performance.get_monitor(Performance.OBJECT_NODE_COUNT)),
			"object_count_end": int(Performance.get_monitor(Performance.OBJECT_COUNT)),
		},
		"population": {
			"stable": population_stable,
			"alive_count": _stats(enemy_counts),
			"visible_in_frustum": _stats(visible_counts),
			"final_distance_to_player_m": _stats(final_distances),
			"long_still_far_melee_count": long_still_far_melee,
		},
		"unexpected_exits": _exit_records,
		"bare_movement": {
			"measured_physics_ticks": _movement_audit.ticks if _movement_audit != null else 0,
			"total_loop_ms": float(_movement_audit.measured_usec) / 1000.0 if _movement_audit != null else 0.0,
			"move_and_slide_ms": float(_movement_audit.move_usec) / 1000.0 if _movement_audit != null else 0.0,
		},
		"navigation": {
			"native_queries": NativeSteering.native_queries - native_queries_at_begin,
			"native_query_total_ms": float(NativeSteering.native_query_usec - native_usec_at_begin) / 1000.0,
			"jobs_started": SpatialController.jobs_started - jobs_started_at_begin,
			"full_ticks": SpatialController.full_ticks - full_ticks_at_begin,
			"throttled_ticks": SpatialController.throttled_ticks - throttled_ticks_at_begin,
			"plan_deferrals": SpatialController.plan_deferrals - deferrals_at_begin,
			"queue_length": _stats(queue_lengths),
		},
		"actors": actor_rows,
		"screenshot": screenshot_path,
	}
	var report_path := Artifacts.ensure_dir("reports").path_join(
		"horde_performance_%03d.json" % _count
	)
	var file := FileAccess.open(report_path, FileAccess.WRITE)
	if file == null:
		push_error("海量敌人性能计量：无法写报告 %s" % report_path)
		quit(1)
		return
	file.store_string(JSON.stringify(report, "\t"))
	file.close()
	print("[海量性能] count=%d mean=%.2fms p95=%.2fms p99=%.2fms fps=%.1f 1%%low=%.1f visible_mean=%.1f queue_p95=%.0f" % [
		_count,
		float(frame_stats.mean),
		float(frame_stats.p95),
		float(frame_stats.p99),
		float(report.fps.mean_from_frame_time),
		float(report.fps.one_percent_low),
		float(report.population.visible_in_frustum.mean),
		float(report.navigation.queue_length.p95),
	])
	print("[海量性能] 报告=", report_path)
	if not population_stable:
		push_error("海量敌人性能计量：固定人口失稳，%d 只测试结束时仅存活 %d 只" % [
			_count, _living_spawn_count(),
		])
		quit(2)
	else:
		quit(0)


func _parse_arguments() -> void:
	for argument in OS.get_cmdline_user_args():
		if argument.begins_with("--count="):
			_count = int(argument.get_slice("=", 1))
		elif argument.begins_with("--warmup="):
			_warmup = int(argument.get_slice("=", 1))
		elif argument.begins_with("--frames="):
			_frames = int(argument.get_slice("=", 1))
		elif argument.begins_with("--seed="):
			_seed = int(argument.get_slice("=", 1))
		elif argument == "--native-paths":
			_native_paths = true
		elif argument == "--no-attacks":
			_no_attacks = true
		elif argument == "--no-animation":
			_no_animation = true
		elif argument == "--no-visuals":
			_no_visuals = true
		elif argument == "--bare-movement":
			_bare_movement = true


func _start_formal_scene() -> bool:
	var initial := MainScene.instantiate()
	root.add_child(initial)
	current_scene = initial
	for _frame in 3:
		await process_frame
	var flow := root.get_node_or_null("GameFlow")
	if flow == null:
		push_error("海量敌人性能计量：找不到 GameFlow")
		return false
	var old_scene := current_scene
	flow.call("start_run")
	for _frame in 360:
		await process_frame
		if current_scene != null and current_scene != old_scene \
				and not get_nodes_in_group("player").is_empty():
			break
	if current_scene == null or get_nodes_in_group("player").is_empty():
		push_error("海量敌人性能计量：正式场景或玩家未就绪")
		return false
	_scene = current_scene
	_player = get_nodes_in_group("player")[0] as Node3D
	_camera = _player.get_node_or_null("CameraPivot/SpringArm3D/Camera3D") as Camera3D
	_spawner = _scene.find_child("EnemySpawner", true, false)
	if _camera == null or _spawner == null:
		push_error("海量敌人性能计量：找不到正式相机或 EnemySpawner")
		return false

	# 固定人口：正式刷怪器全部停止，但敌人自身的战斗逻辑保持运行。
	for director_name in ["WaveDirector", "SurvivalDirector"]:
		var director := _scene.find_child(director_name, true, false)
		if director != null:
			director.set_process(false)
	for spawn_point in _scene.find_children("*", "EnemySpawnPoint", true, false):
		spawn_point.set_process(false)
		spawn_point.set_physics_process(false)
	var timeline := _scene.find_child("WeatherTimeline", true, false)
	if timeline != null:
		timeline.set_process(false)
		timeline.set_process_input(false)
	var time_of_day := _scene.find_child("TimeOfDay", true, false)
	if time_of_day != null:
		time_of_day.call("set_time", 12, 0, 0)
		time_of_day.call("pause")
	var weather := _scene.find_child("WeatherSystem", true, false)
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
	await _clear_existing_enemies()

	_arena = Arena.get_params()
	for pair in Arena.generate_spawn_anchors(_arena):
		var x := float(pair[0])
		var z := float(pair[1])
		_anchors.append(Vector3(x, Terrain.height_at(x, z), z))
	var roster := Config.get_dictionary("enemy_roster")
	var raw_entries: Variant = roster.get("entries", [])
	if raw_entries is not Array:
		push_error("海量敌人性能计量：敌人图鉴格式无效")
		return false
	for value in raw_entries as Array:
		var entry := value as Dictionary
		if int(entry.get("min_weapon_level", 1)) > LEVEL:
			continue
		var kind := String(entry.get("kind", "melee"))
		if _entries_by_kind.has(kind):
			(_entries_by_kind[kind] as Array).append(entry)
	if (_entries_by_kind.melee as Array).is_empty() or (_entries_by_kind.ranged as Array).is_empty():
		push_error("海量敌人性能计量：等级 %d 的近战或远程图鉴为空" % LEVEL)
		return false
	_player.set_meta(&"experiment_invincible", true)
	return true


func _spawn_population() -> bool:
	var rng := RandomNumberGenerator.new()
	rng.seed = _seed
	var deployment := DeploymentScript.new()
	deployment.configure(_scene, _arena, rng)
	deployment.begin_wave(_count)
	var mix: Dictionary = _arena.get("enemy_mix", {})
	var ranged_ratio := clampf(float(mix.get(
		"ranged_ratio", Config.get_float("spawn.ranged_ratio", 0.42)
	)), 0.0, 1.0)
	for index in _count:
		# 乘法置换把远程均匀散进序列，最终比例仍由本竞技场配置决定。
		var phase := float((index * 37) % _count) / float(_count)
		var kind := "ranged" if phase < ranged_ratio else "melee"
		var pool := _entries_by_kind[kind] as Array
		var entry := pool[(index * 5 + index / 7) % pool.size()] as Dictionary
		var location: Dictionary = {}
		for attempt in SPAWN_ATTEMPTS_PER_ENEMY:
			location = deployment.pick_position(entry, _anchors)
			if not location.is_empty():
				break
			if attempt % 12 == 11:
				await physics_frame
		if location.is_empty():
			push_error("海量敌人性能计量：第 %d/%d 只敌人在 %d 次尝试后仍无合法出生点" % [
				index + 1, _count, SPAWN_ATTEMPTS_PER_ENEMY,
			])
			return false
		var enemy := _spawner.call("spawn_enemy", entry, location.position, float(LEVEL)) as Node3D
		if enemy == null:
			push_error("海量敌人性能计量：第 %d/%d 只构造失败" % [index + 1, _count])
			return false
		enemy.add_to_group("dynamic_enemies")
		enemy.process_mode = Node.PROCESS_MODE_DISABLED
		enemy.set_meta(&"experiment_invincible", true)
		enemy.tree_exiting.connect(
			_on_enemy_exiting.bind(enemy, index, kind), CONNECT_ONE_SHOT
		)
		_spawned.append(enemy)
		_kinds.append(kind)
		deployment.commit_spawn()
		# 等一个物理帧，让下一次正式占位校验能看到这只身体。
		await physics_frame
	for _frame in 4:
		await process_frame
	for enemy in _spawned:
		if is_instance_valid(enemy):
			if _native_paths:
				_replace_steering_for_audit(enemy)
			if _no_attacks:
				var property := "fire_cooldown" if String(_kinds[_spawned.find(enemy)]) == "ranged" else "attack_cooldown"
				enemy.set(property, 100000.0)
			if _no_animation:
				var rig: Node = enemy.get("_rig")
				rig.set("_model", null)
			if _no_visuals:
				enemy.visible = false
			enemy.process_mode = Node.PROCESS_MODE_INHERIT
	if _bare_movement:
		_movement_audit = BareMovementAudit.new()
		_movement_audit.bodies = _spawned
		_movement_audit.target = _player
		_scene.add_child(_movement_audit)
		for enemy in _spawned:
			enemy.set_physics_process(false)
	return _spawned.size() == _count


func _replace_steering_for_audit(enemy: Node3D) -> void:
	var previous: RefCounted = enemy.get("_steering")
	if previous.spatial != null:
		var controller: RefCounted = previous.spatial
		if enemy.tree_exiting.is_connected(controller.dispose):
			enemy.tree_exiting.disconnect(controller.dispose)
		controller.dispose()
		previous.spatial = null
	if is_instance_valid(previous._nav_origin):
		previous._nav_origin.queue_free()
	var replacement := NativeSteering.new()
	replacement.setup(enemy, 0.6, 1.8)
	enemy.set("_steering", replacement)


func _clear_existing_enemies() -> void:
	for enemy in get_nodes_in_group("enemies"):
		if is_instance_valid(enemy):
			enemy.queue_free()
	for _frame in 3:
		await process_frame


func _on_enemy_exiting(enemy: Node3D, index: int, kind: String) -> void:
	if _phase == "setup" or not is_instance_valid(enemy):
		return
	var position := enemy.global_position
	var ground_y := Terrain.height_at(position.x, position.z)
	_exit_records.append({
		"index": index,
		"kind": kind,
		"phase": _phase,
		"phase_frame": _phase_frame,
		"position": position,
		"ground_y": ground_y,
		"below_expected_ground_m": ground_y - position.y,
		"health": float(enemy.get("health")),
		"queued_for_deletion": enemy.is_queued_for_deletion(),
	})


func _living_spawn_count() -> int:
	var total := 0
	for enemy in _spawned:
		if is_instance_valid(enemy) and not enemy.is_queued_for_deletion():
			total += 1
	return total


func _visible_enemy_count() -> int:
	var total := 0
	for enemy in _spawned:
		if is_instance_valid(enemy) \
				and _camera.is_position_in_frustum(enemy.global_position + Vector3.UP):
			total += 1
	return total


func _stats(values: Array) -> Dictionary:
	if values.is_empty():
		return {"count": 0, "mean": 0.0, "min": 0.0, "p50": 0.0, "p95": 0.0, "p99": 0.0, "max": 0.0}
	var sorted := values.duplicate()
	sorted.sort()
	var total := 0.0
	for value in values:
		total += float(value)
	return {
		"count": values.size(),
		"mean": total / float(values.size()),
		"min": float(sorted[0]),
		"p50": _percentile(sorted, 0.50),
		"p95": _percentile(sorted, 0.95),
		"p99": _percentile(sorted, 0.99),
		"max": float(sorted[-1]),
	}


func _percentile(sorted: Array, fraction: float) -> float:
	var index := clampi(ceili(float(sorted.size()) * fraction) - 1, 0, sorted.size() - 1)
	return float(sorted[index])


func _count_over(values: Array[float], threshold: float) -> int:
	var total := 0
	for value in values:
		if value > threshold:
			total += 1
	return total
