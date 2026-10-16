extends SceneTree

const PortResolver := preload("res://addons/godot_ai/utils/port_resolver.gd")

var _failed := false


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	if OS.get_name() != "Windows":
		print("SKIP: Windows listener lookup requires Windows")
		quit(0)
		return
	var server := TCPServer.new()
	if server.listen(0, "127.0.0.1") != OK:
		push_error("Could not open the test listener")
		quit(1)
		return
	var port := server.get_local_port()
	_verify_listener(port, "normal environment")
	var original_path := OS.get_environment("PATH")
	OS.set_environment("PATH", "")
	_verify_listener(port, "empty PATH")
	server.stop()
	var snapshot := PortResolver.windows_listener_snapshot()
	_check(PortResolver.windows_port_occupancy(port, snapshot) == PortResolver.PortOccupancy.FREE,
		"Stopped listener must be reported free with empty PATH")
	OS.set_environment("PATH", original_path)
	if not _failed:
		print("PASS: Windows port lookup finds the listener PID and released port without PATH")
	quit(1 if _failed else 0)


func _verify_listener(port: int, label: String) -> void:
	var calls: Array[String] = []
	var snapshot := PortResolver.windows_listener_snapshot(func(counter: String) -> void:
		calls.append(counter)
	)
	_check(bool(snapshot.known), "%s: listener snapshot must be available" % label)
	_check(calls == ["netstat"], "%s: installed netstat must work without PowerShell fallback: %s" % [label, calls])
	_check(PortResolver.windows_port_occupancy(port, snapshot) == PortResolver.PortOccupancy.OCCUPIED,
		"%s: open listener must be reported occupied" % label)
	_check(PortResolver.find_all_pids_on_port(port, Callable(), snapshot).has(OS.get_process_id()),
		"%s: listener PID must match this Godot process" % label)


func _check(condition: bool, message: String) -> void:
	if not condition:
		_failed = true
		push_error(message)
