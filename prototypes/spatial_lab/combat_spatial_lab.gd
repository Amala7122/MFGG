extends "res://prototypes/combat_lab/combat_lab.gd"
## 小空间实验场复用 Combat Lab，不另建战斗流程或敌人体系。

## 图鉴条目 ID。整组投放里直接用它们，才能验证【正式游戏那一套实现与配置】，
## 而不是另做一个只存在于实验场的版本（见 AGENTS.md「预览和正式游戏共用实现与配置」）。
const SHIELD_GUARD_ID := "L3ShieldGuard"
const SNIPER_ID := "L3Sniper"
const HEAVY_ARTILLERY_ID := "L4HeavyArtillery"

const GROUP_PRESETS := [
	{"title": "混合组 · 6 只", "enemies": {MUD_GOLEM_ID: 2, FAST_BEAST_ID: 2, HORNET_ID: 2}},
	{"title": "近战组 · 4 只", "enemies": {MUD_GOLEM_ID: 2, FAST_BEAST_ID: 2}},
	{"title": "泰坦组 · 3 只", "enemies": {SEDIMENT_TITAN_ID: 1, MUD_GOLEM_ID: 1, FAST_BEAST_ID: 1}},
	{"title": "单晶兽 · 1 只", "enemies": {FAST_BEAST_ID: 1}},
	{"title": "单泰坦 · 掩体破坏", "enemies": {SEDIMENT_TITAN_ID: 1}},
	# ── 2026-10-08 新增机制验证组：直接用图鉴条目，改参数即改游戏本体 ──
	# 【为什么要带 loop】机制验证的对象是**一个行为**（插盾 / 破防 / 受击反馈），
	# 不是"清完这一波"。而实验场在场上清空时会立刻结算 —— 按一次共鸣或丢一颗手雷
	# 就把怪清光，结算画面当场弹出来，什么都观察不到（用户实测反馈）。
	# 这些组默认开 REPLACE（死一只立刻补一只），让验证对象一直在场。
	{"title": "盾卫 · 插盾与破防", "enemies": {SHIELD_GUARD_ID: 1}, "loop": LoopMode.REPLACE},
	{"title": "盾卫墙 · 3 只 · 绕侧后", "enemies": {SHIELD_GUARD_ID: 3}, "loop": LoopMode.REPLACE},
	{"title": "狙击 · 近失呼啸", "enemies": {SNIPER_ID: 2}, "loop": LoopMode.REPLACE},
	{"title": "重型反应 · 盾卫+迫击炮", "enemies": {SHIELD_GUARD_ID: 1, HEAVY_ARTILLERY_ID: 1}, "loop": LoopMode.REPLACE},
	{"title": "泰坦反应组 · 7 只", "enemies": {SEDIMENT_TITAN_ID: 1, MUD_GOLEM_ID: 2, FAST_BEAST_ID: 2, HORNET_ID: 2}},
]
const STARTS := [
	{"title": "平地", "position": Vector3(0, 1.08, 12)},
	{"title": "坡道脚下", "position": Vector3(-12, 1.08, 11)},
	{"title": "1 米台阶上", "position": Vector3(-5, 2.08, -5)},
	{"title": "小台面 · 跳跃普攻", "position": Vector3(-10, 2.58, -15)},
	{"title": "2 米平台上", "position": Vector3(6, 3.08, -5)},
	{"title": "掩体角左侧", "position": Vector3(6, 1.08, 6)},
	{"title": "窄路入口", "position": Vector3(-18, 1.08, 11)},
	{"title": "悬崖边", "position": Vector3(13, 1.08, -12)},
	{"title": "可破坏石块 / 残柱旁", "position": Vector3(-7.5, 1.08, 14)},
]
const GroundMovement := preload("res://scripts/ground_movement.gd")

var _group_choice: OptionButton
var _start_choice: OptionButton
var _quick_panel: PanelContainer
var _navigation_dirty := false
var _navigation_baking := false


func _build_navigation() -> void:
	var mesh := NavigationMesh.new()
	# 共用通道包含泰坦的 1.4m 半径，按 0.3m 栅格向上对齐。
	mesh.agent_radius = maxf(Config.get_float("navigation.agent_radius", 1.2), 1.5)
	mesh.agent_height = maxf(Config.get_float("navigation.agent_height", 2.0), 3.5)
	mesh.agent_max_climb = GroundMovement.STEP_HEIGHT
	mesh.agent_max_slope = Config.get_float("navigation.agent_max_slope", 45.0)
	mesh.cell_size = Config.get_float("navigation.cell_size", 0.3)
	# 25cm 高度栅格会把薄板边误连到坡侧；用 10cm 分辨率识别真正入口。
	mesh.cell_height = 0.1
	mesh.geometry_parsed_geometry_type = NavigationMesh.PARSED_GEOMETRY_STATIC_COLLIDERS
	mesh.geometry_collision_mask = 1
	var region := $NavigationRegion3D as NavigationRegion3D
	NavigationServer3D.map_set_cell_size(region.get_navigation_map(), mesh.cell_size)
	NavigationServer3D.map_set_cell_height(region.get_navigation_map(), mesh.cell_height)
	region.navigation_mesh = mesh
	region.bake_navigation_mesh(false)
	region.bake_finished.connect(_on_navigation_bake_finished)
	$NavigationRegion3D/SpatialLayout.destruction_changed.connect(_request_navigation_update)


