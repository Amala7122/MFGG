extends SceneTree
## T02：唯一归属、域级历史、真实跨台返回和战斗样本几何；不改正式参数。
const Tuning := preload("res://scripts/prototypes/enemy_tuning.gd")
const Session := preload("res://scripts/testing/tuning_session.gd")
const Ownership := preload("res://scripts/testing/enemy_parameter_ownership.gd")
const Artifacts := preload("res://scripts/artifact_paths.gd")
const Lab := preload("res://prototypes/combat_lab/combat_lab.tscn")
const Profile := "VisualChargeBeetle"
var failures: Array[String] = []
var checks := 0

func _initialize() -> void: _run.call_deferred()
func frames(count: int) -> void:
	for i in count: await process_frame
func check(ok: bool, message: String) -> void:
	checks += 1
	if not ok: failures.append(message); push_error(message)
func capture(name: String) -> void:
	if DisplayServer.get_name() == "headless": return
	await RenderingServer.frame_post_draw
	check(root.get_texture().get_image().save_png(Artifacts.ensure_dir("screenshots").path_join(name+".png")) == OK, "实际工作区截图可写")

func button_named(node: Node, text: String) -> Button:
	for child in node.get_children():
		if child is Button and child.text == text: return child
		var found := button_named(child,text)
		if found: return found
	return null

func click(button: Button) -> void:
	check(button != null and button.is_visible_in_tree() and not button.disabled,"入口实际可点击")
	if button == null: return
	check(root.get_visible_rect().encloses(button.get_global_rect()),"入口位于视口内")
	var point := button.get_global_rect().get_center()
	for down in [true,false]:
		var event := InputEventMouseButton.new()
		event.position = point
		event.global_position = point
		event.button_index = MOUSE_BUTTON_LEFT
		event.button_mask = MOUSE_BUTTON_MASK_LEFT if down else 0
		event.pressed = down
		root.push_input(event,true)
		await frames(1)

func _run() -> void:
	root.size = Vector2i(1280,720)
	root.content_scale_size = Vector2i(1280,720)
	await frames(4)
	var original := Tuning.storage_directory
	Tuning.storage_directory = Artifacts.ensure_dir("tmp", "t02_presets")
	for profile: String in Tuning.PROFILE_PATHS:
		var path := original.path_join(profile+".json")
		if FileAccess.file_exists(path):
			var out := FileAccess.open(Tuning.storage_directory.path_join(profile+".json"),FileAccess.WRITE)
			out.store_buffer(FileAccess.get_file_as_bytes(path)); out.close()
	Tuning.reload_saved()
	_ownership()
	_history()
	await _navigation_initialization()
	await _navigation()
	await _invalid_navigation()
	await _recovery_controls()
	await _spatial_route()
	Tuning.storage_directory = original
	Tuning.reload_saved()
	var report := FileAccess.open(Artifacts.ensure_dir("reports").path_join("t02_workspace.json"),FileAccess.WRITE)
	report.store_string(JSON.stringify({"checks":checks,"failures":failures},"\t")); report.close()
	print("[T02] checks=",checks," failures=",failures.size())
	quit(0 if failures.is_empty() else 1)

func _navigation_initialization() -> void:
	var type := preload("res://scripts/testing/professional_navigation.gd")
	var pending: CanvasLayer = type.shared(self)
	check(pending == type.shared(self),"挂载前重复请求复用唯一导航实例")
	check(not pending.is_inside_tree() and pending.destination != null,"挂载前控件已经构建，不能等ready后才可设置")
	pending.set_local(func(): pass, "启动时返回上下文")
	await frames(2)
	check(pending.is_node_ready() and pending.destination.text == "启动时返回上下文" and not pending.back_button.disabled,"延迟挂载保留提前设置的返回策略")
	pending.set_local()

