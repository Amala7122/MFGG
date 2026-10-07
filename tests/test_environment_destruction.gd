extends SceneTree
## 用真实攻击验证破坏时机、可赋予组件、遮挡与清理。
const SpatialScene := preload("res://prototypes/combat/spatial/combat_spatial_lab.tscn")
const Prop := preload("res://scripts/destructible_prop.gd")
const Component := preload("res://scripts/destructible_component.gd")
const Destruction := preload("res://scripts/environment_destruction.gd")
const SmallTree := preload("res://prototypes/combat/spatial/props/small_tree.tscn")
const LowWall := preload("res://prototypes/combat/spatial/props/low_wall.tscn")
var _lab: Node3D
var _failed := false
var _contact_broken_in_air := false
var _radial_broken_on_land := false


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	_lab = SpatialScene.instantiate()
	root.add_child(_lab)
	current_scene = _lab
	for _frame in range(8):
		await process_frame
	_lab._crowd_motion.button_pressed = false
	await _prop_contract()
	await _assigned_component()
	await _dense_batch()
	await _real_slam()
	await _real_sweep()
	await _real_jump_melee()
	await _real_leap()
	await _cancel_and_block()
	await _native_demo()
	await _reset_and_limits()
	for _frame in range(60):
		await process_frame
		if not _lab._navigation_baking and not _lab._navigation_dirty:
			break
	current_scene = null
	_lab.queue_free()
	await process_frame
	paused = false
	print("[环境破坏] ", "FAIL" if _failed else "PASS")
	quit(1 if _failed else 0)


func _prop_contract() -> void:
	paused = false
	var rock: StaticBody3D = _lab.get_node("NavigationRegion3D/SpatialLayout/Geometry/BreakableRock")
	for _frame in range(3):
		await physics_frame
	var space := rock.get_world_3d().direct_space_state
	var query := PhysicsRayQueryParameters3D.create(rock.global_position + Vector3.UP * 4, rock.global_position + Vector3.DOWN, 1)
	var before := space.intersect_ray(query)
	_check(not before.is_empty() and before.collider == rock, "完整石块有真实碰撞")
	_check(not rock.break_from_impact(rock.global_position, Vector3.DOWN, 0.5) and not rock.is_broken, "不足强度不生成破坏")
	_check(rock.break_from_impact(rock.global_position, Vector3.DOWN, 1.0), "足够强度可以破坏")
	var count := get_nodes_in_group("destruction_debris").size()
	_check(not rock.break_from_impact(rock.global_position, Vector3.DOWN, 1.0) and get_nodes_in_group("destruction_debris").size() == count, "重复接触只碎一次")
	var after := space.intersect_ray(query)
	_check(rock.collision_layer == 0 and not after.is_empty() and absf(after.position.y) < 0.01, "破坏当帧移除碰撞，射线落到下方地板")
	_check(not rock.get_node("Intact").visible and rock.get_node("Rubble").visible, "切换完整网格与残骸")
	paused = true
	_lab.clear_round()
	_check(not rock.is_broken and rock.collision_layer == 1 and get_nodes_in_group("destruction_debris").is_empty(), "清空恢复碰撞并移除碎块")


