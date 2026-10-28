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
const NavDatasetScript := preload("res://scripts/navigation/nav_dataset.gd")
const MovementProfileScript := preload("res://scripts/prototypes/movement_profile.gd")
const MERGED_SHADER := preload("res://shaders/golem_fodder_merged.gdshader")
const FodderVisualsScript := preload("res://scripts/prototypes/fodder_visuals.gd")

const SPEED := 3.4
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
const SURFACE_BUILD_DELAY_FRAMES := 8
const RESOLVE_INTERVAL := 2
const MAX_SEPARATION_NEIGHBORS := 24
## 分层：完整合同只给最近的一笔固定预算，其余按距离降档。
## 近身预算与人数无关，1000 只和 200 只付的是同一份物理账。
const TIER_FULL := 0
const TIER_CHEAP := 1
const TIER_FAR := 2
const FULL_BUDGET := 140
const FULL_RADIUS_MIN := 8.0
const FULL_RADIUS_MAX := 40.0
const FULL_EXIT_MARGIN := 2.5
const CHEAP_RADIUS := 48.0
const FAR_STRIDE := 6
const CHEAP_SEPARATION_NEIGHBORS := 8
const CHEAP_SEPARATION_RADIUS := 1.15
## 观感实验（默认关，观察台 F9 切换）：把人群摊开。
## 近身槽位从 3 环扩到 5 环，中距分离半径从 1.15 提到 1.65。
const SPREAD_CHEAP_SEPARATION_RADIUS := 1.65
const SPREAD_SEPARATION_STRENGTH_SCALE := 1.15
const SPREAD_SLOT_RINGS := 5
const SPREAD_SLOT_STEP := 1.3
## 扁平邻居哈希：2m 格，覆盖以 (-96,-96) 起点的 192m 见方。
const HASH_ORIGIN := Vector2(-96.0, -96.0)
const HASH_CELL := 2.0
const HASH_N := 96
## 上台阶后短暂保持高度，避免脚下旧地面把身体拉回台阶下。
const STEP_HOLD := 0.3
## 手动实验开关（默认关）：门洞/接战“跟车让行”。同场景 A/B 里 10s 到达 35→20、
## 20s 80→69，所以不作为默认行为；观察台 F8 可开开看队形，再决定是否值得正式做。
const QUEUE_PACING_RADIUS := 1.2
const QUEUE_PACING_MIN_SCALE := 0.35
const SLOT_RANGE := 14.0
const SLOT_RECHECK := 0.3

const STATE_MOVE := 0
const STATE_WINDUP := 1
const STATE_RECOVER := 2
const STATE_HITSTUN := 3
const STATE_DEAD := 4

var player: Node3D
var flow: RefCounted
var profile
var step_height := 0.0
var avoid_step := AVOID_STEP
var separation_radius := 0.0
var separation_strength := 0.0
## 地图导航数据（data/navigation/*.json）：walkability 路径、网格、流场、重建节奏。
var _nav: Dictionary = {}
## 身体/移动数据来自 MovementProfile；运行时胶囊、扫掠和台体判定共用同一份。
var _resolve_radius := 0.0
var _resolve_height := 0.0
var _resolve_center := 0.0
var _sweep_lift := 0.0
var _step_probe := 0.0
var _step_lookahead := 0.0
var _support_reach := 0.0
## 默认关：见 QUEUE_PACING_RADIUS 的 A/B 说明。观察台 F8 可切换。
var queue_pacing := false
## 观感实验：0=关，1=摊开（5 环 + 1.65 分离），2=站位（CHEAP 层向日葵环带）。
## 观察台 F9 循环切换；切入站位时按当前人数重算每只的槽位偏移。
var spread_mode := 0
var _cheap_slots := PackedVector2Array()
## 压上档（spread_mode=3）：编队中心按玩家速度前移，近身层按距离排名分环。
var _formation_center := Vector3.ZERO
var _player_velocity := Vector3.ZERO
var _player_last := Vector3.ZERO
var _formation_clock := 0.0
var count := 0
## 人群渲染/体型的种类 id（FodderSpecies 的 id）：必须在 setup 之前设置。
var species_id := "mud_golem"

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
var _flow_ready := false
var _dirty_centers: Array[Vector2] = []
var _dirty_clock := 0.0
var _last_positions := PackedVector3Array()
var _stuck_clock := 0.0
var _stuck_count := PackedByteArray()
var _attack_los_cache := PackedByteArray()
var _snapshot_positions := PackedVector3Array()
var _attack_wait := PackedFloat32Array()
var _speed := PackedFloat32Array()
var _step_hold := PackedFloat32Array()
var _step_ground := PackedFloat32Array()
var _slot_ok := PackedByteArray()
var _slot_timer := PackedFloat32Array()
var _blocked_ticks := PackedByteArray()
var _tier := PackedByteArray()
var _hash_head := PackedInt32Array()
var _hash_next := PackedInt32Array()
var _full_radius := FULL_RADIUS_MAX
var _full_cutoff := 1.0e9
var _full_list := PackedInt32Array()
var _tier_clock := 0.0
var cheap_units := 0
var far_units := 0
var _flow_direction_ok := false
var _support_query: PhysicsRayQueryParameters3D

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
var unstuck_count := 0
var spawn_relocations := 0
var step_up_count := 0
var blocked_hits := 0
var stalled_units := 0
var unreachable_units := 0
var _move_blocked := false
var _flow_debug := false
var _flow_debug_mesh: MeshInstance3D
var _flow_debug_panel: Control
var _flow_debug_layer: CanvasLayer
var _flow_debug_clock := 0.0


