class_name FodderField
extends Node3D
## 100 只炮灰的数据场：没有 per-unit 节点、没有 CharacterBody。
## 位置/朝向/状态/计时器/血量全部是数组；渲染是一个 MultiMesh + 合并网格，
## 四肢/攻击/受击姿态在 GPU shader 里，死亡散体用有限数量的 RigidBody 碎片。
## 命中由共享查询（射线/锥/径向）负责，不依赖每只 CollisionShape。

const Terrain := preload("res://scripts/terrain_field.gd")
const SurfaceGridScript := preload("res://scripts/prototypes/surface_grid.gd")
const WalkabilityGridScript := preload("res://scripts/navigation/walkability_grid.gd")
const FlowFieldScript := preload("res://scripts/flow_field.gd")
const MovementProfileScript := preload("res://scripts/prototypes/movement_profile.gd")
const MERGED_SHADER := preload("res://shaders/golem_fodder_merged.gdshader")

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
const BODY_OFFSET := 0.65
const MAX_HEALTH := 60.0
const HITSTUN_MIN := 0.35
const MAX_DEBRIS := 72
const AVOID_DISTANCE := 1.7
const AVOID_INTERVAL := 3
const AVOID_HOLD := 0.25
const AVOID_STEP := 1.0
const STEP_HEIGHT := 0.7
const SURFACE_EXTENT := 80.0
const SURFACE_CELL := 1.0
const WALKABILITY_PATH := "res://data/navigation/sanctum_walkability.json"
const SURFACE_BUILD_DELAY_FRAMES := 8
const RESOLVE_INTERVAL := 2
const RESOLVE_RADIUS := 0.35
const RESOLVE_CENTER := 0.05

const STATE_MOVE := 0
const STATE_WINDUP := 1
const STATE_RECOVER := 2
const STATE_HITSTUN := 3
const STATE_DEAD := 4

var player: Node3D
var flow: RefCounted
var profile
var step_height := STEP_HEIGHT
var avoid_step := AVOID_STEP
var count := 0

var _positions := PackedVector3Array()
var _velocity := PackedVector3Array()
var _yaw := PackedFloat32Array()
var _cooldown := PackedFloat32Array()
var _timer := PackedFloat32Array()
var _health := PackedFloat32Array()
var _state := PackedByteArray()
var _phase := PackedFloat32Array()
var _flash := PackedFloat32Array()
var _move_weight := PackedFloat32Array()
var _alive := PackedByteArray()
var _render_indices := PackedInt32Array()
var _avoid_dirs := PackedVector3Array()
var _avoid_timers := PackedFloat32Array()
var _slot_angle := PackedFloat32Array()
var _slot_radius := PackedFloat32Array()
var _detour_dir := PackedVector3Array()
var _detour_timer := PackedFloat32Array()
var _ground_heights := PackedFloat32Array()
var _resolve_shape: CapsuleShape3D
var _resolve_query: PhysicsShapeQueryParameters3D
var _cast_query: PhysicsShapeQueryParameters3D
var _point_query: PhysicsPointQueryParameters3D
var _surface
var _surface_ready := false
var surface_build_ms := 0.0
var _flow_clock := 0.0
var _flow_anchor := Vector3.ZERO
var _surface_delay := SURFACE_BUILD_DELAY_FRAMES
var _flow_inited := false
var _dirty_centers: Array[Vector2] = []
var _dirty_clock := 0.0

var _multimesh: MultiMesh
var _multimesh_instance: MultiMeshInstance3D
var _body_material: ShaderMaterial
var _torso_mesh: Mesh
var _core_mesh: Mesh
var _fist_mesh: Mesh
var _leg_mesh: Mesh
var _debris_materials: Array[StandardMaterial3D] = []
var _debris_count := 0

var alive_count := 0
var active_attackers := 0
var total_attacks := 0
var hits_taken := 0
var kills := 0
var ray_queries := 0
var resolve_hits := 0
var resolve_inside := 0
var under_platform := 0
var _flow_debug := false
var _flow_debug_mesh: MeshInstance3D
var _flow_debug_panel: Control
var _flow_debug_layer: CanvasLayer
var _flow_debug_clock := 0.0


