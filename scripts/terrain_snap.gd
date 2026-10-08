extends Node3D
## 把这个节点的直接子节点贴合到地形高度。
##
## 场景里的树是按 y=0 的平地手工摆放的；换成高度场地形后，落在山丘上的树
## 会浮空或埋进土里（实测 Tree20 处地形已达 +2.08 米）。这里统一按
## TerrainField.height_at() 校正，避免逐个手改 22 个坐标。

const TerrainFieldUtil := preload("res://scripts/terrain_field.gd")


func _ready() -> void:
	# 树也是导航障碍：不登记的话敌人会直接穿过树干。
	add_to_group("nav_source")
	for child in get_children():
		if child is Node3D:
			var node := child as Node3D
			node.position.y = TerrainFieldUtil.height_at(node.position.x, node.position.z)
