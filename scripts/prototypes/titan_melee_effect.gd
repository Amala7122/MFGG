extends Node3D
## 直线砸地裂痕与横扫拖痕/风切。只表现接触，不结算伤害。
const GroundEffect := preload("res://scripts/prototypes/titan_ground_effect.gd")
const Audio := preload("res://scripts/audio_manager.gd")
var age := 0.0
var lifetime := 3.5
var radius := 1.0
var arc := PI
var duration := 0.4
var body_size := 1.0
var progress := 0.0
var sweeping := false
var _motion_stopped := false
var _trace: MeshInstance3D
var _trace_material: StandardMaterial3D
var _ribbon: MeshInstance3D
var _ribbon_material: StandardMaterial3D
var _arc_edges: Array[Vector3] = []
var _tip := Vector3.ZERO
var _trace_step := -1

static func spawn(host: Node, pose: Transform3D, spec: Dictionary, size: float, sweep: bool, swing := 0.4, shake := 1.0) -> Node3D:
	var active: Array[Node] = []
	for node in host.get_tree().get_nodes_in_group("titan_melee_effect"):
		if not node.is_queued_for_deletion():
			active.append(node)
	while active.size() >= 16:
		active.pop_front().queue_free()
	var effect := load("res://scripts/prototypes/titan_melee_effect.gd").new() as Node3D
	host.add_child(effect)
	effect.global_transform = Transform3D(pose.basis.orthonormalized(), pose.origin)
	effect.call("setup", spec, size, sweep, swing, shake)
	return effect

func setup(spec: Dictionary, size: float, sweep: bool, swing: float, shake: float) -> void:
	add_to_group("titan_melee_effect")
	add_to_group("ground_impulse")
	body_size = size
	sweeping = sweep
	duration = swing
	_trace_material = _material(Color(0.19, 0.14, 0.09, 0.80))
	_trace = MeshInstance3D.new()
	_trace.material_override = _trace_material
	_trace.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(_trace)
	_ribbon_material = _material(Color(0.79, 0.67, 0.42, 0.46))
	_ribbon_material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	_ribbon = MeshInstance3D.new()
	_ribbon.material_override = _ribbon_material
	_ribbon.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(_ribbon)
	if sweeping:
		radius = float(spec.radius)
		arc = deg_to_rad(float(spec.angle))
		for i in range(49):
			var angle := -arc * 0.5 + arc * float(i) / 48.0
			var direction := Vector3(sin(angle), 0, -cos(angle))
			_arc_edges.append(_ground(direction * radius * 0.76))
			_arc_edges.append(_ground(direction * radius * 0.96))
		Audio.play_at("titan_sweep", global_position, -5.0)
		set_progress(0.0)
	else:
		radius = float(spec.width)
		_build_slam(spec)
		var contact := _ground(spec.get("contact", Vector3(float(spec.offset), 0, -minf(float(spec.length) * 0.35, 2.8 * size))))
		_tip = contact
		GroundEffect.spawn(get_tree().current_scene, to_global(contact), float(spec.width) * 0.65, 1.0, false, shake)

func set_progress(value: float) -> void:
	if not sweeping or _motion_stopped:
		return
	progress = clampf(value, 0.0, 1.0)
	var angle := -arc * 0.5 + arc * progress
	_tip = _arc_edges[mini(int(progress * 48), 48) * 2]
	var step := int(progress * 48)
	if step != _trace_step:
		_trace_step = step
		var trace := _surface()
		for i in range(step):
			# 扫过后留下断续弧形刮痕，未扫到的区域不提前留下痕迹。
			if i % 4 == 3:
				continue
			_quad(trace, _arc_edges[i*2], _arc_edges[i*2+1], _arc_edges[(i+1)*2+1], _arc_edges[(i+1)*2])
		_trace.mesh = trace.commit() if step > 0 else null
	var ribbon := _surface()
	var span := minf(deg_to_rad(42), arc * progress)
	for i in range(12):
		var a := angle - span + span * float(i) / 12.0
		var b := angle - span + span * float(i+1) / 12.0
		var da := Vector3(sin(a), 0, -cos(a))
		var db := Vector3(sin(b), 0, -cos(b))
		var height := (0.95 - 1.7) * body_size
		_quad(ribbon, da * maxf(radius - body_size, 0.1) + Vector3.UP * height,
			da * radius + Vector3.UP * (height + 0.15 * body_size),
			db * radius + Vector3.UP * (height + 0.15 * body_size),
			db * maxf(radius - body_size, 0.1) + Vector3.UP * height)
	_ribbon.mesh = ribbon.commit()

