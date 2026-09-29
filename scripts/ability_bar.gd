class_name AbilityBar
extends Control
## 右下技能：按键与图标，冷却由遮罩和细线表示。
const UiThemeUtil := preload("res://scripts/ui_theme.gd")
const ConfigUtil := preload("res://scripts/game_config.gd")
const PANEL_WIDTH := 134.0
const PANEL_HEIGHT := 58.0
const CARD_WIDTH := 60.0
const CARD_GAP := 14.0
var _font: Font
var _background := StyleBoxFlat.new()
var _grenade_remaining := 0.0
var _skill_remaining := 0.0
var _grenade_total := 6.0
var _skill_total := 9.0
var _drawn_key := ""
var _ready_flash := Vector2.ZERO

func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	_font = UiThemeUtil.get_font()
	_background.bg_color = Color(0.035, 0.055, 0.065, 0.38)
	_background.set_corner_radius_all(4)
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
	_card(Vector2.ZERO, "E", _grenade_remaining, _grenade_total, true, _ready_flash.x)
	_card(Vector2(CARD_WIDTH + CARD_GAP, 0), "Q", _skill_remaining, _skill_total, false, _ready_flash.y)

func _card(at: Vector2, key: String, remaining: float, total: float, grenade: bool, flash: float) -> void:
	var ready := remaining <= 0
	var color := Color(0.97, 0.98, 0.95, 1 if ready else 0.32)
	var box := Rect2(at, Vector2(CARD_WIDTH, PANEL_HEIGHT))
	draw_style_box(_background, box)
	if flash > 0:
		draw_rect(box, Color(0.7, 0.95, 1, flash * 0.35))
	var center := at + Vector2(35, 25)
	if grenade:
		draw_colored_polygon(PackedVector2Array([center + Vector2(-9,-5), center + Vector2(-5,-11), center + Vector2(5,-11), center + Vector2(9,-5), center + Vector2(9,7), center + Vector2(4,12), center + Vector2(-5,12), center + Vector2(-9,6)]), color)
		draw_line(center + Vector2(-1,-13), center + Vector2(5,-13), color, 3, true)
		draw_line(center + Vector2(5,-13), center + Vector2(11,-8), color, 2, true)
	else:
		draw_polyline(PackedVector2Array([center+Vector2(-15,0),center+Vector2(-9,0),center+Vector2(-5,-10),center+Vector2(0,11),center+Vector2(5,-12),center+Vector2(9,0),center+Vector2(15,0)]), color, 2.4, true)
	draw_string(_font, at + Vector2(7, 48), key, HORIZONTAL_ALIGNMENT_LEFT, -1, 12, Color(0.92,0.95,0.93,0.85))
	if not ready:
		draw_rect(Rect2(at + Vector2(7, 53), Vector2(46, 2)), Color(1,1,1,0.1))
		draw_rect(Rect2(at + Vector2(7, 53), Vector2(46 * (1 - clampf(remaining / total, 0, 1)), 2)), Color(0.6,0.85,0.89,0.8))
