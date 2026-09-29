extends RefCounted
## 统一 UI 主题：全局唯一的字体尺寸 / 配色 / 控件样式来源。
##
## 为什么需要它：这些值原先散落在 player_hud.gd 与 game_flow.gd 里各写一份
## （各自的 COLOR_* 常量、各自的 add_theme_font_size_override），改一次配色要翻
## 好几个文件，而且两边的"标题色 / 正文色"已经开始漂移。这里收成一处。
##
## 用法：控件挂【主题变体】而不是各自写 override：
##
##     label.theme = UiTheme.get_theme()
##     label.theme_type_variation = UiTheme.VARIATION_HUD_TIME
##
## 关于 theme/game_theme.tres：磁盘上存在这个文件就优先用它（可以直接在编辑器里
## 改配色并实时预览），不存在则用下面这份代码默认值。与 game_config 同一思路 ——
## 资源是可编辑入口，代码提供不会坏的兜底，缺了哪一边游戏都能跑。

const THEME_PATH := "res://theme/game_theme.tres"
const FONT_PATH := "res://theme/fonts/NotoSansSC-wght.ttf"

# ---------------------------------------------------------------- 主题变体名
# 控件用这些名字取样式，不要再去各自写死颜色与字号。

const VARIATION_TITLE := "UiTitle"
const VARIATION_BODY := "UiBody"
const VARIATION_DIM := "UiDim"
const VARIATION_HUD_ABILITIES := "UiHudAbilities"
const VARIATION_HUD_TIME := "UiHudTime"
const VARIATION_HUD_WEAPON := "UiHudWeapon"

## 【本轮的减法】原先还有弹药 / 狙击 / 弹道 / 生命条 / 护盾条五个变体，
## 它们服务的都是"用 Label 和 ProgressBar 拼 HUD"的做法。现在这些读数全部
## 走了自绘控件（WeaponPanel / VitalsPanel / BossBar / WaveBanner），
## 那五个变体就成了没人引用的死配置 —— 直接从定义和 game_theme.tres 里去掉，
## 免得以后有人照着它们做出第五种风格的条。
##
## 【改这块时必须同时改两处】theme/game_theme.tres 是优先加载的那一份，
## 它里面记的是这些变体名与字号 / 配色 / 按钮样式盒的展开值。
## 只改这里的话，运行期读到的仍然是 .tres —— 编辑器里看着对，跑起来是旧的。
## （.tres 里不写注释：资源文本格式的注释支持不可靠，说明一律留在本文件。）

# ---------------------------------------------------------------- 配色（单一来源）

## 这组颜色直接取自通过评审的低多边形 HUD 稿：暖米色负责正文，森林绿负责
## 大面积承托，珊瑚红 / 湖蓝 / 营火金只承担语义。避免再回到蓝灰石板 + 青色发光线。
const COLOR_TITLE := Color(0.98, 0.84, 0.38, 1.0)
const COLOR_BODY := Color(0.96, 0.91, 0.76, 1.0)
const COLOR_DIM := Color(0.74, 0.73, 0.60, 1.0)
const COLOR_ACCENT := Color(0.20, 0.82, 0.84, 1.0)
const COLOR_AMMO := Color(0.98, 0.76, 0.25, 1.0)
const COLOR_SNIPER := Color(0.28, 0.86, 0.88, 1.0)
const COLOR_BALLISTICS := Color(0.72, 0.78, 0.66, 1.0)
const COLOR_SHIELD := Color(0.16, 0.82, 0.86, 1.0)
const COLOR_DANGER := Color(0.94, 0.24, 0.20, 1.0)
const COLOR_HEALTH := Color(0.90, 0.25, 0.20, 1.0)
const COLOR_PANEL := Color(0.08, 0.15, 0.09, 0.70)
const COLOR_PANEL_BORDER := Color(0.73, 0.56, 0.25, 0.55)
const COLOR_SHADOW := Color(0.06, 0.08, 0.04, 0.92)

# ---------------------------------------------------------------- 材质层（UI 的"实体感"）
#
# 上面那批是【语义色】（血量红 / 弹药黄 / 强调青），下面是【材质色】。
# 两者分开的原因：语义色描述"这是什么"，材质色描述"它由什么做成"。
# 面板的深石板灰与青铜包边在整套 UI 里必须逐值一致，否则同一屏里几块面板
# 会各自深浅不一，那正是"原型感"最刺眼的来源。

