extends RigidBody3D
## 独立死亡演出；不持有敌人或其回调。触地之后再散架，暂停和重开随节点生效。
var tuning: Dictionary
var parts: Array[MeshInstance3D] = []
var fall_age := 0.0
var impact_age := 0.0
var impacted := false
var shattered := false


func _ready() -> void:
	add_to_group("enemy_death_effect")
	add_to_group("hornet_death_body")
	contact_monitor = true
	max_contacts_reported = 4


func _integrate_forces(state: PhysicsDirectBodyState3D) -> void:
	# 接触墙壁不算砸地；必须有支撑面，避免在空中提前散架。
	for index in range(state.get_contact_count()):
		# local 表示本体一侧的接触；引擎返回世界方向，不再乘身体旋转。
		var normal := state.get_contact_local_normal(index)
		if normal.dot(Vector3.UP) > 0.5:
			impacted = true


func _physics_process(delta: float) -> void:
	fall_age += delta
	if impacted:
		impact_age += delta
	if (impacted and impact_age >= float(tuning.impact_delay)) or (not impacted and fall_age >= float(tuning.fall_timeout)):
		shatter()


func shatter() -> void:
	if shattered:
		return
	shattered = true
	# 先缓存所有变换，避免移动父子部件后改变尚未处理的部件位置。
	var poses: Array[Transform3D] = []
	for part in parts:
		poses.append(part.global_transform)
	for index in range(parts.size()):
		var part := parts[index]
		var pose := poses[index]
		var fragment := RigidBody3D.new()
		fragment.mass = float(tuning.debris_mass)
		fragment.collision_layer = 0
		fragment.collision_mask = 1
		fragment.add_to_group("enemy_death_effect")
		fragment.add_to_group("hornet_debris")
		get_parent().add_child(fragment)
		fragment.global_transform = Transform3D(pose.basis.orthonormalized(), pose.origin)
		part.reparent(fragment, false)
		var mesh_scale := pose.basis.get_scale().abs()
		part.transform = Transform3D(Basis.from_scale(mesh_scale), Vector3.ZERO)
		var bounds := part.mesh.get_aabb()
		var collision := CollisionShape3D.new()
		var box := BoxShape3D.new()
		box.size = bounds.size * mesh_scale
		collision.shape = box
		collision.position = bounds.get_center() * mesh_scale
		fragment.add_child(collision)
		var horizontal := float(tuning.scatter_horizontal)
		fragment.apply_central_impulse(Vector3(randf_range(-horizontal, horizontal), randf_range(float(tuning.scatter_up_min), float(tuning.scatter_up_max)), randf_range(-horizontal, horizontal)) * fragment.mass)
		fragment.apply_torque_impulse(Vector3(randf(), randf(), randf()) * float(tuning.scatter_torque))
		var lifetime := Timer.new()
		lifetime.one_shot = true
		lifetime.wait_time = float(tuning.debris_lifetime)
		fragment.add_child(lifetime)
		lifetime.timeout.connect(fragment.queue_free)
		lifetime.start()
	queue_free()
