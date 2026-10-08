extends SceneTree
## 菜单/提示的布局与真实渲染验收；不提交成绩、不保存显示配置。
const Flow := preload("res://scripts/game_flow.gd")
const GlassButton := preload("res://scripts/glass_button.gd")
const Notices := preload("res://scripts/notification_stack.gd")
const Terrain := preload("res://scripts/terrain_field.gd")
const CapturePaths := preload("res://scripts/capture_paths.gd")
const Upgrades := preload("res://scripts/upgrade_pool.gd")
const RunState := preload("res://scripts/run_state.gd")
const UiTheme := preload("res://scripts/ui_theme.gd")
var _failures := 0
var _capture := false

func _initialize() -> void:
	_capture = "--capture" in OS.get_cmdline_user_args() and DisplayServer.get_name() != "headless"
	call_deferred("_run")

func _run() -> void:
	change_scene_to_file("res://scenes/hyrule_field.tscn")
	await _settle()
	root.mode = Window.MODE_WINDOWED
	_resize_window(Vector2i(1920, 1080))
	root.content_scale_factor = 1.0
	var flow := root.get_node("GameFlow")
	flow.call("_enter_menu")
	await _settle()
	_check(ProjectSettings.get_setting("application/config/name") == "遗迹星球-new", "合并项目名称")
	if OS.get_name() == "Windows":
		var configured_dir := String(ProjectSettings.get_setting("application/config/custom_user_dir_name"))
		_check(OS.get_user_data_dir().replace("\\", "/").ends_with(configured_dir.replace("\\", "/")), "使用项目配置的用户目录")
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
	flow.call("_resume_play")
	flow.call("_enter_stage_cleared", 1)
	await _settle()
	_verify_menu(flow)
	await _save("08_stage_clear")
	await _upgrade_cases(flow)
	flow.set("state", Flow.State.GAME_OVER)
	flow.call("_show_game_over", 219.57, 47, 373.58, 228, false)
	await _settle()
	_verify_menu(flow)
	_check(flow.get("_stats_row").get_child_count() == 3, "结算统计保留")
	await _save("04_game_over")
	_resize_window(Vector2i(1280, 720))
	root.content_scale_factor = 1.3
	await _settle()
	_verify_menu(flow)
	await _save("05_small_scaled")
	flow.call("_enter_menu")
	await _settle()
	_verify_menu(flow)
	_check(not flow.get("_stats_row").visible and not flow.get("_body").visible, "返回开始页没有统计残留")
	# 单独展示实际拾取通知；关闭战斗刷新，避免随机场景污染验收。
	_resize_window(Vector2i(1920, 1080))
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

func _upgrade_cases(flow: Node) -> void:
	var picks: Array[Dictionary] = [Upgrades.get_perk("incendiary_rounds"),
		Upgrades.get_perk("armor_pierce"), Upgrades.get_perk("resonance_burn")]
	var colors := [UiTheme.COLOR_BODY, UiTheme.COLOR_ACCENT, UiTheme.COLOR_TITLE]
	for dimensions in [Vector2i(1920, 1080), Vector2i(1280, 720), Vector2i(960, 540)]:
		for factor in [0.85, 1.0, 1.15, 1.3]:
			_resize_window(dimensions)
			root.content_scale_factor = factor
			flow.call("_enter_upgrade_pick", picks, 1, 4)
			await _settle()
			var canvas := Vector2(root.content_scale_size)
			if canvas == Vector2.ZERO:
				canvas = Vector2(dimensions)
			_check(root.get_visible_rect().size.distance_to(canvas / factor) < 1.0,
				"赐福验收尊重项目画布与 UI 缩放 requested=%s scale=%.2f actual=%s canvas=%s" %
				[dimensions, factor, root.get_visible_rect().size, canvas])
			if DisplayServer.get_name() != "headless":
				_check(root.size == dimensions, "图形验收实际改变窗口尺寸")
			var panel: Control = flow.get("_panel")
			var scroll: ScrollContainer = flow.get("_action_scroll")
			_check(root.get_visible_rect().encloses(panel.get_global_rect()), "赐福面板在小窗口和 UI 缩放下不溢出")
			var actions: VBoxContainer = flow.get("_actions")
			_check(actions.get_child_count() == 3, "赐福页只保留三个当前选项")
			for index in range(3):
				var button := actions.get_child(index) as Button
				_check(button.autowrap_mode == TextServer.AUTOWRAP_WORD_SMART,
					"赐福说明实际启用自动换行")
				_check(is_equal_approx(button.custom_minimum_size.x, minf(540.0, flow.get("_column").custom_minimum_size.x))
					and is_equal_approx(button.custom_minimum_size.y, 64.0), "赐福按钮消费宽高参数")
				for color_name in ["font_color", "font_hover_color", "font_pressed_color", "font_focus_color", "font_hover_pressed_color"]:
					_check(button.get_theme_color(color_name) == colors[index], "稀有度颜色在各交互状态保留")
				var font := button.get_theme_font("font")
				var height := font.get_multiline_string_size(button.text, HORIZONTAL_ALIGNMENT_CENTER,
					button.size.x - 36.0, button.get_theme_font_size("font_size")).y + 16.0
				_check(button.size.y + 1.0 >= height, "赐福标题与完整说明没有被截断")
				button.grab_focus()
				await process_frame
				await process_frame
				_check(root.gui_get_focus_owner() == button, "方向键焦点可落在每张赐福")
				_check(scroll.get_global_rect().grow(1.0).encloses(button.get_global_rect()),
					"滚动区域跟随焦点，每个赐福按钮完整可见 %s x%.2f #%d scroll=%s button=%s" %
					[dimensions, factor, index, scroll.get_global_rect(), button.get_global_rect()])
			if dimensions == Vector2i(1920, 1080) and factor == 1.0:
				await _save("09_upgrade")
			if dimensions == Vector2i(1280, 720) and factor == 1.3:
				await _save("10_upgrade_small_scaled")
	# 按数字键与真正的按钮输入都只能选择一次。
	_resize_window(Vector2i(1920, 1080))
	root.content_scale_factor = 1.0
	for mode in ["number", "mouse", "enter"]:
		flow.call("_enter_upgrade_pick", picks, 1, 4)
		await _settle()
		var button := flow.get("_actions").get_child(1) as Button
		var before := RunState.get_perk_count("armor_pierce")
		button.grab_focus()
		if mode == "number":
			var event := InputEventKey.new()
			event.physical_keycode = KEY_2
			event.pressed = true
			flow.call("_input", event)
		elif mode == "mouse":
			for pressed in [true, false]:
				var event := InputEventMouseButton.new()
				event.button_index = MOUSE_BUTTON_LEFT
				event.position = button.get_global_rect().get_center()
				event.global_position = event.position
				event.pressed = pressed
				root.push_input(event, true)
		else:
			for pressed in [true, false]:
				var event := InputEventAction.new()
				event.action = "ui_accept"
				event.pressed = pressed
				root.push_input(event, true)
		_check(RunState.get_perk_count("armor_pierce") == before + 1
			and flow.get("state") == Flow.State.PLAYING and not paused, "数字键/鼠标/确认键实际选卡并继续")
		button.pressed.emit()
		_check(RunState.get_perk_count("armor_pierce") == before + 1, "旧按钮或重复确认不会再添加赐福")
	print("[UI 统一验收] 赐福三种稀有度、12 组窗口/缩放与三种选卡输入通过")


func _resize_window(dimensions: Vector2i) -> void:
	root.size = dimensions
	if DisplayServer.get_name() == "headless":
		root.content_scale_size = dimensions


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
