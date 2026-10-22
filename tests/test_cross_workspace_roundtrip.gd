extends SceneTree
## T04 A1–A7：真实圣所、两条独立试点、真实GUI与逐项现场快照。
const World := preload("res://scenes/sanctum_main.tscn")
const Flow := preload("res://scripts/game_flow.gd")
const Run := preload("res://scripts/run_state.gd")
const Session := preload("res://scripts/testing/tuning_session.gd")
const Tuning := preload("res://scripts/prototypes/enemy_tuning.gd")
const Runtime := preload("res://scripts/testing/workspace_runtime.gd")
const Nav := preload("res://scripts/testing/professional_navigation.gd")
const Artifacts := preload("res://scripts/artifact_paths.gd")
const Bus := preload("res://scripts/event_bus.gd")
var failures: Array[String] = []
var checks := 0
var evidence: Array[Dictionary] = []
var world: Node3D
var player: Node3D
var beetle: Node3D
var titan: Node3D
var director: Node
var workspace: CanvasLayer
var navigation: CanvasLayer
var timer: Timer
var projectile: Node3D
var poison: Node3D
var death: Node3D
var peer: Node3D

func _initialize() -> void: _run.call_deferred()
func frames(count: int) -> void:
	for i in count: await process_frame
func check(ok: bool, message: String) -> void:
	checks += 1
	if not ok: failures.append(message); push_error(message)
func button(node: Node, text: String) -> Button:
	for child in node.get_children():
		if child is Button and child.text.begins_with(text): return child
		var found := button(child, text)
		if found: return found
	return null
func click(control: Control) -> void:
	check(control != null and control.is_visible_in_tree(), "真实入口可见")
	if control == null: return
	if control is Button: check(not control.disabled,"真实按钮已启用："+control.text)
	check(root.get_visible_rect().encloses(control.get_global_rect()), "真实入口在视口内")
	var point := control.get_global_rect().get_center()
	for down in [true, false]:
		var event := InputEventMouseButton.new()
		event.position = point; event.global_position = point
		event.button_index = MOUSE_BUTTON_LEFT; event.pressed = down
		event.button_mask = MOUSE_BUTTON_MASK_LEFT if down else 0
		root.push_input(event, true)
		await frames(1)
	await frames(3)
func capture(name: String) -> void:
	if DisplayServer.get_name() == "headless": return
	await RenderingServer.frame_post_draw
	check(root.get_texture().get_image().save_png(Artifacts.ensure_dir("screenshots").path_join(name+".png")) == OK, "实际窗口截图 "+name)
func scene_ids(node: Node) -> Array:
	var result: Array = []
	if not node.scene_file_path.is_empty(): result.append(node.get_instance_id())
	for child in node.get_children(): result.append_array(scene_ids(child))
	result.sort()
	return result
func snapshot() -> Dictionary:
	var enemies: Array = []
	var jobs: Array = []
	for reference: WeakRef in preload("res://scripts/combat_spatial_controller.gd")._jobs:
		if reference.get_ref() != null: jobs.append(reference.get_ref().get_instance_id())
	for item in get_nodes_in_group("enemies"): enemies.append(item.get_instance_id())
	enemies.sort()
	return {"scenes":scene_ids(world), "enemies":enemies, "spatial_jobs": jobs, "run":[Run.get_stage(), Run.get_wave(), Run.get_weapon_level(), Run.get_upgrades(), Run._perks.duplicate()],
		"wave":director.get_snapshot().duplicate(true), "wave_rng":director._random.state, "wave_cooldown":director._spawn_cooldown,
		"player_pose":player.global_transform, "health":player.health, "shield":player.shield, "kills":player.kill_count,
		"camera":root.get_camera_3d().get_instance_id(), "timer":timer.time_left, "titan_clock":titan.anim_clock,
		"projectile":[projectile.get_instance_id(), projectile._elapsed, projectile.global_transform, projectile._warning.get_instance_id()],
		"poison":[poison.get_instance_id(), poison.elapsed, poison.radius, poison.tick_damage],
		"death":[death.get_instance_id(), death._elapsed], "pickups":get_nodes_in_group("pickups").size()}
