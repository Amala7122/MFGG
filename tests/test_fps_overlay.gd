extends SceneTree
## 全局帧数显示的守卫：面板存在、FPS/毫秒文本会更新、鼠标不拦截。
const Overlay := preload("res://scripts/fps_overlay.gd")
var _failed := false


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	# 自动化运行默认隐藏，本测试强制打开一个实例。
	_check(root.find_child("FpsOverlayPanel", true, false) == null,
		"自动化运行默认不显示全局帧数面板")
	OS.set_environment("RUIN_STAR_FPS_OVERLAY", "1")
	var overlay: CanvasLayer = Overlay.new()
	root.add_child(overlay)
	await process_frame
	var panel := overlay.get_node_or_null("FpsOverlayPanel") as PanelContainer
	_check(panel != null, "全局帧数面板已创建")
	var label := panel.get_node_or_null("FpsOverlayLabel") as Label if panel != null else null
	_check(label != null, "帧数文本已创建")
	if panel != null:
		_check(panel.mouse_filter == Control.MOUSE_FILTER_IGNORE, "帧数面板不拦截鼠标")
		_check(panel.anchor_left == 1.0 and panel.anchor_top == 1.0,
			"帧数面板固定在右下角")
	if label != null:
		for _frame in 30:
			await process_frame
		_check(label.text.begins_with("FPS "), "文本包含实时 FPS")
		_check(label.text.contains("ms") and label.text.contains("peak"), "文本包含帧耗与最差单帧")
		var sampled_ms := float(overlay.call("sampled_ms"))
		var sampled_fps := float(overlay.call("sampled_fps"))
		_check(sampled_ms > 0.0 and sampled_ms < 1000.0,
			"毫秒值来自真实墙钟而不是加载尖峰")
		_check(sampled_fps > 0.0 and sampled_fps < 100000.0, "帧率来自真实墙钟")
	overlay.queue_free()
	await process_frame
	print("[FPS overlay] ", "FAIL" if _failed else "PASS")
	quit(1 if _failed else 0)


func _check(ok: bool, message: String) -> void:
	if not ok:
		_failed = true
		push_error("[FPS overlay] " + message)
