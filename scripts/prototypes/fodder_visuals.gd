class_name FodderVisuals
extends RefCounted
## 人群/炮灰用的简化部件表：每种敌人一张，全部由基础图元拼成，
## 走 FodderField._build_visuals() 的同一套“合并网格 + 通用着色器”。
##
## 与正式敌人模型的关系：正式模型是节点/骨架，进不了 1000 只的 MultiMesh；
## 这里只保留轮廓、四肢和发光点，用部件角色驱动摆臂/迈腿/攻击前挥。
##
## 角色：0 躯干 / 1 发光核心（眼、晶核）/ 2 头 / 3 尾或背囊 / 10、11 前肢 / 12.. 腿

const BODY := 0
const CORE := 1
const HEAD := 2
const TAIL := 3
const LIMB_FRONT := 10
const LIMB := 12


static func table(id: String) -> Dictionary:
	match id:
		"fast_beast":
			return _fast_beast()
		"burst_crawler":
			return _burst_crawler()
		"prism_spider":
			return _prism_spider()
		"charge_beetle":
			return _charge_beetle()
		_:
			return _mud_golem()


static func make_mesh(part: Dictionary) -> Mesh:
	var shape := String(part.get("shape", "box"))
	match shape:
		"sphere":
			var sphere := SphereMesh.new()
			sphere.radius = float(part.get("radius", 0.3))
			sphere.height = sphere.radius * 2.0
			sphere.radial_segments = int(part.get("segments", 8))
			sphere.rings = 4
			return sphere
		"cylinder":
			var cylinder := CylinderMesh.new()
			cylinder.top_radius = float(part.get("top", 0.3))
			cylinder.bottom_radius = float(part.get("bottom", 0.25))
			cylinder.height = float(part.get("height", 0.6))
			cylinder.radial_segments = int(part.get("segments", 8))
			cylinder.rings = 0
			return cylinder
		_:
			var box := BoxMesh.new()
			box.size = part.get("size", Vector3.ONE * 0.3)
			return box


static func _part(shape: String, pos: Vector3, pivot: Vector3, role: int,
		color: Color, glow := 0.0, extra := {}) -> Dictionary:
	var part := {"shape": shape, "pos": pos, "pivot": pivot, "role": role,
		"color": color, "glow": glow}
	part.merge(extra, true)
	return part


static func _box(pos: Vector3, size: Vector3, pivot: Vector3, role: int,
		color: Color, glow := 0.0, euler := Vector3.ZERO, scale := 1.0) -> Dictionary:
	return _part("box", pos, pivot, role, color, glow,
		{"size": size, "euler": euler, "scale": scale})


static func _sphere(pos: Vector3, radius: float, pivot: Vector3, role: int,
		color: Color, glow := 0.0) -> Dictionary:
	return _part("sphere", pos, pivot, role, color, glow, {"radius": radius})


static func _cylinder(pos: Vector3, top: float, bottom: float, height: float,
		pivot: Vector3, role: int, color: Color) -> Dictionary:
	return _part("cylinder", pos, pivot, role, color, 0.0,
		{"top": top, "bottom": bottom, "height": height})


static func _mud_golem() -> Dictionary:
	var body := Color(0.28, 0.32, 0.22)
	var fist := Color(0.42, 0.44, 0.45)
	return {"parts": [
		_cylinder(Vector3(0, 0.75, 0), 0.4, 0.25, 0.6, Vector3(0, 0.75, 0), BODY, body),
		_box(Vector3(0, 0.87, 0.32), Vector3(0.16, 0.16, 0.16), Vector3(0, 0.87, 0.32),
			CORE, Color(0.10, 0.85, 0.90), 0.16, Vector3(deg_to_rad(45), deg_to_rad(45), 0)),
		_box(Vector3(-0.6, 0.6, 0), Vector3(0.28, 0.42, 0.32), Vector3(-0.45, 0.9, 0),
			LIMB_FRONT, fist),
		_box(Vector3(0.6, 0.6, 0), Vector3(0.28, 0.42, 0.32), Vector3(0.45, 0.9, 0),
			LIMB_FRONT + 1, fist, 0.0, Vector3.ZERO, 1.15),
		_box(Vector3(-0.22, 0.2, 0), Vector3(0.18, 0.35, 0.22), Vector3(-0.22, 0.35, 0),
			LIMB, body),
		_box(Vector3(0.22, 0.2, 0), Vector3(0.18, 0.35, 0.22), Vector3(0.22, 0.35, 0),
			LIMB + 1, body),
	]}


