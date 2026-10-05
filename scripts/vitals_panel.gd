class_name VitalsPanel
extends Control
## 下方中央生命与护盾：半透明底、连续色条，保留伤害残影与低血量反馈。

const UiThemeUtil := preload("res://scripts/ui_theme.gd")
const HEART_ICON := preload("res://assets/hud/heart.svg")
const SHIELD_ICON := preload("res://assets/hud/shield.svg")

## 面板尺寸。PlayerHUD 用它来排布（不想让两处各写一份坐标）。
const PANEL_WIDTH := 242.0
const PANEL_HEIGHT := 50.0

## 残影：停留时间 + 之后每秒回落的比例。停留是为了让"刚掉了多少"看得见，
## 否则残影在受击的同一帧就开始缩，等于没画。
const GHOST_HOLD := 0.32
const GHOST_SPEED := 0.55
## 生命低于该比例开始呼吸。
const LOW_RATIO := 0.3

# ---------------------------------------------------------------- 版面度量
# 全部相对面板左上角，画的时候只读这些常量，不在 _draw 里现算。
const ROW_HEIGHT := 18.0
const ROW_GAP := 4.0
const ICON_WIDTH := 46.0
const VALUE_WIDTH := 47.0
const BAR_LEFT := ICON_WIDTH + VALUE_WIDTH + 6.0
## 右留白覆盖底板斜边，护盾条不越过玻璃轮廓。
const BAR_RIGHT_PAD := 24.0
const BAR_TOP_INSET := 4.0
const BAR_HEIGHT := 9.0
const FONT_VALUE := 10

var _font: Font

var _health := 0.0
var _health_max := 0.0
var _shield := 0.0
var _shield_max := 0.0

## 当前比例与残影比例（0..1）。
var _ratio := 1.0
var _ghost := 1.0
var _ghost_hold := 0.0
var _initialized := false

## 已画出去的四舍五入读数。血条本身按浮点比例判断变化，读数按整数判断 ——
## 两者分开是因为"生命在自动回复"时比例每帧都在动，但显示的数字十几帧才变一次。
var _shown_health := -1
var _shown_health_max := -1
var _shown_shield := -1
var _shown_shield_max := -1


func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	set_process(true)
	_font = UiThemeUtil.get_font()
	UiThemeUtil.install_black_glass(self)


func _process(delta: float) -> void:
	# 残影只在"掉血"之后往回追；回血时直接跟上（见 set_health）。
	if _ghost_hold > 0.0:
		_ghost_hold = maxf(_ghost_hold - delta, 0.0)
		queue_redraw()
	elif _ghost > _ratio + 0.0005:
		_ghost = maxf(_ratio, _ghost - GHOST_SPEED * delta)
		queue_redraw()
	# 呼吸是连续动效，低血量期间必须每帧重绘（这也是它只在 30% 以下才开的原因）。
	if is_low():
		queue_redraw()


# ---------------------------------------------------------------- 数据绑定

func set_health(current: float, maximum: float) -> void:
	_health = current
	_health_max = maximum
	var safe := maxf(maximum, 0.001)
	var ratio := clampf(current / safe, 0.0, 1.0)
	if not _initialized:
		# 首帧直接把残影对准实际值：否则开局第一条血会看到一次假的"掉血"。
		_initialized = true
		_ratio = ratio
		_ghost = ratio
		var ints := _health_ints()
		_shown_health = ints[0]
		_shown_health_max = ints[1]
		queue_redraw()
		return
	var changed := false
	if absf(ratio - _ratio) > 0.0005:
		if ratio < _ratio:
			_ghost_hold = GHOST_HOLD
		_ratio = ratio
		changed = true
	var ints := _health_ints()
	if ints[0] != _shown_health or ints[1] != _shown_health_max:
		_shown_health = ints[0]
		_shown_health_max = ints[1]
		changed = true
	if changed:
		queue_redraw()


func set_shield(current: float, maximum: float) -> void:
	_shield = current
	_shield_max = maximum
	var ints := _shield_ints()
	if ints[0] == _shown_shield and ints[1] == _shown_shield_max:
		return
	_shown_shield = ints[0]
	_shown_shield_max = ints[1]
	queue_redraw()


## 护盾上限 <= 0 表示整套护盾机制被配置关掉了（见 game_config 的 shield_max）。
func has_shield() -> bool:
	return _shield_max > 0.0


func shield_ratio() -> float:
	if _shield_max <= 0.0:
		return 0.0
	return clampf(_shield / _shield_max, 0.0, 1.0)


func is_low() -> bool:
	return _ratio < LOW_RATIO and _health_max > 0.0


func _health_ints() -> Array:
	return [ceili(maxf(_health, 0.0)), ceili(maxf(_health_max, 0.0))]


func _shield_ints() -> Array:
	return [ceili(maxf(_shield, 0.0)), ceili(maxf(_shield_max, 0.0))]


# ---------------------------------------------------------------- 绘制

func _draw() -> void:
	var glass := PackedVector2Array([
		Vector2(24, 0), Vector2(size.x, 0),
		Vector2(size.x - 24, size.y), Vector2(0, size.y),
	])
	UiThemeUtil.draw_black_glass(self, glass)
	var accent := UiThemeUtil.COLOR_HEALTH
	if is_low():
		accent = UiThemeUtil.shade(UiThemeUtil.COLOR_HEALTH, _pulse() * 0.30)
	_draw_health(6.0, accent)
	_draw_shield(6.0 + ROW_HEIGHT + ROW_GAP)


