class_name WeaponPanel
extends Control
## 左下弹药：大号斜体主读数，备用弹药与独立狙击弹匣降低视觉权重。
const UiThemeUtil := preload("res://scripts/ui_theme.gd")
const PANEL_WIDTH := 210.0
const PANEL_HEIGHT := 100.0
const MARGIN := 26.0
var _font: Font
var _number_font: FontVariation
var _ammo := 0
var _capacity := 30
var _reserve := -1
var _reloading := false
var _reload_ratio := 0.0
var _sniper_ammo := 0
var _sniper_capacity := 0
var _sniper_reload_remaining := 0.0
var _sniper_reserve := -1

func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	_font = UiThemeUtil.get_font()
	_number_font = FontVariation.new()
	_number_font.base_font = load(UiThemeUtil.FONT_PATH) as Font
	_number_font.variation_opentype = {0x77676874: 850}
	_number_font.variation_transform = Transform2D(Vector2(1, 0), Vector2(0.22, 1), Vector2.ZERO)

func update_state(ammo: int, capacity: int, reserve: int, reloading: bool,
		reload_ratio: float, _level: int, _pellets: int, _damage: float) -> void:
	if _ammo == ammo and _capacity == capacity and _reserve == reserve and _reloading == reloading and is_equal_approx(_reload_ratio, reload_ratio):
		return
	_ammo = ammo
	_capacity = capacity
	_reserve = reserve
	_reloading = reloading
	_reload_ratio = reload_ratio
	queue_redraw()

func update_sniper(ammo: int, capacity: int, reload_remaining: float, reserve: int) -> void:
	if _sniper_ammo == ammo and _sniper_capacity == capacity and is_equal_approx(_sniper_reload_remaining, reload_remaining) and _sniper_reserve == reserve:
		return
	_sniper_ammo = ammo
	_sniper_capacity = capacity
	_sniper_reload_remaining = reload_remaining
	_sniper_reserve = reserve
	queue_redraw()

# 保留 HUD 数据入口，成长信息由升级/结算界面承担。
func update_upgrades(_fire_rate: int, _damage: int, _magazine: int) -> void:
	pass

func set_labels(_primary: String, _sniper: String) -> void:
	pass

func _text(font: Font, at: Vector2, text: String, font_size: int, color: Color) -> void:
	draw_string_outline(font, at, text, HORIZONTAL_ALIGNMENT_LEFT, -1, font_size, 3, Color(0.015, 0.025, 0.03, 0.65))
	draw_string(font, at, text, HORIZONTAL_ALIGNMENT_LEFT, -1, font_size, color)

func _draw() -> void:
	if _font == null:
		return
	var origin := Vector2(MARGIN, size.y - MARGIN - PANEL_HEIGHT)
	draw_set_transform(origin)
	var glass := PackedVector2Array([
		Vector2.ZERO, Vector2(PANEL_WIDTH, 0),
		Vector2(PANEL_WIDTH - 24, PANEL_HEIGHT), Vector2(0, PANEL_HEIGHT),
	])
	UiThemeUtil.draw_black_glass(self, glass)
	var white := Color(0.97, 0.98, 0.95)
	var dim := Color(0.84, 0.89, 0.86, 0.78)
	var low := _ammo <= maxi(ceili(_capacity * 0.2), 1)
	var ink := Color(1.0, 0.56, 0.35) if low else white
	var digits := str(_ammo)
	# 所有弹匣数字共用同一条水平基线；斜度只来自字形本身。
	const AMMO_BASELINE := 77.0
	_text(_number_font, Vector2(10, AMMO_BASELINE), digits, 62, ink)
	var number_width := _number_font.get_string_size(digits, HORIZONTAL_ALIGNMENT_LEFT, -1, 62).x
	_text(_font, Vector2(number_width + 23, AMMO_BASELINE), "/ %d" % _capacity, 17, dim)
	var reserve_text := "∞" if _reserve < 0 else str(_reserve)
	_text(_font, Vector2(4, 99), "备弹  " + reserve_text, 11, dim)
	if _reloading:
		_text(_font, Vector2(116, 99), "装填中", 11, white)
		draw_rect(Rect2(4, 84, 176, 3), Color(0.02, 0.035, 0.04, 0.5))
		draw_rect(Rect2(4, 84, 176 * clampf(_reload_ratio, 0, 1), 3), Color(0.5, 0.88, 0.92))
	if _sniper_capacity > 0:
		draw_line(Vector2(5, 12), Vector2(34, 12), dim, 2, true)
		draw_line(Vector2(16, 8), Vector2(25, 8), dim, 2, true)
		draw_line(Vector2(12, 13), Vector2(8, 19), dim, 3, true)
		var sniper_text := "%d / %d" % [_sniper_ammo, _sniper_capacity]
		if _sniper_reload_remaining > 0:
			sniper_text = "%.1fs" % _sniper_reload_remaining
		_text(_font, Vector2(44, 17), sniper_text, 13, dim)
	draw_set_transform(Vector2.ZERO)
