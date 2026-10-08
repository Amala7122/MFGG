@tool
extends RefCounted
## 按需生成并缓存两套云形；默认切面版，圆润版完整保留供比较。

const Faceted := preload("res://scripts/cloud_mesh_library_faceted.gd")
const Rounded := preload("res://scripts/cloud_mesh_library_rounded.gd")
enum Style { FACETED, ROUNDED }
const VARIANT_COUNT := 6
static var _faceted_meshes: Array[ArrayMesh] = []
static var _faceted_version := 0


static func get_meshes(style: int = Style.FACETED) -> Array[ArrayMesh]:
	if style == Style.ROUNDED:
		return Rounded.get_meshes()
	if _faceted_meshes.is_empty() or _faceted_version != Faceted.GENERATION_VERSION:
		_faceted_meshes.clear()
		for variant in range(VARIANT_COUNT):
			_faceted_meshes.append(Faceted.build_cloud(variant))
		_faceted_version = Faceted.GENERATION_VERSION
	return _faceted_meshes


static func refresh_for_editor() -> void:
	if Engine.is_editor_hint():
		_faceted_meshes.clear()
		Rounded.refresh_for_editor()
