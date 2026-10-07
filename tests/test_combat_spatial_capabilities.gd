extends SceneTree
## 真正移动身体验证可赋予能力、返程预留及墙顶接战；没有测试瞬移执行器。
const Actor := preload("res://prototypes/combat/spatial/traversal_actor.gd")
const Profile := preload("res://scripts/combat_spatial_profile.gd")
const Capability := preload("res://scripts/traversal_capability.gd")
const Query := preload("res://scripts/spatial_query.gd")
const Link := preload("res://scripts/spatial_traversal_link.gd")
const Surface := preload("res://scripts/surface_traversal.gd")
const Prop := preload("res://scripts/destructible_prop.gd")
class TestTarget extends CharacterBody3D:
	var health := 10000.0
	var hits := 0
	var camera: Camera3D
	func take_damage(amount: float, _at: Vector3, _shield_scale: float) -> void:
		health -= amount
		hits += 1
var stage: Node3D
var failed := false

func _initialize() -> void:
	call_deferred("run")

func run() -> void:
	for i in range(8):
		await process_frame
	paused = false
	await _jump_obstacle()
	await _pit(1.0, true)
	await _pit(5.0, false)
	await _pit(5.0, false, true)
	await _forced_fall(true)
	await _forced_fall(false)
	await _break_obstacle()
	await _climb()
	await _formal_enemies()
	await _boss_breach()
	await _demo_scene()
	current_scene = null
	stage.free()
	print("[T03 能力] ", "FAIL" if failed else "PASS")
	quit(1 if failed else 0)

func _stage() -> void:
	if is_instance_valid(stage):
		stage.free()
	stage = Node3D.new()
	stage.process_mode = Node.PROCESS_MODE_ALWAYS
	stage.position.x = 100
	root.add_child(stage)
	current_scene = stage

func _box(at: Vector3, size: Vector3) -> StaticBody3D:
	var object := StaticBody3D.new()
	object.position = at
	object.collision_layer = 1
	object.collision_mask = 0
	var collision := CollisionShape3D.new()
	var shape := BoxShape3D.new()
	shape.size = size
	collision.shape = shape
	object.add_child(collision)
	stage.add_child(object)
	return object

func _target(at: Vector3) -> CharacterBody3D:
	var object := TestTarget.new()
	object.position = at
	object.collision_layer = 2
	object.collision_mask = 1
	var collision := CollisionShape3D.new()
	var shape := CapsuleShape3D.new()
	shape.radius = 0.3
	shape.height = 1.8
	collision.shape = shape
	object.add_child(collision)
	stage.add_child(object)
	return object

func _profile(kind: Capability.Kind) -> Resource:
	var settings := Profile.new()
	settings.preserve_ground_style = false
	var walk := Capability.new()
	walk.travel_speed = 3.0
	settings.capabilities.append(walk)
	if kind != Capability.Kind.WALK:
		var item := Capability.new()
		item.kind = kind
		item.id = &"jump" if kind == Capability.Kind.JUMP else &"break" if kind == Capability.Kind.BREAK else &"climb"
		item.max_distance = 14
		item.max_rise = 2
		item.max_drop = 6
		item.travel_speed = 6 if kind == Capability.Kind.JUMP else 3.0
		item.max_flight = 1.0
		item.cooldown = 0.4
		item.windup = 0.2
		item.power = 2
		settings.capabilities.append(item)
	settings.max_escape_wait = 0.5
	return settings

func _actor(at: Vector3, target: Node3D, settings: Resource) -> CharacterBody3D:
	var actor := Actor.new()
	actor.position = at
	actor.target = target
	actor.combat_spatial_profile = settings
	stage.add_child(actor)
	return actor

func _wait(frames: int) -> void:
	for i in range(frames):
		await physics_frame

func _jump_obstacle() -> void:
	_stage()
	_box(Vector3(0, -0.5, 0), Vector3(18, 1, 8))
	_box(Vector3(0, 0.35, 0), Vector3(0.5, 0.7, 8))
	var target := _target(Vector3(4, 0.9, 0))
	var actor := _actor(Vector3(-4, 0.65, 0), target, _profile(Capability.Kind.JUMP))
	var highest := 0.0
	var jumped := false
	for i in range(350):
		await physics_frame
		highest = maxf(highest, actor.position.y)
		jumped = jumped or actor.steering.spatial.last_action == "jump"
		if actor.hits > 0:
			break
	_check(jumped and highest > 1.4 and actor.position.x > 0.5 and actor.hits > 0, "真实跳过阻断地面路线的矮墙并接战 %s / %s" % [actor.position, actor.steering.spatial.last_failure])
	print("[T03 能力] 跳障碍 ", actor.position, " height=", highest, " hits=", actor.hits)

