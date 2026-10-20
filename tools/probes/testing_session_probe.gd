extends SceneTree
## T00 有限隔离实验，不是测试工作区的正式运行时。
## run_probe 负责隔离工程、鼠标保护和产物；这里比较重建、裸 World3D 与受控预览。
const Artifacts := preload("res://scripts/artifact_paths.gd")
const Flow := preload("res://scripts/game_flow.gd")
const Run := preload("res://scripts/run_state.gd")
const Arena := preload("res://scripts/arena.gd")
const Tuning := preload("res://scripts/prototypes/enemy_tuning.gd")
const Targeting := preload("res://scripts/targeting.gd")
const Limiter := preload("res://scripts/skill_limiter.gd")
const Crowd := preload("res://scripts/prototypes/enemy_crowd.gd")
const Pool := preload("res://scripts/object_pool.gd")
const Titan := preload("res://prototypes/enemy_prototypes/procedural_sediment_titan.tscn")

class Target extends CharacterBody3D:
	var health := 10000.0
	var damage_events := 0
	var physics_ticks := 0
	func _physics_process(delta: float) -> void:
		physics_ticks += 1
		velocity.y -= 9.8 * delta
		velocity.x = 2.0 if Input.is_action_pressed("move_right") else 0.0
		move_and_slide()
	func take_damage(amount: float, _at := Vector3.ZERO, _scale := 1.0) -> void:
		health -= amount
		damage_events += 1

var failures: Array[String] = []
var observations: Array[Dictionary] = []
var source: Node3D
var player: CharacterBody3D
var boss: CharacterBody3D
var director: Node
var source_body: RigidBody3D
var source_timer: Timer
var preview: SubViewport
var preview_root: Node3D
var preview_boss: CharacterBody3D
var preview_target: Target
var preview_body: RigidBody3D
var original_modes: Array[Dictionary] = []
var hidden_groups: Array[Dictionary] = []
var saved_limiter: Dictionary
var saved_crowd: Dictionary
var saved_clock := 1.0
var saved_mouse := Input.MOUSE_MODE_VISIBLE
var source_space: RID

func _initialize() -> void:
	_run.call_deferred()

func check(ok: bool, message: String) -> void:
	if not ok:
		failures.append(message)
		push_error(message)

func frames(count: int) -> void:
	for _i in count:
		await physics_frame

func all_nodes(node: Node) -> Array[Node]:
	var result: Array[Node] = [node]
	for child: Node in node.get_children():
		result.append_array(all_nodes(child))
	return result

func metrics() -> Dictionary:
	return {"static_memory": OS.get_static_memory_usage(), "objects": Performance.get_monitor(Performance.OBJECT_COUNT), "nodes": Performance.get_monitor(Performance.OBJECT_NODE_COUNT)}

func snapshot() -> Dictionary:
	return {
		"world_id": source.get_instance_id(), "player_id": player.get_instance_id(), "boss_id": boss.get_instance_id(),
		"player_pose": player.global_transform, "player_velocity": player.velocity,
		"health": player.health, "shield": player.shield, "kills": player.kill_count,
		"boss_pose": boss.global_transform, "boss_velocity": boss.velocity, "boss_health": boss.health,
		"boss_state": boss.current_state, "boss_clock": boss.anim_clock, "boss_attack_elapsed": boss._attack_elapsed,
		"boss_attack_phase": boss._attack_area.phase, "boss_attack_progress": boss._attack_area.progress,
		"boss_cooldown": boss.attack_cooldown, "boss_brain": boss._brain.cooldowns.duplicate(true),
		"boss_tween": boss._action_tween.get_total_elapsed_time() if boss._action_tween and boss._action_tween.is_valid() else -1.0,
		"tuning": boss._tuning.duplicate(true), "wave": director._wave, "wave_state": director._state,
		"budget": director._spawn_budget, "wave_rng": str(director._random.state),
		"crowd_rng": str(boss._crowd._rng.state), "pending_clear": director._pending_clear.duplicate(true),
		"run": [Run.get_stage(), Run.get_wave(), Run.get_weapon_level(), Run.get_upgrades(), Run.get_perks()],
		"arena": Arena.current_id, "rigid_pose": source_body.global_transform,
		"timer": source_timer.time_left, "flow_state": Flow.instance.state,
	}

