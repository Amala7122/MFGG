extends Node
## 可重复的性能记录器。
##
## 正常游玩时完全休眠；只有命令行带以下参数才工作：
##   --perf-log                    记录当前游玩，直到进程退出
##   --perf-benchmark=single       自动建立单人 + 14 敌人压力场景并退出
##
## 每次运行写独立 CSV，不再覆盖上一局。记录器是 autoload，因此换图不会像旧的
## PlayerHUD 临时探针那样丢失所有权；HUD 只负责屏幕上的 FPS 数字。

const ConfigUtil := preload("res://scripts/game_config.gd")
const TerrainFieldUtil := preload("res://scripts/terrain_field.gd")
const MELEE_SCENE: PackedScene = preload("res://scenes/melee_enemy.tscn")
const RANGED_SCENE: PackedScene = preload("res://scenes/ranged_enemy.tscn")

const SAMPLE_INTERVAL := 0.5
const FLUSH_INTERVAL := 5.0
const BENCHMARK_WARMUP := 5.0
const BENCHMARK_DURATION := 12.0
const BENCHMARK_ENEMIES := 14
const OUTPUT_DIR := "user://performance"

var _enabled := false
var _benchmark_mode := ""
var _benchmark_active := false
var _recording := false
var _log: FileAccess
var _log_path := ""
var _sample_time := 0.0
var _flush_time := 0.0
var _elapsed := 0.0
var _frame_times: Array[float] = []
var _draw_sum := 0.0
var _primitive_sum := 0.0
var _process_sum := 0.0
var _physics_sum := 0.0
var _peak_draw := 0
var _peak_nodes := 0
var _peak_enemies := 0


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	_benchmark_mode = _argument_value("--perf-benchmark=")
	_enabled = _has_argument("--perf-log") or _benchmark_mode == "single"
	if not _enabled:
		set_process(false)
		return
	_open_log()
	if _benchmark_mode.is_empty():
		_recording = true
	else:
		call_deferred("_start_benchmark")


func _process(delta: float) -> void:
	if _benchmark_active:
		_keep_players_alive()
	if not _recording:
		return
	var safe_delta := maxf(delta, 0.000001)
	_frame_times.append(safe_delta)
	_elapsed += safe_delta
	_sample_time += safe_delta
	_flush_time += safe_delta

	var draw := int(Performance.get_monitor(Performance.RENDER_TOTAL_DRAW_CALLS_IN_FRAME))
	var primitives := int(Performance.get_monitor(Performance.RENDER_TOTAL_PRIMITIVES_IN_FRAME))
	var nodes := int(Performance.get_monitor(Performance.OBJECT_NODE_COUNT))
	var enemies := get_tree().get_nodes_in_group("dynamic_enemies").size()
	var process_ms := Performance.get_monitor(Performance.TIME_PROCESS) * 1000.0
	var physics_ms := Performance.get_monitor(Performance.TIME_PHYSICS_PROCESS) * 1000.0
	_draw_sum += draw
	_primitive_sum += primitives
	_process_sum += process_ms
	_physics_sum += physics_ms
	_peak_draw = maxi(_peak_draw, draw)
	_peak_nodes = maxi(_peak_nodes, nodes)
	_peak_enemies = maxi(_peak_enemies, enemies)

	if _sample_time >= SAMPLE_INTERVAL:
		_sample_time = 0.0
		_write_sample(safe_delta, draw, primitives, nodes, enemies, process_ms, physics_ms)
	if _flush_time >= FLUSH_INTERVAL and _log != null:
		_flush_time = 0.0
		_log.flush()
	if not _benchmark_mode.is_empty() and _elapsed >= BENCHMARK_DURATION:
		_finish_benchmark()


func _open_log() -> void:
	var stamp := str(int(Time.get_unix_time_from_system()))
	var mode := _benchmark_mode if not _benchmark_mode.is_empty() else "play"
	var requested_dir := _argument_value("--perf-output=")
	var output_dirs: Array[String] = []
	if not requested_dir.is_empty():
		output_dirs.append(requested_dir.trim_suffix("/"))
	else:
		# user:// 是发行版的正常位置；工程内目录是编辑器 / 自动化环境的后备。
		output_dirs.append(OUTPUT_DIR)
		output_dirs.append("res://performance_logs")
	for output_dir in output_dirs:
		DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(output_dir))
		_log_path = "%s/perf_%s_%s.csv" % [output_dir, mode, stamp]
		_log = FileAccess.open(_log_path, FileAccess.WRITE)
		if _log != null:
			break
	if _log == null:
		push_error("PerformanceRecorder: 无法创建性能日志；仍会在控制台输出测试汇总")
		# 自动基准不能因为日志失败而永不结束。普通 --perf-log 没有落盘价值，才休眠。
		if _benchmark_mode.is_empty():
			_enabled = false
			set_process(false)
		return
	_log.store_line("# godot=%s mode=%s tier=%s" % [
		Engine.get_version_info().get("string", "unknown"), mode,
		ConfigUtil.get_string("graphics.active", "high")
	])
	_log.store_csv_line(PackedStringArray([
		"elapsed_s", "fps", "frame_ms", "draw_calls", "primitives", "nodes",
		"enemies", "process_ms", "physics_ms", "viewport_w", "viewport_h"
	]))
	print("[PERF] 独立日志：", ProjectSettings.globalize_path(_log_path))


