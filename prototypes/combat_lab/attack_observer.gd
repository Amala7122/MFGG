extends Node3D
## 仅测试台创建。蓝色理论范围／预计路线，橙色真实起手快照，绿色实际运动留痕。
const Inspect := preload("res://scripts/testing/enemy_attack_inspection.gd")
const UI := preload("res://scripts/ui_theme.gd")
const Area := preload("res://scripts/enemy_attack_area.gd")
const Puddle := preload("res://scripts/enemies/poison_puddle.gd")
const ObservationCamera := preload("res://scripts/testing/observation_camera.gd")
const ShapePanel := preload("res://prototypes/combat_lab/skill_shape_panel.gd")
signal replay_requested
signal return_requested
var lab: Node3D
var study := false
var enabled := true
var actor: Node3D
var actor_choice: OptionButton
var skill_choice: OptionButton
var distance_input: SpinBox
var _ranges: CheckBox
var _paths: CheckBox
var _panel: PanelContainer
var _readout: Label
var _hint: Label
var _study_controls: Container
var shape_panel: PanelContainer
var shape_sample: Dictionary = {}
var single_playing := false
var _single_completed := false
var _edit_button: Button
var _step_button: Button
var _canvas: CanvasLayer
var _mesh: MeshInstance3D
var _geometry := ImmediateMesh.new()
var _vertices := PackedVector3Array()
var _colors: Array[Color] = []
var _traces: Array[Dictionary] = []
var _last_positions := {}
var _clock := 0.0
var _refresh := 0.0
var _saved_time_scale := 1.0
var _was_paused := false
var _speed: OptionButton
var _hold: SpinBox
var _pause: Button
var _view: OptionButton
var _framing: OptionButton
var _zoom: SpinBox
var camera: Camera3D
var camera_control := ObservationCamera.new()
var _base_camera_distance := 13.0
var sample_data := {}
var active_snapshots: Array[Dictionary] = []

