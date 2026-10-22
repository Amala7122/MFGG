extends SceneTree
## Runtime CPU auditing must be opt-in and observational; it cannot be allowed
## to change an enemy's normal frame, attack state, or physics-process timing.
const Audit := preload("res://scripts/enemy_cpu_audit.gd")


func _initialize() -> void:
	call_deferred("_check")


func _check() -> void:
	var old_enabled: bool = Audit.enabled
	var old_stride: int = Audit.sample_stride
	Audit.drain()
	Audit.drain_events()
	Audit.enabled = false
	if Audit.begin(&"disabled") != null:
		_fail("disabled scope must not allocate")
		return
	Audit.enabled = true
	Audit.sample_stride = 1
	var scope: RefCounted = Audit.begin(&"test.motion")
	if scope == null:
		_fail("enabled scope should be allocated")
		return
	scope = null # Release immediately: _notification records this inclusive scope.
	var measured: Dictionary = Audit.drain()
	if not measured.has(&"test.motion") or int(measured[&"test.motion"].calls) != 1:
		_fail("scope did not close and record one call")
		return
	if not Audit.drain().is_empty():
		_fail("drain did not reset the window")
		return
	var enemy := Node.new()
	enemy.name = "TestEnemy"
	enemy.set_meta(&"crowd_family", "PrototypeMudGolem")
	Audit.mark_attack(enemy)
	Audit.mark_attack(enemy)
	var events: Dictionary = Audit.drain_events()
	if int(events.get("PrototypeMudGolem", 0)) != 2:
		_fail("real attack start counters must not be downsampled")
		return
	if not Audit.drain_events().is_empty():
		_fail("attack window did not reset")
		return
	enemy.free()
	Audit.enabled = old_enabled
	Audit.sample_stride = old_stride
	print("PASS: opt-in CPU audit scope, draining and unsampled attack events")
	quit(0)


func _fail(message: String) -> void:
	push_error("EnemyCpuAudit: " + message)
	quit(1)
