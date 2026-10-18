extends SceneTree
## 正式玩家碰撞与翻滚：落地单滚后停下会受追击；看到新预警后侧移能避开。
const Spawner := preload("res://scripts/enemy_spawner.gd")
const Artifacts := preload("res://scripts/artifact_paths.gd")
var failures := 0
var results: Array = []
var world: Node3D
var player: CharacterBody3D
var boss: CharacterBody3D
func _initialize() -> void: call_deferred("_run")
func check(ok: bool, message: String) -> void:
	if not ok:
		failures += 1
		push_error(message)
func frames(n: int) -> void:
	for _i in range(n): await physics_frame
func setup(phase: String) -> void:
	world = Node3D.new()
	root.add_child(world)
	current_scene = world
	var floor_body := StaticBody3D.new()
	var c := CollisionShape3D.new()
	var shape := BoxShape3D.new()
	shape.size = Vector3(150, 1, 150)
	c.shape = shape
	floor_body.position.y = -0.5
	floor_body.add_child(c)
	world.add_child(floor_body)
	player = load("res://scenes/player.tscn").instantiate()
	player.position = Vector3(0, 1.05, -18)
	world.add_child(player)
	var spawner := Node.new()
	spawner.set_script(Spawner)
	world.add_child(spawner)
	boss = spawner.spawn_boss("sediment_titan", Vector3.ZERO)
	boss.ai_enabled = false
	boss.prepare_sparring_phase(phase)
	boss.target = player
	await frames(8)
	player.health = 10000
	player.shield = 0
	player._shield_regen_timer = 1000
func dispose() -> void:
	Input.action_release("move_right")
	current_scene = null
	world.queue_free()
	await frames(5)
func _run() -> void:
	root.get_node("GameFlow").set_meta(&"sparring_session_active", true)
	for sidestep in [false, true]:
		await setup("rage")
		check(boss.trigger_leap_attack() and boss._leap_followup_armed, "正式跃击可作为招组开头，预留独立追击")
		var rolled := false
		var landing := -1
		var warning := -1
		var impact := -1
		var hp_at_landing := 0.0
		for _i in range(360):
			await physics_frame
			if boss.current_state == boss.State.LEAP_AIR and not rolled and boss._leap_elapsed >= boss._leap_flight - .10:
				rolled = true
				player.position = boss._leap_landing + Vector3(0, -boss.get_stand_height() + 1.05, -4)
				player.velocity = Vector3.ZERO
				player._start_roll(Vector3.FORWARD)
			if boss.current_state == boss.State.LEAP_RECOVERY and landing < 0:
				landing = Engine.get_physics_frames()
				hp_at_landing = player.health
			if boss.current_state == boss.State.ATK_THRUST:
				if warning < 0:
					warning = Engine.get_physics_frames()
					check(player.health == 10000, "真实翻滚无敌帧躲过落地，尚无追击伤害")
					player.camera_pivot.rotation = Vector3.ZERO
					player.target_yaw = 0
				if sidestep and Engine.get_physics_frames() - warning >= 15: Input.action_press("move_right")
				if boss._attack_area.phase == boss.AttackArea.Phase.RECOVERY and impact < 0: impact = Engine.get_physics_frames()
			if impact >= 0 and boss.current_state == boss.State.IDLE: break
		check(landing >= 0 and warning > landing and impact > warning, "落地／新预警／追击命中是三个独立阶段")
		check(hp_at_landing == 10000, "落地本身未漏过翻滚无敌")
		check(player.health == 10000 if sidestep else player.health < 10000, "延迟0.25秒侧移可躲；仅单滚后停下会受轻追击")
		check(boss._brain.group_count == 0 and boss._brain.history.size() == 2, "跃击＋轻震拳同组两招后明确结束，不无限补招")
		var adapter := preload("res://tools/probes/sparring/sparring_enemy_adapter.gd")
		check(adapter.sample(boss, "chain").state != "unknown", "陪练识别新动作")
		results.append({"sidestep": sidestep, "landing_to_warning": float(warning - landing) / 60, "landing_to_impact": float(impact - landing) / 60, "health_loss": 10000-player.health, "attacks": boss._brain.history.duplicate(true)})
		await dispose()
	# 已挣得长奖励抢先取消落地后续，不能被衔接回调复活。
	await setup("front")
	player.set_physics_process(false)
	check(boss.trigger_leap_attack(), "前半衔接跃击可开始")
	for _i in range(160):
		await physics_frame
		if boss.current_state == boss.State.LEAP_AIR: break
	for token in [201, 202, 203]: boss.receive_grenade_contact(10, token, {})
	check(boss._pending_reward == "kneel", "空中第三枚实际触盾事件锁定已挣得跪地")
	await frames(170)
	check(boss._reward_kind == "kneel" and not boss._leap_followup_armed and boss._brain.history.size() == 1, "安全接地后给完整跪地，不残留追击")
	await dispose()
	# 目标离开长轻击范围，不隔空强接或无限追招。
	await setup("rage")
	player.set_physics_process(false)
	check(boss.trigger_leap_attack(), "越界反例真实跃击开始")
	for _i in range(160):
		await physics_frame
		if boss.current_state == boss.State.LEAP_AIR:
			player.position = boss._leap_landing + Vector3(0, 1.05-boss.get_stand_height(), -25)
			break
	await frames(260)
	check(boss.current_state == boss.State.IDLE and boss._brain.history.size() == 1 and boss._brain.group_count == 0, "越界后兑现完整收势并结束，不触发幽灵追击")
	await dispose()
	await setup("front")
	player.set_physics_process(false)
	player.position = Vector3(0, 1.05, -9.5)
	boss.rotation.y = 0
	boss._select_attack(9.5)
	check(boss.current_state == boss.State.ATK_SWEEP, "横扫覆盖原8.25米外的9.5米稳定引招带")
	for _i in range(150):
		await physics_frame
		check(boss.has_mud_shield, "前半横扫／重招／收势全程常驻泥盾")
		if boss.current_state == boss.State.IDLE: break
	boss._brain.finish_group("test")
	player.position = Vector3(0, 1.05, -12)
	boss._select_attack(12)
	check(boss.current_state == boss.State.ATK_THRUST, "横扫外中距离优先远距轻击，不能总诱发慢直线重击")
	var facing: float = boss.rotation.y
	player.position.x += 8
	await frames(12)
	check(is_equal_approx(boss.rotation.y, facing), "新预警之后移动目标不能扭转已公布攻击线")
	var time: float = boss._brain.elapsed
	paused = true
	for _i in range(5): await process_frame
	check(is_equal_approx(boss._brain.elapsed, time), "暂停冻结新动作及招组")
	paused = false
	boss.apply_grenade_stagger(.25)
	check(boss._grenade_pause.remaining >= .249, "新轻击仍受真实手雷短硬直")
	boss.take_damage(10000000)
	await frames(100)
	check(not is_instance_valid(boss), "死亡取消追击及旧回调")
	await dispose()
	var file := FileAccess.open(Artifacts.ensure_dir("reports", "followup").path_join("result.json"), FileAccess.WRITE)
	file.store_string(JSON.stringify({"failures": failures, "trials": results, "scope": "受控机制，不是玩家群体难度结论"}, "\t"))
	file.close()
	preload("res://scripts/object_pool.gd").clear_all()
	await preload("res://tools/probes/sparring/sparring_runtime.gd").settle_audio(self)
	root.get_node("GameFlow").remove_meta(&"sparring_session_active")
	print("[泰坦落地衔接] failures=", failures)
	quit(1 if failures else 0)
