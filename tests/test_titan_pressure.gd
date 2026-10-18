extends SceneTree
## 枪击表现顿帧与战术硬直独立，暂停、前半和完整重招收势不退化。
const Spawner := preload("res://scripts/enemy_spawner.gd")
const FX := preload("res://scripts/combat_fx.gd")
var failures := 0
func _initialize() -> void: call_deferred("_run")
func check(ok: bool, message: String) -> void:
	if not ok:
		failures += 1
		push_error(message)
func _run() -> void:
	var world := Node3D.new()
	root.add_child(world)
	current_scene = world
	var floor_body := StaticBody3D.new()
	var collision := CollisionShape3D.new()
	var shape := BoxShape3D.new()
	shape.size = Vector3(150, 1, 150)
	collision.shape = shape
	floor_body.position.y = -0.5
	floor_body.add_child(collision)
	world.add_child(floor_body)
	var player: CharacterBody3D = load("res://scenes/player.tscn").instantiate()
	player.position = Vector3(0, 1.05, -7)
	world.add_child(player)
	var spawner := Node.new()
	spawner.set_script(Spawner)
	world.add_child(spawner)
	var boss: CharacterBody3D = spawner.spawn_boss("sediment_titan", Vector3.ZERO)
	boss.ai_enabled = false
	boss.prepare_sparring_phase("front")
	boss.target = player
	for _i in range(6): await physics_frame
	player.set_physics_process(false)
	player.health = 100000.0
	boss._tuning.rage_bullet_hitstop_interval = 0.35
	boss._tuning.rage_shot_movement_armor = false
	FX.hitstop(boss, 0.028)
	check(boss._grenade_pause.remaining > 0.0 and boss._bullet_hitstop_remaining == 0.0, "前半原枪击反馈保持，狂暴间隔不提前生效")
	for _i in range(4): await physics_frame
	# 阶段直入只允许首次SPAWN；在已开战的前半通过真实半血转换。
	boss.take_damage(float(boss.max_hp) * 3.0)
	check(boss.is_enraged and boss.current_state != boss.State.DEAD, "盾减伤后真实半血进入狂暴")
	for _i in range(60): await physics_frame
	var before: float = boss._brain.elapsed
	for i in range(84):
		if i % 6 == 0: FX.hitstop(boss, 0.028)
		await physics_frame
	var lost := 1.4 - (float(boss._brain.elapsed) - before)
	check(lost > 0.05 and lost < 0.22, "10Hz连续普通枪仍有顿帧反馈，但不持续拖慢狂暴动作")
	FX.hitstop(boss, 0.028)
	boss.apply_grenade_stagger(0.25)
	check(boss._grenade_pause.remaining >= 0.249, "E完整0.25秒硬直绕过普通枪限频，不能被吞")
	var cooldown: float = boss._bullet_hitstop_remaining
	paused = true
	for _i in range(6): await process_frame
	check(is_equal_approx(cooldown, float(boss._bullet_hitstop_remaining)), "暂停冻结枪击顿帧间隔")
	paused = false
	for _i in range(20): await physics_frame
	boss._tuning.rage_shot_movement_armor = true
	before = boss._brain.elapsed
	for i in range(42):
		if i % 6 == 0: FX.hitstop(boss, 0.028)
		await physics_frame
	check(float(boss._brain.elapsed) - before > 0.68 and boss._grenade_pause.remaining == 0.0, "狂暴移动阶段连续枪击不再刹停，仍走正式局部受击入口")
	boss.apply_grenade_stagger(0.25)
	check(boss._grenade_pause.remaining >= 0.249, "移动抗枪击停顿仍受E战术硬直")
	for _i in range(20): await physics_frame
	boss._tuning.rage_heavy_recovery_scale = 0.5
	boss.trigger_slam_attack()
	boss._tuning.rage_heavy_recovery_scale = 1.0
	boss._bullet_hitstop_remaining = 0.0
	FX.hitstop(boss, 0.028)
	check(boss._grenade_pause.remaining > 0.0, "招式中仍保留限频的普通枪顿帧，不是全程动作免疫")
	var recovery_start := -1
	for _i in range(400):
		await physics_frame
		if boss._heavy_recovering and recovery_start < 0: recovery_start = Engine.get_physics_frames()
		if boss.current_state == boss.State.IDLE: break
	var recovery_seconds := float(Engine.get_physics_frames() - recovery_start) / 60.0
	check(recovery_start >= 0 and recovery_seconds >= 1.16 and recovery_seconds < 1.4, "狂暴新1.2秒完整收势按起手快照，运行改值不改变已公布窗口")
	check(not boss.has_mud_shield, "增加压力不恢复狂暴泥盾")
	var hp: float = boss.health
	boss.take_damage(100.0)
	check(is_equal_approx(hp - float(boss.health), 100.0), "普通身体承伤保持1倍")

	var pressure_samples := [
		{"time": 0.0, "state": 2, "diagnostic": {}},
		{"time": 1.0, "state": 9, "diagnostic": {"heavy_recovering": true}},
		{"time": 3.4, "state": 13, "diagnostic": {"break_reward": {"kind": "down"}}}]
	for sample: Dictionary in pressure_samples: sample["opponents"] = [{"implementation": "titan"}]
	var metrics := preload("res://tools/probes/sparring/sparring_pressure_analysis.gd").summarize(pressure_samples, [], [], 11.4)
	check(is_equal_approx(metrics.heavy_recovery_seconds, 2.4) and is_equal_approx(metrics.reward_seconds, 8.0) and is_equal_approx(metrics.chase_idle_seconds, 1.0), "压力统计明确分开追击、完整后摇与挣得奖励")
	check(metrics.front_shield_coverage.status == "unknown_missing_opponent_shield", "旧快照缺盾字段不能伪造常驻覆盖率")
	for sample: Dictionary in pressure_samples:
		sample.opponents[0].merge({"rage": int(sample.state) == 13, "mud_shield": int(sample.state) != 13})
	metrics = preload("res://tools/probes/sparring/sparring_pressure_analysis.gd").summarize(pressure_samples, [], [], 11.4)
	check(is_equal_approx(metrics.front_shield_coverage.active_seconds, 3.4) and metrics.front_shield_coverage.fraction == 1.0, "前半盾覆盖排除真实倒地奖励，不能把狂暴无盾算漏洞")
	check(preload("res://tools/probes/sparring/sparring_pressure_analysis.gd").summarize([{"time": 0, "state": 9}], [], [], 3).status == "insufficient_diagnostic_snapshots", "简化时间线缺原因数据必须报未知，不能伪报后摇／暂停为零")
	check(preload("res://tools/probes/sparring/sparring_pressure_analysis.gd").summarize([{"time": 0, "state": -1, "diagnostic": {}, "opponents": [{"implementation": "roster_ranged"}]}], [], [], 3).status == "unsupported_pressure_model", "普通射手未知编号不伪报泰坦各项0秒；通用陪练保留自身逐对象分析")
	current_scene = null
	world.queue_free()
	for _i in range(8): await process_frame
	preload("res://scripts/object_pool.gd").clear_all()
	await preload("res://tools/probes/sparring/sparring_runtime.gd").settle_audio(self)
	print("[泰坦压力] failures=", failures)
	quit(1 if failures else 0)