func _assigned_component() -> void:
	paused = false
	# 没有专用物件脚本、没有 Intact 约定节点，且包含两个独立静态碰撞体。
	var object := Node3D.new()
	object.position = Vector3(14, 0, 12)
	var bodies: Array[StaticBody3D] = []
	for x in [-0.5, 0.5]:
		var body := StaticBody3D.new()
		body.collision_layer = 5 if x < 0 else 9
		body.position = Vector3(x, 0.5, 0)
		var collision := CollisionShape3D.new()
		var shape := BoxShape3D.new()
		shape.size = Vector3(0.8, 1, 0.6)
		collision.shape = shape
		body.add_child(collision)
		var mesh := MeshInstance3D.new()
		var box := BoxMesh.new()
		box.size = shape.size
		mesh.mesh = box
		body.add_child(mesh)
		object.add_child(body)
		bodies.append(body)
	var component := Component.new()
	component.profile = preload("res://data/destruction/wood.tres")
	object.add_child(component)
	_lab.get_node("NavigationRegion3D").add_child(object)
	for _frame in range(3):
		await physics_frame
	_check(component.get_collision_rids().size() == 2 and Destruction.breakable_rids(_lab, 0.5).has(bodies[1].get_rid()), "任意模型可赋予组件，登记全部子碰撞")
	_check(Destruction.radial_impact(_lab, object.global_position, 2.0, 2.0, 0.5) == 1, "多碰撞物件通过公共环境攻击只破坏一次")
	_check(component.is_broken and bodies[0].collision_layer == 0 and bodies[1].collision_layer == 0, "全部碰撞同帧移除")
	_check(not bodies[0].get_child(1).visible and not bodies[1].get_child(1).visible, "没有 Intact 节点时自动隐藏原模型")
	var debris: Node = get_nodes_in_group("destruction_debris")[-1]
	_check(debris._chunks.multimesh.mesh == component.profile.fragment_mesh and debris._chunks.multimesh.instance_count == 18, "共享木材配置决定碎片网格和数量")
	component.reset_destruction()
	_check(bodies[0].collision_layer == 5 and bodies[1].collision_layer == 9 and bodies[0].get_child(1).visible, "恢复原始碰撞层与可见性")
	_check(is_equal_approx(preload("res://data/destruction/wood.tres").strength, 0.5), "共享配置不会被破坏状态改写")
	object.free()
	paused = true
	_lab.clear_round()


func _dense_batch() -> void:
	paused = false
	var container := Node3D.new()
	var shape := BoxShape3D.new()
	shape.size = Vector3(0.035, 0.4, 0.035)
	var mesh := BoxMesh.new()
	mesh.size = shape.size
	var components: Array[Node3D] = []
	for i in range(300):
		var body := StaticBody3D.new()
		body.collision_mask = 0
		body.position = Vector3(14 + (i % 20) * 0.06, 0.2, 12 + floorf(i / 20.0) * 0.06)
		var collision := CollisionShape3D.new()
		collision.shape = shape
		body.add_child(collision)
		var visual := MeshInstance3D.new()
		visual.mesh = mesh
		body.add_child(visual)
		var component := Component.new()
		body.add_child(component)
		components.append(component)
		container.add_child(body)
	_lab.get_node("NavigationRegion3D").add_child(container)
	for _frame in range(3):
		await physics_frame
	var count := Destruction.radial_impact(_lab, Vector3(12, 0, 10), 4.5, 1.0, 1.0)
	_check(count == 300 and components.all(func(prop: Node3D): return prop.is_broken), "密集范围内 300 个物件都被处理，不受单次查询数量截断")
	_check(get_nodes_in_group("destruction_debris").size() <= 8, "大量物件破坏仍保留全场效果数量上限")
	container.free()
	paused = true
	_lab.clear_round()


func _authored(scene: PackedScene, at: Vector3) -> StaticBody3D:
	var prop := scene.instantiate() as StaticBody3D
	prop.position = at
	_lab.get_node("NavigationRegion3D").add_child(prop)
	return prop


func _real_slam() -> void:
	var enemy := await _spawn()
	enemy.position = Vector3(0, 1.78, 8)
	_lab._player.position = Vector3(0, 1.08, 12)
	var tree := _authored(SmallTree, Vector3(-0.35, 0, 10.5))
	var low_wall := _authored(LowWall, Vector3(2.5, 0, 11.5))
	var wall := _box(Vector3(0, 1.5, 14), Vector3(4, 3, 0.25))
	var sheltered := _prop(Vector3(0, 0, 15.2), Vector3(0.6, 1.2, 0.6), 0)
	var strong := _prop(Vector3(0.8, 0, 13), Vector3(0.45, 1.5, 0.45), 1)
	strong.break_strength = 2.0
	var outside := _prop(Vector3(5.5, 0, 11), Vector3(0.6, 1.2, 0.6), 0)
	for _frame in range(3):
		await physics_frame
	enemy.trigger_slam_attack()
	_check(enemy.current_state == enemy.State.ATK_SLAM and not tree.get_node("Destructible").is_broken, "砸地预警不提前破坏")
	await _capture("05_slam_before", Vector3(0, 1.5, 11))
	for _frame in range(140):
		await physics_frame
		if tree.get_node("Destructible").is_broken:
			break
	_check(tree.get_node("Destructible").is_broken and low_wall.get_node("Destructible").is_broken, "真实砸地破坏小树和中心在范围外但边缘命中的长矮墙")
	_check(not sheltered.is_broken and not strong.is_broken and not outside.is_broken, "砸地保留实墙后、强度不足和范围外物件")
	_check(_lab.get_stats_snapshot().received_hits == 1, "砸地破坏后按实际通路命中玩家一次")
	var count := get_nodes_in_group("destruction_debris").size()
	enemy._execute_slam_impact()
	_check(get_nodes_in_group("destruction_debris").size() == count and _lab.get_stats_snapshot().received_hits == 1, "重复砸地结算不再破坏或伤害")
	await _capture("06_slam_broken", Vector3(0, 1.5, 11))
	for prop in [tree, low_wall, wall, sheltered, strong, outside]:
		prop.free()
	paused = true


