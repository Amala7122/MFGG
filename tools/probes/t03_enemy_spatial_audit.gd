extends SceneTree
## T03 观察探针：默认 AI 与有路可走时的决策对照，不改变敌人实现。
## 使用 --headless --fixed-fps 60 --script res://tools/probes/t03_enemy_spatial_audit.gd。

const SpatialScene := preload("res://prototypes/combat/spatial/combat_spatial_lab.tscn")
var _lab: Node3D
var _observations: Array[Dictionary] = []


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	_lab = SpatialScene.instantiate()
	root.add_child(_lab)
	current_scene = _lab
	for frame in range(8):
		await process_frame
	_lab._crowd_motion.button_pressed = false
	for id: String in [_lab.MUD_GOLEM_ID, _lab.FAST_BEAST_ID, _lab.SEDIMENT_TITAN_ID]:
		await _observe(id, "2m_platform_default", Vector3(6, 0, 1.5), Vector3(6, 3.08, -5), 30.0)
		await _observe(id, "small_perch_default", Vector3(-10, 0, -9), Vector3(-10, 2.58, -15), 15.0)
	# 同一平台抬高到 5m，保留一条约 40° 的真实薄板坡，重新烘焙。
	var platform: StaticBody3D = _lab.get_node("NavigationRegion3D/SpatialLayout/Geometry/Platform2m")
	platform.position.y = 2.5
	(platform.get_node("CollisionShape3D").shape as BoxShape3D).size.y = 5.0
	var ramp: StaticBody3D = _lab.get_node("NavigationRegion3D/SpatialLayout/Geometry/PlatformRamp")
	ramp.position.y = 2.5
	ramp.rotation.z = -atan(5.0 / 6.0)
	(ramp.get_node("CollisionShape3D").shape as BoxShape3D).size.x = sqrt(61.0)
	_lab.get_node("NavigationRegion3D").bake_navigation_mesh(false)
	for frame in range(5):
		await physics_frame
	for id: String in [_lab.MUD_GOLEM_ID, _lab.FAST_BEAST_ID, _lab.SEDIMENT_TITAN_ID]:
		var front_z: float = -0.5 if id == _lab.SEDIMENT_TITAN_ID else -1.45
		await _observe(id, "5m_ramped_platform_default", Vector3(6, 0, front_z), Vector3(6, 6.08, -3.0), 25.0)
		if id != _lab.MUD_GOLEM_ID:
			await _observe(id, "5m_ramped_platform_close_stop_disabled", Vector3(6, 0, front_z), Vector3(6, 6.08, -3.0), 25.0, true)
	# 平台中央没有站立障碍，但上方顶板不能被当成玩家的落脚地板。
	await _ceiling_plan()
	await _edge_landing()
	await _local_retreat()
	var output := ProjectSettings.globalize_path("res://../visual_captures/t03_enemy_spatial_audit.json")
	var file := FileAccess.open(output, FileAccess.WRITE)
	if file:
		file.store_string(JSON.stringify(_observations, "  "))
		file.close()
	print("[T03 审核] 观察数据：", output)
	current_scene = null
	_lab.queue_free()
	await process_frame
	paused = false
	await create_timer(0.5).timeout
	quit()


func _spawn(id: String, ground: Vector3, target_at: Vector3) -> CharacterBody3D:
	seed(303003)
	_lab.set_selection({id: 1})
	await _lab.generate_round()
	var enemy: CharacterBody3D = _lab._live_enemies[0]
	enemy.ai_enabled = false
	var shape: Shape3D = enemy._collision.shape
	var height: float = shape.size.y if shape is BoxShape3D else shape.height
	enemy.position = ground + Vector3.UP * (height * enemy.scale.y * 0.5 + 0.08)
	_lab._player.position = target_at
	_lab._start_fight()
	_lab._player.process_mode = Node.PROCESS_MODE_DISABLED
	paused = false
	for frame in range(250):
		await physics_frame
	return enemy


