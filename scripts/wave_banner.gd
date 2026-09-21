class_name WaveBanner
extends Control
## 波次横幅（屏幕顶部中央）。
##
## 原先是一条纯文字 Label："阶段 1 · 圆形斗兽场　　第 2/3 波 · 剩余 5"。
## 一整行等权重的文字有三个毛病：读不出"还差几波"、读不出"还要等多久"、
## 而且它悬在空场景上没有任何承托，看起来像调试输出。
##
## 现在拆成"一块面板 + 两行信息"：
##   第一行  阶段号小牌 + 竞技场名 ｜ 右侧当前状态读数
##   第二行  进度条：交战中是【波次格】（清掉的亮起，当前那格脉动），
##           准备/休整时变成【倒计时条】。同一根条分时承担两种语义 ——
##           它们永远不会同时出现，堆两条只会白占高度。
##
## 倒计时条的分母靠"见过的最大剩余时间"自推（见 _timer_span）：
## 快照里只给了剩余秒数，没有总时长，而 wave_director 的接口不该为了
## 显示一个进度条去改。第一次拿到的值就是最大值，之后单调取大即可 ——
## 波次/状态一变就重置，所以跨波也不会残留。

const UiThemeUtil := preload("res://scripts/ui_theme.gd")

const PANEL_HEIGHT := 30.0
## 【宽度不在这里定义】本面板是"占满整行"的宽元素，它的横向边界必须由 PlayerHUD
## 按两侧信息栏的留白算（见 PlayerHUD._center_half_width）—— 这里再声明一个
## 半宽就成了第二份真相：改了它不会有任何效果，反而会让人以为改这里能改宽度。

const PAD := 10.0
const HEADER_BASELINE := 14.0
const TAG_TOP := 3.0
const STRIP_TOP := 20.0
const STRIP_H := 6.0

const FONT_HEADER := 10
const FONT_TAG := 9

## wave_director 的 STATE_LABELS 值。这里按字符串比对，因为快照里给的就是字符串 ——
## HUD 不需要认识 wave_director 的枚举，改枚举也不该牵动界面。
const STATE_PREPARE := "准备"
const STATE_FIGHT := "交战中"
const STATE_BREAK := "波间休整"
const STATE_BOSS := "BOSS 战"
const STATE_CLEARED := "阶段通过"

var _font: Font

var _stage := 1
var _arena := ""
var _wave := 0
var _total_waves := 0
var _remaining := 0
var _timer := 0.0
var _state := STATE_PREPARE

## 倒计时分母自推用的键与已见最大值。
var _timer_key := ""
var _timer_span := 1.0


func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	set_process(true)
	_font = ThemeDB.fallback_font
	visible = false


## 倒计时条需要每帧重画（秒数在连续变化），波次格只在快照到达时变。
func _process(_delta: float) -> void:
	if is_countdown():
		queue_redraw()


## 由 PlayerHUD 转发 EventBus.wave_updated 的快照字典。
func update_wave(info: Dictionary) -> void:
	var new_state := String(info.get("state", STATE_PREPARE))
	_stage = int(info.get("stage", 1))
	_arena = String(info.get("arena_label", ""))
	_wave = int(info.get("wave", 0))
	_total_waves = int(info.get("total_waves", 0))
	_remaining = int(info.get("remaining", 0))
	_timer = float(info.get("timer", 0.0))
	_state = new_state
	if bool(info.get("boss", false)):
		_state = STATE_BOSS

	# 倒计时分母：键里带上 stage/wave/state，三者任一变化就重置。
	var key := "%d|%d|%s" % [_stage, _wave, _state]
	if key != _timer_key:
		_timer_key = key
		_timer_span = maxf(_timer, 0.001)
	else:
		_timer_span = maxf(_timer_span, _timer)
	visible = true
	queue_redraw()