func _real_sweep() -> void:
	var enemy := await _spawn()
	enemy.position = Vector3(0, 1.78, 10)
	_lab._player.position = Vector3(0, 1.08, 6)
	var tree := _authored(SmallTree, Vector3(-3.55, 0, 9.37))
	var low_wall := _authored(LowWall, Vector3(3.7, 0, 10.65))
	low_wall.scale.x = 0.4
	var wall := _box(Vector3(2.2, 1.5, 7), Vector3(0.25, 3, 4))
	var sheltered := _prop(Vector3(3.3, 0, 7), Vector3(0.6, 1.2, 0.6), 0)
	var outside := _prop(Vector3(0, 0, 16), Vector3(0.6, 1.2, 0.6), 0)
	var strong := _prop(Vector3(-2.25, 0, 6.1), Vector3(0.6, 1.5, 0.6), 1)
	strong.break_strength = 2.0
	for _frame in range(3):
		await physics_frame
	enemy.trigger_sweep_attack()
	_check(enemy.current_state == enemy.State.ATK_SWEEP and not tree.get_node("Destructible").is_broken, "横扫蓄力不提前破坏")
	var observed := false
	for _frame in range(160):
		await physics_frame
		if tree.get_node("Destructible").is_broken and not observed:
			observed = true
			_check(enemy._sweep_progress < 0.5 and not low_wall.get_node("Destructible").is_broken, "横扫前段只破坏已扫过物件，后段保持完整")
			await _capture("07_sweep_partial", Vector3(0, 1.5, 10))
		if enemy._attack_area.phase == enemy.AttackArea.Phase.RECOVERY:
			break
	_check(observed and low_wall.get_node("Destructible").is_broken, "横扫后段实际扫过时破坏矮墙")
	_check(not sheltered.is_broken and not outside.is_broken and not strong.is_broken, "横扫保留实墙后、范围外及强度不足物件")
	_check(_lab.get_stats_snapshot().received_hits == 1, "持续横扫只结算一次玩家伤害")
	await _capture("08_sweep_broken", Vector3(0, 1.5, 10))
	for prop in [tree, low_wall, wall, sheltered, outside, strong]:
		prop.free()
	# 两种地面技能的取消都必须阻止延迟破坏。
	for skill in ["slam", "sweep"]:
		enemy = await _spawn()
		enemy.position = Vector3(0, 1.78, 10)
		_lab._player.position = Vector3(0, 1.08, 6)
		var prop := _prop(Vector3(0, 0, 7), Vector3(0.6, 1.5, 0.6), 0)
		for _frame in range(3):
			await physics_frame
		if skill == "slam":
			enemy.trigger_slam_attack()
		else:
			enemy.trigger_sweep_attack()
		enemy._stop_action()
		enemy.current_state = enemy.State.IDLE
		for _frame in range(140):
			await physics_frame
		_check(not prop.is_broken, skill + "取消不再产生破坏")
		prop.free()
	paused = true


