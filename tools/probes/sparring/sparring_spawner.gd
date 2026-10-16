extends "res://scripts/player_spawner.gd"
## 仅陪练入口替换输入／记录适配；模型、武器、移动与受伤继承正式玩家。
const SparringPlayer := preload("res://tools/probes/sparring/sparring_player.gd")

func spawn_player() -> Node3D:
	var container := get_parent().get_node_or_null("Players")
	if container == null:
		return null
	_clear_players()
	var player := PlayerScene.instantiate() as Node3D
	player.set_script(SparringPlayer)
	player.name = "Player"
	player.position = _spawn_origin()
	container.add_child(player)
	return player
