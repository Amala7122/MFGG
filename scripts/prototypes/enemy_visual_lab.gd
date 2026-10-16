extends Node3D
## 可切换的纯视觉角色观察台。新增角色只需在 GALLERY 登记场景和机位。

const VisualPanel = preload("res://scripts/prototypes/visual_model_panel.gd")
const Tuning := preload("res://scripts/prototypes/enemy_tuning.gd")
const Timeline := preload("res://scripts/prototypes/motion_timeline.gd")
const ParamParts := preload("res://scripts/prototypes/visual_param_parts.gd")
## observe 是每个条目**必须显式声明**的观察能力，守卫 test_enemy_observation_coverage 会核对
## 声明与实现是否一致：
##   "scrub" —— 有可定位的时间轴（set_preview_pose + sample_pose）：慢放、逐帧、叠影、排开可用；
##   "play"  —— 没有时间驱动姿态（战斗体 / 相位机角色）：只能冻结与全局慢放。
## 新敌人（新外形或新兵种）必须在下面登记一条，见 AGENTS.md「敌人观察台」。
## 2026-10-10 用户要求：把机器人样的正式兵种（大型盾卫）撤出观察台，以后再说。
## 泥土傀儡 / 沉积泰坦 属于原型怪物，保留（用户明确「这两个不撤」）。
const GALLERY := [
	{"title": "裂釉镇墓兽 · 外形原型", "scene": preload("res://prototypes/visual_lab/tomb_guardian_visual.tscn"), "look_y": 3.5, "distance": 14.0, "yaw": 0.55, "height": 0.0, "profile": "", "observe": "scrub"},
	{"title": "泥土傀儡", "scene": preload("res://prototypes/enemy_prototypes/procedural_mud_golem.tscn"), "look_y": 1.05, "height": 0.65, "profile": "PrototypeMudGolem", "observe": "play"},
	{"title": "沉积泰坦", "scene": preload("res://prototypes/enemy_prototypes/procedural_sediment_titan.tscn"), "look_y": 1.85, "height": 1.7, "profile": "PrototypeSedimentTitan", "observe": "play"},
	{"title": "迅捷晶兽", "scene": preload("res://prototypes/enemy_prototypes/procedural_fast_beast.tscn"), "look_y": 1.0, "height": 0.775, "profile": "PrototypeFastBeast", "observe": "play"},
	{"title": "晶刺蜂", "scene": preload("res://prototypes/enemy_prototypes/procedural_hornet.tscn"), "look_y": 2.0, "height": 2.6, "profile": "PrototypeHornet", "observe": "play"},
	{"title": "爆囊爬兽 · 外形原型", "scene": preload("res://prototypes/visual_lab/burst_crawler_visual.tscn"), "look_y": 0.95, "distance": 6.5, "yaw": 0.55, "height": 0.0, "profile": "VisualBurstCrawler", "observe": "scrub"},
	{"title": "棱眼蛛 · 外形原型", "scene": preload("res://prototypes/visual_lab/prism_spider_visual.tscn"), "look_y": 0.8, "distance": 8.0, "yaw": 0.42, "height": 0.0, "profile": "VisualPrismSpider", "observe": "scrub"},
	{"title": "裂甲兜虫 · 外形原型", "scene": preload("res://prototypes/visual_lab/charge_beetle_visual.tscn"), "look_y": 0.95, "distance": 10.0, "yaw": 0.60, "height": 0.0, "profile": "VisualChargeBeetle", "observe": "scrub"},
]
@export_range(0.001, 0.02, 0.001) var orbit_sensitivity := 0.006

@onready var _subject_mount: Node3D = $SubjectMount
@onready var _camera_rig: Node3D = $CameraRig
@onready var _camera_pitch: Node3D = $CameraRig/Pitch
@onready var _camera: Camera3D = $CameraRig/Pitch/Camera3D
@onready var _status_label: Label = $Interface/SafeArea/Panel/Padding/Status

var _visual_panel: PanelContainer
var _gallery_picker: OptionButton
var _subject: Node3D
var _gallery_index := 0
var _dragging := false
var _auto_rotate := false
var _motion_enabled := true
var _silhouette := false
var _distance_index := 1
var _distances := [6.0, 12.0, 24.0]
var _original_materials: Dictionary = {}
var _silhouette_material: StandardMaterial3D
var _isolation_frames_remaining := 3
var _game_flow: CanvasLayer
var _game_flow_mode := Node.PROCESS_MODE_INHERIT
var _game_flow_visible := true

# —— 观察工具：慢放、逐帧、运动分解（叠影 / 排开） ——
const SPEEDS: Array[float] = [0.05, 0.1, 0.25, 0.5, 1.0]
const DECOMPOSE_FRAME_STEPS: Array[int] = [2, 4, 8, 12]
const DECOMPOSE_SLOTS: Array[int] = [-2, -1, 1, 2]
const DECOMPOSE_NAMES: Array[String] = ["关", "叠影", "排开"]

var _timeline: Control
var _speed_index := 4
var _motion_decompose := 0
var _decompose_step_index := 1
var _ghost_mount: Node3D
var _ghosts: Array[Node3D] = []
var _ghost_past: StandardMaterial3D
var _ghost_future: StandardMaterial3D
var _ghosts_dirty := false