func changed(before: Dictionary, after: Dictionary) -> Array[String]:
	var keys: Array[String] = []
	for key: String in before:
		if before[key] != after.get(key): keys.append(key)
	return keys

func setup_source() -> void:
	Flow.instance.state = Flow.State.MENU
	Flow.instance._set_overlay_visible(false)
	paused = false
	Run.begin_run()
	source = load("res://scenes/sanctum_main.tscn").instantiate()
	root.add_child(source)
	current_scene = source
	await frames(15)
	director = source.get_node("Enemies/WaveDirector")
	director.set_process(false)
	Flow.instance.state = Flow.State.PLAYING
	player = source.get_node("PlayerSpawner").spawn_player()
	for _i in 240:
		if _i == 0:
			director.start_boss_direct(833731)
		else:
			director._process(1.0 / 60.0)
		director.set_process(false)
		await physics_frame
		if is_instance_valid(director._boss): break
	boss = director._boss
	check(is_instance_valid(boss), "正式圣所必须实际生成泰坦，不能换成模拟敌人")
	if not is_instance_valid(boss): return
	boss.ai_enabled = false
	boss.prepare_sparring_phase("front")
	player.health = 600.0
	player.shield = 37.0
	boss.target = player
	source_body = falling_body(source, Vector3(20, 30, 20))
	source_timer = Timer.new()
	source_timer.wait_time = 60.0
	source.add_child(source_timer)
	source_timer.start()
	await frames(4)
	# 固定源目标与预览目标的查询距离，供全树 player 查询负对照。
	player.velocity = Vector3.ZERO
	player.global_position = Vector3(0, 1.05, -1)
	boss.trigger_thrust_attack()
	await frames(2)
	MouseControl.mode = Input.MOUSE_MODE_CAPTURED

func falling_body(host: Node, at: Vector3) -> RigidBody3D:
	var body := RigidBody3D.new()
	var shape := CollisionShape3D.new()
	shape.shape = SphereShape3D.new()
	body.add_child(shape)
	body.position = at
	body.can_sleep = false
	host.add_child(body)
	return body

func create_preview(guarded: bool, settings: Dictionary = {}) -> void:
	preview = SubViewport.new()
	preview.size = Vector2i(640, 480)
	preview.own_world_3d = true
	preview.process_mode = Node.PROCESS_MODE_ALWAYS
	preview.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	root.add_child(preview)
	preview_root = Node3D.new()
	preview_root.name = "T00Preview"
	preview.add_child(preview_root)
	# SceneTree.current_scene 必须是 root 的直接子节点；用预览视口承接
	# 现有技能通过 current_scene 生成的临时效果，不能指向嵌套的 Node3D。
	if guarded: current_scene = preview
	var floor_body := StaticBody3D.new()
	var collider := CollisionShape3D.new()
	var shape := BoxShape3D.new()
	shape.size = Vector3(100, 1, 100)
	collider.shape = shape
	floor_body.position.y = -0.5
	floor_body.add_child(collider)
	preview_root.add_child(floor_body)
	var mesh := MeshInstance3D.new()
	var plane := PlaneMesh.new()
	plane.size = Vector2(100, 100)
	mesh.mesh = plane
	preview_root.add_child(mesh)
	var light := DirectionalLight3D.new()
	light.rotation_degrees = Vector3(-55, -30, 0)
	preview_root.add_child(light)
	var camera := Camera3D.new()
	preview_root.add_child(camera)
	camera.position = Vector3(18, 16, 18)
	camera.look_at(Vector3(0, 1, -6))
	camera.make_current()
	preview_target = Target.new()
	preview_target.position = Vector3(0, 1.05, -12)
	preview_target.collision_layer = 2
	preview_target.collision_mask = 1
	var target_shape := CollisionShape3D.new()
	var capsule := CapsuleShape3D.new()
	capsule.height = 2.0
	capsule.radius = 0.45
	target_shape.shape = capsule
	preview_target.add_child(target_shape)
	preview_root.add_child(preview_target)
	preview_target.add_to_group("player")
	preview_boss = Titan.instantiate()
	preview_boss.set_meta(&"enemy_tuning", (boss._tuning if settings.is_empty() else settings).duplicate(true))
	preview_boss.set_meta(&"crowd_uniform", true)
	preview_boss.set_meta(&"crowd_seed", 833731)
	if guarded:
		preview_boss.combat_spatial_profile = preview_boss.combat_spatial_profile.duplicate(true)
	preview_root.add_child(preview_boss)
	preview_boss.ai_enabled = false
	preview_boss.prepare_sparring_phase("front")
	preview_boss.position = Vector3(0, preview_boss.get_stand_height(), 0)
	preview_boss.target = preview_target
	preview_body = falling_body(preview_root, Vector3(8, 12, 8))

