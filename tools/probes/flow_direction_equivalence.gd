extends SceneTree
## 等价性验证：FlowField.direction_at 的“预计算方向数组”必须与原 8 邻居扫描逐格一致。
## 只读诊断：不修改地图/烘焙/参数；用 FodderField 的真实流场（含高度 profile）。
##
## 用法：
##   godot --headless --script res://tools/probes/flow_direction_equivalence.gd -- \
##     --artifact-dir=<run>

const MainScene := preload("res://scenes/sanctum_main.tscn")
const FodderScript := preload("res://scripts/prototypes/fodder_field.gd")
const NavDataset := preload("res://scripts/navigation/nav_dataset.gd")
const Terrain := preload("res://scripts/terrain_field.gd")
const NAV_PATH := "res://data/navigation/sanctum_nav.json"

const DIRECTIONS := [
	Vector2i(1, 0), Vector2i(-1, 0), Vector2i(0, 1), Vector2i(0, -1),
	Vector2i(1, 1), Vector2i(1, -1), Vector2i(-1, 1), Vector2i(-1, -1),
]
const UNREACHABLE := 1.0e19
const EPSILON := 1.0e-6


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
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

	var nav := NavDataset.load_file(NAV_PATH)
	var field := FodderScript.new()
	field.top_level = true
	scene.add_child(field)
	field.setup(player, null, 32, player.global_position, NavDataset.load_profile(nav), nav)
	var waited := 0
	while not bool(field.get("_flow_ready")) and waited < 900:
		await physics_frame
		waited += 1
	var flow = field.flow
	if flow == null or not bool(field.get("_flow_ready")):
		push_error("[flow_equiv] 流场未就绪")
		quit(1)
		return

	var n: int = flow._n
	var origin: Vector2 = flow._origin
	var cell: float = flow.cell_size
	var distance: PackedFloat32Array = flow._distance
	var edge_cache: PackedByteArray = flow._edge_cache
	var dirs: PackedVector2Array = flow._dirs
	print("[flow_equiv] n=%d dirs=%d cells=%d" % [n, dirs.size(), n * n])

	var mismatches := 0
	var checked := 0
	var worst := 0.0
	var first := ""
	for cell_index in n * n:
		var ix := cell_index % n
		var iz := int(cell_index / n)
		var world := Vector3(origin.x + (float(ix) + 0.5) * cell,
			Terrain.height_at(origin.x + (float(ix) + 0.5) * cell,
				origin.y + (float(iz) + 0.5) * cell),
			origin.y + (float(iz) + 0.5) * cell)
		var actual: Vector3 = flow.direction_at(world)
		var expected := _reference_direction(ix, iz, n, distance, edge_cache)
		checked += 1
		var error := actual.distance_to(expected)
		if error > worst:
			worst = error
		if error > EPSILON:
			mismatches += 1
			if first == "":
				first = "cell=(%d,%d) actual=%s expected=%s" % [ix, iz, str(actual), str(expected)]

	print("[flow_equiv] checked=%d mismatches=%d worst=%.9f %s" % [
		checked, mismatches, worst, first])
	print("[flow_equiv] ", "PASS" if mismatches == 0 else "FAIL")
	field.queue_free()
	quit(0 if mismatches == 0 else 1)


func _reference_direction(ix: int, iz: int, n: int,
		distance: PackedFloat32Array, edge_cache: PackedByteArray) -> Vector3:
	var index := iz * n + ix
	var current := distance[index]
	var best := current if current < UNREACHABLE else UNREACHABLE * 10.0
	var best_dx := 0
	var best_dz := 0
	for direction_index in DIRECTIONS.size():
		var direction: Vector2i = DIRECTIONS[direction_index]
		var nx: int = ix + direction.x
		var nz: int = iz + direction.y
		if nx < 0 or nz < 0 or nx >= n or nz >= n:
			continue
		if edge_cache[(index * DIRECTIONS.size()) + direction_index] == 0:
			continue
		var neighbor: int = nz * n + nx
		if distance[neighbor] >= UNREACHABLE:
			continue
		if distance[neighbor] < best:
			best = distance[neighbor]
			best_dx = direction.x
			best_dz = direction.y
	if best_dx == 0 and best_dz == 0:
		return Vector3.ZERO
	return Vector3(float(best_dx), 0.0, float(best_dz)).normalized()
