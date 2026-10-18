extends SceneTree
## 真实自动加载入口、正式玩家、调参 / 保存；图形另验HUD像素与警告边界。
const Settings := preload("res://scripts/sketch_settings.gd")
const Terrain := preload("res://scripts/terrain_field.gd")
const Artifacts := preload("res://scripts/artifact_paths.gd")
var world: Node3D
var player: CharacterBody3D
var effect: CanvasLayer
var checks := 0
var failures := 0
var camera: Camera3D
var warning: Node3D
var hud: CanvasLayer

func _initialize() -> void:
	call_deferred("_run")

func check(ok: bool, label: String) -> void:
	checks += 1
	if ok:
		print("PASS ", label)
	else:
		failures += 1
		push_error(label)

func frames(count: int) -> void:
	for _i in count:
		await process_frame
		if DisplayServer.get_name() != "headless":
			await RenderingServer.frame_post_draw

func key(code: Key) -> void:
	for pressed in [true, false]:
		var event := InputEventKey.new()
		event.keycode = code
		event.physical_keycode = code
		event.pressed = pressed
		Input.parse_input_event(event)
		Input.flush_buffered_events()

func _run() -> void:
	world = Node3D.new()
	root.add_child(world)
	current_scene = world
	player = preload("res://scenes/player.tscn").instantiate()
	if DisplayServer.get_name() == "headless":
		player.set_script(preload("res://tests/fixtures/player_melee_input_host.gd"))
	player.position = Vector3(0, Terrain.height_at(0,0) + 1, 0)
	world.add_child(player)
	await frames(3)
	root.get_node("GameFlow")._resume_play()
	player.set_physics_process(false)
	player._wisp.set_physics_process(false)
	effect = root.get_node("PostProcess")
	var defaults := Settings.load_values()
	check(defaults.double_stroke == 0 and defaults.monochrome_mode == 0, "项目配方为单轮廓彩铅；个人风格默认仍关闭")
	check(Settings.recipe("legacy").double_stroke == 0.05 and Settings.recipe("legacy").line_thickness == 0.6, "旧版对照取实际配置，不误用场景的强线稿")
	check(root.get_node("DisplaySettings").POST_PROCESS_LABELS.size() == 6, "统一显示菜单增加第6项，原编号不变")
	for style in range(6):
		effect.set_style(style)
		check(effect._overlay.visible == (style in [1,2,3,4]) and effect._sketch_rect.visible == (style == 5), "风格%d互斥，不叠两套全屏效果" % style)
	check(effect._sketch_layer.layer < 0 and effect.layer == 90, "手绘在默认HUD下，原五种风格层序未改")
	effect.set_style(5)
	var draft := defaults.duplicate(true)
	draft.filter_blend = 0
	effect.apply_sketch_parameters(draft)
	check(not effect._sketch_rect.visible and not effect._sketch_copy.visible, "混合为0时不绘制滤镜或复制屏幕")
	effect.apply_sketch_parameters(defaults)
	for uniform in Settings.FIELDS:
		var expected: Variant = defaults[uniform]
		if uniform in Settings.BOOLS:
			expected = bool(expected)
		elif uniform == "color_bands":
			expected = int(expected)
		check(effect._sketch_material.get_shader_parameter(uniform) == expected, "唯一参数生效：" + uniform)
	for uniform in Settings.COLORS:
		var channels: Array = defaults[uniform]
		check(effect._sketch_material.get_shader_parameter(uniform) == Color(channels[0],channels[1],channels[2],channels[3]), "颜色参数实际送入Shader：" + uniform)
	var uniforms := RegEx.new()
	uniforms.compile("uniform\\s+\\w+\\s+(\\w+)")
	for found in uniforms.search_all(effect._sketch_material.shader.code):
		var uniform := found.get_string(1)
		check(uniform == "screen_texture" or defaults.has(uniform), "Shader不存在未接入配置的参数："+uniform)
	await panel_cases(defaults)
	if DisplayServer.get_name() != "headless":
		await graphics()
	# 全局调参面板不可跨换场景遗留暂停，先恢复玩家的真实捕获状态。
	Input.mouse_mode = Input.MOUSE_MODE_CAPTURED
	root.get_node("GameFlow")._resume_play()
	effect._sketch_panel.open()
	check(effect._sketch_panel.opened, "场景退出清理的前置面板实际打开")
	current_scene = null
	world.queue_free()
	await frames(2)
	check(not paused and not effect._sketch_panel.opened and not root.get_node("GameFlow").has_meta(&"sketch_tuning_modal"), "场景退出关闭全局F9并清除暂停与模态")
	effect.set_style(0)
	print("[手绘滤镜] checks=", checks, " failures=", failures)
	quit(1 if failures else 0)

