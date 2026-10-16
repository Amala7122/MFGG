extends SceneTree
const Lab = preload("res://prototypes/visual_lab/enemy_visual_lab.tscn")
const CapturePaths = preload("res://scripts/capture_paths.gd")

func _initialize() -> void:
	run.call_deferred()

func run() -> void:
	var lab := Lab.instantiate()
	root.add_child(lab)
	current_scene = lab
	await process_frame
	var output := CapturePaths.ensure_dir("new_enemy_visuals")
	for index in lab.GALLERY.size():
		var id := String(lab.GALLERY[index].profile)
		if not id.begins_with("Visual"):
			continue
		if "--crawler-mount" in OS.get_cmdline_user_args() and id != "VisualBurstCrawler":
			continue
		lab.call("_show_subject", index)
		await process_frame
		var subject: Node3D = lab.get("_subject")
		subject.process_mode = Node.PROCESS_MODE_DISABLED
		subject.call("set_preview_pose", 0)
		for frame in 5:
			await process_frame
		await RenderingServer.frame_post_draw
		root.get_texture().get_image().save_png(output.path_join(id + "_panel.png"))
		lab.get_node("Interface").hide()
		for shot in ["three_quarter", "front", "side", "charge", "silhouette"]:
			var yaw: float = lab.GALLERY[index].yaw
			if shot == "front":
				yaw = 0
			if shot == "side":
				yaw = PI * 0.5
			(lab.get_node("CameraRig") as Node3D).rotation.y = yaw
			subject.call("set_preview_pose", 3 if shot == "charge" else 0)
			if shot == "silhouette":
				lab.call("_toggle_silhouette")
			for frame in 3:
				await process_frame
			await RenderingServer.frame_post_draw
			root.get_texture().get_image().save_png(output.path_join(id + "_" + shot + ".png"))
			if shot == "silhouette":
				lab.call("_toggle_silhouette")
		lab.get_node("Interface").show()
		if "--crawler-mount" in OS.get_cmdline_user_args():
			lab.get_node("Interface").hide()
			lab.call("_set_distance", 8.0)
			(lab.get_node("CameraRig") as Node3D).position.y = 1.4
			var values: Dictionary = subject.get("values")
			for angle in [0.55, PI * 0.5]:
				(lab.get_node("CameraRig") as Node3D).rotation.y = angle
				for step in 7:
					subject.call("set_preview_pose", 2)
					subject.call("sample_pose", float(values.windup) * step / 6.0)
					for frame in 3:
						await process_frame
					await RenderingServer.frame_post_draw
					root.get_texture().get_image().save_png(output.path_join("mount_%s_%02d.png" % ["side" if angle > 1.0 else "quarter", step]))
			lab.get_node("Interface").show()
		if "--motion" in OS.get_cmdline_user_args():
			lab.get_node("Interface").hide()
			for distance in [12.0, 24.0]:
				lab.call("_set_distance", distance)
				for pose in ["idle", "charge", "release"]:
					subject.call("set_preview_pose", 0 if pose == "idle" else 3)
					if pose == "release":
						subject.call("set_preview_pose", 2)
						var values: Dictionary = subject.get("values")
						subject.call("sample_pose", float(values.windup) + float(values.release) * float(values.release_snap_ratio))
					for frame in 3:
						await process_frame
					await RenderingServer.frame_post_draw
					root.get_texture().get_image().save_png(output.path_join("%s_%dm_%s.png" % [id, int(distance), pose]))
			lab.get_node("Interface").show()
	print("New enemy captures: ", output)
	lab.queue_free()
	await process_frame
	quit()
