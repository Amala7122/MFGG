extends SceneTree
## I-148真实低机位／肩部枪口回归；不把晶体高度的悬浮枪线当正常瞄准。
const Artifacts := preload("res://scripts/artifact_paths.gd")
var failures := 0
var actor: Node3D
var boss: Node3D
var world: Node3D
var weapon: Node
var camera: Camera3D
func _initialize() -> void: call_deferred("_run")
func check(ok: bool, message: String) -> void:
	if not ok:
		failures += 1
		push_error(message)
func frames(count: int) -> void:
	for _i in range(count): await physics_frame
func aim(part: Node3D, distance := 12.0) -> void:
	actor.set_physics_process(false)
	weapon.set("view_kick", Vector2.ZERO) # 受控机位等价于后坐已回收；真实动态由陪练另测。
	actor.global_position = Vector3(0, 1.01, distance)
	for _i in range(75):
		var point := part.global_position
		var offset := point - camera.global_position
		actor.set("target_yaw", atan2(-offset.x, -offset.z))
		actor.set("target_pitch", atan2(offset.y, Vector2(offset.x, offset.z).length()))
		actor.call("_update_camera", 1.0 / 60.0)
		weapon.set("visual_direction", (point - weapon.get("_weapon_rig").global_position).normalized())
		weapon.call("_pose_weapon", 1.0 / 60.0)
		await physics_frame # SpringArm真实物理同步，不能只空转相机计算。
func capture(label: String) -> void:
	if DisplayServer.get_name() == "headless": return
	actor.get("_hud").call("set_target_feedback", weapon.call("get_aim_feedback"))
	actor.get("_hud").call("update", 0.016, Vector2.ZERO, true, false)
	boss.call("_update_crystal_hint")
	await RenderingServer.frame_post_draw
	var path := Artifacts.ensure_dir("screenshots", "crystal_targeting").path_join(label + ".png")
	check(root.get_texture().get_image().save_png(path) == OK, "晶体提示图像保存成功")