func _write_sample(
	delta: float, draw: int, primitives: int, nodes: int, enemies: int,
	process_ms: float, physics_ms: float
) -> void:
	if _log == null:
		return
	var viewport_size := get_viewport().get_visible_rect().size
	_log.store_csv_line(PackedStringArray([
		"%.3f" % _elapsed,
		"%.1f" % (1.0 / delta),
		"%.3f" % (delta * 1000.0),
		str(draw), str(primitives), str(nodes), str(enemies),
		"%.3f" % process_ms, "%.3f" % physics_ms,
		str(roundi(viewport_size.x)), str(roundi(viewport_size.y)),
	]))


func _start_benchmark() -> void:
	# GameFlow 自己会等一帧后进入菜单；必须等它完成再设场景。
	await get_tree().process_frame
	await get_tree().process_frame
	var flow := get_node_or_null("/root/GameFlow")
	if flow == null:
		_fail_benchmark("找不到 GameFlow")
		return
	flow.call("start_run")

	if not await _wait_for_players(1):
		_fail_benchmark("玩家未在时限内生成")
		return
	_prepare_pressure_scene()
	_benchmark_active = true
	print("[PERF] 压力场景就绪：%s，敌人=%d，预热 %.1f 秒" % [
		_benchmark_mode, get_tree().get_nodes_in_group("dynamic_enemies").size(),
		BENCHMARK_WARMUP
	])
	await get_tree().create_timer(BENCHMARK_WARMUP, true, false, true).timeout
	_reset_metrics()
	_recording = true
	print("[PERF] 正式采样 %.1f 秒" % BENCHMARK_DURATION)


func _wait_for_players(expected: int) -> bool:
	for _frame in range(360):
		await get_tree().process_frame
		if get_tree().get_nodes_in_group("player").size() >= expected:
			return true
	return false


func _prepare_pressure_scene() -> void:
	var scene := get_tree().current_scene
	if scene == null:
		return
	var wave := scene.find_child("WaveDirector", true, false)
	if wave != null:
		wave.set_process(false)
	for enemy in get_tree().get_nodes_in_group("dynamic_enemies"):
		if is_instance_valid(enemy):
			enemy.queue_free()

	var holder := scene.get_node_or_null("Enemies")
	if holder == null:
		holder = scene
	for index in BENCHMARK_ENEMIES:
		var angle := TAU * float(index) / float(BENCHMARK_ENEMIES)
		var radius := 18.0 + float(index % 3) * 3.5
		var x := cos(angle) * radius
		var z := sin(angle) * radius
		var packed := RANGED_SCENE if index % 2 == 0 else MELEE_SCENE
		var enemy := packed.instantiate() as Node3D
		enemy.position = Vector3(x, TerrainFieldUtil.height_at(x, z) + 1.2, z)
		enemy.add_to_group("dynamic_enemies")
		holder.add_child(enemy)
	_keep_players_alive()


func _keep_players_alive() -> void:
	for player in get_tree().get_nodes_in_group("player"):
		if not is_instance_valid(player):
			continue
		player.set("max_health", 1000000.0)
		player.set("health", 1000000.0)
		player.set("max_shield", 1000000.0)
		player.set("shield", 1000000.0)


func _reset_metrics() -> void:
	_frame_times.clear()
	_elapsed = 0.0
	_sample_time = 0.0
	_flush_time = 0.0
	_draw_sum = 0.0
	_primitive_sum = 0.0
	_process_sum = 0.0
	_physics_sum = 0.0
	_peak_draw = 0
	_peak_nodes = 0
	_peak_enemies = 0


func _finish_benchmark() -> void:
	_recording = false
	var frames := _frame_times.size()
	var total := 0.0
	for frame_time in _frame_times:
		total += frame_time
	var sorted := _frame_times.duplicate()
	sorted.sort()
	var p99_index := clampi(ceili(float(frames) * 0.99) - 1, 0, maxi(frames - 1, 0))
	var p95_index := clampi(ceili(float(frames) * 0.95) - 1, 0, maxi(frames - 1, 0))
	var average_fps := float(frames) / maxf(total, 0.000001)
	var low_1: float = 1.0 / float(sorted[p99_index]) if frames > 0 else 0.0
	var low_5: float = 1.0 / float(sorted[p95_index]) if frames > 0 else 0.0
	var divisor := maxf(float(frames), 1.0)
	var summary := {
		"mode": _benchmark_mode,
		"tier": ConfigUtil.get_string("graphics.active", "high"),
		"frames": frames,
		"seconds": total,
		"average_fps": average_fps,
		"one_percent_low_fps": low_1,
		"five_percent_low_fps": low_5,
		"average_draw_calls": _draw_sum / divisor,
		"peak_draw_calls": _peak_draw,
		"average_primitives": _primitive_sum / divisor,
		"average_process_ms": _process_sum / divisor,
		"average_physics_ms": _physics_sum / divisor,
		"peak_nodes": _peak_nodes,
		"peak_enemies": _peak_enemies,
	}
	var line := JSON.stringify(summary)
	print("[PERF-SUMMARY] ", line)
	if _log != null:
		_log.store_line("# SUMMARY " + line)
		_log.flush()
		_log.close()
	_log = null
	get_tree().quit()


func _fail_benchmark(reason: String) -> void:
	push_error("PerformanceRecorder: %s" % reason)
	if _log != null:
		_log.store_line("# ERROR " + reason)
		_log.close()
	get_tree().quit(1)


func _has_argument(wanted: String) -> bool:
	for arg in OS.get_cmdline_user_args():
		if arg == wanted:
			return true
	return false


func _argument_value(prefix: String) -> String:
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with(prefix):
			return arg.trim_prefix(prefix)
	return ""


func _notification(what: int) -> void:
	if what == NOTIFICATION_PREDELETE and _log != null:
		_log.flush()
		_log.close()
		_log = null
