extends "res://tools/probes/burst_crawler_perf.gd"
## 正式波次实时刷出诊断；必须通过run_probe --realtime（或等价run_check）启动。
const Scope := preload("res://tools/probes/cpu_scope.gd")
var _seconds := 30.0
var _seen: Dictionary = {}
var _move_player := false
var _pipeline_monitors: Dictionary = {}
var _render_timing := false
var _warm_resources := false
var _warm_ms := 0.0
var _retain_fx := false
var _retained: Dictionary = {}
var _created: Array = []
var _capture := false
var _warm_dust_only := false
var _queue_variant := "default"
var _seed_serial := 0
var _max_ground_seen := 0
var _max_ground_details: Dictionary = {}
var _max_untracked_ground := 0
var _peak_actual_ground_groups := 0
var _skip_combat_preparation := false

func _uses_formal_population() -> bool:
	return true

func _run() -> void:
	seed(314159)
	node_added.connect(_seed_population)
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--seconds="):
			_seconds = clampf(float(arg.trim_prefix("--seconds=")), 5.0, 90.0)
		elif arg == "--move-player":
			_move_player = true
		elif arg == "--warm-resources":
			_warm_resources = true
		elif arg == "--retain-fx-resources":
			_retain_fx = true
		elif arg == "--capture":
			_capture = true
		elif arg == "--warm-dust-only":
			_warm_resources = true
			_warm_dust_only = true
		elif arg.begins_with("--queue-variant="):
			_queue_variant = arg.trim_prefix("--queue-variant=")
		elif arg == "--skip-combat-preparation":
			_skip_combat_preparation = true
	preload("res://scripts/combat_resource_preparation.gd").enabled = not _skip_combat_preparation
	# 同一正式入口比较编排候选；所有修改只在当前进程，不写配置文件。
	var queue_policy := preload("res://scripts/enemy_attack_queue_policy.gd")
	var queue_config: Dictionary = queue_policy.current().duplicate(true)
	match _queue_variant:
		"off": queue_config.enabled = false
		"conservative": queue_config.global.merge({"max_active": 2, "max_ground": 1, "starts_per_frame": 1, "start_gap": 0.5}, true)
		"open": queue_config.global.merge({"max_active": 4, "max_ground": 3, "starts_per_frame": 1, "start_gap": 0.2}, true)
	if not queue_policy.apply(queue_config):
		push_error(queue_policy.last_error)
		quit(1)
		return
	# 将诊断要求的手绘风格放在开局准备前，避免测量开始才首次切换滤镜。
	# 流程中的镜头清理会恢复DisplaySettings，需设置当前进程的正式风格。
	# 不保存个人配置；准备和测量均保持同一种渲染路径。
	root.get_node("DisplaySettings").post_process_style = SKETCH
	_set_filter(true)
	_render_timing = RenderingServer.has_method("viewport_set_measure_render_time")
	if _render_timing:
		RenderingServer.call("viewport_set_measure_render_time", root.get_viewport_rid(), true)
	var startup_started := Time.get_ticks_usec()
	if not await _start_formal_scene():
		quit(1)
		return
	var startup_ms := (Time.get_ticks_usec() - startup_started) / 1000.0
	var prepared_style: int = root.get_node("PostProcess").style
	if prepared_style != SKETCH:
		push_error("正式准备与测量风格不一致，拒绝使用该轮性能结果")
		quit(1)
		return
	_set_filter(true)
	var director := _scene.find_child("WaveDirector", true, false)
	if director == null:
		push_error("实时刷怪探针缺少正式WaveDirector")
		quit(1)
		return
	var random: RandomNumberGenerator = director.get("_random")
	# configure在_ready已取过初始投放角，仅重设RNG不会重置它。
	# 同时重置投放器初相位，确保准备开／关不会随机落在不同地形上。
	random.seed = 314159
	var deployment: RefCounted = director.get("_deployment")
	deployment.call("configure", director, director.get("_arena"), random, director.get("_spawn_cfg"))
	seed(271828)
	if _warm_resources:
		await _warm_render_resources()
	for label in ClassDB.class_get_integer_constant_list("Performance"):
		if "PIPELINE" in label:
			_pipeline_monitors[label] = ClassDB.class_get_integer_constant("Performance", label)
	_player.set_meta(&"experiment_invincible", true)
	var initial_pipelines := {}
	for label in _pipeline_monitors:
		initial_pipelines[label] = Performance.get_monitor(_pipeline_monitors[label])
	var samples: Array = []
	var start := Time.get_ticks_usec()
	var previous := start
	var physics := Engine.get_physics_frames()
	var last_delta := 1.0 / 60.0
	var previous_cpu: Dictionary = {}
	Scope.rows.clear()
	Scope.enabled = true
	node_added.connect(_observe_added)
	while Time.get_ticks_usec() - start < _seconds * 1000000.0:
		# 按墙钟给相同速度的正常移动／转头输入，不随FPS改变动作速度。
		if _move_player:
			Input.action_press("move_right", 0.65)
		_player.set("target_yaw", wrapf(float(_player.get("target_yaw")) + minf(last_delta, 0.1) * 0.5, -PI, PI))
		await process_frame
		var now := Time.get_ticks_usec()
		var next_physics := Engine.get_physics_frames()
		var born: Array = []
		var enemies := get_nodes_in_group("enemies")
		for enemy in enemies:
			var id: int = enemy.get_instance_id()
			if not _seen.has(id):
				_seen[id] = true
				var entry: Dictionary = enemy.get_meta("enemy_entry", {})
				born.append({"id": str(id), "species": entry.get("species", ""), "at": enemy.global_position})
		var timings: Dictionary = {}
		for label in ["wave_director._spawn_one", "combat_spatial_controller.process_jobs", "attack_surface_mesh.build"]:
			var cumulative := int(Scope.rows.get(label, {}).get("total_usec", 0))
			timings[label] = cumulative - int(previous_cpu.get(label, 0))
			previous_cpu[label] = cumulative
		var pipelines: Dictionary = {}
		for label in _pipeline_monitors:
			pipelines[label] = Performance.get_monitor(_pipeline_monitors[label])
		var sample := {"seconds": float(now - start) / 1000000.0, "ms": float(now - previous) / 1000.0,
			"physics_monitor_ms": Performance.get_monitor(Performance.TIME_PHYSICS_PROCESS) * 1000.0,
			"process_monitor_ms": Performance.get_monitor(Performance.TIME_PROCESS) * 1000.0,
			"physics_steps": next_physics - physics, "enemies": enemies.size(), "born": born,
			"cpu_usec": timings, "pipelines": pipelines, "created": _created}
		var ground_nodes: Array[Node] = []
		ground_nodes.assign(get_nodes_in_group("enemy_hazards"))
		for area in get_nodes_in_group("enemy_attack_debug_areas"):
			if area.is_visible_in_tree() and bool(area.shape.get("ground_effect", true)) and area.phase in [AttackArea.Phase.PREPARE, AttackArea.Phase.LOCKED]: ground_nodes.append(area)
		for projectile in get_nodes_in_group("enemy_projectiles"):
			var warning: Node3D = projectile.get("_warning")
			if is_instance_valid(warning) and not warning.is_queued_for_deletion(): ground_nodes.append(projectile)
		sample["visible_ground"] = ground_nodes.size()
		var actual_groups: Dictionary = {}
		var untracked := 0
		var current_queue := _scene.get_node_or_null("EnemyAttackQueue")
		for node in ground_nodes:
			var owner: Node = node.get_parent() if node.get_script() == AttackArea else node
			var ticket := int(owner.get_meta(&"attack_queue_id", 0))
			if ticket == 0: ticket = int(node.get_meta(&"attack_queue_effect", {}).get("id", 0))
			if ticket > 0 and current_queue != null and current_queue.active.has(ticket): actual_groups[ticket] = true
			else: untracked += 1
		sample["untracked_ground"] = untracked
		_max_untracked_ground = maxi(_max_untracked_ground, untracked)
		_peak_actual_ground_groups = maxi(_peak_actual_ground_groups, actual_groups.size())
		if ground_nodes.size() > _max_ground_seen:
			_max_ground_seen = ground_nodes.size()
			var detail: Array = []
			for node in ground_nodes:
				var owner: Node = node.get_parent() if node.get_script() == AttackArea else node
				detail.append({"path": String(node.get_path()), "owner": String(owner.get_path()),
					"actor_ticket": owner.get_meta(&"attack_queue_id", 0),
					"effect_ticket": node.get_meta(&"attack_queue_effect", {}).get("id", 0)})
			_max_ground_details = {"seconds": sample.seconds, "nodes": detail}
		_created = []
		if _render_timing:
			sample["render_cpu_ms"] = RenderingServer.call("viewport_get_measured_render_time_cpu", root.get_viewport_rid())
			sample["render_gpu_ms"] = RenderingServer.call("viewport_get_measured_render_time_gpu", root.get_viewport_rid())
		samples.append(sample)
		last_delta = float(now - previous) / 1000000.0
		previous = now
		physics = next_physics
	Scope.enabled = false
	node_added.disconnect(_observe_added)
	Input.action_release("move_right")
	var sorted: Array = samples.map(func(row): return float(row.ms))
	sorted.sort()
	var total := 0.0
	var catchup := 0
	for row in samples:
		total += float(row.ms)
		if int(row.physics_steps) > 1:
			catchup += 1
	var result := {"fixed_fps": OS.get_environment("RUIN_STAR_RUN_FIXED_FPS"),
		"queue_variant": _queue_variant, "queue_config": queue_config,
		"max_ground_details": _max_ground_details,
		"max_untracked_ground": _max_untracked_ground, "peak_actual_ground_groups": _peak_actual_ground_groups,
		"startup_ms": startup_ms, "prepared_style": prepared_style, "initial_pipelines": initial_pipelines,
		"formal_dust_warmed": preload("res://scripts/ground_dust.gd")._render_warmed,
		"combat_preparation_ms": preload("res://scripts/combat_resource_preparation.gd").last_ms,
		"combat_preparation_runs": preload("res://scripts/combat_resource_preparation.gd").runs,
		"combat_preparation_resources": preload("res://scripts/combat_resource_preparation.gd").last_resource_count,
		"combat_preparation_static_bytes": preload("res://scripts/combat_resource_preparation.gd").last_static_bytes,
		"warm_resources": _warm_resources, "warm_ms": _warm_ms,
		"retain_fx_resources": _retain_fx, "retained_resources": _retained.size(),
		"window": DisplayServer.window_get_size(), "render_scale": root.scaling_3d_scale,
		"frames": samples.size(), "fps": float(samples.size()) * 1000.0 / total,
		"p95_ms": sorted[mini(ceili(sorted.size() * 0.95) - 1, sorted.size() - 1)],
		"max_ms": sorted.back(), "catchup_frames": catchup, "spawned": _seen.size(),
		"samples": samples, "cpu": Scope.rows}
	var attack_queue := _scene.get_node_or_null("EnemyAttackQueue")
	result["attack_queue"] = attack_queue.snapshot() if attack_queue != null else {}
	var path := Artifacts.ensure_dir("reports").path_join("formal_spawn_perf.json")
	var file := FileAccess.open(path, FileAccess.WRITE)
	if file == null:
		push_error("无法写实时刷怪报告：" + path)
		quit(1)
		return
	file.store_string(JSON.stringify(result, "  "))
	file.close()
	print("[正式实时刷怪] FPS=%.1f p95=%.1fms max=%.1fms catchup=%d/%d spawned=%d fixed=%s" % [
		result.fps, result.p95_ms, result.max_ms, catchup, samples.size(), _seen.size(), result.fixed_fps])
	var labels := Scope.rows.keys()
	labels.sort_custom(func(a, b): return Scope.rows[a].total_usec > Scope.rows[b].total_usec)
	for label in labels.slice(0, 25):
		print("[刷怪CPU] ", label, " ", Scope.rows[label])
	if _capture and DisplayServer.get_name() != "headless":
		await RenderingServer.frame_post_draw
		var error := root.get_texture().get_image().save_png(Artifacts.ensure_dir("screenshots").path_join("formal_spawn.png"))
		if error != OK:
			push_error("保存正式刷怪截图失败：" + error_string(error))
			quit(1)
			return
	quit(0)