## 面板不再模拟写实石材，改成三块低多边形色面。微弱明暗差负责体积感，
## 不使用噪声纹理、雕刻或高光描边。
const COLOR_PLATE := Color(0.075, 0.13, 0.075, 0.94)
const COLOR_PLATE_INNER := Color(0.13, 0.23, 0.13, 0.91)
const COLOR_PLATE_FACET := Color(0.23, 0.36, 0.19, 0.44)
const COLOR_EDGE := Color(0.53, 0.44, 0.22, 0.95)
const COLOR_EDGE_LIGHT := Color(0.91, 0.72, 0.34, 0.94)
const COLOR_EDGE_DARK := Color(0.19, 0.18, 0.10, 0.96)
const COLOR_PAPER := Color(0.94, 0.84, 0.62, 0.98)
const COLOR_INK := Color(0.16, 0.15, 0.10, 1.0)
## 发丝线保留为语义色的极淡版本，但不允许发光。
const COLOR_HAIRLINE := Color(0.78, 0.65, 0.35, 0.34)
## 进度条的空槽。
const COLOR_TRACK := Color(0.08, 0.11, 0.07, 0.92)
## 大面积衬底（小地图这种"内容区"用，比面板更透，避免糊住地形缩略图）。
const COLOR_GLASS := Color(0.08, 0.20, 0.11, 0.78)

# 面板不是一种材质，而是一套共享轮廓下的材质家族。调用方按语义选皮肤：
# 生命、护盾、奖励、交互、队伍各有自己的主色和斜切方向，避免所有组件像同一块板缩放。
const PLATE_FOREST := 0
const PLATE_HEALTH := 1
const PLATE_SHIELD := 2
const PLATE_GOLD := 3
const PLATE_CREAM := 4
const PLATE_STEEL := 5

# ---------------------------------------------------------------- 几何度量

## 【切角边长】整套 UI 的签名。项目场景是低多边形切面几何，
## 界面若用圆角就与场景语言对冲 —— 这里一律切角，不用圆角。
const BEVEL := 7.0
## 1152 逻辑画布映射到 1080p 时，1.5 逻辑像素至少约 2 个物理像素。
const HAIRLINE_WIDTH := 1.5
## 进度条这类矮元素的切角（太大在 10px 高的条上会吃掉整段）。
const BAR_BEVEL := 5.0
## 内嵌层相对外板的内缩量。
const PLATE_INSET := 3.0

## 面板圆角 / 内边距等度量，同样只在这里定义一次。
## RADIUS 保留为 0：走 Theme 的那部分控件（菜单按钮）也统一成直角，
## 与 HUD 的切角语言同属"棱角分明"一族，不再混用两种转角。
const RADIUS := 0
const PAD_H := 12

static var _cached: Theme


## 项目内置、可随游戏分发的中英文字体。手绘 HUD 与普通控件使用同一资源。
static func get_font() -> Font:
	var theme := get_theme()
	return theme.default_font if theme.default_font != null else ThemeDB.fallback_font


## 取全局主题。首次调用时尝试读 theme/game_theme.tres，读不到就用代码构建。
static func get_theme() -> Theme:
	if _cached != null:
		return _cached
	if ResourceLoader.exists(THEME_PATH):
		var loaded: Resource = load(THEME_PATH)
		if loaded is Theme:
			_cached = loaded as Theme
			# 用 print 而不是 push_warning：警告在 release 版本里可能被剥离，
			# 而这个"主题到底来自哪"的结论必须能在导出版本里被看到。
			print("[界面] 主题已加载：", THEME_PATH)
			return _cached
		push_error("UiTheme: %s 存在但不是 Theme，改用代码默认主题。" % THEME_PATH)
	else:
		# 必须明确报出来而不是静默降级：这个文件不在包里（例如导出漏了
		# include_filter）时游戏照样能跑，只是配色全部退回代码默认值 ——
		# 那种"看起来正常"的失效最难发现。
		push_error("UiTheme: 找不到 %s，改用代码默认主题。" % THEME_PATH)
	print("[界面] 主题来自代码默认值（未使用 game_theme.tres）")
	_cached = build_default_theme()
	return _cached


