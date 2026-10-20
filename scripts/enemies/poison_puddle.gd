extends Node3D
## 投出的爆囊留下的真实毒池；与死亡毒液分开，来源只保存快照。
const Surface := preload("res://scripts/attack_surface_mesh.gd")
const FX := preload("res://scripts/combat_fx.gd")
const Targets := preload("res://scripts/targeting.gd")
const Telemetry := preload("res://scripts/combat_telemetry.gd")
const Flow := preload("res://scripts/game_flow.gd")
const Health := preload("res://scripts/health_util.gd")
const Destruction := preload("res://scripts/environment_destruction.gd")
const SlimeShader := preload("res://shaders/poison_slime.gdshader")
var radius := 0.0
var duration := 0.0
var tick_damage := 0.0
var tick_interval := 1.0
var hit_height := 0.0
var elapsed := 0.0
var source_info: Dictionary = {}
var _until_tick := 0.0
var _fade_duration := 0.0
var _revision := -1
var _surface: RefCounted
var _mesh: MeshInstance3D
var _material: ShaderMaterial


func configure(point: Vector3, values: Dictionary, info: Dictionary) -> void:
	radius = float(values.poison_radius)
	duration = float(values.poison_duration)
	tick_damage = float(values.poison_damage)
	tick_interval = float(values.poison_tick_interval)
	hit_height = float(values.poison_hit_height)
	_until_tick = tick_interval
	_fade_duration = minf(float(values.impact_fx_lifetime), duration)
	source_info = info.duplicate(true)
	source_info["attack"] = "爆囊有毒黏液"
	var ground := FX.sample_ground(self, point + Vector3.UP * 0.5, 32.0)
	if ground.is_empty() or duration <= 0.0 or radius <= 0.0:
		queue_free()
		return
	global_position = ground.position
	add_to_group("enemy_hazards")
	_mesh = MeshInstance3D.new()
	_mesh.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_material = ShaderMaterial.new()
	_material.shader = SlimeShader
	_material.set_shader_parameter("radius", radius)
	_mesh.material_override = _material
	add_child(_mesh)
	_rebuild()


func _rebuild() -> void:
	_surface = Surface.new()
	var outline := PackedVector2Array()
	for i in range(32):
		outline.append(Vector2.from_angle(TAU * float(i) / 32.0) * radius)
	var meshes: Dictionary = _surface.build(self, outline, {"kind": "circle", "radius": radius, "height": hit_height, "source_height": 0.2})
	_mesh.mesh = meshes.fill
	_revision = Destruction.geometry_revision


func _physics_process(delta: float) -> void:
	if not is_instance_valid(_mesh) or not Flow.is_playing():
		return
	elapsed += delta
	if elapsed >= duration:
		queue_free()
		return
	if _revision != Destruction.geometry_revision:
		_rebuild()
	_material.set_shader_parameter("age", elapsed)
	_material.set_shader_parameter("opacity", clampf((duration - elapsed) / maxf(_fade_duration, 0.001), 0.0, 1.0))
	_until_tick -= delta
	if _until_tick <= 0.0:
		# 顿帧不补发积压伤害，单次周期最多结算一次。
		_until_tick = tick_interval
		for actor: Node3D in Targets.living_players(self):
			if can_affect(actor):
				Telemetry.hurt_player(actor, tick_damage, global_position, 1.0, source_info)


func can_affect(actor: Node3D) -> bool:
	if not Health.is_alive(actor) or _surface == null or not _surface.allows(actor.global_position):
		return false
	var offset := actor.global_position - global_position
	if Vector2(offset.x, offset.z).length() > radius:
		return false
	var ground := FX.sample_ground(self, actor.global_position, hit_height + 0.5)
	if ground.is_empty() or actor.global_position.y - float(ground.position.y) > hit_height:
		return false
	# 同一可达地表且身体视线无墙；不能隔楼层或通过后来增加的掩体持续伤人。
	return absf(float(ground.position.y) - global_position.y) <= hit_height and preload("res://scripts/enemy_attack_area.gd").unobstructed(self, global_position + Vector3.UP * 0.2, actor.global_position)
