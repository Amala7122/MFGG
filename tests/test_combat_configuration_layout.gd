extends SceneTree
## 从真实配置入口滚动并点击调参，覆盖物理窗口尺寸与UI缩放，不只测参数子面板。
const Artifacts := preload("res://scripts/artifact_paths.gd")
const Scenes := [preload("res://prototypes/combat_lab/combat_lab.tscn"), preload("res://prototypes/spatial_lab/combat_spatial_lab.tscn")]
var failures: Array[String] = []
var measurements: Array[Dictionary] = []
var checks := 0

func _initialize() -> void: _run.call_deferred()

func check(ok: bool, message: String) -> void:
	checks += 1
	if not ok:
		failures.append(message)
		push_error(message)

func frames(count: int) -> void:
	for _i in count: await process_frame

func button_named(node: Node, captions: Array) -> Button:
	for child: Node in node.get_children():
		if child is Button and child.text in captions: return child
		var found := button_named(child, captions)
		if found != null: return found
	return null

func tooltip_shown(node: Node, expected: String) -> bool:
	for child: Node in node.get_children(true):
		if child is Label and child.text == expected and child.is_visible_in_tree(): return true
		if tooltip_shown(child, expected): return true
	return false

func click(control: Control) -> void:
	var point := control.get_global_rect().get_center()
	var motion := InputEventMouseMotion.new()
	motion.position = point
	motion.global_position = point
	root.push_input(motion, true)
	for down: bool in [true, false]:
		var event := InputEventMouseButton.new()
		event.position = point
		event.global_position = point
		event.button_index = MOUSE_BUTTON_LEFT
		event.pressed = down
		event.button_mask = MOUSE_BUTTON_MASK_LEFT if down else 0
		root.push_input(event, true)
		await frames(1)

