extends CanvasLayer
## 全局帧数显示：任何场景（主游戏、测试台、原型）自动出现，不需要每个场景接入。
## 用真实墙钟（Time.get_ticks_usec）而不是 delta：固定步进、时间缩放、暂停都不会伪造帧率。
## 显示 FPS、平滑帧耗、最近 1 秒最差单帧（peak）和本场景最差单帧（min）。
## 超过 50ms 的单帧写入 user://logs/fps_hitches.log，便于事后追卡顿。
## F12 切换；鼠标穿透；自动化运行默认隐藏（可用 --fps-overlay 或环境变量强制）。

const TOGGLE_KEY := KEY_F12
const UPDATE_INTERVAL := 0.25
const HUD_CHECK_INTERVAL := 1.0
const PEAK_WINDOW := 1.0
## 加载、场景切换或断点会返回秒级间隔；超过这个值视为加载尖峰，不参与统计。
const MAX_VALID_FRAME_MS := 1000.0
## 场景开始后的前 30 帧不参与 min/日志，避免把加载本身当成战斗中卡顿。
const WARMUP_FRAMES := 30
const HITCH_MS := 50.0
const LOG_PATH := "user://logs/fps_hitches.log"

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
var _scene_id := 0
var _frames_in_scene := 0
var _min_ms := 0.0
var _in_hitch := false
var _hitch_start := 0
var _hitch_frames := 0
var _hitch_max := 0.0
var _hitch_total := 0.0


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
	_panel.offset_left = -312.0
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
	_label.text = "FPS --   -- ms   peak --   min --"
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
	_track_scene()
	_frames_in_scene += 1
	_ema_ms = lerpf(_ema_ms, instant_ms, 0.1)
	_peak_ms = maxf(_peak_ms, instant_ms)
	_peak_window += instant_ms / 1000.0
	_elapsed += instant_ms / 1000.0
	_hud_elapsed += instant_ms / 1000.0
	if _peak_window >= PEAK_WINDOW:
		_peak_display = _peak_ms
		_peak_ms = 0.0
		_peak_window = 0.0
	if _frames_in_scene > WARMUP_FRAMES:
		if instant_ms > _min_ms:
			_min_ms = instant_ms
		if instant_ms >= HITCH_MS:
			_track_hitch(instant_ms)
		elif _in_hitch:
			_append_log(_hitch_line("hitch end"))
			_in_hitch = false
	if _elapsed >= UPDATE_INTERVAL:
		_elapsed = 0.0
		var fps := 1000.0 / maxf(_ema_ms, 0.001)
		var min_fps := 1000.0 / _min_ms if _min_ms > 0.0 else 0.0
		_label.text = "FPS %.0f   %.1f ms   peak %.0f   min %.0f" % [
			fps, _ema_ms, _peak_display, min_fps]
	if _hud_elapsed >= HUD_CHECK_INTERVAL:
		_hud_elapsed = 0.0
		# 主游戏 HUD 自己带可选 FPS（ui.show_fps）时让给它，避免同一屏两处数字。
		_hud_owns = _visible_hud_fps() != null
		_panel.visible = _shown and not _hud_owns


func _track_scene() -> void:
	var scene := get_tree().current_scene
	var id := scene.get_instance_id() if scene != null else 0
	if id == _scene_id:
		return
	_scene_id = id
	_frames_in_scene = 0
	_min_ms = 0.0
	_peak_ms = 0.0
	_peak_window = 0.0
	_peak_display = 0.0
	if scene != null:
		_append_log("--- scene %s ---" % scene.scene_file_path)


func _track_hitch(instant_ms: float) -> void:
	if not _in_hitch:
		_in_hitch = true
		_hitch_start = Time.get_ticks_msec()
		_hitch_frames = 0
		_hitch_max = 0.0
		_hitch_total = 0.0
	_hitch_frames += 1
	_hitch_max = maxf(_hitch_max, instant_ms)
	_hitch_total += instant_ms
	# 卡顿拖过 0.5 秒也留一条进度，避免只有开始没有结束。
	if _hitch_frames % 6 == 0:
		_append_log(_hitch_line("hitch ongoing"))


func _hitch_line(kind: String) -> String:
	var scene := get_tree().current_scene
	var scene_name := scene.scene_file_path.get_file() if scene != null else "unknown"
	var enemies := get_tree().get_nodes_in_group("enemies").size()
	var players := get_tree().get_nodes_in_group("player")
	var position := (players[0] as Node3D).global_position if not players.is_empty() else Vector3.ZERO
	var window_size := DisplayServer.window_get_size()
	return "%s %s duration=%dms slow=%.1fms frames=%d max=%.1fms scene=%s enemies=%d player=(%.0f,%.0f) draw=%d nodes=%d resolution=%dx%d window_mode=%d time_scale=%.2f" % [
		Time.get_datetime_string_from_system(), kind,
		Time.get_ticks_msec() - _hitch_start, _hitch_total, _hitch_frames, _hitch_max,
		scene_name, enemies, position.x, position.z,
		int(Performance.get_monitor(Performance.RENDER_TOTAL_DRAW_CALLS_IN_FRAME)),
		int(Performance.get_monitor(Performance.OBJECT_NODE_COUNT)),
		window_size.x, window_size.y, DisplayServer.window_get_mode(), Engine.time_scale]


func _append_log(line: String) -> void:
	DirAccess.make_dir_recursive_absolute("user://logs")
	var file := FileAccess.open(LOG_PATH, FileAccess.READ_WRITE)
	if file == null:
		file = FileAccess.open(LOG_PATH, FileAccess.WRITE)
	if file == null:
		return
	file.seek_end()
	file.store_line(line)
	file.close()


## 供守卫测试读取；显示文本不应成为唯一数据源。
func sampled_ms() -> float:
	return _ema_ms


func sampled_fps() -> float:
	return 1000.0 / maxf(_ema_ms, 0.001)


func sampled_peak_ms() -> float:
	return _peak_display


func sampled_min_fps() -> float:
	return 1000.0 / _min_ms if _min_ms > 0.0 else 0.0


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
