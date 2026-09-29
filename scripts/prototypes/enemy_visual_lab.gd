extends Node3D
## 独立敌人视觉实验场：只负责观察模型，不启动正式游戏、AI 或波次。

@export var subject_scene: PackedScene
@export var subject_title := "快速野兽 · 剪影原型 01"
@export_range(0.001, 0.02, 0.001) var orbit_sensitivity := 0.006

@onready var _subject_mount: Node3D = $SubjectMount
@onready var _camera_rig: Node3D = $CameraRig
@onready var _camera_pitch: Node3D = $CameraRig/Pitch
@onready var _camera: Camera3D = $CameraRig/Pitch/Camera3D
@onready var _status_label: Label = $Interface/SafeArea/Panel/Padding/Status

var _subject: Node3D
var _dragging := false
var _auto_rotate := true
var _silhouette := false
var _distance_index := 1
var _distances := [6.0, 12.0, 24.0]
var _original_materials: Dictionary = {}
var _silhouette_material: StandardMaterial3D
var _isolation_frames_remaining := 3


func _ready() -> void:
	# GameFlow 是全局自动加载项，会在任意场景启动后一帧弹出正式主菜单并暂停场景树。
	# 实验场必须持续运行，因此先让自己不受暂停影响，再在前三帧压住全局流程层。
	process_mode = Node.PROCESS_MODE_ALWAYS
	_enforce_lab_isolation()
	_build_silhouette_material()
	_spawn_subject()
	_reset_view()
	_update_status()


func _process(delta: float) -> void:
	if _isolation_frames_remaining > 0:
		_enforce_lab_isolation()
		_isolation_frames_remaining -= 1
	if _auto_rotate and is_instance_valid(_subject):
		_subject.rotate_y(delta * 0.42)


func _enforce_lab_isolation() -> void:
	get_tree().paused = false
	var game_flow := get_node_or_null("/root/GameFlow") as CanvasLayer
	if game_flow != null:
		game_flow.process_mode = Node.PROCESS_MODE_DISABLED
		game_flow.visible = false
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


func _spawn_subject() -> void:
	if subject_scene == null:
		push_error("敌人视觉实验场没有指定 subject_scene")
		return
	_subject = subject_scene.instantiate() as Node3D
	if _subject == null:
		push_error("敌人视觉实验场的 subject_scene 根节点必须是 Node3D")
		return
	_subject_mount.add_child(_subject)
	_subject.rotation.y = PI
	_capture_original_materials()


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
	for key in _original_materials:
		var mesh_instance := key as MeshInstance3D
		if is_instance_valid(mesh_instance):
			mesh_instance.material_override = (
				_silhouette_material if _silhouette else _original_materials[key] as Material
			)
	_update_status()


func _apply_distance_preset(index: int) -> void:
	_distance_index = clampi(index, 0, _distances.size() - 1)
	_set_distance(float(_distances[_distance_index]))


func _set_distance(value: float) -> void:
	_camera.position.z = clampf(value, 4.5, 30.0)
	_update_status()


func _reset_view() -> void:
	_camera_rig.rotation = Vector3.ZERO
	_camera_pitch.rotation.x = -0.12
	_apply_distance_preset(1)
	if is_instance_valid(_subject):
		_subject.rotation = Vector3(0.0, PI, 0.0)


func _update_status() -> void:
	if _status_label == null:
		return
	var mesh_count := _original_materials.size()
	var triangle_count := _count_triangles()
	_status_label.text = (
		"%s\n"
		+ "左键拖拽：环绕观察    滚轮：连续缩放    1 / 2 / 3：近 / 中 / 远\n"
		+ "B：纯黑剪影    空格：自动旋转    F：复位视角\n"
		+ "当前：%s  |  距离 %.1f m  |  网格节点 %d  |  三角面 %d  |  自动旋转 %s"
	) % [
		subject_title,
		"剪影" if _silhouette else "材质",
		_camera.position.z,
		mesh_count,
		triangle_count,
		"开" if _auto_rotate else "关",
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
