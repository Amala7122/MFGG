extends SceneTree
## 真实面板的宽范围、原生数字提交、错误持续显示和退出恢复；不操作系统鼠标。
const Tuning := preload("res://scripts/prototypes/enemy_tuning.gd")
const Layout := preload("res://scripts/testing/enemy_parameter_layout.gd")
const Catalog := preload("res://scripts/testing/tuning_catalog.gd")
const Lab := preload("res://prototypes/combat_lab/combat_lab.tscn")
const Gallery := preload("res://prototypes/visual_lab/enemy_visual_lab.tscn")
const Artifacts := preload("res://scripts/artifact_paths.gd")
var failures: Array[String] = []
var checks := 0
var ranges: Array[Dictionary] = []
var runs: Array[Dictionary] = []
var lab: Node3D

func _initialize() -> void: _run.call_deferred()
func check(ok: bool, message: String) -> void:
	checks += 1
	if not ok: failures.append(message); push_error(message)
func frames(count: int) -> void:
	for i in count: await process_frame
func button_named(node: Node, caption: String) -> Button:
	for child: Node in node.get_children():
		if child is Button and child.text == caption: return child
		var result := button_named(child,caption)
		if result: return result
	return null
func click(node: Control) -> void:
	check(node != null and node.is_visible_in_tree(), "操作入口实际可见")
	if node == null: return
	check(root.get_visible_rect().encloses(node.get_global_rect()), "操作入口位于视口内："+node.name)
	var point := node.get_global_rect().get_center()
	var motion := InputEventMouseMotion.new()
	motion.position = point
	motion.global_position = point
	root.push_input(motion,true)
	for down: bool in [true,false]:
		var event := InputEventMouseButton.new()
		event.position = point
		event.global_position = point
		event.button_index = MOUSE_BUTTON_LEFT
		event.pressed = down
		event.button_mask = MOUSE_BUTTON_MASK_LEFT if down else 0
		root.push_input(event,true)
		await frames(1)
func enter(control: SpinBox, raw: String) -> void:
	control.get_line_edit().text = raw
	control.get_line_edit().text_changed.emit(raw)
	control.apply() # 覆盖Godot原生钳制、value_changed和文字刷新，不能只直接写会话。
	await frames(3)
func capture(name: String) -> void:
	if DisplayServer.get_name() == "headless": return
	await RenderingServer.frame_post_draw
	check(root.get_texture().get_image().save_png(Artifacts.ensure_dir("screenshots").path_join(name+".png")) == OK,"截图可写："+name)

func _catalog() -> void:
	for id: String in Tuning.PROFILE_PATHS:
		var schema := Tuning.get_schema(id)
		check(Tuning.validate(id,Tuning.defaults(id)).is_empty(),id+" 基础值合法")
		for group: Dictionary in schema.groups:
			for spec: Dictionary in group.fields:
				if spec.value is bool: continue
				var meta := Layout.field(id,spec,String(group.title))
				ranges.append({"profile":id,"key":spec.key,"unit":meta.unit,"min":meta.min,"max":meta.max,"recommended_min":meta.recommended_min,"recommended_max":meta.recommended_max,"reason":meta.limit_reason,"integer":spec.get("integer",false)})
				check(not String(spec.limit_reason).is_empty(), id+" 每个数字边界有原因："+String(spec.key))
				check(spec.min <= spec.recommended_min and spec.max >= spec.recommended_max,id+" 不缩窄已有边界："+String(spec.key))
				if meta.unit == "米/秒": check(meta.min <= 0.0 and meta.max >= 1000.0,id+" 速度充分开放："+String(spec.key))
	var values := Tuning.defaults("PrototypeHornet")
	values.needle_count = 1.5
	check(Tuning.validation_issues("PrototypeHornet",values)[0].code == "integer","晶针数量拒绝小数并说明整数要求")
	values.needle_count = 4
	check(Tuning.validation_issues("PrototypeHornet",values)[0].code == "range","固定三插槽数量保留真实上限")
	values = Tuning.defaults("VisualChargeBeetle")
	values.charge_speed = INF
	check(not Tuning.validate("VisualChargeBeetle",values).is_empty(),"存储层拒绝非有限值")
	values.charge_speed = 50.0
	values.armor = 1.1
	check(not Tuning.validate("VisualChargeBeetle",values).is_empty(),"减伤比例保留数学范围")

