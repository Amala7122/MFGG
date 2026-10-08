extends SceneTree
## 地面效果成本探针：同一场地、同一组范围，对照构建与完整横扫过程。
const SpatialScene := preload("res://prototypes/combat/spatial/combat_spatial_lab.tscn")
const AttackArea := preload("res://scripts/enemy_attack_area.gd")
const MeleeEffect := preload("res://scripts/prototypes/titan_melee_effect.gd")
var _lab: Node3D


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	_lab = SpatialScene.instantiate()
	root.add_child(_lab)
	current_scene = _lab
	for _i in range(12):
		await process_frame
	paused = true
	var cases := [
		{"name": "平地横扫", "at": Vector3(0, 1.7, 10), "spec": {"kind": "sector", "radius": 5.0, "angle": 270.0, "height": 2.5}},
		{"name": "掩体横扫", "at": Vector3(10, 1.7, 8), "spec": {"kind": "sector", "radius": 5.0, "angle": 270.0, "height": 2.5}},
		{"name": "狂暴横扫", "at": Vector3(0, 1.7, 8), "spec": {"kind": "sector", "radius": 10.0, "angle": 270.0, "height": 2.5}},
		{"name": "薄板砸地", "at": Vector3(-12, 2.2, 9), "spec": {"kind": "rect", "width": 5.0, "length": 11.0, "height": 4.0}},
		{"name": "飞扑", "at": Vector3(0, 0.8, 9), "spec": _pounce_spec()},
	]
	for item: Dictionary in cases:
		var area := AttackArea.new()
		area.process_mode = Node.PROCESS_MODE_DISABLED
		_lab.add_child(area)
		var times: Array[float] = []
		for _i in range(4):
			var start := Time.get_ticks_usec()
			area.prepare(Transform3D(Basis.IDENTITY, item.at), item.spec, 10.0)
			times.append((Time.get_ticks_usec() - start) / 1000.0)
		var surface: RefCounted = area.get_surface()
		var rays: int = surface._samples.size()
		print("[地面性能] ", item.name, " build_ms=", times, " samples=", rays, " triangles=", surface._triangles.size(), " plane=", surface._plane_height)
		if item.spec.kind == "sector":
			var spec: Dictionary = item.spec.duplicate()
			spec.surface = surface
			var start := Time.get_ticks_usec()
			var effect: Node3D = MeleeEffect.spawn(_lab, area.global_transform, spec, 1.0, true, 0.45, 0.0)
			var setup_ms := (Time.get_ticks_usec() - start) / 1000.0
			var steps: Array[float] = []
			for i in range(1, 28):
				start = Time.get_ticks_usec()
				effect.set_progress(float(i) / 27.0)
				steps.append((Time.get_ticks_usec() - start) / 1000.0)
			var total := 0.0
			for ms in steps:
				total += ms
			print("[地面性能] ", item.name, " sweep_setup_ms=%.2f total_ms=%.2f max_step_ms=%.2f" % [setup_ms, total, steps.max()])
			effect.free()
		area.free()
	current_scene = null
	_lab.free()
	paused = false
	await process_frame
	quit()


func _pounce_spec() -> Dictionary:
	var body := BoxShape3D.new()
	body.size = Vector3(0.9, 1.55, 1.6)
	return {"kind": "capsule", "radius": 1.6, "length": 7.35, "height": 1.6,
		"travel_speed": 11.44, "jump_speed": 4.5, "gravity": 14.0, "flight_time": 0.64,
		"hit_angle": 90.0, "body_shape": body}
