class_name Telegraph
extends Node3D
## 地面与空间危险预警（Telegraph 系统）。
##
## 支持：
##   - LINE: 狙击红线 / 锁定射线（支持实时端点跟随与锁定闪烁）
##   - RIBBON: 冲锋路径 / 矩形杀伤带（带前向导引箭头）
##   - SECTOR: 扑击 / 扫击前方扇形范围（扇面几何体，准确匹配角度与半径）
##
## 生命周期：
##   WINDUP 阶段半透明提示 → LOCK 阶段高频闪烁并锁死方向 → 攻击触发后淡出移除

const TerrainFieldUtil := preload("res://scripts/terrain_field.gd")

enum Type { LINE, RIBBON, SECTOR }

var type: Type = Type.RIBBON
var duration: float = 1.0
var time_elapsed: float = 0.0
var size_param: Vector3 = Vector3(1, 1, 5) # Ribbon: width, 1, length. Sector: radius, angle_deg, 0
var base_color: Color = Color(1.0, 0.15, 0.15, 0.45)
var is_locked: bool = false

var mesh_instance: MeshInstance3D
var material: StandardMaterial3D
var _cancelling: bool = false


static func _resolve_parent(parent: Node) -> Node:
	if parent != null:
		return parent
	var tree := Engine.get_main_loop() as SceneTree
	if tree:
		if tree.current_scene:
			return tree.current_scene
		if tree.root:
			return tree.root
	return null


static func create_ribbon(parent: Node, local_transform: Transform3D, width: float, length: float, duration: float, color: Color = Color(1.0, 0.12, 0.12, 0.45)) -> Telegraph:
	var target_parent := _resolve_parent(parent)
	if target_parent == null:
		return null
	var t := Telegraph.new()
	t.type = Type.RIBBON
	t.duration = maxf(duration, 0.1)
	t.size_param = Vector3(width, 1.0, length)
	t.base_color = color
	target_parent.add_child(t)
	t.transform = local_transform
	var px := t.global_position.x if t.is_inside_tree() else t.position.x
	var pz := t.global_position.z if t.is_inside_tree() else t.position.z
	var ground_y := TerrainFieldUtil.height_at(px, pz)
	if t.is_inside_tree():
		t.global_position.y = ground_y + 0.04
	else:
		t.position.y = ground_y + 0.04
	return t


static func create_sector(parent: Node, local_transform: Transform3D, radius: float, angle_degrees: float, duration: float, color: Color = Color(1.0, 0.25, 0.1, 0.45)) -> Telegraph:
	var target_parent := _resolve_parent(parent)
	if target_parent == null:
		return null
	var t := Telegraph.new()
	t.type = Type.SECTOR
	t.duration = maxf(duration, 0.1)
	t.size_param = Vector3(radius, angle_degrees, 0.0)
	t.base_color = color
	target_parent.add_child(t)
	t.transform = local_transform
	var px := t.global_position.x if t.is_inside_tree() else t.position.x
	var pz := t.global_position.z if t.is_inside_tree() else t.position.z
	var ground_y := TerrainFieldUtil.height_at(px, pz)
	if t.is_inside_tree():
		t.global_position.y = ground_y + 0.04
	else:
		t.position.y = ground_y + 0.04
	return t


static func create_line(parent: Node, from_pos: Vector3, to_pos: Vector3, duration: float, color: Color = Color(1.0, 0.08, 0.08, 0.75)) -> Telegraph:
	var target_parent := _resolve_parent(parent)
	if target_parent == null:
		return null
	var t := Telegraph.new()
	t.type = Type.LINE
	t.duration = maxf(duration, 0.1)
	t.base_color = color
	target_parent.add_child(t)
	t.update_line(from_pos, to_pos)
	return t


func _ready() -> void:
	add_to_group("enemy_telegraphs")
	mesh_instance = MeshInstance3D.new()
	add_child(mesh_instance)

	material = StandardMaterial3D.new()
	material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	material.cull_mode = BaseMaterial3D.CULL_DISABLED
	material.no_depth_test = true
	material.render_priority = 10
	material.albedo_color = base_color
	material.emission_enabled = true
	material.emission = base_color
	material.emission_energy_multiplier = 1.8

	match type:
		Type.RIBBON:
			_build_ribbon_mesh()
		Type.LINE:
			_build_line_mesh(size_param.z if size_param.z > 0.1 else 20.0)
		Type.SECTOR:
			_build_sector_mesh(size_param.x, size_param.y)

	mesh_instance.material_override = material