func setup(target: Node3D, field: RefCounted, amount: int, center: Vector3,
		movement_profile = null) -> void:
	player = target
	flow = field
	profile = movement_profile if movement_profile != null else MovementProfileScript.new()
	step_height = profile.step_height
	avoid_step = profile.avoid_step
	count = amount
	_positions.resize(count)
	_velocity.resize(count)
	_yaw.resize(count)
	_cooldown.resize(count)
	_timer.resize(count)
	_health.resize(count)
	_state.resize(count)
	_phase.resize(count)
	_flash.resize(count)
	_move_weight.resize(count)
	_alive.resize(count)
	_avoid_dirs.resize(count)
	_avoid_timers.resize(count)
	_slot_angle.resize(count)
	_slot_radius.resize(count)
	_detour_dir.resize(count)
	_detour_timer.resize(count)
	_ground_heights.resize(count)
	_build_visuals()
	alive_count = count
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
		_health[index] = MAX_HEALTH
		_state[index] = STATE_MOVE
		_phase[index] = float(index) * 0.618
		_flash[index] = 0.0
		_move_weight[index] = 1.0
		_alive[index] = 1
		_avoid_dirs[index] = Vector3.ZERO
		_avoid_timers[index] = 0.0
		# 黄金角分位：靠近玩家后走向自己的槽位，避免全部从同一侧挤成一条线。
		_slot_angle[index] = float(index) * 2.399963 + 0.35
		_slot_radius[index] = ATTACK_RANGE + 0.25 + float(index % 3) * 0.9
		_detour_dir[index] = Vector3.ZERO
		_detour_timer[index] = 0.0
		_ground_heights[index] = Terrain.height_at(x, z)
	add_to_group("fodder_fields")
	_resolve_shape = CapsuleShape3D.new()
	_resolve_shape.radius = RESOLVE_RADIUS
	_resolve_shape.height = 1.3
	_resolve_query = PhysicsShapeQueryParameters3D.new()
	_resolve_query.shape = _resolve_shape
	_resolve_query.collision_mask = 1
	_resolve_query.collide_with_areas = false
	_resolve_query.collide_with_bodies = true
	_cast_query = PhysicsShapeQueryParameters3D.new()
	_cast_query.shape = _resolve_shape
	_cast_query.collision_mask = 1
	_cast_query.collide_with_areas = false
	_cast_query.collide_with_bodies = true
	_surface = WalkabilityGridScript.new()
	if _surface.load_json(WALKABILITY_PATH):
		_surface_ready = true
		surface_build_ms = 0.0
		print("[fodder] walkability loaded %s vertices=%d" % [WALKABILITY_PATH, _surface.n * _surface.n])
	else:
		print("[fodder] walkability missing, will bake once at runtime")
	for prop in get_tree().get_nodes_in_group("destructible_props"):
		if is_instance_valid(prop) and not prop.tree_exiting.is_connected(_on_destructible_exiting):
			prop.tree_exiting.connect(_on_destructible_exiting.bind(prop))
	_point_query = PhysicsPointQueryParameters3D.new()
	_point_query.collision_mask = 1
	_point_query.collide_with_areas = false
	_point_query.collide_with_bodies = true


func _build_visuals() -> void:
	var tool := SurfaceTool.new()
	tool.begin(Mesh.PRIMITIVE_TRIANGLES)
	var cursor := 0
	var torso := CylinderMesh.new()
	torso.top_radius = 0.4
	torso.bottom_radius = 0.25
	torso.height = 0.6
	torso.radial_segments = 5
	torso.rings = 0
	_torso_mesh = torso
	cursor = _append_part(tool, torso, Transform3D(Basis(), Vector3(0, 0.75, 0)),
		0, Vector3(0, 0.75, 0), cursor)
	var core := BoxMesh.new()
	core.size = Vector3(0.16, 0.16, 0.16)
	_core_mesh = core
	var core_basis := Basis.from_euler(Vector3(deg_to_rad(45), deg_to_rad(45), 0))
	cursor = _append_part(tool, core, Transform3D(core_basis, Vector3(0, 0.87, 0.32)),
		1, Vector3(0, 0.87, 0.32), cursor)
	var fist := BoxMesh.new()
	fist.size = Vector3(0.28, 0.42, 0.32)
	_fist_mesh = fist
	cursor = _append_part(tool, fist, Transform3D(Basis(), Vector3(-0.6, 0.6, 0)),
		2, Vector3(-0.45, 0.9, 0), cursor)
	cursor = _append_part(tool, fist, Transform3D(Basis.from_scale(Vector3.ONE * 1.15), Vector3(0.6, 0.6, 0)),
		3, Vector3(0.45, 0.9, 0), cursor)
	var leg := BoxMesh.new()
	leg.size = Vector3(0.18, 0.35, 0.22)
	_leg_mesh = leg
	cursor = _append_part(tool, leg, Transform3D(Basis(), Vector3(-0.22, 0.2, 0)),
		4, Vector3(-0.22, 0.35, 0), cursor)
	cursor = _append_part(tool, leg, Transform3D(Basis(), Vector3(0.22, 0.2, 0)),
		5, Vector3(0.22, 0.35, 0), cursor)

	_body_material = ShaderMaterial.new()
	_body_material.shader = MERGED_SHADER
	_body_material.set_shader_parameter("body_color", Color(0.28, 0.32, 0.22))
	_body_material.set_shader_parameter("core_color", Color(0.10, 0.85, 0.90))
	_body_material.set_shader_parameter("fist_color", Color(0.42, 0.44, 0.45))
	_body_material.set_shader_parameter("leg_color", Color(0.28, 0.32, 0.22))

	_multimesh = MultiMesh.new()
	_multimesh.transform_format = MultiMesh.TRANSFORM_3D
	_multimesh.use_custom_data = true
	_multimesh.mesh = tool.commit()
	_multimesh.instance_count = count
	_multimesh.visible_instance_count = count
	_multimesh.custom_aabb = AABB(Vector3(-1000, -100, -1000), Vector3(2000, 400, 2000))
	_multimesh_instance = MultiMeshInstance3D.new()
	_multimesh_instance.name = "FodderFieldMesh"
	_multimesh_instance.multimesh = _multimesh
	_multimesh_instance.material_override = _body_material
	add_child(_multimesh_instance)

	for color in [Color(0.28, 0.32, 0.22), Color(0.10, 0.85, 0.90),
			Color(0.42, 0.44, 0.45), Color(0.24, 0.28, 0.20)]:
		var material := StandardMaterial3D.new()
		material.albedo_color = color
		material.roughness = 0.95
		material.specular_mode = BaseMaterial3D.SPECULAR_DISABLED
		_debris_materials.append(material)


