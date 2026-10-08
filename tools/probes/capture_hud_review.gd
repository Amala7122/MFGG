extends SceneTree
## 手动视觉验收：实际场景下的正常、低弹药/冷却、夜晚状态。
const CapturePaths := preload("res://scripts/capture_paths.gd")
const Terrain := preload("res://scripts/terrain_field.gd")
const WeaponPanel := preload("res://scripts/weapon_panel.gd")
const AbilityBar := preload("res://scripts/ability_bar.gd")
const Minimap := preload("res://scripts/minimap.gd")

func _initialize() -> void:
	call_deferred("_run")

func _run() -> void:
	change_scene_to_file("res://scenes/hyrule_field.tscn")
	for i in range(24):
		await process_frame
	# 只修改本次运行，不保存个人显示配置。
	root.mode = Window.MODE_WINDOWED
	root.size = Vector2i(1920, 1080)
	root.content_scale_factor = 1.0
	var game_flow := root.get_node("GameFlow")
	game_flow.visible = false
	game_flow.process_mode = Node.PROCESS_MODE_DISABLED
	paused = false
	Engine.time_scale = 1.0
	var player := (load("res://scenes/player.tscn") as PackedScene).instantiate()
	current_scene.add_child(player)
	player.global_position = Vector3(0, Terrain.height_at(0, 28) + 1, 28)
	player.get_node("CameraPivot/SpringArm3D/Camera3D").make_current()
	player.set_physics_process(false)
	player.set_process(false)
	# 静态标志用于验收小地图；不刷战斗实体、不修改真实波次逻辑。
	for point in [Vector2(-27, 7), Vector2(23, 19), Vector2(31, -9), Vector2(-18, -21), Vector2(18, 49), Vector2(-38, 43)]:
		var marker := Node3D.new()
		current_scene.add_child(marker)
		marker.global_position = Vector3(point.x, Terrain.height_at(point.x, point.y), point.y)
		marker.add_to_group("enemies")
	var hud: Node = player.get("_hud")
	if not _verify_alignment(hud):
		quit(1)
		return
	var weather := current_scene.get_node("WeatherEnvironment/WeatherSystem")
	var time := current_scene.get_node("WeatherEnvironment/Sky3D/TimeOfDay")
	time.set("game_time_enabled", false)
	CapturePaths.ensure_dir("hud_review")
	for mode in ["day", "cooldown", "night", "between_waves", "small_window", "large_ammo", "ui_scale"]:
		if mode == "small_window":
			root.mode = Window.MODE_WINDOWED
			root.size = Vector2i(1280, 720)
		elif mode == "ui_scale":
			root.size = Vector2i(2560, 1440)
			root.content_scale_factor = 1.15
		elif mode == "large_ammo":
			root.size = Vector2i(1920, 1080)
		time.set("current_time", 0.0 if mode == "night" else 14.0)
		weather.set_rain_amount(1.0 if mode == "night" else 0.0)
		weather.set_fog_amount(0.48 if mode == "night" else 0.06)
		weather.set("_rain_intensity", 1.0 if mode == "night" else 0.0)
		weather.call("_sync_extra_layers")
		weather.call("_update_environment")
		hud.set_health(27 if mode == "cooldown" else 100, 100)
		hud.set_shield(0 if mode == "cooldown" else 70, 70)
		hud.get("_weapon_panel").update_state(4 if mode == "cooldown" else 30, 30, 180, mode == "cooldown", 0.56, 1, 1, 20)
		if mode == "large_ammo":
			hud.get("_weapon_panel").update_state(376, 430, 150, false, 0, 1, 1, 20)
		hud.get("_weapon_panel").update_sniper(5, 5, 0.0, 20)
		hud.set_abilities(3.2 if mode == "cooldown" else 0.0, 6.0 if mode == "cooldown" else 0.0)
		hud.get("_wave_banner").update_wave({"stage":1,"arena_label":"寂石圣所","wave":2,"total_waves":4,"state":"交战中"})
		if mode == "between_waves":
			hud.get("_wave_banner").update_wave({"stage":1,"arena_label":"寂石圣所","wave":2,"total_waves":4,"state":"波间休整","timer":5.0})
		player.get_node("CameraPivot/FlashlightRig").set_light_enabled(mode == "night")
		if mode == "night":
			player.get_node("CameraPivot/FlashlightRig").set_light_enabled(true)
		# GameFlow 在场景切换阶段可能短暂冻结时间；视觉验收用确定的模拟步长，
		# 避免截图脚本依赖真实时间或当前帧率。
		for i in range(180):
			hud.get("_wave_banner").call("_process", 1.0 / 50.0)
			await process_frame
		# 持续战况更新不能把已经淡出的横幅再次唤醒。
		if mode != "between_waves":
			hud.get("_wave_banner").update_wave({"stage":1,"arena_label":"寂石圣所","wave":2,"total_waves":4,"state":"交战中","remaining":2})
			if hud.get("_wave_banner").visible:
				push_error("战斗波次提示未淡出")
				quit(1)
				return
		elif not hud.get("_wave_banner").visible:
			push_error("波间休整提示被错误隐藏")
			quit(1)
			return
		await RenderingServer.frame_post_draw
		if not _verify_alignment(hud) or not _verify_glass_geometry(hud):
			quit(1)
			return
		var path := CapturePaths.file("hud_review/%s.png" % mode)
		root.get_texture().get_image().save_png(path)
		print("[HUD 预览] ", path)
	quit()

