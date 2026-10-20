extends SceneTree
## 六种真实战斗实体的平地/障碍接敌与晶兽扑击测量；不修改正式参数。
const Catalog := preload("res://scripts/enemies/creature_catalog.gd")
const Tuning := preload("res://scripts/prototypes/enemy_tuning.gd")
const Region := preload("res://scripts/navigation_region.gd")
const Flow := preload("res://scripts/game_flow.gd")
const Artifacts := preload("res://scripts/artifact_paths.gd")
const Terrain := preload("res://scripts/terrain_field.gd")
var world: Node3D
var player: Victim
var enemy: CharacterBody3D
var rows: Array = []
var failed := false
var _fixture_map := RID()

class Victim extends CharacterBody3D:
	var health := 1000000.0
	var hits := 0
	func take_damage(amount: float, _at := Vector3.ZERO, _scale := 1.0) -> void:
		health -= amount
		hits += 1

func _initialize() -> void:
	_run.call_deferred()

func _run() -> void:
	for frame in range(3): await process_frame
	Flow.instance.state = Flow.State.PLAYING
	Flow.instance.visible = false
	paused = false
	if OS.get_cmdline_user_args().has("--repeat-mud-rock"):
		for attempt in range(6): await _route("mud_golem", "rock")
		await _write_report()
		return
	if OS.get_cmdline_user_args().has("--path-debug"):
		await _fixture("charge_beetle", Vector3(0, 0, 8), Vector3(0, 0, -8), "low_wall")
		var planner := preload("res://scripts/spatial_route_planner.gd").new()
		planner.body = enemy
		planner.profile = enemy._steering.spatial.profile
		planner.capabilities = enemy._steering.spatial.capabilities
		planner.navigation_map = enemy._steering._agent.get_navigation_map()
		preload("res://scripts/spatial_query.gd").debug = true
		var end := player.global_position
		end.y = enemy.position.y
		var route := planner.walk_route(enemy.global_position, end)
		print("[Path debug] ", route)
		preload("res://scripts/spatial_query.gd").debug = false
		await _dispose()
		quit()
		return
	for distance: float in [3.5, 5.5, 7.0]:
		await _pounce(distance, false)
	await _pounce(5.5, true)
	for size: float in [0.8, 1.3]: await _pounce(5.5, false, size)
	await _short_beast()
	await _hornet_skill(false)
	await _hornet_skill(true)
	await _formal_pounces()
	if OS.get_cmdline_user_args().has("--formal-routes"):
		await _formal_routes()
	if not OS.get_cmdline_user_args().has("--pounce-only"):
		for species: String in Catalog.SPECIES:
			for kind: String in ["low_wall", "rock", "boulder"]:
				await _route(species, kind)
	await _write_report()

func _write_report() -> void:
	var file := FileAccess.open(Artifacts.ensure_dir("reports").path_join("creature_navigation.json"), FileAccess.WRITE)
	file.store_string(JSON.stringify({"passed": not failed, "rows": rows}, "\t") + "\n")
	file.close()
	await _dispose()
	preload("res://scripts/object_pool.gd").clear_all()
	await create_timer(0.8).timeout
	quit(1 if failed else 0)

func _box(at: Vector3, size: Vector3, label: String) -> void:
	var body := StaticBody3D.new()
	body.name = label
	body.position = at
	body.add_to_group("nav_source")
	var shape := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = size
	shape.shape = box
	body.add_child(shape)
	world.add_child(body)

func _values(profile: String) -> Dictionary:
	return Tuning.get_values(profile)