func setup(target: Node3D, field: RefCounted, amount: int, center: Vector3,
		movement_profile = null, nav_data := {}) -> void:
	_nav = nav_data
	if _nav.is_empty():
		push_error("[fodder] 缺少导航数据（data/navigation/*.json），不猜默认地图")
		return
	player = target
	flow = field
	_flow_direction_ok = field != null and field.has_method("direction_at")
	profile = movement_profile if movement_profile != null else NavDatasetScript.load_profile(_nav)
	if profile == null:
		return
	step_height = profile.step_height
	avoid_step = profile.avoid_step
	separation_radius = profile.separation_radius
	separation_strength = profile.separation_strength
	_resolve_radius = profile.radius
	_resolve_height = profile.body_height
	_resolve_center = profile.foot_clearance + profile.body_height * 0.5 - BODY_OFFSET
	_sweep_lift = profile.sweep_lift
	_step_probe = profile.step_probe
	_step_lookahead = profile.step_lookahead
	_support_reach = profile.support_reach
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
	_last_positions.resize(count)
	_stuck_count.resize(count)
	_attack_los_cache.resize(count)
	_snapshot_positions.resize(count)
	_attack_wait.resize(count)
	_speed.resize(count)
	_step_hold.resize(count)
	_step_ground.resize(count)
	_slot_ok.resize(count)
	_slot_timer.resize(count)
	_blocked_ticks.resize(count)
	_tier.resize(count)
	_hash_next.resize(count)
	_hash_head.resize(HASH_N * HASH_N)
	_hash_head.fill(-1)
	_build_visuals()
	alive_count = count
	for index in count:
		var angle := TAU * float(index) / float(maxi(count, 1))
		var ring := 12.0 + float(index % 7) * 1.8
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
		_slot_radius[index] = _slot_radius_for(index, false)
		_detour_dir[index] = Vector3.ZERO
		_detour_timer[index] = 0.0
		_ground_heights[index] = Terrain.height_at(x, z)
		_last_positions[index] = _positions[index]
		_stuck_count[index] = 0
		_attack_wait[index] = 0.0
		_speed[index] = 0.0
		_step_hold[index] = 0.0
		_step_ground[index] = _ground_heights[index]
		_slot_ok[index] = 0
		_slot_timer[index] = float(index % 9) * 0.03
		_blocked_ticks[index] = 0
		_tier[index] = TIER_FULL
	add_to_group("fodder_fields")
	_resolve_shape = CapsuleShape3D.new()
	_resolve_shape.radius = _resolve_radius
	_resolve_shape.height = _resolve_height
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
	_support_query = PhysicsRayQueryParameters3D.new()
	_support_query.collision_mask = 1
	_support_query.collide_with_areas = false
	_support_query.collide_with_bodies = true
	_surface = WalkabilityGridScript.new()
	_surface.configure_body(profile)
	_surface.configure_rays(_nav.grid)
	if _surface.load_json(String(_nav.walkability)):
		_surface_ready = true
		surface_build_ms = 0.0
		print("[fodder] walkability loaded %s vertices=%d body=%.2f" % [
			String(_nav.walkability), _surface.n * _surface.n, _surface.body_radius])
		if not is_equal_approx(_surface.body_radius, profile.radius) \
				or not is_equal_approx(_surface.body_height, profile.body_height) \
				or not is_equal_approx(_surface.body_lift, profile.sweep_lift):
			push_warning("[fodder] walkability body=%.2f/%.2f/%.2f != profile=%.2f/%.2f/%.2f; 需要重烘焙"
				% [_surface.body_radius, _surface.body_height, _surface.body_lift,
					profile.radius, profile.body_height, profile.sweep_lift])
	else:
		print("[fodder] walkability missing, will bake once at runtime")
	for prop in get_tree().get_nodes_in_group("destructible_props"):
		if is_instance_valid(prop) and not prop.tree_exiting.is_connected(_on_destructible_exiting):
			prop.tree_exiting.connect(_on_destructible_exiting.bind(prop))
	_point_query = PhysicsPointQueryParameters3D.new()
	_point_query.collision_mask = 1
	_point_query.collide_with_areas = false
	_point_query.collide_with_bodies = true
	if _surface_ready:
		for index in count:
			_place_out_of_blocker(index)
			_place_out_of_raised_surface(index)
			_place_out_of_body_overlap(index)


func _line_clear_to_target(pos: Vector3, target: Vector3) -> bool:
	var from := pos + Vector3.UP * 0.8
	var to := target + Vector3.UP * 0.8
	var query := PhysicsRayQueryParameters3D.create(from, to, 1)
	return get_world_3d().direct_space_state.intersect_ray(query).is_empty()


func _choose_escape_direction(pos: Vector3, desired: Vector3, to_target: Vector3) -> Vector3:
	if _surface == null or not _surface.ready:
		return desired
	var best := desired
	var best_score := -INF
	var direction_to_target := Vector3(to_target.x, 0.0, to_target.z)
	direction_to_target = direction_to_target.normalized() \
		if direction_to_target.length_squared() > 0.001 else desired
	var feet := pos.y - BODY_OFFSET
	for index in 12:
		var angle := TAU * float(index) / 12.0
		var candidate := Vector3(cos(angle), 0.0, sin(angle))
		var probe := pos + candidate * 1.4
		if _surface.blocked_at(probe.x, probe.z):
			continue
		# 只在同一层上绕行：探针处支撑高度超出台阶就不算可走方向。
		var support := _support_at(probe.x, probe.z, feet)
		if is_nan(support) or absf(support - feet) > step_height + 0.05:
			continue
		var clearance: float = _surface.clearance_at(probe.x, probe.z)
		var score: float = clearance * 2.0 + candidate.dot(desired) * 1.2 \
			+ candidate.dot(direction_to_target) * 0.2
		if score > best_score:
			best_score = score
			best = candidate
	return best


func _place_out_of_blocker(index: int) -> void:
	var p := _positions[index]
	if not _surface.blocked_at(p.x, p.z):
		return
	var open: Vector3 = _surface.nearest_open_away(p.x, p.z, player.global_position, 12)
	var away := Vector3(open.x - p.x, 0.0, open.z - p.z)
	if away.length_squared() < 0.001:
		away = Vector3.FORWARD
	away = away.normalized()
	var shifted := open + away * 1.2
	if not _surface.blocked_at(shifted.x, shifted.z):
		open = shifted
	# 出生合法化：只在 setup 时执行一次，是落点投影，不算运行期脱困。
	_positions[index] = open + Vector3.UP * BODY_OFFSET
	_ground_heights[index] = open.y
	_step_ground[index] = open.y
	_velocity[index] = Vector3.ZERO
	_state[index] = STATE_MOVE
	_detour_dir[index] = away
	_detour_timer[index] = 0.8
	unstuck_count += 1


## 出生点落在高台/石头“内部”时（脚下是地形，但该格的行走面在 0.7m 以上），
## 投影到最近的一层地面开放格。blocked 只说明身体在“台面上”能否站下，
## 不能说明单位是不是被塞进了台体里，所以需要单独检查。
func _place_out_of_raised_surface(index: int) -> void:
	if not _surface_ready:
		return
	var p := _positions[index]
	var terrain := Terrain.height_at(p.x, p.z)
	var feet := p.y - BODY_OFFSET
	var walk: float = _surface.nav_height_at(p.x, p.z)
	if walk - terrain <= step_height + 0.05:
		return
	if feet - terrain > step_height + 0.05:
		return
	var target := _nearest_ground_cell(p)
	var offset := Vector3(target.x - p.x, 0.0, target.z - p.z)
	if offset.length() < 0.05:
		return
	_positions[index] = target + Vector3.UP * BODY_OFFSET
	_ground_heights[index] = target.y
	_step_ground[index] = target.y
	_velocity[index] = Vector3.ZERO
	_state[index] = STATE_MOVE
	_stuck_count[index] = 0
	_detour_dir[index] = offset.normalized()
	_detour_timer[index] = 0.8
	unstuck_count += 1


## 在通行表里找最近的“同层地面”格：不 blocked，且行走面与地形高差在台阶内。
func _nearest_ground_cell(p: Vector3) -> Vector3:
	var n: int = _surface.n
	var cell: float = _surface.cell_size
	var cx := clampi(int(round((p.x - _surface.origin.x) / cell)), 0, n - 1)
	var cz := clampi(int(round((p.z - _surface.origin.y) / cell)), 0, n - 1)
	for radius in range(0, 17):
		for dz in range(-radius, radius + 1):
			for dx in range(-radius, radius + 1):
				if radius > 0 and absi(dx) != radius and absi(dz) != radius:
					continue
				var ix := cx + dx
				var iz := cz + dz
				if ix < 0 or iz < 0 or ix >= n or iz >= n:
					continue
				var index := iz * n + ix
				if _surface.blocked[index] != 0:
					continue
				var walk: float = _surface.walk_heights[index]
				if walk - _surface.terrain_heights[index] > step_height + 0.05:
					continue
				return Vector3(_surface.origin.x + float(ix) * cell, walk,
					_surface.origin.y + float(iz) * cell)
	return p


