class_name AbilityBar
extends Control
## 左下角技能条。每个技能都是独立的低多边形卡片：按键、图标、名称、冷却状态
## 各占自己的区域，不再把整组信息拼成一行调试式文本。

const UiThemeUtil := preload("res://scripts/ui_theme.gd")
const ConfigUtil := preload("res://scripts/game_config.gd")

const PANEL_WIDTH := 294.0
const PANEL_HEIGHT := 36.0
const CARD_WIDTH := 144.0
const CARD_GAP := 6.0
const KEY_WIDTH := 31.0
const ICON_WIDTH := 29.0
const FONT_KEY := 15
const FONT_LABEL := 12
const FONT_STATE := 9

var _font: Font
var _grenade_remaining := 0.0
var _skill_remaining := 0.0
var _grenade_total := 6.0
var _skill_total := 9.0
var _drawn_key := ""


func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	_font = ThemeDB.fallback_font
	_grenade_total = maxf(ConfigUtil.get_float("abilities.grenade.cooldown", 6.0), 0.01)
	_skill_total = maxf(ConfigUtil.get_float("abilities.skill.cooldown", 9.0), 0.01)


func set_cooldowns(grenade_remaining: float, skill_remaining: float) -> void:
	_grenade_remaining = maxf(grenade_remaining, 0.0)
	_skill_remaining = maxf(skill_remaining, 0.0)
	# 百分之一秒没有视觉意义；按十分之一秒去重，减少常驻 HUD 的重绘。
	var key := "%d|%d" % [roundi(_grenade_remaining * 10.0), roundi(_skill_remaining * 10.0)]
	if key == _drawn_key:
		return
	_drawn_key = key
	queue_redraw()


func _draw() -> void:
	_draw_card(Vector2.ZERO, "E", "手雷", _grenade_remaining, _grenade_total, true)
	_draw_card(
		Vector2(CARD_WIDTH + CARD_GAP, 0.0), "Q", "震地脉冲",
		_skill_remaining, _skill_total, false
	)


func _draw_card(
	position: Vector2, key_text: String, label: String,
	remaining: float, total: float, grenade: bool
) -> void:
	var ready := remaining <= 0.0
	var accent := UiThemeUtil.COLOR_AMMO if grenade else UiThemeUtil.COLOR_ACCENT
	if not ready:
		accent = UiThemeUtil.with_alpha(accent, 0.58)
	var card := Rect2(position, Vector2(CARD_WIDTH, PANEL_HEIGHT))
	UiThemeUtil.draw_plate(
		self, card, accent,
		UiThemeUtil.PLATE_GOLD if grenade else UiThemeUtil.PLATE_SHIELD
	)

	var key_rect := Rect2(position + Vector2(3.0, 3.0), Vector2(KEY_WIDTH, PANEL_HEIGHT - 6.0))
	var key_points := UiThemeUtil.bevel_points(key_rect, 5.0)
	draw_colored_polygon(key_points, UiThemeUtil.COLOR_PAPER)
	draw_polyline(UiThemeUtil.closed(key_points), UiThemeUtil.COLOR_EDGE, 1.0, true)
	var key_w := UiThemeUtil.tracked_width(_font, key_text, FONT_KEY, 0.0)
	UiThemeUtil.draw_tracked(
		self, _font,
		Vector2(key_rect.get_center().x - key_w * 0.5, position.y + 23.0),
		key_text, FONT_KEY, UiThemeUtil.COLOR_INK, 0.0
	)

	var icon_center := position + Vector2(KEY_WIDTH + ICON_WIDTH * 0.5 + 5.0, 17.0)
	if grenade:
		_draw_grenade(icon_center, accent)
	else:
		_draw_pulse(icon_center, accent)

	var text_x := position.x + KEY_WIDTH + ICON_WIDTH + 8.0
	UiThemeUtil.draw_tracked(
		self, _font, Vector2(text_x, position.y + 16.0), label,
		FONT_LABEL, UiThemeUtil.COLOR_BODY if ready else UiThemeUtil.COLOR_DIM, 0.35
	)
	var state := "就绪" if ready else "%.1fs" % remaining
	UiThemeUtil.draw_tracked(
		self, _font, Vector2(text_x, position.y + 29.0), state,
		FONT_STATE, accent, 0.5
	)

	# 冷却条沿卡片下沿回填；就绪时改成三枚短格，避免一直亮一整条抢视线。
	if ready:
		for i in 3:
			var pip := Rect2(
				Vector2(position.x + CARD_WIDTH - 27.0 + float(i) * 7.0, position.y + 26.0),
				Vector2(4.0, 5.0)
			)
			draw_colored_polygon(UiThemeUtil.bevel_points(pip, 1.5), accent)
	else:
		var ratio := 1.0 - clampf(remaining / maxf(total, 0.01), 0.0, 1.0)
		UiThemeUtil.draw_bar(
			self,
			Rect2(Vector2(text_x, position.y + 31.0), Vector2(CARD_WIDTH - (text_x - position.x) - 7.0, 3.0)),
			ratio, accent, 0
		)


func _draw_grenade(center: Vector2, color: Color) -> void:
	var body := PackedVector2Array([
		center + Vector2(-6.0, -4.0), center + Vector2(-2.0, -8.0),
		center + Vector2(4.0, -7.0), center + Vector2(7.0, -2.0),
		center + Vector2(6.0, 6.0), center + Vector2(2.0, 9.0),
		center + Vector2(-5.0, 7.0), center + Vector2(-7.0, 2.0),
	])
	draw_colored_polygon(body, color)
	draw_polyline(UiThemeUtil.closed(body), UiThemeUtil.shade(color, -0.35), 1.0, true)
	var cap := Rect2(center + Vector2(-2.0, -11.0), Vector2(6.0, 4.0))
	draw_colored_polygon(UiThemeUtil.bevel_points(cap, 1.5), UiThemeUtil.COLOR_EDGE_LIGHT)
	draw_line(center + Vector2(3.0, -10.0), center + Vector2(7.0, -13.0), UiThemeUtil.COLOR_EDGE_LIGHT, 1.5, true)


func _draw_pulse(center: Vector2, color: Color) -> void:
	var points := PackedVector2Array([
		center + Vector2(-11.0, 1.0), center + Vector2(-7.0, 1.0),
		center + Vector2(-4.0, -6.0), center + Vector2(-1.0, 7.0),
		center + Vector2(3.0, -7.0), center + Vector2(6.0, 1.0),
		center + Vector2(11.0, 1.0),
	])
	draw_polyline(points, color, 2.0, true)
	draw_line(center + Vector2(-10.0, 6.0), center + Vector2(10.0, 6.0), UiThemeUtil.with_alpha(color, 0.45), 1.0, true)
