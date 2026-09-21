class_name WeaponPanel
extends Control
## 武器 HUD 面板（右下角）：弹匣 / 备弹 / 等级 / 威力 / 换弹进度 / 升级模块 / 狙击弹匣。
##
## 全部用 _draw() 绘制，不用一堆 Label 拼 —— 理由：
##   - 弹丸格（一发一格）用 Control 拼需要动态增删节点，而 _draw 只是一次循环；
##   - 大号弹匣数字、进度条、切角面板要精确对齐，手绘比调四组 anchors 可靠得多。
## 这与项目里准星 / 命中标记的做法一致（都是纯 _draw 的 Control）。
##
## ── 视觉语言（本次升级新增）──────────────────────────────────────
##
## 面板形状、包边、发丝线全部走 UiThemeUtil 的共享画笔（draw_plate / draw_bar /
## draw_tracked），不在这里自己画矩形。原因：同屏还有血量条、小地图两块面板，
## 只要有一块自己写一套直角矩形，轮廓就不统一 —— 那种"拼凑感"是
## 原型与成品之间最明显的那道坎，而且观众说不出具体哪里不对。
##
## 三条排版原则，改动时请一并守住：
##   1. 【同类读数同行】当前弹匣与备弹在同一基线上 —— 都是"还能打多久"，
##      分两行只会多一次视线跳转。
##   2. 【能"看"就不"读"】升级模块画成小格条而不是一行文字；文字读数需要读，
##      格状读数只需要看，而战斗中玩家的注意力预算是零。
##   3. 【分时复用同一块地方】换弹进度占用弹丸格的位置，不另开一行 ——
##      两者不会同时出现，堆叠只会白占高度。
##
## 数值来源全部由 PlayerHUD 每帧灌进来，本类不主动查询任何东西。

## 配色统一取自主题（preload 而非裸类名 —— ui_theme.gd 没有 class_name）。
const UiThemeUtil := preload("res://scripts/ui_theme.gd")

## 面板尺寸与站位（距屏幕右下角的边距）。
const PANEL_WIDTH := 300.0
const PANEL_HEIGHT := 142.0
const DISPLAY_SCALE := 0.72
const MARGIN := 18.0

## 狙击区自己一块小底板，叠在主面板上方、中间留 6 像素缝。
## 【用独立底板而不是同板再分一行】—— 它和主武器是两套独立资源，
## 底板的分离本身就在说"这是另一把武器"，比多写一个标签有效。
const SNIPER_HEIGHT := 32.0

## 弹丸格：每格宽度与间距。【格宽必须放得下满弹匣】——
## 40 × (3.6 + 1.4) = 200，仍在可用宽 PANEL_WIDTH - 28 = 220 之内。
## 改这三个值前先算这一步，否则满配弹匣会溢出面板右边界，而且不会报错。
const PIP_WIDTH := 4.5
const PIP_GAP := 1.7
const PIP_HEIGHT := 8.0
const PIP_MAX := 20

## 升级模块最多画几格；超出部分退回数字显示，避免小条被撑破。
const MODULE_PIPS := 5

const FONT_BIG := 30
const FONT_SMALL := 12
const FONT_TINY := 11

var _ammo := 0
var _capacity := 30
var _reserve := -1          # < 0 表示无限备弹
var _reloading := false
var _reload_ratio := 0.0
var _level := 1
var _pellets := 1
var _damage := 0.0
## 狙击弹匣（独立弹药）。sniper_capacity <= 0 表示隐藏该区块。
var _sniper_ammo := 0
var _sniper_capacity := 0
var _sniper_reload_remaining := 0.0
var _sniper_reserve := -1
## 三种升级模块的层数。
var _up_fire_rate := 0
var _up_damage := 0
var _up_magazine := 0

## 武器分类名，来自配置的 weapon.classes（如"冲锋枪""狙击枪"）。空串 = 不画，
## 这样配置缺失时只是少一行标签，而不是画出一块空白。
var _primary_label := ""
var _sniper_label := ""

var _font: Font


func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	_font = ThemeDB.fallback_font


