extends Node3D
## 独立近战手感实验场：生成一圈小型野兽，统计击杀并隔离正式游戏流程。

@export var target_scene: PackedScene

@onready var _player: CharacterBody3D = $LabPlayer
@onready var _targets: Node3D = $Targets
@onready var _status: Label = $Interface/SafeArea/Panel/Padding/Status

var _kills := 0
var _isolation_frames_remaining := 3
var _demo_attack_timer := -1.0


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	_enforce_lab_isolation()
	_spawn_wave()
	if OS.get_cmdline_user_args().has("--demo-melee"):
		_demo_attack_timer = 2.0
	_update_status()


func _process(delta: float) -> void:
	if _isolation_frames_remaining > 0:
		_enforce_lab_isolation()
		_isolation_frames_remaining -= 1
	if _demo_attack_timer >= 0.0:
		_demo_attack_timer -= delta
		if _demo_attack_timer <= 0.0:
			_player.call("perform_melee")
			_demo_attack_timer = 0.42


func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventKey and event.pressed and not event.echo:
		if event.physical_keycode == KEY_R:
			_spawn_wave()


func _enforce_lab_isolation() -> void:
	get_tree().paused = false
	var game_flow := get_node_or_null("/root/GameFlow") as CanvasLayer
	if game_flow != null:
		game_flow.process_mode = Node.PROCESS_MODE_DISABLED
		game_flow.visible = false


func _spawn_wave() -> void:
	if target_scene == null:
		push_error("近战实验场没有指定 target_scene")
		return
	for child in _targets.get_children():
		child.queue_free()
	var positions := [
		Vector3(-4.0, 0.0, -7.0), Vector3(0.0, 0.0, -8.5), Vector3(4.0, 0.0, -7.0),
		Vector3(-7.0, 0.0, -2.0), Vector3(7.0, 0.0, -2.0),
		Vector3(-5.5, 0.0, 4.0), Vector3(0.0, 0.0, 6.0), Vector3(5.5, 0.0, 4.0),
	]
	for index in range(positions.size()):
		var target := target_scene.instantiate() as Node3D
		_targets.add_child(target)
		target.global_position = positions[index]
		target.call("setup", _player, -1.0 if index % 2 == 0 else 1.0)
		target.connect("eliminated", _on_target_eliminated)
	_update_status()


func _on_target_eliminated(_target: Node3D) -> void:
	_kills += 1
	_update_status()


func _update_status() -> void:
	if _status == null:
		return
	var alive := 0
	for target in _targets.get_children():
		if target.has_method("is_lab_dead") and not bool(target.call("is_lab_dead")):
			alive += 1
	_status.text = (
		"近战手感实验场\n"
		+ "WASD 移动　Shift 冲刺　鼠标转向　F 近战　R 重置兽群　ESC 释放鼠标\n"
		+ "小型野兽：近战一击必杀，单次最多命中 3 只　|　累计击杀 %d　|　剩余 %d"
	) % [_kills, alive]