## 1m 通行格是“格内某个点放得下身体”，不代表格心放得下；出生环如果正好落在
## 石头/岩壁内部，blocked=false 也救不了。这里用真实胶囊（与移动扫掠同一套抬升）
## 做体测试，把出生就嵌进几何的单位投到最近的体自由格。
func _body_free(position: Vector3) -> bool:
	_resolve_query.transform = Transform3D(Basis(),
		position + Vector3.UP * (_resolve_center + _sweep_lift))
	return get_world_3d().direct_space_state.intersect_shape(_resolve_query, 1).is_empty()


func _nearest_body_free_cell(p: Vector3) -> Vector3:
	var n: int = _surface.n
	var cell: float = _surface.cell_size
	var cx := clampi(int(round((p.x - _surface.origin.x) / cell)), 0, n - 1)
	var cz := clampi(int(round((p.z - _surface.origin.y) / cell)), 0, n - 1)
	for radius in range(0, 17):
		for dz in range(-radius, radius + 1):
			for dx in range(-radius, radius + 1):
				if radius > 0 and absi(dx) != radius and absi(dz) != radius:
					continue
				var ix := cx + dx
				var iz := cz + dz
				if ix < 0 or iz < 0 or ix >= n or iz >= n:
					continue
				var index := iz * n + ix
				if _surface.blocked[index] != 0:
					continue
				var walk: float = _surface.walk_heights[index]
				if walk - _surface.terrain_heights[index] > step_height + 0.05:
					continue
				var wx: float = _surface.origin.x + float(ix) * cell
				var wz: float = _surface.origin.y + float(iz) * cell
				if _body_free(Vector3(wx, walk + BODY_OFFSET, wz)):
					return Vector3(wx, walk, wz)
	return p


func _place_out_of_body_overlap(index: int) -> void:
	if not _surface_ready:
		return
	var p := _positions[index]
	if _body_free(p):
		return
	var target := _nearest_body_free_cell(p)
	var offset := Vector3(target.x - p.x, 0.0, target.z - p.z)
	if offset.length() < 0.05:
		return
	_positions[index] = target + Vector3.UP * BODY_OFFSET
	_ground_heights[index] = target.y
	_step_ground[index] = target.y
	_velocity[index] = Vector3.ZERO
	_state[index] = STATE_MOVE
	_stuck_count[index] = 0
	_detour_dir[index] = offset.normalized()
	_detour_timer[index] = 0.8
	unstuck_count += 1


## 物理支撑面：从脚上方向下打射线，得到身体真正站着的高度。
## 返回 NAN 表示下方没有几何（出图/悬空）。
func _support_at(x: float, z: float, feet: float) -> float:
	_support_query.from = Vector3(x, feet + step_height + 0.25, z)
	_support_query.to = Vector3(x, feet - _support_reach, z)
	var hit := get_world_3d().direct_space_state.intersect_ray(_support_query)
	if hit.is_empty():
		return NAN
	return float(hit.position.y)


## 把 Y 落到真实支撑面。上升受台阶高度限制；下降允许到下一层，
## 上台阶后的短暂保持避免脚下旧地面把身体拉回台面下。
func _settle_support(index: int, pos: Vector3) -> Vector3:
	var feet := pos.y - BODY_OFFSET
	var support := _support_at(pos.x, pos.z, feet)
	if is_nan(support):
		support = _surface.nav_height_at(pos.x, pos.z) if _surface_ready \
			else Terrain.height_at(pos.x, pos.z)
		if absf(support - feet) > step_height + 1.0:
			support = Terrain.height_at(pos.x, pos.z)
	if _step_hold[index] > 0.0:
		support = maxf(support, _step_ground[index])
	var rise := support - feet
	if rise > step_height + 0.02:
		# 支撑面比脚高出一台阶以上：身体不该被抬上去，等移动器从合法台阶登上去。
		return pos
	if feet - support > _support_reach + 0.5:
		return pos
	pos.y = maxf(support + BODY_OFFSET, _floor_height(pos.x, pos.z) + BODY_OFFSET)
	_ground_heights[index] = pos.y - BODY_OFFSET
	return pos


## 前方是否是一个可上的台阶；返回可抬升高度，0 表示不是。
## 0.9m 处仍不低于台面，才认作“可以站上去的台面”，薄墙顶/栏杆顶不算。
func _step_ahead(pos: Vector3, direction: Vector3) -> float:
	var flat := Vector3(direction.x, 0.0, direction.z)
	if flat.length_squared() < 1.0e-6:
		return 0.0
	flat = flat.normalized()
	var feet := pos.y - BODY_OFFSET
	var near_x := pos.x + flat.x * _step_probe
	var near_z := pos.z + flat.z * _step_probe
	if _surface_ready and _surface.blocked_at(near_x, near_z):
		return 0.0
	var near := _support_at(near_x, near_z, feet)
	if is_nan(near):
		return 0.0
	var rise := near - feet
	if rise <= 0.03 or rise > step_height:
		return 0.0
	var far := _support_at(pos.x + flat.x * _step_lookahead, pos.z + flat.z * _step_lookahead, feet)
	if is_nan(far) or far < near - 0.15:
		return 0.0
	return rise


## 统一水平位移：扫掠胶囊（抬离坡面）→ 台阶上抬 → 被挡时退到安全比例。
## 每一步位移都经过碰撞，不再用“高度差在台阶内就跳过扫掠”的判断，
## 因此平地薄墙、平台侧面和击退都受同一约束。
func _move_unit(index: int, pos: Vector3, motion: Vector3, to_target: Vector3,
		allow_step: bool) -> Vector3:
	_move_blocked = false
	if motion.length_squared() < 1.0e-10:
		return _settle_support(index, pos)
	# 通行表合同：下一格放不下这个身体就不要迈进去（已经在 blocked 格里时允许走出来）。
	# 没有这一层，流场/人群会把 0.76m 身体推进 1m 格里的 blocked 格，物理扫掠再把它卡住。
	if _surface_ready and not profile.ignore_terrain:
		var next_flat := pos + Vector3(motion.x, 0.0, motion.z)
		if not _surface.blocked_at(pos.x, pos.z) and _surface.blocked_at(next_flat.x, next_flat.z):
			_move_blocked = true
			return pos
	var space := get_world_3d().direct_space_state
	_cast_query.transform = Transform3D(Basis(), pos + Vector3.UP * (_resolve_center + _sweep_lift))
	_cast_query.motion = motion
	var fractions := space.cast_motion(_cast_query)
	var safe := 1.0
	if not fractions.is_empty():
		safe = clampf(float(fractions[0]), 0.0, 1.0)
	if safe >= 0.999:
		return _settle_support(index, pos + motion)
	if allow_step:
		var rise := _step_ahead(pos, motion)
		if rise > 0.0:
			_cast_query.transform = Transform3D(Basis(),
				pos + Vector3.UP * (_resolve_center + _sweep_lift + rise))
			_cast_query.motion = motion
			var lifted := space.cast_motion(_cast_query)
			if lifted.is_empty() or float(lifted[0]) >= 0.999:
				_step_hold[index] = STEP_HOLD
				_step_ground[index] = pos.y - BODY_OFFSET + rise
				step_up_count += 1
				return _settle_support(index, pos + Vector3.UP * rise + motion)
	if safe > 0.001:
		return _settle_support(index, pos + motion * safe)
	_move_blocked = true
	return pos