# —— 参数 → 部位高亮 ——
const HIGHLIGHT_MS := 3000
var _highlight_material: StandardMaterial3D
var _highlight_restore: Dictionary = {}
var _highlight_meshes: Array[MeshInstance3D] = []
var _highlight_until := 0
var _param_hint := ""

# —— 点击拾取：点中哪个几何体，就报出它的名字与影响它的参数 ——
var _select_material: StandardMaterial3D
var _selected_mesh: MeshInstance3D
var _selected_restore: Material
var _selection_hint := ""
var _press_position := Vector2.ZERO
var _press_valid := false


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	_game_flow = get_node_or_null("/root/GameFlow") as CanvasLayer
	if _game_flow != null:
		_game_flow_mode = _game_flow.process_mode
		_game_flow_visible = _game_flow.visible
	_enforce_lab_isolation()
	_build_silhouette_material()
	_build_visual_controls()
	var initial := 0
	for argument in OS.get_cmdline_user_args():
		if argument.begins_with("--visual-profile="):
			for i in GALLERY.size():
				if GALLERY[i].profile == argument.trim_prefix("--visual-profile="):
					initial = i
	_show_subject(initial)


func _exit_tree() -> void:
	if is_instance_valid(_game_flow):
		_game_flow.process_mode = _game_flow_mode
		_game_flow.visible = _game_flow_visible
	get_tree().paused = false
	Engine.time_scale = 1.0
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE


func _process(delta: float) -> void:
	if _isolation_frames_remaining > 0:
		_enforce_lab_isolation()
		_isolation_frames_remaining -= 1
	# GameFlow 会延迟向当前场景添加 MainMenuCamera；始终保持观察台相机为当前相机。
	if get_viewport().get_camera_3d() != _camera:
		_camera.make_current()
	if _auto_rotate and is_instance_valid(_subject):
		_subject.rotate_y(delta * 0.42)
	if _motion_decompose != 0 and _ghosts_dirty:
		_rebuild_ghosts()
	if not _ghosts.is_empty():
		_update_ghost_poses()
	if is_instance_valid(_timeline) and _timeline.visible and _supports_skill_timeline():
		var time := float(_subject.get("preview_time"))
		var loop := not _subject.has_method("is_preview_looping") or bool(_subject.call("is_preview_looping"))
		_timeline.set_cursor(fposmod(time, _cycle_duration()) if loop else minf(time, _cycle_duration()))
	if _highlight_until > 0 and Time.get_ticks_msec() >= _highlight_until:
		_clear_highlight()


func _enforce_lab_isolation() -> void:
	get_tree().paused = false
	if is_instance_valid(_game_flow):
		_game_flow.process_mode = Node.PROCESS_MODE_DISABLED
		_game_flow.visible = false
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE


func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventMouseButton:
		var mouse_event := event as InputEventMouseButton
		if mouse_event.button_index == MOUSE_BUTTON_LEFT:
			_dragging = mouse_event.pressed
			# 单击（不是拖拽）用来拾取几何体；拖拽仍然是环绕。
			if mouse_event.pressed:
				_press_position = mouse_event.position
				_press_valid = true
			else:
				if _press_valid and mouse_event.position.distance_to(_press_position) < 4.0:
					_pick_at(mouse_event.position)
				_press_valid = false
		elif mouse_event.pressed and mouse_event.button_index == MOUSE_BUTTON_WHEEL_UP:
			_set_distance(_camera.position.z - 0.8)
		elif mouse_event.pressed and mouse_event.button_index == MOUSE_BUTTON_WHEEL_DOWN:
			_set_distance(_camera.position.z + 0.8)
	elif event is InputEventMouseMotion and _dragging:
		var motion := event as InputEventMouseMotion
		_camera_rig.rotation.y -= motion.relative.x * orbit_sensitivity
		_camera_pitch.rotation.x = clampf(
			_camera_pitch.rotation.x - motion.relative.y * orbit_sensitivity, -0.55, 0.35
		)
	elif event is InputEventKey and event.pressed and not event.echo:
		match event.physical_keycode:
			KEY_LEFT, KEY_A:
				_show_subject(_gallery_index - 1)
			KEY_RIGHT, KEY_D:
				_show_subject(_gallery_index + 1)
			KEY_M:
				_motion_enabled = not _motion_enabled
				_apply_motion_state()
				_update_status()
			KEY_P:
				_visual_panel.stop_demo()
				if is_instance_valid(_subject) and _subject.has_method("set_preview_pose"):
					_subject.call("set_preview_pose", int(_subject.get("preview_pose")) + 1)
					_ghosts_dirty = true
					_update_status()
			KEY_R:
				_replay_visual()
			KEY_K:
				_play_subject_death()
			KEY_TAB:
				_visual_panel.visible = not _visual_panel.visible and String(GALLERY[_gallery_index].profile).begins_with("Visual")
			KEY_B:
				_toggle_silhouette()
			KEY_SPACE:
				_auto_rotate = not _auto_rotate
				_update_status()
			KEY_1:
				_apply_distance_preset(0)
			KEY_2:
				_apply_distance_preset(1)
			KEY_3:
				_apply_distance_preset(2)
			KEY_F:
				_reset_view()
			KEY_BRACKETLEFT:
				_cycle_speed(-1)
			KEY_BRACKETRIGHT:
				_cycle_speed(1)
			KEY_COMMA:
				_step_frames(-10 if event.shift_pressed else -1)
			KEY_PERIOD:
				_step_frames(10 if event.shift_pressed else 1)
			KEY_V:
				_cycle_decompose()
			KEY_N:
				_cycle_decompose_frames()
			KEY_ESCAPE:
				_dragging = false
				Input.mouse_mode = Input.MOUSE_MODE_VISIBLE


