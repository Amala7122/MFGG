extends Node3D
## 五组共用策略能力的可视观察场，与正式敌人种类无关。
const Actor := preload("res://prototypes/combat/spatial/traversal_actor.gd")
const Profile := preload("res://scripts/combat_spatial_profile.gd")
const Capability := preload("res://scripts/traversal_capability.gd")
const Link := preload("res://scripts/spatial_traversal_link.gd")
const Prop := preload("res://scripts/destructible_prop.gd")
var _geometry: Node3D
var _actors: Array[CharacterBody3D] = []
var _targets: Array[Node3D] = []
var _readouts: Array[Label3D] = []
var _pit_target: Node3D
var _outside := false
var _camera: Camera3D
var _flow: CanvasLayer
var _saved_flow_visible := true
var _saved_paused := false
var _saved_mouse := Input.MOUSE_MODE_VISIBLE

func _enter_tree() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS

func _ready() -> void:
	_saved_paused = get_tree().paused
	_saved_mouse = Input.mouse_mode
	_geometry = Node3D.new()
	_geometry.name = "Geometry"
	add_child(_geometry)
	_box(Vector3(0, -0.5, 0), Vector3(16, 1, 8))
	_box(Vector3(0, 0.35, 0), Vector3(0.5, 0.7, 8))
	_pair(Vector3(-4, 0.65, 0), Vector3(4, 0.9, 0), _profile(Capability.Kind.JUMP), "跳越矮墙")
	for info in [{"x": 18.0, "depth": 1.0, "kind": Capability.Kind.JUMP, "title": "浅坑 · 预留返程"},
		{"x": 36.0, "depth": 5.0, "kind": Capability.Kind.WALK, "title": "深坑 · 拒绝进入"}]:
		var x := float(info.x)
		_box(Vector3(x - 5, -0.5, 0), Vector3(6, 1, 8))
		_box(Vector3(x + 5, -0.5, 0), Vector3(6, 1, 8))
		_box(Vector3(x, -float(info.depth) - 0.5, 0), Vector3(4, 1, 8))
		_pair(Vector3(x - 4, 0.65, 0), Vector3(x, 0.9 - float(info.depth), 0), _profile(info.kind), info.title)
		if x == 18:
			_pit_target = _targets.back()
	_box(Vector3(54, -0.5, 0), Vector3(16, 1, 8))
	var obstacle := Prop.new()
	obstacle.position.x = 54
	obstacle.dimensions = Vector3(0.6, 3, 8)
	_geometry.add_child(obstacle)
	_pair(Vector3(50, 0.65, 0), Vector3(58, 0.9, 0), _profile(Capability.Kind.BREAK), "真实破障后接近")
	_box(Vector3(72, -0.5, 0), Vector3(14, 1, 8))
	_box(Vector3(72.25, 1.6, 0), Vector3(0.5, 3.2, 8))
	_box(Vector3(70, 3.4, 0), Vector3(4, 0.4, 8))
	_pair(Vector3(71.32, 0.65, 0), Vector3(69, 1.35, 0), _profile(Capability.Kind.CLIMB), "攀墙 → 天花板接战")
	_actors.back().attack_requires_attachment = true
	_actors.back().attack_reach = 1.25
	var link := Link.new()
	link.capability = &"climb"
	link.position.x = 72
	link.points = PackedVector3Array([Vector3(-0.68, 0.65, 0), Vector3(-0.68, 2.52, 0), Vector3(-0.68, 2.52, 0), Vector3(-1.3, 2.52, 0), Vector3(-3, 2.52, 0)])
	link.normals = PackedVector3Array([Vector3.LEFT, Vector3.LEFT, Vector3(-1, -1, 0).normalized(), Vector3.DOWN, Vector3.DOWN])
	add_child(link)
	_camera = Camera3D.new()
	_camera.projection = Camera3D.PROJECTION_ORTHOGONAL
	_camera.size = 90
	_camera.position = Vector3(36, 35, 30)
	add_child(_camera)
	_camera.look_at(Vector3(36, -1, 0))
	_camera.current = true
	var light := DirectionalLight3D.new()
	light.rotation_degrees = Vector3(-55, -30, 0)
	light.light_energy = 1.4
	add_child(light)
	var environment := WorldEnvironment.new()
	environment.environment = Environment.new()
	environment.environment.background_mode = Environment.BG_COLOR
	environment.environment.background_color = Color(0.07, 0.1, 0.12)
	environment.environment.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	environment.environment.ambient_light_color = Color(0.65, 0.72, 0.8)
	environment.environment.ambient_light_energy = 0.6
	add_child(environment)
	var canvas := CanvasLayer.new()
	add_child(canvas)
	var instructions := Label.new()
	instructions.position = Vector2(20, 16)
	instructions.add_theme_font_override("font", preload("res://theme/fonts/NotoSansSC-wght.ttf"))
	instructions.text = "T03 能力演示：绿 = 测试角色，红 = 目标\nE：浅坑目标出坑 / 回坑　R：重开　滚轮：缩放\n小台面跳跃普攻与混合敌人：运行 combat_spatial_lab"
	canvas.add_child(instructions)
	_start.call_deferred()