## 每帧由 PlayerHUD 调用。参数与 PlayerWeapon 的读取接口一一对应。
func update_state(
	ammo: int, capacity: int, reserve: int, reloading: bool, reload_ratio: float,
	level: int, pellets: int, damage: float
) -> void:
	if _ammo == ammo and _capacity == capacity and _reserve == reserve \
			and _reloading == reloading and is_equal_approx(_reload_ratio, reload_ratio) \
			and _level == level and _pellets == pellets and is_equal_approx(_damage, damage):
		return
	_ammo = ammo
	_capacity = capacity
	_reserve = reserve
	_reloading = reloading
	_reload_ratio = reload_ratio
	_level = level
	_pellets = pellets
	_damage = damage
	queue_redraw()


func update_sniper(ammo: int, capacity: int, reload_remaining: float, reserve: int) -> void:
	if _sniper_ammo == ammo and _sniper_capacity == capacity \
			and is_equal_approx(_sniper_reload_remaining, reload_remaining) \
			and _sniper_reserve == reserve:
		return
	_sniper_ammo = ammo
	_sniper_capacity = capacity
	_sniper_reload_remaining = reload_remaining
	_sniper_reserve = reserve
	queue_redraw()


## 三种升级模块的层数。它们同时也会推高武器等级，所以这里只显示"模块带来的"部分，
## 等级本身仍由 update_state 的 level 显示 —— 两者会一起涨，但含义不同。
func update_upgrades(fire_rate: int, damage: int, magazine: int) -> void:
	if _up_fire_rate == fire_rate and _up_damage == damage and _up_magazine == magazine:
		return
	_up_fire_rate = fire_rate
	_up_damage = damage
	_up_magazine = magazine
	queue_redraw()


## 武器分类名（主武器 / 狙击各一个），来自配置的 weapon.classes。
## 只在武器本身发生变化时才会变，但这里跟着每帧一起灌 —— 与其它 set_* 保持一致，
## 免得面板多一条"什么时候该刷新标签"的隐式约定。
func set_labels(primary: String, sniper: String) -> void:
	if _primary_label == primary and _sniper_label == sniper:
		return
	_primary_label = primary
	_sniper_label = sniper
	queue_redraw()


func _draw() -> void:
	var origin := Vector2(
		size.x - PANEL_WIDTH * DISPLAY_SCALE - MARGIN,
		size.y - PANEL_HEIGHT * DISPLAY_SCALE - MARGIN
	)
	draw_set_transform(origin, 0.0, Vector2(DISPLAY_SCALE, DISPLAY_SCALE))
	_draw_panel(Vector2.ZERO)
	_draw_primary(Vector2.ZERO)
	_draw_sniper(Vector2.ZERO)
	draw_set_transform(Vector2.ZERO, 0.0, Vector2.ONE)


## 面板底板：直接走设计系统的标准面板（石板 → 青铜包边 → 内嵌层 → 四段切角压亮）。
## 强调色用弹药黄，让这块面板在余光里就能被认出来。
func _draw_panel(origin: Vector2) -> void:
	UiThemeUtil.draw_plate(
		self, Rect2(origin, Vector2(PANEL_WIDTH, PANEL_HEIGHT)), UiThemeUtil.COLOR_AMMO,
		UiThemeUtil.PLATE_FOREST
	)


func _draw_primary(origin: Vector2) -> void:
	var left := origin.x + 14.0
	var right := origin.x + PANEL_WIDTH - 14.0
	_draw_header(left, right, origin.y)
	_draw_magazine(left, right, origin.y)
	_draw_modules(left, origin.y)
	_draw_footer(right, origin)


