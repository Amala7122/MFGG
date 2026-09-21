extends SceneTree

const LowPolyMeshUtil := preload("res://scripts/lowpoly_mesh.gd")


func _initialize() -> void:
	var failed := false
	var cases := [
		{"size": Vector3(2.0, 2.0, 2.0), "bevel": 0.2},
		{"size": Vector3(12.0, 0.55, 11.0), "bevel": 0.35},
		{"size": Vector3(2.2, 8.0, 2.5), "bevel": 0.24},
		{"size": Vector3(8.0, 1.8, 1.2), "bevel": 0.18},
		{"size": Vector3(1.0, 1.0, 1.0), "bevel": 10.0},
	]
	for case_index in range(cases.size()):
		var spec := cases[case_index] as Dictionary
		var size: Vector3 = spec["size"]
		var mesh := LowPolyMeshUtil.chamfered_box(size, float(spec["bevel"]))
		var errors := LowPolyMeshUtil.validate_convex_outward(mesh)
		var bounds := mesh.get_aabb()
		if not bounds.size.is_equal_approx(size):
			errors.append("AABB 尺寸 %s 与目标 %s 不一致" % [bounds.size, size])
		var collision := mesh.create_convex_shape(true, false)
		if collision == null or collision.points.is_empty():
			errors.append("无法从倒角网格生成凸碰撞")
		if errors.is_empty():
			print("[倒角测试] 案例 %d 通过：size=%s bevel=%.3f" % [
				case_index, size, float(spec["bevel"])
			])
		else:
			failed = true
			for error in errors:
				push_error("[倒角测试] 案例 %d：%s" % [case_index, error])
	quit(1 if failed else 0)
