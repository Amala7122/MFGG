extends Node3D

const HealthUtil := preload("res://scripts/health_util.gd")
## 小型公共攻击约定：准备只显示范围，锁定后不追踪；命中消费一次，取消立即清理。
## 数值均为世界单位。动作时间由敌人自己的物理帧或物理 Tween 驱动。

enum Phase { IDLE, PREPARE, LOCKED, STRIKE, RECOVERY }
const FillShader := preload("res://shaders/enemy_attack_fill.gdshader")
const SurfaceMesh := preload("res://scripts/attack_surface_mesh.gd")
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
var _pending_surface: RefCounted
var _pending_pose: Transform3D


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
	if is_in_group("combat_dangers"):
		remove_from_group("combat_dangers")
	shape = spec.duplicate(true)
	if bool(shape.get("affects_allies", false)):
		add_to_group("combat_dangers")
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
	SurfaceMesh.process_build_jobs()
	if _pending_surface and _pending_surface.is_finished():
		_publish_surface(_pending_surface, _pending_surface.get_meshes(), _pending_pose)
	_surface_cooldown = maxf(_surface_cooldown - delta, 0.0)
	if phase == Phase.PREPARE and _surface_dirty and _surface_cooldown <= 0.0 and _should_track_surface():
		_rebuild(true)
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
	if _surface_cooldown <= 0.0 and _should_track_surface():
		_rebuild(true)


func lock() -> void:
	if phase == Phase.PREPARE:
		if _surface_dirty or _pending_surface != null:
			if _pending_surface and _pending_pose.is_equal_approx(global_transform):
				_publish_surface(_pending_surface, _pending_surface.finish(), _pending_pose)
			else:
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
	_clear_danger()
	visible = false
	return true


func recover() -> void:
	_clear_danger()
	if phase != Phase.IDLE:
		phase = Phase.RECOVERY
	visible = false


func cancel() -> void:
	_clear_danger()
	phase = Phase.IDLE
	progress = 0.0
	_countdown_duration = 0.0
	_countdown_elapsed = 0.0
	_spent = true
	_surface_dirty = false
	_pending_surface = null
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


func _clear_danger() -> void:
	if is_in_group("combat_dangers"):
		remove_from_group("combat_dangers")


func danger_active() -> bool:
	return phase in [Phase.PREPARE, Phase.LOCKED] and bool(shape.get("affects_allies", false))


func danger_remaining() -> float:
	return maxf(_countdown_duration - _countdown_elapsed, 0.0)


func can_affect_ally(actor: Node3D) -> bool:
	if not bool(shape.get("affects_allies", false)) or not HealthUtil.is_alive(actor):
		return false
	if not can_reach(actor.global_position) or absf(actor.global_position.y - global_position.y) > float(shape.get("ally_height", shape.get("height", 2.5))):
		return false
	# 预判时允许破坏物消失；落地刷新时排除列表已移除，按实际碰撞判断。
	var excluded: Array[RID] = []
	excluded.assign(shape.get("exclude_bodies", []))
	var query := PhysicsRayQueryParameters3D.create(global_position + Vector3.UP * 0.2, actor.global_position, 1, excluded)
	return get_world_3d().direct_space_state.intersect_ray(query).is_empty()


func can_hit(actor: Node3D, source: Vector3) -> bool:
	if not HealthUtil.is_alive(actor) or not can_reach(actor.global_position):
		return false
	# 不隔楼层打人；地面炮击允许命中站立玩家，但跳出高度窗口可躲开。
	if absf(actor.global_position.y - global_position.y) > float(shape.get("height", 2.5)):
		return false
	return unobstructed(self, source, actor.global_position)


func can_reach(point: Vector3) -> bool:
	return contains(point) and (not bool(shape.get("ground_effect", true)) or (_surface != null and bool(_surface.call("allows", point))))


func get_surface() -> RefCounted:
	return _surface


func refresh_surface() -> void:
	# 环境碰撞改变后刷新覆盖；持续横扫在结束时也要留下实际剩余地表上的笔迹。
	if phase in [Phase.PREPARE, Phase.LOCKED, Phase.STRIKE]:
		_rebuild()


static func unobstructed(context: Node3D, from: Vector3, to: Vector3) -> bool:
	if from.is_equal_approx(to):
		return true
	var query := PhysicsRayQueryParameters3D.create(from, to, 1)
	return context.get_world_3d().direct_space_state.intersect_ray(query).is_empty()


static func candidate_can_hit(context: Node3D, pose: Transform3D, spec: Dictionary, actor: Node3D) -> bool:
	if not is_instance_valid(actor):
		return false
	var p := pose.affine_inverse() * actor.global_position
	if absf(p.y) > float(spec.get("height", 2.5)):
		return false
	var inside := false
	match String(spec.get("kind", "sector")):
		"rect":
			inside = absf(p.x - float(spec.get("offset", 0.0))) <= float(spec.width) * 0.5 and p.z <= 0.0 and p.z >= -float(spec.length)
		"capsule":
			inside = Vector2(p.x, p.z - clampf(p.z, -float(spec.length), 0.0)).length() <= float(spec.radius)
		"circle":
			inside = Vector2(p.x, p.z).length() <= float(spec.radius)
		_:
			var distance := Vector2(p.x, p.z).length()
			inside = distance <= float(spec.radius) and (distance < 0.001 or -p.z / distance >= cos(deg_to_rad(float(spec.get("angle", 180.0))) * 0.5))
	if not inside:
		return false
	var excluded: Array[RID] = []
	excluded.assign(spec.get("exclude_bodies", []))
	var ray := PhysicsRayQueryParameters3D.create(pose.origin, actor.global_position, 1, excluded)
	if not context.get_world_3d().direct_space_state.intersect_ray(ray).is_empty():
		return false
	return not bool(spec.get("ground_effect", true)) or SurfaceMesh.new().query_reachable(context, pose, spec, actor.global_position)


func _should_track_surface() -> bool:
	if _pending_surface != null:
		return false
	var reach := maxf(float(shape.get("radius", 0.0)), float(shape.get("length", 0.0)))
	var error := global_position.distance_to(_mesh.global_position) + (global_basis.z - _mesh.global_basis.z).length() * reach
	# 小于 5cm 的视觉变化等锁定时一次刷新，避免落地浮点抖动触发重建。
	return error >= 0.05


func _publish_surface(surface: RefCounted, meshes: Dictionary, pose: Transform3D) -> void:
	_surface = surface
	_mesh.global_transform = pose
	_border.global_transform = pose
	_mesh.mesh = meshes.fill
	_border.mesh = meshes.edge
	_pending_surface = null
	_surface_dirty = not global_transform.is_equal_approx(pose)
	_surface_cooldown = 0.05


func _rebuild(deferred := false) -> void:
	if not bool(shape.get("ground_effect", true)):
		_surface = null
		_mesh.mesh = null
		_border.mesh = null
		_surface_dirty = false
		_pending_surface = null
		return
	# 初始和锁定范围完整生成。追踪重建用全场共用的 3ms 帧预算，期间保留已完成网格。
	_surface_cooldown = 0.05
	_surface_dirty = false
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
	_pending_surface = null
	var surface := SurfaceMesh.new()
	if deferred:
		_pending_pose = global_transform
		surface.begin(self, footprint, shape)
		if surface.is_finished():
			_publish_surface(surface, surface.get_meshes(), _pending_pose)
		else:
			_pending_surface = surface
			surface.queue_build()
	else:
		_publish_surface(surface, surface.build(self, footprint, shape), global_transform)
