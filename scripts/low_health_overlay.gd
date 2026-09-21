class_name LowHealthOverlay
extends Control
## 低血量屏幕提示：四角低多边形碎片 + 随危险程度加速的心跳。
##
## 目的不是"好看"，而是把"你快死了"变成不用读数字就能感知的信号 ——
## 现有 HUD 只有一个百分比，激烈交火时根本来不及去看。
##
## 三个实现要点：
##   1. 只画直线三角形，不再用柔和径向渐变；它与 HUD 和场景的切面语言一致。
##   2. 心跳同时给【画面脉动】和【音效】两个反馈，且共用同一个相位；
##      只给一个会出现"听见心跳但画面不动"的割裂感。
##   3. 血量越低，心跳越密、vignette 越强 —— 危险程度是一个连续量，不是开关。

const ConfigUtil := preload("res://scripts/game_config.gd")
const AudioUtil := preload("res://scripts/audio_manager.gd")
const UiThemeUtil := preload("res://scripts/ui_theme.gd")

var _threshold := 0.35
var _max_intensity := 0.85
var _rest_intensity := 0.25
var _interval_safe := 1.15
var _interval_critical := 0.45

## 危险程度：0 = 刚到阈值，1 = 濒死。
var _danger := 0.0
var _active := false
var _beat_timer := 0.0
## 心跳脉动的包络（0..1），每次"跳"时置 1 然后衰减。
var _envelope := 0.0
var _shown_intensity := 0.0
var _shown_pulse := 0.0


func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_read_config()
	_push(0.0, 0.0)


func _read_config() -> void:
	_threshold = clampf(ConfigUtil.get_float("ui.low_health_threshold", 0.35), 0.0, 1.0)
	_max_intensity = clampf(ConfigUtil.get_float("ui.vignette_max_intensity", 0.85), 0.0, 1.0)
	_rest_intensity = clampf(ConfigUtil.get_float("ui.vignette_rest_intensity", 0.25), 0.0, 1.0)
	_interval_safe = maxf(ConfigUtil.get_float("ui.heartbeat_interval_safe", 1.15), 0.1)
	_interval_critical = maxf(ConfigUtil.get_float("ui.heartbeat_interval_critical", 0.45), 0.1)


## 每帧由 PlayerHUD 灌入当前生命。上限为 0 时视为该机制关闭。
func update_health(health: float, maximum: float) -> void:
	if maximum <= 0.0:
		_deactivate()
		return
	var ratio := clampf(health / maximum, 0.0, 1.0)
	if ratio >= _threshold:
		_deactivate()
		return
	_active = true
	# danger 0 → 刚好低于阈值；1 → 生命见底。
	_danger = clampf(1.0 - ratio / maxf(_threshold, 0.001), 0.0, 1.0)
	var intensity := lerpf(_rest_intensity, _max_intensity, _danger)
	_push(intensity, _envelope)


func _deactivate() -> void:
	_active = false
	_danger = 0.0
	_beat_timer = 0.0


func _process(delta: float) -> void:
	# 包络只衰减，不在这里重新触发 —— 触发点是"心跳节拍到点"，
	# 这样画面脉动与音效必然同一个相位。
	_envelope = maxf(_envelope - delta * 3.6, 0.0)
	if _active:
		_beat_timer -= delta
		if _beat_timer <= 0.0:
			# 用 += 而不是 = ：即使某帧超时，节拍也不会累积漂移。
			_beat_timer += lerpf(_interval_safe, _interval_critical, _danger)
			_envelope = 1.0
			AudioUtil.play("heartbeat", -7.0)
	var intensity := 0.0
	if _active:
		intensity = lerpf(_rest_intensity, _max_intensity, _danger)
	_push(intensity, _envelope)


func _push(intensity: float, pulse: float) -> void:
	_shown_intensity = intensity
	_shown_pulse = pulse
	queue_redraw()


func _draw() -> void:
	if _shown_intensity <= 0.001:
		return
	var strength := _shown_intensity * (0.72 + 0.28 * _shown_pulse)
	var depth := lerpf(24.0, 76.0, clampf(strength, 0.0, 1.0))
	var color := UiThemeUtil.with_alpha(UiThemeUtil.COLOR_DANGER, strength * 0.48)
	var dark := UiThemeUtil.with_alpha(UiThemeUtil.shade(UiThemeUtil.COLOR_DANGER, -0.35), strength * 0.32)
	_draw_corner(Vector2.ZERO, Vector2(1.0, 1.0), depth, color, dark)
	_draw_corner(Vector2(size.x, 0.0), Vector2(-1.0, 1.0), depth, color, dark)
	_draw_corner(Vector2(0.0, size.y), Vector2(1.0, -1.0), depth, color, dark)
	_draw_corner(size, Vector2(-1.0, -1.0), depth, color, dark)


func _draw_corner(origin: Vector2, direction: Vector2, depth: float, color: Color, dark: Color) -> void:
	var x := Vector2(direction.x, 0.0)
	var y := Vector2(0.0, direction.y)
	draw_colored_polygon(PackedVector2Array([
		origin, origin + x * depth * 1.75, origin + x * depth * 0.72 + y * depth * 0.52,
	]), color)
	draw_colored_polygon(PackedVector2Array([
		origin, origin + y * depth * 1.55, origin + x * depth * 0.55 + y * depth * 0.66,
	]), color)
	draw_colored_polygon(PackedVector2Array([
		origin + x * depth * 0.72 + y * depth * 0.52,
		origin + x * depth * 1.35 + y * depth * 0.18,
		origin + x * depth * 0.92 + y * depth * 0.86,
	]), dark)


## 供探针/调试读取。
func get_danger() -> float:
	return _danger


func is_active() -> bool:
	return _active
