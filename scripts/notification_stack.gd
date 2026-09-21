class_name NotificationStack
extends Control
## 游戏内即时通知。卡片从右侧滑入，短暂停留后淡出；最多保留三条，避免战斗中
## 形成日志墙。这里只承担“刚发生了什么”，长期状态仍留在固定 HUD 中。

const UiThemeUtil := preload("res://scripts/ui_theme.gd")

const CARD_WIDTH := 220.0
const CARD_HEIGHT := 32.0
const CARD_GAP := 5.0
const MARGIN_RIGHT := 18.0
const TOP := 190.0
const LIFETIME := 2.8
const MAX_ITEMS := 3
const FONT_TEXT := 11

var _font: Font
var _items: Array[Dictionary] = []


func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_font = ThemeDB.fallback_font
	set_process(false)


func push_notice(text: String, accent: Color = UiThemeUtil.COLOR_ACCENT) -> void:
	if text.is_empty():
		return
	_items.push_front({"text": text, "accent": accent, "age": 0.0})
	while _items.size() > MAX_ITEMS:
		_items.pop_back()
	set_process(true)
	queue_redraw()


func _process(delta: float) -> void:
	var alive: Array[Dictionary] = []
	for item in _items:
		var entry := item.duplicate()
		entry["age"] = float(entry.get("age", 0.0)) + delta
		if float(entry["age"]) < LIFETIME:
			alive.append(entry)
	_items = alive
	queue_redraw()
	if _items.is_empty():
		set_process(false)


func _draw() -> void:
	var x := size.x - MARGIN_RIGHT - CARD_WIDTH
	for index in _items.size():
		var item := _items[index]
		var age := float(item.get("age", 0.0))
		var enter := clampf(age / 0.18, 0.0, 1.0)
		var leave := clampf((LIFETIME - age) / 0.35, 0.0, 1.0)
		var alpha := minf(enter, leave)
		var offset_x := (1.0 - enter) * 42.0
		var y := TOP + float(index) * (CARD_HEIGHT + CARD_GAP)
		_draw_card(
			Rect2(Vector2(x + offset_x, y), Vector2(CARD_WIDTH, CARD_HEIGHT)),
			String(item.get("text", "")), item.get("accent", UiThemeUtil.COLOR_ACCENT), alpha
		)


func _draw_card(rect: Rect2, text: String, accent: Color, alpha: float) -> void:
	var faded := UiThemeUtil.with_alpha(accent, accent.a * alpha)
	UiThemeUtil.draw_plate(self, rect, faded, UiThemeUtil.PLATE_CREAM)
	var icon_rect := Rect2(rect.position + Vector2(4.0, 4.0), Vector2(24.0, 24.0))
	var icon := UiThemeUtil.bevel_points(icon_rect, 6.0)
	draw_colored_polygon(icon, UiThemeUtil.with_alpha(accent, 0.28 * alpha))
	draw_polyline(UiThemeUtil.closed(icon), UiThemeUtil.with_alpha(accent, 0.82 * alpha), 1.0, true)
	var center := icon_rect.get_center()
	draw_colored_polygon(PackedVector2Array([
		center + Vector2(0.0, -6.0), center + Vector2(5.0, 0.0),
		center + Vector2(0.0, 6.0), center + Vector2(-5.0, 0.0),
	]), UiThemeUtil.with_alpha(accent, alpha))
	UiThemeUtil.draw_tracked(
		self, _font, Vector2(rect.position.x + 35.0, rect.position.y + 20.0),
		text, FONT_TEXT, UiThemeUtil.with_alpha(UiThemeUtil.COLOR_INK, alpha), 0.35
	)
