extends SceneTree
const Lab := preload("res://prototypes/painterly_lab/painterly_style_lab.tscn")
const Artifacts := preload("res://scripts/artifact_paths.gd")

func _initialize() -> void:
	_run.call_deferred()

func _run() -> void:
	for frame in 12:
		await process_frame
	var lab = Lab.instantiate()
	root.add_child(lab)
	current_scene = lab
	root.size = Vector2i(1600, 900)
	root.content_scale_factor = 1
	var output := Artifacts.ensure_dir("screenshots", "woodblock")
	if "--cut-scale-check" in OS.get_cmdline_user_args():
		await _capture_cut_scale(lab, output)
		lab.free()
		quit()
		return
	for scene in [0, 1]:
		lab.set_scene(scene)
		for style in [0, 7]:
			lab.set_style(style)
			lab.set_lighting(0)
			lab.ui.visible = false
			for view in [0, 2]:
				lab.set_view(view)
				for frame in 12:
					await process_frame
				await RenderingServer.frame_post_draw
				var error := root.get_texture().get_image().save_png(output.path_join("scene_%d_style_%d_view_%d.png" % [scene, style, view]))
				if error != OK:
					push_error("Capture failed")
					quit(1)
					return
	lab.set_scene(0)
	lab.set_lighting(2)
	lab.set_view(2)
	for frame in 12:
		await process_frame
	await RenderingServer.frame_post_draw
	root.get_texture().get_image().save_png(output.path_join("night_flashlight.png"))
	lab.set_lighting(0)
	lab.set_view(0)
	lab.ui.visible = true
	for frame in 12:
		await process_frame
	await RenderingServer.frame_post_draw
	root.get_texture().get_image().save_png(output.path_join("controls.png"))
	print("WOODBLOCK_CAPTURE: ", output)
	lab.free()
	quit()

func _capture_cut_scale(lab: Node, output: String) -> void:
	lab.set_scene(0)
	lab.set_style(7)
	lab.set_lighting(0)
	lab.set_view(2)
	lab.ui.visible = false
	var images: Array[Image] = []
	var values := [0.3, 1.0, 3.0]
	for value: float in values:
		lab.set("cut_scale", value)
		lab.set_style(7)
		for frame in 12:
			await process_frame
		await RenderingServer.frame_post_draw
		var picture := root.get_texture().get_image()
		var error := picture.save_png(output.path_join("cut_scale_%.1f.png" % value))
		if error != OK:
			push_error("刀刻尺度对照截图失败")
			return
		images.append(picture)
	var mean_difference := 0.0
	var changed := 0
	var samples := 0
	# Fixed camera: sample the central gate and nearby foliage, excluding sky
	# and ground. This checks visible rendered change, not just a uniform value.
	for y in range(220, 560, 2):
		for x in range(650, 1360, 2):
			var a := images[0].get_pixel(x, y)
			var b := images[2].get_pixel(x, y)
			var difference := (absf(a.r - b.r) + absf(a.g - b.g) + absf(a.b - b.b)) / 3.0
			mean_difference += difference
			if difference > 0.035:
				changed += 1
			samples += 1
	var report := {"scales": values, "mean_rgb_difference": mean_difference / samples,
		"visibly_changed_fraction": float(changed) / samples,
		"region": [650, 220, 710, 340], "resolution": [1600, 900]}
	var file := FileAccess.open(Artifacts.ensure_dir("reports").path_join("cut_scale_check.json"), FileAccess.WRITE)
	if file == null:
		push_error("刀刻尺度对照报告写入失败")
		return
	file.store_string(JSON.stringify(report, "\t") + "\n")
	print("CUT_SCALE_CHECK: ", JSON.stringify(report))