func stop_motion() -> void:
	_motion_stopped = true
	duration = minf(duration, age)

func impulse() -> Vector4:
	var point := to_global(_tip)
	var power := 0.45 if sweeping and not _motion_stopped else maxf(1.0 - age / 0.55, 0.0)
	return Vector4(point.x, point.z, body_size * 2.0, power)

func _physics_process(delta: float) -> void:
	age += delta
	if age >= lifetime:
		queue_free()
		return
	_trace_material.albedo_color.a = 0.8 * clampf((lifetime-age) / 0.8, 0.0, 1.0)
	_ribbon_material.albedo_color.a = 0.46 * clampf((duration + 0.22 - age) / 0.22, 0.0, 1.0) if sweeping else 0.46 * maxf(1.0 - age / 0.4, 0.0)

func _build_slam(spec: Dictionary) -> void:
	var trace := _surface()
	var dust := _surface()
	var width := float(spec.width)
	var length := float(spec.length)
	var offset := float(spec.offset)
	var previous := Vector3(offset, 0, -length * 0.08)
	for i in range(1, 9):
		var next := Vector3(offset + sin(float(i) * 2.7) * width * 0.12, 0, -length * float(i) / 9.0)
		_segment(trace, previous, next, width * 0.035)
		_segment(trace, next, next + Vector3((0.38 if i % 2 == 0 else -0.38) * width, 0, -length * 0.055), width * 0.02)
		var left := _ground(Vector3(offset-width*0.45, 0, next.z))
		var right := _ground(Vector3(offset+width*0.45, 0, next.z))
		_quad(dust, left, right, right + Vector3(0, 0.85*body_size, 0.18*body_size), left + Vector3(0, 0.85*body_size, 0.18*body_size))
		previous = next
	_trace.mesh = trace.commit()
	_ribbon.mesh = dust.commit()

func _ground(local: Vector3) -> Vector3:
	var point := to_global(local)
	var query := PhysicsRayQueryParameters3D.create(point + Vector3.UP * 3, point + Vector3.DOWN * 8, 1)
	var hit := get_world_3d().direct_space_state.intersect_ray(query)
	if not hit.is_empty():
		point.y = float(hit.position.y) + 0.035
	return to_local(point)

func _segment(surface: SurfaceTool, from: Vector3, to: Vector3, width: float) -> void:
	var side := (to-from).cross(Vector3.UP).normalized() * width
	_quad(surface, _ground(from-side), _ground(from+side), _ground(to+side), _ground(to-side))

func _surface() -> SurfaceTool:
	var surface := SurfaceTool.new()
	surface.begin(Mesh.PRIMITIVE_TRIANGLES)
	return surface

func _quad(surface: SurfaceTool, a: Vector3, b: Vector3, c: Vector3, d: Vector3) -> void:
	for point in [a,b,c,a,c,d]:
		surface.set_normal(Vector3.UP)
		surface.add_vertex(point)

func _material(color: Color) -> StandardMaterial3D:
	var material := StandardMaterial3D.new()
	material.albedo_color = color
	material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	material.cull_mode = BaseMaterial3D.CULL_DISABLED
	material.roughness = 1.0
	return material
