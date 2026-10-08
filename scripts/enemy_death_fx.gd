extends Node3D
## 敌人程序化死亡与毁灭视觉系统：本体Mesh真实散体飞溅（带燃烧与拖曳黑烟）、大型敌人倒地发黑崩解（带燃烧、黑烟柱与尸体存留）。
##
## 1. 散体爆裂（Disassembly）：
##    提取敌人本体真实的 MeshInstance3D 构件（胸甲、头盔、四肢、护甲片、武器等）真实向外炸开；
##    部分核心部件燃烧带火（橙红自发光与火星），并在空中拖着浓厚黑烟轨迹飞溅与翻滚弹跳；
## 2. 大型敌人崩解倒地（Collapse & Char）：
##    大型敌人与 Boss 倒地趴伏在地面（绝不沉入地下），尸体逐渐发黑碳化（Charring）；
##    胸腔核心处烈焰燃烧，向天际滚滚升起黑色烟尘巨柱；
##    尸体在战场上长时间存留（Boss 永久存留 / 大怪存留 28 秒），战果清晰可见；
## 3. 终结特写组合（Cinematic）：慢动作下的真实本体 Mesh 散体与核心殉爆。

const STYLE_DISASSEMBLY := 0
const STYLE_IMPACT_EXPLOSION := 1
const STYLE_CRUMBLE := 2
const STYLE_CINEMATIC := 3
const STYLE_COLLAPSE_DETACH := 4

const AudioUtil := preload("res://scripts/audio_manager.gd")
const TerrainFieldUtil := preload("res://scripts/terrain_field.gd")
const CombatFXUtil := preload("res://scripts/combat_fx.gd")

var _style := STYLE_DISASSEMBLY
var _elapsed := 0.0
var _is_cinematic := false
var _is_large := false
var _is_boss := false
var _overkill_scale: float = 1.0

# 散体飞溅碎片（来自敌人真实的 MeshInstance3D）
var _shards: Array[Dictionary] = []

# 身体构件脱节垮塌落地组件
var _collapse_pieces: Array[Dictionary] = []

# 大型敌人崩解碳化与存留组件
var _collapsed_model: Node3D = null
var _char_materials: Array[Dictionary] = []
var _corpse_smoke: CPUParticles3D = null
var _corpse_flames: CPUParticles3D = null
var _corpse_light: OmniLight3D = null

# 大型敌人两阶段倒地与垮塌状态
var _detached := false
var _detach_delay := 2.45
var _armor_color := Color.WHITE

# 大型敌人真实物理重力倾覆倒地过程状态
var _falling := false
var _fall_time := 0.0
var _fall_duration := 0.95
var _impact_triggered := false
var _fall_initial_model_quat := Quaternion.IDENTITY
var _fall_initial_model_pos := Vector3.ZERO
var _fall_target_model_quat := Quaternion.IDENTITY
var _fall_target_model_pos := Vector3.ZERO
var _fall_joint_initial: Dictionary = {}
var _fall_joint_target: Dictionary = {}
var _shockwave_boosted := false

# 倒地殉爆组件（用于特写与20%大型敌人倒地爆炸）
var _detonated := false
var _ground_scorched := false
var _shockwave: MeshInstance3D
var _shockwave_mat: StandardMaterial3D
var _blast_dome: MeshInstance3D
var _blast_dome_mat: StandardMaterial3D
var _blast_light: OmniLight3D
var _detonation_time := 0.20


func _enter_tree() -> void:
	add_to_group("enemy_death_fx")


func _ready() -> void:
	add_to_group("enemy_death_fx")


## 吹飞全场敌人散落碎片与大怪残骸（小核弹共鸣大爆发冲击波调用）
static func blow_away_debris(tree: SceneTree, epicenter: Vector3, radius: float, force: float) -> void:
	if tree == null:
		return
	for node in tree.get_nodes_in_group("enemy_death_fx"):
		if is_instance_valid(node) and node.has_method("apply_shockwave_impulse"):
			node.call("apply_shockwave_impulse", epicenter, radius, force)


static func spawn_large(
	parent: Node,
	enemy_model: Node3D,
	root_pos: Vector3,
	armor_color: Color,
	is_boss: bool = false,
	is_last_enemy: bool = false
) -> Node3D:
	var script := load("res://scripts/enemy_death_fx.gd") as GDScript
	var fx = script.new()
	fx.name = "EnemyDeathFX_Large"
	fx._is_large = true
	fx._is_boss = is_boss
	fx._is_cinematic = is_last_enemy
	fx._style = STYLE_COLLAPSE_DETACH
	fx.add_to_group("enemy_death_fx")
	parent.add_child(fx)
	if fx.is_inside_tree():
		fx.global_position = root_pos
	else:
		fx.position = root_pos
	fx._build_large_collapse(enemy_model, armor_color)
	return fx


static func spawn_small(
	parent: Node,
	enemy_model: Node3D,
	root_pos: Vector3,
	armor_color: Color,
	is_last_enemy: bool = false,
	overkill_scale: float = 1.0
) -> Node3D:
	var script := load("res://scripts/enemy_death_fx.gd") as GDScript
	var fx = script.new()
	fx.name = "EnemyDeathFX_Small"
	fx._is_large = false
	fx._is_boss = false
	fx._is_cinematic = is_last_enemy
	fx._style = STYLE_CINEMATIC if is_last_enemy else STYLE_DISASSEMBLY
	fx._overkill_scale = clampf(overkill_scale, 0.8, 2.5)
	fx.add_to_group("enemy_death_fx")
	parent.add_child(fx)
	if fx.is_inside_tree():
		fx.global_position = root_pos
	else:
		fx.position = root_pos
	fx._build_fx(enemy_model, armor_color)
	return fx


static func spawn(
	parent: Node,
	enemy_model: Node3D,
	root_pos: Vector3,
	armor_color: Color,
	style: int = -1,
	is_last_enemy: bool = false,
	is_large_enemy: bool = false,
	overkill_scale: float = 1.0
) -> Node3D:
	if is_large_enemy or style == STYLE_CRUMBLE or style == STYLE_COLLAPSE_DETACH:
		var is_boss: bool = (style == STYLE_CRUMBLE) or (is_instance_valid(enemy_model) and enemy_model.is_in_group("boss"))
		return spawn_large(parent, enemy_model, root_pos, armor_color, is_boss, is_last_enemy)
	return spawn_small(parent, enemy_model, root_pos, armor_color, is_last_enemy, overkill_scale)


func _build_fx(enemy_model: Node3D, armor_color: Color) -> void:
	_armor_color = armor_color
	if _style == STYLE_COLLAPSE_DETACH or _style == STYLE_CRUMBLE:
		_build_large_collapse(enemy_model, armor_color)
	elif _style == STYLE_IMPACT_EXPLOSION:
		_build_real_mesh_shards(enemy_model, armor_color, true)
		_build_impact_explosion_visuals(armor_color)
		_trigger_detonation()
	elif _style == STYLE_CINEMATIC:
		_build_real_mesh_shards(enemy_model, armor_color, false)
		_build_impact_explosion_visuals(armor_color)
	else:
		_build_real_mesh_shards(enemy_model, armor_color, false)
		AudioUtil.play_at("hit", global_position if is_inside_tree() else position, -2.0, 1.3)


## 提取敌人自身的全部 MeshInstance3D 构件进行真实散体飞溅（仅挑 1~2 个部件燃烧与拖曳黑烟）
func _mesh_parts(model: Node3D) -> Array[MeshInstance3D]:
	var meshes: Array[MeshInstance3D] = []
	if not is_instance_valid(model):
		return meshes
	if model is MeshInstance3D and model.visible and model.mesh != null:
		meshes.append(model as MeshInstance3D)
	for child in model.find_children("*", "MeshInstance3D", true, false):
		var mesh := child as MeshInstance3D
		if mesh.visible and mesh.mesh != null:
			meshes.append(mesh)
	return meshes


func _ground_surface(point: Vector3) -> Dictionary:
	# 碎片积分可能已略穿入平台；射线仍从死亡时的身体高度以上开始。
	var probe := point
	probe.y = maxf(probe.y, global_position.y if is_inside_tree() else position.y)
	var hit := CombatFXUtil.sample_ground(self, probe, 24.0)
	if not hit.is_empty():
		return hit
	return {"position": Vector3(point.x, TerrainFieldUtil.height_at(point.x, point.z), point.z),
		"normal": TerrainFieldUtil.normal_at(point.x, point.z)}


