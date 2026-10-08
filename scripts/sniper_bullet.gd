class_name SniperBullet
extends Node3D
## 远程狙击重型高能穿甲弹（超音速曳光弹道与近身呼啸判定）。
##
## 解决痛点：狙击手开火不再是瞬间隐形判定，而是发射可见的超音速高亮重弹。
## - 强烈的发光弹头与长条形电离高亮尾迹；
## - 飞行速度 72 m/s，跨越战场有可察觉的弹道；
## - 玩家若在锁定后翻滚/闪避，近距离擦身而过触发超音速掠顶呼啸音效与微镜头震颤（成就感拉满）；
## - 命中掩体/地面触发爆碎火花与尘烟。

const CombatFXUtil := preload("res://scripts/combat_fx.gd")
const AudioUtil := preload("res://scripts/audio_manager.gd")

var speed: float = 72.0
var damage: float = 35.0
var direction: Vector3 = Vector3.FORWARD
var shooter: CollisionObject3D = null
var lifetime: float = 1.6
var elapsed: float = 0.0

var _near_miss_triggered: bool = false
var _mesh: MeshInstance3D
var _light: OmniLight3D
var _trail: MeshInstance3D
var _color: Color = Color(1.0, 0.25, 0.1, 1.0)
var _last_pos: Vector3


func setup(start_pos: Vector3, dir: Vector3, source: CollisionObject3D, dmg: float, bullet_color: Color = Color(1.0, 0.25, 0.1, 1.0)) -> void:
	direction = dir.normalized()
	global_position = start_pos
	_last_pos = start_pos
	shooter = source
	damage = dmg
	_color = bullet_color
	look_at(global_position + direction, Vector3.UP)
	add_to_group("enemy_projectiles")
	_build_visuals()


## 被震地脉冲格挡打碎
func deflect() -> void:
	queue_free()


func _build_visuals() -> void:
	# 1. 穿甲弹头主网格：细长流线型低多边形弹体（长 1.8m）
	var cyl := CylinderMesh.new()
	cyl.top_radius = 0.02
	cyl.bottom_radius = 0.07
	cyl.height = 1.8
	cyl.radial_segments = 8
	cyl.rings = 1

	var mat := StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.albedo_color = Color(1.0, 0.95, 0.8)
	mat.emission_enabled = true
	mat.emission = _color
	mat.emission_energy_multiplier = 12.0
	cyl.material = mat

	_mesh = MeshInstance3D.new()
	_mesh.mesh = cyl
	_mesh.rotation.x = PI * 0.5 # 沿 Z 轴对齐
	add_child(_mesh)

	# 2. 超音速弹道离子辉光
	_light = OmniLight3D.new()
	_light.light_color = _color
	_light.light_energy = 4.5
	_light.omni_range = 5.0
	_light.shadow_enabled = false
	add_child(_light)

	# 3. 曳光电离长尾迹 (Trail)
	var trail_box := BoxMesh.new()
	trail_box.size = Vector3(0.04, 0.04, 3.8)
	var trail_mat := StandardMaterial3D.new()
	trail_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	trail_mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	trail_mat.blend_mode = BaseMaterial3D.BLEND_MODE_ADD
	trail_mat.albedo_color = Color(_color.r, _color.g, _color.b, 0.7)
	trail_box.material = trail_mat

	_trail = MeshInstance3D.new()
	_trail.mesh = trail_box
	_trail.position = Vector3(0.0, 0.0, 2.2) # 拖在弹头后方
	add_child(_trail)


func _physics_process(delta: float) -> void:
	elapsed += delta
	if elapsed >= lifetime:
		queue_free()
		return

	var current_pos := global_position
	var next_pos := current_pos + direction * speed * delta

	# 空间防穿模扫掠射线检测
	var space := get_world_3d().direct_space_state
	if space:
		var ray := PhysicsRayQueryParameters3D.create(current_pos, next_pos, 1 | 2) # 掩体/世界 + 玩家
		if is_instance_valid(shooter):
			ray.exclude = [shooter.get_rid()]
		var hit := space.intersect_ray(ray)
		if not hit.is_empty():
			_on_impact(hit)
			return

	# 近距离掠顶/近身音效检测 (Near Miss)：让躲开狙击的反馈极具爽感
	if not _near_miss_triggered:
		var player := get_tree().get_first_node_in_group("player") as Node3D
		if player and is_instance_valid(player):
			var dist := next_pos.distance_to(player.global_position + Vector3.UP * 0.9)
			if dist <= 2.6:
				_near_miss_triggered = true
				AudioUtil.play_at("shot", player.global_position, 1.5, 2.4)
				if player.has_method("apply_camera_shake"):
					player.call("apply_camera_shake", 0.3)

	global_position = next_pos
	_last_pos = current_pos


func _on_impact(hit: Dictionary) -> void:
	var hit_pos: Vector3 = hit.position
	var hit_normal: Vector3 = hit.normal
	var scene := get_tree().current_scene if get_tree() else null

	if scene:
		CombatFXUtil.spawn_impact(scene, hit_pos, hit_normal, _color, 2.4)
		AudioUtil.play_at("hit", hit_pos, 2.0, 0.8)

	var collider: Object = hit.collider
	if collider and collider is Node and collider.is_in_group("player"):
		if collider.has_method("take_damage"):
			collider.call("take_damage", damage, global_position)

	queue_free()