func _run() -> void:
	world = Node3D.new()
	root.add_child(world)
	current_scene = world
	var light := DirectionalLight3D.new()
	light.rotation_degrees = Vector3(-45, -25, 0)
	light.light_energy = 1.5
	world.add_child(light)
	var ground := StaticBody3D.new()
	var shape := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = Vector3(100, 1, 100)
	shape.shape = box
	ground.position.y = -0.5
	ground.add_child(shape)
	world.add_child(ground)
	actor = load("res://scenes/player.tscn").instantiate()
	actor.position = Vector3(0, 1.01, 12)
	world.add_child(actor)
	actor.set_physics_process(false)
	weapon = actor.get("_weapon")
	camera = actor.get("camera")
	actor.set("_aiming", true)
	weapon.set("_aiming", true)
	weapon.set("_sniper_ammo", 5)
	var spawner := Node.new()
	spawner.set_script(load("res://scripts/enemy_spawner.gd"))
	world.add_child(spawner)
	boss = spawner.spawn_boss("sediment_titan", Vector3(0, 2.805, 0))
	boss.prepare_sparring_phase("rage")
	boss.ai_enabled = false
	await frames(6)
	check(is_equal_approx(boss._collision.shape.height, 3.4) and is_equal_approx(boss._collision.shape.radius, 1.4) and boss.collision_mask == 3, "世界／玩家移动碰撞体保持原尺寸与掩码：" + str([boss._collision.shape.height, boss._collision.shape.radius, boss.collision_mask]))
	check(boss._weapon_regions.areas.size() == boss.destructible_parts.size(), "每个可见实体部件登记一个玩家射线受弹区")
	for distance in [8.0, 12.0, 20.0]:
		await aim(boss.core_mesh, distance)
		await frames(2)
		var hits: Array = weapon.call("_resolve_shot_hits", -camera.global_basis.z, true)
		check(not hits.is_empty() and hits[0].hit_region == "crystal", "正常肩部机位 %.0fm 对准晶体中心实际命中晶体" % distance)
		var cue: Dictionary = weapon.call("get_aim_feedback")
		check(cue.get("kind") == "crystal", "准星按真实枪线报告开放晶体 distance=%s cue=%s" % [distance, cue])
	# 核对模型旋转／步态后的部位跟随，不修改运动圆柱或使用自动命中。
	boss.set_physics_process(false)
	for rotation_angle in [0.0, 1.57, 3.14]:
		boss.rotation.y = rotation_angle
		boss.call("_animate_walk", rotation_angle)
		await frames(2)
		await aim(boss.core_mesh, 20)
		var hits: Array = weapon.call("_resolve_shot_hits", -camera.global_basis.z, true)
		check(not hits.is_empty() and hits[0].hit_region == "crystal", "转身与步态后晶体受弹跟随可见模型")
	boss.rotation.y = 0.0
	boss.set_physics_process(true)
	await aim(boss.core_mesh)
	await frames(2)
	await capture("open_crystal")
	var hp: float = boss.health
	weapon.fire()
	check(boss._crystal_hits == 1 and boss.health < hp and weapon.get_sniper_ammo() == 4, "真实射击扣弹和伤害，晶体计数只增加一次")
	var crosshair: Control = actor.get("_hud").get("_crosshair")
	check(crosshair.get("_hit_feedback").get("kind") == "break" and "1/3" in crosshair.get("_hit_feedback").text, "正式HUD逐发显示有效破击1/3")
	await capture("break_confirmed")
	await frames(2)
	await aim(boss.core_mesh)
	check(weapon.call("get_aim_feedback").get("kind") == "protected", "真实护罩下准星明确显示保护")
	hp = boss.health
	weapon.fire()
	check(boss.health == hp and boss._crystal_hits == 1 and crosshair.get("_hit_feedback").get("kind") == "protected", "护罩拦截无伤／无计数，HUD区分拦截")
	var labels := world.find_children("*", "Label3D", true, false).size()
	for _i in range(20): weapon.call("_fire_hitscan", -camera.global_basis.z, false)
	check(world.find_children("*", "Label3D", true, false).size() == labels and boss.health == hp and boss._crystal_hits == 1, "持续击中护罩不堆积重复浮字，不伤害或累计进度")
	await capture("protected_crystal")
	await aim(boss.torso_pivot)
	await frames(2)
	check(weapon.call("get_aim_feedback").get("kind") == "body", "晶体保护期间身体仍可选中：" + str(weapon.call("get_aim_feedback")))
	hp = boss.health
	weapon.fire()
	check(boss.health < hp and boss._crystal_hits == 1 and crosshair.get("_hit_feedback").get("kind") == "body", "身体照常扣血并明确不增加破解")
	await capture("body_confirmed")
	while boss._crystal_guard_remaining > 0.0: await physics_frame
	await aim(boss.core_mesh)
	check(weapon.call("get_aim_feedback").get("kind") == "crystal", "真实5秒后可重新瞄准晶体")
	var wall := StaticBody3D.new()
	var wall_shape := CollisionShape3D.new()
	var wall_box := BoxShape3D.new()
	wall_box.size = Vector3.ONE * 0.2
	wall_shape.shape = wall_box
	wall.add_child(wall_shape)
	world.add_child(wall)
	var muzzle: Vector3 = weapon.get("_muzzle").global_position
	var anchor := Vector3(actor.global_position.x, weapon.get("_weapon_rig").global_position.y, actor.global_position.z)
	wall.global_position = anchor.lerp(muzzle, 0.5)
	await frames(2)
	check(weapon.call("get_aim_feedback").get("kind") == "obstructed", "相机看到晶体但枪口前有真实掩体时明确提示阻挡")
	hp = boss.health
	weapon.fire()
	check(boss.health == hp and boss._crystal_hits == 1, "真实掩体不被代理排除或弱点穿透绕过")
	await capture("muzzle_obstructed")
	wall.queue_free()
	await frames(2)
	weapon.set("_aiming", false)
	weapon.set("base_spread_degrees", 0.0)
	weapon.set("_bloom", 0.0)
	await aim(boss.core_mesh)
	weapon.fire()
	check(boss._crystal_hits == 1 and crosshair.get("_hit_feedback").get("text", "").contains("需狙击"), "普通枪击晶体说明需要狙击，不冒充破击：" + str(crosshair.get("_hit_feedback")))
	boss.trigger_death_scatter()
	check(boss._weapon_regions.areas.all(func(area): return area.collision_layer == 0) and not boss._crystal_hint.visible, "死亡禁用全部受弹部件及晶体状态提示")
	current_scene = null
	world.queue_free()
	await frames(8)
	preload("res://scripts/object_pool.gd").clear_all()
	await preload("res://tools/probes/sparring/sparring_runtime.gd").settle_audio(self)
	print("[晶体命中与提示] failures=", failures)
	quit(1 if failures else 0)
