extends Node3D
## 可切换的纯视觉角色观察台。新增角色只需在 GALLERY 登记场景和机位。

const Tuning := preload("res://scripts/prototypes/enemy_tuning.gd")
const GALLERY := [
	{"title": "裂釉镇墓兽 · 外形原型", "scene": preload("res://prototypes/visual/enemies/tomb_guardian_visual.tscn"), "look_y": 3.5, "distance": 14.0, "yaw": 0.55, "height": 0.0, "profile": ""},
	{"title": "泥土傀儡", "scene": preload("res://prototypes/combat/enemies/procedural_mud_golem.tscn"), "look_y": 1.05, "height": 0.65, "profile": "PrototypeMudGolem"},
	{"title": "沉积泰坦", "scene": preload("res://prototypes/combat/enemies/procedural_sediment_titan.tscn"), "look_y": 1.85, "height": 1.7, "profile": "PrototypeSedimentTitan"},
	{"title": "迅捷晶兽", "scene": preload("res://prototypes/combat/enemies/procedural_fast_beast.tscn"), "look_y": 1.0, "height": 0.775, "profile": "PrototypeFastBeast"},
	{"title": "晶刺蜂", "scene": preload("res://prototypes/combat/enemies/procedural_hornet.tscn"), "look_y": 2.0, "height": 2.6, "profile": "PrototypeHornet"},
]
@export_range(0.001, 0.02, 0.001) var orbit_sensitivity := 0.006

@onready var _subject_mount: Node3D = $SubjectMount
@onready var _camera_rig: Node3D = $CameraRig
@onready var _camera_pitch: Node3D = $CameraRig/Pitch
@onready var _camera: Camera3D = $CameraRig/Pitch/Camera3D
@onready var _status_label: Label = $Interface/SafeArea/Panel/Padding/Status

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


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	_game_flow = get_node_or_null("/root/GameFlow") as CanvasLayer
	if _game_flow != null:
		_game_flow_mode = _game_flow.process_mode
		_game_flow_visible = _game_flow.visible
	_enforce_lab_isolation()
	_build_silhouette_material()
	_show_subject(0)


func _exit_tree() -> void:
	if is_instance_valid(_game_flow):
		_game_flow.process_mode = _game_flow_mode
		_game_flow.visible = _game_flow_visible
	get_tree().paused = false
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
				if is_instance_valid(_subject) and _subject.has_method("set_preview_pose"):
					_subject.call("set_preview_pose", int(_subject.get("preview_pose")) + 1)
					_update_status()
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
			KEY_ESCAPE:
				_dragging = false
				Input.mouse_mode = Input.MOUSE_MODE_VISIBLE


func _show_subject(index: int) -> void:
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


func _toggle_silhouette() -> void:
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
	var pose_text := ""
	if is_instance_valid(_subject) and _subject.has_method("get_preview_pose_name"):
		pose_text = "  |  姿态：" + String(_subject.call("get_preview_pose_name"))
	_status_label.text = (
		"敌人视觉实验场  %d/%d  ·  %s  |  %s  |  %s%s\n"
		+ "← / → 或 A / D：换角色    M：静 / 动    P：姿态    B：剪影    空格：旋转    F：复位    Esc：释放鼠标\n"
		+ "左键环绕    滚轮或 1 / 2 / 3 缩放    距离 %.1f m    网格 %d    三角面 %d"
	) % [
		_gallery_index + 1, GALLERY.size(), String(entry["title"]),
		"剪影" if _silhouette else "材质", "动态" if _motion_enabled else "静态",
		pose_text, _camera.position.z, _original_materials.size(), _count_triangles(),
	]


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