func _draw_health(top: float, accent: Color) -> void:
	var value_color := UiThemeUtil.shade(UiThemeUtil.COLOR_HEALTH, 0.5)
	if is_low():
		value_color = UiThemeUtil.shade(UiThemeUtil.COLOR_DANGER, _pulse() * 0.45)
	var text := "——"
	if _health_max > 0.0:
		text = "%d / %d" % [_shown_health, _shown_health_max]
	var fill := UiThemeUtil.COLOR_HEALTH
	if is_low():
		fill = UiThemeUtil.COLOR_DANGER
	_draw_stat_row(top, text, value_color, fill, _ratio, _ghost, true, accent)


func _draw_shield(top: float) -> void:
	var text := "未启用"
	var value_color := UiThemeUtil.with_alpha(UiThemeUtil.COLOR_DIM, 0.6)
	if has_shield():
		text = "%d / %d" % [_shown_shield, _shown_shield_max]
		value_color = UiThemeUtil.shade(UiThemeUtil.COLOR_SHIELD, 0.35)
		if _shield <= 0.0:
			value_color = UiThemeUtil.with_alpha(UiThemeUtil.COLOR_DANGER, 0.85)
	_draw_stat_row(
		top, text, value_color, UiThemeUtil.COLOR_SHIELD, shield_ratio(), -1.0,
		false, UiThemeUtil.COLOR_SHIELD
	)


## 每行严格拆成三段：图标、数字、纯进度条。数字永远不会再压在色条上。
func _draw_stat_row(
	top: float, text: String, _value_color: Color, fill: Color,
	ratio: float, ghost: float, heart: bool, _accent: Color
) -> void:
	# 留出斜边安全区；矢量图标与文字保持原生清晰度。
	var center := Vector2(35, top + ROW_HEIGHT * 0.5)
	draw_texture_rect(HEART_ICON if heart else SHIELD_ICON, Rect2(center - Vector2(6.5, 6.5), Vector2(13, 13)), false)
	draw_string(_font, Vector2(ICON_WIDTH + 2.0, top + 13), text, HORIZONTAL_ALIGNMENT_LEFT, -1, FONT_VALUE, Color(0.94, 0.96, 0.94))
	# 数字与色条分列；不将数值叠在色条上。
	var bar := Rect2(BAR_LEFT, top + BAR_TOP_INSET, size.x - BAR_LEFT - BAR_RIGHT_PAD, BAR_HEIGHT)
	UiThemeUtil.draw_pill(self, bar, Color(1, 1, 1, 0.11))
	if ghost > ratio:
		UiThemeUtil.draw_pill(self, Rect2(bar.position, Vector2(bar.size.x * clampf(ghost, 0, 1), bar.size.y)), Color(1, 0.89, 0.8, 0.48))
	var vivid := Color(1, 0.24, 0.31) if heart else Color(0.23, 0.94, 0.97)
	UiThemeUtil.draw_pill(self, Rect2(bar.position, Vector2(bar.size.x * clampf(ratio, 0, 1), bar.size.y)), vivid, true)

func _draw_heart(center: Vector2, color: Color) -> void:
	var points := PackedVector2Array([
		center + Vector2(0.0, 10.0), center + Vector2(-12.0, -1.0),
		center + Vector2(-11.0, -7.0), center + Vector2(-7.0, -10.0),
		center + Vector2(-2.0, -9.0), center,
		center + Vector2(2.0, -9.0), center + Vector2(7.0, -10.0),
		center + Vector2(11.0, -7.0), center + Vector2(12.0, -1.0),
	])
	draw_colored_polygon(points, color)
	draw_polyline(UiThemeUtil.closed(points), UiThemeUtil.shade(color, -0.30), UiThemeUtil.HAIRLINE_WIDTH, true)


func _draw_shield_icon(center: Vector2, color: Color) -> void:
	var points := PackedVector2Array([
		center + Vector2(-10.0, -10.0), center + Vector2(10.0, -10.0),
		center + Vector2(9.0, 3.0), center + Vector2(0.0, 11.0),
		center + Vector2(-9.0, 3.0),
	])
	draw_colored_polygon(points, color)
	draw_polyline(UiThemeUtil.closed(points), UiThemeUtil.shade(color, -0.30), UiThemeUtil.HAIRLINE_WIDTH, true)
	draw_colored_polygon(PackedVector2Array([
		center + Vector2(0.0, -7.0), center + Vector2(7.0, -7.0),
		center + Vector2(5.0, 1.0), center + Vector2(0.0, 7.0),
	]), UiThemeUtil.with_alpha(UiThemeUtil.shade(color, 0.40), 0.55))


## 0..1 的呼吸包络。用 sin 而不是 Tween：它在 _draw 里被调用，
## 需要是"当前时刻的函数"，不能依赖某个动画状态机的推进。
func _pulse() -> float:
	return sin(Time.get_ticks_msec() / 1000.0 * 5.4) * 0.5 + 0.5
