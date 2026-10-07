@tool
extends StaticBody3D
## 石块 / 残柱的程序化示例外形。破坏能力由独立组件提供，其他模型无需扩展 kind。
signal broken(prop: StaticBody3D)
const StoneMesh := preload("res://scripts/lowpoly_mesh.gd")
const Destructible := preload("res://scripts/destructible_component.gd")
@export_enum("石块", "残柱") var kind := 0
@export var dimensions := Vector3(2.0, 1.5, 1.8)
@export var stone_color := Color(0.53, 0.43, 0.31)
@export var break_strength := 1.0:
	set(value):
		break_strength = value
		if _destructible:
			_destructible.profile.strength = value
var is_broken: bool:
	get:
		return _destructible != null and _destructible.is_broken
var _destructible: Node3D
var _intact: Node3D
var _rubble: Node3D
var _collision: CollisionShape3D


func _ready() -> void:
	collision_layer = 1
	collision_mask = 0
	_build()
	if not Engine.is_editor_hint():
		_destructible = Destructible.new()
		_destructible.name = "Destructible"
		_destructible.profile = preload("res://data/destruction/stone.tres").duplicate()
		_destructible.profile.strength = break_strength
		_destructible.profile.fragment_color = stone_color
		_destructible.profile.fragment_count = 16 if kind == 1 else 14
		_destructible.broken.connect(func(_component: Node3D): broken.emit(self))
		add_child(_destructible)


func can_break(power: float) -> bool:
	return _destructible != null and _destructible.can_break(power)


func break_from_impact(point: Vector3, direction: Vector3, power: float) -> bool:
	return _destructible != null and _destructible.break_from_impact(point, direction, power)


func reset_destruction() -> void:
	if _destructible:
		_destructible.reset_destruction()


func impact_point(from: Vector3) -> Vector3:
	return _destructible.impact_point(from) if _destructible else global_position


func _build() -> void:
	_intact = Node3D.new()
	_intact.name = "Intact"
	add_child(_intact)
	var material := _material(stone_color)
	var mesh: Mesh
	if kind == 1:
		var cylinder := CylinderMesh.new()
		cylinder.top_radius = dimensions.x * 0.39
		cylinder.bottom_radius = dimensions.x * 0.5
		cylinder.height = dimensions.y
		cylinder.radial_segments = 7
		mesh = cylinder
	else:
		mesh = StoneMesh.faceted_ellipsoid(1.0, 2.0, 9, 5, 0.19)
	var visual := MeshInstance3D.new()
	visual.mesh = mesh
	visual.material_override = material
	visual.position.y = dimensions.y * 0.5
	if kind == 0:
		visual.scale = dimensions * 0.5
	_intact.add_child(visual)
	_collision = CollisionShape3D.new()
	_collision.name = "CollisionShape3D"
	if kind == 1:
		var shape := CylinderShape3D.new()
		shape.radius = dimensions.x * 0.5
		shape.height = dimensions.y
		_collision.shape = shape
	else:
		# 与非均匀岩块网格同尺寸的凸碰撞；碰撞节点本身保持单位缩放。
		var arrays := mesh.surface_get_arrays(0)
		var points: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
		for i in range(points.size()):
			points[i] *= dimensions * 0.5
		var shape := ConvexPolygonShape3D.new()
		shape.points = points
		_collision.shape = shape
	_collision.position.y = dimensions.y * 0.5
	add_child(_collision)
	_rubble = Node3D.new()
	_rubble.name = "Rubble"
	_rubble.visible = false
	add_child(_rubble)
	for i in range(7):
		var chip := MeshInstance3D.new()
		chip.mesh = StoneMesh.chamfered_box(Vector3(0.35, 0.10, 0.28), 0.035)
		chip.material_override = material
		var angle := i * 2.39996
		chip.position = Vector3(cos(angle) * dimensions.x * 0.27, 0.05, sin(angle) * dimensions.z * 0.27)
		chip.rotation.y = angle
		_rubble.add_child(chip)
	# 可破坏残柱用石节接缝与暖色区别于完整灰墙。
	if kind == 1:
		for level in [0.32, 0.67]:
			var seam := MeshInstance3D.new()
			var ring := CylinderMesh.new()
			ring.top_radius = dimensions.x * (0.5 - level * 0.11) + 0.006
			ring.bottom_radius = ring.top_radius
			ring.height = 0.025
			ring.radial_segments = 7
			seam.mesh = ring
			seam.material_override = _material(stone_color.darkened(0.48))
			seam.position.y = dimensions.y * level
			_intact.add_child(seam)


func _material(color: Color) -> StandardMaterial3D:
	var material := StandardMaterial3D.new()
	material.albedo_color = color
	material.roughness = 0.95
	material.vertex_color_use_as_albedo = true
	return material
