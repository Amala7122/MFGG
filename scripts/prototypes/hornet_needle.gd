extends MeshInstance3D
## 自包含直线晶针：逐物理帧扫过路段，发射者死亡后仍保留伤害来源。
const Telemetry := preload("res://scripts/combat_telemetry.gd")
var direction := Vector3.FORWARD
var speed: float
var damage: float
var remaining_range: float
var source_info: Dictionary


func _physics_process(delta: float) -> void:
	var distance := minf(speed * delta, remaining_range)
	var destination := global_position + direction * distance
	var query := PhysicsRayQueryParameters3D.create(global_position, destination, 3)
	query.hit_from_inside = true
	var hit := get_world_3d().direct_space_state.intersect_ray(query)
	if not hit.is_empty():
		global_position = hit.position
		var actor := hit.collider as Node
		if actor != null and actor.is_in_group("player") and actor.has_method("take_damage"):
			Telemetry.hurt_player(actor, damage, global_position, 1.0, source_info)
		CombatFX.spawn_impact(get_parent(), global_position, hit.normal, CombatFX.COLOR_WORLD_HIT, 0.5)
		queue_free()
		return
	global_position = destination
	remaining_range -= distance
	if remaining_range <= 0.0:
		queue_free()
