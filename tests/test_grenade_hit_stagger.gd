extends SceneTree
const Lab := preload("res://prototypes/spatial_lab/combat_spatial_lab.tscn")
const FX := preload("res://scripts/combat_fx.gd")
const LegacyBoss := preload("res://scripts/boss.gd")
var _failures := 0

func _initialize() -> void:
	call_deferred("_run")

func _check(ok: bool, message: String) -> void:
	if not ok:
		_failures += 1
		push_error(message)

func _run() -> void:
	var lab := Lab.instantiate()
	root.add_child(lab)
	current_scene = lab
	for _frame in range(8):
		await process_frame
	lab._crowd_motion.button_pressed = false
	lab.set_selection({lab.SEDIMENT_TITAN_ID: 1, lab.MUD_GOLEM_ID: 1, lab.FAST_BEAST_ID: 1, lab.HORNET_ID: 1})
	await lab.generate_round()
	lab._start_fight()
	var titan: CharacterBody3D
	var others: Array[CharacterBody3D] = []
	for actor: CharacterBody3D in lab._live_enemies:
		actor.ai_enabled = false
		if actor.has_method("grenade_stagger_active"):
			titan = actor
		else:
			others.append(actor)
	for _frame in range(220):
		await physics_frame
	var melee := preload("res://scenes/melee_enemy.tscn").instantiate()
	var ranged := preload("res://scenes/ranged_enemy.tscn").instantiate()
	melee.position = Vector3(10, 1.1, 0)
	ranged.position = Vector3(-10, 1.1, 0)
	lab.add_child(melee)
	lab.add_child(ranged)
	melee.target = lab._player
	ranged.target = lab._player
	for _frame in range(4):
		await physics_frame
	melee._attack_elapsed = 0.0
	ranged.attack_queued = true
	# 没有推力仍须真正硬直；默认径向接口不擅自赋予新时长。
	FX.apply_radial_damage(lab._player, Vector3.ZERO, 200.0, 0.01, 0.0, false, null, 0.6, 0.25)
	_check(melee._attack_elapsed < 0.0 and ranged.attack_queued == false, "手雷实际取消近战攻击与远程蓄力")
	_check(melee._stagger_time >= 0.59 and ranged._stagger_time >= 0.59, "无推力也能赋予通用0.6秒硬直")
	for actor: CharacterBody3D in others:
		var state: int = actor.current_state
		_check(state == actor.State.STAGGER if actor.get_script().resource_path.ends_with("procedural_mud_golem.gd") else state == actor.State.HIT_STAGGER, "泥土傀儡、晶兽、蜂进入自身实际受击状态")
	for _frame in range(20):
		await physics_frame
	_check(melee._stagger_time > 0.2 and ranged._stagger_time > 0.2 and not ranged.attack_queued, "普通敌人硬直中不能重新出招")
	melee.apply_grenade_stagger(0.6)
	_check(melee._stagger_time <= 0.601, "重复爆炸刷新时长，不将多枚硬直相加")
	# 使用泰坦的真实物理Tween与攻击区域，不能只测一个计时字段。
	titan._stop_action()
	titan.current_state = titan.State.IDLE
	titan.target = lab._player
	titan.attack_cooldown = 0.0
	titan._brain.cooldowns["slam"] = 0.0
	titan._grenade_pause.remaining = 0.0
	titan.trigger_slam_attack()
	_check(titan.current_state == titan.State.ATK_SLAM, "真实砸地能开始")
	await physics_frame
	var pose: Vector3 = titan.right_arm_pivot.rotation
	var progress: float = titan._attack_area.progress
	var state: int = titan.current_state
	titan.apply_grenade_stagger(0.25)
	for _frame in range(8):
		await physics_frame
	_check(titan.current_state == state and titan.right_arm_pivot.rotation.is_equal_approx(pose), "Boss短硬直同时暂停真实动作，不丢原招式")
	_check(is_equal_approx(titan._attack_area.progress, progress), "攻击预警与动作一起暂停")
	paused = true
	var remaining: float = titan._grenade_pause.remaining
	for _frame in range(4):
		await process_frame
	_check(is_equal_approx(remaining, titan._grenade_pause.remaining), "暂停菜单不消耗硬直")
	paused = false
	for _frame in range(30):
		await physics_frame
	_check(not titan.grenade_stagger_active() and not titan.right_arm_pivot.rotation.is_equal_approx(pose), "结束后原动作继续，非永久冻结")
	titan._stop_action()
	titan.current_state = titan.State.IDLE
	titan._brain.cooldowns["leap"] = 0.0
	titan.attack_cooldown = 0.0
	titan.position = Vector3(0, titan.get_stand_height(), -3)
	lab._player.position = Vector3(0, 1.08, 10)
	for _frame in range(5):
		await physics_frame
	if titan.trigger_leap_attack():
		for _frame in range(120):
			await physics_frame
			if titan.current_state == titan.State.LEAP_AIR:
				break
		titan.apply_grenade_stagger(0.25)
		var air_position: Vector3 = titan.global_position
		for _frame in range(4):
			await physics_frame
		_check(not titan.global_position.is_equal_approx(air_position) and not titan.grenade_stagger_active(), "空中命中继续飞行与落地，不悬停")
		var deferred := false
		for _frame in range(150):
			await physics_frame
			deferred = deferred or titan.grenade_stagger_active()
		_check(deferred, "落地后兑现完整短硬直")
	else:
		_check(false, "测试必须成功发起真实空中动作")
	var old := LegacyBoss.new()
	lab.add_child(old)
	old.configure("unused_test_boss")
	old._step = old.Step.WINDUP
	old._step_timer = 0.7
	old._spawn_slam_warning(0.7)
	var warning_timer: float = old._warning.timer
	old.apply_grenade_stagger(0.25)
	for _frame in range(6):
		await physics_frame
	_check(is_equal_approx(old._step_timer, 0.7) and is_equal_approx(old._warning.timer, warning_timer), "旧Boss行为计时和独立落点预警同时暂停")
	# 致死爆炸后的短硬直不能复活对象或重开动作。
	titan.take_damage(1000000000.0)
	if is_instance_valid(titan):
		titan.apply_grenade_stagger(0.25)
		_check(not titan.grenade_stagger_active(), "死亡优先于短硬直")
	current_scene = null
	lab.queue_free()
	await process_frame
	preload("res://scripts/object_pool.gd").clear_all()
	await preload("res://tools/probes/sparring/sparring_runtime.gd").settle_audio(self)
	print("[手雷真实硬直] failures=", _failures)
	quit(1 if _failures else 0)
