extends CanvasLayer
## 全局帧数显示：任何场景（主游戏、测试台、原型）自动出现，不需要每个场景接入。
## 用真实墙钟（Time.get_ticks_usec）而不是 delta：固定步进、时间缩放、暂停都不会伪造帧率。
## 显示 FPS、平滑帧耗，以及最近 1 秒内的最差单帧（peak），用来暴露“平均 60 但会顿一下”。
## F12 切换；鼠标穿透；自动化运行默认隐藏（可用 --fps-overlay 或环境变量强制）。

const TOGGLE_KEY := KEY_F12
const UPDATE_INTERVAL := 0.25
const HUD_CHECK_INTERVAL := 1.0
const PEAK_WINDOW := 1.0
## 加载、场景切换或断点会返回秒级间隔；超过这个值视为加载尖峰，不参与统计。
const MAX_VALID_FRAME_MS := 1000.0

var _panel: PanelContainer
var _label: Label
var _elapsed := 0.0
var _hud_elapsed := 0.0
var _ema_ms := 16.7
var _last_usec := 0
var _peak_ms := 0.0
var _peak_window := 0.0
var _peak_display := 0.0
var _shown := true
var _hud_owns := false


func _ready() -> void:
	layer = 100
	process_mode = Node.PROCESS_MODE_ALWAYS
	if _automation_hidden():
		# 自动化不接受本节点时直接退出，连节点计数都不改。
		queue_free()
		return
	_build()


func _automation_hidden() -> bool:
	if OS.get_environment("RUIN_STAR_FPS_OVERLAY") == "1":
		return false
	if OS.get_cmdline_user_args().has("--fps-overlay"):
		return false
	return OS.get_environment("RUIN_STAR_AUTOMATION") == "1"


func _build() -> void:
	_panel = PanelContainer.new()
	_panel.name = "FpsOverlayPanel"
	_panel.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_panel.set_anchors_preset(Control.PRESET_BOTTOM_RIGHT)
	_panel.offset_left = -248.0
	_panel.offset_top = -38.0
	_panel.offset_right = -12.0
	_panel.offset_bottom = -10.0
	var style := StyleBoxFlat.new()
	style.bg_color = Color(0.02, 0.03, 0.04, 0.55)
	style.set_corner_radius_all(4)
	style.content_margin_left = 8.0
	style.content_margin_right = 8.0
	style.content_margin_top = 2.0
	style.content_margin_bottom = 2.0
	_panel.add_theme_stylebox_override("panel", style)

	_label = Label.new()
	_label.name = "FpsOverlayLabel"
	_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	_label.add_theme_font_size_override("font_size", 13)
	_label.add_theme_color_override("font_color", Color(0.86, 0.94, 0.98))
	_label.add_theme_color_override("font_shadow_color", Color(0, 0, 0, 0.85))
	_label.add_theme_constant_override("shadow_offset_x", 1)
	_label.add_theme_constant_override("shadow_offset_y", 1)
	_label.text = "FPS --   -- ms   peak -- ms"
	_panel.add_child(_label)
	add_child(_panel)


func _process(_delta: float) -> void:
	var now := Time.get_ticks_usec()
	if _last_usec == 0:
		_last_usec = now
		return
	var instant_ms := float(now - _last_usec) / 1000.0
	_last_usec = now
	if instant_ms <= 0.0 or instant_ms > MAX_VALID_FRAME_MS:
		return
	_ema_ms = lerpf(_ema_ms, instant_ms, 0.1)
	_peak_ms = maxf(_peak_ms, instant_ms)
	_peak_window += instant_ms / 1000.0
	_elapsed += instant_ms / 1000.0
	_hud_elapsed += instant_ms / 1000.0
	if _peak_window >= PEAK_WINDOW:
		_peak_display = _peak_ms
		_peak_ms = 0.0
		_peak_window = 0.0
	if _elapsed >= UPDATE_INTERVAL:
		_elapsed = 0.0
		var fps := 1000.0 / maxf(_ema_ms, 0.001)
		_label.text = "FPS %.0f   %.1f ms   peak %.0f ms" % [fps, _ema_ms, _peak_display]
	if _hud_elapsed >= HUD_CHECK_INTERVAL:
		_hud_elapsed = 0.0
		# 主游戏 HUD 自己带可选 FPS（ui.show_fps）时让给它，避免同一屏两处数字。
		_hud_owns = _visible_hud_fps() != null
		_panel.visible = _shown and not _hud_owns


## 供守卫测试读取；显示文本不应成为唯一数据源。
func sampled_ms() -> float:
	return _ema_ms


func sampled_fps() -> float:
	return 1000.0 / maxf(_ema_ms, 0.001)


func sampled_peak_ms() -> float:
	return _peak_display


func _visible_hud_fps() -> Node:
	var scene := get_tree().current_scene
	if scene == null:
		return null
	var label := scene.find_child("FpsLabel", true, false)
	if label is CanvasItem and not (label as CanvasItem).is_visible_in_tree():
		return null
	return label


func _unhandled_input(event: InputEvent) -> void:
	var key := event as InputEventKey
	if key == null or not key.pressed or key.echo:
		return
	if key.keycode != TOGGLE_KEY:
		return
	_shown = not _shown
	_panel.visible = _shown and not _hud_owns