func _verify_alignment(hud: Node) -> bool:
	var vitals := hud.get("_vitals") as Control
	var abilities := hud.get("_ability_bar") as Control
	var minimap := hud.get("_minimap") as Control
	var time_plate := hud.get("_game_time_plate") as Control
	var bottom := -WeaponPanel.MARGIN
	var ok := true
	ok = _check(is_equal_approx(vitals.offset_bottom, bottom), "生命护盾未与弹药板下基线对齐") and ok
	ok = _check(is_equal_approx(abilities.offset_bottom, bottom), "技能栏未与弹药板下基线对齐") and ok
	ok = _check(is_equal_approx(abilities.offset_right, minimap.offset_right), "Q 与小地图右基线不齐") and ok
	ok = _check(is_equal_approx(time_plate.offset_right, minimap.offset_right), "时间与小地图右基线不齐") and ok
	ok = _check(is_equal_approx(abilities.offset_right - abilities.offset_left, Minimap.PANEL_SIZE), "E+Q 总宽不等于小地图宽度") and ok
	ok = _check(is_equal_approx(AbilityBar.PANEL_WIDTH, Minimap.PANEL_SIZE), "技能栏与小地图常量宽度不一致") and ok
	return ok

func _check(condition: bool, message: String) -> bool:
	if condition:
		return true
	push_error(message)
	return false


func _verify_glass_geometry(hud: Node) -> bool:
	var ok := true
	for key in ["_vitals", "_ability_bar", "_weapon_panel", "_game_time_plate"]:
		var control := hud.get(key) as Control
		ok = _check(control.has_meta("hud_glass_layers"), key + " 缺少玻璃底层") and ok
		if not control.has_meta("hud_glass_layers"):
			continue
		for glass in control.get_meta("hud_glass_layers"):
			var shape: PackedVector2Array = glass.get("_shape")
			ok = _check(shape.size() >= 4, key + " 轮廓退化为三角形") and ok
			ok = _check(Geometry2D.triangulate_polygon(shape).size() == (shape.size() - 2) * 3, key + " 轮廓自交或无效") and ok
	var abilities := hud.get("_ability_bar") as Control
	var layers: Array = abilities.get_meta("hud_glass_layers")
	var e: PackedVector2Array = layers[0].get("_shape")
	var q: PackedVector2Array = layers[1].get("_shape")
	ok = _check(e.size() == 4 and is_equal_approx(e[0].x - e[3].x, e[1].x - e[2].x), "E 必须是同向斜边的平行四边形") and ok
	ok = _check(q.size() == 5 and absf(q[1].x - q[2].x) < 4, "Q 必须保持直右边及右下切角") and ok
	return ok
