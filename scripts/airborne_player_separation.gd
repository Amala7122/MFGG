extends RefCounted
## 重型跃击暂不以身体挤压玩家；区域攻击照常结算，真实分离后恢复实体阻挡。
var _players: Array[Dictionary] = []

func begin(host: PhysicsBody3D) -> void:
	for candidate in host.get_tree().get_nodes_in_group("player"):
		var player := candidate as PhysicsBody3D
		if player == null or _players.any(func(entry: Dictionary): return entry.player.get_ref() == player):
			continue
		var player_added := not player.get_collision_exceptions().has(host)
		var host_added := not host.get_collision_exceptions().has(player)
		if player_added:
			player.add_collision_exception_with(host)
		if host_added:
			host.add_collision_exception_with(player)
		_players.append({"player": weakref(player), "player_added": player_added, "host_added": host_added})

func step(host: PhysicsBody3D, airborne: bool) -> void:
	if airborne:
		return
	for entry: Dictionary in _players.duplicate():
		var player := entry.player.get_ref() as PhysicsBody3D
		if player == null or not player.is_inside_tree() or not _overlapping(host, player):
			_restore(host, entry)
			_players.erase(entry)

func clear(host: PhysicsBody3D) -> void:
	for entry: Dictionary in _players:
		_restore(host, entry)
	_players.clear()

func _overlapping(host: PhysicsBody3D, player: PhysicsBody3D) -> bool:
	var space := host.get_world_3d().direct_space_state
	for child in player.get_children():
		var collision := child as CollisionShape3D
		if collision == null or collision.disabled or collision.shape == null:
			continue
		var query := PhysicsShapeQueryParameters3D.new()
		query.shape = collision.shape
		query.transform = collision.global_transform
		query.margin = 0.04
		query.collision_mask = host.collision_layer
		query.exclude = [player.get_rid()]
		var hits := space.intersect_shape(query, 64)
		for hit: Dictionary in hits:
			if hit.collider == host:
				return true
		if hits.size() >= 64:
			return true # 查询上限不能成为提前恢复阻挡的理由。
	return false

func _restore(host: PhysicsBody3D, entry: Dictionary) -> void:
	var player := entry.player.get_ref() as PhysicsBody3D
	if player != null:
		if entry.player_added:
			player.remove_collision_exception_with(host)
		if entry.host_added:
			host.remove_collision_exception_with(player)
