extends Node3D
## 敌人弹幕子弹。
##
## 【池化改造】玩家改成瞬发命中后不再生成子弹，但敌人弹幕仍在持续产生，
## 是当前唯一还在反复 instantiate / queue_free 的对象。改造要点：
##   1. 材质只在首次使用时 duplicate 一次，之后只改属性 —— 原来每次 setup()
##      都要 duplicate 三个材质，池化后它会变成主要剩余开销；
##   2. pulse_time 必须在 setup() 里归零，否则脉冲相位会带到下一次命中，
##      光环缩放会出现肉眼可见的跳变；
##   3. 生命周期结束时交还对象池，而不是 queue_free()。

const PoolUtil := preload("res://scripts/object_pool.gd")

const POOL_KEY := "enemy_bullet"

@export var speed: float = 9.0
@export var damage: float = 14.0
@export var lifetime: float = 6.0
@export var turn_rate: float

var direction: Vector3 = Vector3.FORWARD
var shooter: CollisionObject3D
var fired_by_player: bool
var pulse_time: float

var _core_material: StandardMaterial3D
var _aura_material: StandardMaterial3D


func setup(
	new_direction: Vector3,
	source: CollisionObject3D,
	new_damage: float = 14.0,
	new_speed: float = 9.0,
	new_turn_rate: float = 0.0,
	new_color: Color = Color(1.0, 0.04, 0.24, 1.0)
) -> void:
	direction = new_direction.normalized()
	shooter = source
	fired_by_player = source.is_in_group("player")
	# 池化时覆盖来源快照；发射者死亡后弹丸仍能正确归属。
	set_meta(&"combat_source", preload("res://scripts/combat_telemetry.gd").source_info(source, "弹幕"))
	damage = new_damage
	speed = new_speed
	turn_rate = new_turn_rate
	# 池化复用必须把全部随时间累积的状态归零，否则上一发的相位会带过来。
	pulse_time = 0.0
	lifetime = 6.0
	($Aura as MeshInstance3D).scale = Vector3.ONE
	apply_color(new_color)
	look_at(global_position + direction, Vector3.UP, true)


func apply_color(new_color: Color) -> void:
	if _core_material == null:
		_build_materials()
	_core_material.albedo_color = Color.WHITE
	_core_material.emission = Color.WHITE.lerp(new_color, 0.32)
	var contrast_color := Color.from_hsv(fmod(new_color.h + 0.18, 1.0), 0.88, 1.0, 0.34)
	_aura_material.albedo_color = contrast_color
	_aura_material.emission = contrast_color
	($Glow as OmniLight3D).light_color = new_color


## 每个实例只 duplicate 一次材质。Trail 与 Aura 共用同一份，保持原来的观感。
func _build_materials() -> void:
	var core_mesh: MeshInstance3D = $Core
	_core_material = core_mesh.material_override.duplicate() as StandardMaterial3D
	core_mesh.material_override = _core_material
	var aura_mesh: MeshInstance3D = $Aura
	_aura_material = aura_mesh.material_override.duplicate() as StandardMaterial3D
	aura_mesh.material_override = _aura_material
	($Trail as MeshInstance3D).material_override = _aura_material


func _physics_process(delta: float) -> void:
	pulse_time += delta
	$Aura.scale = Vector3.ONE * (1.0 + sin(pulse_time * 9.0) * 0.13)
	if not is_zero_approx(turn_rate):
		direction = direction.rotated(Vector3.UP, turn_rate * delta).normalized()
		look_at(global_position + direction, Vector3.UP, true)
	var next_position := global_position + direction * speed * delta
	var query := PhysicsRayQueryParameters3D.create(global_position, next_position)
	# Enemy barrage hits only world geometry (layer 1) and the player (layer 2).
	query.collision_mask = 5 if fired_by_player else 3
	if is_instance_valid(shooter):
		query.exclude = [shooter.get_rid()]
	var hit := get_world_3d().direct_space_state.intersect_ray(query)
	if hit:
		global_position = hit.position
		var collider: Object = hit.collider
		var collider_node := collider as Node
		var hit_player := collider_node != null and collider_node.is_in_group("player")
		var hit_enemy := collider_node != null and collider_node.is_in_group("enemies")
		var valid_target: bool = hit_enemy if fired_by_player else hit_player
		if valid_target and collider.has_method("take_damage"):
			if hit_player:
				# 玩家额外接收一个"伤害来源坐标"，供 HUD 画受击方向指示。
				# 敌人版本没有这个参数，所以必须分开调用，不能统一传两个参数。
				preload("res://scripts/combat_telemetry.gd").hurt_player(collider_node,
					damage, global_position, 1.0, get_meta(&"combat_source", {}))
			else:
				collider.call("take_damage", damage)
		_spawn_hit_feedback(hit, valid_target and hit_player)
		_retire()
		return
	global_position = next_position
	lifetime -= delta
	if lifetime <= 0.0:
		_retire()


## 交还对象池。调用方无需持有引用，也不需要再做任何清理。
func _retire() -> void:
	PoolUtil.release(POOL_KEY, self)


## 命中反馈：打中玩家用受击色、打中场景用中性色。
func _spawn_hit_feedback(hit: Dictionary, hit_player: bool) -> void:
	var scene := get_tree().current_scene
	if not scene:
		return
	var normal: Vector3 = hit.get("normal", Vector3.UP)
	# 不能叫 position：Node3D 自带同名属性，会触发 SHADOWED_VARIABLE_BASE_CLASS。
	var hit_position: Vector3 = hit.get("position", global_position)
	var color: Color = CombatFX.COLOR_PLAYER_HIT if hit_player else CombatFX.COLOR_WORLD_HIT
	CombatFX.spawn_impact(scene, hit_position, normal, color, 0.85)
