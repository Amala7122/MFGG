@tool
extends Node3D

## 地面装饰（花 / 碎石 / 岩块 / 远景松）。它们都是"摆好就不动"的静态 MultiMesh。
##
## 【草不在这里】草有独立的模块：scripts/grass_field.gd + shaders/grass.gdshader。
## 它是场上唯一上万株、要逐帧按玩家位置切 LOD / 剔除 / 淡出、还要被角色踩开的
## 东西，塞在本脚本里会把这些逻辑全部埋掉。要调草去那边。
const TerrainFieldUtil := preload("res://scripts/terrain_field.gd")
const ArenaUtil := preload("res://scripts/arena.gd")
const ConfigUtil := preload("res://scripts/game_config.gd")
const LowPolyMeshUtil := preload("res://scripts/lowpoly_mesh.gd")

## 以下两个 @export 是【兜底值】：正常情况下数量与半径由竞技场决定
## （稀疏的采石场与茂密的湖畔不该用同一份密度）。
@export var flower_count: int = 120
@export var area_radius: float = 56.0

var _flower_count := 120
var _area_radius := 56.0
var _flower_seed := 93211
var _pebble_count := 90
var _pebble_seed := 51727
var _boulder_count := 0
var _distant_pine_count := 28
## 四种装饰共用的随机数发生器。
##
## 原先每个 create_* 各 new 一个 RandomNumberGenerator —— 若干份对象，却完全错开
## 使用（花摆完就再没人碰花那份）。它们只是要"各自的固定种子"，不是要各自的
## 实例，所以共用一份、进段前重设 seed 即可，输出与原来逐字节一致。
var _rng := RandomNumberGenerator.new()
## 竞技场参数缓存。保留区判定（湖 / 主路 / 遗迹）要用它。
var _arena: Dictionary = {}
@export var editor_preview_enabled := false


func _ready() -> void:
	if Engine.is_editor_hint() and not editor_preview_enabled:
		return
	_arena = ArenaUtil.get_params()
	_flower_seed = ConfigUtil.get_int("decor.flower_seed", 93211)
	_pebble_seed = ConfigUtil.get_int("decor.pebble_seed", 51727)
	_flower_count = maxi(int(_arena.get("flower_count", flower_count)), 0)
	_area_radius = maxf(float(_arena.get("decor_radius", area_radius)), 1.0)
	_pebble_count = maxi(int(_arena.get("pebble_count", 90)), 0)
	_boulder_count = maxi(int(_arena.get("boulder_count", 0)), 0)
	_distant_pine_count = maxi(int(_arena.get("distant_pine_count", 28)), 0)
	create_flowers()
	create_pebbles()
	create_boulders()
	create_distant_pines()


func create_flowers() -> void:
	var flower := SphereMesh.new()
	flower.radius = 0.085
	flower.height = 0.13
	flower.radial_segments = 5
	flower.rings = 2
	var flower_material := StandardMaterial3D.new()
	flower_material.albedo_color = Color(0.96, 0.72, 0.12, 1.0)
	flower_material.roughness = 1.0
	flower.material = flower_material
	var multimesh := MultiMesh.new()
	multimesh.transform_format = MultiMesh.TRANSFORM_3D
	multimesh.mesh = flower
	multimesh.instance_count = _flower_count
	var rng := _rng
	rng.seed = _flower_seed
	var placed := 0
	while placed < _flower_count:
		var x := rng.randf_range(-_area_radius, _area_radius)
		var z := rng.randf_range(-_area_radius, _area_radius)
		if is_reserved_area(x, z):
			continue
		multimesh.set_instance_transform(
			placed,
			Transform3D(Basis.IDENTITY, Vector3(x, TerrainFieldUtil.height_at(x, z) + 0.11, z))
		)
		placed += 1
	var flower_instance := MultiMeshInstance3D.new()
	flower_instance.multimesh = multimesh
	_mount(self, flower_instance, "Flowers")


func create_pebbles() -> void:
	if _pebble_count <= 0:
		return
	var pebble := SphereMesh.new()
	pebble.radius = 0.24
	pebble.height = 0.22
	pebble.radial_segments = 6
	pebble.rings = 3
	var material := StandardMaterial3D.new()
	material.albedo_color = Color(0.29, 0.285, 0.25, 1.0)
	material.roughness = 0.96
	pebble.material = material
	var multimesh := MultiMesh.new()
	multimesh.transform_format = MultiMesh.TRANSFORM_3D
	multimesh.mesh = pebble
	multimesh.instance_count = _pebble_count
	var rng := _rng
	rng.seed = _pebble_seed + String(_arena.get("_id", "")).hash()
	var placed := 0
	while placed < _pebble_count:
		var x := rng.randf_range(-_area_radius, _area_radius)
		var z := rng.randf_range(-_area_radius, _area_radius)
		if is_reserved_area(x, z):
			continue
		var size := rng.randf_range(0.55, 1.55)
		var pebble_basis := Basis(Vector3.UP, rng.randf_range(0.0, TAU)).scaled(
			Vector3(size * rng.randf_range(0.8, 1.35), size * rng.randf_range(0.55, 0.9), size)
		)
		multimesh.set_instance_transform(
			placed,
			Transform3D(pebble_basis, Vector3(x, TerrainFieldUtil.height_at(x, z) + 0.055, z))
		)
		placed += 1
	var instance := MultiMeshInstance3D.new()
	instance.multimesh = multimesh
	_mount(self, instance, "GroundPebbles")


