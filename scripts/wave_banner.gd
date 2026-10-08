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
var _combat_age := 0.0
const COMBAT_SHOW_TIME := 2.8


func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	set_process(true)
	_font = UiThemeUtil.get_font()
	visible = false


## 倒计时条需要每帧重画（秒数在连续变化），波次格只在快照到达时变。
func _process(delta: float) -> void:
	if _state == STATE_FIGHT or _state == STATE_BOSS:
		_combat_age += delta
		modulate.a = clampf((COMBAT_SHOW_TIME - _combat_age) / 0.5, 0.0, 1.0)
		visible = _combat_age < COMBAT_SHOW_TIME
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
		_combat_age = 0.0
		_timer_key = key
		_timer_span = maxf(_timer, 0.001)
	else:
		_timer_span = maxf(_timer_span, _timer)
	var combat := _state == STATE_FIGHT or _state == STATE_BOSS
	visible = not combat or _combat_age < COMBAT_SHOW_TIME
	if not combat:
		modulate.a = 1.0
	queue_redraw()


## 第一行右侧在当前状态下该说的一句话。
func status_text() -> String:
	match _state:
		STATE_FIGHT:
			return "第 %d / %d 波" % [_wave, _total_waves]
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
	var status := status_text()
	var label := "%s  ·  阶段 %d" % [_arena, _stage]
	var label_width := _font.get_string_size(label, HORIZONTAL_ALIGNMENT_LEFT, -1, 10).x
	var status_width := _font.get_string_size(status, HORIZONTAL_ALIGNMENT_LEFT, -1, 16).x
	var backdrop := Rect2(Vector2(size.x * 0.5 - 120, 0), Vector2(240, 42))
	draw_rect(backdrop, Color(0.025, 0.045, 0.06, 0.35))
	draw_string(_font, Vector2((size.x - label_width) * 0.5, 13), label, HORIZONTAL_ALIGNMENT_LEFT, -1, 10, Color(0.85, 0.91, 0.9, 0.78))
	draw_string(_font, Vector2((size.x - status_width) * 0.5, 33), status, HORIZONTAL_ALIGNMENT_LEFT, -1, 16, Color(0.95, 0.98, 0.95))
	if is_countdown():
		draw_rect(Rect2(size.x * 0.5 - 90, 40, 180 * clampf(_timer / maxf(_timer_span, 0.001), 0, 1), 2), Color(0.45, 0.86, 0.9, 0.7))