func _build_real_mesh_shards(enemy_model: Node3D, armor_color: Color, is_large_explosion: bool = false) -> void:
	var center := global_position + Vector3.UP * 0.95 if is_inside_tree() else position + Vector3.UP * 0.95
	var found_meshes := _mesh_parts(enemy_model)

	if not found_meshes.is_empty():
		# 随机挑选 1~2 个关键部件燃烧冒烟，绝不全员着火，避免遮挡视线
		var burning_indices: Array[int] = []
		var burn_count := 2 if _overkill_scale > 1.35 else (1 if randf() < 0.70 else 2)
		var candidates := range(found_meshes.size())
		candidates.shuffle()
		for i in range(mini(burn_count, candidates.size())):
			burning_indices.append(candidates[i])

		var idx := 0
		for src_mesh in found_meshes:
			var shard := MeshInstance3D.new()
			shard.mesh = src_mesh.mesh
			# 复制材质并重置残留受击闪白，杜绝定格高亮
			var mat: StandardMaterial3D = null
			if src_mesh.material_override is StandardMaterial3D:
				mat = (src_mesh.material_override as StandardMaterial3D).duplicate() as StandardMaterial3D
			else:
				mat = StandardMaterial3D.new()
			mat.emission_enabled = false
			mat.emission = Color.BLACK
			mat.emission_energy_multiplier = 0.0
			shard.material_override = mat
			shard.material_overlay = src_mesh.material_overlay
			shard.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
			add_child(shard)

			# 继承原有全局变换，从原部位爆散
			if is_inside_tree() and src_mesh.is_inside_tree():
				shard.global_transform = src_mesh.global_transform
			else:
				shard.transform = src_mesh.transform

			var shard_pos := shard.global_position if is_inside_tree() else shard.position
			var offset := shard_pos - center
			var outward_dir := Vector3(offset.x, 0.0, offset.z)
			if outward_dir.length_squared() > 0.01:
				outward_dir = outward_dir.normalized()
			else:
				var rand_angle := randf() * TAU
				outward_dir = Vector3(cos(rand_angle), 0.0, sin(rand_angle))

			# 过量击杀初速度与炸裂弧度加剧
			var out_force := (randf_range(5.5, 9.8) if is_large_explosion else randf_range(3.2, 6.5)) * _overkill_scale
			var up_force := (randf_range(4.5, 9.2) if is_large_explosion else randf_range(2.8, 6.2)) * _overkill_scale
			var vel := outward_dir * out_force + Vector3.UP * up_force
			var ang := Vector3(randf_range(-18.0, 18.0), randf_range(-18.0, 18.0), randf_range(-18.0, 18.0)) * _overkill_scale

			# 关键特性：仅挑选 1~2 个关键部件燃烧发光并拖曳黑烟
			var is_burning: bool = (idx in burning_indices)
			var smoke_node: CPUParticles3D = null
			var spark_node: CPUParticles3D = null

			if is_burning:
				mat.emission_enabled = true
				mat.emission = Color(1.0, 0.42, 0.08)
				mat.emission_energy_multiplier = 3.6

				# 拖曳黑烟粒子 (local_coords = false: 烟雾停留在世界空间轨迹上)
				smoke_node = CPUParticles3D.new()
				smoke_node.emitting = true
				smoke_node.amount = 8
				smoke_node.lifetime = 0.65
				smoke_node.local_coords = false
				smoke_node.gravity = Vector3(0.0, 1.5, 0.0)
				smoke_node.direction = Vector3.UP
				smoke_node.initial_velocity_min = 0.1
				smoke_node.initial_velocity_max = 0.4
				smoke_node.scale_amount_min = 0.14
				smoke_node.scale_amount_max = 0.38

				var s_mesh := SphereMesh.new()
				s_mesh.radius = 0.11
				s_mesh.height = 0.22
				var s_mat := StandardMaterial3D.new()
				s_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
				s_mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
				s_mat.albedo_color = Color(0.1, 0.1, 0.11, 0.45)
				s_mesh.material = s_mat
				smoke_node.mesh = s_mesh
				shard.add_child(smoke_node)

				# 飞溅火星
				spark_node = CPUParticles3D.new()
				spark_node.emitting = true
				spark_node.amount = 4
				spark_node.lifetime = 0.35
				spark_node.local_coords = false
				spark_node.gravity = Vector3(0.0, 0.5, 0.0)
				var sp_mesh := BoxMesh.new()
				sp_mesh.size = Vector3(0.04, 0.04, 0.04)
				var sp_mat := StandardMaterial3D.new()
				sp_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
				sp_mat.albedo_color = Color(1.0, 0.6, 0.1)
				sp_mesh.material = sp_mat
				spark_node.mesh = sp_mesh
				shard.add_child(spark_node)

			_shards.append({
				"node": shard,
				"vel": vel,
				"ang": ang,
				"landed": false,
				"burning": is_burning,
				"smoke": smoke_node,
				"spark": spark_node,
				"land_timer": 0.0,
			})
			idx += 1

		# 隐藏敌人原模型，完成真实“肢体散解”
		if is_instance_valid(enemy_model):
			enemy_model.visible = false
	else:
		_build_fallback_shards(armor_color)


## 兼容旧接口：大型敌人垮塌引导至大怪倒地
func _build_collapse_detach(enemy_model: Node3D, armor_color: Color) -> void:
	_build_large_collapse(enemy_model, armor_color)


