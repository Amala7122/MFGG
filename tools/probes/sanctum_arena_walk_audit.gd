extends SceneTree
## 预览场景的可行走性检查：真的驱动 PreviewWalker 过门槛、下台阶、上台阶。
## 只读；不修改场景。用于确认“F6 能走进去”，不是战斗验收。

const LEVEL := preload("res://prototypes/sanctum_arena/sanctum_arena.tscn")


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	var scene := LEVEL.instantiate() as Node3D
	root.add_child(scene)
	current_scene = scene
	for _frame in 45:
		await physics_frame
	var walker := scene.get_node_or_null("Preview/PreviewWalker") as CharacterBody3D
	if walker == null:
		push_error("找不到 Preview/PreviewWalker")
		quit(1)
		return
	print("[走查] start=", walker.global_position)
	await _segment(walker, "spawn_to_court", walker.global_position, 0.0, 520)
	await _segment(walker, "court_to_nave", Vector3(0, 0.35, 4.0), 0.0, 300)
	await _segment(walker, "west_stair_down", Vector3(-20.6, 0.25, 11.5), -PI * 0.5, 170)
	await _segment(walker, "east_stair_up", Vector3(17.0, -1.1, 11.5), -PI * 0.5, 240)
	await _segment(walker, "inner_gate_side_door", Vector3(-24.0, 0.1, -1.0), 0.0, 160)
	await _segment(walker, "hall_to_east_garth", Vector3(10.0, 0.1, -10.0), -PI * 0.5, 150)
	await _segment(walker, "west_to_east_garth_south", Vector3(-24.0, 0.1, -20.0),
		PI, 160)
	await _segment(walker, "garth_rear_east", Vector3(-24.0, 0.1, -37.2),
		-PI * 0.5, 260)
	await _segment(walker, "east_garth_north", Vector3(24.0, 0.1, -37.2), 0.0, 170)
	await _segment(walker, "east_postern", Vector3(25.0, 0.1, 26.0), -PI * 0.5, 110)
	await _segment(walker, "postern_ledge_south", Vector3(31.2, 0.1, 26.0), PI, 100)
	await _segment(walker, "south_ledge_west", Vector3(31.2, 0.1, 31.8), PI * 0.5, 260)
	await _segment(walker, "approach_from_ledge", Vector3(11.0, 0.1, 31.8), 0.0, 260)
	await _segment(walker, "south_side_door_west", Vector3(-20.0, 0.1, 28.4), PI, 100)
	await _segment(walker, "south_side_door_east", Vector3(20.0, 0.1, 28.4), PI, 100)
	await _segment(walker, "west_garth_rear", Vector3(-22.0, 0.1, -20.0), 0.0, 250)
	await _segment(walker, "rear_east_garth", Vector3(-24.0, 0.1, -37.2), -PI * 0.5, 700)
	await _segment(walker, "east_garth_in", Vector3(22.0, 0.1, -37.2), PI, 250)
	await _segment(walker, "west_range_scriptorium", Vector3(-21.0, 0.1, -20.0),
		PI * 0.5, 180)
	await _segment(walker, "east_range_refectory", Vector3(21.0, 0.1, -18.0),
		-PI * 0.5, 180)
	await _segment(walker, "hospice_entry", Vector3(0.0, 0.1, 46.0), PI * 0.5, 240)
	await _segment(walker, "stable_entry", Vector3(0.0, 0.1, 46.0), -PI * 0.5, 240)
	await _segment(walker, "upper_cloister_north", Vector3(-24.0, 0.1, 24.0), 0.0, 480)
	await _segment(walker, "upper_landing_cross", Vector3(-18.0, 0.1, -3.0), -PI * 0.5, 300)
	await _segment(walker, "east_cloister_south", Vector3(24.0, 0.1, -2.0), PI, 320)
	quit()


func _segment(walker: CharacterBody3D, label: String, start: Vector3, yaw: float,
		frames: int) -> void:
	walker.global_position = start
	walker.rotation.y = yaw
	walker.velocity = Vector3.ZERO
	for _frame in 10:
		await physics_frame
	Input.action_press("move_forward")
	var samples: Array = []
	for index in frames:
		await physics_frame
		if index % 40 == 0:
			samples.append([index, walker.global_position])
	Input.action_release("move_forward")
	print("[走查] ", label, " start=", start, " end=", walker.global_position,
		" samples=", samples)
