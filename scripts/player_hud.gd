class_name PlayerHUD
extends Node
## 玩家 HUD（从原 player.gd 中拆出）：绑定 player.tscn 里已有的 AimUI 节点，
## 并在运行时补充动态扩散准星、命中标记、弹药与技能读数。
##
## 全部控件由代码创建，不新增也不修改任何 .tscn。
##
## 准星命中标记由 EventBus.hit_confirmed 驱动（原先靠 CombatFX 按 "player_hud"
## 组查找本节点，多一个 HUD 就会闪错对象）。因此这里不再把自己登记进任何组。

const EventBusUtil := preload("res://scripts/event_bus.gd")
const ConfigUtil := preload("res://scripts/game_config.gd")
## 配色与字号全部来自统一主题，本文件不再自带 COLOR_* 常量
## （原先与 game_flow.gd 各写一份，两边已经开始漂移）。
const UiThemeUtil := preload("res://scripts/ui_theme.gd")
## 用 preload 当类型而不是裸类名：新建脚本要等编辑器扫描进 class 缓存之后
## 才能被按名字引用，而 preload 立刻可用（本项目多处注释都提到这个坑）。
const DamageDirectionIndicatorScript := preload("res://scripts/damage_direction_indicator.gd")
const WeaponPanelScript := preload("res://scripts/weapon_panel.gd")
const AbilityBarScript := preload("res://scripts/ability_bar.gd")
const NotificationStackScript := preload("res://scripts/notification_stack.gd")
const MinimapScript := preload("res://scripts/minimap.gd")
const LowHealthOverlayScript := preload("res://scripts/low_health_overlay.gd")
## 生命 / 护盾 / 首领 / 波次四块读数全部改成自绘控件（原先是 ProgressBar 与 Label）。
## 理由见各自文件头：ProgressBar 只能画"纯色块 + 1 像素描边"，与整套切角石板语言无关。
const VitalsPanelScript := preload("res://scripts/vitals_panel.gd")
const BossBarScript := preload("res://scripts/boss_bar.gd")
const WaveBannerScript := preload("res://scripts/wave_banner.gd")
## 单行读数板（击杀 / 生存）。它们原先是一条拼好的 Label，
## 现在与面板同形 —— 见 ReadoutPlate 文件头。
const ReadoutPlateScript := preload("res://scripts/readout_plate.gd")

const DAMAGE_FLASH_TIME := 0.18

var _aim_ui: CanvasLayer
var _theme: Theme
## player.tscn 自带、现已停用的控件。保留引用只为把它们藏起来 ——
## .tscn 是既有资产，动它要连带改场景引用，而"运行时换成自绘控件"在这个
## 项目里已经是惯例（静态 "+" 准星就是这么被换掉的）。
var _legacy_health_bar: ProgressBar
var _legacy_health_label: Label
var _damage_overlay: ColorRect
## 击杀 / 生存两块读数原先各是一条 Label（拼一句文本），现已由读数板取代。
## 与生命条一样：只隐藏、不删除场景里的原节点。
var _legacy_kill_label: Label
var _legacy_survival_label: Label
var _weapon_label: Label
var _ability_bar: AbilityBarScript
var _crosshair: DynamicCrosshair
var _hit_marker: HitMarker

var _vitals: VitalsPanelScript
var _damage_direction: DamageDirectionIndicatorScript
var _weapon_panel: WeaponPanelScript
var _minimap: MinimapScript
var _game_time_plate: ReadoutPlateScript
var _sky_time: Node
var _has_sky_time := false
var _fps_label: Label
var _low_health: LowHealthOverlayScript
var _kill_plate: ReadoutPlateScript
var _survival_plate: ReadoutPlateScript
var _notifications: NotificationStackScript
## 死亡过渡的最终压暗层。挂在 AimUI 最后，因此会把战斗 HUD 一并压下去，
## 但 GameFlow（更高 CanvasLayer）弹出的结算石板仍然清晰。
var _death_overlay: ColorRect

var _damage_flash_time := 0.0
var _fps_refresh_time := 0.0
## 生命与护盾的当前值。
##
## 【只存，不画】真正绘制的是 VitalsPanel —— 这里保留一份是因为低血量叠加层
## 每帧要读它们（见 update）。去重（"值没变就别重绘"）挪进了面板内部，
## 因为现在只有一条绘制路径，在那里判比在这里替另一块控件判更省事。
var _shown_health := 0.0
var _shown_max_health := 0.0
var _shown_shield := 0.0
var _shown_max_shield := 0.0

