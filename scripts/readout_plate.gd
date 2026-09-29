class_name ReadoutPlate
extends Control
## 读数板：左侧小号标签 + 右侧数值；附属说明独占第二行。
##
## 【为什么需要它】"生存 / 最佳"与"击杀"这两块原先各是一条 Label，内容拼成
## 一句话："生存 01:23   最佳 01:10"、"击杀：12"。它们与旁边的生命面板、
## 武器面板长得完全不像 —— 那些是切角石板，这些是直接印在场景上的字。
## 同屏时"实心面板"和"漂浮文字"混在一起的拼凑感，正是原型期的典型症状。
##
## 这两块的信息形状其实一模一样（一个名字 + 一个数），所以共用一块小板，
## 而不是各写一套绘制。数值将来要给武器等级读数复用时，也直接用它。
##
## 布局刻意做成"标签在左、数值贴右"：数值右对齐后，
## 每 0.01 秒跳一次的数字不会推着整行文字左右抖动。

const UiThemeUtil := preload("res://scripts/ui_theme.gd")

const PAD := 10.0
const FONT_LABEL := 9
const FONT_VALUE := 15
const FONT_SUB := 9
## 数值变化时那一下闪光的衰减速度（每秒衰减多少）。1/3 秒衰减完 ——
## 再慢就成了"常亮"，而常亮等于没有强调。
const FLASH_DECAY := 3.0

## 数值变化时是否闪一下。【默认关，必须显式打开】——
## 生存时间每秒变几十次，跟着闪的话这块板会一直抖；
## 只有"击杀数"这种偶尔跳一次的量才适合闪光。
var pulse_on_change := false

var _font: Font
var _accent := UiThemeUtil.COLOR_ACCENT
var _plate_variant := UiThemeUtil.PLATE_FOREST

var _label := ""
var _value := ""
var _sub := ""
## 已画出去的组合。读数每帧都会被灌一次（见 PlayerHUD.set_survival），
## 而生存时间的变化频率是每秒几十次 —— 不去重就是每秒几十次无谓重绘。
var _drawn := ""
## 0..1 的闪光量。只在 pulse() 之后自行衰减到 0，期间持续重绘。
var _flash := 0.0


func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	_font = UiThemeUtil.get_font()
	# 平时不跑 _process：这块板在绝大多数帧里什么都不做。
	set_process(false)


## 闪一下。由外界在"这个数真的变大了"时调用 ——
## 光靠数字本身变化的话，盯着看才会发现；而击杀数正是玩家最想立刻知道的数。
func pulse() -> void:
	_flash = 1.0
	set_process(true)


func _process(delta: float) -> void:
	_flash = maxf(_flash - FLASH_DECAY * delta, 0.0)
	queue_redraw()
	if _flash <= 0.0:
		set_process(false)


## 强调色只在构建时定一次（击杀 / 生存各有各的主题色），
## 不跟读数一起传 —— 那会让调用点每帧重复声明一个常量。
func configure(accent: Color, plate_variant: int = UiThemeUtil.PLATE_FOREST) -> void:
	_accent = accent
	_plate_variant = plate_variant
	queue_redraw()


func set_readout(label: String, value: String, sub: String = "") -> void:
	var key := "%s|%s|%s" % [label, value, sub]
	if key == _drawn:
		return
	# 首次赋值不算"变化"：那只是这块板被建出来而已，
	# 在它上面闪一下会让人以为"一进游戏就被记了一次击杀"。
	var changed := not _drawn.is_empty()
	_drawn = key
	_label = label
	_value = value
	_sub = sub
	if pulse_on_change and changed:
		pulse()
	queue_redraw()


func _draw() -> void:
	# 闪光量并入强调色：板边与数值同时亮一下，而不是另外加一层盖在上面。
	var accent := UiThemeUtil.shade(_accent, _flash * 0.45)
	UiThemeUtil.draw_plate(self, Rect2(Vector2.ZERO, size), accent, _plate_variant)
	var baseline := size.y * 0.5 + float(FONT_VALUE) * 0.36
	if not _sub.is_empty():
		baseline = 19.0

	UiThemeUtil.draw_tracked(
		self, _font, Vector2(PAD, baseline), _label,
		FONT_LABEL, UiThemeUtil.shade(UiThemeUtil.COLOR_DIM, _flash * 0.5), 2.6
	)

	var right := size.x - PAD
	var value_w := UiThemeUtil.tracked_width(_font, _value, FONT_VALUE, 0.8)
	UiThemeUtil.draw_tracked(
		self, _font, Vector2(right - value_w, baseline), _value,
		FONT_VALUE, UiThemeUtil.shade(accent, 0.15), 0.8
	)
	if _sub.is_empty():
		return
	# 结算页的“最佳击杀”有自己的第二行，避免与时间和主标签争同一行。
	UiThemeUtil.draw_tracked(
		self, _font, Vector2(PAD, size.y - 8.0), _sub,
		FONT_SUB, UiThemeUtil.with_alpha(UiThemeUtil.COLOR_DIM, 0.85), 0.6
	)
