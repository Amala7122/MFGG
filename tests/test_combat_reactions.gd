extends SceneTree
## 真实泰坦跃击：撤离、失败受击、贴地恢复、死亡及跨种类赋予。
const SpatialScene := preload("res://prototypes/combat/spatial/combat_spatial_lab.tscn")
const Tuning := preload("res://scripts/prototypes/enemy_tuning.gd")
const Reactions := preload("res://scripts/combat_reactions.gd")
const AttackArea := preload("res://scripts/enemy_attack_area.gd")
const Telemetry := preload("res://scripts/combat_telemetry.gd")
const Hold := preload("res://data/combat_reactions/hold_anchored.tres")
const Dodge := preload("res://data/combat_reactions/evade_knockback.tres")
const Fall := preload("res://data/combat_reactions/evade_knockdown.tres")
var _lab: Node3D
var _failed := false
var _actors: Dictionary


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	for id: String in Tuning.PROFILE_PATHS:
		# 固定项目默认，避免用户本地数值方案改变测试条件；不写方案文件。
		Tuning._saved[id] = {"version": 1, "active": Tuning.DEFAULT_PRESET, "presets": {}}
	_lab = SpatialScene.instantiate()
	root.add_child(_lab)
	current_scene = _lab
	for _frame in range(8):
		await process_frame
	_lab._crowd_motion.button_pressed = false
	await _real_escape()
	await _real_hits()
	await _lethal_hit()
	await _cancel_and_pause()
	await _assignment_and_obstacles()
	paused = true
	_lab.clear_round()
	_check(get_nodes_in_group("combat_dangers").is_empty(), "清空移除所有危险信息")
	current_scene = null
	_lab.queue_free()
	await process_frame
	paused = false
	print("[小怪反应] ", "FAIL" if _failed else "PASS")
	quit(1 if _failed else 0)


func _spawn() -> CharacterBody3D:
	_lab.set_selection({_lab.SEDIMENT_TITAN_ID: 1, _lab.MUD_GOLEM_ID: 1, _lab.FAST_BEAST_ID: 1, _lab.HORNET_ID: 1})
	await _lab.generate_round()
	_actors = {}
	for actor: CharacterBody3D in _lab._live_enemies:
		actor.ai_enabled = false
		_actors[String(actor.get_meta(&"lab_roster_id"))] = actor
	_actors[_lab.SEDIMENT_TITAN_ID].position = Vector3(0, 1.78, -3)
	_actors[_lab.MUD_GOLEM_ID].position = Vector3(-1.5, 0.73, 10)
	_actors[_lab.FAST_BEAST_ID].position = Vector3(1.4, 0.855, 10)
	_actors[_lab.HORNET_ID].position = Vector3(-1, 4.28, 11.5)
	_lab._player.position = Vector3(0, 1.08, 10)
	_lab._start_fight()
	_lab._player.process_mode = Node.PROCESS_MODE_DISABLED
	paused = false
	for _frame in range(250):
		await physics_frame
	return _actors[_lab.SEDIMENT_TITAN_ID]


func _real_escape() -> void:
	var titan := await _spawn()
	var mud: CharacterBody3D = _actors[_lab.MUD_GOLEM_ID]
	var beast: CharacterBody3D = _actors[_lab.FAST_BEAST_ID]
	var bee: CharacterBody3D = _actors[_lab.HORNET_ID]
	var mud_start := mud.global_position
	var hp := [mud.health, beast.health, bee.health]
	_check(titan.trigger_leap_attack(), "真实跃击发布危险范围")
	mud.ai_enabled = true
	beast.ai_enabled = true
	bee.ai_enabled = true
	var beast_evaded := false
	var bee_evaded := false
	var airborne := false
	for frame in range(240):
		await physics_frame
		beast_evaded = beast_evaded or beast._reactions.mode == Reactions.Mode.EVADE
		bee_evaded = bee_evaded or bee._reactions.mode == Reactions.Mode.EVADE
		airborne = airborne or titan.current_state == titan.State.LEAP_AIR
		if frame == 35:
			await _capture("01_evading")
		if airborne and titan.current_state == titan.State.LEAP_RECOVERY:
			break
	_check(airborne and beast_evaded and bee_evaded, "晶兽和蜂感知到跃击并主动撤离")
	_check(mud.health < hp[0] and mud._reactions.mode == Reactions.Mode.NONE and mud.global_position.distance_to(mud_start) < 0.08,
		"泥偶硬吃伤害，保留攻击且不产生冲击位移")
	_check(is_equal_approx(beast.health, hp[1]) and is_equal_approx(bee.health, hp[2]), "成功走出范围的晶兽和蜂不受伤")
	_check(not titan._attack_area.can_affect_ally(beast) and not titan._attack_area.can_affect_ally(bee), "撤离的安全边缘与实际冲击范围一致")
	_check(get_nodes_in_group("combat_dangers").is_empty(), "冲击消费后危险信息立即撤销")
	for _frame in range(15):
		await physics_frame
	_check(beast._reactions.mode == Reactions.Mode.NONE and bee._reactions.mode == Reactions.Mode.NONE, "危险结束交回各自正常 AI")
	print("[小怪反应] 撤离：beast=", beast.position, " bee=", bee.position)
	paused = true