func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	add_to_group("attack_inspection_observers")
	_saved_time_scale = Engine.time_scale
	_mesh = MeshInstance3D.new()
	_mesh.mesh = _geometry
	_mesh.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	var material := StandardMaterial3D.new()
	material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	material.vertex_color_use_as_albedo = true
	material.no_depth_test = true
	_mesh.material_override = material
	add_child(_mesh)
	camera = Camera3D.new()
	camera.far = 250.0
	add_child(camera)
	add_child(camera_control)
	camera_control.bind(camera,Vector3.ZERO)
	camera_control.active = false
	camera_control.changed.connect(_camera_changed)
	_canvas = CanvasLayer.new()
	_canvas.layer = 115
	add_child(_canvas)
	_panel = PanelContainer.new()
	_panel.theme = lab._configuration_theme()
	for type in ["CheckBox", "OptionButton", "Button", "Label", "SpinBox"]:
		for key in ["font_color", "font_hover_color", "font_pressed_color", "font_focus_color"]: _panel.theme.set_color(key, type, UI.COLOR_BODY)
	var style := StyleBoxFlat.new()
	style.bg_color = Color(0.025, 0.045, 0.04, 0.98)
	style.set_content_margin_all(5)
	_panel.add_theme_stylebox_override("panel", style)
	_panel.position = Vector2(8, 40)
	_canvas.add_child(_panel)
	var column := VBoxContainer.new()
	column.add_theme_constant_override("separation", 2)
	_panel.add_child(column)
	var row := HFlowContainer.new()
	column.add_child(row)
	_ranges = CheckBox.new()
	_ranges.text = "攻击范围"
	_ranges.button_pressed = true
	row.add_child(_ranges)
	_paths = CheckBox.new()
	_paths.text = "轨迹"
	_paths.button_pressed = true
	row.add_child(_paths)
	actor_choice = OptionButton.new()
	actor_choice.fit_to_longest_item = false
	actor_choice.custom_minimum_size.x = 130
	actor_choice.item_selected.connect(func(_index: int):
		actor = instance_from_id(int(actor_choice.get_item_metadata(actor_choice.selected))) as Node3D
		_traces.clear()
		_last_positions.clear()
		_fill_skills())
	row.add_child(actor_choice)
	skill_choice = OptionButton.new()
	skill_choice.custom_minimum_size.x = 130
	row.add_child(skill_choice)
	_hold = SpinBox.new()
	_hold.min_value = 0.5
	_hold.max_value = 30.0
	_hold.step = 0.5
	_hold.value = 8.0
	_hold.prefix = "留痕 "
	_hold.suffix = " 秒"
	_hold.custom_minimum_size.x = 115
	row.add_child(_hold)
	_button(row, "清轨迹", func(): _traces.clear(); _last_positions.clear())
	_study_controls = HFlowContainer.new()
	column.add_child(_study_controls)
	distance_input = SpinBox.new()
	distance_input.min_value = 0.5
	distance_input.max_value = 80.0
	distance_input.step = 0.5
	distance_input.value = 8.0
	distance_input.prefix = "距离 "
	distance_input.suffix = " 米"
	distance_input.custom_minimum_size.x = 120
	distance_input.tooltip_text = "重播／进入定格时采用此固定目标距离；不会移动已经锁定的预警。"
	_study_controls.add_child(distance_input)
	_button(_study_controls, "重播", _request_replay)
	_edit_button = _button(_study_controls,"定格编辑",func():
		if shape_panel.visible: close_shape_edit()
		else: lab.edit_observation_shape())
	_edit_button.tooltip_text = "首批支持沉积泰坦→三线重击；固定站位与时刻，调整真实范围及时序。其他技能仍可重播观察。"
	_pause = _button(_study_controls, "暂停 / 继续", func(): get_tree().paused = not get_tree().paused)
	_step_button = _button(_study_controls, "单帧", _step)
	_speed = OptionButton.new()
	for label in ["1×", "0.5×", "0.25×", "0.1×"]: _speed.add_item(label)
	_speed.item_selected.connect(func(index: int): Engine.time_scale = _saved_time_scale * [1.0, 0.5, 0.25, 0.1][index])
	_study_controls.add_child(_speed)
	_view = OptionButton.new()
	for title in ["斜视", "俯视", "侧视"]: _view.add_item(title)
	_view.item_selected.connect(func(_index: int): frame_study())
	_study_controls.add_child(_view)
	_framing = OptionButton.new()
	for title in ["交战区域", "完整范围"]: _framing.add_item(title)
	_framing.item_selected.connect(func(_index: int): frame_study())
	_study_controls.add_child(_framing)
	_zoom = SpinBox.new()
	_zoom.min_value = 0.001
	_zoom.max_value = 1000.0
	_zoom.step = 0.1
	_zoom.value = 1.0
	_zoom.prefix = "镜距 "
	_zoom.custom_minimum_size.x = 110
	_zoom.value_changed.connect(func(value: float): camera_control.set_distance(_base_camera_distance*value))
	_study_controls.add_child(_zoom)
	# 返回统一使用视口左上角的ProfessionalNavigation，不再另造工具栏返回位置。
	_readout = Label.new()
	_readout.clip_text = true
	column.add_child(_readout)
	_hint = Label.new()
	_hint.clip_text = true
	_hint.add_theme_color_override("font_color", Color(0.65, 0.8, 0.75))
	column.add_child(_hint)
	_panel.tooltip_text = "青蓝：理论范围与预计轨迹；橙红：真实准备／锁定／命中快照；绿色：实际运动。范围线穿透地形便于观察，不代表可隔墙命中。普通战斗按 V 开关。单体重播固定种子并关闭个体浮动。"
	var camera_help := Label.new()
	camera_help.text = ObservationCamera.HELP_TEXT + "；选固定视角可复位"
	_study_controls.get_parent().add_child(camera_help)
	camera_help.add_theme_color_override("font_color",Color(0.65,0.8,0.75))
	camera_help.set_meta("study_camera_help",true)
	shape_panel = ShapePanel.new()
	_canvas.add_child(shape_panel)
	shape_panel.sample_changed.connect(func(): _refresh = 0.0)
	shape_panel.play_requested.connect(lab.play_edited_observation.bind(false))
	shape_panel.fight_requested.connect(lab.play_edited_observation.bind(true))