func _show_subject(index: int) -> void:
	for effect in get_tree().get_nodes_in_group("enemy_death_effect"):
		if effect != _subject and is_ancestor_of(effect):
			effect.queue_free()
	_gallery_index = posmod(index, GALLERY.size())
	_original_materials.clear()
	if is_instance_valid(_subject):
		_subject.queue_free()
		_subject = null
	var entry: Dictionary = GALLERY[_gallery_index]
	var scene: PackedScene = entry["scene"]
	_subject = scene.instantiate() as Node3D
	if _subject == null:
		push_error("敌人视觉实验场的角色场景根节点必须是 Node3D")
		return
	var profile := String(entry["profile"])
	if not profile.is_empty():
		_subject.set_meta(&"enemy_tuning", Tuning.get_values(profile))
		_subject.set_meta(&"crowd_uniform", true)
		_subject.set("ai_enabled", false)
	_subject.position.y = float(entry["height"])
	_subject_mount.add_child(_subject)
	_subject.rotation.y = PI
	if _subject is CharacterBody3D:
		var body := _subject as CharacterBody3D
		body.collision_layer = 0
		body.collision_mask = 1
		# 泰坦的战斗场景会先播放出土；观察台直接展示完整站姿。
		if profile == "PrototypeSedimentTitan":
			var spawn_tween := body.get("_action_tween") as Tween
			if spawn_tween != null and spawn_tween.is_valid():
				spawn_tween.kill()
			(body.get("visual_root") as Node3D).position.y = -1.6
			body.set("current_state", 1)
	for node in _subject.find_children("*", "Label3D", true, false):
		(node as Label3D).visible = false
	_camera_rig.position.y = float(entry["look_y"])
	_capture_original_materials()
	if _silhouette:
		_apply_silhouette(true)
	_apply_motion_state()
	_reset_view()
	_gallery_picker.select(_gallery_index)
	_visual_panel.bind_profile(profile if profile.begins_with("Visual") else "")
	if profile.begins_with("Visual"):
		_visual_panel.bind_subject(_subject)
	if profile.begins_with("Visual"):
		_apply_visual_values(_visual_panel.values)
	_clear_ghosts()
	_clear_highlight()
	_clear_selection()
	_param_hint = ""
	_apply_preview_speed()
	_ghosts_dirty = true
	_update_status()


func _apply_motion_state() -> void:
	if is_instance_valid(_subject):
		_subject.process_mode = Node.PROCESS_MODE_INHERIT if _motion_enabled else Node.PROCESS_MODE_DISABLED


func _capture_original_materials() -> void:
	_original_materials.clear()
	if not is_instance_valid(_subject):
		return
	for node in _subject.find_children("*", "MeshInstance3D", true, false):
		var mesh_instance := node as MeshInstance3D
		_original_materials[mesh_instance] = mesh_instance.material_override
	if _subject is MeshInstance3D:
		var root_mesh := _subject as MeshInstance3D
		_original_materials[root_mesh] = root_mesh.material_override


func _build_silhouette_material() -> void:
	_silhouette_material = StandardMaterial3D.new()
	_silhouette_material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	_silhouette_material.albedo_color = Color(0.008, 0.008, 0.008, 1.0)
	_highlight_material = StandardMaterial3D.new()
	_highlight_material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	_highlight_material.albedo_color = Color(1.0, 0.78, 0.25, 1.0)
	_select_material = StandardMaterial3D.new()
	_select_material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	_select_material.albedo_color = Color(0.15, 1.0, 0.85, 1.0)


func _toggle_silhouette() -> void:
	_clear_highlight()
	_silhouette = not _silhouette
	_apply_silhouette(_silhouette)
	_update_status()


func _apply_silhouette(enabled: bool) -> void:
	for key in _original_materials:
		var mesh_instance := key as MeshInstance3D
		if is_instance_valid(mesh_instance):
			mesh_instance.material_override = (
				_silhouette_material if enabled else _original_materials[key] as Material
			)


func _apply_distance_preset(index: int) -> void:
	_distance_index = clampi(index, 0, _distances.size() - 1)
	_set_distance(float(_distances[_distance_index]))


func _set_distance(value: float) -> void:
	_camera.position.z = clampf(value, 4.5, 30.0)
	_update_status()


func _reset_view() -> void:
	_camera_rig.rotation = Vector3.ZERO
	_camera_pitch.rotation.x = -0.12
	_distance_index = 1
	var entry: Dictionary = GALLERY[_gallery_index]
	_set_distance(float(entry.get("distance", _distances[1])))
	_camera_rig.rotation.y = float(entry.get("yaw", 0.0))
	if is_instance_valid(_subject):
		_subject.rotation = Vector3(0.0, PI, 0.0)