func _run() -> void:
	root.size = Vector2i(1280,720)
	root.content_scale_size = Vector2i(1280,720)
	await frames(4)
	var previous := Tuning.storage_directory
	Tuning.storage_directory = Artifacts.ensure_dir("tmp","wide_input_presets")
	for id: String in Tuning.PROFILE_PATHS:
		var source := previous.path_join(id+".json")
		if FileAccess.file_exists(source):
			var copy := FileAccess.open(Tuning.storage_directory.path_join(id+".json"),FileAccess.WRITE)
			copy.store_buffer(FileAccess.get_file_as_bytes(source))
			copy.close()
	Tuning.reload_saved()
	_catalog()
	lab = Lab.instantiate()
	root.add_child(lab)
	current_scene = lab
	await frames(8)
	await _wide_speeds()
	await _errors_and_return()
	await _relations_and_counts()
	await _save_failure()
	await _visual_errors()
	paused = false
	Tuning.storage_directory = previous
	Tuning.reload_saved()
	current_scene = null
	lab.queue_free()
	await frames(3)
	var file := FileAccess.open(Artifacts.ensure_dir("reports").path_join("enemy_parameter_input.json"),FileAccess.WRITE)
	check(file != null,"回归报告可写")
	if file:
		file.store_string(JSON.stringify({"checks":checks,"failures":failures,"ranges":ranges,"real_charge_runs":runs},"\t"))
		file.close()
	print("[参数输入] checks=",checks," failures=",failures.size())
	quit(0 if failures.is_empty() else 1)

func _wide_speeds() -> void:
	var profile := "VisualChargeBeetle"
	var active := Tuning.active_name(profile)
	var original := Tuning.preset_values(profile,active)
	for speed: float in [50.0,300.0,500.0]:
		lab._show_enemy_tuning(profile)
		var panel: Control = lab._tuning_panel
		panel._restore_defaults()
		for key: String in {"body_size":1.0,"variation_enabled":false,"crowd_enabled":false,"charge_distance":30.0,"windup":0.06,"aim_lock_time":0.01}:
			panel._session.set_value(panel.draft_id,key,{"body_size":1.0,"variation_enabled":false,"crowd_enabled":false,"charge_distance":30.0,"windup":0.06,"aim_lock_time":0.01}[key])
		panel._tabs.current_tab = 2
		await frames(4)
		await enter(panel._fields.charge_speed,str(speed))
		check(panel._session.values(panel.draft_id).charge_speed == speed,"原生输入%s不被旧30上限钳制"%speed)
		check(panel._pending_text.is_empty() and not panel._message.text.contains("无法"),"合法高速值可提交")
		if speed == 500.0:
			panel._name_edit.text = "input_500_candidate"
			await click(button_named(panel,"保存候选"))
			Tuning.reload_saved()
			check(Tuning.preset_values(profile,"input_500_candidate").charge_speed == speed,"高速候选写入后真实重读一致")
			check(Tuning.active_name(profile) == active and Tuning.preset_values(profile,active) == original,"保存高速候选不改当前默认及原方案")
			await capture("01_charge_500_input")
		await click(button_named(panel,"观察本草稿"))
		# 从起手前采样；高速冲锋只需几帧，固定等15帧会错过整招。
		check(lab._attack_observer.study and not lab._tuning_open,"合法高速值通过实际按钮进入观察")
		if lab._live_enemies.is_empty(): check(false,"真实兜虫已创建"); return
		var actor: CharacterBody3D = lab._live_enemies[0]
		check(actor._tuning.charge_speed == speed,"真实实例采用高速草稿")
		var top_speed := Vector2(actor.velocity.x,actor.velocity.z).length()
		var top_step := 0.0
		for i in 50:
			var before := actor.global_position
			await physics_frame
			await process_frame
			top_speed = maxf(top_speed,Vector2(actor.velocity.x,actor.velocity.z).length())
			top_step = maxf(top_step,actor.global_position.distance_to(before))
			if speed == 500.0 and top_step > 4.0:
				paused = true
				await capture("02_charge_500_real_motion")
				paused = false
				break
		check(is_equal_approx(top_speed,speed),"实际冲锋速度达到%s，无隐藏30钳制"%speed)
		check(top_step > speed / float(Engine.physics_ticks_per_second) * 0.75,"实际单帧位移随%s速度增大"%speed)
		runs.append({"input":speed,"instance_speed":actor._tuning.charge_speed,"measured_peak_speed":top_speed,"max_frame_distance":top_step,"charges":actor.charges})

