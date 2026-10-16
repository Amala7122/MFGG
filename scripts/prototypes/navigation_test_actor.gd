extends CharacterBody3D
## 导航测量体：没有攻击、技能、受击、死亡、投放或隐蔽行为。
const Steering := preload("res://scripts/nav_steering.gd")
const Ground := preload("res://scripts/ground_movement.gd")
const Query := preload("res://scripts/spatial_query.gd")
var steering: RefCounted
var target: Node3D
var speed := 4.0
var running := true
var spatial_enabled := true
var travelled := 0.0
var stationary_time := 0.0
var longest_stop := 0.0
var reached := false
var trail := PackedVector3Array()
var _previous := Vector3.ZERO
var _trail_timer := 0.0
var _reached_target := Vector3.ZERO

func _ready() -> void:
	steering = Steering.new()
	var dimensions := Query.dimensions(self)
	steering.setup(self, float(dimensions.radius), float(dimensions.half_height) * 2.0)
	steering.spatial.bind({"move_speed": speed}, {"can_attack": func(): return false})
	_previous = global_position

func _physics_process(delta: float) -> void:
	if not running or not is_instance_valid(target):
		return
	var offset := target.global_position - global_position
	offset.y = 0.0
	if target.global_position.distance_to(_reached_target) > 0.05:
		reached = false
	if not reached and offset.length() < 0.85:
		var here := Query.support(self, false)
		var there := Query.support(target, false)
		if not here.is_empty() and not there.is_empty() and absf(float(here.position.y) - float(there.position.y)) < 0.35:
			reached = Query.ground_segment(self, global_position, Query.body_on_floor(self, there), 0.3)
			if reached: _reached_target = target.global_position
	if reached:
		velocity = Vector3(0, -0.5, 0)
		Ground.move(self, delta)
	else:
		var overridden: bool = spatial_enabled and steering.tick(delta, true, target, speed)
		if not overridden:
			var desired := offset.normalized() * minf(speed, offset.length() / delta)
			var motion: Vector3 = steering.ground_velocity(target.global_position, desired, delta) if spatial_enabled else steering.raw_ground_velocity(target.global_position, desired, delta)
			if not spatial_enabled:
				motion = steering.spatial.gate_motion(motion, delta)
			velocity.x = motion.x
			velocity.z = motion.z
			velocity.y = -0.5 if is_on_floor() else velocity.y - 20.0 * delta
			Ground.move(self, delta)
	var displacement := Vector2(global_position.x - _previous.x, global_position.z - _previous.z).length()
	travelled += displacement
	stationary_time = stationary_time + delta if displacement < 0.002 and not reached else 0.0
	longest_stop = maxf(longest_stop, stationary_time)
	_previous = global_position
	_trail_timer -= delta
	if _trail_timer <= 0.0:
		_trail_timer = 0.15
		trail.append(global_position)
		if trail.size() > 600:
			trail.remove_at(0)

func snapshot() -> Dictionary:
	var spatial: RefCounted = steering.spatial
	return {"id": name, "position": [position.x, position.y, position.z], "reached": reached,
		"travelled": travelled, "longest_stop": longest_stop, "stationary": stationary_time,
		"status": spatial.status, "failure": spatial.last_failure,
		"reachable": not spatial.route.is_empty() or (steering.path_requests > 0 and steering.has_path()), "recovery": steering._state,
		"path_requests": steering.path_requests, "local_recoveries": spatial.recovery_count}
