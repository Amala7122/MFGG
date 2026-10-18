extends SceneTree
## 几何诊断：正式玩家肩部相机／枪口，采样可见晶体三角形与实际判区。
## 停止AI和玩家移动，只能诊断枪线，不进入胜率样本。
const Artifacts := preload("res://scripts/artifact_paths.gd")
var rows: Array = []
func _initialize() -> void:
	call_deferred("_run")
func frames(count: int) -> void:
	for _i in range(count): await physics_frame
func _run() -> void:
	var world := Node3D.new()
	root.add_child(world)
	current_scene = world
	var sun := DirectionalLight3D.new()
	sun.rotation_degrees = Vector3(-45, -25, 0)
	sun.light_energy = 1.5
	world.add_child(sun)
	var ground := StaticBody3D.new()
	var c := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = Vector3(100, 1, 100)
	c.shape = box
	ground.position.y = -0.5
	ground.add_child(c)
	world.add_child(ground)
	var actor: Node3D = load("res://scenes/player.tscn").instantiate()
	actor.position = Vector3(0, 1.01, 12)
	world.add_child(actor)
	actor.set_physics_process(false)
	var spawner := Node.new()
	spawner.set_script(load("res://scripts/enemy_spawner.gd"))
	world.add_child(spawner)
	var boss: Node3D = spawner.spawn_boss("sediment_titan", Vector3(0, 2.805, 0))
	boss.prepare_sparring_phase("rage")
	boss.ai_enabled = false
	await frames(60)
	boss.set_physics_process(false)
	var body_top := 1.7
	for argument in OS.get_cmdline_user_args():
		if argument.begins_with("--body-top="):
			body_top = float(argument.trim_prefix("--body-top="))
			if body_top < 0.5 or body_top > 1.7:
				push_error("诊断body-top必须为0.5–1.7局部米")
				quit(1)
				return
	var body_collision: CollisionShape3D = boss.get("_collision")
	(body_collision.shape as CylinderShape3D).height = body_top + 1.7
	body_collision.position.y = (body_top - 1.7) * 0.5
	await frames(2)
	var weapon: Node = actor.get("_weapon")
	var camera: Camera3D = actor.get("camera")
	actor.set("_aiming", true)
	weapon.set("_aiming", true)
	for distance in [8.0, 12.0, 20.0]:
		for degrees in [0, 45, 90, 135, 180, 225, 270, 315]:
			var radial := Vector3(0, 0, distance).rotated(Vector3.UP, deg_to_rad(degrees))
			actor.global_position = Vector3(radial.x, 1.01, radial.z)
			var core: MeshInstance3D = boss.get("core_mesh")
			for _step in range(75):
				var offset := core.global_position - camera.global_position
				actor.set("target_yaw", atan2(-offset.x, -offset.z))
				actor.set("target_pitch", atan2(offset.y, Vector2(offset.x, offset.z).length()))
				actor.call("_update_camera", 1.0 / 60.0)
				weapon.set("visual_direction", (core.global_position - weapon.get("_weapon_rig").global_position).normalized())
				weapon.call("_pose_weapon", 1.0 / 60.0)
				await physics_frame
			await frames(2)
			var center: Array = weapon.call("_resolve_shot_hits", -camera.global_basis.z, true)
			var camera_hits: Array = weapon.call("_collect_hits", -camera.global_basis.z, true, camera.global_position)
			var row := {"distance": distance, "azimuth": degrees, "center_region": center[0].hit_region if not center.is_empty() else "miss", "camera_center_region": camera_hits[0].hit_region if not camera_hits.is_empty() else "miss", "visible_mesh_rays": 0, "accepted_mesh_rays": 0, "rejected": {}, "mesh_occluded": 0,
				"core_position": _v(core.global_position), "body_shape_position": _v(boss.get("_collision").global_position), "camera_position": _v(camera.global_position), "muzzle_position": _v(weapon.get("_muzzle").global_position), "actual_model_blocked": 0, "geometry_mismatch": 0}
			# 采样画面中穿过实际实体晶体三角形的射线，火焰／辉光不当作晶体。
			for x in range(-10, 11):
				for y in range(-10, 11):
					var target := core.global_position + (camera.global_basis.x * float(x) + camera.global_basis.y * float(y)) * 0.1
					var direction := (target - camera.global_position).normalized()
					var surface := _mesh_distance(core, camera.global_position, direction)
					if surface == INF: continue
					var occluded := false
					for part: Node in boss.find_children("*", "MeshInstance3D", true, false):
						if part == core or not part.is_visible_in_tree(): continue
						if _mesh_distance(part, camera.global_position, direction) < surface - 0.001:
							occluded = true
							break
					if occluded:
						row.mesh_occluded += 1
						continue
					row.visible_mesh_rays += 1
					var hits: Array = weapon.call("_resolve_shot_hits", direction, true)
					var region := String(hits[0].hit_region) if not hits.is_empty() else "miss"
					if region == "crystal": row.accepted_mesh_rays += 1
					else:
						row.rejected[region] = int(row.rejected.get(region, 0)) + 1
						var camera_path: Array = weapon.call("_collect_hits", direction, true, camera.global_position)
						var aim_point: Vector3 = camera_path[0].position if not camera_path.is_empty() else target
						var muzzle: Vector3 = weapon.get("_muzzle").global_position
						var physical_direction := (aim_point - muzzle).normalized()
						var ray_exclude: Array[RID] = [actor.get_rid()]
						var raw: Dictionary = weapon.call("_shot_ray", muzzle, aim_point + physical_direction * 0.02, ray_exclude)
						var part: Node = raw.get("collider")
						var model := part.get_parent() as MeshInstance3D if is_instance_valid(part) else null
						if model != null and model != core and _mesh_distance(model, muzzle, physical_direction) < muzzle.distance_to(aim_point) + 0.03:
							row.actual_model_blocked += 1
						else: row.geometry_mismatch += 1
			rows.append(row)
			if distance == 12.0 and degrees == 0 and DisplayServer.get_name() != "headless":
				await _capture(world, boss, row)
	var report := {"diagnostic_only": true, "diagnostic_body_top": body_top, "conditions": "正式玩家相机/枪口、正式Boss狂暴、平地、静止实体、无开枪扣血；不是动态可读性测试。body-top偏离1.7仅为局部几何反证，不是正式修改。", "rows": rows}
	var path := Artifacts.ensure_dir("reports", "crystal_aim").path_join("geometry.json")
	var file := FileAccess.open(path, FileAccess.WRITE)
	if file == null:
		push_error("几何审计输出失败")
		quit(1)
		return
	file.store_string(JSON.stringify(report, "  ") + "\n")
	file.close()
	print("[晶体几何] ", path)
	current_scene = null
	world.queue_free()
	await frames(8)
	preload("res://scripts/object_pool.gd").clear_all()
	await preload("res://tools/probes/sparring/sparring_runtime.gd").settle_audio(self)
	quit(0)
