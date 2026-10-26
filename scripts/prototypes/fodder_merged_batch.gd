class_name FodderMergedBatch
extends Node3D
## 单网格/单实例/GPU 姿态的傀儡表现层。
## 每只傀儡只保留 CharacterBody3D 和碰撞；视觉上不再有 6 个肢体 pivot/Tween，
## 整个身体是一个合并网格，一个 MultiMesh 实例，四肢由 vertex shader 摆动。

const SHADER := preload("res://shaders/golem_fodder_merged.gdshader")
static var _scenes: Dictionary = {}

var _actors: Dictionary = {}
var _multimesh: MultiMesh
var _multimesh_instance: MultiMeshInstance3D
var _capacity := 0
var _torso_mesh: Mesh
var _core_mesh: Mesh
var _fist_mesh: Mesh
var _leg_mesh: Mesh
var _debris_materials: Array[StandardMaterial3D] = []


static func acquire(body: Node3D) -> FodderMergedBatch:
	var scene := body.get_tree().current_scene
	if scene == null:
		scene = body.get_tree().root
	var key := scene.get_instance_id()
	var existing: WeakRef = _scenes.get(key)
	var batch: FodderMergedBatch = existing.get_ref() as FodderMergedBatch if existing != null else null
	if is_instance_valid(batch):
		return batch
	batch = FodderMergedBatch.new()
	batch.name = "FodderMergedBatch"
	batch.top_level = true
	scene.add_child(batch)
	batch.global_transform = Transform3D.IDENTITY
	_scenes[key] = weakref(batch)
	return batch


func _ready() -> void:
	for color in [Color(0.28, 0.32, 0.22), Color(0.10, 0.85, 0.90),
			Color(0.42, 0.44, 0.45), Color(0.24, 0.28, 0.20)]:
		var debris := StandardMaterial3D.new()
		debris.albedo_color = color
		debris.roughness = 0.95
		debris.specular_mode = BaseMaterial3D.SPECULAR_DISABLED
		_debris_materials.append(debris)
	var material := ShaderMaterial.new()
	material.shader = SHADER
	material.set_shader_parameter("body_color", Color(0.28, 0.32, 0.22))
	material.set_shader_parameter("core_color", Color(0.10, 0.85, 0.90))
	material.set_shader_parameter("fist_color", Color(0.42, 0.44, 0.45))
	material.set_shader_parameter("leg_color", Color(0.28, 0.32, 0.22))
	_multimesh = MultiMesh.new()
	_multimesh.transform_format = MultiMesh.TRANSFORM_3D
	_multimesh.use_custom_data = true
	_multimesh.mesh = _build_merged_mesh()
	_multimesh.instance_count = 0
	_multimesh.visible_instance_count = 0
	_multimesh.custom_aabb = AABB(Vector3(-1000, -100, -1000), Vector3(2000, 400, 2000))
	_multimesh_instance = MultiMeshInstance3D.new()
	_multimesh_instance.name = "FodderMergedMesh"
	_multimesh_instance.multimesh = _multimesh
	_multimesh_instance.material_override = material
	add_child(_multimesh_instance)
	set_physics_process(false)


func _exit_tree() -> void:
	_actors.clear()
	for scene_id in _scenes.keys():
		var ref: WeakRef = _scenes[scene_id]
		if ref.get_ref() == self or ref.get_ref() == null:
			_scenes.erase(scene_id)


func register(body: CharacterBody3D, visual_root: Node3D) -> void:
	_actors[body.get_instance_id()] = {"body": weakref(body), "root": visual_root}


func unregister(body: Node3D) -> void:
	_actors.erase(body.get_instance_id())


func actor_count() -> int:
	return _actors.size()


func _ensure_capacity(needed: int) -> void:
	if _capacity >= needed:
		return
	var next_capacity := 8
	while next_capacity < needed:
		next_capacity *= 2
	_multimesh.instance_count = next_capacity
	_capacity = next_capacity


func _process(_delta: float) -> void:
	var alive: Array = []
	var expired: Array[int] = []
	for id: int in _actors:
		var entry: Dictionary = _actors[id]
		var body := entry.body.get_ref() as Node3D
		var root := entry.root as Node3D
		if not is_instance_valid(body) or not is_instance_valid(root):
			expired.append(id)
			continue
		alive.append(entry)
	for id in expired:
		_actors.erase(id)
	_ensure_capacity(alive.size())
	for index in alive.size():
		var entry: Dictionary = alive[index]
		var body := entry.body.get_ref() as Node3D
		var root := entry.root as Node3D
		var phase := float(body.get("anim_clock"))
		if body.has_method("get") and body.get("fodder_attack_phase") != null:
			phase = float(body.get("anim_clock"))
		var attack := float(body.get("fodder_attack_phase")) if body.get("fodder_attack_phase") != null else 0.0
		var move := 1.0 if body is CharacterBody3D and (body as CharacterBody3D).velocity.length() > 0.15 else 0.0
		var flash := 0.0
		if body.has_method("visual_flash_strength"):
			flash = float(body.call("visual_flash_strength"))
		_multimesh.set_instance_transform(index, root.global_transform)
		_multimesh.set_instance_custom_data(index, Color(phase, attack, flash, move))
	_multimesh.visible_instance_count = alive.size()


