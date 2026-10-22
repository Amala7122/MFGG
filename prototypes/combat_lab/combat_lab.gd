extends Node3D
## 独立战斗测试场，复用正式图鉴与敌人构造入口。

const Config := preload("res://scripts/game_config.gd")
const Spawner := preload("res://scripts/enemy_spawner.gd")
const PlayerScene := preload("res://scenes/player.tscn")
const LabPlayer := preload("res://prototypes/combat_lab/combat_lab_player.gd")
const Overlay := preload("res://prototypes/combat_lab/combat_lab_overlay.gd")
const Flow := preload("res://scripts/game_flow.gd")
const UI := preload("res://scripts/ui_theme.gd")
const Stats := preload("res://prototypes/combat_lab/combat_lab_stats.gd")
const StatsView := preload("res://prototypes/combat_lab/combat_lab_stats_view.gd")
const EnemyTuning := preload("res://scripts/prototypes/enemy_tuning.gd")
const TuningPanel := preload("res://prototypes/combat_lab/enemy_tuning_panel.gd")
const ProfessionalNavigation := preload("res://scripts/testing/professional_navigation.gd")
var _professional_navigation: CanvasLayer
const ParameterInput := preload("res://scripts/testing/parameter_input.gd")
const AttackObserver := preload("res://prototypes/combat_lab/attack_observer.gd")
const AttackInspect := preload("res://scripts/testing/enemy_attack_inspection.gd")
const MudGolemScene := preload("res://prototypes/enemy_prototypes/procedural_mud_golem.tscn")
const MUD_GOLEM_ID := "PrototypeMudGolem"
const MUD_GOLEM_ENTRY := {"id": MUD_GOLEM_ID, "title": "泥土傀儡 · 动作原型", "kind": "melee"}
const SedimentTitanScene := preload("res://prototypes/enemy_prototypes/procedural_sediment_titan.tscn")
const SEDIMENT_TITAN_ID := "PrototypeSedimentTitan"
const SEDIMENT_TITAN_ENTRY := {"id": SEDIMENT_TITAN_ID, "title": "沉积泰坦 · 巨拳原型", "kind": "melee"}
const FastBeastScene := preload("res://prototypes/enemy_prototypes/procedural_fast_beast.tscn")
const FAST_BEAST_ID := "PrototypeFastBeast"
const FAST_BEAST_ENTRY := {"id": FAST_BEAST_ID, "title": "迅捷晶兽 · 四足飞扑原型", "kind": "melee"}
const HornetScene := preload("res://prototypes/enemy_prototypes/procedural_hornet.tscn")
const HORNET_ID := "PrototypeHornet"
const HORNET_ENTRY := {"id": HORNET_ID, "title": "晶刺蜂 · 飞行原型", "kind": "ranged"}
const PROTOTYPE_SCENES := {
	"VisualBurstCrawler": preload("res://prototypes/enemy_prototypes/procedural_burst_crawler.tscn"),
	"VisualPrismSpider": preload("res://prototypes/enemy_prototypes/procedural_prism_spider.tscn"),
	"VisualChargeBeetle": preload("res://prototypes/enemy_prototypes/procedural_charge_beetle.tscn"),

	MUD_GOLEM_ID: MudGolemScene,
	SEDIMENT_TITAN_ID: SedimentTitanScene,
	FAST_BEAST_ID: FastBeastScene,
	HORNET_ID: HornetScene,
}

const MAX_ENEMIES := 36
const LINE_Z := -38.0
const LINE_SPACING := 3.0
const PLAYER_START := Vector3(0, 1.08, 8)

# 独立空间预设复用同一套投放、统计和补兵流程，空场入口保留原默认值。
@export var player_start := PLAYER_START
@export var enemy_line_z := LINE_Z
@export var enemy_limit := MAX_ENEMIES
@export var enemy_line_width := MAX_ENEMIES * LINE_SPACING

enum State { CONFIGURING, COUNTDOWN, FIGHTING, FINISHED, RESOLVING }
enum LoopMode { OFF, WAVE, REPLACE }

var state := State.CONFIGURING
var countdown_remaining := 0.0
var elapsed := 0.0
var spawned_total := 0
var _serial := 0
var _generating := false
var _cancel_generation_requested := false
var _panel_open := true
var _settlement_won := false
var _settlement_player_invincible := false
var _live_enemies: Array[Node3D] = []
var _rows: Dictionary = {}
var _round_slots: Array[Dictionary] = []
var _pending_slots: Dictionary = {}
var _wave_pending := false
var _loop_mode := LoopMode.OFF
var _wave_number := 0
var _player: CharacterBody3D
var _spawner: Node
var _static_children: Array[Node] = []
var _flow: CanvasLayer
var _saved_flow_state := 0
var _saved_flow_mode := Node.PROCESS_MODE_ALWAYS
var _saved_flow_visible := true
var _saved_paused := false
var _saved_mouse_mode := Input.MOUSE_MODE_VISIBLE

var _interface: CanvasLayer
var _panel: PanelContainer
var _summary: Label
var _config_help: Label
var _title: Label
var _status: Label
var _result: Label
var _countdown: Label
var _countdown_hint: Label
var _generate: Button
var _resume: Button
var _invincible: CheckBox
## 【敌人不死】见 _build_interface 的说明：伤害照常结算，只是不进入死亡。
var _enemy_invincible: CheckBox
var _crowd_motion: CheckBox
var _level: SpinBox
var _loop_choice: OptionButton
var _controls: Label
var _weapon_plate: PanelContainer
var _weapon_readout: Label
var _stats := Stats.new()
var _stats_open := false
var _tuning_open := false
var _tuning_panel: PanelContainer
var _stats_panel: PanelContainer
var _stats_report: RichTextLabel
var _stats_resume: Button
var _live_stats_toggle: CheckBox
var _live_stats_plate: PanelContainer
var _live_stats_readout: Label
var _sample_time := 0.0
var _attack_observer: Node3D
var _observation_profile := ""
var _observation_values := {}
var _shape_transition := false

@onready var _actors: Node3D = $Combatants
@onready var _enemy_container: Node3D = $Combatants/Enemies
@onready var _overview: Camera3D = $OverviewCamera


