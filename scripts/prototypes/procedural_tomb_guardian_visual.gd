class_name ProceduralTombGuardianVisual
extends Node3D
## 参考釉陶镇墓兽：连贯折角、中央额脊、凹眼窝、方吻。朝 -Z，脚底为原点。
const Profile = preload("res://scripts/prototypes/tomb_guardian_visual_profile.gd")
const POSE_NAMES := ["守立呼吸", "张翼威吓", "抬爪蓄势"]
@export var visual_profile: Profile = preload("res://prototypes/visual/enemies/tomb_guardian_reference.tres")
@export_range(0.5, 2.0, 0.05) var body_size := 1.0
var preview_pose := 0
var _clock := 0.0
var _body: Node3D
var _head: Node3D
var _jaw: Node3D
var _tail: Node3D
var _wings: Array[Node3D] = []
var _forelegs: Array[Node3D] = []
var _jade: StandardMaterial3D
var _amber: StandardMaterial3D
var _ivory: StandardMaterial3D
var _dark: StandardMaterial3D
var _eye: StandardMaterial3D
var _p: Profile
static var _material_cache: Dictionary = {}


func _ready() -> void:
	_p = visual_profile if visual_profile is Profile else Profile.new()
	_make_materials()
	_build()
	_batch_static(self)
	_apply_pose()


func _process(delta: float) -> void:
	_clock += delta * float(_p.animation_speed)
	_apply_pose()


func set_preview_pose(index: int) -> void:
	preview_pose = posmod(index, POSE_NAMES.size())
	_apply_pose()


func get_preview_pose_name() -> String:
	return POSE_NAMES[preview_pose]


func get_preview_pose_count() -> int:
	return POSE_NAMES.size()


func _make_materials() -> void:
	# 同一预设复用小纹理和材质；只在生成时烘焙，不在每帧计算噪声。
	var key := str([_p.jade_color, _p.amber_color, _p.ivory_color, _p.patina_amount, _p.glaze_roughness, _p.eye_energy])
	if not _material_cache.has(key):
		var materials: Array[StandardMaterial3D] = []
		for base in [_p.jade_color, _p.amber_color, _p.ivory_color]:
			var mat := StandardMaterial3D.new()
			mat.albedo_texture = _bake_glaze(base)
			mat.uv1_triplanar = true
			mat.uv1_scale = Vector3(0.42, 0.42, 0.42)
			mat.uv1_triplanar_sharpness = 4.0
			mat.roughness = float(_p.glaze_roughness)
			mat.metallic_specular = 0.32
			materials.append(mat)
		var dark := StandardMaterial3D.new()
		dark.albedo_color = Color("111c16")
		dark.roughness = 0.95
		materials.append(dark)
		var eye := StandardMaterial3D.new()
		eye.albedo_color = Color("b9e85c")
		eye.emission_enabled = true
		eye.emission = Color("8cc52e")
		eye.emission_energy_multiplier = float(_p.eye_energy)
		materials.append(eye)
		_material_cache[key] = materials
	var cached: Array = _material_cache[key]
	_jade = cached[0]
	_amber = cached[1]
	_ivory = cached[2]
	_dark = cached[3]
	_eye = cached[4]