## 两阶段死亡第二阶段：身体构件失去连接，就地垮塌脱节/次级殉爆散落（在地面停顿片刻后触发）
func _do_detach_components() -> void:
	if _detached:
		return
	_detached = true
	_falling = false

	var root_pos := global_position if is_inside_tree() else position
	var surface := _ground_surface(root_pos)
	var ground_y: float = surface.position.y
	var terrain_normal: Vector3 = surface.normal

	var blast_center := root_pos + Vector3.UP * 0.45
	if is_instance_valid(_collapsed_model):
		var ch := _collapsed_model.find_child("Chest", true, false)
		if ch and ch is Node3D:
			blast_center = (ch as Node3D).global_position if (ch as Node3D).is_inside_tree() else ((ch as Node3D).position + root_pos)
		else:
			blast_center = (_collapsed_model.global_position if _collapsed_model.is_inside_tree() else _collapsed_model.position) + Vector3.UP * 0.35

	# 核心次级殉爆：重击与爆炸轰鸣音效、地面冲击波尘土与火星
	AudioUtil.play_at("explosion", blast_center, -1.0, 1.05)
	AudioUtil.play_at("shockwave", blast_center, 0.0, 0.9)
	CombatFXUtil.spawn_impact(
		self,
		Vector3(blast_center.x, ground_y + 0.05, blast_center.z),
		terrain_normal,
		Color(1.0, 0.55, 0.15) if _is_boss else _armor_color,
		2.6 if _is_boss else 1.9
	)
	_trigger_detonation_at(blast_center)

	# 强化黑烟柱与烈焰中心
	if is_instance_valid(_corpse_smoke):
		if _corpse_smoke.is_inside_tree():
			_corpse_smoke.global_position = blast_center + Vector3.UP * 0.15
		else:
			_corpse_smoke.position = (blast_center + Vector3.UP * 0.15) - root_pos
		_corpse_smoke.emitting = true
	if is_instance_valid(_corpse_flames):
		if _corpse_flames.is_inside_tree():
			_corpse_flames.global_position = blast_center
		else:
			_corpse_flames.position = blast_center - root_pos
		_corpse_flames.emitting = true
	if is_instance_valid(_corpse_light):
		if _corpse_light.is_inside_tree():
			_corpse_light.global_position = blast_center + Vector3.UP * 0.25
		else:
			_corpse_light.position = (blast_center + Vector3.UP * 0.25) - root_pos
		_corpse_light.light_energy = 4.2

	var found_meshes := _mesh_parts(_collapsed_model)

	# Boss 专属：额外生成 4~6 块沉重合金装甲残骸碎块向外飞溅
	if _is_boss:
		var boss_plate_mat := StandardMaterial3D.new()
		boss_plate_mat.albedo_color = Color(0.24, 0.06, 0.28, 1.0)
		boss_plate_mat.roughness = 0.65
		boss_plate_mat.metallic = 0.5
		for p_idx in range(5):
			var plate := MeshInstance3D.new()
			var plate_box := BoxMesh.new()
			plate_box.size = Vector3(randf_range(0.4, 0.8), randf_range(0.15, 0.3), randf_range(0.4, 0.9))
			plate.mesh = plate_box
			plate.material_override = boss_plate_mat.duplicate()
			add_child(plate)
			var angle := (TAU / 5.0) * p_idx + randf_range(-0.3, 0.3)
			var p_out := Vector3(cos(angle), 0.0, sin(angle))
			plate.global_position = blast_center + p_out * randf_range(0.3, 0.7) + Vector3.UP * randf_range(0.1, 0.4)
			var p_vel := p_out * randf_range(2.4, 4.2) + Vector3.UP * randf_range(2.0, 3.8)
			var p_ang := Vector3(randf_range(-6.0, 6.0), randf_range(-6.0, 6.0), randf_range(-6.0, 6.0))
			_collapse_pieces.append({
				"node": plate,
				"vel": p_vel,
				"ang": p_ang,
				"landed": false,
				"bounce_count": 0,
				"mat": plate.material_override as StandardMaterial3D,
				"orig_color": boss_plate_mat.albedo_color,
				"orig_roughness": 0.65,
				"orig_metallic": 0.5,
				"burning": true,
				"smoke": null,
				"spark": null,
				"land_timer": 0.0
			})

	if not found_meshes.is_empty():
		# 挑选 1~2 个关键部件带有冒烟与微弱火星
		var burning_indices: Array[int] = []
		var burn_count := 1 if randf() < 0.65 else 2
		var candidates := range(found_meshes.size())
		candidates.shuffle()
		for i in range(mini(burn_count, candidates.size())):
			burning_indices.append(candidates[i])

		var idx := 0
		for src_mesh in found_meshes:
			var piece := MeshInstance3D.new()
			piece.mesh = src_mesh.mesh
			piece.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF

			var mat: StandardMaterial3D = null
			if src_mesh.material_override is StandardMaterial3D:
				mat = (src_mesh.material_override as StandardMaterial3D).duplicate() as StandardMaterial3D
			elif src_mesh.mesh and src_mesh.mesh.surface_get_material(0) is StandardMaterial3D:
				mat = (src_mesh.mesh.surface_get_material(0) as StandardMaterial3D).duplicate() as StandardMaterial3D
			else:
				mat = StandardMaterial3D.new()
				mat.albedo_color = _armor_color
			mat.emission_enabled = false
			mat.emission = Color.BLACK
			mat.emission_energy_multiplier = 0.0
			piece.material_override = mat
			add_child(piece)

			if is_inside_tree() and src_mesh.is_inside_tree():
				piece.global_transform = src_mesh.global_transform
			else:
				piece.transform = src_mesh.transform

			var piece_pos := piece.global_position if is_inside_tree() else piece.position
			var offset := piece_pos - blast_center
			var outward_dir := Vector3(offset.x, 0.0, offset.z)
			if outward_dir.length_squared() > 0.005:
				outward_dir = outward_dir.normalized()
			else:
				var rand_ang := randf() * TAU
				outward_dir = Vector3(cos(rand_ang), 0.0, sin(rand_ang))

			# 构件断开脱节飞散初速度（外扩 1.6~3.2 m/s，起跳 1.0~2.4 m/s）
			var is_peripheral := piece.name.contains("Head") or piece.name.contains("Helm") or piece.name.contains("Blade") or piece.name.contains("Gun") or piece.name.contains("Plate") or piece.name.contains("Shoulder") or piece.name.contains("Foot") or piece.name.contains("Elbow")
			var slide_speed := randf_range(1.6, 3.2) if is_peripheral else randf_range(0.8, 1.8)
			var upward_pop := randf_range(1.0, 2.2) if is_peripheral else randf_range(0.5, 1.3)
			var vel := outward_dir * slide_speed + Vector3.UP * upward_pop
			var ang := Vector3(randf_range(-5.0, 5.0), randf_range(-4.0, 4.0), randf_range(-5.0, 5.0))

			var is_burning: bool = (idx in burning_indices)
			var smoke_node: CPUParticles3D = null
			var spark_node: CPUParticles3D = null

			if is_burning:
				smoke_node = CPUParticles3D.new()
				smoke_node.emitting = true
				smoke_node.amount = 6
				smoke_node.lifetime = 1.0
				smoke_node.local_coords = false
				smoke_node.gravity = Vector3(0.0, 1.4, 0.0)
				smoke_node.direction = Vector3.UP
				smoke_node.initial_velocity_min = 0.1
				smoke_node.initial_velocity_max = 0.3
				smoke_node.scale_amount_min = 0.14
				smoke_node.scale_amount_max = 0.38
				var s_mesh := SphereMesh.new()
				s_mesh.radius = 0.12
				s_mesh.height = 0.24
				var s_mat := StandardMaterial3D.new()
				s_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
				s_mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
				s_mat.albedo_color = Color(0.09, 0.09, 0.1, 0.45)
				s_mesh.material = s_mat
				smoke_node.mesh = s_mesh
				piece.add_child(smoke_node)

			_collapse_pieces.append({
				"node": piece,
				"vel": vel,
				"ang": ang,
				"landed": false,
				"bounce_count": 0,
				"mat": mat,
				"orig_color": mat.albedo_color,
				"orig_roughness": mat.roughness,
				"orig_metallic": mat.metallic,
				"burning": is_burning,
				"smoke": smoke_node,
				"spark": spark_node,
				"land_timer": 0.0
			})
			idx += 1

		# 隐藏原模型
		if is_instance_valid(_collapsed_model):
			_collapsed_model.visible = false
	else:
		# 兜底：若未解析到网格，绝不隐藏模型，确保残骸永久可见
		if is_instance_valid(_collapsed_model):
			_collapsed_model.visible = true


## 大型敌人两阶段死亡：完整执行 Phase 1 倒地物理动画 + Phase 2 垮塌殉爆脱节
func _build_large_collapse(enemy_model: Node3D, armor_color: Color) -> void:
	if not is_instance_valid(enemy_model):
		return

	# 将敌人模型脱离原实体挂载到本特效节点下，确保实体被销毁后尸体依然在战场上存留
	_collapsed_model = enemy_model
	if _collapsed_model.is_inside_tree():
		_collapsed_model.reparent(self, true)
	_collapsed_model.visible = true

	var root_pos := global_position if is_inside_tree() else position
	var ground_y: float = _ground_surface(root_pos).position.y

	# 1. 记录初始直立姿态与骨骼局部变换
	_fall_initial_model_quat = _collapsed_model.quaternion
	_fall_initial_model_pos = _collapsed_model.position
	_fall_joint_initial.clear()
	_fall_joint_target.clear()
	for child in _collapsed_model.find_children("*", "Node3D", true, false):
		var n3d := child as Node3D
		if n3d:
			_fall_joint_initial[n3d] = {
				"quat": n3d.quaternion,
				"pos": n3d.position,
			}

	# 2. 计算最终倒地姿态与形状
	_randomize_corpse_pose(_collapsed_model, _is_boss, armor_color)

	# 3. 记录计算出的目标贴地倒地姿态
	_fall_target_model_quat = _collapsed_model.quaternion
	_fall_target_model_pos = _collapsed_model.position
	for n3d in _fall_joint_initial.keys():
		if is_instance_valid(n3d):
			_fall_joint_target[n3d] = {
				"quat": n3d.quaternion,
				"pos": n3d.position,
			}

	# 4. 立即恢复到直立姿势，开启程序化动态倒地与物理重力倾覆（Phase 1 启动）
	_collapsed_model.quaternion = _fall_initial_model_quat
	_collapsed_model.position = _fall_initial_model_pos
	for n3d in _fall_joint_initial.keys():
		if is_instance_valid(n3d):
			n3d.quaternion = _fall_joint_initial[n3d]["quat"]
			n3d.position = _fall_joint_initial[n3d]["pos"]

	_falling = true
	_fall_time = 0.0
	_fall_duration = 0.95
	_impact_triggered = false
	_detach_delay = 1.35

	# 提取所有 Mesh 材质，准备进行发黑碳化渐变 (Charring)
	for child in _collapsed_model.find_children("*", "MeshInstance3D", true, false):
		var m := child as MeshInstance3D
		if m and m.visible:
			var mat: StandardMaterial3D = null
			if m.material_override is StandardMaterial3D:
				mat = (m.material_override as StandardMaterial3D).duplicate() as StandardMaterial3D
			else:
				mat = StandardMaterial3D.new()
			# 重置任何残留的受击闪白自发光，杜绝高亮定格
			mat.emission_enabled = false
			mat.emission = Color.BLACK
			mat.emission_energy_multiplier = 0.0
			m.material_override = mat
			_char_materials.append({
				"mat": mat,
				"orig_color": mat.albedo_color,
				"orig_roughness": mat.roughness,
				"orig_metallic": mat.metallic,
			})

	# 尸体核心处烈焰发光
	_corpse_light = OmniLight3D.new()
	_corpse_light.light_color = Color(1.0, 0.45, 0.12)
	_corpse_light.light_energy = 0.0
	_corpse_light.omni_range = 6.5
	add_child(_corpse_light)
	if _corpse_light.is_inside_tree():
		_corpse_light.global_position = Vector3(root_pos.x, ground_y + 0.6, root_pos.z)
	else:
		_corpse_light.position = Vector3(0.0, (ground_y + 0.6) - root_pos.y, 0.0)

	# 尸体滚滚黑烟柱（向天际持续飘散）
	_corpse_smoke = CPUParticles3D.new()
	_corpse_smoke.emitting = false
	_corpse_smoke.amount = 26
	_corpse_smoke.lifetime = 2.4
	_corpse_smoke.local_coords = false
	_corpse_smoke.gravity = Vector3(0.0, 2.2, 0.0)
	_corpse_smoke.direction = Vector3.UP
	_corpse_smoke.initial_velocity_min = 0.2
	_corpse_smoke.initial_velocity_max = 0.8
	_corpse_smoke.scale_amount_min = 0.35
	_corpse_smoke.scale_amount_max = 0.95

	var c_smoke_mesh := SphereMesh.new()
	c_smoke_mesh.radius = 0.25
	c_smoke_mesh.height = 0.5
	var c_smoke_mat := StandardMaterial3D.new()
	c_smoke_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	c_smoke_mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	c_smoke_mat.albedo_color = Color(0.08, 0.08, 0.09, 0.75)
	c_smoke_mesh.material = c_smoke_mat
	_corpse_smoke.mesh = c_smoke_mesh
	add_child(_corpse_smoke)
	if _corpse_smoke.is_inside_tree():
		_corpse_smoke.global_position = Vector3(root_pos.x, ground_y + 0.4, root_pos.z)
	else:
		_corpse_smoke.position = Vector3(0.0, (ground_y + 0.4) - root_pos.y, 0.0)

	# 尸体燃烧火舌粒子
	_corpse_flames = CPUParticles3D.new()
	_corpse_flames.emitting = false
	_corpse_flames.amount = 14
	_corpse_flames.lifetime = 0.8
	_corpse_flames.gravity = Vector3(0.0, 1.5, 0.0)
	_corpse_flames.scale_amount_min = 0.15
	_corpse_flames.scale_amount_max = 0.38
	var fl_mesh := BoxMesh.new()
	fl_mesh.size = Vector3(0.12, 0.18, 0.12)
	var fl_mat := StandardMaterial3D.new()
	fl_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	fl_mat.albedo_color = Color(1.0, 0.5, 0.1)
	fl_mesh.material = fl_mat
	_corpse_flames.mesh = fl_mesh
	add_child(_corpse_flames)
	if _corpse_flames.is_inside_tree():
		_corpse_flames.global_position = Vector3(root_pos.x, ground_y + 0.35, root_pos.z)
	else:
		_corpse_flames.position = Vector3(0.0, (ground_y + 0.35) - root_pos.y, 0.0)

	# 预先构建次级殉爆视觉组件
	_build_impact_explosion_visuals(armor_color)



