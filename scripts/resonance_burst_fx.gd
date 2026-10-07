class_name ResonanceBurstFX
extends Node3D
## 毁灭脉冲（遗迹共鸣大爆发）专属宏大视觉特效。
##
## 包含五个层级的高级视觉表现：
## 1. 通天光柱（Sky Pillar）：穿透天际的 45 米高能虚空晶体光柱
## 2. 毁灭半球（Blast Dome）：向四周急剧扩散的半球型冲击护盾
## 3. 双重破裂环（Dual Torus）：地表高速推进的黄金与紫水晶同心冲击环
## 4. 爆裂遗迹晶片（Erupting Shards）：16 块向斜上方爆发飞溅的低多边形旋转发光碎片
## 5. 强光照与淡出销毁：自发光与动态全向光源驱动

const DURATION := 0.82
const CombatFXUtil := preload("res://scripts/combat_fx.gd")

var _radius := 20.0
var _elapsed := 0.0
var _finished := false

var _pillar: MeshInstance3D
var _pillar_mat: StandardMaterial3D
var _dome: MeshInstance3D
var _dome_mat: StandardMaterial3D
var _ring_outer: MeshInstance3D
var _ring_outer_mat: StandardMaterial3D
var _ring_inner: MeshInstance3D
var _ring_inner_mat: StandardMaterial3D
var _light: OmniLight3D

# 碎片结构：[{ node: MeshInstance3D, vel: Vector3, rot_speed: Vector3 }]
var _shards: Array[Dictionary] = []


static func spawn(parent: Node, pos: Vector3, radius: float, is_overload: bool = false) -> Node3D:
	var script: GDScript = load("res://scripts/resonance_burst_fx.gd")
	var fx: Node3D = script.new() as Node3D
	fx._radius = radius
	parent.add_child(fx)
	if fx.is_inside_tree():
		fx.global_position = pos
	else:
		fx.position = pos
	fx.setup_visuals(is_overload)
	CombatFXUtil.spawn_scorch_mark(parent, pos, radius * 0.65)
	return fx