func _observe(id: String, title: String, ground: Vector3, target_at: Vector3, duration: float, disable_close_stop := false) -> void:
	var enemy := await _spawn(id, ground, target_at)
	if disable_close_stop:
		# 唯一改动是缩小普通攻击距离，让目前的“在空中普通攻击距离内就停步”失效。
		enemy._tuning.normal_attack_reach = 0.1
	var map: RID = _lab.get_node("NavigationRegion3D").get_navigation_map()
	var start_nav := NavigationServer3D.map_get_closest_point(map, ground)
	var goal_nav := NavigationServer3D.map_get_closest_point(map, target_at - Vector3.UP * 1.08)
	var path := NavigationServer3D.map_get_path(map, start_nav, goal_nav, true)
	var path_reaches_floor := not path.is_empty() and absf(path[path.size() - 1].y - (target_at.y - 1.08)) < 0.3
	var result := {"case": title, "enemy": id, "path_points": path.size(), "path_reaches_target_floor": path_reaches_floor,
		"projected_goal": goal_nav, "first_hit_seconds": -1.0, "highest_feet": 0.0, "stationary_seconds": 0.0,
		"states": {}, "state_entries": {}, "melee_lock_can_hit": [], "observed_seconds": duration}
	var half_height: float = enemy._collision.shape.size.y * enemy.scale.y * 0.5 if enemy._collision.shape is BoxShape3D else enemy._collision.shape.height * enemy.scale.y * 0.5
	var previous := enemy.position
	var previous_state := -1
	var previous_phase := -1
	enemy.ai_enabled = true
	for frame in range(ceili(duration * 60.0)):
		# 固定位置靶不更新玩家 timers；清理这个测试引入的免伤冻结。
		_lab._player._damage_invulnerability = 0.0
		await physics_frame
		var state_name: String = enemy.State.keys()[enemy.current_state]
		result.states[state_name] = int(result.states.get(state_name, 0)) + 1
		if enemy.current_state != previous_state:
			result.state_entries[state_name] = int(result.state_entries.get(state_name, 0)) + 1
		previous_state = enemy.current_state
		if id == _lab.SEDIMENT_TITAN_ID and state_name in ["ATK_SLAM", "ATK_SWEEP"] and enemy._attack_area.phase == enemy._attack_area.Phase.LOCKED and previous_phase != enemy._attack_area.Phase.LOCKED:
			result.melee_lock_can_hit.append(enemy._attack_area.can_hit(_lab._player, enemy._attack_area.global_position))
		previous_phase = enemy._attack_area.phase
		result.highest_feet = maxf(float(result.highest_feet), enemy.position.y - half_height)
		if enemy.position.distance_to(previous) < 0.001:
			result.stationary_seconds += 1.0 / 60.0
		previous = enemy.position
		var stats: Dictionary = _lab.get_stats_snapshot()
		if float(result.first_hit_seconds) < 0.0 and int(stats.received_hits) > 0:
			result.first_hit_seconds = snappedf(float(frame + 1) / 60.0, 0.01)
		if enemy.position.y < -8.0:
			result.observed_seconds = float(frame + 1) / 60.0
			break
	enemy.ai_enabled = false
	var stats: Dictionary = _lab.get_stats_snapshot()
	result.hits = stats.received_hits
	result.final_position = enemy.position
	result.target_position = _lab._player.position
	result.final_state = enemy.State.keys()[enemy.current_state]
	result.current_nav_reachable = enemy._steering.has_path()
	if id == _lab.SEDIMENT_TITAN_ID:
		result.leap_plan_failure = enemy._leap_plan_failure
		result.jump_attack_possible = preload("res://scripts/jump_melee.gd").can_start(enemy, _lab._player, enemy._normal_attack_spec())
		result.leap_history = enemy._brain.history.duplicate(true)
	elif id == _lab.FAST_BEAST_ID:
		result.pounce_landing_possible = enemy._pounce_landing_ok()
		result.jump_attack_possible = preload("res://scripts/jump_melee.gd").can_start(enemy, _lab._player, enemy._normal_attack_spec())
		if disable_close_stop:
			var away: Vector3 = enemy.position - _lab._player.position
			away.y = 0.0
			var retreat: Vector3 = away.normalized() * enemy.move_speed
			result.requested_retreat_velocity = retreat
			result.nav_retreat_velocity = enemy._steering.ground_velocity(_lab._player.position, retreat, 1.0 / 60.0)
			result.retreat_body_clear = not enemy.test_move(enemy.global_transform, retreat.normalized() * 0.12)
	_observations.append(result)
	print("[T03 审核] ", JSON.stringify(result))
	paused = true