func _update_status() -> void:
	if _status_label == null:
		return
	var entry: Dictionary = GALLERY[_gallery_index]
	if is_instance_valid(_visual_panel) and is_instance_valid(_subject) and _subject.has_method("apply_visual_values"):
		_visual_panel.poses.select(int(_subject.get("preview_pose")))
	var pose_text := ""
	if is_instance_valid(_subject) and _subject.has_method("get_preview_pose_name"):
		pose_text = "  |  姿态：" + String(_subject.call("get_preview_pose_name"))
	_status_label.text = (
		"敌人视觉实验场 %d/%d · %s | %s | %s%s\n"
		+ "←/→ 换角色　M 静/动　P 姿态　B 剪影　空格 旋转　F 复位　Esc 释放鼠标　K 死亡重播\n"
		+ "左键单击=拾取　拖拽=环绕　滚轮或 1/2/3 缩放　距离 %.1f m　网格 %d　三角面 %d\n"
		+ "%s"
	) % [
		_gallery_index + 1, GALLERY.size(), String(entry["title"]),
		"剪影" if _silhouette else "材质", "动态" if _motion_enabled else "静态",
		pose_text, _camera.position.z, _original_materials.size(), _count_triangles(),
		_status_detail(),
	]
	_refresh_timeline()


func _count_triangles() -> int:
	var total := 0
	for key in _original_materials:
		var mesh_instance := key as MeshInstance3D
		if not is_instance_valid(mesh_instance) or mesh_instance.mesh == null:
			continue
		for surface_index in range(mesh_instance.mesh.get_surface_count()):
			var arrays := mesh_instance.mesh.surface_get_arrays(surface_index)
			var index_data: Variant = arrays[Mesh.ARRAY_INDEX]
			if index_data is PackedInt32Array and not (index_data as PackedInt32Array).is_empty():
				total += (index_data as PackedInt32Array).size() / 3
				continue
			var vertex_data: Variant = arrays[Mesh.ARRAY_VERTEX]
			if vertex_data is PackedVector3Array:
				total += (vertex_data as PackedVector3Array).size() / 3
	return total


## 实验室是调试工具：逻辑画布只有 1152×648，会被 canvas_items 拉伸到 1080p（×1.667）。
## 不显式压小字号的话，默认 16 号字在屏幕上是约 27px，状态行和参数面板会互相挤掉。
func _build_small_theme() -> Theme:
	var theme := Theme.new()
	theme.default_font_size = 11
	for type_name in ["Label", "OptionButton", "SpinBox", "LineEdit", "CheckBox"]:
		theme.set_font_size("font_size", String(type_name), 11)
	theme.set_font_size("font_size", "Button", 12)
	return theme


func _build_visual_controls() -> void:
	var small := _build_small_theme()
	($Interface/SafeArea as Control).theme = small
	_gallery_picker = OptionButton.new()
	_gallery_picker.set_anchors_and_offsets_preset(Control.PRESET_TOP_RIGHT)
	_gallery_picker.position = Vector2(-280, 128)
	_gallery_picker.size = Vector2(264, 26)
	_gallery_picker.theme = small
	_gallery_picker.focus_mode = Control.FOCUS_NONE
	for entry in GALLERY:
		_gallery_picker.add_item(String(entry.title))
	_gallery_picker.item_selected.connect(_show_subject)
	$Interface.add_child(_gallery_picker)
	_visual_panel = VisualPanel.new()
	$Interface.add_child(_visual_panel)
	_visual_panel.set_anchors_and_offsets_preset(Control.PRESET_RIGHT_WIDE)
	_visual_panel.offset_left = -280
	_visual_panel.offset_right = -16
	_visual_panel.offset_top = 164
	_visual_panel.offset_bottom = -16
	_visual_panel.theme = small
	_visual_panel.values_changed.connect(_apply_visual_values)
	_visual_panel.field_focused.connect(_highlight_field)
	_visual_panel.pose_selected.connect(func(index: int):
		_visual_panel.stop_demo()
		_subject.call("set_preview_pose", index)
		_ghosts_dirty = true
		_update_status())
	_visual_panel.replay_requested.connect(_replay_visual)
	_visual_panel.seek_requested.connect(_seek_visual)
	_visual_panel.tooltip_text = "Tab 显示/隐藏参数面板；R 重播；M 冻结"
	_timeline = Timeline.new()
	$Interface.add_child(_timeline)
	_timeline.set_anchors_and_offsets_preset(Control.PRESET_BOTTOM_WIDE)
	_timeline.offset_left = 20
	_timeline.offset_right = -296
	_timeline.offset_top = -140
	_timeline.offset_bottom = -16
	_timeline.theme = small
	_timeline.seek_requested.connect(_seek_visual)
	_timeline.visible = false


func _apply_visual_values(values: Dictionary) -> void:
	if not is_instance_valid(_subject) or not _subject.has_method("apply_visual_values"):
		return
	_clear_highlight()
	_clear_selection()
	_subject.call("apply_visual_values", values)
	_ghosts_dirty = true
	_capture_original_materials()
	if _silhouette:
		_apply_silhouette(true)
	_update_status()


func _replay_visual() -> void:
	if not is_instance_valid(_subject) or not _subject.has_method("sample_pose"):
		return
	_subject.call("set_preview_pose", int(_subject.get("preview_pose")))
	_motion_enabled = true
	_apply_motion_state()
	_update_status()

func _play_subject_death() -> void:
	_visual_panel.stop_demo()
	_motion_enabled = true
	_show_subject(_gallery_index)
	if _subject.has_method("play_death"):
		_subject.call("play_death")
	else:
		for method in ["trigger_death_fall", "trigger_death_scatter", "trigger_death_shatter"]:
			if _subject.has_method(method):
				_subject.call(method)
				break
	_update_status()


