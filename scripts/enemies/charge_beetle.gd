extends "res://scripts/enemies/crystal_creature_actor.gd"
var charge_direction := Vector3.FORWARD
var charge_origin := Vector3.ZERO
var charge_locked := false
var charge_hits := 0
var charges := 0
var _spent := false
var _contact := false
var _recovery_time := 0.0
var _lane: Node3D


func profile_id() -> String:
	return "VisualChargeBeetle"


func visual_scene() -> PackedScene:
	return preload("res://prototypes/visual_lab/charge_beetle_visual.tscn")


static func get_body_dimensions(values: Dictionary = {}) -> Vector3:
	return Vector3(float(values.get("shell_width", 2.45)) * 0.87, 1.08 + float(values.get("shell_height", 1.35)) * 0.5, float(values.get("shell_length", 2.75)) * 0.95)


func _setup_species() -> void:
	_regions.add_part(self, visual.find_child("ShovelHorn", true, false), "body")
	_lane = AttackArea.new()
	add_child(_lane)


func trigger_attack() -> bool:
	if not Health.is_alive(target):
		return false
	var distance := global_position.distance_to(target.global_position)
	if distance < p("charge_min_range") and distance > p("contact_range"):
		return false
	if not _crowd.request_attack():
		return false
	_contact = distance < p("charge_min_range")
	charge_locked = false
	_spent = false
	_recovery_time = p("recovery")
	set_state(State.WINDUP)
	_lane.prepare(_warning_pose(), attack_debug_spec(_contact), attack_damage, p("contact_windup") if _contact else p("windup"))
	return true


func attack_debug_spec(contact := false) -> Dictionary:
	var dimensions: Vector3 = get_body_dimensions(_tuning) * scale
	return {"kind": "circle", "radius": p("contact_range"), "height": p("contact_range")} if contact else {"kind": "rect", "width": dimensions.x, "length": p("charge_distance") + dimensions.z * 0.5 + p("charge_front_reach"), "height": p("charge_hit_height"), "stable_tracking_surface": true}


func can_attack_from(pose: Transform3D) -> bool:
	if not super(pose): return false
	var offset := target.global_position - pose.origin
	if offset.length() < p("charge_min_range"):
		# 顶撞与冲锋起步之间可能有距离空档，必须继续靠近，不能原地空打。
		return offset.length() <= p("contact_range")
	offset.y = 0.0
	var facing := pose
	facing.basis = Basis(Vector3.UP, atan2(-offset.x, -offset.z)).scaled(pose.basis.get_scale())
	facing.origin += Vector3.UP * Ground.STEP_HEIGHT
	return SpatialQuery.motion_clear(self, facing, offset)


func _warning_pose() -> Transform3D:
	var pose := global_transform.orthonormalized()
	pose.origin.y -= _collision.shape.size.y * scale.y * 0.5
	return pose


