@tool
extends MeshInstance3D
## 快速野兽的第一版剪影灰模。
##
## 造型刻意只使用少量大体块：三个躯干团块、头/吻部、四条分段腿和两段尾巴。
## 所有部件在生成时烘进同一个 ArrayMesh，因此运行时只有一个 MeshInstance3D、
## 一个材质和一次绘制提交。这个脚本只负责视觉原型，不包含敌人 AI 或碰撞。

const LowPolyMeshUtil := preload("res://scripts/lowpoly_mesh.gd")

const FUR_DARK := Color(0.115, 0.075, 0.05, 1.0)
const FUR_MID := Color(0.30, 0.15, 0.075, 1.0)
const FUR_LIGHT := Color(0.48, 0.255, 0.105, 1.0)
const CLAW := Color(0.10, 0.085, 0.072, 1.0)
const EYE := Color(1.0, 0.28, 0.035, 1.0)


func _ready() -> void:
	_rebuild()


func _rebuild() -> void:
	mesh = _build_mesh()
	var surface_material := StandardMaterial3D.new()
	surface_material.vertex_color_use_as_albedo = true
	surface_material.roughness = 0.92
	surface_material.metallic = 0.0
	material_override = surface_material


func _build_mesh() -> ArrayMesh:
	var builder := LowPolyMeshUtil.begin()

	# 三个大团块先决定“低、长、前轻后重”的四足剪影。
	_add_ellipsoid(builder, Vector3(0.0, 1.13, 0.05), Vector3(0.62, 0.50, 1.05), Basis.IDENTITY, FUR_MID, 7, 4)
	_add_ellipsoid(builder, Vector3(0.0, 1.18, -0.58), Vector3(0.68, 0.58, 0.62), Basis.IDENTITY, FUR_LIGHT, 7, 4)
	_add_ellipsoid(builder, Vector3(0.0, 1.16, 0.68), Vector3(0.73, 0.65, 0.68), Basis.IDENTITY, FUR_DARK, 7, 4)

	# 脖子、头与吻部整体压低，避免读成人形或直立机器人。
	_add_segment(builder, Vector3(0.0, 1.43, -0.75), Vector3(0.0, 1.30, -1.16), 0.40, 0.32, 7, FUR_MID)
	_add_ellipsoid(builder, Vector3(0.0, 1.28, -1.38), Vector3(0.43, 0.38, 0.55), Basis.IDENTITY, FUR_LIGHT, 7, 4)
	_add_box(builder, Vector3(0.0, 1.13, -1.78), Vector3(0.50, 0.28, 0.62), Basis.from_euler(Vector3(-0.10, 0.0, 0.0)), FUR_DARK)
	_add_box(builder, Vector3(0.0, 1.08, -2.09), Vector3(0.34, 0.20, 0.16), Basis.IDENTITY, CLAW)

	# 两只大耳朵承担动物性，不增加零碎毛发或装饰件。
	_add_segment(builder, Vector3(-0.25, 1.54, -1.34), Vector3(-0.31, 1.94, -1.27), 0.19, 0.015, 4, FUR_DARK)
	_add_segment(builder, Vector3(0.25, 1.54, -1.34), Vector3(0.31, 1.94, -1.27), 0.19, 0.015, 4, FUR_DARK)

	# 前后腿故意摆成错开的奔跑预备姿态；负空间比关节细节更重要。
	_add_leg(builder, Vector3(-0.47, 1.08, -0.62), Vector3(-0.49, 0.61, -0.82), Vector3(-0.49, 0.18, -1.02), -0.12)
	_add_leg(builder, Vector3(0.47, 1.06, -0.54), Vector3(0.49, 0.59, -0.36), Vector3(0.49, 0.18, -0.22), 0.10)
	_add_leg(builder, Vector3(-0.50, 1.08, 0.63), Vector3(-0.52, 0.64, 0.91), Vector3(-0.52, 0.18, 0.72), -0.10)
	_add_leg(builder, Vector3(0.50, 1.06, 0.70), Vector3(0.52, 0.60, 0.48), Vector3(0.52, 0.18, 0.26), 0.10)

	# 两段长尾把轮廓继续向后拉，强化“速度型”而不是“缩小的人”。
	_add_segment(builder, Vector3(0.0, 1.38, 1.18), Vector3(0.0, 1.48, 1.95), 0.24, 0.15, 7, FUR_DARK)
	_add_segment(builder, Vector3(0.0, 1.48, 1.92), Vector3(0.0, 1.36, 2.70), 0.15, 0.035, 7, FUR_DARK)

	# 两个眼点仍烘在同一网格中，不增加材质或绘制次数。
	_add_ellipsoid(builder, Vector3(-0.285, 1.40, -1.72), Vector3(0.055, 0.055, 0.035), Basis.IDENTITY, EYE, 6, 3)
	_add_ellipsoid(builder, Vector3(0.285, 1.40, -1.72), Vector3(0.055, 0.055, 0.035), Basis.IDENTITY, EYE, 6, 3)

	return LowPolyMeshUtil.commit(builder)


