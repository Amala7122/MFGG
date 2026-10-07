extends "res://prototypes/combat/combat_lab.gd"
## 小空间实验场复用 Combat Lab，不另建战斗流程或敌人体系。

const GROUP_PRESETS := [
	{"title": "混合组 · 6 只", "enemies": {MUD_GOLEM_ID: 2, FAST_BEAST_ID: 2, HORNET_ID: 2}},
	{"title": "近战组 · 4 只", "enemies": {MUD_GOLEM_ID: 2, FAST_BEAST_ID: 2}},
	{"title": "泰坦组 · 3 只", "enemies": {SEDIMENT_TITAN_ID: 1, MUD_GOLEM_ID: 1, FAST_BEAST_ID: 1}},
	{"title": "单晶兽 · 1 只", "enemies": {FAST_BEAST_ID: 1}},
	{"title": "单泰坦 · 掩体破坏", "enemies": {SEDIMENT_TITAN_ID: 1}},
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
	_title.text = "战斗空间测试场"
	var column := _panel.get_child(0) as VBoxContainer
	(column.get_child(1) as Label).text = "在此自选敌人，或使用左侧整组投放。\n最多 12 只；按体型限制投放线容量。"
	_quick_panel = PanelContainer.new()
	_quick_panel.name = "GroupDeployment"
	var style := StyleBoxFlat.new()
	style.bg_color = Color(0.065, 0.105, 0.09, 0.95)
	style.set_content_margin_all(14)
	style.set_corner_radius_all(8)
	_quick_panel.add_theme_stylebox_override("panel", style)
	_interface.get_node("Root").add_child(_quick_panel)
	var quick_column := VBoxContainer.new()
	quick_column.add_theme_constant_override("separation", 8)
	_quick_panel.add_child(quick_column)
	quick_column.add_child(_label("空间预设 · 整组投放", 18, UI.COLOR_TITLE))
	quick_column.add_child(_label("9 个起点；泰坦反应组可观察撤离与受击。", 13, UI.COLOR_DIM))
	var groups := HBoxContainer.new()
	_group_choice = OptionButton.new()
	_group_choice.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_group_choice.add_theme_font_size_override("font_size", 14)
	for preset: Dictionary in GROUP_PRESETS:
		_group_choice.add_item(preset.title)
	groups.add_child(_group_choice)
	var deploy := Button.new()
	deploy.text = "投放这组"
	deploy.add_theme_font_size_override("font_size", 14)
	deploy.pressed.connect(deploy_group)
	groups.add_child(deploy)
	quick_column.add_child(groups)
	var starts := HBoxContainer.new()
	starts.add_child(_label("玩家起点", 14, UI.COLOR_BODY))
	_start_choice = OptionButton.new()
	_start_choice.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_start_choice.add_theme_font_size_override("font_size", 14)
	for start: Dictionary in STARTS:
		_start_choice.add_item(start.title)
	starts.add_child(_start_choice)
	quick_column.add_child(starts)
	_invincible.button_pressed = true
	set_selection(GROUP_PRESETS[0].enemies)
	_controls.text += "\nF5 按当前组合重开 · 悬崖落下后可直接重开"
	# --lab-demo 是基础实验场的一键启动入口；空间场继承同一入口。


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
	set_selection(GROUP_PRESETS[_group_choice.selected].enemies)
	generate_round()


func handle_lab_input(event: InputEvent) -> void:
	if event is InputEventKey and event.pressed and not event.echo and (event.physical_keycode == KEY_F5 or event.keycode == KEY_F5):
		get_viewport().set_input_as_handled()
		generate_round()
		return
	super.handle_lab_input(event)
