extends Node3D
## 有上限、有寿命的贴地痕迹、碎土与尘浪；不带碰撞，不参与伤害。
const Shake := preload("res://scripts/ground_impact_shake.gd")
const Audio := preload("res://scripts/audio_manager.gd")
var age := 0.0
var radius := 1.0
var pulse_strength := 0.0
var lifetime := 5.0
var charging := false
var _chunks: MultiMeshInstance3D
var _velocities: Array[Vector3] = []
var _origins: Array[Vector3] = []
var _rotations: Array[Vector3] = []
var _trace: MeshInstance3D
var _trace_material: StandardMaterial3D
var _dust: MeshInstance3D
var _dust_material: StandardMaterial3D

static func spawn(host: Node, point: Vector3, size: float, power: float, takeoff := false, shake_scale := 1.0, charge := false) -> Node3D:
	var existing := host.get_tree().get_nodes_in_group("titan_ground_effect")
	var active: Array[Node] = []
	for node in existing:
		if not node.is_queued_for_deletion():
			active.append(node)
	while active.size() >= 16:
		active.pop_front().queue_free()
	var effect := load("res://scripts/prototypes/titan_ground_effect.gd").new() as Node3D
	host.add_child(effect)
	effect.global_position = point
	effect.call("trigger", size, power, takeoff, shake_scale, charge)
	return effect

func trigger(size: float, power: float, takeoff: bool, shake_scale: float, charge := false) -> void:
	add_to_group("titan_ground_effect")
	add_to_group("ground_impulse")
	radius = size
	pulse_strength = power
	lifetime = 3.5 if takeoff else 6.0
	charging = charge
	if charging:
		lifetime = 0.85
	_trace_material = _material(Color(0.19, 0.15, 0.11, 0.85))
	_trace = MeshInstance3D.new()
	_trace.mesh = _trace_mesh(takeoff)
	_trace.material_override = _trace_material
	_trace.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(_trace)
	_dust_material = _material(Color(0.60, 0.49, 0.31, 0.42))
	_dust = MeshInstance3D.new()
	_dust.mesh = _ring_mesh()
	_dust.material_override = _dust_material
	_dust.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_dust.position.y = 0.06
	add_child(_dust)
	_dust.visible = not charging
	_chunks = MultiMeshInstance3D.new()
	_chunks.multimesh = MultiMesh.new()
	_chunks.multimesh.transform_format = MultiMesh.TRANSFORM_3D
	var box := BoxMesh.new()
	box.size = Vector3.ONE
	var chunk_material := StandardMaterial3D.new()
	chunk_material.albedo_color = Color(0.48, 0.37, 0.23)
	chunk_material.roughness = 1.0
	box.material = chunk_material
	_chunks.multimesh.mesh = box
	_chunks.multimesh.instance_count = 14 if takeoff else 26
	_chunks.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(_chunks)
	var rng := RandomNumberGenerator.new()
	rng.seed = get_instance_id()
	for i in range(_chunks.multimesh.instance_count):
		var direction := Vector3(cos(float(i) * 2.4), 0, sin(float(i) * 2.4))
		_origins.append(direction * rng.randf_range(radius * 0.15, radius * 0.65) + Vector3.UP * 0.1)
		_velocities.append(direction * rng.randf_range(2.0, 5.5) * power + Vector3.UP * rng.randf_range(2.3, 5.0))
		_rotations.append(Vector3(rng.randf(), rng.randf(), rng.randf()) * TAU)
		_chunks.multimesh.set_instance_transform(i, Transform3D(Basis.from_scale(Vector3.ONE * 0.14), _origins[i]))
	if not charging:
		Audio.play_at("titan_takeoff" if takeoff else "titan_land", global_position, -7.0 if takeoff else -3.0)
	var camera := get_viewport().get_camera_3d()
	if camera != null and shake_scale > 0.0:
		var attenuation := clampf(1.0 - camera.global_position.distance_to(global_position) / 28.0, 0.0, 1.0)
		var shake := camera.get_node_or_null("GroundImpactShake")
		if shake == null:
			shake = Shake.new()
			shake.name = "GroundImpactShake"
			camera.add_child(shake)
		shake.call("request", (0.018 if takeoff else 0.05) * attenuation * shake_scale)