func _bake_glaze(base: Color) -> Texture2D:
	var noise := FastNoiseLite.new()
	noise.seed = 713
	noise.frequency = 0.035
	noise.fractal_octaves = 3
	var fine := FastNoiseLite.new()
	fine.seed = 121
	fine.frequency = 0.38
	fine.fractal_octaves = 2
	var image := Image.create(256, 256, false, Image.FORMAT_RGB8)
	var jade: Color = _p.jade_color
	var amber: Color = _p.amber_color
	var ivory: Color = _p.ivory_color
	for y in range(256):
		for x in range(256):
			var n := noise.get_noise_2d(float(x) * 1.3, float(y) * 0.38)
			var grain := fine.get_noise_2d(float(x), float(y))
			var glaze := jade.darkened(clampf(-n * 0.6, 0.0, 0.3))
			if n > 0.06:
				glaze = amber.lerp(ivory, smoothstep(0.22, 0.42, n))
			var amount := float(_p.patina_amount) * (0.86 if base == jade else 0.42)
			if base == ivory:
				amount *= smoothstep(0.02, 0.28, n)
			var color := base.lerp(glaze, amount).darkened(clampf(grain * 0.25, 0.0, 0.14))
			if grain > 0.55:
				color = color.lerp(ivory, 0.45)
			image.set_pixel(x, y, color)
	image.generate_mipmaps()
	return ImageTexture.create_from_image(image)


func _build() -> void:
	var sculpture := _pivot(self, "GuardianSculpture", Vector3.ZERO)
	sculpture.scale = Vector3.ONE * body_size * float(_p.body_size)
	_body = _pivot(sculpture, "BreathingBody", Vector3.ZERO)
	_sweep(_body, "Torso", [Vector3(0, 2.07, -0.75), Vector3(0, 2.04, -0.2), Vector3(0, 1.92, 0.65), Vector3(0, 1.75, 1.26)], [Vector2(0.59, 0.69), Vector2(0.72, 0.65), Vector2(0.63, 0.5), Vector2(0.43, 0.4)], _jade)
	_sweep(_body, "UprightNeck", [Vector3(0, 2.01, -0.69), Vector3(0, 2.8, -0.87), Vector3(0, 3.48, -0.91)], [Vector2(0.6, 0.45), Vector2(0.49, 0.44), Vector2(0.43, 0.35)], _jade)
	_sweep(_body, "Breastplate", [Vector3(0, 1.14, -0.96), Vector3(0, 1.83, -1.05), Vector3(0, 2.49, -1.0), Vector3(0, 2.83, -0.88)], [Vector2(0.03, 0.06), Vector2(0.43, 0.23), Vector2(0.55, 0.29), Vector2(0.34, 0.2)], _jade)
	for side in [-1.0, 1.0]:
		_build_leg(sculpture, side, true)
		_build_leg(sculpture, side, false)
		_build_wing(side)
		_plate(_body, "IvoryMane", [Vector3(side * 0.48, 2.24, -0.43), Vector3(side * 0.46, 3.94, -0.13), Vector3(side * 0.54, 3.48, 0.23), Vector3(side * 0.62, 2.15, 0.01)], Vector3(side, 0, 0), 0.1, _ivory)
		_plate(_body, "HaunchArmor", [Vector3(side * 0.5, 1.31, 1.02), Vector3(side * 0.52, 2.27, 0.83), Vector3(side * 0.7, 2.39, 1.33), Vector3(side * 0.7, 1.45, 1.5)], Vector3(side, 0, 0), 0.14, _amber)
	for i in range(3):
		var z := 0.17 + i * 0.48
		_plate(_body, "DorsalCrest", [Vector3(-0.11, 2.19, z - 0.26), Vector3(0, 2.96 - i * 0.14, z + 0.22), Vector3(0.11, 2.07, z + 0.38)], Vector3.RIGHT, 0.06, _amber)
	_build_head()
	_tail = _pivot(_body, "TailPivot", Vector3(0, 1.75, 1.17))
	_sweep(_tail, "SweptTail", [Vector3.ZERO, Vector3(0, 0.12, 0.55), Vector3(0, 0.61, 1.18), Vector3(0, 1.31, 1.48), Vector3(0, 1.72, 1.45)], [Vector2(0.27, 0.26), Vector2(0.25, 0.25), Vector2(0.22, 0.24), Vector2(0.16, 0.2), Vector2(0.035, 0.05)], _jade)
	_plate(_tail, "TailBlade", [Vector3(0, 0.61, 1.06), Vector3(0, 1.83, 1.76), Vector3(0, 1.36, 1.12)], Vector3.RIGHT, 0.11, _amber)


