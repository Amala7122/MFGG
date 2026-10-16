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
## 震地脉冲的点数。<0 表示调用方没提供（按旧的两态显示处理）。
var _skill_charges := -1
var _skill_charges_max := 0
var _drawn_key := ""
var _grenade_stock: Dictionary = {}


func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	UiThemeUtil.install_black_glass(self, 2)
	_font = UiThemeUtil.get_font()
	_grenade_total = maxf(ConfigUtil.get_float("abilities.grenade.cooldown", 6.0), 0.01)
	_skill_total = maxf(ConfigUtil.get_float("abilities.skill.cooldown", 9.0), 0.01)


func set_cooldowns(
	grenade_remaining: float, skill_remaining: float,
	skill_charges: int = -1, skill_charges_max: int = 0,
	grenade_stock: Dictionary = {}
) -> void:
	_grenade_remaining = maxf(grenade_remaining, 0.0)
	_skill_remaining = maxf(skill_remaining, 0.0)
	_skill_charges = skill_charges
	_skill_charges_max = maxi(skill_charges_max, 0)
	_grenade_stock = grenade_stock
	# 百分之一秒没有视觉意义；按十分之一秒去重，减少常驻 HUD 的重绘。
	var key := "%d|%d|%d|%d" % [
		roundi(_grenade_remaining * 10.0), roundi(_skill_remaining * 10.0),
		_skill_charges, _skill_charges_max
	]
	key += "|%s|%d|%d|%d" % [_grenade_stock.get("mode", "cooldown"), int(_grenade_stock.get("charges", -1)),
		int(_grenade_stock.get("capacity", 0)), roundi(float(_grenade_stock.get("recharge_remaining", 0.0)) * 10.0)]
	if key == _drawn_key:
		return
	_drawn_key = key
	queue_redraw()


func _draw() -> void:
	var reserve: bool = _grenade_stock.get("mode", "cooldown") == "reserve"
	_draw_card(Vector2.ZERO, "E", "手雷 %d/%d" % [_grenade_stock.charges, _grenade_stock.capacity] if reserve else "手雷",
		_grenade_remaining, float(_grenade_stock.get("throw_interval", _grenade_total)), true,
		int(_grenade_stock.charges) if reserve else -1, int(_grenade_stock.capacity) if reserve else 0)
	_draw_card(
		Vector2(CARD_WIDTH + CARD_GAP, 0.0), "Q", "震地脉冲",
		_skill_remaining, _skill_total, false, _skill_charges, _skill_charges_max
	)


func _draw_card(
	position: Vector2, key_text: String, label: String,
	remaining: float, total: float, grenade: bool,
	charges: int = -1, charges_max: int = 0
) -> void:
	# 有点数系统时，"就绪"还要看点数：没点数就是没得放，不能显示成绿的。
	var ready := remaining <= 0.0 and (charges < 0 or charges > 0)
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
	draw_polyline(UiThemeUtil.closed(key_points), UiThemeUtil.COLOR_EDGE, UiThemeUtil.HAIRLINE_WIDTH, true)
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
	if grenade and _grenade_stock.get("mode", "cooldown") == "reserve":
		state = "投 %.1fs" % remaining if remaining > 0.0 else "可投" if charges > 0 else "空"
		var recharge := float(_grenade_stock.recharge_remaining)
		var refill := "补 %.1fs" % recharge if charges < charges_max else "已满"
		UiThemeUtil.draw_tracked(self, _font, Vector2(text_x, position.y + 29.0), state, FONT_STATE, accent, 0.0)
		var refill_width := UiThemeUtil.tracked_width(_font, refill, FONT_STATE, 0.0)
		UiThemeUtil.draw_tracked(self, _font, Vector2(position.x + CARD_WIDTH - 7.0 - refill_width, position.y + 29.0), refill, FONT_STATE, accent, 0.0)
		if charges < charges_max:
			UiThemeUtil.draw_bar(self, Rect2(Vector2(text_x, position.y + 32.0), Vector2(CARD_WIDTH - (text_x - position.x) - 7.0, 2.0)),
				1.0 - clampf(recharge / maxf(float(_grenade_stock.recharge_seconds), 0.01), 0.0, 1.0), accent, 0)
		return
	if charges >= 0:
		# 有点数时，"就绪"之外还要读得出还剩几次。
		if remaining > 0.0:
			state = "%.1fs" % remaining
		elif charges <= 0:
			state = "回充中"
		else:
			state = "×%d" % charges
	UiThemeUtil.draw_tracked(
		self, _font, Vector2(text_x, position.y + 29.0), state,
		FONT_STATE, accent, 0.5
	)

	# 点数格：亮 = 可用，暗 = 已用。格数就是这一场能连着放几次（Q 是 3 次）。
	if charges >= 0:
		var slots := maxi(charges_max, 1)
		for i in slots:
			var pip := Rect2(
				Vector2(position.x + CARD_WIDTH - 8.0 - float(slots - 1 - i) * 8.0, position.y + 25.0),
				Vector2(5.0, 6.0)
			)
			draw_colored_polygon(
				UiThemeUtil.bevel_points(pip, 1.5),
				accent if i < charges else UiThemeUtil.with_alpha(UiThemeUtil.COLOR_DIM, 0.30)
			)
		if remaining > 0.0:
			var ratio := 1.0 - clampf(remaining / maxf(total, 0.01), 0.0, 1.0)
			UiThemeUtil.draw_bar(
				self,
				Rect2(Vector2(text_x, position.y + 31.0), Vector2(CARD_WIDTH - (text_x - position.x) - 30.0, 3.0)),
				ratio, accent, 0
			)
		return

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
	draw_polyline(UiThemeUtil.closed(body), UiThemeUtil.shade(color, -0.35), UiThemeUtil.HAIRLINE_WIDTH, true)
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
	draw_line(center + Vector2(-10.0, 6.0), center + Vector2(10.0, 6.0), UiThemeUtil.with_alpha(color, 0.45), UiThemeUtil.HAIRLINE_WIDTH, true)

