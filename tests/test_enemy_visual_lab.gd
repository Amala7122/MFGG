extends SceneTree
const CapturePaths := preload("res://scripts/capture_paths.gd")

const LabScene := preload("res://prototypes/visual_lab/enemy_visual_lab.tscn")
var failures := 0


func _initialize() -> void:
	_run.call_deferred()


func _check(condition: bool, message: String) -> void:
	if not condition:
		failures += 1
		push_error(message)


func _run() -> void:
	var lab: Node3D = LabScene.instantiate()
	root.add_child(lab)
	current_scene = lab
	for frame in range(5):
		await process_frame
	var subject := lab.get_node("SubjectMount").get_child(0) as Node3D
	_check(subject is ProceduralTombGuardianVisual, "First preview must be the tomb guardian")
	var guardian_parts := subject.find_children("*", "MeshInstance3D", true, false)
	_check(guardian_parts.size() > 0 and guardian_parts.size() <= 40, "Guardian mesh batching regressed")
	_check(int(lab.call("_count_triangles")) <= 6000, "Guardian triangle budget regressed")
	for part in guardian_parts:
		_check_winding(part as MeshInstance3D)
	var eyes := subject.find_children("EmberEye*", "MeshInstance3D", true, false)
	_check(eyes.size() == 2 and absf((eyes[0] as MeshInstance3D).get_aabb().get_center().x) < 0.33, "Guardian eyes must remain close-set")
	_check(subject.find_children("StoneBrow*", "MeshInstance3D", true, false).is_empty(), "Separate brows make the face look comical")
	_check(subject.get_node_or_null("GuardianSculpture/BreathingBody/HeadPivot/CentralCrest") is MeshInstance3D, "Central forehead crest is missing")
	var fang := subject.get_node("GuardianSculpture/BreathingBody/HeadPivot/UpperFang") as MeshInstance3D
	var fang_vertices: PackedVector3Array = fang.mesh.surface_get_arrays(0)[Mesh.ARRAY_VERTEX]
	var tip_width := 0.0
	for vertex in fang_vertices:
		if vertex.y < fang.get_aabb().position.y + 0.01:
			tip_width = maxf(tip_width, absf(vertex.x + 0.27))
	_check(tip_width < 0.01 and fang.get_aabb().size.y > 0.25, "Guardian fangs must end in sharp points")
	print("Guardian geometry: ", guardian_parts.size(), " meshes / ", lab.call("_count_triangles"), " triangles")
	_check(MouseControl.mode == Input.MOUSE_MODE_VISIBLE, "Visual Lab must release the mouse")
	_check(not paused, "Visual Lab must not be paused by GameFlow")
	_check(root.get_viewport().get_camera_3d() == lab.get_node("CameraRig/Pitch/Camera3D"), "Visual Lab camera must win over GameFlow menu camera")
	var head := subject.get_node("GuardianSculpture/BreathingBody/HeadPivot") as Node3D
	var initial_head_x := head.rotation.x
	for frame in range(25):
		await process_frame
	_check(absf(head.rotation.x - initial_head_x) > 0.0001, "Dynamic preview must animate")
	lab.call("_unhandled_input", _key(KEY_P))
	_check(subject.call("get_preview_pose_name") == "张翼威吓", "Pose preview must advance")
	lab.call("_unhandled_input", _key(KEY_M))
	_check(subject.process_mode == Node.PROCESS_MODE_DISABLED, "Static preview must freeze the subject")
	var frozen_head_x := head.rotation.x
	for frame in range(12):
		await process_frame
	_check(is_equal_approx(head.rotation.x, frozen_head_x), "Static preview pose changed")
	lab.call("_unhandled_input", _key(KEY_B))
	var face := subject.get_node("GuardianSculpture/BreathingBody/HeadPivot/Skull") as MeshInstance3D
	_check(face.material_override == lab.get("_silhouette_material"), "Silhouette preview must cover generated meshes")
	lab.call("_unhandled_input", _key(KEY_B))
	_check(face.material_override != lab.get("_silhouette_material"), "Material preview must restore glaze")
	for expected_name in ["ProceduralMudGolem", "ProceduralSedimentTitan", "ProceduralFastBeast", "ProceduralHornet", "ProceduralBurstCrawlerVisual", "ProceduralPrismSpiderVisual", "ProceduralChargeBeetleVisual", "BurstCrawler", "PrismSpider", "ChargeBeetle"]:
		lab.call("_unhandled_input", _key(KEY_RIGHT))
		await process_frame
		subject = lab.get_node("SubjectMount").get_child(lab.get_node("SubjectMount").get_child_count() - 1) as Node3D
		_check(subject.name == expected_name, "Gallery did not load " + expected_name)
		if not lab.get("_visual_panel").visible:
			_check(bool(lab.get("_visual_panel").call("_commit_inputs")), "Unbound visual panel must not block gallery switching")
		_check(not bool(subject.get("ai_enabled")), "Preview must suppress enemy AI: " + expected_name)
		_check(subject.process_mode == Node.PROCESS_MODE_DISABLED, "Static mode must survive gallery switching")
		_check(subject.find_children("*", "MeshInstance3D", true, false).size() > 0, "Gallery subject has no visual parts: " + expected_name)
	lab.call("_unhandled_input", _key(KEY_RIGHT))
	await process_frame
	_check(lab.get_node("SubjectMount").get_child(lab.get_node("SubjectMount").get_child_count() - 1) is ProceduralTombGuardianVisual, "Gallery must wrap to first preview")
	lab.call("_unhandled_input", _key(KEY_ESCAPE))
	_check(MouseControl.mode == Input.MOUSE_MODE_VISIBLE, "Esc must leave the mouse free")
	if "--capture-guardian" in OS.get_cmdline_user_args():
		var output_dir := CapturePaths.ensure_dir("tomb_guardian")
		DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(output_dir))
		(lab.get_node("Interface") as CanvasLayer).hide()
		var model: Node3D = lab.get_node("SubjectMount").get_child(lab.get_node("SubjectMount").get_child_count() - 1)
		model.process_mode = Node.PROCESS_MODE_DISABLED
		model.set("_clock", 0.0)
		model.call("set_preview_pose", 0)
		(lab.get_node("CameraRig") as Node3D).position.y = 3.0
		(lab.get_node("CameraRig") as Node3D).rotation.y = 0.0
		lab.call("_set_distance", 13.2)
		for frame in range(4):
			await process_frame
		root.get_viewport().get_texture().get_image().save_png(output_dir + "/front.png")
		model.call("set_preview_pose", 1)
		for frame in range(3):
			await process_frame
		root.get_viewport().get_texture().get_image().save_png(output_dir + "/threat.png")
		model.call("set_preview_pose", 0)
		(lab.get_node("CameraRig") as Node3D).rotation.y = 0.64
		lab.call("_unhandled_input", _key(KEY_B))
		for frame in range(3):
			await process_frame
		root.get_viewport().get_texture().get_image().save_png(output_dir + "/silhouette.png")
		lab.call("_unhandled_input", _key(KEY_B))
		for frame in range(3):
			await process_frame
		root.get_viewport().get_texture().get_image().save_png(output_dir + "/three_quarter.png")
		(lab.get_node("CameraRig") as Node3D).rotation.y = PI * 0.5
		for frame in range(3):
			await process_frame
		root.get_viewport().get_texture().get_image().save_png(output_dir + "/side.png")
		(lab.get_node("CameraRig") as Node3D).position.y = 4.12
		(lab.get_node("CameraRig") as Node3D).rotation.y = 0.38
		(lab.get_node("CameraRig/Pitch") as Node3D).rotation.x = -0.045
		lab.call("_set_distance", 7.8)
		for frame in range(3):
			await process_frame
		root.get_viewport().get_texture().get_image().save_png(output_dir + "/face_detail.png")
	if "--capture-shield-guard" in OS.get_cmdline_user_args():
		# 盾卫插盾姿态的对照截图：收盾 / 插盾防御 / 插盾受击 / 剪影 / 起手中间帧。
		# 中间帧靠"先跑一段真实相位机、再把预览冻住"取得 —— 这正是视觉台 M 键的用法。
		var output_dir := CapturePaths.ensure_dir("shield_guard")
		DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(output_dir))
		lab.call("_show_subject", _gallery_index_of(lab, "大型盾卫"))
		for frame in range(6):
			await process_frame
		var model: Node3D = lab.get_node("SubjectMount").get_child(lab.get_node("SubjectMount").get_child_count() - 1)
		(lab.get_node("Interface") as CanvasLayer).hide()
		var rig := lab.get_node("CameraRig") as Node3D
		rig.position.y = 1.15
		lab.call("_set_distance", 6.5)
		for shot in [
			{"name": "01_rest", "pose": 0, "yaw": 0.0},
			{"name": "02_planted", "pose": 1, "yaw": 0.35},
			{"name": "03_planted_three_quarter", "pose": 1, "yaw": 0.9},
			{"name": "04_block_hit", "pose": 2, "yaw": 0.35},
		]:
			model.call("set_preview_pose", int(shot.pose))
			rig.rotation.y = float(shot.yaw)
			for frame in range(8):
				await process_frame
			root.get_viewport().get_texture().get_image().save_png(
				output_dir + "/" + String(shot.name) + ".png"
			)
		# 起手中间帧：跑真实时序，在起手相位中途冻住。
		model.call("set_preview_pose", 3)
		rig.rotation.y = 0.35
		for frame in range(10):
			await process_frame
		model.process_mode = Node.PROCESS_MODE_DISABLED
		for frame in range(3):
			await process_frame
		root.get_viewport().get_texture().get_image().save_png(output_dir + "/05_planting_midframe.png")
		model.process_mode = Node.PROCESS_MODE_INHERIT
		lab.call("_unhandled_input", _key(KEY_B))
		for frame in range(4):
			await process_frame
		root.get_viewport().get_texture().get_image().save_png(output_dir + "/06_silhouette_planted.png")
		lab.call("_unhandled_input", _key(KEY_B))
	lab.queue_free()
	await process_frame
	print("Enemy Visual Lab: ", "PASS" if failures == 0 else "%d FAILURES" % failures)
	quit(0 if failures == 0 else 1)


func _key(code: Key) -> InputEventKey:
	var event := InputEventKey.new()
	event.physical_keycode = code
	event.pressed = true
	return event


## 按标题子串在画廊里找条目 —— 截图脚本不该依赖"它是第几个"。
func _gallery_index_of(lab: Node, title_part: String) -> int:
	var gallery: Array = lab.get("GALLERY")
	for i in range(gallery.size()):
		if String(gallery[i].get("title", "")).contains(title_part):
			return i
	push_error("画廊里找不到条目：" + title_part)
	return 0


func _check_winding(part: MeshInstance3D) -> void:
	if not part.mesh is ArrayMesh:
		return
	for surface_index in range(part.mesh.get_surface_count()):
		var arrays := part.mesh.surface_get_arrays(surface_index)
		var vertices: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
		var normals: PackedVector3Array = arrays[Mesh.ARRAY_NORMAL]
		for i in range(0, vertices.size(), 3):
			var cross := (vertices[i + 1] - vertices[i]).cross(vertices[i + 2] - vertices[i]).normalized()
			if cross.dot(normals[i]) > -0.9:
				_check(false, "Inverted or degenerate face in " + str(part.name))
				return
