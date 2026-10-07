@tool
extends Node3D
## 可整组实例化的固定空间预设。视觉网格和静态碰撞使用相同尺寸。

const FLOOR_COLOR := Color(0.38, 0.43, 0.40)
const OBSTACLE_COLOR := Color(0.55, 0.51, 0.40)
const PLATFORM_COLOR := Color(0.43, 0.55, 0.57)
const LABEL_FONT := preload("res://theme/fonts/NotoSansSC-wght.ttf")
const DestructibleProp := preload("res://scripts/destructible_prop.gd")
const SmallTree := preload("res://prototypes/combat/spatial/props/small_tree.tscn")
const LowWall := preload("res://prototypes/combat/spatial/props/low_wall.tscn")
signal destruction_changed

func _ready() -> void:
	if has_node("Geometry"):
		return
	var geometry := Node3D.new()
	geometry.name = "Geometry"
	add_child(geometry)
	_box(geometry, "MainFloor", Vector3(0, -0.5, 2), Vector3(44, 1, 32), FLOOR_COLOR)
	_box(geometry, "NorthFloor", Vector3(-7, -0.5, -18), Vector3(30, 1, 8), FLOOR_COLOR)
	_box(geometry, "FarLedge", Vector3(15, -0.5, -21.5), Vector3(14, 1, 3), PLATFORM_COLOR)
	_box(geometry, "PitFloor", Vector3(15, -5.5, -17), Vector3(14, 1, 6), Color(0.22, 0.28, 0.29))
	_box(geometry, "CliffBridge", Vector3(19, -0.25, -17), Vector3(3.2, 0.5, 6), PLATFORM_COLOR)
	_box(geometry, "SouthWall", Vector3(0, 1.5, 18.5), Vector3(46, 3, 1), OBSTACLE_COLOR)
	_box(geometry, "NorthWall", Vector3(0, 1.5, -23), Vector3(46, 3, 1), OBSTACLE_COLOR)
	for side in [-1.0, 1.0]:
		_box(geometry, "SideWall", Vector3(side * 22.5, -1, -2), Vector3(1, 8, 42), OBSTACLE_COLOR)
	_box(geometry, "SlopeLanding", Vector3(-12, 1, -0.5), Vector3(6, 2, 5), PLATFORM_COLOR)
	_box(geometry, "Slope", Vector3(-12, 1, 5), Vector3(6, 0.3, sqrt(40.0)), PLATFORM_COLOR, Vector3(atan(1.0 / 3.0), 0, 0))
	_box(geometry, "Step1m", Vector3(-5, 0.5, -5), Vector3(6, 1, 5), OBSTACLE_COLOR)
	_box(geometry, "SmallPlatform", Vector3(-10, 0.75, -15), Vector3(1.2, 1.5, 1.2), PLATFORM_COLOR)
	_box(geometry, "Platform2m", Vector3(6, 1, -5), Vector3(6, 2, 5), PLATFORM_COLOR)
	_box(geometry, "PlatformRamp", Vector3(12, 1, -5), Vector3(sqrt(40.0), 0.3, 4), PLATFORM_COLOR, Vector3(0, 0, -atan(1.0 / 3.0)))
	_box(geometry, "CoverLong", Vector3(8, 1.2, 6), Vector3(0.6, 2.4, 5), OBSTACLE_COLOR)
	_box(geometry, "CoverCorner", Vector3(10, 1.2, 3.8), Vector3(4, 2.4, 0.6), OBSTACLE_COLOR)
	for x in [-20.0, -16.0]:
		_box(geometry, "NarrowWall", Vector3(x, 1.25, 3), Vector3(0.6, 2.5, 10), OBSTACLE_COLOR)
	_prop(geometry, "BreakableRock", Vector3(-9, 0, 12), Vector3(2.2, 1.6, 2.0), 0)
	_prop(geometry, "BreakablePillar", Vector3(-5.5, 0, 11.5), Vector3(1.35, 3.2, 1.35), 1)
	_authored_prop(geometry, SmallTree, Vector3(-12.8, 0, 13))
	_authored_prop(geometry, LowWall, Vector3(-12, 0, 16.5))
	_label("平地 · 贴脸 / 横移射击", Vector3(0, 0.2, 8))
	_label("坡道 · 约 18°", Vector3(-12, 2.25, -0.5))
	_label("1 米台阶", Vector3(-5, 1.25, -5))
	_label("小台面 · 跳跃普攻", Vector3(-10, 1.75, -15))
	_label("2 米平台 · 右侧可绕坡", Vector3(6, 2.25, -5))
	_label("掩体角 · 枪口阻挡", Vector3(10, 2.65, 5))
	_label("窄路 · 净宽 3.4 米", Vector3(-18, 2.8, 3))
	_label("悬崖 · 落差 5 米 / 右侧桥", Vector3(13, 0.3, -13))
	_label("石块 / 残柱 / 小树 / 矮墙 · 可破坏", Vector3(-9.5, 3.7, 14))
	var stripe_color := Color(0.84, 0.64, 0.30)
	for x in range(-20, 21, 5):
		_mark(geometry, Vector3(x, 0.015, 12), Vector3(0.025, 0.01, 10), Color(0.47, 0.53, 0.48))
	_mark(geometry, Vector3(0, 0.025, -9), Vector3(36, 0.02, 0.12), stripe_color)
	for z in [9.0, 7.0, 5.0, 2.0]:
		_mark(geometry, Vector3(0, 0.025, z), Vector3(4, 0.02, 0.07), Color(0.40, 0.78, 0.74))


