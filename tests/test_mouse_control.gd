extends SceneTree
## 自动图形运行必须保持系统鼠标自由，并保留游戏的瞄准/暂停请求语义。
const Artifacts := preload("res://scripts/artifact_paths.gd")
var failures := 0


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	_check(MouseControl.is_automation(), "统一启动器必须启用鼠标隔离")
	_check(bool(ProjectSettings.get_setting("display/window/size/no_focus", false)), "隔离工程必须从窗口创建前禁用焦点")
	if DisplayServer.get_name().to_lower() != "headless":
		_check(DisplayServer.window_get_flag(DisplayServer.WINDOW_FLAG_NO_FOCUS), "真实图形窗口必须不可获取焦点")
		_check(not DisplayServer.window_get_flag(DisplayServer.WINDOW_FLAG_ALWAYS_ON_TOP), "自动窗口不能置顶")
	var previous := MouseControl.mode
	for requested in [Input.MOUSE_MODE_CAPTURED, Input.MOUSE_MODE_CONFINED,
			Input.MOUSE_MODE_CONFINED_HIDDEN, Input.MOUSE_MODE_HIDDEN, Input.MOUSE_MODE_VISIBLE]:
		MouseControl.mode = requested
		_check(MouseControl.mode == requested, "游戏逻辑仍能读取请求模式 %d" % requested)
		_check(Input.mouse_mode == Input.MOUSE_MODE_VISIBLE, "系统鼠标在请求当下仍可见自由 %d" % requested)
		await process_frame
		_check(DisplayServer.mouse_get_mode() == DisplayServer.MOUSE_MODE_VISIBLE, "渲染帧后系统鼠标仍自由 %d" % requested)
	var was_paused := paused
	paused = true
	MouseControl.mode = Input.MOUSE_MODE_CAPTURED
	_check(Input.mouse_mode == Input.MOUSE_MODE_VISIBLE, "暂停/面板恢复时也不能捕获，不依赖逐帧释放")
	paused = was_paused
	MouseControl.mode = previous
	_scan_calls("res://scripts")
	_scan_calls("res://prototypes/combat_lab")
	_scan_calls("res://tests")
	_scan_calls("res://tools/probes")
	_verify_headless_child(true)
	_verify_headless_child(false)
	print("[鼠标隔离] failures=", failures)
	quit(1 if failures else 0)


func _scan_calls(directory: String) -> void:
	var bypass := RegEx.new()
	bypass.compile("Input\\s*\\.\\s*(mouse_mode\\s*=(?!=)|set_mouse_mode\\s*\\()|DisplayServer\\s*\\.\\s*mouse_set_mode\\s*\\(")
	for name in DirAccess.get_files_at(directory):
		var path := directory.path_join(name)
		if not name.ends_with(".gd") or path == "res://scripts/mouse_control.gd":
			continue
		_check(bypass.search(FileAccess.get_file_as_string(path)) == null, "禁止绕过鼠标隔离入口：" + path)
	for name in DirAccess.get_directories_at(directory):
		_scan_calls(directory.path_join(name))


func _verify_headless_child(automated: bool) -> void:
	# 无头只核对读回原生 Input；真人捕获必须由用户试玩确认。
	var marker := OS.get_environment("RUIN_STAR_AUTOMATION")
	if not automated:
		OS.unset_environment("RUIN_STAR_AUTOMATION")
	var output: Array = []
	var log_path := Artifacts.ensure_dir("logs").path_join("automated_mouse_child.engine.log" if automated else "manual_mouse.engine.log")
	var code := OS.execute(OS.get_executable_path(), PackedStringArray([
		"--headless", "--path", ProjectSettings.globalize_path("res://"),
		"--log-file", log_path, "--script", "res://tests/fixtures/mouse_mode_child.gd",
		"--", "--expect-automation" if automated else "--expect-manual",
	]), output, true)
	OS.set_environment("RUIN_STAR_AUTOMATION", marker)
	var log_text := FileAccess.get_file_as_string(log_path) if FileAccess.file_exists(log_path) else ""
	_check(code == 0 and log_text.contains("[鼠标子进程] PASS")
		and not log_text.contains("SCRIPT ERROR:") and not log_text.contains("\nERROR:"), "自动标记继承" if automated else "无自动标记时读回原生 Input（无头验证）")


func _check(condition: bool, message: String) -> void:
	if not condition:
		failures += 1
		push_error(message)
