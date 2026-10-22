class_name MudGolemRenderBatch
extends Node3D
## 泥土傀儡的世界表现服务。
## 每只敌人保留物理、独立攻击与六个动画姿态锚点，不再生成任何 MeshInstance3D。
## 每 24m XZ 网格四组 MultiMesh：躯干 / 晶核 / 双拳 / 双腿。只按渲染帧提交外观。
## 单元格避免一张 MultiMesh 覆盖整个地图，碰撞、逻辑、攻击时序完全不走本服务。

const CELL_SIZE := 24.0
const SHADER := preload("res://shaders/mud_golem_instanced.gdshader")
const COLORS := [
	Color(0.28, 0.32, 0.22), # 身体
	Color(0.10, 0.85, 0.90), # 晶核
	Color(0.42, 0.44, 0.45), # 石拳
	Color(0.28, 0.32, 0.22), # 腿
]
const PART_COUNT := [1, 1, 2, 2]
static var _scenes: Dictionary = {}

var _actors: Dictionary = {}
var _buckets: Dictionary = {}
var _shared_meshes: Array[Mesh] = []
var _shared_visual_materials: Array[Material] = []
var _shared_debris_materials: Array[Material] = []
var _draw_calls_expected := 0


static func acquire(body: Node3D) -> MudGolemRenderBatch:
	var scene := body.get_tree().current_scene
	if scene == null:
		scene = body.get_tree().root
	var key := scene.get_instance_id()
	var existing: WeakRef = _scenes.get(key)
	var batch: MudGolemRenderBatch = existing.get_ref() as MudGolemRenderBatch if existing != null else null
	if is_instance_valid(batch):
		return batch
	batch = MudGolemRenderBatch.new()
	batch.name = "MudGolemRenderBatch"
	# Model transforms are WORLD transforms. Never inherit a translated scene root.
	batch.top_level = true
	scene.add_child(batch)
	batch.global_transform = Transform3D.IDENTITY
	_scenes[key] = weakref(batch)
	return batch


func _ready() -> void:
	_create_shared_resources()
	# 批服务没有任何物理更新，所有动画姿态只在真正需要渲染时提取。
	set_physics_process(false)


func _exit_tree() -> void:
	_actors.clear()
	_buckets.clear()
	for scene_id in _scenes.keys():
		var ref: WeakRef = _scenes[scene_id]
		if ref.get_ref() == self or ref.get_ref() == null:
			_scenes.erase(scene_id)


func register(
	body: CharacterBody3D, root_node: Node3D, torso: Node3D, core: Node3D,
	left_arm: Node3D, right_arm: Node3D, left_leg: Node3D, right_leg: Node3D
) -> void:
	_actors[body.get_instance_id()] = {
		"ref": weakref(body), "root": root_node, "torso": torso, "core": core,
		"left_arm": left_arm, "right_arm": right_arm,
		"left_leg": left_leg, "right_leg": right_leg,
	}


func unregister(body: Node3D) -> void:
	_actors.erase(body.get_instance_id())


func actor_count() -> int:
	return _actors.size()


func batch_count() -> int:
	return _buckets.size()


func expected_draw_groups() -> int:
	return _draw_calls_expected


## 临死才实例化真实可碰撞碎块，平时六个外观部位全部是 MultiMesh 实例。
func debris_parts(body: Node3D) -> Array[Dictionary]:
	var record: Dictionary = _actors.get(body.get_instance_id(), {})
	if record.is_empty():
		return []
	var poses := _part_poses(record)
	var parts: Array[Dictionary] = []
	for part_index in 6:
		var resource_index := 0 if part_index == 0 else 1 if part_index == 1 else 2 if part_index < 4 else 3
		parts.append({
			"transform": poses[part_index],
			"mesh": _shared_meshes[resource_index],
			"material": _shared_debris_materials[resource_index],
		})
	return parts


func _create_shared_resources() -> void:
	var torso := CylinderMesh.new()
	torso.top_radius = 0.4
	torso.bottom_radius = 0.25
	torso.height = 0.6
	torso.radial_segments = 5
	torso.rings = 0
	var core := BoxMesh.new()
	core.size = Vector3(0.16, 0.16, 0.16)
	var fist := BoxMesh.new()
	fist.size = Vector3(0.28, 0.42, 0.32)
	var leg := BoxMesh.new()
	leg.size = Vector3(0.18, 0.35, 0.22)
	_shared_meshes.assign([torso, core, fist, leg])
	for index in COLORS.size():
		var material := ShaderMaterial.new()
		material.shader = SHADER
		material.set_shader_parameter("base_color", COLORS[index])
		material.set_shader_parameter("roughness_value", 0.95 if index == 0 or index == 3 else 0.90)
		material.set_shader_parameter("glow_strength", 0.16 if index == 1 else 0.0)
		_shared_visual_materials.append(material)
		var debris := StandardMaterial3D.new()
		debris.albedo_color = COLORS[index]
		debris.roughness = 0.95 if index == 0 or index == 3 else 0.9
		debris.specular_mode = BaseMaterial3D.SPECULAR_DISABLED
		if index == 1:
			debris.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		_shared_debris_materials.append(debris)