func compare(before: Dictionary, name: String) -> void:
	var after := snapshot()
	for key: String in before: check(before[key] == after[key], name+" 保留 "+key)
	check(current_scene == world and Flow.instance.state == Flow.State.PAUSED and paused, name+" 同一暂停圣所／GameFlow.PAUSED")
	check(MouseControl.mode == Input.MOUSE_MODE_VISIBLE, name+" 不捕获鼠标")
	evidence.append({"chain":name,"before":before,"after":after})
func select_object(object: Node) -> void:
	var index: int = workspace.objects.find(object)
	check(index >= 0,"实际对象列表含原实例")
	if index >= 0:
		workspace.list.select(index)
		workspace.list.ensure_current_is_visible()
		await frames(2)
		workspace.list.deselect_all()
		var rectangle: Rect2 = workspace.list.get_item_rect(index)
		var point: Vector2 = workspace.list.global_position + rectangle.get_center()
		point.y -= workspace.list.get_v_scroll_bar().value
		for down in [true,false]:
			var event := InputEventMouseButton.new()
			event.position = point; event.global_position = point
			event.button_index = MOUSE_BUTTON_LEFT; event.pressed = down
			root.push_input(event,true)
		await frames(4)
		print("[T04选择] index=",index," rect=",rectangle," scroll=",workspace.list.get_v_scroll_bar().value," selected=",Runtime.identity(workspace.selected).get("profile", ""))
	check(workspace.selected == object,"真实列表选择指向指定实例")

