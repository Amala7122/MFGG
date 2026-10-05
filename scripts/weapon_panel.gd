class_name WeaponPanel
extends Control
## 左下弹药：大号斜体主读数，备用弹药与独立狙击弹匣降低视觉权重。
const UiThemeUtil := preload("res://scripts/ui_theme.gd")
const PANEL_WIDTH := 210.0
const PANEL_HEIGHT := 96.0
const MARGIN := 26.0
const NUMBER_SLANT := 0.22
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
	UiThemeUtil.install_black_glass(self)
	_number_font = make_number_font()


static func make_number_font() -> FontVariation:
	var font := FontVariation.new()
	font.base_font = load(UiThemeUtil.FONT_PATH) as Font
	font.variation_opentype = {0x77676874: 900}
	# 注意：FontVariation 将分量以 FreeType 的行顺序传入，不等同于 Canvas
	# 使用 Transform2D 的列顺序。x.y 在这里是横向切变：x'=x+s*y, y'=y
	# （字形坐标 y 向上）。误写 y.x 会变成 y'=y+s*x，造成纵向错切。
	font.variation_transform = Transform2D(Vector2(1, NUMBER_SLANT), Vector2(0, 1), Vector2.ZERO)
	return font

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
	draw_string_outline(font, at, text, HORIZONTAL_ALIGNMENT_LEFT, -1, font_size, 1, Color(0.015, 0.025, 0.03, 0.4))
	draw_string(font, at, text, HORIZONTAL_ALIGNMENT_LEFT, -1, font_size, color)

func _draw() -> void:
	if _font == null:
		return
	var origin := Vector2(MARGIN, size.y - MARGIN - PANEL_HEIGHT)
	draw_set_transform(origin)
	var glass := PackedVector2Array([
		Vector2(16, 0), Vector2(PANEL_WIDTH, 0),
		Vector2(PANEL_WIDTH - 58, PANEL_HEIGHT), Vector2(0, PANEL_HEIGHT), Vector2(0, 17),
	])
	UiThemeUtil.draw_black_glass(self, glass, origin)
	var white := Color(0.97, 0.98, 0.95)
	var dim := Color(0.94, 0.95, 0.95, 0.94)
	var low := _ammo <= maxi(ceili(_capacity * 0.2), 1)
	var ink := Color(1.0, 0.56, 0.35) if low else white
	var digits := str(_ammo)
	# 所有弹匣数字共用同一条水平基线；斜度只来自字形本身。
	const AMMO_BASELINE := 63.0
	var digit_size := 60 if digits.length() <= 2 else (46 if digits.length() == 3 else 35)
	_text(_number_font, Vector2(12, AMMO_BASELINE), digits, digit_size, ink)
	var number_width := _number_font.get_string_size(digits, HORIZONTAL_ALIGNMENT_LEFT, -1, digit_size).x
	_text(_number_font, Vector2(number_width + 20, AMMO_BASELINE), "/ %d" % _capacity, 23, dim)
	var reserve_text := "∞" if _reserve < 0 else str(_reserve)
	_text(_font, Vector2(13, 86), "备弹  " + reserve_text, 14, dim)
	if _reloading:
		_text(_font, Vector2(113, 85), "装填", 10, white)
		UiThemeUtil.draw_pill(self, Rect2(13, 69, 150, 2), Color(1, 1, 1, 0.15))
		UiThemeUtil.draw_pill(self, Rect2(13, 69, 150 * clampf(_reload_ratio, 0, 1), 2), white)
	draw_set_transform(Vector2.ZERO)
