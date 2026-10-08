extends Node3D
## 余震烈焰：贴地覆盖与伤害共用一片可达地表，随场景暂停/卸载。

const AttackArea := preload("res://scripts/enemy_attack_area.gd")
const BurnShader := preload("res://shaders/resonance_burn_fill.gdshader")
const HealthUtil := preload("res://scripts/health_util.gd")
const Telemetry := preload("res://scripts/combat_telemetry.gd")
const CombatFXUtil := preload("res://scripts/combat_fx.gd")
const DURATION := 5.0
const TICK_INTERVAL := 0.5

var _remaining_time := DURATION
var _tick_elapsed := 0.0
var _tick_damage := 20.0
var _area: Node3D


func _ready() -> void:
	_area = AttackArea.new()
	add_child(_area)


func setup(radius: float, damage_per_second: float) -> void:
	_tick_damage = maxf(damage_per_second, 0.0) * TICK_INTERVAL
	_area.prepare(global_transform, {"kind": "circle", "radius": maxf(radius, 0.1),
		"height": 2.5, "source_height": 0.2,
		"exclude_bodies": _enemy_bodies()}, _tick_damage)
	_area.lock()
	_area.set_progress(1.0)
	_area._material.shader = BurnShader
	(_area._border.material_override as StandardMaterial3D).albedo_color = Color(1.0, 0.65, 0.1, 0.9)


func _physics_process(delta: float) -> void:
	var active_delta := minf(maxf(delta, 0.0), _remaining_time)
	_remaining_time = maxf(_remaining_time - active_delta, 0.0)
	_tick_elapsed += active_delta
	while _tick_elapsed + 0.000001 >= TICK_INTERVAL:
		_tick_elapsed = maxf(_tick_elapsed - TICK_INTERVAL, 0.0)
		_damage_targets()
	if _remaining_time <= 0.000001:
		queue_free()


func _damage_targets() -> void:
	if _area == null or _tick_damage <= 0.0:
		return
	var excluded := _enemy_bodies()
	for node in get_tree().get_nodes_in_group("enemies"):
		var target := node as Node3D
		if not HealthUtil.is_alive(target) or not target.has_method("take_damage"):
			continue
		if not _area.can_reach(target.global_position) \
			or absf(target.global_position.y - global_position.y) > 2.5:
			continue
		# 旧 Boss 也占地形层；敌人自身不能被当作隔断领域的墙体。
		var ray := PhysicsRayQueryParameters3D.create(global_position + Vector3.UP * 0.2,
			target.global_position, 1, excluded)
		if not get_world_3d().direct_space_state.intersect_ray(ray).is_empty():
			continue
		Telemetry.hurt_enemy(target, _tick_damage, {"source": "resonance_burn", "source_kind": "player"})
		if is_instance_valid(target):
			CombatFXUtil.spawn_damage_number(self, target.global_position + Vector3.UP,
				_tick_damage, Color(1.0, 0.55, 0.1), 0.85)


func _enemy_bodies() -> Array[RID]:
	var bodies: Array[RID] = []
	for node in get_tree().get_nodes_in_group("enemies"):
		if node is CollisionObject3D:
			bodies.append(node.get_rid())
	return bodies