## 程序化随机化大型敌人与 Boss 的倒地姿态与形变，消除千篇一律的整齐倒地
func _randomize_corpse_pose(model: Node3D, is_boss_enemy: bool, armor_col: Color) -> void:
	if not is_instance_valid(model):
		return

	var root_pos := global_position if is_inside_tree() else position
	var surface := _ground_surface(root_pos)
	var ground_y: float = surface.position.y
	var terrain_normal: Vector3 = surface.normal

	if is_boss_enemy:
		# Boss 专属倒地随机形态：圆柱主轴必须完全水平平躺于地面，绝不以 45 度斜立
		var boss_archetype := randi() % 4
		var side := 1.0 if randf() > 0.5 else -1.0
		match boss_archetype:
			0: # 侧向躺卧（左侧或右侧完全平躺）
				model.rotation.z = side * deg_to_rad(randf_range(88.0, 92.0))
				model.rotation.x = deg_to_rad(randf_range(-6.0, 6.0))
				model.rotation.y = deg_to_rad(randf_range(-180.0, 180.0))
			1: # 仰天轰倒（完全平躺）
				model.rotation.x = -deg_to_rad(randf_range(88.0, 92.0))
				model.rotation.z = deg_to_rad(randf_range(-6.0, 6.0))
				model.rotation.y = deg_to_rad(randf_range(-180.0, 180.0))
			2: # 俯冲扑倒（完全平贴）
				model.rotation.x = deg_to_rad(randf_range(88.0, 92.0))
				model.rotation.z = deg_to_rad(randf_range(-6.0, 6.0))
				model.rotation.y = deg_to_rad(randf_range(-180.0, 180.0))
			3: # 侧前横卧
				model.rotation.z = side * deg_to_rad(randf_range(88.0, 92.0))
				model.rotation.x = deg_to_rad(randf_range(-8.0, 8.0))
				model.rotation.y = deg_to_rad(randf_range(-180.0, 180.0))

		# Boss 弱点核心或附着件受损错位
		var weak_core := model.find_child("WeakCore", true, false) as Node3D
		if weak_core:
			weak_core.position += Vector3(randf_range(-0.15, 0.15), randf_range(-0.1, 0.1), randf_range(-0.15, 0.15))
			weak_core.rotation += Vector3(randf_range(-0.4, 0.4), randf_range(-0.4, 0.4), randf_range(-0.4, 0.4))
	else:
		# 人形精英大怪（巨型近战/远程/破坏者）倒地姿势：
		# 遵循真实力学：躯干（胸腔与髋部）必须平实贴合地面，绝不可只靠脚后跟 45 度斜立！
		var archetype := randi() % 4
		var side_sign := 1.0 if randf() > 0.5 else -1.0

		var hips: Node3D = model.find_child("Hips", true, false) as Node3D
		var chest: Node3D = model.find_child("Chest", true, false) as Node3D
		var head: Node3D = model.find_child("Head", true, false) as Node3D
		var l_hip: Node3D = model.find_child("LeftHip", true, false) as Node3D
		var r_hip: Node3D = model.find_child("RightHip", true, false) as Node3D
		var l_knee: Node3D = model.find_child("Hips/LeftHip/Knee", true, false) as Node3D
		if not l_knee: l_knee = model.find_child("LeftKnee", true, false) as Node3D
		var r_knee: Node3D = model.find_child("Hips/RightHip/Knee", true, false) as Node3D
		if not r_knee: r_knee = model.find_child("RightKnee", true, false) as Node3D
		var l_foot: Node3D = model.find_child("Hips/LeftHip/Knee/Foot", true, false) as Node3D
		if not l_foot: l_foot = model.find_child("LeftFoot", true, false) as Node3D
		var r_foot: Node3D = model.find_child("Hips/RightHip/Knee/Foot", true, false) as Node3D
		if not r_foot: r_foot = model.find_child("RightFoot", true, false) as Node3D
		var l_shoulder: Node3D = model.find_child("LeftShoulder", true, false) as Node3D
		var r_shoulder: Node3D = model.find_child("RightShoulder", true, false) as Node3D
		var l_elbow: Node3D = model.find_child("Chest/LeftShoulder/Elbow", true, false) as Node3D
		if not l_elbow: l_elbow = model.find_child("LeftElbow", true, false) as Node3D
		var r_elbow: Node3D = model.find_child("Chest/RightShoulder/Elbow", true, false) as Node3D
		if not r_elbow: r_elbow = model.find_child("RightElbow", true, false) as Node3D

		# 脚踝关节必须自然瘫软放松，消除原本 90 度直立将身体如支架般顶在空中的“脚后跟踩地斜立”假象
		if l_foot:
			l_foot.rotation.x = randf_range(-0.5, 0.2)
		if r_foot:
			r_foot.rotation.x = randf_range(-0.5, 0.2)

		match archetype:
			0: # 姿态 0：侧身横倒卷曲（身体完全横卧贴地）
				model.rotation.z = side_sign * deg_to_rad(randf_range(86.0, 94.0))
				model.rotation.x = deg_to_rad(randf_range(-6.0, 6.0))
				model.rotation.y = deg_to_rad(randf_range(-180.0, 180.0))
				if chest:
					chest.rotation = Vector3(randf_range(-0.1, 0.15), randf_range(-0.2, 0.2), 0.0)
				if head:
					head.rotation = Vector3(randf_range(0.1, 0.3), randf_range(-0.4, 0.4), side_sign * randf_range(0.2, 0.4))
				var down_knee := l_knee if side_sign > 0 else r_knee
				var up_knee := r_knee if side_sign > 0 else l_knee
				if down_knee: down_knee.rotation.x = randf_range(1.1, 1.5)
				if up_knee: up_knee.rotation.x = randf_range(0.2, 0.5)
				if l_hip: l_hip.rotation.z = randf_range(-0.25, 0.25)
				if r_hip: r_hip.rotation.z = randf_range(-0.25, 0.25)
				if l_shoulder: l_shoulder.rotation = Vector3(randf_range(-0.3, 0.4), 0.0, randf_range(-0.4, 0.3))
				if r_shoulder: r_shoulder.rotation = Vector3(randf_range(-0.3, 0.4), 0.0, randf_range(-0.3, 0.4))

			1: # 姿态 1：仰面大字型重砸瘫倒（背部与后脑勺完全贴地）
				model.rotation.x = -deg_to_rad(randf_range(86.0, 94.0))
				model.rotation.z = deg_to_rad(randf_range(-6.0, 6.0))
				model.rotation.y = deg_to_rad(randf_range(-180.0, 180.0))
				if chest:
					chest.rotation = Vector3(randf_range(-0.15, 0.05), randf_range(-0.15, 0.15), 0.0)
				if head:
					head.rotation = Vector3(randf_range(-0.3, -0.1), randf_range(-0.35, 0.35), randf_range(-0.2, 0.2))
				if l_shoulder: l_shoulder.rotation = Vector3(randf_range(-0.2, 0.3), 0.0, randf_range(0.4, 0.8))
				if r_shoulder: r_shoulder.rotation = Vector3(randf_range(-0.2, 0.3), 0.0, randf_range(-0.8, -0.4))
				if l_hip: l_hip.rotation.z = randf_range(0.2, 0.5)
				if r_hip: r_hip.rotation.z = randf_range(-0.5, -0.2)
				if l_knee: l_knee.rotation.x = randf_range(0.1, 0.5)
				if r_knee: r_knee.rotation.x = randf_range(0.1, 0.5)

			2: # 姿态 2：前扑贴地趴伏（胸腹部完全贴地）
				model.rotation.x = deg_to_rad(randf_range(86.0, 94.0))
				model.rotation.z = deg_to_rad(randf_range(-6.0, 6.0))
				model.rotation.y = deg_to_rad(randf_range(-180.0, 180.0))
				if chest:
					chest.rotation = Vector3(randf_range(0.05, 0.2), 0.0, randf_range(-0.1, 0.1))
				if head:
					head.rotation = Vector3(randf_range(0.1, 0.3), side_sign * randf_range(0.5, 0.9), 0.0)
				if l_shoulder: l_shoulder.rotation = Vector3(randf_range(0.3, 0.7), 0.0, randf_range(0.2, 0.5))
				if r_shoulder: r_shoulder.rotation = Vector3(randf_range(0.3, 0.7), 0.0, randf_range(-0.5, -0.2))
				if l_knee: l_knee.rotation.x = randf_range(0.1, 0.35)
				if r_knee: r_knee.rotation.x = randf_range(0.1, 0.35)

			3: # 姿态 3：侧卷屈膝脱力瘫倒（身体与双膝自然侧蜷于地）
				model.rotation.z = -side_sign * deg_to_rad(randf_range(86.0, 94.0))
				model.rotation.x = deg_to_rad(randf_range(-8.0, 8.0))
				model.rotation.y = deg_to_rad(randf_range(-180.0, 180.0))
				if chest:
					chest.rotation = Vector3(randf_range(0.1, 0.25), 0.0, 0.0)
				if head:
					head.rotation = Vector3(randf_range(0.2, 0.4), randf_range(-0.3, 0.3), 0.0)
				if l_knee: l_knee.rotation.x = randf_range(1.2, 1.6)
				if r_knee: r_knee.rotation.x = randf_range(1.0, 1.5)
				if l_hip: l_hip.rotation.x = randf_range(-0.5, -0.9)
				if r_hip: r_hip.rotation.x = randf_range(-0.5, -0.9)

		# 掉落的近战刀刃/枪械随重力自然脱手倒伏在地面
		var weapon_pivot := model.find_child("WeaponPivot", true, false) as Node3D
		if weapon_pivot:
			weapon_pivot.rotation = Vector3(deg_to_rad(randf_range(75.0, 105.0)), randf_range(-0.5, 0.5), randf_range(-0.5, 0.5))
		var gun_pivot := model.find_child("GunPivot", true, false) as Node3D
		if gun_pivot:
			gun_pivot.rotation = Vector3(deg_to_rad(randf_range(75.0, 105.0)), randf_range(-0.8, 0.8), randf_range(-0.8, 0.8))

	# 坡度倾斜拟合：如果地表存在倾角，将尸体轻微朝向地形法线倾斜
	if terrain_normal.dot(Vector3.UP) < 0.985:
		var slope_axis := Vector3.UP.cross(terrain_normal).normalized()
		if not slope_axis.is_zero_approx():
			var slope_ang := Vector3.UP.angle_to(terrain_normal)
			model.rotate(slope_axis, slope_ang * 0.65)

	# 确保核心重心（胸腔、盆骨与髋部）实打实着陆于地面：
	# 收集躯干核心构件（Chest, Hips, Pelvis, Body, Head, Visual, WeakCore）
	# 注意：仅检索直属网格（recursive=false），绝不可递归到四肢与长刀武器，避免因刀尖/脚跟触地而将重心抬到半空！
	var torso_meshes: Array[MeshInstance3D] = []
	for part_name in ["Chest", "Hips", "Chest/Head", "Visual", "WeakCore", "Body", "Pelvis"]:
		var part_node := model.get_node_or_null(part_name)
		if not part_node:
			part_node = model.find_child(part_name, true, false)
		if part_node:
			for m in part_node.find_children("*", "MeshInstance3D", false, false):
				torso_meshes.append(m as MeshInstance3D)
			if part_node is MeshInstance3D:
				torso_meshes.append(part_node as MeshInstance3D)

	var lowest_torso_y := 99999.0
	for m in torso_meshes:
		if m and m.visible and m.mesh != null:
			var aabb := m.get_aabb()
			var xf := m.global_transform if m.is_inside_tree() else m.transform
			var corners := [
				xf * aabb.position,
				xf * (aabb.position + Vector3(aabb.size.x, 0, 0)),
				xf * (aabb.position + Vector3(0, 0, aabb.size.z)),
				xf * (aabb.position + Vector3(aabb.size.x, 0, aabb.size.z)),
				xf * (aabb.position + Vector3(0, aabb.size.y, 0)),
				xf * (aabb.position + aabb.size)
			]
			for pt in corners:
				if pt.y < lowest_torso_y:
					lowest_torso_y = pt.y

	# 首先将模型高度对齐到躯干核心贴地（躯干接触面距离地表 3cm）
	if lowest_torso_y < 9999.0:
		if model.is_inside_tree():
			model.global_position.y += (ground_y + 0.03) - lowest_torso_y
		else:
			model.position.y += (ground_y + 0.03) - lowest_torso_y
	else:
		if model.is_inside_tree():
			model.global_position.y = ground_y + 0.06
		else:
			model.position.y = ground_y + 0.06

	# 检查四肢或武器是否扎入地下过深；如果扎入过深，微调抬升（但最多允许抬升 0.08m，绝不允许因为长刀尖而把全身抬到半空）
	var lowest_overall_y := 99999.0
	for child in model.find_children("*", "MeshInstance3D", true, false):
		var m := child as MeshInstance3D
		if m and m.visible and m.mesh != null:
			var aabb := m.get_aabb()
			var xf := m.global_transform if m.is_inside_tree() else m.transform
			var corners := [
				xf * aabb.position,
				xf * (aabb.position + aabb.size),
				xf * (aabb.position + Vector3(aabb.size.x, 0, 0)),
				xf * (aabb.position + Vector3(0, 0, aabb.size.z))
			]
			for pt in corners:
				if pt.y < lowest_overall_y:
					lowest_overall_y = pt.y

	if lowest_overall_y < ground_y:
		var lift: float = minf(ground_y - lowest_overall_y, 0.08)
		if model.is_inside_tree():
			model.global_position.y += lift
		else:
			model.position.y += lift


