extends CharacterBody3D
## 通用能力验收载体；空间逻辑全部来自 NavSteering，不按敌人名称分支。
const Steering := preload("res://scripts/nav_steering.gd")
const Query := preload("res://scripts/spatial_query.gd")
@export var combat_spatial_profile: Resource = preload("res://data/combat_spatial/ground.tres")
@export var move_speed := 3.0
@export var gravity := 20.0
@export var attack_reach := 1.4
@export var attack_requires_attachment := false
var target: Node3D
var steering := Steering.new()
var hits := 0
var _break_target: WeakRef
var _break_clock := 0.0
var _break_power := 0.0
var _hit_clock := 0.0

func _ready() -> void:
	collision_layer = 4
	collision_mask = 1
	var collision := CollisionShape3D.new()
	var shape := CapsuleShape3D.new()
	shape.radius = 0.25
	shape.height = 1.2
	collision.shape = shape
	add_child(collision)
	var visual := MeshInstance3D.new()
	var mesh := CapsuleMesh.new()
	mesh.radius = 0.25
	mesh.height = 1.2
	visual.mesh = mesh
	var material := StandardMaterial3D.new()
	material.albedo_color = Color(0.3, 0.85, 0.7)
	visual.material_override = material
	add_child(visual)
	steering.setup(self, 0.25, 1.2)
	steering.spatial.bind({"move_speed": move_speed, "gravity": gravity},
		{"can_attack": _can_attack, "attack_pose": _attack_pose, "break_action": _begin_break, "attached_action": _attached_attack})

func _physics_process(delta: float) -> void:
	_hit_clock -= delta
	if _break_target != null:
		_break_clock -= delta
		if _break_clock <= 0.0:
			var obstacle: Node3D = _break_target.get_ref()
			if is_instance_valid(obstacle):
				var point: Vector3 = obstacle.impact_point(global_position)
				if global_position.distance_to(point) <= 2.5:
					obstacle.break_from_impact(point, (point - global_position).normalized(), _break_power)
			_break_target = null
	if steering.tick(delta, _break_target == null, target, move_speed):
		return
	var desired := Vector3.ZERO
	if is_instance_valid(target):
		if _can_attack():
			_attached_attack(delta)
		else:
			var direction := target.global_position - global_position
			direction.y = 0
			desired = steering.ground_velocity(target.global_position, direction.normalized() * move_speed, delta)
	velocity.x = desired.x if _break_target == null else 0.0
	velocity.z = desired.z if _break_target == null else 0.0
	velocity.y = -0.5 if is_on_floor() else velocity.y - gravity * delta
	preload("res://scripts/ground_movement.gd").move(self, delta)

func _attack_pose(pose: Transform3D) -> bool:
	if attack_requires_attachment and pose.basis.y.normalized().dot(Vector3.DOWN) < 0.99:
		return false
	if not is_instance_valid(target) or pose.origin.distance_to(target.global_position) > attack_reach:
		return false
	return get_world_3d().direct_space_state.intersect_ray(PhysicsRayQueryParameters3D.create(pose.origin, target.global_position, 1)).is_empty()

func _can_attack() -> bool:
	return _attack_pose(global_transform)

func _attached_attack(_delta: float) -> void:
	if _hit_clock <= 0.0 and _can_attack():
		hits += 1
		_hit_clock = 0.5

func _begin_break(obstacle: Node3D, point: Vector3, ability: Resource) -> bool:
	if _break_target != null or global_position.distance_to(point) > ability.max_distance:
		return false
	_break_target = weakref(obstacle)
	_break_clock = maxf(ability.windup, 0.2)
	_break_power = ability.power
	steering.spatial._consume(ability)
	return true