func suspend_source() -> void:
	saved_clock = Engine.time_scale
	saved_mouse = MouseControl.mode
	saved_limiter = Limiter._active.duplicate(true)
	saved_crowd = Crowd._snapshots.duplicate(true)
	# 仅一个活动预览：冻结源节点（包括显式 Always 子节点），屏蔽其全树组查询。
	for node: Node in all_nodes(source):
		original_modes.append({"node": node, "mode": node.process_mode})
		node.process_mode = Node.PROCESS_MODE_DISABLED
		for group: StringName in node.get_groups():
			if String(group).begins_with("_"): continue
			hidden_groups.append({"node": node, "group": group})
			node.remove_from_group(group)
	for node: Node in root.get_children():
		if node == source: continue
		original_modes.append({"node": node, "mode": node.process_mode})
		node.process_mode = Node.PROCESS_MODE_DISABLED
	Limiter._active = {}
	Crowd._snapshots = {}
	paused = true
	source_space = source.get_world_3d().space
	PhysicsServer3D.space_set_active(source_space, false)
	# 总暂停默认停整个物理服务；只放行预览，源世界仍保持关闭。
	PhysicsServer3D.set_active(true)

func restore_source() -> void:
	current_scene = source
	Engine.time_scale = saved_clock
	MouseControl.mode = saved_mouse
	Limiter._active = saved_limiter
	Crowd._snapshots = saved_crowd
	for item: Dictionary in hidden_groups:
		if is_instance_valid(item.node): item.node.add_to_group(item.group)
	hidden_groups.clear()
	for item: Dictionary in original_modes:
		if is_instance_valid(item.node): item.node.process_mode = item.mode
	original_modes.clear()
	# 返回仍停在原现场，用户继续时才恢复模拟。
	PhysicsServer3D.space_set_active(source_space, true)
	PhysicsServer3D.set_active(false)

func raw_trial() -> void:
	paused = true
	var before := snapshot()
	var start := Time.get_ticks_usec()
	var memory := metrics()
	create_preview(false)
	await frames(5)
	var original_y := preview_body.position.y
	var nearest := Targeting.nearest_player(preview_boss)
	var shared: bool = preview_boss.combat_spatial_profile == boss.combat_spatial_profile
	var run_before := Run.get_wave()
	Run.set_progress(Run.get_stage(), 99)
	var run_leak := Run.get_wave() == 99
	Run.set_progress(Run.get_stage(), run_before)
	await frames(20)
	var result := {"case": "raw_world3d", "open_ms": float(Time.get_ticks_usec()-start)/1000.0,
		"memory_before": memory, "memory_open": metrics(), "target_crosses_source": nearest == player,
		"shared_spatial_resource": shared, "run_state_is_global": run_leak,
		"preview_physics_frozen": is_equal_approx(preview_body.position.y, original_y),
		"source_changed": changed(before, snapshot())}
	check(result.target_crosses_source and result.shared_spatial_resource and result.run_state_is_global,
		"裸 World3D 必须暴露全树目标、共享 Resource 与全局进度负对照")
	check(result.preview_physics_frozen, "总暂停下的裸预览物理应被阻止，防止误认 Always 即物理独立")
	preview.queue_free()
	await process_frame
	observations.append(result)
	paused = false
	await frames(2)