func _seek_visual(fraction: float) -> void:
	if not _supports_pose_scrub():
		return
	var duration := _cycle_duration()
	if _supports_skill_timeline() and not _subject.has_method("get_preview_duration"):
		var values: Dictionary = _subject.get("values")
		if int(_subject.get("preview_pose")) < 2:
			duration = 1.0 / float(values.gait_rate)
		else:
			duration = float(values.windup) + float(values.release) + float(values.recovery)
	var time := fraction * duration
	_subject.set("preview_time", time)
	_subject.call("sample_pose", time)
	_motion_enabled = false
	_apply_motion_state()
	_update_status()


## —— 观察工具实现：慢放、逐帧、运动分解、时间轴 ——


## 能按时刻取姿态：慢放走角色自身倍速，逐帧与运动分解靠它。
func _supports_pose_scrub() -> bool:
	return is_instance_valid(_subject) and _subject.has_method("sample_pose") and _subject.has_method("set_preview_pose")


## 有"蓄力→释放"技能循环：才有阶段色带与阶段名。
func _supports_skill_timeline() -> bool:
	return _supports_pose_scrub() and _subject.has_method("charge_at") and _subject.has_method("release_at")


## 慢放：角色自己能调速就用角色倍速；不能（战斗体、相位机角色）退到全局时间缩放。
func _apply_preview_speed() -> void:
	var speed := SPEEDS[_speed_index]
	if _supports_pose_scrub():
		_subject.set("preview_speed", speed)
		Engine.time_scale = 1.0
	else:
		Engine.time_scale = speed


func _cycle_duration() -> float:
	if is_instance_valid(_subject) and _subject.has_method("get_preview_duration"):
		return float(_subject.call("get_preview_duration"))
	if not _supports_skill_timeline():
		return 4.0
	var values: Dictionary = _subject.get("values")
	match int(_subject.get("preview_pose")):
		0:
			return 1.0 / maxf(0.01, float(values.get("breath_rate", 1.0)))
		1:
			return 1.0 / maxf(0.01, float(values.get("gait_rate", 1.0)))
	return maxf(0.0001, float(values.get("windup", 1.0)) + float(values.get("release", 0.35)) + float(values.get("recovery", 1.2)))


func _phase_name(time: float) -> String:
	if is_instance_valid(_subject) and _subject.has_method("get_preview_bands"):
		var bands: Array = _subject.call("get_preview_bands")
		for band: Dictionary in bands:
			if time <= float(band.to):
				return String(band.label)
	if not _supports_skill_timeline():
		return "—"
	var values: Dictionary = _subject.get("values")
	var windup := float(values.get("windup", 1.0))
	var release := float(values.get("release", 0.35))
	var recovery := float(values.get("recovery", 1.2))
	var cycle := maxf(windup + release + recovery, 0.0001)
	if bool(_subject.get("skill_reversed")):
		var strike_start := cycle - windup - release * float(values.get("release_snap_ratio", 0.18))
		var strike_end := cycle - windup
		var hold_end := strike_end + windup * (1.0 - float(values.get("windup_rise_ratio", 0.62)))
		if time < strike_start:
			return "转身预备"
		if time < strike_end:
			return "弹甲投囊"
		if time < hold_end:
			return "定势"
		return "收回甲壳"
	var rise := windup * float(values.get("windup_rise_ratio", 0.62))
	var snap := release * float(values.get("release_snap_ratio", 0.18))
	if time < rise:
		return "蓄力上升"
	if time < windup:
		return "定势保持"
	if time < windup + snap:
		return "爆发"
	return "收势回落"


func _cycle_speed(direction: int) -> void:
	_speed_index = clampi(_speed_index + direction, 0, SPEEDS.size() - 1)
	_apply_preview_speed()
	_update_status()


## 逐帧步进会自动冻结，避免"跳了一帧又被动画带走"。
func _step_frames(count: int) -> void:
	if not _supports_pose_scrub():
		return
	# 不按周期取模：角色自己的曲线都按绝对时间算，取模反而会让播放很久后再逐帧跳一大截。
	var time := float(_subject.get("preview_time")) + float(count) / 60.0
	_subject.set("preview_time", time)
	_subject.call("sample_pose", time)
	_motion_enabled = false
	_apply_motion_state()
	_ghosts_dirty = true
	_update_status()


func _cycle_decompose() -> void:
	_motion_decompose = (_motion_decompose + 1) % 3
	_ghosts_dirty = true
	if _motion_decompose == 0:
		_clear_ghosts()
	_update_status()


func _cycle_decompose_frames() -> void:
	_decompose_step_index = (_decompose_step_index + 1) % DECOMPOSE_FRAME_STEPS.size()
	if _motion_decompose != 0:
		_update_ghost_poses()
	_update_status()


func _clear_ghosts() -> void:
	for ghost in _ghosts:
		if is_instance_valid(ghost):
			ghost.queue_free()
	_ghosts.clear()


func _ensure_ghost_mount() -> void:
	if is_instance_valid(_ghost_mount):
		return
	_ghost_mount = Node3D.new()
	_ghost_mount.name = "MotionDecompose"
	add_child(_ghost_mount)