func _build_head() -> void:
	_head = _pivot(_body, "HeadPivot", Vector3(0, 3.55, -0.96))
	_head.scale = Vector3.ONE * float(_p.head_size)
	_sweep(_head, "Skull", [Vector3(0, 0.05, 0.28), Vector3(0, 0.06, -0.23), Vector3(0, 0.02, -0.6)], [Vector2(0.51, 0.55), Vector2(0.56, 0.53), Vector2(0.48, 0.39)], _jade)
	# 从额顶、眉心到鼻根的连续楔面。中央脊直接接在头骨上。
	_sweep(_head, "CentralCrest", [Vector3(0, 0.93, 0.03), Vector3(0, 0.69, -0.28), Vector3(0, 0.52, -0.62), Vector3(0, 0.28, -0.75), Vector3(0, 0.02, -0.86)], [Vector2(0.15, 0.17), Vector2(0.2, 0.16), Vector2(0.19, 0.14), Vector2(0.115, 0.115), Vector2(0.14, 0.11)], _amber)
	_plate(_head, "ForeheadGlaze", [Vector3(-0.145, 0.515, -0.759), Vector3(0.145, 0.515, -0.759), Vector3(0, 0.31, -0.875)], Vector3.FORWARD, 0.016, _jade)
	_sweep(_head, "SquaredMuzzle", [Vector3(0, -0.075, -0.54), Vector3(0, -0.1, -0.96), Vector3(0, -0.13, -1.23)], [Vector2(0.39, 0.195), Vector2(0.45, 0.16), Vector2(0.42, 0.135)], _jade)
	_build_nose()
	_box(_head, "MouthRecess", Vector3(0, -0.425, -0.79), Vector3(0.74, 0.33, 0.65), _dark)
	_jaw = _pivot(_head, "LowerJawPivot", Vector3(0, -0.5, -0.36))
	_sweep(_jaw, "LowerJaw", [Vector3(0, 0.0, 0), Vector3(0, -0.08, -0.63), Vector3(0, -0.075, -0.86)], [Vector2(0.36, 0.115), Vector2(0.42, 0.105), Vector2(0.39, 0.09)], _jade)
	_sweep(_jaw, "JawBand", [Vector3(0, -0.075, -0.8), Vector3(0, -0.075, -0.9)], [Vector2(0.4, 0.1), Vector2(0.38, 0.085)], _amber)
	for side in [-1.0, 1.0]:
		var socket := [Vector3(side * 0.12, 0.315, -0.735), Vector3(side * 0.48, 0.35, -0.68), Vector3(side * 0.48, 0.095, -0.73), Vector3(side * 0.12, 0.08, -0.78)]
		_plate(_head, "EyeSocket", socket, Vector3.FORWARD, 0.022, _dark)
		var eye_outline := [Vector3(side * 0.17, 0.23, -0.797), Vector3(side * 0.405, 0.255, -0.753), Vector3(side * 0.405, 0.14, -0.77), Vector3(side * 0.17, 0.125, -0.81)]
		_plate(_head, "EmberEyeLeft" if side < 0 else "EmberEyeRight", eye_outline, Vector3.FORWARD, 0.008, _eye)
		_plate(_head, "OrbitalRoof", [Vector3(side * 0.095, 0.335, -0.83), Vector3(side * 0.55, 0.39, -0.77), Vector3(side * 0.5, 0.54, -0.57), Vector3(side * 0.16, 0.55, -0.65)], Vector3.UP, 0.05, _jade)
		_plate(_head, "CheekFrame", [Vector3(side * 0.48, 0.31, -0.63), Vector3(side * 0.55, 0.23, -0.36), Vector3(side * 0.47, -0.59, -0.39), Vector3(side * 0.4, -0.52, -0.78)], Vector3(side, 0, -0.3).normalized(), 0.06, _jade)
		_plate(_head, "TempleFin", [Vector3(side * 0.48, 0.33, -0.35), Vector3(side * 0.68, 0.58, -0.12), Vector3(side * 0.58, -0.05, 0.01)], Vector3(side, 0, 0), 0.06, _amber)
		_build_horns(side)
		_fang(_head, "UpperFang", [Vector3(side * 0.285, -0.257, -1.15), Vector3(side * 0.28, -0.4, -1.18), Vector3(side * 0.27, -0.52, -1.18)], 0.07)
		_fang(_jaw, "LowerFang", [Vector3(side * 0.35, 0.02, -0.77), Vector3(side * 0.345, 0.1, -0.78), Vector3(side * 0.335, 0.15, -0.79)], 0.045)
	for x in [-0.13, 0.13]:
		_fang(_head, "SmallFang", [Vector3(x, -0.265, -1.175), Vector3(x, -0.315, -1.18), Vector3(x, -0.365, -1.19)], 0.039)