func _run() -> void:
	await frames(3)
	var original_size := root.size
	var original_scale := root.content_scale_factor
	for scene_index in Scenes.size():
		paused = false
		var lab: Node = Scenes[scene_index].instantiate()
		root.add_child(lab)
		current_scene = lab
		await frames(8)
		for condition: Dictionary in [
			{"name": "1920_scale100", "size": Vector2i(1920, 1080), "scale": 1.0},
			{"name": "1280_scale100", "size": Vector2i(1280, 720), "scale": 1.0},
			{"name": "1280_scale130", "size": Vector2i(1280, 720), "scale": 1.3},
		]:
			root.size = condition.size
			root.content_scale_factor = condition.scale
			await frames(6)
			lab._layout_interface()
			await frames(3)
			var scroll: ScrollContainer = lab._panel.find_child("EnemyList", true, false)
			var header: Control = lab._panel.find_child("ConfigurationHeader", true, false)
			var actions: Control = lab._panel.find_child("ConfigurationActions", true, false)
			var viewport := root.get_visible_rect()
			var tag := "%s_%s" % ["prototype" if scene_index == 0 else "space", condition.name]
			measurements.append({"case": tag, "window": str(root.size), "scale": root.content_scale_factor,
				"viewport": str(viewport), "panel": str(lab._panel.get_global_rect()), "list": str(scroll.get_global_rect()),
				"header": str(header.get_global_rect()), "actions": str(actions.get_global_rect())})
			check(viewport.encloses(lab._panel.get_global_rect()), tag + " 配置面板不超出逻辑视口")
			check(scroll.size.y >= viewport.size.y * 0.55, tag + " 大部分垂直空间留给敌人列表")
			check(header.size.y <= viewport.size.y * 0.06 and actions.size.y <= viewport.size.y * 0.06, tag + " 标题信息和操作分别收在一行紧凑区域")
			check(viewport.encloses(lab._generate.get_global_rect()), tag + " 底部生成按钮可见")
			check(lab._controls.get_line_count() * lab._controls.get_line_height() <= lab._controls.size.y, tag + " 底部帮助行高可完整容纳")
			var previous_selection: Dictionary = lab.get_selection()
			var deselect := button_named(actions, ["全不选"])
			await click(deselect)
			check(lab.get_selection().is_empty(), tag + " 紧凑按钮实际取消全部选择")
			lab.set_selection(previous_selection)
			for id: String in lab.PROTOTYPE_SCENES:
				var row: Control = lab._rows[id].check.get_parent()
				var tune := button_named(row, ["参数", "调参"])
				check(tune != null, tag + " 可找到 " + id + " 的调参入口")
				if tune == null: continue
				check(tune.text == "调参", tag + " 行内按钮使用明确调参名称")
				scroll.ensure_control_visible(row)
				await frames(3)
				var inside := scroll.get_global_rect().encloses(tune.get_global_rect())
				check(inside, tag + " 滚动后完整显示 " + id + " 调参按钮")
				if not inside: continue
				# 基准条件逐一实际点击七个对象；缩放条件验证泰坦打开及返回。
				if condition.scale == 1.0 and condition.size.x == 1920 or id == lab.SEDIMENT_TITAN_ID:
					await click(tune)
					check(lab._tuning_panel.visible and lab._tuning_panel.enemy_id == id, tag + " 实际点击打开正确敌人的参数")
					var back := button_named(lab._tuning_panel, ["返回敌人配置"])
					if back != null and lab._tuning_panel.visible:
						await click(back)
						check(lab._panel.visible and not lab._tuning_panel.visible, tag + " 实际返回配置列表")
					else:
						check(false, tag + " 参数面板返回按钮可达")
						lab._show_configuration()
			var last: Control = lab._rows.values().back().check.get_parent()
			scroll.ensure_control_visible(last)
			await frames(3)
			check(scroll.get_global_rect().encloses(last.get_global_rect()), tag + " 最后一行也可完整滚动到")
			lab._on_enemy_tuning_saved(lab.SEDIMENT_TITAN_ID, "很长的方案名".repeat(8))
			await frames(4)
			check(viewport.encloses(lab._panel.get_global_rect()) and scroll.size.y >= viewport.size.y * 0.55, tag + " 保存反馈及长名称仍为列表保留大部分空间")
			check(lab._result.tooltip_text == lab._result.text, tag + " 多行反馈可悬停查看完整内容")
			lab._set_result("")
			check(not lab._result.visible, tag + " 空信息行不占用内容区")
			scroll.scroll_vertical = 0
			await frames(3)
			if DisplayServer.get_name() != "headless":
				await RenderingServer.frame_post_draw
				check(root.get_texture().get_image().save_png(Artifacts.ensure_dir("screenshots").path_join(tag + ".png")) == OK, tag + " 保存真实父入口截图")
				if scene_index == 0 and condition.size.x == 1920:
					var hover := InputEventMouseMotion.new()
					hover.position = lab._config_help.get_global_rect().get_center()
					hover.global_position = hover.position
					root.push_input(hover, true)
					await create_timer(0.8, true).timeout
					check(tooltip_shown(root, lab._config_help.tooltip_text), "鼠标悬停实际显示完整说明浮动提示")
					await RenderingServer.frame_post_draw
					check(root.get_texture().get_image().save_png(Artifacts.ensure_dir("screenshots").path_join(tag + "_help.png")) == OK, "保存实际悬停说明截图")
		current_scene = null
		lab.queue_free()
		await frames(3)
	root.size = original_size
	root.content_scale_factor = original_scale
	paused = false
	var report := FileAccess.open(Artifacts.ensure_dir("reports").path_join("combat_configuration_layout.json"), FileAccess.WRITE)
	check(report != null, "布局报告可写入")
	if report != null:
		report.store_string(JSON.stringify({"passed": failures.is_empty(), "checks": checks, "failures": failures, "measurements": measurements}, "\t"))
		report.close()
	print("[配置入口布局] checks=", checks, " failures=", failures.size())
	quit(0 if failures.is_empty() else 1)