func _build_fallback_shards(armor_color: Color) -> void:
	var shard_mat := StandardMaterial3D.new()
	shard_mat.albedo_color = armor_color
	for i in range(4):
		var mesh_inst := MeshInstance3D.new()
		var box := BoxMesh.new()
		box.size = Vector3(0.2, 0.2, 0.2)
		mesh_inst.mesh = box
		mesh_inst.material_override = shard_mat
		add_child(mesh_inst)
		var spread_angle := randf() * TAU
		var vel := Vector3(cos(spread_angle) * 3.0, 4.0, sin(spread_angle) * 3.0)
		_shards.append({
			"node": mesh_inst,
			"vel": vel,
			"ang": Vector3(randf_range(-8.0, 8.0), 0, 0),
			"landed": false,
			"burning": false,
			"land_timer": 0.0,
		})


func _build_impact_explosion_visuals(_armor_color: Color) -> void:
	# 冲击波环（TorusMesh）
	var torus := TorusMesh.new()
	torus.inner_radius = 0.82
	torus.outer_radius = 1.0
	torus.rings = 20
	torus.ring_segments = 10

	_shockwave = MeshInstance3D.new()
	_shockwave.mesh = torus
	# TorusMesh 的环面原本就在 XZ 平面；沿地表扩散，不竖起一圈。
	_shockwave.position.y = 0.08

	_shockwave_mat = StandardMaterial3D.new()
	_shockwave_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	_shockwave_mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	_shockwave_mat.blend_mode = BaseMaterial3D.BLEND_MODE_ADD
	_shockwave_mat.albedo_color = Color(1.0, 0.65, 0.2, 0.0)
	_shockwave.material_override = _shockwave_mat
	_shockwave.visible = false
	add_child(_shockwave)

	# 核心爆光穹顶（SphereMesh）—— 半透明收敛，不遮挡视线
	var sphere := SphereMesh.new()
	sphere.radius = 0.22
	sphere.height = 0.44
	_blast_dome = MeshInstance3D.new()
	_blast_dome.mesh = sphere
	_blast_dome.position.y = 0.45

	_blast_dome_mat = StandardMaterial3D.new()
	_blast_dome_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	_blast_dome_mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	_blast_dome_mat.blend_mode = BaseMaterial3D.BLEND_MODE_ADD
	_blast_dome_mat.albedo_color = Color(1.0, 0.85, 0.4, 0.0)
	_blast_dome.material_override = _blast_dome_mat
	_blast_dome.visible = false
	add_child(_blast_dome)

	_blast_light = OmniLight3D.new()
	_blast_light.light_color = Color(1.0, 0.7, 0.25)
	_blast_light.light_energy = 0.0
	_blast_light.omni_range = 5.5
	_blast_light.position.y = 0.6
	add_child(_blast_light)


