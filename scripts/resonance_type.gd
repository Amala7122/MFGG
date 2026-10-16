class_name ResonanceType
extends Resource
## 共鸣的目标策略数据。当前只启用范围清场型；以后新增单体型时换资源，
## 不再往 resonance.gd 里继续堆 Boss 特判。

enum TargetMode { AREA_CLEAR, SINGLE_TARGET }

@export var id: StringName = &"area_clear"
@export var display_name := "范围清场"
@export_enum("范围清场", "单体攻击") var target_mode: int = TargetMode.AREA_CLEAR
@export_range(0.0, 10.0, 0.05) var boss_damage_scale := 0.0
@export_range(0.0, 10.0, 0.05) var boss_push_scale := 0.0
@export_range(0.0, 10.0, 0.05) var boss_slow_scale := 0.0
@export var instant_kill_light := true
@export var overload_kills_large := true