## 顶栏：左侧武器分类（带字距），右侧等级徽标。
## 分类名回答"我拿的是什么"，等级徽标把"成长"变成一块看得见的牌 ——
## 原先这两样都缩在右下角一行小字里，等于没有。
func _draw_header(left: float, right: float, top: float) -> void:
	var baseline := top + 20.0
	var class_text := _primary_label if not _primary_label.is_empty() else "——"
	UiThemeUtil.draw_tracked(
		self, _font, Vector2(left, baseline), class_text,
		FONT_SMALL, UiThemeUtil.COLOR_BODY, 1.2
	)

	# 等级徽标走共享的小牌原语：顶部横幅的阶段号、首领条的首领标记也是同一形状。
	# （以前这里自己拼了一遍矩形 + 描边，那正是"三块面板各写一套"的开端。）
	var lv_text := "LV %d" % _level
	var lv_w := UiThemeUtil.tracked_width(_font, lv_text, FONT_TINY, 1.2) + 16.0
	UiThemeUtil.draw_tag(
		self, _font, Vector2(right - lv_w, top + 6.0), lv_text,
		FONT_TINY, UiThemeUtil.COLOR_ACCENT, 1.2
	)

	UiThemeUtil.draw_divider(self, Vector2(left, top + 29.0), right - left,
		UiThemeUtil.COLOR_AMMO)


## 弹匣区：大号当前弹药 + 容量 + 右对齐备弹，下面一格一个弹丸格（或换弹进度）。
func _draw_magazine(left: float, right: float, top: float) -> void:
	var ammo_color := UiThemeUtil.COLOR_AMMO
	if _reloading:
		ammo_color = UiThemeUtil.COLOR_DIM
	elif _ammo == 0:
		ammo_color = UiThemeUtil.COLOR_DANGER
	elif _is_low_ammo():
		# 低弹量呼吸。幅度刻意压小：真实射击游戏里满屏闪烁的警告很快会被
		# 玩家训练成噪音，而一点点明暗脉动既拉得住视线又不遮挡画面。
		var phase := sin(Time.get_ticks_msec() / 1000.0 * 6.0) * 0.5 + 0.5
		ammo_color = UiThemeUtil.shade(UiThemeUtil.COLOR_DANGER, phase * 0.35)

	var ammo_text := "%d" % _ammo
	draw_string(_font, Vector2(left, top + 72.0), ammo_text,
		HORIZONTAL_ALIGNMENT_LEFT, -1, FONT_BIG, ammo_color)
	var ammo_w := _font.get_string_size(
		ammo_text, HORIZONTAL_ALIGNMENT_LEFT, -1, FONT_BIG
	).x
	draw_string(_font, Vector2(left + ammo_w + 4.0, top + 72.0), "/ %d" % _capacity,
		HORIZONTAL_ALIGNMENT_LEFT, -1, FONT_SMALL + 3, UiThemeUtil.COLOR_DIM)

	# 备用弹夹右对齐到同一基线。
	#
	# 【不再在 0 时转红】原先备弹是"能不能换弹"的前置条件，归零就等于断了火力，
	# 所以转红。现在主武器子弹无限：备用弹夹空了，换弹照常给一个满弹匣
	# （见 PlayerWeapon._finish_reload）。继续转红会传递一条已经不成立的信息 ——
	# 玩家会以为自己打不动了，而实际上没有这回事。
	var reserve_text := "备用 ∞" if _reserve < 0 else "备用 %d" % _reserve
	var reserve_w := _font.get_string_size(
		reserve_text, HORIZONTAL_ALIGNMENT_LEFT, -1, FONT_SMALL
	).x
	draw_string(_font, Vector2(right - reserve_w, top + 49.0), reserve_text,
		HORIZONTAL_ALIGNMENT_LEFT, -1, FONT_SMALL, UiThemeUtil.COLOR_DIM)
	_draw_rifle(Vector2(right - 70.0, top + 65.0), UiThemeUtil.with_alpha(UiThemeUtil.COLOR_BODY, 0.82))

	var slot_y := top + 83.0
	if _reloading:
		_draw_reload(left, right, slot_y)
	else:
		_draw_pips(Vector2(left, slot_y), _ammo, _capacity, UiThemeUtil.COLOR_AMMO)


