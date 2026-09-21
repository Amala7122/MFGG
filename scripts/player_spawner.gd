extends Node
## 生成本局的玩家（单机）。
##
## ── 为什么不让 Player 直接写死在场景里 ──────────────────────────────
##
## 出生点必须落在当前地图压平的出生圆里，重开一局/切图时还要能重建，
## 所以统一由本节点负责实例化，和敌人生成器对称。

const GameFlowUtil := preload("res://scripts/game_flow.gd")
const ConfigUtil := preload("res://scripts/game_config.gd")
const ArenaUtil := preload("res://scripts/arena.gd")

const PlayerScene := preload("res://scenes/player.tscn")

## 出生点兜底值。取自原先写死在场景里的 Player 坐标。
##
## 读 `arenas.definitions.<id>.map.spawn_origin`，缺项才退回这个值。
const FALLBACK_SPAWN_ORIGIN := Vector3(0.0, 1.0, 13.0)


func _ready() -> void:
	# 生成目标容器：与 spawner 同级的 Players 节点。
	if get_parent().get_node_or_null("Players") == null:
		push_error("PlayerSpawner: 找不到同级的 Players 容器节点")
		return
	# 开局事件由 GameFlow 负责重载地图；新场景起来时一局已经在跑，统一生成一次。
	if GameFlowUtil.is_playing():
		spawn_player()


## 生成（或重建）本局的玩家。
func spawn_player() -> Node3D:
	var container := get_parent().get_node_or_null("Players")
	if container == null:
		return null
	_clear_players()
	var node := PlayerScene.instantiate() as Node3D
	node.name = "Player"
	node.position = _spawn_origin()
	container.add_child(node)
	return node


## 清掉现有玩家。用 remove_child + queue_free 而不是只 queue_free ——
## queue_free 是延迟的，紧接着 spawn 同名节点会被自动改名（Player@2 之类），
## 让后面的按名/按路径查找全部失准。
func _clear_players() -> void:
	var container := get_parent().get_node_or_null("Players")
	if container == null:
		return
	for child in container.get_children():
		container.remove_child(child)
		child.queue_free()


## 本张地图的出生点。竞技场给了 `map.spawn_origin` 就用它，否则退回旧常量。
##
## 【为什么要读竞技场而不是读全局】—— 出生点必须落在该图的压平圆里，
## 而每张图的 mask_circles 各不相同。写在全局等于把湖畔的坐标套给所有图。
func _spawn_origin() -> Vector3:
	var map := ConfigUtil.get_dictionary(
		"arenas.definitions.%s.map" % ArenaUtil.resolve_id()
	)
	var value: Variant = map.get("spawn_origin", null)
	if value is Array and (value as Array).size() >= 2:
		var pair := value as Array
		var y := float(pair[2]) if pair.size() >= 3 else FALLBACK_SPAWN_ORIGIN.y
		return Vector3(float(pair[0]), y, float(pair[1]))
	return FALLBACK_SPAWN_ORIGIN