func _real_jump_melee() -> void:
	var enemy := await _spawn()
	enemy.position = Vector3(0, 1.78, 10)
	_lab._player.position = Vector3(0, 3.8, 8)
	var tree := _authored(SmallTree, Vector3(1.9, 0, 8.5))
	for _frame in range(3):
		await physics_frame
	var effects := get_nodes_in_group("titan_ground_effect").size()
	_check(enemy.trigger_jump_attack(), "高处玩家可发动真实跳跃普攻")
	_check(not tree.get_node("Destructible").is_broken, "跳跃普攻起跳不提前破坏")
	for _frame in range(100):
		await physics_frame
		if enemy.current_state != enemy.State.JUMP_ATTACK:
			break
	_check(tree.get_node("Destructible").is_broken, "跳跃普攻在空中挥击窗口破坏小树")
	_check(_lab.get_stats_snapshot().received_hits == 1, "跳跃普攻仍按实际高度命中一次")
	_check(get_nodes_in_group("titan_ground_effect").size() == effects and not enemy._attack_area.visible, "空中普攻破坏不产生地面预警或震波")
	tree.free()
	# 参数设为 0 后，普通木材也必须保留，且不能在预测阶段被忽略。
	enemy = await _spawn()
	enemy.position = Vector3(0, 1.78, 8)
	_lab._player.position = Vector3(0, 1.08, 12)
	tree = _authored(SmallTree, Vector3(0, 0, 10.5))
	enemy._tuning.slam_break_power = 0.0
	for _frame in range(3):
		await physics_frame
	enemy.trigger_slam_attack()
	_check(not enemy._attack_area.shape.exclude_bodies.has(tree.get_rid()), "关闭破坏后预警保留完整物件遮挡")
	for _frame in range(140):
		await physics_frame
	_check(not tree.get_node("Destructible").is_broken, "攻击破坏强度 0 可以关闭破坏")
	tree.free()
	paused = true


func _spawn() -> CharacterBody3D:
	_lab.set_selection({_lab.SEDIMENT_TITAN_ID: 1})
	await _lab.generate_round()
	var enemy: CharacterBody3D = _lab._live_enemies[0]
	enemy.position = Vector3(0, 1.78, -3)
	enemy.ai_enabled = false
	_lab._player.position = Vector3(0, 1.08, 10)
	_lab._start_fight()
	_lab._player.process_mode = Node.PROCESS_MODE_DISABLED
	paused = false
	for _frame in range(250):
		await physics_frame
	return enemy


func _real_leap() -> void:
	var enemy := await _spawn()
	var rock := _prop(Vector3(0, 0, 10), Vector3(1.8, 1.6, 1.8), 0)
	var pillar := _prop(Vector3(2.7, 0, 10), Vector3(1.1, 3.2, 1.1), 1)
	var wall := _box(Vector3(-2.3, 1.5, 10), Vector3(0.25, 3, 5))
	var sheltered := _prop(Vector3(-3.1, 0, 10), Vector3(0.6, 1.2, 0.6), 0)
	var outside := _prop(Vector3(5.5, 0, 10), Vector3(1, 1.5, 1), 1)
	rock.broken.connect(func(_prop: StaticBody3D): _contact_broken_in_air = enemy.current_state == enemy.State.LEAP_AIR and enemy.velocity.y < 0.0)
	pillar.broken.connect(func(_prop: StaticBody3D): _radial_broken_on_land = enemy.current_state == enemy.State.LEAP_RECOVERY)
	# 玩家站在原石块顶面，规划必须找到砸碎后的地面，不把石块当永久平台。
	_lab._player.position.y = 2.68
	for _frame in range(3):
		await physics_frame
	var plan: Dictionary = enemy._plan_leap()
	_check(not plan.is_empty() and absf(float(plan.get("ground", Vector3.UP).y)) < 0.01, "可破坏落点按下方真实地板规划：" + enemy._leap_plan_failure)
	_check(enemy.trigger_leap_attack(), "有石块与残柱的落点可发动跃击")
	_check(not rock.is_broken and not pillar.is_broken, "预警和规划阶段不提前破坏")
	_check(enemy._attack_area.can_reach(Vector3(1.8, 1, 10)), "预警覆盖破坏后可达的地面")
	_check(not enemy._attack_area.can_reach(Vector3(-3.1, 1, 10)), "预测破坏也保留普通墙的遮挡")
	await _capture("01_before", Vector3(0, 1.5, 10))
	var airborne := false
	var captured := false
	for _frame in range(240):
		await physics_frame
		airborne = airborne or enemy.current_state == enemy.State.LEAP_AIR
		if rock.is_broken and not captured:
			captured = true
			await _capture("02_contact", Vector3(0, 1.5, 10))
		if airborne and enemy.current_state == enemy.State.LEAP_RECOVERY:
			break
	_check(airborne and _contact_broken_in_air, "实际下落接触时砸碎石块，而不是起跳时清场")
	_check(pillar.is_broken and _radial_broken_on_land, "落地冲击震碎附近残柱")
	_check(not sheltered.is_broken and not outside.is_broken and wall.collision_layer == 1, "实墙后与范围外物件保持完整")
	_check(enemy.is_on_floor() and absf(enemy.position.y - 1.7) < 0.12, "砸碎后继续落到原地板，身体不悬空")
	_check(_lab.get_stats_snapshot().received_hits == 1, "破坏后按实际范围结算一次跃击伤害")
	for _frame in range(12):
		await physics_frame
	await _capture("03_landing", Vector3(0, 1.5, 10))
	# 暂停必须冻结飞散轨迹和寿命。
	paused = true
	var debris: Node = get_nodes_in_group("destruction_debris")[0]
	var age: float = debris.age
	for _frame in range(5):
		await process_frame
	_check(is_equal_approx(float(debris.age), age), "暂停冻结碎块")
	paused = false
	for _frame in range(260):
		await physics_frame
	_check(get_nodes_in_group("destruction_debris").is_empty(), "碎块和尘土按寿命全部清理")
	for body in [rock, pillar, wall, sheltered, outside]:
		body.free()
	paused = true


