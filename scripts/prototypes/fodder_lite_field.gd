class_name FodderLiteField
extends Node3D
## Fodder Lite：一只炮灰 = 两个 MultiMesh 实例（身体/晶核），没有子节点、
## 没有 CharacterBody、没有 CollisionShape、没有 per-unit Tween/Area。
## 移动只读流场 + 轻量分离；攻击是共享计时器；动画在 shader 里整体起伏。
## 原型阶段允许穿过玩家/石头，用于验证“数据导向炮灰”的上限。

const Terrain := preload("res://scripts/terrain_field.gd")
const LiteShader := preload("res://shaders/fodder_lite.gdshader")

const SPEED := 3.4
const SEPARATION_RADIUS := 1.55
const SEPARATION_STRENGTH := 1.35
const ATTACK_RANGE := 2.5
const ATTACK_WINDUP := 0.42
const ATTACK_RECOVER := 0.55
const ATTACK_COOLDOWN := 1.25
const MAX_ACTIVE_ATTACKERS := 8
const DAMAGE := 1.0
const BODY_OFFSET := 0.6

var player: Node3D
var flow: RefCounted
var count := 0

var _positions := PackedVector3Array()
var _yaw := PackedFloat32Array()
var _cooldown := PackedFloat32Array()
var _timer := PackedFloat32Array()
var _state := PackedByteArray()
var _phase := PackedFloat32Array()
var _flash := PackedFloat32Array()
var _body_mm: MultiMesh
var _core_mm: MultiMesh
var active_attackers := 0
var total_attacks := 0
var _attack_cycle := 0


func setup(target: Node3D, field: RefCounted, amount: int, center: Vector3) -> void:
	player = target
	flow = field
	count = amount
	_positions.resize(count)
	_yaw.resize(count)
	_cooldown.resize(count)
	_timer.resize(count)
	_state.resize(count)
	_phase.resize(count)
	_flash.resize(count)
	_build_mesh()
	for index in count:
		var angle := TAU * float(index) / float(maxi(count, 1))
		var ring := 8.0 + float(index % 7) * 1.8
		var x := center.x + cos(angle) * ring
		var z := center.z + sin(angle) * ring
		_positions[index] = Vector3(x, Terrain.height_at(x, z) + BODY_OFFSET, z)
		_yaw[index] = angle
		_cooldown[index] = 0.0
		_timer[index] = 0.0
		_state[index] = 0
		_phase[index] = float(index) * 0.618
		_flash[index] = 0.0
	_update_visuals()


func _build_mesh() -> void:
	var body := SurfaceTool.new()
	body.begin(Mesh.PRIMITIVE_TRIANGLES)
	var torso := CylinderMesh.new()
	torso.top_radius = 0.42
	torso.bottom_radius = 0.28
	torso.height = 0.7
	torso.radial_segments = 6
	torso.rings = 0
	body.append_from(torso, 0, Transform3D(Basis(), Vector3(0.0, 0.42, 0.0)))
	var arm := BoxMesh.new()
	arm.size = Vector3(0.18, 0.5, 0.2)
	body.append_from(arm, 0, Transform3D(Basis(), Vector3(-0.34, 0.58, 0.0)))
	body.append_from(arm, 0, Transform3D(Basis(), Vector3(0.34, 0.58, 0.0)))
	var leg := BoxMesh.new()
	leg.size = Vector3(0.2, 0.42, 0.24)
	body.append_from(leg, 0, Transform3D(Basis(), Vector3(-0.14, 0.18, 0.0)))
	body.append_from(leg, 0, Transform3D(Basis(), Vector3(0.14, 0.18, 0.0)))
	var body_mesh := body.commit()

	var body_material := ShaderMaterial.new()
	body_material.shader = LiteShader
	body_material.set_shader_parameter("base_color", Color(0.28, 0.32, 0.22))
	body_material.set_shader_parameter("bob_amplitude", 0.045)

	var core := BoxMesh.new()
	core.size = Vector3(0.2, 0.2, 0.2)
	var core_material := ShaderMaterial.new()
	core_material.shader = LiteShader
	core_material.set_shader_parameter("base_color", Color(0.10, 0.85, 0.90))
	core_material.set_shader_parameter("bob_amplitude", 0.025)

	_body_mm = MultiMesh.new()
	_body_mm.transform_format = MultiMesh.TRANSFORM_3D
	_body_mm.use_custom_data = true
	_body_mm.mesh = body_mesh
	_body_mm.instance_count = count
	_body_mm.visible_instance_count = count
	var body_instance := MultiMeshInstance3D.new()
	body_instance.name = "FodderLiteBody"
	body_instance.multimesh = _body_mm
	body_instance.material_override = body_material
	add_child(body_instance)

	_core_mm = MultiMesh.new()
	_core_mm.transform_format = MultiMesh.TRANSFORM_3D
	_core_mm.use_custom_data = true
	_core_mm.mesh = core
	_core_mm.instance_count = count
	_core_mm.visible_instance_count = count
	var core_instance := MultiMeshInstance3D.new()
	core_instance.name = "FodderLiteCore"
	core_instance.multimesh = _core_mm
	core_instance.material_override = core_material
	add_child(core_instance)