func _errors_and_return() -> void:
	lab._show_enemy_tuning("VisualChargeBeetle")
	var panel: Control = lab._tuning_panel
	await frames(4)
	var old: float = panel._session.values(panel.draft_id).charge_speed
	await enter(panel._fields.charge_speed,"1001")
	check(panel._pending_text.get("charge_speed") == "1001" and panel._session.values(panel.draft_id).charge_speed == old,"超实验边界保留原文，绝不静默保存钳制值")
	panel._session.set_value(panel.draft_id,"max_health",777.0)
	await frames(5)
	check(panel._message.text.contains("1001") and panel._message.text.contains("1000") and panel._message.text.contains("charge_speed"),"草稿刷新后错误对象／字段／输入／范围仍可见")
	check(panel._fields.charge_speed.get_line_edit().has_theme_color_override("font_color"),"错误字段显式标色")
	panel._search.text = "body_size"
	panel._filter_fields("body_size")
	panel._tabs.current_tab = 0
	await click(button_named(panel,"观察本草稿"))
	await frames(4)
	check(panel.visible and panel._tabs.current_tab == 2 and panel._search.text.is_empty(),"预览失败定位到正确分页并解除搜索遮挡")
	check(panel._fields.charge_speed.get_line_edit().text == "1001","错误定位／聚焦后显示原输入，不能改成边界1000")
	check(panel._message.text.contains("无法观察本草稿") and panel._message.text.contains("实验"),"被阻止的动作和约束原因明确")
	await capture("03_range_error_located")
	panel._name_edit.text = "invalid_must_not_save"
	await click(button_named(panel,"保存候选"))
	check(not Tuning.preset_names("VisualChargeBeetle").has("invalid_must_not_save"),"非法输入不能保存旧值冒充成功")
	await click(lab._professional_navigation.back_button)
	check(not panel.visible and lab._panel.visible,"有非法输入仍可实际点击返回")
	lab._show_enemy_tuning("PrototypeHornet")
	await frames(3)
	check(panel.enemy_id == "PrototypeHornet","返回后能进入其他对象，不被旧错误困住")
	await click(lab._professional_navigation.back_button)
	lab._show_enemy_tuning("VisualChargeBeetle")
	await frames(4)
	check(panel._pending_text.get("charge_speed") == "1001" and panel._fields.charge_speed.get_line_edit().text == "1001","重新进入原对象完整恢复未提交文字")
	await click(button_named(panel,"撤回输入"))
	check(panel._pending_text.is_empty() and panel._session.values(panel.draft_id).charge_speed == old,"撤回输入恢复草稿值，保留已提交修改")
	await enter(panel._fields.charge_speed,"bad input")
	check(panel._message.text.contains("完整数值"),"非法文字有具体解析错误")
	check(panel._fields.charge_speed.get_line_edit().text == "bad input","原生格式化不得吞掉非法文字")
	await enter(panel._fields.charge_speed,"-1")
	check(panel._pending_text.get("charge_speed") == "-1" and panel._fields.charge_speed.get_line_edit().text == "-1","低于数学下限也保留文字与原因")
	await enter(panel._fields.charge_speed,"300")
	check(panel._pending_text.is_empty() and panel._session.values(panel.draft_id).charge_speed == 300.0,"修正原文即可恢复提交")
	check(not panel._fields.charge_speed.get_line_edit().has_theme_color_override("font_color"),"修复后移除错误标色")
	await click(lab._professional_navigation.back_button)