func _make_bucket(cell: Vector2i) -> Dictionary:
	var container := Node3D.new()
	container.name = "MudGolemCell_%d_%d" % [cell.x, cell.y]
	add_child(container)
	var groups: Array[MultiMesh] = []
	for index in _shared_meshes.size():
		var multimesh := MultiMesh.new()
		multimesh.transform_format = MultiMesh.TRANSFORM_3D
		multimesh.use_custom_data = true
		multimesh.mesh = _shared_meshes[index]
		multimesh.visible_instance_count = 0
		var instance := MultiMeshInstance3D.new()
		instance.name = "Mud_%d" % index
		instance.multimesh = multimesh
		instance.material_override = _shared_visual_materials[index]
		container.add_child(instance)
		groups.append(multimesh)
	return {"container": container, "groups": groups, "capacity": 0}


func _ensure_capacity(bucket: Dictionary, count: int) -> void:
	if int(bucket.capacity) >= count:
		return
	var next_capacity := maxi(8, int(bucket.capacity))
	while next_capacity < count:
		next_capacity *= 2
	for index in PART_COUNT.size():
		var multimesh: MultiMesh = bucket.groups[index]
		multimesh.instance_count = next_capacity * PART_COUNT[index]
	bucket.capacity = next_capacity


func _part_poses(entry: Dictionary) -> Array[Transform3D]:
	var torso: Node3D = entry.torso
	var core: Node3D = entry.core
	var left_arm: Node3D = entry.left_arm
	var right_arm: Node3D = entry.right_arm
	var left_leg: Node3D = entry.left_leg
	var right_leg: Node3D = entry.right_leg
	return [
		torso.global_transform,
		core.global_transform,
		left_arm.global_transform * Transform3D(Basis.IDENTITY, Vector3(-0.15, -0.3, 0.0)),
		right_arm.global_transform * Transform3D(Basis.from_scale(Vector3.ONE * 1.15), Vector3(0.15, -0.3, 0.0)),
		left_leg.global_transform * Transform3D(Basis.IDENTITY, Vector3(0.0, -0.15, 0.0)),
		right_leg.global_transform * Transform3D(Basis.IDENTITY, Vector3(0.0, -0.15, 0.0)),
	]


func _process(_delta: float) -> void:
	var grouped: Dictionary = {}
	var expired: Array[int] = []
	for id: int in _actors:
		var entry: Dictionary = _actors[id]
		var actor: Node3D = entry.ref.get_ref() as Node3D
		if not is_instance_valid(actor) or not actor.is_inside_tree() or actor.is_queued_for_deletion():
			expired.append(id)
			continue
		var root_node: Node3D = entry.root
		if not actor.is_visible_in_tree() or not is_instance_valid(root_node) or not root_node.is_visible_in_tree():
			continue
		var p := actor.global_position
		var cell := Vector2i(floori(p.x / CELL_SIZE), floori(p.z / CELL_SIZE))
		if not grouped.has(cell):
			grouped[cell] = []
		(grouped[cell] as Array).append(entry)
	for id in expired:
		_actors.erase(id)

	_draw_calls_expected = 0
	for cell: Vector2i in grouped:
		if not _buckets.has(cell):
			_buckets[cell] = _make_bucket(cell)
		var bucket: Dictionary = _buckets[cell]
		bucket["idle_frames"] = 0
		var members: Array = grouped[cell]
		_ensure_capacity(bucket, members.size())
		var multimeshes: Array = bucket.groups
		var lowest := Vector3(INF, INF, INF)
		var highest := Vector3(-INF, -INF, -INF)
		for index in members.size():
			var entry: Dictionary = members[index]
			var actor: Node3D = entry.ref.get_ref() as Node3D
			var point := actor.global_position
			lowest = lowest.min(point)
			highest = highest.max(point)
			var poses := _part_poses(entry)
			var flash := float(actor.call("visual_flash_strength"))
			for piece in 4:
				var mm: MultiMesh = multimeshes[piece]
				for local_index in PART_COUNT[piece]:
					var actual_index := index * PART_COUNT[piece] + local_index
					var pose_index := piece if piece < 2 else 2 + local_index if piece == 2 else 4 + local_index
					mm.set_instance_transform(actual_index, poses[pose_index])
					mm.set_instance_custom_data(actual_index, Color(flash, 0.0, 0.0, 0.0))
		var bounds := AABB(lowest - Vector3(4, 5, 4), highest - lowest + Vector3(8, 10, 8))
		for piece in 4:
			var mm: MultiMesh = multimeshes[piece]
			mm.visible_instance_count = members.size() * PART_COUNT[piece]
			if not mm.custom_aabb.is_equal_approx(bounds):
				mm.custom_aabb = bounds
		_draw_calls_expected += 4
	var stale_cells: Array[Vector2i] = []
	for cell: Vector2i in _buckets:
		if grouped.has(cell):
			continue
		var bucket: Dictionary = _buckets[cell]
		for mm: MultiMesh in bucket.groups:
			mm.visible_instance_count = 0
		# Preserve short wave gaps without accumulating thousands of empty cells
		# across a long exploratory run.
		bucket["idle_frames"] = int(bucket.get("idle_frames", 0)) + 1
		if int(bucket.idle_frames) > 600:
			stale_cells.append(cell)
	for cell in stale_cells:
		var bucket: Dictionary = _buckets[cell]
		(bucket.container as Node).queue_free()
		_buckets.erase(cell)