func _capture(world: Node3D, boss: Node3D, row: Dictionary) -> void:
	var layer := CanvasLayer.new()
	world.add_child(layer)
	var label := Label.new()
	label.position = Vector2(20, 210)
	label.add_theme_font_size_override("font_size", 18)
	label.text = "静态诊断 · 实体晶体中心\n相机判区 %s / 实际枪线 %s\n当前身体碰撞上沿：局部 %.2fm" % [row.camera_center_region, row.center_region, (boss.get("_collision").shape.height * 0.5 + boss.get("_collision").position.y)]
	layer.add_child(label)
	var folder := Artifacts.ensure_dir("screenshots", "crystal_aim")
	await RenderingServer.frame_post_draw
	if root.get_texture().get_image().save_png(folder.path_join("normal.png")) != OK: push_error("晶体诊断截图失败")
	var overlay := MeshInstance3D.new()
	var cylinder := CylinderMesh.new()
	cylinder.top_radius = 1.4
	cylinder.bottom_radius = 1.4
	cylinder.height = boss.get("_collision").shape.height
	overlay.mesh = cylinder
	overlay.position = boss.get("_collision").position
	var material := StandardMaterial3D.new()
	material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	material.albedo_color = Color(0, 1, 1, 0.28)
	material.cull_mode = BaseMaterial3D.CULL_DISABLED
	overlay.material_override = material
	boss.add_child(overlay)
	await RenderingServer.frame_post_draw
	if root.get_texture().get_image().save_png(folder.path_join("collision_overlay.png")) != OK: push_error("碰撞叠加截图失败")
	overlay.queue_free()
	layer.queue_free()
func _v(point: Vector3) -> Array: return [point.x, point.y, point.z]
func _mesh_distance(mesh: MeshInstance3D, origin: Vector3, direction: Vector3) -> float:
	if mesh.mesh == null: return INF
	var inverse := mesh.global_transform.affine_inverse()
	var start := inverse * origin
	var ray := (inverse.basis * direction).normalized()
	var faces := mesh.mesh.get_faces()
	var distance := INF
	for i in range(0, faces.size(), 3):
		var hit: Variant = Geometry3D.ray_intersects_triangle(start, ray, faces[i], faces[i + 1], faces[i + 2])
		if hit != null: distance = minf(distance, origin.distance_to(mesh.global_transform * Vector3(hit)))
	return distance