func _pit(depth: float, allowed: bool, insufficient_jump := false) -> void:
	_stage()
	_box(Vector3(-5, -0.5, 0), Vector3(6, 1, 10))
	_box(Vector3(5, -0.5, 0), Vector3(6, 1, 10))
	_box(Vector3(0, -depth - 0.5, 0), Vector3(4, 1, 10))
	var target := _target(Vector3(0, 0.9 - depth, 0))
	var actor := _actor(Vector3(-4, 0.65, 0), target, _profile(Capability.Kind.JUMP if allowed or insufficient_jump else Capability.Kind.WALK))
	await _wait(3)
	if allowed:
		var jump: Resource = actor.steering.spatial.ability(&"jump")
		var landing := Vector3(100, 0.6 - depth, 0)
		var excluded: Array[RID] = []
		_check(actor.steering.spatial.permit_landing(landing, &"jump", excluded, false), "消耗入坑技能后，返程冷却在预算内才允许下降")
		jump.cooldown = 2.0
		_check(not actor.steering.spatial.permit_landing(landing, &"jump", excluded, false), "入坑消耗会超出返程等待预算时拒绝下降")
		jump.cooldown = 0.4
	var lowest := actor.position.y
	for i in range(350):
		await physics_frame
		lowest = minf(lowest, actor.position.y)
		if OS.get_cmdline_user_args().has("--debug-t03") and allowed and i % 10 == 0:
			print("[T03 pit] ", i, " ", actor.position, " ", actor.velocity, " ", actor.steering.spatial.status, "/", actor.steering.spatial.last_failure, " active=", actor.steering.spatial._active)
		if allowed and actor.hits > 0:
			break
	if allowed:
		_check(actor.hits > 0 and lowest < 0.0, "有真实返程能力才下浅坑")
		_check(actor.steering.spatial.escape_reserved == &"jump" and not actor.steering.spatial.permits_channel(&"jump"), "坑内预留返程资源")
		target.position = Vector3(-4, 0.9, 0)
		for i in range(240):
			await physics_frame
			if actor.position.y > 0.6 and actor.is_on_floor():
				break
		_check(actor.is_on_floor() and actor.position.y > 0.6 and actor.steering.spatial.escape_reserved.is_empty(), "玩家出坑后真实跳出续追并释放预留")
	else:
		_check(lowest > 0.59 and actor.is_on_floor() and actor.position.x < -2.0, "无出口不主动进深坑，不能把坑顶投影当出口")
		_check(actor.position.distance_to(Vector3(-4, 0.65, 0)) > 1.0, "没有接战路线时离开坑边转移")
	print("[T03 能力] 坑 depth=", depth, " position=", actor.position, " lowest=", lowest, " status=", actor.steering.spatial.status, "/", actor.steering.spatial.last_failure)

func _break_obstacle() -> void:
	_stage()
	_box(Vector3(0, -0.5, 0), Vector3(18, 1, 8))
	var obstacle := Prop.new()
	obstacle.dimensions = Vector3(0.6, 3, 8)
	stage.add_child(obstacle)
	var target := _target(Vector3(4, 0.9, 0))
	var actor := _actor(Vector3(-4, 0.65, 0), target, _profile(Capability.Kind.BREAK))
	var telegraphed := false
	var intact_during_windup := false
	for i in range(300):
		await physics_frame
		if actor._break_target != null:
			telegraphed = true
			intact_during_windup = intact_during_windup or not obstacle.is_broken
		if actor.hits > 0:
			break
	_check(telegraphed and intact_during_windup and obstacle.is_broken and actor.hits > 0, "以物件为目的真实破障后接战，命中前不忽略碰撞")
	print("[T03 能力] 破障 ", actor.position, " broken=", obstacle.is_broken, " hits=", actor.hits)

