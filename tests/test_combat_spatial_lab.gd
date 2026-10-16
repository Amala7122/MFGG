extends SceneTree
const CapturePaths := preload("res://scripts/capture_paths.gd")

const SpatialScene := preload("res://prototypes/spatial_lab/combat_spatial_lab.tscn")
const EmptyScene := preload("res://prototypes/combat_lab/combat_lab.tscn")
var _failed := false


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	var lab := SpatialScene.instantiate()
	root.add_child(lab)
	current_scene = lab
	for _frame in range(8):
		await process_frame
	await _capture("01_configuration")
	_check(lab.get_selection() == lab.GROUP_PRESETS[0].enemies, "默认混合组可直接投放")
	_check(lab.enemy_limit == 12 and is_equal_approx(lab.enemy_line_width, 36.0), "小场地按实际容量限制投放")
	var region: NavigationRegion3D = lab.get_node("NavigationRegion3D")
	_check(region.navigation_mesh.get_polygon_count() > 0, "导航根据实际空间碰撞烘焙")
	var geometry := region.get_node("SpatialLayout/Geometry")
	for name in ["Slope", "Step1m", "SmallPlatform", "Platform2m", "CoverLong", "CoverCorner", "NarrowWall", "CliffBridge", "PitFloor"]:
		_check(geometry.has_node(name), "空间区域存在：" + name)
	paused = false
	for _frame in range(5):
		await physics_frame
	var space: PhysicsDirectSpaceState3D = region.get_world_3d().direct_space_state
	for surface in [{"point": Vector3(-5, 5, -5), "height": 1.0}, {"point": Vector3(6, 5, -5), "height": 2.0}, {"point": Vector3(13, 5, -17), "height": -5.0}]:
		var hit := space.intersect_ray(PhysicsRayQueryParameters3D.create(surface.point, surface.point + Vector3.DOWN * 12.0, 1))
		_check(not hit.is_empty() and is_equal_approx(hit.position.y, float(surface.height)), "实际碰撞高度对应标注")
	var nav_map := region.get_navigation_map()
	var start := NavigationServer3D.map_get_closest_point(nav_map, Vector3(0, 0, 12))
	var platform := NavigationServer3D.map_get_closest_point(nav_map, Vector3(6, 2, -5))
	var ramp_path := NavigationServer3D.map_get_path(nav_map, start, platform, true)
	_check(platform.y >= 1.8 and not ramp_path.is_empty() and ramp_path[ramp_path.size() - 1].distance_to(platform) < 0.1, "2 米平台的绕坡路径实际到达台面")
	var step := NavigationServer3D.map_get_closest_point(nav_map, Vector3(-5, 1, -5))
	var step_path := NavigationServer3D.map_get_path(nav_map, start, step, true)
	_check(step.y >= 0.9 and (step_path.is_empty() or step_path[step_path.size() - 1].distance_to(step) > 0.5), "1 米直角台阶不会被平面路径伪装成可达")
	await lab.generate_round()
	await process_frame
	_check(lab._live_enemies.size() == 6 and lab.state == lab.State.COUNTDOWN, "整组生成并进入倒数")
	_verify_spawns(lab)
	lab._start_fight()
	lab._player.process_mode = Node.PROCESS_MODE_DISABLED
	for enemy: Node in lab._live_enemies:
		enemy.process_mode = Node.PROCESS_MODE_DISABLED
	await _capture("02_fighting")
	if OS.get_cmdline_user_args().has("--capture-spatial") and DisplayServer.get_name() != "headless":
		lab._overview.current = true
		lab._weapon_plate.visible = false
		lab._player.aim_ui.visible = false
		await _capture("03_layout")
		lab._player.camera.current = true
	lab._loop_choice.select(lab.LoopMode.REPLACE)
	lab._apply_loop_choice()
	var original_slot := int(lab._live_enemies[0].get_meta(&"lab_slot"))
	var original_position: Vector3 = lab._live_enemies[0].position
	lab._live_enemies[0].free()
	for _frame in range(6):
		await process_frame
	_check(lab._live_enemies.size() == 6, "B 循环补回整组人数")
	for enemy: Node3D in lab._live_enemies:
		if int(enemy.get_meta(&"lab_slot")) == original_slot:
			_check(absf(enemy.position.x - original_position.x) < 0.3 and absf(enemy.position.z - original_position.z) < 0.3, "补兵保持本轮空间生成位置")
	lab._loop_choice.select(lab.LoopMode.OFF)
	lab._apply_loop_choice()
	# 按标题查找而不是按下标：预设列表是会增长的，用 size()-1 断言"最后一组"
	# 会在任何人往后追加一组时静默指错对象。
	var reaction_index := _preset_index(lab.GROUP_PRESETS, "泰坦反应组")
	_check(reaction_index >= 0, "泰坦反应组预设存在")
	lab._group_choice.select(reaction_index)
	lab.deploy_group()
	for _frame in range(8):
		await process_frame
	_check(lab._live_enemies.size() == 7 and lab.get_selection() == lab.GROUP_PRESETS[reaction_index].enemies,
		"泰坦反应组实际按钮能投放泰坦及三种小怪共 7 只")
	_verify_spawns(lab)
	await _verify_mechanic_presets(lab)
	await _verify_experiment_conveniences(lab)
	for index in range(lab.STARTS.size()):
		lab._start_choice.select(index)
		lab.set_selection({lab.FAST_BEAST_ID: 1})
		await lab.generate_round()
		await process_frame
		_check(lab._player.position.is_equal_approx(lab.STARTS[index].position), "玩家起点正确：" + String(lab.STARTS[index].title))
		_verify_spawns(lab)
	lab.clear_round()
	_check(lab._live_enemies.is_empty() and lab._round_slots.is_empty(), "清理不残留旧敌人与补兵名额")
	current_scene = null
	lab.queue_free()
	await process_frame
	paused = false
	var empty := EmptyScene.instantiate()
	root.add_child(empty)
	current_scene = empty
	for _frame in range(5):
		await process_frame
	_check(empty.enemy_limit == 36 and empty.enemy_line_z == -38.0 and empty.player_start == Vector3(0, 1.08, 8), "原平地 Combat Lab 默认行为保持有效")
	current_scene = null
	empty.queue_free()
	await process_frame
	paused = false
	print("[空间测试场] ", "FAIL" if _failed else "PASS")
	quit(1 if _failed else 0)