func guarded_trial(cancel_early: bool) -> void:
	var start := Time.get_ticks_usec()
	var memory := metrics()
	var before := snapshot()
	var source_node_count := all_nodes(source).size()
	# 诊断用固定序列；不通过“返回时重设种子”伪造现场随机状态保留。
	seed(482391)
	var expected_next := randi()
	seed(482391)
	suspend_source()
	create_preview(true)
	await frames(6)
	var open_ms := float(Time.get_ticks_usec()-start)/1000.0
	var initial_y := preview_body.position.y
	check(preview_boss.get_world_3d() != source.get_world_3d(), "预览必须有独立物理世界")
	check(Targeting.nearest_player(preview_boss) == preview_target, "受控预览目标不应跨到源玩家")
	check(preview_boss.combat_spatial_profile != boss.combat_spatial_profile, "预览可变 Resource 必须独立")
	check(preview_boss._tuning == boss._tuning, "使用正式泰坦的实际参数快照，不复制另一套数值")
	preview_boss.combat_spatial_profile.set_meta(&"t00_preview_only", true)
	check(not boss.combat_spatial_profile.has_meta(&"t00_preview_only"), "Resource 编辑不能污染原对象")
	check(preview_boss.trigger_thrust_attack(), "真实泰坦应能在预览中执行已有震拳")
	var damage_seen := false
	var input_origin := preview_target.position
	for index in (8 if cancel_early else 190):
		if index == 2: Input.action_press("move_right")
		if index == 12: Input.action_release("move_right")
		if index == 20: Engine.time_scale = 0.25
		if index == 40: Engine.time_scale = 1.0
		await physics_frame
		if index == 18 and DisplayServer.get_name() != "headless":
			await RenderingServer.frame_post_draw
			check(preview.get_texture().get_image().save_png(Artifacts.ensure_dir("screenshots").path_join("t00_preview_warning.png")) == OK, "实际预警画面保存成功")
		damage_seen = damage_seen or preview_target.damage_events > 0
		if not cancel_early and damage_seen and preview_boss.current_state == preview_boss.State.IDLE: break
	Input.action_release("move_right")
	var active_ms := float(Time.get_ticks_usec()-start)/1000.0
	var altered := changed(before, snapshot())
	var result := {"case": "guarded_cancel" if cancel_early else "guarded_skill", "open_ms": open_ms,
		"active_wall_ms": active_ms, "memory_before": memory, "memory_open": metrics(),
		"source_changed_while_preview": altered, "damage_events": preview_target.damage_events,
		"preview_physics_fell": preview_body.position.y < initial_y - 0.05,
		"preview_input_moved": preview_target.position.x > input_origin.x + 0.01,
		"source_nodes_before": source_node_count, "source_before": before, "source_during": snapshot()}
	check(altered.is_empty(), "预览／输入／慢放不能改源现场：" + str(altered))
	check(result.preview_physics_fell, "预览必须真正运行刚体物理，不能只播放动画")
	if not cancel_early:
		check(damage_seen, "真实震拳必须通过现有判定造成一次预览伤害")
		check(result.preview_input_moved, "预览允许处理输入，同时源现场不移动")
		if DisplayServer.get_name() != "headless":
			await RenderingServer.frame_post_draw
			check(preview.get_texture().get_image().save_png(Artifacts.ensure_dir("screenshots").path_join("t00_preview.png")) == OK, "预览画面保存成功")
	start = Time.get_ticks_usec()
	preview.queue_free()
	await process_frame
	restore_source()
	result["return_ms"] = float(Time.get_ticks_usec()-start)/1000.0
	result["source_changed_after_return"] = changed(before, snapshot())
	result["source_after_return"] = snapshot()
	result["source_nodes_after"] = all_nodes(source).size()
	result["global_rng_preserved"] = randi() == expected_next
	result["full_isolation_accepted"] = false
	check(result.source_changed_after_return.is_empty(), "返回必须保留同一个现场及其状态")
	check(result.source_nodes_after == source_node_count, "攻击／取消后不能往源场景留下预览效果")
	check(is_equal_approx(Engine.time_scale, saved_clock) and MouseControl.mode == saved_mouse, "返回还原时钟与鼠标请求")
	check(get_nodes_in_group("player").has(player) and get_nodes_in_group("enemies").has(boss), "返回恢复原对象组身份")
	check(Input.mouse_mode == Input.MOUSE_MODE_VISIBLE and MouseControl.is_automation(), "自动运行真实鼠标始终自由")
	check(not result.global_rng_preserved, "负对照应揭示实际泰坦初始化仍消耗共享全局随机序列")
	observations.append(result)
	# 明确解除暂停，验证原技能和模拟可以继续。
	var old_clock: float = boss.anim_clock
	paused = false
	await frames(4)
	check(boss.anim_clock > old_clock, "返回后原对象必须能继续模拟")

