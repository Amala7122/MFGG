extends SceneTree
## 相同正式玩家、晶体、真实SpringArm：测镜头构图，不改项目配置或推导真人读图能力。
const Artifacts := preload("res://scripts/artifact_paths.gd")
const Spawner := preload("res://scripts/enemy_spawner.gd")
const CASES := [
	{"id": "current", "fov": 26.0, "arm": 2.3, "reticle_y": 0.5},
	{"id": "wide_only", "fov": 60.0, "arm": 2.3, "reticle_y": 0.5},
	{"id": "wide_back", "fov": 60.0, "arm": 5.0, "reticle_y": 0.5},
	{"id": "upper_reticle_concept", "fov": 60.0, "arm": 3.5, "reticle_y": 0.30},
	{"id": "combat_frame_concept", "fov": 60.0, "arm": 5.0, "reticle_y": 0.30}]
var actor: CharacterBody3D
var boss: CharacterBody3D
var weapon: Node
var camera: Camera3D
var rows: Array = []
var failures := 0
func _initialize() -> void: call_deferred("_run")
func frames(n: int) -> void:
	for _i in range(n): await physics_frame
func visible(point: Vector3) -> bool:
	return not camera.is_position_behind(point) and camera.get_viewport().get_visible_rect().has_point(camera.unproject_position(point))
func capture(name: String) -> void:
	if DisplayServer.get_name() == "headless": return
	await RenderingServer.frame_post_draw
	if root.get_texture().get_image().save_png(Artifacts.ensure_dir("screenshots", "sniper_framing").path_join(name + ".png")) != OK:
		failures += 1
		push_error("构图截图保存失败")
func _run() -> void:
	var world := Node3D.new()
	root.add_child(world)
	current_scene = world
	var light := DirectionalLight3D.new()
	light.rotation_degrees = Vector3(-50,-20,0)
	world.add_child(light)
	var ground := StaticBody3D.new()
	var c := CollisionShape3D.new()
	var shape := BoxShape3D.new()
	shape.size = Vector3(120,1,120)
	c.shape = shape
	ground.position.y = -0.5
	ground.add_child(c)
	world.add_child(ground)
	var floor_mesh := MeshInstance3D.new()
	var plane := PlaneMesh.new()
	plane.size = Vector2(120,120)
	floor_mesh.mesh = plane
	world.add_child(floor_mesh)
	actor = load("res://scenes/player.tscn").instantiate()
	actor.position = Vector3(0,1.01,12)
	world.add_child(actor)
	weapon = actor._weapon
	camera = actor.camera
	var spawner := Node.new()
	spawner.set_script(Spawner)
	world.add_child(spawner)
	boss = spawner.spawn_boss("sediment_titan", Vector3.ZERO)
	boss.ai_enabled = false
	boss.prepare_sparring_phase("rage")
	boss.target = actor
	await frames(35)
	actor.set_physics_process(false)
	boss.set_physics_process(false)
	actor._aiming = true
	weapon._aiming = true
	var size := root.get_visible_rect().size
	actor.get_node("AimUI").visible = false
	var overlay := CanvasLayer.new()
	world.add_child(overlay)
	var caption := Label.new()
	caption.position = Vector2(20,20)
	overlay.add_child(caption)
	var reticle := Label.new()
	reticle.text = "+"
	reticle.add_theme_font_size_override("font_size",30)
	overlay.add_child(reticle)
	for distance in [6.0,8.0,12.0,18.0,26.0,36.0]:
		for variant: Dictionary in CASES:
			actor.position = Vector3(0,1.01,distance)
			actor.sniper_fov = variant.fov
			actor.sniper_spring_length = variant.arm
			weapon.view_kick = Vector2.ZERO
			caption.text = "构图测量 · %s · %.0fm · %.0f° · %.1fm镜距\n上置准星只作构图演示，尚未接入正式武器与HUD" % [variant.id,distance,variant.fov,variant.arm]
			reticle.position = size*Vector2(.5,float(variant.reticle_y))-Vector2(8,18)
			for _i in range(85):
				var offset: Vector3 = boss.core_mesh.global_position - camera.global_position
				actor.target_yaw = atan2(-offset.x,-offset.z)
				var reticle_angle := atan((0.5-float(variant.reticle_y))*2.0*tan(deg_to_rad(float(variant.fov))*.5))
				actor.target_pitch = atan2(offset.y,Vector2(offset.x,offset.z).length())-reticle_angle
				actor._update_camera(1.0/60)
				weapon.visual_direction = (boss.core_mesh.global_position-weapon._weapon_rig.global_position).normalized()
				weapon._pose_weapon(1.0/60)
				await physics_frame
			var core: Vector3 = boss.core_mesh.global_position
			var core_screen := camera.unproject_position(core)
			var foot := Vector3(actor.global_position.x,0.05,actor.global_position.z)
			var forward := (Vector3.ZERO-foot).normalized()
			forward.y = 0
			var ground_visible := 0
			for delta in [Vector3.ZERO, Vector3.RIGHT, Vector3.LEFT, forward, forward*2, forward+Vector3.RIGHT,forward+Vector3.LEFT]:
				if visible(foot+delta): ground_visible += 1
			var ray := camera.project_ray_normal(size*Vector2(.5,float(variant.reticle_y)))
			var hits: Array = weapon._resolve_shot_hits(ray,true)
			var min_y := INF
			var max_y := -INF
			var box: AABB = boss.core_mesh.mesh.get_aabb()
			for x in [box.position.x,box.end.x]:
				for y in [box.position.y,box.end.y]:
					for z in [box.position.z,box.end.z]:
						var p := camera.unproject_position(boss.core_mesh.to_global(Vector3(x,y,z)))
						min_y=minf(min_y,p.y)
						max_y=maxf(max_y,p.y)
			rows.append({"distance": distance,"variant":variant,"core_screen_y_ratio":core_screen.y/size.y,
				"core_height_pixels":max_y-min_y,"core_center_in_view":visible(core),"player_feet_in_view":visible(foot),
				"near_feet_ground_samples_visible":ground_visible,"near_feet_ground_samples_total":7,
				"boss_feet_in_view":visible(Vector3(boss.global_position.x,.05,boss.global_position.z)),
				"mid_ground_in_view":visible(Vector3(0,.05,distance*.5)),
				"actual_ray_region":hits[0].get("hit_region","unknown") if not hits.is_empty() else "miss",
				"camera_position":[camera.global_position.x,camera.global_position.y,camera.global_position.z],
				"scope":"视锥构图与真实枪线；不含角色/植被像素遮挡。upper_reticle是未接入正式武器/HUD的构图候选。"})
			if distance in [6.0,8.0,18.0]: await capture("%s_%.0fm" % [variant.id,distance])
	var file := FileAccess.open(Artifacts.ensure_dir("reports","sniper_framing").path_join("audit.json"),FileAccess.WRITE)
	if file == null:
		failures += 1
		push_error("构图报告无法保存")
	else:
		file.store_string(JSON.stringify({"rows":rows,"viewport":[size.x,size.y],"failures":failures,"purpose":"候选构图区分，非战斗体验验收"},"\t"))
		file.close()
	current_scene=null
	world.queue_free()
	await frames(5)
	preload("res://scripts/object_pool.gd").clear_all()
	await preload("res://tools/probes/sparring/sparring_runtime.gd").settle_audio(self)
	print("[狙击构图候选] rows=",rows.size()," failures=",failures)
	quit(1 if failures else 0)