## 武器状态。由 player.gd 通过 set_* 灌进来，每帧在 update() 里统一推给武器面板
## （面板不做任何查询，纯显示器）。
var _ammo := 0
var _capacity := 0
var _reloading := false
var _reload_ratio := 0.0
var _sniper_ammo := 0
var _sniper_capacity := 0
var _sniper_reload_remaining := 0.0
var _weapon_level := 1
var _weapon_pellets := 1
var _weapon_damage := 0.0
## 弹道模式角标已随"T 键切换"一起删除 —— 玩家的射击现在是固定瞬发。
## 备弹（-1 = 无限，即该机制被配置关掉）。
var _reserve := -1
var _sniper_reserve := -1
## 三种升级模块的层数，面板会显示成"射速+2 威力+1 弹匣+3"。
var _up_fire_rate := 0
var _up_damage := 0
var _up_magazine := 0
## 武器分类名（来自配置的 weapon.classes），只用于显示。
var _weapon_class_label := ""
var _sniper_class_label := ""

## 轻量 HUD：左下弹药、下中血盾、右下技能、右上地图。
## UI 使用当前视口的逻辑尺寸；波次只在开场和休整显示。
const REFERENCE_WIDTH := 1152.0
const WAVE_HALF_WIDTH := 190.0
const BOSS_HALF_WIDTH := 200.0
## 生命 / 护盾面板的落位（替代原先 player.tscn 里 HealthLabel + HealthBar 两块）。
const VITALS_LEFT := 18.0
const VITALS_TOP := 16.0
## 击杀读数板的宽度（右上角，与小地图同宽对齐右边界）。
const KILL_PLATE_WIDTH := 108.0
const KILL_PLATE_HEIGHT := 26.0
## 游戏时钟独立放在小地图上方，避免重新占用地图内容区。
const GAME_TIME_PLATE_HEIGHT := 24.0
## 生存读数板的宽度。它是"当前局"最核心的一个数，所以给得比击杀宽。
const SURVIVAL_PLATE_WIDTH := 220.0
const SURVIVAL_PLATE_HEIGHT := 26.0
## 生存读数板在顶部中央的槽位：紧贴生存读数原来那一行（22..56）。
const SURVIVAL_PLATE_TOP := 16.0
## 帧数读数的槽位在击杀读数下方（见 _place_right_column），这里只给高度。
const FPS_PLATE_HEIGHT := 22.0
const LAYOUT_GAP := 4.0
const BOTTOM_MARGIN := WeaponPanelScript.MARGIN
## 顶部中央那一列与左右两栏之间的留白。比 LAYOUT_GAP 宽：这一列是"插在"
## 两栏之间的，4 像素看着像贴上了，8 像素才读得出是两块独立的板。
const TOP_ROW_GAP := 8.0
const WAVE_LABEL_TOP := 22.0
const WAVE_LABEL_HEIGHT := 42.0
const BOSS_BAR_TOP := 76.0
const BOSS_BAR_HEIGHT := 40.0

## 阶段/波次横幅与 Boss 血条。都挂在屏幕顶部中央 ——
## 生命/击杀/武器/生存已在左右两侧，中间一块原本是空的，正好用上。
var _wave_banner: WaveBannerScript
var _boss_bar: BossBarScript


