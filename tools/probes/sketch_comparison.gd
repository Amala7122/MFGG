extends SceneTree
## 正式地图同机位 / 同天气 / 同一Boss静态姿态；只比较滤镜渲染成本，不测AI容量。
const Settings := preload("res://scripts/sketch_settings.gd")
const Terrain := preload("res://scripts/terrain_field.gd")
const Artifacts := preload("res://scripts/artifact_paths.gd")
var effect: CanvasLayer
var samples: Array = []
var first_enable: Array = []
var gpu_timing := false
var camera: Camera3D
var weather: Node
var failures := 0

func _initialize() -> void:
	seed(180018)
	call_deferred("_run")

func frames(count: int) -> void:
	for _i in count:
		await process_frame
		await RenderingServer.frame_post_draw

func _run() -> void:
	if DisplayServer.get_name() == "headless":
		push_error("手绘画面 / GPU对照需要真实图形渲染器")
		quit(1)
		return
	change_scene_to_file("res://scenes/hyrule_field.tscn")
	await frames(45)
	root.size = Vector2i(1920,1080)
	root.content_scale_factor = 1.0
	root.scaling_3d_scale = 1.0
	root.get_node("GameFlow")._resume_play()
	current_scene.get_node("Enemies/WaveDirector").process_mode = Node.PROCESS_MODE_DISABLED
	var player: Node3D = current_scene.get_node("PlayerSpawner").spawn_player()
	player.position = Vector3(0,Terrain.height_at(0,24)+1,24)
	player.set_physics_process(false)
	player._wisp.set_physics_process(false)
	var spawner := current_scene.get_node("Enemies/EnemySpawner")
	var boss: CharacterBody3D = spawner.spawn_boss("sediment_titan", Vector3(0,Terrain.height_at(0,5),5))
	boss.ai_enabled = false
	if not boss.prepare_sparring_phase("front"):
		push_error("静态泰坦必须先从出场动画进入可见稳定阶段")
		quit(1)
		return
	await frames(5)
	# 暂停动作、天气随机与云偏移；GPU仍绘制真实材质 / 粒子，所有模式同一快照。
	paused = true
	var camera_target := Vector3(0,Terrain.height_at(0,12)+2,10)
	camera = Camera3D.new()
	current_scene.add_child(camera)
	camera.position = Vector3(12,Terrain.height_at(0,24)+11,29)
	camera.look_at(camera_target)
	camera.far = 2500
	camera.make_current()
	var area := preload("res://scripts/enemy_attack_area.gd").new()
	current_scene.add_child(area)
	area.prepare(Transform3D(Basis(), Vector3(0,Terrain.height_at(0,15)+0.1,15)), {"kind":"circle","radius":6.0}, 30)
	area.set_progress(0.55)
	area.set_physics_process(false)
	weather = current_scene.get_node("WeatherEnvironment/WeatherSystem")
	current_scene.get_node("WeatherEnvironment/Sky3D/TimeOfDay").pause()
	effect = root.get_node("PostProcess")
	gpu_timing = RenderingServer.has_method("viewport_set_measure_render_time") and RenderingServer.has_method("viewport_get_measured_render_time_gpu")
	if gpu_timing:
		RenderingServer.call("viewport_set_measure_render_time", root.get_viewport_rid(), true)
	for climate in ["clear","storm"]:
		set_climate(climate)
		await frames(35)
		# 轮换顺序，避免固定次序把升温 / 缓存差异归给某个模式。
		for order in [["off","legacy","light"],["light","off","legacy"],["legacy","light","off"]]:
			for mode in order:
				select_mode(mode)
				var start := Time.get_ticks_usec()
				await frames(1)
				first_enable.append({"weather":climate,"mode":mode,"wall_ms":(Time.get_ticks_usec()-start)/1000.0})
				await frames(40)
				var row := await measure(mode, climate)
				samples.append(row)
		for mode in ["off","legacy","light","mono"]:
			select_mode(mode)
			await frames(15)
			var path := Artifacts.ensure_dir("screenshots","sketch_live").path_join(climate+"_"+mode+".png")
			if root.get_texture().get_image().save_png(path) != OK:
				failures += 1
				push_error("正式地图截图写入失败："+path)
	# 面板用实际正式玩家，不留在暂停状态调用入口。
	paused = false
	effect.set_style(0)
	MouseControl.mode = Input.MOUSE_MODE_CAPTURED
	effect._sketch_panel.open()
	await frames(5)
	if not effect._sketch_panel.opened:
		failures += 1
		push_error("正式地图F9未打开")
	else:
		var panel_path := Artifacts.ensure_dir("screenshots","sketch_live").path_join("panel.png")
		if root.get_texture().get_image().save_png(panel_path) != OK:
			failures += 1
			push_error("面板截图写入失败")
		effect._sketch_panel.close()
	paused = true
	var report := {"gpu":RenderingServer.get_video_adapter_name(),"godot":Engine.get_version_info(),
		"enemies":get_nodes_in_group("enemies").size(),"boss_visual_y":boss.visual_root.position.y,
		"size":[root.size.x,root.size.y],"render_scale":root.scaling_3d_scale,
		"camera_position":str(camera.position),"camera_transform":str(camera.transform),
		"scene":current_scene.scene_file_path,"seed":180018,"gpu_timing_supported":gpu_timing,
		"samples":samples,"first_switch_wall_ms":first_enable,"failures":failures,
		"scope":"正式圣所，1个静态泰坦，冻结AI与天气时间，同模式同快照；不是百体AI帧率，也不是首次进游戏冷启动结论。固定帧步长的wall_ms只作切换观察；GPU数据为viewport计时，截图读回在采样段之外。"}
	var file := FileAccess.open(Artifacts.ensure_dir("reports").path_join("sketch_comparison.json"), FileAccess.WRITE)
	if file == null:
		push_error("滤镜对照报告写入失败")
		failures += 1
	else:
		file.store_string(JSON.stringify(report,"  "))
		file.close()
	print("[手绘对照] ",JSON.stringify(samples))
	effect.set_style(0)
	paused = false
	current_scene.queue_free()
	await frames(4)
	preload("res://scripts/object_pool.gd").clear_all()
	quit(1 if failures else 0)