func _think(delta: float) -> Vector3:
	var offset := target.global_position - global_position
	var distance := Vector2(offset.x, offset.z).length()
	if current_state == State.WINDUP:
		var windup := p("contact_windup") if _contact else p("windup")
		if state_timer < windup - minf(p("aim_lock_time"), windup * 0.8):
			face(target.global_position, delta)
			charge_direction = -global_basis.z.normalized()
			_lane.track(_warning_pose())
		else:
			charge_locked = true
			_lane.lock()
		if state_timer >= windup:
			_lane.cancel()
			if _contact:
				_contact_strike()
				_finish_charge(false)
			else:
				charge_origin = global_position
				charges += 1
				Telemetry.enemy_attack_started(self, "裂甲锁向冲锋")
				set_state(State.CHARGE)
		return Vector3.ZERO
	if current_state == State.CHARGE:
		if state_timer >= p("charge_timeout") or global_position.distance_to(charge_origin) >= p("charge_distance"):
			_finish_charge(false)
			return Vector3.ZERO
		var forward_reach: float = _collision.shape.size.z * scale.z * 0.5 + p("charge_front_reach")
		var wall_ray := PhysicsRayQueryParameters3D.create(global_position, global_position + charge_direction * (forward_reach + p("charge_speed") * delta), 1)
		var wall := get_world_3d().direct_space_state.intersect_ray(wall_ray)
		if not wall.is_empty() and (wall.normal as Vector3).y < 0.55:
			_finish_charge(true)
			return Vector3.ZERO
		var safe: Vector3 = _steering.spatial.gate_motion(charge_direction * p("charge_speed"), delta)
		if safe.length() < p("charge_speed") * 0.8 or safe.normalized().dot(charge_direction) < 0.95:
			_finish_charge(true)
			return Vector3.ZERO
		return charge_direction * p("charge_speed")
	if current_state == State.RECOVERY:
		if state_timer >= _recovery_time:
			_crowd.release_attack()
			set_state(State.IDLE)
		return Vector3.ZERO
	face(target.global_position, delta)
	if cooldown <= 0.0 and can_attack_from(global_transform):
		if trigger_attack():
			return Vector3.ZERO
	set_state(State.APPROACH)
	return navigate(target.global_position, move_speed, delta)


func _after_move(previous: Vector3, _delta: float) -> void:
	if current_state != State.CHARGE:
		return
	if not _spent:
		var sweep := BoxShape3D.new()
		var dimensions: Vector3 = _collision.shape.size * scale.abs()
		var moved := global_position.distance_to(previous)
		sweep.size = Vector3(dimensions.x, p("charge_hit_height"), dimensions.z + p("charge_front_reach") + moved)
		var query := PhysicsShapeQueryParameters3D.new()
		query.shape = sweep
		query.collision_mask = 2
		query.transform = Transform3D(global_basis.orthonormalized(), (previous + global_position) * 0.5 + charge_direction * p("charge_front_reach") * 0.5)
		for hit: Dictionary in get_world_3d().direct_space_state.intersect_shape(query):
			var actor := hit.collider as Node3D
			if actor != null and actor.is_in_group("player") and line_clear(actor.global_position):
				_spent = true
				charge_hits += 1
				Telemetry.hurt_player(actor, attack_damage, global_position, 1.0, Telemetry.source_info(self, "裂甲冲锋接触"))
				_finish_charge(false)
				break
	if is_on_wall():
		_finish_charge(true)


func _contact_strike() -> void:
	if Health.is_alive(target) and global_position.distance_to(target.global_position) <= p("contact_range") and line_clear(target.global_position):
		Telemetry.hurt_player(target, p("contact_damage") * _crowd.damage_multiplier, global_position, 1.0, Telemetry.source_info(self, "近身顶撞"))
		Telemetry.enemy_attack_started(self, "近身顶撞")


func _finish_charge(wall: bool) -> void:
	velocity.x = 0.0
	velocity.z = 0.0
	_recovery_time = p("wall_recovery") if wall else p("recovery")
	cooldown = p("attack_interval")
	_lane.cancel()
	set_state(State.RECOVERY)


func _pose(delta: float) -> void:
	if current_state in [State.WINDUP, State.CHARGE, State.RECOVERY]:
		visual.preview_pose = 2
		var at := state_timer
		if current_state == State.WINDUP and _contact:
			at = state_timer / p("contact_windup") * p("windup")
		elif current_state == State.CHARGE:
			at = p("windup") + p("release") * 0.5
		elif current_state == State.RECOVERY:
			at = p("windup") + p("release") + minf(state_timer, p("recovery") - 0.001)
		visual.sample_pose(at)
		# 实际位移属于 CharacterBody；去掉原外形的展示冲刺偏移，不能跑两遍。
		visual.rig.position.z = 0.0
	else:
		super(delta)


func cancel_attack() -> void:
	super()
	if is_instance_valid(_lane):
		_lane.cancel()