func _ceiling_plan() -> void:
	var platform: StaticBody3D = _lab.get_node("NavigationRegion3D/SpatialLayout/Geometry/Platform2m")
	platform.position.y = 0.25
	(platform.get_node("CollisionShape3D").shape as BoxShape3D).size.y = 0.5
	var enemy := await _spawn(_lab.FAST_BEAST_ID, Vector3(6, 0, 1.5), Vector3(6, 1.58, -5))
	var before: bool = enemy._pounce_landing_ok()
	var ceiling := StaticBody3D.new()
	ceiling.position = Vector3(6, 3.3, -5)
	var collision := CollisionShape3D.new()
	var shape := BoxShape3D.new()
	shape.size = Vector3(6, 0.2, 5)
	collision.shape = shape
	ceiling.add_child(collision)
	_lab.add_child(ceiling)
	for frame in range(3):
		await physics_frame
	var after: bool = enemy._pounce_landing_ok()
	var result := {"case": "overhead_floor_selection", "enemy": _lab.FAST_BEAST_ID,
		"landing_without_ceiling": before, "landing_with_clear_ceiling": after, "ceiling_bottom": 3.2,
		"actual_body_apex_top": enemy.position.y + enemy._collision.shape.size.y * 0.5 + pow(enemy._p("pounce_jump_speed"), 2) / (2.0 * enemy._p("gravity"))}
	_observations.append(result)
	print("[T03 审核] ", JSON.stringify(result))
	ceiling.queue_free()
	paused = true


func _edge_landing() -> void:
	var platform: StaticBody3D = _lab.get_node("NavigationRegion3D/SpatialLayout/Geometry/Platform2m")
	platform.position.y = 1.0
	(platform.get_node("CollisionShape3D").shape as BoxShape3D).size.y = 2.0
	var enemy := await _spawn(_lab.SEDIMENT_TITAN_ID, Vector3(6, 0, 7), Vector3(6, 3.08, -3))
	var edge: Dictionary = enemy._plan_leap()
	var edge_failure: String = enemy._leap_plan_failure
	_lab._player.position = Vector3(6, 3.08, -5)
	var center: Dictionary = enemy._plan_leap()
	var result := {"case": "wide_platform_edge_landing", "enemy": _lab.SEDIMENT_TITAN_ID,
		"edge_player_plan": not edge.is_empty(), "edge_failure": edge_failure, "center_player_plan": not center.is_empty()}
	_observations.append(result)
	print("[T03 审核] ", JSON.stringify(result))
	paused = true


func _local_retreat() -> void:
	var enemy := await _spawn(_lab.FAST_BEAST_ID, Vector3(0, 0, 10), Vector3(0, 1.08, 14))
	var goal := enemy.position + Vector3(0, 0.3, 0.5)
	var retreat: Vector3 = Vector3.FORWARD * enemy.move_speed
	var actual: Vector3 = enemy._steering.ground_velocity(goal, retreat, 1.0 / 60.0)
	var result := {"case": "local_retreat_at_nav_goal", "enemy": _lab.FAST_BEAST_ID,
		"requested_velocity": retreat, "actual_velocity": actual,
		"retreat_body_clear": not enemy.test_move(enemy.global_transform, Vector3.FORWARD * 0.12),
		"needs_route": enemy._steering.needs_route(goal)}
	_observations.append(result)
	print("[T03 审核] ", JSON.stringify(result))
	paused = true