## 实时更新射线端点（用于狙击手瞄准阶段跟踪玩家）
func update_line(from_pos: Vector3, to_pos: Vector3) -> void:
	global_position = from_pos
	var diff := to_pos - from_pos
	var length := diff.length()
	if length > 0.01:
		look_at(to_pos, Vector3.UP)
	size_param.z = length
	if mesh_instance != null:
		_build_line_mesh(length)


## 锁定方向：预警变亮、开始高频脉冲
func lock_in() -> void:
	is_locked = true
	if material != null:
		material.emission_energy_multiplier = 4.0


## 取消/打断预警
func cancel() -> void:
	if _cancelling:
		return
	_cancelling = true
	var tween := create_tween()
	if tween and material:
		tween.tween_property(material, "albedo_color:a", 0.0, 0.15)
		tween.tween_callback(queue_free)
	else:
		queue_free()


func _process(delta: float) -> void:
	if _cancelling:
		return
	if type == Type.RIBBON or type == Type.SECTOR:
		var px := global_position.x if is_inside_tree() else position.x
		var pz := global_position.z if is_inside_tree() else position.z
		var ground_y := TerrainFieldUtil.height_at(px, pz)
		if is_inside_tree():
			global_position.y = ground_y + 0.04
		else:
			position.y = ground_y + 0.04
	time_elapsed += delta
	var progress := clampf(time_elapsed / maxf(duration, 0.01), 0.0, 1.0)

	if material != null:
		if is_locked:
			# 锁定阶段高频脉冲
			var pulse := 0.65 + sin(time_elapsed * 24.0) * 0.35
			material.albedo_color.a = base_color.a * pulse * 1.5
			material.emission_energy_multiplier = 3.5 + pulse * 2.0
		else:
			# 常规蓄力阶段平稳发光
			var pulse := 0.85 + sin(time_elapsed * 8.0) * 0.15
			material.albedo_color.a = base_color.a * pulse

	if time_elapsed >= duration + 0.35:
		queue_free()


func _build_line_mesh(length: float) -> void:
	var box := BoxMesh.new()
	box.size = Vector3(0.04, 0.04, length)
	mesh_instance.mesh = box
	# Box 原点在中心，沿 -Z 延伸需要向 -Z 偏移半长
	mesh_instance.position = Vector3(0.0, 0.0, -length * 0.5)


