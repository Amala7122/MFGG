extends SceneTree
## 父验收即使固定模拟步长，子进程仍按原生实时复现物理追赶。
const Artifacts := preload("res://scripts/artifact_paths.gd")

func _initialize() -> void:
	call_deferred("_run")

func _run() -> void:
	var output: Array = []
	var log_path := Artifacts.ensure_dir("logs").path_join("navigation_render_budget_child.engine.log")
	var code := OS.execute(OS.get_executable_path(), PackedStringArray([
		"--headless", "--path", ProjectSettings.globalize_path("res://"),
		"--log-file", log_path, "--script", "res://tests/fixtures/navigation_job_budget_child.gd",
	]), output, true)
	var log_text := FileAccess.get_file_as_string(log_path) if FileAccess.file_exists(log_path) else ""
	var passed := code == 0 and log_text.contains("[规划渲染帧预算子进程] PASS") \
		and not log_text.contains("SCRIPT ERROR:") and not log_text.contains("\nERROR:")
	if not passed:
		push_error("[规划渲染帧预算] 真实物理追赶时预算须只推进一份；子日志：" + log_path + " " + str(output))
	print("[规划渲染帧预算] ", "PASS" if passed else "FAIL")
	quit(0 if passed else 1)