func _real_hits() -> void:
	var titan := await _spawn()
	var mud: CharacterBody3D = _actors[_lab.MUD_GOLEM_ID]
	var beast: CharacterBody3D = _actors[_lab.FAST_BEAST_ID]
	var bee: CharacterBody3D = _actors[_lab.HORNET_ID]
	var beast_start := beast.position
	var bee_start := bee.position
	var before := [mud.health, beast.health, bee.health]
	for actor: CharacterBody3D in [beast, bee]:
		actor._reactions.profile = actor._reactions.profile.duplicate(true)
		actor._reactions.profile.reaction_delay = 0.0
		actor._reactions.profile.escape_speed_multiplier = 0.1
		actor.move_speed = 0.1 # 正在撤离但速度不足，不能及时走出冲击范围。
		actor.ai_enabled = true
	_check(titan.trigger_leap_attack(), "发动无法及时撤离的真实跃击")
	var airborne := false
	var attempted := false
	for _frame in range(240):
		await physics_frame
		attempted = attempted or beast._reactions.mode == Reactions.Mode.EVADE
		airborne = airborne or titan.current_state == titan.State.LEAP_AIR
		if airborne and titan.current_state == titan.State.LEAP_RECOVERY:
			break
	_check(attempted and beast.health < before[1] and bee.health < before[2], "尝试躲避但来不及时按真实范围受伤")
	_check(mud.health < before[0] and mud._reactions.mode == Reactions.Mode.NONE, "硬吃策略同样结算伤害")
	_check(beast._reactions.mode == Reactions.Mode.KNOCKBACK and Vector2(beast.velocity.x, beast.velocity.z).length() > 5.0, "晶兽命中后沿冲击方向被击退")
	_check(bee._reactions.mode == Reactions.Mode.FALLING and bee.velocity.y < -8.0, "蜂命中后向下坠落，不走原来的向上受击弹跳")
	var hp_after := [mud.health, beast.health, bee.health]
	_check(not titan._attack_area.strike(), "同次冲击不能重复结算")
	for _frame in range(5):
		await physics_frame
	await _capture("02_impact")
	var touched_ground := false
	var rose := false
	var resumed := false
	var lowest := bee.global_position.y
	for _frame in range(240):
		await physics_frame
		lowest = minf(lowest, bee.global_position.y)
		if not touched_ground and bee._reactions.mode == Reactions.Mode.GROUNDED:
			touched_ground = true
			_check(bee.is_on_floor(), "蜂坠地由真实地板碰撞确认")
			# 玩家伤害能扣血，但不能把尚在坠地状态的蜂提前弹回空中。
			Telemetry.hurt_enemy(bee, 1.0, {"source": "primary"})
			_check(bee._reactions.mode == Reactions.Mode.GROUNDED, "坠地期间普通受击不抢占恢复流程")
			await _capture("03_grounded")
		rose = rose or bee._reactions.mode == Reactions.Mode.RISING
		if touched_ground and rose and bee._reactions.mode == Reactions.Mode.NONE:
			resumed = true
			break
	_check(touched_ground and rose and resumed and lowest < bee_start.y - 2.0 and bee.position.y >= bee_start.y - 0.2,
		"蜂存活后贴地停顿，再连续起飞恢复原悬停高度")
	_check(beast.position.distance_to(beast_start) > 1.0 and beast._reactions.mode == Reactions.Mode.NONE, "击退结束后晶兽恢复正常移动")
	_check(is_equal_approx(mud.health, hp_after[0]) and is_equal_approx(beast.health, hp_after[1]), "后摇和恢复不重复扣除冲击伤害")
	await _capture("04_recovered")
	print("[小怪反应] 受击 / 恢复：beast=", beast.position, " bee=", bee.position, " lowest=", lowest)
	paused = true


