extends "res://tools/probes/burst_crawler_perf.gd"
## 同一进程ABBA抵消跨进程环境差异；导航计时与帧耗分开，毒池单独对照。
const MeasuredNav := preload("res://tools/probes/measured_nav_steering.gd")
const Surface := preload("res://scripts/attack_surface_mesh.gd")
const Cache := preload("res://scripts/nav_projection_cache.gd")
var _native := false

func _configure_enemy(enemy: Node, index: int) -> void:
	super._configure_enemy(enemy, index)
	# 此时尚未入树，导航尚未setup，没有运行状态或子节点需要迁移。
	var steering: RefCounted = enemy.get("_steering")
	steering.set_script(MeasuredNav)
	steering.set("native_query", _native)

func _run() -> void:
	if not await _start_formal_scene():
		quit(1)
		return
	for species in ["burst_crawler", "mud_golem", "fast_beast"]:
		for native in [true, false, false, true]:
			_native = native
			MeasuredNav.elapsed_usec = 0
			MeasuredNav.calls = 0
			Cache.reset_counters()
			await _phase(species + ("_native" if native else "_exact"), true, true, species, _count)
			var row: Dictionary = _rows.back()
			row["native_navigation"] = native
			row["navigation_usec"] = MeasuredNav.elapsed_usec
			row["navigation_calls"] = MeasuredNav.calls
			row["exact_hits"] = Cache.exact_hits
			row["exact_misses"] = Cache.exact_misses
			print("[主场景A/B] ", row)
	await _clear_enemies()
	var poison := _poison_builds()
	var path := Artifacts.ensure_dir("reports").path_join("main_scene_ab.json")
	var file := FileAccess.open(path, FileAccess.WRITE)
	if file == null:
		push_error("无法写入主场景A/B：" + path)
		quit(1)
		return
	file.store_string(JSON.stringify({"count": _count, "warmup": _warmup, "frames": _frames,
		"window": DisplayServer.window_get_size(), "render_scale": root.scaling_3d_scale,
		"phases": _rows, "poison_builds": poison,
		"note": "导航计时包含预热；帧耗只含测量帧。原生/精确缓存两支都保留毒池填充优化。"}, "  "))
	file.close()
	quit(0)

func _poison_builds() -> Array:
	var results: Array = []
	var outline := PackedVector2Array()
	for i in range(32):
		outline.append(Vector2.from_angle(TAU * float(i) / 32.0) * 4.0)
	var context := Node3D.new()
	_scene.add_child(context)
	context.global_position = Vector3(-12, Terrain.height_at(-12, 9), 9)
	for border in [true, false, false, true]:
		var times: Array = []
		for _i in range(8):
			var surface := Surface.new()
			var start := Time.get_ticks_usec()
			surface.build(context, outline, {"kind": "circle", "radius": 4.0,
				"height": 2.5, "source_height": 0.2, "build_border": border})
			times.append((Time.get_ticks_usec() - start) / 1000.0)
		results.append({"border": border, "ms": times})
	context.free()
	print("[毒池A/B] ", results)
	return results