## 用当前代码默认值构建主题。除了内部兜底，也被"生成 game_theme.tres"的一次性
## 脚本调用 —— 这样磁盘上的资源与代码默认值从一开始就是一致的。
static func build_default_theme() -> Theme:
	var theme := Theme.new()
	if ResourceLoader.exists(FONT_PATH):
		var game_font := FontVariation.new()
		game_font.base_font = load(FONT_PATH) as Font
		game_font.variation_opentype = {0x77676874: 600}
		theme.default_font = game_font
	_add_label_variation(theme, VARIATION_TITLE, 58, COLOR_TITLE)
	_add_label_variation(theme, VARIATION_BODY, 19, COLOR_BODY)
	_add_label_variation(theme, VARIATION_DIM, 17, COLOR_DIM)
	_add_label_variation(theme, VARIATION_HUD_ABILITIES, 20, COLOR_ACCENT)
	_add_label_variation(theme, VARIATION_HUD_TIME, 20, COLOR_BODY)
	_add_label_variation(theme, VARIATION_HUD_WEAPON, 18, COLOR_AMMO)

	_add_button_styles(theme)
	return theme


## Label 变体：一个字号 + 一个颜色，外加统一的描边阴影（保证在任何背景上都可读）。
static func _add_label_variation(
	theme: Theme, variation: String, font_size: int, color: Color
) -> void:
	theme.set_type_variation(variation, "Label")
	theme.set_font_size("font_size", variation, font_size)
	theme.set_color("font_color", variation, color)
	theme.set_color("font_shadow_color", variation, COLOR_SHADOW)
	theme.set_constant("shadow_offset_x", variation, 2)
	theme.set_constant("shadow_offset_y", variation, 2)


## 按钮样式：菜单是纯代码构建的，原先只有系统默认外观（灰色方块），
## 和游戏的色彩体系完全不搭。这里给一套带描边与悬停高亮的扁平样式。
static func _add_button_styles(theme: Theme) -> void:
	theme.set_font_size("font_size", "Button", 21)
	theme.set_color("font_color", "Button", COLOR_BODY)
	theme.set_color("font_hover_color", "Button", COLOR_ACCENT)
	theme.set_color("font_pressed_color", "Button", COLOR_ACCENT)
	theme.set_color("font_focus_color", "Button", COLOR_ACCENT)
	theme.set_color("font_disabled_color", "Button", COLOR_DIM)

	# 常态按钮用【氧化青铜】包边而不是青色：满屏的青色留给"当前可交互"（悬停 / 按下），
	# 常态按钮安静下来，整块菜单才有一层"石头底 + 一点金属"的层次。
	var normal := StyleBoxFlat.new()
	normal.bg_color = Color(0.12, 0.24, 0.13, 0.94)
	normal.border_color = COLOR_EDGE
	normal.set_border_width_all(2)
	normal.set_corner_radius_all(RADIUS)
	normal.content_margin_left = PAD_H + 6
	normal.content_margin_right = PAD_H + 6
	normal.content_margin_top = 8
	normal.content_margin_bottom = 8
	theme.set_stylebox("normal", "Button", normal)
	theme.set_stylebox("disabled", "Button", normal)

	var hover := normal.duplicate() as StyleBoxFlat
	hover.bg_color = COLOR_PAPER
	hover.border_color = COLOR_EDGE_LIGHT
	theme.set_color("font_hover_color", "Button", COLOR_INK)
	# 焦点框没有实心浅色底，不能沿用悬停态的深色文字；键盘焦点单独用青色。
	theme.set_color("font_focus_color", "Button", COLOR_ACCENT)
	theme.set_stylebox("hover", "Button", hover)

	var pressed := hover.duplicate() as StyleBoxFlat
	pressed.bg_color = Color(0.88, 0.70, 0.39, 1.0)
	theme.set_color("font_pressed_color", "Button", COLOR_INK)
	theme.set_stylebox("pressed", "Button", pressed)

	# 焦点框只画边框、不画底，避免和 normal 叠成两层色块。
	var focus := hover.duplicate() as StyleBoxFlat
	focus.draw_center = false
	focus.set_border_width_all(2)
	theme.set_stylebox("focus", "Button", focus)


