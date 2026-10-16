extends RefCounted
## Pure decision module: host owns navigation, movement and projectile spawning.
enum State { IDLE, TURN, THROW, RECOVER, RETREAT, DEAD }
var state := State.IDLE
var clock := 0.0
var cooldown := 0.0
var yaw := 0.0
var start_yaw := 0.0
var attack_yaw := 0.0
var fired := false

func reset() -> void:
	state = State.IDLE
	clock = 0.0
	cooldown = 0.0
	yaw = 0.0
	fired = false

func kill() -> void:
	state = State.DEAD
	fired = true

func update(delta: float, offset: Vector3, values: Dictionary, line_clear := true) -> Dictionary:
	var distance := Vector2(offset.x, offset.z).length()
	var away := -Vector3(offset.x, 0, offset.z).normalized()
	var throw_now := false
	cooldown = maxf(0.0, cooldown - delta)
	if state == State.DEAD:
		return output(Vector3.ZERO, false, values)
	# This check runs before any throw event, even on its exact release frame.
	if distance <= float(values.retreat_range):
		if state != State.RETREAT:
			state = State.RETREAT
			clock = 0.0
			fired = true
			cooldown = float(values.attack_interval)
	elif state == State.RETREAT and distance >= float(values.retreat_exit_range):
		state = State.IDLE
		clock = 0.0
	if state == State.RETREAT:
		clock += delta
		if away.length_squared() > 0.01:
			yaw = atan2(-away.x, -away.z)
		return output(away * float(values.retreat_speed), false, values)
	if state == State.IDLE and cooldown <= 0 and line_clear and distance <= float(values.attack_range):
		state = State.TURN
		clock = 0.0
		start_yaw = yaw
		attack_yaw = atan2(-offset.x, -offset.z) + deg_to_rad(float(values.turn_yaw))
		fired = false
	clock += delta
	if state == State.TURN:
		yaw = lerp_angle(start_yaw, attack_yaw, smoothstep(0.0, float(values.turn_duration), clock))
		if clock >= float(values.turn_duration):
			clock -= float(values.turn_duration)
			state = State.THROW
	if state == State.THROW:
		var snap := float(values.release) * float(values.release_snap_ratio)
		if not fired and clock >= snap:
			# Abort if player left the attack range or moved behind cover before release.
			throw_now = line_clear and distance <= float(values.attack_range)
			fired = true
		if clock >= float(values.release) + float(values.recovery):
			state = State.RECOVER
			clock = 0.0
	elif state == State.RECOVER:
		yaw = lerp_angle(attack_yaw, attack_yaw - deg_to_rad(float(values.turn_yaw)), smoothstep(0.0, float(values.windup), clock))
		if clock >= float(values.windup):
			state = State.IDLE
			cooldown = float(values.attack_interval)
			clock = 0.0
	return output(Vector3.ZERO, throw_now, values)

func output(velocity: Vector3, throw_now: bool, values: Dictionary) -> Dictionary:
	var action_time := 0.0
	if state == State.TURN:
		action_time = minf(clock, float(values.turn_duration))
	elif state == State.THROW:
		action_time = float(values.turn_duration) + clock
	elif state == State.RECOVER:
		action_time = float(values.turn_duration) + float(values.release) + float(values.recovery) + clock
	return {"state": state, "yaw": yaw, "velocity": velocity, "throw": throw_now, "action_time": action_time, "retreat_time": clock}