func _ready() -> void:
	add_to_group("professional_workspaces")
	_professional_navigation = ProfessionalNavigation.shared(get_tree())
	_professional_navigation.set_local()
	_saved_paused = get_tree().paused
	_saved_mouse_mode = MouseControl.mode
	_flow = get_node_or_null("/root/GameFlow") as CanvasLayer
	if _flow:
		_saved_flow_state = int(_flow.get("state"))
		_saved_flow_mode = _flow.process_mode
		_saved_flow_visible = _flow.visible
		_flow.process_mode = Node.PROCESS_MODE_DISABLED
		_flow.visible = false
		_flow.set("state", Flow.State.PLAYING)
	_build_navigation()
	_build_markings()
	_spawner = Spawner.new()
	_spawner.name = "EnemySpawner"
	_enemy_container.add_child(_spawner)
	_build_interface()
	_attack_observer = AttackObserver.new()
	_attack_observer.lab = self
	add_child(_attack_observer)
	_attack_observer.replay_requested.connect(func(): observe_draft(_observation_profile, _observation_values, false))
	_attack_observer.return_requested.connect(func(): _show_enemy_tuning(_observation_profile))
	_attack_observer.skill_choice.item_selected.connect(func(index: int):
		if _attack_observer.study: _attack_observer.distance_input.value = _observation_distance(_observation_profile, _observation_values, index))
	_tuning_panel.connect("observe_requested", observe_draft)
	_tuning_panel.connect("visual_requested", func(profile: String):
		if _generating: return
		_professional_navigation.open(self, "res://prototypes/visual_lab/enemy_visual_lab.tscn", profile, "combat" if profile == "VisualChargeBeetle" else "visual"))
	_static_children.assign(get_children())
	_create_player()
	get_viewport().size_changed.connect(_layout_interface)
	_layout_interface()
	_show_configuration()
	# Autoload 的首帧菜单与画质覆盖结束后，再确立实验场初始状态。
	for frame in range(3):
		await get_tree().process_frame
		if _flow:
			_flow.visible = false
			_flow.set("state", Flow.State.PLAYING)
		if state == State.CONFIGURING:
			get_tree().paused = true
			MouseControl.mode = Input.MOUSE_MODE_VISIBLE
	var environment: Environment = $WorldEnvironment.environment
	environment.fog_enabled = false
	environment.volumetric_fog_enabled = false
	environment.ambient_light_energy = 0.65
	if OS.get_cmdline_user_args().has("--lab-mud-golem"):
		set_selection({MUD_GOLEM_ID: 1})
		_invincible.button_pressed = true
		var check: CheckBox = _rows[MUD_GOLEM_ID].check
		check.grab_focus()
	if OS.get_cmdline_user_args().has("--lab-sediment-titan"):
		set_selection({SEDIMENT_TITAN_ID: 1})
		_invincible.button_pressed = true
		var check: CheckBox = _rows[SEDIMENT_TITAN_ID].check
		check.grab_focus()
	if OS.get_cmdline_user_args().has("--lab-fast-beast"):
		set_selection({FAST_BEAST_ID: 1})
		_invincible.button_pressed = true
		var check: CheckBox = _rows[FAST_BEAST_ID].check
		check.grab_focus()
	if OS.get_cmdline_user_args().has("--lab-hornet"):
		set_selection({HORNET_ID: 1})
		_invincible.button_pressed = true
	if OS.get_cmdline_user_args().has("--lab-hornet-swarm"):
		set_selection({HORNET_ID: 16})
		_invincible.button_pressed = true
	if OS.get_cmdline_user_args().has("--lab-uniform"):
		_crowd_motion.button_pressed = false
	if OS.get_cmdline_user_args().has("--lab-pack"):
		set_selection({FAST_BEAST_ID: 24})
		_invincible.button_pressed = true
	if OS.get_cmdline_user_args().has("--lab-enemy-tuning"):
		var tuning_id := SEDIMENT_TITAN_ID
		if OS.get_cmdline_user_args().has("--lab-mud-golem"):
			tuning_id = MUD_GOLEM_ID
		if OS.get_cmdline_user_args().has("--lab-fast-beast"):
			tuning_id = FAST_BEAST_ID
		if OS.get_cmdline_user_args().has("--lab-hornet"):
			tuning_id = HORNET_ID
		_show_enemy_tuning(tuning_id)
	if OS.get_cmdline_user_args().has("--lab-demo"):
		generate_round()
	if has_meta("workspace_profile"):
		_tuning_panel.target_id = get_meta("workspace_target_id", "")
		_show_enemy_tuning(get_meta("workspace_profile"))


func _exit_tree() -> void:
	if is_instance_valid(_flow):
		_flow.set("state", _saved_flow_state)
		_flow.process_mode = _saved_flow_mode
		_flow.visible = _saved_flow_visible
	get_tree().paused = _saved_paused
	if not get_meta("workspace_suspended", false): MouseControl.mode = _saved_mouse_mode


func workspace_suspending() -> void:
	if _tuning_open:
		_tuning_panel._commit_inputs()
		_tuning_panel.remember_view()
	_attack_observer.camera_control.cancel_drag()


func workspace_resumed() -> void:
	if is_instance_valid(_flow):
		_flow.process_mode = Node.PROCESS_MODE_DISABLED
		_flow.visible = false
		_flow.set("state", Flow.State.PLAYING)
	get_tree().paused = true
	MouseControl.mode = Input.MOUSE_MODE_VISIBLE
	_tuning_panel.resume_view()
	_tuning_panel._set_notice("已返回同一页面与草稿；战斗实例待重新观察／生成，未自动继续")
	_layout_interface()


func _process(delta: float) -> void:
	if state == State.COUNTDOWN:
		countdown_remaining = maxf(countdown_remaining - delta, 0.0)
		_countdown.text = str(ceili(countdown_remaining))
		if countdown_remaining <= 0.0:
			_start_fight()
	elif state == State.FIGHTING:
		_stats.advance(delta)
		elapsed = _stats.time
		_stats.capture_player(_player)
		_sample_time += delta
		if _sample_time >= 0.1:
			_sample_time = 0.0
			_stats.sample_motion(_live_enemies)
		_update_status()
	elif state == State.RESOLVING:
		_update_weapon_readout()
		if not _has_enemy_death_effects():
			_present_result(_settlement_won)


func handle_lab_input(event: InputEvent) -> void:
	if not (event is InputEventKey) or not event.pressed or event.echo:
		return
	var key: int = event.physical_keycode if event.physical_keycode != 0 else event.keycode
	if key == KEY_V and state == State.FIGHTING and not _tuning_open:
		_attack_observer.enabled = not _attack_observer.enabled
		get_viewport().set_input_as_handled()
		return
	if key not in [KEY_ESCAPE, KEY_TAB]:
		return
	get_viewport().set_input_as_handled()
	if key == KEY_ESCAPE:
		# 包括生成和死亡演出期间：Esc 永远先释放，只有显式继续才重新捕获。
		MouseControl.mode = Input.MOUSE_MODE_VISIBLE
		if _generating:
			_cancel_generation_requested = true
	if _generating or state == State.RESOLVING:
		return
	if _tuning_open:
		_tuning_panel.call("_request_return")
		return
	if state == State.COUNTDOWN:
		clear_round()
	elif key == KEY_TAB and state == State.FIGHTING and _panel_open:
		resume_fight()
	else:
		_show_configuration()


func _build_navigation() -> void:
	# 空场地是确定的平面，无需烘焙正式世界的地形或加载其场景内容。
	var mesh := NavigationMesh.new()
	mesh.cell_size = Config.get_float("navigation.cell_size", 0.3)
	mesh.cell_height = Config.get_float("navigation.cell_height", 0.25)
	mesh.vertices = PackedVector3Array([
		Vector3(-58, 0, -43), Vector3(-58, 0, 43),
		Vector3(58, 0, 43), Vector3(58, 0, -43),
	])
	mesh.add_polygon(PackedInt32Array([0, 1, 2, 3]))
	NavigationServer3D.map_set_cell_size($NavigationRegion3D.get_navigation_map(), mesh.cell_size)
	NavigationServer3D.map_set_cell_height($NavigationRegion3D.get_navigation_map(), mesh.cell_height)
	$NavigationRegion3D.navigation_mesh = mesh


func _build_markings() -> void:
	var markings := Node3D.new()
	markings.name = "FloorMarkings"
	add_child(markings)
	var grid_material := StandardMaterial3D.new()
	grid_material.albedo_color = Color(0.35, 0.40, 0.36)
	grid_material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	for x in range(-55, 56, 5):
		_add_floor_box(markings, Vector3(x, 0.012, 0), Vector3(0.035, 0.015, 88), grid_material)
	for z in range(-40, 41, 5):
		_add_floor_box(markings, Vector3(0, 0.012, z), Vector3(118, 0.015, 0.035), grid_material)
	var line_material := StandardMaterial3D.new()
	line_material.albedo_color = Color(0.9, 0.63, 0.25)
	line_material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	_add_floor_box(markings, Vector3(0, 0.02, LINE_Z + 2), Vector3(112, 0.02, 0.16), line_material)
	var spawn_material := StandardMaterial3D.new()
	spawn_material.albedo_color = Color(0.38, 0.78, 0.77)
	spawn_material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	_add_floor_box(markings, Vector3(0, 0.018, PLAYER_START.z), Vector3(4, 0.02, 0.12), spawn_material)
	for side in [-1.0, 1.0]:
		_add_floor_box(markings, Vector3(side * 2, 0.018, PLAYER_START.z), Vector3(0.12, 0.02, 4), spawn_material)


