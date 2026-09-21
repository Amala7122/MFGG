extends CanvasLayer
## 游戏流程（autoload）：主菜单 → 游戏 → 暂停 → 死亡结算。
##
## 全部 UI 由代码构建，不新增任何 .tscn —— 与 PlayerHUD 的做法一致，
## 这样流程层可以整体作为 autoload 存在，不需要改动任何现有场景。
##
## 状态机：MENU → PLAYING ⇄ PAUSED，PLAYING → DYING → GAME_OVER → （重开）PLAYING
##
## 注意 process_mode 必须是 ALWAYS：暂停时整个场景树停摆，但流程层自己
## 还要能响应 ESC 和按钮，否则一旦暂停就再也退不出来。

const AudioUtil := preload("res://scripts/audio_manager.gd")
const SaveUtil := preload("res://scripts/save_manager.gd")
const PoolUtil := preload("res://scripts/object_pool.gd")
const EventBusUtil := preload("res://scripts/event_bus.gd")
const RunStateUtil := preload("res://scripts/run_state.gd")
const ArenaUtil := preload("res://scripts/arena.gd")
const DisplaySettingsUtil := preload("res://scripts/display_settings.gd")

static var instance: Node

## STAGE_CLEAR：一个阶段的 Boss 被击败。它与 GAME_OVER 的区别是"还有下一张图"，
## 所以它给的是"进入下一区域"而不是"再来一局"。
enum State { MENU, PLAYING, PAUSED, DYING, GAME_OVER, STAGE_CLEAR, DISPLAY_SETTINGS }

## 配色与控件样式统一来自 UiTheme —— 本文件原先自带一套 COLOR_*，
## 与 PlayerHUD 那套已经开始漂移（"标题色"两边已经不是同一个值了）。
const UiThemeUtil := preload("res://scripts/ui_theme.gd")
## 菜单外框。与 HUD 共用同一支 draw_plate 画笔 —— 见 MenuPanel 文件头。
const MenuPanelScript := preload("res://scripts/menu_panel.gd")
## 带字距的小号标签（副标题 / 提示行）。Label 画不出字距，而"小号 + 宽字距"
## 是这套 UI 里固定的一档排版。
const TrackedLabelScript := preload("res://scripts/tracked_label.gd")
## 单行读数板。暂停 / 阵亡 / 肃清屏上的统计数字复用它 ——
## HUD 上的"击杀""生存"就是这一块，两边同形。
const ReadoutPlateScript := preload("res://scripts/readout_plate.gd")

## 面板内容的最小宽度。三个屏幕（菜单 / 暂停 / 结算）共用同一个值，
## 否则切界面时整个面板会横向抽动一下。
const COLUMN_WIDTH := 620.0
## 按钮宽度。面板按内容撑开，而按钮必须自己收窄 —— 否则会跟着面板铺满整行。
const BUTTON_WIDTH := 300.0
## 按钮高度。50 会给主菜单凑出超出一屏的总高（窗口默认 648），44 是
## "仍然好点"与"四个按钮排得下"的交点。
const BUTTON_HEIGHT := 44.0
## 统计读数板的尺寸。
const STAT_WIDTH := 168.0
const STAT_HEIGHT := 34.0

var state: State = State.MENU

var _root: Control
## 菜单石板。三种屏幕共用它，只换强调色与文案。
var _panel: MenuPanelScript
var _caption: TrackedLabelScript
var _title: Label
var _body: Label
var _hint: TrackedLabelScript
var _actions: VBoxContainer
## 关卡选择那一行。测试时不用每次从第一张图打过来。
var _arena_row: HBoxContainer
## 统计读数行。暂停 / 阵亡 / 肃清各有各的三块，菜单下整行隐藏。
var _stats_row: HBoxContainer
## 选中的起始关卡。空 = 按正常顺序从第一张开始。
var _start_arena := ""
## 显示设置是菜单与暂停界面共用的子页；返回时必须知道从哪一页进来。
var _display_settings_return_state: State = State.MENU