func _relations_and_counts() -> void:
	lab._show_enemy_tuning("VisualPrismSpider")
	var panel: Control = lab._tuning_panel
	panel._restore_defaults()
	await frames(4)
	var exit_range: float = panel._session.values(panel.draft_id).retreat_exit_range
	await enter(panel._fields.retreat_range,str(exit_range+1.0))
	await click(button_named(panel,"观察本草稿"))
	await frames(3)
	check(panel.visible and panel._message.text.contains("retreat_range") and panel._message.text.contains("retreat_exit_range") and panel._message.text.contains("小于"),"组合错误明确指出两个字段及大小关系")
	await capture("04_relation_error")
	await enter(panel._fields.retreat_range,str(exit_range-0.1))
	check(panel._commit_inputs(),"组合关系修正可恢复")
	await click(lab._professional_navigation.back_button)
	lab._show_enemy_tuning("PrototypeHornet")
	panel._restore_defaults()
	await frames(3)
	await enter(panel._fields.needle_count,"1.5")
	check(panel._pending_text.get("needle_count") == "1.5" and panel._message.text.contains("整数"),"原生数量提交不吞掉小数错误")
	await click(button_named(panel,"撤回输入"))
	await click(lab._professional_navigation.back_button)
	# 底层观察入口也必须报告失败，不能只有面板挡住非法值。
	var invalid := Tuning.defaults("VisualChargeBeetle")
	invalid.charge_speed = 1001.0
	await lab.observe_draft("VisualChargeBeetle",invalid)
	check(panel._message.text.contains("无法观察") and panel._message.text.contains("charge_speed"),"宿主拒绝非法快照也给出原因")

func _visual_errors() -> void:
	lab._interface.visible = false
	lab.hide()
	lab.process_mode = Node.PROCESS_MODE_DISABLED
	paused = false
	var gallery := Gallery.instantiate()
	root.add_child(gallery)
	current_scene = gallery
	await frames(6)
	gallery._show_subject(preload("res://scripts/prototypes/enemy_visual_lab.gd").gallery_index_for("VisualChargeBeetle","visual"))
	await frames(4)
	var panel: Control = gallery._visual_panel
	check(panel.visible and panel.profile == "VisualChargeBeetle","真实视觉台打开可编辑纯外形")
	await enter(panel._inputs.rock_r,"1.1")
	panel._session.set_value(panel.draft_id,"max_health",778.0)
	await frames(3)
	check(panel.status.text.contains("1.1") and panel.status.text.contains("rock_r"),"视觉面板错误不会被共享草稿同步清空")
	check(panel.status.text.contains("撤回输入") and panel.status.text.contains("返回会"),"恢复提示只列该面板实际提供的动作")
	check(not panel._commit_inputs(),"视觉面板非法输入不能保存或切方案")
	await frames(4)
	await capture("05_visual_error")
	await click(button_named(panel,"撤回输入"))
	check(panel._pending.is_empty(),"视觉面板实际按钮能撤回错误输入")
	await enter(panel._inputs.rock_r,"0.5")
	check(panel._pending.is_empty() and panel.values.rock_r == 0.5,"视觉面板共用宽范围与恢复行为")
	current_scene = lab
	gallery.queue_free()
	lab.process_mode = Node.PROCESS_MODE_INHERIT
	await frames(3)

func _save_failure() -> void:
	lab._show_enemy_tuning("VisualChargeBeetle")
	var panel: Control = lab._tuning_panel
	var old_store := Tuning.storage_directory
	var blocked := Artifacts.ensure_dir("tmp").path_join("blocked_directory")
	var file := FileAccess.open(blocked,FileAccess.WRITE)
	file.store_string("file, not directory")
	file.close()
	Tuning.storage_directory = blocked
	Tuning.reload_saved()
	panel._name_edit.text = "cannot_write_candidate"
	var before: Dictionary = panel._session.values(panel.draft_id)
	await frames(3)
	await click(button_named(panel,"保存候选"))
	await frames(3)
	check(panel._message.text.contains("无法保存候选") and panel._message.text.contains("目录") and (panel._message.text.contains("可写") or panel._message.text.contains("权限")),"真实保存失败显示操作、原因、恢复建议："+panel._message.text)
	runs.append({"save_failure_message":panel._message.text})
	check(panel._session.values(panel.draft_id) == before and panel._notice_error,"保存失败保留草稿并持续显著显示")
	await capture("06_save_failure")
	await click(lab._professional_navigation.back_button)
	check(lab._panel.visible,"磁盘保存失败仍可正常返回")
	Tuning.storage_directory = old_store
	Tuning.reload_saved()
