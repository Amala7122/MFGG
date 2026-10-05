extends SceneTree
## 菜单/提示的布局与真实渲染验收；不提交成绩、不保存显示配置。
const Flow := preload("res://scripts/game_flow.gd")
const GlassButton := preload("res://scripts/glass_button.gd")
const Notices := preload("res://scripts/notification_stack.gd")
const Terrain := preload("res://scripts/terrain_field.gd")
const CapturePaths := preload("res://scripts/capture_paths.gd")
var _failures := 0
var _capture := false

func _initialize() -> void:
	_capture = "--capture" in OS.get_cmdline_user_args() and DisplayServer.get_name() != "headless"
	call_deferred("_run")

func _run() -> void:
	change_scene_to_file("res://scenes/hyrule_field.tscn")
	await _settle()
	root.mode = Window.MODE_WINDOWED
	root.size = Vector2i(1920, 1080)
	root.content_scale_factor = 1.0
	var flow := root.get_node("GameFlow")
	flow.call("_enter_menu")
	await _settle()
	_check(ProjectSettings.get_setting("application/config/name") == "遗迹星球", "游戏名称")
	if OS.get_name() == "Windows":
		_check(OS.get_user_data_dir().replace("\\", "/").ends_with("Godot/app_userdata/godot-zelda"), "改名后保留原用户目录")
	_check(flow.get("_title").text == "遗迹星球", "开始页标题")
	_check(not flow.get("_body").visible and not flow.get("_caption").visible and not flow.get("_hint").visible, "开始页无介绍/操作文字")
	_verify_menu(flow)
	await _save("01_start")
	flow.call("_on_open_display_settings")
	await _settle()
	_verify_menu(flow)
	await _save("02_settings")
	flow.call("_on_display_settings_back")
	await _settle()
	_check(flow.get("state") == Flow.State.MENU and not flow.get("_body").visible, "设置返回不会残留介绍")
	flow.call("_enter_pause")
	await _settle()
	_verify_menu(flow)
	await _save("03_pause")
	flow.call("_on_open_display_settings")
	await _settle()
	flow.call("_on_display_settings_back")
	await _settle()
	_check(flow.get("state") == Flow.State.PAUSED, "暂停设置页返回正确")
	flow.call("_enter_stage_cleared", 1)
	await _settle()
	_verify_menu(flow)
	await _save("08_stage_clear")
	flow.set("state", Flow.State.GAME_OVER)
	flow.call("_show_game_over", 219.57, 47, 373.58, 228, false)
	await _settle()
	_verify_menu(flow)
	_check(flow.get("_stats_row").get_child_count() == 3, "结算统计保留")
	await _save("04_game_over")
	root.size = Vector2i(1280, 720)
	root.content_scale_factor = 1.3
	await _settle()
	_verify_menu(flow)
	await _save("05_small_scaled")
	flow.call("_enter_menu")
	await _settle()
	_verify_menu(flow)
	_check(not flow.get("_stats_row").visible and not flow.get("_body").visible, "返回开始页没有统计残留")
	# 单独展示实际拾取通知；关闭战斗刷新，避免随机场景污染验收。
	root.size = Vector2i(1920, 1080)
	root.content_scale_factor = 1.0
	flow.visible = false
	flow.process_mode = Node.PROCESS_MODE_DISABLED
	paused = false
	var player := (load("res://scenes/player.tscn") as PackedScene).instantiate()
	current_scene.add_child(player)
	player.global_position = Vector3(0, Terrain.height_at(0, 28) + 1, 28)
	player.get_node("CameraPivot/SpringArm3D/Camera3D").make_current()
	player.set_physics_process(false)
	player.set_process(false)
	await _settle()
	var hud: Node = player.get("_hud")
	hud.get("_weapon_panel").update_state(30, 30, 180, false, 0, 1, 1, 20)
	var notices: Control = hud.get("_notifications")
	notices.set_process(false)
	hud.show_notice("生命 +25", "health")
	hud.show_notice("弹药 +60", "ammo")
	_check(notices.get("_items").is_empty(), "普通补给不增加战斗日志")
	for text in ["射速模块 +1", "威力模块 +1", "弹匣模块 +1", "额外模块 +1"]:
		hud.show_notice(text, "upgrade")
	notices.set_process(false)
	_check(notices.get("_items").size() == Notices.MAX_ITEMS, "最多显示三条")
	notices.call("_process", 0.25)
	await _settle()
	await _save("06_pickup")
	var layers: Array = notices.get_meta("hud_glass_layers")
	for glass in layers:
		_check(glass.visible, "通知有玻璃背景")
		_check(Geometry2D.triangulate_polygon(glass.get("_shape")).size() > 0, "通知轮廓合法")
		_check(is_equal_approx(glass.material.get_shader_parameter("surface_opacity"), 1), "通知玻璃稳定透明度")
		notices.call("_process", 0.0)
	notices.call("_process", Notices.LIFETIME - 0.40)
	await _settle()
	await _save("07_pickup_fade")
	for glass in layers:
		_check(float(glass.material.get_shader_parameter("surface_opacity")) < 0.5, "玻璃随提示一起淡出")
	notices.call("_process", 0.5)
	await _settle()
	_check(notices.get("_items").is_empty(), "提示到期清空")
	for glass in layers:
		_check(not glass.visible, "没有遗留空玻璃卡片")
	# 点击真正的开始按钮：菜单相机必须随场景重载消失，玩家相机接管。
	flow.visible = true
	flow.process_mode = Node.PROCESS_MODE_ALWAYS
	flow.call("_enter_menu")
	await _settle()
	var menu_camera: WeakRef = weakref(flow.get("_menu_camera"))
	flow.get("_actions").get_child(0).pressed.emit()
	await _settle()
	_check(flow.get("state") == Flow.State.PLAYING and not flow.get("_root").visible, "开始按钮正常开局并隐藏菜单")
	_check(menu_camera.get_ref() == null, "开局释放开始页相机")
	_check(root.get_camera_3d() != null and root.get_camera_3d().name != "MainMenuCamera", "玩家相机接管")
	flow.call("_enter_pause")
	await _settle()
	flow.call("_on_resume")
	_check(not paused and flow.get("state") == Flow.State.PLAYING, "暂停后继续流程不变")
	print("[UI 统一验收] failures=", _failures)
	quit(1 if _failures else 0)