func _seed_population(node: Node) -> void:
	if node is CharacterBody3D and bool(node.get_meta(&"formal_enemy", false)):
		node.set_meta(&"crowd_seed", 314159 + _seed_serial)
		_seed_serial += 1

func _observe_added(node: Node) -> void:
	if node is MeshInstance3D or node is CPUParticles3D or node is Label3D or node is Decal:
		call_deferred("_observe_resource", weakref(node))

func _observe_resource(reference: WeakRef) -> void:
	var node: Node = reference.get_ref()
	if not is_instance_valid(node) or not node.is_inside_tree():
		return
	var parent := node.get_parent()
	_created.append({"path": String(node.get_path()), "type": node.get_class(),
		"script": node.get_script().resource_path if node.get_script() != null else "",
		"parent_script": parent.get_script().resource_path if parent != null and parent.get_script() != null else ""})
	if _retain_fx and (node is MeshInstance3D or node is CPUParticles3D):
		for resource: Resource in [node.mesh, node.material_override, node.material_overlay]:
			if resource != null:
				_retained[resource.get_instance_id()] = resource

func _warm_render_resources() -> void:
	# 只用于最小A/B；冻结正式战局，在同一渲染环境实际显示样本再隐藏并保留资源。
	var started := Time.get_ticks_usec()
	paused = true
	var holder := Node3D.new()
	holder.name = "ProbeRenderWarmup"
	holder.process_mode = Node.PROCESS_MODE_DISABLED
	_scene.add_child(holder)
	if _warm_dust_only:
		var dust := preload("res://scripts/ground_dust.gd").new()
		dust.process_mode = Node.PROCESS_MODE_ALWAYS
		holder.add_child(dust)
		dust.global_position = _camera.global_transform * Vector3(0, 0, -3)
		dust.call("_build", Vector3.UP, 0.5)
		for _frame in range(4):
			await process_frame
			if DisplayServer.get_name() != "headless":
				await RenderingServer.frame_post_draw
		holder.queue_free()
		paused = false
		_warm_ms = (Time.get_ticks_usec() - started) / 1000.0
		return
	var index := 0
	var flashes: Array[Node] = []
	for species in Creatures.SPECIES:
		var body := Creatures.instantiate({"species": species})
		holder.add_child(body)
		body.remove_from_group("enemies")
		body.collision_layer = 0
		body.collision_mask = 0
		body.global_position = _camera.global_transform * Vector3((index % 3 - 1) * 3.5, float(index / 3) * 3.0 - 1.5, -12)
		for flash in body.find_children("EnemyHitFlash", "", true, false):
			flashes.append(flash)
		index += 1
	var area := AttackArea.new()
	holder.add_child(area)
	area.prepare(_player.global_transform, {"kind": "circle", "radius": 2.0, "height": 2.5}, 1.0)
	var puddle := preload("res://scripts/enemies/poison_puddle.gd").new()
	holder.add_child(puddle)
	puddle.configure(_player.global_position, preload("res://scripts/prototypes/enemy_tuning.gd").get_values("VisualBurstCrawler"), {})
	puddle.remove_from_group("enemy_hazards")
	for _frame in range(3):
		await process_frame
		if DisplayServer.get_name() != "headless":
			await RenderingServer.frame_post_draw
	for flash in flashes:
		flash.call("play")
	for _frame in range(3):
		await process_frame
		if DisplayServer.get_name() != "headless":
			await RenderingServer.frame_post_draw
	for flash in flashes:
		flash.call("clear")
	holder.hide()
	paused = false
	_warm_ms = (Time.get_ticks_usec() - started) / 1000.0
