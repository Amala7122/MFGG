extends "res://tools/probes/burst_crawler_perf.gd"
## Lab-only A/B probe: one fixed golem population per process.
## The same file is committed to the base and PR14 lab branches, so the only
## variable between runs is the implementation under test.
## Keeps the formal sanctum scene, real AI/navigation/attacks/physics, the
## sketch filter, and the player walking. Reports frame stats, node counts,
## optional batch-renderer stats, an attack/approach behaviour window and one
## screenshot, so a frame-time win cannot hide a behaviour loss.

var _behaviour_frames := 180


func _initialize() -> void:
	_count = 30
	_warmup = 120
	_frames = 450
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--count="):
			_count = clampi(int(arg.trim_prefix("--count=")), 1, 200)
		elif arg.begins_with("--warmup="):
			_warmup = clampi(int(arg.trim_prefix("--warmup=")), 0, 600)
		elif arg.begins_with("--frames="):
			_frames = clampi(int(arg.trim_prefix("--frames=")), 30, 1200)
		elif arg.begins_with("--behaviour="):
			_behaviour_frames = clampi(int(arg.trim_prefix("--behaviour=")), 0, 900)
	call_deferred("_run")


func _run() -> void:
	if not await _start_formal_scene():
		quit(1)
		return
	_set_filter(true)
	await _phase("golem_%d" % _count, true, true, "mud_golem", _count)
	var row: Dictionary = _rows.back()
	var behaviour: Dictionary = await _behaviour_window()
	var population := 0
	var descendants := 0
	for actor in _spawned:
		if is_instance_valid(actor) and not actor.is_queued_for_deletion():
			population += 1
			descendants += _descendants(actor)
	var graphics := DisplayServer.get_name() != "headless"
	var screenshot := ""
	if graphics:
		screenshot = await _capture("golem_%d.png" % _count)
	var result := {
		"count_requested": _count,
		"count_alive": population,
		"frame_stats": row,
		"draw_calls": row.draw_calls,
		"primitives": row.primitives,
		"physics_ms": row.physics_ms,
		"process_ms": row.process_ms,
		"nodes_total": int(Performance.get_monitor(Performance.OBJECT_NODE_COUNT)),
		"objects_total": int(Performance.get_monitor(Performance.OBJECT_COUNT)),
		"nodes_per_enemy_average": float(descendants) / maxf(float(population), 1.0),
		"batch": _batch_stats(),
		"behaviour": behaviour,
		"filter": "sketch",
		"warmup_frames": _warmup,
		"measured_frames": _frames,
		"behaviour_frames": _behaviour_frames,
		"window": [_window.x, _window.y],
		"render_texture": [root.get_texture().get_width(), root.get_texture().get_height()] if graphics else [],
		"screenshot": screenshot,
	}
	var path := Artifacts.ensure_dir("reports").path_join("lab_mud_horde.json")
	var handle := FileAccess.open(path, FileAccess.WRITE)
	if handle == null:
		push_error("lab probe: cannot write " + path)
		quit(1)
		return
	handle.store_string(JSON.stringify(result, "  "))
	handle.close()
	print("[lab] count=%d alive=%d avg=%.2f p50=%.2f p95=%.2f draw=%d nodes=%d" % [
		_count, population, row.avg_ms, row.p50_ms, row.p95_ms, row.draw_calls,
		int(Performance.get_monitor(Performance.OBJECT_NODE_COUNT))])
	quit(0 if population == _count else 1)


func _batch_stats() -> Dictionary:
	var node := _scene.get_node_or_null("MudGolemRenderBatch")
	if node == null:
		return {"present": false}
	var visible := 0
	for child in node.find_children("*", "MultiMeshInstance3D", true, false):
		var instance := child as MultiMeshInstance3D
		if instance != null and instance.multimesh != null:
			visible += instance.multimesh.visible_instance_count
	return {
		"present": true,
		"actor_count": int(node.call("actor_count")),
		"batch_count": int(node.call("batch_count")),
		"draw_groups": int(node.call("expected_draw_groups")),
		"visible_instances": visible,
	}


func _behaviour_window() -> Dictionary:
	var attackers := {}
	var closest := {}
	var attack_samples := 0
	var samples := 0
	var near_samples := 0
	var min_distance := INF
	var total_distance := 0.0
	for frame in _behaviour_frames:
		_advance_view()
		await process_frame
		if frame % 6 != 0:
			continue
		var player_position := _player.global_position
		for actor in _spawned:
			if not is_instance_valid(actor) or actor.is_queued_for_deletion():
				continue
			var position: Vector3 = actor.global_position
			var distance := Vector2(position.x - player_position.x,
				position.z - player_position.z).length()
			var id := actor.get_instance_id()
			min_distance = minf(min_distance, distance)
			total_distance += distance
			samples += 1
			closest[id] = minf(float(closest.get(id, INF)), distance)
			if distance <= 2.4:
				near_samples += 1
			# ProceduralMudGolem.State.ATTACK == 2 on both branches.
			if int(actor.get("current_state")) == 2:
				attack_samples += 1
				attackers[id] = true
	var stuck := 0
	for id in closest:
		if float(closest[id]) > 3.0:
			stuck += 1
	return {
		"frames": _behaviour_frames,
		"samples": samples,
		"attacking_actors": attackers.size(),
		"attack_state_samples": attack_samples,
		"min_distance_m": min_distance,
		"mean_distance_m": total_distance / maxf(float(samples), 1.0),
		"near_samples": near_samples,
		"actors_never_nearer_than_3m": stuck,
	}


func _capture(file_name: String) -> String:
	await process_frame
	await RenderingServer.frame_post_draw
	var image := root.get_texture().get_image()
	if image == null or image.is_empty():
		return ""
	var path := Artifacts.ensure_dir("screenshots").path_join(file_name)
	return path if image.save_png(path) == OK else ""

func _descendants(node: Node) -> int:
	var result := 0
	for child in node.get_children():
		result += 1 + _descendants(child)
	return result
