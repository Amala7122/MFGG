extends SceneTree
## 真实GUI输入→定格预览→真实三道命中→同草稿真人试打；不只检查控件存在。
const Lab := preload("res://prototypes/combat_lab/combat_lab.tscn")
const Tuning := preload("res://scripts/prototypes/enemy_tuning.gd")
const Catalog := preload("res://scripts/testing/tuning_catalog.gd")
const Definition := preload("res://scripts/prototypes/titan_triple_slam_definition.gd")
const Artifacts := preload("res://scripts/artifact_paths.gd")
const PROFILE := "PrototypeSedimentTitan"
var checks := 0
var failures: Array[String] = []
var measurements: Array[Dictionary] = []
var hits: Array[Dictionary] = []
var lab: Node3D

func _initialize() -> void: _run.call_deferred()
func check(ok: bool, message: String) -> void:
	checks += 1
	if not ok: failures.append(message); push_error(message)
func frames(count: int) -> void:
	for i in count: await physics_frame
func ui_frames(count: int) -> void:
	for i in count: await process_frame
func click(control: Control) -> void:
	click_point(control.get_global_rect().get_center())
func click_point(point: Vector2) -> void:
	var motion := InputEventMouseMotion.new()
	motion.position = point; motion.global_position = point
	root.push_input(motion,true)
	for down: bool in [true,false]:
		var event := InputEventMouseButton.new()
		event.position = point; event.global_position = point
		event.button_index = MOUSE_BUTTON_LEFT; event.pressed = down
		event.button_mask = MOUSE_BUTTON_MASK_LEFT if down else 0
		root.push_input(event,true)
func type_number(control: SpinBox, text: String) -> void:
	click(control.get_line_edit())
	await ui_frames(2)
	# 后台无焦点窗口不依赖系统键盘；走LineEdit原生逐字插入与SpinBox提交，按钮仍用GUI点击。
	var edit := control.get_line_edit()
	edit.text = ""
	edit.caret_column = 0
	edit.text_changed.emit("")
	for character in text:
		edit.insert_text_at_caret(character)
		edit.text_changed.emit(edit.text)
		await process_frame
	await ui_frames(2)
	print("[输入] requested=",text," actual=",control.get_line_edit().text," focused=",control.get_line_edit().has_focus()," rect=",control.get_global_rect())
func capture(name: String) -> void:
	if DisplayServer.get_name() == "headless": return
	await RenderingServer.frame_post_draw
	check(root.get_texture().get_image().save_png(Artifacts.ensure_dir("screenshots").path_join(name+".png")) == OK,"定格工作区截图保存 "+name)