func _append_part(tool: SurfaceTool, mesh: Mesh, transform: Transform3D, part: int,
		pivot: Vector3, cursor: int) -> int:
	var arrays := mesh.surface_get_arrays(0)
	var vertices: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
	var normals: PackedVector3Array = arrays[Mesh.ARRAY_NORMAL]
	var indices: PackedInt32Array = arrays[Mesh.ARRAY_INDEX]
	var base := cursor
	for index in vertices.size():
		tool.set_uv(Vector2(float(part), pivot.x))
		tool.set_uv2(Vector2(pivot.y, pivot.z))
		tool.set_normal((transform.basis * normals[index]).normalized())
		tool.add_vertex(transform * vertices[index])
		cursor += 1
	for index in indices:
		tool.add_index(base + index)
	return cursor


func _on_destructible_exiting(prop: Node) -> void:
	if is_instance_valid(prop):
		_dirty_centers.append(Vector2(prop.global_position.x, prop.global_position.z))


func _init_surface_flow() -> void:
	_flow_inited = true
	var surface_flow := FlowFieldScript.new()
	# 流场按 profile 的坡度放行；ignore_terrain 的蜘蛛不做高度约束。
	surface_flow.set_height_profile(_surface, profile)
	surface_flow.rebuild(player.global_position)
	flow = surface_flow
	print("[fodder] surface step=%.2f profile=%s ignore=%s flow_cells=%d" % [
		step_height, profile.id, str(profile.ignore_terrain), surface_flow.reachable_cells])
	_flow_anchor = player.global_position
	_flow_clock = 0.0


