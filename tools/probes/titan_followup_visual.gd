extends "res://tests/test_titan_followup.gd"
## 固定机位只核对招式／泥盾／预警；正式地图实战另录，不当真人可读性结论。
func capture(label: String) -> void:
	await process_frame
	await RenderingServer.frame_post_draw
	check(root.get_texture().get_image().save_png(Artifacts.ensure_dir("screenshots", "followup").path_join(label + ".png")) == OK, "截图可保存")
func _run() -> void:
	if DisplayServer.get_name() == "headless":
		push_error("需要图形")
		quit(1)
		return
	root.get_node("GameFlow").set_meta(&"sparring_session_active", true)
	await setup("front")
	var ground := MeshInstance3D.new()
	var mesh := PlaneMesh.new()
	mesh.size = Vector2(120, 120)
	ground.mesh = mesh
	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color(.28,.34,.29)
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	ground.material_override = mat
	world.add_child(ground)
	var sun := DirectionalLight3D.new()
	sun.rotation_degrees = Vector3(-60,-20,0)
	world.add_child(sun)
	var camera := Camera3D.new()
	world.add_child(camera)
	camera.make_current()
	player.set_physics_process(false)
	player.position = Vector3(0,1.05,-11)
	camera.position = Vector3(15,16,16)
	camera.look_at(Vector3(0,2,-5))
	boss.rotation.y = 0
	boss.trigger_thrust_attack()
	await frames(18)
	check(boss.has_mud_shield, "新轻击仍带盾")
	await capture("front_thrust_warning_shield")
	await frames(72)
	boss._brain.finish_group("visual")
	boss.trigger_sweep_attack()
	await frames(12)
	await capture("front_sweep_extended")
	await frames(72)
	boss.current_hp = boss.max_hp*.49
	boss._trigger_rage()
	boss._brain.finish_group("visual")
	boss._brain.cooldowns.leap = 0
	boss._brain.approach_remaining = 0
	player.position = Vector3(0,1.05,-18)
	check(boss.trigger_leap_attack(), "实际跃击开始")
	for _i in range(220):
		await physics_frame
		if boss.current_state == boss.State.ATK_THRUST:
			camera.position = boss.global_position + Vector3(15,16,16)
			camera.look_at(boss.global_position + Vector3(0,0,-5))
			await frames(12)
			await capture("rage_landing_followup_warning")
			break
	await frames(100)
	await dispose()
	preload("res://scripts/object_pool.gd").clear_all()
	await preload("res://tools/probes/sparring/sparring_runtime.gd").settle_audio(self)
	root.get_node("GameFlow").remove_meta(&"sparring_session_active")
	quit(1 if failures else 0)
