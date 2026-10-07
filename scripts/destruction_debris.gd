extends Node3D
## 预制碎块轨迹只负责表现；没有刚体和伤害，数量、寿命均有上限。
const StoneMesh := preload("res://scripts/lowpoly_mesh.gd")
const MAX_BURSTS := 8
var lifetime := 4.0
var age := 0.0
var _chunks: MultiMeshInstance3D
var _positions: Array[Vector3] = []
var _velocities: Array[Vector3] = []
var _rotations: Array[Vector3] = []
var _sizes: Array[Vector3] = []
var _resting: Array[bool] = []


static func spawn(host: Node, pose: Transform3D, dimensions: Vector3, profile: Resource, direction: Vector3) -> Node3D:
	var active: Array[Node] = []
	for node: Node in host.get_tree().get_nodes_in_group("destruction_debris"):
		if not node.is_queued_for_deletion():
			active.append(node)
	while active.size() >= MAX_BURSTS:
		active.pop_front().free()
	var effect := load("res://scripts/destruction_debris.gd").new() as Node3D
	host.add_child(effect)
	effect.global_transform = Transform3D(pose.basis.orthonormalized(), pose.origin)
	effect.call("build", dimensions * pose.basis.get_scale().abs(), profile, direction)
	return effect


func build(dimensions: Vector3, profile: Resource, direction: Vector3) -> void:
	add_to_group("destruction_debris")
	lifetime = float(profile.fragment_lifetime)
	_chunks = MultiMeshInstance3D.new()
	_chunks.multimesh = MultiMesh.new()
	_chunks.multimesh.transform_format = MultiMesh.TRANSFORM_3D
	_chunks.multimesh.mesh = profile.fragment_mesh if profile.fragment_mesh else StoneMesh.chamfered_box(Vector3.ONE, 0.16)
	var material := StandardMaterial3D.new()
	material.albedo_color = profile.fragment_color.lightened(0.08)
	material.roughness = 1.0
	material.vertex_color_use_as_albedo = true
	_chunks.material_override = profile.fragment_material if profile.fragment_material else material
	_chunks.multimesh.instance_count = clampi(int(profile.fragment_count), 1, 32)
	add_child(_chunks)
	var rng := RandomNumberGenerator.new()
	rng.seed = get_instance_id()
	var local_push := global_basis.inverse() * direction.normalized()
	local_push.y = 0.0
	for i in range(_chunks.multimesh.instance_count):
		var angle := float(i) * 2.39996
		var outward := Vector3(cos(angle), 0, sin(angle))
		var point := dimensions * Vector3(0.5 + outward.x * 0.27, rng.randf_range(0.2, 0.85), 0.5 + outward.z * 0.27)
		var size: Vector3 = dimensions * profile.fragment_size_ratio * rng.randf_range(0.8, 1.2)
		_positions.append(point)
		_sizes.append(size)
		_velocities.append(outward * rng.randf_range(profile.scatter_speed.x, profile.scatter_speed.y) + local_push * 1.2 + Vector3.UP * rng.randf_range(profile.lift_speed.x, profile.lift_speed.y))
		_rotations.append(Vector3(rng.randf(), rng.randf(), rng.randf()) * 0.6)
		_resting.append(false)
		_chunks.multimesh.set_instance_transform(i, Transform3D(Basis.from_euler(_rotations[i]).scaled(size), point))
	if profile.dust_enabled:
		_build_dust(dimensions, profile.fragment_color)


func _physics_process(delta: float) -> void:
	age += delta
	if age >= lifetime:
		queue_free()
		return
	var space := get_world_3d().direct_space_state
	var shrink := clampf((lifetime - age) / 0.8, 0.0, 1.0)
	for i in range(_positions.size()):
		if not _resting[i]:
			_velocities[i] += Vector3.DOWN * 14.0 * delta
			var next := _positions[i] + _velocities[i] * delta
			var query := PhysicsRayQueryParameters3D.create(to_global(_positions[i]), to_global(next), 1)
			var hit := space.intersect_ray(query)
			if not hit.is_empty():
				var normal: Vector3 = global_basis.inverse() * (hit.normal as Vector3)
				next = to_local(hit.position) + normal * minf(_sizes[i].y * 0.3, 0.12)
				_velocities[i] = _velocities[i].bounce(normal) * 0.22
				if normal.y > 0.6 and _velocities[i].length() < 1.2:
					_resting[i] = true
			_positions[i] = next
			_rotations[i] += Vector3(1.5, 2.2, 0.8) * delta
		_chunks.multimesh.set_instance_transform(i, Transform3D(Basis.from_euler(_rotations[i]).scaled(_sizes[i] * shrink), _positions[i]))


func _build_dust(dimensions: Vector3, color: Color) -> void:
	var particles := CPUParticles3D.new()
	particles.amount = 24
	particles.lifetime = 0.9
	particles.one_shot = true
	particles.explosiveness = 0.95
	particles.direction = Vector3.UP
	particles.spread = 85.0
	particles.gravity = Vector3(0, -1, 0)
	particles.initial_velocity_min = 1.5
	particles.initial_velocity_max = 4.0
	particles.scale_amount_min = 0.6
	particles.scale_amount_max = 1.8
	particles.emission_shape = CPUParticles3D.EMISSION_SHAPE_BOX
	particles.emission_box_extents = dimensions * Vector3(0.45, 0.3, 0.45)
	particles.position = dimensions * Vector3(0.5, 0.4, 0.5)
	var gradient := Gradient.new()
	gradient.colors = PackedColorArray([Color(1, 1, 1, 0.35), Color(1, 1, 1, 0)])
	var texture := GradientTexture2D.new()
	texture.gradient = gradient
	texture.fill = GradientTexture2D.FILL_RADIAL
	texture.fill_from = Vector2(0.5, 0.5)
	texture.fill_to = Vector2(1, 0.5)
	var material := StandardMaterial3D.new()
	material.albedo_color = color.lightened(0.3)
	material.albedo_texture = texture
	material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	material.billboard_mode = BaseMaterial3D.BILLBOARD_PARTICLES
	material.vertex_color_use_as_albedo = true
	var fade_gradient := Gradient.new()
	fade_gradient.colors = PackedColorArray([Color.WHITE, Color(1, 1, 1, 0)])
	particles.color_ramp = fade_gradient
	var mesh := QuadMesh.new()
	mesh.material = material
	particles.mesh = mesh
	add_child(particles)
	particles.emitting = true
