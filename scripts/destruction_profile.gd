class_name DestructionProfile
extends Resource
## 可被多个场景共享的破坏材质；外形和碰撞由物件场景提供。
@export_range(0.0, 100.0, 0.1) var strength := 1.0
@export_range(1, 32, 1) var fragment_count := 14
@export_range(0.5, 10.0, 0.1) var fragment_lifetime := 4.0
@export var fragment_mesh: Mesh
@export var fragment_material: Material
@export var fragment_color := Color(0.53, 0.43, 0.31)
@export var fragment_size_ratio := Vector3(0.25, 0.20, 0.25)
@export var scatter_speed := Vector2(2.5, 5.5)
@export var lift_speed := Vector2(2.0, 4.8)
@export var dust_enabled := true
