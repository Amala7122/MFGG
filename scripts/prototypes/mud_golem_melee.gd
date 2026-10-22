class_name MudGolemMelee
extends RefCounted
## 单次普通拳击：无地面预警、无渲染节点、无独立物理 tick。
## 保留 EnemyAttackArea 的 PREPARE→LOCKED→STRIKE→RECOVERY 语义。
## 时间顺序仍由实体原有物理 Tween 决定；命中后仍按真实世界遮挡判断。

const AttackArea := preload("res://scripts/enemy_attack_area.gd")
const HealthUtil := preload("res://scripts/health_util.gd")

enum Phase { IDLE, PREPARE, LOCKED, STRIKE, RECOVERY }

var phase := Phase.IDLE
var shape: Dictionary = {}
var damage := 0.0
var origin := Vector3.ZERO
var visible := false
var _host: Node3D
var _pose := Transform3D.IDENTITY
var _spent := true


func setup(host: Node3D) -> void:
	_host = host


func prepare(pose: Transform3D, spec: Dictionary, amount: float, _countdown_duration := 0.0) -> void:
	_pose = Transform3D(pose.basis.orthonormalized(), pose.origin)
	origin = _pose.origin
	shape = spec.duplicate(true)
	damage = amount
	phase = Phase.PREPARE
	_spent = false


func lock() -> void:
	if phase == Phase.PREPARE:
		phase = Phase.LOCKED


func strike() -> bool:
	if phase != Phase.LOCKED or _spent:
		return false
	_spent = true
	phase = Phase.STRIKE
	return true


func recover() -> void:
	if phase != Phase.IDLE:
		phase = Phase.RECOVERY


func cancel() -> void:
	phase = Phase.IDLE
	_spent = true
	# Original AttackArea.cancel() keeps the last shape for observation tools.


func can_reach(point: Vector3) -> bool:
	if shape.is_empty():
		return false
	# Ordinary mud punches use a sector. Geometry remains identical to
	# EnemyAttackArea.contains(), including its numeric boundary tolerance.
	var p := _pose.affine_inverse() * point
	var distance := Vector2(p.x, p.z).length()
	return distance <= float(shape.radius) + 0.00001 and (
		distance <= 0.001 or -p.z / distance + 0.00001 >=
		cos(deg_to_rad(float(shape.angle)) * 0.5)
	)


func can_hit(actor: Node3D, source: Vector3) -> bool:
	if not HealthUtil.is_alive(actor) or not can_reach(actor.global_position):
		return false
	if absf(actor.global_position.y - origin.y) > float(shape.get("height", 2.5)):
		return false
	return AttackArea.unobstructed(_host, source, actor.global_position)
