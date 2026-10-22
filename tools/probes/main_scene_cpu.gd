extends "res://tools/probes/burst_crawler_perf.gd"
## 配合 profile_main_cpu.py：仅在隔离副本插桩，耗时含子调用，不应跨层相加。
const Scope := preload("res://tools/probes/cpu_scope.gd")

func _run() -> void:
	if not await _start_formal_scene():
		quit(1)
		return
	_player.set_meta(&"experiment_invincible", true)
	var origin: Vector3 = _player.global_position
	var profiles: Array = []
	for species in ["burst_crawler", "mud_golem", "fast_beast"]:
		_player.global_position = origin
		Scope.rows.clear()
		Scope.enabled = true
		await _phase(species, true, true, species, _count)
		Scope.enabled = false
		profiles.append({"species": species, "timings": Scope.rows.duplicate(true)})
		print("[CPU] ", species, " ", _rows.back())
		var names := Scope.rows.keys()
		names.sort_custom(func(a, b): return Scope.rows[a].total_usec > Scope.rows[b].total_usec)
		for label in names.slice(0, 18):
			print("[CPU] ", label, " ", Scope.rows[label])
	var path := Artifacts.ensure_dir("reports").path_join("main_scene_cpu.json")
	var file := FileAccess.open(path, FileAccess.WRITE)
	if file == null:
		push_error("无法写入 CPU 诊断：" + path)
		quit(1)
		return
	file.store_string(JSON.stringify({"phases": _rows, "profiles": profiles}, "  "))
	file.close()
	quit(0)
