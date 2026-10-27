extends SceneTree
## Property test: every live FodderField unit must stay above the actual world surface.
## No hand-picked map coordinates: walk a grid around the spawn and sample every unit
## every physics frame. Any slope/rock/platform is covered by the same invariant.
const MainScene := preload("res://scenes/sanctum_main.tscn")
const Fodder := preload("res://scripts/prototypes/fodder_field.gd")
const FlowScript := preload("res://scripts/flow_field.gd")
const Profile := preload("res://scripts/prototypes/movement_profile.gd")
const Terrain := preload("res://scripts/terrain_field.gd")

const SAMPLES := 48
const FRAMES_PER_SAMPLE := 3
const PENETRATION_LIMIT := 0.08

var _failures := 0
var _checks := 0


func _initialize() -> void:
	call_deferred("_run")


func _check(ok: bool, text: String) -> void:
	_checks += 1
	if not ok:
		_failures += 1
		push_error(text)


func _run() -> void:
	paused = false
	var initial := MainScene.instantiate()
	root.add_child(initial)
	current_scene = initial
	for _frame in 3:
		await process_frame
	var game_flow := root.get_node_or_null("GameFlow")
	_check(game_flow != null, "GameFlow exists")
	if game_flow == null:
		_finish()
		return
	var old_scene := current_scene
	game_flow.call("start_run")
	for _frame in 360:
		await process_frame
		if current_scene != null and current_scene != old_scene \
				and not get_nodes_in_group("player").is_empty() \
				and not bool(game_flow.get("_preparing_run")):
			break
	var scene := current_scene as Node3D
	_check(scene != null and not get_nodes_in_group("player").is_empty(),
		"formal scene and player are ready")
	if scene == null or get_nodes_in_group("player").is_empty():
		_finish()
		return
	var player := get_nodes_in_group("player")[0] as Node3D
	player.set_meta(&"experiment_invincible", true)
	for director_name in ["WaveDirector", "SurvivalDirector"]:
		var director := scene.find_child(director_name, true, false)
		if director != null:
			director.set_process(false)
			director.set_physics_process(false)
	for enemy in get_nodes_in_group("enemies"):
		enemy.queue_free()
	for _frame in 2:
		await process_frame

	var flow := FlowScript.new()
	flow.rebuild(player.global_position)
	var field := Fodder.new()
	field.top_level = true
	scene.add_child(field)
	var profile := Profile.new()
	profile.id = "clearance_probe"
	field.setup(player, flow, 100, player.global_position, profile)
	for _frame in 240:
		await physics_frame
		if field.is_surface_ready():
			break
	_check(field.is_surface_ready(), "surface grid finished")
	if not field.is_surface_ready():
		field.queue_free()
		_finish()
		return

	var origin := player.global_position
	var worst_penetration := 0.0
	var worst_position := Vector3.ZERO
	var total_samples := 0
	var penetrating_samples := 0
	for sample in SAMPLES:
		if sample % 4 == 0:
			var column := sample % 8
			var row := int(sample / 8)
			var target := origin + Vector3(float(column - 4) * 8.0, 0.0, float(row - 3) * 8.0)
			player.global_position = Vector3(target.x,
				Terrain.height_at(target.x, target.z) + 1.0, target.z)
		for _frame in FRAMES_PER_SAMPLE:
			await physics_frame
			for position in field.live_positions():
				var query := PhysicsRayQueryParameters3D.create(
					Vector3(position.x, position.y + 2.0, position.z),
					Vector3(position.x, position.y - 5.0, position.z), 1)
				var hit := field.get_world_3d().direct_space_state.intersect_ray(query)
				total_samples += 1
				var penetration := 0.0
				if not hit.is_empty():
					penetration = float(hit.position.y) - (position.y - field.body_offset())
				var terrain_penetration := Terrain.height_at(position.x, position.z) \
					+ field.body_offset() - position.y
				penetration = maxf(penetration, terrain_penetration)
				if penetration > worst_penetration:
					worst_penetration = penetration
					worst_position = position
				if penetration > PENETRATION_LIMIT:
					penetrating_samples += 1
	_check(total_samples >= 5000, "sampled at least 5000 unit-frames")
	_check(penetrating_samples == 0,
		"no unit below world surface: %d samples, worst %.3fm at %s" % [
			penetrating_samples, worst_penetration, str(worst_position)])
	print("[Fodder terrain clearance] samples=%d checks=%d failures=%d worst=%.3fm" % [
		total_samples, _checks, _failures, worst_penetration])
	field.queue_free()
	await process_frame
	_finish()


func _finish() -> void:
	print("[Fodder terrain clearance] ", "PASS" if _failures == 0 else "FAIL")
	quit(0 if _failures == 0 else 1)