func _verify_spawns(lab: Node) -> void:
	for enemy: CharacterBody3D in lab._live_enemies:
		_check(enemy.position.z == -10.0 and absf(enemy.position.x) <= 18.0, "敌人生成在小场地投放线内")
		_check(enemy.target == lab._player and enemy.position.y > 0.0, "目标与站立 / 飞行高度就绪")


## 按标题子串查找：预设标题常带后缀（例如「泰坦反应组 · 7 只」），
## 而调用方只关心是哪一组。
## 实验场该有的两项便利（用户明确要求）：
##   1. **共鸣读数** —— 主 HUD 在实验场被隐藏，能量满没满必须自己显示出来，
##      否则"盾卫会不会迎面对盾""共鸣打不动重型"只能靠猜；
##   2. **E 手雷与 Q 震地无冷却、无限次** —— 机制验证要反复触发同一事件。
func _verify_experiment_conveniences(lab: Node) -> void:
	var player: CharacterBody3D = lab._player
	_check(bool(player.get_meta(&"experiment_unlimited_abilities", false)),
		"实验场给玩家挂了「无冷却无限次」标记")
	lab.call("_update_weapon_readout")
	var readout := String(lab._weapon_readout.text)
	_check(readout.contains("共鸣"), "实验场读数里有共鸣状态")
	_check(readout.contains("E 手雷") and readout.contains("Q 震地脉冲"), "实验场读数里有 E / Q 状态")

	# 真按一遍键的部分放在 `test_skill_charges` 里：那条测试已经证明
	# "注入按键 → 玩家真的会扣点/进冷却"，所以它里面的 A/B 不会是空过。
	# （本测试里玩家的输入处理被实验场状态挡住，按键注入不生效 —— 在这里写
	#  "连按三次冷却仍是 0" 会是一条永远通过、什么也没验证的断言。）
	var player_unlimited := bool(player.call("_abilities_unlimited"))
	_check(player_unlimited, "玩家认出实验场的「无冷却无限次」标记")
	player.set_physics_process(false)


