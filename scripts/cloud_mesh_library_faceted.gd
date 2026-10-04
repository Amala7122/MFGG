@tool
extends RefCounted
## 切面云：多边形云块堆积成连续表面，仅在衔接处做窄幅融合。
## 保留平面、折线和灰色云底，不逐顶点随机扰动，也不做整体圆润化。

const Rounded := preload("res://scripts/cloud_mesh_library_rounded.gd")
## 修改生成参数时递增，编辑器中的云场会自动替换缓存引用。
const GENERATION_VERSION := 1
const JOIN_WIDTH := 5.0
const SIDE_DIRECTIONS := [
	Vector2(1.0, 0.0), Vector2(0.766044, 0.642788), Vector2(0.173648, 0.984808),
	Vector2(-0.5, 0.866025), Vector2(-0.939693, 0.342020), Vector2(-0.939693, -0.342020),
	Vector2(-0.5, -0.866025), Vector2(0.173648, -0.984808), Vector2(0.766044, -0.642788),
]


static func build_cloud(variant: int) -> ArrayMesh:
	var shape := Rounded.make_puffs(variant)
	var puffs: Array[Rounded.Puff] = shape["puffs"]
	# 保留平面轮廓；只在云块相交的窄区域融合，不对整个网格做松弛。
	return Rounded._extract_surface(puffs, shape["lower"], shape["upper"], _distance.bind(puffs), 0.0, _face_color, 0.02)


static func _distance(point: Vector3, puffs: Array[Rounded.Puff]) -> float:
	var distance := 1000000.0
	for puff in puffs:
		var local := puff.inverse_rotation * (point - puff.center) / puff.radii
		var radial := -INF
		for direction in SIDE_DIRECTIONS:
			radial = maxf(radial, Vector2(local.x, local.z).dot(direction))
		# 九边体的上下肩部都是平面倒角。限制顶部/底部外伸，防止出现薄片尖端。
		var next := maxf(radial - 0.94, local.y - 0.55)
		next = maxf(next, -local.y - 0.40)
		next = maxf(next, radial * 0.75 + local.y * 1.20 - 0.95)
		next = maxf(next, radial * 0.75 - local.y * 1.35 - 0.98)
		next *= puff.distance_scale
		# 所有相交云块只提取同一张外皮，内部面不会形成台阶剪影。
		var blend := clampf(0.5 + 0.5 * (next - distance) / JOIN_WIDTH, 0.0, 1.0)
		distance = lerpf(next, distance, blend) - JOIN_WIDTH * blend * (1.0 - blend)
	return distance


static func _face_color(a: Vector3, b: Vector3, c: Vector3) -> Color:
	var normal := (b - a).cross(c - a).normalized()
	var shade := clampf(0.88 + normal.y * 0.13 + normal.x * 0.015 + normal.z * 0.01, 0.73, 1.0)
	return Color(shade, minf(shade + 0.012, 1.0), minf(shade + 0.025, 1.0))
