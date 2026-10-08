extends SceneTree
## T02 真实物理查询回归：相机命中、贴脸、枪口穿墙、掩体角与狙击穿透。

const Weapon := preload("res://scripts/player_weapon.gd")

class Target extends CharacterBody3D:
	var health := 10000.0
	func take_damage(amount: float) -> void:
		health -= amount

var _failed := false
var _world: Node3D
var _host: CharacterBody3D
var _camera: Camera3D
var _rig: Node3D
var _muzzle: Node3D
var _weapon: Node


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	await process_frame
	paused = false
	for distance in [0.65, 1.0, 3.0, 5.0, 10.0]:
		for camera_x in [0.0, 0.75, -0.75]:
			await _fixture()
			var target := _target(Vector3(0, 1, -distance))
			_camera.position.x = camera_x
			_camera.look_at(Vector3(0, 1.6, -distance))
			await _sync()
			var hits: Array = _weapon.call("_resolve_shot_hits", -_camera.global_basis.z, true)
			_check(hits.size() == 1 and hits[0].collider == target, "%.2f 米 / 相机横移 %.2f 米命中" % [distance, camera_x])
			if not hits.is_empty():
				_check(bool(hits[0].headshot), "贴脸仍用相机表面判爆头")
				_check((hits[0].normal as Vector3).length() > 0.9, "命中反馈法线有效")
				var previous := target.health
				_weapon.call("_fire_hitscan", -_camera.global_basis.z, true)
				_check(is_equal_approx(previous - target.health, float(hits[0].amount)), "瞬发伤害只结算一次")
			await _dispose()
	await _cover_cases()
	await _pierce_cases()
	await _range_and_layers()
	await _fire_modes()
	# 最后一发的非定位音效归 AudioManager 持有，等待播放结束后退出。
	await create_timer(0.5).timeout
	print("[T02] 射击回归完成：", "FAIL" if _failed else "PASS")
	quit(1 if _failed else 0)


func _fixture() -> void:
	_world = Node3D.new()
	root.add_child(_world)
	current_scene = _world
	_host = CharacterBody3D.new()
	_host.position = Vector3(0, 1, 0)
	_world.add_child(_host)
	_rig = Node3D.new()
	_rig.position = Vector3(0, 0.6, 0)
	_host.add_child(_rig)
	_muzzle = Node3D.new()
	_muzzle.position = Vector3(0.4, 0, -0.8)
	_rig.add_child(_muzzle)
	_camera = Camera3D.new()
	_camera.position = Vector3(0, 1.6, 4.5)
	_world.add_child(_camera)
	_weapon = Weapon.new()
	_host.add_child(_weapon)
	_weapon.set("_host", _host)
	_weapon.set("_camera", _camera)
	_weapon.set("_weapon_rig", _rig)
	_weapon.set("_muzzle", _muzzle)
	await _sync()


func _target(at: Vector3) -> Target:
	var target := Target.new()
	target.position = at
	target.collision_layer = 4
	target.collision_mask = 0
	target.add_to_group("enemies")
	var collision := CollisionShape3D.new()
	collision.name = "CollisionShape3D"
	var shape := CapsuleShape3D.new()
	shape.radius = 0.5
	shape.height = 2.0
	collision.shape = shape
	target.add_child(collision)
	_world.add_child(target)
	return target


func _box(at: Vector3, size: Vector3, layer: int = 1) -> StaticBody3D:
	var body := StaticBody3D.new()
	body.position = at
	body.collision_layer = layer
	body.collision_mask = 0
	var collision := CollisionShape3D.new()
	var shape := BoxShape3D.new()
	shape.size = size
	collision.shape = shape
	body.add_child(collision)
	_world.add_child(body)
	return body


func _cover_cases() -> void:
	for position in [Vector3(0.4, 1.6, -0.6), Vector3(0.3, 1.6, -1.6)]:
		await _fixture()
		var target := _target(Vector3(0, 1, -5))
		var wall := _box(position, Vector3(0.3, 2, 0.3))
		await _sync()
		var aim_point: Vector3 = _weapon.call("get_aim_point")
		_check(aim_point.z < -4.0, "相机看得到掩体后的目标")
		var hits: Array = _weapon.call("_resolve_shot_hits", Vector3.FORWARD, true)
		_check(hits.size() == 1 and hits[0].collider == wall and not bool(hits[0].is_enemy), "枪管穿入 / 掩体角阻挡优先")
		_weapon.call("_fire_hitscan", Vector3.FORWARD, true)
		_check(is_equal_approx(target.health, 10000.0), "枪口被挡不能伤害掩体后敌人")
		await _dispose()
	await _fixture()
	var inside_wall := _box(Vector3(0, 1.6, 0), Vector3(1.4, 2, 2))
	_target(Vector3(0, 1, -5))
	await _sync()
	var hits: Array = _weapon.call("_resolve_shot_hits", Vector3.FORWARD, false)
	_check(hits.size() == 1 and hits[0].collider == inside_wall and (hits[0].normal as Vector3).length() > 0.9, "肩部和枪口都在掩体内部仍阻挡且法线有效")
	await _dispose()