## 死亡散体：merged 模式没有 6 个 pivot，按当前相位/攻击姿态重建 6 个部件姿态。
func debris_parts(body: Node3D) -> Array[Dictionary]:
	var entry: Dictionary = _actors.get(body.get_instance_id(), {})
	var root := entry.get("root") as Node3D
	if not is_instance_valid(root):
		return []
	var phase := float(body.get("anim_clock"))
	var attack := float(body.get("fodder_attack_phase")) if body.get("fodder_attack_phase") != null else 0.0
	var move := 1.0 if body is CharacterBody3D and (body as CharacterBody3D).velocity.length() > 0.15 else 0.0
	var walk := sin(phase * 7.0) * 0.5 * move
	var attack_swing := sin(clampf(attack, 0.0, 1.0) * PI) * 1.8 if attack > 0.001 else 0.0
	var bob := absf(sin(phase * 7.0)) * 0.03 * move
	var root_transform := root.global_transform
	var torso := root_transform * Transform3D(Basis(), Vector3(0, 0.75 + bob, 0))
	var core_basis := Basis.from_euler(Vector3(deg_to_rad(45), deg_to_rad(45), 0))
	var core := root_transform * Transform3D(core_basis, Vector3(0, 0.87, 0.32))
	var left_arm := _limb_transform(root_transform, Vector3(-0.45, 0.9, 0), -walk + attack_swing, 0.3)
	var right_arm := _limb_transform(root_transform, Vector3(0.45, 0.9, 0), walk + attack_swing, 0.3)
	var left_leg := _limb_transform(root_transform, Vector3(-0.22, 0.35, 0), walk * 1.3, 0.15)
	var right_leg := _limb_transform(root_transform, Vector3(0.22, 0.35, 0), -walk * 1.3, 0.15)
	return [
		{"transform": torso, "mesh": _torso_mesh, "material": _debris_materials[0]},
		{"transform": core, "mesh": _core_mesh, "material": _debris_materials[1]},
		{"transform": left_arm, "mesh": _fist_mesh, "material": _debris_materials[2]},
		{"transform": right_arm, "mesh": _fist_mesh, "material": _debris_materials[2]},
		{"transform": left_leg, "mesh": _leg_mesh, "material": _debris_materials[3]},
		{"transform": right_leg, "mesh": _leg_mesh, "material": _debris_materials[3]},
	]


func _limb_transform(root: Transform3D, shoulder: Vector3, angle: float, half_length: float) -> Transform3D:
	var basis := Basis(Vector3.RIGHT, angle)
	return root * Transform3D(basis, shoulder + basis * Vector3(0, -half_length, 0))


func _build_merged_mesh() -> ArrayMesh:
	var tool := SurfaceTool.new()
	tool.begin(Mesh.PRIMITIVE_TRIANGLES)
	var cursor := 0

	var torso := CylinderMesh.new()
	_torso_mesh = torso
	torso.top_radius = 0.4
	torso.bottom_radius = 0.25
	torso.height = 0.6
	torso.radial_segments = 5
	torso.rings = 0
	cursor = _append_part(tool, torso, Transform3D(Basis(), Vector3(0, 0.75, 0)),
		0, Vector3(0, 0.75, 0), cursor)

	var core := BoxMesh.new()
	_core_mesh = core
	core.size = Vector3(0.16, 0.16, 0.16)
	var core_basis := Basis.from_euler(Vector3(deg_to_rad(45), deg_to_rad(45), 0))
	cursor = _append_part(tool, core, Transform3D(core_basis, Vector3(0, 0.87, 0.32)),
		1, Vector3(0, 0.87, 0.32), cursor)

	var fist := BoxMesh.new()
	_fist_mesh = fist
	fist.size = Vector3(0.28, 0.42, 0.32)
	cursor = _append_part(tool, fist, Transform3D(Basis(), Vector3(-0.6, 0.6, 0)),
		2, Vector3(-0.45, 0.9, 0), cursor)
	cursor = _append_part(tool, fist, Transform3D(Basis.from_scale(Vector3.ONE * 1.15), Vector3(0.6, 0.6, 0)),
		3, Vector3(0.45, 0.9, 0), cursor)

	var leg := BoxMesh.new()
	_leg_mesh = leg
	leg.size = Vector3(0.18, 0.35, 0.22)
	cursor = _append_part(tool, leg, Transform3D(Basis(), Vector3(-0.22, 0.2, 0)),
		4, Vector3(-0.22, 0.35, 0), cursor)
	cursor = _append_part(tool, leg, Transform3D(Basis(), Vector3(0.22, 0.2, 0)),
		5, Vector3(0.22, 0.35, 0), cursor)
	return tool.commit()


func _append_part(tool: SurfaceTool, mesh: Mesh, transform: Transform3D, part: int,		pivot: Vector3, cursor: int) -> int:
	var arrays := mesh.surface_get_arrays(0)
	var vertices: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
	var normals: PackedVector3Array = arrays[Mesh.ARRAY_NORMAL]
	var indices: PackedInt32Array = arrays[Mesh.ARRAY_INDEX]
	var base := cursor
	for index in vertices.size():
		tool.set_uv(Vector2(float(part), pivot.x))
		tool.set_uv2(Vector2(pivot.y, pivot.z))
		tool.set_normal((transform.basis * normals[index]).normalized())
		tool.add_vertex(transform * vertices[index])
		cursor += 1
	for index in indices:
		tool.add_index(base + index)
	return cursor