func process_trial(cancel_early := false) -> void:
	paused = true
	var before := snapshot()
	var start := Time.get_ticks_usec()
	var memory := metrics()
	var suffix := "_cancel" if cancel_early else ""
	var request_path := Artifacts.ensure_dir("reports").path_join("t00_child_request" + suffix + ".json")
	var request_file := FileAccess.open(request_path, FileAccess.WRITE)
	check(request_file != null, "子预览请求必须能写入本次产物，不能回退项目配置")
	if request_file == null: return
	request_file.store_string(JSON.stringify({"values": boss._tuning, "seed": 833731, "hold_for_cancel": cancel_early}))
	request_file.close()
	var child_artifacts := Artifacts.ensure_dir("tmp", "preview_child" + suffix)
	var child_report := child_artifacts.path_join("reports/t00_child.json")
	var started_report := child_artifacts.path_join("reports/started.json")
	seed(482391)
	var expected_next := randi()
	seed(482391)
	var pid := OS.create_process(OS.get_executable_path(), PackedStringArray([
		"--headless", "--path", ProjectSettings.globalize_path("res://"),
		"--log-file", Artifacts.ensure_dir("logs").path_join("t00_child" + suffix + ".engine.log"),
		"--fixed-fps", "60", "--script", "res://tools/probes/testing_session_probe.gd", "--",
		"--t00-child=" + request_path, "--artifact-dir=" + child_artifacts]), false)
	check(pid > 0, "独立预览进程必须成功创建")
	var cancelled := false
	while pid > 0 and OS.is_process_running(pid) and Time.get_ticks_usec() - start < 30000000:
		if cancel_early and FileAccess.file_exists(started_report):
			var ready: Variant = JSON.parse_string(FileAccess.get_file_as_string(started_report))
			if ready is Dictionary and int(ready.get("pid", -1)) == pid:
				cancelled = OS.kill(pid) == OK
				break
		await process_frame
	if cancelled:
		while OS.is_process_running(pid) and Time.get_ticks_usec() - start < 30000000:
			await process_frame
	if pid > 0 and OS.is_process_running(pid):
		OS.kill(pid)
		check(false, "独立预览超时，必须清理并返回源现场")
	var rng_preserved := randi() == expected_next
	var child: Variant = JSON.parse_string(FileAccess.get_file_as_string(child_report)) if FileAccess.file_exists(child_report) else null
	var child_ok: bool = cancelled if cancel_early else child is Dictionary and child.get("passed", false)
	var child_log := FileAccess.get_file_as_string(Artifacts.ensure_dir("logs").path_join("t00_child" + suffix + ".engine.log"))
	check(not child_log.contains("SCRIPT ERROR:") and not child_log.contains("ERROR:"), "子预览也必须经过引擎错误检查")
	check(child_ok, "独立预览必须实际通过技能／物理／参数检查并写回结果")
	var delta := changed(before, snapshot())
	check(delta.is_empty(), "独立预览不能改变源现场：" + str(delta))
	check(rng_preserved, "子预览使用／重设随机种子不得消耗父进程随机序列")
	check(is_equal_approx(Engine.time_scale, 1.0), "子预览慢放不得改变父进程时钟")
	check(MouseControl.mode == Input.MOUSE_MODE_CAPTURED and Input.mouse_mode == Input.MOUSE_MODE_VISIBLE, "子预览不能改变源鼠标请求或捕获系统鼠标")
	observations.append({"case": "separate_process_cancel" if cancel_early else "separate_process", "roundtrip_ms": float(Time.get_ticks_usec()-start)/1000.0,
		"memory_before": memory, "parent_memory_after": metrics(), "child": child,
		"cancelled": cancelled, "child_still_running": OS.is_process_running(pid),
		"source_before": before, "source_after_return": snapshot(),
		"source_changed_after_return": delta, "global_rng_preserved": rng_preserved,
		"same_instance": source.get_instance_id() == before.world_id,
		"full_isolation_accepted": child_ok and delta.is_empty() and rng_preserved,
		"limits": "真实物理预览为无头子进程；窗口/草稿通信界面尚未实现，父现场已有未归属定时器另需审查。"})
	paused = false
	await frames(4)

