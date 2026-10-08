@tool
extends StaticBody3D

const LowPolyMeshUtil := preload("res://scripts/lowpoly_mesh.gd")

@export var pine := false

static var _broadleaf_mesh: ArrayMesh
static var _pine_mesh: ArrayMesh


func _ready() -> void:
	if pine:
		if _pine_mesh == null:
			_pine_mesh = LowPolyMeshUtil.faceted_cone(1.15, 2.35, 12)
		_assign_mesh(["CrownLow", "CrownHigh", "CrownTip"], _pine_mesh)
	else:
		if _broadleaf_mesh == null:
			_broadleaf_mesh = LowPolyMeshUtil.faceted_ellipsoid(1.0, 1.65, 14, 7, 0.16)
		_assign_mesh(["CrownLow", "CrownHigh", "CrownSide"], _broadleaf_mesh)


func _assign_mesh(names: Array[String], shared_mesh: ArrayMesh) -> void:
	for node_name in names:
		var instance := get_node_or_null(node_name) as MeshInstance3D
		if instance != null:
			instance.mesh = shared_mesh
