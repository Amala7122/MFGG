extends SceneTree
## 从真实按钮走准备、真人录制、主动结束、返回与再次进入；注入样本不能算真人群体。
const Lab := preload("res://prototypes/sparring_lab/combat_sparring_lab.tscn")
const Artifacts := preload("res://scripts/artifact_paths.gd")
const Inputs := preload("res://tools/probes/sparring/sparring_input.gd")
var _failures := 0

func _initialize() -> void:
	call_deferred("_run")

func _check(ok: bool, message: String) -> void:
	if not ok:
		_failures += 1
		push_error(message)

func _button(node: Node, caption: String) -> Button:
	for child in node.get_children():
		if child is Button and child.text == caption:
			return child
		var found := _button(child, caption)
		if found != null:
			return found
	return null

func _prepared() -> Node:
	for _frame in range(1200):
		await process_frame
		var candidate := current_scene
		if is_instance_valid(candidate) and candidate.scene_file_path.ends_with("combat_sparring_lab.tscn") and is_instance_valid(candidate.get("session")):
			return candidate.session
	_check(false, "真实入口能进入陪练准备面板")
	return null

func _run() -> void:
	var world := Lab.instantiate()
	root.add_child(world)
	current_scene = world
	var session: Node = await _prepared()
	if session != null:
		_check(session.options.mode == "manual" and not session.running and paused, "编辑器直接运行默认为真人准备，不自动替玩家开战")
		var start := _button(session, "真人打一局并录制")
		_check(start != null and start.is_visible_in_tree(), "真人一键入口无需滚动寻找")
		await process_frame
		if start != null:
			_check(start.get_global_rect().end.y < root.get_visible_rect().size.y, "真人按钮位于窗口内")
		if DisplayServer.get_name() != "headless":
			await RenderingServer.frame_post_draw
			_check(root.get_texture().get_image().save_png(Artifacts.ensure_dir("screenshots", "manual_entry").path_join("ready.png")) == OK, "保存实际初始准备画面")
		# 自动脚本必须如实标记，不污染真实玩家资料。
		session.options.capture_origin = "synthetic_input_contract"
		if start != null:
			start.pressed.emit()
		_check(session.running and session.options.mode == "manual" and not paused, "点击真人按钮启动真实手动输入与录制")
		Input.action_press("move_right")
		for _frame in range(20):
			await physics_frame
		Input.action_release("move_right")
		session.toggle_pause()
		_check(paused and session._panel.visible, "Tab 对应暂停后可操作结束与保存")
		var stop := _button(session, "结束并保存")
		if stop != null:
			stop.pressed.emit()
		_check(not session.running and session.result.get("outcome") == "manual_stop", "主动结束保留截断结果，不伪记击杀或死亡")
		var folder: String = session.recorder.directory
		_check(FileAccess.file_exists(folder.path_join("result.json")) and not Inputs.read(folder.path_join("inputs.jsonl")).frames.is_empty(), "主动结束产生可分析的输入与战况文件")
		_check(session.result.conditions.capture_origin == "synthetic_input_contract", "入口测试不冒充真实玩家")
		_button(session, "返回主菜单").pressed.emit()
		for _frame in range(1200):
			await process_frame
			if current_scene != null and current_scene.scene_file_path == "res://scenes/hyrule_field.tscn" and paused:
				break
		var flow := root.get_node("GameFlow")
		_check(paused and flow.visible and not bool(flow.get_meta(&"sparring_session_active", false)), "返回清理陪练标记并显示正常主菜单")
		var entry := _button(flow, "实战陪练 / 真人录制")
		_check(entry != null and entry.is_visible_in_tree(), "主菜单有可见的实战真人入口")
		if entry != null:
			entry.pressed.emit()
			session = await _prepared()
			_check(session != null and not session.running and session.options.mode == "manual", "主菜单再次进入也停在真人准备")
	paused = false
	var last := current_scene
	current_scene = null
	if is_instance_valid(last):
		last.queue_free()
	for _frame in range(5):
		await process_frame
	preload("res://scripts/object_pool.gd").clear_all()
	await preload("res://tools/probes/sparring/sparring_runtime.gd").settle_audio(self)
	print("[真人实战入口] failures=", _failures)
	quit(1 if _failures else 0)
