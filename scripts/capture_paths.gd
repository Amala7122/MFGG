extends RefCounted
## 截图兼容入口；路径由共用产物规则提供。
const Artifacts := preload("res://scripts/artifact_paths.gd")


static func root() -> String:
	return Artifacts.ensure_dir("screenshots")


static func file(relative_path: String) -> String:
	var base := root()
	return "" if base.is_empty() else base.path_join(relative_path)


static func ensure_dir(relative_path: String = "") -> String:
	return Artifacts.ensure_dir("screenshots", relative_path)
