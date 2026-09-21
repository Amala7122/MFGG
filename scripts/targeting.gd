extends RefCounted
## 敌人选目标 / 玩家查询的【唯一入口】。
##
## ── 为什么必须有它 ──────────────────────────────────────────────
##
## 全项目一度都用 `get_tree().get_first_node_in_group("player")` 找玩家。
## 这种写法在"场上只有一个人"时是对的，但它把"谁是目标"散落在每一处调用点，
## 语义也没写清楚 —— 是第一个、最近的、还是活着的？日后再加第二名玩家时，
## 每处各挑各的，就会变成"敌人只追某个人、击杀算到别人头上"，
## 而且不会报任何错，只让人觉得"AI 有点怪"。
##
## 所以把"谁是目标"收成一处，语义写清楚：敌人取【最近的】。

const GROUP_PLAYER := "player"


static func players(from: Node) -> Array:
	if from == null or not from.is_inside_tree():
		return []
	return from.get_tree().get_nodes_in_group(GROUP_PLAYER)


## 还【活着】的玩家（血量 > 0）。敌人选目标必须用这个集合。
##
## 【为什么】血量归零的玩家不该继续吸引火力：敌人会对着尸体一直打，
## 而这些攻击对已经进入结算流程的玩家毫无意义。
static func living_players(from: Node) -> Array:
	var out: Array = []
	for node in players(from):
		var candidate := node as Node3D
		if candidate == null or not is_instance_valid(candidate):
			continue
		if float(candidate.get("health")) > 0.0:
			out.append(candidate)
	return out


## 离 from 最近的【活着】的玩家。没有则返回 null。
static func nearest_player(from: Node3D) -> Node3D:
	if from == null or not from.is_inside_tree():
		return null
	var here := from.global_position
	var best: Node3D = null
	var best_distance := INF
	for node in living_players(from):
		var candidate := node as Node3D
		if candidate == null or not is_instance_valid(candidate):
			continue
		var distance := candidate.global_position.distance_squared_to(here)
		if distance < best_distance:
			best_distance = distance
			best = candidate
	return best


## 离 from 最近的玩家位置。没有玩家时返回 from 自己的位置，
## 这样调用方拿到的一定是"一个合理的位置"，不需要到处判空。
static func nearest_player_position(from: Node3D) -> Vector3:
	var found := nearest_player(from)
	return found.global_position if found != null else from.global_position


## 离某个【点】最近的玩家。给"我没有一个自己的位置"的场合用（刷怪点等）。
static func nearest_to(from: Node, point: Vector3) -> Node3D:
	if from == null or not from.is_inside_tree():
		return null
	var best: Node3D = null
	var best_distance := INF
	for node in living_players(from):
		var candidate := node as Node3D
		if candidate == null or not is_instance_valid(candidate):
			continue
		var distance := candidate.global_position.distance_squared_to(point)
		if distance < best_distance:
			best_distance = distance
			best = candidate
	return best


## 这个点附近有没有任何玩家。刷怪点/落点预警用它 —— 判定条件应该是
## "离【任何】玩家太近"，而不是"离第一个玩家太近"。
static func any_within(from: Node, point: Vector3, radius: float) -> bool:
	var limit := radius * radius
	for node in living_players(from):
		var candidate := node as Node3D
		if candidate == null or not is_instance_valid(candidate):
			continue
		if candidate.global_position.distance_squared_to(point) <= limit:
			return true
	return false


## 任意一个玩家。给【自身没有位置】的调用方（wave_director 是 Node，不是 Node3D，
## 对它来说"最近的玩家"没有意义）。有位置时优先用 nearest_player。
static func first_player(from: Node) -> Node3D:
	for node in living_players(from):
		var candidate := node as Node3D
		if candidate != null and is_instance_valid(candidate):
			return candidate
	return null
