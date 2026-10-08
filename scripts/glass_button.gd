extends Button
## 原生按钮的鼠标/键盘逻辑 + HUD 黑玻璃，不绘制旧铜边样式盒。
const UiThemeUtil := preload("res://scripts/ui_theme.gd")

func _ready() -> void:
	UiThemeUtil.install_black_glass(self)
	for state in ["normal", "hover", "pressed", "disabled", "focus"]:
		var empty := StyleBoxEmpty.new()
		empty.content_margin_left = 18
		empty.content_margin_right = 18
		empty.content_margin_top = 8
		empty.content_margin_bottom = 8
		add_theme_stylebox_override(state, empty)
	for state in ["font_color", "font_hover_color", "font_pressed_color", "font_focus_color"]:
		add_theme_color_override(state, Color(0.96, 0.97, 0.98))
	add_theme_font_size_override("font_size", 19)
	mouse_entered.connect(queue_redraw)
	mouse_exited.connect(queue_redraw)
	focus_entered.connect(queue_redraw)
	focus_exited.connect(queue_redraw)
	button_down.connect(queue_redraw)
	button_up.connect(queue_redraw)
	resized.connect(queue_redraw)

func _draw() -> void:
	var shape := UiThemeUtil.bevel_points(Rect2(Vector2.ZERO, size), 8)
	UiThemeUtil.draw_black_glass(self, shape)
	if not disabled and (has_focus() or is_hovered()):
		draw_colored_polygon(shape, Color(1, 1, 1, 0.07 if not is_pressed() else 0.13))
		# 单一短标记表示选中，不加包边或外发光。
		draw_line(Vector2(13, size.y * 0.30), Vector2(13, size.y * 0.70), Color(0.92, 0.97, 1), 2, true)
