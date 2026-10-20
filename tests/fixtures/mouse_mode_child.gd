extends SceneTree
## 无头子进程检查自动标记继承，以及手动路径如实读回原生 Input。


func _initialize() -> void:
	var expected_automation := "--expect-automation" in OS.get_cmdline_user_args()
	if DisplayServer.get_name().to_lower() != "headless" or MouseControl.is_automation() != expected_automation:
		push_error("鼠标夹具必须在无头子进程中运行，且自动标记须与预期一致")
		quit(1)
		return
	for requested in [Input.MOUSE_MODE_CAPTURED, Input.MOUSE_MODE_CONFINED, Input.MOUSE_MODE_VISIBLE]:
		MouseControl.mode = requested
		# 无头 DisplayServer 忽略捕获；手动入口必须如实读回原生值。
		var valid: bool = (MouseControl.mode == requested and Input.mouse_mode == Input.MOUSE_MODE_VISIBLE) if expected_automation else MouseControl.mode == Input.mouse_mode
		if not valid:
			push_error("子进程鼠标模式不符：%d" % requested)
			quit(1)
			return
	print("[鼠标子进程] PASS")
	quit(0)
