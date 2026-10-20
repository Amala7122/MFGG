extends Node3D
## 弹道爆囊 / 直线晶束共用逐段扫掠；投射物只保留伤害快照，不持有敌人。
const FX := preload("res://scripts/combat_fx.gd")
const Telemetry := preload("res://scripts/combat_telemetry.gd")
const Targets := preload("res://scripts/targeting.gd")
const Area := preload("res://scripts/enemy_attack_area.gd")
const Puddle := preload("res://scripts/enemies/poison_puddle.gd")
var velocity := Vector3.ZERO
var gravity := 0.0
var damage := 0.0
var lifetime := 4.0
var blast_radius := 0.0
var blast_height := 2.5
var source_info: Dictionary = {}
var exploded := false
var _elapsed := 0.0
var _warning: Node3D
var _body: MeshInstance3D
var _poison_values: Dictionary = {}


static func lob_velocity(origin: Vector3, goal: Vector3, values: Dictionary) -> Vector3:
	var time := float(values.projectile_flight_time)
	return (goal - origin) / time + Vector3.UP * float(values.projectile_gravity) * time * 0.5


static func lob_points(origin: Vector3, goal: Vector3, values: Dictionary) -> PackedVector3Array:
	var points := PackedVector3Array()
	var launch := lob_velocity(origin, goal, values)
	for step in 49:
		var at := float(values.projectile_flight_time) * step / 48.0
		points.append(origin + launch * at + Vector3.DOWN * float(values.projectile_gravity) * at * at * 0.5)
	return points


static func lob_is_clear(context: Node3D, origin: Vector3, goal: Vector3, values: Dictionary) -> bool:
	var time := float(values.projectile_flight_time)
	var gravity_value := float(values.projectile_gravity)
	var launch := lob_velocity(origin, goal, values)
	var previous := origin
	var steps := maxi(ceili(time * 30.0), 4)
	for step in range(1, steps + 1):
		var at := time * float(step) / steps
		var next := origin + launch * at + Vector3.DOWN * gravity_value * at * at * 0.5
		var query := PhysicsRayQueryParameters3D.create(previous, next, 1)
		query.hit_from_inside = true
		var hit := context.get_world_3d().direct_space_state.intersect_ray(query)
		if not hit.is_empty():
			return step == steps and (hit.position as Vector3).distance_to(goal) < 0.1
		previous = next
	return true


func _ready() -> void:
	add_to_group("enemy_projectiles")


func configure_lob(origin: Vector3, goal: Vector3, values: Dictionary, info: Dictionary) -> void:
	global_position = origin
	gravity = float(values.projectile_gravity)
	var time := float(values.projectile_flight_time)
	velocity = lob_velocity(origin, goal, values)
	damage = float(values.attack_damage)
	blast_radius = float(values.blast_radius)
	blast_height = float(values.blast_height)
	lifetime = float(values.projectile_lifetime)
	_poison_values = values.duplicate(true)
	source_info = info.duplicate(true)
	_build_mesh(float(values.projectile_radius), Color(0.35, 1.0, 0.06))
	# 落点提前可见；只用一个平面环，不每帧烘焙地面网格。
	_warning = MeshInstance3D.new()
	var ring := TorusMesh.new()
	var warning_radius := blast_radius
	if float(values.poison_duration) > 0.0 and float(values.poison_damage) > 0.0:
		warning_radius = maxf(warning_radius, float(values.poison_radius))
	ring.inner_radius = maxf(warning_radius - 0.07, 0.05)
	ring.outer_radius = warning_radius
	ring.rings = 24
	ring.ring_segments = 6
	_warning.mesh = ring
	_warning.material_override = _material(Color(1, 0.25, 0.06, 0.8))
	get_parent().add_child(_warning)
	_warning.global_position = goal + Vector3.UP * 0.04


func configure_bolt(origin: Vector3, direction: Vector3, values: Dictionary, info: Dictionary) -> void:
	global_position = origin
	velocity = direction.normalized() * float(values.projectile_speed)
	damage = float(values.attack_damage)
	lifetime = float(values.projectile_lifetime)
	source_info = info.duplicate(true)
	_build_mesh(float(values.projectile_radius), Color(1.0, 0.32, 0.13))
	if not direction.is_zero_approx():
		look_at(origin + direction.normalized())
	_body.scale = Vector3(1, 1, 7)


func _build_mesh(radius: float, color: Color) -> void:
	_body = MeshInstance3D.new()
	var sphere := SphereMesh.new()
	sphere.radius = radius
	sphere.height = radius * 2.0
	sphere.radial_segments = 8
	sphere.rings = 4
	_body.mesh = sphere
	_body.material_override = _material(color)
	_body.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(_body)


func _material(color: Color) -> StandardMaterial3D:
	var mat := StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.albedo_color = color
	return mat


func _physics_process(delta: float) -> void:
	if exploded:
		return
	_elapsed += delta
	var destination := global_position + velocity * delta + Vector3.DOWN * gravity * delta * delta * 0.5
	var query := PhysicsRayQueryParameters3D.create(global_position, destination, 3)
	query.hit_from_inside = true
	var hit := get_world_3d().direct_space_state.intersect_ray(query)
	for observer: Node in get_tree().get_nodes_in_group("attack_inspection_observers"):
		observer.record_segment(get_instance_id(), global_position, hit.position if not hit.is_empty() else destination, int(source_info.get("inspection_actor_id", 0)))
	if not hit.is_empty():
		global_position = hit.position
		if blast_radius > 0:
			detonate()
		else:
			var actor := hit.collider as Node
			if actor != null and actor.is_in_group("player") and actor.has_method("take_damage"):
				Telemetry.hurt_player(actor, damage, global_position, 1.0, source_info)
			FX.spawn_impact(get_parent(), global_position, hit.normal, FX.COLOR_WORLD_HIT, 0.7)
			queue_free()
		return
	global_position = destination
	velocity.y -= gravity * delta
	if _elapsed >= lifetime:
		queue_free()


func detonate() -> void:
	if exploded:
		return
	exploded = true
	for actor: Node3D in Targets.living_players(self):
		var offset := actor.global_position - global_position
		if Vector2(offset.x, offset.z).length() <= blast_radius and absf(offset.y) <= blast_height and Area.unobstructed(self, global_position + Vector3.UP * 0.2, actor.global_position):
			Telemetry.hurt_player(actor, damage, global_position, 1.0, source_info)
	FX.spawn_ground_burst(get_parent(), global_position, blast_radius, false)
	if not _poison_values.is_empty():
		var pool := Puddle.new()
		get_parent().add_child(pool)
		pool.configure(global_position, _poison_values, source_info)
	queue_free()


func deflect() -> void:
	queue_free()


func _exit_tree() -> void:
	if is_instance_valid(_warning):
		_warning.queue_free()
