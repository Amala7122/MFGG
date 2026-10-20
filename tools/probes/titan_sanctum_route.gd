extends SceneTree
const Scene := preload("res://scenes/sanctum_main.tscn")
const Flow := preload("res://scripts/game_flow.gd")
const Artifacts := preload("res://scripts/artifact_paths.gd")

func _initialize() -> void:
	_run.call_deferred()

func _run() -> void:
	for frame in range(3): await process_frame
	Flow.instance.state = Flow.State.MENU
	paused = false
	var world: Node3D = Scene.instantiate()
	root.add_child(world)
	current_scene = world
	for frame in range(15): await process_frame
	world.get_node("Enemies/WaveDirector").set_process(false)
	Flow.instance.state = Flow.State.PLAYING
	paused = false
	var player: CharacterBody3D = world.get_node("PlayerSpawner").spawn_player()
	player.set_physics_process(false)
	player._wisp.set_physics_process(false)
	player.global_position = Vector3(39.5325, 1.823838, 46.01185)
	var boss: Node3D = world.get_node("Enemies/EnemySpawner").spawn_boss("sediment_titan", Vector3.ZERO)
	for frame in range(2): await physics_frame
	boss.ai_enabled = false
	for frame in range(180): await physics_frame
	boss.global_position = Vector3(25.760378, 2.470214, 49.804386)
	boss.velocity = Vector3.ZERO
	boss.target = player
	var planner: RefCounted = boss._steering.spatial._planner(player, player.global_position, true)
	while not planner.done: planner.advance(Time.get_ticks_usec() + 1000000)
	print("[Titan route initial] ", planner.result)
	boss.ai_enabled = true
	var rows: Array = []
	for frame in range(1800):
		await physics_frame
		if frame % 120 == 0:
			var contacts: Array = []
			for index in range(boss.get_slide_collision_count()):
				var contact: KinematicCollision3D = boss.get_slide_collision(index)
				contacts.append({"collider": str(contact.get_collider()), "normal": str(contact.get_normal())})
			rows.append({"frame": frame, "at": str(boss.global_position), "player": str(player.global_position), "velocity": str(boss.velocity), "state": boss.current_state, "above": boss._target_above(), "can_attack": boss._spatial_can_attack(), "diagnostic": boss._steering.get_sparring_diagnostic(), "route": boss._steering.spatial.route, "attacks": boss._brain.history.size(), "contacts": contacts})
	var file := FileAccess.open(Artifacts.ensure_dir("reports").path_join("route.json"), FileAccess.WRITE)
	file.store_string(JSON.stringify(rows, "\t"))
	file.close()
	print("[Titan route end] ", rows[-1])
	var valid: bool = boss._brain.history.size() > 0
	if not valid:
		var before: int = boss.current_state
		boss._sparring_decision = {"probe": true}
		var offset: Vector3 = player.global_position - boss.global_position
		boss._select_attack(Vector2(offset.x, offset.z).length())
		print("[Titan admission proof] before=", before, " after=", boss.current_state, " requires_heavy=", boss._brain.needs_heavy(boss.is_enraged), " decision=", boss._sparring_decision, " current=", boss.get_sparring_diagnostic())
	if not valid: push_error("泰坦在真实边坡位置连续追击后没有发动原生攻击")
	Flow.instance.state = Flow.State.MENU
	current_scene = null
	world.queue_free()
	await process_frame
	preload("res://scripts/object_pool.gd").clear_all()
	await create_timer(0.3).timeout
	quit(0 if valid else 1)
