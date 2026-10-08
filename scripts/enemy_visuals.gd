class_name EnemyVisuals
extends RefCounted
## 敌人外观统一处理：护甲配色 + 整身受击闪光。
##
## 场景约定（两个敌人 .tscn 都必须遵守）：
##   1. 需要跟随 armor_color 的网格放进组 "tint"；
##   2. 所有 MeshInstance3D 的材质都必须是 StandardMaterial3D，
##      且每个 sub_resource 上都要写 resource_local_to_scene = true。
##      否则同一场景的多个敌人实例会共用同一份材质，
##      一个敌人被染色 / 被闪白，其余全部跟着变色。
##
## 之所以不用原来的「只改 Body 一个网格」，是因为新模型有二三十个部件，
## 只闪胸口看起来像穿帮。

const TINT_GROUP := "tint"

const FLASH_EMISSION := Color(1.0, 0.94, 0.62, 1.0)
const FLASH_ENERGY := 3.2

var _tint_meshes: Array[MeshInstance3D] = []
var _materials: Array[StandardMaterial3D] = []
var _base_emission_enabled: Array[bool] = []
var _base_emission: Array[Color] = []
var _base_energy: Array[float] = []
var _flashing := false


## 在 _ready() 里调用一次，收集模型下所有部件。
func register(model: Node3D) -> void:
	_tint_meshes.clear()
	_materials.clear()
	_base_emission_enabled.clear()
	_base_emission.clear()
	_base_energy.clear()
	if not model:
		return
	for child in model.find_children("*", "MeshInstance3D", true, false):
		var mesh := child as MeshInstance3D
		if not mesh:
			continue
		if mesh.is_in_group(TINT_GROUP):
			_tint_meshes.append(mesh)
		var material := mesh.material_override
		if material is StandardMaterial3D:
			_materials.append(material)
			_base_emission_enabled.append(material.emission_enabled)
			_base_emission.append(material.emission)
			_base_energy.append(material.emission_energy_multiplier)


## 统一设置护甲主色（组 "tint" 的全部网格）。
func apply_tint(color: Color) -> void:
	for mesh in _tint_meshes:
		var material := mesh.material_override
		if material is StandardMaterial3D:
			material.albedo_color = color


## 整身受击闪白；关闭时精确还原各材质原本的自发光设置。
func set_flash(active: bool) -> void:
	if active == _flashing:
		return
	_flashing = active
	for index in range(_materials.size()):
		var material := _materials[index]
		if active:
			material.emission_enabled = true
			material.emission = FLASH_EMISSION
			material.emission_energy_multiplier = FLASH_ENERGY
		else:
			material.emission_enabled = _base_emission_enabled[index]
			material.emission = _base_emission[index]
			material.emission_energy_multiplier = _base_energy[index]
