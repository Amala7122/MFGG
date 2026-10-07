@tool
class_name SpatialTraversalLink
extends Node3D
## 通用的模式转换连接。坐标与法向在连接局部空间，不绑定任何敌人。
@export var capability: StringName = &"climb"
@export var points := PackedVector3Array()
@export var normals := PackedVector3Array()
@export var bidirectional := true
@export var enabled := true
@export var attachable := true

func _ready() -> void:
	if not Engine.is_editor_hint():
		add_to_group("spatial_traversal_links")

func world_points(reverse := false) -> PackedVector3Array:
	var result := PackedVector3Array()
	for point in points:
		result.append(global_transform * point)
	if reverse:
		result.reverse()
	return result

func world_normals(reverse := false) -> PackedVector3Array:
	var result := PackedVector3Array()
	for normal in normals:
		result.append((global_basis * normal).normalized())
	if reverse:
		result.reverse()
	return result