func _fixture(species: String, start: Vector3, goal: Vector3, obstacle := "", overrides: Dictionary = {}) -> void:
	await _dispose()
	world = Node3D.new()
	root.add_child(world)
	current_scene = world
	_box(Vector3(0, -0.5, 0), Vector3(70, 1, 70), "Floor")
	if obstacle == "low_wall": _box(Vector3(0, 0.6, 0), Vector3(9, 1.2, 1.5), "Wall")
	if obstacle == "rock": _box(Vector3(0, 1.5, 0), Vector3(4.5, 3, 4.5), "Rock")
	if obstacle == "boulder":
		var boulder := StaticBody3D.new()
		boulder.position.y = 0.8
		boulder.add_to_group("nav_source")
		var collider := CollisionShape3D.new()
		var sphere := SphereShape3D.new()
		sphere.radius = 2.3
		collider.shape = sphere
		boulder.add_child(collider)
		world.add_child(boulder)
	var region := NavigationRegion3D.new()
	region.set_script(Region)
	# 每例独立地图，避免上例异步移除命令与本例复用World默认地图交错。
	_fixture_map = NavigationServer3D.map_create()
	NavigationServer3D.map_set_active(_fixture_map, true)
	region.set_navigation_map(_fixture_map)
	world.add_child(region)
	for frame in range(1200):
		if region.is_baked() and NavigationServer3D.map_get_closest_point_owner(_fixture_map, Vector3.ZERO) == region.get_rid(): break
		await physics_frame
	# 本探针在同一World中连续拆建18张小网格；烘焙完成不等于服务器已合并。
	# 显式同步测试夹具的新地图，缺地图必须拒绝，不能把零点投影当成AI无路。
	if not region.is_baked() or NavigationServer3D.map_get_closest_point_owner(_fixture_map, Vector3.ZERO) != region.get_rid():
		failed = true
		push_error("障碍夹具导航尚未就绪：" + obstacle + " / " + species)
	player = Victim.new()
	player.collision_layer = 2
	player.collision_mask = 1
	player.add_to_group("player")
	var collider := CollisionShape3D.new()
	var capsule := CapsuleShape3D.new()
	capsule.radius = 0.4
	capsule.height = 1.8
	collider.shape = capsule
	player.add_child(collider)
	player.position = goal + Vector3.UP * 0.95
	world.add_child(player)
	var record: Dictionary = Catalog.SPECIES[species]
	var values := _values(record.profile)
	values.merge(overrides, true)
	enemy = record.scene.instantiate()
	enemy.set_meta(&"enemy_tuning", values)
	enemy.set_meta(&"crowd_uniform", true)
	enemy.set_meta(&"crowd_seed", 42)
	enemy.ai_enabled = false
	enemy.target = player
	var dimensions: Vector3 = enemy.get_script().get_body_dimensions(values)
	enemy.position = start + Vector3.UP * (dimensions.y * float(values.body_size) * 0.5 + 0.06)
	world.add_child(enemy)
	if species != "hornet": enemy._steering._agent.set_navigation_map(_fixture_map)
	if species == "hornet": enemy.position.y = enemy.get_spawn_height(0.0)
	for frame in range(12): await physics_frame

func _pounce(distance: float, dodge: bool, size := -1.0) -> void:
	await _fixture("fast_beast", Vector3.ZERO, Vector3(0, 0, -distance), "", {"body_size": size} if size > 0.0 else {})
	enemy.rotation.y = 0
	enemy.trigger_pounce()
	var row := {"kind": "pounce", "distance": distance, "dodge": dodge, "scale": enemy.scale.x, "started": enemy.current_state == enemy.State.POUNCE_WINDUP, "trace": [], "leaped": false}
	var last_state := -1
	var minimum := INF
	var dodged := false
	for frame in range(160):
		await physics_frame
		minimum = minf(minimum, enemy.global_position.distance_to(player.global_position))
		if enemy.current_state == enemy.State.POUNCE_LEAP: row.leaped = true
		if dodge and not dodged and enemy.current_state == enemy.State.POUNCE_LEAP:
			player.position.x += 5.0
			dodged = true
		if int(enemy.current_state) != last_state:
			last_state = enemy.current_state
			row.trace.append({"frame": frame, "state": last_state, "position": [enemy.position.x, enemy.position.y, enemy.position.z], "velocity": [enemy.velocity.x, enemy.velocity.y, enemy.velocity.z], "on_floor": enemy.is_on_floor(), "area_phase": enemy._attack_area.phase, "area_reach": enemy._attack_area.can_reach(player.global_position)})
	row["minimum_distance"] = minimum
	row["hits"] = player.hits
	row["valid"] = bool(row.started) and bool(row.leaped) and player.hits == (0 if dodge else 1)
	_record(row)

func _short_beast() -> void:
	await _fixture("fast_beast", Vector3.ZERO, Vector3(0, 0, -1.6))
	var started: bool = enemy.trigger_jump_attack()
	for frame in range(110): await physics_frame
	_record({"kind": "beast_close_attack", "started": started, "hits": player.hits, "valid": started and player.hits == 1})

func _hornet_skill(dive: bool) -> void:
	await _fixture("hornet", Vector3.ZERO, Vector3(0, 0, -8))
	if dive: enemy.trigger_swoop_dive()
	else: enemy.trigger_fire()
	var began: bool = enemy.current_state == (enemy.State.SWOOP_WINDUP if dive else enemy.State.PREPARE_FIRE)
	for frame in range(160): await physics_frame
	_record({"kind": "hornet_dive" if dive else "hornet_needle", "started": began, "hits": player.hits, "valid": began and player.hits == 1})

