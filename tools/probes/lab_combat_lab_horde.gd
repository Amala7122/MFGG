extends SceneTree
## Lab diagnostic: drive the real combat lab to N mud golems, wait for the fight,
## verify the scene-level shared batch, and capture a screenshot.
## This is not an acceptance test; it exists so "playable by hand" can be checked
## without a human at the mouse.

const Artifacts := preload("res://scripts/artifact_paths.gd")
const COUNT := 30


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	var scene: PackedScene = load("res://prototypes/combat_lab/combat_lab.tscn")
	var lab: Node = scene.instantiate()
	root.add_child(lab)
	current_scene = lab
	for _frame in 3:
		await process_frame
	lab.call("set_selection", {"PrototypeMudGolem": COUNT})
	for _frame in 3:
		await process_frame
	lab.call("generate_round")
	# Realtime 下帧率会被无上限拉高，按墙钟等倒计时，不能按帧数等。
	var wait_deadline := Time.get_ticks_msec() + 20000
	while Time.get_ticks_msec() < wait_deadline and int(lab.get("state")) != 2:
		await process_frame
	var waited := int(lab.get("state"))
	# Let the horde close in and attack before the screenshot.
	var fight_deadline := Time.get_ticks_msec() + 8000
	while Time.get_ticks_msec() < fight_deadline:
		await process_frame
	var alive: int = (lab.get("_live_enemies") as Array).size()
	var batch: Node = lab.get_node_or_null("MudGolemRenderBatch")
	var result := {"count": COUNT, "alive": alive, "state": waited,
		"batch_present": batch != null}
	if batch != null:
		result["batch_actors"] = int(batch.call("actor_count"))
		result["batch_cells"] = int(batch.call("batch_count"))
		result["draw_groups"] = int(batch.call("expected_draw_groups"))
	print("[play probe] ", JSON.stringify(result))
	var overlay_label := root.get_node_or_null("FpsOverlay/FpsOverlayPanel/FpsOverlayLabel") as Label
	print("[play probe] engine_fps=", Engine.get_frames_per_second(),
		" overlay=", overlay_label.text if overlay_label != null else "none")
	var path := Artifacts.ensure_dir("screenshots").path_join("combat_lab_%d.png" % COUNT)
	await RenderingServer.frame_post_draw
	var image := root.get_texture().get_image()
	var saved := image != null and image.save_png(path) == OK
	print("[play probe] screenshot=", path if saved else "FAILED")
	var ok := alive == COUNT and batch != null and int(batch.call("actor_count")) == COUNT and saved
	quit(0 if ok else 1)