func _add_floor_box(parent: Node3D, at: Vector3, dimensions: Vector3, material: Material) -> void:
	var instance := MeshInstance3D.new()
	var mesh := BoxMesh.new()
	mesh.size = dimensions
	mesh.material = material
	instance.mesh = mesh
	instance.position = at
	instance.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	parent.add_child(instance)


func _create_player() -> void:
	_player = PlayerScene.instantiate() as CharacterBody3D
	_player.set_script(LabPlayer)
	_player.name = "LabPlayer"
	_player.position = player_start
	_player.process_mode = Node.PROCESS_MODE_DISABLED
	_actors.add_child(_player)
	_player.connect("defeated", _on_player_defeated)
	_player.set_meta(&"experiment_invincible", _invincible.button_pressed)
	# 实验场里 E 手雷与 Q 震地**无冷却、无限次**：机制验证要反复触发同一个事件
	# （盾卫迎面对盾、手雷能不能破防），卡冷却会把单次观察拉长到十几秒。
	# 与 experiment_invincible 同一套约定，正式游戏永远没有这个 meta。
	_player.set_meta(&"experiment_unlimited_abilities", true)
	_player.set_meta(&"combat_recorder", _stats)
	var weapon: Node = _player.get("_weapon")
	weapon.set("_weapon_level", int(_level.value))
	weapon.call("apply_weapon_visual_upgrade")
	_player.call("_refresh_hud")
	_stats.capture_player(_player)
	var hud: Node = _player.get("_hud")
	var aim_ui: CanvasLayer = _player.get("aim_ui")
	var hidden_hud := Control.new()
	hidden_hud.name = "HiddenMainHUD"
	hidden_hud.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	hidden_hud.mouse_filter = Control.MOUSE_FILTER_IGNORE
	hidden_hud.visible = false
	# 挂到隐藏父控件下，正式 HUD 刷新时即使切换子控件可见性也不会重新出现。
	var widgets := aim_ui.get_children()
	aim_ui.add_child(hidden_hud)
	for widget in widgets:
		if widget is CanvasItem and widget != hud.get("_crosshair") and widget != hud.get("_hit_marker"):
			widget.reparent(hidden_hud, false)
	_player.get("camera_pivot").rotation.x = deg_to_rad(-8.0)
	_player.set("target_pitch", deg_to_rad(-8.0))
	(_player.get("aim_ui") as CanvasLayer).visible = false
	_overview.current = true


func open_sparring() -> void:
	var selection := get_selection()
	var groups := preload("res://tools/probes/sparring/sparring_groups.gd")
	var problem := groups.validate(selection)
	if not problem.is_empty():
		_set_result("尚不能交接到正式实战：" + problem)
		return
	var id := "lab_" + JSON.stringify(selection).sha256_text().left(8)
	var error := groups.save_named(id, selection)
	if error != OK:
		_set_result("编组交接保存失败：" + error_string(error))
		return
	preload("res://tools/probes/sparring/sparring_settings.gd").pending_run = {"scenario_id": "sanctum_mixed", "group_id": id, "group_selection": selection}
	get_tree().paused = false
	get_tree().change_scene_to_file("res://prototypes/sparring_lab/combat_sparring_lab.tscn")

func get_selection() -> Dictionary:
	var selection := {}
	for id in _rows:
		var row: Dictionary = _rows[id]
		if (row.check as CheckBox).button_pressed:
			selection[id] = int((row.count as SpinBox).value)
	return selection


func set_selection(selection: Dictionary) -> void:
	for id in _rows:
		var row: Dictionary = _rows[id]
		(row.check as CheckBox).button_pressed = selection.has(id)
		if selection.has(id):
			(row.count as SpinBox).value = int(selection[id])
	_update_selection()


func _update_selection(_unused: Variant = null) -> void:
	var total := 0
	var kinds := 0
	var line_width := 0.0
	var invalid_profile := false
	for row: Dictionary in _rows.values():
		var selected := (row.check as CheckBox).button_pressed
		(row.count as SpinBox).editable = selected
		if selected:
			kinds += 1
			total += int((row.count as SpinBox).value)
			line_width += _slot_width(String(row.entry.id)) * int((row.count as SpinBox).value)
			if EnemyTuning.PROFILE_PATHS.has(String(row.entry.id)) and EnemyTuning.get_values(String(row.entry.id)).is_empty():
				invalid_profile = true
	_summary.text = "已选 %d 种 · %d / %d 只" % [kinds, total, enemy_limit]
	var too_wide := line_width > enemy_line_width
	_summary.modulate = UI.COLOR_DANGER if total > enemy_limit or too_wide else UI.COLOR_BODY
	_generate.disabled = _generating or total <= 0 or total > enemy_limit or too_wide or invalid_profile
	if invalid_profile:
		_set_result("敌人参数配置不可用，请检查对应的独立配置文件。")
	_generate.tooltip_text = "单排空间不足，请减少数量或调整敌人的排列占位" if too_wide else "生成选择的敌人，倒数后开始新的战斗"


func _slot_width(id: String) -> float:
	if EnemyTuning.PROFILE_PATHS.has(id):
		var values := EnemyTuning.get_values(id)
		return float(values.get("formation_width", LINE_SPACING)) * float(values.get("body_size", 1.0))
	return LINE_SPACING


func generate_round() -> void:
	if _generating:
		return
	var selection := get_selection()
	var total := 0
	var line_width := 0.0
	for id in selection:
		total += int(selection[id])
		line_width += _slot_width(String(id)) * int(selection[id])
	if total < 1 or total > enemy_limit or line_width > enemy_line_width:
		return
	_generating = true
	_cancel_generation_requested = false
	var tuning_snapshot := {}
	for id in selection:
		if EnemyTuning.PROFILE_PATHS.has(id):
			tuning_snapshot[id] = EnemyTuning.get_values(id).duplicate(true)
			if tuning_snapshot[id].is_empty():
				_generating = false
				_update_selection()
				return
	_serial += 1
	_dispose_round()
	state = State.CONFIGURING
	_stats = Stats.new({"level": int(_level.value), "count": total, "composition": selection,
		"mode": _loop_choice.get_selected_id(), "enemy_parameters": tuning_snapshot.duplicate(true),
		"crowd_motion": _crowd_motion.button_pressed})
	_sample_time = 0.0
	_create_player()
	elapsed = 0.0
	spawned_total = total
	_loop_mode = _loop_choice.get_selected_id()
	_wave_number = 1
	_set_result("")
	var index := 0
	var line_cursor := -line_width * 0.5
	for id in selection:
		var entry: Dictionary = _rows[id].entry
		for copy in range(int(selection[id])):
			var width := _slot_width(String(id))
			var x := line_cursor + width * 0.5
			line_cursor += width
			# 固定本轮组合、等级和起始位置，暂停编辑面板不会改变自动补兵。
			_round_slots.append({"entry": entry.duplicate(true), "level": _level.value, "x": x,
				"tuning": tuning_snapshot.get(id, {}).duplicate(true), "crowd_motion": _crowd_motion.button_pressed})
			_spawn_slot(index, false)
			index += 1
	_update_selection()
	await get_tree().process_frame
	_generating = false
	if _cancel_generation_requested:
		clear_round()
		return
	_begin_countdown()