func _physics_process(delta: float) -> void:
	if player == null or not is_instance_valid(player) or count <= 0:
		return
	if not _surface_ready and _surface != null:
		# 只有烘焙文件缺失时才回退到运行时构建；正常启动不应走到这里。
		if _surface_delay > 0:
			_surface_delay -= 1
			return
		_surface.build(get_world_3d(), Vector2.ZERO, SURFACE_EXTENT, SURFACE_CELL)
		_surface_ready = true
		surface_build_ms = _surface.build_usec / 1000.0
		print("[fodder] walkability baked at runtime ms=%.1f extent=%.0f cell=%.1f" % [
			surface_build_ms, SURFACE_EXTENT, SURFACE_CELL])
	if _surface_ready and not _flow_inited:
		_init_surface_flow()
	if _surface_ready and not _dirty_centers.is_empty():
		_dirty_clock += delta
		if _dirty_clock >= 0.3:
			_dirty_clock = 0.0
			for center: Vector2 in _dirty_centers:
				_surface.rebake_region(get_world_3d(), center, 12.0)
			_dirty_centers.clear()
			flow = null
			_flow_inited = false
	if flow != null:
		flow.poll_rebuild()
		_flow_clock += delta
		if player.global_position.distance_to(_flow_anchor) > 2.0 or _flow_clock >= 3.0:
			flow.request_rebuild(player.global_position)
			_flow_anchor = player.global_position
			_flow_clock = 0.0
		for index in count:
			if _alive[index] != 0:
				var p := _positions[index]
				var current_ground := p.y - BODY_OFFSET
				var target_ground: float = _surface.height_at(p.x, p.z)
				# 只允许 35cm 以内的抬升；高平台内的单位保持原位，让胶囊解算把它们推出去，
				# 避免首帧“瞬移站上高平台”。
				if target_ground - current_ground <= step_height + 0.001 \
						or target_ground - Terrain.height_at(p.x, p.z) <= step_height + 0.001:
					p.y = target_ground + BODY_OFFSET
					_positions[index] = p
				_ground_heights[index] = Terrain.height_at(p.x, p.z)
	var target := player.global_position
	if flow != null and flow.has_method("movement_target") and not bool(flow.get("tracking_player")):
		target = flow.movement_target()
	var grid: Dictionary = {}
	for index in count:
		if _alive[index] == 0:
			continue
		var p := _positions[index]
		var key := Vector2i(floori(p.x / 2.0), floori(p.z / 2.0))
		if not grid.has(key):
			grid[key] = []
		(grid[key] as Array).append(index)
	var active := 0
	for index in count:
		if _alive[index] == 0:
			continue
		var pos := _positions[index]
		# 硬性防钻地：低于地形就立刻抬回地面；不依赖 step 修正。
		var terrain_floor := Terrain.height_at(pos.x, pos.z) + BODY_OFFSET
		if pos.y < terrain_floor:
			pos.y = terrain_floor
			_positions[index] = pos
		# 用实际向下射线贴地，而不是 1m 最近格；陡坡上后者会把单位放进坡体。
		if (Engine.get_physics_frames() + index) % 4 == 0:
			var ground_ray := PhysicsRayQueryParameters3D.create(
				Vector3(pos.x, pos.y + 0.5, pos.z), Vector3(pos.x, pos.y - 4.0, pos.z), 1)
			var ground_hit := get_world_3d().direct_space_state.intersect_ray(ground_ray)
			if not ground_hit.is_empty():
				_ground_heights[index] = float(ground_hit.position.y)
			else:
				_ground_heights[index] = Terrain.height_at(pos.x, pos.z)
		var to := target - pos
		to.y = 0.0
		var distance := to.length()
		var state := int(_state[index])
		# 硬排除：不能站在高表面覆盖区的地面下（平台/大石头底部）。
		if _surface_ready and not profile.ignore_terrain:
			var terrain_here := Terrain.height_at(pos.x, pos.z)
			var surface_here := _ground_heights[index]
			var ground_here := pos.y - BODY_OFFSET
			if surface_here - terrain_here > step_height and ground_here - terrain_here <= step_height:
				var best_dir := Vector3.ZERO
				var best_height := INF
				for step_index in 8:
					var angle := TAU * float(step_index) / 8.0
					var probe := pos + Vector3(cos(angle), 0.0, sin(angle)) * 1.6
					var probe_height := _surface_height(probe.x, probe.z)
					if probe_height - terrain_here <= step_height and probe_height < best_height:
						best_height = probe_height
						best_dir = Vector3(cos(angle), 0.0, sin(angle))
				if best_dir.length_squared() > 0.001:
					pos += best_dir * 0.35
					pos.y = Terrain.height_at(pos.x, pos.z) + BODY_OFFSET
					_positions[index] = pos
					under_platform += 1
		_flash[index] = maxf(0.0, _flash[index] - delta * 3.0)
		if state == STATE_HITSTUN:
			_timer[index] -= delta
			pos += _velocity[index] * delta
			_velocity[index] *= maxf(0.0, 1.0 - delta * 5.0)
			pos = _snap_to_surface(pos, index)
			pos.y = maxf(pos.y, Terrain.height_at(pos.x, pos.z) + BODY_OFFSET)
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
		# 近距离改走自己的环形槽位，形成包围而不是排队。
		if distance < 14.0:
			var slot := target + Vector3(cos(_slot_angle[index]), 0.0,
				sin(_slot_angle[index])) * _slot_radius[index]
			var to_slot := slot - pos
			to_slot.y = 0.0
			if to_slot.length() > 0.2:
				direction = (direction * 0.35 + to_slot.normalized() * 1.35).normalized()
		_avoid_timers[index] = maxf(0.0, _avoid_timers[index] - delta)
		if (Engine.get_physics_frames() + index) % AVOID_INTERVAL == 0:
			var origin := pos + Vector3.UP * 0.6
			var query := PhysicsRayQueryParameters3D.create(origin, origin + direction * AVOID_DISTANCE, 1)
			var hit := get_world_3d().direct_space_state.intersect_ray(query)
			var avoid := Vector3.ZERO
			if not hit.is_empty():
				var normal: Vector3 = hit.normal
				normal.y = 0.0
				if normal.length_squared() > 0.001 and absf(float(hit.normal.y)) < 0.75:
					var tangent := normal.normalized().cross(Vector3.UP).normalized()
					if tangent.dot(to) < 0.0:
						tangent = -tangent
					avoid = tangent
			else:
				var ahead := pos + direction * 1.2
				var ahead_height := _surface_height(ahead.x, ahead.z)
				if absf(ahead_height - (pos.y - BODY_OFFSET)) > avoid_step:
					var ground_normal := Terrain.normal_at(ahead.x, ahead.z)
					ground_normal.y = 0.0
					if ground_normal.length_squared() > 0.001:
						var tangent2 := ground_normal.normalized().cross(Vector3.UP).normalized()
						if tangent2.dot(to) < 0.0:
							tangent2 = -tangent2
						avoid = tangent2
			if avoid.length_squared() > 0.001:
				_avoid_dirs[index] = avoid
				_avoid_timers[index] = AVOID_HOLD
		if _avoid_timers[index] > 0.0 and _avoid_dirs[index].length_squared() > 0.001:
			direction = (direction + _avoid_dirs[index] * 1.6).normalized()
		var push := Vector3.ZERO
		var cell := Vector2i(floori(pos.x / 2.0), floori(pos.z / 2.0))
		for dz in range(-1, 2):
			for dx in range(-1, 2):
				var bucket: Array = grid.get(Vector2i(cell.x + dx, cell.y + dz), [])
				for other: int in bucket:
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
		_detour_timer[index] = maxf(0.0, _detour_timer[index] - delta)
		if _detour_timer[index] > 0.0 and _detour_dir[index].length_squared() > 0.001:
			desired = (desired * 0.25 + _detour_dir[index] * 1.5).normalized()
		var probe := pos + desired * SPEED * delta
		var current_ground := pos.y - BODY_OFFSET
		var probe_ground := _surface_height(probe.x, probe.z)
		# 台阶检测要向前看 0.6m：cast 只看当前胶囊，脚还没进台面就先撞立面，
		# 会把本来能上的低台/坡沿误判成墙。
		var step_probe := pos + desired * 0.6
		var step_ground := _surface_height(step_probe.x, step_probe.z)
		var step_change := step_ground - current_ground
		var step_up := step_change > 0.0 and step_change <= step_height
		var step_ok := absf(step_change) <= step_height
		var move_delta := desired * SPEED * delta
		# 目标只是抬脚可上的台阶时，不做 cast_motion：cast 会撞到垂直面，
		# 把 0.35m 台沿误判成墙。高墙/大落差才扫掠。
		if not profile.ignore_terrain and not step_ok:
			_cast_query.transform = Transform3D(Basis(), pos + Vector3.UP * RESOLVE_CENTER)
			_cast_query.motion = move_delta
			var fractions := get_world_3d().direct_space_state.cast_motion(_cast_query)
			if not fractions.is_empty():
				var safe: float = clampf(float(fractions[0]), 0.0, 1.0)
				move_delta *= safe
				if safe < 0.2 and _detour_timer[index] <= 0.0:
					var tangent := Vector3(-desired.z, 0.0, desired.x)
					if tangent.dot(to) < 0.0:
						tangent = -tangent
					_detour_dir[index] = tangent
					_detour_timer[index] = 0.6
		var next := pos + move_delta
		var next_ground := _surface_height(next.x, next.z)
		if step_up:
			next.y = step_ground + BODY_OFFSET
		if _surface_ready and not profile.ignore_terrain and absf(next_ground - current_ground) > step_height:
			# 正面被台阶/平台挡住时，沿 X 或 Z 单轴滑动，避免整群顶死在边缘。
			var slide_x := pos + Vector3(desired.x, 0.0, 0.0) * SPEED * delta
			var slide_z := pos + Vector3(0.0, 0.0, desired.z) * SPEED * delta
			if absf(_surface_height(slide_x.x, slide_x.z) - current_ground) <= step_height:
				next = slide_x
			elif absf(_surface_height(slide_z.x, slide_z.z) - current_ground) <= step_height:
				next = slide_z
			else:
				next = pos
		pos = next
		pos = _snap_to_surface(pos, index)
		pos.y = maxf(pos.y, Terrain.height_at(pos.x, pos.z) + BODY_OFFSET)
		# 人群互推会把个体挤进平台/石头；每 2 个物理帧做一次共享 shape 解算，
		# 把重叠的身体沿接触法线推出去，避免整群站进静态几何。
		if (Engine.get_physics_frames() + index) % RESOLVE_INTERVAL == 0:
			for _pass in 2:
				var center := pos + Vector3.UP * RESOLVE_CENTER
				_resolve_query.transform = Transform3D(Basis(), center)
				var hits := get_world_3d().direct_space_state.intersect_shape(_resolve_query, 4)
				if hits.is_empty():
					# 球体完全在实体内部时 shape 查询不报；用中心点查询补“整只站进去”。
					_point_query.position = center
					var inside := get_world_3d().direct_space_state.intersect_point(_point_query, 4)
					if inside.is_empty():
						break
					resolve_inside += inside.size()
					var inside_push := Vector3.ZERO
					for hit in inside:
						var collider := hit.get("collider") as Node3D
						if is_instance_valid(collider):
							var away := center - collider.global_position
							away.y = 0.0
							if away.length_squared() > 0.001:
								inside_push += away.normalized()
					if inside_push.length_squared() < 0.0001:
						break
					pos += inside_push.normalized() * 0.28
					pos = _snap_to_surface(pos, index)
					continue
				resolve_hits += hits.size()
				var resolve_push := Vector3.ZERO
				for hit in hits:
					var normal: Vector3 = hit.get("normal", Vector3.ZERO)
					if normal.length_squared() < 0.001:
						var point: Vector3 = hit.get("point", center)
						normal = center - point
					normal.y = 0.0
					if normal.length_squared() > 0.001:
						resolve_push += normal.normalized()
				if resolve_push.length_squared() < 0.0001:
					break
				pos += resolve_push.normalized() * 0.22
				pos = _snap_to_surface(pos, index)
		_positions[index] = pos
		_yaw[index] = atan2(-desired.x, -desired.z)
		_move_weight[index] = 1.0
		_phase[index] += delta * 8.0
	active_attackers = active


