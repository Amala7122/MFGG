extends RefCounted
## 普通地面移动：薄板坡脚也是真实障碍，靠角色跨低坎通过，而不是修改地形。
const STEP_HEIGHT := 0.3


static func move(body: CharacterBody3D, delta: float, allow_step := true) -> bool:
	body.floor_snap_length = maxf(body.floor_snap_length, STEP_HEIGHT)
	var start := body.global_transform
	var grounded := body.is_on_floor()
	var requested := body.velocity
	var horizontal := Vector3(requested.x, 0, requested.z) * delta
	body.move_and_slide()
	if not allow_step or not grounded or requested.y > 0.01 or horizontal.length_squared() < 0.000001:
		return false
	var travelled := body.global_position - start.origin
	travelled.y = 0.0
	# 侧向滑动不等于跨过边缘；检查沿期望方向的推进，避免大平底身体擦边打转。
	if not body.is_on_wall() and travelled.dot(horizontal.normalized()) >= horizontal.length() * 0.9:
		return false
	var step := step_landing(body, start, horizontal)
	if step.is_empty():
		return false
	body.global_position = step.position
	body.velocity = Vector3(requested.x, 0, requested.z)
	body.apply_floor_snap()
	return true


static func step_landing(body: CharacterBody3D, start: Transform3D, horizontal: Vector3) -> Dictionary:
	if not body.test_move(start, horizontal):
		return {}
	# 撞边后的速度会被清零，加速首帧只有几毫米；落脚探针需越过碰撞圆角。
	# 仍扫掠完整身体，单次额外推进不超过 6cm。
	horizontal = horizontal.normalized() * maxf(horizontal.length(), 0.06)
	var up := body.up_direction * STEP_HEIGHT
	if body.test_move(start, up):
		return {}
	var raised := start
	raised.origin += up
	if body.test_move(raised, horizontal):
		return {}
	var ahead := raised
	ahead.origin += horizontal
	var query := PhysicsTestMotionParameters3D.new()
	query.from = ahead
	query.motion = -body.up_direction * (STEP_HEIGHT + 0.08)
	query.margin = body.safe_margin
	var result := PhysicsTestMotionResult3D.new()
	if not PhysicsServer3D.body_test_motion(body.get_rid(), query, result) or result.get_collision_count() == 0:
		return {}
	if result.get_collision_normal().dot(body.up_direction) < cos(body.floor_max_angle):
		return {}
	var landing := ahead.origin + result.get_travel()
	var rise := (landing - start.origin).dot(body.up_direction)
	if rise <= 0.02 or rise > STEP_HEIGHT + 0.001:
		return {}
	return {"position": landing}