func _ownership() -> void:
	for profile: String in Tuning.PROFILE_PATHS:
		var seen := {}
		for domain: String in Ownership.FIELDS[profile]:
			for field: String in Ownership.FIELDS[profile][domain]:
				check(not seen.has(field) and Tuning.defaults(profile).has(field), profile+" 唯一已存在字段 "+field)
				seen[field] = domain
		check(seen.size() == Tuning.defaults(profile).size(),profile+" 全量归属覆盖")
	check(Ownership.owner("VisualBurstCrawler","turn_yaw") == "combat_prototype" and Ownership.owner("VisualBurstCrawler","release_snap_ratio") == "combat_prototype","真实投囊方向／触发时机不能误归视觉")
	check(Ownership.owner(Profile,"dash_distance") == "visual" and Ownership.owner(Profile,"charge_distance") == "combat_prototype","展示位移与真实冲锋距离分离")
	check(Ownership.owner("PrototypeHornet","wing_frequency") == "visual", "蜂翼姿态归视觉")

func _history() -> void:
	var session := Session.new()
	var id := session.open_profile(Profile)
	var base := session.values(id)
	check(not session.set_domain_value(id,"visual","charge_speed",50.0),"视觉模块拒绝跨域写入")
	check(session.set_domain_value(id,"combat_prototype","charge_speed",50.0),"战斗域修改真实速度")
	session.set_domain_value(id,"visual","shell_width",3.0)
	check(not session.domain_history(id,"combat_prototype") and session.values(id).shell_width == 3.0,"战斗撤销不能回滚最新外形操作")
	session.restore_domain(id,"visual")
	check(session.values(id).shell_width == base.shell_width and session.values(id).charge_speed == 50.0,"还原外形保留战斗修改")
	check(session.domain_history(id,"visual") and session.values(id).shell_width == 3.0,"模块还原在同一历史链可撤销")
	check(session.domain_history(id,"visual",true) and session.values(id).shell_width == base.shell_width,"模块还原可重做")
	session.restore_domain(id,"combat_prototype",true)
	check(session.values(id).charge_speed == base.charge_speed,"战斗基础值只还原战斗字段")