## 直线通路校验：按 0.5m 采样检查 blocked 与层高连续性。
## 用于“隔墙时不要用近身槽位覆盖流场”，也用于卡住时的可走逃逸点。
func _straight_route_ok(from: Vector3, to: Vector3) -> bool:
	if _surface == null or not _surface.ready:
		return true
	var delta := Vector3(to.x - from.x, 0.0, to.z - from.z)
	var distance := delta.length()
	if distance < 0.35:
		return true
	var steps := int(ceil(distance / 0.5))
	var previous: float = _surface.nav_height_at(from.x, from.z)
	for step in range(1, steps + 1):
		var t := float(step) / float(steps)
		var x := from.x + delta.x * t
		var z := from.z + delta.z * t
		if _surface.blocked_at(x, z):
			return false
		var height: float = _surface.nav_height_at(x, z)
		if absf(height - previous) > step_height + 0.02:
			return false
		previous = height
	return true


## 近身槽位只在到槽位有直线可走通路时接管方向；隔着墙就继续跟流场绕。
func _update_slot(index: int, pos: Vector3, target: Vector3, delta: float) -> void:
	_slot_timer[index] = maxf(0.0, _slot_timer[index] - delta)
	if _slot_timer[index] > 0.0:
		return
	_slot_timer[index] = SLOT_RECHECK + float(index % 7) * 0.03
	var slot := target + Vector3(cos(_slot_angle[index]), 0.0,
		sin(_slot_angle[index])) * _slot_radius[index]
	if _surface == null or not _surface.ready:
		_slot_ok[index] = 1
		return
	if _surface.blocked_at(slot.x, slot.z):
		_slot_ok[index] = 0
		return
	if _flow_ready and flow != null and not flow.is_reachable(slot):
		_slot_ok[index] = 0
		return
	# 槽位必须能直视玩家：墙内侧的槽位虽然可达，但站在那儿打不到人，
	# 只会把整群吸到墙根。没有视线就交回流场，先绕出去。
	if not _line_clear_to_target(slot, player.global_position):
		_slot_ok[index] = 0
		return
	_slot_ok[index] = 1 if _straight_route_ok(pos, slot) else 0


func _build_visuals() -> void:
	var table := FodderVisualsScript.table(species_id)
	var tool := SurfaceTool.new()
	tool.begin(Mesh.PRIMITIVE_TRIANGLES)
	var cursor := 0
	for part in table["parts"]:
		var mesh := FodderVisualsScript.make_mesh(part)
		var role := int(part["role"])
		if role == FodderVisualsScript.BODY and _torso_mesh == null:
			_torso_mesh = mesh
		elif role == FodderVisualsScript.CORE and _core_mesh == null:
			_core_mesh = mesh
		elif role == FodderVisualsScript.LIMB_FRONT and _fist_mesh == null:
			_fist_mesh = mesh
		elif role >= FodderVisualsScript.LIMB and _leg_mesh == null:
			_leg_mesh = mesh
		var euler: Vector3 = part.get("euler", Vector3.ZERO)
		var scale: float = float(part.get("scale", 1.0))
		var basis := Basis.from_euler(euler).scaled(Vector3.ONE * scale)
		cursor = _append_part(tool, mesh, Transform3D(basis, part["pos"]),
			part["pivot"], role, part["color"],
			float(part.get("glow", 0.0)), cursor)

	# 尸体碎块用代表性图元；没有对应角色的种类回落到躯干。
	if _torso_mesh == null:
		var fallback := BoxMesh.new()
		fallback.size = Vector3(0.5, 0.6, 0.5)
		_torso_mesh = fallback
	if _core_mesh == null:
		_core_mesh = _torso_mesh
	if _fist_mesh == null:
		_fist_mesh = _torso_mesh
	if _leg_mesh == null:
		_leg_mesh = _torso_mesh

	_body_material = ShaderMaterial.new()
	_body_material.shader = MERGED_SHADER

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


func _append_part(tool: SurfaceTool, mesh: Mesh, transform: Transform3D, pivot: Vector3,
		role: int, color: Color, glow: float, cursor: int) -> int:
	var arrays := mesh.surface_get_arrays(0)
	var vertices: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
	var normals: PackedVector3Array = arrays[Mesh.ARRAY_NORMAL]
	var indices: PackedInt32Array = arrays[Mesh.ARRAY_INDEX]
	var linear := color.srgb_to_linear()
	linear.a = glow
	var base := cursor
	for index in vertices.size():
		tool.set_color(linear)
		tool.set_uv(Vector2(pivot.x, pivot.y))
		tool.set_uv2(Vector2(pivot.z, float(role)))
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
	_flow_ready = false
	var surface_flow := FlowFieldScript.new()
	surface_flow.configure(_nav.flow, float(_nav.grid.half_extent))
	# 流场按 profile 的坡度放行；ignore_terrain 的蜘蛛不做高度约束。
	surface_flow.set_height_profile(_surface, profile)
	# 首次流场也走 worker，避免主线程同步全图 Dijkstra。
	surface_flow.request_rebuild(player.global_position)
	flow = surface_flow
	_flow_direction_ok = true
	_flow_anchor = player.global_position
	_flow_clock = 0.0
	print("[fodder] flow rebuild requested in worker")


## 出生投影：只在首次流场就绪后跑一次。只有“附近且直线可走”的可达格才搬过去；
## 隔墙的最近可达格会制造“穿墙瞬移”，直接放弃，让单位自己沿流场走出去。
func _legalize_spawn_relocations() -> void:
	if flow == null:
		return
	for index in count:
		if _alive[index] == 0:
			continue
		var pos := _positions[index]
		if flow.is_reachable(pos):
			continue
		var target: Vector3 = flow.nearest_reachable(pos)
		var offset := target - pos
		offset.y = 0.0
		if offset.length() < 0.5 or offset.length() > 5.0:
			continue
		if not _straight_route_ok(pos, target):
			continue
		_positions[index] = target + Vector3.UP * BODY_OFFSET
		_ground_heights[index] = target.y
		_step_ground[index] = target.y
		_velocity[index] = Vector3.ZERO
		_stuck_count[index] = 0
		_last_positions[index] = _positions[index]
		spawn_relocations += 1


## 每秒一次的真实进展检查。不做任何位置搬运：
## 没进展就换一个可走方向继续绕，仍走不动就保持等待，由移动器决定能不能过去。
func _update_stall_state() -> void:
	var stalled := 0
	var unreachable := 0
	for index in count:
		if _alive[index] == 0:
			continue
		var current := _positions[index]
		if _surface.blocked_at(current.x, current.z):
			_blocked_ticks[index] = mini(int(_blocked_ticks[index]) + 1, 255)
		else:
			_blocked_ticks[index] = 0
		var moved := current.distance_to(_last_positions[index])
		var goal_distance := current.distance_to(player.global_position)
		if moved < 0.1 and goal_distance > ATTACK_RANGE + 1.5:
			_stuck_count[index] = mini(int(_stuck_count[index]) + 1, 9)
		else:
			_stuck_count[index] = 0
		if flow != null and not flow.is_reachable(current):
			unreachable += 1
		if _stuck_count[index] >= 2:
			stalled += 1
			var escape: Vector3 = _surface.nearest_open(current.x, current.z, 12)
			var offset := Vector3(escape.x - current.x, 0.0, escape.z - current.z)
			if offset.length() > 0.4 and _straight_route_ok(current, escape):
				_detour_dir[index] = offset.normalized()
				_detour_timer[index] = 1.5
				_stuck_count[index] = 0
		_last_positions[index] = current
	stalled_units = stalled
	unreachable_units = unreachable


