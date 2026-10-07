extends SceneTree
## 六个持续转向的地面预警、三个横扫效果，测量实际渲染帧间隔与效果 CPU 成本。
const SpatialScene := preload("res://prototypes/combat/spatial/combat_spatial_lab.tscn")
const AttackArea := preload("res://scripts/enemy_attack_area.gd")
const MeleeEffect := preload("res://scripts/prototypes/titan_melee_effect.gd")
var _lab: Node3D
var _areas: Array[Node3D] = []
var _effects: Array[Node3D] = []


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	var area_script: Script = AttackArea
	var effect_script: Script = MeleeEffect
	var baseline := OS.get_cmdline_user_args().has("--baseline-snapshot")
	if baseline:
		area_script = load("D:/godot_project/visual_captures/enemy_attack_area_baseline.gd")
		effect_script = load("D:/godot_project/visual_captures/titan_melee_effect_before.gd")
	_lab = SpatialScene.instantiate()
	root.add_child(_lab)
	current_scene = _lab
	for _frame in range(24):
		await process_frame
	paused = true
	var body := BoxShape3D.new()
	body.size = Vector3(0.9, 1.55, 1.6)
	var specs := [
		{"kind": "sector", "radius": 5.0, "angle": 270.0, "height": 2.5},
		{"kind": "capsule", "radius": 1.6, "length": 7.35, "height": 1.6, "travel_speed": 11.44,
			"jump_speed": 4.5, "gravity": 14.0, "flight_time": 0.64, "hit_angle": 90.0, "body_shape": body},
	]
	var setup := Time.get_ticks_usec()
	for i in range(6):
		var area: Node3D = area_script.new()
		area.process_mode = Node.PROCESS_MODE_DISABLED
		_lab.add_child(area)
		var spec: Dictionary = specs[i / 3]
		area.prepare(Transform3D(Basis.IDENTITY, Vector3(0, 1.7 if i < 3 else 0.8, 10)), spec, 10.0)
		_areas.append(area)
		if i < 3:
			var visual := spec.duplicate()
			visual.surface = area.get_surface()
			var effect: Node3D = effect_script.spawn(_lab, area.global_transform, visual, 1.0, true, 0.45, 0.0)
			effect.process_mode = Node.PROCESS_MODE_DISABLED
			_effects.append(effect)
	print("[地面帧基准] baseline=%s initial_six_ms=%.2f" % [baseline, (Time.get_ticks_usec() - setup) / 1000.0])
	var frame_times: Array[float] = []
	var work_times: Array[float] = []
	var previous := Time.get_ticks_usec()
	for frame in range(90):
		await process_frame
		var now := Time.get_ticks_usec()
		var delta := (now - previous) / 1000000.0
		previous = now
		var start := Time.get_ticks_usec()
		for i in range(6):
			_areas[i].track(Transform3D(Basis(Vector3.UP, 0.25 * sin(frame * 0.05 + i * 0.2)), Vector3(0, 1.7 if i < 3 else 0.8, 10)))
			_areas[i]._physics_process(delta)
		for effect in _effects:
			effect.set_progress(float(frame % 27) / 26.0)
		if frame >= 10:
			frame_times.append(delta * 1000.0)
			work_times.append((Time.get_ticks_usec() - start) / 1000.0)
	var sum := 0.0
	var work := 0.0
	for value in frame_times:
		sum += value
	for value in work_times:
		work += value
	frame_times.sort()
	work_times.sort()
	print("[地面帧基准] baseline=%s fps=%.1f frame_p95_ms=%.2f effect_cpu_avg_ms=%.2f effect_cpu_p95_ms=%.2f" % [baseline, 1000.0 * frame_times.size() / sum,
		frame_times[floori(frame_times.size() * 0.95)], work / work_times.size(), work_times[floori(work_times.size() * 0.95)]])
	current_scene = null
	_lab.free()
	paused = false
	await process_frame
	quit()