func _route(species: String, kind: String) -> void:
	var distance := 3.8 if kind == "boulder" else 8.0
	var start := Vector3(0, 0, distance)
	if species == "mud_golem" and kind == "rock" and OS.get_cmdline_user_args().has("--contact-start"):
		start.z = 2.76003
	await _fixture(species, start, Vector3(0, 0, -distance), kind)
	enemy.ai_enabled = true
	var row := {"kind": kind, "species": species, "states": {}, "samples": []}
	var minimum := INF
	var lateral := 0.0
	for frame in range(1200):
		await physics_frame
		minimum = minf(minimum, enemy.global_position.distance_to(player.global_position))
		lateral = maxf(lateral, absf(enemy.position.x))
		row.states[str(enemy.current_state)] = true
		if frame % 120 == 0:
			row.samples.append({"frame": frame, "position": [enemy.position.x, enemy.position.y, enemy.position.z], "diagnostic": enemy._steering.get_sparring_diagnostic() if species != "hornet" else {}})
		if player.hits > 0: break
	row["minimum_distance"] = minimum
	row["lateral_distance"] = lateral
	row["hits"] = player.hits
	if species == "burst_crawler":
		row["throws"] = enemy.throws
		row["behavior"] = {"state": enemy.visual.behavior.state, "clock": enemy.visual.behavior.clock}
	elif species == "prism_spider": row["shots"] = enemy.shots
	elif species == "charge_beetle": row["charges"] = enemy.charges
	row["valid"] = player.hits > 0
	if not row.valid and species != "hornet":
		var fresh: RefCounted = enemy._steering.spatial._planner(player, player.global_position, true)
		var nav: RID = enemy._steering._agent.get_navigation_map()
		var regions: Array = []
		for region: NavigationRegion3D in world.find_children("*", "NavigationRegion3D", true, false):
			regions.append({"id": str(region.get_rid()), "node_map": str(region.get_navigation_map()), "server_map": str(NavigationServer3D.region_get_map(region.get_rid())), "polygons": region.navigation_mesh.get_polygon_count(), "enabled": region.enabled})
		row["map_diagnostic"] = {"agent": str(nav), "world": str(world.get_world_3d().navigation_map), "iteration": NavigationServer3D.map_get_iteration_id(nav), "active": NavigationServer3D.map_is_active(nav), "server_regions": str(NavigationServer3D.map_get_regions(nav)), "regions": regions}
		preload("res://scripts/spatial_query.gd").debug = true
		while not fresh.done: fresh.advance(Time.get_ticks_usec() + 1000000)
		print("[Failed route fresh proof] stances=", fresh._stances, " result=", fresh.result)
		preload("res://scripts/spatial_query.gd").debug = false
	_record(row)

func _formal_pounces() -> void:
	await _dispose()
	var scene := preload("res://scenes/sanctum_main.tscn").instantiate()
	world = scene
	Flow.instance.state = Flow.State.MENU
	root.add_child(scene)
	current_scene = scene
	for frame in range(15): await process_frame
	scene.get_node("Enemies/WaveDirector").set_process(false)
	Flow.instance.state = Flow.State.PLAYING
	paused = false
	var actual: CharacterBody3D = scene.get_node("PlayerSpawner").spawn_player()
	actual.set_physics_process(false)
	actual.set_process_input(false)
	actual._wisp.set_process(false)
	actual._wisp.set_physics_process(false)
	for at: Vector2 in [Vector2(0, 10), Vector2(-8, 16), Vector2(20, 16), Vector2(34, -16), Vector2(-30, -20)]:
		for spread: bool in [false, true]:
			actual.health = 100
			actual.shield = 70
			actual._damage_invulnerability = 0.0
			actual.global_position = Vector3(at.x, Terrain.height_at(at.x, at.y) + 1.08, at.y)
			var values := _values("PrototypeFastBeast")
			enemy = Catalog.SPECIES.fast_beast.scene.instantiate()
			enemy.set_meta(&"enemy_tuning", values)
			enemy.set_meta(&"crowd_uniform", not spread)
			enemy.set_meta(&"crowd_seed", 42)
			enemy.ai_enabled = false
			enemy.target = actual
			var z := at.y + 5.5
			enemy.position = Vector3(at.x, Terrain.height_at(at.x, z) + 0.775 * float(values.body_size) + 0.06, z)
			scene.add_child(enemy)
			for frame in range(15): await physics_frame
			enemy.rotation.y = 0
			enemy.trigger_pounce()
			var row := {"kind": "formal_pounce", "at": [at.x, at.y], "variation": spread, "scale": enemy.scale.x, "started": enemy.current_state == enemy.State.POUNCE_WINDUP, "trace": [],
				"landing_ok": enemy._pounce_landing_ok(), "spec": {"speed": enemy.move_speed, "multiplier": enemy._p("pounce_speed_multiplier")}, "can_attack": enemy._spatial_can_attack()}
			var last := -1
			for frame in range(160):
				await physics_frame
				if int(enemy.current_state) != last:
					last = enemy.current_state
					row.trace.append({"frame": frame, "state": last, "position": [enemy.position.x, enemy.position.y, enemy.position.z], "on_floor": enemy.is_on_floor(), "can_reach": not enemy._attack_area.shape.is_empty() and enemy._attack_area.can_reach(actual.global_position)})
			row["damage"] = 170.0 - actual.health - actual.shield
			row["expected_hit"] = at != Vector2(34, -16)
			row["valid"] = bool(row.started) and float(row.damage) > 0.0 if row.expected_hit else not bool(row.started)
			_record(row)
			enemy.queue_free()
			await process_frame
	await _dispose()
	Flow.instance.state = Flow.State.PLAYING
	paused = false