func _run() -> void:
	await frames(4)
	root.size = Vector2i(1280,720)
	root.content_scale_size = Vector2i(1280,720)
	var original := Tuning.storage_directory
	Tuning.storage_directory = Artifacts.ensure_dir("tmp","t04_presets")
	for profile: String in Tuning.PROFILE_PATHS:
		var path := original.path_join(profile+".json")
		if FileAccess.file_exists(path):
			var output := FileAccess.open(Tuning.storage_directory.path_join(profile+".json"),FileAccess.WRITE)
			output.store_buffer(FileAccess.get_file_as_bytes(path)); output.close()
	Tuning.reload_saved()
	Run.begin_run()
	Flow.instance.state = Flow.State.MENU
	Flow.instance._set_overlay_visible(false)
	paused = false
	world = World.instantiate()
	root.add_child(world); current_scene = world
	await frames(14)
	director = world.get_node("Enemies/WaveDirector")
	director.set_process(false)
	Flow.instance.state = Flow.State.PLAYING
	player = world.get_node("PlayerSpawner").spawn_player()
	player.set_meta("experiment_invincible",true)
	player.set_physics_process(false)
	director._random.seed = 251021
	director._start_wave()
	for i in 150:
		if director._alive.size() >= 6: break
		director._spawn_one()
		await physics_frame
	for actor: Node3D in get_nodes_in_group("enemies"):
		actor.ai_enabled = false
		if Runtime.identity(actor).get("profile") == "VisualChargeBeetle": beetle = actor
	await frames(5)
	Flow.instance._enter_pause()
	await frames(3)
	await click(button(Flow.instance._root,"测试台"))
	check(world.has_meta("sanctum_workspace"),"真实暂停菜单进入本轮对象")
	if not world.has_meta("sanctum_workspace"):
		_finish()
		return
	workspace = world.get_meta("sanctum_workspace")
	navigation = Nav.shared(self)
	await frames(4)
	await click(button(workspace.panel,"放置缺少的两条试点"))
	for object: Node3D in get_nodes_in_group("enemies"):
		if Runtime.identity(object).get("profile") == "PrototypeSedimentTitan": titan = object
	check(beetle != null and titan != null,"同一圣所现场有两个试点，不伪造单对象覆盖")
	if beetle == null or titan == null:
		_finish()
		return
	titan.ai_enabled = false
	peer = world.get_node("Enemies/EnemySpawner").spawn_enemy(beetle.get_meta("enemy_entry"),player.global_position+Vector3(-7,0,9),1)
	peer.ai_enabled = false
	peer.set_meta("formal_enemy",false)
	peer.set_meta("workspace_trial",true)
	workspace.refresh()
	await _effects()
	# 实际身体点击反向定位列表；相机只为该输入夹具转向，随后恢复再拍现场快照。
	var camera := root.get_camera_3d()
	var camera_pose := camera.global_transform
	camera.look_at(beetle.global_position,Vector3.UP)
	await frames(2)
	var point := camera.unproject_position(beetle.global_position)
	for down in [true,false]:
		var event := InputEventMouseButton.new()
		event.position = point; event.global_position = point
		event.button_index = MOUSE_BUTTON_LEFT; event.pressed = down
		root.push_input(event,true)
		await frames(1)
	camera.global_transform = camera_pose
	check(workspace.selected == beetle and workspace.list.is_selected(workspace.objects.find(beetle)),"身体点击与对象列表相互定位")
	await select_object(beetle)
	await _visual_chain()
	await select_object(titan)
	await _skill_chain()
	await _global_modules(false)
	await click(button(workspace.panel,"返回暂停菜单"))
	check(Flow.instance.state == Flow.State.PAUSED and paused,"关闭对象工作区仍暂停")
	await click(button(Flow.instance._root,"测试台"))
	var cancel := InputEventAction.new()
	cancel.action = "ui_cancel"; cancel.pressed = true
	root.push_input(cancel,true)
	await frames(3)
	check(not workspace.opened and Flow.instance.state == Flow.State.PAUSED and paused,"Esc关闭当前对象工作区，不穿透为继续战斗")
	await click(button(Flow.instance._root,"继续"))
	check(Flow.instance.state == Flow.State.PLAYING and not paused,"只有显式继续按钮推进同一现场")
	Flow.instance._enter_pause()
	await _saved_selection()
	_finish()

func _effects() -> void:
	timer = Timer.new(); timer.wait_time = 5.0
	world.add_child(timer); timer.start()
	projectile = preload("res://scripts/enemies/crystal_projectile.gd").new()
	world.add_child(projectile)
	projectile.configure_lob(player.global_position+Vector3(0,3,-8),player.global_position+Vector3(5,0,-8),Tuning.defaults("VisualBurstCrawler"),{})
	poison = preload("res://scripts/enemies/poison_puddle.gd").new()
	world.add_child(poison)
	poison.configure(player.global_position+Vector3(4,0,-5),Tuning.defaults("VisualBurstCrawler"),{})
	death = preload("res://scripts/enemy_death_fx.gd").new()
	world.add_child(death)
	# 独立死亡演出使用真实脚本时钟；不触发新的击杀／掉落。
	await frames(2)

