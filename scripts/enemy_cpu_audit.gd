class_name EnemyCpuAudit
extends RefCounted
## 仅当 --perf-enemy-cpu 启动时计时。默认零对象分配、零钟表调用。
## 每8个真实物理步抽样一次：这是包含子调用的耗时，不能跨层相加。
## 通过 PerformanceRecorder 每约 0.5 秒写出统计，再清空累计窗口。

static var enabled := OS.get_cmdline_user_args().has("--perf-enemy-cpu")
static var sample_stride := 8
static var rows: Dictionary = {}

var _label: StringName
var _started_usec := 0


func _init(label: StringName) -> void:
	_label = label
	_started_usec = Time.get_ticks_usec()


static func begin(label: StringName) -> EnemyCpuAudit:
	if not enabled or Engine.get_physics_frames() % sample_stride != 0:
		return null
	return EnemyCpuAudit.new(label)


static func drain() -> Dictionary:
	var snapshot := rows
	rows = {}
	return snapshot


func _notification(what: int) -> void:
	if what != NOTIFICATION_PREDELETE or _started_usec <= 0:
		return
	var elapsed := Time.get_ticks_usec() - _started_usec
	var row: Dictionary = rows.get(_label, {"calls": 0, "total_usec": 0, "max_usec": 0})
	row.calls += 1
	row.total_usec += elapsed
	row.max_usec = maxi(int(row.max_usec), elapsed)
	rows[_label] = row
