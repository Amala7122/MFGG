@tool
extends Node3D
## 天气实验场专用：地面陈列六种实际基础网格，编辑器与运行时都可查看。

const Library := preload("res://scripts/cloud_mesh_library.gd")
const Terrain := preload("res://scripts/terrain_field.gd")
const CloudShader := preload("res://shaders/procedural_cloud.gdshader")
const NAMES := ["01 隆起云", "02 弯尾云", "03 分叉云", "04 宽团云", "05 斜坡云", "06 长带云"]
const GENERATED := "__CloudModels"
var _build_pending := false
var _displayed_style := -1

@export var gallery_enabled := true:
	set(value):
		gallery_enabled = value
		_request_build()
@export_range(0.01, 0.08, 0.005) var display_scale := 0.04:
	set(value):
		display_scale = value
		_request_build()
@export_tool_button("刷新基础云形和陈列") var refresh_gallery: Callable = _refresh_models


func _ready() -> void:
	set_process(true)
	_request_build()


func _process(_delta: float) -> void:
	var model := get_node_or_null(GENERATED + "/Cloud01/Model") as MeshInstance3D
	var style := _weather_style()
	if gallery_enabled and (model == null or style != _displayed_style or model.mesh != Library.get_meshes(style)[0]):
		_request_build()


func _weather_style() -> int:
	var weather := get_node_or_null("../WeatherEnvironment/WeatherSystem")
	return int(weather.get("cloud_shape_style")) if weather != null else Library.Style.FACETED


func _refresh_models() -> void:
	Library.refresh_for_editor()
	_request_build()


func _request_build() -> void:
	if is_inside_tree() and not _build_pending:
		_build_pending = true
		call_deferred("_build")


func _build() -> void:
	_build_pending = false
	var old := get_node_or_null(GENERATED)
	if old != null:
		old.free()
	if not gallery_enabled:
		return
	var holder := Node3D.new()
	holder.name = GENERATED
	add_child(holder)
	var material := ShaderMaterial.new()
	material.shader = CloudShader
	material.set_shader_parameter("cloud_tint", Color(0.78, 0.82, 0.86))
	material.set_shader_parameter("cloud_density", 0.25)
	var base_material := StandardMaterial3D.new()
	base_material.albedo_color = Color(0.22, 0.27, 0.29)
	base_material.roughness = 1.0
	_displayed_style = _weather_style()
	var meshes := Library.get_meshes(_displayed_style)
	for index in range(meshes.size()):
		var x := float(index % 3 - 1) * 17.0
		# 出生点后方的空地，避开遗迹低墙和中央庭院。
		var z := 58.0 + float(index / 3) * 17.0
		var ground := Terrain.height_at(global_position.x + x, global_position.z + z) - global_position.y
		var stand := Node3D.new()
		stand.name = "Cloud%02d" % (index + 1)
		stand.position = Vector3(x, ground, z)
		holder.add_child(stand)
		var plinth := MeshInstance3D.new()
		plinth.name = "Plinth"
		var cylinder := CylinderMesh.new()
		cylinder.top_radius = 6.0
		cylinder.bottom_radius = 6.15
		cylinder.height = 2.2
		cylinder.radial_segments = 32
		plinth.mesh = cylinder
		plinth.material_override = base_material
		plinth.position.y = 1.1
		stand.add_child(plinth)
		var model := MeshInstance3D.new()
		model.name = "Model"
		model.mesh = meshes[index]
		model.material_override = material
		model.scale = Vector3.ONE * display_scale
		var bounds := meshes[index].get_aabb()
		var center := bounds.get_center()
		model.position = Vector3(-center.x * display_scale,
			2.30 - bounds.position.y * display_scale, -center.z * display_scale)
		model.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		stand.add_child(model)
		var label := Label3D.new()
		label.name = "Name"
		label.text = NAMES[index]
		label.position = Vector3(0.0, 3.0 + bounds.size.y * display_scale, 0.0)
		label.font_size = 96
		label.pixel_size = 0.012
		label.modulate = Color(0.90, 0.94, 0.98)
		label.outline_modulate = Color(0.08, 0.12, 0.15)
		label.billboard = BaseMaterial3D.BILLBOARD_ENABLED
		stand.add_child(label)