func _visual_chain() -> void:
	var before := snapshot()
	var session := Session.shared()
	var draft: String = workspace.draft_id
	var active := Tuning.active_name("VisualChargeBeetle")
	await click(workspace.visual_button)
	check(navigation.frames.size() == 1 and navigation.destination.text == "圣所实战","A1直接视觉台来源标题及栈")
	var visual := current_scene
	await frames(5)
	check(get_nodes_in_group("player").is_empty(),"视觉台确实没有玩家")
	check(visual._visual_panel.draft_id == draft,"A3实例草稿传到视觉台")
	session.set_domain_value(draft,"visual","rock_r",.125)
	session.set_domain_value(draft,"visual","shell_width",3.0)
	await frames(5)
	var revision: int = session.record(draft).revision
	Bus.emit_weapon_level_changed(88)
	check(director._weapon_level != 88,"离树现场总线订阅不收预览事件")
	await _global_modules(true)
	await capture("t04_visual_beetle")
	await click(navigation.back_button)
	await frames(4)
	compare(before,"A1外形链路")
	check(workspace.draft_id == draft and session.record(draft).revision >= revision and session.dirty(draft),"A3同草稿／修订不回退／未保存")
	check(Tuning.active_name("VisualChargeBeetle") == active,"返回没有activate默认")
	check(workspace.last_application.runtime_applied and workspace.last_application.rebuild.has("shell_width"),"A4立即颜色且明确待重建")
	check(is_equal_approx(beetle.visual.rock.albedo_color.r,.125),"颜色真正作用于原实例")
	check(not is_equal_approx(peer.visual.rock.albedo_color.r,.125),"默认只应用选中实例，不隐式覆盖同方案全部")
	await click(button(workspace.panel,"同方案全部"))
	check(is_equal_approx(peer.visual.rock.albedo_color.r,.125),"显式同方案全部真正应用到第二个来源实例")
	check(not is_equal_approx(beetle._collision.shape.size.x,3.0*.87),"返回不偷偷重建碰撞")
	# 非法原文允许返回，原实例仍用最近有效值。
	await click(workspace.visual_button)
	await frames(4)
	visual = current_scene
	var field: SpinBox = visual._visual_panel._inputs.get("shell_width")
	field.get_line_edit().text = "invalid-width"
	field.get_line_edit().text_changed.emit("invalid-width")
	await frames(2)
	await click(navigation.back_button)
	await frames(3)
	check(not workspace.last_application.runtime_applied and workspace.status.text.contains("原文"),"非法原文不冒充应用成功")
	await click(workspace.visual_button)
	await frames(4)
	visual = current_scene
	check(visual._visual_panel._pending.get("shell_width","") == "invalid-width","A3非法原文往返保留")
	visual._visual_panel._pending.clear()
	visual._visual_panel.remember_view()
	await click(navigation.back_button)
	await frames(3)
	# 在空旷位置的原实例上显式重建；只检查目标，不重开世界。
	beetle.current_state = beetle.State.IDLE
	var old_pose: Transform3D = beetle.global_transform
	beetle.global_position = player.global_position+Vector3(0,3,12)
	workspace.apply_current(true)
	check(workspace.last_application.runtime_applied and workspace.last_application.rebuild.is_empty(),"A4显式目标重建成功")
	check(is_equal_approx(beetle._collision.shape.size.x,3.0*.87),"重建更新真实碰撞")
	beetle.global_transform = old_pose
	await capture("t04_sanctum_return")