func _build_ribbon_mesh() -> void:
	var width: float = size_param.x
	var length: float = size_param.z
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)

	var half_w := width * 0.5
	var step_size := 0.8
	var steps := maxi(ceili(length / step_size), 2)
	var dz := length / float(steps)

	st.set_color(base_color)

	# 跑道表面分段四边形网格，每个截面精确采样真实地形高度，完美贴合起伏斜坡
	for i in range(steps):
		var z0 := -float(i) * dz
		var z1 := -float(i + 1) * dz

		var p0_local := Vector3(-half_w, 0.0, z0)
		var p1_local := Vector3(half_w, 0.0, z0)
		var p2_local := Vector3(half_w, 0.0, z1)
		var p3_local := Vector3(-half_w, 0.0, z1)

		var p0_w := to_global(p0_local) if is_inside_tree() else p0_local + global_position
		var p1_w := to_global(p1_local) if is_inside_tree() else p1_local + global_position
		var p2_w := to_global(p2_local) if is_inside_tree() else p2_local + global_position
		var p3_w := to_global(p3_local) if is_inside_tree() else p3_local + global_position

		var base_y := global_position.y if is_inside_tree() else position.y
		p0_local.y = TerrainFieldUtil.height_at(p0_w.x, p0_w.z) - base_y + 0.05
		p1_local.y = TerrainFieldUtil.height_at(p1_w.x, p1_w.z) - base_y + 0.05
		p2_local.y = TerrainFieldUtil.height_at(p2_w.x, p2_w.z) - base_y + 0.05
		p3_local.y = TerrainFieldUtil.height_at(p3_w.x, p3_w.z) - base_y + 0.05

		st.add_vertex(p0_local)
		st.add_vertex(p1_local)
		st.add_vertex(p2_local)

		st.add_vertex(p0_local)
		st.add_vertex(p2_local)
		st.add_vertex(p3_local)

	# 跑道中段的前进箭头 (采样地形高度提升辨识度)
	var arrow_step := maxf(length / 3.0, 3.0)
	var z_cursor := -arrow_step * 0.5
	while z_cursor > -length + 1.0:
		var tip_local := Vector3(0.0, 0.0, z_cursor - 0.9)
		var left_local := Vector3(-half_w * 0.6, 0.0, z_cursor)
		var right_local := Vector3(half_w * 0.6, 0.0, z_cursor)

		var tip_w := to_global(tip_local) if is_inside_tree() else tip_local + global_position
		var left_w := to_global(left_local) if is_inside_tree() else left_local + global_position
		var right_w := to_global(right_local) if is_inside_tree() else right_local + global_position

		var base_y := global_position.y if is_inside_tree() else position.y
		tip_local.y = TerrainFieldUtil.height_at(tip_w.x, tip_w.z) - base_y + 0.07
		left_local.y = TerrainFieldUtil.height_at(left_w.x, left_w.z) - base_y + 0.07
		right_local.y = TerrainFieldUtil.height_at(right_w.x, right_w.z) - base_y + 0.07

		st.add_vertex(left_local)
		st.add_vertex(tip_local)
		st.add_vertex(right_local)
		z_cursor -= arrow_step

	mesh_instance.mesh = st.commit()


func _build_sector_mesh(radius: float, angle_degrees: float) -> void:
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)

	var half_angle_rad := deg_to_rad(angle_degrees * 0.5)
	var segments := maxi(roundi(angle_degrees / 5.0), 10)
	var rings := 3
	var dr := radius / float(rings)

	st.set_color(base_color)

	# 径向分层网格，精确贴合凹凸山地轮廓
	for r_idx in range(rings):
		var r0 := float(r_idx) * dr
		var r1 := float(r_idx + 1) * dr
		for i in range(segments):
			var a0 := lerpf(-half_angle_rad, half_angle_rad, float(i) / float(segments))
			var a1 := lerpf(-half_angle_rad, half_angle_rad, float(i + 1) / float(segments))

			var p0_local := Vector3(sin(a0) * r0, 0.0, -cos(a0) * r0)
			var p1_local := Vector3(sin(a1) * r0, 0.0, -cos(a1) * r0)
			var p2_local := Vector3(sin(a1) * r1, 0.0, -cos(a1) * r1)
			var p3_local := Vector3(sin(a0) * r1, 0.0, -cos(a0) * r1)

			var p0_w := to_global(p0_local) if is_inside_tree() else p0_local + global_position
			var p1_w := to_global(p1_local) if is_inside_tree() else p1_local + global_position
			var p2_w := to_global(p2_local) if is_inside_tree() else p2_local + global_position
			var p3_w := to_global(p3_local) if is_inside_tree() else p3_local + global_position

			var base_y := global_position.y if is_inside_tree() else position.y
			p0_local.y = TerrainFieldUtil.height_at(p0_w.x, p0_w.z) - base_y + 0.05
			p1_local.y = TerrainFieldUtil.height_at(p1_w.x, p1_w.z) - base_y + 0.05
			p2_local.y = TerrainFieldUtil.height_at(p2_w.x, p2_w.z) - base_y + 0.05
			p3_local.y = TerrainFieldUtil.height_at(p3_w.x, p3_w.z) - base_y + 0.05

			if r_idx == 0:
				st.add_vertex(p0_local)
				st.add_vertex(p2_local)
				st.add_vertex(p3_local)
			else:
				st.add_vertex(p0_local)
				st.add_vertex(p1_local)
				st.add_vertex(p2_local)

				st.add_vertex(p0_local)
				st.add_vertex(p2_local)
				st.add_vertex(p3_local)

	mesh_instance.mesh = st.commit()