## 换弹进度：占用弹丸格的位置，右边留出 64 像素写标签。
## 两个元素不会同时出现，与其上下堆叠白占高度，不如分时复用同一行。
func _draw_reload(left: float, right: float, slot_y: float) -> void:
	var bar_w := (right - left) - 68.0
	var bar := Rect2(Vector2(left, slot_y), Vector2(bar_w, PIP_HEIGHT + 3.0))
	UiThemeUtil.draw_bar(self, bar, _reload_ratio, UiThemeUtil.COLOR_ACCENT, 0)
	var text := "装填中"
	UiThemeUtil.draw_tracked(
		self, _font, Vector2(right - UiThemeUtil.tracked_width(_font, text, FONT_TINY, 1.4),
			slot_y + PIP_HEIGHT + 1.0),
		text, FONT_TINY, UiThemeUtil.COLOR_ACCENT, 1.4
	)


## 三种升级模块：各画一根小格条，而不是一行 "射速+1 威力+2 弹匣+0"。
## 文字读数需要逐字读，格状读数一眼就够 —— 战斗中玩家的注意力预算是零。
func _draw_modules(left: float, top: float) -> void:
	var labels := ["射速", "威力", "弹匣"]
	var counts := [_up_fire_rate, _up_damage, _up_magazine]
	var colors := [
		UiThemeUtil.COLOR_ACCENT, UiThemeUtil.COLOR_AMMO, UiThemeUtil.COLOR_SHIELD
	]
	var col_w := (PANEL_WIDTH - 28.0) / 3.0
	for i in labels.size():
		var x := left + col_w * float(i)
		var count: int = counts[i]
		var color: Color = colors[i]
		UiThemeUtil.draw_tracked(
			self, _font, Vector2(x, top + 112.0), labels[i], FONT_TINY,
			UiThemeUtil.COLOR_DIM, 1.2
		)
		var pip_x := x + 28.0
		if count > MODULE_PIPS:
			# 层数超出格数时退回数字：宁可换个表现形式，也不把条撑破。
			UiThemeUtil.draw_tracked(
				self, _font, Vector2(pip_x, top + 112.0), "×%d" % count, FONT_TINY,
				color, 1.0
			)
			continue
		for k in MODULE_PIPS:
			var cell := Rect2(Vector2(pip_x + float(k) * 8.0, top + 103.0), Vector2(6.0, 9.0))
			draw_colored_polygon(
				UiThemeUtil.bevel_points(cell, 1.5),
				color if k < count else Color(1.0, 1.0, 1.0, 0.10)
			)


## 底部读数：单发威力，以及散弹类才有的弹丸数。
## 单发武器不显示"×1"—— 那个数字对冲锋枪没有信息量，只有弹丸 > 1 时才是有效读数。
func _draw_footer(right: float, origin: Vector2) -> void:
	var info := "威力 %.1f" % _damage
	if _pellets > 1:
		info += "   弹丸 ×%d" % _pellets
	UiThemeUtil.draw_tracked(
		self, _font,
		Vector2(right - UiThemeUtil.tracked_width(_font, info, FONT_TINY, 1.0),
			origin.y + PANEL_HEIGHT - 7.0),
		info, FONT_TINY, UiThemeUtil.COLOR_DIM, 1.0
	)


## 武器剪影也只用折线：它是识别提示，不承担写实展示，因此无需纹理资产。
func _draw_rifle(origin: Vector2, color: Color) -> void:
	var points := PackedVector2Array([
		origin + Vector2(0.0, -3.0), origin + Vector2(31.0, -3.0),
		origin + Vector2(37.0, -8.0), origin + Vector2(54.0, -8.0),
		origin + Vector2(57.0, -4.0), origin + Vector2(68.0, -4.0),
		origin + Vector2(68.0, 1.0), origin + Vector2(44.0, 1.0),
		origin + Vector2(52.0, 8.0), origin + Vector2(42.0, 8.0),
		origin + Vector2(33.0, 1.0), origin + Vector2(0.0, 1.0),
	])
	draw_colored_polygon(points, color)
	draw_line(origin + Vector2(25.0, -6.0), origin + Vector2(43.0, -6.0), color, 2.0, true)


## 低于 25% 才提示。阈值不能定高：整局都在脉动的话，玩家很快会学会无视它，
## 那时真见底了也拉不回注意力。
func _is_low_ammo() -> bool:
	return _capacity > 0 and float(_ammo) <= float(_capacity) * 0.25