func _physics_process(delta: float) -> void:
	if player == null or not is_instance_valid(player) or count <= 0:
		return
	var target := player.global_position
	# 轻量空间哈希：每 2m 一格，只为邻域分离服务，不建任何节点。
	var grid: Dictionary = {}
	for index in count:
		var p := _positions[index]
		var key := Vector2i(floori(p.x / 2.0), floori(p.z / 2.0))
		if not grid.has(key):
			grid[key] = []
		(grid[key] as Array).append(index)
	var active := 0
	for index in count:
		var pos := _positions[index]
		var to := target - pos
		to.y = 0.0
		var distance := to.length()
		var state := int(_state[index])
		_flash[index] = maxf(0.0, _flash[index] - delta * 3.0)
		if state == 1:
			_timer[index] -= delta
			_yaw[index] = atan2(-to.x, -to.z)
			if _timer[index] <= 0.0:
				if distance <= ATTACK_RANGE + 0.7:
					var forward := Vector3(-sin(_yaw[index]), 0.0, -cos(_yaw[index]))
					if forward.dot(to.normalized()) > 0.15 and player.has_method("take_damage"):
						player.call("take_damage", DAMAGE, pos)
						total_attacks += 1
						_flash[index] = 1.0
				_state[index] = 2
				_timer[index] = ATTACK_RECOVER
			active += 1
			continue
		if state == 2:
			_timer[index] -= delta
			if _timer[index] <= 0.0:
				_state[index] = 0
				_cooldown[index] = ATTACK_COOLDOWN
			active += 1
			continue
		_cooldown[index] = maxf(0.0, _cooldown[index] - delta)
		if distance <= ATTACK_RANGE and _cooldown[index] <= 0.0 and active < MAX_ACTIVE_ATTACKERS:
			_state[index] = 1
			_timer[index] = ATTACK_WINDUP
			_yaw[index] = atan2(-to.x, -to.z)
			active += 1
			continue
		var direction := Vector3.ZERO
		if flow != null:
			direction = flow.call("direction_at", pos)
		if direction.length_squared() < 0.001:
			direction = to.normalized() if distance > 0.001 else Vector3.FORWARD
		var push := Vector3.ZERO
		var cell := Vector2i(floori(pos.x / 2.0), floori(pos.z / 2.0))
		for dz in range(-1, 2):
			for dx in range(-1, 2):
				var bucket: Array = grid.get(Vector2i(cell.x + dx, cell.y + dz), [])
				for other in bucket:
					if other == index:
						continue
					var delta_pos := pos - _positions[other]
					delta_pos.y = 0.0
					var length := delta_pos.length()
					if length > 0.001 and length < SEPARATION_RADIUS:
						push += delta_pos / length * (1.0 - length / SEPARATION_RADIUS)
		var desired := (direction + push * SEPARATION_STRENGTH).normalized()
		pos += desired * SPEED * delta
		pos.y = Terrain.height_at(pos.x, pos.z) + BODY_OFFSET
		_positions[index] = pos
		_yaw[index] = atan2(-desired.x, -desired.z)
	active_attackers = active
	_update_visuals()


func _update_visuals() -> void:
	if _body_mm == null or _core_mm == null:
		return
	for index in count:
		var basis := Basis(Vector3.UP, _yaw[index])
		var transform := Transform3D(basis, _positions[index])
		_body_mm.set_instance_transform(index, transform)
		_core_mm.set_instance_transform(index, transform * Transform3D(Basis(), Vector3(0.0, 0.86, 0.0)))
		var custom := Color(_phase[index], _flash[index], 0.0, 0.0)
		_body_mm.set_instance_custom_data(index, custom)
		_core_mm.set_instance_custom_data(index, custom)


func units() -> int:
	return count


func reset_stats() -> void:
	total_attacks = 0
	active_attackers = 0
