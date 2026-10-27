extends SceneTree
## Offline bake for the static sanctum walkability grid. Run once when the map changes:
## godot --headless --path . --script res://tools/probes/bake_walkability.gd
const MainScene := preload("res://scenes/sanctum_main.tscn")
const Walkability := preload("res://scripts/navigation/walkability_grid.gd")
const OUTPUT := "res://data/navigation/sanctum_walkability.json"


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	paused = false
	var initial := MainScene.instantiate()
	root.add_child(initial)
	current_scene = initial
	for _frame in 3:
		await process_frame
	var game_flow := root.get_node_or_null("GameFlow")
	if game_flow == null:
		push_error("bake: GameFlow missing")
		quit(1)
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
	if scene == null:
		push_error("bake: scene missing")
		quit(1)
		return
	var grid := Walkability.new()
	grid.build(scene.get_world_3d(), Vector2.ZERO, 80.0, 1.0)
	var ok := grid.save_json(OUTPUT)
	print("[bake] vertices=%d hits=%d ms=%.1f saved=%s ok=%s" % [
		grid.n * grid.n, grid.hit_count, grid.build_usec / 1000.0, OUTPUT, str(ok)])
	quit(0 if ok else 1)
