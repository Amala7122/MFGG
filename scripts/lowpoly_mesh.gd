class_name LowPolyMesh
extends RefCounted
## 低多边形几何工厂：把一堆面变成硬边网格。
##
## "雕塑感"来自【每个面一个法线】。共享顶点 + 平均法线会把面糊成光滑曲面，
## 那正是巨石 / 树冠 / 山体看起来"圆滚滚"的根源。
## 这里用不共享顶点的方式提交：每个三角形三个顶点写同一个面法线。
##
## 不需要自定义着色器：StandardMaterial3D 配 vertex_color_use_as_albedo 即可。

## 面集合。三个数组等长，逐顶点写入。
class Builder:
	var verts := PackedVector3Array()
	var normals := PackedVector3Array()
	var colors := PackedColorArray()


static func begin() -> Builder:
	return Builder.new()


## 提交一个三角形。调用方始终按右手系的外法线顺序 a→b→c 描述表面；
## 这里统一把顶点写成 a→c→b，因为 Godot 把顺时针绕序认作正面。
##
## 不允许调用方自行“翻法线”补救：三角形正面由绕序决定，光照由法线决定，
## 只改其中一个正是过去倒角出现“里面成外面”的根源。
static func push_triangle(builder: Builder, a: Vector3, b: Vector3, c: Vector3, color: Color) -> void:
	var normal := (b - a).cross(c - a)
	if normal.length_squared() < 0.000001:
		return
	_push(builder, a, c, b, normal.normalized(), color)


## 提交一个四边形，按 a→b→c→d 的绕序拆成两个三角形。
static func push_quad(
	builder: Builder, a: Vector3, b: Vector3, c: Vector3, d: Vector3, color: Color
) -> void:
	push_triangle(builder, a, b, c, color)
	push_triangle(builder, a, c, d, color)


## 提交一个盒子（center 为中心，size 为全尺寸）的六个面。
static func push_box(builder: Builder, center: Vector3, size: Vector3, color: Color) -> void:
	var h := size * 0.5
	var x0 := center.x - h.x
	var x1 := center.x + h.x
	var y0 := center.y - h.y
	var y1 := center.y + h.y
	var z0 := center.z - h.z
	var z1 := center.z + h.z
	var a := Vector3(x0, y0, z0)
	var b := Vector3(x1, y0, z0)
	var c := Vector3(x1, y0, z1)
	var d := Vector3(x0, y0, z1)
	var e := Vector3(x0, y1, z0)
	var f := Vector3(x1, y1, z0)
	var g := Vector3(x1, y1, z1)
	var t := Vector3(x0, y1, z1)
	# 每一面都从物体外侧看按同一绕序提交，叉乘法线因此统一朝外。
	push_quad(builder, e, t, g, f, color)
	push_quad(builder, d, a, b, c, color)
	push_quad(builder, t, d, c, g, color)
	push_quad(builder, a, e, f, b, color)
	push_quad(builder, b, f, g, c, color)
	push_quad(builder, d, t, e, a, color)


