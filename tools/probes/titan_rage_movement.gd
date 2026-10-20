extends "res://tests/test_titan_followup.gd"
## 无地图边缘的原生方向跑诊断；不用它代替正式地图胜负或掩盖场外异常。
func _run() -> void:
	root.get_node("GameFlow").set_meta(&"sparring_session_active",true)
	var policies := ["left","right","retreat"]
	for arg: String in OS.get_cmdline_user_args():
		if arg.begins_with("--policies="): policies = Array(arg.trim_prefix("--policies=").split(","))
	for policy: String in policies:
		if policy not in ["left","right","retreat","diagonal_left","diagonal_right"]:
			push_error("未知平地跑策略："+policy)
			quit(1)
			return
		await setup("rage")
		for body: Node in world.get_children():
			if body is StaticBody3D:
				(body.get_child(0).shape as BoxShape3D).size = Vector3(800,1,800)
		player.health = 100
		player.max_health = 100
		player.shield = 70
		player.position = Vector3(0,1.01,12)
		player.velocity = Vector3.ZERO
		player.camera_pivot.rotation = Vector3.ZERO
		player.target_yaw = 0
		await frames(5)
		boss.ai_enabled = true
		Input.action_press("sprint")
		var action := "move_left" if policy == "left" else "move_right" if policy == "right" else "move_back"
		Input.action_press(action)
		var side_action := "move_left" if policy == "diagonal_left" else "move_right" if policy == "diagonal_right" else ""
		if not side_action.is_empty(): Input.action_press(side_action)
		var start := Time.get_ticks_usec()
		var actual := 0.0
		var losses: Array = []
		var trace: Array = []
		var previous := 170.0
		for tick in range(1800):
			await physics_frame
			actual += 1.0/60
			var durability: float = player.health+player.shield
			if durability < previous-.01: losses.append({"time":actual,"loss":previous-durability})
			previous = durability
			if tick%60 == 0: trace.append({"time":actual,"boss":[boss.position.x,boss.position.y,boss.position.z],"player":[player.position.x,player.position.y,player.position.z],"director":boss._rage_director.snapshot(),"state":boss.current_state})
			if player.health <= 0: break
		var wall := float(Time.get_ticks_usec()-start)/1000000.0
		results.append({"policy":policy,"simulation_seconds":actual,"wall_seconds":wall,"realtime_ratio":actual/wall,"hits":losses,"trace":trace,"history":boss._brain.history.duplicate(true),"scope":"800m平地、正式100/70、无射击、原生全速方向跑；不是正式地图通关/手感结论"})
		Input.action_release(action)
		if not side_action.is_empty(): Input.action_release(side_action)
		Input.action_release("sprint")
		await dispose()
	var file := FileAccess.open(Artifacts.ensure_dir("reports","movement_open_ground").path_join("result.json"),FileAccess.WRITE)
	if file == null:
		quit(1)
		return
	file.store_string(JSON.stringify({"trials":results},"\t"))
	file.close()
	preload("res://scripts/object_pool.gd").clear_all()
	await preload("res://tools/probes/sparring/sparring_runtime.gd").settle_audio(self)
	root.get_node("GameFlow").remove_meta(&"sparring_session_active")
	quit(0)