## player 只用于小地图定位；传 null 时小地图不画东西。
func setup(aim_ui: CanvasLayer, camera: Camera3D = null, player: Node3D = null) -> void:
	_aim_ui = aim_ui
	_theme = UiThemeUtil.get_theme()
	# 订阅命中确认。HUD 随场景重载被释放时，Godot 会自动断开这个连接。
	EventBusUtil.subscribe_hit_confirmed(_on_hit_confirmed)
	if not _aim_ui:
		push_warning("PlayerHUD: 未找到 AimUI，HUD 已禁用")
		return
	# 生命条与生命文字由 VitalsPanel 接管（见 _build_vitals），这里把 .tscn 里
	# 那两块藏掉。留着节点不删：场景是既有资产，而"运行时换自绘控件"是本项目惯例。
	_legacy_health_bar = _aim_ui.get_node_or_null("HealthBar") as ProgressBar
	_legacy_health_label = _aim_ui.get_node_or_null("HealthLabel") as Label
	if _legacy_health_bar:
		_legacy_health_bar.visible = false
	if _legacy_health_label:
		_legacy_health_label.visible = false
	_damage_overlay = _aim_ui.get_node_or_null("DamageOverlay")
	_weapon_label = _aim_ui.get_node_or_null("WeaponLevelLabel")
	# 击杀与生存读数由读数板接管（见 _build_extra_readouts）。
	_legacy_kill_label = _aim_ui.get_node_or_null("KillLabel") as Label
	_legacy_survival_label = _aim_ui.get_node_or_null("SurvivalLabel") as Label
	if _legacy_kill_label:
		_legacy_kill_label.visible = false
	if _legacy_survival_label:
		_legacy_survival_label.visible = false
	# 场景里自带的这个控件也要挂主题，否则它还留着 .tscn 里的老配色。
	_apply_theme(_weapon_label, UiThemeUtil.VARIATION_HUD_WEAPON)
	# 原来的静态 "+" 准星由动态扩散准星取代。
	var legacy_crosshair := _aim_ui.get_node_or_null("Crosshair") as CanvasItem
	if legacy_crosshair:
		legacy_crosshair.visible = false
	if _damage_overlay:
		_damage_overlay.visible = false
	_build_crosshair()
	_build_hit_marker()
	_build_damage_direction(camera)
	_build_extra_readouts()
	_build_notifications()
	_build_vitals()
	_build_weapon_panel()
	_build_minimap(player, camera)
	_build_fps_readout()
	_build_low_health()
	_build_wave_readout()
	_build_boss_bar()
	_build_death_overlay()
	_bind_sky_time()
	# 最后统一落位：各 _build_* 里写的只是初值。
	# 【这里不做两遍】原先先调一次 _layout_top_hud() 再调 relayout_for_width()，
	# 两处都在摆右上角那一列，改一处忘一处就会出现"某个宽度下才对"的错位。
	relayout_for_width()
	# 波次与 Boss 状态由 wave_director 广播 —— HUD 不认识它，也不需要认识。
	EventBusUtil.subscribe_wave_updated(_on_wave_updated)
	EventBusUtil.subscribe_boss_updated(_on_boss_updated)


## HUD 的实际可用宽度。
##
## 取 AimUI 所在视口的宽度：它是根视口。真正会让它变小的只有"把窗口拖窄"这一种情况。
func _hud_width() -> float:
	if _aim_ui == null:
		return REFERENCE_WIDTH
	var vp := _aim_ui.get_viewport()
	if vp == null:
		return REFERENCE_WIDTH
	return vp.get_visible_rect().size.x


## 统一的落位入口。各 _build_* 里写的坐标只是"初值"，最终以这里为准。
##
## 调用时机只有一个：setup 里一次。
##
## 【这里必须管横向】顶部中央那一列是"占满整行"的宽元素，它的横向边界要跟着
## 屏幕宽算 —— 只按宽度改纵向挡不住它伸进左栏的生命面板（Round 36 的那个重叠）。
func relayout_for_width() -> void:
	var width := _hud_width()
	var center_half := _center_half_width(width)
	var half := minf(WAVE_HALF_WIDTH, center_half)

	if _wave_banner != null:
		_wave_banner.offset_left = -half
		_wave_banner.offset_right = half
		_wave_banner.offset_top = WAVE_LABEL_TOP
		_wave_banner.offset_bottom = WAVE_LABEL_TOP + WAVE_LABEL_HEIGHT

	if _boss_bar != null:
		var bhalf := minf(BOSS_HALF_WIDTH, center_half)
		_boss_bar.offset_left = -bhalf
		_boss_bar.offset_right = bhalf
		_boss_bar.offset_top = BOSS_BAR_TOP
		_boss_bar.offset_bottom = BOSS_BAR_TOP + BOSS_BAR_HEIGHT

	if _survival_plate != null:
		# 这块板现在比两侧留白窄得多（150 < 268），走一遍同一个上限是为了
		# 以后调宽它的时候不会重新长出压住两侧的问题。
		var shalf := minf(SURVIVAL_PLATE_WIDTH * 0.5, half)
		_survival_plate.offset_left = -shalf
		_survival_plate.offset_right = shalf
		_survival_plate.offset_top = SURVIVAL_PLATE_TOP
		_survival_plate.offset_bottom = SURVIVAL_PLATE_TOP + SURVIVAL_PLATE_HEIGHT

	_place_right_column()
	_place_bottom_hud()