func _process(delta: float) -> void:
	_elapsed += delta

	# 1. 更新飞溅的散体碎片物理轨迹与黑烟拖曳
	if not _shards.is_empty():
		_update_shards(delta)

	# 2. 构件断开失联垮塌：如果在第一阶段倒地，等待到时触发脱节；若已脱节，更新碎片物理与碳化
	if _style == STYLE_COLLAPSE_DETACH:
		if not _detached:
			_update_large_collapse(delta)
			if _elapsed >= _detach_delay:
				_do_detach_components()
		elif not _collapse_pieces.is_empty():
			_update_collapse_detach(delta)

	# 3. 大型敌人崩解碳化、发黑与燃烧
	if _style == STYLE_CRUMBLE or (_is_large and _is_boss):
		if not _detached:
			_update_large_collapse(delta)
			if _elapsed >= _detach_delay:
				_do_detach_components()
		elif not _collapse_pieces.is_empty():
			_update_collapse_detach(delta)

	# 4. 倒地爆炸触发与更新（特写与大型敌人次级殉爆）
	if (_style == STYLE_IMPACT_EXPLOSION or _is_cinematic) and not _detonated and _elapsed >= _detonation_time:
		_trigger_detonation()

	if _detonated:
		_update_detonation(delta)

	# 5. 生命周期管理：普通散体在 2.8s 内退场；大型敌人残骸/尸体存留 32 秒（Boss 永久存留）
	var max_duration: float = 2.8
	if _style == STYLE_CRUMBLE or _style == STYLE_COLLAPSE_DETACH or _is_large or _is_boss:
		max_duration = 9999.0 if _is_boss else 32.0

	if _elapsed >= max_duration:
		queue_free()


func _update_collapse_detach(delta: float) -> void:
	var gravity := 14.0
	for piece in _collapse_pieces:
		var node := piece["node"] as MeshInstance3D
		if not is_instance_valid(node):
			continue

		if piece["landed"]:
			piece["land_timer"] += delta
			if piece["land_timer"] > 20.0:
				if is_instance_valid(piece.get("smoke")):
					(piece["smoke"] as CPUParticles3D).emitting = false
				if is_instance_valid(piece.get("spark")):
					(piece["spark"] as CPUParticles3D).emitting = false
			continue

		var vel := piece["vel"] as Vector3
		vel.y -= gravity * delta
		piece["vel"] = vel

		if node.is_inside_tree():
			node.global_position += vel * delta
		else:
			node.position += vel * delta
		var ang := piece["ang"] as Vector3
		node.rotation += ang * delta

		# 地面碰撞与轻度弹跳平卧
		var world_pos: Vector3 = node.global_position if node.is_inside_tree() else node.position
		var ground_y: float = _ground_surface(world_pos).position.y
		if world_pos.y <= ground_y + 0.05:
			if node.is_inside_tree():
				node.global_position.y = ground_y + 0.05
			else:
				node.position.y = ground_y + 0.05

			if absf(vel.y) > 1.2 and int(piece["bounce_count"]) < 1:
				vel.y = -vel.y * 0.22
				vel.x *= 0.35
				vel.z *= 0.35
				piece["vel"] = vel
				piece["ang"] = ang * 0.35
				piece["bounce_count"] = int(piece["bounce_count"]) + 1
			else:
				piece["landed"] = true
				piece["vel"] = Vector3.ZERO
				piece["ang"] = Vector3.ZERO
				# 落地自然平伏
				if absf(node.rotation.x) < 0.6:
					node.rotation.x = deg_to_rad(randf_range(80.0, 100.0))

	# 随时间逐渐发黑碳化 (Charring)
	var char_t := clampf((_elapsed - _detach_delay) / 3.0, 0.0, 1.0)
	for piece in _collapse_pieces:
		var mat: StandardMaterial3D = piece["mat"]
		if mat:
			var orig_c: Color = piece["orig_color"]
			mat.albedo_color = orig_c.lerp(Color(0.06, 0.06, 0.07, 1.0), char_t)
			mat.roughness = lerpf(float(piece["orig_roughness"]), 0.95, char_t)
			mat.metallic = lerpf(float(piece["orig_metallic"]), 0.05, char_t)

	# 火光随风微晃
	if is_instance_valid(_corpse_light):
		_corpse_light.light_energy = (3.2 + sin(_elapsed * 16.0) * 0.75) * maxf(1.0 - _elapsed / 25.0, 0.2)

	# 20 秒后烈焰逐渐减弱熄灭，保留残烟与焦黑残骸
	if _elapsed > 20.0 and is_instance_valid(_corpse_flames):
		_corpse_flames.emitting = false


func _update_shards(delta: float) -> void:
	var gravity := 14.0
	for shard in _shards:
		var node := shard["node"] as MeshInstance3D
		if not is_instance_valid(node):
			continue
		if shard["landed"]:
			shard["land_timer"] += delta
			if shard["land_timer"] > 1.2:
				if is_instance_valid(shard.get("smoke")):
					(shard["smoke"] as CPUParticles3D).emitting = false
				if is_instance_valid(shard.get("spark")):
					(shard["spark"] as CPUParticles3D).emitting = false
				node.scale = node.scale.move_toward(Vector3.ZERO, delta * 0.55)
			continue

		var vel := shard["vel"] as Vector3
		vel.y -= gravity * delta
		shard["vel"] = vel

		node.position += vel * delta
		var ang := shard["ang"] as Vector3
		node.rotation += ang * delta

		# 地面碰撞与弹性反弹
		var world_pos: Vector3 = node.global_position if node.is_inside_tree() else node.position
		var ground_y: float = _ground_surface(world_pos).position.y
		if world_pos.y <= ground_y + 0.08:
			if node.is_inside_tree():
				node.global_position.y = ground_y + 0.08
			else:
				node.position.y = ground_y + 0.08
			if absf(vel.y) > 1.2:
				vel.y = -vel.y * 0.35
				vel.x *= 0.55
				vel.z *= 0.55
				shard["vel"] = vel
				shard["ang"] = ang * 0.5
			else:
				shard["landed"] = true
				shard["vel"] = Vector3.ZERO