func _cancel_and_block() -> void:
	var enemy := await _spawn()
	var rock := _prop(Vector3(0, 0, 10), Vector3(1.5, 1.5, 1.5), 0)
	for _frame in range(3):
		await physics_frame
	_check(enemy.trigger_leap_attack(), "取消测试进入蓄力")
	enemy._stop_action()
	enemy.current_state = enemy.State.IDLE
	for _frame in range(120):
		await physics_frame
	_check(not rock.is_broken and get_nodes_in_group("destruction_debris").is_empty(), "蓄力取消不破坏环境、不遗留效果")
	var wall := _box(Vector3(0, 8, 5), Vector3(6, 16, 0.4))
	for _frame in range(3):
		await physics_frame
	_check(enemy._plan_leap().is_empty() and not rock.is_broken, "不可破坏墙仍会阻止飞行，不能借排除石块穿墙")
	wall.free()
	rock.break_strength = 2.0
	for _frame in range(3):
		await physics_frame
	var strong_plan: Dictionary = enemy._plan_leap()
	# 同一支撑面现在可搜索旁边的合法落点；仍不能排除强度不足的物件。
	_check(not rock.is_broken and (strong_plan.is_empty() or not rock.get_rid() in strong_plan.breakable), "超过重砸强度的石块不会被规划忽略")
	if not strong_plan.is_empty():
		for _frame in range(900):
			if enemy._brain.available("leap") and enemy.attack_cooldown <= 0.0: break
			await physics_frame
		_check(enemy.trigger_leap_attack(), "强石块旁的合法落点仍可正常跃击")
		for _frame in range(220): await physics_frame
		_check(not rock.is_broken and rock.collision_layer == 1, "绕到旁边落地不等于忽略或破坏强石块")
	rock.free()
	paused = true


func _native_demo() -> void:
	var enemy := await _spawn()
	enemy.position = Vector3(0, 1.78, -10)
	_lab._player.position = _lab.STARTS[-1].position
	var geometry := _lab.get_node("NavigationRegion3D/SpatialLayout/Geometry")
	var rock: StaticBody3D = geometry.get_node("BreakableRock")
	var pillar: StaticBody3D = geometry.get_node("BreakablePillar")
	for _frame in range(3):
		await physics_frame
	var initial_plan: Dictionary = enemy._plan_leap()
	print("[环境破坏] 原生区域初始规划：", not initial_plan.is_empty(), " ", enemy._leap_plan_failure)
	enemy.ai_enabled = true
	var airborne := false
	for _frame in range(360):
		await physics_frame
		airborne = airborne or enemy.current_state == enemy.State.LEAP_AIR
		if airborne and enemy.current_state == enemy.State.LEAP_RECOVERY:
			break
	enemy.ai_enabled = false
	print("[环境破坏] 原生区域结果：air=", airborne, " rock=", rock.is_broken, " pillar=", pillar.is_broken,
		" at=", enemy.position, " failure=", enemy._leap_plan_failure, " history=", enemy._brain.history)
	_check(airborne and rock.is_broken and pillar.is_broken, "原生掩体区实际自动选招能砸碎石块与残柱")
	for _frame in range(12):
		await physics_frame
	await _capture("04_native_demo", Vector3(-7.5, 1.3, 12))
	paused = true