func _settle() -> void:
	for i in 24:
		await process_frame
	# Tween 用真实时间；headless 高帧率下也必须等入场结束。
	await create_timer(0.3, true).timeout
	await process_frame

func _verify_menu(flow: Node) -> void:
	var panel: Control = flow.get("_panel")
	var rect := panel.get_global_rect()
	_check(root.get_visible_rect().encloses(rect), "菜单在视口范围内")
	_check(panel.has_meta("hud_glass_layers"), "菜单黑玻璃材质")
	var actions: Control = flow.get("_actions")
	_check(actions.get_child_count() > 0, "有可操作按钮")
	for button in actions.get_children():
		_check(button.get_script() == GlassButton, "按钮统一黑玻璃")
		_check(rect.encloses(button.get_global_rect()), "按钮没有溢出面板")
		_check(button.pressed.get_connections().size() == 1, "按钮原有回调保留")
	_check(root.gui_get_focus_owner() in actions.get_children(), "键盘焦点落在菜单按钮")
	for plate in flow.get("_stats_row").get_children():
		_check(plate.get("glass_style"), "统计卡统一玻璃")

func _save(name: String) -> void:
	if not _capture:
		return
	await RenderingServer.frame_post_draw
	var path := CapturePaths.ensure_dir("ui_surfaces").path_join(name + ".png")
	_check(root.get_texture().get_image().save_png(path) == OK, "保存截图 " + name)
	print("[UI 截图] ", path)

func _check(ok: bool, description: String) -> void:
	if not ok:
		_failures += 1
		push_error(description)
