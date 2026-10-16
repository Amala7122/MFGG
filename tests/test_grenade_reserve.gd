extends SceneTree
## A3：从正式投放与真实E输入检查资源，不用直接改库存证明能释放。
const PlayerScene := preload("res://scenes/player.tscn")
const Spawner := preload("res://scripts/enemy_spawner.gd")
const GrenadeScript := preload("res://scripts/grenade.gd")
const Tuning := preload("res://scripts/prototypes/enemy_tuning.gd")
const Recorder := preload("res://tools/probes/sparring/sparring_recorder.gd")
const Artifacts := preload("res://scripts/artifact_paths.gd")
const Capture := preload("res://tools/probes/sparring/sparring_capture.gd")
const ParameterPanel := preload("res://scripts/prototypes/visual_model_panel.gd")
var _failures := 0
var _world: Node3D

func _initialize() -> void:
	call_deferred("_run")

func _check(ok: bool, message: String) -> void:
	if not ok:
		_failures += 1
		push_error(message)

func _projectiles() -> int:
	var count := 0
	for node in _world.get_children():
		if node.get_script() == GrenadeScript and not node.is_queued_for_deletion():
			count += 1
	return count

func _press(player: Node) -> bool:
	var before := _projectiles()
	player.set_physics_process(true)
	var event := InputEventAction.new()
	event.action = "grenade"
	event.pressed = true
	Input.parse_input_event(event)
	Input.flush_buffered_events()
	await physics_frame
	event = InputEventAction.new()
	event.action = "grenade"
	event.pressed = false
	Input.parse_input_event(event)
	Input.flush_buffered_events()
	await physics_frame
	player.set_physics_process(false)
	return _projectiles() > before

func _spawn_boss(spawner: Node) -> Node3D:
	var boss: Node3D = spawner.spawn_boss("sediment_titan", Vector3(0, 0, -25))
	boss.ai_enabled = false
	boss.set_physics_process(false)
	if boss._action_tween != null:
		boss._action_tween.pause()
	for _frame in range(3):
		await process_frame
	return boss

func _capture(player: Node, name: String) -> void:
	player._refresh_hud()
	if DisplayServer.get_name() == "headless":
		return
	await process_frame
	await RenderingServer.frame_post_draw
	_check(root.get_texture().get_image().save_png(Artifacts.ensure_dir("screenshots", "grenade_stock").path_join(name + ".png")) == OK, "保存真实HUD画面")