func _spawn_slot(slot_index: int, activate: bool) -> void:
	var slot: Dictionary = _round_slots[slot_index]
	var spawn_position := _spawn_position(slot_index, slot)
	var enemy: CharacterBody3D
	if PROTOTYPE_SCENES.has(String(slot.entry.id)):
		var prototype_scene: PackedScene = PROTOTYPE_SCENES[String(slot.entry.id)]
		enemy = prototype_scene.instantiate() as CharacterBody3D
		enemy.set_meta(&"enemy_tuning", slot.tuning.duplicate(true))
		enemy.set_meta(&"crowd_uniform", not bool(slot.crowd_motion))
		if slot.has("observe_z"): enemy.set_meta(&"crowd_seed", 20261020)
		enemy.position = spawn_position
		enemy.process_mode = Node.PROCESS_MODE_DISABLED
		_enemy_container.add_child(enemy)
	else:
		enemy = _spawner.call("spawn_enemy", slot.entry, spawn_position, slot.level) as CharacterBody3D
	enemy.process_mode = Node.PROCESS_MODE_DISABLED
	enemy.set_meta(&"lab_ground_y", spawn_position.y)
	enemy.set_meta(&"lab_roster_id", String(slot.entry.id))
	enemy.set_meta(&"lab_slot", slot_index)
	enemy.set_meta(&"lab_title", String(slot.entry.title))
	enemy.set_meta(&"lab_kind", String(slot.entry.kind))
	enemy.set_meta(&"combat_recorder", _stats)
	# 敌人不死：与玩家无敌同一套 meta 约定（正式游戏永远没有这个 meta）。
	enemy.set_meta(&"experiment_invincible", _enemy_invincible.button_pressed)
	_live_enemies.append(enemy)
	enemy.tree_exited.connect(_on_enemy_gone.bind(enemy, _serial, slot_index), CONNECT_ONE_SHOT)
	# 排在生成器的延后配置之后，按实际体型摆位，再让补兵加入战斗。
	_prepare_enemy.call_deferred(enemy, _serial, activate)


func _spawn_position(_slot_index: int, slot: Dictionary) -> Vector3:
	return Vector3(slot.x, 0, float(slot.get("observe_z", enemy_line_z)))


func _prepare_enemy(enemy: CharacterBody3D, serial: int, activate: bool) -> void:
	if not is_instance_valid(enemy) or serial != _serial or not is_inside_tree():
		return
	var capsule := enemy.get_node("CollisionShape3D") as CollisionShape3D
	var shape_height: float = capsule.shape.size.y if capsule.shape is BoxShape3D else (capsule.shape.radius * 2.0 if capsule.shape is SphereShape3D else capsule.shape.height)
	var half_height := shape_height * enemy.scale.y * 0.5
	var ground_y := float(enemy.get_meta(&"lab_ground_y", 0.0))
	enemy.position.y = maxf(float(enemy.call("get_spawn_height", _player.global_position.y)), ground_y + half_height + 0.08) if enemy.has_method("get_spawn_height") else ground_y + half_height + 0.08
	var offset := _player.global_position - enemy.global_position
	enemy.rotation.y = atan2(-offset.x, -offset.z)
	enemy.velocity = Vector3.ZERO
	enemy.set("target", _player)
	_stats.register_enemy(enemy)
	if activate and state == State.FIGHTING:
		enemy.process_mode = Node.PROCESS_MODE_INHERIT


func _on_loop_mode_selected(_index: int) -> void:
	_apply_loop_choice()
	_update_status()


func _apply_loop_choice() -> void:
	var selected := _loop_choice.get_selected_id()
	if selected != _loop_mode:
		_loop_mode = selected
		_stats.set_mode(selected)
		_stats.capture_player(_player)
		_pending_slots.clear()
		_wave_pending = false


func _continue_loop() -> void:
	if not _can_reinforce():
		return
	if _loop_mode == LoopMode.REPLACE:
		var occupied := {}
		for enemy in _live_enemies:
			occupied[int(enemy.get_meta(&"lab_slot"))] = true
		for index in range(_round_slots.size()):
			if not occupied.has(index):
				_pending_slots[index] = true
	elif _live_enemies.is_empty():
		if _loop_mode == LoopMode.WAVE:
			_wave_pending = true
		else:
			_finish_round(true)
			return
	_flush_respawns.call_deferred(_serial)


func _can_reinforce() -> bool:
	return is_inside_tree() and state == State.FIGHTING and is_instance_valid(_player) and float(_player.get("health")) > 0.0


func _flush_respawns(serial: int) -> void:
	# 死亡摘除回调之后再生成，避免操作正在退出树的父节点。
	# 暂停时保留待补名额，继续战斗再补；清空、重开和玩家倒下均取消旧请求。
	if serial != _serial or not _can_reinforce() or get_tree().paused:
		return
	if _loop_mode == LoopMode.WAVE and _wave_pending and _live_enemies.is_empty():
		_wave_pending = false
		_wave_number += 1
		for index in range(_round_slots.size()):
			_spawn_slot(index, true)
	elif _loop_mode == LoopMode.REPLACE:
		var slots := _pending_slots.keys()
		_pending_slots.clear()
		for index: int in slots:
			_spawn_slot(index, true)
	_update_status()


func _dispose_round() -> void:
	_stats.stop("清空 / 重开")
	_pending_slots.clear()
	_wave_pending = false
	_round_slots.clear()
	_live_enemies.clear()
	for child in _enemy_container.get_children():
		if child != _spawner:
			child.free()
	if is_instance_valid(_player):
		_player.free()
	# 玩家弹道、敌方子弹、地面预警、拾取物等都挂在 current_scene 下。
	# 清理上一轮动态内容，避免重开后旧的炮击和手雷继续伤人。
	for child in get_children():
		if child not in _static_children:
			child.free()


func clear_round() -> void:
	if _generating:
		return
	_serial += 1
	_dispose_round()
	_create_player()
	state = State.CONFIGURING
	spawned_total = 0
	elapsed = 0.0
	_wave_number = 0
	_set_result("")
	_show_configuration()


func _begin_countdown() -> void:
	state = State.COUNTDOWN
	_tuning_open = false
	_tuning_panel.visible = false
	_stats_open = false
	_stats_panel.visible = false
	countdown_remaining = 3.0
	_panel_open = false
	_interface.visible = true
	_panel.visible = false
	_countdown.visible = true
	_countdown.text = "3"
	_countdown_hint.text = "准备战斗 · %d 只敌人\nEsc 取消本轮" % spawned_total
	_countdown_hint.visible = true
	_overview.current = false
	(_player.get("camera") as Camera3D).current = true
	get_tree().paused = false
	MouseControl.mode = Input.MOUSE_MODE_CAPTURED
	if _flow:
		_flow.set("state", Flow.State.PLAYING)
	_update_status()
	_layout_interface()


func _start_fight() -> void:
	state = State.FIGHTING
	_stats.start()
	_stats.capture_player(_player)
	_countdown.visible = false
	_countdown_hint.visible = false
	_interface.visible = false
	_player.process_mode = Node.PROCESS_MODE_INHERIT
	(_player.get("aim_ui") as CanvasLayer).visible = true
	for enemy in _live_enemies:
		enemy.process_mode = Node.PROCESS_MODE_INHERIT
	_update_status()
	_layout_interface()


func _show_configuration() -> void:
	if is_instance_valid(_attack_observer) and _attack_observer.study:
		_attack_observer.end_study()
		state = State.CONFIGURING
	_panel_open = true
	_tuning_open = false
	_tuning_panel.visible = false
	_stats_open = false
	_stats.paused = true
	_stats_panel.visible = false
	_interface.visible = true
	_panel.visible = true
	_resume.visible = state == State.FIGHTING
	_countdown.visible = false
	_countdown_hint.visible = false
	if state != State.FIGHTING:
		_overview.current = true
	if is_instance_valid(_player):
		(_player.get("aim_ui") as CanvasLayer).visible = false
	get_tree().paused = true
	MouseControl.mode = Input.MOUSE_MODE_VISIBLE
	_update_selection()
	_update_status()
	_layout_interface()