func _physics_process(delta: float) -> void:
	if player == null or not is_instance_valid(player) or count <= 0:
		return
	if not _surface_ready and _surface != null:
		# 只有烘焙文件缺失时才回退到运行时构建；正常启动不应走到这里。
		if _surface_delay > 0:
			_surface_delay -= 1
			return
		_surface.build(get_world_3d(), Vector2.ZERO,
			float(_nav.grid.half_extent), float(_nav.grid.cell_size))
		_surface_ready = true
		surface_build_ms = _surface.build_usec / 1000.0
		print("[fodder] walkability baked at runtime ms=%.1f extent=%.0f cell=%.1f" % [
			surface_build_ms, float(_nav.grid.half_extent), float(_nav.grid.cell_size)])
	if _surface_ready and not _flow_inited:
		_init_surface_flow()
	if _surface_ready and not _dirty_centers.is_empty():
		_dirty_clock += delta
		if _dirty_clock >= 0.3:
			_dirty_clock = 0.0
			var merged_centers: Array[Vector2] = []
			for center: Vector2 in _dirty_centers:
				var merged := false
				for existing_index in merged_centers.size():
					if merged_centers[existing_index].distance_to(center) < 12.0:
						merged_centers[existing_index] = (merged_centers[existing_index] + center) * 0.5
						merged = true
						break
				if not merged:
					merged_centers.append(center)
			for center: Vector2 in merged_centers:
				_surface.rebake_region(get_world_3d(), center,
					float(_nav.rebuild.rebake_radius))
			_dirty_centers.clear()
			flow = null
			_flow_inited = false
	if _surface_ready:
		_stuck_clock += delta
		if _stuck_clock >= 1.0:
			_stuck_clock = 0.0
			_update_stall_state()
	if flow != null:
		if flow.poll_rebuild():
			if not _flow_ready:
				_flow_ready = true
				print("[fodder] surface step=%.2f profile=%s ignore=%s flow_cells=%d" % [
					step_height, profile.id, str(profile.ignore_terrain), flow.reachable_cells])
				print("[fodder] flow_tracking=%s target=(%.1f,%.1f,%.1f)" % [
					str(flow.tracking_player), flow.target_position.x,
					flow.target_position.y, flow.target_position.z])
				_legalize_spawn_relocations()
		_flow_clock += delta
		var move_threshold := float(_nav.rebuild.move_threshold)
		var rebuild_interval := float(_nav.rebuild.interval)
		if player.global_position.distance_to(_flow_anchor) > move_threshold \
				or _flow_clock >= rebuild_interval:
			flow.request_rebuild(player.global_position)
			_flow_anchor = player.global_position
			_flow_clock = 0.0
	var target := player.global_position
	if flow != null and flow.has_method("movement_target") and not bool(flow.get("tracking_player")):
		target = flow.movement_target()
	var tracking := flow == null or bool(flow.get("tracking_player"))
	var attack_point := player.global_position
	if spread_mode == 3:
		var moved := player.global_position - _player_last
		_player_velocity = _player_velocity.lerp(moved / maxf(delta, 0.0001), 0.2)
		_player_last = player.global_position
		var lead := _player_velocity * 0.45
		if lead.length() > 2.0:
			lead = lead.normalized() * 2.0
		_formation_center = player.global_position + lead
		_update_formation(delta, attack_point)
	else:
		_player_last = player.global_position
		_player_velocity = Vector3.ZERO
		_formation_center = player.global_position
	_update_tiers(delta, attack_point)
	_rebuild_hash()
	var active := 0
	for index in _full_list:
		if _alive[index] == 0:
			continue
		if _state[index] == STATE_WINDUP or _state[index] == STATE_RECOVER:
			active += 1
	var granted := PackedByteArray()
	granted.resize(count)
	var candidates: Array[int] = []
	for index in _full_list:
		if _alive[index] == 0:
			continue
		if _state[index] != STATE_MOVE or _cooldown[index] > 0.0:
			_attack_wait[index] = 0.0
			continue
		var dx := _positions[index].x - attack_point.x
		var dz := _positions[index].z - attack_point.z
		if Vector2(dx, dz).length() <= ATTACK_RANGE + 0.5:
			_attack_wait[index] += delta
			candidates.append(index)
		else:
			_attack_wait[index] = 0.0
	candidates.sort_custom(func(a: int, b: int) -> bool:
		return _attack_wait[a] > _attack_wait[b])
	var available := maxi(0, MAX_ACTIVE_ATTACKERS - active)
	for candidate_index in mini(available, candidates.size()):
		granted[candidates[candidate_index]] = 1
	for index in count:
		if _alive[index] == 0:
			continue
		# 远处只跑流场 + 网格移动；只有近身预算内的单位走完整物理合同。
		if _tier[index] != TIER_FULL:
			if _tier[index] == TIER_FAR:
				if (Engine.get_physics_frames() + index) % FAR_STRIDE != 0:
					continue
				_step_far(index, delta * float(FAR_STRIDE), target)
			else:
				if (Engine.get_physics_frames() + index) % 2 != 0:
					continue
				_step_cheap(index, delta * 2.0, target)
			continue
		_step_hold[index] = maxf(0.0, _step_hold[index] - delta)
		var pos := _positions[index]
		# 硬性防钻地：低于地面就立刻抬回地面；不依赖 step 修正。
		# 高度取 1m 通行表（0.7µs），只有表未就绪或该格放不下身体时才回落 Terrain（26µs）。
		var terrain_floor := _floor_height(pos.x, pos.z) + BODY_OFFSET
		if pos.y < terrain_floor:
			pos.y = terrain_floor
			_positions[index] = pos
		var to := target - pos
		to.y = 0.0
		var distance := to.length()
		var attack_to := attack_point - pos
		attack_to.y = 0.0
		var attack_distance := attack_to.length()
		var attack_vertical_ok := absf(pos.y - attack_point.y) <= 1.8
		var attack_los := false
		if tracking and attack_vertical_ok and attack_distance <= ATTACK_RANGE + 1.0:
			if (Engine.get_physics_frames() + index) % 10 == 0:
				_attack_los_cache[index] = 1 if _line_clear_to_target(pos, attack_point) else 0
			attack_los = _attack_los_cache[index] != 0
		else:
			_attack_los_cache[index] = 0
		var state := int(_state[index])
		_flash[index] = maxf(0.0, _flash[index] - delta * 3.0)
		if state == STATE_HITSTUN:
			_timer[index] -= delta
			pos = _move_unit(index, pos, _velocity[index] * delta, to, false)
			_velocity[index] *= maxf(0.0, 1.0 - delta * 5.0)
			_positions[index] = pos
			_move_weight[index] = 0.0
			_speed[index] = 0.0
			if _timer[index] <= 0.0:
				_state[index] = STATE_MOVE
				_cooldown[index] = ATTACK_COOLDOWN * 0.5
			continue
		if state == STATE_WINDUP:
			_timer[index] -= delta
			pos = _settle_support(index, pos)
			_positions[index] = pos
			_move_weight[index] = 0.0
			_speed[index] = 0.0
			if _timer[index] <= 0.0:
				var hit_los := tracking and attack_vertical_ok \
					and _line_clear_to_target(pos, attack_point)
				if attack_distance <= ATTACK_RANGE + 0.7 and hit_los:
					var forward := Vector3(-sin(_yaw[index]), 0.0, -cos(_yaw[index]))
					if forward.dot(attack_to.normalized()) > 0.15 and player.has_method("take_damage"):
						player.call("take_damage", DAMAGE, pos)
						total_attacks += 1
						_flash[index] = 1.0
				_state[index] = STATE_RECOVER
				_timer[index] = ATTACK_RECOVER
			continue
		if state == STATE_RECOVER:
			_timer[index] -= delta
			_yaw[index] = atan2(-attack_to.x, -attack_to.z)
			_move_weight[index] = 0.0
			_speed[index] = 0.0
			_positions[index] = _settle_support(index, pos)
			if _timer[index] <= 0.0:
				_state[index] = STATE_MOVE
				_cooldown[index] = ATTACK_COOLDOWN
				active = maxi(0, active - 1)
			continue
		_cooldown[index] = maxf(0.0, _cooldown[index] - delta)
		if attack_distance <= ATTACK_RANGE and attack_los and _cooldown[index] <= 0.0 \
				and active < MAX_ACTIVE_ATTACKERS and granted[index] != 0:
			_state[index] = STATE_WINDUP
			_timer[index] = ATTACK_WINDUP
			_yaw[index] = atan2(-attack_to.x, -attack_to.z)
			_move_weight[index] = 0.0
			_speed[index] = 0.0
			_attack_wait[index] = 0.0
			active += 1
			continue
		var direction := Vector3.ZERO
		if _flow_direction_ok:
			direction = flow.direction_at(pos)
		if direction.length_squared() < 0.001:
			direction = to.normalized() if distance > 0.001 else Vector3.FORWARD
		# 近距离改走自己的环形槽位，形成包围而不是排队。
		# 只有到槽位存在直线可走通路时槽位才接管；隔着墙继续跟流场绕出去。
		if granted[index] != 0 and distance > ATTACK_RANGE - 0.3:
			# 拿到出手名额：直接压到攻击距离，不被槽位拉住。
			direction = attack_to.normalized()
			_slot_ok[index] = 0
		elif distance < SLOT_RANGE:
			_update_slot(index, pos, target, delta)
			if _slot_ok[index] != 0:
				var slot := target + Vector3(cos(_slot_angle[index]), 0.0,
					sin(_slot_angle[index])) * _slot_radius[index]
				var to_slot := slot - pos
				to_slot.y = 0.0
				if to_slot.length() > 0.2:
					direction = (direction * 0.35 + to_slot.normalized() * 1.35).normalized()
		else:
			_slot_ok[index] = 0
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
					# 沿墙滑动的方向跟随“这次想走的方向”，不能跟随指向玩家的直线；
					# 否则墙内侧的单位会被一路推向玩家方向的墙角，逆着流场走。
					var tangent := normal.normalized().cross(Vector3.UP).normalized()
					if tangent.dot(direction) < 0.0:
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
						if tangent2.dot(direction) < 0.0:
							tangent2 = -tangent2
						avoid = tangent2
			if avoid.length_squared() > 0.001:
				_avoid_dirs[index] = avoid
				_avoid_timers[index] = AVOID_HOLD
		if _avoid_timers[index] > 0.0 and _avoid_dirs[index].length_squared() > 0.001:
			direction = (direction + _avoid_dirs[index] * 1.6).normalized()
		var travel := direction
		var push := Vector3.ZERO
		var ahead_gap := INF
		var ahead_speed := SPEED
		var cell := _hash_cell_of(pos)
		var considered := 0
		if cell >= 0:
			var cell_x := cell % HASH_N
			var cell_z := int(cell / HASH_N)
			for dz in range(-1, 2):
				for dx in range(-1, 2):
					var bucket := _hash_index(cell_x + dx, cell_z + dz)
					if bucket < 0:
						continue
					var other := _hash_head[bucket]
					while other != -1:
						if considered >= MAX_SEPARATION_NEIGHBORS:
							break
						considered += 1
						if other != index:
							var offset := pos - _snapshot_positions[other]
							offset.y = 0.0
							var length := offset.length()
							if length > 0.001 and length < separation_radius:
								push += offset / length * (1.0 - length / separation_radius)
							# 实验用让行：只记录“行进方向前方最近的同伴”及其上一帧速度。
							if queue_pacing and length > 0.001 and length < QUEUE_PACING_RADIUS + 0.05:
								if -offset.dot(travel) > 0.55 * length and length < ahead_gap:
									ahead_gap = length
									ahead_speed = _speed[other]
						other = _hash_next[other]
					if considered >= MAX_SEPARATION_NEIGHBORS:
						break
				if considered >= MAX_SEPARATION_NEIGHBORS:
					break
		if distance > 0.001 and distance < PLAYER_RADIUS:
			push += -to.normalized() * (1.0 - distance / PLAYER_RADIUS) * 2.0
		var desired := (direction + push * separation_strength).normalized()
		_detour_timer[index] = maxf(0.0, _detour_timer[index] - delta)
		if _detour_timer[index] > 0.0 and _detour_dir[index].length_squared() > 0.001:
			# 凹角处不能用“径向 + 切线”混合，否则径向分量会持续把单位压回墙角。
			# 只按计时器结束，不用“看见玩家”提前结束：墙内侧本来就没有直线视线。
			desired = _detour_dir[index]
		var approach_scale := 1.0
		if distance < 2.2 and distance > 0.01:
			approach_scale = 0.55 + 0.45 * (distance / 2.2)
		# 前面的人慢才跟慢；他跑满速时保持间距、不额外减速。默认关闭。
		var queue_scale := 1.0
		if queue_pacing and ahead_gap < QUEUE_PACING_RADIUS:
			var follow_speed := ahead_speed + maxf(ahead_gap - 0.85, 0.0) * SPEED * 1.2
			queue_scale = clampf(follow_speed / SPEED, QUEUE_PACING_MIN_SCALE, 1.0)
		var motion := desired * SPEED * delta * approach_scale * queue_scale
		var before := pos
		pos = _move_unit(index, pos, motion, to, true)
		if _move_blocked:
			blocked_hits += 1
			if _detour_timer[index] <= 0.0:
				_detour_dir[index] = _choose_escape_direction(pos, desired, to)
				_detour_timer[index] = 0.8
		# 人群互推会把个体挤进平台/石头；共享 shape 解算只处理真正的墙接触，
		# 地面/斜坡接触不推出，推出量也走同一扫掠，避免推挤穿过薄墙。
		if (Engine.get_physics_frames() + index) % RESOLVE_INTERVAL == 0:
			pos = _resolve_overlap(index, pos, to)
		_positions[index] = pos
		var moved := pos.distance_to(before)
		# 动画跟实际位移走：挤在门口慢挪就慢迈步，完全被挡才停下，不再原地踏步或滑步。
		var expected := motion.length()
		var speed_ratio := moved / expected if expected > 0.0001 else 0.0
		speed_ratio = clampf(speed_ratio, 0.0, 1.0)
		_move_weight[index] = clampf(speed_ratio * 1.5, 0.0, 1.0)
		_phase[index] += delta * 8.0 * speed_ratio
		_speed[index] = moved / maxf(delta, 0.0001)
		_yaw[index] = atan2(-desired.x, -desired.z)
	active_attackers = active