func _build_nose() -> void:
	# 方鼻孔真正向内凹陷；前表面留洞，孔壁与孔底提供深度。
	var surface := SurfaceTool.new()
	surface.begin(Mesh.PRIMITIVE_TRIANGLES)
	var xs := [-0.42, -0.3, -0.14, 0.14, 0.3, 0.42]
	var ys := [-0.26, -0.155, -0.04, 0.005]
	var front := -1.32
	var rear := -1.18
	for i in range(xs.size() - 1):
		for j in range(ys.size() - 1):
			if j == 1 and (i == 1 or i == 3):
				continue
			_quad(surface, Vector3(xs[i], ys[j], front), Vector3(xs[i + 1], ys[j], front), Vector3(xs[i + 1], ys[j + 1], front), Vector3(xs[i], ys[j + 1], front), Vector3.FORWARD)
	var rim := [Vector3(-0.42, -0.26, front), Vector3(0.42, -0.26, front), Vector3(0.42, 0.005, front), Vector3(-0.42, 0.005, front)]
	for i in range(4):
		var a: Vector3 = rim[i]
		var b: Vector3 = rim[(i + 1) % 4]
		_quad(surface, a, b, Vector3(b.x, b.y, rear), Vector3(a.x, a.y, rear), (a + b) * 0.5 - Vector3(0, -0.1275, front))
	for side in [-1.0, 1.0]:
		var x: float = side * 0.22
		var hole := [Vector3(x - 0.08, -0.155, front), Vector3(x + 0.08, -0.155, front), Vector3(x + 0.08, -0.04, front), Vector3(x - 0.08, -0.04, front)]
		var center := Vector3(x, -0.0975, front)
		for i in range(4):
			var a: Vector3 = hole[i]
			var b: Vector3 = hole[(i + 1) % 4]
			var c := Vector3(b.x, b.y, front + 0.075)
			var d := Vector3(a.x, a.y, front + 0.075)
			_quad(surface, a, b, c, d, center - (a + b) * 0.5)
		_box(_head, "NostrilFloor", Vector3(x, -0.0975, front + 0.08), Vector3(0.16, 0.115, 0.01), _dark)
	_part(_head, "NoseBand", surface.commit(), _amber)


