extends SceneTree
## A5诊断开启晶体，真实fire/两阶段射线/弹药。无记录器也须工作。
const Spawner := preload("res://scripts/enemy_spawner.gd")
const Weapon := preload("res://scripts/player_weapon.gd")
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
	boss._tuning.down_reward_enabled = false # A5独立诊断止于第三击事件，A6另测完整奖励。
	check(boss.prepare_sparring_phase("rage"), "直入狂暴用于晶体验证")
	boss.crystal_broken.connect(func(_enemy): signals_received += 1)
	await frames(5)
	check(not boss.has_meta(&"combat_recorder"), "没有记录器也正确判部位与狙击来源")
	shoot(boss.core_mesh.global_position, false)
	check(boss._crystal_hits == 0, "普通步枪打晶体不冒充狙击")
	shoot(boss.global_position)
	check(boss._crystal_hits == 0, "真实狙击躯干不增加晶体计数")
	aim(boss.core_mesh.global_position)
	var hits: Array = weapon._resolve_shot_hits(-camera.global_basis.z, true)
	check(hits.size() == 1 and hits[0].hit_region == "crystal", "真实碰撞形状识别晶体，不按高度猜测")
	shoot(boss.core_mesh.global_position)
	check(boss._crystal_hits == 1 and boss._crystal_guard_remaining == 5.0, "第一枪真实晶体破击，保护5秒")
	await frames(2)
	var back_target := CharacterBody3D.new()
	back_target.collision_layer = 4
	back_target.add_to_group("enemies")
	var back_collision := CollisionShape3D.new()
	var back_shape := BoxShape3D.new()
	back_shape.size = Vector3(3, 3, 1)
	back_collision.shape = back_shape
	back_target.add_child(back_collision)
	world.add_child(back_target)
	back_target.global_position = boss.core_mesh.global_position + Vector3(0, 0, -5)
	await frames(2)
	aim(boss.core_mesh.global_position)
	var guarded_hits: Array = weapon._resolve_shot_hits(-camera.global_basis.z, true)
	check(guarded_hits.size() == 1 and guarded_hits[0].collider == boss, "护罩阻止整发穿透，后方对象不被继续收集")
	back_target.queue_free()
	var hp: float = boss.health
	var remaining: float = boss._crystal_guard_remaining
	shoot(boss.core_mesh.global_position)
	check(float(boss.health) == hp and boss._crystal_hits == 1, "真实护罩命中无伤害、不穿到同一身体")
	check(float(boss._crystal_guard_remaining) == remaining, "误射不刷新保护时长")
	boss.take_damage(100)
	check(is_equal_approx(hp - float(boss.health), 100.0), "晶体罩期间身体照常承伤，狂暴常态×1")
	paused = true
	for _i in range(8):await process_frame
	check(float(boss._crystal_guard_remaining) == remaining, "暂停冻结晶体保护")
	paused = false
	boss.apply_grenade_stagger(.25)
	await frames(30)
	check(absf(float(boss._crystal_guard_remaining) - (remaining - .5)) < .04, "短硬直不延长晶体保护时钟")
	while boss._crystal_guard_remaining > .04:await physics_frame
	check(boss._crystal_guard_visual.visible, "保护结束前仍显示护罩")
	await frames(3)
	check(boss._crystal_guard_remaining == 0.0 and not boss._crystal_guard_visual.visible, "5秒边界后护罩消退且持续开放")
	shoot(boss.core_mesh.global_position)
	check(boss._crystal_hits == 2, "第二次真实晶体狙击有效")
	await frames(302)
	shoot(boss.core_mesh.global_position)
	check(boss._crystal_hits == 3 and signals_received == 1 and boss._crystal_break_pending, "第三枪产生唯一倒地请求事件")
	check(weapon.get_sniper_ammo() == 0, "实际5发均消耗，不用无限弹证明3次有效命中")
	check(boss._crystal_guard_remaining == 0.0, "第三次不额外等待保护")
	current_scene = null
	world.queue_free()
	await frames(8)
	preload("res://scripts/object_pool.gd").clear_all()
	await preload("res://tools/probes/sparring/sparring_runtime.gd").settle_audio(self)
	print("[A5晶体保护] failures=", failures)
	quit(1 if failures else 0)
