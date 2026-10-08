extends Node3D
## 小型公共攻击约定：准备只显示范围，锁定后不追踪；命中消费一次，取消立即清理。
## 数值均为世界单位。动作时间由敌人自己的物理帧或物理 Tween 驱动。

enum Phase { IDLE, PREPARE, LOCKED, STRIKE, RECOVERY }
const FillShader := preload("res://shaders/enemy_attack_fill.gdshader")
const SurfaceMesh := preload("res://tests/fixtures/attack_surface/attack_surface_before.gd")
var phase := Phase.IDLE
var progress := 0.0
var shape: Dictionary = {}
var damage := 0.0
var _spent := false
var _mesh: MeshInstance3D
var _material: ShaderMaterial
var _border: MeshInstance3D
var _countdown_duration := 0.0
var _countdown_elapsed := 0.0
var _surface_cooldown := 0.0
var _surface_dirty := false
var _surface: RefCounted


func _ready() -> void:
	name = "AttackArea"
	top_level = true
	_mesh = MeshInstance3D.new()
	_mesh.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_material = ShaderMaterial.new()
	_material.shader = FillShader
	_mesh.material_override = _material
	add_child(_mesh)
	_mesh.top_level = true
	_border = MeshInstance3D.new()
	_border.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	var edge_material := StandardMaterial3D.new()
	edge_material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	edge_material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	edge_material.cull_mode = BaseMaterial3D.CULL_DISABLED
	edge_material.albedo_color = Color(1.0, 0.25, 0.055, 0.9)
	_border.material_override = edge_material
	add_child(_border)
	_border.top_level = true
	visible = false


func prepare(pose: Transform3D, spec: Dictionary, amount: float, countdown_duration := 0.0) -> void:
	shape = spec.duplicate(true)
	damage = amount
	_spent = false
	phase = Phase.PREPARE
	_countdown_duration = maxf(countdown_duration, 0.0)
	_countdown_elapsed = 0.0
	_material.set_shader_parameter("locked_phase", 0.0)
	_material.set_shader_parameter("radial_fill", String(shape.kind) in ["circle", "sector"])
	_material.set_shader_parameter("radius", float(shape.get("radius", 1.0)))
	var cap_radius := float(shape.get("radius", 0.0)) if String(shape.kind) == "capsule" else 0.0
	_material.set_shader_parameter("start_z", cap_radius)
	_material.set_shader_parameter("end_z", -float(shape.get("length", 1.0)) - cap_radius)
	set_progress(0.0)
	global_transform = Transform3D(pose.basis.orthonormalized(), pose.origin)
	_rebuild()
	visible = bool(shape.get("ground_effect", true))


func _physics_process(delta: float) -> void:
	_surface_cooldown = maxf(_surface_cooldown - delta, 0.0)
	if phase == Phase.PREPARE and _surface_dirty and _surface_cooldown <= 0.0:
		_rebuild()
	if phase in [Phase.PREPARE, Phase.LOCKED] and _countdown_duration > 0.0:
		_countdown_elapsed += delta
		set_progress(_countdown_elapsed / _countdown_duration)


func set_progress(value: float) -> void:
	if phase not in [Phase.PREPARE, Phase.LOCKED]:
		return
	progress = clampf(value, 0.0, 1.0)
	_material.set_shader_parameter("progress", progress)


func track(pose: Transform3D) -> void:
	if phase != Phase.PREPARE:
		return
	var next := Transform3D(pose.basis.orthonormalized(), pose.origin)
	if global_transform.is_equal_approx(next):
		return
	global_transform = next
	_surface_dirty = true
	if _surface_cooldown <= 0.0:
		_rebuild()


func lock() -> void:
	if phase == Phase.PREPARE:
		if _surface_dirty:
			_rebuild()
		phase = Phase.LOCKED
		_material.set_shader_parameter("locked_phase", 1.0)


func strike() -> bool:
	if phase != Phase.LOCKED or _spent:
		return false
	set_progress(1.0)
	_spent = true
	_surface_dirty = false
	phase = Phase.STRIKE
	visible = false
	return true


func recover() -> void:
	if phase != Phase.IDLE:
		phase = Phase.RECOVERY
	visible = false


