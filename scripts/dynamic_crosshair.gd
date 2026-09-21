class_name DynamicCrosshair
extends Control
## 动态扩散准星：四条线段随射击/移动扩散，瞄准时收拢，换弹时旋转提示。
## 纯 _draw() 绘制，铺满父容器（放在 AimUI 这个 CanvasLayer 下）。

const LINE_WIDTH := 2.4
const LINE_LENGTH := 9.0
const MIN_GAP := 6.5
const MAX_GAP := 26.0
const UiThemeUtil := preload("res://scripts/ui_theme.gd")

## 由武器 bloom 驱动的扩散比例 0..1。
var spread := 0.0
var aiming := false
var reloading := false

var _reload_spin := 0.0


func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)


func _process(delta: float) -> void:
	if reloading:
		_reload_spin = fmod(_reload_spin + delta * TAU * 1.15, TAU)
	elif not is_zero_approx(_reload_spin):
		_reload_spin = 0.0
	queue_redraw()


func _draw() -> void:
	var center := size * 0.5
	var gap := lerpf(MIN_GAP, MAX_GAP, clampf(spread, 0.0, 1.0))
	if aiming:
		gap *= 0.6
	var color := UiThemeUtil.COLOR_AMMO if reloading else UiThemeUtil.COLOR_TITLE
	if aiming:
		color = UiThemeUtil.COLOR_ACCENT
	var width := LINE_WIDTH * (1.0 + clampf(spread, 0.0, 1.0) * 0.35)
	var directions: Array[Vector2] = [Vector2.UP, Vector2.DOWN, Vector2.LEFT, Vector2.RIGHT]
	for direction in directions:
		var rotated := direction.rotated(_reload_spin)
		draw_line(center + rotated * gap, center + rotated * (gap + LINE_LENGTH), color, width, true)
	if aiming:
		var diamond := PackedVector2Array([
			center + Vector2(0.0, -2.8), center + Vector2(2.8, 0.0),
			center + Vector2(0.0, 2.8), center + Vector2(-2.8, 0.0),
		])
		draw_polyline(UiThemeUtil.closed(diamond), color, 1.4, true)