# ================================================================ 共享绘制原语
#
# 下面这些是【所有 HUD 控件共用的画笔】。为什么必须收在一处：
#
#   面板的切角尺寸、包边粗细、发丝线的淡度，只要有一个控件自己写一份，
#   同屏两块面板就会长得不一样 —— 观众说不出哪里怪，但一眼就觉得"拼凑"。
#   统一形状比统一颜色更重要，因为形状是轮廓，轮廓先被看到。
#
# 用法：控件在自己的 _draw() 里调——
#
#     UiThemeUtil.draw_plate(self, Rect2(Vector2.ZERO, size))
#
# 【允许 self 之外的实例调用 draw_*】：Godot 只在"该控件正处于 NOTIFICATION_DRAW
# 中"时才允许绘制，而这里传进来的 ci 正是那个正在绘制的控件（drawing 标志为真），
# 所以从静态函数里调 ci.draw_* 与在 _draw() 里直接写是等价的。


## 返回一个颜色的同色变体，只改透明度。
static func with_alpha(color: Color, alpha: float) -> Color:
	return Color(color.r, color.g, color.b, alpha)


## 提亮 / 压暗。amount > 0 提亮，< 0 压暗。用于从基色派生高光与暗部，
## 避免同一个色系里出现几个"差不多但不相等"的手写色值。
static func shade(color: Color, amount: float) -> Color:
	if amount >= 0.0:
		return color.lerp(Color(1.0, 1.0, 1.0, color.a), amount)
	return color.lerp(Color(0.0, 0.0, 0.0, color.a), -amount)


## 把点列表首尾连上，供 draw_polyline 使用（它不会自动闭合）。
static func closed(points: PackedVector2Array) -> PackedVector2Array:
	if points.is_empty():
		return points
	var out := points.duplicate()
	out.append(points[0])
	return out


## 中性黑色玻璃。轮廓由调用者决定，本函数只负责统一材质：清晰边缘、
## 半透明黑色主体和非常克制的内部明暗层次。没有彩色玻璃、厚包边或外发光。
static func draw_black_glass(ci: CanvasItem, points: PackedVector2Array) -> void:
	if points.size() < 3:
		return
	var shadow := points.duplicate()
	for i in range(shadow.size()):
		shadow[i] += Vector2(1.0, 2.0)
	ci.draw_colored_polygon(shadow, Color(0.0, 0.0, 0.0, 0.18))
	var min_x := INF
	var max_x := -INF
	var min_y := INF
	var max_y := -INF
	for point in points:
		min_x = minf(min_x, point.x)
		max_x = maxf(max_x, point.x)
		min_y = minf(min_y, point.y)
		max_y = maxf(max_y, point.y)
	var span := maxf(max_y - min_y, 1.0)
	var colors := PackedColorArray()
	for point in points:
		var depth := clampf((point.y - min_y) / span, 0.0, 1.0)
		colors.append(Color(0.012, 0.013, 0.015, lerpf(0.62, 0.50, depth)))
	ci.draw_polygon(points, colors)
	# 宽而淡的内部折射面。它完全收在轮廓里，只改变亮度，不给玻璃染色。
	var width := maxf(max_x - min_x, 1.0)
	var inset := minf(3.0, span * 0.12)
	var reflection := PackedVector2Array([
		Vector2(min_x + width * 0.08, min_y + inset),
		Vector2(min_x + width * 0.40, min_y + inset),
		Vector2(min_x + width * 0.27, max_y - inset),
		Vector2(min_x + width * 0.02, max_y - inset),
	])
	ci.draw_colored_polygon(reflection, Color(1.0, 1.0, 1.0, 0.045))
	# 这条线不是装饰边框，而是玻璃断面的一丝中性反光；透明度刻意压低。
	ci.draw_polyline(closed(points), Color(0.88, 0.90, 0.90, 0.11), 0.8, true)


## 切角矩形的八个顶点（左上 / 右上 / 右下 / 左下各切一刀）。
## 切角量会被夹到短边的一半，所以极扁的条也能安全调用。
static func bevel_points(rect: Rect2, bevel: float) -> PackedVector2Array:
	var b := clampf(bevel, 0.0, minf(rect.size.x, rect.size.y) * 0.5)
	var p := rect.position
	var s := rect.size
	return PackedVector2Array([
		p + Vector2(b, 0.0),
		p + Vector2(s.x - b, 0.0),
		p + Vector2(s.x, b),
		p + Vector2(s.x, s.y - b),
		p + Vector2(s.x - b, s.y),
		p + Vector2(b, s.y),
		p + Vector2(0.0, s.y - b),
		p + Vector2(0.0, b),
	])