func _build_horns(side: float) -> void:
	var points := [Vector3(side * 0.41, 0.47, 0.02), Vector3(side * 0.48, 0.95, 0.025), Vector3(side * 0.88, 1.52, 0.075), Vector3(side * 1.09, 1.87, 0.12), Vector3(side * 1.08, 2.43, 0.14), Vector3(side * 0.92, 2.53, 0.145)]
	for i in range(points.size()):
		points[i].x *= float(_p.horn_spread)
		points[i].y = 0.47 + (points[i].y - 0.47) * float(_p.horn_height)
	_sweep(_head, "HookedIvoryHorn", points, [Vector2(0.24, 0.235), Vector2(0.235, 0.22), Vector2(0.195, 0.18), Vector2(0.16, 0.155), Vector2(0.125, 0.13), Vector2(0.115, 0.12)], _ivory, 0.15)
	_sweep(_head, "AmberInnerHorn", [Vector3(side * 0.19, 0.57, 0.21), Vector3(side * 0.25, 0.96, 0.22), Vector3(side * 0.23, 1.32, 0.29), Vector3(side * 0.2, 1.54, 0.35)], [Vector2(0.16, 0.16), Vector2(0.125, 0.12), Vector2(0.07, 0.075), Vector2(0.018, 0.025)], _amber, 0.16)


func _build_wing(side: float) -> void:
	var x := side * 0.71 * float(_p.shoulder_width)
	var wing := _pivot(_body, "CeramicWingLeft" if side < 0 else "CeramicWingRight", Vector3(x, 2.2, -0.43))
	_wings.append(wing)
	_plate(wing, "ShoulderBlade", [Vector3(0, -0.46, -0.3), Vector3(side * 0.42, 1.02, -0.5), Vector3(side * 0.52, 0.4, 0.17), Vector3(side * 0.18, -0.18, 0.4)], Vector3(side, 0, -0.4).normalized(), 0.15, _jade)
	_plate(wing, "RearBlade", [Vector3(0, -0.23, 0.17), Vector3(side * 0.2, 1.11, 0.46), Vector3(side * 0.31, 0.57, 0.83), Vector3(side * 0.11, -0.24, 0.66)], Vector3(side, 0, 0), 0.14, _amber)
	_plate(wing, "BackBlade", [Vector3(0, -0.3, 0.57), Vector3(side * 0.13, 0.7, 1.12), Vector3(side * 0.21, 0.21, 1.36), Vector3(side * 0.11, -0.46, 1.01)], Vector3(side, 0, 0), 0.1, _jade)


func _build_leg(parent: Node3D, side: float, front: bool) -> void:
	var leg := _pivot(parent, ("Foreleg" if front else "Hindleg") + ("Left" if side < 0 else "Right"), Vector3(side * 0.62, 0, -0.67 if front else 1.05))
	if front:
		_forelegs.append(leg)
		_sweep(leg, "IvoryForeleg", [Vector3(0, 0.27, -0.04), Vector3(0, 0.58, 0), Vector3(0, 1.7, 0), Vector3(0, 2.4, 0.04)], [Vector2(0.25, 0.26), Vector2(0.19, 0.205), Vector2(0.215, 0.22), Vector2(0.26, 0.29)], _ivory)
		_sweep(leg, "ShoulderCuff", [Vector3(0, 1.85, 0), Vector3(0, 2.42, 0.04)], [Vector2(0.26, 0.27), Vector2(0.29, 0.32)], _jade)
	else:
		_sweep(leg, "BentHaunch", [Vector3(0, 0.26, 0.34), Vector3(side * 0.06, 0.8, 0.44), Vector3(side * 0.07, 1.28, 0.08), Vector3(0, 1.91, 0)], [Vector2(0.17, 0.2), Vector2(0.17, 0.19), Vector2(0.27, 0.3), Vector2(0.32, 0.37)], _ivory)
	var paw_z := -0.17 if front else 0.22
	_sweep(leg, "StonePaw", [Vector3(0, 0.025, paw_z), Vector3(0, 0.23, paw_z), Vector3(0, 0.4, paw_z + 0.065)], [Vector2(0.33, 0.4), Vector2(0.33, 0.39), Vector2(0.24, 0.26)], _jade)
	for toe in [-1.0, 1.0]:
		_box(leg, "ToeCut", Vector3(toe * 0.11, 0.13, paw_z - 0.397), Vector3(0.018, 0.17, 0.018), _dark)