func _skill_chain() -> void:
	var before := snapshot()
	var session := Session.shared()
	var draft: String = workspace.draft_id
	await click(workspace.combat_button)
	await frames(8)
	var lab := current_scene
	check(navigation.frames.size() == 1 and lab._tuning_panel.draft_id == draft,"A2圣所到原型深度1及实例草稿")
	await click(button(lab._tuning_panel,"外形 ↗"))
	await frames(5)
	check(navigation.frames.size() == 2 and navigation.destination.text == "战斗原型测试台","A2原型到视觉深度2／目的地")
	await click(navigation.back_button)
	await frames(4)
	check(current_scene == lab and navigation.frames.size() == 1 and paused,"A2回同一原型／深度1／原暂停")
	# 只用泰坦已有定格适配，不给兜虫添加第二套。
	await lab.observe_draft("PrototypeSedimentTitan",session.values(draft))
	await frames(18)
	lab._attack_observer.skill_choice.select(4)
	lab._attack_observer.skill_choice.item_selected.emit(4)
	await frames(3)
	await click(lab._attack_observer._edit_button)
	for i in 30: await physics_frame
	await frames(3)
	print("[T04定格] visible=",lab._attack_observer.shape_panel.visible," transition=",lab._shape_transition," study=",lab._attack_observer.study," profile=",lab._observation_profile," skill=",lab._attack_observer.skill_choice.selected," pending=",lab._tuning_panel._pending_text)
	check(lab._attack_observer.shape_panel.visible,"真实技能定格入口")
	session.set_value(draft,"triple_slam_width",2.4)
	session.set_value(draft,"triple_slam_windup",.7)
	session.set_value(draft,"rage_director_enabled",true)
	await frames(4)
	await _layout_matrix("skill")
	await capture("t04_titan_shape")
	# 按实际本地返回栈先回参数页，再回圣所。
	await click(navigation.back_button)
	await frames(4)
	if current_scene == lab: await click(navigation.back_button)
	await frames(5)
	check(navigation.frames.is_empty(),"A2最终深度0")
	compare(before,"A1技能定格链路")
	check(workspace.draft_id == draft and session.dirty(draft),"A3技能草稿仍在")
	check(not workspace.last_application.runtime_applied and workspace.last_application.next_action.has("triple_slam_windup"),"A4下次动作不假报已经采用")
	var old_clock: float = titan.anim_clock
	titan.current_state = titan.State.IDLE
	titan._apply_workspace_next_action()
	check(is_equal_approx(titan._tuning.triple_slam_width,2.4) and is_equal_approx(titan._tuning.triple_slam_windup,.7),"安全状态真正采用技能草稿")
	check(titan.anim_clock == old_clock,"采用不推进旧动作时钟")
	var old_packet: Dictionary = Session.shared().snapshot(draft)
	check(not Runtime.apply(old_packet,beetle).runtime_applied,"错误实例身份拒绝应用")

func _global_modules(visual: bool) -> void:
	var flow_state: int = Flow.instance.state
	var was_paused := paused
	await click(navigation.global_button)
	await frames(3)
	var globals: CanvasLayer = navigation._globals
	check(globals.opened,"A5可见公共入口直接打开")
	await click(button(globals.panel,"显示设置"))
	var settings := root.get_node("DisplaySettings")
	var old: float = settings.render_scale
	await click(button(globals.panel,"3D渲染比例"))
	check(settings.render_scale != old,"A5显示模块能真实修改一项")
	await click(navigation.back_button)
	await frames(3)
	check(paused == was_paused and Flow.instance.state == flow_state,"A5显示关闭不接管流程")
	await click(navigation.global_button)
	await click(button(globals.panel,"画面风格"))
	var sketch: CanvasLayer = root.get_node("PostProcess")._sketch_panel
	check(sketch.opened,"A5画面面板在无玩家／暂停可开")
	if sketch.opened:
		var value: float = root.get_node("PostProcess").parameters.paper_tint
		sketch._fields.paper_tint.value = value+.01
		check(root.get_node("PostProcess").parameters.paper_tint != value,"A5画面参数真正变化")
		await click(navigation.back_button)
	check(paused == was_paused and MouseControl.mode == Input.MOUSE_MODE_VISIBLE,"A5画面返回恢复暂停／鼠标")
	await click(navigation.global_button)
	await click(button(globals.panel,"灰模"))
	var grey := root.get_node("GreyboxDirector")
	check(grey._panel.opened,"A5灰模在无玩家／暂停可开")
	if grey._panel.opened:
		var value: float = grey.parameters.grid_size
		grey._panel._fields.grid_size.value = value+.1
		check(grey.parameters.grid_size != value,"A5灰模参数真正变化")
		await capture("t04_global_"+("visual" if visual else "sanctum"))
		await click(navigation.back_button)
	check(paused == was_paused and Flow.instance.state == flow_state and MouseControl.mode == Input.MOUSE_MODE_VISIBLE,"A5灰模返回仍原状态")
	# 风险反例：灰模启用期间改变个人风格，退出灰模应采用新风格。
	grey.activate()
	await click(navigation.global_button)
	await click(button(globals.panel,"显示设置"))
	await click(button(globals.panel,"画面风格"))
	var style: int = settings.post_process_style
	await click(navigation.back_button)
	grey.deactivate()
	check(root.get_node("PostProcess").style == style,"灰模→显示修改→关灰模保留最新渲染设置")
	if visual: await _layout_matrix()

