extends SceneTree

const SpatialScene := preload("res://prototypes/combat/spatial/combat_spatial_lab.tscn")
const JumpLanding := preload("res://scripts/jump_landing.gd")
var _lab: Node3D
var _failed := false


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	_lab = SpatialScene.instantiate()
	root.add_child(_lab)
	current_scene = _lab
	for _frame in range(8):
		await process_frame
	_lab._crowd_motion.button_pressed = false
	var pedestal: StaticBody3D = _lab.get_node("NavigationRegion3D/SpatialLayout/Geometry/SmallPlatform")
	for id: String in [_lab.FAST_BEAST_ID, _lab.SEDIMENT_TITAN_ID]:
		await _small_perch(id)
		await _blocked_jump(id, pedestal)
	pedestal.free()
	await _large_platform()
	current_scene = null
	_lab.queue_free()
	await process_frame
	paused = false
	await create_timer(0.5).timeout
	print("[空间攻击] ", "FAIL" if _failed else "PASS")
	quit(1 if _failed else 0)


func _spawn(id: String, at: Vector3, target_at: Vector3) -> CharacterBody3D:
	_lab.set_selection({id: 1})
	await _lab.generate_round()
	var enemy: CharacterBody3D = _lab._live_enemies[0]
	enemy.position = at
	enemy.ai_enabled = false
	_lab._player.position = target_at
	_lab._start_fight()
	_lab._player.process_mode = Node.PROCESS_MODE_DISABLED
	paused = false
	# 等泰坦默认 2.5s 出土及 1.5s 准备结束，再测试其正常决策。
	for _frame in range(250):
		await physics_frame
	return enemy


func _small_perch(id: String) -> void:
	var titan: bool = id == _lab.SEDIMENT_TITAN_ID
	var start := Vector3(-10, 1.78 if titan else 0.855, -9)
	var enemy := await _spawn(id, start, Vector3(-10, 2.58, -15))
	_check(not JumpLanding.supported(enemy, Vector3(-10, 1.5, -15), Vector3.UP, enemy._collision.shape, enemy._collision.global_basis), id + "小台面不能容纳完整脚印")
	if titan:
		_check(enemy._plan_leap().is_empty() and enemy._leap_plan_failure == "landing_too_small", "泰坦拒绝中心射线能命中但身体站不下的落点")
	else:
		_check(not enemy._pounce_landing_ok(), "晶兽拒绝不足以落脚的飞扑目标")
	var effects_before := get_nodes_in_group("titan_ground_effect").size()
	var origin := enemy.global_position
	if OS.get_cmdline_user_args().has("--debug-t03"):
		var planner: RefCounted = enemy._steering.spatial._planner(_lab._player)
		print("[T03 stances] ", id, " ", planner._stances)
		for stance: Vector3 in planner._stances:
			print("[T03 walk] ", stance, " ", planner.walk_route(enemy.global_position, stance))
	enemy.ai_enabled = true
	var jumped := false
	var skill_started := false
	var captured := false
	var previous := enemy.global_position
	for _frame in range(240):
		await physics_frame
		if not jumped and enemy.current_state == enemy.State.JUMP_ATTACK:
			origin = previous
		jumped = jumped or enemy.current_state == enemy.State.JUMP_ATTACK
		skill_started = skill_started or enemy._attack_area.visible
		if not captured and _lab.get_stats_snapshot().received_hits > 0:
			captured = true
			await _capture_attack(id + "_jump_melee", Vector3(-10, 1.5, -15))
		if jumped and enemy.is_on_floor() and enemy.current_state != enemy.State.JUMP_ATTACK:
			break
		previous = enemy.global_position
	enemy.ai_enabled = false
	var stats: Dictionary = _lab.get_stats_snapshot()
	_check(jumped and not skill_started, id + "自动选择跳跃普攻，无地面预警")
	_check(stats.received_hits == 1 and stats.incoming.has(id + ("/泰坦跳跃普攻" if titan else "/晶兽跳跃普攻")), id + "按真实跃起高度命中一次并归属普通攻击")
	_check(enemy.is_on_floor() and absf(enemy.global_position.y - origin.y) < 0.1 and Vector2(enemy.position.x - origin.x, enemy.position.z - origin.z).length() < 0.15,
		id + "落回原地，没有瞬移上台或悬空")
	_check(get_nodes_in_group("titan_ground_effect").size() == effects_before, id + "跳跃普攻不留下地面痕迹")
	print("[空间攻击] ", id, " 小台面跳跃普攻：hits=", stats.received_hits, " jumped=", jumped, " skill=", skill_started, " final=", enemy.position, " spatial=", enemy._steering.spatial.status, "/", enemy._steering.spatial.last_failure)
	paused = true