func setup_visuals(is_overload: bool) -> void:
	var gold := Color(1.0, 0.78, 0.28, 1.0)
	var purple := Color(0.88, 0.32, 1.0, 1.0)
	var core_color := gold if not is_overload else Color(1.0, 0.35, 0.15, 1.0)

	# 1. 通天光柱 (Sky Pillar)
	var cyl := CylinderMesh.new()
	cyl.top_radius = 4.2
	cyl.bottom_radius = 5.6
	cyl.height = 46.0
	cyl.radial_segments = 24
	cyl.rings = 2

	_pillar_mat = StandardMaterial3D.new()
	_pillar_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	_pillar_mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	_pillar_mat.blend_mode = BaseMaterial3D.BLEND_MODE_ADD
	_pillar_mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	_pillar_mat.albedo_color = Color(core_color.r, core_color.g, core_color.b, 0.85)
	_pillar_mat.emission_enabled = true
	_pillar_mat.emission = core_color
	_pillar_mat.emission_energy_multiplier = 14.0
	cyl.material = _pillar_mat

	_pillar = MeshInstance3D.new()
	_pillar.mesh = cyl
	_pillar.position = Vector3(0.0, 23.0, 0.0)
	_pillar.scale = Vector3(0.3, 1.0, 0.3)
	add_child(_pillar)

	# 2. 毁灭能量半球 (Blast Dome)
	var sphere := SphereMesh.new()
	sphere.radius = 1.0
	sphere.height = 2.0
	sphere.radial_segments = 24
	sphere.rings = 16
	sphere.is_hemisphere = true

	_dome_mat = StandardMaterial3D.new()
	_dome_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	_dome_mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	_dome_mat.blend_mode = BaseMaterial3D.BLEND_MODE_ADD
	_dome_mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	_dome_mat.no_depth_test = true
	_dome_mat.render_priority = 10
	_dome_mat.albedo_color = Color(purple.r, purple.g, purple.b, 0.65)
	_dome_mat.emission_enabled = true
	_dome_mat.emission = purple
	_dome_mat.emission_energy_multiplier = 8.0
	sphere.material = _dome_mat

	_dome = MeshInstance3D.new()
	_dome.mesh = sphere
	_dome.position = Vector3(0.0, 0.04, 0.0)
	_dome.scale = Vector3.ONE * 0.5
	add_child(_dome)

	# 3. 外层黄金冲击波环 (Outer Ring)
	var torus_out := TorusMesh.new()
	torus_out.inner_radius = 0.88
	torus_out.outer_radius = 1.0
	torus_out.rings = 36
	torus_out.ring_segments = 6

	_ring_outer_mat = StandardMaterial3D.new()
	_ring_outer_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	_ring_outer_mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	_ring_outer_mat.blend_mode = BaseMaterial3D.BLEND_MODE_ADD
	_ring_outer_mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	_ring_outer_mat.no_depth_test = true
	_ring_outer_mat.render_priority = 12
	_ring_outer_mat.albedo_color = Color(gold.r, gold.g, gold.b, 0.95)
	_ring_outer_mat.emission_enabled = true
	_ring_outer_mat.emission = gold
	_ring_outer_mat.emission_energy_multiplier = 10.0
	torus_out.material = _ring_outer_mat

	_ring_outer = MeshInstance3D.new()
	_ring_outer.mesh = torus_out
	_ring_outer.position = Vector3(0.0, 0.06, 0.0)
	_ring_outer.scale = Vector3.ONE * 1.0
	add_child(_ring_outer)

	# 4. 内层紫晶碎裂环 (Inner Ring)
	var torus_in := TorusMesh.new()
	torus_in.inner_radius = 0.82
	torus_in.outer_radius = 1.0
	torus_in.rings = 32
	torus_in.ring_segments = 6

	_ring_inner_mat = StandardMaterial3D.new()
	_ring_inner_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	_ring_inner_mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	_ring_inner_mat.blend_mode = BaseMaterial3D.BLEND_MODE_ADD
	_ring_inner_mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	_ring_inner_mat.no_depth_test = true
	_ring_inner_mat.render_priority = 13
	_ring_inner_mat.albedo_color = Color(purple.r, purple.g, purple.b, 0.8)
	_ring_inner_mat.emission_enabled = true
	_ring_inner_mat.emission = purple
	_ring_inner_mat.emission_energy_multiplier = 8.0
	torus_in.material = _ring_inner_mat

	_ring_inner = MeshInstance3D.new()
	_ring_inner.mesh = torus_in
	_ring_inner.position = Vector3(0.0, 0.08, 0.0)
	_ring_inner.scale = Vector3.ONE * 0.8
	add_child(_ring_inner)

	# 5. 爆裂遗迹晶片 (16 块立体低多边形飞溅碎片)
	_build_shards(is_overload)

	# 6. 环境动态强光 (OmniLight3D)
	_light = OmniLight3D.new()
	_light.light_color = gold.lerp(purple, 0.3)
	_light.light_energy = 24.0 if not is_overload else 35.0
	_light.omni_range = _radius * 2.2
	_light.shadow_enabled = false
	_light.position = Vector3(0.0, 2.5, 0.0)
	add_child(_light)


func _build_shards(is_overload: bool) -> void:
	var count := 16 if not is_overload else 24
	var shard_mesh := BoxMesh.new()
	shard_mesh.size = Vector3(0.35, 0.7, 0.25)

	var shard_mat := StandardMaterial3D.new()
	shard_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	shard_mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	shard_mat.blend_mode = BaseMaterial3D.BLEND_MODE_ADD
	shard_mat.albedo_color = Color(1.0, 0.85, 0.45, 0.9)
	shard_mat.emission_enabled = true
	shard_mat.emission = Color(1.0, 0.7, 0.2, 1.0)
	shard_mat.emission_energy_multiplier = 8.0
	shard_mesh.material = shard_mat

	var rng := RandomNumberGenerator.new()
	rng.randomize()

	for i in count:
		var node := MeshInstance3D.new()
		node.mesh = shard_mesh
		var angle := rng.randf_range(0.0, TAU)
		var h_dir := Vector3(cos(angle), 0.0, sin(angle))
		var v_speed := rng.randf_range(7.0, 18.0)
		var h_speed := rng.randf_range(10.0, 25.0)
		var vel := h_dir * h_speed + Vector3.UP * v_speed
		node.position = Vector3.UP * 0.8 + h_dir * rng.randf_range(0.2, 1.2)
		node.scale = Vector3.ONE * rng.randf_range(0.7, 1.4)
		add_child(node)

		var rot_speed := Vector3(
			rng.randf_range(-12.0, 12.0),
			rng.randf_range(-15.0, 15.0),
			rng.randf_range(-12.0, 12.0)
		)
		_shards.append({ "node": node, "vel": vel, "rot_speed": rot_speed })