## 四段斜切边压亮。这是整套 UI 的"签名笔"：同一套面板并排时才像一个设计师画的。
static func draw_corner_bevels(
	ci: CanvasItem, rect: Rect2, accent: Color,
	edge_color: Color = COLOR_EDGE_LIGHT, bevel: float = BEVEL
) -> void:
	var b := minf(bevel, minf(rect.size.x, rect.size.y) * 0.5)
	if b <= 1.0:
		return
	var p := rect.position
	var s := rect.size
	var c := edge_color
	ci.draw_line(p + Vector2(b, 0.0), p + Vector2(0.0, b), c, 1.8, true)
	ci.draw_line(p + Vector2(s.x - b, 0.0), p + Vector2(s.x, b), c, 1.8, true)
	ci.draw_line(p + Vector2(s.x, s.y - b), p + Vector2(s.x - b, s.y), c, 1.8, true)
	ci.draw_line(p + Vector2(b, s.y), p + Vector2(0.0, s.y - b), c, 1.8, true)


## 标准面板：投影 → 森林绿底 → 内层切面 → 暖金边角。所有形状都是直线与折线，
## 与场景中的低多边形岩石、树冠使用同一种轮廓语言。
static func plate_palette(variant: int) -> Array[Color]:
	match variant:
		PLATE_HEALTH:
			return [
				Color(0.18, 0.045, 0.035, 0.97), Color(0.54, 0.15, 0.10, 0.96),
				Color(0.98, 0.42, 0.25, 0.96), Color(0.25, 0.075, 0.055, 0.94),
				Color(0.48, 0.12, 0.075, 0.48),
			]
		PLATE_SHIELD:
			return [
				Color(0.025, 0.11, 0.13, 0.97), Color(0.055, 0.43, 0.47, 0.96),
				Color(0.30, 0.94, 0.95, 0.96), Color(0.045, 0.19, 0.21, 0.94),
				Color(0.08, 0.38, 0.42, 0.48),
			]
		PLATE_GOLD:
			return [
				Color(0.20, 0.14, 0.045, 0.97), Color(0.62, 0.42, 0.10, 0.96),
				Color(1.0, 0.78, 0.30, 0.98), Color(0.29, 0.22, 0.075, 0.94),
				Color(0.48, 0.35, 0.10, 0.50),
			]
		PLATE_CREAM:
			return [
				Color(0.26, 0.19, 0.085, 0.98), Color(0.66, 0.49, 0.20, 0.98),
				Color(1.0, 0.88, 0.59, 1.0), Color(0.86, 0.75, 0.49, 0.98),
				Color(0.98, 0.86, 0.60, 0.52),
			]
		PLATE_STEEL:
			return [
				Color(0.075, 0.10, 0.085, 0.97), Color(0.31, 0.39, 0.30, 0.96),
				Color(0.70, 0.76, 0.55, 0.94), Color(0.14, 0.19, 0.15, 0.94),
				Color(0.25, 0.32, 0.23, 0.45),
			]
	return [COLOR_EDGE_DARK, COLOR_EDGE, COLOR_EDGE_LIGHT, COLOR_PLATE_INNER, COLOR_PLATE_FACET]


static func plate_bevel(variant: int) -> float:
	match variant:
		PLATE_HEALTH:
			return BEVEL + 2.0
		PLATE_SHIELD:
			return BEVEL - 1.0
		PLATE_STEEL:
			return BEVEL - 2.0
		PLATE_GOLD:
			return BEVEL + 1.0
	return BEVEL


