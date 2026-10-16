extends SceneTree
const GrenadeScript := preload("res://scripts/grenade.gd")
var _failures := 0
var _world: Node3D

class Target extends Node3D:
	var health := 10000.0
	var hits := 0
	var stagger := 0.0
	func take_damage(amount: float) -> void:
		health -= amount
		hits += 1
	func apply_grenade_stagger(seconds: float) -> void:
		stagger = seconds

func _initialize() -> void:
	call_deferred("_run")

func _check(ok: bool, message: String) -> void:
	if not ok:
		_failures += 1
		push_error(message)

func _target(at: Vector3, radius := 0.5, child_offset := Vector3.ZERO) -> Target:
	var target := Target.new()
	target.position = at
	target.add_to_group("enemies")
	var body := StaticBody3D.new()
	body.collision_layer = 4
	body.position = child_offset
	var shape := CollisionShape3D.new()
	var sphere := SphereShape3D.new()
	sphere.radius = radius
	shape.shape = sphere
	body.add_child(shape)
	target.add_child(body)
	_world.add_child(target)
	return target

func _grenade(at: Vector3, speed := 17.0) -> RigidBody3D:
	var grenade := GrenadeScript.new()
	_world.add_child(grenade)
	grenade.launch(at, Vector3.RIGHT, speed)
	grenade.gravity_scale = 0.0
	grenade.linear_velocity = Vector3.RIGHT * speed
	return grenade

func _wait_explosion(grenade: Node, frames := 45) -> int:
	for index in range(frames):
		await physics_frame
		if not is_instance_valid(grenade):
			return index
	return frames

func _run() -> void:
	_world = Node3D.new()
	root.add_child(_world)
	current_scene = _world
	var target := _target(Vector3(0, 2, 0))
	await physics_frame
	var grenade := _grenade(Vector3(-3, 2, 0))
	var elapsed: int = await _wait_explosion(grenade)
	_check(elapsed < 25 and target.hits == 1 and target.stagger > 0.0, "真实物理接触在引信前起爆并只命中一次、赋予硬直")
	var fast := _target(Vector3(0, 2, 12), 0.05)
	await physics_frame
	grenade = _grenade(Vector3(-6, 2, 12), 600.0)
	await _wait_explosion(grenade, 8)
	_check(fast.hits == 1, "高速扫掠不漏薄目标")
	# 根不在爆炸半径，实际接触壳在近处；同一个敌人还有第二个身体。
	var large := _target(Vector3(20, 2, 24), 0.5, Vector3(-20, 0, 0))
	var second := large.get_child(0).duplicate()
	large.add_child(second)
	await physics_frame
	grenade = _grenade(Vector3(-3, 2, 24))
	await _wait_explosion(grenade)
	_check(large.hits == 1, "子级壳接触按敌人根去重，根在半径外仍结算该直接目标")
	var protected := _target(Vector3(2, 2, 36))
	var wall := StaticBody3D.new()
	wall.position = Vector3(0, 2, 36)
	var wall_shape := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = Vector3(0.3, 5, 5)
	wall_shape.shape = box
	wall.add_child(wall_shape)
	_world.add_child(wall)
	await physics_frame
	grenade = _grenade(Vector3(-1, 2, 36), 0.0)
	grenade._fuse = 0.01
	await _wait_explosion(grenade, 8)
	_check(protected.hits == 0, "墙体继续遮挡非直接目标的范围爆炸")
	grenade = _grenade(Vector3(-10, 2, 48), 0.0)
	grenade._fuse = 0.06
	await _wait_explosion(grenade, 12)
	_check(not is_instance_valid(grenade), "没有接敌仍能由引信起爆")
	# 接触请求与引信同帧竞争，仍走同一爆炸锁。
	var simultaneous := _target(Vector3(0, 2, 60))
	await physics_frame
	grenade = _grenade(Vector3(-0.55, 2, 60), 0.0)
	grenade._fuse = 0.001
	grenade._on_body_entered(simultaneous.get_child(0))
	grenade._on_body_entered(simultaneous.get_child(0))
	await _wait_explosion(grenade, 8)
	_check(simultaneous.hits == 1, "接触／多身体／同帧引信竞争不重复伤害")
	var removed := _target(Vector3(0, 2, 72))
	await physics_frame
	grenade = _grenade(Vector3(-1, 2, 72), 0.0)
	grenade._request_detonation(removed)
	removed.free()
	await _wait_explosion(grenade, 8)
	_check(not is_instance_valid(grenade), "接触对象在安全结算前死亡／退出时仍安全起爆，不持有已释放节点")
	current_scene = null
	_world.queue_free()
	await process_frame
	preload("res://scripts/object_pool.gd").clear_all()
	await preload("res://tools/probes/sparring/sparring_runtime.gd").settle_audio(self)
	print("[手雷接敌] failures=", _failures)
	quit(1 if _failures else 0)
