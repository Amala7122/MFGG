extends SceneTree
const Lab = preload("res://prototypes/visual_lab/enemy_visual_lab.tscn")
const Tuning = preload("res://scripts/prototypes/enemy_tuning.gd")
var failures := 0

func _initialize() -> void:
	run.call_deferred()

func check(ok: bool, message: String) -> void:
	if not ok:
		failures += 1
		push_error(message)

func run() -> void:
	var lab := Lab.instantiate()
	root.add_child(lab)
	current_scene = lab
	await process_frame
	for index in lab.GALLERY.size():
		var id := String(lab.GALLERY[index].profile)
		if not id.begins_with("Visual") or String(lab.GALLERY[index].get("observe", "")) != "scrub":
			continue
		lab.call("_show_subject", index)
		await process_frame
		var subject: Node3D = lab.get("_subject")
		check(subject != null, id + " missing")
		check(Tuning.validate(id, subject.get("values")).is_empty(), id + " schema invalid")
		check(int(lab.call("_count_triangles")) < 10000, id + " over triangle budget")
		check(subject.find_children("*", "MeshInstance3D", true, false).size() <= 70, id + " over mesh budget")
		print(id, ": meshes=", subject.find_children("*", "MeshInstance3D", true, false).size(), " triangles=", lab.call("_count_triangles"))
		check_action_readability(subject, id)
		if id == "VisualBurstCrawler":
			check_crawler_mounts(subject)
		for pose in 4:
			subject.call("set_preview_pose", pose)
			for fraction in [0.0, 0.25, 0.5, 0.75, 1.0]:
				lab.call("_seek_visual", fraction)
				for part in subject.find_children("*", "Node3D", true, false):
					check((part as Node3D).transform.is_finite(), id + " nonfinite pose")
		check(subject.process_mode == Node.PROCESS_MODE_DISABLED, "Timeline must freeze")
		lab.call("_replay_visual")
		check(subject.process_mode != Node.PROCESS_MODE_DISABLED, "Replay must resume")
		var next: Dictionary = subject.get("values").duplicate(true)
		next.body_size = 1.4
		lab.call("_toggle_silhouette")
		lab.call("_apply_visual_values", next)
		check(is_equal_approx((subject.get("rig") as Node3D).scale.x, 1.4), "Size editing must rebuild")
		for mesh in subject.find_children("*", "MeshInstance3D", true, false):
			check(mesh.material_override == lab.get("_silhouette_material"), "Rebuild lost silhouette")
		lab.call("_toggle_silhouette")
		# Save/load/default separation and disk persistence in an isolated test location.
		var previous := Tuning.storage_directory
		Tuning.storage_directory = "user://new_visual_presets_test"
		Tuning.reload_saved()
		check(Tuning.set_active_preset(id, Tuning.DEFAULT_PRESET), "Reset default")
		check(Tuning.save_preset(id, "test_visual", next, false), "Save named preset")
		check(Tuning.active_name(id) == Tuning.DEFAULT_PRESET, "Saving must not select a default")
		check(Tuning.set_active_preset(id, "test_visual"), "Set default")
		Tuning.reload_saved()
		check(is_equal_approx(float(Tuning.get_values(id).body_size), 1.4), "Preset disk round trip")
		Tuning.storage_directory = previous
		Tuning.reload_saved()
	lab.queue_free()
	await process_frame
	print("New enemy visuals: ", "PASS" if failures == 0 else "FAIL")
	quit(0 if failures == 0 else 1)

func check_action_readability(subject: Node3D, id: String) -> void:
	subject.call("set_preview_pose", 0)
	var idle_body: Transform3D = (subject.get("body") as Node3D).transform
	var eye_y := 0.0
	if id == "VisualPrismSpider":
		eye_y = (subject.get("head") as Node3D).global_position.y
	subject.call("set_preview_pose", 3)
	if id == "VisualBurstCrawler":
		check((subject.get("back_armor") as Node3D).rotation.x > deg_to_rad(60), "Crawler must raise its back armor")
	elif id == "VisualPrismSpider":
		check((subject.get("head") as Node3D).global_position.y - eye_y > 0.8, "Spider firing eye must rise visibly")
	elif id == "VisualChargeBeetle":
		check((subject.get("body") as Node3D).position.z - idle_body.origin.z > 0.4, "Beetle must visibly coil backward")
	# Large torso poses must not detach the legs from their hip sockets.
	for leg: Dictionary in subject.get("legs"):
		var expected: Vector3 = (subject.get("body") as Node3D).transform * (leg.hip as Vector3)
		check((leg.node as Node3D).position.distance_to(expected) < 0.001, id + " detached hip")
		var shin: MeshInstance3D = leg.shin
		var endpoint := shin.global_transform * Vector3(0, (shin.mesh as CylinderMesh).height * 0.5, 0)
		check(endpoint.y >= -0.01, id + " planted foot below floor")
	var values: Dictionary = subject.get("values")
	subject.call("set_preview_pose", 2)
	# 爆囊的技能循环按用户要求整体倒放，打击时刻改到循环靠后的一侧。
	var cycle := float(values.windup) + float(values.release) + float(values.recovery)
	var peak := cycle - float(values.windup) - float(values.release) * float(values.release_snap_ratio)
	if not bool(subject.get("skill_reversed")):
		peak = float(values.windup) + float(values.release) * float(values.release_snap_ratio)
	subject.call("sample_pose", peak)
	if id == "VisualChargeBeetle":
		check((subject.get("rig") as Node3D).position.z < -1.0, "Beetle release must visibly drive forward")
	var peak_pose: Transform3D = (subject.get("body") as Node3D).transform
	subject.call("sample_pose", 0.1)
	subject.call("sample_pose", peak)
	check((subject.get("body") as Node3D).transform.is_equal_approx(peak_pose), id + " timeline seek must be deterministic")

func check_crawler_mounts(subject: Node3D) -> void:
	var carrier: Node3D = subject.get("back_armor")
	var sockets: Array = subject.get("sacs")
	var rest: Array[Transform3D] = []
	for socket: Node3D in sockets:
		check(socket.get_parent() == carrier, "Sac socket must be attached to the armor carrying it")
		rest.append(socket.transform)
	var values: Dictionary = subject.get("values")
	var duration := float(values.windup) + float(values.release) + float(values.recovery)
	subject.call("set_preview_pose", 2)
	for frame in 61:
		subject.call("sample_pose", duration * frame / 60.0)
		for index in sockets.size():
			var socket: Node3D = sockets[index]
			check(socket.transform.is_equal_approx(rest[index]), "Sac root must not slide or float away while armor opens")
			var membrane := socket.get_node("SacOrgan/LuminousSac") as MeshInstance3D
			var to_carrier := carrier.global_transform.affine_inverse() * membrane.global_transform
			for corner in 8:
				var point := to_carrier * membrane.get_aabb().get_endpoint(corner)
				check(point.y > 0.21, "Inflating membrane crossed its carrier armor surface")
		for rim: Node3D in subject.get("flank_armor"):
			check(rim.get_parent() == carrier and rim.rotation.is_zero_approx(), "Side rim must not rotate through the sac independently")