func _update_large_collapse(delta: float) -> void:
	if _falling:
		_fall_time += delta
		var t := clampf(_fall_time / _fall_duration, 0.0, 1.0)

		# 第一阶段：致命受创与重心失衡 (0.0 <= t < 0.28)
		# 敌人中弹后身躯后仰/踉跄失衡，膝关节微屈，重心微沉
		if t < 0.28:
			var p_stagger := t / 0.28
			var buck_angle := sin(p_stagger * PI) * 0.14
			var sink_y := sin(p_stagger * PI) * 0.09
			if is_instance_valid(_collapsed_model):
				_collapsed_model.position = _fall_initial_model_pos - Vector3(0.0, sink_y, 0.0)
				_collapsed_model.quaternion = _fall_initial_model_quat.slerp(_fall_target_model_quat, buck_angle * 0.18)

		# 第二阶段：重力加速下坠倾覆 (0.28 <= t < 0.92)
		elif t < 0.92:
			var p_fall := (t - 0.28) / (0.92 - 0.28)
			# 符合真实物理重力加速度的非线性曲线（缓慢失衡 -> 加速重砸）
			var fall_curve := 0.04 + 0.96 * pow(p_fall, 2.2)
			if is_instance_valid(_collapsed_model):
				_collapsed_model.quaternion = _fall_initial_model_quat.slerp(_fall_target_model_quat, fall_curve)
				_collapsed_model.position = _fall_initial_model_pos.lerp(_fall_target_model_pos, fall_curve)

			for n3d in _fall_joint_initial.keys():
				if is_instance_valid(n3d) and _fall_joint_target.has(n3d):
					var init_q: Quaternion = _fall_joint_initial[n3d]["quat"]
					var targ_q: Quaternion = _fall_joint_target[n3d]["quat"]
					var init_p: Vector3 = _fall_joint_initial[n3d]["pos"]
					var targ_p: Vector3 = _fall_joint_target[n3d]["pos"]
					n3d.quaternion = init_q.slerp(targ_q, fall_curve)
					n3d.position = init_p.lerp(targ_p, fall_curve)

		# 第三阶段：重砸地面、尘土轰鸣与火焰引燃 (0.92 <= t <= 1.0)
		else:
			if not _impact_triggered:
				_impact_triggered = true
				var root_pos := global_position if is_inside_tree() else position
				var ground_y: float = _ground_surface(root_pos).position.y
				var terrain_normal: Vector3 = _ground_surface(root_pos).normal

				# 震耳欲聋的砸地重击音效与冲击波
				AudioUtil.play_at("hit", root_pos, 2.0, 0.65)
				AudioUtil.play_at("shockwave", root_pos, 0.0, 0.6)

				# 砸地冲击波尘土与火星
				CombatFXUtil.spawn_ground_burst(get_parent(), root_pos, 2.4 if _is_boss else 1.7)
				CombatFXUtil.spawn_impact(
					self,
					Vector3(root_pos.x, ground_y + 0.05, root_pos.z),
					terrain_normal,
					Color(1.0, 0.55, 0.15) if _is_boss else _armor_color,
					2.5 if _is_boss else 1.8
				)

				var player: Node = null
				if is_inside_tree() and get_tree() != null:
					player = get_tree().get_first_node_in_group("player")
				if player and player.has_method("apply_camera_shake"):
					player.call("apply_camera_shake", 0.24 if _is_boss else 0.16)

				var core_pos := root_pos + Vector3.UP * 0.35
				if is_instance_valid(_collapsed_model):
					var ch := _collapsed_model.find_child("Chest", true, false)
					if ch and ch is Node3D:
						core_pos = (ch as Node3D).global_position if (ch as Node3D).is_inside_tree() else ((ch as Node3D).position + root_pos)
					else:
						core_pos = (_collapsed_model.global_position if _collapsed_model.is_inside_tree() else _collapsed_model.position) + Vector3.UP * 0.35

				# 点燃残骸火焰与黑烟柱
				if is_instance_valid(_corpse_smoke):
					if _corpse_smoke.is_inside_tree():
						_corpse_smoke.global_position = core_pos + Vector3.UP * 0.15
					else:
						_corpse_smoke.position = (core_pos + Vector3.UP * 0.15) - root_pos
					_corpse_smoke.emitting = true
				if is_instance_valid(_corpse_flames):
					if _corpse_flames.is_inside_tree():
						_corpse_flames.global_position = core_pos
					else:
						_corpse_flames.position = core_pos - root_pos
					_corpse_flames.emitting = true
				if is_instance_valid(_corpse_light):
					if _corpse_light.is_inside_tree():
						_corpse_light.global_position = core_pos + Vector3.UP * 0.25
					else:
						_corpse_light.position = (core_pos + Vector3.UP * 0.25) - root_pos
					_corpse_light.light_energy = 3.6

			# 落地微弹性衰减回弹 (3cm 缓冲自然定格)
			var bounce_p := (t - 0.92) / 0.08
			var bounce_y := sin(bounce_p * PI) * 0.035
			if is_instance_valid(_collapsed_model):
				_collapsed_model.quaternion = _fall_target_model_quat
				_collapsed_model.position = _fall_target_model_pos + Vector3(0.0, bounce_y, 0.0)

		if t >= 1.0:
			_falling = false
			if is_instance_valid(_collapsed_model):
				_collapsed_model.quaternion = _fall_target_model_quat
				_collapsed_model.position = _fall_target_model_pos
			for n3d in _fall_joint_target.keys():
				if is_instance_valid(n3d):
					n3d.quaternion = _fall_joint_target[n3d]["quat"]
					n3d.position = _fall_joint_target[n3d]["pos"]

	# 随时间逐渐发黑碳化 (Charring)
	var char_t := clampf((_elapsed - _fall_duration * 0.8) / 2.2, 0.0, 1.0)
	for item in _char_materials:
		var mat: StandardMaterial3D = item["mat"]
		var orig_c: Color = item["orig_color"]
		mat.albedo_color = orig_c.lerp(Color(0.06, 0.06, 0.07, 1.0), char_t)
		mat.roughness = lerpf(float(item["orig_roughness"]), 0.95, char_t)
		mat.metallic = lerpf(float(item["orig_metallic"]), 0.05, char_t)

	# 火光随风微晃
	if is_instance_valid(_corpse_light) and _impact_triggered:
		_corpse_light.light_energy = (3.2 + sin(_elapsed * 16.0) * 0.75) * maxf(1.0 - _elapsed / 25.0, 0.25)

	# 20 秒后烈焰逐渐减弱熄灭，保留残烟与焦黑尸体
	if _elapsed > 20.0 and is_instance_valid(_corpse_flames):
		_corpse_flames.emitting = false


func _trigger_detonation() -> void:
	_trigger_detonation_at(global_position if is_inside_tree() else position)


func _trigger_detonation_at(pos: Vector3) -> void:
	_detonated = true
	_detonation_time = _elapsed
	var surface := _ground_surface(pos)
	var ground_y: float = surface.position.y
	var normal: Vector3 = surface.normal
	var my_pos := global_position if is_inside_tree() else position
	if is_instance_valid(_shockwave):
		if _shockwave.is_inside_tree():
			_shockwave.global_position = surface.position + normal * 0.08
			_shockwave.global_basis = Basis(Quaternion(Vector3.UP, normal))
		else:
			_shockwave.position = Vector3(pos.x, ground_y + 0.08, pos.z) - my_pos
		_shockwave.visible = true
		_shockwave.scale = Vector3(0.4, 0.3, 0.4)
	if is_instance_valid(_blast_dome):
		if _blast_dome.is_inside_tree():
			_blast_dome.global_position = Vector3(pos.x, ground_y + 0.35, pos.z)
		else:
			_blast_dome.position = Vector3(pos.x, ground_y + 0.35, pos.z) - my_pos
		_blast_dome.visible = true
		_blast_dome.scale = Vector3(0.3, 0.2, 0.3)
	if is_instance_valid(_blast_light):
		if _blast_light.is_inside_tree():
			_blast_light.global_position = Vector3(pos.x, ground_y + 0.6, pos.z)
		else:
			_blast_light.position = Vector3(pos.x, ground_y + 0.6, pos.z) - my_pos
		_blast_light.light_energy = 3.6
	AudioUtil.play_at("explosion", pos, -1.0, 1.05)
	var scene := get_parent()
	if scene:
		# 焦痕归场景所有，短命散体退场后仍能看到战斗留下的痕迹。
		CombatFXUtil.spawn_ground_burst(scene, surface.position, 2.6 if _is_boss else 1.7, not _ground_scorched)
		_ground_scorched = true

	var player: Node = null
	if is_inside_tree() and get_tree() != null:
		player = get_tree().get_first_node_in_group("player")
	if player and player.has_method("apply_camera_shake"):
		player.call("apply_camera_shake", 0.24 if (_is_cinematic or _is_boss) else 0.16)



func _update_detonation(_delta: float) -> void:
	var progress := clampf((_elapsed - _detonation_time) / 0.38, 0.0, 1.0)
	var ease_wave := ease(progress, 0.4)

	if is_instance_valid(_shockwave):
		var scale_r := lerpf(0.4, 2.2 if _is_cinematic else 1.7, ease_wave)
		_shockwave.scale = Vector3(scale_r, 0.3, scale_r)
		var alpha := (1.0 - progress) * 0.45
		_shockwave_mat.albedo_color = Color(1.0, 0.65, 0.2, alpha)

	if is_instance_valid(_blast_dome):
		var dome_r := lerpf(0.3, 1.3, ease_wave)
		_blast_dome.scale = Vector3(dome_r, dome_r * 0.7, dome_r)
		_blast_dome_mat.albedo_color = Color(1.0, 0.85, 0.4, (1.0 - progress) * 0.26)

	if is_instance_valid(_blast_light):
		_blast_light.light_energy = lerpf(3.6, 0.0, progress)
	if progress >= 1.0:
		if is_instance_valid(_shockwave):
			_shockwave.visible = false
		if is_instance_valid(_blast_dome):
			_blast_dome.visible = false


