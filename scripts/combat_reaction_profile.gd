class_name CombatReactionProfile
extends Resource
## 可赋予任意兼容角色。危险决策与受击位移独立配置，不读取敌人种类。

enum WarningResponse { HOLD, EVADE }
enum ImpactResponse { ANCHORED, KNOCKBACK, KNOCKDOWN }

@export var title := "战斗反应"
@export var warning_response: WarningResponse = WarningResponse.HOLD
@export var impact_response: ImpactResponse = ImpactResponse.ANCHORED
@export_group("感知与撤离")
@export_range(0.0, 60.0, 0.1) var perception_range := 16.0
@export_range(0.0, 3.0, 0.05) var reaction_delay := 0.2
@export_range(0.1, 4.0, 0.05) var escape_speed_multiplier := 1.5
@export_range(0.1, 3.0, 0.1) var safe_margin := 0.8
@export_group("冲击反应")
@export_range(0.0, 30.0, 0.1) var knockback_speed := 8.5
@export_range(0.05, 3.0, 0.05) var hit_duration := 0.6
@export_range(0.1, 40.0, 0.1) var impact_drag := 12.0
@export_range(1.0, 60.0, 0.1) var gravity := 24.0
@export_range(1.0, 30.0, 0.1) var fall_speed := 12.0
@export_range(0.0, 3.0, 0.05) var grounded_duration := 0.7
@export_range(0.1, 15.0, 0.1) var rise_speed := 5.5