## 中型岩块负责前景构图与尺度感。视觉仍由一个 MultiMesh 批量绘制，
## 但每块岩石都有简化碰撞盒，并登记为导航障碍，避免玩家和敌人穿过去。
func create_boulders() -> void:
	if _boulder_count <= 0:
		return
	var boulder := LowPolyMeshUtil.faceted_ellipsoid(1.0, 2.0, 12, 6, 0.18)
	var material := StandardMaterial3D.new()
	material.albedo_color = Color(0.34, 0.33, 0.285, 1.0)
	material.vertex_color_use_as_albedo = true
	material.vertex_color_is_srgb = true
	material.roughness = 0.97
	boulder.surface_set_material(0, material)
	var multimesh := MultiMesh.new()
	multimesh.transform_format = MultiMesh.TRANSFORM_3D
	multimesh.mesh = boulder
	multimesh.instance_count = _boulder_count
	var holder := StaticBody3D.new()
	holder.name = "FieldBoulders"
	holder.add_to_group("nav_source")
	var rng := _rng
	rng.seed = 36871 + String(_arena.get("_id", "")).hash()
	var placed := 0
	while placed < _boulder_count:
		var angle := rng.randf_range(0.0, TAU)
		var distance := sqrt(rng.randf_range(0.18, 1.0)) * _area_radius * 0.94
		var x := cos(angle) * distance
		var z := sin(angle) * distance
		if is_reserved_area(x, z):
			continue
		var size := rng.randf_range(0.72, 1.85)
		var stretch_x := rng.randf_range(0.9, 1.45)
		var stretch_z := rng.randf_range(0.78, 1.28)
		var yaw := rng.randf_range(0.0, TAU)
		var surface := TerrainFieldUtil.height_at(x, z)
		var rock_basis := Basis(Vector3.UP, yaw).scaled(Vector3(
			size * stretch_x, size * rng.randf_range(0.48, 0.72), size * stretch_z
		))
		multimesh.set_instance_transform(
			placed,
			Transform3D(rock_basis, Vector3(x, surface + size * 0.55, z))
		)
		var collision_shape := BoxShape3D.new()
		collision_shape.size = Vector3(
			size * stretch_x * 1.65, size * 0.95, size * stretch_z * 1.65
		)
		var collision := CollisionShape3D.new()
		collision.name = "BoulderCollision_%02d" % placed
		collision.shape = collision_shape
		collision.position = Vector3(x, surface + size * 0.48, z)
		collision.rotation.y = yaw
		holder.add_child(collision)
		placed += 1
	# 【岩块保留投影】它有碰撞体、是场上的实体障碍（见 create_boulders 的注释），
	# 在地上有影子才立得住；而下面那些贴地装饰一律关掉（见 _mount）。
	var instance := MultiMeshInstance3D.new()
	instance.name = "BoulderBatch"
	instance.multimesh = multimesh
	holder.add_child(instance)
	add_child(holder)


## 远处松树只有视觉网格，不带碰撞、也不进入 nav_source。
func create_distant_pines() -> void:
	if _distant_pine_count <= 0:
		return
	var crown := CylinderMesh.new()
	crown.top_radius = 0.04
	crown.bottom_radius = 1.05
	crown.height = 2.8
	crown.radial_segments = 10
	var material := StandardMaterial3D.new()
	material.albedo_color = Color(0.085, 0.29, 0.12, 1.0)
	material.roughness = 0.94
	crown.material = material
	var multimesh := MultiMesh.new()
	multimesh.transform_format = MultiMesh.TRANSFORM_3D
	multimesh.mesh = crown
	multimesh.instance_count = _distant_pine_count
	var rng := _rng
	rng.seed = 77621 + String(_arena.get("_id", "")).hash()
	var placed := 0
	while placed < _distant_pine_count:
		var angle := TAU * float(placed) / float(_distant_pine_count) + rng.randf_range(-0.22, 0.22)
		var distance := rng.randf_range(_area_radius * 0.56, _area_radius * 0.96)
		var x := cos(angle) * distance
		var z := sin(angle) * distance
		if is_reserved_area(x, z):
			continue
		var size := rng.randf_range(0.9, 1.75)
		var pine_basis := Basis(Vector3.UP, rng.randf_range(0.0, TAU)).scaled(
			Vector3(size, size * rng.randf_range(1.0, 1.35), size)
		)
		multimesh.set_instance_transform(
			placed,
			Transform3D(
				pine_basis,
				Vector3(x, TerrainFieldUtil.height_at(x, z) + 1.4 * size, z)
			)
		)
		placed += 1
	var instance := MultiMeshInstance3D.new()
	instance.multimesh = multimesh
	_mount(self, instance, "DistantPines")


## 挂一个装饰用 MultiMeshInstance3D，并关掉它的投影。
##
## 花 / 碎石 / 远景松都是贴地的纯装饰：花 120 朵、碎石 90 块，
## 高不过十几厘米，影子在画面里几乎看不见，却要在阴影 pass 里按实例数【再画
## 一遍】。关掉之后阴影 pass 只剩下角色、敌人与岩块（岩块有碰撞体、是场上的
## 实体，保留投影）。
## （草曾经也走这里，现在归 grass_field.gd 自己管，那边同样关投影。）
func _mount(parent: Node, instance: MultiMeshInstance3D, node_name: String) -> void:
	instance.name = node_name
	instance.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	parent.add_child(instance)


## 保留区（湖 / 主路 / 遗迹 …）由竞技场定义 —— 原先这里写死了三处矩形，
## 换竞技场后会与实际地形脱钩，草就会长到水面上。
func is_reserved_area(x: float, z: float) -> bool:
	return ArenaUtil.is_masked_out(_arena, x, z)