func _formal_routes() -> void:
	await _dispose()
	var scene := preload("res://scenes/sanctum_main.tscn").instantiate()
	world = scene
	Flow.instance.state = Flow.State.MENU
	root.add_child(scene)
	current_scene = scene
	for frame in range(15): await process_frame
	scene.get_node("Enemies/WaveDirector").set_process(false)
	Flow.instance.state = Flow.State.PLAYING
	paused = false
	var actual: CharacterBody3D = scene.get_node("PlayerSpawner").spawn_player()
	actual.set_physics_process(false)
	actual.set_process_input(false)
	actual._wisp.set_process(false)
	actual._wisp.set_physics_process(false)
	var query := preload("res://scripts/spatial_query.gd")
	for species: String in Catalog.SPECIES:
		var record: Dictionary = Catalog.SPECIES[species]
		var values := _values(record.profile)
		enemy = record.scene.instantiate()
		enemy.set_meta(&"enemy_tuning", values)
		enemy.set_meta(&"crowd_uniform", true)
		enemy.set_meta(&"crowd_seed", 42)
		enemy.ai_enabled = false
		scene.add_child(enemy)
		var chosen := ""
		for boulder: Node in scene.get_node("Cover").get_children():
			if not String(boulder.name).begins_with("Boulder_"): continue
			var shape: CollisionShape3D = query.primary(boulder)
			if shape == null: continue
			var radius: float = shape.shape.radius
			var center: Vector3 = boulder.global_position
			var margin: float = radius + maxf(float(query.dimensions(enemy).radius), 0.6) + 0.8
			for angle: float in [0.0, 1.5708, 0.7]:
				var forward := Vector3.FORWARD.rotated(Vector3.UP, angle)
				var start := center - forward * margin
				var goal := center + forward * (radius + 1.4)
				actual.global_position = Vector3(goal.x, Terrain.height_at(goal.x, goal.z) + 1.08, goal.z)
				start.y = Terrain.height_at(start.x, start.z) + float(query.dimensions(enemy).half_height) + 0.12
				enemy.global_position = start
				enemy.rotation.y = angle
				if species == "hornet": enemy.position.y = enemy.get_spawn_height(actual.position.y)
				if query.motion_clear(enemy, enemy.global_transform, Vector3.ZERO) and query.motion_clear(actual, actual.global_transform, Vector3.ZERO):
					chosen = String(boulder.name)
					break
			if not chosen.is_empty(): break
		actual.health = 100
		actual.shield = 70
		actual._damage_invulnerability = 0.0
		enemy.target = actual
		for frame in range(10): await physics_frame
		enemy.ai_enabled = true
		var row := {"kind": "formal_obstacle", "species": species, "obstacle": chosen, "states": {}, "samples": []}
		for frame in range(1800):
			await physics_frame
			row.states[str(enemy.current_state)] = true
			if frame % 180 == 0:
				row.samples.append({"frame": frame, "position": [enemy.position.x, enemy.position.y, enemy.position.z], "diagnostic": enemy._steering.get_sparring_diagnostic() if species != "hornet" else {}})
			if actual.health + actual.shield < 169.99: break
		row["damage"] = 170.0 - actual.health - actual.shield
		row["valid"] = not chosen.is_empty() and float(row.damage) > 0.0
		_record(row)
		enemy.queue_free()
		await process_frame
		for projectile: Node in get_nodes_in_group("enemy_projectiles"): projectile.queue_free()
		for needle: Node in get_nodes_in_group("hornet_needles"): needle.queue_free()
	await _dispose()
	Flow.instance.state = Flow.State.PLAYING
	paused = false

func _record(row: Dictionary) -> void:
	rows.append(row)
	print("[Creature navigation] ", JSON.stringify(row))
	if not bool(row.valid) and OS.get_cmdline_user_args().has("--strict"):
		failed = true
		push_error("敌人接战回归失败：" + JSON.stringify(row))

func _dispose() -> void:
	if is_instance_valid(world):
		current_scene = null
		world.queue_free()
		await process_frame
		await physics_frame
	if _fixture_map.is_valid():
		NavigationServer3D.free_rid(_fixture_map)
		_fixture_map = RID()
