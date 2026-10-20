extends "res://tests/test_titan_followup.gd"
## 真实Player相机与俯视诊断并列；不以固定镜头截图替代正式地图可读性。
func capture(label: String) -> void:
	await RenderingServer.frame_post_draw
	check(root.get_texture().get_image().save_png(Artifacts.ensure_dir("screenshots","rage_director").path_join(label+".png")) == OK,"三线截图保存成功")

func _run() -> void:
	if DisplayServer.get_name() == "headless":
		push_error("三线读图探针需要图形")
		quit(1)
		return
	root.get_node("GameFlow").set_meta(&"sparring_session_active",true)
	for view: String in ["player_hip","overview"]:
		await setup("rage")
		player.set_physics_process(false)
		player.position = Vector3(0,1.01,16)
		var ground := MeshInstance3D.new()
		var mesh := PlaneMesh.new()
		mesh.size = Vector2(120,120)
		ground.mesh = mesh
		var mat := StandardMaterial3D.new()
		mat.albedo_color = Color(.28,.33,.29)
		mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		ground.material_override = mat
		world.add_child(ground)
		var sun := DirectionalLight3D.new()
		sun.rotation_degrees = Vector3(-60,-20,0)
		world.add_child(sun)
		var camera: Camera3D = player.camera
		if view == "overview":
			camera = Camera3D.new()
			world.add_child(camera)
			camera.position = Vector3(25,30,30)
			camera.look_at(Vector3(0,1,10))
		else:
			player.target_yaw = 0
			player.target_pitch = .1
			for _i in range(60):
				player._update_camera(1.0/60)
				await physics_frame
		camera.make_current()
		check(boss.trigger_triple_slam_attack(),"正式三线进入真实图形状态")
		for tick in range(165):
			await physics_frame
			if tick in [12,60,78,108,144]: await capture(view+"_"+str(tick))
		await dispose()
	preload("res://scripts/object_pool.gd").clear_all()
	await preload("res://tools/probes/sparring/sparring_runtime.gd").settle_audio(self)
	root.get_node("GameFlow").remove_meta(&"sparring_session_active")
	quit(1 if failures else 0)