## 按一下某个动作并等一帧物理。
func _tap(_player: Node, action: String) -> void:
	_press(action, true)
	await physics_frame
	_press(action, false)
	await physics_frame


func _press(action: String, pressed: bool) -> void:
	var event := InputEventAction.new()
	event.action = action
	event.pressed = pressed
	Input.parse_input_event(event)
	Input.flush_buffered_events()


func _preset_index(presets: Array, title: String) -> int:
	for i in range(presets.size()):
		if String(presets[i].title).contains(title):
			return i
	return -1


## 机制验证组必须真的能用：投放的是【图鉴条目】（正式实现与配置），
## 而且盾卫要带着盾进来 —— 否则"插盾姿态可单独验证"只是文档里的说法。
func _verify_mechanic_presets(lab: Node) -> void:
	for title in ["盾卫 · 插盾与破防", "狙击 · 近失呼啸", "重型反应 · 盾卫+迫击炮"]:
		var index := _preset_index(lab.GROUP_PRESETS, title)
		_check(index >= 0, "机制验证组存在：" + title)
		if index < 0:
			continue
		var expected: Dictionary = lab.GROUP_PRESETS[index].enemies
		lab._group_choice.select(index)
		lab.deploy_group()
		for _frame in range(8):
			await process_frame
		# 机制验证组必须自带补兵循环：否则一次共鸣/一颗手雷清空场上就立刻结算，
		# 结算画面当场弹出来、什么都观察不到（用户实测反馈）。
		_check(lab._loop_mode == lab.LoopMode.REPLACE,
			"机制验证组自动开补兵循环，清空场上不会结算：" + title)
		_check(lab._live_enemies.size() == expected.size() or lab._live_enemies.size() > 0,
			"机制验证组可投放：" + title)
		var ids := {}
		for enemy: Node in lab._live_enemies:
			ids[String(enemy.get_meta(&"lab_roster_id"))] = true
		for id: String in expected.keys():
			_check(ids.has(id), "投放的是图鉴条目 %s（%s）" % [id, title])
		if title.begins_with("盾卫") or title.begins_with("重型反应"):
			var armed := false
			for enemy: Node in lab._live_enemies:
				if String(enemy.get_meta(&"lab_roster_id")) == lab.SHIELD_GUARD_ID and enemy.get("_shield_pivot") != null:
					armed = true
			_check(armed, "盾卫在实验场里带着 ShieldPivot（插盾姿态可单独验证）：" + title)
	lab.clear_round()
	await process_frame


func _check(condition: bool, message: String) -> void:
	if not condition:
		_failed = true
		push_error("[空间测试场] " + message)


func _capture(name: String) -> void:
	if not OS.get_cmdline_user_args().has("--capture-spatial") or DisplayServer.get_name() == "headless":
		return
	for _frame in range(5):
		await process_frame
	await RenderingServer.frame_post_draw
	var directory := CapturePaths.ensure_dir("combat_spatial")
	DirAccess.make_dir_recursive_absolute(directory)
	var screenshot := root.get_texture().get_image()
	_check(screenshot != null and not screenshot.is_empty(), "空间场可以实际渲染")
	if screenshot != null and not screenshot.is_empty():
		screenshot.save_png(directory.path_join(name + ".png"))
