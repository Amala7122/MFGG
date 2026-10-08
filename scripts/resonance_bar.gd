class_name ResonanceBar
extends Control
## 遗迹共鸣能量指示条。
##
## 位于屏幕中下方（生命面板正上方），实时反映能量蓄积与爆发就绪状态。
## - 充能中：紫蓝能量流动，显示百分比
## - 蓄满 100% 时：金色脉冲外框 + 呼吸发光，提示「★ 共鸣就绪 [按 C 释放]」
## - 溢出阶段：超过 100% 的部分显示为高亮琥珀金，提示额外伤害加成

const UiThemeUtil := preload("res://scripts/ui_theme.gd")
const EventBusUtil := preload("res://scripts/event_bus.gd")

const BAR_WIDTH := 272.0
const BAR_HEIGHT := 22.0

var _font: Font
var _energy: float = 0.0
var _max_energy: float = 100.0
var _overflow_cap: float = 150.0

var _pulse_time: float = 0.0


func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	_font = UiThemeUtil.get_font()
	EventBusUtil.subscribe_resonance_changed(_on_resonance_changed)


func _on_resonance_changed(energy: float, max_energy: float, overflow_cap: float) -> void:
	_energy = energy
	_max_energy = maxf(max_energy, 1.0)
	_overflow_cap = maxf(overflow_cap, _max_energy)
	queue_redraw()


func _process(delta: float) -> void:
	if _energy >= _max_energy:
		_pulse_time += delta
		queue_redraw()


func _draw() -> void:
	var rect := Rect2(Vector2.ZERO, Vector2(BAR_WIDTH, BAR_HEIGHT))
	var is_ready := _energy >= _max_energy
	var is_overflow := _energy > _max_energy

	# 1. 底框与背景石板
	var accent := UiThemeUtil.COLOR_ACCENT
	if is_ready:
		var pulse := 0.65 + sin(_pulse_time * 8.0) * 0.35
		accent = Color(0.98, 0.84, 0.38, pulse)

	UiThemeUtil.draw_plate(self, rect, accent, UiThemeUtil.PLATE_GOLD if is_ready else UiThemeUtil.PLATE_SHIELD)

	# 2. 能量条绘制
	var inner_rect := rect.grow(-3.0)
	var fill_ratio := clampf(_energy / _max_energy, 0.0, 1.0)
	var fill_w := inner_rect.size.x * fill_ratio

	if fill_w > 1.0:
		var fill_rect := Rect2(inner_rect.position, Vector2(fill_w, inner_rect.size.y))
		var fill_color := Color(0.55, 0.25, 0.85, 0.85) if not is_ready else Color(0.85, 0.45, 1.0, 0.95)
		draw_rect(fill_rect, fill_color)

	# 3. 溢出充能条
	if is_overflow and _overflow_cap > _max_energy:
		var overflow_ratio := clampf((_energy - _max_energy) / (_overflow_cap - _max_energy), 0.0, 1.0)
		var overflow_w := inner_rect.size.x * overflow_ratio
		if overflow_w > 1.0:
			var overflow_rect := Rect2(inner_rect.position, Vector2(overflow_w, inner_rect.size.y))
			var gold_color := Color(1.0, 0.82, 0.2, 0.85)
			draw_rect(overflow_rect, gold_color)

	# 4. 文字提示
	var text_y := 15.0
	if is_ready:
		var label := "★ 共鸣就绪 [按 C 爆发]"
		if is_overflow:
			var bonus := roundi((_energy / _max_energy - 1.0) * 100.0)
			label = "★ 满载过载 +%d%% [按 C 释放]" % bonus
		var pulse_val := 0.75 + sin(_pulse_time * 8.0) * 0.25
		var txt_col := Color(1.0, 0.95, 0.4, pulse_val)
		var w := UiThemeUtil.tracked_width(_font, label, 11, 0.2)
		UiThemeUtil.draw_tracked(self, _font, Vector2((BAR_WIDTH - w) * 0.5, text_y), label, 11, txt_col, 0.2)
	else:
		var pct := roundi((_energy / _max_energy) * 100.0)
		var label := "遗迹共鸣 %d%%" % pct
		var w := UiThemeUtil.tracked_width(_font, label, 11, 0.2)
		var txt_col := Color(0.85, 0.8, 0.95, 0.8)
		UiThemeUtil.draw_tracked(self, _font, Vector2((BAR_WIDTH - w) * 0.5, text_y), label, 11, txt_col, 0.2)