func _run() -> void:
	await frames(4)
	Tuning.storage_directory = Artifacts.ensure_dir("tmp","t03_presets")
	lab = Lab.instantiate()
	root.add_child(lab); current_scene = lab
	await frames(8)
	lab._show_enemy_tuning(PROFILE)
	var source: PanelContainer = lab._tuning_panel
	var session: RefCounted = source._session
	var draft: String = source.draft_id
	var original_default := Tuning.active_name(PROFILE)
	var formal := Catalog.formal_preset(PROFILE)
	session.set_domain_value(draft,"visual","body_size",1.0)
	session.set_domain_value(draft,"combat_prototype","variation_enabled",false)
	session.set_domain_value(draft,"combat_prototype","crowd_enabled",false)
	await lab.observe_draft(PROFILE,session.values(draft))
	var observer: Node3D = lab._attack_observer
	observer.skill_choice.select(4)
	observer.skill_choice.item_selected.emit(4)
	await frames(2)
	check(not observer._edit_button.disabled,"三线重击有明确可用的定格编辑入口")
	click(observer._edit_button)
	await frames(22)
	var editor: PanelContainer = observer.shape_panel
	check(editor.visible and paused,"真实按钮进入站桩定格并暂停世界")
	check(editor.source == source and editor._draft == draft,"紧凑视图复用完整参数控制器与同一草稿")
	check(not editor.commit() and editor.status.text.contains("启用"),"项目默认未启用三线时明确阻止无效果的播放")
	click(editor.enable_toggle)
	await frames(2)
	check(session.values(draft).rage_director_enabled,"实际开关显式启用狂暴编排，不偷偷修改方案")
	var actor: Node3D = observer.actor
	var origin: Vector3 = actor.global_position
	var clock: float = actor.anim_clock
	check(actor.current_state == actor.State.IDLE and not actor.ai_enabled,"站桩宿主不运行选招AI")
	await type_number(editor.fields.triple_slam_width,"2.4")
	check(editor.fields.triple_slam_width.get_line_edit().text == "2.4","真实GUI可连续输入小数，输入不被刷新吞掉")
	check(is_equal_approx(float(editor.sample().snapshot.width),2.4),"合法原文不必离开输入框即可更新几何")
	check(not source._pending_text.is_empty(),"即时预览不把尚在输入的文字冒充已提交")
	for pair: Array in [["triple_slam_length","16"],["triple_slam_spread","45"],["triple_slam_windup","0.6"],["triple_slam_recovery","0.4"],["triple_slam_damage","37"],["triple_slam_cooldown","3"]]:
		await type_number(editor.fields[pair[0]],pair[1])
	editor.fields.triple_slam_cooldown.apply()
	editor.commit()
	await frames(3)
	editor.time_input.value = .2
	var sample: Dictionary = editor.sample()
	check(sample.shapes.size() == 3 and is_equal_approx(sample.snapshot.spread,45),"三道轮廓即时采用新夹角")
	check(is_equal_approx(sample.snapshot.height,4.1),"定格高度与真实三线固定4.1米一致")
	check(is_equal_approx(sample.timing.raise,1.0/3.0) and not sample.timing.struck,"固定时刻使用共享前摇定义")
	check(actor.global_position.is_equal_approx(origin) and is_equal_approx(actor.anim_clock,clock),"输入／时间采样不推进站位或世界时钟")
	check(actor._rage_director.areas.is_empty(),"定格只采数据，不创建会伤人的运行预警")
	check(session.values(draft).triple_slam_width == 2.4 and session.values(draft).triple_slam_damage == 37.0,"离开输入框后提交同一对象草稿")
	var damage_box: SpinBox = editor.fields.triple_slam_damage
	click_point(damage_box.get_global_rect().position+Vector2(damage_box.size.x-7,damage_box.size.y*.25))
	await ui_frames(3)
	check(session.values(draft).triple_slam_damage > 37,"原生箭头仍能真实修改草稿")
	await type_number(damage_box,"37")
	editor.commit()
	await capture("t03_shape_before")
	await type_number(editor.fields.triple_slam_spread,"60")
	print("[夹角预览] ",editor.sample().snapshot.spread," committed=",session.values(draft).triple_slam_spread," pending=",source._pending_text," status=",editor.status.text)
	check(is_equal_approx(editor.time_input.value,.2),"改变参数保留绝对几何时刻")
	check(not (sample.shapes[0].pose as Transform3D).is_equal_approx(editor.sample().shapes[0].pose),"修改夹角实际改变两侧预警朝向")
	editor.fields.triple_slam_spread.apply()
	editor.commit()
	await frames(2)
	await capture("t03_shape_after")
	click(observer._edit_button)
	await ui_frames(3)
	print("[收起] editor=",editor.visible," study=",observer.study," button=",observer._edit_button.get_global_rect()," hint=",observer._hint.text)
	check(not editor.visible and observer._hint.text.contains("待重播") and session.values(draft).triple_slam_spread == 60.0,"收起编辑明确提示旧运行样本待重播，不冒充草稿还原")
	click(observer._edit_button)
	await frames(22)
	print("[重入] editor=",editor.visible," study=",observer.study," spread=",editor.sample().snapshot.spread," panel=",source.visible)
	check(editor.visible and is_equal_approx(editor.sample().snapshot.spread,60),"再次定格采用同一最新草稿")
	await type_number(editor.fields.triple_slam_width,"10001")
	check(editor.status.text.contains("10001") and editor.status.text.contains("1000") and editor.status.text.contains("需在") and editor.status.text.contains("宽度"),"超限输入持续说明字段、原文、支持边界与恢复方式")
	check(editor.fields.triple_slam_width.get_line_edit().text == "10001","非法数字不被原生控件限幅")
	check(is_equal_approx(editor.sample().snapshot.width,2.4),"非法输入保留最近合法几何")
	check(not editor.commit(),"非法输入不能播放／试打")
	await capture("t03_shape_error")
	click(lab._professional_navigation.back_button)
	await frames(4)
	check(source.visible and not editor.visible,"非法输入仍能统一左上角返回完整参数页")
	check(source._pending_text.get("triple_slam_width") == "10001" and source._fields.triple_slam_width.get_line_edit().text == "10001","返回共享原文与错误，未出现第二份配置")
	source._discard_pending()
	check(session.values(draft).triple_slam_width == 2.4,"撤回输入不还原已提交的有效修改")
	source._name_edit.text = "T03三线试验"
	source.save_current()
	check(Tuning.preset_values(PROFILE,"T03三线试验").triple_slam_spread == 60.0,"显式保存候选读取相同形状草稿")
	check(Tuning.active_name(PROFILE) == original_default and Catalog.formal_preset(PROFILE) == formal,"保存／预览不改变默认或正式Boss引用")
	var values: Dictionary = session.values(draft)
	await lab.play_edited_observation(false)
	check(observer.actor._rage_director.areas.size() == 3,"同一草稿播放真实三线单招")
	if observer.actor._rage_director.areas.size() != 3:
		print("[T03中止] values=",values," state=",observer.actor.current_state," skill=",observer.skill_choice.selected)
		quit(1)
		return
	var runtime: Dictionary = observer.actor._rage_director.triple_snapshot
	check(runtime == Definition.snapshot(values,observer.actor.scale.x,observer.actor._damage_scale),"运行快照使用共享定义")
	for index in 3:
		var actual: Node3D = observer.actor._rage_director.areas[index]
		var expected: Dictionary = Definition.shapes(runtime,observer.actor.global_transform.orthonormalized())[index]
		check(actual.shape == expected.spec and actual.global_transform.is_equal_approx(expected.pose),"真实区域与纯采样逐道一致 "+str(index))
	await frames(75)
	check(paused and observer._single_completed,"单次真实播放结束后自动冻结，不偷偷循环或继续跑世界")
	# 锁定后摆危险/安全测点，由真实物理帧完成结算，并验证重叠只伤一次。
	for trial: Dictionary in [{"point":Vector3(0,1.08,-10),"hit":true,"name":"中心线"},{"point":Vector3(2.0,1.08,-10),"hit":false,"name":"线旁安全点"},{"point":Vector3(0,1.08,-.4),"hit":true,"name":"近处重叠"}]:
		await lab.observe_draft(PROFILE,values,false)
		actor = observer.actor
		var player: Node3D = lab._player
		player.set_meta(&"experiment_invincible",false)
		player.max_health = 10000
		player.health = 10000
		player.shield = 0
		player.hit_invulnerability = 0
		player._damage_invulnerability = 0
		player.global_position = actor.global_transform.orthonormalized()*trial.point
		var inside := false
		for area: Node3D in actor._rage_director.areas: inside = inside or area.can_hit(player,area.hit_source())
		check(inside == trial.hit,"真实区域危险／安全判断 "+String(trial.name))
		var damage: float = actor._rage_director.triple_snapshot.damage
		await frames(41)
		var loss: float = 10000-player.health
		check(is_equal_approx(loss,damage if trial.hit else 0.0),"物理帧真实扣血与显示并集一致 "+String(trial.name))
		hits.append({"name":trial.name,"predicted_hit":inside,"loss":loss,"single_damage":damage})
	await lab.observe_draft(PROFILE,values,false)
	await lab.edit_observation_shape()
	await frames(3)
	# 布局同时检查常见逻辑窗口及130%UI，保留实际返回、编辑与动作入口。
	for dimensions: Vector2i in [Vector2i(1920,1080),Vector2i(1280,720)]:
		root.size = dimensions
		for factor: float in [1.0,1.3]:
			root.content_scale_factor = factor
			await frames(5)
			var viewport_rect := Rect2(Vector2.ZERO,root.get_visible_rect().size)
			check(viewport_rect.encloses(editor.get_global_rect()),"紧凑形状面板在窗口／缩放内")
			check(not observer._panel.get_global_rect().intersects(editor.get_global_rect()),"观察条与编辑区不互相遮挡")
			check(not observer._panel.get_global_rect().intersects(lab._professional_navigation.back_button.get_global_rect()),"统一返回不再遮挡攻击观察首行")
			check(editor.fields.triple_slam_spread.is_visible_in_tree() and observer._edit_button.is_visible_in_tree(),"形状字段与收起入口可见")
			for field_key: String in editor.fields:
				var field: SpinBox = editor.fields[field_key]
				check((field.get_parent().get_parent().get_parent() as ScrollContainer).get_global_rect().encloses(field.get_global_rect()),"七个参数均完整位于可见滚动区")
				check(is_equal_approx(field.value,float(values[field_key])) and field.get_line_edit().text == String.num(float(values[field_key]),12),"重入／缩放后原生数值与小数显示均为同一精确草稿 "+field_key)
				if not is_equal_approx(field.value,float(values[field_key])) or field.get_line_edit().text != String.num(float(values[field_key]),12):
					print("[精度差异] ",field_key," native=",field.value," text=",field.get_line_edit().text," expected=",values[field_key]," focus=",field.get_line_edit().has_focus())
			measurements.append({"window":str(dimensions),"scale":factor,"logical":str(viewport_rect.size),"editor":str(editor.get_global_rect()),"observer":str(observer._panel.get_global_rect())})
			await capture("t03_layout_%d_%d" % [dimensions.x,int(factor*100)])
	root.content_scale_factor = 1
	await frames(3)
	var button: Button
	for node: Node in editor.find_children("*","Button",true,false):
		if node.text == "真人试打": button = node
	click(button)
	await frames(22)
	check(not observer.study and not editor.visible and lab.accepts_player_input(),"真实按钮重建后进入真人交战")
	check(lab._player.process_mode == Node.PROCESS_MODE_INHERIT and observer.actor.ai_enabled,"试打启用玩家及真实选招AI")
	check(observer.actor._tuning.triple_slam_width == 2.4 and observer.actor._tuning.triple_slam_spread == 60.0,"试打使用同一整份草稿，不回读旧默认")
	check(not observer.actor.get_meta(&"attack_inspection_manual") and not observer.actor.get_meta(&"experiment_invincible"),"单招观察的手动／敌人无敌条件没有泄漏到真人试打")
	click(lab._professional_navigation.back_button)
	await frames(4)
	check(source.visible and paused and source.draft_id == draft and session.values(draft).triple_slam_damage == 37.0,"真人试打也能同位置返回，草稿不还原")
	await lab.observe_draft(PROFILE,values,false)
	lab.edit_observation_shape()
	click(lab._professional_navigation.back_button)
	await frames(16)
	check(source.visible and not observer.study and not editor.visible and not observer.camera.current,"准备期间立即返回取消待完成观察，不重开编辑或抢回相机")
	paused = false
	current_scene = null
	lab.queue_free()
	await frames(3)
	var file := FileAccess.open(Artifacts.ensure_dir("reports").path_join("skill_shape_workspace.json"),FileAccess.WRITE)
	file.store_string(JSON.stringify({"checks":checks,"failures":failures,"layout":measurements,"hits":hits},"\t")); file.close()
	print("[T03形状工作区] checks=",checks," failures=",failures.size())
	quit(0 if failures.is_empty() else 1)