## 第一行右侧在当前状态下该说的一句话。
func status_text() -> String:
	match _state:
		STATE_FIGHT:
			return "第 %d / %d 波 · 剩余 %d" % [_wave, _total_waves, _remaining]
		STATE_BREAK:
			return "下一波 %.1f 秒" % _timer
		STATE_PREPARE:
			return "准备 %.1f 秒" % _timer
		STATE_BOSS:
			return "首领战"
		STATE_CLEARED:
			return "阶段通过"
	return ""


## 第二行画倒计时条还是波次格。
func is_countdown() -> bool:
	return _state == STATE_PREPARE or _state == STATE_BREAK


## 当前状态的主题色。首领战与阶段通过需要在一眼之内与常规波次区分开，
## 但又不该各自发明一套配色 —— 前者借危险红，后者借标题金。
func accent() -> Color:
	match _state:
		STATE_BOSS:
			return UiThemeUtil.COLOR_DANGER
		STATE_CLEARED:
			return UiThemeUtil.COLOR_TITLE
	return UiThemeUtil.COLOR_ACCENT


## 已清空的波数。用于点亮波次格。
func cleared_waves() -> int:
	match _state:
		STATE_FIGHT:
			# 当前这一波正在打，所以已完成的是 wave - 1。
			return maxi(_wave - 1, 0)
		STATE_BREAK:
			return _wave
		STATE_BOSS, STATE_CLEARED:
			return _total_waves
	return 0


# ---------------------------------------------------------------- 绘制

func _draw() -> void:
	var color := accent()
	UiThemeUtil.draw_plate(
		self, Rect2(Vector2.ZERO, size), color, UiThemeUtil.PLATE_GOLD
	)

	var left := PAD
	var right := size.x - PAD
	var tag_w := UiThemeUtil.draw_tag(
		self, _font, Vector2(left, TAG_TOP), "阶段 %d" % _stage, FONT_TAG, color, 1.4
	) + 10.0
	if not _arena.is_empty():
		UiThemeUtil.draw_tracked(
			self, _font, Vector2(left + tag_w, HEADER_BASELINE), _arena,
			FONT_HEADER, UiThemeUtil.with_alpha(UiThemeUtil.COLOR_BODY, 0.86), 1.2
		)

	var status := status_text()
	if not status.is_empty():
		var status_w := UiThemeUtil.tracked_width(_font, status, FONT_HEADER, 1.0)
		UiThemeUtil.draw_tracked(
			self, _font, Vector2(right - status_w, HEADER_BASELINE), status,
			FONT_HEADER, color, 1.0
		)

	var strip := Rect2(Vector2(left, STRIP_TOP), Vector2(right - left, STRIP_H))
	if is_countdown():
		var span := maxf(_timer_span, 0.001)
		UiThemeUtil.draw_bar(self, strip, clampf(_timer / span, 0.0, 1.0), color, 0)
	else:
		_draw_wave_cells(strip, color)


## 波次格：每波一格。已清空的亮起，正在打的那格脉动 ——
## "还差几波"由此变成一眼可数的东西，而不是一句要读的"第 2/3 波"。
func _draw_wave_cells(strip: Rect2, color: Color) -> void:
	var count := maxi(_total_waves, 1)
	var gap := 3.0
	var cell_w := maxf((strip.size.x - gap * float(count - 1)) / float(count), 2.0)
	var done := cleared_waves()
	var pulse := sin(Time.get_ticks_msec() / 1000.0 * 5.0) * 0.5 + 0.5
	for i in count:
		var cell := Rect2(
			Vector2(strip.position.x + float(i) * (cell_w + gap), strip.position.y),
			Vector2(cell_w, strip.size.y)
		)
		var fill: Color
		if i < done:
			fill = UiThemeUtil.with_alpha(color, 0.85)
		elif i == done and _state == STATE_FIGHT:
			fill = UiThemeUtil.with_alpha(color, 0.35 + pulse * 0.45)
		else:
			fill = Color(1.0, 1.0, 1.0, 0.10)
		draw_colored_polygon(UiThemeUtil.bevel_points(cell, 2.0), fill)
