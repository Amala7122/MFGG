extends SceneTree
## 通过引擎枚举自有场景和资源的传递依赖，避免实例化实验场。

var _failed := false
var _loaded := 0
var _visited: Dictionary = {}


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	for _frame in range(3):
		await process_frame
	for directory in ["res://scenes", "res://prototypes", "res://data", "res://theme"]:
		_scan(directory)
	_check(_loaded > 0, "找到自有资源")
	var legacy_dependencies := ResourceLoader.get_dependencies("res://prototypes/combat_lab.tscn")
	var valid_lab := false
	for dependency in legacy_dependencies:
		if _dependency_path(dependency) == "res://prototypes/combat/combat_lab.tscn":
			valid_lab = true
	_check(valid_lab,
		"旧 Combat Lab 入口依赖有效实验场景")
	for _frame in range(3):
		await process_frame
	print("[场景依赖检查] roots=", _loaded, " dependencies=", _visited.size(), " ", "FAIL" if _failed else "PASS")
	quit(1 if _failed else 0)


func _scan(path: String) -> void:
	var directory := DirAccess.open(path)
	if directory == null:
		_check(false, "无法读取目录 " + path)
		return
	for folder in directory.get_directories():
		_scan(path.path_join(folder))
	for filename in directory.get_files():
		if filename.get_extension() in ["tscn", "tres"]:
			_check_dependency(path.path_join(filename))
			_loaded += 1


func _dependency_path(dependency: String) -> String:
	return dependency.get_slice("::", 2) if dependency.contains("::") else dependency


func _check_dependency(path: String) -> void:
	if _visited.has(path):
		return
	_visited[path] = true
	if not ResourceLoader.exists(path):
		_check(false, "资源依赖不存在 " + path)
		return
	for dependency in ResourceLoader.get_dependencies(path):
		_check_dependency(_dependency_path(dependency))


func _check(condition: bool, description: String) -> void:
	if not condition:
		_failed = true
		push_error("[场景依赖检查] " + description)