## 响应外部小核弹冲击波：将全部碎片构件以及第一阶段倒地大怪向外吹飞！
func apply_shockwave_impulse(epicenter: Vector3, radius: float, force: float) -> void:
	var root_pos := global_position if is_inside_tree() else position
	var dist_to_root := (root_pos - epicenter).length()
	if dist_to_root > radius * 1.35 and _shards.is_empty() and _collapse_pieces.is_empty() and not _falling:
		return

	# 1. 大型敌人两阶段死亡处理：
	var is_large_collapse := (_style == STYLE_COLLAPSE_DETACH or _style == STYLE_CRUMBLE or _is_large or _is_boss)
	if is_large_collapse:
		# 情况 A：大怪正处于第一阶段（正在直立失衡踉跄或重力下坠，尚未实打实着地）
		# 绝对禁止当场解体消失！而是施加冲击波重力后仰加速倒地击退物理反馈！
		if _falling or not _impact_triggered or _elapsed < _fall_duration:
			_apply_shockwave_to_falling_large(epicenter, radius, force)
			return

		# 情况 B：大怪已实打实砸在地面平躺，但尚未脱节（遭到后续共鸣冲击波时震散断开构件）
		elif not _detached:
			_do_detach_components()

	# 2. 吹飞所有散体碎片
	for shard in _shards:
		var node := shard["node"] as Node3D
		if not is_instance_valid(node):
			continue
		var shard_pos: Vector3 = node.global_position if node.is_inside_tree() else node.position
		var offset: Vector3 = shard_pos - epicenter
		var dist: float = offset.length()
		if dist <= radius:
			var factor := clampf(1.0 - (dist / radius) * 0.45, 0.4, 1.0)
			var horiz := Vector3(offset.x, 0.0, offset.z)
			if horiz.length_squared() > 0.01:
				horiz = horiz.normalized()
			else:
				var a := randf() * TAU
				horiz = Vector3(cos(a), 0.0, sin(a))
			var shard_force := clampf(force * 0.32, 4.0, 13.0)
			var blow_vel := horiz * (shard_force * factor * randf_range(0.9, 1.4)) + Vector3.UP * (shard_force * factor * randf_range(0.7, 1.3))
			shard["vel"] = blow_vel
			shard["ang"] = Vector3(randf_range(-15.0, 15.0), randf_range(-15.0, 15.0), randf_range(-15.0, 15.0))
			shard["landed"] = false
			shard["land_timer"] = 0.0
			if shard.get("burning") and is_instance_valid(shard.get("smoke")):
				(shard["smoke"] as CPUParticles3D).emitting = true

	# 3. 吹飞所有大怪垮塌构件（重型装甲构件，速度合理约束在 2~6 m/s，Boss 约束在 1.2~3.5 m/s，体现重金属质量感）
	for piece in _collapse_pieces:
		var node := piece["node"] as Node3D
		if not is_instance_valid(node):
			continue
		var piece_pos: Vector3 = node.global_position if node.is_inside_tree() else node.position
		var offset: Vector3 = piece_pos - epicenter
		var dist: float = offset.length()
		if dist <= radius:
			var factor := clampf(1.0 - (dist / radius) * 0.45, 0.35, 1.0)
			var horiz := Vector3(offset.x, 0.0, offset.z)
			if horiz.length_squared() > 0.01:
				horiz = horiz.normalized()
			else:
				var a := randf() * TAU
				horiz = Vector3(cos(a), 0.0, sin(a))
			var piece_force := clampf(force * 0.16, 2.2, 6.5)
			if _is_boss:
				piece_force = clampf(force * 0.08, 1.2, 3.2)
			var blow_vel := horiz * (piece_force * factor * randf_range(0.8, 1.3)) + Vector3.UP * (piece_force * factor * randf_range(0.4, 0.9))
			piece["vel"] = blow_vel
			piece["ang"] = Vector3(randf_range(-8.0, 8.0), randf_range(-8.0, 8.0), randf_range(-8.0, 8.0))
			piece["landed"] = false
			piece["land_timer"] = 0.0


## 冲击波击中第一阶段倒地中的大型敌人：施加背向冲击波的击退、仰面翻倒姿态重定向、与加速度倒地反馈
func _apply_shockwave_to_falling_large(epicenter: Vector3, radius: float, force: float) -> void:
	if not is_instance_valid(_collapsed_model):
		return

	var root_pos := global_position if is_inside_tree() else position
	var offset := root_pos - epicenter
	var dist := offset.length()
	if dist > radius * 1.25:
		return

	var factor := clampf(1.0 - (dist / radius) * 0.45, 0.35, 1.0)
	var horiz := Vector3(offset.x, 0.0, offset.z)
	if horiz.length_squared() > 0.01:
		horiz = horiz.normalized()
	else:
		horiz = -_collapsed_model.global_transform.basis.z.normalized() if is_instance_valid(_collapsed_model) and is_inside_tree() else -_collapsed_model.transform.basis.z.normalized()
		horiz.y = 0.0
		if horiz.length_squared() < 0.01:
			horiz = Vector3.BACK

	# 1. 击退位移：落点位置向冲击波外侧平移 0.9 ~ 2.2 米
	var knockback_dist := clampf(force * 0.05 * factor, 0.9, 2.2)
	var old_target_pos := _fall_target_model_pos
	_fall_target_model_pos += horiz * knockback_dist

	# 根据新落点处的地形高度微调 target_pos.y，确保实打实贴地
	var new_world_pos := root_pos + _fall_target_model_pos
	var new_ground_y: float = _ground_surface(new_world_pos).position.y
	var old_ground_y: float = _ground_surface(root_pos + old_target_pos).position.y
	_fall_target_model_pos.y += (new_ground_y - old_ground_y)

	# 初始失衡点也向外侧轻微位移
	_fall_initial_model_pos += horiz * (knockback_dist * 0.3)
	if is_instance_valid(_collapsed_model):
		_collapsed_model.position += horiz * (knockback_dist * 0.3)

	# 2. 仰天倒地姿态修正：被小核弹冲击波正面掀翻，身躯仰面轰然背向爆炸源倒地
	var right := horiz.cross(Vector3.UP).normalized()
	if right.length_squared() > 0.01:
		var basis_x := -right
		var basis_y := horiz
		var basis_z := -Vector3.UP
		var blast_basis := Basis(basis_x, basis_y, basis_z).orthonormalized()
		var blast_quat := blast_basis.get_rotation_quaternion()
		var noise_rot := Quaternion.from_euler(Vector3(
			deg_to_rad(randf_range(-6.0, 6.0)),
			deg_to_rad(randf_range(-8.0, 8.0)),
			deg_to_rad(randf_range(-6.0, 6.0))
		))
		_fall_target_model_quat = (blast_quat * noise_rot).normalized()

	# 关节目标微调：双臂受气浪冲击向两侧张开甩出
	var l_shoulder := _collapsed_model.find_child("LeftShoulder", true, false) as Node3D
	var r_shoulder := _collapsed_model.find_child("RightShoulder", true, false) as Node3D
	if l_shoulder and _fall_joint_target.has(l_shoulder):
		_fall_joint_target[l_shoulder]["quat"] = Quaternion.from_euler(Vector3(randf_range(-0.2, 0.3), 0.0, randf_range(0.4, 0.8)))
	if r_shoulder and _fall_joint_target.has(r_shoulder):
		_fall_joint_target[r_shoulder]["quat"] = Quaternion.from_euler(Vector3(randf_range(-0.2, 0.3), 0.0, randf_range(-0.8, -0.4)))

	# 3. 冲击波加速下坠：受强大气浪压制，失衡倒地时间缩短至 0.62 秒，加快重砸地面
	_fall_duration = clampf(_fall_duration * 0.68, 0.55, 0.72)
	_detach_delay = _fall_duration + 0.42
	_shockwave_boosted = true

	# 4. 躯干受击火星与沉重撞击音效
	var torso_pos := root_pos + Vector3.UP * 1.0
	CombatFXUtil.spawn_impact(self, torso_pos, -horiz, Color(1.0, 0.62, 0.2), 2.2)
	AudioUtil.play_at("hit", root_pos, 2.5, 0.68)