func _layout_matrix(tag := "visual") -> void:
	var settings := root.get_node("DisplaySettings")
	for size: Vector2i in [Vector2i(1920,1080),Vector2i(1280,720)]:
		for scale: float in [1.0,1.3]:
			root.size = size
			root.content_scale_size = size
			settings.ui_scale = scale
			settings._apply_ui_scale()
			await frames(5)
			check(navigation.back_button.global_position == Vector2(8,8),"A6固定8像素锚点")
			check(navigation.back_button.size == Vector2(68,24),"A6保留68×24返回")
			check(root.get_visible_rect().encloses(navigation.global_button.get_global_rect()),"A6公共按钮完整可点")
			if current_scene.has_method("edit_observation_shape"):
				check(not navigation.back_button.get_global_rect().intersects(current_scene._attack_observer._panel.get_global_rect()),"A6返回条避让观察区首行")
			await capture("t04_layout_%s_%d_%d" % [tag,size.x,int(scale*100)])
			# 实际点击打开／关闭，不能只有矩形检查。
			await click(navigation.global_button)
			await click(navigation.back_button)
	root.size = Vector2i(1280,720); root.content_scale_size = Vector2i(1280,720)
	settings.ui_scale = 1.0; settings._apply_ui_scale()
	await frames(4)

func _saved_selection() -> void:
	var session := Session.shared()
	var draft: String = workspace.draft_id
	var profile: String = session.record(draft).profile
	var active := Tuning.active_name(profile)
	check(session.save_as(draft,"T04命名试验"),"显式保存命名方案")
	workspace.choose_saved()
	check(session.scene_preset(world.scene_file_path,profile) == "T04命名试验","保存与本场景明确选用分别执行")
	var fresh: Node3D = world.get_node("Enemies/EnemySpawner").spawn_boss("sediment_titan",player.global_position+Vector3(-10,0,-10))
	check(is_equal_approx(fresh._tuning.triple_slam_width,2.4),"按本场景选用重新生成读取命名值")
	check(Tuning.active_name(profile) == active,"命名／本场景选用不修改默认")
	fresh.queue_free()
	await frames(2)
	var previous_id := world.get_instance_id()
	Flow.instance._on_restart()
	await frames(15)
	world = current_scene
	check(world.get_instance_id() != previous_id,"明确重新开始才创建新圣所；与前面原现场返回分开核对")
	var new_director := world.get_node("Enemies/WaveDirector")
	new_director.set_process(false)
	player = get_first_node_in_group("player")
	fresh = world.get_node("Enemies/EnemySpawner").spawn_boss("sediment_titan",player.global_position+Vector3(-10,0,-10))
	check(is_equal_approx(fresh._tuning.triple_slam_width,2.4) and fresh.get_meta("workspace_source_preset") == "T04命名试验","完整重开后仍明确采用本场景命名方案")
	check(Tuning.active_name(profile) == active,"重开未更改项目默认")
	Flow.instance._enter_pause()

func _finish() -> void:
	var report := FileAccess.open(Artifacts.ensure_dir("reports").path_join("t04_roundtrip.json"),FileAccess.WRITE)
	report.store_string(JSON.stringify({"checks":checks,"failures":failures,"snapshots":evidence},"\t")); report.close()
	if is_instance_valid(world) and world.has_meta("workspace_suspended"): world.remove_meta("workspace_suspended")
	paused = false
	current_scene = null
	if is_instance_valid(world): world.queue_free()
	print("[T04] checks=",checks," failures=",failures.size())
	quit(0 if failures.is_empty() else 1)
