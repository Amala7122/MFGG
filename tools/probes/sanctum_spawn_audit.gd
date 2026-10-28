extends SceneTree
## 圣所出怪落点审计：玩家在空场中心 vs 主路出生点时，实际敌人从多远、哪里出现。
##
## 只读：启动正式一局、保持正式波次配置，不改任何数据。玩家血量只做测试抬高，
## 避免在抽样期间死亡中断；不修改敌人、地图或波次参数。

const Artifacts := preload("res://scripts/artifact_paths.gd")
const ArenaUtil := preload("res://scripts/arena.gd")

const CENTER := Vector3(0.0, 1.0, -5.0)
const SPAWN := Vector3(0.0, 1.0, 46.0)
const CENTER_SECONDS := 26.0
const SPAWN_SECONDS := 20.0


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	var flow := root.get_node_or_null("GameFlow")
	if flow == null:
		push_error("缺少 GameFlow")
		quit(1)
		return
	var scene := load("res://scenes/sanctum_main.tscn").instantiate() as Node3D
	root.add_child(scene)
	current_scene = scene
	for _frame in 10:
		await process_frame
	flow.call("start_run")
	var player: Node3D
	for _frame in range(900):
		await process_frame
		if current_scene != null and current_scene != scene:
			player = current_scene.get_node_or_null("Players/Player") as Node3D
			if player != null:
				break
	if player == null:
		push_error("正式一局未生成玩家")
		quit(1)
		return
	player.set("max_health", 1.0e9)
	player.set("health", 1.0e9)
	player.set("max_shield", 1.0e9)
	player.set("shield", 1.0e9)
	var world: World3D = current_scene.get_world_3d()
	for _frame in range(1800):
		if NavigationServer3D.map_get_closest_point_owner(world.navigation_map, Vector3.ZERO).is_valid():
			break
		await physics_frame

	var arena := ArenaUtil.get_params()
	var wave := current_scene.get_node_or_null("Enemies/WaveDirector")
	var spawns: Array = []
	var seen: Dictionary = {}
	var phases: Array = []

	await _sample(player, wave, CENTER, CENTER_SECONDS, "court_center", arena, spawns, seen, phases)
	await _sample(player, wave, SPAWN, SPAWN_SECONDS, "player_spawn_road", arena, spawns, seen, phases)

	var report := {
		"arena": arena.get("_id", ""),
		"phases": phases,
		"spawns": spawns,
		"summary": _summarize(spawns),
	}
	var path := Artifacts.ensure_dir("reports").path_join("sanctum_spawn_audit.json")
	var file := FileAccess.open(path, FileAccess.WRITE)
	if file == null:
		push_error("审计报告写入失败")
		quit(1)
		return
	file.store_string(JSON.stringify(report, "\t") + "\n")
	file.close()
	print("[出怪审计] ", path)
	print("[出怪审计] ", JSON.stringify(report.summary))
	quit()


func _sample(player: Node3D, wave: Node, at: Vector3, seconds: float,
		label: String, arena: Dictionary, spawns: Array, seen: Dictionary, phases: Array) -> void:
	player.global_position = at
	for _frame in 30:
		await physics_frame
	var enemies := current_scene.get_node_or_null("Enemies")
	var started := Time.get_ticks_msec()
	var phase := {"name": label, "player": [at.x, at.y, at.z], "spawn_count": 0,
		"budget_start": int(wave.get("_spawn_budget")),
		"alive_start": int(wave.get("_alive").size())}
	while Time.get_ticks_msec() - started < int(seconds * 1000.0):
		await physics_frame
		if enemies == null:
			continue
		for child in enemies.get_children():
			var body := child as Node3D
			if body == null:
				continue
			var id := body.get_instance_id()
			if seen.has(id):
				continue
			seen[id] = true
			var pos := body.global_position
			var flat := Vector2(pos.x, pos.z)
			var player_flat := Vector2(player.global_position.x, player.global_position.z)
			spawns.append({
				"phase": label,
				"name": String(body.name),
				"position": [pos.x, pos.y, pos.z],
				"distance": flat.distance_to(player_flat),
				"inside_flat_mask": ArenaUtil.is_masked_out(arena, pos.x, pos.z),
				"t_ms": Time.get_ticks_msec() - started,
			})
			phase["spawn_count"] = int(phase["spawn_count"]) + 1
	phase["budget_end"] = int(wave.get("_spawn_budget"))
	phase["alive_end"] = int(wave.get("_alive").size())
	phases.append(phase)


func _summarize(spawns: Array) -> Dictionary:
	var out := {}
	for label in ["court_center", "player_spawn_road"]:
		var distances: Array = []
		var inside := 0
		for entry in spawns:
			if String(entry["phase"]) == label:
				distances.append(float(entry["distance"]))
				if bool(entry["inside_flat_mask"]):
					inside += 1
		distances.sort()
		if distances.is_empty():
			out[label] = {"count": 0}
			continue
		var under_30 := 0
		var under_40 := 0
		var over_60 := 0
		for value in distances:
			if value < 30.0:
				under_30 += 1
			if value < 40.0:
				under_40 += 1
			if value > 60.0:
				over_60 += 1
		out[label] = {
			"count": distances.size(),
			"min": distances[0],
			"max": distances[distances.size() - 1],
			"median": distances[distances.size() / 2],
			"under_30": under_30,
			"under_40": under_40,
			"over_60": over_60,
			"inside_flat_mask": inside,
		}
	return out
