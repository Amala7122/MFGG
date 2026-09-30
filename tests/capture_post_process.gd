extends SceneTree
## Capture each screen effect against the same paused game frame for visual review.

const MainScene := preload("res://scenes/hyrule_field.tscn")
const CapturePaths := preload("res://scripts/capture_paths.gd")
const STYLE_NAMES := ["off", "black_white_tv", "crt", "old_photo", "invert"]


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	var scene := MainScene.instantiate()
	root.add_child(scene)
	current_scene = scene
	for _frame in range(3):
		await process_frame
	var flow := root.get_node_or_null("GameFlow") as CanvasLayer
	var effect := root.get_node_or_null("PostProcess")
	var settings := root.get_node_or_null("DisplaySettings")
	if flow == null or effect == null or settings == null:
		push_error("Post-process capture needs GameFlow, PostProcess, and DisplaySettings autoloads")
		quit(1)
		return
	var old_scene := current_scene
	flow.call("start_run")
	for _frame in range(120):
		await process_frame
		if current_scene != null and current_scene != old_scene:
			break
	if current_scene == old_scene:
		push_error("Post-process capture could not start the game")
		quit(1)
		return
	for _frame in range(30):
		await process_frame
	paused = true
	var output_dir := CapturePaths.ensure_dir("post_process")
	for style in STYLE_NAMES.size():
		settings.set("post_process_style", style)
		settings.call("_apply_post_process")
		await process_frame
		await RenderingServer.frame_post_draw
		var image := root.get_texture().get_image()
		var path := output_dir.path_join("%d_%s.png" % [style, STYLE_NAMES[style]])
		if image.save_png(path) != OK:
			push_error("Post-process capture failed: %s" % path)
			quit(1)
			return
		print("[后处理验收] %s" % path)
	quit()
