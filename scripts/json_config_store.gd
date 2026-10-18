extends RefCounted
## 小型参数文件显式写回：先验证备份 / 临时文件，再原子替换；产物不进入项目。
const Artifacts := preload("res://scripts/artifact_paths.gd")

static func save_json(path: String, values: Dictionary, category: String) -> Error:
	if OS.has_feature("standalone"):
		return ERR_UNAVAILABLE
	if not path.begins_with("res://data/") or not path.ends_with(".json") or path.contains(".."):
		return ERR_INVALID_PARAMETER
	var original := FileAccess.open(path, FileAccess.READ)
	if original == null:
		return FileAccess.get_open_error()
	var previous := original.get_as_text()
	original.close()
	var stamp := category.validate_filename() + "_" + str(Time.get_ticks_usec())
	var backup := Artifacts.ensure_dir("reports").path_join(stamp + "_previous.json")
	var error := _write(backup, previous)
	if error != OK:
		return error
	var encoded := JSON.stringify(values, "  ", true, true) + "\n"
	var temporary := Artifacts.ensure_dir("tmp").path_join(stamp + ".json")
	error = _write(temporary, encoded)
	if error != OK:
		return error
	var receipt := {"target": ProjectSettings.globalize_path(path), "backup": backup,
		"previous_sha256": previous.sha256_text(), "next_sha256": encoded.sha256_text(),
		"rollback": "Verify no later edits overlap; restore only the exact target from this backup.",
		"status": "prepared; success requires target hash to equal next_sha256"}
	error = _write(Artifacts.ensure_dir("reports").path_join(stamp + "_receipt.json"), JSON.stringify(receipt, "  "))
	if error != OK:
		return error
	error = DirAccess.rename_absolute(temporary, ProjectSettings.globalize_path(path))
	if error != OK:
		return error
	return OK if FileAccess.get_sha256(path) == encoded.sha256_text() else ERR_FILE_CORRUPT

static func _write(path: String, content: String) -> Error:
	var file := FileAccess.open(path, FileAccess.WRITE)
	if file == null:
		return FileAccess.get_open_error()
	file.store_string(content)
	file.flush()
	var error := file.get_error()
	file.close()
	if error != OK:
		return error
	return OK if FileAccess.get_sha256(path) == content.sha256_text() else ERR_FILE_CORRUPT