## 完整 12 边 + 8 角倒角盒。size 是最终外包尺寸，bevel 是每条边向内切的距离。
## 所有面都经过 push_triangle，因此可见正面、光照法线和几何外侧共用一个约定。
static func chamfered_box(
	size: Vector3, bevel: float, color: Color = Color.WHITE
) -> ArrayMesh:
	var safe_size := Vector3(maxf(size.x, 0.001), maxf(size.y, 0.001), maxf(size.z, 0.001))
	var half := safe_size * 0.5
	var safe_bevel := clampf(bevel, 0.0, minf(half.x, minf(half.y, half.z)) * 0.95)
	var builder := begin()
	if safe_bevel <= 0.0001:
		push_box(builder, Vector3.ZERO, safe_size, color)
		return _commit_validated_chamfer(builder)

	# 每个原始角被一个三角面截去，留下三个顶点；共 24 个凸多面体顶点。
	var vertices: Array[Vector3] = []
	for sx in [-1.0, 1.0]:
		for sy in [-1.0, 1.0]:
			for sz in [-1.0, 1.0]:
				var corner := Vector3(sx * half.x, sy * half.y, sz * half.z)
				vertices.append(corner - Vector3(sx * safe_bevel, 0.0, 0.0))
				vertices.append(corner - Vector3(0.0, sy * safe_bevel, 0.0))
				vertices.append(corner - Vector3(0.0, 0.0, sz * safe_bevel))

	# 六个主面：每个面是切掉四角后的八边形。
	for axis in range(3):
		for sign_value in [-1.0, 1.0]:
			var outward: Vector3 = _axis_vector(axis) * float(sign_value)
			var points: Array[Vector3] = []
			var target: float = _component(half, axis)
			for point in vertices:
				if is_equal_approx(float(sign_value) * _component(point, axis), target):
					points.append(point)
			_push_polygon(builder, points, outward, _face_tint(color, outward))

	# 十二个边面：两个轴向的截面相交成四边形。
	var edge_axes := [[0, 1], [0, 2], [1, 2]]
	for pair in edge_axes:
		var axis_a := int(pair[0])
		var axis_b := int(pair[1])
		for sign_a in [-1.0, 1.0]:
			for sign_b in [-1.0, 1.0]:
				var outward: Vector3 = (
					_axis_vector(axis_a) * float(sign_a)
					+ _axis_vector(axis_b) * float(sign_b)
				).normalized()
				var target: float = (
					_component(half, axis_a) + _component(half, axis_b) - safe_bevel
				)
				var points: Array[Vector3] = []
				for point in vertices:
					var plane_value: float = (
						float(sign_a) * _component(point, axis_a)
						+ float(sign_b) * _component(point, axis_b)
					)
					if is_equal_approx(plane_value, target):
						points.append(point)
				_push_polygon(builder, points, outward, _face_tint(color, outward).lightened(0.025))

	# 八个角面：每个原始角对应一个三角形。
	for sx in [-1.0, 1.0]:
		for sy in [-1.0, 1.0]:
			for sz in [-1.0, 1.0]:
				var outward := Vector3(float(sx), float(sy), float(sz)).normalized()
				var target: float = half.x + half.y + half.z - safe_bevel
				var points: Array[Vector3] = []
				for point in vertices:
					var plane_value: float = (
						float(sx) * point.x + float(sy) * point.y + float(sz) * point.z
					)
					if is_equal_approx(plane_value, target):
						points.append(point)
				_push_polygon(builder, points, outward, _face_tint(color, outward).lightened(0.04))
	return _commit_validated_chamfer(builder)


## 多环硬边椭球。比 Godot 的光滑 SphereMesh 多出清楚的折面受光，既可作为
## 岩石，也可作为树冠；irregularity 只改变轮廓，不额外增加节点或材质。
static func faceted_ellipsoid(
	radius: float = 1.0, height: float = 2.0, facets: int = 12, rings: int = 6,
	irregularity: float = 0.12
) -> ArrayMesh:
	var safe_facets := maxi(facets, 5)
	var safe_rings := maxi(rings, 3)
	var builder := begin()
	var ring_points: Array = []
	for ring_index in range(1, safe_rings):
		var latitude := -PI * 0.5 + PI * float(ring_index) / float(safe_rings)
		var ring: Array[Vector3] = []
		for index in range(safe_facets):
			var angle := TAU * float(index) / float(safe_facets)
			var wobble := 1.0 + irregularity * (
				sin(float(index) * 2.17 + float(ring_index) * 1.31) * 0.62
				+ cos(float(index) * 1.13 - float(ring_index) * 2.07) * 0.38
			)
			ring.append(Vector3(
				cos(angle) * cos(latitude) * radius * wobble,
				sin(latitude) * height * 0.5,
				sin(angle) * cos(latitude) * radius * wobble
			))
		ring_points.append(ring)
	var bottom := Vector3(0.0, -height * 0.5, 0.0)
	var top := Vector3(radius * irregularity * 0.18, height * 0.5, -radius * irregularity * 0.12)
	var first := ring_points[0] as Array
	var last := ring_points[ring_points.size() - 1] as Array
	for index in range(safe_facets):
		var next := (index + 1) % safe_facets
		push_triangle(builder, bottom, first[index], first[next], Color(0.88, 0.88, 0.88))
		for ring_index in range(ring_points.size() - 1):
			var lower := ring_points[ring_index] as Array
			var upper := ring_points[ring_index + 1] as Array
			push_quad(builder, lower[next], lower[index], upper[index], upper[next], Color.WHITE)
		push_triangle(builder, last[next], last[index], top, Color(1.04, 1.04, 1.04))
	return commit(builder)


## 分段硬边圆锥，用于松树冠。三层圆锥共用同一份网格，轮廓比平滑锥体清楚。
static func faceted_cone(radius: float = 1.0, height: float = 2.5, facets: int = 12) -> ArrayMesh:
	var safe_facets := maxi(facets, 5)
	var builder := begin()
	var top := Vector3(0.0, height * 0.5, 0.0)
	var bottom := Vector3(0.0, -height * 0.5, 0.0)
	var ring: Array[Vector3] = []
	for index in range(safe_facets):
		var angle := TAU * float(index) / float(safe_facets)
		ring.append(Vector3(cos(angle) * radius, -height * 0.5, sin(angle) * radius))
	for index in range(safe_facets):
		var next := (index + 1) % safe_facets
		push_triangle(builder, ring[next], ring[index], top, Color.WHITE)
		push_triangle(builder, bottom, ring[index], ring[next], Color(0.82, 0.82, 0.82))
	return commit(builder)