func _ready() -> void:
	instance = self
	layer = 100
	process_mode = Node.PROCESS_MODE_ALWAYS
	# 订阅事件总线。放在这里（而不是等玩家死亡时才建立联系）是因为
	# 本节点是 autoload，生命周期覆盖整局，没有"错过事件"的风险。
	EventBusUtil.subscribe_player_died(_enter_game_over)
	# 阶段清空由 wave_director 广播。推进节奏（弹面板、换图）属于流程层，
	# 战斗节点只负责报告"这里清干净了"。
	EventBusUtil.subscribe_stage_cleared(_enter_stage_cleared)
	_build_ui()
	# 等一帧：让场景里的 Player._ready() 先跑完（它会把鼠标设为捕获态），
	# 再进菜单把鼠标交还给用户。
	await get_tree().process_frame
	_enter_menu()


# ---------------------------------------------------------------- 静态入口

static func is_playing() -> bool:
	return instance != null and instance.get("state") == State.PLAYING


## 玩家倒地动画开始后先封住暂停与波次推进，场景本身保持运行以播放动画。
static func begin_death_transition() -> void:
	if instance != null and instance.get("state") == State.PLAYING:
		instance.set("state", State.DYING)


# ---------------------------------------------------------------- UI 构建

func _build_ui() -> void:
	_root = Control.new()
	_root.set_anchors_preset(Control.PRESET_FULL_RECT)
	_root.mouse_filter = Control.MOUSE_FILTER_STOP
	# 主题挂在这一个根节点上就会向下传播给全部子控件（按钮样式、字号都在主题里）。
	_root.theme = UiThemeUtil.get_theme()
	add_child(_root)

	var dim := ColorRect.new()
	dim.color = Color(0.02, 0.03, 0.05, 0.80)
	dim.set_anchors_preset(Control.PRESET_FULL_RECT)
	dim.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_root.add_child(dim)

	var center := CenterContainer.new()
	center.set_anchors_preset(Control.PRESET_FULL_RECT)
	center.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_root.add_child(center)

	# 【石板外框】原先菜单是直接压在半透明暗幕上的一堆文字，与 HUD 的切角石板
	# 完全不在一个世界。现在三种屏幕共用同一块石板，只换强调色。
	_panel = MenuPanelScript.new()
	_panel.name = "MenuPanel"
	center.add_child(_panel)

	# 列宽写死而不是跟着文字走：三种屏幕的正文长短差别很大，
	# 让容器按内容撑开的话，切一次界面整块石板会横向抽动一下。
	var column := VBoxContainer.new()
	column.custom_minimum_size = Vector2(COLUMN_WIDTH, 0.0)
	column.alignment = BoxContainer.ALIGNMENT_CENTER
	column.add_theme_constant_override("separation", 12)
	_panel.add_child(column)

	# 副标题：小号拉丁字母 + 宽字距。它不承载信息，只承担"这一屏是什么语境" ——
	# 中文标题在上、拉丁副题在下，是让默认字体看起来被设计过的最省力组合。
	_caption = TrackedLabelScript.new()
	_caption.font_size = 12
	_caption.tracking = 5.0
	column.add_child(_caption)

	_title = _make_label(UiThemeUtil.VARIATION_TITLE)
	column.add_child(_title)
	# 标题下那道分隔线由面板画（它需要在标题的【实际】下沿，见 MenuPanel）。
	_panel.rule_anchor = _title

	_body = _make_label(UiThemeUtil.VARIATION_DIM)
	_body.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	column.add_child(_body)

	# 关卡选择行放在正文与按钮之间：它属于"这一局怎么开"的一部分，
	# 所以必须在按"开始游戏"【之前】就能看到自己选了什么。
	_arena_row = HBoxContainer.new()
	_arena_row.alignment = BoxContainer.ALIGNMENT_CENTER
	_arena_row.add_theme_constant_override("separation", 8)
	column.add_child(_arena_row)

	# 统计读数行：暂停 / 阵亡 / 肃清各给三块。它用的是 HUD 上"击杀""生存"
	# 那块同一个控件 —— 于是"这局打得怎么样"在菜单里和战斗中长得一样。
	_stats_row = HBoxContainer.new()
	_stats_row.alignment = BoxContainer.ALIGNMENT_CENTER
	_stats_row.add_theme_constant_override("separation", 12)
	_stats_row.visible = false
	column.add_child(_stats_row)

	_actions = VBoxContainer.new()
	_actions.alignment = BoxContainer.ALIGNMENT_CENTER
	_actions.add_theme_constant_override("separation", 6)
	column.add_child(_actions)

	_hint = TrackedLabelScript.new()
	_hint.font_size = 11
	_hint.tracking = 2.0
	column.add_child(_hint)


