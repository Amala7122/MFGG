@tool
class_name PlayerFlashlight
extends Node3D
## 单个聚光灯照亮场景；局部雾只提供淡光柱，不参与地面补光。
## 参数可在 Player 场景的 FlashlightRig 节点上调整。

@export_category("照明颜色与方向")
@export var light_color := Color(1.0, 0.96, 0.84)
@export var source_offset := Vector3(0.48, 0.74, -1.05)
@export_range(-20.0, 35.0, 0.5) var downward_angle := 15.0

@export_category("中心亮斑")
@export_range(0.0, 60.0, 0.5) var core_energy := 10.0
@export_range(2.0, 60.0, 0.5) var core_range := 28.0
@export_range(5.0, 60.0, 0.5) var core_half_angle := 33.0
@export_range(0.0, 3.0, 0.05) var core_distance_falloff := 0.42
@export_range(0.0, 5.0, 0.05) var core_edge_falloff := 1.7
@export var core_casts_shadows := true

@export_category("局部光柱")
@export var beam_enabled := true
@export_range(0.001, 0.1, 0.001) var beam_density := 0.006
@export_range(0.0, 10.0, 0.1) var beam_scatter := 1.2
@export_range(5.0, 40.0, 0.5) var beam_length := 22.0
@export_range(2.0, 30.0, 0.5) var beam_width := 15.0

@onready var _core: SpotLight3D = $Core
@onready var _beam: FogVolume = $Beam


func _ready() -> void:
	_apply_parameters()
	set_process(Engine.is_editor_hint())


func _process(_delta: float) -> void:
	# 在 Inspector 改数值时即时预览；正式运行不做每帧属性写入。
	_apply_parameters()


func set_light_enabled(enabled: bool) -> void:
	visible = enabled


func is_light_enabled() -> bool:
	return visible


func _apply_parameters() -> void:
	if _core == null or _beam == null:
		return
	_core.position = source_offset
	_core.rotation_degrees.x = -downward_angle
	_core.light_color = light_color
	_core.light_energy = core_energy
	_core.spot_range = core_range
	_core.spot_angle = core_half_angle
	_core.spot_attenuation = core_distance_falloff
	_core.spot_angle_attenuation = core_edge_falloff
	_core.shadow_enabled = core_casts_shadows
	_core.light_volumetric_fog_energy = beam_scatter if beam_enabled else 0.0
	_beam.visible = beam_enabled
	_beam.position = source_offset + Vector3(0.0, -tan(deg_to_rad(downward_angle)) * beam_length * 0.5, -beam_length * 0.5)
	_beam.rotation_degrees.x = -downward_angle
	_beam.size = Vector3(beam_width, 8.0, beam_length)
	var fog := _beam.material as FogMaterial
	if fog != null:
		fog.density = beam_density
