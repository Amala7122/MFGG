extends SceneTree
## Offline bake for the static walkability grid.
## 地图场景、网格尺寸、射线范围、身体数据、输出路径都来自 nav 数据，不在工具里写死：
## godot --headless --path . --script res://tools/probes/bake_walkability.gd \
##     -- --nav=res://data/navigation/sanctum_nav.json
const NavDatasetScript := preload("res://scripts/navigation/nav_dataset.gd")
const Walkability := preload("res://scripts/navigation/walkability_grid.gd")


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	var nav_path := ""
	for argument in OS.get_cmdline_user_args():
		if argument.begins_with("--nav="):
			nav_path = argument.trim_prefix("--nav=")
	if nav_path.is_empty():
		push_error("bake: 需要 --nav=res://data/navigation/*.json")
		quit(1)
		return
	var nav := NavDatasetScript.load_file(nav_path)
	if nav.is_empty():
		quit(1)
		return
	var profile := NavDatasetScript.load_profile(nav)
	if profile == null:
		quit(1)
		return
	var packed = load(String(nav["scene"]))
	if packed == null:
		push_error("bake: 场景加载失败 %s" % String(nav["scene"]))
		quit(1)
		return
	paused = false
	var initial = packed.instantiate()
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
	# 烘焙只针对静态场景：清掉敌人、停掉导演、把玩家碰撞从静态查询里摘出去，
	# 否则 0.76m 身体会把玩家/怪物所在的格子烘成 blocked。
	# 导演节点名是地图数据（nav.bake.directors），不在工具里写死。
	for director_name in nav.get("bake", {}).get("directors", []):
		var director := scene.find_child(String(director_name), true, false)
		if director != null:
			director.set_process(false)
			director.set_physics_process(false)
	for enemy in get_nodes_in_group("enemies"):
		enemy.queue_free()
	for player in get_nodes_in_group("player"):
		if player is CollisionObject3D:
			(player as CollisionObject3D).collision_layer = 0
	for _frame in 2:
		await process_frame
	var grid := Walkability.new()
	grid.configure_body(profile)
	grid.configure_rays(nav.grid)
	var extent := float(nav.grid.half_extent)
	var cell := float(nav.grid.cell_size)
	grid.build(scene.get_world_3d(), Vector2.ZERO, extent, cell)
	var output := String(nav["walkability"])
	var ok := grid.save_json(output)
	print("[bake] vertices=%d hits=%d body=%.2f/%.2f lift=%.2f clearance=%.2f cells=%.0f/%.1f ms=%.1f saved=%s ok=%s" % [
		grid.n * grid.n, grid.hit_count, grid.body_radius, grid.body_height,
		grid.body_lift, grid.body_clearance, extent, cell,
		grid.build_usec / 1000.0, output, str(ok)])
	quit(0 if ok else 1)
