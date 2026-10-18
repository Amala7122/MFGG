extends SceneTree
## A4.1 正式实现的时序契约；高血量靶仅验规则，不作胜率或手感结论。
const Spawner := preload("res://scripts/enemy_spawner.gd")
const Player := preload("res://scenes/player.tscn")
const Artifacts := preload("res://scripts/artifact_paths.gd")
var failures := 0
var rows: Array = []

func _initialize() -> void:
	call_deferred("_run")

func check(ok: bool, message: String) -> void:
	if not ok:
		failures += 1
		push_error(message)

func _run() -> void:
	var world := Node3D.new()
	root.add_child(world)
	current_scene = world
	var ground := StaticBody3D.new()
	var collision := CollisionShape3D.new()
	var shape := BoxShape3D.new()
	shape.size = Vector3(160, 1, 160)
	collision.shape = shape
	ground.position.y = -0.5
	ground.add_child(collision)
	world.add_child(ground)
	var player: CharacterBody3D = Player.instantiate()
	player.position = Vector3(0, 1.05, -7)
	world.add_child(player)
	var spawner := Node.new()
	spawner.set_script(Spawner)
	world.add_child(spawner)
	var boss: CharacterBody3D = spawner.spawn_boss("sediment_titan", Vector3.ZERO)
	boss.ai_enabled = false
	# 本测试守住A4.1的原2.4秒完整窗口；狂暴新配置与快照由test_titan_pressure独立验证。
	boss._tuning.rage_heavy_recovery_scale = 1.0
	boss._tuning.leap_followup_enabled = false # 独立守住无衔接时完整重跃击；新衔接另测。
	check(boss.prepare_sparring_phase("front"), "可以直入前半稳定姿态")
	boss.target = player
	for _i in range(5):
		await physics_frame
	player.set_physics_process(false)
	player.health = 100000.0
	check(boss.has_mud_shield and boss.mud_shield_visual.visible, "前半准备时泥盾视觉与减伤同时存在")
	var before: float = boss.health
	boss.take_damage(100.0)
	check(is_equal_approx(before - float(boss.health), 20.0), "前半常态盾保留80%减伤")
	for _i in range(400):
		await physics_frame
	check(boss.has_mud_shield, "盾不再因旧6秒持续时间自然消失")
	boss.trigger_sweep_attack()
	check(boss.has_mud_shield and boss._brain.group_count == 1, "快横扫保留泥盾并消费一招")
	await _idle(boss)
	boss.trigger_slam_attack()
	check(boss._heavy_window and boss.has_mud_shield and boss.mud_shield_visual.visible, "正式前半重招全程保盾，视觉与判定同步")
	before = boss.health
	boss.take_damage(100.0)
	check(is_equal_approx(before - float(boss.health), 20.0), "正式重招仍保留泥盾减伤，三雷破盾才有高收益")
	var result: Dictionary = await _observe_heavy(boss, true)
	rows.append(result)
	check(float(result.recovery_seconds) >= 2.33 and float(result.recovery_seconds) < 2.8, "砸地有效收势约2.4秒，短硬直不吞窗口")
	check(boss.has_mud_shield and boss._brain.group_count == 0, "完整后摇结束维持泥盾并结束招组")
	# 半血发生在承诺后的动作中，不能取消已开始的收势或临时多加一招。
	boss._brain.cooldowns.slam = 0.0
	boss.trigger_slam_attack()
	boss.current_hp = boss.max_hp * 0.49
	boss._trigger_rage()
	var stock: Dictionary = player.get_grenade_status()
	result = await _observe_heavy(boss, false)
	rows.append(result)
	check(float(result.recovery_seconds) >= 2.33, "半血不缩短前半已公布的完整2.4秒收势")
	check(not boss.has_mud_shield and not boss.mud_shield_visual.visible, "狂暴重招收势结束不重建泥盾")
	boss.on_resonance_incoming(Vector3.ZERO)
	boss._activate_mud_shield(true)
	check(not boss.has_mud_shield, "狂暴共鸣与强制入口都不能重新加泥盾")
	check(player.get_grenade_status().charges == stock.charges, "半血切换不重发手雷库存")
	# 单元边界使用同一选招器，验证上限在组开始锁定及无合法重招时不补快刀。
	boss._brain.finish_group("test_next")
	boss._brain.commit_offense(false, false)
	check(boss._brain.needs_heavy(), "前半第一快招后只允许重招收尾")
	check(boss._brain.group_limit == 2, "前半开始锁定两招上限")
	boss._brain.commit_offense(true, true)
	check(boss._brain.group_limit == 2, "中途狂暴不延长当前招组")
	boss._brain.finish_group("test_next")
	boss._brain.commit_offense(true, false)
	check(boss._brain.group_limit == 3 and not boss._brain.needs_heavy(), "狂暴新组最多三招")
	boss._brain.commit_offense(true, false)
	check(boss._brain.needs_heavy(), "狂暴第二快招后要求重招")
	check(boss._brain.link_expired(2.1), "无合法衔接有明确超时出口")
	# 实际物理循环中，后续不可用时要主动结束并停止追击。
	boss._brain.link_elapsed = 0.0
	boss._brain.cooldowns.slam = 20.0
	boss._brain.cooldowns.sweep = 20.0
	boss._brain.cooldowns.leap = 20.0
	boss._brain.cooldowns.thrust = 20.0
	for _i in range(135):
		await physics_frame
	check(boss.current_state == boss.State.GROUP_REST and boss._brain.group_count == 0, "衔接失败在物理循环进入短收势而非无限补招")
	check(not boss._heavy_window and boss._group_rest_remaining > 0.0, "衔接失败不冒充重招奖励窗口")
	var observed := preload("res://tools/probes/sparring/sparring_enemy_adapter.gd").sample(boss, "rhythm_test")
	check(observed.state == "group_rest" and observed.expected_wait and not observed.actionable, "陪练明确识别短收势为预期等待，不误报停摆")
	await _idle(boss)
	for key: String in boss._brain.cooldowns:
		boss._brain.cooldowns[key] = 0.0
	boss._brain.finish_group("test_next")
	var original_limit: float = boss._brain._settings.offense_front_limit
	boss._brain._settings.offense_front_limit = 1
	check(boss._brain.needs_heavy(false), "一招方案从第一招即要求重招，不越过上限")
	boss._brain._settings.offense_front_limit = original_limit
	# 真实合法跃击：落地后完整收势，保留既有安全接地。
	boss._brain.cooldowns.leap = 0.0
	boss._brain.approach_remaining = 0.0
	player.position = Vector3(0, 1.05, -22)
	await physics_frame
	check(boss.trigger_leap_attack(), "保留真实落点规划后可释放重跃击")
	result = await _observe_heavy(boss, false)
	rows.append(result)
	check(float(result.recovery_seconds) >= 2.33, "跃击从接地后的最后伤害起兑现完整收势")
	check(boss.is_on_floor() and not boss.has_mud_shield, "狂暴重跃击安全接地且不恢复盾")
	# 真实自动选招必须遵守相同上限；不是只验证手动调用的计数器。
	player.position = boss.global_position + Vector3(0, -1.75, -7)
	boss.ai_enabled = true
	var completed_groups := 0
	var previous_group: int = boss._brain.group_index
	for _i in range(1000):
		await physics_frame
		check(boss._brain.group_count <= boss._brain.group_limit, "自动选招不超过已锁定招组上限")
		check(not boss.has_mud_shield, "狂暴自动循环全程没有泥盾")
		if boss._brain.group_index != previous_group:
			previous_group = boss._brain.group_index
			completed_groups += 1
	check(completed_groups >= 2, "自动选招确实运行多组，不以停摆满足有限攻势")
	# 死亡必须取消旧收招回调，不能延后重施盾或复活动作。
	boss.take_damage(10000000.0)
	for _i in range(180):
		await physics_frame
	check(not is_instance_valid(boss), "重招／收势期间死亡正常退出，不被旧回调复活")
	var file := FileAccess.open(Artifacts.ensure_dir("reports", "rhythm").path_join("windows.json"), FileAccess.WRITE)
	file.store_string(JSON.stringify({"windows": rows, "failures": failures, "purpose": "mechanics_only_not_balance"}, "\t"))
	file.close()
	current_scene = null
	world.queue_free()
	for _i in range(5):
		await process_frame
	preload("res://scripts/object_pool.gd").clear_all()
	await preload("res://tools/probes/sparring/sparring_runtime.gd").settle_audio(self)
	print("[A4.1攻势窗口] failures=", failures)
	quit(1 if failures else 0)

