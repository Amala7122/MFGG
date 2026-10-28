extends SceneTree
## 诊断：FodderField 随数量的分项耗时与物理查询次数。
##
## 只读诊断：不改地图、烘焙、正式参数、正式刷怪。通过子类覆盖统计
## `_move_unit`（扫掠）、`_support_at`（支撑射线）、`_resolve_overlap`
## （接触解算）、`_update_slot`（槽位/视线）、`_line_clear_to_target`（视线射线）
## 的调用次数与耗时；每个数量档都从同一出生环重新铺开，互不继承位置。
##
## 用法：
##   godot --headless --script res://tools/probes/fodder_scale_perf.gd -- \
##     --counts=0,100,300,500 --steps=180 --warmup=20 \
##     --variants=baseline,no_resolve,no_sweep,no_support_ray --variant-count=500
##
## `no_resolve` / `no_sweep` / `no_support_ray` 只用于归因，会改变行为，
## 不能当作已优化版本或验收成绩。

const Artifacts := preload("res://scripts/artifact_paths.gd")
const MainScene := preload("res://scenes/sanctum_main.tscn")
const FodderScript := preload("res://scripts/prototypes/fodder_field.gd")
const NavDataset := preload("res://scripts/navigation/nav_dataset.gd")
const Terrain := preload("res://scripts/terrain_field.gd")
const NAV_PATH := "res://data/navigation/sanctum_nav.json"


## 统计版炮灰场。depth 用于只在外层调用累计，避免嵌套重复计时：
## `_resolve_overlap` 内部会再调 `_move_unit`，两者不重复计入。
class TimedField extends FodderScript:
	var variant := "baseline"
	var depth := 0
	var steps := 0

	var n_move := 0
	var n_support := 0
	var n_resolve := 0
	var n_slot := 0
	var n_los := 0

	var t_phys := 0
	var t_proc := 0
	var t_move := 0
	var t_resolve := 0
	var t_slot := 0
	var t_support := 0
	var t_los := 0
	var t_cheap := 0
	var t_far := 0
	var t_tiers := 0
	var t_hash := 0
	var n_cheap := 0
	var n_far := 0

	func _physics_process(delta: float) -> void:
		var started := Time.get_ticks_usec()
		steps += 1
		super(delta)
		t_phys += Time.get_ticks_usec() - started

	func _process(delta: float) -> void:
		var started := Time.get_ticks_usec()
		super(delta)
		t_proc += Time.get_ticks_usec() - started

	func _move_unit(index: int, pos: Vector3, motion: Vector3, to_target: Vector3,
			allow_step: bool) -> Vector3:
		n_move += 1
		var outer := depth == 0
		depth += 1
		var started := Time.get_ticks_usec()
		var result: Vector3
		if variant == "no_sweep":
			# 保留 1m 通行表阻挡，只去掉胶囊扫掠，用于估算扫掠的边际成本。
			if _surface_ready and not profile.ignore_terrain:
				var next_flat := pos + Vector3(motion.x, 0.0, motion.z)
				if not _surface.blocked_at(pos.x, pos.z) \
						and _surface.blocked_at(next_flat.x, next_flat.z):
					_move_blocked = true
					depth -= 1
					if outer:
						t_move += Time.get_ticks_usec() - started
					return pos
			result = _settle_support(index, pos + motion)
		else:
			result = super(index, pos, motion, to_target, allow_step)
		var elapsed := Time.get_ticks_usec() - started
		depth -= 1
		if outer:
			t_move += elapsed
		return result

	func _support_at(x: float, z: float, feet: float) -> float:
		n_support += 1
		var started := Time.get_ticks_usec()
		var result: float
		if variant == "no_support_ray":
			result = NAN
		else:
			result = super(x, z, feet)
		t_support += Time.get_ticks_usec() - started
		return result

	func _resolve_overlap(index: int, pos: Vector3, to_target: Vector3) -> Vector3:
		n_resolve += 1
		if variant == "no_resolve":
			return pos
		var outer := depth == 0
		depth += 1
		var started := Time.get_ticks_usec()
		var result := super(index, pos, to_target)
		var elapsed := Time.get_ticks_usec() - started
		depth -= 1
		if outer:
			t_resolve += elapsed
		return result

	func _update_slot(index: int, pos: Vector3, target: Vector3, delta: float) -> void:
		n_slot += 1
		var started := Time.get_ticks_usec()
		super(index, pos, target, delta)
		t_slot += Time.get_ticks_usec() - started

	func _step_cheap(index: int, delta: float, target: Vector3) -> void:
		n_cheap += 1
		var started := Time.get_ticks_usec()
		super(index, delta, target)
		t_cheap += Time.get_ticks_usec() - started

	func _step_far(index: int, delta: float, target: Vector3) -> void:
		n_far += 1
		var started := Time.get_ticks_usec()
		super(index, delta, target)
		t_far += Time.get_ticks_usec() - started

	func _update_tiers(delta: float, center: Vector3) -> void:
		var started := Time.get_ticks_usec()
		super(delta, center)
		t_tiers += Time.get_ticks_usec() - started

	func _rebuild_hash() -> void:
		var started := Time.get_ticks_usec()
		super()
		t_hash += Time.get_ticks_usec() - started

	func _line_clear_to_target(pos: Vector3, target: Vector3) -> bool:
		n_los += 1
		var started := Time.get_ticks_usec()
		var result := super(pos, target)
		t_los += Time.get_ticks_usec() - started
		return result

	func reset_counters() -> void:
		steps = 0
		n_move = 0
		n_support = 0
		n_resolve = 0
		n_slot = 0
		n_los = 0
		t_phys = 0
		t_proc = 0
		t_move = 0
		t_resolve = 0
		t_slot = 0
		t_support = 0
		t_los = 0
		t_cheap = 0
		t_far = 0
		t_tiers = 0
		t_hash = 0
		n_cheap = 0
		n_far = 0


