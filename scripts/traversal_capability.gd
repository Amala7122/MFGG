class_name TraversalCapability
extends Resource
## 能力定义由资源赋予；规划与执行均不读取物种 ID。
enum Kind { WALK, JUMP, BREAK, CLIMB, FLY, CUSTOM }
@export var id: StringName = &"walk"
@export var kind: Kind = Kind.WALK
@export var enabled := true
@export var cost_multiplier := 1.0
@export var max_distance := 12.0
@export var max_rise := 1.0
@export var max_drop := 1.0
@export var travel_speed := 10.0
@export var gravity := 20.0
@export var launch_speed_limit := 0.0
@export var min_flight := 0.35
@export var max_flight := 1.2
@export var windup := 0.15
@export var cooldown := 2.0
@export var power := 1.0
@export var contact_distance := 0.08
@export var max_turn_degrees := 100.0
## 可映射到角色既有参数与冷却；共享资源在运行时不修改。
@export var parameter_bindings: Dictionary = {}
@export var cooldown_channel: StringName

func resolved(values: Dictionary) -> TraversalCapability:
	var result := duplicate(true) as TraversalCapability
	for property: String in parameter_bindings:
		var key := String(parameter_bindings[property])
		if values.has(key):
			result.set(property, values[key])
	return result

## 新介质通行方式的扩展契约；没有真实规划 / 执行器时保持不可用。
func plan_custom(_body: CharacterBody3D, _points: PackedVector3Array, _normals: PackedVector3Array) -> Dictionary:
	return {}

func begin_custom(_body: CharacterBody3D, _plan: Dictionary) -> bool:
	return false

func step_custom(_body: CharacterBody3D, _plan: Dictionary, _delta: float) -> String:
	return "blocked"

func cancel_custom(_body: CharacterBody3D) -> void:
	pass
