extends SceneTree
## A6真实第三枪接完整倒地，核对实际姿态命中、5秒与最终倍伤。
const Spawner := preload("res://scripts/enemy_spawner.gd")
const Weapon := preload("res://scripts/player_weapon.gd")
class PracticeTarget extends CharacterBody3D:
	var health := 10000.0
	func take_damage(amount: float) -> void:
		health -= amount
var failures := 0
var boss: Node3D
var weapon: Node
var camera: Camera3D
var rig: Node3D
var signals_received := 0
func _initialize() -> void:
	call_deferred("_run")
func check(ok: bool, text: String) -> void:
	if not ok:
		failures += 1
		push_error(text)
func frames(count: int) -> void:
	for _i in range(count):await physics_frame
func aim(point: Vector3) -> void:
	camera.global_position = Vector3(0, point.y, 22)
	rig.global_position = Vector3(0, point.y, 20)
	camera.look_at(point)
func shoot(point: Vector3, sniper := true) -> void:
	aim(point)
	weapon._aiming = sniper
	weapon.fire()
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
	var host := CharacterBody3D.new()
	host.position = Vector3(0, 1, 20)
	world.add_child(host)
	rig = Node3D.new()
	host.add_child(rig)
	var muzzle := Node3D.new()
	muzzle.position.z = -0.8
	rig.add_child(muzzle)
	camera = Camera3D.new()
	world.add_child(camera)
	weapon = Weapon.new()
	host.add_child(weapon)
	weapon._host = host
	weapon._weapon_rig = rig
	weapon._muzzle = muzzle
	weapon._camera = camera
	weapon._sniper_ammo = 5
	weapon._ammo = 20
	weapon.base_spread_degrees = 0.0
	var spawner := Node.new()
	spawner.set_script(Spawner)
	world.add_child(spawner)
	boss = spawner.spawn_boss("sediment_titan", Vector3.ZERO)
	boss.ai_enabled = false
	boss._tuning.crystal_break_enabled = true
	boss._tuning.down_reward_enabled = true
	check(boss.prepare_sparring_phase("rage"), "直入狂暴用于晶体验证")
	boss.crystal_broken.connect(func(_enemy): signals_received += 1)
	await frames(5)
	check(not boss.has_meta(&"combat_recorder"), "没有记录器也正确判部位与狙击来源")
	for hit in range(1, 4):
		shoot(boss.core_mesh.global_position)
		check(boss._crystal_hits == hit, "真实第%d次晶体狙击有效" % hit)
		if hit < 3:await frames(302)
	check(signals_received == 1 and boss._reward_kind == "down", "第三枪同次触发倒下，无多余5秒保护")
	check(boss.current_state == boss.State.REWARD_LOWER, "倒下与有效倒地分开")
	var before: float = boss.health
	boss.take_damage(100)
	check(is_equal_approx(before - float(boss.health), 100.0), "尚未倒稳不提前倍伤")
	await frames(47)
	check(boss.current_state == boss.State.REWARD_LOWER, "0.5秒过渡前尚未开始5秒")
	await frames(2)
	check(boss.current_state == boss.State.REWARD_HOLD and boss.is_on_floor(), "安全接地倒稳才兑现有效窗口")
	var elapsed_start: float = boss._reward_elapsed
	var clock := Engine.get_physics_frames()
	boss.rage_incoming_multiplier = 1.5 # 反证旧倍率不可乘成三倍。
	before = boss.health
	boss.take_damage(100)
	check(is_equal_approx(before - float(boss.health), 200.0), "100输入最终扣200，覆盖旧狂暴1.5而非乘成300")
	boss.rage_incoming_multiplier = 1.0
	var point: Vector3 = boss._reward_body_area.global_position
	aim(point)
	var hits: Array = weapon._resolve_shot_hits(-camera.global_basis.z, true)
	check(hits.size() == 1 and hits[0].collider == boss, "倒地真实命中体随姿态移动，穿透按唯一Boss去重")
	if not hits.is_empty():
		before = boss.health
		weapon._fire_hitscan(-camera.global_basis.z, true)
		check(absf(before - float(boss.health) - float(hits[0].amount) * 2.0) < 0.01, "实际枪线命中倒地身体，单发只结算一次×2")
	check(boss.is_physics_processing(), "真实枪击不关闭整个Boss更新，不延长5秒")
	boss._tuning.down_hold_seconds = 2.0
	check(float(boss._reward_durations.hold) == 5.0, "已开始窗口快照不被运行改值缩短")
	boss.apply_grenade_stagger(.8)
	boss.on_resonance_incoming(Vector3.ZERO)
	check(not boss.has_mud_shield and boss._grenade_pause.remaining == 0.0, "倒地不叠手雷硬直，共鸣不加泥盾")
	paused = true
	var elapsed: float = boss._reward_elapsed
	for _i in range(8):await process_frame
	check(float(boss._reward_elapsed) == elapsed, "暂停冻结有效倒地")
	paused = false
	clock = Engine.get_physics_frames()
	for _i in range(500):
		await physics_frame
		if boss.current_state != boss.State.REWARD_HOLD:break
	var active_seconds := float(Engine.get_physics_frames() - clock) / 60.0 + elapsed_start
	check(absf(active_seconds - 5.0) < .06, "完整5秒不含倒下／起身，不叠短暂停顿")
	before = boss.health
	boss.take_damage(100)
	check(is_equal_approx(before - float(boss.health), 100.0), "5秒结束立即恢复常态承伤")
	check(boss.current_state == boss.State.REWARD_RISE, "起身阶段仍不能起招")
	await frames(74)
	check(boss._reward_kind.is_empty() and boss._crystal_hits == 0 and not boss._crystal_break_pending, "站稳重置晶体与闪光，可以开始下一轮")
	check(boss.collision_layer == 4 and boss._reward_body_area.collision_layer == 0, "起身恢复原身体碰撞，没有遗留倒地命中体")
	boss._tuning.down_hold_seconds = 5.0
	# 已在空中的真实跃击，第三枪不能使其悬停或残留落地伤害。
	boss._brain.cooldowns.leap = 0.0
	boss._brain.approach_remaining = 0.0
	var target := PracticeTarget.new()
	target.collision_layer = 2
	target.collision_mask = 1
	var target_collision := CollisionShape3D.new()
	var target_shape := CapsuleShape3D.new()
	target_shape.radius = .35
	target_shape.height = 2.0
	target_collision.shape = target_shape
	target.add_child(target_collision)
	target.position = boss.global_position + Vector3(0, -1.75, -15)
	world.add_child(target)
	boss.target = target
	var launched: bool = boss.trigger_leap_attack()
	print("[A6空中前置] launched=", launched, " floor=", boss.is_on_floor(), " state=", boss.current_state, " rejection=", boss._leap_plan_failure)
	check(launched, "真实合法跃击可开始")
	for _i in range(120):
		await physics_frame
		if boss.current_state == boss.State.LEAP_AIR:break
	boss._crystal_hits = 2 # 独立构造空中第三次的前置进度，命中仍用真实射线。
	await frames(4)
	aim(boss.core_mesh.global_position)
	print("[A6空中枪线] ", weapon._resolve_shot_hits(-camera.global_basis.z, true), " ammo=", weapon.get_sniper_ammo(), " guard=", boss._crystal_guard_remaining)
	shoot(boss.core_mesh.global_position)
	print("[A6空中命中] hits=", boss._crystal_hits, " state=", boss.current_state, " pending=", boss._pending_reward)
	check(boss._pending_reward == "down" and boss.current_state == boss.State.LEAP_AIR, "空中第三枪保留真实飞行，暂不开始奖励")
	for _i in range(180):
		await physics_frame
		if not boss._reward_kind.is_empty():break
	check(boss.is_on_floor() and boss._reward_kind == "down", "接地后才开始倒下")
	check(not boss._leap_followup_armed, "空中第三枪已挣得倒地必须取消新落地追击")
	check(boss._attack_area.phase == boss.AttackArea.Phase.IDLE, "原落地判定取消，无残留伤害")
	var expected := preload("res://tools/probes/sparring/sparring_enemy_adapter.gd").sample(boss, "reward_contract")
	var changed: Dictionary = expected.duplicate(true)
	changed.diagnostic.break_reward.crystal_hits += 1
	var capture_script := preload("res://tools/probes/sparring/sparring_capture.gd")
	check(capture_script._opponent_difference([changed], [expected]).get("kind") == "break_reward", "重放能识别只有破解进度不同的首次偏离")
	expected.diagnostic.erase("break_reward")
	check(capture_script._opponent_difference([changed], [expected]).is_empty(), "旧记录缺破解状态时不伪造该项偏离")
	boss.take_damage(10000000)
	await frames(100)
	check(not is_instance_valid(boss), "奖励中死亡优先，旧回调不能重生或发下轮")
	current_scene = null
	world.queue_free()
	await frames(8)
	preload("res://scripts/object_pool.gd").clear_all()
	await preload("res://tools/probes/sparring/sparring_runtime.gd").settle_audio(self)
	print("[A6倒地倍伤] failures=", failures)
	quit(1 if failures else 0)