## 弹丸格：一格一发。数量超过 PIP_MAX 时退化为"比例填充的整条"，
## 否则 40 发的弹匣会画成一排看不清的细线。
func _draw_pips(from: Vector2, current: int, capacity: int, color: Color) -> void:
	if capacity <= 0:
		return
	if capacity > PIP_MAX:
		UiThemeUtil.draw_bar(
			self, Rect2(from, Vector2(PANEL_WIDTH - 28.0, PIP_HEIGHT + 3.0)),
			float(current) / float(capacity), color, 0
		)
		return
	var step := PIP_WIDTH + PIP_GAP
	for index in range(capacity):
		var filled := index < current
		var cell := Rect2(
			from + Vector2(float(index) * step, 0.0), Vector2(PIP_WIDTH, PIP_HEIGHT + 3.0)
		)
		draw_colored_polygon(
			UiThemeUtil.bevel_points(cell, 2.0),
			color if filled else Color(1.0, 1.0, 1.0, 0.12)
		)
		# 每 5 格压一道短线：把"一排格子"读成"几组"，
		# 玩家就不必在交火中逐个数自己还剩几发。
		if filled and (index + 1) % 5 == 0:
			draw_line(
				Vector2(cell.position.x, cell.position.y - 3.5),
				Vector2(cell.position.x, cell.position.y - 1.5),
				UiThemeUtil.with_alpha(color, 0.55), 1.0, true
			)


## 狙击区：独立弹匣，单独一块小底板叠在主面板上方，颜色用青色与主武器区分。
func _draw_sniper(origin: Vector2) -> void:
	if _sniper_capacity <= 0:
		return
	var rect := Rect2(
		Vector2(origin.x, origin.y - SNIPER_HEIGHT - 6.0),
		Vector2(PANEL_WIDTH, SNIPER_HEIGHT)
	)
	UiThemeUtil.draw_plate(
		self, rect, UiThemeUtil.COLOR_SNIPER, UiThemeUtil.PLATE_SHIELD
	)

	var title := _sniper_label if not _sniper_label.is_empty() else "狙击"
	UiThemeUtil.draw_tracked(
		self, _font, Vector2(rect.position.x + 14.0, rect.position.y + 16.0), title,
		FONT_SMALL, UiThemeUtil.COLOR_SNIPER, 1.4
	)

	var reserve_text := "∞" if _sniper_reserve < 0 else "%d" % _sniper_reserve
	var reserve_w := UiThemeUtil.tracked_width(_font, reserve_text, FONT_TINY, 1.0)
	UiThemeUtil.draw_tracked(
		self, _font, Vector2(rect.end.x - 14.0 - reserve_w, rect.position.y + 16.0),
		reserve_text, FONT_TINY, UiThemeUtil.COLOR_DIM, 1.0
	)

	# 装填中就把读数换成倒计时、并把青色调暗：同一个位置既能报"还有几发"，
	# 也能报"还要等多久"，不新增元素。
	var readout := "%d / %d" % [_sniper_ammo, _sniper_capacity]
	var readout_color := UiThemeUtil.COLOR_SNIPER
	if _sniper_reload_remaining > 0.0:
		readout = "装填 %.1fs" % _sniper_reload_remaining
		readout_color = UiThemeUtil.COLOR_DIM
	var readout_w := UiThemeUtil.tracked_width(_font, readout, FONT_SMALL, 1.0)
	UiThemeUtil.draw_tracked(
		self, _font,
		Vector2(rect.end.x - 14.0 - reserve_w - 12.0 - readout_w, rect.position.y + 16.0),
		readout, FONT_SMALL, readout_color, 1.0
	)

	# 底部一根细格条代表弹匣本身：0 发时它整条压暗，一眼可见"该换弹了"。
	var bar := Rect2(
		Vector2(rect.position.x + 14.0, rect.end.y - 7.0),
		Vector2(PANEL_WIDTH - 28.0, 4.0)
	)
	UiThemeUtil.draw_bar(
		self, bar, float(_sniper_ammo) / float(_sniper_capacity),
		UiThemeUtil.COLOR_SNIPER, _sniper_capacity
	)
