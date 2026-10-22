extends "res://tools/probes/burst_crawler_perf.gd"
## Live-artifact golem horde profile; compare the same command on BASE and new branch.
## Preserves AI/navigation/attacks/hits/collision and visual animation.
## --count=30 for first acceptance, --count=100 for cannon-fodder scale.
## --realtime is essential for observing physics catch-up rather than fixed-tick sim.


func _initialize() -> void:
	_count = 30
	_warmup = 120
	_frames = 450
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--count="):
			_count = clampi(int(arg.trim_prefix("--count=")), 1, 200)
		elif arg.begins_with("--warmup="):
			_warmup = clampi(int(arg.trim_prefix("--warmup=")), 1, 600)
		elif arg.begins_with("--frames="):
			_frames = clampi(int(arg.trim_prefix("--frames=")), 120, 2400)
	call_deferred("_run")


func _run() -> void:
	if not await _start_formal_scene():
		quit(1)
		return
	_set_filter(true)
	await _phase("mud_golem_%d" % _count, true, true, "mud_golem", _count)
	var renderer := _scene.get_node_or_null("MudGolemRenderBatch") as MudGolemRenderBatch
	var row: Dictionary = _rows.back()
	var population_alive := 0
	var pose_nodes := 0
	for actor in _spawned:
		if is_instance_valid(actor) and not actor.is_queued_for_deletion():
			population_alive += 1
			pose_nodes += _descendants(actor)
	var result := {
		"count_requested": _count, "count_alive": population_alive,
		"frame_stats": row, "draw_calls": row.draw_calls, "physics_monitor_ms": row.physics_ms,
		"nodes_per_enemy_average": float(pose_nodes) / maxf(float(population_alive), 1.0),
		"batched_renderer": is_instance_valid(renderer),
		"batch_actor_count": renderer.actor_count() if renderer != null else 0,
		"batch_cells": renderer.batch_count() if renderer != null else 0,
		"batch_draw_groups": renderer.expected_draw_groups() if renderer != null else 0,
		"notes": [
			"All golems use their real AI, attack queue, navigation, physics and procedural animation.",
			"Do not use this static FPS window alone to certify attack activity: also run creature_navigation_audit and play.",
			"Frame timing depends on --realtime, process monitor is not pure script CPU.",
			"Base branch does not have this file; compare same scene using burst_crawler_perf.gd --species=mud_golem.",
		],
	}
	var output := Artifacts.ensure_dir("reports").path_join("mud_golem_horde_perf.json")
	var handle := FileAccess.open(output, FileAccess.WRITE)
	if handle == null:
		push_error("Failed to save mud horde report: " + output)
		quit(1)
		return
	handle.store_string(JSON.stringify(result, "  "))
	handle.close()
	print("[Mud horde] ", result)
	quit(0 if population_alive == _count else 1)


func _descendants(node: Node) -> int:
	var result := 0
	for child in node.get_children():
		result += 1 + _descendants(child)
	return result