func _reset_and_limits() -> void:
	var enemy := await _spawn()
	var rock: StaticBody3D = _lab.get_node("NavigationRegion3D/SpatialLayout/Geometry/BreakableRock")
	var tree: StaticBody3D = _lab.get_node("NavigationRegion3D/SpatialLayout/Geometry/SmallTree")
	var wall: StaticBody3D = _lab.get_node("NavigationRegion3D/SpatialLayout/Geometry/LowWall")
	_check(rock.break_from_impact(rock.global_position, Vector3.DOWN, 1.0), "测试场原生物件可破坏")
	_check(tree.get_node("Destructible").break_from_impact(tree.global_position, Vector3.DOWN, 1.0)
		and wall.get_node("Destructible").break_from_impact(wall.global_position, Vector3.DOWN, 1.0), "原生小树、矮墙使用同一组件")
	for _frame in range(120):
		await physics_frame
		if not _lab._navigation_baking and not _lab._navigation_dirty:
			break
	# bake_finished 之后，导航服务器还需要物理帧同步新的区域网格。
	for _frame in range(3):
		await physics_frame
	var nav_map: RID = _lab.get_node("NavigationRegion3D").get_navigation_map()
	var nearest := NavigationServer3D.map_get_closest_point(nav_map, rock.global_position)
	_check(nearest.distance_to(rock.global_position) < 0.35, "破坏后导航恢复原石块占用的地面：" + str(nearest))
	for i in range(12):
		var prop := _prop(Vector3(0.1 * i, 0, 14), Vector3(0.4, 0.5, 0.4), 0)
		prop.break_from_impact(prop.global_position, Vector3.DOWN, 1.0)
		prop.free()
	_check(get_nodes_in_group("destruction_debris").size() <= 8, "密集破坏的碎块效果有全场数量上限")
	paused = true
	await _lab.generate_round()
	_check(not rock.is_broken and rock.collision_layer == 1 and get_nodes_in_group("destruction_debris").is_empty(), "重开恢复物件与清理所有上一轮效果")
	_check(not tree.get_node("Destructible").is_broken and not wall.get_node("Destructible").is_broken
		and tree.collision_layer == 1 and wall.collision_layer == 1, "重开同时恢复场景资源中的可赋予物件")
	_check(is_instance_valid(enemy) == false, "重开移除旧动作执行者")


func _prop(at: Vector3, size: Vector3, kind: int) -> StaticBody3D:
	var prop := Prop.new()
	prop.position = at
	prop.dimensions = size
	prop.kind = kind
	_lab.get_node("NavigationRegion3D").add_child(prop)
	return prop


func _box(at: Vector3, size: Vector3) -> StaticBody3D:
	var body := StaticBody3D.new()
	body.position = at
	body.collision_layer = 1
	body.collision_mask = 0
	var collision := CollisionShape3D.new()
	var shape := BoxShape3D.new()
	shape.size = size
	collision.shape = shape
	body.add_child(collision)
	_lab.get_node("NavigationRegion3D").add_child(body)
	return body


func _capture(title: String, at: Vector3) -> void:
	if not OS.get_cmdline_user_args().has("--capture-destruction") or DisplayServer.get_name() == "headless":
		return
	var before := paused
	paused = true
	_lab._interface.visible = false
	_lab._weapon_plate.visible = false
	_lab._player.aim_ui.visible = false
	_lab._player.visible = false
	for label: Node in _lab.get_node("NavigationRegion3D/SpatialLayout").get_children():
		if label is Label3D:
			label.visible = false
	for enemy: Node in _lab._live_enemies:
		enemy._health_label.visible = false
	_lab._overview.global_position = at + Vector3(-7, 6, 8)
	_lab._overview.look_at(at)
	_lab._overview.current = true
	for _frame in range(5):
		await process_frame
	await RenderingServer.frame_post_draw
	var directory := "D:/godot_project/visual_captures/destruction"
	DirAccess.make_dir_recursive_absolute(directory)
	root.get_texture().get_image().save_png(directory.path_join(title + ".png"))
	paused = before


func _check(condition: bool, message: String) -> void:
	if not condition:
		_failed = true
		push_error("[环境破坏] " + message)