## 字号与颜色由主题变体决定，这里不再逐个 add_theme_*_override。
func _make_label(variation: String) -> Label:
	var label := Label.new()
	label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	label.theme_type_variation = variation
	return label


## 一屏的公共部分：副标题文案 + 强调色 + 提示行 + 入场动效。
##
## 三种屏幕（菜单 / 暂停 / 结算）的差别只有文案、统计数字与按钮，
## 形状与动效完全一样 —— 所以这里收成一个入口，避免三处各写一遍
## （以前三个 _enter_* 各写四五行动画代码的那种分叉，正是要避免的）。
func _present(caption: String, accent: Color, hint: String, stats: Array = []) -> void:
	_caption.text = caption
	_caption.color = UiThemeUtil.with_alpha(accent, 0.72)
	_hint.text = hint
	_hint.color = UiThemeUtil.with_alpha(UiThemeUtil.COLOR_DIM, 0.7)
	# 标题跟着强调色走：阵亡是红的、肃清是金的、常态是青的 ——
	# 一眼就能分清"现在是哪种中断"，不需要读文字。
	_title.add_theme_color_override("font_color", accent)
	_panel.configure(accent)
	_set_stats(stats)
	_set_overlay_visible(true)
	_panel.play_entrance()


## 装满统计读数行。entries 为 [{ "label": String, "value": String, "sub": String }]。
## 传空数组就是整行隐藏 —— 主菜单不需要任何统计数字。
func _set_stats(entries: Array) -> void:
	for child in _stats_row.get_children():
		child.queue_free()
	_stats_row.visible = not entries.is_empty()
	for entry in entries:
		var plate := ReadoutPlateScript.new()
		plate.custom_minimum_size = Vector2(STAT_WIDTH, STAT_HEIGHT)
		plate.configure(UiThemeUtil.COLOR_ACCENT)
		plate.set_readout(
			String(entry.get("label", "")),
			String(entry.get("value", "")),
			String(entry.get("sub", ""))
		)
		_stats_row.add_child(plate)


## 清空关卡选择行。它不是"只在菜单里存在"就够了 —— 暂停时如果不清，
## 上一屏选关的按钮会留在那里（切屏时最容易漏的一类状态）。
func _clear_arena_row() -> void:
	for child in _arena_row.get_children():
		child.queue_free()
	_arena_row.visible = false


## 重建按钮列表。actions 为 [{ "text": String, "callback": Callable }]。
##
## 按钮逐个淡入（错开 40 毫秒）：静止地一次性出现，读起来就是"一堆控件"；
## 有先后地把视线从上往下带一遍，读起来才是"一屏菜单"。
## 首个按钮仍然立刻取得焦点，键盘用户不受动效影响。
func _set_actions(actions: Array, focus_index: int = 0) -> void:
	for child in _actions.get_children():
		child.queue_free()
	var focus_target: Button = null
	var index := 0
	for action in actions:
		var button := Button.new()
		button.text = String(action["text"])
		# size_flags 收窄 + custom_minimum_size 定宽：容器是 620 宽的列，
		# 不这么写按钮会被拉成通栏，四个等宽通栏按钮比现在要"廉价"得多。
		button.custom_minimum_size = Vector2(BUTTON_WIDTH, BUTTON_HEIGHT)
		button.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
		button.pressed.connect(action["callback"] as Callable)
		_actions.add_child(button)
		button.modulate.a = 0.0
		var tween := button.create_tween()
		tween.tween_property(button, "modulate:a", 1.0, 0.16) \
			.set_delay(0.08 + float(index) * 0.04).set_ease(Tween.EASE_OUT)
		index += 1
		if index - 1 == focus_index:
			focus_target = button
	# 默认首项；设置页切换某一项后则把焦点留在该项，键盘不会每次跳回顶部。
	if focus_target == null and _actions.get_child_count() > 0:
		focus_target = _actions.get_child(0) as Button
	if focus_target:
		focus_target.call_deferred("grab_focus")


