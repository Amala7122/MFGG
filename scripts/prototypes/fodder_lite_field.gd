class_name FodderLiteField
extends Node3D
## Fodder Lite v2：数据导向炮灰，不是“糊弄版”。
## 每只炮灰没有子节点、没有 CharacterBody/CollisionShape，但保留 6 个分件的
## MultiMesh 变换（躯干/晶核/双拳/双腿）、走路摆动、攻击抬手、受击闪红、硬直和击退。
## 移动只读共享流场 + 2m 空间哈希分离；攻击是共享计时器；受击由 CombatFX 径向伤害接入。
## 原型阶段仍不做石头/玩家硬碰撞，先验证“数据导向 + 完整反馈”的 CPU 上限。

const Terrain := preload("res://scripts/terrain_field.gd")
const LiteShader := preload("res://shaders/fodder_lite.gdshader")

const SPEED := 3.4
const SEPARATION_RADIUS := 1.55
const SEPARATION_STRENGTH := 1.35
const PLAYER_RADIUS := 1.0
const ATTACK_RANGE := 2.5
const ATTACK_WINDUP := 0.42
const ATTACK_RECOVER := 0.55
const ATTACK_COOLDOWN := 1.25
const MAX_ACTIVE_ATTACKERS := 8
const DAMAGE := 1.0
const BODY_OFFSET := 0.6
const HITSTUN_MIN := 0.35

const STATE_MOVE := 0
const STATE_WINDUP := 1
const STATE_RECOVER := 2
const STATE_HITSTUN := 3

var player: Node3D
var flow: RefCounted
var count := 0

var _positions := PackedVector3Array()
var _velocity := PackedVector3Array()
var _yaw := PackedFloat32Array()
var _cooldown := PackedFloat32Array()
var _timer := PackedFloat32Array()
var _state := PackedByteArray()
var _phase := PackedFloat32Array()
var _flash := PackedFloat32Array()
var _move_weight := PackedFloat32Array()
var _torso_mm: MultiMesh
var _core_mm: MultiMesh
var _arm_mm: MultiMesh
var _leg_mm: MultiMesh
var active_attackers := 0
var total_attacks := 0


func setup(target: Node3D, field: RefCounted, amount: int, center: Vector3) -> void:
	player = target
	flow = field
	count = amount
	_positions.resize(count)
	_velocity.resize(count)
	_yaw.resize(count)
	_cooldown.resize(count)
	_timer.resize(count)
	_state.resize(count)
	_phase.resize(count)
	_flash.resize(count)
	_move_weight.resize(count)
	_build_visuals()
	add_to_group("fodder_lite_fields")
	for index in count:
		var angle := TAU * float(index) / float(maxi(count, 1))
		var ring := 8.0 + float(index % 7) * 1.8
		var x := center.x + cos(angle) * ring
		var z := center.z + sin(angle) * ring
		_positions[index] = Vector3(x, Terrain.height_at(x, z) + BODY_OFFSET, z)
		_velocity[index] = Vector3.ZERO
		_yaw[index] = angle
		_cooldown[index] = 0.0
		_timer[index] = 0.0
		_state[index] = STATE_MOVE
		_phase[index] = float(index) * 0.618
		_flash[index] = 0.0
		_move_weight[index] = 1.0
	_update_visuals()


func _build_visuals() -> void:
	var torso := CylinderMesh.new()
	torso.top_radius = 0.42
	torso.bottom_radius = 0.28
	torso.height = 0.7
	torso.radial_segments = 6
	torso.rings = 0
	var core := BoxMesh.new()
	core.size = Vector3(0.2, 0.2, 0.2)
	var arm := BoxMesh.new()
	arm.size = Vector3(0.18, 0.5, 0.2)
	var leg := BoxMesh.new()
	leg.size = Vector3(0.2, 0.42, 0.24)

	_torso_mm = _make_group("FodderLiteTorso", torso, Color(0.28, 0.32, 0.22), count)
	_core_mm = _make_group("FodderLiteCore", core, Color(0.10, 0.85, 0.90), count)
	_arm_mm = _make_group("FodderLiteArms", arm, Color(0.42, 0.44, 0.45), count * 2)
	_leg_mm = _make_group("FodderLiteLegs", leg, Color(0.24, 0.28, 0.20), count * 2)