func _request_replay() -> void:
	if lab._shape_transition: return
	if shape_panel.visible:
		if shape_panel.commit(): lab.play_edited_observation(false)
	elif _single_completed: lab.play_edited_observation(false)
	else: replay_requested.emit()

func close_shape_edit() -> void:
	single_playing = false
	_single_completed = false
	shape_panel.visible = false
	shape_sample.clear()
	_refresh = 0.0

func _layout_panels() -> void:
	var viewport_size := get_viewport().get_visible_rect().size
	shape_panel.position = Vector2(viewport_size.x-288,40)
	shape_panel.size = Vector2(280,maxf(280,minf(470,viewport_size.y-52)))
	_panel.size = Vector2(minf(710,viewport_size.x-16-(288 if shape_panel.visible else 0)),0)
	var editing: bool = shape_panel.visible
	_edit_button.disabled = lab._shape_transition or (not editing and (not study or lab._observation_profile != ShapePanel.PROFILE or skill_choice.selected != 4))
	_edit_button.text = "收起编辑" if editing else "定格编辑"
	skill_choice.disabled = editing
	_pause.disabled = editing
	_step_button.disabled = editing
	_speed.disabled = editing

func _unhandled_input(event: InputEvent) -> void:
	if study and camera_control.handle_event(event): get_viewport().set_input_as_handled()

func _camera_changed() -> void:
	if is_instance_valid(_zoom): _zoom.set_value_no_signal(camera_control.distance()/_base_camera_distance)

func _button(parent: Node, title: String, callback: Callable) -> Button:
	var control := Button.new()
	control.text = title
	control.pressed.connect(callback)
	parent.add_child(control)
	return control

func _exit_tree() -> void: Engine.time_scale = _saved_time_scale

func end_study() -> void:
	close_shape_edit()
	study = false
	camera_control.active = false
	camera.current = false
	Engine.time_scale = _saved_time_scale
	_speed.select(0)
	_traces.clear()
	_last_positions.clear()

func watch(subject: Node3D, skill_index: int) -> void:
	actor = subject
	_traces.clear()
	_last_positions.clear()
	_fill_skills()
	skill_choice.select(clampi(skill_index, 0, skill_choice.item_count - 1))
	_refresh = 0.0

func frame_study(preserve_manual := false) -> void:
	if not is_instance_valid(actor): return
	camera_control.active = true
	if preserve_manual and camera_control.user_adjusted:
		camera.current = true
		return
	var target := lab.get("_player") as Node3D
	var center := actor.global_position.lerp(target.global_position, 0.5)
	var span := maxf(actor.global_position.distance_to(target.global_position), actor.scale.x * 5.0)
	if _framing.selected == 1:
		var sample := Inspect.sample(actor, skill_choice.selected)
		var spec: Dictionary = sample.get("spec", {})
		var pose: Transform3D = sample.get("pose", actor.global_transform.orthonormalized())
		if spec.has("length"):
			center = pose.origin - pose.basis.z * float(spec.length) * 0.5
			span = maxf(float(spec.length), float(spec.get("width", spec.get("radius",0.0)))*2.0)
		elif spec.has("radius"):
			center = pose.origin
			span = float(spec.radius)*2.0
		for point: Vector3 in sample.get("path", PackedVector3Array()): span = maxf(span, center.distance_to(point)*2.0)
	var directions := [Vector3(0.8,0.8,1), Vector3(0,1,0), Vector3(1,0.25,0.15)]
	_base_camera_distance = maxf(span * 1.4,13.0)
	camera_control.set_view(center+(directions[_view.selected] as Vector3).normalized()*_base_camera_distance*_zoom.value,center,Vector3.FORWARD if _view.selected == 1 else Vector3.UP)
	camera.current = true