func _process(delta: float) -> void:
	if _finished:
		return

	_elapsed += delta
	var progress := _elapsed / DURATION
	if progress >= 1.0:
		_finished = true
		queue_free()
		return

	var fade := clampf(1.0 - progress, 0.0, 1.0)
	# 强动量缓动曲线
	var eased_blast := 1.0 - pow(1.0 - progress, 3.2)
	var eased_ring := 1.0 - pow(1.0 - progress, 2.5)

	# 1. 通天光柱：前 0.2 秒急剧变粗，之后向上方消散收束
	if _pillar:
		var pillar_scale_xz: float
		if progress < 0.25:
			pillar_scale_xz = lerpf(0.4, 1.3, progress / 0.25)
		else:
			pillar_scale_xz = lerpf(1.3, 0.1, (progress - 0.25) / 0.75)
		_pillar.scale.x = pillar_scale_xz
		_pillar.scale.z = pillar_scale_xz
		_pillar.position.y += delta * 18.0 # 向上腾飞
	if _pillar_mat:
		_pillar_mat.albedo_color.a = 0.85 * pow(fade, 1.6)
		_pillar_mat.emission_energy_multiplier = 14.0 * fade

	# 2. 毁灭半球：从中心膨胀至整个爆发半径
	if _dome:
		var dome_scale := lerpf(1.0, _radius, eased_blast)
		_dome.scale = Vector3(dome_scale, dome_scale * 0.75, dome_scale)
	if _dome_mat:
		_dome_mat.albedo_color.a = 0.65 * pow(fade, 1.8)
		_dome_mat.emission_energy_multiplier = 8.0 * fade

	# 3. 外层光环与内层光环
	if _ring_outer:
		_ring_outer.scale = Vector3.ONE * lerpf(1.5, _radius * 1.08, eased_ring)
	if _ring_outer_mat:
		_ring_outer_mat.albedo_color.a = 0.95 * fade
		_ring_outer_mat.emission_energy_multiplier = 10.0 * fade

	if _ring_inner:
		var inner_progress := clampf((_elapsed - 0.06) / (DURATION - 0.06), 0.0, 1.0)
		var inner_eased := 1.0 - pow(1.0 - inner_progress, 2.2)
		_ring_inner.scale = Vector3.ONE * lerpf(1.0, _radius * 0.82, inner_eased)
	if _ring_inner_mat:
		_ring_inner_mat.albedo_color.a = 0.8 * fade
		_ring_inner_mat.emission_energy_multiplier = 8.0 * fade

	# 4. 爆裂晶片物理运动
	for shard in _shards:
		var node := shard["node"] as MeshInstance3D
		if not is_instance_valid(node):
			continue
		var vel := shard["vel"] as Vector3
		node.position += vel * delta
		vel.y -= 25.0 * delta # 重力下坠
		shard["vel"] = vel

		var rot := shard["rot_speed"] as Vector3
		node.rotate_x(rot.x * delta)
		node.rotate_y(rot.y * delta)
		node.rotate_z(rot.z * delta)
		node.scale = Vector3.ONE * (fade * 1.1)

	# 5. 动态强光闪烁衰退
	if _light:
		_light.light_energy = (24.0 if _radius <= 22.0 else 35.0) * pow(fade, 2.0)

