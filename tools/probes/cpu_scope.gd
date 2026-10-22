extends RefCounted
## 仅供隔离副本插桩；局部作用域释放时记录包含子调用的墙钟耗时。
static var enabled := false
static var rows: Dictionary = {}
var _label: String
var _started := 0

func _init(label: String) -> void:
	_label = label
	if enabled:
		_started = Time.get_ticks_usec()

func _notification(what: int) -> void:
	if what != NOTIFICATION_PREDELETE or _started == 0 or not enabled:
		return
	var elapsed := Time.get_ticks_usec() - _started
	var row: Dictionary = rows.get(_label, {"calls": 0, "total_usec": 0, "max_usec": 0})
	row.calls += 1
	row.total_usec += elapsed
	row.max_usec = maxi(row.max_usec, elapsed)
	rows[_label] = row
