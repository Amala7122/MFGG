extends Node
## 背景地景总管（autoload）：每次场景重建后，往场景里挂一份 backdrop_landmark。
##
## 为什么是 autoload 而不是场景里的节点：世界是每次换图重建的，做成场景节点
## 就得改 hyrule_field.tscn，而本项目当前没有编辑器可用（MCP 端口 9080 未监听），
## 硬改场景树的风险大于收益。
##
## 【必须同时用两条路找地形】—— 实测首个场景进树【早于】autoload 的 _ready()，
## 所以 node_added 永远看不到第一个 Ground（只连它的话，表现是"什么也没发生"）。
## 换图时场景是后加的，那时 node_added 才有效。两条都留。

const BackdropScript := preload("res://scripts/backdrop_landmark.gd")
const MapBuilderScript := preload("res://scripts/world_map_builder.gd")
const TerrainUtil := preload("res://scripts/terrain_field.gd")

const NODE_NAME := "Backdrop"


func _ready() -> void:
	call_deferred("_attach_first_scene")
	get_tree().node_added.connect(_on_node_added)


func _on_node_added(node: Node) -> void:
	if node is TerrainUtil:
		call_deferred("_attach", node)


func _attach_first_scene() -> void:
	var scene := get_tree().current_scene
	if scene == null:
		return
	var terrain := _find_terrain(scene)
	if terrain != null:
		_attach(terrain)


func _find_terrain(node: Node) -> Node:
	if node is TerrainUtil:
		return node
	for child in node.get_children():
		var found := _find_terrain(child)
		if found != null:
			return found
	return null


func _attach(terrain: Node) -> void:
	if not is_instance_valid(terrain):
		return
	var parent := terrain.get_parent()
	if parent == null or parent.has_node(NODE_NAME):
		return
	# 背景地景。与地形平级，因为它要读竞技场的 extent 与天空色。
	var backdrop := BackdropScript.new()
	backdrop.name = NODE_NAME
	parent.add_child(backdrop)
	# 地图内容（水体 / 道路 / 遗迹 / 营地 / 树簇）。统一按 height_at 落地，
	# 于是"陈设必须摆在 y≈0"这个隐含前提被彻底消除。
	var map_builder := MapBuilderScript.new()
	map_builder.name = "MapContent"
	parent.add_child(map_builder)