static func draw_plate(
	ci: CanvasItem, rect: Rect2, accent: Color = COLOR_HAIRLINE,
	variant: int = PLATE_FOREST
) -> void:
	if rect.size.x <= 4.0 or rect.size.y <= 4.0:
		return
	var palette := plate_palette(variant)
	var outer_dark: Color = palette[0]
	var rim_color: Color = palette[1]
	var rim_light: Color = palette[2]
	var inner_color: Color = palette[3]
	var facet_color: Color = palette[4]
	var bevel := plate_bevel(variant)
	var shadow_rect := Rect2(rect.position + Vector2(2.0, 3.0), rect.size)
	ci.draw_colored_polygon(bevel_points(shadow_rect, bevel), with_alpha(COLOR_SHADOW, 0.52))
	var outer := bevel_points(rect, bevel)
	ci.draw_colored_polygon(outer, outer_dark)
	ci.draw_polyline(closed(outer), with_alpha(rim_light, 0.76), HAIRLINE_WIDTH, true)

	# 金属包边不是一根线：先铺青铜中层，再内嵌深色槽，细小面积也能读出厚度。
	var rim_rect := rect.grow(-1.25)
	var rim := bevel_points(rim_rect, bevel - 1.25)
	ci.draw_colored_polygon(rim, rim_color)
	var inner_rect := rect.grow(-PLATE_INSET)
	var inner_bevel := maxf(bevel - PLATE_INSET, 1.0)
	var inner := bevel_points(inner_rect, inner_bevel)
	ci.draw_colored_polygon(inner, inner_color)

	# 两块明确的色面，比一整块半透明渐变更贴近场景的低多边形材质。
	var p := inner_rect.position
	var s := inner_rect.size
	if s.x > 18.0 and s.y > 12.0:
		ci.draw_colored_polygon(PackedVector2Array([
			p + Vector2(inner_bevel, 0.0), p + Vector2(s.x * 0.42, 0.0),
			p + Vector2(s.x * 0.31, s.y), p + Vector2(inner_bevel, s.y),
			p + Vector2(0.0, s.y - inner_bevel), p + Vector2(0.0, inner_bevel),
		]), facet_color)
		ci.draw_colored_polygon(PackedVector2Array([
			p + Vector2(s.x * 0.72, 0.0), p + Vector2(s.x, 0.0),
			p + Vector2(s.x, s.y * 0.56), p + Vector2(s.x * 0.88, s.y),
			p + Vector2(s.x * 0.62, s.y),
		]), with_alpha(shade(inner_color, -0.32), 0.42))

	# 顶亮、底暗与两枚角铆片共同建立“薄而精”的镶边，不增加面板占地。
	ci.draw_line(
		p + Vector2(inner_bevel, 0.5), p + Vector2(s.x - inner_bevel, 0.5),
		with_alpha(rim_light, 0.58), HAIRLINE_WIDTH, true
	)
	ci.draw_line(
		p + Vector2(maxf(BEVEL - PLATE_INSET, 1.0), s.y - 0.5),
		p + Vector2(s.x - maxf(BEVEL - PLATE_INSET, 1.0), s.y - 0.5),
		with_alpha(COLOR_SHADOW, 0.80), HAIRLINE_WIDTH, true
	)
	ci.draw_colored_polygon(PackedVector2Array([
		rect.position + Vector2(bevel, 0.0), rect.position + Vector2(bevel + 11.0, 0.0),
		rect.position + Vector2(bevel + 6.0, PLATE_INSET), rect.position + Vector2(bevel - 2.0, PLATE_INSET),
	]), with_alpha(accent, 0.46))
	ci.draw_colored_polygon(PackedVector2Array([
		rect.end - Vector2(bevel, 0.0), rect.end - Vector2(bevel + 11.0, 0.0),
		rect.end - Vector2(bevel + 6.0, PLATE_INSET), rect.end - Vector2(bevel - 2.0, PLATE_INSET),
	]), with_alpha(accent, 0.22))
	ci.draw_polyline(closed(inner), with_alpha(accent, 0.28), HAIRLINE_WIDTH, true)

	_draw_plate_signature(ci, rect, variant, accent, rim_light, bevel)
	draw_corner_bevels(ci, rect, accent, rim_light, bevel)


