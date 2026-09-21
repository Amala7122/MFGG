extends Node3D

const TargetingUtil := preload("res://scripts/targeting.gd")

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


func setup(radius: float, delay: float, blast_damage: float, color: Color) -> void:
	blast_radius = radius
	warning_duration = delay
	damage = blast_damage
	warning_color = color
	timer = warning_duration
	apply_color()


func apply_color() -> void:
	var disc_material := disc.material_override.duplicate() as StandardMaterial3D
	disc_material.albedo_color = Color(warning_color.r, warning_color.g, warning_color.b, 0.3)
	disc_material.emission = warning_color
	disc.material_override = disc_material
	var ring_material := ring.material_override.duplicate() as StandardMaterial3D
	ring_material.albedo_color = warning_color
	ring_material.emission = warning_color
	ring.material_override = ring_material
	light.light_color = warning_color
	label.modulate = warning_color


func _process(delta: float) -> void:
	timer -= delta
	if not exploded:
		var progress := 1.0 - clampf(timer / maxf(warning_duration, 0.01), 0.0, 1.0)
		var pulse := 1.0 + sin(Time.get_ticks_msec() * 0.025) * 0.08
		disc.scale = Vector3(blast_radius * progress, 1.0, blast_radius * progress) * pulse
		ring.scale = Vector3.ONE * blast_radius * pulse
		light.light_energy = 1.5 + progress * 4.0
		if timer <= 0.0:
			explode()
	else:
		var flash_scale := blast_radius * (1.0 + (0.18 - timer) * 4.0)
		disc.scale = Vector3(flash_scale, 1.0, flash_scale)
		if timer <= 0.0:
			queue_free()


func explode() -> void:
	exploded = true
	timer = 0.18
	label.visible = false
	ring.visible = false
	light.light_energy = 9.0
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
		var flat_distance := Vector2(
			player.global_position.x - global_position.x,
			player.global_position.z - global_position.z
		).length()
		if flat_distance <= blast_radius and player.has_method("take_damage"):
			# 传落点中心，让受击方向指示器指出这片炮击区域来自哪一侧。
			player.call("take_damage", damage, global_position)