func _snap_to_surface(pos: Vector3, index: int) -> Vector3:
	if not _surface_ready:
		pos.y = Terrain.height_at(pos.x, pos.z) + BODY_OFFSET
		return pos
	var current_ground := pos.y - BODY_OFFSET
	var target := _ground_heights[index]
	# 已经低于地形时无条件抬回；step 只限制“主动上台阶”，不能阻止纠错。
	var terrain_here := Terrain.height_at(pos.x, pos.z)
	if target > current_ground + 0.001 and target - terrain_here <= step_height + 0.001:
		pos.y = target + BODY_OFFSET
		return pos
	if profile.ignore_terrain or absf(target - current_ground) <= step_height + 0.001:
		pos.y = target + BODY_OFFSET
	return pos


func _surface_height(x: float, z: float) -> float:
	if _surface != null and _surface.ready:
		return _surface.nav_height_at(x, z)
	return Terrain.height_at(x, z)


func toggle_flow_debug() -> void:
	_flow_debug = not _flow_debug
	if _flow_debug and _flow_debug_panel == null:
		_flow_debug_layer = CanvasLayer.new()
		_flow_debug_layer.layer = 10
		add_child(_flow_debug_layer)
		_flow_debug_panel = Control.new()
		_flow_debug_panel.name = "FlowDebugPanel"
		_flow_debug_panel.position = Vector2(20, 150)
		_flow_debug_panel.size = Vector2(360, 400)
		_flow_debug_panel.mouse_filter = Control.MOUSE_FILTER_IGNORE
		_flow_debug_layer.add_child(_flow_debug_panel)
		_flow_debug_panel.draw.connect(_draw_flow_panel)
	if _flow_debug_panel != null:
		_flow_debug_panel.visible = _flow_debug
		_flow_debug_panel.queue_redraw()
	_flow_debug_clock = 0.0
	print("[fodder] flow_debug=%s" % str(_flow_debug))