func _request_navigation_update() -> void:
	_navigation_dirty = true
	_refresh_navigation.call_deferred()


func _refresh_navigation() -> void:
	if not _navigation_dirty or _navigation_baking or not is_inside_tree():
		return
	_navigation_dirty = false
	_navigation_baking = true
	# 同帧多件破坏合并为一次后台烘焙，更新旧掩体占用的通路。
	$NavigationRegion3D.bake_navigation_mesh(true)


func _on_navigation_bake_finished() -> void:
	_navigation_baking = false
	if _navigation_dirty:
		_refresh_navigation.call_deferred()


func _dispose_round() -> void:
	super._dispose_round()
	$NavigationRegion3D/SpatialLayout.reset_destructibles()


func _build_markings() -> void:
	# 标记与碰撞都属于可单独实例化的 SpatialLayout。
	pass


func _build_interface() -> void:
	super._build_interface()
	_title.text = "战斗空间测试台"
	_config_help.tooltip_text += "\n空间台可自选敌人或从左侧整组投放；最多12只，按体型限制容量。"
	_quick_panel = PanelContainer.new()
	_quick_panel.name = "GroupDeployment"
	_quick_panel.theme = _configuration_theme()
	var style := StyleBoxFlat.new()
	style.bg_color = Color(0.065, 0.105, 0.09, 0.95)
	style.set_content_margin_all(6)
	style.set_corner_radius_all(5)
	_quick_panel.add_theme_stylebox_override("panel", style)
	_interface.get_node("Root").add_child(_quick_panel)
	var quick_column := VBoxContainer.new()
	quick_column.add_theme_constant_override("separation", 3)
	_quick_panel.add_child(quick_column)
	var heading := HBoxContainer.new()
	quick_column.add_child(heading)
	var title := _label("空间预设", 12, UI.COLOR_TITLE)
	title.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	heading.add_child(title)
	var help := _label("?", 12, UI.COLOR_DIM)
	help.mouse_filter = Control.MOUSE_FILTER_PASS
	help.tooltip_text = "9个起点；泰坦反应组可观察撤离与受击。\n机制验证组自带“死一只补一只”，清空场上不会结算。"
	heading.add_child(help)
	var groups := HBoxContainer.new()
	_group_choice = OptionButton.new()
	_group_choice.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_group_choice.tooltip_text = "选择空间测试用的敌人编组；点击投放应用本组与其循环模式"
	for preset: Dictionary in GROUP_PRESETS:
		_group_choice.add_item(preset.title)
	groups.add_child(_group_choice)
	_action_button(groups, "投放", "投放所选编组，并采用本组循环模式", deploy_group)
	quick_column.add_child(groups)
	var starts := HBoxContainer.new()
	starts.add_child(_label("起点", 11, UI.COLOR_BODY))
	_start_choice = OptionButton.new()
	_start_choice.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_start_choice.tooltip_text = "下次生成时使用的玩家起点"
	for start: Dictionary in STARTS:
		_start_choice.add_item(start.title)
	starts.add_child(_start_choice)
	_action_button(starts, "满共鸣", "填满玩家共鸣能量，方便反复触发机制测试", fill_resonance)
	quick_column.add_child(starts)
	_invincible.button_pressed = true
	set_selection(GROUP_PRESETS[0].enemies)
	_controls.text += "\nF5 按当前组合重开 · 悬崖落下后可直接重开"
	_controls.text += "\n机制验证配方见 prototypes/spatial_lab/README.md"
	# --lab-demo 是基础实验场的一键启动入口；空间场继承同一入口。


## 实验场专用：把共鸣能量填满，便于反复触发同一个事件做对照观察。
## 只改运行时状态，不写回任何项目配置。
func fill_resonance() -> void:
	if not is_instance_valid(_player):
		return
	var resonance: Node = _player.get("_resonance")
	if resonance != null and resonance.has_method("add_energy"):
		resonance.call("add_energy", 400.0)


func _layout_interface() -> void:
	super._layout_interface()
	var viewport_size := get_viewport().get_visible_rect().size
	if is_instance_valid(_quick_panel):
		_quick_panel.position = Vector2(24, 88)
		_quick_panel.size = Vector2(350, 0)
		_quick_panel.visible = _panel_open and not _stats_open and not _tuning_open
	_controls.position.y = viewport_size.y - 80.0
	_controls.size.y = 68.0


func _create_player() -> void:
	if is_instance_valid(_start_choice):
		player_start = STARTS[_start_choice.selected].position
	super._create_player()


func deploy_group() -> void:
	if _generating:
		return
	var preset: Dictionary = GROUP_PRESETS[_group_choice.selected]
	set_selection(preset.enemies)
	# 机制验证组自带循环模式（见 GROUP_PRESETS 的注释）：否则清空场上就结算。
	if preset.has("loop"):
		_loop_choice.select(int(preset.loop))
		_apply_loop_choice()
	generate_round()


func handle_lab_input(event: InputEvent) -> void:
	if event is InputEventKey and event.pressed and not event.echo and (event.physical_keycode == KEY_F5 or event.keycode == KEY_F5):
		get_viewport().set_input_as_handled()
		generate_round()
		return
	super.handle_lab_input(event)