## 每个材质家族的一笔“身份证”。轮廓语言仍然统一，但不再只有换色：
## 红色是斜向装甲缝、青色是双轨能量线、金色是端部箭羽、钢色是铆钉。
static func _draw_plate_signature(
	ci: CanvasItem, rect: Rect2, variant: int, accent: Color,
	rim_light: Color, bevel: float
) -> void:
	var p := rect.position
	var s := rect.size
	match variant:
		PLATE_HEALTH:
			var x := p.x + s.x - bevel - 11.0
			ci.draw_line(Vector2(x, p.y + 5.0), Vector2(x + 6.0, p.y + 11.0),
				with_alpha(rim_light, 0.62), HAIRLINE_WIDTH, true)
			ci.draw_line(Vector2(x + 5.0, p.y + 5.0), Vector2(x + 11.0, p.y + 11.0),
				with_alpha(accent, 0.56), HAIRLINE_WIDTH, true)
		PLATE_SHIELD:
			var left := p.x + bevel + 10.0
			var right := p.x + s.x - bevel - 10.0
			if right > left:
				ci.draw_line(Vector2(left, p.y + 2.0), Vector2(right, p.y + 2.0),
					with_alpha(rim_light, 0.66), HAIRLINE_WIDTH, true)
				ci.draw_line(Vector2(left + 7.0, p.y + s.y - 2.0), Vector2(right, p.y + s.y - 2.0),
					with_alpha(accent, 0.48), HAIRLINE_WIDTH, true)
		PLATE_GOLD:
			var mid_y := p.y + s.y * 0.5
			ci.draw_colored_polygon(PackedVector2Array([
				Vector2(p.x + 3.0, mid_y), Vector2(p.x + bevel + 5.0, p.y + 3.0),
				Vector2(p.x + bevel + 9.0, p.y + 3.0), Vector2(p.x + bevel + 3.0, mid_y),
				Vector2(p.x + bevel + 9.0, p.y + s.y - 3.0), Vector2(p.x + bevel + 5.0, p.y + s.y - 3.0),
			]), with_alpha(rim_light, 0.30))
			ci.draw_colored_polygon(PackedVector2Array([
				Vector2(p.x + s.x - 3.0, mid_y), Vector2(p.x + s.x - bevel - 5.0, p.y + 3.0),
				Vector2(p.x + s.x - bevel - 9.0, p.y + 3.0), Vector2(p.x + s.x - bevel - 3.0, mid_y),
				Vector2(p.x + s.x - bevel - 9.0, p.y + s.y - 3.0), Vector2(p.x + s.x - bevel - 5.0, p.y + s.y - 3.0),
			]), with_alpha(rim_light, 0.30))
		PLATE_STEEL:
			var rivet := with_alpha(rim_light, 0.64)
			ci.draw_circle(p + Vector2(bevel + 3.0, 4.0), 1.2, rivet)
			ci.draw_circle(p + Vector2(s.x - bevel - 3.0, s.y - 4.0), 1.2, rivet)
		PLATE_CREAM:
			ci.draw_line(
				p + Vector2(bevel + 5.0, s.y - 3.0),
				p + Vector2(minf(s.x * 0.38, s.x - bevel - 5.0), s.y - 3.0),
				with_alpha(accent, 0.48), HAIRLINE_WIDTH, true
			)


## 渐隐分隔线：从 accent 渐隐到透明。比一根等宽白线"贵气"，
## 因为它暗示了光从哪一侧来。
static func draw_divider(ci: CanvasItem, start: Vector2, length: float, accent: Color) -> void:
	if length <= 1.0:
		return
	var pts := PackedVector2Array([
		start,
		start + Vector2(length, 0.0),
		start + Vector2(length, HAIRLINE_WIDTH),
		start + Vector2(0.0, HAIRLINE_WIDTH),
	])
	var cols := PackedColorArray([
		with_alpha(accent, 0.55),
		with_alpha(accent, 0.05),
		with_alpha(accent, 0.05),
		with_alpha(accent, 0.55),
	])
	ci.draw_polygon(pts, cols)


