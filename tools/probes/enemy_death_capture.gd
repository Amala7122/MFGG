extends SceneTree
const Lab = preload("res://prototypes/visual_lab/enemy_visual_lab.tscn")
const Capture = preload("res://scripts/capture_paths.gd")

func _initialize() -> void:
	run.call_deferred()

func run() -> void:
	var lab := Lab.instantiate()
	root.add_child(lab)
	current_scene = lab
	await process_frame
	var output := Capture.ensure_dir("enemy_deaths")
	for index in lab.GALLERY.size():
		var id := String(lab.GALLERY[index].profile)
		if not id.begins_with("Visual"):
			continue
		lab.call("_show_subject", index)
		await process_frame
		var subject: Node3D = lab.get("_subject")
		subject.process_mode = Node.PROCESS_MODE_DISABLED
		lab.call("_set_distance", 9.5)
		(lab.get_node("CameraRig") as Node3D).position.y = 0.8
		var values: Dictionary = subject.get("values")
		for shot in ["alive", "prepare", "action", "twitch", "corpse", "timeline"]:
			subject.call("set_preview_pose", 0 if shot == "alive" else subject.call("death_pose_index"))
			var time := 0.0
			if shot == "prepare":
				time = float(values.death_prepare) * 0.65
			if shot == "action":
				time = float(values.death_prepare) + float(values.death_action) * 0.35
			if shot == "twitch":
				time = float(values.death_prepare) + float(values.death_action) + 0.2
			if shot == "corpse" or shot == "timeline":
				time = float(subject.call("get_preview_duration"))
			subject.set("preview_time", time)
			subject.call("sample_pose", time)
			lab.call("_update_status")
			lab.get_node("Interface").visible = shot == "timeline"
			for frame in 4:
				await process_frame
			await RenderingServer.frame_post_draw
			root.get_texture().get_image().save_png(output.path_join(id + "_" + shot + ".png"))
		if id == "VisualBurstCrawler":
			lab.get_node("Interface").visible = false
			for time in [0.0, float(values.turn_duration) * 0.5, float(values.turn_duration), float(values.turn_duration) + float(values.release) * float(values.release_snap_ratio)]:
				subject.call("set_preview_pose", 2)
				subject.call("sample_pose", time)
				for frame in 3:
					await process_frame
				await RenderingServer.frame_post_draw
				root.get_texture().get_image().save_png(output.path_join("crawler_turn_%03d.png" % int(time * 100)))
			subject.call("set_preview_pose", 4)
			subject.call("sample_pose", float(values.retreat_close_time))
			for frame in 3:
				await process_frame
			await RenderingServer.frame_post_draw
			root.get_texture().get_image().save_png(output.path_join("crawler_retreat_closed.png"))
		lab.get_node("Interface").show()
	print("Enemy death captures: ", output)
	lab.queue_free()
	await process_frame
	quit()
