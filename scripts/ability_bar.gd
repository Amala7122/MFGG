class_name AbilityBar
extends Control
## 右下技能：按键与图标，冷却由遮罩和细线表示。
const UiThemeUtil := preload("res://scripts/ui_theme.gd")
const ConfigUtil := preload("res://scripts/game_config.gd")
## 技能组总宽严格等于小地图边长；PlayerHUD 负责让 Q 的最右点与地图右边对齐。
const PANEL_WIDTH := 124.0
const PANEL_HEIGHT := 36.0
const E_CARD_WIDTH := 56.0
const Q_CARD_WIDTH := 64.0
const CARD_GAP := 4.0
var _font: Font
var _grenade_remaining := 0.0
var _skill_remaining := 0.0
var _grenade_total := 6.0
var _skill_total := 9.0
var _drawn_key := ""
var _ready_flash := Vector2.ZERO

func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	_font = UiThemeUtil.get_font()
	_grenade_total = maxf(ConfigUtil.get_float("abilities.grenade.cooldown", 6.0), 0.01)
	_skill_total = maxf(ConfigUtil.get_float("abilities.skill.cooldown", 9.0), 0.01)
	set_process(false)

func set_cooldowns(grenade_remaining: float, skill_remaining: float) -> void:
	if _grenade_remaining > 0 and grenade_remaining <= 0:
		_ready_flash.x = 0.5
	if _skill_remaining > 0 and skill_remaining <= 0:
		_ready_flash.y = 0.5
	_grenade_remaining = maxf(grenade_remaining, 0)
	_skill_remaining = maxf(skill_remaining, 0)
	set_process(_ready_flash.length_squared() > 0)
	var key := "%d|%d" % [ceili(_grenade_remaining * 10), ceili(_skill_remaining * 10)]
	if key != _drawn_key:
		_drawn_key = key
		queue_redraw()

func _process(delta: float) -> void:
	_ready_flash = Vector2(maxf(0, _ready_flash.x - delta), maxf(0, _ready_flash.y - delta))
	queue_redraw()
	set_process(_ready_flash.length_squared() > 0)

func _draw() -> void:
	_card(Vector2.ZERO, E_CARD_WIDTH, "E", _grenade_remaining, _grenade_total, true, _ready_flash.x)
	_card(Vector2(E_CARD_WIDTH + CARD_GAP, 0), Q_CARD_WIDTH, "Q", _skill_remaining, _skill_total, false, _ready_flash.y)

func _card(at: Vector2, width: float, key: String, remaining: float, total: float, grenade: bool, flash: float) -> void:
	var ready := remaining <= 0
	var color := Color(0.97, 0.98, 0.95, 1 if ready else 0.32)
	var points: PackedVector2Array
	if grenade:
		# E 是规整平行四边形；两个斜边方向一致。
		points = PackedVector2Array([
			at + Vector2(8, 0), at + Vector2(width, 0),
			at + Vector2(width - 8, PANEL_HEIGHT), at,
		])
	else:
		# Q 保留与左下弹药板相同的“直左边 + 斜右边”轮廓。
		points = PackedVector2Array([
			at, at + Vector2(width, 0),
			at + Vector2(width - 10, PANEL_HEIGHT), at + Vector2(0, PANEL_HEIGHT),
		])
	UiThemeUtil.draw_black_glass(self, points)
	if flash > 0:
		draw_colored_polygon(points, Color(1.0, 1.0, 1.0, flash * 0.14))
	# 按键与图标同行，避免对角排布留下大块空白。
	var center := at + Vector2(width - 16, 17)
	if grenade:
		draw_colored_polygon(PackedVector2Array([center + Vector2(-7,-4), center + Vector2(-4,-9), center + Vector2(4,-9), center + Vector2(7,-4), center + Vector2(7,6), center + Vector2(3,10), center + Vector2(-4,10), center + Vector2(-7,5)]), color)
		draw_line(center + Vector2(-1,-11), center + Vector2(4,-11), color, 2.4, true)
		draw_line(center + Vector2(4,-11), center + Vector2(8,-7), color, 1.8, true)
	else:
		draw_polyline(PackedVector2Array([center+Vector2(-12,0),center+Vector2(-7,0),center+Vector2(-4,-8),center+Vector2(0,9),center+Vector2(4,-9),center+Vector2(7,0),center+Vector2(12,0)]), color, 2.1, true)
	var key_size := _font.get_string_size(key, HORIZONTAL_ALIGNMENT_LEFT, -1, 13)
	draw_string(_font, at + Vector2(12 - key_size.x * 0.5, 22), key, HORIZONTAL_ALIGNMENT_LEFT, -1, 13, Color(0.92,0.95,0.93,0.9))
	draw_line(at + Vector2(24, 7), at + Vector2(24, 29), Color(1,1,1,0.10), 1.0)
	if not ready:
		var cooldown_width := width - 14.0
		draw_rect(Rect2(at + Vector2(4, 32), Vector2(cooldown_width, 2)), Color(1,1,1,0.1))
		draw_rect(Rect2(at + Vector2(4, 32), Vector2(cooldown_width * (1 - clampf(remaining / total, 0, 1)), 2)), Color(0.78,0.84,0.84,0.82))
