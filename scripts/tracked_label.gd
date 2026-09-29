class_name TrackedLabel
extends Control
## 带字距的小号标签。整个 UI 的"副标题 / 分区名"都用它。
##
## 【为什么不用 Label】Label 画不出字距，而"小号 + 宽字距"是不引入字体资源的
## 前提下，让系统默认字体看起来被设计过的最省力手段。HUD 里已经有 draw_tracked
## 这个原语（武器面板的分类名、各面板的小标题都在用），菜单这边却还是普通 Label ——
## 于是同一款游戏里出现了两种"小标题"，正是"拼凑感"的来源之一。
##
## 【为什么是 Control 而不是继续在 MenuPanel 里画】文字要参与 VBoxContainer 的
## 排版（居中、上下留白），而容器只认控件。自己测量宽度并实现
## _get_minimum_size()，就能像 Label 一样被摆布。
##
## 它不挂主题变体：TrackedLabel 的字号 / 颜色是"这一处的排版决定"，
## 不是"全局一致的设计令牌"，所以由调用点直接给（与 HUD 各面板的写法一致）。

const UiThemeUtil := preload("res://scripts/ui_theme.gd")

## 文本。
var text := "":
	set(value):
		if text == value:
			return
		text = value
		update_minimum_size()
		queue_redraw()

## 字号与颜色。
var font_size := 12:
	set(value):
		if font_size == value:
			return
		font_size = value
		update_minimum_size()
		queue_redraw()

var color := UiThemeUtil.COLOR_DIM:
	set(value):
		color = value
		queue_redraw()

## 字距（像素）。0 = 就是普通文本。
var tracking := 2.4:
	set(value):
		if tracking == value:
			return
		tracking = value
		update_minimum_size()
		queue_redraw()

var alignment := HORIZONTAL_ALIGNMENT_CENTER:
	set(value):
		alignment = value
		queue_redraw()

var _font: Font


func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	# _font 在属性 setter 跑的时候还是 null（那些 setter 往往在 add_child 之前被调用），
	# 所以那一刻算出来的最小尺寸是 0。拿到字体后必须重算一次，否则控件被排成 0 宽。
	_font = UiThemeUtil.get_font()
	update_minimum_size()


func _get_minimum_size() -> Vector2:
	if _font == null:
		return Vector2.ZERO
	# 高度按字号给足：draw_string 的 pos 是基线，不给余量的话下伸部会被切掉。
	return Vector2(UiThemeUtil.tracked_width(_font, text, font_size, tracking), float(font_size) * 1.4)


func _draw() -> void:
	if _font == null or text.is_empty():
		return
	var width := UiThemeUtil.tracked_width(_font, text, font_size, tracking)
	var x := 0.0
	match alignment:
		HORIZONTAL_ALIGNMENT_CENTER:
			x = (size.x - width) * 0.5
		HORIZONTAL_ALIGNMENT_RIGHT:
			x = size.x - width
	UiThemeUtil.draw_tracked(
		self, _font, Vector2(x, size.y * 0.5 + float(font_size) * 0.36),
		text, font_size, color, tracking
	)
