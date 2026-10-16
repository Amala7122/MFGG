extends SceneTree
## 原型台只交接编组；正式实战不继承无敌、临时参数或暂停／菜单状态。
const Settings := preload("res://tools/probes/sparring/sparring_settings.gd")
var _failures := 0

func _initialize() -> void:
	call_deferred("_run")

func _check(ok: bool, message: String) -> void:
	if not ok:
		_failures += 1
		push_error(message)

func _run() -> void:
	var original := FileAccess.get_file_as_string(Settings.Groups.PATH)
	var defaults := String(Settings.Groups.document().active)
	var flow := root.get_node("GameFlow")
	flow.set("state", preload("res://scripts/game_flow.gd").State.MENU)
	var prototype: Node = load("res://prototypes/combat_lab/combat_lab.tscn").instantiate()
	root.add_child(prototype)
	current_scene = prototype
	for _frame in range(5):
		await process_frame
	var selection := {"L1MeleeSoldier": 1, "L1ScoutGunner": 1}
	prototype.set_selection(selection)
	prototype._invincible.button_pressed = true
	prototype.open_sparring()
	var world: Node
	for _frame in range(1200):
		await process_frame
		var candidate := current_scene
		if is_instance_valid(candidate) and candidate.scene_file_path.ends_with("combat_sparring_lab.tscn") and is_instance_valid(candidate.get("session")):
			world = candidate
			break
	_check(is_instance_valid(world), "实际场景切换能从战斗实验台进入实战准备")
	if is_instance_valid(world):
		_check(Settings.same_values(world.run_options.group_selection, selection), "只带入选定正式兵种和数量")
		_check(not world.session.running and paused, "交接后在编辑器面板确认条件，未擅自开战")
		_check(not bool(world.session.actor.get_meta(&"experiment_invincible", false)), "原型台玩家无敌不会进入正式实战")
		_check(Settings.Groups.document().active == defaults, "交接保存不改变默认编组")
		world.session.start_run()
		_check(world.session.running, "继承自原型台的菜单／暂停状态不会阻止实战开始")
		world.session.finish("handoff_contract_end")
	paused = false
	current_scene = null
	if is_instance_valid(world):
		world.queue_free()
	elif is_instance_valid(prototype):
		prototype.queue_free()
	for _frame in range(5):
		await process_frame
	preload("res://scripts/object_pool.gd").clear_all()
	await preload("res://tools/probes/sparring/sparring_runtime.gd").settle_audio(self)
	var file := FileAccess.open(Settings.Groups.PATH, FileAccess.WRITE)
	file.store_string(original)
	file.close()
	print("[实验台 → 实战陪练] failures=", _failures)
	quit(1 if _failures else 0)
