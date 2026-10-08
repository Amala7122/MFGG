extends RefCounted
## 开发产物按项目 / 任务 / 运行编号组织；发行版使用 user://。
static var _run_directory := ""


static func _failed_directory() -> String:
	# 可执行文件本身是文件，不能成为目录。让未检查返回值的旧调用也无法
	# 把空路径拼成相对文件名而意外写到当前工作目录。
	return OS.get_executable_path().path_join("ARTIFACT_OUTPUT_FAILED")


static func run_directory() -> String:
	if not _run_directory.is_empty():
		return _run_directory
	var supplied := ""
	var task := "editor"
	for argument in OS.get_cmdline_user_args():
		if argument.begins_with("--artifact-dir="):
			supplied = argument.trim_prefix("--artifact-dir=")
		elif argument.begins_with("--artifact-task="):
			task = argument.trim_prefix("--artifact-task=").validate_filename()
	var project_root := ProjectSettings.globalize_path("res://").trim_suffix("/").simplify_path()
	if not supplied.is_empty():
		var candidate := supplied.replace("\\", "/").simplify_path().trim_suffix("/")
		if not candidate.is_absolute_path() or candidate.to_lower() == project_root.to_lower() or candidate.to_lower().begins_with(project_root.to_lower() + "/"):
			push_error("产物目录必须是项目之外的绝对路径：%s" % supplied)
			return _failed_directory()
		_run_directory = candidate
	else:
		if task.is_empty():
			task = "editor"
		var stamp := Time.get_datetime_string_from_system().replace(":", "").replace("-", "").replace("T", "_")
		var run_id := "%s_%d_%d" % [stamp, OS.get_process_id(), Time.get_ticks_usec()]
		var base := ProjectSettings.globalize_path("user://artifacts") if OS.has_feature("standalone") else project_root.get_base_dir().path_join("_artifacts").path_join(project_root.get_file())
		_run_directory = base.path_join(task).path_join(run_id)
	var report_directory := _run_directory.path_join("reports")
	var error := DirAccess.make_dir_recursive_absolute(report_directory)
	if error != OK and error != ERR_ALREADY_EXISTS:
		push_error("产物目录创建失败：%s（%d）" % [report_directory, error])
		_run_directory = ""
		return _failed_directory()
	var metadata_path := report_directory.path_join("run.json")
	if not FileAccess.file_exists(metadata_path):
		var metadata := FileAccess.open(metadata_path, FileAccess.WRITE)
		if metadata == null:
			push_error("运行记录写入失败：%s" % metadata_path)
			_run_directory = ""
			return _failed_directory()
		metadata.store_string(JSON.stringify({"source_project": project_root, "task": task,
			"godot": Engine.get_version_info().get("string", "unknown"),
			"created_at": Time.get_datetime_string_from_system(),
			"version_status": "直接引擎运行；版本及工作区状态未采集，自动验收请使用 tools/run_acceptance.py"}, "\t") + "\n")
	print("[产物] 本次运行：", _run_directory)
	return _run_directory


static func ensure_dir(kind: String, relative_path: String = "") -> String:
	if kind not in ["logs", "screenshots", "reports", "tmp"]:
		push_error("未知产物类型：%s" % kind)
		return _failed_directory()
	var run := run_directory()
	if run.is_empty():
		return _failed_directory()
	var directory := run.path_join(kind).path_join(relative_path).simplify_path()
	if directory != run.path_join(kind) and not directory.begins_with(run.path_join(kind) + "/"):
		push_error("产物相对路径越界：%s" % relative_path)
		return _failed_directory()
	var error := DirAccess.make_dir_recursive_absolute(directory)
	if error != OK and error != ERR_ALREADY_EXISTS:
		push_error("产物目录创建失败：%s（%d）" % [directory, error])
		return _failed_directory()
	return directory