func _navigation() -> void:
	var lab := Lab.instantiate()
	root.add_child(lab); current_scene = lab
	await frames(8)
	var nav: CanvasLayer = lab._professional_navigation
	check(nav.back_button.disabled and nav.back_button.get_global_position() == Vector2(8,8),"独立启动左上角返回禁用并有来源说明")
	lab._show_enemy_tuning(Profile)
	var panel: Control = lab._tuning_panel
	check(panel._readonly.has("body_size") and not panel._fields.has("body_size"),"原型页外形只读且有入口")
	panel._changed(50.0,"charge_speed")
	panel._search.text = "charge"
	panel._filter_fields("charge")
	panel._tabs.current_tab = 2
	var id: String = panel.draft_id
	var player_id: int = lab._player.get_instance_id()
	await frames(4)
	await click(button_named(panel,"外形 ↗"))
	await frames(12)
	var gallery: Node3D = current_scene
	check(gallery != lab and not lab.is_inside_tree(),"跨台时调用方离树，只有当前真实物理世界活动")
	check(gallery._gallery_index == 10 and gallery._subject.scene_file_path.ends_with("procedural_charge_beetle.tscn"),"路由定位兜虫真实战斗宿主")
	var visual: Control = gallery._visual_panel
	check(visual.draft_id == id and not visual._inputs.has("charge_speed") and visual._readonly.has("charge_speed"),"同一草稿，视觉只写外形，技能只读")
	gallery._motion_enabled = false
	gallery._apply_motion_state()
	var transform: Transform3D = gallery._camera.global_transform
	var time: float = gallery._subject.anim_clock
	visual._field_changed(2.0,"body_size")
	visual._field_changed(3.0,"shell_width")
	visual._field_changed(4.0,"shell_length")
	visual._field_changed(2.0,"shell_height")
	await frames(8)
	var actor: CharacterBody3D = gallery._subject
	var dimensions := Vector3(3.0*0.87,1.08+2.0*0.5,4.0*0.95)
	check(actor.scale.is_equal_approx(Vector3.ONE*2.0),"战斗体型只应用一次")
	check(actor._collision.shape.size.is_equal_approx(dimensions),"新碰撞盒真实采用甲壳尺寸")
	check(is_equal_approx(actor.visual.position.y,-dimensions.y*0.5) and is_equal_approx(actor.position.y,dimensions.y),"脚底与碰撞盒底部一致")
	var agent: NavigationAgent3D = actor.get_node("NavOrigin/NavAgent")
	check(is_equal_approx(agent.height,dimensions.y*2.0) and is_equal_approx(agent.radius,maxf(dimensions.x,dimensions.z)),"重建导航代理跟随尺寸和体型")
	check(actor.visual.get("rig").scale.is_equal_approx(Vector3.ONE),"局部模型未重复乘基础体型")
	var shell := actor.visual.find_child("HeavyShell",true,false) as MeshInstance3D
	check(shell.scale.is_equal_approx(Vector3(3.0*0.53,2.0,4.0)),"真实外形网格尺寸采用同一甲壳草稿")
	visual._field_changed(0.42,"rock_r")
	await frames(4)
	check(gallery._subject.scale.is_equal_approx(Vector3.ONE*2.0),"只改材质的第二次重建不累乘旧体型")
	for size: float in [1.5,2.0]:
		visual._field_changed(size,"body_size")
		await frames(4)
		check(gallery._subject.scale.is_equal_approx(Vector3.ONE*size),"连续重建每次只应用本次体型 "+str(size))
	actor = gallery._subject
	check(visual._replay_button.disabled and visual.poses.disabled,"play战斗体不提供无效动作采样／重播按钮")
	check(gallery._camera.global_transform.is_equal_approx(transform) and is_equal_approx(actor.anim_clock,time),"重建保留相机与冻结观察时钟")
	check(nav.back_button.size.y <= 24.0 and visual.status.get_line_count() <= 2,"返回与正常状态说明保持紧凑，不挤占参数区")
	check(actor._tuning.charge_speed == 100.0 and visual.status.text.contains("重建"),"重建沿用完整战斗草稿并明确应用状态")
	visual._search.text = "shell_width"
	visual._filter_fields("shell_width")
	await frames(5)
	await capture("01_beetle_visual_workspace")
	visual._inputs.shell_width.get_line_edit().text = "bad appearance"
	visual._inputs.shell_width.get_line_edit().text_changed.emit("bad appearance")
	check(not visual._commit_inputs(),"非法外形原文有具体错误")
	await click(button_named(visual,"技能 ↗"))
	await frames(12)
	var nested: Node3D = current_scene
	check(nested != gallery and nav.frames.size() == 2 and not gallery.is_inside_tree(),"嵌套进入专业原型页，来源视觉页也离树保留")
	nested._tuning_panel._changed(300.0,"charge_speed")
	check(not nested._tuning_panel._session.save_as(id,"T02 must not ignore input") and nested._tuning_panel._session.error.contains("视觉"),"其他模块的非法原文不能被整份保存忽略")
	await click(nav.back_button)
	await frames(10)
	check(current_scene == gallery and visual._pending.get("shell_width") == "bad appearance", "返回同一个视觉页，非法原文保留")
	check(visual.values.charge_speed == 300.0 and visual.values.shell_width == 3.0,"返回同时保留两域修改，不用旧运行值覆盖")
	check(gallery._camera.global_transform.is_equal_approx(transform),"跨台返回观察相机保留")
	check(gallery._subject.scale.is_equal_approx(Vector3.ONE*2.0),"跨台返回的再次重建不累乘体型")
	visual._discard_pending()
	visual.preset_name.text = "T02 complete candidate"
	visual._save()
	Tuning.reload_saved()
	check(Tuning.preset_values(Profile,"T02 complete candidate").charge_speed == 300.0 and Tuning.preset_values(Profile,"T02 complete candidate").shell_width == 3.0,"保存完整候选，重读两域一致")
	await click(nav.back_button)
	await frames(10)
	check(current_scene == lab and lab._player.get_instance_id() == player_id,"逐级返回原调用方与原玩家实例")
	check(panel._draft.charge_speed == 300.0 and panel._draft.body_size == 2.0 and paused,"原型返回同一草稿，保持暂停")
	check(panel._search.text == "charge" and panel._tabs.current_tab == 2,"原分页与搜索保留")
	check(nav.frames.is_empty() and nav.back_button.get_global_position() == Vector2(8,8),"嵌套栈清空，返回位置固定")
	await capture("02_combat_returned_workspace")
	await click(nav.back_button)
	await frames(3)

	check(lab._panel.visible and not panel.visible,"最后一级返回敌人配置")
	paused = false
	current_scene = null
	lab.queue_free()
	await frames(3)