static func _fast_beast() -> Dictionary:
	var hide := Color(0.46, 0.31, 0.18)
	var dark := Color(0.34, 0.22, 0.13)
	var head := Color(0.52, 0.35, 0.20)
	return {"parts": [
		_box(Vector3(0, 0.92, 0), Vector3(0.72, 0.62, 1.5), Vector3(0, 0.92, 0), BODY, hide),
		_box(Vector3(0, 1.02, 0.85), Vector3(0.46, 0.44, 0.5), Vector3(0, 1.02, 0.85), HEAD, head),
		_box(Vector3(0, 0.92, 1.18), Vector3(0.3, 0.22, 0.3), Vector3(0, 0.92, 1.18), HEAD, dark),
		_box(Vector3(0, 1.0, -0.95), Vector3(0.1, 0.1, 0.55), Vector3(0, 1.0, -0.7), TAIL, dark),
		_box(Vector3(-0.3, 0.36, 0.52), Vector3(0.2, 0.72, 0.24), Vector3(-0.3, 0.72, 0.52),
			LIMB, dark),
		_box(Vector3(0.3, 0.36, 0.52), Vector3(0.2, 0.72, 0.24), Vector3(0.3, 0.72, 0.52),
			LIMB + 1, dark),
		_box(Vector3(-0.3, 0.36, -0.52), Vector3(0.2, 0.72, 0.24), Vector3(-0.3, 0.72, -0.52),
			LIMB + 2, dark),
		_box(Vector3(0.3, 0.36, -0.52), Vector3(0.2, 0.72, 0.24), Vector3(0.3, 0.72, -0.52),
			LIMB + 3, dark),
		_box(Vector3(-0.13, 1.08, 1.1), Vector3(0.07, 0.06, 0.05), Vector3(-0.13, 1.08, 1.1),
			CORE, Color(0.15, 0.9, 0.85), 0.5),
		_box(Vector3(0.13, 1.08, 1.1), Vector3(0.07, 0.06, 0.05), Vector3(0.13, 1.08, 1.1),
			CORE, Color(0.15, 0.9, 0.85), 0.5),
	]}


static func _burst_crawler() -> Dictionary:
	var shell := Color(0.5, 0.22, 0.16)
	var dark := Color(0.38, 0.17, 0.12)
	return {"parts": [
		_box(Vector3(0, 0.6, 0), Vector3(1.0, 0.5, 1.35), Vector3(0, 0.6, 0), BODY, shell),
		_sphere(Vector3(0, 1.02, -0.25), 0.42, Vector3(0, 1.02, -0.25), TAIL,
			Color(0.62, 0.30, 0.18), 0.04),
		_box(Vector3(0, 0.7, 0.75), Vector3(0.4, 0.35, 0.4), Vector3(0, 0.7, 0.75), HEAD,
			Color(0.56, 0.27, 0.18)),
		_box(Vector3(-0.55, 0.25, -0.45), Vector3(0.16, 0.5, 0.18), Vector3(-0.55, 0.5, -0.45),
			LIMB, dark),
		_box(Vector3(0.55, 0.25, -0.45), Vector3(0.16, 0.5, 0.18), Vector3(0.55, 0.5, -0.45),
			LIMB + 1, dark),
		_box(Vector3(-0.55, 0.25, 0.0), Vector3(0.16, 0.5, 0.18), Vector3(-0.55, 0.5, 0.0),
			LIMB + 2, dark),
		_box(Vector3(0.55, 0.25, 0.0), Vector3(0.16, 0.5, 0.18), Vector3(0.55, 0.5, 0.0),
			LIMB + 3, dark),
		_box(Vector3(-0.55, 0.25, 0.45), Vector3(0.16, 0.5, 0.18), Vector3(-0.55, 0.5, 0.45),
			LIMB + 4, dark),
		_box(Vector3(0.55, 0.25, 0.45), Vector3(0.16, 0.5, 0.18), Vector3(0.55, 0.5, 0.45),
			LIMB + 5, dark),
	]}