func _make_group(node_name: String, mesh: Mesh, color: Color, instances: int) -> MultiMesh:
	var material := ShaderMaterial.new()
	material.shader = LiteShader
	material.set_shader_parameter("base_color", color)
	material.set_shader_parameter("bob_amplitude", 0.0)
	var multimesh := MultiMesh.new()
	multimesh.transform_format = MultiMesh.TRANSFORM_3D
	multimesh.use_custom_data = true
	multimesh.mesh = mesh
	multimesh.instance_count = instances
	multimesh.visible_instance_count = instances
	var instance := MultiMeshInstance3D.new()
	instance.name = node_name
	instance.multimesh = multimesh
	instance.material_override = material
	add_child(instance)
	return multimesh


func _physics_process(delta: float) -> void:
	if player == null or not is_instance_valid(player) or count <= 0:
		return
	var target := player.global_position
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
		if state == STATE_HITSTUN:
			_timer[index] -= delta
			pos += _velocity[index] * delta
			_velocity[index] *= maxf(0.0, 1.0 - delta * 5.0)
			pos.y = Terrain.height_at(pos.x, pos.z) + BODY_OFFSET
			_positions[index] = pos
			_move_weight[index] = 0.0
			if _timer[index] <= 0.0:
				_state[index] = STATE_MOVE
				_cooldown[index] = ATTACK_COOLDOWN * 0.5
			continue
		if state == STATE_WINDUP:
			_timer[index] -= delta
			_yaw[index] = atan2(-to.x, -to.z)
			_move_weight[index] = 0.0
			if _timer[index] <= 0.0:
				if distance <= ATTACK_RANGE + 0.7:
					var forward := Vector3(-sin(_yaw[index]), 0.0, -cos(_yaw[index]))
					if forward.dot(to.normalized()) > 0.15 and player.has_method("take_damage"):
						player.call("take_damage", DAMAGE, pos)
						total_attacks += 1
						_flash[index] = 1.0
				_state[index] = STATE_RECOVER
				_timer[index] = ATTACK_RECOVER
			active += 1
			continue
		if state == STATE_RECOVER:
			_timer[index] -= delta
			_yaw[index] = atan2(-to.x, -to.z)
			_move_weight[index] = 0.0
			if _timer[index] <= 0.0:
				_state[index] = STATE_MOVE
				_cooldown[index] = ATTACK_COOLDOWN
			active += 1
			continue
		_cooldown[index] = maxf(0.0, _cooldown[index] - delta)
		if distance <= ATTACK_RANGE and _cooldown[index] <= 0.0 and active < MAX_ACTIVE_ATTACKERS:
			_state[index] = STATE_WINDUP
			_timer[index] = ATTACK_WINDUP
			_yaw[index] = atan2(-to.x, -to.z)
			_move_weight[index] = 0.0
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
					var offset := pos - _positions[other]
					offset.y = 0.0
					var length := offset.length()
					if length > 0.001 and length < SEPARATION_RADIUS:
						push += offset / length * (1.0 - length / SEPARATION_RADIUS)
		if distance > 0.001 and distance < PLAYER_RADIUS:
			push += -to.normalized() * (1.0 - distance / PLAYER_RADIUS) * 2.0
		var desired := (direction + push * SEPARATION_STRENGTH).normalized()
		pos += desired * SPEED * delta
		pos.y = Terrain.height_at(pos.x, pos.z) + BODY_OFFSET
		_positions[index] = pos
		_yaw[index] = atan2(-desired.x, -desired.z)
		_move_weight[index] = 1.0
		_phase[index] += delta * 8.0
	active_attackers = active