## 残影必须挂在独立挂点上：测试和截图脚本都按 SubjectMount 的子节点顺序取主体。
func _rebuild_ghosts() -> void:
	_ghosts_dirty = false
	_clear_ghosts()
	if _motion_decompose == 0 or not _supports_pose_scrub():
		return
	var entry: Dictionary = GALLERY[_gallery_index]
	var scene: PackedScene = entry["scene"]
	# 只有三种新外形带可调参字典 values；镇墓兽这类角色直接用自己的场景默认值。
	var raw_values: Variant = _subject.get("values")
	var values: Dictionary = raw_values.duplicate(true) if raw_values is Dictionary else {}
	_ensure_ghost_mount()
	if not is_instance_valid(_ghost_mount):
		return
	_ghost_mount.transform = _subject_mount.transform
	for slot in DECOMPOSE_SLOTS:
		var ghost := scene.instantiate() as Node3D
		if ghost == null:
			continue
		if not values.is_empty():
			ghost.set_meta(&"enemy_tuning", values)
		_ghost_mount.add_child(ghost)
		ghost.set("preview_pose", int(_subject.get("preview_pose")))
		ghost.process_mode = Node.PROCESS_MODE_DISABLED
		var material := _ghost_material(slot < 0)
		for node in ghost.find_children("*", "MeshInstance3D", true, false):
			var part := node as MeshInstance3D
			part.material_override = material
			part.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		_ghosts.append(ghost)
	_update_ghost_poses()


func _update_ghost_poses() -> void:
	if _ghosts.is_empty() or not _supports_pose_scrub():
		return
	var base := float(_subject.get("preview_time"))
	var step := float(DECOMPOSE_FRAME_STEPS[_decompose_step_index]) / 60.0
	var spacing := _decompose_spacing()
	for i in _ghosts.size():
		var slot := DECOMPOSE_SLOTS[i]
		var ghost := _ghosts[i]
		var offset := float(slot) * spacing if _motion_decompose == 2 else 0.0
		ghost.rotation = _subject.rotation
		ghost.position = _subject.position + Vector3(offset, 0.0, 0.0)
		var time := base + float(slot) * step
		ghost.set("preview_time", time)
		ghost.call("sample_pose", time)


func _decompose_spacing() -> float:
	# 三种新外形读可调参字典 values.body_size；镇墓兽这类角色读自己的 body_size。
	var raw: Variant = _subject.get("values")
	var size := 1.0
	if raw is Dictionary:
		size = float((raw as Dictionary).get("body_size", 1.0))
	elif _subject.get("body_size") != null:
		size = float(_subject.get("body_size"))
	return 3.0 * maxf(1.0, size)


func _ghost_material(past: bool) -> StandardMaterial3D:
	if past and _ghost_past != null:
		return _ghost_past
	if not past and _ghost_future != null:
		return _ghost_future
	var material := StandardMaterial3D.new()
	material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	material.albedo_color = Color(0.35, 0.62, 1.0, 0.16) if past else Color(1.0, 0.62, 0.28, 0.16)
	if past:
		_ghost_past = material
	else:
		_ghost_future = material
	return material


func _refresh_timeline() -> void:
	if not is_instance_valid(_timeline):
		return
	_timeline.heading = "技能循环"
	_timeline.legend = "黄：蓄力量　蓝：释放量"
	if _supports_pose_scrub() and _subject.has_method("get_preview_bands"):
		var custom: Array = _subject.call("get_preview_bands")
		if not custom.is_empty():
			var cycle := _cycle_duration()
			var death := int(_subject.get("preview_pose")) == int(_subject.call("death_pose_index"))
			_timeline.heading = String(_subject.call("get_preview_pose_name"))
			if death:
				_timeline.legend = "黄：动作进度　蓝：抖腿衰减"
			var charge := PackedFloat32Array()
			var release := PackedFloat32Array()
			for i in 241:
				var t := cycle * i / 240.0
				if death:
					var values: Dictionary = _subject.get("values")
					var end := float(values.death_prepare) + float(values.death_action) + float(values.death_twitch_time)
					charge.append(t / cycle)
					release.append(1.0 - smoothstep(float(values.death_prepare), end, t))
				else:
					charge.append(float(_subject.call("charge_at", t)))
					release.append(float(_subject.call("release_at", t)))
			_timeline.visible = true
			_timeline.set_state(custom, cycle, charge, release)
			return
	if not _supports_skill_timeline() or int(_subject.get("preview_pose")) != 2:
		_timeline.visible = false
		return
	var values: Dictionary = _subject.get("values")
	var windup := float(values.get("windup", 1.0))
	var release := float(values.get("release", 0.35))
	var recovery := float(values.get("recovery", 1.2))
	var cycle := maxf(windup + release + recovery, 0.0001)
	var rise := windup * float(values.get("windup_rise_ratio", 0.62))
	var snap := release * float(values.get("release_snap_ratio", 0.18))
	var bands: Array = []
	if bool(_subject.get("skill_reversed")):
		# 倒放顺序：先转身预备，再弹甲投囊，然后定势，最后收甲转回。
		var strike_start := recovery + release - snap
		var strike_end := recovery + release
		var hold_end := strike_end + (windup - rise)
		bands = [
			{"from": 0.0, "to": strike_start, "label": "转身预备", "color": Color(0.38, 0.30, 0.52, 0.85)},
			{"from": strike_start, "to": strike_end, "label": "弹甲投囊", "color": Color(0.86, 0.28, 0.16, 0.95), "decisive": true},
			{"from": strike_end, "to": hold_end, "label": "定势", "color": Color(0.24, 0.52, 0.34, 0.85)},
			{"from": hold_end, "to": cycle, "label": "收回甲壳", "color": Color(0.20, 0.42, 0.72, 0.85)},
		]
	else:
		bands = [
			{"from": 0.0, "to": rise, "label": "蓄力", "color": Color(0.20, 0.42, 0.72, 0.85)},
			{"from": rise, "to": windup, "label": "定势", "color": Color(0.24, 0.52, 0.34, 0.85)},
			{"from": windup, "to": windup + snap, "label": "爆发", "color": Color(0.86, 0.28, 0.16, 0.95), "decisive": true},
			{"from": windup + snap, "to": cycle, "label": "收势", "color": Color(0.38, 0.30, 0.52, 0.85)},
		]
	var samples := 240
	var charge := PackedFloat32Array()
	var release_curve := PackedFloat32Array()
	for i in samples + 1:
		var t := cycle * float(i) / float(samples)
		charge.append(float(_subject.call("charge_at", t)))
		release_curve.append(float(_subject.call("release_at", t)))
	_timeline.visible = true
	_timeline.set_state(bands, cycle, charge, release_curve)