static func _prism_spider() -> Dictionary:
	var shell := Color(0.35, 0.25, 0.45)
	var dark := Color(0.28, 0.19, 0.36)
	var parts := [
		_sphere(Vector3(0, 0.65, 0), 0.45, Vector3(0, 0.65, 0), BODY, shell),
		_box(Vector3(0, 0.7, 0.55), Vector3(0.3, 0.25, 0.3), Vector3(0, 0.7, 0.55), HEAD,
			Color(0.42, 0.31, 0.52)),
		_box(Vector3(-0.08, 0.78, 0.68), Vector3(0.07, 0.06, 0.05), Vector3(-0.08, 0.78, 0.68),
			CORE, Color(0.2, 0.95, 0.9), 0.6),
		_box(Vector3(0.08, 0.78, 0.68), Vector3(0.07, 0.06, 0.05), Vector3(0.08, 0.78, 0.68),
			CORE, Color(0.2, 0.95, 0.9), 0.6),
		_box(Vector3(-0.18, 0.75, 0.64), Vector3(0.06, 0.05, 0.05), Vector3(-0.18, 0.75, 0.64),
			CORE, Color(0.2, 0.95, 0.9), 0.5),
		_box(Vector3(0.18, 0.75, 0.64), Vector3(0.06, 0.05, 0.05), Vector3(0.18, 0.75, 0.64),
			CORE, Color(0.2, 0.95, 0.9), 0.5),
	]
	var z_values := [0.22, 0.58]
	for z in z_values:
		for side in [-1.0, 1.0]:
			var role: int = LIMB if z > 0.4 else LIMB_FRONT
			if side > 0.0:
				role += 1
			parts.append(_box(Vector3(side * 0.42, 0.33, z), Vector3(0.09, 0.65, 0.09),
				Vector3(side * 0.42, 0.66, z), role, dark, 0.0,
				Vector3(0.0, 0.0, side * 0.55)))
	return {"parts": parts}


static func _charge_beetle() -> Dictionary:
	var shell := Color(0.38, 0.12, 0.10)
	var dark := Color(0.28, 0.09, 0.08)
	var parts := [
		_box(Vector3(0, 0.85, 0), Vector3(1.5, 0.6, 2.1), Vector3(0, 0.85, 0), BODY, shell),
		_box(Vector3(0, 0.7, 1.05), Vector3(0.6, 0.4, 0.5), Vector3(0, 0.7, 1.05), HEAD, shell),
		_box(Vector3(0, 0.98, 1.42), Vector3(0.18, 0.3, 0.85), Vector3(0, 0.88, 1.1), HEAD,
			Color(0.72, 0.55, 0.20), 0.0, Vector3(deg_to_rad(-22), 0, 0)),
	]
	for z in [-0.6, 0.0, 0.6]:
		for side in [-1.0, 1.0]:
			var role: int = LIMB + int((z + 0.6) / 0.6) * 2 + (0 if side < 0 else 1)
			parts.append(_box(Vector3(side * 0.66, 0.27, z), Vector3(0.18, 0.55, 0.2),
				Vector3(side * 0.66, 0.55, z), role, dark))
	return {"parts": parts}
