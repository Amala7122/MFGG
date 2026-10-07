class_name SpeedLinesOverlay
extends Control
## 冲刺速度线与风洞视觉特效（Speed lines / Wind warp）。
## 纯 _draw() 绘制，铺满父容器（挂在 AimUI 下，位于准星与信息板底层）。
##
## 表现：玩家按住 Shift 疾跑时，屏幕四周边缘涌现指向屏幕中心的动态辐射速度线条，
## 中心瞄准区域保持 100% 净空，绝不遮挡准星与目标视线。

const UiThemeUtil := preload("res://scripts/ui_theme.gd")

const LINE_COUNT := 22
const CLEAR_RADIUS_RATIO := 0.38
const FADE_IN_SPEED := 5.0
const FADE_OUT_SPEED := 6.5

var _sprint_active := false
var _intensity := 0.0
var _rng := RandomNumberGenerator.new()


func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_rng.randomize()


func set_sprint(active: bool) -> void:
	_sprint_active = active


func _process(delta: float) -> void:
	if _sprint_active:
		_intensity = minf(_intensity + delta * FADE_IN_SPEED, 1.0)
	else:
		_intensity = maxf(_intensity - delta * FADE_OUT_SPEED, 0.0)

	if _intensity > 0.001:
		queue_redraw()


func _draw() -> void:
	if _intensity <= 0.008:
		return

	var center := size * 0.5
	var diag_radius := center.length()
	var clear_radius := minf(size.x, size.y) * CLEAR_RADIUS_RATIO

	# 随机绘制辐射速度流线
	for i in range(LINE_COUNT):
		# 基础角度加上小幅度的动态抖动
		var base_angle := float(i) / float(LINE_COUNT) * TAU
		var jitter := _rng.randf_range(-0.06, 0.06)
		var angle := base_angle + jitter
		var dir := Vector2(cos(angle), sin(angle))

		# 线段从边缘向内延伸，但停在净空安全区之外
		var outer_dist := diag_radius * _rng.randf_range(0.85, 1.02)
		var inner_dist := lerpf(diag_radius * 0.52, clear_radius, _rng.randf_range(0.0, 0.85))
		
		var p_start := center + dir * outer_dist
		var p_end := center + dir * inner_dist

		# 透明度由边缘衰减与全局强度调制，淡青白科技流光
		var alpha := _rng.randf_range(0.12, 0.28) * _intensity
		var color := Color(0.85, 0.95, 1.0, alpha)
		var width := _rng.randf_range(1.4, 2.6)

		draw_line(p_start, p_end, color, width, true)