## 底部三组共用同一条下基线；技能组同时服从右栏的右基线。
func _place_bottom_hud() -> void:
	if _vitals != null:
		_vitals.offset_left = -VitalsPanelScript.PANEL_WIDTH * 0.5
		_vitals.offset_right = VitalsPanelScript.PANEL_WIDTH * 0.5
		_vitals.offset_top = -BOTTOM_MARGIN - VitalsPanelScript.PANEL_HEIGHT
		_vitals.offset_bottom = -BOTTOM_MARGIN
	if _ability_bar != null:
		_ability_bar.offset_left = -MinimapScript.MARGIN - AbilityBarScript.PANEL_WIDTH
		_ability_bar.offset_right = -MinimapScript.MARGIN
		_ability_bar.offset_top = -BOTTOM_MARGIN - AbilityBarScript.PANEL_HEIGHT
		_ability_bar.offset_bottom = -BOTTOM_MARGIN


## 顶部中央那一列（生存读数 / 波次横幅 / Boss 血条）能用的半宽。
##
## 【为什么不能按屏幕宽算】这一列的元素都是"占满整行"的宽元素，横向一伸长就
## 必然压住两侧的信息栏。原先取屏幕宽的 ±340，左端落在 236 —— 正好盖住生命面板
## 右侧的护盾读数（截图里"阶段 1"小牌压在护盾数字上）。
##
## 约束是左右两条：左端不能让过左栏右边界，右端不能让进右栏左边界。
## 取【两个留白的较大者】而不是各算各的边界 —— 这样这一列仍然屏幕居中，
## 与上面同样居中的生存读数对齐；各算各的会把它推得偏右，两行错开半个身位。
func _center_half_width(width: float) -> float:
	var guard := TOP_ROW_GAP + maxf(
		VITALS_LEFT + VitalsPanelScript.PANEL_WIDTH,
		MinimapScript.MARGIN + MinimapScript.PANEL_SIZE
	)
	return maxf(width * 0.5 - guard, 80.0)


## 右上角那一列：游戏时钟 → 小地图 → 击杀读数 → 帧数读数，自上而下排开。
##
## player.tscn 里 KillLabel 在 24..56（右上角），而小地图占 26..194 ——
## 两者重叠，击杀数被压在地图上面看不清。这里把它们串成一列。
##
## 帧数读数也挂在这一列（原先固定在小地图正上方 2..24）：它是 Label，
## 高度由字体撑到 26，压不住 22 的槽位 —— 实际矩形会向下长到 28，
## 于是压进小地图 2 像素。挂在击杀读数下面就没有这个"最小高度顶出去"的问题。
func _place_right_column() -> void:
	if _minimap != null:
		var minimap_top := _minimap_top()
		_minimap.offset_top = minimap_top
		_minimap.offset_bottom = minimap_top + MinimapScript.PANEL_SIZE
	var next_top := _below_minimap()
	if _game_time_plate != null:
		_game_time_plate.offset_top = next_top
		_game_time_plate.offset_bottom = next_top + GAME_TIME_PLATE_HEIGHT
		if _game_time_plate.visible:
			next_top += GAME_TIME_PLATE_HEIGHT + LAYOUT_GAP
	if _fps_label != null:
		_fps_label.offset_top = next_top
		_fps_label.offset_bottom = next_top + FPS_PLATE_HEIGHT


## 小地图下沿再留一点缝的位置。
func _below_minimap() -> float:
	return _minimap_top() + MinimapScript.PANEL_SIZE + LAYOUT_GAP * 2.0


func _minimap_top() -> float:
	return MinimapScript.MARGIN


## 波次横幅。内容由 wave_director 的快照字典决定，HUD 只负责转发 ——
## 文案与进度条形态都搬进了 WaveBanner（那里才能同时看到布局与语义）。
func _build_wave_readout() -> void:
	_wave_banner = WaveBannerScript.new()
	_wave_banner.name = "WaveBanner"
	_wave_banner.set_anchors_preset(Control.PRESET_CENTER_TOP)
	_wave_banner.offset_left = -WAVE_HALF_WIDTH
	_wave_banner.offset_right = WAVE_HALF_WIDTH
	_wave_banner.offset_top = WAVE_LABEL_TOP
	_wave_banner.offset_bottom = WAVE_LABEL_TOP + WAVE_LABEL_HEIGHT
	# WaveBanner 自己会在第一条快照到达前保持隐藏，避免空面板闪一下。
	_aim_ui.add_child(_wave_banner)


