extends "res://tests/test_navigation_stress.gd"
## 压力取样的每个区域都走同一套真实通道诊断，不按已知失败坐标选点。
func _run() -> void:
	lab = Lab.instantiate()
	root.add_child(lab)
	current_scene = lab
	for frame in range(1200):
		if lab.ready_for_test: break
		await process_frame
	if not lab.ready_for_test:
		push_error("压力诊断：主场景导航未同步")
		quit(1)
		return
	lab.set_process(false)
	lab.clear_actors()
	await _sample_area()
	Query.debug = true
	for argument in OS.get_cmdline_user_args():
		if not argument.begins_with("--report="): continue
		var records: Variant = JSON.parse_string(FileAccess.get_file_as_string(argument.trim_prefix("--report=")))
		if not records is Array:
			push_error("压力诊断：报告必须是失败测量体数组")
			quit(1)
			return
		for record: Dictionary in records:
			var at := Vector3(record.position[0], record.position[1], record.position[2])
			var actor: CharacterBody3D = lab.spawn_actor(at - Vector3.UP * 1.1, 0)
			actor.running = false
			actor.position = at
			lab.target.position = Vector3(record.goal[0], record.goal[1], record.goal[2])
			var goal := Query.body_on_floor(actor, Query.support(lab.target, false))
			print("[失败诊断] ", record.id, " ", at, " -> ", goal)
			print("[失败规划] ", record.id, " ", actor.steering.spatial._walking(at, goal))
		Query.debug = false
		lab.queue_free()
		await process_frame
		quit()
		return
	for index in range(anchors.size()):
		var actor: CharacterBody3D = lab.spawn_actor(anchors[index] - Vector3.UP * 1.1, index)
		actor.running = false
		var goal := Query.body_on_floor(actor, Query.support(lab.target, false))
		print("[分区诊断] ", index + 1, " ", actor.position, " -> ", goal)
		var route: Dictionary = actor.steering.spatial._walking(actor.position, goal)
		print("[分区结果] ", index + 1, " walk=", not route.is_empty(), " connected=", _connected(actor.position, goal))
	Query.debug = false
	current_scene = null
	lab.queue_free()
	await process_frame
	quit()
