extends RefCounted
## 动态小队投放：中心随玩家位置选择，实际落点、身体空间和路线每次重新校验。

const Config := preload("res://scripts/game_config.gd")
const Arena := preload("res://scripts/arena.gd")
const Terrain := preload("res://scripts/terrain_field.gd")
const Targeting := preload("res://scripts/targeting.gd")
const FX := preload("res://scripts/combat_fx.gd")

var _owner: Node
var _arena: Dictionary
var _random: RandomNumberGenerator
var _squads: Array[Dictionary] = []
var _index := 0
var _last_angle := 0.0


func configure(owner: Node, arena: Dictionary, random: RandomNumberGenerator) -> void:
	_owner = owner
	_arena = arena
	_random = random
	_last_angle = _random.randf() * TAU


func begin_wave(total: int) -> void:
	_squads.clear()
	_index = 0
	var remaining := total
	while remaining > 0:
		var count := mini(remaining, _random.randi_range(2, 4))
		_squads.append({"count": count, "spawned": 0, "center": null})
		remaining -= count


func pick_position(entry: Dictionary, anchors: Array) -> Dictionary:
	if _index >= _squads.size():
		return select_single(entry, anchors)
	var squad: Dictionary = _squads[_index]
	var center: Variant = squad.center
	if center == null:
		var chosen := select_single(entry, anchors)
		if chosen.is_empty():
			return {}
		center = chosen.position
		squad.center = center
	for attempt in range(12):
		var candidate: Vector3 = center
		if int(squad.spawned) > 0 or attempt > 0:
			var angle := _random.randf() * TAU
			var spread := _random.randf_range(1.4, 3.2)
			candidate += Vector3(cos(angle), 0, sin(angle)) * spread
		var safe := validate(candidate, entry)
		if not safe.is_empty():
			return safe
	# 本组附近被占据或玩家移近：保留编组与预算，下一次在新中心重试。
	squad.center = null
	return {}


func commit_spawn() -> float:
	if _index < _squads.size():
		_squads[_index].spawned += 1
		if int(_squads[_index].spawned) < int(_squads[_index].count):
			return maxf(Config.get_float("spawn.squad_member_interval", 0.25), 0.05)
		_index += 1
	return maxf(Config.get_float("spawn.spawn_interval", 0.85), 0.05)


func select_single(entry: Dictionary, anchors: Array) -> Dictionary:
	var players := Targeting.living_players(_owner)
	if players.is_empty():
		return {}
	var minimum := maxf(Config.get_float("enemy_roster.anchor_min_player_distance", 14.0), 1.0)
	var maximum := maxf(Config.get_float("enemy_roster.anchor_max_player_distance", 32.0), minimum + 4.0)
	_last_angle = fposmod(_last_angle + _random.randf_range(1.15, 2.7), TAU)
	var visible_fallback: Dictionary = {}
	var attempts := maxi(Config.get_int("spawn.attempts", 24), 1)
	for attempt in range(attempts):
		var player := players[(_index + attempt) % players.size()] as Node3D
		var angle := _last_angle + attempt * 0.65
		var distance := _random.randf_range(minimum + 2.0, maximum - 2.0)
		var candidate := player.global_position + Vector3(cos(angle), 0, sin(angle)) * distance
		var safe := validate(candidate, entry)
		if safe.is_empty():
			continue
		# 优先从镜头外或遮挡后加入战斗；开阔场没有遮挡时允许安全距离内的可见点。
		if not _in_clear_view(safe.position):
			return safe
		if visible_fallback.is_empty():
			visible_fallback = safe
	if not visible_fallback.is_empty():
		return visible_fallback
	# 固定锚点仅作兜底，仍须通过相同的安全与可达性检查。
	for candidate in anchors:
		var safe := validate(candidate, entry)
		if not safe.is_empty():
			return safe
	return {}