func _apply_pose() -> void:
	if _body == null:
		return
	var breath := sin(_clock * 1.4)
	_body.position.y = breath * 0.012
	_head.rotation.x = -0.01 + breath * 0.012
	_jaw.rotation.x = -float(_p.resting_jaw_open)
	_tail.rotation.y = sin(_clock * 0.8) * 0.035
	for wing in _wings:
		wing.rotation.z = 0.0
	for leg in _forelegs:
		leg.rotation.x = 0.0
		leg.position.y = 0.0
	if preview_pose == 1:
		_head.rotation.x = -0.07 + breath * 0.012
		_jaw.rotation.x = -float(_p.threat_jaw_open) - breath * 0.018
		for wing in _wings:
			wing.rotation.z = -signf(wing.position.x) * (0.085 + breath * 0.015)
	elif preview_pose == 2:
		_head.rotation.x = 0.065 + breath * 0.012
		_forelegs[0].rotation.x = -0.09
		_forelegs[0].position.y = 0.16 + breath * 0.035


func _pivot(parent: Node3D, title: String, position: Vector3) -> Node3D:
	var pivot := Node3D.new()
	pivot.name = title
	pivot.position = position
	parent.add_child(pivot)
	return pivot


func _box(parent: Node3D, title: String, position: Vector3, size: Vector3, material: Material) -> MeshInstance3D:
	var mesh := BoxMesh.new()
	mesh.size = size
	var part := _part(parent, title, mesh, material)
	part.position = position
	return part


func _fang(parent: Node3D, title: String, path: Array, radius: float) -> void:
	_sweep(parent, title, path, [Vector2(radius, radius * 0.75), Vector2(radius * 0.55, radius * 0.45), Vector2(0.002, 0.002)], _ivory, 0.35)


func _sweep(parent: Node3D, title: String, path: Array, sizes: Array, material: Material, bevel := 0.23) -> MeshInstance3D:
	var rings: Array = []
	for i in range(path.size()):
		var tangent: Vector3 = (path[mini(i + 1, path.size() - 1)] - path[maxi(0, i - 1)]).normalized()
		var side := Vector3.RIGHT if absf(tangent.dot(Vector3.BACK)) > 0.92 else tangent.cross(Vector3.BACK).normalized()
		var depth := tangent.cross(side).normalized()
		var w: float = sizes[i].x
		var h: float = sizes[i].y
		var corners := [Vector2(-w * (1.0 - bevel), -h), Vector2(w * (1.0 - bevel), -h), Vector2(w, -h * (1.0 - bevel)), Vector2(w, h * (1.0 - bevel)), Vector2(w * (1.0 - bevel), h), Vector2(-w * (1.0 - bevel), h), Vector2(-w, h * (1.0 - bevel)), Vector2(-w, -h * (1.0 - bevel))]
		var ring: Array[Vector3] = []
		for corner in corners:
			ring.append(path[i] + side * corner.x + depth * corner.y)
		rings.append(ring)
	var surface := SurfaceTool.new()
	surface.begin(Mesh.PRIMITIVE_TRIANGLES)
	for i in range(rings.size() - 1):
		var center: Vector3 = (path[i] + path[i + 1]) * 0.5
		for j in range(8):
			var k := (j + 1) % 8
			_quad(surface, rings[i][j], rings[i][k], rings[i + 1][k], rings[i + 1][j], (rings[i][j] + rings[i][k] + rings[i + 1][k] + rings[i + 1][j]) * 0.25 - center)
	for end in [0, rings.size() - 1]:
		var outward: Vector3 = (path[0] - path[1]) if end == 0 else (path[-1] - path[-2])
		for j in range(1, 7):
			_triangle(surface, rings[end][0], rings[end][j], rings[end][j + 1], outward)
	return _part(parent, title, surface.commit(), material)


