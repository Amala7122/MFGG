extends Node
## 仅供独立冷启动子进程使用；经测试临时登记为autoload，不接入正式项目。
const Artifacts := preload("res://scripts/artifact_paths.gd")

func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	var expected := ""
	for argument: String in OS.get_cmdline_user_args():
		if argument.begins_with("--expected-scene="):
			expected = argument.trim_prefix("--expected-scene=")
	var prepared := false
	for tick in range(1200):
		await get_tree().process_frame
		var scene := get_tree().current_scene
		if not is_instance_valid(scene): continue
		# 通用陪练默认可能是普通敌人编组，须检查实际准备面板，不能要求存在Boss。
		var encounter_ready: bool = is_instance_valid(scene.session) and is_instance_valid(scene.session.actor) and is_instance_valid(scene.session._panel) if scene.has_method("default_scenario") else get_tree().get_first_node_in_group("boss") != null
		if tick >= 3 and not scene.has_node("BossTrialLoading") and encounter_ready:
			prepared = true
			break
	var scene := get_tree().current_scene
	var settings := get_node("/root/DisplaySettings")
	var effect := get_node("/root/PostProcess")
	var saved := ConfigFile.new()
	var saved_style := -1
	if saved.load("user://display.cfg") == OK:
		saved_style = int(saved.get_value("display","post_process_style",-1))
	var headless := DisplayServer.get_name() == "headless"
	var report := {"prepared":prepared,"expected_scene":expected,"actual_scene":scene.scene_file_path if is_instance_valid(scene) else "", "post_process_ready":effect.is_node_ready(),"effective_style":settings.effective_post_process_style(),"effect_style":effect.style,"material_ready":effect._effect_material != null,"material_style":effect._effect_material.get_shader_parameter("style") if effect._effect_material != null else null,"saved_style":saved_style,"effect_visible":effect._overlay.visible or effect._sketch_rect.visible,"headless":headless}
	# 没有写入的参数保留null并拒绝，不把空值转0掩盖风格未真正应用。
	var material_ok: bool = report.material_ready and report.material_style == 0
	var passed: bool = prepared and report.actual_scene == expected and report.post_process_ready and report.effective_style == 0 and report.effect_style == 0 and material_ok and saved_style == 1 and not report.effect_visible
	report["passed"] = passed
	var directory := Artifacts.ensure_dir("reports","cold_start")
	var file := FileAccess.open(directory.path_join(scene.name+".json"),FileAccess.WRITE)
	if file == null:
		push_error("冷启动报告写入失败")
		get_tree().quit(1)
		return
	file.store_string(JSON.stringify(report,"\t"))
	file.close()
	if not passed: push_error("真实挑战冷启动未兑现基础画面/场景准备/存档保持")
	print("[真实冷启动] ", JSON.stringify(report))
	get_tree().quit(0 if passed else 1)