## 扁平邻居哈希：每帧重建，用 PackedInt32Array 链表替代 Dictionary[Array]，
## 避免每帧上百个 Vector2i 键和 Array 分配。
func _rebuild_hash() -> void:
	_hash_head.fill(-1)
	for index in count:
		if _alive[index] == 0:
			continue
		var pos := _positions[index]
		_snapshot_positions[index] = pos
		var cell := _hash_cell_of(pos)
		if cell < 0:
			continue
		_hash_next[index] = _hash_head[cell]
		_hash_head[cell] = index


func _hash_cell_of(pos: Vector3) -> int:
	return _hash_index(
		floori((pos.x - HASH_ORIGIN.x) / HASH_CELL),
		floori((pos.z - HASH_ORIGIN.y) / HASH_CELL))


func _hash_index(cx: int, cz: int) -> int:
	if cx < 0 or cz < 0 or cx >= HASH_N or cz >= HASH_N:
		return -1
	return cz * HASH_N + cx


## 近身预算：每 0.25 秒取最近 FULL_BUDGET 只的距离分位作为硬阈值。
## 只按半径会被人群堆叠撑爆（半径内可能挤进几百只），所以必须按名次封顶。
func _recompute_full_radius(center: Vector3) -> void:
	var distances := PackedFloat32Array()
	distances.resize(count)
	var alive := 0
	for index in count:
		if _alive[index] == 0:
			distances[index] = 1.0e9
			continue
		alive += 1
		var pos := _positions[index]
		distances[index] = Vector2(pos.x - center.x, pos.z - center.z).length()
	if alive <= FULL_BUDGET:
		_full_cutoff = 1.0e9
		_full_radius = FULL_RADIUS_MAX
		return
	var sorted := distances.duplicate()
	sorted.sort()
	_full_cutoff = sorted[FULL_BUDGET - 1] + 0.001
	_full_radius = clampf(_full_cutoff, FULL_RADIUS_MIN, FULL_RADIUS_MAX)