func resume_fight() -> void:
	if state != State.FIGHTING:
		return
	_panel_open = false
	_tuning_open = false
	_tuning_panel.visible = false
	_stats_open = false
	_stats_panel.visible = false
	_interface.visible = false
	_panel.visible = false
	(_player.get("aim_ui") as CanvasLayer).visible = true
	_player.set_meta(&"experiment_invincible", _invincible.button_pressed)
	_player.set_meta(&"experiment_unlimited_abilities", true)
	_apply_loop_choice()
	_stats.paused = false
	_stats.capture_player(_player)
	get_tree().paused = false
	MouseControl.mode = Input.MOUSE_MODE_CAPTURED
	_continue_loop()
	_update_status()
	_layout_interface()


func _on_enemy_gone(enemy: Node3D, serial: int, slot_index: int) -> void:
	if serial != _serial or not is_inside_tree():
		return
	_live_enemies.erase(enemy)
	_stats.remove_enemy(enemy.get_instance_id())
	if not _can_reinforce():
		return
	if _loop_mode == LoopMode.REPLACE:
		_pending_slots[slot_index] = true
		_flush_respawns.call_deferred(_serial)
	elif _live_enemies.is_empty():
		if _loop_mode == LoopMode.WAVE:
			_stats.complete_wave()
			_wave_pending = true
			_flush_respawns.call_deferred(_serial)
		else:
			_finish_round(true)


func _on_player_defeated() -> void:
	if state == State.FIGHTING:
		_finish_round(false)


func _finish_round(won: bool) -> void:
	if state in [State.RESOLVING, State.FINISHED]:
		return
	_stats.capture_player(_player)
	_stats.stop("测试完成" if won else "玩家倒下")
	_pending_slots.clear()
	_wave_pending = false
	if _has_enemy_death_effects():
		# 战斗统计立即冻结，死亡碎片仍随场景树运行；不换镜头、不弹面板。
		_settlement_won = won
		state = State.RESOLVING
		_panel_open = false
		_stats_open = false
		_interface.visible = false
		_panel.visible = false
		_stats_panel.visible = false
		_live_stats_plate.visible = false
		if is_instance_valid(_player):
			# 已结束的战斗不再让残留弹丸伤害观看死亡演出的玩家。
			_settlement_player_invincible = bool(_player.get_meta(&"experiment_invincible", false))
			_player.set_meta(&"experiment_invincible", true)
		get_tree().paused = false
		_update_status()
		return
	_present_result(won)


func _has_enemy_death_effects() -> bool:
	for effect in get_tree().get_nodes_in_group("enemy_death_effect"):
		if is_ancestor_of(effect) and not effect.is_queued_for_deletion():
			return true
	return false


func _present_result(won: bool) -> void:
	if state == State.RESOLVING and is_instance_valid(_player):
		_player.set_meta(&"experiment_invincible", _settlement_player_invincible)
	state = State.FINISHED
	_set_result("%s · 用时 %.1f 秒\n剩余 %d / %d 只，可修改配置再次生成" % [
		"测试完成" if won else "玩家倒下", elapsed, _live_enemies.size(), spawned_total,
	])
	_show_configuration()
	_show_statistics()
	if _flow:
		_flow.set("state", Flow.State.PLAYING)


func _update_status() -> void:
	var label: String = ["准备配置", "准备战斗", "已暂停" if _panel_open else "战斗中", "本轮结束", "死亡演出"][state]
	_status.text = "%s  ·  剩余 %d / %d  ·  %.1f 秒" % [label, _live_enemies.size(), spawned_total, elapsed]
	if _wave_number > 0 and _loop_mode != LoopMode.OFF:
		_status.text += "  ·  %s" % ("A 第 %d 批" % _wave_number if _loop_mode == LoopMode.WAVE else "B 逐只补兵")
	_update_weapon_readout()
	_update_live_stats()


func _update_weapon_readout() -> void:
	_weapon_plate.visible = is_instance_valid(_player) and not _stats_open and not _tuning_open and (not is_instance_valid(_attack_observer) or not _attack_observer.study) and state in [State.FIGHTING, State.FINISHED, State.RESOLVING]
	if not is_instance_valid(_player):
		return
	var weapon: Node = _player.get("_weapon")
	var text := StatsView.weapon_text(weapon.call("get_combat_snapshot"))
	var q_remaining := maxf(float(_player.get("_skill_cooldown")), 0.0)
	var q_state := "可用" if q_remaining <= 0.0 else "冷却 %.1f 秒" % (ceilf(q_remaining * 10.0) / 10.0)
	text += "\nQ 震地脉冲 · " + q_state
	text += "\nE 手雷 · %s" % (
		"可用" if maxf(float(_player.get("_grenade_cooldown")), 0.0) <= 0.0
		else "冷却 %.1f 秒" % (ceilf(maxf(float(_player.get("_grenade_cooldown")), 0.0) * 10.0) / 10.0)
	)
	text += "\n" + _resonance_readout()
	if _weapon_readout.text != text:
		_weapon_readout.text = text


## 共鸣读数。主 HUD 在实验场里被隐藏（生命 / 弹药 / 技能都藏起来了），
## 于是"共鸣满没满"完全看不见 —— 而"盾卫会不会迎面对盾""共鸣打不动重型"
## 这些验证全靠它是否满。这里补一条自用读数（用户反馈：实验台无显示）。
func _resonance_readout() -> String:
	var resonance: Variant = _player.get("_resonance")
	if resonance == null:
		return "共鸣 · 未接入"
	var energy := float(resonance.get("_energy"))
	var max_energy := maxf(float(resonance.get("_max_energy")), 1.0)
	var cap := maxf(float(resonance.get("_overflow_cap")), max_energy)
	var ready := bool(resonance.call("is_ready"))
	var bar := "█".repeat(clampi(roundi(energy / max_energy * 10.0), 0, 10))
	bar += "░".repeat(clampi(10 - roundi(energy / max_energy * 10.0), 0, 10))
	var head := "共鸣 · %s %s %.0f/%.0f" % [
		"可放" if ready else "充能中", bar, energy, max_energy
	]
	if cap > max_energy:
		head += "（溢出上限 %.0f）" % cap
	return head


func get_stats_snapshot() -> Dictionary:
	return _stats.snapshot()


func _update_live_stats() -> void:
	_live_stats_plate.visible = _live_stats_toggle.button_pressed and state == State.FIGHTING and not _panel_open
	if _live_stats_plate.visible:
		_live_stats_readout.text = StatsView.live_text(_stats.live_snapshot())
	_live_stats_plate.position = _weapon_plate.position + Vector2(0, _weapon_plate.size.y + 10)


func _show_statistics() -> void:
	_tuning_open = false
	_tuning_panel.visible = false
	_stats_open = true
	_stats_panel.visible = true
	_panel.visible = false
	_stats_resume.visible = state == State.FIGHTING
	_stats_report.text = StatsView.report(_stats.snapshot())
	_update_status()
	_layout_interface()


func _on_tuning_closed() -> void:
	_professional_navigation.set_local()
	_show_configuration()
	if not _tuning_panel._pending_text.is_empty():
		_set_result("未提交输入已保留；重新进入该敌人调参可继续修改，未用于预览或写入方案。")


func _show_enemy_tuning(id: String) -> void:
	_tuning_panel.target_id = String(get_meta("workspace_target_id", "")) if get_meta("workspace_profile", "") == id else ""
	_show_configuration()
	_tuning_open = true
	_panel.visible = false
	_tuning_panel.call("open_enemy", id)
	_professional_navigation.set_local() if has_meta("workspace_profile") else _professional_navigation.set_local(_tuning_panel._request_return, "敌人配置")
	_update_status()
	_layout_interface()


func accepts_player_input() -> bool:
	return state == State.FIGHTING and not _panel_open and not get_tree().paused and not _attack_observer.study