func _blocked_jump(id: String, pedestal: StaticBody3D) -> void:
	var titan: bool = id == _lab.SEDIMENT_TITAN_ID
	pedestal.position.y = 2.5
	(pedestal.get_node("CollisionShape3D").shape as BoxShape3D).size.y = 5.0
	var enemy := await _spawn(id, Vector3(-10, 1.78 if titan else 0.855, -12.9 if titan else -13.45), Vector3(-10, 6.08, -15))
	_check(not enemy.trigger_jump_attack() and not enemy._attack_area.visible, id + "台子高于真实跳跃攻击能力时不空放")
	pedestal.position.y = 0.75
	(pedestal.get_node("CollisionShape3D").shape as BoxShape3D).size.y = 1.5
	_lab._player.position = Vector3(-10, 2.58, -15)
	var ceiling := _box(Vector3(-10, 4.0 if titan else 2.05, -12.5), Vector3(4, 0.2, 2.8))
	for _frame in range(3):
		await physics_frame
	_check(not enemy.trigger_jump_attack(), id + "头顶空间不足时不穿过顶板跳跃")
	ceiling.free()
	paused = true


func _large_platform() -> void:
	var enemy := await _spawn(_lab.SEDIMENT_TITAN_ID, Vector3(6, 1.78, 7), Vector3(6, 3.08, -5))
	var plan: Dictionary = enemy._plan_leap()
	_check(not plan.is_empty(), "大平台完整落脚且飞行通道畅通时可规划跃击：" + enemy._leap_plan_failure)
	enemy.ai_enabled = true
	var took_off := false
	var captured := false
	for _frame in range(200):
		await physics_frame
		took_off = took_off or enemy.current_state == enemy.State.LEAP_AIR
		if not captured and took_off and enemy.global_position.y > 4.0:
			captured = true
			await _capture_attack("titan_platform_leap", Vector3(8, 1.5, -5))
		if took_off and enemy.is_on_floor() and enemy.current_state != enemy.State.LEAP_AIR:
			break
	enemy.ai_enabled = false
	_check(took_off and enemy.global_position.y - 1.7 > 1.85, "泰坦实际跃上 2m 大平台，而不是只画落点")
	_check(_lab.get_stats_snapshot().received_hits > 0, "实际可达跃击范围结算伤害")
	print("[空间攻击] 大平台跃击：plan=", not plan.is_empty(), " airborne=", took_off, " final=", enemy.position)
	paused = true


func _box(at: Vector3, size: Vector3) -> StaticBody3D:
	var body := StaticBody3D.new()
	body.collision_layer = 1
	body.collision_mask = 0
	body.position = at
	var collision := CollisionShape3D.new()
	collision.name = "CollisionShape3D"
	var shape := BoxShape3D.new()
	shape.size = size
	collision.shape = shape
	body.add_child(collision)
	_lab.get_node("NavigationRegion3D").add_child(body)
	return body


func _capture_attack(title: String, at: Vector3) -> void:
	if not OS.get_cmdline_user_args().has("--capture-spatial-attacks") or DisplayServer.get_name() == "headless":
		return
	var before := paused
	paused = true
	_lab._interface.visible = false
	_lab._weapon_plate.visible = false
	_lab._player.aim_ui.visible = false
	_lab._player.get_node("PlayerModel").visible = true
	_lab._overview.global_position = at + Vector3(-6, 6, 7)
	_lab._overview.look_at(at)
	_lab._overview.current = true
	for _frame in range(5):
		await process_frame
	await RenderingServer.frame_post_draw
	var directory := "res://visual_captures/combat_spatial_attacks"
	DirAccess.make_dir_recursive_absolute(directory)
	root.get_texture().get_image().save_png(directory.path_join(title + ".png"))
	paused = before


func _check(condition: bool, message: String) -> void:
	if not condition:
		_failed = true
		push_error("[空间攻击] " + message)