var _counts: Array[int] = [100, 300, 500]
var _steps := 180
var _warmup := 20
var _variants: Array[String] = ["baseline"]
var _variant_count := 500
var _spread := 0
var _rows: Array[Dictionary] = []
var _baseline_usec := 0


func _initialize() -> void:
	for argument in OS.get_cmdline_user_args():
		if argument.begins_with("--counts="):
			_counts.clear()
			for part in argument.trim_prefix("--counts=").split(","):
				_counts.append(int(part))
		elif argument.begins_with("--steps="):
			_steps = maxi(1, int(argument.trim_prefix("--steps=")))
		elif argument.begins_with("--warmup="):
			_warmup = maxi(0, int(argument.trim_prefix("--warmup=")))
		elif argument.begins_with("--variants="):
			_variants.clear()
			for part in argument.trim_prefix("--variants=").split(","):
				if not part.is_empty():
					_variants.append(part)
		elif argument.begins_with("--variant-count="):
			_variant_count = int(argument.trim_prefix("--variant-count="))
		elif argument == "--spread=on":
			_spread = 1
		elif argument == "--spread=slots":
			_spread = 2
		elif argument == "--spread=press":
			_spread = 3
	call_deferred("_run")


func _run() -> void:
	var menu := MainScene.instantiate()
	root.add_child(menu)
	current_scene = menu
	for _index in 3:
		await process_frame
	var game_flow := root.get_node_or_null("GameFlow")
	if game_flow == null:
		push_error("[scale_perf] 缺少 GameFlow")
		_finish()
		return
	game_flow.call("start_run")
	for _index in 360:
		await process_frame
		if current_scene != null and current_scene != menu \
				and not get_nodes_in_group("player").is_empty() \
				and not bool(game_flow.get("_preparing_run")):
			break
	var scene := current_scene as Node3D
	if scene == null or get_nodes_in_group("player").is_empty():
		push_error("[scale_perf] 正式场景与玩家未就绪")
		_finish()
		return
	var player := get_nodes_in_group("player")[0] as Node3D
	player.set_meta(&"experiment_invincible", true)
	player.process_mode = Node.PROCESS_MODE_DISABLED
	for director_name in ["WaveDirector", "SurvivalDirector"]:
		var director := scene.find_child(director_name, true, false)
		if director != null:
			director.set_process(false)
			director.set_physics_process(false)
	for enemy in get_nodes_in_group("enemies"):
		enemy.queue_free()
	for _index in 2:
		await process_frame

	var nav := NavDataset.load_file(NAV_PATH)
	var profile = NavDataset.load_profile(nav)
	print("[scale_perf] player=(%.1f,%.1f) counts=%s steps=%d variants=%s@%d" % [
		player.global_position.x, player.global_position.z, str(_counts),
		_steps, str(_variants), _variant_count])

	_baseline_usec = await _measure_scene_only()
	print("[scale_perf] baseline scene physics median=%.3fms" % (_baseline_usec / 1000.0))

	for count in _counts:
		var variants: Array[String] = ["baseline"]
		if count == _variant_count:
			variants = _variants.duplicate()
			if not variants.has("baseline"):
				variants.push_front("baseline")
		for variant in variants:
			await _measure_field(scene, player, nav, profile, count, variant)

	_write_report()
	_finish()


func _measure_scene_only() -> int:
	var samples: Array[int] = []
	for _index in 120:
		await physics_frame
		samples.append(int(Performance.get_monitor(Performance.TIME_PHYSICS_PROCESS) * 1000000.0))
	return _median(samples)


