extends SceneTree
## 接入前审计：每种敌人按自己的体型跑一遍炮灰分层/站位，先找特殊情况。
## 只读诊断：不改地图、烘焙、正式参数。
##
## 用法：
##   godot --headless --fixed-fps 60 --script res://tools/probes/enemy_fodder_fit_audit.gd -- \
##     --artifact-dir=<run> --count=200 --steps=180

const Artifacts := preload("res://scripts/artifact_paths.gd")
const MainScene := preload("res://scenes/sanctum_main.tscn")
const FodderScript := preload("res://scripts/prototypes/fodder_field.gd")
const NavDataset := preload("res://scripts/navigation/nav_dataset.gd")
const MovementProfileScript := preload("res://scripts/prototypes/movement_profile.gd")
const WalkabilityGridScript := preload("res://scripts/navigation/walkability_grid.gd")
const Catalog := preload("res://scripts/enemies/creature_catalog.gd")
const Terrain := preload("res://scripts/terrain_field.gd")
const NAV_PATH := "res://data/navigation/sanctum_nav.json"

const SPECIES := ["burst_crawler", "prism_spider", "charge_beetle", "mud_golem", "fast_beast"]
const SKIP := {"hornet": "飞行单位：悬停高度由 _air 控制，地面流场/分层不适用"}

var _count := 200
var _steps := 180
var _rows: Array[Dictionary] = []
var _bake_radius := 0.0


func _initialize() -> void:
	for argument in OS.get_cmdline_user_args():
		if argument.begins_with("--count="):
			_count = clampi(int(argument.trim_prefix("--count=")), 10, 2000)
		elif argument.begins_with("--steps="):
			_steps = maxi(30, int(argument.trim_prefix("--steps=")))
	call_deferred("_run")


func _run() -> void:
	var nav := NavDataset.load_file(NAV_PATH)
	var bake_profile = NavDataset.load_profile(nav)
	var grid = WalkabilityGridScript.new()
	grid.configure_body(bake_profile)
	grid.configure_rays(nav.grid)
	var loaded: bool = grid.load_json(String(nav.walkability))
	var blocked := 0
	for value in grid.blocked:
		blocked += int(value)
	_bake_radius = grid.body_radius
	print("[fit] bake loaded=%s n=%d cell=%.2f body=%.2f/%.2f lift=%.2f blocked=%d" % [
		str(loaded), grid.n, grid.cell_size, grid.body_radius, grid.body_height,
		grid.body_lift, blocked])

	var menu := MainScene.instantiate()
	root.add_child(menu)
	current_scene = menu
	for _index in 3:
		await process_frame
	var game_flow := root.get_node_or_null("GameFlow")
	game_flow.call("start_run")
	for _index in 360:
		await process_frame
		if current_scene != null and current_scene != menu \
				and not get_nodes_in_group("player").is_empty() \
				and not bool(game_flow.get("_preparing_run")):
			break
	var scene := current_scene as Node3D
	var player := get_nodes_in_group("player")[0] as Node3D
	player.set_meta(&"experiment_invincible", true)
	player.process_mode = Node.PROCESS_MODE_DISABLED
	for director_name in ["WaveDirector", "SurvivalDirector"]:
		var director := scene.find_child(director_name, true, false)
		if director != null:
			director.set_process(false)
			director.set_physics_process(false)
	for enemy in get_nodes_in_group("enemies"):
		enemy.queue_free()
	for _index in 2:
		await process_frame

	for id in SPECIES:
		await _audit_species(scene, player, nav, id)

	for id in SKIP:
		print("[fit] %s SKIP %s" % [id, SKIP[id]])
	_write_report()
	print("[fit] DONE")
	quit(0)


func _audit_species(scene: Node3D, player: Node3D, nav: Dictionary, id: String) -> void:
	var prepared: Dictionary = Catalog.prepare({"species": id})
	if prepared.is_empty():
		print("[fit] %s PREPARE_FAILED" % id)
		return
	var body_radius := float(prepared.get("body_radius", 0.0))
	var body_height := float(prepared.get("body_height", 0.0))
	var dimensions: Vector3 = prepared.get("body_dimensions", Vector3.ZERO)
	var profile := MovementProfileScript.new()
	profile.id = id
	profile.radius = body_radius
	profile.body_height = body_height
	profile.step_height = 0.7
	profile.max_slope_deg = 40.0
	profile.ignore_terrain = id == "prism_spider"
	profile.separation_radius = maxf(body_radius * 2.0 + 0.2, 1.2)
	profile.separation_strength = 1.1

	var field := FodderScript.new()
	field.top_level = true
	scene.add_child(field)
	field.setup(player, null, _count, player.global_position, profile, nav)
	var waited := 0
	while not bool(field.get("_flow_ready")) and waited < 900:
		await physics_frame
		waited += 1
	var ready := bool(field.get("_flow_ready"))
	field.set_spread_mode(2)
	for _index in _steps:
		await physics_frame

	var blocked_spawn := 0
	var distances: Array[float] = []
	var center := player.global_position
	for index in _count:
		var position: Vector3 = field._positions[index]
		if field._surface.blocked_at(position.x, position.z):
			blocked_spawn += 1
		distances.append(Vector2(position.x - center.x, position.z - center.z).length())
	distances.sort()
	var p10 := distances[int(float(distances.size()) * 0.1)] if not distances.is_empty() else 0.0
	var p50 := distances[int(float(distances.size()) * 0.5)] if not distances.is_empty() else 0.0
	var p90 := distances[int(float(distances.size()) * 0.9)] if not distances.is_empty() else 0.0
	var row := {
		"species": id,
		"body_radius": body_radius,
		"body_height": body_height,
		"dimensions": [dimensions.x, dimensions.y, dimensions.z],
		"bake_radius": _bake_radius,
		"ready": ready,
		"wait_steps": waited,
		"blocked_spawn": blocked_spawn,
		"stalled": field.stalled_units,
		"cheap": field.cheap_units,
		"far": field.far_units,
		"full": field.alive_count - field.cheap_units - field.far_units,
		"radius_p10": p10,
		"radius_p50": p50,
		"radius_p90": p90,
	}
	_rows.append(row)
	print("[fit] %s r=%.2f h=%.2f dims=(%.2f,%.2f,%.2f) ready=%s blocked_spawn=%d stalled=%d full/cheap/far=%d/%d/%d radius p10/50/90=%.1f/%.1f/%.1f" % [
		id, body_radius, body_height, dimensions.x, dimensions.y, dimensions.z, str(ready),
		blocked_spawn, field.stalled_units,
		row.full, row.cheap, row.far, p10, p50, p90])
	field.queue_free()
	for _index in 3:
		await process_frame




func _write_report() -> void:
	var report := {"count": _count, "steps": _steps, "rows": _rows}
	var directory := Artifacts.ensure_dir("reports")
	var path := directory.path_join("enemy_fodder_fit.json")
	var file := FileAccess.open(path, FileAccess.WRITE)
	if file != null:
		file.store_string(JSON.stringify(report, "\t") + "\n")
		file.close()
		print("[fit] report=%s" % path)
