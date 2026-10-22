extends SceneTree
## 真正开始游戏的异步预热、重复点击、重开与日志敌人数回归。
const MainScene := preload("res://scenes/sanctum_main.tscn")
const Dust := preload("res://scripts/ground_dust.gd")
var _failed := false

func _initialize() -> void:
	call_deferred("_run")

func _run() -> void:
	var initial := MainScene.instantiate()
	root.add_child(initial)
	current_scene = initial
	for _frame in range(3):
		await process_frame
	var flow := root.get_node("GameFlow")
	flow.call("start_run")
	if bool(flow.get("_preparing_run")):
		_check(paused and not flow.is_playing(), "准备期间冻结战局，尚未进入游戏态")
		flow.call("start_run")
	await _wait_for_run(initial)
	_check(is_instance_valid(current_scene) and current_scene != initial, "准备完成后真实重载主场景")
	_check(get_nodes_in_group("player").size() == 1 and flow.is_playing() and not paused,
		"重复开始请求仍只生成一个正式玩家并恢复游戏态")
	_check(get_nodes_in_group("ground_dust").is_empty()
		and root.find_children("GroundDustWarmup", "", true, false).is_empty(), "预热发射器已释放，不混入战局")
	if DisplayServer.get_name() != "headless":
		_check(Dust._render_warmed, "图形开局已实际渲染共享扬尘资源")
	var old := current_scene
	flow.call("start_run")
	_check(not bool(flow.get("_preparing_run")), "同进程重开不重复等待管线预热")
	await _wait_for_run(old)
	_check(get_nodes_in_group("player").size() == 1, "重开正常生成玩家")
	var recorder := root.get_node("PerformanceRecorder")
	var baseline: int = recorder.call("_enemy_count")
	var new_enemy := Node.new()
	var old_enemy := Node.new()
	current_scene.add_child(new_enemy)
	current_scene.add_child(old_enemy)
	new_enemy.add_to_group("enemies")
	old_enemy.add_to_group("dynamic_enemies")
	old_enemy.add_to_group("enemies")
	_check(int(recorder.call("_enemy_count")) == baseline + 2, "日志涵盖新旧敌人组，同一实例不重复计数")
	print("[主场景开局准备] ", "FAIL" if _failed else "PASS")
	quit(1 if _failed else 0)

func _wait_for_run(previous: Node) -> void:
	for _frame in range(360):
		await process_frame
		if current_scene != null and current_scene != previous and not get_nodes_in_group("player").is_empty():
			return
	_check(false, "正式开局超时")

func _check(condition: bool, message: String) -> void:
	if not condition:
		_failed = true
		push_error(message)