func _lethal_hit() -> void:
	var titan := await _spawn()
	var bee: CharacterBody3D = _actors[_lab.HORNET_ID]
	bee.health = 1.0
	var watched: WeakRef = weakref(bee)
	_check(titan.trigger_leap_attack(), "低血量蜂的跃击测试启动")
	for _frame in range(220):
		await physics_frame
		if watched.get_ref() == null:
			break
	_check(watched.get_ref() == null, "蜂被砸死进入原死亡解体流程，不再次起飞")
	var corpses := get_nodes_in_group("hornet_death_body")
	_check(corpses.size() == 1 and corpses[0].linear_velocity.y < -8.0, "致死冲击也将蜂尸体向下砸落")
	if not corpses.is_empty():
		var corpse: RigidBody3D = corpses[0]
		for _frame in range(90):
			await physics_frame
			if corpse.impacted:
				break
		_check(corpse.impacted, "致死坠落同样经过地板碰撞后散架")
	var stats: Dictionary = _lab.get_stats_snapshot()
	_check(stats.totals.kills == 0 and stats.totals.damage == 0.0 and stats.unassigned_deaths == 1 and stats.sources.primary.kills == 0 and stats.sources.sniper.kills == 0,
		"Boss 击杀不计入玩家击杀、武器命中和 DPS")
	paused = true


func _cancel_and_pause() -> void:
	var titan := await _spawn()
	var beast: CharacterBody3D = _actors[_lab.FAST_BEAST_ID]
	beast.ai_enabled = true
	_check(titan.trigger_leap_attack(), "取消 / 暂停测试发布危险")
	for _frame in range(24):
		await physics_frame
	_check(beast._reactions.mode == Reactions.Mode.EVADE, "取消前已经撤离")
	paused = true
	var frozen := beast.global_position
	var noticed: float = beast._reactions._noticed
	for _frame in range(16):
		await process_frame
	_check(beast.global_position.is_equal_approx(frozen) and is_equal_approx(beast._reactions._noticed, noticed), "暂停冻结撤离和反应计时")
	beast.apply_push(Vector3.RIGHT, 4.0)
	_check(beast._reactions.mode == Reactions.Mode.NONE and beast.current_state == beast.State.HIT_STAGGER, "撤离没有额外霸体，玩家脉冲仍能打断")
	# 模拟外部结束动作；AI 不再因为目标变化取消已经公布的跃击。
	titan._stop_action()
	titan._finish_action(0.0)
	_check(get_nodes_in_group("combat_dangers").is_empty(), "取消技能立即撤销危险")
	paused = false
	for _frame in range(10):
		await physics_frame
	_check(beast._reactions.mode == Reactions.Mode.NONE, "恢复后取消撤离，不保留过期危险")
	paused = true