func _idle(boss: Node) -> void:
	for _i in range(600):
		await physics_frame
		if boss.current_state == boss.State.IDLE:
			return
	check(false, "动作必须在有限时间收招")

func _observe_heavy(boss: Node, front: bool) -> Dictionary:
	var recovery_frame := -1
	var start := Engine.get_physics_frames()
	var location: Vector3 = boss.global_position
	var paused_once := false
	var paused_frames := 0
	for _i in range(720):
		await physics_frame
		if boss._heavy_recovering and recovery_frame < 0:
			recovery_frame = Engine.get_physics_frames()
			location = boss.global_position
		if boss._heavy_window:
			check(boss.has_mud_shield == (not boss.is_enraged) and boss.mud_shield_visual.visible == (not boss.is_enraged), "重招前摇／出手／后摇：前半常驻盾，狂暴无盾 rage=%s shield=%s visual=%s" % [boss.is_enraged, boss.has_mud_shield, boss.mud_shield_visual.visible])
			boss.on_resonance_incoming(Vector3.ZERO)
			check(boss.has_mud_shield == (not boss.is_enraged), "共鸣不能改变前半常驻／狂暴无盾规则")
		if boss._heavy_recovering:
			check(Vector2(boss.global_position.x - location.x, boss.global_position.z - location.z).length() < 0.04, "收势期间不追击或横移")
			check(boss._attack_area.phase == boss.AttackArea.Phase.RECOVERY, "收势没有残留攻击判定")
			if front and not paused_once:
				paused_once = true
				paused = true
				var pause_start := Engine.get_physics_frames()
				var elapsed: float = boss._brain.elapsed
				for _j in range(8):
					await process_frame
				check(is_equal_approx(elapsed, float(boss._brain.elapsed)) and boss.has_mud_shield, "暂停冻结窗口和招组计时，保留前半盾")
				paused_frames += Engine.get_physics_frames() - pause_start
				paused = false
				boss.apply_grenade_stagger(0.25)
		if boss.current_state == boss.State.IDLE:
			check(recovery_frame >= 0, "确实经历重招收势，不以取消冒充兑现")
			return {"rage": boss.is_enraged, "recovery_seconds": float(Engine.get_physics_frames() - recovery_frame - paused_frames) / 60.0,
				"excluded_paused_seconds": float(paused_frames) / 60.0, "grenade_stagger_seconds": 0.25 if front else 0.0,
				"total_seconds": float(Engine.get_physics_frames() - start) / 60.0, "shield_after": boss.has_mud_shield}
	check(false, "重招有有限完成时间")
	return {"recovery_seconds": 0.0}
