extends Node3D
## 小型公共攻击约定：准备只显示范围，锁定后不追踪；命中消费一次，取消立即清理。
## 数值均为世界单位。动作时间由敌人自己的物理帧或物理 Tween 驱动。

enum Phase { IDLE, PREPARE, LOCKED, STRIKE, RECOVERY }
const FillShader := preload("res://shaders/enemy_attack_fill.gdshader")
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


func _ready() -> void:
	name = "AttackArea"
	top_level = true
	_mesh = MeshInstance3D.new()
	_mesh.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_material = ShaderMaterial.new()
	_material.shader = FillShader
	_mesh.material_override = _material
	add_child(_mesh)
	_border = MeshInstance3D.new()
	_border.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	var edge_material := StandardMaterial3D.new()
	edge_material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	edge_material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	edge_material.cull_mode = BaseMaterial3D.CULL_DISABLED
	edge_material.albedo_color = Color(1.0, 0.25, 0.055, 0.9)
	_border.material_override = edge_material
	add_child(_border)
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
	visible = true


func _physics_process(delta: float) -> void:
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
	_rebuild()


func lock() -> void:
	if phase == Phase.PREPARE:
		phase = Phase.LOCKED
		_material.set_shader_parameter("locked_phase", 1.0)


func strike() -> bool:
	if phase != Phase.LOCKED or _spent:
		return false
	set_progress(1.0)
	_spent = true
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
	if not is_instance_valid(actor) or float(actor.get("health")) <= 0.0 or not contains(actor.global_position):
		return false
	# 不隔楼层打人；地面炮击允许命中站立玩家，但跳出高度窗口可躲开。
	if absf(actor.global_position.y - global_position.y) > float(shape.get("height", 2.5)):
		return false
	return unobstructed(self, source, actor.global_position)


static func unobstructed(context: Node3D, from: Vector3, to: Vector3) -> bool:
	if from.is_equal_approx(to):
		return true
	var query := PhysicsRayQueryParameters3D.create(from, to, 1)
	return context.get_world_3d().direct_space_state.intersect_ray(query).is_empty()


func _rebuild() -> void:
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
	# 每个顶点贴实际碰撞地面，不能假定实验场的 y=0。找不到地面则保留附近高度。
	var center := Vector3.ZERO
	for p in polygon:
		center += p
	center /= polygon.size()
	if kind in ["sector", "circle"]:
		center = Vector3.ZERO
	var grounded: Array[Vector3] = []
	for p in polygon:
		grounded.append(_ground_vertex(p))
	center = _ground_vertex(center)
	var surface := SurfaceTool.new()
	surface.begin(Mesh.PRIMITIVE_TRIANGLES)
	for i in range(polygon.size()):
		for p in [center, grounded[i], grounded[(i+1) % polygon.size()]]:
			surface.set_normal(Vector3.UP)
			surface.set_uv(Vector2(p.x, p.z))
			surface.add_vertex(p)
	_mesh.mesh = surface.commit()
	var edge := SurfaceTool.new()
	edge.begin(Mesh.PRIMITIVE_TRIANGLES)
	for i in range(grounded.size()):
		var a := grounded[i] + Vector3.UP * 0.005
		var b := grounded[(i+1) % grounded.size()] + Vector3.UP * 0.005
		var side := (b-a).cross(Vector3.UP).normalized() * 0.035
		for p in [a-side, a+side, b+side, a-side, b+side, b-side]:
			edge.set_normal(Vector3.UP)
			edge.add_vertex(p)
	_border.mesh = edge.commit()


func _ground_vertex(point: Vector3) -> Vector3:
	var world := global_transform * point
	var query := PhysicsRayQueryParameters3D.create(world + Vector3.UP * 3, world + Vector3.DOWN * 8, 1)
	var hit := get_world_3d().direct_space_state.intersect_ray(query)
	world.y = float(hit.position.y) + 0.045 if not hit.is_empty() else global_position.y - float(shape.get("floor_offset", 1.0))
	return to_local(world)