func _assignment_and_obstacles() -> void:
	await _spawn()
	for actor: CharacterBody3D in _actors.values():
		actor.process_mode = Node.PROCESS_MODE_DISABLED
	var mud := _assigned(_lab.MUD_GOLEM_ID, Dodge, Vector3(59, 0.73, 10))
	var beast := _assigned(_lab.FAST_BEAST_ID, Hold, Vector3(61, 0.855, 10))
	var bee := _assigned(_lab.HORNET_ID, Hold, Vector3(59, 4.28, 11.5))
	var floor_body := _box(Vector3(60, -0.5, 10), Vector3(12, 1, 12))
	var hazard := AttackArea.new()
	_lab.add_child(hazard)
	paused = false
	for _frame in range(8):
		await physics_frame
	hazard.prepare(Transform3D(Basis.IDENTITY, Vector3(60, 0, 10)), {"kind": "circle", "radius": 4.2, "height": 3.0,
		"ally_height": 6.0, "affects_allies": true}, 32.0, 1.0)
	var wall := _box(Vector3(62, 3, 10), Vector3(0.3, 6, 12))
	for _frame in range(3):
		await physics_frame
	var protected := _assigned(_lab.MUD_GOLEM_ID, Dodge, Vector3(63, 0.73, 10))
	var high := _assigned(_lab.HORNET_ID, Hold, Vector3(60, 8.0, 10))
	_check(not hazard.can_affect_ally(protected) and not hazard.can_affect_ally(high), "普通实墙和高度窗口继续保护小怪")
	var held_start := beast.global_position
	var bee_start := bee.global_position
	hazard.lock()
	_check(hazard.strike(), "可配置冲击可被消费一次")
	Reactions.impact_allies(hazard, _actors[_lab.SEDIMENT_TITAN_ID], {"attack": "配置交换测试"})
	_check(mud._reactions.mode == Reactions.Mode.KNOCKBACK and beast._reactions.mode == Reactions.Mode.NONE and bee._reactions.mode == Reactions.Mode.NONE,
		"交换赋予后泥偶可击退，晶兽和蜂可硬吃；不读取物种 ID")
	_check(protected.health == protected.max_health and high.health == high.max_health, "遮挡 / 范围外的敌人不扣血")
	for _frame in range(12):
		await physics_frame
	_check(beast.position.distance_to(held_start) < 0.05 and bee.position.distance_to(bee_start) < 0.05, "赋予硬吃后不会触发各自默认受击位移")
	# 再给泥偶赋予躲避，验证出口不会穿墙或掉进无支撑区域。
	mud.position = Vector3(64.9, 0.73, 13)
	mud.velocity = Vector3.ZERO
	for _frame in range(50):
		await physics_frame
	_check(not mud._reactions._route_clear(mud.position + Vector3(5, 0, 0)), "撤离路线拒绝悬崖外无支撑的出口")
	_check(not mud._reactions._route_clear(Vector3(60, mud.position.y, 13)), "撤离路线扫掠完整身体，不穿实墙")
	var crash := _assigned(_lab.HORNET_ID, Fall, Vector3(56, 4.28, 8))
	crash._reactions.receive_impact(Vector3(55, 0, 8))
	for _frame in range(60):
		await physics_frame
		if crash._reactions.mode == Reactions.Mode.GROUNDED:
			break
	_check(crash._reactions.mode == Reactions.Mode.GROUNDED, "低顶恢复测试先确认真实坠地")
	crash._reactions.receive_impact(Vector3(55, 0, 8))
	_check(crash._reactions.mode == Reactions.Mode.FALLING and crash.velocity.y < -8.0, "连续冲击重新压向地面，不提前起飞")
	var ceiling := _box(Vector3(56, 2.6, 8), Vector3(4, 0.2, 4))
	for _frame in range(120):
		await physics_frame
		if crash._reactions.mode == Reactions.Mode.NONE:
			break
	_check(crash._reactions.mode == Reactions.Mode.NONE and crash.motion_mode == CharacterBody3D.MOTION_MODE_FLOATING and crash.position.y < 2.0,
		"低顶限制起飞高度时交回飞行 AI，不永久卡在恢复状态")
	hazard.free()
	wall.free()
	ceiling.free()
	floor_body.free()
	for actor in [mud, beast, bee, protected, high, crash]:
		actor.queue_free()
	await process_frame
	paused = true


func _assigned(id: String, assigned: Resource, at: Vector3) -> CharacterBody3D:
	var actor: CharacterBody3D = _lab.PROTOTYPE_SCENES[id].instantiate()
	actor.set_meta(&"enemy_tuning", Tuning.defaults(id))
	actor.set_meta(&"crowd_uniform", true)
	actor.set_meta(&"combat_reaction_profile", assigned)
	actor.ai_enabled = false
	actor.position = at
	_lab.add_child(actor)
	actor.target = _lab._player
	return actor


func _box(at: Vector3, size: Vector3) -> StaticBody3D:
	var body := StaticBody3D.new()
	var collision := CollisionShape3D.new()
	var shape := BoxShape3D.new()
	shape.size = size
	collision.shape = shape
	body.add_child(collision)
	body.position = at
	_lab.add_child(body)
	return body


func _capture(title: String) -> void:
	if not "--capture-reactions" in OS.get_cmdline_user_args() or DisplayServer.get_name() == "headless":
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
	var camera: Camera3D = _lab._overview
	camera.global_position = Vector3(-9, 8, 20)
	camera.look_at(Vector3(0, 1.8, 10))
	camera.current = true
	for _frame in range(5):
		await process_frame
	await RenderingServer.frame_post_draw
	var folder := "D:/godot_project/visual_captures/reactions"
	DirAccess.make_dir_recursive_absolute(folder)
	_check(root.get_texture().get_image().save_png(folder.path_join(title + ".png")) == OK, "保存实际画面 " + title)
	paused = before


func _check(condition: bool, message: String) -> void:
	print("[小怪反应] ", "OK " if condition else "FAIL ", message)
	if not condition:
		_failed = true