## 内部：写入三个顶点，共用同一条法线与同一个颜色。
static func _push(
	builder: Builder, a: Vector3, b: Vector3, c: Vector3, normal: Vector3, color: Color
) -> void:
	builder.verts.append(a)
	builder.verts.append(b)
	builder.verts.append(c)
	for _i in range(3):
		builder.normals.append(normal)
		builder.colors.append(color)


## 检查封闭凸网格的每个三角形：Godot 正面、写入法线、从中心向外必须同向。
## 返回空数组表示通过。测试与调试工具应调用它，防止未来再次提交翻面网格。
static func validate_convex_outward(mesh: ArrayMesh, center: Vector3 = Vector3.ZERO) -> PackedStringArray:
	var errors := PackedStringArray()
	if mesh == null or mesh.get_surface_count() == 0:
		errors.append("网格为空")
		return errors
	var arrays := mesh.surface_get_arrays(0)
	var vertices: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
	var normals: PackedVector3Array = arrays[Mesh.ARRAY_NORMAL]
	if vertices.size() % 3 != 0:
		errors.append("顶点数不是 3 的倍数")
		return errors
	if normals.size() != vertices.size():
		errors.append("法线数与顶点数不一致")
		return errors
	for index in range(0, vertices.size(), 3):
		var a := vertices[index]
		var b := vertices[index + 1]
		var c := vertices[index + 2]
		# Godot 的顺时针正面方向。
		var front := (c - a).cross(b - a)
		if front.length_squared() < 0.000001:
			errors.append("三角形 %d 退化" % (index / 3))
			continue
		front = front.normalized()
		var centroid := (a + b + c) / 3.0
		if front.dot(centroid - center) <= 0.0001:
			errors.append("三角形 %d 的可见正面朝内" % (index / 3))
		if front.dot(normals[index].normalized()) < 0.999:
			errors.append("三角形 %d 的法线与可见正面不一致" % (index / 3))
	return errors


static func _commit_validated_chamfer(builder: Builder) -> ArrayMesh:
	var mesh := commit(builder)
	if OS.is_debug_build():
		var errors := validate_convex_outward(mesh)
		assert(errors.is_empty(), "倒角网格面序校验失败：%s" % "; ".join(errors))
	return mesh


static func _push_polygon(
	builder: Builder, source_points: Array[Vector3], outward: Vector3, color: Color
) -> void:
	if source_points.size() < 3:
		push_error("LowPolyMesh: 构面失败，顶点不足 %d" % source_points.size())
		return
	var center := Vector3.ZERO
	for point in source_points:
		center += point
	center /= float(source_points.size())
	var helper := Vector3.UP if absf(outward.dot(Vector3.UP)) < 0.9 else Vector3.RIGHT
	var axis_u := helper.cross(outward).normalized()
	var axis_v := outward.cross(axis_u).normalized()
	var points := source_points.duplicate()
	points.sort_custom(func(left: Vector3, right: Vector3) -> bool:
		var left_delta := left - center
		var right_delta := right - center
		var left_angle := atan2(left_delta.dot(axis_v), left_delta.dot(axis_u))
		var right_angle := atan2(right_delta.dot(axis_v), right_delta.dot(axis_u))
		return left_angle < right_angle
	)
	for index in range(1, points.size() - 1):
		push_triangle(builder, points[0], points[index], points[index + 1], color)


static func _component(value: Vector3, axis: int) -> float:
	match axis:
		0:
			return value.x
		1:
			return value.y
		_:
			return value.z


static func _axis_vector(axis: int) -> Vector3:
	match axis:
		0:
			return Vector3.RIGHT
		1:
			return Vector3.UP
		_:
			return Vector3.BACK


static func _face_tint(color: Color, outward: Vector3) -> Color:
	if outward.y > 0.5:
		return color.lightened(0.035)
	if outward.y < -0.5:
		return color.darkened(0.055)
	return color


## 收尾：生成为单个 ArrayMesh。空集合返回 null。
static func commit(builder: Builder) -> ArrayMesh:
	if builder.verts.is_empty():
		return null
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = builder.verts
	arrays[Mesh.ARRAY_NORMAL] = builder.normals
	arrays[Mesh.ARRAY_COLOR] = builder.colors
	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	return mesh


## 按距离把颜色推向天空色：越远越亮、越冷、对比越低。
## ratio 是 0（近）到 1（远）。把分层直接烘进顶点色，运行时代价为零。
static func grade_by_distance(base: Color, sky: Color, ratio: float) -> Color:
	return base.lerp(sky, clampf(ratio, 0.0, 1.0))