func child_run(request_path: String) -> void:
	await frames(3)
	check(MouseControl.is_automation(), "子进程必须继承统一启动器的自动标记")
	check(bool(ProjectSettings.get_setting("display/window/size/no_focus", false)), "子进程必须沿用隔离工程窗口设置")
	var request: Variant = JSON.parse_string(FileAccess.get_file_as_string(request_path))
	if not request is Dictionary or not request.get("values") is Dictionary:
		check(false, "子预览请求格式不正确")
		quit(1)
		return
	Flow.instance.set_meta(&"sparring_session_active", true)
	Flow.instance.state = Flow.State.PLAYING
	paused = false
	seed(int(request.seed))
	create_preview(true, request.values)
	await frames(8)
	check(preview_boss._tuning == request.values, "独立预览必须沿用父进程传来的实际参数快照")
	check(preview_boss.trigger_thrust_attack(), "独立进程执行真实震拳")
	var start_y := preview_body.position.y
	# 刻意修改子进程全局状态，检查父进程不会跟着变。
	Run.set_progress(9, 99)
	Arena.current_id = "t00_child_only"
	preview_boss.combat_spatial_profile.set_meta(&"t00_child_only", true)
	MouseControl.mode = Input.MOUSE_MODE_VISIBLE
	Engine.time_scale = 0.25
	Input.action_press("move_right")
	if bool(request.get("hold_for_cancel", false)):
		var ready_file := FileAccess.open(Artifacts.ensure_dir("reports").path_join("started.json"), FileAccess.WRITE)
		if ready_file == null:
			check(false, "子预览取消握手写入失败")
			quit(1)
			return
		ready_file.store_string(JSON.stringify({"pid": OS.get_process_id(), "state": "real_attack_started"}))
		ready_file.close()
		var hold_start := Time.get_ticks_msec()
		while Time.get_ticks_msec() - hold_start < 5000: await process_frame
	await frames(12)
	Input.action_release("move_right")
	Engine.time_scale = 1.0
	for _i in 190:
		await physics_frame
		if preview_target.damage_events > 0 and preview_boss.current_state == preview_boss.State.IDLE: break
	check(preview_target.damage_events == 1, "独立预览实际伤害只结算一次")
	check(preview_body.position.y < start_y-0.05, "独立预览刚体物理正常运行")
	var result := {"passed": failures.is_empty(), "failures": failures, "pid": OS.get_process_id(),
		"damage_events": preview_target.damage_events, "physics_ticks": preview_target.physics_ticks,
		"memory": metrics(), "settings_equal": preview_boss._tuning == request.values,
		"deliberate_global_changes": ["RunState", "Arena", "Engine.time_scale", "global RNG", "Resource", "input", "MouseControl"]}
	current_scene = null
	preview.queue_free()
	await frames(4)
	Pool.clear_all()
	await preload("res://tools/probes/sparring/sparring_runtime.gd").settle_audio(self)
	var file := FileAccess.open(Artifacts.ensure_dir("reports").path_join("t00_child.json"), FileAccess.WRITE)
	if file == null:
		push_error("子预览报告写入失败")
		quit(1)
		return
	file.store_string(JSON.stringify(result, "\t"))
	file.close()
	quit(0 if failures.is_empty() else 1)