func _invalid_navigation() -> void:
	var session := Session.shared()
	var profile := "VisualPrismSpider"
	var id: String = session.open_profile(profile)
	var valid: Dictionary = session.preview_values(id)
	session.set_domain_value(id,"combat_prototype","retreat_range",float(valid.retreat_exit_range)+1.0)
	check(not session.validation(id).is_empty(),"合法标量组合出非法关系的草稿仍可保留")
	var scene := preload("res://prototypes/visual_lab/enemy_visual_lab.tscn").instantiate()
	scene.set_meta("workspace_profile",profile)
	scene.set_meta("workspace_form","visual")
	root.add_child(scene); current_scene = scene
	await frames(8)
	check(Tuning.validate(profile,scene._subject.values).is_empty(),"跨台创建样本只采用最近合法草稿，不向真实宿主注入非法关系")
	check(scene._visual_panel.values.retreat_range != valid.retreat_range and scene._visual_panel.status.text.contains("retreat_range"),"非法草稿及字段原因仍显示，没有用合法样本反写草稿")
	await click(button_named(scene._visual_panel,"技能 ↗"))
	await frames(10)
	var lab: Node3D = current_scene
	check(lab._tuning_panel.enemy_id == profile and lab._tuning_panel._message.text.contains("retreat_range"),"有字段关系错误仍可通过专业入口定位修改")
	await click(lab._professional_navigation.back_button)
	await frames(8)
	check(current_scene == scene and not session.validation(id).is_empty(),"非法关系也可统一返回且保留原草稿")
	session.restore_domain(id,"combat_prototype",true)
	await frames(3)
	paused = false
	current_scene = null
	scene.queue_free()
	await frames(3)

func _recovery_controls() -> void:
	var panel := preload("res://prototypes/combat_lab/enemy_tuning_panel.gd").new()
	root.add_child(panel)
	panel.open_enemy(Profile)
	panel._restore_defaults()
	var body_size: float = panel._draft.body_size
	var spin: SpinBox = panel._fields.charge_speed
	spin.get_line_edit().text = "1001"
	spin.get_line_edit().text_changed.emit("1001")
	check(not panel._commit_inputs(),"基础值上方的非法原文仍被明确拒绝")
	panel._restore_defaults() # 值本来就等于基础值，没有会话changed信号。
	await frames(3)
	check(panel._pending_text.is_empty() and is_equal_approx(spin.get_line_edit().text.to_float(),float(Tuning.defaults(Profile).charge_speed)),"无数值变化的恢复动作也清除错误原文并刷新控件")
	check(panel._draft.body_size == body_size,"载入战斗基础值保留外形体型")
	panel.queue_free()
	await frames(3)

func _spatial_route() -> void:
	var scene := preload("res://prototypes/spatial_lab/combat_spatial_lab.tscn").instantiate()
	root.add_child(scene); current_scene = scene
	await frames(8)
	scene._show_enemy_tuning(Profile)
	var player_id: int = scene._player.get_instance_id()
	var nav: CanvasLayer = scene._professional_navigation
	await frames(4)
	await click(button_named(scene._tuning_panel,"外形 ↗"))
	await frames(10)
	check(current_scene != scene and nav.destination.text == "战斗空间测试台", "继承参数页的空间台使用真实调用方名称")
	await click(nav.back_button)
	await frames(8)
	check(current_scene == scene and scene._player.get_instance_id() == player_id and scene._tuning_panel.visible,"空间台继承入口也返回原页面与原实例")
	check(MouseControl.mode == Input.MOUSE_MODE_VISIBLE and paused,"空间台返回保持暂停与自由鼠标")
	current_scene = null
	paused = false
	scene.queue_free()
	await frames(3)