func _pierce_cases() -> void:
	await _fixture()
	var targets: Array[Target] = []
	for z in [-3.0, -6.0, -9.0, -12.0]:
		targets.append(_target(Vector3(0, 1, z)))
	await _sync()
	var hits: Array = _weapon.call("_resolve_shot_hits", Vector3.FORWARD, true)
	_check(hits.size() == 3, "狙击最多穿透 3 个敌人")
	for index in range(hits.size()):
		_check(hits[index].collider == targets[index] and bool(hits[index].headshot), "每个穿透目标只命中一次且独立判爆头")
	_weapon.call("_fire_hitscan", Vector3.FORWARD, true)
	_check(targets[3].health == 10000.0, "穿透上限后的第四个目标不扣血")
	var primary: Array = _weapon.call("_resolve_shot_hits", Vector3.FORWARD, false)
	_check(primary.size() == 1 and primary[0].collider == targets[0], "普攻不穿透")
	await _dispose()
	await _fixture()
	var first := _target(Vector3(0, 1, -3))
	var wall := _box(Vector3(0, 1, -5), Vector3(2, 3, 0.3))
	var behind := _target(Vector3(0, 1, -7))
	await _sync()
	hits = _weapon.call("_resolve_shot_hits", Vector3.FORWARD, true)
	_check(hits.size() == 2 and hits[0].collider == first and hits[1].collider == wall, "穿透遇到世界碰撞即停止")
	_weapon.call("_fire_hitscan", Vector3.FORWARD, true)
	_check(behind.health == 10000.0, "墙后的穿透目标不扣血")
	await _dispose()
	await _fixture()
	var aimed := _target(Vector3(0, 1, -5))
	var interceptor := _target(Vector3(0.62, 1, -1.3))
	await _sync()
	hits = _weapon.call("_resolve_shot_hits", Vector3.FORWARD, false)
	_check(hits.size() == 1 and hits[0].collider == interceptor and hits[0].collider != aimed, "枪口前另一名敌人可以截住射击")
	await _dispose()


func _range_and_layers() -> void:
	await _fixture()
	var target := _target(Vector3(0, 1, -3))
	_box(Vector3(0, 1.6, -1.5), Vector3(2, 2, 0.3), 8)
	await _sync()
	var aim: Vector3 = _weapon.call("get_aim_point")
	var hits: Array = _weapon.call("_resolve_shot_hits", Vector3.FORWARD, false)
	_check(aim.z < -2.0 and hits.size() == 1 and hits[0].collider == target, "瞄准与结算使用同一碰撞层")
	await _dispose()
	await _fixture()
	_weapon.set("shot_range", 10.0)
	_target(Vector3(0, 1, -15))
	await _sync()
	hits = _weapon.call("_resolve_shot_hits", Vector3.FORWARD, false)
	_check(hits.is_empty(), "第三人称相机偏移不会扩大伤害射程")
	await _dispose()


func _sync() -> void:
	await physics_frame
	await physics_frame


func _fire_modes() -> void:
	for sniper in [false, true]:
		await _fixture()
		var target := _target(Vector3(0, 1, -0.65))
		_camera.position.x = 0.75
		_camera.look_at(Vector3(0, 1.6, -0.65))
		_weapon.set("base_spread_degrees", 0.0)
		_weapon.set("_aiming", sniper)
		_weapon.set("_ammo", 10)
		_weapon.set("_sniper_ammo", 5)
		await _sync()
		var previous := target.health
		_weapon.call("fire")
		_check(target.health < previous, "实际 fire 入口贴脸命中：" + ("狙击" if sniper else "普攻"))
		_check(int(_weapon.get("_sniper_ammo" if sniper else "_ammo")) == (4 if sniper else 9), "各模式只消耗一发弹药")
		await _dispose()


func _dispose() -> void:
	current_scene = null
	_world.queue_free()
	await process_frame
	await _sync()


func _check(condition: bool, message: String) -> void:
	if not condition:
		_failed = true
		push_error("[T02] " + message)