func _process(_delta: float) -> void:
	_update_visuals()


func _update_visuals() -> void:
	if _torso_mm == null:
		return
	for index in count:
		var pos := _positions[index]
		var root := Transform3D(Basis(Vector3.UP, _yaw[index]), pos)
		var state := int(_state[index])
		var walk := sin(_phase[index]) * 0.5 * _move_weight[index]
		var bob := absf(sin(_phase[index])) * 0.03 * _move_weight[index]
		var attack_swing := 0.0
		if state == STATE_WINDUP:
			var progress := 1.0 - _timer[index] / ATTACK_WINDUP
			attack_swing = lerpf(0.0, -1.6, clampf(progress, 0.0, 1.0))
		elif state == STATE_RECOVER:
			var progress := 1.0 - _timer[index] / ATTACK_RECOVER
			attack_swing = sin(clampf(progress, 0.0, 1.0) * PI) * 1.9 - 0.2
		elif state == STATE_HITSTUN:
			attack_swing = -0.35
		var torso := root * Transform3D(Basis(), Vector3(0.0, 0.42 + bob, 0.0))
		var core := root * Transform3D(Basis(), Vector3(0.0, 0.9 + bob, 0.0))
		var left_arm_angle := walk + attack_swing
		var right_arm_angle := -walk + attack_swing
		var left_arm := _limb_transform(root, Vector3(-0.34, 0.6, 0.0), left_arm_angle, 0.25)
		var right_arm := _limb_transform(root, Vector3(0.34, 0.6, 0.0), right_arm_angle, 0.25)
		var left_leg := _limb_transform(root, Vector3(-0.14, 0.2, 0.0), -walk * 0.9, 0.21)
		var right_leg := _limb_transform(root, Vector3(0.14, 0.2, 0.0), walk * 0.9, 0.21)
		_torso_mm.set_instance_transform(index, torso)
		_core_mm.set_instance_transform(index, core)
		_arm_mm.set_instance_transform(index * 2, left_arm)
		_arm_mm.set_instance_transform(index * 2 + 1, right_arm)
		_leg_mm.set_instance_transform(index * 2, left_leg)
		_leg_mm.set_instance_transform(index * 2 + 1, right_leg)
		var custom := Color(_phase[index], _flash[index], 0.0, 0.0)
		_torso_mm.set_instance_custom_data(index, custom)
		_core_mm.set_instance_custom_data(index, custom)
		_arm_mm.set_instance_custom_data(index * 2, custom)
		_arm_mm.set_instance_custom_data(index * 2 + 1, custom)
		_leg_mm.set_instance_custom_data(index * 2, custom)
		_leg_mm.set_instance_custom_data(index * 2 + 1, custom)


func _limb_transform(root: Transform3D, shoulder: Vector3, angle: float, half_length: float) -> Transform3D:
	var basis := Basis(Vector3.RIGHT, angle)
	var center := shoulder + basis * Vector3(0.0, -half_length, 0.0)
	return root * Transform3D(basis, center)


## CombatFX.apply_radial_damage 的接入点：闪红 + 硬直 + 击退。
func apply_radial_hit(center: Vector3, radius: float, _damage: float, push_force: float, stagger_seconds: float = 0.0) -> int:
	var hits := 0
	for index in count:
		var offset := _positions[index] - center
		offset.y = 0.0
		var distance := offset.length()
		if distance > radius:
			continue
		var direction := offset.normalized() if distance > 0.001 else Vector3.FORWARD
		var impulse := direction * maxf(push_force, 1.0) * clampf(1.0 - distance / maxf(radius, 0.01), 0.25, 1.0)
		_state[index] = STATE_HITSTUN
		_timer[index] = maxf(HITSTUN_MIN, stagger_seconds) + 0.1
		_velocity[index] = impulse
		_flash[index] = 1.0
		hits += 1
	return hits


func units() -> int:
	return count


func reset_stats() -> void:
	total_attacks = 0
	active_attackers = 0
