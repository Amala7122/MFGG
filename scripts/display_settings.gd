extends Node
## 显示设置的唯一入口。
##
## 物理窗口分辨率与 UI 逻辑画布刻意分开：项目仍以 1152×648 排版，
## Canvas Items 会在实际窗口上以原生像素绘制 2D；3D 独立使用渲染比例。

signal ui_scale_changed(value: float)

const SETTINGS_PATH := "user://display.cfg"
const SECTION := "display"
const MODE_WINDOWED := 0
const MODE_BORDERLESS := 1
const DEFAULT_RESOLUTION := Vector2i(1920, 1080)
const RESOLUTIONS: Array[Vector2i] = [
	Vector2i(1280, 720),
	Vector2i(1600, 900),
	Vector2i(1920, 1080),
	Vector2i(2560, 1440),
	Vector2i(3840, 2160),
]
const UI_SCALES: Array[float] = [0.85, 1.0, 1.15, 1.3]
const RENDER_SCALES: Array[float] = [1.0, 0.85, 0.7]

static var instance: Node

var display_mode := MODE_WINDOWED
var window_resolution := DEFAULT_RESOLUTION
var ui_scale := 1.0
var render_scale := 1.0


func _ready() -> void:
	instance = self
	process_mode = Node.PROCESS_MODE_ALWAYS
	# 截图与性能基准必须由各自的命令行参数决定尺寸，不能被个人存档污染。
	if _is_automation_run() or DisplayServer.get_name().to_lower() == "headless":
		return
	_load_settings()
	call_deferred("_apply_all")


func _load_settings() -> void:
	var config := ConfigFile.new()
	if config.load(SETTINGS_PATH) != OK:
		return
	display_mode = clampi(int(config.get_value(SECTION, "mode", MODE_WINDOWED)), 0, 1)
	var loaded := Vector2i(
		int(config.get_value(SECTION, "width", DEFAULT_RESOLUTION.x)),
		int(config.get_value(SECTION, "height", DEFAULT_RESOLUTION.y))
	)
	window_resolution = loaded if loaded in RESOLUTIONS else DEFAULT_RESOLUTION
	ui_scale = _nearest_ui_scale(float(config.get_value(SECTION, "ui_scale", 1.0)))
	render_scale = _nearest_render_scale(float(config.get_value(SECTION, "render_scale", 1.0)))


func _save_settings() -> void:
	var config := ConfigFile.new()
	config.set_value(SECTION, "mode", display_mode)
	config.set_value(SECTION, "width", window_resolution.x)
	config.set_value(SECTION, "height", window_resolution.y)
	config.set_value(SECTION, "ui_scale", ui_scale)
	config.set_value(SECTION, "render_scale", render_scale)
	var result := config.save(SETTINGS_PATH)
	if result != OK:
		push_warning("DisplaySettings: 无法保存显示设置（错误 %d）" % result)


func _apply_all() -> void:
	_apply_ui_scale()
	_apply_render_scale()
	_apply_display_mode()


func _apply_display_mode() -> void:
	if display_mode == MODE_BORDERLESS:
		# Godot 的 FULLSCREEN 是无边框桌面全屏；EXCLUSIVE_FULLSCREEN 才是独占全屏。
		DisplayServer.window_set_mode(DisplayServer.WINDOW_MODE_FULLSCREEN)
		return
	DisplayServer.window_set_mode(DisplayServer.WINDOW_MODE_WINDOWED)
	DisplayServer.window_set_flag(DisplayServer.WINDOW_FLAG_BORDERLESS, false)
	# 从全屏退回窗口时，系统要先完成模式切换，下一次消息循环再设尺寸才可靠。
	call_deferred("_apply_windowed_resolution")


func _apply_windowed_resolution() -> void:
	if display_mode != MODE_WINDOWED:
		return
	DisplayServer.window_set_size(window_resolution)
	var screen := DisplayServer.window_get_current_screen()
	var usable := DisplayServer.screen_get_usable_rect(screen)
	var centered := usable.position + (usable.size - window_resolution) / 2
	DisplayServer.window_set_position(centered)


func _apply_ui_scale() -> void:
	var window := get_tree().root
	if window == null:
		return
	window.content_scale_factor = ui_scale
	ui_scale_changed.emit(ui_scale)


func _apply_render_scale() -> void:
	var viewport := get_tree().root
	if viewport == null:
		return
	# Godot 只缩放 3D 缓冲区；CanvasItem/HUD 保持窗口原生像素。
	# 100% 禁用缩放；低于 100% 时 FSR 1.0 在低模边缘比双线性更清楚。
	viewport.scaling_3d_mode = Viewport.SCALING_3D_MODE_FSR \
		if render_scale < 1.0 else Viewport.SCALING_3D_MODE_BILINEAR
	viewport.scaling_3d_scale = render_scale


func cycle_display_mode() -> void:
	display_mode = MODE_BORDERLESS if display_mode == MODE_WINDOWED else MODE_WINDOWED
	_save_settings()
	_apply_display_mode()


func cycle_resolution() -> void:
	var index := RESOLUTIONS.find(window_resolution)
	window_resolution = RESOLUTIONS[(index + 1) % RESOLUTIONS.size()]
	_save_settings()
	if display_mode == MODE_WINDOWED:
		_apply_windowed_resolution()


func cycle_ui_scale() -> void:
	var index := _ui_scale_index(ui_scale)
	ui_scale = UI_SCALES[(index + 1) % UI_SCALES.size()]
	_save_settings()
	_apply_ui_scale()


func cycle_render_scale() -> void:
	var index := _render_scale_index(render_scale)
	render_scale = RENDER_SCALES[(index + 1) % RENDER_SCALES.size()]
	_save_settings()
	_apply_render_scale()


func mode_label() -> String:
	return "无边框全屏" if display_mode == MODE_BORDERLESS else "窗口模式"


func resolution_label() -> String:
	return "%d × %d" % [window_resolution.x, window_resolution.y]


func ui_scale_label() -> String:
	return "%d%%" % roundi(ui_scale * 100.0)


func render_scale_label() -> String:
	return "%d%%" % roundi(render_scale * 100.0)


func _ui_scale_index(value: float) -> int:
	for index in UI_SCALES.size():
		if is_equal_approx(UI_SCALES[index], value):
			return index
	return 1


func _nearest_ui_scale(value: float) -> float:
	var nearest := UI_SCALES[0]
	var distance := absf(value - nearest)
	for candidate in UI_SCALES:
		var candidate_distance := absf(value - candidate)
		if candidate_distance < distance:
			nearest = candidate
			distance = candidate_distance
	return nearest


func _render_scale_index(value: float) -> int:
	for index in RENDER_SCALES.size():
		if is_equal_approx(RENDER_SCALES[index], value):
			return index
	return 0


func _nearest_render_scale(value: float) -> float:
	var nearest := RENDER_SCALES[0]
	var distance := absf(value - nearest)
	for candidate in RENDER_SCALES:
		var candidate_distance := absf(value - candidate)
		if candidate_distance < distance:
			nearest = candidate
			distance = candidate_distance
	return nearest


func _is_automation_run() -> bool:
	for arg in OS.get_cmdline_user_args():
		if arg == "--vis-capture" or arg.begins_with("--perf-benchmark="):
			return true
	return false