func _motion_readout() -> String:
	if not _supports_pose_scrub():
		return "倍速 ×%.2f（[ ] 全局慢放）　逐帧 / 运动分解：该角色没有可定位的时间轴" % SPEEDS[_speed_index]
	var text := "倍速 ×%.2f（[ ]）　, . 逐帧（Shift 十帧）　V 运动分解：%s" % [SPEEDS[_speed_index], DECOMPOSE_NAMES[_motion_decompose]]
	if _motion_decompose != 0:
		text += " 帧距 %d（N）" % DECOMPOSE_FRAME_STEPS[_decompose_step_index]
	if _supports_skill_timeline() and int(_subject.get("preview_pose")) == 2:
		var cycle := _cycle_duration()
		var time := fposmod(float(_subject.get("preview_time")), cycle)
		text += "\n循环 %.2f/%.2f s　第 %d/%d 帧　%s" % [
			time, cycle, int(roundf(time * 60.0)), int(roundf(cycle * 60.0)), _phase_name(time)]
	else:
		text += "\n时间 %.2f s　姿态：%s" % [float(_subject.get("preview_time")), String(_subject.call("get_preview_pose_name"))]
	return text


## —— 点击拾取：程序化外形没有碰撞体，用射线与网格三角形求交 ——


func _nodes_named(part: String) -> Array[Node3D]:
	var found: Array[Node3D] = []
	if not is_instance_valid(_subject):
		return found
	# 同名兄弟会被 Godot 改名（例如 @CrystalSac@2），所以用包含匹配而不是前缀。
	for node in _subject.find_children("*", "Node3D", true, false):
		if String(node.name).contains(part):
			found.append(node as Node3D)
	return found


func _pick_at(viewport_position: Vector2) -> void:
	if not is_instance_valid(_subject) or not is_instance_valid(_camera):
		return
	var origin := _camera.project_ray_origin(viewport_position)
	var direction := _camera.project_ray_normal(viewport_position)
	var best: MeshInstance3D = null
	var best_distance := INF
	for node in _subject.find_children("*", "MeshInstance3D", true, false):
		var distance := _ray_mesh_distance(node as MeshInstance3D, origin, direction)
		if distance >= 0.0 and distance < best_distance:
			best_distance = distance
			best = node as MeshInstance3D
	_select_mesh(best)
	_update_status()


## 射线与网格求交：返回世界空间的命中距离；未命中返回 -1。
func _ray_mesh_distance(mesh: MeshInstance3D, origin: Vector3, direction: Vector3) -> float:
	if mesh == null or mesh.mesh == null:
		return -1.0
	var to_local := mesh.global_transform.affine_inverse()
	var local_origin := to_local * origin
	var local_direction := to_local.basis * direction
	var faces := mesh.mesh.get_faces()
	var best := -1.0
	var index := 0
	while index + 2 < faces.size():
		var t := _ray_triangle(local_origin, local_direction, faces[index], faces[index + 1], faces[index + 2])
		if t > 0.0:
			var world_hit := mesh.global_transform * (local_origin + local_direction * t)
			var distance := origin.distance_to(world_hit)
			if best < 0.0 or distance < best:
				best = distance
		index += 3
	return best


## Möller–Trumbore：返回射线参数 t；未命中返回 -1。
func _ray_triangle(origin: Vector3, direction: Vector3, a: Vector3, b: Vector3, c: Vector3) -> float:
	var edge1 := b - a
	var edge2 := c - a
	var pvec := direction.cross(edge2)
	var determinant := edge1.dot(pvec)
	if absf(determinant) < 0.0000001:
		return -1.0
	var inverse := 1.0 / determinant
	var tvec := origin - a
	var u := tvec.dot(pvec) * inverse
	if u < 0.0 or u > 1.0:
		return -1.0
	var qvec := tvec.cross(edge1)
	var v := direction.dot(qvec) * inverse
	if v < 0.0 or u + v > 1.0:
		return -1.0
	var t := edge2.dot(qvec) * inverse
	return t if t > 0.0 else -1.0