func _draw_flow_panel() -> void:
	if _flow_debug_panel == null or flow == null or not _surface_ready or player == null:
		return
	var font := ThemeDB.fallback_font
	var size := _flow_debug_panel.size
	_flow_debug_panel.draw_rect(Rect2(Vector2.ZERO, size), Color(0.02, 0.03, 0.04, 0.8), true)
	_flow_debug_panel.draw_rect(Rect2(Vector2.ZERO, size), Color(0.4, 0.8, 0.9, 0.9), false, 1.0)
	_flow_debug_panel.draw_string(font, Vector2(8, 18),
		"FLOW 40m  cyan=dir  red=blocked  yellow=high",
		HORIZONTAL_ALIGNMENT_LEFT, -1, 12, Color(0.85, 0.95, 1.0))
	var center := Vector2(size.x * 0.5, size.y * 0.5 + 10.0)
	var radius_m := 20.0
	var scale := (size.x - 30.0) * 0.5 / radius_m
	var player_world := player.global_position
	for cell in flow.debug_cells(player_world, radius_m):
		var world: Vector3 = cell.world
		var local := Vector2(world.x - player_world.x, world.z - player_world.z)
		var point := center + Vector2(local.x, local.y) * scale
		var ground: float = _surface.height_at(world.x, world.z)
		var relative := ground - Terrain.height_at(world.x, world.z)
		if relative > 3.0:
			continue
		if relative > step_height:
			_flow_debug_panel.draw_rect(Rect2(point - Vector2(2, 2), Vector2(4, 4)),
				Color(1.0, 0.7, 0.05))
			continue
		if int(cell.distance) < 0:
			_flow_debug_panel.draw_rect(Rect2(point - Vector2(1.5, 1.5), Vector2(3, 3)),
				Color(1.0, 0.15, 0.08))
			continue
		var direction: Vector3 = cell.direction
		if direction.length_squared() < 0.001:
			continue
		_flow_debug_panel.draw_line(point, point + Vector2(direction.x, direction.z) * 7.0,
			Color(0.1, 1.0, 0.95), 1.5)
	_flow_debug_panel.draw_circle(center, 3.5, Color(1, 1, 1))
	_flow_debug_panel.draw_string(font, Vector2(8, size.y - 10),
		"player=white  F6 close", HORIZONTAL_ALIGNMENT_LEFT, -1, 11, Color(0.8, 0.9, 1.0))