func panel_cases(defaults: Dictionary) -> void:
	effect.set_style(0)
	var panel: CanvasLayer = effect._sketch_panel
	key(KEY_F9)
	await frames(2)
	check(panel.opened and paused and root.get_node("GameFlow").has_meta(&"sketch_tuning_modal"), "真实F9打开，暂停战斗并预览手绘")
	key(KEY_F7)
	key(KEY_F8)
	check(not player._melee._panel.opened and not player._support_panel.opened, "F9与F7 / F8互斥")
	var hash_before := FileAccess.get_sha256(Settings.PATH)
	panel._fields.line_thickness.value = 0.637
	check(effect.parameters.line_thickness == 0.637 and effect.parameters.paper_tint == defaults.paper_tint, "单字段草稿精度不污染其他参数")
	check(panel._status.text.begins_with("未保存") and FileAccess.get_sha256(Settings.PATH) == hash_before, "调参不自动写项目配置，显示未保存")
	check(ProjectSettings.globalize_path("res://").replace("\\", "/").contains("/tmp/project/"), "保存验收只运行隔离工程")
	if ProjectSettings.globalize_path("res://").replace("\\", "/").contains("/tmp/project/"):
		panel._save()
		check(Settings.load_values().line_thickness == 0.637 and panel._status.text == "与项目默认一致", "显式保存并回读，状态与实际文件一致")
		panel._recipe("mono")
		panel._reload()
		check(effect.parameters.line_thickness == 0.637 and effect.parameters.monochrome_mode == 0, "草稿配方不覆盖默认；可重读已保存值")
		check(Settings.save_values(defaults) == OK, "隔离配置恢复基线")
		panel._reload()
	key(KEY_ESCAPE)
	check(not panel.opened and not paused and effect.style == 0, "Esc只关F9并还原先前显示风格，不打开暂停菜单")
	player._support_panel.open()
	panel.open()
	check(not panel.opened, "已有F8时F9不能抢占暂停")
	player._support_panel.close()
	await frames(1)
	key(KEY_F9)
	panel._use_style(5)
	check(not panel.opened and effect.style == 5 and root.get_node("DisplaySettings").post_process_style == 5, "本机启用与项目配方保存分开，关闭面板后继续手绘")
	var saved := ConfigFile.new()
	check(saved.load("user://display.cfg") == OK and int(saved.get_value("display", "post_process_style", -1)) == 5, "本机风格写入显示设置")
	root.get_node("DisplaySettings").select_post_process_style(0)