func _select_mesh(mesh: MeshInstance3D) -> void:
	_clear_highlight()
	_clear_selection()
	if mesh != null and _select_material != null:
		_selected_mesh = mesh
		_selected_restore = mesh.material_override
		mesh.material_override = _select_material
		_selection_hint = _describe_mesh(mesh)
	# 直接调用本函数（截图、测试）也要立刻看到"选中"行，不能只等 _pick_at 刷新。
	_update_status()


func _clear_selection() -> void:
	if is_instance_valid(_selected_mesh) and _selected_mesh.material_override == _select_material:
		_selected_mesh.material_override = _selected_restore
	_selected_mesh = null
	_selected_restore = null
	_selection_hint = ""


## 报出点中的几何体名与父级（最多三级），并反查影响它的参数。
func _describe_mesh(mesh: MeshInstance3D) -> String:
	var chain := PackedStringArray()
	var node: Node = mesh
	while node != null and node != _subject:
		chain.append(String(node.name))
		node = node.get_parent()
	var params := _params_for_chain(chain)
	# 只显示被点中的几何体与最近两级父级：完整路径太长，会把状态行撑爆。
	var shown := PackedStringArray()
	for i in mini(chain.size(), 3):
		shown.append(chain[i])
	var where := " ← ".join(shown)
	if chain.size() > shown.size():
		where += "（+%d 层）" % (chain.size() - shown.size())
	if params.is_empty():
		return "选中：%s　影响参数：未登记" % where
	return "选中：%s　影响参数：%s" % [where, params]


func _params_for_chain(chain: PackedStringArray) -> String:
	var table: Dictionary = ParamParts.PARTS.get(_current_profile(), {})
	var labels := PackedStringArray()
	# 先看被点中的几何体自己，再看它的父级：排在前面的才是最直接相关的参数。
	for name in chain:
		for key in table:
			var entry: Dictionary = table[key]
			var matched := false
			for part in entry.get("parts", []):
				if name.contains(String(part)):
					matched = true
					break
			if matched:
				var label := _param_label(String(key))
				if not labels.has(label):
					labels.append(label)
					# 上限在追加处就截断：一个父级可能一次命中好几条，否则会折行。
					if labels.size() >= 4:
						return "、".join(labels)
	return "、".join(labels)


## —— 参数 → 部位高亮：悬停或改动滑块时，闪一下它真正作用的部位 ——


func _status_detail() -> String:
	var text := _motion_readout()
	if not _selection_hint.is_empty():
		text += "\n" + _selection_hint
	if not _param_hint.is_empty():
		text += "\n" + _param_hint
	return text


func _highlight_field(key: String) -> void:
	_param_hint = _param_hint_text(key)
	_apply_highlight(key)
	_update_status()


func _param_hint_text(key: String) -> String:
	var label := _param_label(key)
	var entry := ParamParts.lookup(_current_profile(), key)
	if entry.is_empty():
		return "参数：%s → 未登记作用部位" % label
	var parts: Array = entry.get("parts", [])
	var names := PackedStringArray()
	for part in parts:
		names.append(String(part))
	var where := String(entry.get("scope", "全身" if names.is_empty() else "、".join(names)))
	return "参数：%s → %s（%s）" % [label, where, _short_phase(String(entry.get("phase", "")))]


## 阶段说明太长会撑爆状态行：只取开头一段（"弹甲投囊 → 定势（倒放后）" → "弹甲投囊"）。
func _short_phase(phase: String) -> String:
	var cut := phase
	for separator in [" →", "；", "，", "（"]:
		var at := cut.find(separator)
		if at > 0:
			cut = cut.substr(0, at)
	return cut.strip_edges()


func _current_profile() -> String:
	return String(GALLERY[_gallery_index].get("profile", ""))


func _param_label(key: String) -> String:
	for group: Dictionary in Tuning.get_schema(_current_profile()).get("groups", []):
		for field: Dictionary in group.get("fields", []):
			if String(field.get("key", "")) == key:
				return String(field.get("label", key))
	return key


func _apply_highlight(key: String) -> void:
	_clear_highlight()
	if not is_instance_valid(_subject) or _highlight_material == null:
		return
	var entry := ParamParts.lookup(_current_profile(), key)
	if entry.is_empty():
		return
	if entry.has("scope"):
		return # 玩家战斗资源字段有说明，但不把Boss全身高亮成作用部位。
	var parts: Array = entry.get("parts", [])
	if parts.is_empty():
		for node in _subject.find_children("*", "MeshInstance3D", true, false):
			_add_highlight_mesh(node as MeshInstance3D)
	else:
		for part in parts:
			for node in _nodes_named(String(part)):
				_add_highlight_mesh(node as MeshInstance3D)
				for child in node.find_children("*", "MeshInstance3D", true, false):
					_add_highlight_mesh(child as MeshInstance3D)
	if not _highlight_restore.is_empty():
		_highlight_until = Time.get_ticks_msec() + HIGHLIGHT_MS


func _add_highlight_mesh(mesh: MeshInstance3D) -> void:
	if mesh == null or _highlight_restore.has(mesh):
		return
	_highlight_restore[mesh] = mesh.material_override
	mesh.material_override = _highlight_material
	_highlight_meshes.append(mesh)


func _clear_highlight() -> void:
	for mesh in _highlight_meshes:
		if is_instance_valid(mesh) and _highlight_restore.has(mesh):
			mesh.material_override = _highlight_restore[mesh] as Material
	_highlight_meshes.clear()
	_highlight_restore.clear()
	_highlight_until = 0
