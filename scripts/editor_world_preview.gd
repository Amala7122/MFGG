@tool
extends Node3D
## 编辑器中的运行时世界预览。
## 生成节点不设置 owner，因此不会写入场景；运行游戏时本脚本不做任何事。

const TerrainScript := preload("res://scripts/terrain_field.gd")
const MapBuilderScript := preload("res://scripts/world_map_builder.gd")
const DecorScript := preload("res://scripts/world_decor.gd")
const GrassScript := preload("res://scripts/grass_field.gd")
const BackdropScript := preload("res://scripts/backdrop_landmark.gd")

const PREVIEW_ROOT := "__GeneratedWorldPreview"
const LEGACY_NODES := [
	"Ground", "Roads", "Lake", "AncientRuins", "EnemyCamp", "Forest", "WorldDecor", "Cover",
	"Grass"
]
## 这四个节点虽然由代码生成内容，但节点本身仍来自主场景。编辑器预览会隐藏它们，
## 正式运行时必须显式恢复；不能依赖编辑器退出时恰好把 visible 写回场景文件。
const RUNTIME_WORLD_NODES := ["Ground", "WorldDecor", "Cover", "Grass"]

@export var preview_generated_world := true:
	set(value):
		preview_generated_world = value
		_request_rebuild()

@export_tool_button("刷新生成场景预览") var refresh_preview: Callable = _request_rebuild


func _enter_tree() -> void:
	if Engine.is_editor_hint():
		call_deferred("_rebuild_preview")
	else:
		_set_runtime_world_visible()


func _exit_tree() -> void:
	if Engine.is_editor_hint():
		_set_legacy_visible(true)


func _request_rebuild() -> void:
	if Engine.is_editor_hint() and is_inside_tree():
		call_deferred("_rebuild_preview")


func _rebuild_preview() -> void:
	if not Engine.is_editor_hint() or not is_inside_tree():
		return
	var old := get_node_or_null(PREVIEW_ROOT)
	if old != null:
		old.free()
	_set_legacy_visible(not preview_generated_world)
	if not preview_generated_world:
		return

	var holder := Node3D.new()
	holder.name = PREVIEW_ROOT
	add_child(holder)

	var terrain := TerrainScript.new()
	terrain.name = "PreviewTerrain"
	terrain.editor_preview_enabled = true
	holder.add_child(terrain)

	var map_content := MapBuilderScript.new()
	map_content.name = "PreviewMapContent"
	holder.add_child(map_content)

	var decor := DecorScript.new()
	decor.name = "PreviewDecor"
	decor.editor_preview_enabled = true
	holder.add_child(decor)

	# 草是独立模块，预览也要单独挂一份（它自带 LOD / 踩踏逻辑，编辑器里不跑
	# _process，只会停在最近一级）。
	var grass := GrassScript.new()
	grass.name = "PreviewGrass"
	grass.editor_preview_enabled = true
	holder.add_child(grass)

	var backdrop := BackdropScript.new()
	backdrop.name = "PreviewBackdrop"
	holder.add_child(backdrop)


func _set_legacy_visible(wanted: bool) -> void:
	for node_name in LEGACY_NODES:
		var node := get_node_or_null(String(node_name)) as Node3D
		if node != null:
			node.visible = wanted


func _set_runtime_world_visible() -> void:
	for node_name in RUNTIME_WORLD_NODES:
		var node := get_node_or_null(String(node_name)) as Node3D
		if node != null:
			node.visible = true
