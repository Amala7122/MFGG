extends SceneTree

const SpatialScene := preload("res://prototypes/combat/spatial/combat_spatial_lab.tscn")
const GroundMovement := preload("res://scripts/ground_movement.gd")
var _failed := false
var _lab: Node3D


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	_lab = SpatialScene.instantiate()
	root.add_child(_lab)
	current_scene = _lab
	for _frame in range(8):
		await process_frame
	_lab._crowd_motion.button_pressed = false
	for id: String in [_lab.MUD_GOLEM_ID, _lab.FAST_BEAST_ID, _lab.SEDIMENT_TITAN_ID]:
		await _climb(id, Vector3(0, 0, -5), Vector3(6, 3.08, -5), "绕右坡上 2m 平台")
		await _climb(id, Vector3(-12, 0, 12), Vector3(-12, 3.08, -0.5), "从坡脚上坡")
		await _climb(id, Vector3(6, 2, -5), Vector3(0, 1.08, 12), "从平台绕坡下地面", false)
		await _climb(id, Vector3(-12, 2, -0.5), Vector3(-12, 1.08, 12), "沿薄板下坡", false)
	await _step_limits()
	current_scene = null
	_lab.queue_free()
	await process_frame
	paused = false
	print("[空间导航] ", "FAIL" if _failed else "PASS")
	quit(1 if _failed else 0)


func _climb(id: String, start: Vector3, destination: Vector3, title: String, up := true) -> void:
	_lab.set_selection({id: 1})
	await _lab.generate_round()
	for _frame in range(4):
		await physics_frame
	var enemy: CharacterBody3D = _lab._live_enemies[0]
	var shape: Shape3D = enemy.get_node("CollisionShape3D").shape
	var height: float = shape.size.y if shape is BoxShape3D else shape.height
	var half_height := height * enemy.scale.y * 0.5
	enemy.position = start + Vector3.UP * (half_height + 0.08)
	enemy.velocity = Vector3.ZERO
	_lab._player.position = destination
	if id == _lab.FAST_BEAST_ID:
		enemy._normal_cooldown = 1000.0
		enemy._tuning.circle_outer_distance = 0.4
		enemy._tuning.circle_inner_distance = 0.2
		enemy._tuning.orbit_wait_min = 100.0
		enemy._tuning.orbit_wait_max = 100.0
		enemy._orbit_wait = 100.0
	elif id == _lab.SEDIMENT_TITAN_ID:
		enemy._tuning.leap_enabled = false
		enemy._tuning.mud_shield_enabled = false
		enemy._tuning.near_enter_distance = 0.1
		enemy._tuning.near_exit_distance = 0.2
		enemy._brain.cooldowns["slam"] = 1000.0
		enemy._brain.cooldowns["sweep"] = 1000.0
	else:
		enemy.attack_distance = 0.1
	# 本回归专测行走 / 跨坎，能力通行和默认选招另有 T03 行为回归。
	enemy._steering.spatial.profile = preload("res://data/combat_spatial/ground.tres")
	enemy._steering.spatial.bind(enemy._tuning, {"can_attack": func(): return false})
	_lab._start_fight()
	_lab._player.process_mode = Node.PROCESS_MODE_DISABLED
	paused = false
	var reached := false
	var used_route := false
	for _frame in range(2700):
		await physics_frame
		used_route = used_route or enemy._steering.has_path()
		var feet := enemy.global_position - Vector3.UP * half_height
		if (feet.y > 1.95 if up else feet.y < 0.15) and Vector2(feet.x - destination.x, feet.z - destination.z).length() < 1.4:
			reached = true
			break
	_check(used_route, id + "实际获得可达路径")
	_check(reached, id + " " + title + "，最终位置 " + str(enemy.position))
	print("[空间导航] ", id, " / ", title, "：", enemy.position, " route=", used_route, " reached=", reached)
	paused = true


func _check(condition: bool, message: String) -> void:
	if not condition:
		_failed = true
		push_error("[空间导航] " + message)


func _step_limits() -> void:
	for enemy: Node in _lab._live_enemies:
		enemy.process_mode = Node.PROCESS_MODE_DISABLED
	for item in [{"height": 0.14, "ceiling": false, "passes": true}, {"height": 1.0, "ceiling": false, "passes": false}, {"height": 0.14, "ceiling": true, "passes": false}]:
		var stage := Node3D.new()
		stage.position = Vector3(70, 0, 0)
		root.add_child(stage)
		_test_box(stage, Vector3(0, -0.5, 0), Vector3(12, 1, 8))
		_test_box(stage, Vector3(0, float(item.height) * 0.5, 0), Vector3(1, item.height, 5))
		if item.ceiling:
			_test_box(stage, Vector3(0, 1.73, 0), Vector3(12, 0.2, 8))
		var body := CharacterBody3D.new()
		body.position = Vector3(-2, 0.805, 0)
		body.collision_layer = 4
		body.collision_mask = 1
		var collider := CollisionShape3D.new()
		var shape := BoxShape3D.new()
		shape.size = Vector3(0.9, 1.55, 1.6)
		collider.shape = shape
		body.add_child(collider)
		stage.add_child(body)
		paused = false
		for _frame in range(20):
			await physics_frame
			body.velocity = Vector3(0, -0.5, 0)
			GroundMovement.move(body, 1.0 / 60.0)
		for _frame in range(200):
			await physics_frame
			body.velocity = Vector3(1.5, -0.5, 0)
			GroundMovement.move(body, 1.0 / 60.0)
		_check((body.position.x > 1.0) == bool(item.passes), "跨坎限制：高度 %s / 低顶 %s，位置 %s" % [item.height, item.ceiling, body.position])
		stage.free()
	paused = true
	print("[空间导航] 低边可跨，高台和低顶仍阻挡")


func _test_box(host: Node3D, at: Vector3, size: Vector3) -> void:
	var body := StaticBody3D.new()
	body.position = at
	body.collision_layer = 1
	body.collision_mask = 0
	var collision := CollisionShape3D.new()
	var shape := BoxShape3D.new()
	shape.size = size
	collision.shape = shape
	body.add_child(collision)
	host.add_child(body)