func _run() -> void:
	_verify_saved_parameters()
	_verify_resource_replay()
	var cfg := Tuning.preset_values("PrototypeSedimentTitan", "圣所关底 Boss")
	_check(bool(cfg.grenade_reserve_enabled) and int(cfg.grenade_reserve_capacity) == 3 and int(cfg.grenade_reserve_start) == 3, "正式方案显式开启三枚，未依赖原型active方案")
	_check(not bool(Tuning.defaults("PrototypeSedimentTitan").grenade_reserve_enabled), "旧原型默认不开启Boss资源覆盖")
	var invalid := cfg.duplicate(true)
	invalid.grenade_reserve_capacity = 2
	_check(not Tuning.validate("PrototypeSedimentTitan", invalid).is_empty(), "初始枚数高于上限被拒绝")
	_world = Node3D.new()
	root.add_child(_world)
	current_scene = _world
	var floor := StaticBody3D.new()
	var collision := CollisionShape3D.new()
	var shape := BoxShape3D.new()
	shape.size = Vector3(120, 1, 120)
	collision.shape = shape
	floor.position.y = -0.5
	floor.add_child(collision)
	_world.add_child(floor)
	var player: CharacterBody3D = PlayerScene.instantiate()
	player.position = Vector3(0, 1.05, 12)
	_world.add_child(player)
	for _frame in range(5):
		await physics_frame
	player.set_physics_process(false)
	_check(player.get_grenade_status().mode == "cooldown", "普通场景仍是原冷却资源")
	_check(await _press(player), "普通场景真实E生成手雷")
	_check(player._grenade_cooldown > 5.8, "普通场景保留六秒冷却")
	player._tick_timers(2.0)
	var inherited_wait: float = player._grenade_cooldown
	var spawner := Node.new()
	spawner.set_script(Spawner)
	_world.add_child(spawner)
	var boss: Node3D = await _spawn_boss(spawner)
	_check(player.get_grenade_status().charges == 3 and player.get_grenade_status().capacity == 3, "正式生成器自动接入玩家三枚库存")
	_check(is_equal_approx(player._grenade_cooldown, inherited_wait), "进战保留已有投掷冷却，不借模式切换刷新")
	player._tick_timers(inherited_wait + 0.01)
	_check(await _press(player), "第一枚真实E可投")
	var first: Dictionary = player.get_grenade_status()
	_check(first.charges == 2 and first.throw_remaining > 1.1 and first.recharge_remaining > 5.8, "第一枚扣库存，分别开始短间隔与回充")
	await _capture(player, "stock_2_interval_and_refill")
	_check(not await _press(player) and player.get_grenade_status().charges == 2, "短间隔内按E不扣库存、不生成手雷")
	player._tick_timers(1.2)
	var progress_before: float = player.get_grenade_status().recharge_remaining
	_check(await _press(player), "第二枚在短间隔后可投")
	_check(player.get_grenade_status().charges == 1 and player.get_grenade_status().recharge_remaining < progress_before, "第二枚不重置第一枚的回充进度")
	player._tick_timers(1.2)
	_check(await _press(player) and player.get_grenade_status().charges == 0, "第三枚可投且耗尽库存")
	player._tick_timers(1.2)
	var recorder := Recorder.new()
	recorder.start()
	recorder._pending_input = {"just": {"grenade": true}, "before": recorder._input_state(player)}
	_check(not await _press(player) and player.get_grenade_status().charges == 0, "空库存不产生负数或额外投掷")
	recorder.record_input_effects(player)
	_check(recorder.event_rows[-1].details.reason == "手雷库存为空，等待逐枚回充", "陪练能区分库存为空与冷却拒绝")
	await _capture(player, "stock_0_waiting_refill")
	var to_refill: float = player.get_grenade_status().recharge_remaining
	player._tick_timers(to_refill - 0.01)
	_check(player.get_grenade_status().charges == 0, "未到时间不提前补发")
	player._tick_timers(0.02)
	_check(player.get_grenade_status().charges == 1 and player.get_grenade_status().recharge_remaining > 5.9, "到时间只回一枚并继续下一枚")
	player.set_meta(&"combat_recorder", recorder)
	recorder._pending_input = {"just": {"grenade": true}, "before": recorder._input_state(player)}
	_check(await _press(player), "回充的一枚可以实际投出")
	recorder.record_input_effects(player)
	_check(recorder.event_rows[-1].details.accepted, "陪练实际攻击与库存扣除一致")
	player.remove_meta(&"combat_recorder")
	player._tick_timers(30.0)
	_check(player.get_grenade_status().charges == 3 and player.get_grenade_status().recharge_remaining == 0.0, "长步长逐枚补满，不溢出，满库存停表")
	player._tick_timers(30.0)
	_check(player.get_grenade_status().recharge_remaining == 0.0, "满库存不储存预充时间")
	_check(await _press(player), "满库存再投仍生成同一个正式手雷")
	var before_pause: Dictionary = player.get_grenade_status()
	paused = true
	player.set_physics_process(true)
	for _frame in range(8):
		await process_frame
	_check(player.get_grenade_status() == before_pause, "暂停期间间隔与回充均不前进")
	player.set_physics_process(false)
	paused = false
	player.set_meta(&"experiment_unlimited_abilities", true)
	player._tick_timers(1.2)
	var unlimited_before: Dictionary = player.get_grenade_status()
	_check(await _press(player), "实验场无限能力仍能实际投掷")
	_check(player.get_grenade_status().charges == unlimited_before.charges and player._grenade_cooldown <= 0, "实验场无限能力不扣库存或新加冷却")
	player.remove_meta(&"experiment_unlimited_abilities")
	var cached: int = player.get_grenade_status().charges
	player.enter_titan_grenade_reserve(boss, cfg)
	_check(player.get_grenade_status().charges == cached, "同一Boss重复接入不补满")
	boss.take_damage(boss.get_max_health() * 0.6)
	_check(boss.is_enraged and player.get_grenade_status().charges == cached, "实际跨半血狂暴不补库存")
	player.leave_titan_grenade_reserve(boss)
	_check(player.get_grenade_status().mode == "cooldown" and player._grenade_cooldown > 4.6, "退出交回普通冷却，不瞬间送一枚")
	player._tick_timers(10.0)
	player.enter_titan_grenade_reserve(boss, cfg)
	_check(player.get_grenade_status().charges == cached, "离开再进同一实例保留原库存，不在战外回充")
	boss.queue_free()
	await process_frame
	_check(player.get_grenade_status().mode == "cooldown", "Boss退出树自动交还普通模式")
	var second: Node3D = await _spawn_boss(spawner)
	_check(player.get_grenade_status().charges == 3, "新挑战实例按配置初始化")
	var late: CharacterBody3D = PlayerScene.instantiate()
	late.position = Vector3(5, 1.05, 12)
	_world.add_child(late)
	late.set_physics_process(false)
	_check(late.get_grenade_status().charges == 3, "晚于Boss生成的玩家也能正式接入")
	late.queue_free()
	second.queue_free()
	await process_frame
	var prototype: Node3D = load("res://prototypes/enemy_prototypes/procedural_sediment_titan.tscn").instantiate()
	_world.add_child(prototype)
	prototype.set_physics_process(false)
	_check(player.get_grenade_status().mode == "cooldown", "原型外形不会偷偷打开正式Boss资源")
	current_scene = null
	_world.queue_free()
	await process_frame
	preload("res://scripts/object_pool.gd").clear_all()
	await preload("res://tools/probes/sparring/sparring_runtime.gd").settle_audio(self)
	print("[泰坦手雷储备] failures=", _failures)
	quit(1 if _failures else 0)