func _prop(parent: Node3D, label: String, at: Vector3, dimensions: Vector3, kind: int) -> void:
	var prop := DestructibleProp.new()
	prop.name = label
	prop.position = at
	prop.dimensions = dimensions
	prop.kind = kind
	prop.broken.connect(func(_prop: StaticBody3D): destruction_changed.emit())
	parent.add_child(prop)


func _authored_prop(parent: Node3D, scene: PackedScene, at: Vector3) -> void:
	var prop := scene.instantiate() as Node3D
	prop.position = at
	if not Engine.is_editor_hint():
		prop.get_node("Destructible").broken.connect(func(_component: Node3D): destruction_changed.emit())
	parent.add_child(prop)


func reset_destructibles() -> void:
	var changed := false
	for prop: Node in get_tree().get_nodes_in_group("destructible_props"):
		if is_ancestor_of(prop) and prop.is_broken:
			prop.reset_destruction()
			changed = true
	if changed:
		destruction_changed.emit()


func _box(parent: Node3D, label: String, at: Vector3, dimensions: Vector3, color: Color, angles := Vector3.ZERO) -> void:
	var body := StaticBody3D.new()
	body.name = label
	body.position = at
	body.rotation = angles
	body.collision_layer = 1
	body.collision_mask = 0
	parent.add_child(body)
	var collision := CollisionShape3D.new()
	collision.name = "CollisionShape3D"
	var shape := BoxShape3D.new()
	shape.size = dimensions
	collision.shape = shape
	body.add_child(collision)
	_mark(body, Vector3.ZERO, dimensions, color)


func _mark(parent: Node3D, at: Vector3, dimensions: Vector3, color: Color) -> void:
	var visual := MeshInstance3D.new()
	var mesh := BoxMesh.new()
	mesh.size = dimensions
	var material := StandardMaterial3D.new()
	material.albedo_color = color
	material.roughness = 0.95
	mesh.material = material
	visual.mesh = mesh
	visual.position = at
	parent.add_child(visual)


func _label(text: String, at: Vector3) -> void:
	var label := Label3D.new()
	label.text = text
	label.position = at
	label.font_size = 36
	label.font = LABEL_FONT
	label.pixel_size = 0.02
	label.modulate = Color(1.0, 0.89, 0.65)
	label.outline_modulate = Color(0.10, 0.15, 0.13)
	label.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	add_child(label)
