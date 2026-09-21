class_name BossBar
extends Control
## 首领血条（屏幕顶部中央，只在首领存活期间显示）。
##
## 原先是一个 ProgressBar 加一个 Label：进度条是 1 像素描边的纯色块，与整套
## 切角石板语言无关。更关键的是它【没有伤害残影】—— 首领血量是全场最需要
## 被读出来的一根条（它决定了"还要打多久 / 是不是快进二阶段了"），
## 而一根静止的条在这个信息密度下基本等于没有。
##
## 这里的处理：
##   1. 走设计系统标准面板，强调色用危险红（同屏唯一的红面板，位置就说明了一切）。
##   2. 伤害残影 + 分段刻度（4 段 ≈ 阶段感），低血量时整体呼吸。
##   3. 首领标记用共享的小牌原语（draw_tag），与武器面板的等级徽标同形。

const UiThemeUtil := preload("res://scripts/ui_theme.gd")

const PANEL_HEIGHT := 40.0
## 分段刻度数。首领战通常按血量分阶段，4 段读起来刚好。
const SEGMENTS := 4
const GHOST_HOLD := 0.36
const GHOST_SPEED := 0.5
## 低于该比例开始呼吸。
const LOW_RATIO := 0.3

const PAD := 11.0
const HEADER_BASELINE := 15.0
const BAR_TOP := 22.0
const BAR_H := 11.0

const FONT_TITLE := 11
const FONT_VALUE := 10
const FONT_TAG := 9

var _font: Font

var _active := false
var _title := ""
var _current := 0.0
var _maximum := 1.0
var _ratio := 1.0
var _ghost := 1.0
var _ghost_hold := 0.0
var _initialized := false
## 出场进度 0..1：血条由中间向两侧甩开。
var _appear := 1.0
## 上一帧是否处于"首领在场"。只用来识别"刚刚出场"这一个瞬间。
var _was_active := false


func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	# 【宽度不在这里定义】本控件是"占满整行"的宽元素，横向边界必须由 PlayerHUD
	# 按两侧信息栏的留白算（PlayerHUD._center_half_width）—— 在这里再声明一个
	# 半宽就成了第二份真相：改了它不会有任何效果，反而让人以为改这里能改宽度。
	set_process(true)
	_font = ThemeDB.fallback_font


func _process(delta: float) -> void:
	if not _active:
		return
	if _ghost_hold > 0.0:
		_ghost_hold = maxf(_ghost_hold - delta, 0.0)
		queue_redraw()
	elif _ghost > _ratio + 0.0005:
		_ghost = maxf(_ratio, _ghost - GHOST_SPEED * delta)
		queue_redraw()
	if is_low():
		queue_redraw()


## 由 PlayerHUD 转发 EventBus.boss_updated。
func set_boss(active: bool, title: String, current: float, maximum: float) -> void:
	if not active:
		_active = false
		_was_active = false
		visible = false
		return
	# 【出场的那一下】首领真正出现之前，屏幕上没有任何预警，而血条是"打起来了"
	# 的第一个信号。它直接出现在那里，玩家会以为自己漏看了开场。
	# 让它从中间甩开，那一下就把视线拉过去了。
	if not _was_active:
		_was_active = true
		_play_entrance()
	_active = true
	visible = true
	_title = title
	_current = current
	_maximum = maxf(maximum, 1.0)
	var ratio := clampf(current / _maximum, 0.0, 1.0)
	if not _initialized:
		# 首领出场时血是满的，但万一出现时血已不满（中途 join 的客户端），
		# 也直接把残影对准实际值 —— 不能让人看到一次假的掉血。
		_initialized = true
		_ghost = ratio
	elif ratio < _ratio - 0.0005:
		_ghost_hold = GHOST_HOLD
	_ratio = ratio
	queue_redraw()


## 入场。走 _appear 而不是 tween position —— 位置由 PlayerHUD 的布局函数掌管，
## 动它会和下一轮重排打架；而 _appear 只改"条画多宽"，不与任何布局冲突。
func _play_entrance() -> void:
	_appear = 0.0
	_initialized = false
	modulate.a = 0.0
	queue_redraw()
	var tween := create_tween()
	tween.set_parallel(true)
	tween.tween_property(self, "modulate:a", 1.0, 0.20).set_ease(Tween.EASE_OUT)
	tween.tween_method(_set_appear, 0.0, 1.0, 0.44) \
		.set_ease(Tween.EASE_OUT).set_trans(Tween.TRANS_CUBIC)


func _set_appear(value: float) -> void:
	_appear = value
	queue_redraw()


func is_low() -> bool:
	return _ratio < LOW_RATIO


# ---------------------------------------------------------------- 绘制

func _draw() -> void:
	var accent := UiThemeUtil.COLOR_DANGER
	if is_low():
		accent = UiThemeUtil.shade(UiThemeUtil.COLOR_DANGER, _pulse() * 0.35)
	UiThemeUtil.draw_plate(
		self, Rect2(Vector2.ZERO, size), accent, UiThemeUtil.PLATE_HEALTH
	)

	var left := PAD
	var right := size.x - PAD
	var tag_w := 0.0
	# 首领标记。标题为空时它就是唯一的身份说明，所以不能省。
	if _active:
		tag_w = UiThemeUtil.draw_tag(
			self, _font, Vector2(left, 4.0), "首领", FONT_TAG, accent, 2.0
		) + 9.0
		var title := _title if not _title.is_empty() else "未知目标"
		UiThemeUtil.draw_tracked(
			self, _font, Vector2(left + tag_w, HEADER_BASELINE), title,
			FONT_TITLE, UiThemeUtil.shade(UiThemeUtil.COLOR_TITLE, 0.1), 1.4
		)

	var value := "%d / %d" % [ceili(maxf(_current, 0.0)), ceili(_maximum)]
	var value_w := UiThemeUtil.tracked_width(_font, value, FONT_VALUE, 0.8)
	UiThemeUtil.draw_tracked(
		self, _font, Vector2(right - value_w, HEADER_BASELINE), value,
		FONT_VALUE, UiThemeUtil.with_alpha(UiThemeUtil.COLOR_BODY, 0.82), 0.8
	)

	# 条由中间向两侧展开（出场动效）。只在 _appear < 1 时宽度才不同，
	# 平时就是整条 —— 所以这里不是"每次都做一次插值"，而是一次条件化的收窄。
	var full := right - left
	var shown_w := full * clampf(_appear, 0.0, 1.0)
	UiThemeUtil.draw_bar(
		self,
		Rect2(Vector2(left + (full - shown_w) * 0.5, BAR_TOP), Vector2(shown_w, BAR_H)),
		_ratio, UiThemeUtil.COLOR_DANGER, SEGMENTS, _ghost
	)


func _pulse() -> float:
	return sin(Time.get_ticks_msec() / 1000.0 * 5.4) * 0.5 + 0.5
