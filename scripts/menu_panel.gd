class_name MenuPanel
extends PanelContainer
## 菜单与 HUD 共用中性黑玻璃；容器排版和按钮输入仍由 Godot 管理。
const UiThemeUtil := preload("res://scripts/ui_theme.gd")
const PAD_H := 38.0
const PAD_V := 30.0
var _entrance_tween: Tween

func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	var padding := StyleBoxEmpty.new()
	padding.content_margin_left = PAD_H
	padding.content_margin_right = PAD_H
	padding.content_margin_top = PAD_V
	padding.content_margin_bottom = PAD_V
	add_theme_stylebox_override("panel", padding)
	UiThemeUtil.install_black_glass(self)
	resized.connect(queue_redraw)

func play_entrance() -> void:
	if _entrance_tween != null:
		_entrance_tween.kill()
	_set_reveal(0.0)
	_entrance_tween = create_tween()
	_entrance_tween.tween_method(_set_reveal, 0.0, 1.0, 0.22).set_ease(Tween.EASE_OUT)

func _set_reveal(value: float) -> void:
	modulate.a = value
	queue_redraw()

func _draw() -> void:
	UiThemeUtil.draw_black_glass(self, UiThemeUtil.bevel_points(Rect2(Vector2.ZERO, size), 12))