func _set_overlay_visible(enabled: bool) -> void:
	_root.visible = enabled


# ---------------------------------------------------------------- 状态切换

func _enter_menu() -> void:
	state = State.MENU
	_title.text = "海 拉 鲁 生 存"
	# 只有一张图时，地图名从"选择行"挪进正文 —— 玩家仍然要知道自己站在哪。
	var arena_name := String(
		ArenaUtil.get_params(_first_arena_id()).get("label", _first_arena_id())
	)
	# 【正文比原先短】石板的上下内边距要占掉八十多像素，而 648 高的窗口装不下
	# 原来那九行。删掉的都是同义重复（"生存模式"说两遍、"如何输入"说三遍），
	# 信息一个没少 —— 排不下时先删重复，而不是先缩字号。
	_set_body(
		"战场：%s　生存模式　·　敌人无限刷新　·　武器随等级成长\n\n" % arena_name
		+ "WASD 移动　空格 跳跃　Shift 翻滚　Ctrl 冲刺\n"
		+ "左键 开火　右键 瞄准狙击　R 换弹　E 手雷　Q 震地脉冲\n"
		+ "V 自由观察　ESC 暂停\n"
	)
	_build_arena_row()
	_set_actions([
		{"text": "开始游戏", "callback": _on_start},
		{"text": "显示设置", "callback": _on_open_display_settings},
		{"text": "退出", "callback": _on_quit},
	])
	_present("SURVIVAL ARENA", UiThemeUtil.COLOR_ACCENT, "方向键选择　·　Enter 确认")
	get_tree().paused = true
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE


## 正文只有一个调用点这件事值得守住：它同时要管"有没有内容"（空正文会把
## 石板顶出一道空白），所以设置文案与设置可见性必须是同一个动作。
func _set_body(text: String) -> void:
	_body.text = text
	_body.visible = not text.is_empty()


## 关卡选择。顺序与名称都读竞技场表本身 —— 不在这里抄一份，
## 否则以后加了一张图、或者改了顺序，这里会安静地漏掉。
##
## 【为什么第一项就是"从哪开始"而不是额外加一个"默认"】—— 列表第一张就是
## 正常流程的起点，选中它等价于"从正常顺序开始"，不需要第二种表达方式。
func _build_arena_row() -> void:
	for child in _arena_row.get_children():
		child.queue_free()
	# 【只有一张图时不显示这一行】—— 一个按钮的"关卡选择"没有选择可言，
	# 它只会让玩家以为还有别的图没解锁。地图名改由正文显示。
	_arena_row.visible = ArenaUtil.get_order().size() > 1
	for id in ArenaUtil.get_order():
		var arena_id := String(id)
		var params := ArenaUtil.get_params(arena_id)
		var button := Button.new()
		# ▶ 标记当前选中项。不用 disabled：那读起来像"这张图不能选"，
		# 而这里的意思是"已经选好它了"。
		button.text = ("▶ %s" % params.get("label", arena_id)) if arena_id == _start_arena \
			else String(params.get("label", arena_id))
		button.custom_minimum_size = Vector2(0, 40)
		button.pressed.connect(_on_pick_arena.bind(arena_id))
		_arena_row.add_child(button)


func _on_pick_arena(arena_id: String) -> void:
	AudioUtil.play("ui")
	_start_arena = arena_id
	_build_arena_row()


## 主菜单与暂停界面共用的显示设置页。三个选项都立即应用，并由
## DisplaySettings 独立保存；这里仅负责把它们呈现成现有菜单语言。
func _on_open_display_settings() -> void:
	AudioUtil.play("ui")
	_display_settings_return_state = state
	_enter_display_settings()