func _add_leg(builder: LowPolyMeshUtil.Builder, hip: Vector3, knee: Vector3, paw: Vector3, side: float) -> void:
	_add_segment(builder, hip, knee, 0.22, 0.17, 6, FUR_DARK)
	_add_segment(builder, knee, paw + Vector3(0.0, 0.10, 0.0), 0.17, 0.11, 6, FUR_MID)
	# 四面锥台比扁盒更像整块兽掌，同时仍只需 12 个三角面。
	var paw_side := Vector3(sin(side) * 0.035, 0.0, 0.0)
	_add_segment(
		builder,
		paw + Vector3(0.0, 0.11, 0.15) + paw_side,
		paw + Vector3(0.0, 0.08, -0.25) + paw_side,
		0.25, 0.18, 4, CLAW
	)


func _add_ellipsoid(
	builder: LowPolyMeshUtil.Builder,
	center: Vector3,
	radii: Vector3,
	basis: Basis,
	color: Color,
	facets: int = 8,
	rings: int = 4
) -> void:
	var ring_points: Array = []
	for ring_index in range(1, rings):
		var latitude := -PI * 0.5 + PI * float(ring_index) / float(rings)
		var ring: Array[Vector3] = []
		for index in range(facets):
			var angle := TAU * float(index) / float(facets)
			var local := Vector3(
				cos(angle) * cos(latitude) * radii.x,
				sin(latitude) * radii.y,
				sin(angle) * cos(latitude) * radii.z
			)
			ring.append(center + basis * local)
		ring_points.append(ring)
	var bottom := center + basis * Vector3(0.0, -radii.y, 0.0)
	var top := center + basis * Vector3(0.0, radii.y, 0.0)
	var first := ring_points[0] as Array
	var last := ring_points[ring_points.size() - 1] as Array
	for index in range(facets):
		var next := (index + 1) % facets
		LowPolyMeshUtil.push_triangle(builder, bottom, first[index], first[next], color.darkened(0.12))
		for ring_index in range(ring_points.size() - 1):
			var lower := ring_points[ring_index] as Array
			var upper := ring_points[ring_index + 1] as Array
			LowPolyMeshUtil.push_quad(builder, lower[next], lower[index], upper[index], upper[next], color)
		LowPolyMeshUtil.push_triangle(builder, last[next], last[index], top, color.lightened(0.08))


func _add_segment(
	builder: LowPolyMeshUtil.Builder,
	start: Vector3,
	finish: Vector3,
	start_radius: float,
	end_radius: float,
	facets: int,
	color: Color
) -> void:
	var direction := (finish - start).normalized()
	var helper := Vector3.UP if absf(direction.dot(Vector3.UP)) < 0.92 else Vector3.RIGHT
	var axis_u := helper.cross(direction).normalized()
	var axis_v := direction.cross(axis_u).normalized()
	var start_ring: Array[Vector3] = []
	var end_ring: Array[Vector3] = []
	for index in range(facets):
		var angle := TAU * float(index) / float(facets)
		var radial := axis_u * cos(angle) + axis_v * sin(angle)
		start_ring.append(start + radial * start_radius)
		end_ring.append(finish + radial * end_radius)
	for index in range(facets):
		var next := (index + 1) % facets
		LowPolyMeshUtil.push_quad(
			builder, start_ring[index], start_ring[next], end_ring[next], end_ring[index], color
		)
		LowPolyMeshUtil.push_triangle(builder, start, start_ring[next], start_ring[index], color.darkened(0.1))
		if end_radius > 0.001:
			LowPolyMeshUtil.push_triangle(builder, finish, end_ring[index], end_ring[next], color.lightened(0.05))


func _add_box(
	builder: LowPolyMeshUtil.Builder,
	center: Vector3,
	size: Vector3,
	basis: Basis,
	color: Color
) -> void:
	var half := size * 0.5
	var points: Array[Vector3] = [
		Vector3(-half.x, -half.y, -half.z), Vector3(half.x, -half.y, -half.z),
		Vector3(half.x, -half.y, half.z), Vector3(-half.x, -half.y, half.z),
		Vector3(-half.x, half.y, -half.z), Vector3(half.x, half.y, -half.z),
		Vector3(half.x, half.y, half.z), Vector3(-half.x, half.y, half.z),
	]
	for index in range(points.size()):
		points[index] = center + basis * points[index]
	LowPolyMeshUtil.push_quad(builder, points[4], points[7], points[6], points[5], color.lightened(0.08))
	LowPolyMeshUtil.push_quad(builder, points[3], points[0], points[1], points[2], color.darkened(0.12))
	LowPolyMeshUtil.push_quad(builder, points[7], points[3], points[2], points[6], color)
	LowPolyMeshUtil.push_quad(builder, points[0], points[4], points[5], points[1], color.darkened(0.05))
	LowPolyMeshUtil.push_quad(builder, points[1], points[5], points[6], points[2], color)
	LowPolyMeshUtil.push_quad(builder, points[3], points[7], points[4], points[0], color)
