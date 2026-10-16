extends SceneTree
## I-131：真实玩家与正式泰坦在地图内部、双面三角地面上重复重叠落地。
const PlayerScene := preload("res://scenes/player.tscn")
const Spawner := preload("res://scripts/enemy_spawner.gd")
var _failures := 0

func _initialize() -> void:
	call_deferred("_run")

func _check(ok: bool, message: String) -> void:
	if not ok:
		_failures += 1
		push_error(message)

func _run() -> void:
	var flow := root.get_node("GameFlow")
	flow.set_meta(&"sparring_session_active", true)
	var world := Node3D.new()
	root.add_child(world)
	current_scene = world
	var floor := StaticBody3D.new()
	var shape := ConcavePolygonShape3D.new()
	shape.backface_collision = true
	shape.set_faces(PackedVector3Array([Vector3(-80,0,-80), Vector3(80,0,-80), Vector3(-80,0,80), Vector3(80,0,-80), Vector3(80,0,80), Vector3(-80,0,80)]))
	var collision := CollisionShape3D.new()
	collision.shape = shape
	floor.add_child(collision)
	world.add_child(floor)
	var player := PlayerScene.instantiate()
	player.position = Vector3(0, 1.01, 0)
	player.set_meta(&"experiment_invincible", true)
	world.add_child(player)
	var spawner := Node.new()
	spawner.set_script(Spawner)
	world.add_child(spawner)
	var titan: Node3D = spawner.spawn_boss("sediment_titan", Vector3(0,0,12))
	titan.ai_enabled = false
	titan._stop_action()
	titan.current_state = titan.State.IDLE
	titan.visual_root.position.y = titan.STANDING_VISUAL_Y
	titan.target = player
	for _frame in range(30):
		await physics_frame
	for offset: float in [0.0, 0.6, 1.0]:
		player.position = Vector3(offset, 1.01, 0)
		player.velocity = Vector3.ZERO
		titan.position = Vector3(0, titan.get_stand_height(), 12)
		titan._stop_action()
		titan.current_state = titan.State.IDLE
		titan._brain.cooldowns["leap"] = 0.0
		titan.attack_cooldown = 0.0
		for _frame in range(15):
			await physics_frame
		_check(titan.trigger_leap_attack(), "真实泰坦能规划并发动落地重叠复现")
		var lowest: float = player.position.y
		var airborne := false
		var entered_landing := false
		for _frame in range(180):
			await physics_frame
			airborne = airborne or titan.current_state == titan.State.LEAP_AIR
			if titan.current_state == titan.State.LEAP_AIR and not entered_landing:
				# 预警锁定后玩家仍能走入落点；原局落地时水平间距约0.95m。
				player.position = Vector3(titan._leap_landing.x + offset, 1.01, titan._leap_landing.z - 0.95)
				player.velocity = Vector3.ZERO
				entered_landing = true
			lowest = minf(lowest, player.position.y)
		_check(airborne and lowest >= 0.85, "跃击落地不把玩家压过地面：offset=%.1f lowest=%.4f" % [offset, lowest])
		_check(player.get_collision_exceptions().has(titan), "身体重叠时不会提前恢复阻挡")
		player.position += Vector3.RIGHT * 10.0
		for _frame in range(5):
			await physics_frame
		_check(not player.get_collision_exceptions().has(titan), "真实分离后恢复阻挡，不永久穿过Boss")
		print("[地面安全] offset=", offset, " lowest=", lowest)
	current_scene = null
	world.queue_free()
	await process_frame
	preload("res://scripts/object_pool.gd").clear_all()
	await preload("res://tools/probes/sparring/sparring_runtime.gd").settle_audio(self)
	flow.remove_meta(&"sparring_session_active")
	print("[泰坦落地玩家安全] failures=", _failures)
	quit(1 if _failures else 0)