func _enter_display_settings(focus_index: int = 0) -> void:
	state = State.DISPLAY_SETTINGS
	_title.text = "显 示 设 置"
	_clear_arena_row()
	var settings := DisplaySettingsUtil.instance
	if settings == null:
		_set_body("显示设置服务未加载。")
		_set_actions([{"text": "返回", "callback": _on_display_settings_back}])
	else:
		var fullscreen_note := (
			"无边框全屏使用桌面原生分辨率；窗口分辨率会保留到切回窗口模式。"
			if int(settings.get("display_mode")) == DisplaySettingsUtil.MODE_BORDERLESS
			else "窗口分辨率立即生效；无边框全屏会使用桌面原生分辨率。"
		)
		_set_body(fullscreen_note + "\nUI 缩放只改变界面尺寸，不降低 3D 清晰度。")
		_set_actions([
			{
				"text": "显示模式　< %s >" % settings.call("mode_label"),
				"callback": _on_cycle_display_mode,
			},
			{
				"text": "窗口分辨率　< %s >" % settings.call("resolution_label"),
				"callback": _on_cycle_resolution,
			},
			{
				"text": "界面缩放　< %s >" % settings.call("ui_scale_label"),
				"callback": _on_cycle_ui_scale,
			},
			{"text": "返回", "callback": _on_display_settings_back},
		], focus_index)
	_present("DISPLAY", UiThemeUtil.COLOR_ACCENT, "Enter 切换　·　ESC 返回")
	get_tree().paused = true
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE


func _on_cycle_display_mode() -> void:
	AudioUtil.play("ui")
	if DisplaySettingsUtil.instance != null:
		DisplaySettingsUtil.instance.call("cycle_display_mode")
	_enter_display_settings(0)


func _on_cycle_resolution() -> void:
	AudioUtil.play("ui")
	if DisplaySettingsUtil.instance != null:
		DisplaySettingsUtil.instance.call("cycle_resolution")
	_enter_display_settings(1)


func _on_cycle_ui_scale() -> void:
	AudioUtil.play("ui")
	if DisplaySettingsUtil.instance != null:
		DisplaySettingsUtil.instance.call("cycle_ui_scale")
	_enter_display_settings(2)


func _on_display_settings_back() -> void:
	AudioUtil.play("ui")
	if _display_settings_return_state == State.PAUSED:
		_enter_pause()
	else:
		_enter_menu()


func _on_start() -> void:
	AudioUtil.play("ui")
	start_run()


## 供外部直接开局（性能基准等）。语义与点"开始游戏"完全一致。
func start_run() -> void:
	_begin_run()


func _first_arena_id() -> String:
	var order := ArenaUtil.get_order()
	return String(order[0]) if not order.is_empty() else "lakefront"


# ---------------------------------------------------------------- 开局

## 一局真正开始：重置进度、定下竞技场、进游戏态。
func _begin_run() -> void:
	RunStateUtil.begin_run()
	_apply_start_arena(_start_arena)
	_resume_play()
	# 【必须重载场景】—— 地形在场景加载时就建好了，而开始菜单是叠在【已经加载
	# 好的那个场景】之上的。不重载的话，_apply_start_arena 改的只是一个变量：
	# 玩家永远走在地形最初生成的那张图上，表现就是"选哪一关都是第一关"。
	#
	# 这一段放在 _resume_play 【之后】而不是里面：_resume_play 也被"暂停 → 继续"
	# 调用，塞在里面会让每次继续游戏都重建整个世界。
	#
	# 顺序也不能反：_resume_play 先把 state 置为 PLAYING，重载后的
	# player_spawner 才会在 _ready 里认领"一局已经在跑"并补生成玩家。
	get_tree().reload_current_scene()


## 定下这一局的起始竞技场，并把阶段号对齐到它在表里的位置。
##
## 阶段号必须跟着关卡走：直接从沙丘开始却显示"阶段 1"，
## 会让 HUD、结算数字、历史最好成绩全部错位。
func _apply_start_arena(arena_id: String) -> void:
	ArenaUtil.current_id = arena_id if not arena_id.is_empty() else _first_arena_id()
	var order := ArenaUtil.get_order()
	var index := order.find(ArenaUtil.current_id)
	if index >= 0:
		RunStateUtil.set_progress(index + 1, 0)