func _forced_fall(can_escape: bool) -> void:
	_stage()
	_box(Vector3(-5, -0.5, 0), Vector3(6, 1, 10))
	_box(Vector3(5, -0.5, 0), Vector3(6, 1, 10))
	_box(Vector3(0, -1.5, 0), Vector3(4, 1, 10))
	var target := _target(Vector3(-4, 0.9, 0))
	var actor := _actor(Vector3(-4, 0.65, 0), target, _profile(Capability.Kind.JUMP if can_escape else Capability.Kind.WALK))
	await _wait(5)
	actor.set_physics_process(false)
	# 外界推力按真实重力和碰撞移动；不是主动策略，也不改写角色位置。
	actor.velocity = Vector3(5, 0, 0)
	for frame in range(50):
		await physics_frame
		actor.velocity.y -= 20.0 / 60.0
		actor.move_and_slide()
	actor.velocity.x = 0.0
	for frame in range(35):
		await physics_frame
		actor.velocity.y -= 20.0 / 60.0
		actor.move_and_slide()
	_check(actor.position.y < 0.0, "强制落坑必须保留真实物理后果")
	actor.set_physics_process(true)
	var trapped := false
	for frame in range(280):
		await physics_frame
		trapped = trapped or actor.steering.spatial.status == "trapped"
		if can_escape and actor.position.y > 0.59 and actor.is_on_floor(): break
	if can_escape:
		_check(actor.position.y > 0.59 and actor.is_on_floor(), "强制落坑后用实际可用能力跳出")
	else:
		_check(trapped and actor.position.y < 0.0 and actor.steering.spatial.last_action != "jump", "无出口的强制落坑明确受困，不瞬移或虚构跳跃")
	print("[T03 能力] 强制落坑 escape=", can_escape, " position=", actor.position, " trapped=", trapped)

func _climb() -> void:
	_stage()
	_box(Vector3(0, -0.5, 0), Vector3(14, 1, 8))
	var wall := _box(Vector3(0.25, 1.6, 0), Vector3(0.5, 3.2, 8))
	var ceiling := _box(Vector3(-2, 3.4, 0), Vector3(4, 0.4, 8))
	var target := _target(Vector3(-3, 1.35, 0))
	var settings := _profile(Capability.Kind.CLIMB)
	var actor := _actor(Vector3(-0.68, 0.65, 0), target, settings)
	actor.attack_reach = 1.25
	actor.attack_requires_attachment = true
	var link := Link.new()
	link.capability = &"climb"
	link.points = PackedVector3Array([Vector3(-0.68, 0.65, 0), Vector3(-0.68, 2.52, 0), Vector3(-0.68, 2.52, 0), Vector3(-1.3, 2.52, 0), Vector3(-3, 2.52, 0)])
	link.normals = PackedVector3Array([Vector3.LEFT, Vector3.LEFT, Vector3(-1, -1, 0).normalized(), Vector3.DOWN, Vector3.DOWN])
	stage.add_child(link)
	await _wait(4)
	# 强制此演示从附着连接接近；地面仍保留真实碰撞。
	actor.steering.spatial.bind({}, {"can_attack": func(): return actor.up_direction.dot(Vector3.DOWN) > 0.99 and actor._can_attack(),
		"attack_pose": func(pose: Transform3D): return pose.basis.y.normalized().dot(Vector3.DOWN) > 0.99 and actor._attack_pose(pose),
		"attached_action": actor._attached_attack})
	var plan := Surface.plan(actor, link.world_points(), link.world_normals(), actor.steering.spatial.ability(&"climb"), true)
	_check(not plan.is_empty(), "墙到天花板的净空、接触和转角有效")
	wall.set_meta(&"spatial_attachable", false)
	_check(Surface.plan(actor, link.world_points(), link.world_normals(), actor.steering.spatial.ability(&"climb"), true).is_empty(), "不允许附着的材质拒绝攀爬")
	wall.set_meta(&"spatial_attachable", true)
	var tilted := false
	for i in range(350):
		await physics_frame
		tilted = tilted or actor.up_direction.dot(Vector3.UP) < 0.5
		if actor.hits > 0:
			break
	_check(tilted and actor.up_direction.dot(Vector3.DOWN) > 0.99 and actor.hits > 0, "实际爬墙、转到天花板并在可命中姿态接战 %s / %s" % [actor.position, actor.steering.spatial.last_failure])
	wall.set_meta(&"spatial_attachable", false)
	print("[T03 能力] 攀附 ", actor.position, " up=", actor.up_direction, " hits=", actor.hits)
	ceiling.free()
	await _wait(20)
	_check(actor.up_direction.dot(Vector3.UP) > 0.99 and actor.position.y < 2.0, "附着面被移除后恢复真实坠落")