## Boss 血条：首领小牌 + 标题 + 分段血条，平时整体隐藏（Boss 只占一小段时间）。
func _build_boss_bar() -> void:
	_boss_bar = BossBarScript.new()
	_boss_bar.name = "BossBar"
	_boss_bar.set_anchors_preset(Control.PRESET_CENTER_TOP)
	_boss_bar.offset_left = -BOSS_HALF_WIDTH
	_boss_bar.offset_right = BOSS_HALF_WIDTH
	_boss_bar.offset_top = BOSS_BAR_TOP
	_boss_bar.offset_bottom = BOSS_BAR_TOP + BOSS_BAR_HEIGHT
	_boss_bar.visible = false
	_aim_ui.add_child(_boss_bar)


func _on_wave_updated(info: Dictionary) -> void:
	if _wave_banner != null:
		_wave_banner.update_wave(info)


func _on_boss_updated(active: bool, title: String, current: float, maximum: float) -> void:
	if _boss_bar != null:
		_boss_bar.set_boss(active, title, current, maximum)


## 给控件挂主题与变体。variation 为空时只挂主题、不改变体。
func _apply_theme(control: Control, variation: String) -> void:
	if control == null:
		return
	control.theme = _theme
	if not variation.is_empty():
		control.theme_type_variation = variation


func _build_crosshair() -> void:
	_crosshair = DynamicCrosshair.new()
	_crosshair.name = "DynamicCrosshair"
	_aim_ui.add_child(_crosshair)


func _build_hit_marker() -> void:
	_hit_marker = HitMarker.new()
	_hit_marker.name = "HitMarker"
	_aim_ui.add_child(_hit_marker)


## 受击方向指示器。相机是可选的：没传进来时它只是不画东西，
## 其余 HUD 功能不受影响（方便单独测试 HUD）。
func _build_damage_direction(camera: Camera3D) -> void:
	_damage_direction = DamageDirectionIndicatorScript.new()
	_damage_direction.name = "DamageDirectionIndicator"
	_damage_direction.set_camera(camera)
	_aim_ui.add_child(_damage_direction)


## 生命 / 护盾面板：一块石板装下两行读数 + 两根条（见 VitalsPanel）。
##
## 坐标直接写常量而不再"跟着 player.tscn 的 HealthBar 走"：那一对节点已经被
## 本面板取代并隐藏了，继续拿它们当基准等于把已废弃的布局当成事实来源。
func _build_vitals() -> void:
	_vitals = VitalsPanelScript.new()
	_vitals.name = "VitalsPanel"
	_vitals.set_anchors_preset(Control.PRESET_CENTER_BOTTOM)
	_vitals.offset_left = -VitalsPanelScript.PANEL_WIDTH * 0.5
	_vitals.offset_right = VitalsPanelScript.PANEL_WIDTH * 0.5
	_vitals.offset_top = -BOTTOM_MARGIN - VitalsPanelScript.PANEL_HEIGHT
	_vitals.offset_bottom = -BOTTOM_MARGIN
	_aim_ui.add_child(_vitals)


## 技能卡片、击杀读数、生存读数。
##
## 弹药 / 狙击 / 弹道模式全部搬进了右下角的武器面板（见 WeaponPanel）——
## 它们是同一组信息，原先散在屏幕三个角反而难扫读。
## 技能拆成两个独立卡片；击杀与生存是"标签 + 数值"，继续走读数板。
func _build_extra_readouts() -> void:
	_ability_bar = AbilityBarScript.new()
	_ability_bar.name = "AbilityBar"
	_ability_bar.set_anchors_preset(Control.PRESET_BOTTOM_RIGHT)
	_ability_bar.offset_left = -MinimapScript.MARGIN - AbilityBarScript.PANEL_WIDTH
	_ability_bar.offset_right = -MinimapScript.MARGIN
	_ability_bar.offset_top = -BOTTOM_MARGIN - AbilityBarScript.PANEL_HEIGHT
	_ability_bar.offset_bottom = -BOTTOM_MARGIN
	_aim_ui.add_child(_ability_bar)
	_game_time_plate = ReadoutPlateScript.new()
	_game_time_plate.name = "GameTimePlate"
	_game_time_plate.configure(UiThemeUtil.COLOR_ACCENT, UiThemeUtil.PLATE_FOREST)
	_game_time_plate.minimal = true
	_game_time_plate.set_anchors_preset(Control.PRESET_TOP_RIGHT)
	_game_time_plate.offset_left = -MinimapScript.PANEL_SIZE - MinimapScript.MARGIN
	_game_time_plate.offset_right = -MinimapScript.MARGIN
	_game_time_plate.visible = false
	_aim_ui.add_child(_game_time_plate)
	# 战斗画面仅保留行动所需的信息；战绩仍由 GameFlow 记录并在结算展示。

