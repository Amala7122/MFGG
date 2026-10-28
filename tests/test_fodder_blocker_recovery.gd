extends SceneTree
## Regression: units spawned/pushed into a body-blocked rock cell must be moved out.
const MainScene := preload("res://scenes/sanctum_main.tscn")
const Fodder := preload("res://scripts/prototypes/fodder_field.gd")
const NavDataset := preload("res://scripts/navigation/nav_dataset.gd")
const NAV_PATH := "res://data/navigation/sanctum_nav.json"
const Terrain := preload("res://scripts/terrain_field.gd")
const POINT := Vector2(67, 38)

var _failures := 0


func _initialize() -> void:
	call_deferred("_run")


func _check(ok: bool, text: String) -> void:
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
	if game_flow == null:
		_check(false, "GameFlow exists")
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
	if scene == null or get_nodes_in_group("player").is_empty():
		_check(false, "formal scene ready")
		_finish()
		return
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
	for _frame in 2:
		await process_frame
	player.global_position = Vector3(POINT.x, Terrain.height_at(POINT.x, POINT.y) + 0.2, POINT.y)
	var field := Fodder.new()
	field.top_level = true
	scene.add_child(field)
	var nav := NavDataset.load_file(NAV_PATH)
	field.setup(player, null, 100, player.global_position, NavDataset.load_profile(nav), nav)
	for _frame in 120:
		await physics_frame
	var blocked := 0
	for position in field.live_positions():
		if field.is_position_blocked(position):
			blocked += 1
	print("[Fodder blocker recovery] blocked=%d unstuck=%d" % [blocked, field.unstuck_count])
	_check(blocked == 0, "no live unit remains inside a body blocker: %d" % blocked)
	_check(field.unstuck_count > 0, "spawn recovery actually fired: %d" % field.unstuck_count)
	field.queue_free()
	await process_frame
	_finish()


func _finish() -> void:
	print("[Fodder blocker recovery] ", "PASS" if _failures == 0 else "FAIL")
	quit(0 if _failures == 0 else 1)