func _rebuild_flow_debug() -> void:
	if not _flow_debug or _flow_debug_mesh == null or flow == null or not _surface_ready:
		return
	var mesh := ImmediateMesh.new()
	mesh.surface_begin(Mesh.PRIMITIVE_TRIANGLES)
	var debug_cell_count := 0
	var player_world := player.global_position
	for cell in flow.debug_cells(player_world, 22.0):
		var world: Vector3 = cell.world
		var horizontal := Vector2(world.x - player_world.x, world.z - player_world.z).length()
		# 玩家身边 3m 内的格子跳过：贴近相机的三角会糊满屏幕。
		if horizontal < 3.0 or horizontal > 20.0:
			continue
		var ground: float = _surface.height_at(world.x, world.z)
		var relative := ground - Terrain.height_at(world.x, world.z)
		# 树冠/远景高面不作为“可走表面”画，避免天空黄块。
		if relative > 3.0:
			continue
		debug_cell_count += 1
		var base := Vector3(world.x, ground + 1.2, world.z)
		var blocked: bool = int(cell.distance) < 0
		var high: bool = relative > step_height
		if high:
			_add_debug_square(mesh, base, 0.18, Color(1.0, 0.7, 0.05))
			continue
		if blocked:
			_add_debug_square(mesh, base, 0.16, Color(1.0, 0.1, 0.05))
			continue
		var direction: Vector3 = cell.direction
		if direction.length_squared() < 0.001:
			continue
		_add_debug_arrow(mesh, base, direction, Color(0.05, 1.0, 0.95))
	mesh.surface_end()
	_flow_debug_mesh.mesh = mesh


func _add_debug_tri(mesh: ImmediateMesh, a: Vector3, b: Vector3, c: Vector3, color: Color) -> void:
	for point in [a, b, c]:
		mesh.surface_set_color(color)
		mesh.surface_add_vertex(point)


func _add_debug_square(mesh: ImmediateMesh, center: Vector3, half: float, color: Color) -> void:
	var a := center + Vector3(-half, 0, -half)
	var b := center + Vector3(half, 0, -half)
	var c := center + Vector3(half, 0, half)
	var d := center + Vector3(-half, 0, half)
	_add_debug_tri(mesh, a, b, c, color)
	_add_debug_tri(mesh, a, c, d, color)


func _add_debug_arrow(mesh: ImmediateMesh, base: Vector3, direction: Vector3, color: Color) -> void:
	var flat := Vector3(direction.x, 0.0, direction.z).normalized()
	var side := Vector3(-flat.z, 0.0, flat.x)
	var tip := base + flat * 0.95
	var left := base + side * 0.16
	var right := base - side * 0.16
	_add_debug_tri(mesh, left, right, tip, color)
	var shaft_a := base + side * 0.05
	var shaft_b := base - side * 0.05
	var shaft_c := base + flat * 0.55 + side * 0.05
	var shaft_d := base + flat * 0.55 - side * 0.05
	_add_debug_tri(mesh, shaft_a, shaft_b, shaft_c, color)
	_add_debug_tri(mesh, shaft_b, shaft_d, shaft_c, color)


func _process(_delta: float) -> void:
	if _flow_debug:
		_flow_debug_clock += _delta
		if _flow_debug_clock >= 0.4:
			_flow_debug_clock = 0.0
			if _flow_debug_panel != null:
				_flow_debug_panel.queue_redraw()
	if _multimesh == null:
		return
	_render_indices.clear()
	for index in count:
		if _alive[index] != 0:
			_render_indices.append(index)
	alive_count = _render_indices.size()
	var visual_root := Transform3D(Basis(Vector3.UP, PI), Vector3(0, -0.65, 0))
	for slot in _render_indices.size():
		var index := _render_indices[slot]
		var display_pos := _positions[index]
		display_pos.y = maxf(display_pos.y,
			Terrain.height_at(display_pos.x, display_pos.z) + BODY_OFFSET)
		var body := Transform3D(Basis(Vector3.UP, _yaw[index]), display_pos)
		_multimesh.set_instance_transform(slot, body * visual_root)
		var attack := 0.0
		if _state[index] == STATE_WINDUP:
			attack = 0.5 * (1.0 - _timer[index] / ATTACK_WINDUP)
		elif _state[index] == STATE_RECOVER:
			attack = 1.0 - 0.5 * (1.0 - _timer[index] / ATTACK_RECOVER)
		var custom := Color(_phase[index], attack, _flash[index], _move_weight[index])
		_multimesh.set_instance_custom_data(slot, custom)
	_multimesh.visible_instance_count = alive_count


func raycast_hit(origin: Vector3, direction: Vector3, max_distance: float, damage: float,
		push: float = 2.0) -> int:
	ray_queries += 1
	var dir := direction.normalized()
	var best_index := -1
	var best_t := max_distance
	for index in count:
		if _alive[index] == 0:
			continue
		var offset := _positions[index] - origin
		var t := offset.dot(dir)
		if t < 0.0 or t > best_t:
			continue
		var closest := origin + dir * t
		# 用垂直胶囊近似：身体中心在脚底上方约 0.65m，眼睛/枪口通常高约 1m。
		var vertical := absf(closest.y - _positions[index].y)
		var horizontal := Vector2(closest.x - _positions[index].x, closest.z - _positions[index].z).length()
		if vertical > 1.55 or horizontal > 0.7:
			continue
		best_t = t
		best_index = index
	if best_index < 0:
		return 0
	apply_hit(best_index, damage, dir * push, HITSTUN_MIN)
	return 1