func _fill_skills() -> void:
	var previous := skill_choice.selected
	skill_choice.clear()
	if not is_instance_valid(actor): return
	for title in Inspect.names(actor): skill_choice.add_item(title)
	if skill_choice.item_count > 0: skill_choice.select(clampi(previous, 0, skill_choice.item_count - 1))

func _step() -> void:
	if not study or not get_tree().paused: return
	get_tree().paused = false
	await get_tree().physics_frame
	if is_inside_tree() and study: get_tree().set_deferred("paused", true)

func record_segment(id: int, start: Vector3, end: Vector3, owner_id := 0, point := "projectile") -> void:
	if not enabled or not is_instance_valid(actor) or not _paths.button_pressed: return
	if owner_id != 0 and owner_id != actor.get_instance_id(): return
	# Projectile segments include the final collision endpoint, even if freed this frame.
	_traces.append({"id":id, "a":start, "b":end, "time":_clock, "point":point})
	if _traces.size() > 6000: _traces.pop_front()

func _physics_process(_delta: float) -> void:
	# 轨迹只在显式“观察”模式里记录。普通 36 只战斗若自动绑定第一只敌人，
	# 每物理帧累积拳/身轨迹并在 50ms 一次重建 ImmediateMesh，会随战斗时长恶化。
	if not study or not enabled:
		_last_positions.clear()
		return
	if not Inspect.can_observe(actor):
		_last_positions.clear()
		return
	if get_tree().paused: return
	var id := actor.get_instance_id()
	var current := actor.global_position
	if _last_positions.has(id):
		var previous: Vector3 = _last_positions[id]
		if previous.distance_squared_to(current) > 0.00001: record_segment(id, previous, current, id, "body")
	_last_positions[id] = current
	var points := Inspect.motion_points(actor)
	for key: Variant in _last_positions.keys():
		if key is String and not points.has(key): _last_positions.erase(key)
	for key: String in points:
		var point: Vector3 = points[key]
		if _last_positions.has(key) and (Vector3(_last_positions[key])).distance_squared_to(point) > 0.00001:
			record_segment(id, _last_positions[key], point, id, key)
		_last_positions[key] = point