func _update_tiers(delta: float, center: Vector3) -> void:
	_tier_clock += delta
	if _tier_clock >= 0.25:
		_tier_clock = 0.0
		_recompute_full_radius(center)
	cheap_units = 0
	far_units = 0
	_full_list.clear()
	for index in count:
		if _alive[index] == 0:
			continue
		var pos := _positions[index]
		var distance := Vector2(pos.x - center.x, pos.z - center.z).length()
		var want_full := distance <= _full_cutoff
		var tier := int(_tier[index])
		if _state[index] != STATE_MOVE:
			tier = TIER_FULL
		elif tier == TIER_FULL:
			if not want_full:
				tier = TIER_CHEAP if distance <= CHEAP_RADIUS else TIER_FAR
		elif tier == TIER_CHEAP:
			if want_full:
				tier = TIER_FULL
			elif distance > CHEAP_RADIUS:
				tier = TIER_FAR
		else:
			if want_full:
				tier = TIER_FULL
			elif distance <= CHEAP_RADIUS - 4.0:
				tier = TIER_CHEAP
		if tier == TIER_FULL and _tier[index] != TIER_FULL:
			_attack_wait[index] = 0.0
		_tier[index] = tier
		if tier == TIER_FULL:
			_full_list.append(index)
		elif tier == TIER_CHEAP:
			cheap_units += 1
		else:
			far_units += 1


## 中距：流场方向 + 低频分离 + 1m 通行表阻挡，不发任何物理查询。
func _step_cheap(index: int, delta: float, target: Vector3) -> void:
	var pos := _positions[index]
	var desired := _cheap_direction(index, pos, target, CHEAP_SEPARATION_NEIGHBORS)
	if desired.length_squared() < 0.0001:
		# 站在槽位上：把走路权重收掉，避免原地踏步。
		_move_weight[index] = maxf(0.0, _move_weight[index] - delta * 6.0)
		_speed[index] = 0.0
		return
	var motion := desired * SPEED * delta
	var next := pos + motion
	if _surface_ready and _surface != null:
		if _surface.blocked_at(next.x, next.z) and not _surface.blocked_at(pos.x, pos.z):
			var slide_x := Vector3(pos.x + motion.x, pos.y, pos.z)
			var slide_z := Vector3(pos.x, pos.y, pos.z + motion.z)
			if not _surface.blocked_at(slide_x.x, slide_x.z):
				next = slide_x
			elif not _surface.blocked_at(slide_z.x, slide_z.z):
				next = slide_z
			else:
				next = pos
		next.y = _surface.ground_height_at(next.x, next.z) + BODY_OFFSET
	else:
		next.y = Terrain.height_at(next.x, next.z) + BODY_OFFSET
	_positions[index] = next
	_update_cheap_visual(index, pos, next, delta, motion.length())
	_yaw[index] = atan2(-desired.x, -desired.z)


## 远距：6 帧一次，只跟流场；delta 已按步幅放大。
func _step_far(index: int, delta: float, target: Vector3) -> void:
	var pos := _positions[index]
	var direction := Vector3.ZERO
	if _flow_direction_ok:
		direction = flow.direction_at(pos)
	if direction.length_squared() < 0.001:
		var to := target - pos
		to.y = 0.0
		direction = to.normalized() if to.length_squared() > 0.001 else Vector3.ZERO
	if direction.length_squared() < 0.0001:
		return
	var motion := direction * SPEED * delta
	var next := pos + motion
	if _surface_ready and _surface != null:
		if _surface.blocked_at(next.x, next.z) and not _surface.blocked_at(pos.x, pos.z):
			next = pos
		next.y = _surface.ground_height_at(next.x, next.z) + BODY_OFFSET
	else:
		next.y = Terrain.height_at(next.x, next.z) + BODY_OFFSET
	_positions[index] = next
	_update_cheap_visual(index, pos, next, delta, motion.length())
	_yaw[index] = atan2(-direction.x, -direction.z)


func set_spread_mode(value: int) -> void:
	value = clampi(value, 0, 3)
	if spread_mode == value:
		return
	spread_mode = value
	for index in count:
		_slot_radius[index] = _slot_radius_for(index, spread_mode >= 1)
	if spread_mode >= 2:
		_assign_cheap_slots()
	if spread_mode == 3:
		_player_last = player.global_position if player != null else Vector3.ZERO
		_player_velocity = Vector3.ZERO
		_formation_center = _player_last
		_formation_clock = 0.0
		_update_formation(0.4, _player_last)


## 压上档：按距离排名给近身层分环（16 只 2.3m、32 只 3.6m、64 只 5.0m、其余 6.5m），
## 0.4 秒一次、平滑过渡；配合 token 直压和编队中心前移，形成持续压上的层次。
func _update_formation(delta: float, center: Vector3) -> void:
	_formation_clock += delta
	if _formation_clock < 0.4:
		return
	_formation_clock = 0.0
	if count <= 0:
		return
	var distances := PackedFloat32Array()
	distances.resize(count)
	for index in count:
		if _alive[index] == 0:
			distances[index] = 1.0e9
			continue
		var pos := _positions[index]
		distances[index] = Vector2(pos.x - center.x, pos.z - center.z).length()
	var sorted := distances.duplicate()
	sorted.sort()
	var c0: float = sorted[mini(15, sorted.size() - 1)] + 0.001
	var c1: float = sorted[mini(47, sorted.size() - 1)] + 0.001
	var c2: float = sorted[mini(111, sorted.size() - 1)] + 0.001
	for index in count:
		if _alive[index] == 0:
			continue
		var distance := distances[index]
		var target_radius := ATTACK_RANGE + 4.0
		if distance <= c0:
			target_radius = ATTACK_RANGE - 0.2
		elif distance <= c1:
			target_radius = ATTACK_RANGE + 1.1
		elif distance <= c2:
			target_radius = ATTACK_RANGE + 2.5
		_slot_radius[index] = lerpf(_slot_radius[index], target_radius, 0.35)