func _boss_breach() -> void:
	stage.free()
	stage = null
	var lab := preload("res://prototypes/combat/spatial/combat_spatial_lab.tscn").instantiate()
	root.add_child(lab)
	current_scene = lab
	for i in range(8): await process_frame
	lab._crowd_motion.button_pressed = false
	lab.set_selection({lab.SEDIMENT_TITAN_ID: 1})
	await lab.generate_round()
	stage = Node3D.new()
	stage.position.x = 100
	lab.add_child(stage)
	_box(Vector3(0, -0.5, 0), Vector3(18, 1, 8))
	var obstacle := Prop.new()
	obstacle.dimensions = Vector3(0.6, 3, 8)
	stage.add_child(obstacle)
	var enemy: CharacterBody3D = lab._live_enemies[0]
	enemy.ai_enabled = false
	enemy.position = Vector3(96, 1.78, 0)
	lab._player.position = Vector3(104, 1.08, 0)
	lab._start_fight()
	lab._player.process_mode = Node.PROCESS_MODE_DISABLED
	paused = false

	await _wait(250)
	enemy._tuning.leap_enabled = false
	enemy._tuning.mud_shield_enabled = false
	var controller: RefCounted = enemy._steering.spatial
	controller.bind(enemy._tuning, controller._bindings)
	_check(controller.ability(&"jump") == null, "已禁用的真实跃击不能作为通行或脱困能力")
	if OS.get_cmdline_user_args().has("--debug-t03"):
		Query.debug = true
		var planner: RefCounted = controller._planner(lab._player)
		for i in range(18): planner.advance(Time.get_ticks_usec() + 100000)
		print("[T03 boss plan] ", planner.result)
		Query.debug = false
	enemy.ai_enabled = true
	var windup_intact := false
	for i in range(650):
		await physics_frame
		if controller.last_action == "break" and enemy.current_state == enemy.State.ATK_SLAM and enemy._attack_area.phase == enemy._attack_area.Phase.PREPARE:
			windup_intact = windup_intact or not obstacle.is_broken
		if obstacle.is_broken and lab.get_stats_snapshot().received_hits > 0:
			break
	_check(windup_intact and obstacle.is_broken and lab.get_stats_snapshot().received_hits > 0, "真实泰坦以物件为目的施放砸地、破障后继续攻击玩家")
	print("[T03 能力] 泰坦破障 broken=", obstacle.is_broken, " hit=", lab.get_stats_snapshot().received_hits, " position=", enemy.position, " failure=", controller.last_failure)
	current_scene = null
	lab.free()
	stage = Node3D.new()
	root.add_child(stage)
	paused = false

func _formal_enemies() -> void:
	for packed: PackedScene in [preload("res://scenes/melee_enemy.tscn"), preload("res://scenes/ranged_enemy.tscn")]:
		_stage()
		_box(Vector3(0, -0.5, 0), Vector3(30, 1, 24))
		var target: TestTarget = _target(Vector3(0, 0.9, -4))
		target.add_to_group("player")
		target.camera = Camera3D.new()
		target.camera.position = Vector3(0, 3, -6)
		target.add_child(target.camera)
		target.camera.look_at(stage.global_position + Vector3(0, 1, 4))
		var enemy: CharacterBody3D = packed.instantiate()
		enemy.position = Vector3(0, 1.08, 4)
		stage.add_child(enemy)
		enemy.detection_range = 2.0
		await _wait(25)
		_check(enemy._steering.spatial._job == null and enemy._steering.spatial.route.is_empty(), "正式敌人空间接管遵守觉察距离")
		enemy.detection_range = 75.0
		enemy.rotation.y = PI
		for frame in range(480):
			await physics_frame
			if target.hits > 0: break
		_check(target.hits > 0, "正式角色保留实际追击、转向与攻击：" + enemy.name)
		print("[T03 能力] 正式角色 ", enemy.name, " hits=", target.hits, " at=", enemy.position)

func _check(condition: bool, message: String) -> void:
	if not condition:
		failed = true
		push_error("[T03 能力] " + message)

func _demo_scene() -> void:
	stage.free()
	var scene := preload("res://prototypes/combat/spatial/capability_lab.tscn").instantiate()
	root.add_child(scene)
	current_scene = scene
	for i in range(8): await process_frame
	await _wait(550)
	_check(scene._actors.size() == 5, "F6 能力演示场景创建五组真实角色")
	for index in [0, 1, 3, 4]:
		var actor: CharacterBody3D = scene._actors[index]
		_check(actor.hits > 0, "演示场景第 %d 组完成实际接战：%s / %s / %s" % [index, actor.position, actor.steering.spatial.status, actor.steering.spatial.last_failure])
	_check(scene._actors[2].hits == 0 and scene._actors[2].position.y > 0.59, "演示深坑组拒绝无出口下降")
	scene._pit_target.position = Vector3(14, 0.9, 0)
	await _wait(250)
	_check(scene._actors[1].position.y > 0.59 and scene._actors[1].steering.spatial.escape_reserved.is_empty(), "演示场景浅坑目标离坑后释放返程预留")
	print("[T03 能力] F6 演示五组与目标离坑 PASS" if not failed else "[T03 能力] F6 演示检查完成")
	current_scene = null
	scene.free()
	stage = Node3D.new()
	root.add_child(stage)
	paused = false