func _measure_field(scene: Node3D, player: Node3D, nav: Dictionary, profile,
		count: int, variant: String) -> void:
	var field := TimedField.new()
	field.variant = variant
	field.top_level = true
	scene.add_child(field)
	var setup_started := Time.get_ticks_usec()
	field.setup(player, null, count, player.global_position, profile, nav)
	if _spread > 0:
		field.set_spread_mode(_spread)
	var setup_usec := Time.get_ticks_usec() - setup_started
	var waited := 0
	while not bool(field.get("_flow_ready")) and waited < 900:
		await physics_frame
		waited += 1
	if not bool(field.get("_flow_ready")):
		push_error("[scale_perf] count=%d variant=%s 流场未就绪" % [count, variant])
		field.queue_free()
		await process_frame
		return
	for _index in _warmup:
		await physics_frame
	field.reset_counters()
	var samples: Array[int] = []
	for _index in _steps:
		await physics_frame
		samples.append(int(Performance.get_monitor(Performance.TIME_PHYSICS_PROCESS) * 1000000.0))
	var steps := maxi(field.steps, 1)
	var move_usec := field.t_move / steps
	var resolve_usec := field.t_resolve / steps
	var slot_usec := field.t_slot / steps
	var field_phys := field.t_phys / steps
	var rest_usec := maxi(0, field_phys - move_usec - resolve_usec - slot_usec
		- field.t_cheap / steps - field.t_far / steps
		- field.t_tiers / steps - field.t_hash / steps)
	var row := {
		"count": count,
		"variant": variant,
		"steps": steps,
		"flow_wait_steps": waited,
		"setup_usec": setup_usec,
		"alive": field.alive_count,
		"cheap_units": field.cheap_units,
		"far_units": field.far_units,
		"full_radius": field._full_radius,
		"scene_physics_usec_median": _median(samples),
		"scene_physics_usec_p95": _percentile(samples, 0.95),
		"field_physics_usec_per_step": field_phys,
		"field_process_usec_per_step": field.t_proc / steps,
		"move_usec_per_step": move_usec,
		"resolve_usec_per_step": resolve_usec,
		"slot_usec_per_step": slot_usec,
		"rest_usec_per_step": rest_usec,
		"cheap_usec_per_step": field.t_cheap / steps,
		"far_usec_per_step": field.t_far / steps,
		"tiers_usec_per_step": field.t_tiers / steps,
		"hash_usec_per_step": field.t_hash / steps,
		"cheap_calls_per_step": float(field.n_cheap) / float(steps),
		"far_calls_per_step": float(field.n_far) / float(steps),
		"support_usec_per_step": field.t_support / steps,
		"los_usec_per_step": field.t_los / steps,
		"move_calls_per_step": float(field.n_move) / float(steps),
		"support_calls_per_step": float(field.n_support) / float(steps),
		"resolve_calls_per_step": float(field.n_resolve) / float(steps),
		"slot_calls_per_step": float(field.n_slot) / float(steps),
		"los_calls_per_step": float(field.n_los) / float(steps),
		"query_calls_per_step": float(field.n_move + field.n_support
			+ field.n_resolve * 2 + field.n_los) / float(steps),
		"physics_over_baseline_usec": _median(samples) - _baseline_usec,
	}
	_rows.append(row)
	print("[scale_perf] n=%d %-15s field=%.2fms/step scene=%.2fms p95=%.2fms move=%.2f resolve=%.2f slot=%.2f rest=%.2f support=%.2f los=%.2f calls/step move=%.2f support=%.2f resolve=%.2f los=%.2f tiers full=%d cheap=%d far=%d r=%.1f" % [
		count, variant, field_phys / 1000.0, row.scene_physics_usec_median / 1000.0,
		row.scene_physics_usec_p95 / 1000.0, move_usec / 1000.0, resolve_usec / 1000.0,
		slot_usec / 1000.0, rest_usec / 1000.0, row.support_usec_per_step / 1000.0,
		row.los_usec_per_step / 1000.0, row.move_calls_per_step,
		row.support_calls_per_step, row.resolve_calls_per_step, row.los_calls_per_step,
		field.alive_count - field.cheap_units - field.far_units,
		field.cheap_units, field.far_units, field._full_radius])
	print("[scale_perf]   cheap=%.2fms far=%.2fms tiers=%.2fms hash=%.2fms rest=%.2fms" % [
		field.t_cheap / 1000.0 / float(steps), field.t_far / 1000.0 / float(steps),
		field.t_tiers / 1000.0 / float(steps), field.t_hash / 1000.0 / float(steps),
		rest_usec / 1000.0])
	field.queue_free()
	for _index in 3:
		await process_frame


func _median(values: Array[int]) -> int:
	if values.is_empty():
		return 0
	var copy := values.duplicate()
	copy.sort()
	return copy[copy.size() / 2]


func _percentile(values: Array[int], ratio: float) -> int:
	if values.is_empty():
		return 0
	var copy := values.duplicate()
	copy.sort()
	return copy[mini(copy.size() - 1, int(float(copy.size()) * ratio))]


func _write_report() -> void:
	var report := {
		"baseline_scene_physics_usec": _baseline_usec,
		"counts": _counts,
		"steps": _steps,
		"warmup": _warmup,
		"variants": _variants,
		"variant_count": _variant_count,
		"rows": _rows,
	}
	var directory := Artifacts.ensure_dir("reports")
	var path := directory.path_join("fodder_scale_perf.json")
	var file := FileAccess.open(path, FileAccess.WRITE)
	if file == null:
		push_error("[scale_perf] 报告写入失败：%s" % path)
		return
	file.store_string(JSON.stringify(report, "\t") + "\n")
	file.close()
	print("[scale_perf] report=%s" % path)


func _finish() -> void:
	print("[scale_perf] DONE")
	quit(0)
