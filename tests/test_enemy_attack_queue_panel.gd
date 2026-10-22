extends SceneTree
const Policy := preload("res://scripts/enemy_attack_queue_policy.gd")
const QueuePanel := preload("res://scripts/testing/enemy_attack_queue_panel.gd")
const Flow := preload("res://scripts/game_flow.gd")
const Artifacts := preload("res://scripts/artifact_paths.gd")
var _failed := false

func _initialize() -> void:
	call_deferred("_run")

func _check(condition: bool, text: String) -> void:
	if not condition: _failed = true; push_error(text)

func _click(button: Button) -> void:
	_check(is_instance_valid(button) and button.is_visible_in_tree(), "队列面板真实按钮可见")
	if not is_instance_valid(button): return
	var point := button.get_global_rect().get_center()
	_check(root.get_visible_rect().has_point(point), "真实按钮位于可点击视口")
	for down in [true, false]:
		var event := InputEventMouseButton.new()
		event.position = point
		event.global_position = point
		event.button_index = MOUSE_BUTTON_LEFT
		event.pressed = down
		event.button_mask = MOUSE_BUTTON_MASK_LEFT if down else 0
		root.push_input(event, true)
		await process_frame

func _button(node: Node, text: String) -> Button:
	for child in node.get_children():
		if child is Button and child.text.begins_with(text): return child
		var found := _button(child, text)
		if found != null: return found
	return null

func _run() -> void:
	for _frame in range(3): await process_frame
	var scene := Node3D.new()
	root.add_child(scene)
	current_scene = scene
	Flow.instance.state = Flow.State.PAUSED
	paused = true
	var original := Policy.current().duplicate(true)
	var saved_text := FileAccess.get_file_as_string(Policy.storage_path())
	var panel := QueuePanel.shared(self)
	panel.open()
	for _frame in range(3): await process_frame
	var edit: LineEdit = panel.controls["global/max_active"]
	edit.text = "2.5"
	edit.text_changed.emit(edit.text)
	await _click(_button(panel, "应用本次运行"))
	_check(Policy.current() == original and edit.text == "2.5" and panel.status.text.contains("整数"), "非法整数原文保留并说明字段／原因，不修改运行值")
	await _click(_button(panel, "关闭／返回"))
	_check(not panel.opened and paused and not Flow.instance.get_meta(&"attack_queue_modal", false), "关闭无效草稿仍可返回，原暂停状态保留")
	_check(not root.get_node("ProfessionalNavigation").visible, "从普通暂停进入后返回，不留下调试导航条")
	panel.open()
	for _frame in range(2): await process_frame
	_check(panel.controls["global/max_active"].text == "2.5", "返回重开仍保留非法原文")
	edit = panel.controls["global/max_active"]
	edit.text = "4"
	edit.text_changed.emit(edit.text)
	await _click(_button(panel, "应用本次运行"))
	_check(int(Policy.current().global.max_active) == 4 and FileAccess.get_file_as_string(Policy.storage_path()) == saved_text,
		"应用只影响后续起手，不静默保存到项目")
	panel.profiles.select(3)
	panel.profiles.item_selected.emit(3)
	await process_frame
	var paths: Array = panel.controls.keys()
	_check(paths.has("profiles/VisualBurstCrawler/skills/poison"), "切换兵种可单独调整落地黏液并发")
	await _click(_button(panel, "保存为默认并应用"))
	var document: Variant = JSON.parse_string(FileAccess.get_file_as_string(Policy.storage_path()))
	_check(document is Dictionary and int(document.global.max_active) == 4 and Policy.saved() == Policy.current(), "显式保存后默认文件与运行值一致")
	if DisplayServer.get_name() != "headless":
		await RenderingServer.frame_post_draw
		_check(root.get_texture().get_image().save_png(Artifacts.ensure_dir("screenshots").path_join("attack_queue_panel.png")) == OK, "保存队列面板真实截图")
	panel.close()
	_check(paused, "面板不会越过暂停菜单直接恢复战斗")
	var navigation := root.get_node("ProfessionalNavigation")
	navigation.show()
	panel.open()
	panel.close()
	_check(navigation.visible, "专业台原本可见的导航条返回后仍保留")
	Policy.save(original)
	print("[起手队列调节] ", "FAIL" if _failed else "PASS")
	quit(1 if _failed else 0)