func reload_trial() -> void:
	var old_id := source.get_instance_id()
	var old_health: float = player.health
	var old_shield: float = player.shield
	var start := Time.get_ticks_usec()
	current_scene = null
	source.queue_free()
	await frames(3)
	Pool.clear_all()
	await setup_source()
	var rebuilt_id := source.get_instance_id()
	observations.append({"case": "reload_baseline", "roundtrip_ms": float(Time.get_ticks_usec()-start)/1000.0,
		"old_world_id": old_id, "new_world_id": rebuilt_id, "same_instance": old_id == rebuilt_id,
		"old_health": old_health, "old_shield": old_shield,
		"note": "沿用加载主场景并生成玩家的重建机制；未实现任何完整状态序列化。受控准备值相同不等于保留原实例。"})
	check(old_id != rebuilt_id, "重建负对照应产生不同现场，不能冒充保留原帧")

func _run() -> void:
	for argument: String in OS.get_cmdline_user_args():
		if argument.begins_with("--t00-child="):
			await child_run(argument.trim_prefix("--t00-child="))
			return
	await frames(3)
	Flow.instance.set_meta(&"sparring_session_active", true)
	await setup_source()
	if is_instance_valid(boss):
		await raw_trial()
		await guarded_trial(false)
		await guarded_trial(true)
		await process_trial()
		await process_trial(true)
		await reload_trial()
	paused = false
	Engine.time_scale = 1.0
	current_scene = null
	source.queue_free()
	await frames(5)
	Pool.clear_all()
	await preload("res://tools/probes/sparring/sparring_runtime.gd").settle_audio(self)
	Flow.instance.remove_meta(&"sparring_session_active")
	var path := Artifacts.ensure_dir("reports").path_join("testing_session_probe.json")
	var file := FileAccess.open(path, FileAccess.WRITE)
	if file == null:
		push_error("T00 证据写入失败：" + path)
		quit(1)
		return
	file.store_string(JSON.stringify({"godot": Engine.get_version_info(), "passed": failures.is_empty(),
		"failures": failures, "trials": observations,
		"scope": "T00 对照诊断通过不等于所有候选可采用；同进程有限状态保持，但全局随机序列负对照必须被识别。独立进程覆盖实际技能与源随机状态。",
		"unverified": ["完整导航与跨竞技场静态缓存", "预览事件对所有 EventBus 订阅的隔离", "未归属节点的 SceneTreeTimer", "任意新编辑器的全局读写", "生产会话异常恢复与全部画面模块"]}, "\t"))
	file.close()
	print("[T00] failures=", failures.size(), " report=", path)
	quit(0 if failures.is_empty() else 1)