func _process(delta: float) -> void:
	if not is_instance_valid(lab): return
	_layout_panels()
	# 观察面板只在显式观察、或场上只有一只敌人时自动出现。
	# 36 只混战时自动绑定第一只并每帧采样/画范围，是测试台的噪声与额外成本。
	var showing: bool = study or (int(lab.state) == lab.State.FIGHTING
		and not lab._panel_open and lab._live_enemies.size() <= 1)
	_panel.visible = showing and enabled
	_mesh.visible = showing and enabled
	_study_controls.visible = study
	for child in _study_controls.get_parent().get_children():
		if child.has_meta("study_camera_help"): child.visible = study
	if not showing or not enabled: return
	if study and single_playing and Inspect.can_observe(actor) and actor.current_state == actor.State.IDLE:
		single_playing = false
		_single_completed = true
		get_tree().paused = true
	if not get_tree().paused: _clock += delta
	if _was_paused != get_tree().paused:
		_was_paused = get_tree().paused
		_refresh = 0.0
	_refresh -= delta / maxf(Engine.time_scale, 0.001)
	if _refresh > 0.0: return
	_refresh = 0.05 if study else 0.2
	_refresh_actor_choices()
	if not Inspect.can_observe(actor):
		sample_data.clear()
		active_snapshots.clear()
		_vertices.clear()
		_colors.clear()
		_append_recorded_traces()
		_flush_geometry()
		_readout.text = "当前对象已死亡／回收，保留已录轨迹"
		_hint.text = "重播可创建新的观察样本；死亡演出正常继续。" if study else "可重新投放敌人；死亡演出正常继续。"
		_hint.tooltip_text = _hint.text
		return
	if shape_panel.visible:
		shape_sample = shape_panel.sample()
		_vertices.clear()
		_colors.clear()
		active_snapshots.clear()
		sample_data.clear()
		for entry: Dictionary in shape_sample.get("shapes",[]):
			if _ranges.button_pressed:
				_outline(entry.pose,entry.spec,Color(.1,.75,1))
				if not shape_sample.timing.struck: _outline(entry.pose,entry.spec,Color(1,.65,.05))
			if not shape_sample.timing.struck: active_snapshots.append(entry.duplicate(true))
		_flush_geometry()
		_readout.text = "定格几何 · 站位／朝向／种子固定 · 体型 ×%.2f" % actor.scale.x
		_hint.text = "橙色为该时刻预警，青蓝为理论边界；真实命中仍检查高度／遮挡。原世界已暂停。"
		_hint.tooltip_text = _hint.text
		return
	sample_data = Inspect.sample(actor, skill_choice.selected)
	_vertices.clear()
	_colors.clear()
	active_snapshots.clear()
	if _ranges.button_pressed and not sample_data.is_empty():
		_outline(sample_data.pose, sample_data.spec, Color(0.1, 0.75, 1.0))
	for area: Node3D in get_tree().get_nodes_in_group("enemy_attack_debug_areas"):
		if not actor.is_ancestor_of(area) or area.phase == Area.Phase.IDLE: continue
		active_snapshots.append({"pose":area.global_transform, "shape":area.shape.duplicate(true), "phase":area.phase})
		if _ranges.button_pressed: _outline(area.global_transform, area.shape, Color(1, 0.19, 0.02) if area.phase >= Area.Phase.STRIKE else Color(1, 0.65, 0.05))
	for hazard: Node3D in get_tree().get_nodes_in_group("enemy_hazards"):
		if not hazard is Puddle: continue
		if int(hazard.source_info.get("inspection_actor_id", 0)) != actor.get_instance_id(): continue
		var spec := {"kind":"circle", "radius":hazard.radius, "height":hazard.hit_height}
		active_snapshots.append({"pose":hazard.global_transform, "shape":spec, "phase":Area.Phase.STRIKE})
		if _ranges.button_pressed: _outline(hazard.global_transform, spec, Color(1,0.19,0.02))
	if _paths.button_pressed and not sample_data.is_empty(): _polyline(sample_data.path, Color(0.2, 0.7, 1.0))
	_append_recorded_traces()
	_flush_geometry()
	var spec: Dictionary = sample_data.get("spec", {})
	_readout.text = "青蓝 理论范围 / 预计轨迹 · 橙红 实际判定 · 绿 实际运动 | 体型 ×%.2f | %s | %s" % [actor.scale.x, "冻结" if get_tree().paused else "运行", _measure(spec)]
	_hint.text = String(sample_data.get("notes", ""))
	if _single_completed: _hint.text = "单次已结束并冻结；可重播或进入定格编辑。" + _hint.text
	if not study: _hint.text = "V 关闭观察 · Esc 释放鼠标 · " + _hint.text
	var controller: PanelContainer = lab._tuning_panel
	if study and controller.enemy_id == lab._observation_profile and not controller.draft_id.is_empty():
		if not controller._pending_text.is_empty(): _hint.text = "有输入未提交；运行样本尚未采用，返回参数页可继续修改。" + _hint.text
		elif controller._session.values(controller.draft_id) != lab._observation_values: _hint.text = "草稿已更新；当前运行样本待重播／试打。" + _hint.text
	_hint.tooltip_text = _hint.text
	if not study: lab._weapon_plate.position.y = _panel.position.y + _panel.size.y + 8.0

func _append_recorded_traces() -> void:
	while not _traces.is_empty() and _clock - float(_traces[0].time) > _hold.value: _traces.pop_front()
	if _paths.button_pressed:
		for trace: Dictionary in _traces: _line(trace.a, trace.b, Color(0.2, 1, 0.2))

func _flush_geometry() -> void:
	_geometry.clear_surfaces()
	if _vertices.is_empty(): return
	_geometry.surface_begin(Mesh.PRIMITIVE_LINES)
	for i in _vertices.size():
		_geometry.surface_set_color(_colors[i])
		_geometry.surface_add_vertex(_vertices[i])
	_geometry.surface_end()

