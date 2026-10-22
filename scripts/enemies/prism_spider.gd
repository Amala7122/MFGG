extends "res://scripts/enemies/crystal_creature_actor.gd"
const Projectile := preload("res://scripts/enemies/crystal_projectile.gd")
var aim_point := Vector3.ZERO
var aim_locked := false
var shots := 0
var _aim_line: MeshInstance3D
var _line_material: StandardMaterial3D


func profile_id() -> String:
	return "VisualPrismSpider"


func visual_scene() -> PackedScene:
	return preload("res://prototypes/visual_lab/prism_spider_visual.tscn")


static func get_body_dimensions(values: Dictionary = {}) -> Vector3:
	return Vector3(1.25 * float(values.get("abdomen_size", 1.0)), float(values.get("body_height", 0.92)) + 0.65, 2.25)


func _setup_species() -> void:
	_regions.add_part(self, visual.find_child("SingleCrystalEye", true, false), "body")
	_aim_line = MeshInstance3D.new()
	_aim_line.top_level = true
	var beam := BoxMesh.new()
	beam.size = Vector3(p("aim_line_width"), p("aim_line_width"), 1)
	_aim_line.mesh = beam
	_line_material = StandardMaterial3D.new()
	_line_material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	_line_material.albedo_color = Color(1, 0.4, 0.08)
	_aim_line.material_override = _line_material
	_aim_line.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_aim_line.visible = false
	add_child(_aim_line)


func trigger_attack() -> bool:
	if not Health.is_alive(target) or not _crowd.request_attack("snipe"):
		return false
	aim_point = target.global_position
	aim_locked = false
	set_state(State.AIM)
	return true


func can_attack_from(pose: Transform3D) -> bool:
	if not Health.is_alive(target): return false
	var distance := pose.origin.distance_to(target.global_position)
	return distance <= p("attack_range") and distance > p("retreat_range") and line_clear(target.global_position, pose * to_local(visual.focus.global_position))


func _think(delta: float) -> Vector3:
	var offset := target.global_position - global_position
	var distance := Vector2(offset.x, offset.z).length()
	if current_state == State.AIM:
		if state_timer < p("windup") - minf(p("aim_lock_time"), p("windup") * 0.8):
			aim_point = target.global_position
			face(aim_point, delta)
		else:
			aim_locked = true
		if not line_clear(aim_point, visual.focus.global_position):
			cancel_attack()
			cooldown = p("attack_interval")
			set_state(State.RECOVERY)
		elif state_timer >= p("windup"):
			_fire()
			set_state(State.RECOVERY)
		return Vector3.ZERO
	if current_state == State.RECOVERY:
		if state_timer >= p("release") + p("recovery"):
			_crowd.release_attack()
			set_state(State.IDLE)
		return Vector3.ZERO
	face(target.global_position, delta)
	if distance <= p("retreat_range") or (current_state == State.RETREAT and distance < p("retreat_exit_range")):
		set_state(State.RETREAT)
		return navigate(global_position - offset.normalized() * p("retreat_exit_range"), p("retreat_speed"), delta)
	if distance <= p("attack_range") and cooldown <= 0.0 and line_clear(target.global_position, visual.focus.global_position):
		if trigger_attack():
			return Vector3.ZERO
		if _crowd.waiting_for_attack():
			set_state(State.APPROACH)
			return _steering.spatial.gate_motion(_crowd.waiting_velocity(target.global_position, move_speed, delta), delta)
	if distance > p("preferred_distance") or not line_clear(target.global_position):
		set_state(State.APPROACH)
		return navigate(target.global_position, move_speed, delta)
	set_state(State.IDLE)
	return Vector3.ZERO


func _fire() -> void:
	var origin: Vector3 = visual.focus.global_position
	var projectile := Projectile.new()
	get_tree().current_scene.add_child(projectile)
	preload("res://scripts/enemy_attack_queue.gd").track_effect(self, projectile)
	projectile.configure_bolt(origin, aim_point - origin, _tuning, Telemetry.source_info(self, "棱眼锁向狙击"))
	shots += 1
	cooldown = p("attack_interval")
	_aim_line.visible = false
	Telemetry.enemy_attack_started(self, "棱眼锁向狙击")


func _pose(delta: float) -> void:
	if current_state in [State.AIM, State.RECOVERY]:
		visual.preview_pose = 2
		visual.sample_combat_pose(minf(state_timer if current_state == State.AIM else p("windup") + state_timer, p("windup") + p("release") + p("recovery") - 0.001))
	else:
		super(delta)
	_aim_line.visible = current_state == State.AIM
	if _aim_line.visible:
		var origin: Vector3 = visual.focus.global_position
		var endpoint := aim_point
		var ray := PhysicsRayQueryParameters3D.create(origin, endpoint, 1)
		var hit := get_world_3d().direct_space_state.intersect_ray(ray)
		if not hit.is_empty():
			endpoint = hit.position
		_aim_line.global_position = (origin + endpoint) * 0.5
		if origin.distance_to(endpoint) > 0.01:
			_aim_line.look_at(endpoint)
			_aim_line.scale.z = origin.distance_to(endpoint)
		_line_material.albedo_color = Color(1, 0.08, 0.025) if aim_locked else Color(1, 0.5, 0.08)


func cancel_attack() -> void:
	super()
	aim_locked = false
	if is_instance_valid(_aim_line):
		_aim_line.visible = false