func _observation_distance(id: String, values: Dictionary, skill: int) -> float:
	var size := float(values.body_size)
	match id:
		"PrototypeMudGolem": return (float(values.attack_distance)+float(values.attack_reach_extra))*size*0.7
		"PrototypeFastBeast": return (float(values.pounce_min_distance)+float(values.pounce_max_distance))*size*0.5 if skill == 0 else float(values.normal_attack_reach)*size*0.65
		"PrototypeHornet": return float(values.strafe_distance)*size if skill == 0 else minf(float(values.dive_range)*size*0.65, 8.0*size)
		"PrototypeSedimentTitan":
			var keys := ["slam_distance", "sweep_distance", "thrust_distance", "leap_max_distance", "triple_slam_length", "normal_attack_reach", "slam_distance"]
			return float(values[keys[clampi(skill,0,6)]])*size*0.65
		"VisualChargeBeetle": return maxf(float(values.charge_min_range)+1.0,float(values.charge_distance)*0.65)*size if skill == 0 else float(values.contact_range)*size*0.7
	return maxf(float(values.get("retreat_exit_range", 1.0))+1.0, float(values.get("attack_range", 12.0))*0.65)*size


func observe_draft(id: String, values: Dictionary, first := true, play := true) -> void:
	if _generating:
		_tuning_panel.call("_set_notice", "正在生成，无法同时重建观察对象；请稍后重试，草稿已保留。")
		return
	if not PROTOTYPE_SCENES.has(id):
		_tuning_panel.call("_set_notice", "该敌人未接入真实攻击观察；草稿已保留。")
		return
	var invalid := EnemyTuning.validate(id, values)
	if not invalid.is_empty():
		_tuning_panel.call("_set_notice", "无法观察本草稿：" + invalid + "；草稿已保留，请修正后重试。")
		_tuning_panel.call("_refresh_feedback", "观察本草稿", true)
		return
	var skill: int = 0 if first else _attack_observer.skill_choice.selected
	_attack_observer.close_shape_edit()
	_professional_navigation.set_local(func(): _show_enemy_tuning(id), "战斗参数")
	_observation_profile = id
	_observation_values = values.duplicate(true)
	if first: _attack_observer.distance_input.value = _observation_distance(id, values, skill)
	_serial += 1
	_dispose_round()
	_stats = Stats.new()
	_create_player()
	_player.position = Vector3(0, 1.08, 0)
	_player.set_meta(&"experiment_invincible", true)
	_player.process_mode = Node.PROCESS_MODE_DISABLED
	_round_slots.append({"entry":_rows[id].entry.duplicate(true), "level":1, "x":0.0, "observe_z":-_attack_observer.distance_input.value, "tuning":values.duplicate(true), "crowd_motion":false})
	state = State.FIGHTING
	_loop_mode = LoopMode.OFF
	_spawn_slot(0, false)
	if _live_enemies.is_empty():
		_show_enemy_tuning(id)
		_tuning_panel.call("_set_notice", "观察对象未能创建；草稿已保留，请核对体型、场地和资源。")
		return
	var subject: CharacterBody3D = _live_enemies[0]
	subject.set_meta(&"attack_inspection_manual", true)
	subject.set_meta(&"experiment_invincible", true)
	subject.ai_enabled = false
	_panel_open = false
	_tuning_open = false
	_panel.visible = false
	_tuning_panel.visible = false
	_interface.visible = false
	_attack_observer.study = true
	_attack_observer.enabled = true
	_attack_observer.watch(subject, skill)
	get_tree().paused = false
	MouseControl.mode = Input.MOUSE_MODE_VISIBLE
	var observation_tree := get_tree()
	await get_tree().process_frame
	if not is_inside_tree() or not is_instance_valid(subject) or not _attack_observer.study: return
	if id == SEDIMENT_TITAN_ID: subject.prepare_sparring_phase("rage" if skill == 4 else "front")
	subject.process_mode = Node.PROCESS_MODE_INHERIT
	# 先让真实碰撞体落到平地，普通跳跃技能需要 is_on_floor()。
	for frame in 8:
		await observation_tree.physics_frame
		if not is_inside_tree() or not is_instance_valid(subject) or not _attack_observer.study: return
	if id.begins_with("Visual"): subject.ai_enabled = true
	_attack_observer.frame_study(not first)
	if play: AttackInspect.trigger(subject, skill)


func edit_observation_shape() -> void:
	if _shape_transition: return
	if _observation_profile != SEDIMENT_TITAN_ID or _attack_observer.skill_choice.selected != 4: return
	if _tuning_panel.enemy_id != _observation_profile: _tuning_panel.open_enemy(_observation_profile)
	if not _tuning_panel._commit_inputs("定格编辑",true):
		_show_enemy_tuning(_observation_profile)
		return
	var values: Dictionary = _tuning_panel._session.values(_tuning_panel.draft_id)
	_shape_transition = true
	await observe_draft(_observation_profile,values,false,false)
	_shape_transition = false
	if not is_inside_tree() or not _attack_observer.study or _live_enemies.is_empty(): return
	var subject: Node3D = _live_enemies[0]
	var direction: Vector3 = _player.global_position-subject.global_position
	subject.rotation.y = atan2(-direction.x,-direction.z)
	get_tree().paused = true
	_attack_observer.shape_panel.bind(_tuning_panel,subject.global_transform.orthonormalized(),subject.scale.x)
	_attack_observer.frame_study(true)


func play_edited_observation(fight := false) -> void:
	if _shape_transition: return
	if not _tuning_panel._commit_inputs("播放／试打",true): return
	var values: Dictionary = _tuning_panel._session.values(_tuning_panel.draft_id)
	_shape_transition = true
	await observe_draft(_observation_profile,values,false,not fight)
	_shape_transition = false
	if not is_inside_tree(): return
	_attack_observer.single_playing = not fight and _attack_observer.study
	if not fight or not _attack_observer.study or _live_enemies.is_empty(): return
	_attack_observer.end_study()
	var subject: Node3D = _live_enemies[0]
	subject.set_meta(&"attack_inspection_manual",false)
	subject.set_meta(&"experiment_invincible",_enemy_invincible.button_pressed)
	subject.ai_enabled = true
	(_player.get("camera") as Camera3D).make_current()
	_player.set_meta(&"experiment_invincible",_invincible.button_pressed)
	_player.set_meta(&"experiment_unlimited_abilities",true)
	_start_fight()
	get_tree().paused = false
	MouseControl.mode = Input.MOUSE_MODE_CAPTURED
	_professional_navigation.set_local(func(): _show_enemy_tuning(_observation_profile),"战斗参数")


func _on_enemy_tuning_saved(_id: String, name: String) -> void:
	_set_result("方案已保存：%s\n当前轮次不变；原型场按当前默认重新生成，正式关卡按其引用读取。" % name)
	_update_selection()


func _on_enemy_tuning_default_changed(_id: String, name: String) -> void:
	_set_result("已明确选用默认方案：%s\n重新生成后生效；当前轮次和补兵保持开场参数。" % name)
	_update_selection()


func _set_result(text: String) -> void:
	_result.text = text
	_result.tooltip_text = text
	_result.visible = not text.is_empty()


