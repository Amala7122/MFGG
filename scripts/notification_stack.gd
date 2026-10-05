class_name NotificationStack
extends Control
## 游戏内即时通知。卡片从右侧滑入，短暂停留后淡出；最多保留三条，避免战斗中
## 形成日志墙。这里只承担“刚发生了什么”，长期状态仍留在固定 HUD 中。

const UiThemeUtil := preload("res://scripts/ui_theme.gd")
const MinimapScript := preload("res://scripts/minimap.gd")

const CARD_WIDTH := 220.0
const CARD_HEIGHT := 32.0
const CARD_GAP := 5.0
const MARGIN_RIGHT := MinimapScript.MARGIN
const TOP := 224.0
const LIFETIME := 2.8
const MAX_ITEMS := 3
const FONT_TEXT := 11

var _font: Font
var _items: Array[Dictionary] = []


func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_font = UiThemeUtil.get_font()
	UiThemeUtil.install_black_glass(self, MAX_ITEMS)
	for glass in get_meta("hud_glass_layers"):
		glass.visible = false
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
	# 时钟/FPS 的高度可能随字号、UI 缩放改变，不能写死在地图内部。
	var top := TOP
	for node_name in ["Minimap", "GameTimePlate", "FpsLabel"]:
		var sibling := get_parent().get_node_or_null(node_name) as Control
		if sibling != null and sibling.visible:
			top = maxf(top, sibling.get_rect().end.y + 10.0)
	for glass in get_meta("hud_glass_layers"):
		glass.visible = false
	for index in _items.size():
		var item := _items[index]
		var age := float(item.get("age", 0.0))
		var enter := clampf(age / 0.18, 0.0, 1.0)
		var leave := clampf((LIFETIME - age) / 0.35, 0.0, 1.0)
		var alpha := minf(enter, leave)
		var offset_x := (1.0 - enter) * 42.0
		var y := top + float(index) * (CARD_HEIGHT + CARD_GAP)
		_draw_card(
			Rect2(Vector2(x + offset_x, y), Vector2(CARD_WIDTH, CARD_HEIGHT)),
			String(item.get("text", "")), item.get("accent", UiThemeUtil.COLOR_ACCENT), alpha, index
		)


func _draw_card(rect: Rect2, text: String, accent: Color, alpha: float, slot: int) -> void:
	var glass: Control = get_meta("hud_glass_layers")[slot]
	glass.visible = true
	glass.set_shape(UiThemeUtil.bevel_points(Rect2(Vector2.ZERO, rect.size), 6), rect.position)
	glass.material.set_shader_parameter("surface_opacity", alpha)
	draw_polyline(UiThemeUtil.closed(UiThemeUtil.bevel_points(rect, 6)), Color(0.85, 0.91, 0.93, 0.32 * alpha), 0.7, true)
	var center := rect.position + Vector2(16, 16)
	draw_colored_polygon(PackedVector2Array([
		center + Vector2(0.0, -6.0), center + Vector2(5.0, 0.0),
		center + Vector2(0.0, 6.0), center + Vector2(-5.0, 0.0),
	]), UiThemeUtil.with_alpha(accent, alpha))
	# 长提示不越过玻璃边缘；完整效果量仍由物品机制应用。
	var display := text
	var limit := rect.size.x - 44.0
	if _font.get_string_size(display, HORIZONTAL_ALIGNMENT_LEFT, -1, FONT_TEXT).x > limit:
		while not display.is_empty() and _font.get_string_size(display + "…", HORIZONTAL_ALIGNMENT_LEFT, -1, FONT_TEXT).x > limit:
			display = display.left(display.length() - 1)
		display += "…"
	draw_string(_font, rect.position + Vector2(32, 20), display, HORIZONTAL_ALIGNMENT_LEFT, limit, FONT_TEXT, Color(0.95, 0.97, 0.98, alpha))
