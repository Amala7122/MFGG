extends RefCounted
## 开发截图放在项目同级目录，避免被 Godot 扫描并打进导出包。


static func root() -> String:
	if OS.has_feature("standalone"):
		return ProjectSettings.globalize_path("user://visual_captures")
	return ProjectSettings.globalize_path("res://").path_join("../visual_captures").simplify_path()


static func file(relative_path: String) -> String:
	return root().path_join(relative_path)


static func ensure_dir(relative_path: String = "") -> String:
	var directory := root() if relative_path.is_empty() else file(relative_path)
	var error := DirAccess.make_dir_recursive_absolute(directory)
	if error != OK and error != ERR_ALREADY_EXISTS:
		push_error("截图目录创建失败：%s（%d）" % [directory, error])
	return directory
