class_name HitMarker
extends Control
## 命中标记：准星中央四条斜短线，命中时闪现、击杀时变红。
## 纯 _draw() 绘制，铺满父容器（放在 AimUI 这个 CanvasLayer 下）。

const ARM_OFFSET := 8.0
const ARM_LENGTH := 12.0
const LINE_WIDTH := 3.2
const FADE_SPEED := 3.4
const UiThemeUtil := preload("res://scripts/ui_theme.gd")

var _intensity := 0.0
var _kill := false
var _headshot := false


func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)


## 触发一次命中闪现；is_kill 为 true 时用击杀色，is_headshot 为 true 时用爆头标记。
func flash(is_kill: bool = false, is_headshot: bool = false) -> void:
	_kill = is_kill
	_headshot = is_headshot
	_intensity = 1.0
	queue_redraw()



func is_active() -> bool:
	return _intensity > 0.0


func _process(delta: float) -> void:
	if _intensity <= 0.0:
		return
	_intensity = maxf(_intensity - delta * FADE_SPEED, 0.0)
	queue_redraw()


func _draw() -> void:
	if _intensity <= 0.0:
		return
	var center := size * 0.5
	var base := UiThemeUtil.COLOR_DANGER if _kill else (Color(1.0, 0.85, 0.22, 1.0) if _headshot else UiThemeUtil.COLOR_PAPER)
	var color := Color(base.r, base.g, base.b, _intensity)
	var width := LINE_WIDTH * (0.65 + _intensity * 0.5) * (1.25 if _headshot else 1.0)
	var reach := ARM_OFFSET + ARM_LENGTH * (0.5 + _intensity * 0.5) * (1.2 if _headshot else 1.0)

	var directions: Array[Vector2] = [
		Vector2(1.0, 1.0), Vector2(-1.0, 1.0), Vector2(1.0, -1.0), Vector2(-1.0, -1.0)
	]
	for direction in directions:
		draw_line(center + direction * ARM_OFFSET, center + direction * reach, color, width, true)
