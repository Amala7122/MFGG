extends SceneTree
## 正式圣所直战入口的沉积泰坦移动诊断：记录出生、追击、路线与空间能力状态。

const Artifacts := preload("res://scripts/artifact_paths.gd")
const BossLab := preload("res://prototypes/boss_lab/sediment_titan_boss_lab.tscn")
const SpatialQuery := preload("res://scripts/spatial_query.gd")

const FIND_LIMIT := 900
const SAMPLE_FRAMES := 720
const SAMPLE_INTERVAL := 30


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	var lab := BossLab.instantiate()
	root.add_child(lab)
	current_scene = lab
	var boss: CharacterBody3D
	var player: CharacterBody3D
	for _frame in range(FIND_LIMIT):
		boss = get_first_node_in_group("boss") as CharacterBody3D
		player = get_first_node_in_group("player") as CharacterBody3D
		if boss != null and player != null:
			break
		await process_frame
	if boss == null or player == null:
		push_error("正式直战入口未能生成 Boss 或玩家")
		quit(1)
		return

	# 诊断只观察追击，不让玩家在采样期间被击杀而令目标失效。
	player.max_health = 1000000.0
	player.health = player.max_health
	var start := boss.global_position
	var start_distance := _flat_distance(boss.global_position, player.global_position)
	var samples: Array[Dictionary] = []
	for frame in range(SAMPLE_FRAMES + 1):
		if frame % SAMPLE_INTERVAL == 0:
			samples.append(_sample(frame, boss, player, start))
		await physics_frame

	var dimensions: Dictionary = SpatialQuery.dimensions(boss)
	var steering: RefCounted = boss.get("_steering")
	var spatial: RefCounted = steering.spatial
	var final_distance := _flat_distance(boss.global_position, player.global_position)
	var report := {
		"start": _v3(start),
		"finish": _v3(boss.global_position),
		"travelled": _flat_distance(start, boss.global_position),
		"start_distance": start_distance,
		"final_distance": final_distance,
		"distance_closed": start_distance - final_distance,
		"configured_speed": boss.get("move_speed"),
		"effective_speed": boss.get("effective_move_speed"),
		"body_dimensions": dimensions,
		"steering_radius": steering.get("_body_radius"),
		"steering_height": steering.get("_body_height"),
		"agent_radius": steering._agent.radius,
		"agent_height": steering._agent.height,
		"has_path": steering.has_path(),
		"spatial_status": spatial.status,
		"last_failure": spatial.last_failure,
		"last_action": spatial.last_action,
		"leap_plan_failure": boss.get("_leap_plan_failure"),
		"combat_history": boss.get("_brain").history,
		"samples": samples,
	}
	var path := Artifacts.ensure_dir("reports").path_join("sediment_titan_boss_navigation.json")
	var file := FileAccess.open(path, FileAccess.WRITE)
	if file == null:
		push_error("无法写入诊断报告：%s" % path)
		quit(1)
		return
	file.store_string(JSON.stringify(report, "\t") + "\n")
	file.close()
	print("[沉积泰坦移动诊断] 路程=%.3f 接近=%.3f 状态=%s 失败=%s 动作=%s" % [
		report.travelled, report.distance_closed, report.spatial_status,
		report.last_failure, report.last_action])
	current_scene = null
	lab.queue_free()
	await process_frame
	quit()


func _sample(frame: int, boss: CharacterBody3D, player: CharacterBody3D, start: Vector3) -> Dictionary:
	var steering: RefCounted = boss.get("_steering")
	var spatial: RefCounted = steering.spatial
	return {
		"frame": frame,
		"position": _v3(boss.global_position),
		"travelled": _flat_distance(start, boss.global_position),
		"distance": _flat_distance(boss.global_position, player.global_position),
		"velocity": _v3(boss.velocity),
		"state": boss.get("current_state"),
		"status": spatial.status,
		"failure": spatial.last_failure,
		"action": spatial.last_action,
		"leap_failure": boss.get("_leap_plan_failure"),
		"chase_time": boss.get("_brain").chase_time,
		"far_time": boss.get("_brain").far_time,
		"leap_ready": boss.get("_brain").available("leap"),
		"route_segments": 0 if spatial.route.is_empty() else spatial.route.segments.size(),
		"route_job": spatial.get("_job") != null,
		"path_reachable": steering.has_path(),
	}


func _flat_distance(a: Vector3, b: Vector3) -> float:
	return Vector2(a.x - b.x, a.z - b.z).length()


func _v3(value: Vector3) -> Array[float]:
	return [value.x, value.y, value.z]