func _build_notifications() -> void:
	_notifications = NotificationStackScript.new()
	_notifications.name = "NotificationStack"
	_aim_ui.add_child(_notifications)


func show_notice(text: String, kind: String = "info") -> void:
	# 普通补给已有拾取音效以及血量/弹药变化，避免叠加战斗文字日志。
	if kind == "health" or kind == "ammo":
		return
	if _notifications == null:
		return
	var accent := UiThemeUtil.COLOR_ACCENT
	match kind:
		"health":
			accent = UiThemeUtil.COLOR_HEALTH
		"ammo":
			accent = UiThemeUtil.COLOR_AMMO
		"upgrade":
			accent = UiThemeUtil.COLOR_TITLE
		"danger":
			accent = UiThemeUtil.COLOR_DANGER
	_notifications.push_notice(text, accent)


## 建一个带主题变体的 Label。字号与颜色由主题决定，不再逐个 add_theme_*_override。
func _make_label(node_name: String, variation: String) -> Label:
	var label := Label.new()
	label.name = node_name
	label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	label.theme = _theme
	label.theme_type_variation = variation
	_aim_ui.add_child(label)
	return label


## 武器面板铺满全屏，自己按屏幕尺寸把面板摆到右下角（见 WeaponPanel._draw）。
func _build_weapon_panel() -> void:
	_weapon_panel = WeaponPanelScript.new()
	_weapon_panel.name = "WeaponPanel"
	_weapon_panel.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_aim_ui.add_child(_weapon_panel)


## 小地图挂右上角。用"锚右 + 负偏移"的写法，分辨率变化时自动贴边。
func _build_minimap(player: Node3D, camera: Camera3D) -> void:
	_minimap = MinimapScript.new()
	_minimap.name = "Minimap"
	_minimap.set_player(player)
	_minimap.set_camera(camera)
	_minimap.anchor_left = 1.0
	_minimap.anchor_right = 1.0
	_minimap.offset_left = -MinimapScript.PANEL_SIZE - MinimapScript.MARGIN
	_minimap.offset_right = -MinimapScript.MARGIN
	_minimap.offset_top = _minimap_top()
	_minimap.offset_bottom = _minimap_top() + MinimapScript.PANEL_SIZE
	_aim_ui.add_child(_minimap)


func _bind_sky_time() -> void:
	if _aim_ui == null or _game_time_plate == null:
		return
	var tree := _aim_ui.get_tree()
	var scene := tree.current_scene
	var time_node := scene.find_child("TimeOfDay", true, false) if scene != null else null
	if _is_sky_time_node(time_node):
		_attach_sky_time(time_node)
		return
	# 实验场景会在运行时补建 Sky3D。等节点出现再绑定，期间不显示假时间，
	# 小地图也保持原来的顶部位置。
	if not tree.node_added.is_connected(_on_sky_time_node_added):
		tree.node_added.connect(_on_sky_time_node_added)


func _on_sky_time_node_added(node: Node) -> void:
	if _is_sky_time_node(node):
		_attach_sky_time(node)


func _is_sky_time_node(node: Node) -> bool:
	if node == null or not node.has_signal("time_changed"):
		return false
	var script := node.get_script() as Script
	return script != null and script.resource_path == "res://addons/sky_3d/src/TimeOfDay.gd"


func _attach_sky_time(time_node: Node) -> void:
	_sky_time = time_node
	_has_sky_time = true
	_game_time_plate.visible = true
	_on_sky_time_changed(float(_sky_time.get("current_time")))
	if not _sky_time.is_connected("time_changed", _on_sky_time_changed):
		_sky_time.connect("time_changed", _on_sky_time_changed)
	var tree := _aim_ui.get_tree()
	if tree.node_added.is_connected(_on_sky_time_node_added):
		tree.node_added.disconnect(_on_sky_time_node_added)
	_place_right_column()