func _physics_process(delta: float) -> void:
	age += delta
	if age >= lifetime:
		queue_free()
		return
	_trace_material.albedo_color.a = 0.85 * clampf((lifetime - age) / 1.0, 0.0, 1.0)
	var wave := clampf(age / 0.55, 0.0, 1.0)
	_dust.scale = Vector3(1, 1, 1) * lerpf(radius * 0.4, radius * 1.45, wave)
	_dust.scale.y = lerpf(1.35, 0.15, wave)
	_dust_material.albedo_color.a = 0.42 * pow(1.0 - wave, 1.2)
	_chunks.visible = age < 1.4
	if _chunks.visible:
		for i in range(_velocities.size()):
			var point := _origins[i] + _velocities[i] * age + Vector3.DOWN * 5.5 * age * age
			if charging:
				point = _origins[i] + Vector3.UP * sin(age * 65.0 + i) * 0.035
			point.y = maxf(point.y, 0.055)
			var factor := 0.10 + float(i % 4) * 0.035
			factor *= clampf((1.4 - age) / 0.3, 0.0, 1.0)
			_chunks.multimesh.set_instance_transform(i, Transform3D(Basis.from_euler(_rotations[i] + Vector3(2, 1, 3) * age).scaled(Vector3.ONE * factor), point))

func impulse() -> Vector4:
	# 草木冲击只存在于短暂接触过程；余下时间是静态足迹。
	return Vector4(global_position.x, global_position.z, radius * (0.5 + minf(age / 0.55, 1.0)),
		pulse_strength * pow(maxf(1.0 - age / 0.8, 0.0), 2.0))

func _material(color: Color) -> StandardMaterial3D:
	var material := StandardMaterial3D.new()
	material.albedo_color = color
	material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	material.roughness = 1.0
	material.cull_mode = BaseMaterial3D.CULL_DISABLED
	return material

func _ground(local: Vector3) -> Vector3:
	var point := global_position + local
	var query := PhysicsRayQueryParameters3D.create(point + Vector3.UP * 2, point + Vector3.DOWN * 3, 1)
	var hit := get_world_3d().direct_space_state.intersect_ray(query)
	if not hit.is_empty():
		point.y = (hit.position as Vector3).y + 0.028
	return point - global_position

func _trace_mesh(takeoff: bool) -> ArrayMesh:
	var surface := SurfaceTool.new()
	surface.begin(Mesh.PRIMITIVE_TRIANGLES)
	for i in range(18):
		var angle := TAU * float(i) / 18.0
		var direction := Vector3(cos(angle), 0, sin(angle))
		var side := Vector3(-direction.z, 0, direction.x)
		var start := direction * radius * (0.22 + float(i % 3) * 0.04)
		var bend := direction * radius * 0.52 + side * (0.08 if i % 2 == 0 else -0.08)
		var end := direction * radius * ((0.62 if takeoff else 0.82) + float(i % 4) * 0.04) + side * 0.12
		var width := 0.035 if takeoff else 0.06
		var segments := [[start, bend], [bend, end]]
		if i % 3 == 0:
			segments.append([bend, bend + direction * radius * 0.15 - side * radius * 0.18])
		for segment in segments:
			var a: Vector3 = segment[0]
			var b: Vector3 = segment[1]
			for point in [a - side * width, a + side * width, b + side * width, a - side * width, b + side * width, b - side * width]:
				surface.add_vertex(_ground(point))
	surface.generate_normals()
	return surface.commit()

func _ring_mesh() -> ArrayMesh:
	var surface := SurfaceTool.new()
	surface.begin(Mesh.PRIMITIVE_TRIANGLES)
	for i in range(24):
		var a := TAU * float(i) / 24.0
		var b := TAU * float(i + 1) / 24.0
		var p := Vector3(cos(a), 0, sin(a))
		var q := Vector3(cos(b), 0, sin(b))
		var ridge_p := p * 0.84 + Vector3.UP * 0.7
		var ridge_q := q * 0.84 + Vector3.UP * 0.7
		for vertex in [p * 0.72, q * 0.72, ridge_q, p * 0.72, ridge_q, ridge_p,
			ridge_p, ridge_q, q, ridge_p, q, p]:
			surface.add_vertex(vertex)
	surface.generate_normals()
	return surface.commit()