func cancel() -> void:
	phase = Phase.IDLE
	progress = 0.0
	_countdown_duration = 0.0
	_countdown_elapsed = 0.0
	_spent = true
	_surface_dirty = false
	visible = false


func contains(point: Vector3) -> bool:
	var p := to_local(point)
	match String(shape.get("kind", "sector")):
		"rect":
			return absf(p.x - float(shape.get("offset", 0))) <= float(shape.width) * 0.5 + 0.00001 and p.z <= 0.0 and p.z >= -float(shape.length)
		"capsule":
			var nearest := Vector3(0, p.y, clampf(p.z, -float(shape.length), 0.0))
			return Vector2(p.x - nearest.x, p.z - nearest.z).length() <= float(shape.radius) + 0.00001
		"circle":
			return Vector2(p.x, p.z).length() <= float(shape.radius) + 0.00001
		_:
			var distance := Vector2(p.x, p.z).length()
			return distance <= float(shape.radius) + 0.00001 and (distance <= 0.001 or -p.z / distance + 0.00001 >= cos(deg_to_rad(float(shape.angle)) * 0.5))


func can_hit(actor: Node3D, source: Vector3) -> bool:
	if not is_instance_valid(actor) or float(actor.get("health")) <= 0.0 or not can_reach(actor.global_position):
		return false
	# 不隔楼层打人；地面炮击允许命中站立玩家，但跳出高度窗口可躲开。
	if absf(actor.global_position.y - global_position.y) > float(shape.get("height", 2.5)):
		return false
	return unobstructed(self, source, actor.global_position)


func can_reach(point: Vector3) -> bool:
	return contains(point) and (not bool(shape.get("ground_effect", true)) or (_surface != null and bool(_surface.call("allows", point))))


func get_surface() -> RefCounted:
	return _surface


static func unobstructed(context: Node3D, from: Vector3, to: Vector3) -> bool:
	if from.is_equal_approx(to):
		return true
	var query := PhysicsRayQueryParameters3D.create(from, to, 1)
	return context.get_world_3d().direct_space_state.intersect_ray(query).is_empty()


func _rebuild() -> void:
	if not bool(shape.get("ground_effect", true)):
		_surface = null
		_mesh.mesh = null
		_border.mesh = null
		_surface_dirty = false
		return
	# 追踪期最多每 50ms 重建地表；显示网格保留世界姿态，等待时不会随根节点穿地。
	# 锁定会立即刷新最终姿态，命中区域本身始终使用当前姿态。
	_surface_cooldown = 0.05
	_surface_dirty = false
	_mesh.global_transform = global_transform
	_border.global_transform = global_transform
	var polygon: Array[Vector3] = []
	var kind := String(shape.get("kind", "sector"))
	if kind == "rect":
		var x := float(shape.get("offset", 0))
		var w := float(shape.width) * 0.5
		var l := float(shape.length)
		polygon.assign([Vector3(x-w,0,0), Vector3(x+w,0,0), Vector3(x+w,0,-l), Vector3(x-w,0,-l)])
	elif kind == "capsule":
		for i in range(17):
			var a := PI * float(i) / 16.0
			polygon.append(Vector3(cos(a),0,sin(a)) * float(shape.radius))
		for i in range(17):
			var a := PI + PI * float(i) / 16.0
			polygon.append(Vector3(cos(a),0,sin(a)) * float(shape.radius) + Vector3(0,0,-float(shape.length)))
	else:
		var angle := TAU if kind == "circle" else deg_to_rad(float(shape.angle))
		if kind != "circle":
			polygon.append(Vector3.ZERO)
		for i in range(49):
			var a := -angle * 0.5 + angle * float(i) / 48.0
			polygon.append(Vector3(sin(a),0,-cos(a)) * float(shape.radius))
	var footprint := PackedVector2Array()
	for p in polygon:
		# 圆形末尾与首点重合，不将退化边送入多边形裁剪。
		var point := Vector2(p.x, p.z)
		if footprint.is_empty() or not point.is_equal_approx(footprint[0]):
			footprint.append(point)
	_surface = SurfaceMesh.new()
	var meshes: Dictionary = _surface.call("build", self, footprint, shape)
	_mesh.mesh = meshes.fill
	_border.mesh = meshes.edge

