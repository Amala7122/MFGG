extends SceneTree
const Scene := preload("res://prototypes/combat/spatial/combat_spatial_lab.tscn")
const Query := preload("res://scripts/spatial_query.gd")
func _initialize() -> void:
	call_deferred("run")
func run() -> void:
	var lab := Scene.instantiate()
	root.add_child(lab)
	current_scene = lab
	for i in range(10):
		await process_frame
	lab._crowd_motion.button_pressed = false
	for id in [lab.MUD_GOLEM_ID, lab.FAST_BEAST_ID, lab.SEDIMENT_TITAN_ID]:
		lab.set_selection({id: 1})
		await lab.generate_round()
		var enemy: CharacterBody3D = lab._live_enemies[0]
		enemy.ai_enabled = false
		enemy.position = Vector3(6, float(Query.dimensions(enemy).half_height) + 0.08, 1.5)
		lab._player.position = Vector3(6, 3.08, -5)
		lab._start_fight()
		lab._player.process_mode = Node.PROCESS_MODE_DISABLED
		paused = false
		for i in range(250):
			await physics_frame
		var planner: RefCounted = enemy._steering.spatial._planner(lab._player)
		Query.debug = true
		print("[T03 route] ", id, " support=", Query.support(enemy, false), " goal=", planner.goal, " route=", planner.walk_route(enemy.position, planner.goal))
		Query.debug = false
		var map: RID = lab.get_node("NavigationRegion3D").get_navigation_map()
		var path := NavigationServer3D.map_get_path(map, enemy.position - Vector3.UP * float(Query.dimensions(enemy).half_height), Vector3(6, 2, -5), true)
		var previous := enemy.position
		for p in path:
			var hit := Query.floor_at(enemy, p, 0.35)
			if hit.is_empty():
				print("[T03 path] missingfloor ", p)
				continue
			var point := Query.body_on_floor(enemy, hit)
			print("[T03 path] ", previous, " -> ", point, " clear=", Query.ground_segment(enemy, previous, point, 0.3))
			previous = point
		paused = true
	current_scene = null
	lab.free()
	quit()