func graphics() -> void:
	# 同一固定场景，有正式警告边界 / 填充与100个静态几何体；不是百体AI性能验收。
	player.visible = false
	player._wisp.visible = false
	root.size = Vector2i(1280, 720)
	root.content_scale_factor = 1.0
	var y := Terrain.height_at(0,0)
	var floor_body := StaticBody3D.new()
	var shape := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = Vector3(80,1,80)
	shape.shape = box
	floor_body.add_child(shape)
	floor_body.position.y = y - 0.5
	world.add_child(floor_body)
	var floor_mesh := MeshInstance3D.new()
	var plane := PlaneMesh.new()
	plane.size = Vector2(80,80)
	floor_mesh.mesh = plane
	var mat := StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.albedo_color = Color(0.55,0.37,0.15)
	floor_mesh.material_override = mat
	floor_body.add_child(floor_mesh)
	floor_mesh.position.y = 0.501
	var env := WorldEnvironment.new()
	env.environment = Environment.new()
	env.environment.background_mode = Environment.BG_COLOR
	env.environment.background_color = Color(0.10,0.18,0.25)
	world.add_child(env)
	for i in range(100):
		var mesh := MeshInstance3D.new()
		var primitive := BoxMesh.new()
		primitive.size = Vector3(0.6,1.5 + (i % 3)*0.3,0.6)
		mesh.mesh = primitive
		var material := StandardMaterial3D.new()
		material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		material.albedo_color = Color(0.15 + (i%4)*0.1,0.4,0.35)
		mesh.material_override = material
		mesh.position = Vector3(-14 + (i%20)*1.5,y + 1.0,-16 - (i/20)*1.5)
		world.add_child(mesh)
	camera = Camera3D.new()
	world.add_child(camera)
	camera.position = Vector3(15,y+20,22)
	camera.look_at(Vector3(0,y,-2))
	camera.make_current()
	warning = preload("res://scripts/enemy_attack_area.gd").new()
	world.add_child(warning)
	await physics_frame
	warning.prepare(Transform3D(Basis(),Vector3(0,y+0.03,-2)), {"kind":"circle", "radius":5.0}, 30.0)
	warning.set_progress(0.55)
	warning.set_physics_process(false)
	hud = CanvasLayer.new()
	hud.layer = 1
	world.add_child(hud)
	var hud_background := ColorRect.new()
	hud_background.position = Vector2(10,10)
	hud_background.size = Vector2(430,85)
	hud_background.color = Color(0.035,0.045,0.06,1.0)
	hud.add_child(hud_background)
	var swatch := ColorRect.new()
	swatch.position = Vector2(20,20)
	swatch.size = Vector2(80,60)
	swatch.color = Color(0.2,0.8,0.3)
	hud.add_child(swatch)
	var label := Label.new()
	label.position = Vector2(110,20)
	label.text = "HUD 012345 · E / SPACE / C"
	hud.add_child(label)
	paused = true
	var images: Dictionary = {}
	for mode in ["off", "legacy", "light", "mono"]:
		effect.apply_sketch_parameters(Settings.recipe("legacy" if mode == "off" else mode))
		effect.set_style(0 if mode == "off" else 5)
		await frames(12)
		var image := root.get_texture().get_image()
		images[mode] = image
		check(image.save_png(Artifacts.ensure_dir("screenshots", "sketch").path_join(mode + ".png")) == OK, "对照画面保存：" + mode)
		check(image.get_pixel(50,45).is_equal_approx(images.off.get_pixel(50,45)), "HUD色块不被手绘改变：" + mode)
		var warning_pixels := red_pixels(image)
		check(warning_pixels > 100, "全范围边界 / 填充仍有红色信号：" + mode)
		for angle in [0.0,PI*0.5,PI,PI*1.5]:
			var point := Vector3(cos(angle)*4.85,y+0.1,-2+sin(angle)*4.85)
			var pixel: Vector2 = root.get_stretch_transform() * camera.unproject_position(point)
			check(red_patch(image,pixel), "已公布外沿四向保色：%s / %.2f" % [mode,angle])
	check(images.light.get_data() != images.off.get_data(), "手绘实际改变世界画面，不是只切开关")
	check(images.light.get_region(Rect2i(20,20,380,60)).get_data() == images.off.get_region(Rect2i(20,20,380,60)).get_data(), "HUD文字与色块整块像素一致")
	var road_color: Color = images.mono.get_pixel(300,600)
	check(absf(road_color.r-road_color.g)<0.08 and absf(road_color.g-road_color.b)<0.08, "黑白不再让整片黄色地面绕过滤镜")
	var no_protection := Settings.recipe("mono")
	no_protection.preserve_red_signals = 0
	effect.apply_sketch_parameters(no_protection)
	await frames(4)
	var without := root.get_texture().get_image()
	check(red_pixels(images.mono) > red_pixels(without), "移除红色保色的反例确实减少警告信号，不只是空开关")
	check(without.save_png(Artifacts.ensure_dir("screenshots","sketch").path_join("mono_without_red_guard.png")) == OK, "保色反例截图保存")
	paused = false
	effect.apply_sketch_parameters(Settings.load_values())
	effect.set_style(0)

func red_pixels(image: Image) -> int:
	var count := 0
	# 只计警告附近，排除HUD和远处几何体。
	for y in range(220,550,2):
		for x in range(370,900,2):
			var c := image.get_pixel(x,y)
			if c.r > c.g * 1.8 and c.r > c.b * 2.0 and c.r > 0.15:
				count += 1
	return count

func red_patch(image: Image, point: Vector2) -> bool:
	for y in range(maxi(int(point.y)-5,0),mini(int(point.y)+6,image.get_height())):
		for x in range(maxi(int(point.x)-5,0),mini(int(point.x)+6,image.get_width())):
			var c := image.get_pixel(x,y)
			if c.r > c.g*1.8 and c.r > c.b*2 and c.r>0.2:
				return true
	return false