func _plate(parent: Node3D, title: String, outline: Array, outward: Vector3, thickness: float, material: Material) -> MeshInstance3D:
	var center := Vector3.ZERO
	for point in outline:
		center += point
	center /= float(outline.size())
	var rim: Array[Vector3] = []
	var back: Array[Vector3] = []
	for point in outline:
		rim.append(center.lerp(point, 0.83) + outward * thickness)
		back.append(point - outward * thickness * 0.3)
	var surface := SurfaceTool.new()
	surface.begin(Mesh.PRIMITIVE_TRIANGLES)
	for j in range(outline.size()):
		var k := (j + 1) % outline.size()
		_triangle(surface, center + outward * thickness, rim[j], rim[k], outward)
		_quad(surface, outline[j], outline[k], rim[k], rim[j], outward + (outline[j] - center).normalized() * 0.4)
		_quad(surface, back[j], back[k], outline[k], outline[j], outline[j] - center)
		_triangle(surface, center - outward * thickness * 0.3, back[j], back[k], -outward)
	return _part(parent, title, surface.commit(), material)


func _quad(surface: SurfaceTool, a: Vector3, b: Vector3, c: Vector3, d: Vector3, outward: Vector3) -> void:
	_triangle(surface, a, b, c, outward)
	_triangle(surface, a, c, d, outward)


func _triangle(surface: SurfaceTool, a: Vector3, b: Vector3, c: Vector3, outward: Vector3) -> void:
	var normal := (b - a).cross(c - a).normalized()
	if normal.length_squared() < 0.5:
		return
	# Godot 正面为顺时针；法线朝外，绕序叉积朝内。
	if normal.dot(outward) < 0.0:
		normal = -normal
		var swap := b
		b = c
		c = swap
	for vertex in [a, c, b]:
		surface.set_normal(normal)
		surface.add_vertex(vertex)


func _part(parent: Node3D, title: String, mesh: Mesh, material: Material) -> MeshInstance3D:
	var part := MeshInstance3D.new()
	part.name = title
	part.mesh = mesh
	part.material_override = material
	parent.add_child(part)
	return part


func _batch_static(parent: Node3D) -> void:
	# 同一关节、同一材质的静态零件合并；保留独立的眼睛和犬齿供外形检查。
	# 不跨关节合并，头、下颌、肩甲、前腿、尾巴仍可各自动作。
	var groups: Dictionary = {}
	for child in parent.get_children():
		if child is MeshInstance3D:
			var part := child as MeshInstance3D
			if part.material_override == _eye or str(part.name).begins_with("UpperFang") or str(part.name).begins_with("LowerFang"):
				continue
			if not groups.has(part.material_override):
				groups[part.material_override] = []
			groups[part.material_override].append(part)
		elif child is Node3D:
			_batch_static(child as Node3D)
	for material in groups:
		var parts: Array = groups[material]
		if parts.size() < 2:
			continue
		var surface := SurfaceTool.new()
		surface.begin(Mesh.PRIMITIVE_TRIANGLES)
		var title: String = str(parts[0].name)
		for part in parts:
			var transform: Transform3D = part.transform
			var normal_basis := transform.basis.inverse().transposed()
			for index in range(part.mesh.get_surface_count()):
				# BoxMesh 有索引、自建网格无索引；统一展开，避免混合后漏掉面。
				var arrays: Array = part.mesh.surface_get_arrays(index)
				var vertices: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
				var normals: PackedVector3Array = arrays[Mesh.ARRAY_NORMAL]
				var order := PackedInt32Array()
				if arrays[Mesh.ARRAY_INDEX] is PackedInt32Array:
					order = arrays[Mesh.ARRAY_INDEX]
				if order.is_empty():
					for vertex_index in range(vertices.size()):
						order.append(vertex_index)
				for vertex_index in order:
					surface.set_normal((normal_basis * normals[vertex_index]).normalized())
					surface.add_vertex(transform * vertices[vertex_index])
			parent.remove_child(part)
			part.free()
		_part(parent, title, surface.commit(), material)