func cone_hit(origin: Vector3, forward: Vector3, reach: float, half_angle_rad: float,
		damage: float, push: float = 3.0) -> int:
	var hits := 0
	var flat_forward := Vector3(forward.x, 0.0, forward.z).normalized()
	for index in count:
		if _alive[index] == 0:
			continue
		var offset := _positions[index] - origin
		offset.y = 0.0
		var distance := offset.length()
		if distance > reach or distance < 0.001:
			continue
		if flat_forward.dot(offset / distance) < cos(half_angle_rad):
			continue
		apply_hit(index, damage, offset.normalized() * push, HITSTUN_MIN)
		hits += 1
	return hits


func radial_hit(center: Vector3, radius: float, damage: float, push: float = 4.0,
		stagger_seconds: float = 0.0) -> int:
	var hits := 0
	for index in count:
		if _alive[index] == 0:
			continue
		var offset := _positions[index] - center
		offset.y = 0.0
		var distance := offset.length()
		if distance > radius:
			continue
		var direction := offset.normalized() if distance > 0.001 else Vector3.FORWARD
		apply_hit(index, damage, direction * push, maxf(HITSTUN_MIN, stagger_seconds))
		hits += 1
	return hits


func apply_hit(index: int, damage: float, impulse: Vector3, stagger_seconds: float) -> void:
	if index < 0 or index >= count or _alive[index] == 0:
		return
	hits_taken += 1
	_health[index] -= damage
	_flash[index] = 1.0
	_velocity[index] = impulse
	_timer[index] = maxf(HITSTUN_MIN, stagger_seconds)
	if _health[index] <= 0.0:
		_die(index)
		return
	_state[index] = STATE_HITSTUN


func _die(index: int) -> void:
	if _alive[index] == 0:
		return
	_alive[index] = 0
	kills += 1
	alive_count -= 1
	_state[index] = STATE_DEAD
	_spawn_debris(index)


func _spawn_debris(index: int) -> void:
	if _debris_count >= MAX_DEBRIS:
		return
	var body := Transform3D(Basis(Vector3.UP, _yaw[index]), _positions[index])
	var visual_root := Transform3D(Basis(Vector3.UP, PI), Vector3(0, -0.65, 0))
	var root := body * visual_root
	var parts := [
		[root * Transform3D(Basis(), Vector3(0, 0.75, 0)), _torso_mesh, 0],
		[root * Transform3D(Basis(), Vector3(0, 0.87, 0.32)), _core_mesh, 1],
		[root * Transform3D(Basis(), Vector3(-0.6, 0.6, 0)), _fist_mesh, 2],
		[root * Transform3D(Basis(), Vector3(0.6, 0.6, 0)), _fist_mesh, 2],
		[root * Transform3D(Basis(), Vector3(-0.22, 0.2, 0)), _leg_mesh, 3],
		[root * Transform3D(Basis(), Vector3(0.22, 0.2, 0)), _leg_mesh, 3],
	]
	var scene := get_tree().current_scene
	if scene == null:
		scene = get_parent()
	var count_parts := mini(parts.size(), MAX_DEBRIS - _debris_count)
	for part_index in count_parts:
		var part: Array = parts[part_index]
		var rb := RigidBody3D.new()
		rb.collision_layer = 0
		rb.collision_mask = 1
		rb.mass = 0.4
		rb.add_to_group("fodder_debris")
		var shape := CollisionShape3D.new()
		var box := BoxShape3D.new()
		box.size = Vector3(0.28, 0.3, 0.28)
		shape.shape = box
		rb.add_child(shape)
		var mesh_instance := MeshInstance3D.new()
		mesh_instance.mesh = part[1]
		mesh_instance.material_override = _debris_materials[int(part[2])]
		rb.add_child(mesh_instance)
		scene.add_child(rb)
		rb.global_transform = part[0]
		var direction := Vector3(randf_range(-1, 1), randf_range(0.2, 1.0), randf_range(-1, 1))
		rb.linear_velocity = direction * randf_range(2.0, 5.0)
		rb.angular_velocity = direction * randf_range(1.0, 4.0)
		get_tree().create_timer(6.0).timeout.connect(rb.queue_free)
		_debris_count += 1


func nearest_reachable(position: Vector3) -> Vector3:
	if flow == null:
		return position
	return flow.nearest_reachable(position)


func is_world_reachable(position: Vector3) -> bool:
	return flow != null and flow.is_reachable(position)


func units() -> int:
	return count


func is_surface_ready() -> bool:
	return _surface_ready


func body_offset() -> float:
	return BODY_OFFSET


func live_positions() -> Array[Vector3]:
	var result: Array[Vector3] = []
	for index in count:
		if _alive[index] != 0:
			result.append(_positions[index])
	return result


func reset_stats() -> void:
	total_attacks = 0
	hits_taken = 0
	kills = 0
