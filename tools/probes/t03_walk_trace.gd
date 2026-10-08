extends SceneTree
const Scene := preload("res://prototypes/combat/spatial/combat_spatial_lab.tscn")
func _initialize() -> void:
	call_deferred("run")
func run() -> void:
	var lab := Scene.instantiate()
	root.add_child(lab)
	current_scene = lab
	for i in range(10): await process_frame
	lab._crowd_motion.button_pressed = false
	var args := OS.get_cmdline_user_args()
	var id: String = lab.SEDIMENT_TITAN_ID if args.has("--titan") else lab.FAST_BEAST_ID if args.has("--fast") else lab.MUD_GOLEM_ID
	lab.set_selection({id: 1})
	await lab.generate_round()
	var enemy: CharacterBody3D = lab._live_enemies[0]
	enemy.ai_enabled = false
	var half: float = preload("res://scripts/spatial_query.gd").dimensions(enemy).half_height
	enemy.position = Vector3(6, half + 0.08, 1.5)
	lab._player.position = Vector3(6, 3.08, -5)
	if args.has("--high"):
		var platform: StaticBody3D = lab.get_node("NavigationRegion3D/SpatialLayout/Geometry/Platform2m")
		platform.position.y = 2.5
		(platform.get_node("CollisionShape3D").shape as BoxShape3D).size.y = 5.0
		var ramp: StaticBody3D = lab.get_node("NavigationRegion3D/SpatialLayout/Geometry/PlatformRamp")
		ramp.position.y = 2.5
		ramp.rotation.z = -atan(5.0 / 6.0)
		(ramp.get_node("CollisionShape3D").shape as BoxShape3D).size.x = sqrt(61.0)
		lab.get_node("NavigationRegion3D").bake_navigation_mesh(false)
		lab._player.position = Vector3(6, 6.08, -3.0)
	if args.has("--down"):
		enemy.position = Vector3(-12, 2 + half + 0.08, -0.5)
		lab._player.position = Vector3(-12, 1.08, 12)
	if args.has("--walk"):
		enemy._steering.spatial.profile = preload("res://data/combat_spatial/ground.tres")
		enemy._steering.spatial.bind(enemy._tuning, {"can_attack": func(): return false})
		if id == lab.SEDIMENT_TITAN_ID:
			enemy._tuning.leap_enabled = false
			enemy._tuning.near_enter_distance = 0.1
			enemy._tuning.near_exit_distance = 0.2
			enemy._brain.cooldowns["slam"] = 1000.0
			enemy._brain.cooldowns["sweep"] = 1000.0
	lab._start_fight()
	lab._player.process_mode = Node.PROCESS_MODE_DISABLED
	paused = false
	for i in range(250): await physics_frame
	if args.has("--high"):
		var planner: RefCounted = enemy._steering.spatial._planner(lab._player)
		preload("res://scripts/spatial_query.gd").debug = true
		print("[T03 high route] ", planner.walk_route(enemy.global_position, planner.goal))
		preload("res://scripts/spatial_query.gd").debug = false
	enemy.ai_enabled = true
	for i in range(1200):
		await physics_frame
		if i % 30 == 0:
			var c: RefCounted = enemy._steering.spatial
			var segment: Dictionary = c.route.segments[c._segment_index] if not c.route.is_empty() and c._segment_index < c.route.segments.size() else {}
			print("[T03 walk] ", i, " at=", enemy.position, " v=", enemy.velocity, " state=", enemy.current_state, " status=", c.status, "/", c.last_failure, " cursor=", segment.get("_cursor", -1), " support=", preload("res://scripts/spatial_query.gd").support(enemy, false).get("position"))
		if lab.get_stats_snapshot().received_hits > 0:
			print("[T03 walk] HIT ", i)
			break
	current_scene = null
	lab.free()
	quit()