func _build_interface() -> void:
	_interface = Overlay.new()
	_interface.name = "LabInterface"
	_interface.layer = 110
	_interface.process_mode = Node.PROCESS_MODE_ALWAYS
	add_child(_interface)
	var root := Control.new()
	root.name = "Root"
	root.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	root.mouse_filter = Control.MOUSE_FILTER_IGNORE
	root.theme = UI.get_theme()
	_interface.add_child(root)
	# 等级读数独立于配置层，关闭战斗面板时仍保留这一项。
	var weapon_layer := CanvasLayer.new()
	weapon_layer.name = "WeaponReadout"
	weapon_layer.layer = 105
	add_child(weapon_layer)
	_weapon_plate = PanelContainer.new()
	_weapon_plate.theme = UI.get_theme()
	_weapon_plate.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_weapon_plate.custom_minimum_size = Vector2(290, 32)
	var weapon_style := StyleBoxFlat.new()
	weapon_style.bg_color = Color(0.035, 0.06, 0.045, 0.72)
	weapon_style.set_content_margin_all(8)
	weapon_style.set_corner_radius_all(5)
	_weapon_plate.add_theme_stylebox_override("panel", weapon_style)
	weapon_layer.add_child(_weapon_plate)
	_weapon_readout = _label("武器 LV 1", 13, UI.COLOR_BODY)
	_weapon_plate.add_child(_weapon_readout)
	_weapon_plate.visible = false
	_title = _label("战斗原型测试台", 14, UI.COLOR_BODY)
	_title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	root.add_child(_title)
	_status = _label("准备配置", 11, UI.COLOR_DIM)
	_status.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	root.add_child(_status)
	_controls = _label("WASD 移动  ·  鼠标射击  ·  右键瞄准  ·  R 换弹\nE 手雷  ·  Q 脉冲  ·  Esc 暂停并释放鼠标  ·  Tab 切换暂停", 11, UI.COLOR_BODY)
	root.add_child(_controls)
	_panel = PanelContainer.new()
	_panel.name = "Configuration"
	_panel.theme = _configuration_theme()
	var style := StyleBoxFlat.new()
	style.bg_color = Color(0.065, 0.105, 0.09, 0.97)
	style.border_color = Color(0.57, 0.54, 0.36, 0.9)
	style.set_border_width_all(1)
	style.set_content_margin_all(6)
	style.corner_radius_top_left = 10
	style.corner_radius_bottom_left = 10
	_panel.add_theme_stylebox_override("panel", style)
	root.add_child(_panel)
	var column := VBoxContainer.new()
	column.add_theme_constant_override("separation", 2)
	_panel.add_child(column)
	var config_header := HBoxContainer.new()
	config_header.name = "ConfigurationHeader"
	column.add_child(config_header)
	config_header.add_child(_label("敌人", 12, UI.COLOR_TITLE))
	_summary = _label("", 11, UI.COLOR_BODY)
	_summary.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_summary.clip_text = true
	config_header.add_child(_summary)
	_action_button(config_header, "统计", "查看本轮战斗统计", _show_statistics)
	_config_help = _label("?", 12, UI.COLOR_DIM)
	_config_help.name = "ConfigurationHelp"
	_config_help.mouse_filter = Control.MOUSE_FILTER_PASS
	_config_help.tooltip_text = "勾选敌人并设置数量；点行内“调参”编辑参数草稿。\n生成后沿对面墙排列，倒数结束开始行动。"
	config_header.add_child(_config_help)
	var options := HBoxContainer.new()
	options.name = "ConfigurationOptions"
	options.add_theme_constant_override("separation", 2)
	column.add_child(options)
	options.add_child(_label("等级", 11, UI.COLOR_BODY))
	_level = SpinBox.new()
	_level.min_value = 1
	_level.max_value = 12
	_level.value = 1
	_level.custom_minimum_size.x = 48
	_level.tooltip_text = "本次战斗的测试等级"
	options.add_child(_level)
	_invincible = CheckBox.new()
	_invincible.text = "无敌"
	_invincible.tooltip_text = "玩家无敌；只影响本台测试"
	_invincible.add_theme_font_size_override("font_size", 11)
	options.add_child(_invincible)
	# 【敌人不死】机制验证的另一种刚需：一打就死就看不到"被打了之后会怎样"
	#（盾卫举盾 / 重型激怒 / 格挡反馈都要在挨打之后才出现）。
	# 打开后伤害照常结算、受击表现照常播，只是不进入死亡。
	_enemy_invincible = CheckBox.new()
	_enemy_invincible.text = "敌不死"
	_enemy_invincible.tooltip_text = "敌人不死：照常受伤与播放受击表现，生命最低保留1，不进入死亡"
	_enemy_invincible.add_theme_font_size_override("font_size", 11)
	options.add_child(_enemy_invincible)
	_crowd_motion = CheckBox.new()
	_crowd_motion.text = "个体差异"
	_crowd_motion.button_pressed = true
	_crowd_motion.add_theme_font_size_override("font_size", 11)
	_crowd_motion.tooltip_text = "原型个体差异与群体运动。作用于四个程序化敌人；关闭可比较整齐基准。手动生成后生效，自动补兵保持本轮开场设置。"
	options.add_child(_crowd_motion)
	var loop_options := HBoxContainer.new()
	loop_options.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	loop_options.add_theme_constant_override("separation", 2)
	options.add_child(loop_options)
	loop_options.add_child(_label("循环", 11, UI.COLOR_BODY))
	_loop_choice = OptionButton.new()
	_loop_choice.name = "LoopMode"
	_loop_choice.add_theme_font_size_override("font_size", 11)
	_loop_choice.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_loop_choice.add_item("单轮", LoopMode.OFF)
	_loop_choice.add_item("全灭重投", LoopMode.WAVE)
	_loop_choice.add_item("同种补位", LoopMode.REPLACE)
	_loop_choice.tooltip_text = "单轮：清完结束；全灭重投：全灭后生成同一批；同种补位：死一只立即补同种。\n循环补兵从原起始线加入战斗，仅首次倒数；玩家状态不重置。暂停后可切换模式，兵种和数量修改需重新生成。"
	_loop_choice.item_selected.connect(_on_loop_mode_selected)
	loop_options.add_child(_loop_choice)
	column.add_child(HSeparator.new())
	var scroll := ScrollContainer.new()
	scroll.name = "EnemyList"
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	column.add_child(scroll)
	var list := VBoxContainer.new()
	list.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	list.add_theme_constant_override("separation", 2)
	scroll.add_child(list)
	# 此处复用已有程序化角色登记，不改变正式关卡的投放配置。
	var entries: Array = Config.get_dictionary("enemy_roster").get("entries", []).duplicate(true)
	entries.push_front(MUD_GOLEM_ENTRY)
	entries.insert(1, SEDIMENT_TITAN_ENTRY)
	entries.insert(2, FAST_BEAST_ENTRY)
	entries.insert(3, HORNET_ENTRY)
	entries.insert(4, {"id": "VisualBurstCrawler", "title": "爆囊爬兽 · 转身投囊", "kind": "ranged"})
	entries.insert(5, {"id": "VisualPrismSpider", "title": "棱眼蛛 · 锁向狙击", "kind": "ranged"})
	entries.insert(6, {"id": "VisualChargeBeetle", "title": "裂甲兜虫 · 锁向冲锋", "kind": "melee"})
	for entry: Dictionary in entries:
		var id := String(entry.id)
		var row := HBoxContainer.new()
		row.custom_minimum_size.y = 22
		list.add_child(row)
		var check := CheckBox.new()
		check.text = String(entry.title)
		check.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		check.add_theme_font_size_override("font_size", 11)
		check.clip_text = true
		check.tooltip_text = String(entry.title)
		check.add_theme_stylebox_override("normal", StyleBoxEmpty.new())
		check.button_pressed = false
		row.add_child(check)
		var tag := _label("远程" if entry.kind == "ranged" else "近战", 10, UI.COLOR_DIM)
		row.add_child(tag)
		if EnemyTuning.PROFILE_PATHS.has(id):
			var tune := Button.new()
			tune.text = "调参"
			tune.custom_minimum_size.x = 40
			tune.add_theme_font_size_override("font_size", 11)
			tune.tooltip_text = "编辑%s的参数草稿" % String(entry.title)
			tune.pressed.connect(_show_enemy_tuning.bind(id))
			row.add_child(tune)
		var count := SpinBox.new()
		count.min_value = 1
		count.max_value = enemy_limit
		count.value = 1
		count.custom_minimum_size.x = 48
		count.add_theme_font_size_override("font_size", 11)
		row.add_child(count)
		_rows[id] = {"entry": entry, "check": check, "count": count}
		check.toggled.connect(_update_selection)
		count.value_changed.connect(_update_selection)
	column.add_child(HSeparator.new())
	_result = _label("", 11, UI.COLOR_TITLE)
	_result.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_result.max_lines_visible = 1
	_result.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	_result.mouse_filter = Control.MOUSE_FILTER_PASS
	_result.visible = false
	column.add_child(_result)
	var actions := HBoxContainer.new()
	actions.name = "ConfigurationActions"
	actions.add_theme_constant_override("separation", 3)
	column.add_child(actions)
	_generate = _action_button(actions, "开战", "按当前敌人和数量生成，倒数后开始新的战斗", generate_round)
	_action_button(actions, "实战陪练", "当前正式兵种编组进入实战陪练。只交接正式图鉴兵种和数量；无敌、不死、空场临时参数不带入。未投产原型仍在本台验证。", open_sparring)
	_resume = _action_button(actions, "继续", "继续当前暂停的战斗，不重新生成", resume_fight)
	_action_button(actions, "清场", "清空当前场地、敌人和待补兵名额", clear_round)
	_action_button(actions, "全不选", "取消全部敌人的勾选", set_selection.bind({}))
	_countdown = _label("3", 104, UI.COLOR_TITLE)
	_countdown.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	root.add_child(_countdown)
	_countdown_hint = _label("", 18, UI.COLOR_BODY)
	_countdown_hint.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	root.add_child(_countdown_hint)
	_build_stats_interface(root, weapon_layer, weapon_style)
	_tuning_panel = TuningPanel.new()
	_tuning_panel.name = "EnemyTuning"
	root.add_child(_tuning_panel)
	_tuning_panel.connect("closed", _on_tuning_closed)
	_tuning_panel.connect("saved", _on_enemy_tuning_saved)
	_tuning_panel.connect("default_changed", _on_enemy_tuning_default_changed)
	_update_selection()


