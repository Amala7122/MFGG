class_name CombatSpatialProfile
extends Resource
const Capability := preload("res://scripts/traversal_capability.gd")
@export var capabilities: Array[Capability] = []
## 同层且直视时，让角色保留自己的绕行 / 攻击节奏；危险边界仍统一检查。
@export var preserve_ground_style := true
@export var replan_interval := 0.35
@export var target_replan_distance := 0.8
@export var safe_drop := 0.3
@export var max_escape_wait := 0.0
@export var reserve_escape := true
@export var exposure_weight := 1.0
@export var wait_cost := 1.0
@export var candidate_radius := 2.4
@export var retry_delay := 0.6
@export var maximum_expansions := 18
## 受阻时围住入口；搜索中心固定，不能逐次从当前位置向外退。
@export var rim_patrol_radius := 3.0
@export var rim_dwell_min := 1.5
@export var rim_dwell_max := 3.0
@export_range(0.0, 1.0) var rim_exposure_chance := 0.15
@export var rim_exposure_duration := 1.2
@export var threat_range_fallback := 120.0
@export var acceleration := 35.0
