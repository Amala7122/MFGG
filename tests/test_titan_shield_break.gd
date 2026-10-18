extends SceneTree
## A4.2真实E三投；高血量测试靶只验机制，不生成难度结论。
const Player := preload("res://scenes/player.tscn")
const Spawner := preload("res://scripts/enemy_spawner.gd")
const Artifacts := preload("res://scripts/artifact_paths.gd")
var failures := 0
func _initialize() -> void:
	call_deferred("_run")
func check(ok: bool, text: String) -> void:
	if not ok:
		failures += 1
		push_error(text)
func frames(count: int) -> void:
	for _i in range(count):
		await physics_frame
func press(player: Node) -> void:
	player.set_physics_process(true)
	var event := InputEventAction.new()
	event.action = "grenade"
	event.pressed = true
	Input.parse_input_event(event)
	Input.flush_buffered_events()
	await physics_frame
	event = InputEventAction.new()
	event.action = "grenade"
	Input.parse_input_event(event)
	Input.flush_buffered_events()
	await physics_frame
func _run() -> void:
	var world := Node3D.new()
	root.add_child(world)
	current_scene = world
	var ground := StaticBody3D.new()
	var c := CollisionShape3D.new()
	var shape := BoxShape3D.new()
	shape.size = Vector3(100, 1, 100)
	c.shape = shape
	ground.position.y = -0.5
	ground.add_child(c)
	world.add_child(ground)
	var player: CharacterBody3D = Player.instantiate()
	player.position = Vector3(0, 1.05, 7)
	world.add_child(player)
	var spawner := Node.new()
	spawner.set_script(Spawner)
	world.add_child(spawner)
	var boss: Node3D = spawner.spawn_boss("sediment_titan", Vector3.ZERO)
	boss.ai_enabled = false
	check(boss.prepare_sparring_phase("front"), "前半有盾准备")
	await frames(5)
	for hit in range(1, 4):
		await press(player)
		for _i in range(90):
			await physics_frame
			if boss._shield_hits == hit:
				break
		check(boss._shield_hits == hit, "真实E第%d投接触起爆计数" % hit)
		if hit < 3:
			check(boss.has_mud_shield and boss._reward_kind.is_empty(), "前两枚不破盾")
			check(boss._shield_cracks[0].visible, "有效命中显示裂纹")
			var hp: float = boss.health
			var token: int = boss._shield_explosions.keys()[0]
			boss.receive_grenade_contact(95.0, token, {})
			check(boss._shield_hits == hit and float(boss.health) == hp, "同一爆炸去重，不重复伤害或计数")
			boss._remove_mud_shield()
			boss.take_damage(10)
			check(boss._shield_hits == hit, "普通枪及主动卸盾不清累计进度")
			boss._activate_mud_shield()
			await frames(80)
	check(not boss.has_mud_shield and boss._reward_kind == "kneel", "第三枚换取跪地且无泥盾")
	check(player.get_grenade_status().charges == 0, "三枚均真实消耗库存，无赠送")
	for _i in range(120):
		if boss.current_state == boss.State.REWARD_HOLD:
			break
		await physics_frame
	check(boss.current_state == boss.State.REWARD_HOLD, "倒稳后才进入有效跪地")
	var start := Engine.get_physics_frames()
	var before: float = boss.health
	boss.take_damage(100)
	check(is_equal_approx(before - float(boss.health), 100.0), "跪地是正常无盾伤害，不提前赠倍伤")
	boss.current_hp = boss.max_hp * 0.49
	boss._trigger_rage()
	check(not boss.is_enraged and boss._pending_rage, "半血保留已挣得奖励，延后狂暴")
	boss.on_resonance_incoming(Vector3.ZERO)
	check(not boss.has_mud_shield, "共鸣不覆盖长奖励")
	paused = true
	var elapsed: float = boss._reward_elapsed
	for _i in range(8):
		await process_frame
	check(float(boss._reward_elapsed) == elapsed, "暂停冻结跪地计时")
	paused = false
	start = Engine.get_physics_frames()
	boss.apply_grenade_stagger(0.25)
	for _i in range(300):
		await physics_frame
		if boss.current_state != boss.State.REWARD_HOLD:
			break
	var seconds := float(Engine.get_physics_frames() - start) / 60.0
	check(seconds >= 3.95 and seconds < 4.1, "有效4秒不含过渡且不叠短硬直")
	await frames(55)
	check(boss.is_enraged and not boss.has_mud_shield and boss._reward_kind.is_empty(), "完整起身后再狂暴，保持无盾")
	# 未直接触敌的范围爆炸、Q都不计盾进度；另一轮前半奖励结束后正常再生。
	var second: Node3D = spawner.spawn_boss("sediment_titan", Vector3(25, 0, 0))
	second.ai_enabled = false
	second.prepare_sparring_phase("front")
	await frames(5)
	var grenade := preload("res://scripts/grenade.gd").new()
	world.add_child(grenade)
	grenade.global_position = second.global_position + Vector3(0, 0, 4)
	grenade.explode()
	check(second._shield_hits == 0 and second.has_mud_shield, "只有范围波及不算触盾有效爆炸")
	preload("res://scripts/combat_telemetry.gd").hurt_enemy(second, 10, {"source": "Q"})
	check(second.has_mud_shield and second._shield_hits == 0, "正式方案Q不再解除泥盾")
	for token in [201, 202, 203]:second.receive_grenade_contact(10, token, {})
	await frames(330)
	check(second.has_mud_shield and second._shield_hits == 0 and second._reward_kind.is_empty(), "前半完整起身后再生盾并清零下一轮")
	for token in [211, 212, 213]:second.receive_grenade_contact(10, token, {})
	second.take_damage(10000000)
	await frames(8)
	check(not is_instance_valid(second), "跪地中死亡优先，后续状态不复活")
	var file := FileAccess.open(Artifacts.ensure_dir("reports", "shield_break").path_join("result.json"), FileAccess.WRITE)
	file.store_string(JSON.stringify({"failures": failures, "effective_hold_seconds": seconds, "real_E": 3}, "\t"))
	file.close()
	current_scene = null
	world.queue_free()
	await frames(5)
	preload("res://scripts/object_pool.gd").clear_all()
	await preload("res://tools/probes/sparring/sparring_runtime.gd").settle_audio(self)
	print("[A4.2三雷破盾] failures=", failures)
	quit(1 if failures else 0)
