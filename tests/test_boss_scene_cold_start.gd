extends SceneTree
## 另起引擎直接加载正式场景，覆盖主场景_enter_tree早于autoload_ready的实际顺序。
const Artifacts := preload("res://scripts/artifact_paths.gd")
var failures := 0

func _initialize() -> void: call_deferred("_run")

func _run() -> void:
	# run_acceptance提供隔离项目；不允许修改工作区项目或真实用户目录。
	var run_dir := Artifacts.ensure_dir("reports","cold_start")
	var project_dir := ProjectSettings.globalize_path("res://")
	var marker := project_dir.replace("\\","/")
	if not marker.contains("/tmp/project/"):
		push_error("冷启动验收只允许在run_acceptance隔离项目中执行")
		quit(1)
		return
	var config_path := project_dir.path_join("project.godot")
	var original := FileAccess.get_file_as_bytes(config_path)
	var text := original.get_string_from_utf8()
	var anchor := "PostProcess=\"*res://scripts/post_process.gd\""
	if not text.contains(anchor):
		push_error("无法定位正式后处理autoload")
		quit(1)
		return
	var observer := "\nBossStartupObserver=\"*res://tests/fixtures/boss_startup_observer.gd\""
	var file := FileAccess.open(config_path,FileAccess.WRITE)
	file.store_string(text.replace(anchor,anchor+observer))
	file.close()
	var saved := ConfigFile.new()
	saved.set_value("display","post_process_style",1)
	if saved.save("user://display.cfg") != OK:
		push_error("冷启动存档夹具写入失败")
		failures += 1
	var cases: Array = []
	for scene: String in ["res://prototypes/boss_lab/sediment_titan_boss_lab.tscn","res://prototypes/sparring_lab/combat_sparring_lab.tscn"]:
		var name := scene.get_file().get_basename()
		var log_path := run_dir.path_join(name+".engine.log")
		var arguments := PackedStringArray(["--path",project_dir,"--log-file",log_path,"--max-fps","60","--quit-after","1800"])
		if DisplayServer.get_name() == "headless": arguments.append("--headless")
		arguments.append_array([scene,"--","--artifact-dir="+Artifacts.run_directory(),"--expected-scene="+scene])
		var output: Array = []
		var code := OS.execute(OS.get_executable_path(),arguments,output,true)
		var content := FileAccess.get_file_as_string(log_path) if FileAccess.file_exists(log_path) else ""
		var passed := code == 0 and not content.is_empty() and not content.contains("SCRIPT ERROR:") and not content.contains("\nERROR:") and content.contains('"passed":true')
		cases.append({"scene":scene,"exit_code":code,"passed":passed,"engine_log":log_path})
		if not passed:
			failures += 1
			push_error("冷启动拒绝："+scene)
	# 只恢复隔离副本；正式project.godot从未改变。
	file = FileAccess.open(config_path,FileAccess.WRITE)
	file.store_buffer(original)
	file.close()
	var report := FileAccess.open(run_dir.path_join("result.json"),FileAccess.WRITE)
	report.store_string(JSON.stringify({"cases":cases,"failures":failures},"\t"))
	report.close()
	print("[挑战冷启动验收] failures=",failures)
	quit(1 if failures else 0)