func _verify_saved_parameters() -> void:
	var previous_directory: String = Tuning.storage_directory
	var previous_saved: Dictionary = Tuning._saved.duplicate(true)
	var document: Dictionary = Tuning._document("PrototypeSedimentTitan").duplicate(true)
	var previous_active: String = document.active
	Tuning.storage_directory = Artifacts.ensure_dir("tmp", "grenade_resource_presets")
	Tuning._saved = {"PrototypeSedimentTitan": document}
	var panel := ParameterPanel.new()
	root.add_child(panel)
	panel.bind_profile("PrototypeSedimentTitan")
	var switch_found := false
	for row in panel.fields.get_children():
		if row is HBoxContainer and row.get_child_count() == 2 and row.get_child(0) is Label and row.get_child(0).text == "开启玩家手雷储备":
			var toggle := row.get_child(1) as CheckButton
			if toggle != null:
				toggle.button_pressed = true
				switch_found = true
	_check(switch_found and panel.values.grenade_reserve_enabled is bool and panel.values.grenade_reserve_enabled, "真实开关控件编辑后仍保留布尔类型")
	panel._field_changed(1.7, "grenade_throw_interval")
	panel.preset_name.text = "A3保存验收"
	panel._save()
	_check(Tuning.active_name("PrototypeSedimentTitan") == previous_active, "真实面板保存命名方案不改变项目默认")
	_check(is_equal_approx(float(Tuning.preset_values("PrototypeSedimentTitan", "A3保存验收").grenade_throw_interval), 1.7), "真实面板可保存并读回新资源字段")
	panel._activate()
	_check(Tuning.active_name("PrototypeSedimentTitan") == "A3保存验收", "另行设为默认才改变选用方案")
	panel.queue_free()
	Tuning.storage_directory = previous_directory
	Tuning._saved = previous_saved

func _verify_resource_replay() -> void:
	var capture := Capture.new()
	var row := {"time": 1.0, "frame": 60, "state": 1, "player_position": [0,1,0], "boss_position": [0,2,10], "boss_hp": 100, "player_hp": 100, "player_shield": 70,
		"player": {"grenade_stock": {"mode": "reserve", "charges": 2, "capacity": 3, "throw_remaining": 0.0, "recharge_remaining": 4.0}}}
	capture._reference_available = true
	capture._reference = {60: row.duplicate(true)}
	capture.replay_audit = {"status": "checking"}
	row.player.grenade_stock.charges = 1
	capture._check_replay(row)
	_check(capture.replay_audit.status == "diverged" and capture.replay_audit.player_resource_difference.field == "charges", "位置血量相同但库存不同，也要判为首次重放偏离")
