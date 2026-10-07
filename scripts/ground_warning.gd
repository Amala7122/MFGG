extends Node3D

const TargetingUtil := preload("res://scripts/targeting.gd")
const AttackArea := preload("res://scripts/enemy_attack_area.gd")
var _attack_area := AttackArea.new()
var _attacker: WeakRef
var _cancelled := false

@export var warning_duration: float = 1.35
@export var blast_radius: float = 2.5
@export var damage: float = 20.0

var timer: float
var exploded: bool
var warning_color: Color = Color(1.0, 0.12, 0.02, 1.0)
## 只要画面、不要伤害。给"客户端上的同一份预告"用 ——
## 伤害只由服务器判定，两端各画一份时客户端那份绝不能也去扣血。
var visual_only := false

@onready var disc: MeshInstance3D = $Disc
@onready var ring: MeshInstance3D = $Ring
@onready var light: OmniLight3D = $WarningLight
@onready var label: Label3D = $WarningLabel


func _ready() -> void:
	timer = warning_duration
	add_child(_attack_area)


func setup(radius: float, delay: float, blast_damage: float, color: Color) -> void:
	blast_radius = radius
	warning_duration = delay
	damage = blast_damage
	warning_color = color
	timer = warning_duration
	apply_color()
	_attack_area.prepare(global_transform, {"kind": "circle", "radius": blast_radius, "height": 2.5, "source_height": 0.2}, damage)
	_attack_area.lock()
	# 边界与填充都由贴地网格提供，旧的平面圆环/X 在坡道上会悬空。
	disc.visible = false
	ring.visible = false


func bind_attacker(actor: Node3D) -> void:
	_attacker = weakref(actor)


func cancel() -> void:
	_cancelled = true
	_attack_area.cancel()
	visible = false
	queue_free()


func _attacker_alive() -> bool:
	if _attacker == null:
		return true
	var actor := _attacker.get_ref() as Node3D
	return is_instance_valid(actor) and not actor.is_queued_for_deletion() and float(actor.get("health")) > 0.0


func apply_color() -> void:
	var disc_material := disc.material_override.duplicate() as StandardMaterial3D
	disc_material.albedo_color = Color(warning_color.r, warning_color.g, warning_color.b, 0.3)
	disc_material.emission = warning_color
	disc_material.cull_mode = BaseMaterial3D.CULL_DISABLED
	disc.material_override = disc_material
	var ring_material := ring.material_override.duplicate() as StandardMaterial3D
	ring_material.albedo_color = warning_color
	ring_material.emission = warning_color
	ring.material_override = ring_material
	light.light_color = warning_color
	label.modulate = warning_color


func _physics_process(delta: float) -> void:
	if _cancelled or not _attacker_alive():
		cancel()
		return
	timer -= delta
	if not exploded:
		var progress := 1.0 - clampf(timer / maxf(warning_duration, 0.01), 0.0, 1.0)
		_attack_area.set_progress(progress)
		light.light_energy = 1.5 + progress * 4.0
		if timer <= 0.0:
			explode()
	else:
		# 爆炸闪光复用同一片地表，不能缩放后再次穿入坡面。
		(disc.material_override as StandardMaterial3D).albedo_color.a = 0.3 * clampf(timer / 0.18, 0.0, 1.0)
		if timer <= 0.0:
			queue_free()


func explode() -> void:
	if exploded or _cancelled or not _attacker_alive() or not _attack_area.strike():
		return
	exploded = true
	timer = 0.18
	label.visible = false
	ring.visible = false
	light.light_energy = 9.0
	disc.mesh = _attack_area._mesh.mesh
	disc.global_transform = _attack_area.global_transform
	disc.visible = true
	if visual_only:
		return
	# 【圈内所有人都吃伤害】
	#
	# 原先只伤 nearest_player()：两个人站在同一个圈里，只有离落点近的那个掉血，
	# 另一个毫发无伤地站在爆炸里。范围伤害的语义就是"在这片区域里就有事"，
	# 不该再按距离挑一个人。
	for node in TargetingUtil.living_players(self):
		var player := node as Node3D
		if player == null:
			continue
		if _attack_area.can_hit(player, global_position + Vector3.UP * 0.2) and player.has_method("take_damage"):
			# 传落点中心，让受击方向指示器指出这片炮击区域来自哪一侧。
			preload("res://scripts/combat_telemetry.gd").hurt_player(player,
				damage, global_position, 1.0, get_meta(&"combat_source", {"id": "unknown", "title": "未归属", "attack": "炮击"}))