func validate(candidate: Vector3, entry: Dictionary) -> Dictionary:
	if _owner == null or not _owner.is_inside_tree():
		return {}
	var scale := maxf(float(entry.get("scale", 1.0)), 0.5)
	var radius := float(entry.get("body_radius", 0.52)) * scale + 0.12
	var height := maxf(float(entry.get("body_height", 2.0)) * scale, radius * 2.0)
	var bound := float(_arena.get("extent", 60.0)) * 0.82 - radius
	if absf(candidate.x) > bound or absf(candidate.z) > bound or Arena.is_masked_out(_arena, candidate.x, candidate.z):
		return {}
	var minimum := maxf(Config.get_float("enemy_roster.anchor_min_player_distance", 14.0), 1.0)
	var maximum := maxf(Config.get_float("enemy_roster.anchor_max_player_distance", 32.0), minimum + 4.0)
	var players := Targeting.living_players(_owner)
	var nearest: Node3D
	var nearest_distance := INF
	for node in players:
		var player := node as Node3D
		var distance := Vector2(candidate.x - player.global_position.x, candidate.z - player.global_position.z).length()
		if distance < minimum:
			return {}
		if distance < nearest_distance:
			nearest_distance = distance
			nearest = player
	if nearest == null or nearest_distance > maximum:
		return {}
	var probe := candidate
	probe.y = maxf(candidate.y, Terrain.height_at(candidate.x, candidate.z)) + 12.0
	var surface := FX.sample_ground(_owner, probe, 24.0)
	if surface.is_empty() or surface.normal.y < cos(deg_to_rad(45.0)):
		return {}
	var point: Vector3 = surface.position
	var capsule := CapsuleShape3D.new()
	capsule.radius = radius
	capsule.height = height
	var query := PhysicsShapeQueryParameters3D.new()
	query.shape = capsule
	query.transform = Transform3D(Basis.IDENTITY, point + Vector3.UP * (height * 0.5 + 0.10))
	query.collision_mask = 5
	var world := _owner.get_viewport().find_world_3d()
	if not world.direct_space_state.intersect_shape(query, 1).is_empty():
		return {}
	if not _reachable(point, nearest, world):
		return {}
	return {"position": point}


func _reachable(point: Vector3, player: Node3D, world: World3D) -> bool:
	var map := world.navigation_map
	var target_floor := FX.sample_ground(_owner, player.global_position, 4.0)
	if target_floor.is_empty():
		return false
	var target: Vector3 = target_floor.position
	if not NavigationServer3D.map_get_regions(map).is_empty():
		if NavigationServer3D.map_get_iteration_id(map) == 0:
			return false
		var start := NavigationServer3D.map_get_closest_point(map, point)
		var end := NavigationServer3D.map_get_closest_point(map, target)
		if start.distance_to(point) > 1.5 or end.distance_to(target) > 1.5:
			return false
		var path := NavigationServer3D.map_get_path(map, start, end, true)
		return not path.is_empty() and path[path.size() - 1].distance_to(end) < 0.5
	# 未配置导航的实验关只接受有连续支撑的直线路径，不能隔墙或跨坑投放。
	var ray := PhysicsRayQueryParameters3D.create(point + Vector3.UP * 0.7, target + Vector3.UP * 0.7, 1)
	if not world.direct_space_state.intersect_ray(ray).is_empty():
		return false
	var steps := maxi(ceili(point.distance_to(target) / 2.0), 1)
	var previous := point
	for step in range(1, steps + 1):
		var expected := point.lerp(target, float(step) / steps)
		var ground := FX.sample_ground(_owner, expected + Vector3.UP * 1.5, 3.0)
		if ground.is_empty() or ground.normal.y < cos(deg_to_rad(45.0)) or absf(ground.position.y - previous.y) > 1.5:
			return false
		previous = ground.position
	return true


func _in_clear_view(point: Vector3) -> bool:
	var camera := _owner.get_viewport().get_camera_3d()
	if camera == null or not camera.is_position_in_frustum(point + Vector3.UP):
		return false
	var ray := PhysicsRayQueryParameters3D.create(camera.global_position, point + Vector3.UP, 1)
	return camera.get_world_3d().direct_space_state.intersect_ray(ray).is_empty()