## 分段进度条（血条 / 护盾 / 弹药条通用）。
##
## ratio  当前比例 0..1
## ghost  【伤害残影】比实际值"慢一步"的比例，传 <0 表示不画。
##        调用方每帧把 ghost 向 ratio 收拢 —— 实色盖不到的那一截就是刚掉的血。
##        静态血条永远像占位图，就差这一笔。
## segments 分成几格，1 或 0 表示不分格。
static func draw_bar(
	ci: CanvasItem,
	rect: Rect2,
	ratio: float,
	fill: Color,
	segments: int = 0,
	ghost: float = -1.0
) -> void:
	if rect.size.x <= 1.0 or rect.size.y <= 1.0:
		return
	var b := minf(BAR_BEVEL, rect.size.y * 0.5)

	var track := bevel_points(rect, b)
	ci.draw_colored_polygon(track, COLOR_TRACK)
	ci.draw_polyline(closed(track), Color(1.0, 1.0, 1.0, 0.10), HAIRLINE_WIDTH, true)

	var shown := clampf(ratio, 0.0, 1.0)

	if ghost > shown:
		var g := clampf(ghost, 0.0, 1.0)
		ci.draw_colored_polygon(
			bevel_points(Rect2(rect.position, Vector2(rect.size.x * g, rect.size.y)), b),
			Color(1.0, 1.0, 1.0, 0.20)
		)

	if shown > 0.0:
		var fill_rect := Rect2(rect.position, Vector2(rect.size.x * shown, rect.size.y))
		ci.draw_colored_polygon(
			bevel_points(fill_rect, minf(b, fill_rect.size.x * 0.5)), fill
		)
		# 下半面略暗，形成参考稿中进度条的晶体切面。
		if fill_rect.size.x > 5.0 and fill_rect.size.y > 5.0:
			var fp := fill_rect.position
			var fs := fill_rect.size
			ci.draw_colored_polygon(PackedVector2Array([
				fp + Vector2(1.0, fs.y * 0.58), fp + Vector2(fs.x - 1.0, fs.y * 0.58),
				fp + Vector2(fs.x - b, fs.y - 1.0), fp + Vector2(b, fs.y - 1.0),
			]), with_alpha(shade(fill, -0.32), 0.48))
		# 顶端一线高光：给填充块"厚度"。
		if fill_rect.size.x > 3.0:
			ci.draw_line(
				Vector2(fill_rect.position.x + 1.0, fill_rect.position.y + 1.0),
				Vector2(fill_rect.end.x - 1.0, fill_rect.position.y + 1.0),
				with_alpha(shade(fill, 0.45), 0.55),
				HAIRLINE_WIDTH, true
			)

	if segments > 1:
		var tick := Color(0.0, 0.0, 0.0, 0.45)
		for i in range(1, segments):
			var x := rect.position.x + rect.size.x * float(i) / float(segments)
			ci.draw_line(
				Vector2(x, rect.position.y + 1.0), Vector2(x, rect.end.y - 1.0), tick, HAIRLINE_WIDTH, true
			)


## 标签小牌（"LV 3" / "阶段 2" / "首领"）。整套 UI 里所有"贴上去的小牌子"都用它 ——
## 武器面板的等级徽标、波次横幅的阶段号、Boss 条的首领标记必须是同一个形状，
## 否则它们就只是三个各自为政的小方块。
##
## 返回小牌占用的宽度，方便调用方紧接着排下一个元素。
static func draw_tag(
	ci: CanvasItem, font: Font, pos: Vector2, text: String,
	size: int, accent: Color, tracking: float = 1.2
) -> float:
	var w := tracked_width(font, text, size, tracking) + 16.0
	var rect := Rect2(pos, Vector2(w, float(size) + 6.0))
	var pts := bevel_points(rect, 4.0)
	ci.draw_colored_polygon(pts, COLOR_PAPER)
	ci.draw_polyline(closed(pts), with_alpha(accent, 0.78), HAIRLINE_WIDTH, true)
	draw_tracked(
		ci, font, Vector2(rect.position.x + 8.0, rect.position.y + float(size) + 1.0),
		text, size, COLOR_INK, tracking
	)
	return w


## 带字距的文本。Godot 的 draw_string 不支持字距，而"小号大写 + 宽字距"
## 是不引入字体资源、也能让默认字体看起来被设计过的最省力手段。
static func draw_tracked(
	ci: CanvasItem, font: Font, pos: Vector2, text: String,
	size: int, color: Color, tracking: float = 0.0
) -> void:
	if tracking <= 0.0 or text.length() < 2:
		ci.draw_string(font, pos, text, HORIZONTAL_ALIGNMENT_LEFT, -1, size, color)
		return
	var x := pos.x
	for i in text.length():
		var ch := text.substr(i, 1)
		ci.draw_string(font, Vector2(x, pos.y), ch, HORIZONTAL_ALIGNMENT_LEFT, -1, size, color)
		x += font.get_string_size(ch, HORIZONTAL_ALIGNMENT_LEFT, -1, size).x + tracking


## 与 draw_tracked 配套的宽度测量，用于右对齐与居中的场合。
static func tracked_width(font: Font, text: String, size: int, tracking: float) -> float:
	var w := font.get_string_size(text, HORIZONTAL_ALIGNMENT_LEFT, -1, size).x
	if tracking > 0.0 and text.length() > 1:
		w += tracking * float(text.length() - 1)
	return w