func _resume_play() -> void:
	state = State.PLAYING
	_set_overlay_visible(false)
	get_tree().paused = false
	Input.mouse_mode = Input.MOUSE_MODE_CAPTURED


func _enter_pause() -> void:
	state = State.PAUSED
	_title.text = "已 暂 停"
	_clear_arena_row()
	# 【数字从正文里搬出去了】原先三个成绩挤在一行 Label 里，和正文同字号同颜色，
	# 读起来是一句话而不是"三项记录"。现在它们是三块读数板 ——
	# 和战斗界面上那两块同形，于是"看数据"这件事在两边是同一种体验。
	var arena_label := String(
		ArenaUtil.get_params(ArenaUtil.current_id).get("label", ArenaUtil.current_id)
	)
	var upgrades := RunStateUtil.get_upgrades()
	_set_body(
		"当前战场：%s　·　第 %d 阶段\n" % [arena_label, RunStateUtil.get_stage()]
		+ "武器 LV%d　·　模块：射速+%d 威力+%d 弹匣+%d" % [
			RunStateUtil.get_weapon_level(),
			int(upgrades.get("fire_rate", 0)),
			int(upgrades.get("damage", 0)),
			int(upgrades.get("magazine", 0)),
		]
	)
	_set_actions([
		{"text": "继续", "callback": _on_resume},
		{"text": "显示设置", "callback": _on_open_display_settings},
		{"text": "重新开始", "callback": _on_restart},
		{"text": "退出", "callback": _on_quit},
	])
	_present("PAUSED", UiThemeUtil.COLOR_ACCENT, "ESC 继续游戏", [
		{"label": "最好成绩", "value": _format_time(SaveUtil.get_best_survival())},
		{"label": "最佳击杀", "value": "%d" % SaveUtil.get_best_kills()},
		{"label": "总场次", "value": "%d" % SaveUtil.get_total_runs()},
	])
	get_tree().paused = true
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE


func _on_resume() -> void:
	AudioUtil.play("ui")
	_resume_play()


func _on_restart() -> void:
	AudioUtil.play("ui")
	# 清掉上一局的池化对象，避免把旧场景的实例带进新一局。
	PoolUtil.clear_all()
	# "再来一局"意味着进度作废：阶段回 1、武器回 1 级。
	RunStateUtil.begin_run()
	# 地块回到【这一局的开局选择】，而不是永远回第一张 ——
	# 没选过时 _start_arena 为空，行为与改动前完全一致。
	ArenaUtil.current_id = _start_arena if not _start_arena.is_empty() else _first_arena_id()
	state = State.PLAYING
	get_tree().paused = false
	_set_overlay_visible(false)
	Input.mouse_mode = Input.MOUSE_MODE_CAPTURED
	get_tree().reload_current_scene()


func _on_quit() -> void:
	AudioUtil.play("ui")
	get_tree().quit()


func _enter_game_over(survival: float, kills: int) -> void:
	if state == State.GAME_OVER:
		return
	state = State.GAME_OVER
	# 一局到此结束：进度失效。武器成长随 RunState 一起作废，
	# "再来一局"会重新 begin_run()。
	RunStateUtil.end_run()
	var improved := SaveUtil.submit_run(survival, kills)
	_title.text = "阵 亡"
	_clear_arena_row()
	# "★ 新纪录"单独一行且只在真的刷新时才占位 —— 它是一句祝贺，
	# 不是一项数据，混在读数板里会被当成"又一个数字"划过去。
	_set_body("★ 刷新了最好成绩" if improved else "")
	_set_actions([
		{"text": "再来一局", "callback": _on_restart},
		{"text": "退出", "callback": _on_quit},
	])
	# 阵亡用红。这不是装饰：暂停与阵亡的按钮几乎一样，只有标题不同，
	# 一眼能分辨"我按错了没"靠的就是这个颜色。
	_present("RUN TERMINATED", UiThemeUtil.COLOR_DANGER, "方向键选择　·　Enter 确认", [
		{"label": "本局生存", "value": _format_time(survival)},
		{"label": "本局击杀", "value": "%d" % kills},
		{
			"label": "最好成绩",
			"value": _format_time(SaveUtil.get_best_survival()),
			"sub": "最佳击杀 %d" % SaveUtil.get_best_kills(),
		},
	])
	get_tree().paused = true
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE


## 一个阶段的 Boss 被击败。与阵亡不同之处在于"还有下一张图"，
## 所以这里给的是"进入下一区域"，并且明确告诉玩家武装会保留 ——
## 不然玩家会以为换图等于重开，不敢往下走。
func _enter_stage_cleared(stage: int) -> void:
	if state == State.DYING or state == State.GAME_OVER or state == State.STAGE_CLEAR:
		return
	state = State.STAGE_CLEAR
	var next_id := ArenaUtil.next_id(ArenaUtil.current_id)
	var next_label := String(ArenaUtil.get_params(next_id).get("label", next_id))
	var upgrades := RunStateUtil.get_upgrades()
	_title.text = "区 域 肃 清"
	_clear_arena_row()
	_set_body(
		"下一片战场：%s\n" % next_label
		+ "武器 %d 级　·　模块：射速+%d 威力+%d 弹匣+%d" % [
			RunStateUtil.get_weapon_level(),
			int(upgrades.get("fire_rate", 0)),
			int(upgrades.get("damage", 0)),
			int(upgrades.get("magazine", 0)),
		]
	)
	_set_actions([{"text": "进入下一区域", "callback": _on_next_stage}])
	# 肃清用金：这是全场唯一一个"好消息"的中断，值得跟另外两屏区分开。
	_present("STAGE CLEARED", UiThemeUtil.COLOR_TITLE, "方向键选择　·　Enter 确认", [
		{"label": "已通过", "value": "阶段 %d" % stage},
		{"label": "最远阶段", "value": "%d" % RunStateUtil.get_best_stage()},
		{"label": "武器等级", "value": "LV %d" % RunStateUtil.get_weapon_level()},
	])
	get_tree().paused = true
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE


## 切到下一个竞技场。靠重载场景完成 —— 竞技场几何是确定性生成的，
## 换一个 id 就会重建出一套逐点一致的新地形（见 terrain_field.gd 的 _applied_id）。
func _on_next_stage() -> void:
	AudioUtil.play("ui")
	_apply_next_stage(ArenaUtil.next_id(ArenaUtil.current_id))


func _apply_next_stage(next_id: String) -> void:
	# 池化对象属于上一张图，必须清掉，否则会把旧场景的实例带过去。
	PoolUtil.clear_all()
	RunStateUtil.advance_stage()
	ArenaUtil.current_id = next_id
	state = State.PLAYING
	get_tree().paused = false
	_set_overlay_visible(false)
	Input.mouse_mode = Input.MOUSE_MODE_CAPTURED
	get_tree().reload_current_scene()


## 退出时清空对象池。池化节点脱离了场景树，不会被场景释放自动回收；
## 不主动清理会让引擎在退出时报一堆 RID 泄漏警告。
func _notification(what: int) -> void:
	if what == NOTIFICATION_PREDELETE or what == NOTIFICATION_WM_CLOSE_REQUEST:
		PoolUtil.clear_all()


# ---------------------------------------------------------------- 输入

func _input(event: InputEvent) -> void:
	if not event.is_action_pressed("ui_cancel"):
		return
	if state == State.PLAYING:
		_enter_pause()
		get_viewport().set_input_as_handled()
	elif state == State.PAUSED:
		_on_resume()
		get_viewport().set_input_as_handled()
	elif state == State.DISPLAY_SETTINGS:
		_on_display_settings_back()
		get_viewport().set_input_as_handled()


# ---------------------------------------------------------------- 工具

func _format_time(seconds: float) -> String:
	return "%02d:%05.2f" % [floori(seconds / 60.0), fmod(seconds, 60.0)]
