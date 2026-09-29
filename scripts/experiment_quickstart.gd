extends Node
## 寂石圣所实验场景专用：跳过开始画面并生成无敌测试角色。
##
## 只挂在实验场景中，不影响正式关卡的菜单和伤害规则。

@export_category("实验场景快速开始")
## 开启后，运行实验场景会直接进入游戏，不显示开始画面。
@export var skip_start_screen: bool = true
## 开启后，本场景生成的玩家不会受到任何伤害，方便观察天气效果。
@export var invincible_player: bool = true
## 开启后，ESC 只静默暂停/继续，不显示暂停和退出菜单，方便截取干净画面。
@export var silent_escape_pause: bool = true

var _configured_flow: Node


func _enter_tree() -> void:
	# GameFlow 的开始画面会暂停场景树；本节点必须仍能完成快速开始。
	process_mode = Node.PROCESS_MODE_ALWAYS


func _ready() -> void:
	if skip_start_screen:
		call_deferred("_enter_experiment")


func _enter_experiment() -> void:
	# 让 GameFlow 先完成自己的首帧菜单初始化，再接管为实验状态。
	await get_tree().process_frame
	await get_tree().process_frame
	var flow := get_node_or_null("/root/GameFlow")
	if flow != null and silent_escape_pause:
		flow.set_meta(&"experiment_silent_pause", true)
		_configured_flow = flow
	if flow != null and flow.has_method("_resume_play"):
		flow.call("_resume_play")
	else:
		get_tree().paused = false
		Input.mouse_mode = Input.MOUSE_MODE_CAPTURED

	var spawner := get_node_or_null("../PlayerSpawner")
	var player: Node = get_tree().get_first_node_in_group("player")
	if player == null and spawner != null and spawner.has_method("spawn_player"):
		player = spawner.call("spawn_player") as Node
	if player != null and invincible_player:
		player.set_meta(&"experiment_invincible", true)

	# WaveDirector 的 _ready 发生在快速开始切入 PLAYING 之前，需要在玩家就位后补发开局。
	var wave_director := get_node_or_null("../Enemies/WaveDirector")
	if wave_director != null and wave_director.has_method("start_for_active_run"):
		wave_director.call("start_for_active_run")


func _exit_tree() -> void:
	# GameFlow 是 Autoload；离开实验场景时必须撤销标记，避免污染正式关卡。
	if is_instance_valid(_configured_flow):
		_configured_flow.remove_meta(&"experiment_silent_pause")