func select_mode(mode: String) -> void:
	effect.apply_sketch_parameters(Settings.recipe("legacy" if mode == "off" else mode))
	effect.set_style(0 if mode == "off" else 5)

func set_climate(climate: String) -> void:
	var storm := climate == "storm"
	weather.set_rain_amount(1.0 if storm else 0.0)
	weather._rain_intensity = 1.0 if storm else 0.0
	weather.set_fog_amount(0.45 if storm else 0.0)
	weather.set_cloud_type(1 if storm else 0)
	weather.set_cloud_coverage(0.9 if storm else 0.32)
	weather.set_cloud_density(0.8 if storm else 0.25)
	weather._cloud_level = weather.cloud_coverage
	weather._cloud_density_level = weather.cloud_density
	weather._sync_extra_layers()
	weather._update_rain_particles()
	weather._update_environment()
	weather.get_node("ProceduralCloudField")._update_transforms()

func measure(mode: String, climate: String) -> Dictionary:
	var gpu: Array[float] = []
	var wall: Array[float] = []
	for _i in range(80):
		var start := Time.get_ticks_usec()
		await frames(1)
		wall.append((Time.get_ticks_usec()-start)/1000.0)
		if gpu_timing:
			gpu.append(float(RenderingServer.call("viewport_get_measured_render_time_gpu",root.get_viewport_rid())))
	gpu.sort()
	wall.sort()
	return {"mode":mode,"weather":climate,"rain_intensity":weather._rain_intensity,
		"cloud_coverage":weather._cloud_level,"cloud_density":weather._cloud_density_level,
		"samples":wall.size(),"gpu_median_ms":gpu[gpu.size()/2] if not gpu.is_empty() else null,
		"gpu_p95_ms":gpu[int(gpu.size()*0.95)] if not gpu.is_empty() else null,"wall_median_ms":wall[wall.size()/2],
		"draw_calls":Performance.get_monitor(Performance.RENDER_TOTAL_DRAW_CALLS_IN_FRAME)}
