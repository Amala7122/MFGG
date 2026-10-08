extends SceneTree
## 固定场地中的实际构建、横扫和并发追踪预算，防止地面效果重新拖慢物理帧。
const SpatialScene := preload("res://prototypes/combat/spatial/combat_spatial_lab.tscn")
const AttackArea := preload("res://scripts/enemy_attack_area.gd")
const Surface := preload("res://scripts/attack_surface_mesh.gd")
const MeleeEffect := preload("res://scripts/prototypes/titan_melee_effect.gd")
var _lab: Node3D
var _failed := false


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	_lab = SpatialScene.instantiate()
	root.add_child(_lab)
	current_scene = _lab
	for _frame in range(12):
		await process_frame
	paused = true
	_verify_flat_builds()
	_verify_sweep()
	await _verify_tracking()
	current_scene = null
	_lab.free()
	paused = false
	await process_frame
	print("[地面性能回归] ", "FAIL" if _failed else "PASS")
	quit(1 if _failed else 0)


func _area() -> Node3D:
	var area := AttackArea.new()
	area.process_mode = Node.PROCESS_MODE_DISABLED
	_lab.add_child(area)
	return area


func _verify_flat_builds() -> void:
	var body := BoxShape3D.new()
	body.size = Vector3(0.9, 1.55, 1.6)
	for spec in [
		{"kind": "sector", "radius": 5.0, "angle": 270.0, "height": 2.5},
		{"kind": "capsule", "radius": 1.6, "length": 7.35, "height": 1.6, "travel_speed": 11.44,
			"jump_speed": 4.5, "gravity": 14.0, "flight_time": 0.64, "hit_angle": 90.0, "body_shape": body},
	]:
		var area := _area()
		var times: Array[float] = []
		for i in range(5):
			var start := Time.get_ticks_usec()
			# x=0 的 5m 横扫边缘碰到残柱；平地预算应测只有地板的完整范围。
			area.prepare(Transform3D(Basis.IDENTITY, Vector3(1, 0.8 if spec.kind == "capsule" else 1.7, 10)), spec, 10.0)
			if i > 0:
				times.append((Time.get_ticks_usec() - start) / 1000.0)
		_check(area._mesh.mesh != null and area.can_reach(Vector3(0, 1, 8)), "平地完整预警仍覆盖实际攻击路径")
		_check(is_finite(area.get_surface()._plane_height), "平地性能样本必须确实只有同一块平坦地板")
		_check(times.max() < 8.0, "平地 " + spec.kind + " 单次构建应低于 8ms：" + str(times))
		print("[地面性能回归] 平地 ", spec.kind, " build_ms=", times)
		area.free()


func _verify_sweep() -> void:
	var area := _area()
	var spec := {"kind": "sector", "radius": 10.0, "angle": 270.0, "height": 2.5}
	var build_start := Time.get_ticks_usec()
	area.prepare(Transform3D(Basis.IDENTITY, Vector3(0, 1.7, 8)), spec, 10.0)
	_check((Time.get_ticks_usec() - build_start) / 1000.0 < 30.0, "复杂地形狂暴横扫的初次生成应低于 30ms")
	spec.surface = area.get_surface()
	var effect: Node3D = MeleeEffect.spawn(_lab, area.global_transform, spec, 1.0, true, 0.45, 0.0)
	var mesh: Mesh = effect._trace.mesh
	var start := Time.get_ticks_usec()
	var maximum := 0.0
	for i in range(1, 28):
		var step := Time.get_ticks_usec()
		effect.set_progress(float(i) / 27.0)
		maximum = maxf(maximum, (Time.get_ticks_usec() - step) / 1000.0)
		_check(effect._trace.mesh == mesh, "横扫所有帧复用同一笔迹网格")
	var total := (Time.get_ticks_usec() - start) / 1000.0
	_check(mesh != null and total < 8.0 and maximum < 1.0, "完整狂暴横扫的逐帧推进成本受控")
	print("[地面性能回归] 完整横扫 total_ms=%.3f max_step_ms=%.3f" % [total, maximum])
	effect.free()
	area.free()


func _verify_tracking() -> void:
	var areas: Array[Node3D] = []
	var peak := 0.0
	for x in [-12.0, -11.8, -12.2]:
		var area := _area()
		var build_start := Time.get_ticks_usec()
		area.prepare(Transform3D(Basis.IDENTITY, Vector3(x, 2.2, 9)), {"kind": "rect", "width": 5.0, "length": 11.0, "height": 4.0}, 10.0)
		_check((Time.get_ticks_usec() - build_start) / 1000.0 < 30.0, "薄板坡初次刷面成本受控")
		var original: Transform3D = area._mesh.global_transform
		area._surface_cooldown = 0.0
		var start := Time.get_ticks_usec()
		area.track(Transform3D(Basis(Vector3.UP, 0.08), Vector3(x + 0.5, 2.2, 9)))
		_check((Time.get_ticks_usec() - start) / 1000.0 < 4.0, "追踪调用不执行完整坡道重建")
		_check(area._mesh.global_transform.is_equal_approx(original), "未完成的新网格不会挪动旧网格穿地")
		areas.append(area)
	var completed := false
	for _frame in range(180):
		await process_frame
		var start := Time.get_ticks_usec()
		for area in areas:
			area._physics_process(1.0 / 60.0)
		peak = maxf(peak, (Time.get_ticks_usec() - start) / 1000.0)
		completed = true
		for area in areas:
			completed = completed and area._pending_surface == null and area._mesh.global_transform.is_equal_approx(area.global_transform)
		if completed:
			break
	_check(completed and peak < 8.0, "三个并发坡面追踪会完成，合计单帧低于 8ms，peak=" + str(peak))
	for area in areas:
		area.track(Transform3D(Basis(Vector3.UP, 0.081), area.global_position))
		area.lock()
		_check(area._mesh.global_transform.is_equal_approx(area.global_transform), "最终锁定仍使用准确姿态，不拿旧覆盖结算伤害")
		area.free()
	var immediate := _area()
	var spec := {"kind": "rect", "width": 5.0, "length": 11.0, "height": 4.0}
	immediate.prepare(Transform3D(Basis.IDENTITY, Vector3(-12, 2.2, 9)), spec, 10.0)
	immediate._surface_cooldown = 0.0
	immediate.track(Transform3D(Basis(Vector3.UP, 0.08), Vector3(-11.5, 2.2, 9)))
	immediate.lock()
	_check(immediate._pending_surface == null and immediate._mesh.global_transform.is_equal_approx(immediate.global_transform), "追踪任务尚未完成便锁定时也会完整结算最终姿态")
	immediate.free()
	print("[地面性能回归] 三个并发坡面追踪 peak_frame_ms=%.3f completed=%s" % [peak, completed])


func _check(condition: bool, detail: String) -> void:
	if not condition:
		_failed = true
		push_error("[地面性能回归] " + detail)