func _refresh_actor_choices() -> void:
	var candidates: Array = lab._live_enemies.filter(func(node: Node3D): return is_instance_valid(node) and not Inspect.names(node).is_empty())
	var ids: Array = candidates.map(func(node: Node3D): return node.get_instance_id())
	var old: Array = []
	for i in actor_choice.item_count: old.append(actor_choice.get_item_metadata(i))
	if old != ids:
		actor_choice.clear()
		for node: Node3D in candidates:
			actor_choice.add_item(String(node.get_meta(&"lab_title", node.name)))
			actor_choice.set_item_metadata(actor_choice.item_count - 1, node.get_instance_id())
	if not is_instance_valid(actor) and not candidates.is_empty(): actor = candidates[0]; _fill_skills()
	if is_instance_valid(actor) and ids.has(actor.get_instance_id()): actor_choice.select(ids.find(actor.get_instance_id()))

func _measure(spec: Dictionary) -> String:
	var parts: Array[String] = []
	for key: String in ["radius", "length", "width", "height"]:
		if spec.has(key): parts.append("%s %.2fm" % [{"radius":"半径", "length":"长度", "width":"宽度", "height":"高度容差"}[key], float(spec[key])])
	return " · ".join(parts)

func _line(a: Vector3, b: Vector3, color: Color) -> void:
	_vertices.append(a); _vertices.append(b)
	_colors.append(color); _colors.append(color)

func _polyline(points: PackedVector3Array, color: Color) -> void:
	for i in range(1, points.size()): _line(points[i-1], points[i], color)

func _outline(pose: Transform3D, spec: Dictionary, color: Color) -> void:
	if spec.is_empty(): return
	var kind := String(spec.get("kind", "circle"))
	if kind == "fan_rects":
		for slot in [-1, 0, 1]:
			var fork := spec.duplicate()
			fork.kind = "rect"
			_outline(Transform3D(pose.basis.rotated(Vector3.UP, deg_to_rad(float(spec.spread))*slot), pose.origin), fork, color)
		return
	var ring := PackedVector3Array()
	var radius := float(spec.get("radius", 1.0))
	if kind == "sphere":
		for axis in 3:
			var circle := PackedVector3Array()
			for i in 65:
				var angle := TAU*i/64.0
				var p := Vector3(cos(angle), 0, sin(angle))*radius
				if axis == 1: p = Vector3(p.x, p.z, 0)
				if axis == 2: p = Vector3(0, p.x, p.z)
				circle.append(pose*p)
			_polyline(circle, color)
		return
	if kind == "rect":
		var width := float(spec.width)*0.5
		var offset := float(spec.get("offset", 0.0))
		ring = PackedVector3Array([Vector3(offset-width,0,0), Vector3(offset+width,0,0), Vector3(offset+width,0,-float(spec.length)), Vector3(offset-width,0,-float(spec.length)), Vector3(offset-width,0,0)])
	elif kind == "capsule":
		for i in 33:
			var angle := PI*i/32.0
			ring.append(Vector3(cos(angle)*radius,0,sin(angle)*radius))
		for i in 33:
			var angle := PI+PI*i/32.0
			ring.append(Vector3(cos(angle)*radius,0,-float(spec.length)+sin(angle)*radius))
		ring.append(ring[0])
	else:
		var arc := deg_to_rad(float(spec.get("angle", 360.0)))
		if kind == "sector": ring.append(Vector3.ZERO)
		for i in 65:
			var angle := -arc*0.5+arc*i/64.0
			ring.append(Vector3(sin(angle),0,-cos(angle))*radius)
		ring.append(ring[0])
	var height := float(spec.get("height", 0.0))
	var low := PackedVector3Array()
	var high := PackedVector3Array()
	for point in ring:
		var bottom := pose*point
		var top := bottom + Vector3.UP*height
		bottom.y = maxf(0.04, bottom.y-height)
		low.append(bottom); high.append(top)
	_polyline(low, color)
	if height > 0:
		_polyline(high, color)
		for i in range(0, low.size(), maxi(1, low.size()/8)): _line(low[i], high[i], color)