func _build_stats_interface(root: Control, readout_layer: CanvasLayer, readout_style: StyleBoxFlat) -> void:
	_live_stats_plate = PanelContainer.new()
	_live_stats_plate.theme = UI.get_theme()
	_live_stats_plate.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_live_stats_plate.add_theme_stylebox_override("panel", readout_style.duplicate())
	readout_layer.add_child(_live_stats_plate)
	_live_stats_readout = _label("", 13, UI.COLOR_BODY)
	_live_stats_plate.add_child(_live_stats_readout)
	_live_stats_plate.visible = false
	_stats_panel = PanelContainer.new()
	_stats_panel.name = "Statistics"
	_stats_panel.add_theme_stylebox_override("panel", _panel.get_theme_stylebox("panel").duplicate())
	root.add_child(_stats_panel)
	var column := VBoxContainer.new()
	column.add_theme_constant_override("separation", 10)
	_stats_panel.add_child(column)
	var header := HBoxContainer.new()
	column.add_child(header)
	var heading := _label("战斗统计", 24, UI.COLOR_TITLE)
	heading.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	header.add_child(heading)
	_live_stats_toggle = CheckBox.new()
	_live_stats_toggle.text = "战斗中显示简洁统计"
	_live_stats_toggle.add_theme_font_size_override("font_size", 14)
	_live_stats_toggle.toggled.connect(func(_on: bool): _update_live_stats())
	header.add_child(_live_stats_toggle)
	_stats_report = RichTextLabel.new()
	_stats_report.name = "Report"
	_stats_report.bbcode_enabled = true
	_stats_report.selection_enabled = true
	_stats_report.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_stats_report.add_theme_font_size_override("normal_font_size", 14)
	_stats_report.add_theme_font_size_override("bold_font_size", 14)
	_stats_report.add_theme_constant_override("table_h_separation", 16)
	_stats_report.add_theme_constant_override("table_v_separation", 12)
	_stats_report.add_theme_color_override("default_color", UI.COLOR_BODY)
	column.add_child(_stats_report)
	var footer := HBoxContainer.new()
	column.add_child(footer)
	_stats_resume = Button.new()
	_stats_resume.text = "继续战斗"
	_stats_resume.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_stats_resume.custom_minimum_size.y = 40
	_stats_resume.pressed.connect(resume_fight)
	footer.add_child(_stats_resume)
	var configure := Button.new()
	configure.text = "返回敌人配置"
	configure.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	configure.pressed.connect(_show_configuration)
	footer.add_child(configure)
	_stats_panel.visible = false


func _label(text: String, size: int, color: Color) -> Label:
	var label := Label.new()
	label.text = text
	label.add_theme_font_size_override("font_size", size)
	label.add_theme_color_override("font_color", color)
	label.add_theme_color_override("font_outline_color", Color(0.02, 0.035, 0.025, 0.9))
	label.add_theme_constant_override("outline_size", 3)
	label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	return label


func _action_button(parent: Control, caption: String, help_text: String, action: Callable) -> Button:
	var control := Button.new()
	control.text = caption
	control.tooltip_text = help_text
	control.custom_minimum_size.y = 20
	control.size_flags_horizontal = Control.SIZE_SHRINK_BEGIN
	control.pressed.connect(action)
	parent.add_child(control)
	return control


func _configuration_theme() -> Theme:
	# 调试配置不能沿用游戏菜单的大字号和按钮留白，否则列表会被压到零高度。
	var compact := ParameterInput.compact_theme(UI.get_theme(), 11)
	for state_name in ["normal", "hover", "pressed", "disabled", "focus"]:
		if not compact.has_stylebox(state_name, "Button"): continue
		var button_style := compact.get_stylebox(state_name, "Button").duplicate() as StyleBox
		button_style.set_content_margin(SIDE_LEFT, 4)
		button_style.set_content_margin(SIDE_RIGHT, 4)
		button_style.set_content_margin(SIDE_TOP, 2)
		button_style.set_content_margin(SIDE_BOTTOM, 2)
		compact.set_stylebox(state_name, "Button", button_style)
	# 浮动说明使用实色底，避免叠到密集控件上仍透出文字。
	var tooltip_style := StyleBoxFlat.new()
	tooltip_style.bg_color = Color(0.025, 0.035, 0.03, 1.0)
	tooltip_style.set_content_margin_all(6)
	compact.set_stylebox("panel", "TooltipPanel", tooltip_style)
	compact.set_font_size("font_size", "TooltipLabel", 11)
	compact.set_color("font_color", "TooltipLabel", UI.COLOR_BODY)
	return compact


func _layout_interface() -> void:
	var size := get_viewport().get_visible_rect().size
	_weapon_plate.position = Vector2(24, 18)
	var width := minf(480.0, size.x - 24.0)
	var panel_top := 44.0
	_panel.position = Vector2(size.x - width - 12, panel_top)
	var enemy_list := _panel.find_child("EnemyList", true, false) as ScrollContainer
	if enemy_list != null:
		enemy_list.custom_minimum_size.y = minf(220.0, size.y * 0.26)
	_panel.size = Vector2(width, size.y - panel_top - 12)
	var stats_width := minf(1040.0, size.x - 48.0)
	_stats_panel.position = Vector2((size.x - stats_width) * 0.5, 88)
	_stats_panel.size = Vector2(stats_width, maxf(size.y - 112, 380))
	_title.position = Vector2(size.x * 0.5 - 180, 6)
	_title.size = Vector2(360, 20)
	_status.position = Vector2(size.x * 0.5 - 240, 25)
	_status.size = Vector2(480, 16)
	_title.visible = _panel_open
	_status.visible = _panel_open
	_controls.visible = _panel_open and not _stats_open and not _tuning_open
	_controls.position = Vector2(24, size.y - 54)
	_controls.size = Vector2(600, 44)
	_countdown.position = size * 0.5 - Vector2(140, 104)
	_countdown.size = Vector2(280, 150)
	_countdown_hint.position = size * 0.5 + Vector2(-250, 64)
	_countdown_hint.size = Vector2(500, 64)
	if is_instance_valid(_tuning_panel):
		_tuning_panel.call("layout_panel")