func _on_sky_time_changed(current_time: float) -> void:
	if _game_time_plate != null:
		_game_time_plate.set_readout("时刻", format_game_time(current_time))


## 性能探索阶段常驻帧数。它是 Label 而不是自绘控件，所以【不能】自己算槽位：
## 字体决定的最小高度会把它顶出给定的矩形（原先固定在小地图上方 2..24，
## 实际被撑到 2..28，压进小地图 2 像素）。真正落位在 _place_right_column。
## 每 0.25 秒更新一次，读数稳定且不会每帧重排文字。
func _build_fps_readout() -> void:
	if not ConfigUtil.get_bool("ui.show_fps", false):
		return
	_fps_label = _make_label("FpsLabel", UiThemeUtil.VARIATION_HUD_WEAPON)
	_fps_label.set_anchors_preset(Control.PRESET_TOP_RIGHT)
	_fps_label.offset_left = -MinimapScript.PANEL_SIZE - MinimapScript.MARGIN
	_fps_label.offset_right = -MinimapScript.MARGIN
	_fps_label.offset_top = _below_minimap() + KILL_PLATE_HEIGHT + LAYOUT_GAP
	_fps_label.offset_bottom = _fps_label.offset_top + FPS_PLATE_HEIGHT
	_fps_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	_fps_label.text = "FPS --"


## 低血量叠加最后加：它是全屏的，需要压在其它 HUD 元素之上。
func _build_low_health() -> void:
	_low_health = LowHealthOverlayScript.new()
	_low_health.name = "LowHealthOverlay"
	_aim_ui.add_child(_low_health)


func _build_death_overlay() -> void:
	_death_overlay = ColorRect.new()
	_death_overlay.name = "DeathTransition"
	_death_overlay.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_death_overlay.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_death_overlay.color = Color(0.035, 0.0, 0.0, 0.0)
	_aim_ui.add_child(_death_overlay)


# ---------------------------------------------------------------- 每帧

func update(delta: float, bloom_ratio: float, aiming: bool, reloading: bool) -> void:
	_damage_flash_time = maxf(_damage_flash_time - delta, 0.0)
	_fps_refresh_time -= delta
	if _fps_label != null and _fps_refresh_time <= 0.0:
		_fps_refresh_time = 0.25
		_fps_label.text = "FPS %d" % Engine.get_frames_per_second()
	if _damage_overlay:
		_damage_overlay.visible = _damage_flash_time > 0.0
	if _crosshair:
		_crosshair.spread = bloom_ratio
		_crosshair.aiming = aiming
		_crosshair.reloading = reloading
	_refresh_weapon_panel(reloading)
	if _low_health:
		_low_health.update_health(_shown_health, _shown_max_health)


## 武器面板是纯显示器：把所有状态一次性推过去，面板自己不做任何查询。
## reserve 传 -1 表示无限备弹（备弹机制被配置关掉），面板会显示 ∞。
func _refresh_weapon_panel(reloading: bool) -> void:
	if _weapon_panel == null:
		return
	_weapon_panel.update_state(
		_ammo, _capacity, _reserve, reloading, _reload_ratio,
		_weapon_level, _weapon_pellets, _weapon_damage
	)
	_weapon_panel.update_sniper(
		_sniper_ammo, _sniper_capacity, _sniper_reload_remaining, _sniper_reserve
	)
	_weapon_panel.update_upgrades(_up_fire_rate, _up_damage, _up_magazine)
	_weapon_panel.set_labels(_weapon_class_label, _sniper_class_label)


## 备弹池（-1 = 无限）。
func set_reserve(primary: int, sniper: int) -> void:
	_reserve = primary
	_sniper_reserve = sniper


## 三种升级模块的层数。
func set_weapon_upgrades(fire_rate: int, damage: int, magazine: int) -> void:
	_up_fire_rate = fire_rate
	_up_damage = damage
	_up_magazine = magazine


# ---------------------------------------------------------------- 数据绑定

func set_health(current: float, maximum: float) -> void:
	_shown_health = current
	_shown_max_health = maximum
	if _vitals != null:
		_vitals.set_health(current, maximum)


func set_death_progress(progress: float) -> void:
	if _death_overlay == null:
		return
	var darkness := smoothstep(0.22, 1.0, clampf(progress, 0.0, 1.0))
	_death_overlay.color = Color(0.035, 0.0, 0.0, darkness * 0.72)


