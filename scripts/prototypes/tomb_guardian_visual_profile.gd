class_name TombGuardianVisualProfile
extends Resource
## 可另存为 .tres 复用的镇墓兽外形预设。
@export_group("比例")
@export_range(0.5, 2.0, 0.05) var body_size := 1.0
@export_range(0.8, 1.3, 0.025) var head_size := 1.0
@export_range(0.7, 1.3, 0.025) var horn_height := 1.0
@export_range(0.7, 1.3, 0.025) var horn_spread := 1.0
@export_range(0.8, 1.3, 0.025) var shoulder_width := 1.0
@export_group("釉陶")
@export var jade_color := Color("315132")
@export var amber_color := Color("a46627")
@export var ivory_color := Color("dfd0a5")
@export_range(0.0, 1.0, 0.05) var patina_amount := 0.8
@export_range(0.2, 0.95, 0.05) var glaze_roughness := 0.53
@export_range(0.0, 3.0, 0.1) var eye_energy := 0.8
@export_group("展示动作")
@export_range(0.2, 2.0, 0.05) var animation_speed := 1.0
@export_range(0.0, 0.4, 0.01) var resting_jaw_open := 0.025
@export_range(0.05, 0.5, 0.01) var threat_jaw_open := 0.18
