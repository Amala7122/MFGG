class_name MenuPanel
extends PanelContainer
## 菜单石板：主菜单 / 暂停 / 结算 / 大厅共用的外框。
##
## 【它解决什么】菜单原本是"居中的一堆 Label + 按钮"直接压在半透明的暗幕上 ——
## 文字悬空、按钮是方块，和 HUD 那套切角石板完全不在一个世界。而玩家看到的第一屏
## 恰恰就是主菜单，"原型感"十有八九是先从这儿得来的。
##
## 做法与 HUD 完全一致：走 UiThemeUtil.draw_plate 的同一支画笔。
## 之所以 extends PanelContainer 而不是自己算尺寸：容器会自动按内容撑开，
## 只要把它的 panel 样式盒换成空盒（留出内边距），绘制权就完全归 _draw 了 ——
## 于是"内容自动排版"与"形状自己画"两件事可以同时成立。
##
## 入口动效走 _reveal（0→1）而不是直接 tween 位置：面板的位置由 CenterContainer
## 每帧接管，动它会打架；而 _reveal 驱动的只是"框线由内向外长出来"这一类
## 纯绘制量的变化，不会与任何排版冲突。

const UiThemeUtil := preload("res://scripts/ui_theme.gd")

## 内容内边距（由空样式盒承担，见 _ready）。
##
## 【上下比左右小】窗口默认只有 648 高，而主菜单要塞进标题、操作表、四个按钮。
## 左右放宽不花钱（1152 的宽度用不完），上下每一像素都要跟内容抢 ——
## 所以横向给 54 撑开气场，纵向只给 30。
const PAD_H := 54.0
const PAD_V := 30.0
## 外框内侧再刻一圈细线（"石头上刻的边"），距面板边界的距离。
const FRAME_INSET := 7.0

## 强调色。菜单、暂停、阵亡、肃清各用各的主题色，形状不变 ——
## 同一块石板换个边色就能表达不同语境，这是设计系统省下来的成本。
var accent := UiThemeUtil.COLOR_ACCENT:
	set(value):
		accent = value
		queue_redraw()

## 标题下的分隔线要画在标题下方，而"标题下方是第几像素"只有排完版才知道。
## 与其让调用方算一个改字号就失效的常量，不如把标题控件交进来由这里读它的位置。
var rule_anchor: Control = null

## 0..1，驱动"框线长出来"的进度。1 = 完全就位。
var _reveal := 1.0
## 当前正在跑的入场补间。重复入场时要先掐掉上一个 ——
## 两个补间同时写 _reveal 会互相打架（框线抖成一片）。
var _entrance_tween: Tween


func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	# 用空样式盒顶掉 PanelContainer 自带的底板，但保留它的内边距能力 ——
	# 这样形状归我们画，排版仍由容器做。
	var padding := StyleBoxEmpty.new()
	padding.content_margin_left = PAD_H
	padding.content_margin_right = PAD_H
	padding.content_margin_top = PAD_V
	padding.content_margin_bottom = PAD_V
	add_theme_stylebox_override("panel", padding)
	resized.connect(queue_redraw)


## 换强调色。语义（青=常态 / 红=阵亡 / 金=肃清）由调用方决定，这里只管画。
func configure(color: Color) -> void:
	accent = color


## 入场：面板淡入，同时内侧刻线由内向外"长"出来。
## 【必须能在暂停状态下跑】菜单显示时 get_tree().paused == true，
## 而本节点挂在 GameFlow（process_mode = ALWAYS）之下，所以 Tween 照常推进。
func play_entrance() -> void:
	if _entrance_tween != null:
		_entrance_tween.kill()
	_reveal = 0.0
	modulate.a = 0.0
	queue_redraw()
	_entrance_tween = create_tween()
	_entrance_tween.set_parallel(true)
	_entrance_tween.tween_property(self, "modulate:a", 1.0, 0.22).set_ease(Tween.EASE_OUT)
	_entrance_tween.tween_method(_set_reveal, 0.0, 1.0, 0.44) \
		.set_delay(0.06).set_ease(Tween.EASE_OUT).set_trans(Tween.TRANS_CUBIC)


func _set_reveal(value: float) -> void:
	_reveal = value
	queue_redraw()


func _draw() -> void:
	var rect := Rect2(Vector2.ZERO, size)
	UiThemeUtil.draw_plate(self, rect, accent)
	_draw_engraved_frame(rect)
	_draw_title_rule()


## 内侧刻线：随 _reveal 从"离边界 18 像素"收到 FRAME_INSET。
## 只动距离与透明度，不动形状 —— 于是它读起来是"一块框正在落位"，
## 而不是一个会缩放的矩形在闪。
func _draw_engraved_frame(rect: Rect2) -> void:
	if _reveal <= 0.01:
		return
	var inset := FRAME_INSET + (1.0 - _reveal) * 16.0
	var frame := rect.grow(-inset)
	if frame.size.x <= 2.0 or frame.size.y <= 2.0:
		return
	var alpha := _reveal * 0.34
	draw_polyline(
		UiThemeUtil.closed(UiThemeUtil.bevel_points(frame, UiThemeUtil.BEVEL - 2.0)),
		UiThemeUtil.with_alpha(accent, alpha), 1.0, true
	)


## 标题下的分隔线：以中线为轴向外展开（配合入场动效）。
func _draw_title_rule() -> void:
	if rule_anchor == null or not is_instance_valid(rule_anchor):
		return
	var top := get_global_rect().position.y
	var y := rule_anchor.get_global_rect().end.y - top + 10.0
	if y <= 0.0 or y >= size.y - 8.0:
		return
	var span := size.x - PAD_H * 2.0
	var width := span * clampf(_reveal * 1.35 - 0.35, 0.0, 1.0)
	if width <= 2.0:
		return
	UiThemeUtil.draw_divider(self, Vector2((size.x - width) * 0.5, y), width, accent)