## 站位模式：把 CHEAP 层铺到 8–30m 的向日葵环带（黄金角 + 面积均匀）。
## 槽位是相对玩家的偏移，玩家移动时整队跟着走；被墙挡住的槽位向内收。
func _assign_cheap_slots() -> void:
	_cheap_slots.resize(count)
	if player == null:
		return
	var center := player.global_position
	var total := maxi(count, 1)
	for index in count:
		var t := float(index) + 0.5
		var radius := 8.0 + 22.0 * sqrt(t / float(total))
		var angle := t * 2.399963
		var offset := Vector2(cos(angle), sin(angle)) * radius
		if _surface_ready and _surface != null:
			var tries := 0
			while _surface.blocked_at(center.x + offset.x, center.z + offset.y) and tries < 6:
				radius = maxf(6.0, radius - 2.0)
				offset = Vector2(cos(angle), sin(angle)) * radius
				tries += 1
		_cheap_slots[index] = offset


func _slot_radius_for(index: int, spread: bool) -> float:
	if spread:
		return ATTACK_RANGE + 0.25 + float(index % SPREAD_SLOT_RINGS) * SPREAD_SLOT_STEP
	return ATTACK_RANGE + 0.25 + float(index % 3) * 0.9


func _cheap_direction(index: int, pos: Vector3, target: Vector3, neighbors: int) -> Vector3:
	var direction := Vector3.ZERO
	var holding_slot := false
	if spread_mode >= 2 and player != null and index < _cheap_slots.size():
		var center := player.global_position
		if spread_mode == 3:
			center = _formation_center
		var slot := _cheap_slots[index]
		var to_slot := Vector3(center.x + slot.x - pos.x, 0.0,
			center.z + slot.y - pos.z)
		var slot_distance := to_slot.length()
		if slot_distance > 0.9:
			direction = to_slot / slot_distance
			# 槽位在墙后时交回流场绕，不要顶着墙走。
			if _surface_ready and _surface != null and _flow_direction_ok:
				var ahead := pos + direction * 0.9
				if _surface.blocked_at(ahead.x, ahead.z) and not _surface.blocked_at(pos.x, pos.z):
					direction = flow.direction_at(pos)
		else:
			holding_slot = true
	elif _flow_direction_ok:
		direction = flow.direction_at(pos)
	if not holding_slot and direction.length_squared() < 0.001:
		var to := target - pos
		to.y = 0.0
		direction = to.normalized() if to.length_squared() > 0.001 else Vector3.ZERO
	var push := Vector3.ZERO
	var separation_reach := SPREAD_CHEAP_SEPARATION_RADIUS if spread_mode else CHEAP_SEPARATION_RADIUS
	var cell := _hash_cell_of(pos)
	var considered := 0
	if cell >= 0:
		var cell_x := cell % HASH_N
		var cell_z := int(cell / HASH_N)
		for dz in range(-1, 2):
			for dx in range(-1, 2):
				var bucket := _hash_index(cell_x + dx, cell_z + dz)
				if bucket < 0:
					continue
				var other := _hash_head[bucket]
				while other != -1:
					if considered >= neighbors:
						break
					considered += 1
					if other != index:
						var offset := pos - _snapshot_positions[other]
						offset.y = 0.0
						var length := offset.length()
						if length > 0.001 and length < separation_reach:
							push += offset / length * (1.0 - length / separation_reach)
					other = _hash_next[other]
				if considered >= neighbors:
					break
			if considered >= neighbors:
				break
	if push.length_squared() > 0.0001:
		var strength := separation_strength
		if spread_mode:
			strength *= SPREAD_SEPARATION_STRENGTH_SCALE
		direction = (direction + push * strength).normalized()
	return direction


func _update_cheap_visual(index: int, before: Vector3, after: Vector3, delta: float, expected: float) -> void:
	var moved := after.distance_to(before)
	var speed_ratio := moved / expected if expected > 0.0001 else 0.0
	speed_ratio = clampf(speed_ratio, 0.0, 1.0)
	_move_weight[index] = clampf(speed_ratio * 1.5, 0.0, 1.0)
	_phase[index] += delta * 8.0 * speed_ratio
	_speed[index] = moved / maxf(delta, 0.0001)


func _resolve_overlap(index: int, pos: Vector3, to_target: Vector3) -> Vector3:
	var space := get_world_3d().direct_space_state
	for _pass in 2:
		var center := pos + Vector3.UP * _resolve_center
		_resolve_query.transform = Transform3D(Basis(), center)
		var hits := space.intersect_shape(_resolve_query, 4)
		if hits.is_empty():
			# 胶囊完全在实体内部时 shape 查询不报；用中心点查询补“整只站进去”。
			_point_query.position = center
			var inside := space.intersect_point(_point_query, 4)
			if inside.is_empty():
				return pos
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
				return pos
			pos = _move_unit(index, pos, inside_push.normalized() * 0.12, to_target, false)
			continue
		resolve_hits += hits.size()
		var rest := space.get_rest_info(_resolve_query)
		var normal: Vector3 = rest.get("normal", Vector3.ZERO)
		# 地面/斜坡接触不参与水平推出，否则会把单位顺着坡推走。
		if absf(normal.y) > 0.7:
			return pos
		normal.y = 0.0
		if normal.length_squared() < 0.001:
			return pos
		pos = _move_unit(index, pos, normal.normalized() * 0.14, to_target, false)
	return pos


func _surface_height(x: float, z: float) -> float:
	if _surface != null and _surface.ready:
		return _surface.nav_height_at(x, z)
	return Terrain.height_at(x, z)


## 热路径地面高度：已烘焙的 1m 通行表 0.7µs/次，程序化 Terrain 26.3µs/次
## （2026-10-28 隔离测量：500 只每帧 3 次 Terrain.height_at 占 54%）。
## 表未就绪或该格放不下身体时才回落 Terrain：那正是需要独立安全兜底的情况。
func _floor_height(x: float, z: float) -> float:
	if _surface_ready and _surface != null and not _surface.blocked_at(x, z):
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
		# 视觉兜底只读物理已缓存的支撑高度，不再逐只调用程序化地形（26µs/次）。
		display_pos.y = maxf(display_pos.y, _ground_heights[index] + BODY_OFFSET)
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


func is_position_blocked(position: Vector3) -> bool:
	return _surface != null and _surface.ready and _surface.blocked_at(position.x, position.z)


func dump_stuck_units() -> void:
	var above := 0
	var unreachable := 0
	var blocked := 0
	for index in count:
		if _alive[index] == 0:
			continue
		var p := _positions[index]
		var terrain := Terrain.height_at(p.x, p.z)
		var rise := p.y - BODY_OFFSET - terrain
		var is_blocked: bool = _surface.blocked_at(p.x, p.z)
		var reachable: bool = flow != null and flow.is_reachable(p)
		if rise > 0.3:
			above += 1
		if not reachable:
			unreachable += 1
		if is_blocked:
			blocked += 1
		if index < 12:
			print("[fodder_dump] i=%d pos=(%.1f,%.1f,%.1f) rise=%.2f blocked=%s reachable=%s" % [
				index, p.x, p.y, p.z, rise, str(is_blocked), str(reachable)])
	print("[fodder_dump] above03=%d blocked=%d unreachable=%d" % [above, blocked, unreachable])


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
	ray_queries = 0
	resolve_hits = 0
	resolve_inside = 0
	blocked_hits = 0
	step_up_count = 0
	spawn_relocations = 0
	unstuck_count = 0