## 护盾读数。护盾在持续回复，所以每帧都会被调用 ——
## 去重（数值取整后没变就别重绘）在 VitalsPanel 内部做，这里只管转发。
func set_shield(current: float, maximum: float) -> void:
	_shown_shield = current
	_shown_max_shield = maximum
	if _vitals != null:
		_vitals.set_shield(current, maximum)


## 受击方向指示。source_world 为零向量表示来源没有方位信息，直接跳过 ——
## 宁可什么都不画，也不要在屏幕上画一个"正前方"的假信号。
func show_damage_direction(from_world: Vector3, source_world: Vector3) -> void:
	if _damage_direction and not source_world.is_zero_approx():
		_damage_direction.register_hit(from_world, source_world)


## 以下四个 set_* 只负责【存值】。真正画出来的是 WeaponPanel，
## 由 update() 每帧统一推送 —— 这样绘制只有一条路径，不会出现两处各画一半。
func set_ammo(current: int, capacity: int) -> void:
	_ammo = current
	_capacity = capacity


func set_reload(reloading: bool, progress: float) -> void:
	_reloading = reloading
	_reload_ratio = progress


## 狙击弹匣状态（自动装填期间 reload_remaining > 0，面板会改成倒计时）。
func set_sniper_ammo(current: int, capacity: int, reload_remaining: float) -> void:
	_sniper_ammo = current
	_sniper_capacity = capacity
	_sniper_reload_remaining = reload_remaining


func set_kills(count: int) -> void:
	if _kill_plate:
		_kill_plate.set_readout("击杀", "%d" % count)


## 生存与最佳拆成"主数值 + 附属说明"而不是拼成一句话：
## 当前生存时间是这一行里唯一需要一眼读到的数，最佳成绩是参考值。
## 原先两者同样大小并排，反而要先分辨哪个是哪个。
func set_survival(current: float, best: float) -> void:
	if not _survival_plate:
		return
	var shown_best := maxf(best, current)
	_survival_plate.set_readout(
		"生存", _format_time(current), "最佳 %s" % _format_time(shown_best)
	)


## 武器等级 / 弹丸 / 伤害现在由右下角武器面板显示，这里只存值。
## 场景里原有的 WeaponLevelLabel 会被隐藏 —— 同一组数字出现在两处只会让视线打架。
func set_weapon_level(level: int, pellets: int, damage: float) -> void:
	_weapon_level = level
	_weapon_pellets = pellets
	_weapon_damage = damage
	if _weapon_label and _weapon_label.visible:
		_weapon_label.visible = false


## 武器分类名（主武器 / 狙击），由 PlayerWeapon 从配置的 weapon.classes 读出后交进来。
## 它是"武器分了几类"在界面上的落点 —— 换枪时才会变，但跟着其它 set_* 一起每帧灌。
func set_weapon_labels(primary: String, sniper: String) -> void:
	_weapon_class_label = primary
	_sniper_class_label = sniper


## 传入两个技能的剩余冷却秒数（<= 0 表示就绪）。
func set_abilities(grenade_remaining: float, skill_remaining: float) -> void:
	if _ability_bar:
		_ability_bar.set_cooldowns(grenade_remaining, skill_remaining)


## EventBus.hit_confirmed 的接收端。headshot 只用于将来区分标记样式，
## 当前命中标记的视觉只区分"是否击杀"。
func _on_hit_confirmed(_headshot: bool, killed: bool) -> void:
	flash_hit_marker(killed)


func flash_hit_marker(kill: bool = false) -> void:
	if _hit_marker:
		_hit_marker.flash(kill)


func flash_damage() -> void:
	_damage_flash_time = DAMAGE_FLASH_TIME


# ---------------------------------------------------------------- 工具

## Sky3D TimeOfDay.current_time 使用 0..24 的浮点小时；HUD 只显示小时与分钟。
static func format_game_time(hours: float) -> String:
	var wrapped := fposmod(hours, 24.0)
	return "%02d:%02d" % [floori(wrapped), floori(fmod(wrapped, 1.0) * 60.0)]


func _format_time(seconds: float) -> String:
	return "%02d:%05.2f" % [floori(seconds / 60.0), fmod(seconds, 60.0)]


func _format_cooldown(remaining: float) -> String:
	if remaining <= 0.0:
		return "就绪"
	return "%.1fs" % remaining
