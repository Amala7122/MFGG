extends SceneTree
## 实际 sample 启动，以及取景器跨 2D/3D 场景释放、重建后的刷新。

const Flow := preload("res://scripts/game_flow.gd")
const ViewfinderScene := preload("res://addons/phantom_camera/panel/viewfinder/viewfinder_panel.tscn")
const SAMPLE_DIR := "res://addons/phantom_camera/examples/example_scenes/"
const FIRST_SAMPLE := SAMPLE_DIR + "3D/3d_follow_framed_example_scene.tscn"

var _failed := false
var _viewfinder: Control


func _initialize() -> void:
	# 引擎直接启动场景时先挂载初始场景；change_scene_to_file 会延迟到首帧之后。
	var sample: PackedScene = load(FIRST_SAMPLE)
	var scene := sample.instantiate()
	root.add_child(scene)
	current_scene = scene
	call_deferred("_run")


func _run() -> void:
	await _settle()
	var flow := Flow.instance
	_check(not paused, "独立 sample 启动不暂停场景树")
	_check(flow.state == Flow.State.PLAYING, "独立 sample 直接进入运行状态")
	_check(not flow._root.is_visible_in_tree(), "独立 sample 不显示开始画面")
	var cancel := InputEventAction.new()
	cancel.action = &"ui_cancel"
	cancel.pressed = true
	flow._input(cancel)
	_check(not paused and not flow._root.is_visible_in_tree(), "sample 的 ESC 不弹正式暂停菜单")
	# 基线失败时仍继续验证另一条生命周期问题。
	paused = false
	flow.state = Flow.State.PLAYING
	flow._set_overlay_visible(false)
	var manager := root.get_node("PhantomCameraManager")
	_viewfinder = manager.get_viewfinder()
	if is_instance_valid(_viewfinder):
		_viewfinder.free()
	_viewfinder = ViewfinderScene.instantiate()
	root.add_child(_viewfinder)
	manager.set_viewfinder(manager.get_phantom_camera_hosts()[0], _viewfinder)
	var scenes: Array[String] = []
	for dimension in ["2D", "3D"]:
		for filename in DirAccess.get_files_at(SAMPLE_DIR + dimension):
			if filename.ends_with(".tscn"):
				scenes.append(SAMPLE_DIR + dimension + "/" + filename)
	_check(scenes.size() == 18, "覆盖插件的 18 个 sample 入口")
	for path in scenes:
		var old_scene := current_scene
		change_scene_to_file(path)
		await _settle()
		_check(not is_instance_valid(old_scene), "旧场景已释放：" + path.get_file())
		_viewfinder.update_dead_zone()
		await process_frame
		_check(is_instance_valid(_viewfinder.pcam_host), "取景器绑定新场景 Host：" + path.get_file())
		if is_instance_valid(_viewfinder.pcam_host):
			_check(_viewfinder.pcam_host.is_inside_tree(), "取景器 Host 在场景树中：" + path.get_file())
		_check(not paused and not flow._root.is_visible_in_tree(), "sample 切换不弹开始画面：" + path.get_file())
	# 取景器可能作为根节点存在；无相机时刷新也必须安全。
	current_scene.free()
	await _settle()
	_viewfinder.update_dead_zone()
	await process_frame
	_check(not is_instance_valid(_viewfinder.pcam_host), "无 Host 时清空取景器绑定")
	_viewfinder.free()
	print("[Phantom sample 生命周期] ", "FAIL" if _failed else "PASS")
	quit(1 if _failed else 0)


func _settle() -> void:
	for _frame in range(8):
		await process_frame


func _check(condition: bool, message: String) -> void:
	if not condition:
		_failed = true
		push_error("[Phantom sample 生命周期] " + message)
	else:
		print("[Phantom sample 生命周期] 通过：", message)
