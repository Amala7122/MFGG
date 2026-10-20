extends SceneTree
## 已保存电视滤镜不能污染挑战默认；场景内仍可主动切换，离场恢复有效设置。
var failures := 0

func _initialize() -> void: call_deferred("_run")

func check(ok: bool, message: String) -> void:
	if not ok:
		failures += 1
		push_error(message)

func _run() -> void:
	var settings := root.get_node("DisplaySettings")
	var effect := root.get_node("PostProcess")
	settings.select_post_process_style(1)
	settings.post_process_style = 0
	settings._load_settings()
	settings._apply_post_process()
	check(effect.style == 1,"负向基线：真实本机配置可重现黑白电视")
	var saved := FileAccess.get_file_as_bytes(settings.SETTINGS_PATH)
	var first := Node.new()
	root.add_child(first)
	settings.begin_scene_style(first)
	settings.call_deferred("_apply_post_process")
	await process_frame
	await process_frame
	check(effect.style == 0 and settings.post_process_label() == "关闭","挑战初始基础风格，不被延迟应用覆盖")
	check(FileAccess.get_file_as_bytes(settings.SETTINGS_PATH) == saved and settings.post_process_style == 1,"场景默认不改本机已保存风格")
	settings.cycle_post_process_style()
	check(effect.style == 1,"主动切换从当前基础风格开始，不是从隐藏的旧设置跳号")
	settings.select_post_process_style(0)
	check(effect.style == 0,"场景内可切回基础，默认不是锁定开关")
	settings.select_post_process_style(3)
	var second := Node.new()
	root.add_child(second)
	settings.begin_scene_style(second)
	first.queue_free()
	await process_frame
	await process_frame
	check(effect.style == 0,"旧场景离场不会覆盖新挑战默认")
	second.queue_free()
	await process_frame
	await process_frame
	check(effect.style == 3,"挑战离场恢复用户实际保存的风格")
	settings.select_post_process_style(0)
	print("[挑战默认画面] failures=",failures)
	quit(1 if failures else 0)