func _start() -> void:
	await get_tree().process_frame
	await get_tree().process_frame
	_flow = get_node_or_null("/root/GameFlow") as CanvasLayer
	if _flow != null:
		_saved_flow_visible = _flow.visible
		_flow.hide()
	get_tree().paused = false
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE

func _exit_tree() -> void:
	if is_instance_valid(_flow):
		_flow.visible = _saved_flow_visible
	get_tree().paused = _saved_paused
	Input.mouse_mode = _saved_mouse

func _process(_delta: float) -> void:
	var names := {"checking": "检查路线", "approach": "接近目标", "traversing": "能力通行", "escaping": "返程", "relocate": "寻找安全位置", "blocked": "通路受阻", "trapped": "受困", "unsafe_drop": "拒绝危险落差", "breaking": "破障"}
	for i in range(_actors.size()):
		var controller: RefCounted = _actors[i].steering.spatial
		_readouts[i].text = "%s · 命中 %d%s" % [names.get(controller.status, controller.status), _actors[i].hits, " · 已预留返程" if not controller.escape_reserved.is_empty() else ""]

func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventKey and event.pressed and not event.echo:
		if event.keycode == KEY_E:
			_outside = not _outside
			_pit_target.position = Vector3(14, 0.9, 0) if _outside else Vector3(18, -0.1, 0)
		elif event.keycode == KEY_R:
			get_tree().reload_current_scene()
	elif event is InputEventMouseButton and event.pressed:
		if event.button_index == MOUSE_BUTTON_WHEEL_UP:
			_camera.size = maxf(20, _camera.size - 5)
		elif event.button_index == MOUSE_BUTTON_WHEEL_DOWN:
			_camera.size = minf(100, _camera.size + 5)

func _profile(kind: Capability.Kind) -> Resource:
	var settings := Profile.new()
	settings.preserve_ground_style = false
	var walk := Capability.new()
	walk.travel_speed = 3
	settings.capabilities.append(walk)
	if kind != Capability.Kind.WALK:
		var ability := Capability.new()
		ability.kind = kind
		ability.id = &"jump" if kind == Capability.Kind.JUMP else &"break" if kind == Capability.Kind.BREAK else &"climb"
		ability.max_distance = 14
		ability.max_rise = 2
		ability.max_drop = 6
		ability.max_flight = 1.0
		ability.travel_speed = 6 if kind == Capability.Kind.JUMP else 3
		ability.cooldown = 0.4
		ability.windup = 0.2
		ability.power = 2
		settings.capabilities.append(ability)
	settings.max_escape_wait = 0.5
	return settings

func _pair(origin: Vector3, destination: Vector3, profile: Resource, title: String) -> void:
	var target := CharacterBody3D.new()
	target.position = destination
	target.collision_layer = 2
	target.collision_mask = 1
	var collision := CollisionShape3D.new()
	var shape := CapsuleShape3D.new()
	shape.radius = 0.3
	shape.height = 1.8
	collision.shape = shape
	target.add_child(collision)
	var visual := MeshInstance3D.new()
	var sphere := SphereMesh.new()
	sphere.radius = 0.3
	sphere.height = 0.6
	visual.mesh = sphere
	var material := StandardMaterial3D.new()
	material.albedo_color = Color(1, 0.3, 0.25)
	visual.material_override = material
	target.add_child(visual)
	add_child(target)
	_targets.append(target)
	var actor := Actor.new()
	actor.position = origin
	actor.target = target
	actor.combat_spatial_profile = profile
	add_child(actor)
	_actors.append(actor)
	_label(title, Vector3(destination.x, 5, -5))
	_readouts.append(_label("", Vector3(destination.x, 4, -5)))

func _box(at: Vector3, size: Vector3) -> void:
	var object := StaticBody3D.new()
	object.position = at
	object.collision_layer = 1
	var collision := CollisionShape3D.new()
	var shape := BoxShape3D.new()
	shape.size = size
	collision.shape = shape
	object.add_child(collision)
	var visual := MeshInstance3D.new()
	var mesh := BoxMesh.new()
	mesh.size = size
	visual.mesh = mesh
	var material := StandardMaterial3D.new()
	material.albedo_color = Color(0.35, 0.43, 0.46)
	visual.material_override = material
	object.add_child(visual)
	_geometry.add_child(object)

func _label(title: String, at: Vector3) -> Label3D:
	var label := Label3D.new()
	label.text = title
	label.position = at
	label.font = preload("res://theme/fonts/NotoSansSC-wght.ttf")
	label.font_size = 40
	label.pixel_size = 0.018
	label.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	add_child(label)
	return label
