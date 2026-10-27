extends SceneTree
## Reachability audit: spawn a fresh 100-unit field around several open map points
## and require the horde to actually close distance. This is the automated version
## of the manual PathLab click loop.
const MainScene := preload("res://scenes/sanctum_main.tscn")
const Fodder := preload("res://scripts/prototypes/fodder_field.gd")
const Profile := preload("res://scripts/prototypes/movement_profile.gd")
const Terrain := preload("res://scripts/terrain_field.gd")

const POINTS := [
	Vector2(0, 0),
	Vector2(67, 38),
	Vector2(-30, 20),
	Vector2(40, -30),
	Vector2(20, 20),
	Vector2(-48, -20),
]
const WAIT_FRAMES := 180
const MIN_NEAR := 5

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
		_check(false, "formal scene/player ready")
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

	for point in POINTS:
		var field := Fodder.new()
		field.top_level = true
		scene.add_child(field)
		player.global_position = Vector3(point.x, Terrain.height_at(point.x, point.y) + 0.2, point.y)
		field.setup(player, null, 100, player.global_position, Profile.new())
		for _frame in WAIT_FRAMES:
			await physics_frame
		var near := 0
		var nearest := INF
		for position in field.live_positions():
			var distance := Vector2(position.x - point.x, position.z - point.y).length()
			nearest = minf(nearest, distance)
			if distance <= 4.0:
				near += 1
		print("[Fodder reachability] point=(%.1f, %.1f) near4=%d nearest=%.1f" % [
			point.x, point.y, near, nearest])
		_check(near >= MIN_NEAR, "point %s reaches player: near4=%d nearest=%.1f" % [
			str(point), near, nearest])
		field.queue_free()
		await process_frame
	_finish()


func _finish() -> void:
	print("[Fodder reachability] ", "PASS" if _failures == 0 else "FAIL")
	quit(0 if _failures == 0 else 1)
