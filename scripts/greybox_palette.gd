extends RefCounted
## 旧版功能配色的独立适配；不引用或修改正式游戏材质资源。
const GRID_SHADER := preload("res://shaders/prototype_grid.gdshader")
const PROJECTILE_RIM := preload("res://shaders/greybox_projectile_rim.gdshader")
var _mat_ground: ShaderMaterial
var _mat_obstacle: ShaderMaterial
var _mat_wood_props: ShaderMaterial
var _mat_road: ShaderMaterial
var _mat_road_stone: StandardMaterial3D
var _mat_tree_crown: StandardMaterial3D
var _mat_player_body: StandardMaterial3D
var _mat_player_armor: StandardMaterial3D
var _mat_player_head: StandardMaterial3D
var _mat_player_dark: StandardMaterial3D
var _mat_player_weapon: StandardMaterial3D
var _mat_player_sight: StandardMaterial3D
var _mat_enemy_body: StandardMaterial3D
var _mat_enemy_armor: StandardMaterial3D
var _mat_enemy_blade: StandardMaterial3D
var _mat_enemy_eye: StandardMaterial3D
var _mat_accent: StandardMaterial3D
var _mat_projectile_core: StandardMaterial3D
var _mat_projectile_rim: ShaderMaterial
var _mat_projectile_trail: StandardMaterial3D

func _init() -> void:
	_init_materials()

func _init_materials() -> void:
	# 1. 地表行走区原型材质 (中浅灰度量网格 + 1m/5m 刻度 + 交替微棋盘)
	_mat_ground = ShaderMaterial.new()
	_mat_ground.shader = GRID_SHADER
	_mat_ground.set_shader_parameter("u_base_color", Color(0.70, 0.72, 0.75))
	_mat_ground.set_shader_parameter("u_checker_color", Color(0.62, 0.64, 0.67))
	_mat_ground.set_shader_parameter("u_checker_strength", 0.22)
	_mat_ground.set_shader_parameter("u_line_color", Color(0.36, 0.38, 0.42))
	_mat_ground.set_shader_parameter("u_major_line_color", Color(0.18, 0.20, 0.24))
	_mat_ground.set_shader_parameter("u_grid_size", 1.0)
	_mat_ground.set_shader_parameter("u_major_grid_step", 5.0)
	_mat_ground.set_shader_parameter("u_line_width", 0.025)
	_mat_ground.set_shader_parameter("u_major_line_width", 0.055)
	_mat_ground.set_shader_parameter("u_roughness", 0.88)

	# 2. 障碍物 / 掩体 / 石墙原型材质 (较深石板灰网格，突出视线阻挡结构)
	_mat_obstacle = ShaderMaterial.new()
	_mat_obstacle.shader = GRID_SHADER
	_mat_obstacle.set_shader_parameter("u_base_color", Color(0.48, 0.50, 0.53))
	_mat_obstacle.set_shader_parameter("u_checker_color", Color(0.42, 0.44, 0.47))
	_mat_obstacle.set_shader_parameter("u_checker_strength", 0.16)
	_mat_obstacle.set_shader_parameter("u_line_color", Color(0.28, 0.30, 0.34))
	_mat_obstacle.set_shader_parameter("u_major_line_color", Color(0.14, 0.15, 0.18))
	_mat_obstacle.set_shader_parameter("u_grid_size", 1.0)
	_mat_obstacle.set_shader_parameter("u_major_grid_step", 5.0)
	_mat_obstacle.set_shader_parameter("u_line_width", 0.025)
	_mat_obstacle.set_shader_parameter("u_major_line_width", 0.055)
	_mat_obstacle.set_shader_parameter("u_roughness", 0.85)

	# 3. 木质陈设 / 箱子 / 树干原型材质 (偏暖陶土灰)
	_mat_wood_props = ShaderMaterial.new()
	_mat_wood_props.shader = GRID_SHADER
	_mat_wood_props.set_shader_parameter("u_base_color", Color(0.56, 0.53, 0.49))
	_mat_wood_props.set_shader_parameter("u_checker_color", Color(0.50, 0.47, 0.43))
	_mat_wood_props.set_shader_parameter("u_checker_strength", 0.16)
	_mat_wood_props.set_shader_parameter("u_line_color", Color(0.32, 0.30, 0.28))
	_mat_wood_props.set_shader_parameter("u_major_line_color", Color(0.18, 0.16, 0.15))
	_mat_wood_props.set_shader_parameter("u_grid_size", 1.0)
	_mat_wood_props.set_shader_parameter("u_major_grid_step", 5.0)
	_mat_wood_props.set_shader_parameter("u_roughness", 0.90)

	# 4. 道路复用同一世界网格与原点，只用较深底色区分；不改道路几何或碰撞。
	_mat_road = _mat_ground.duplicate() as ShaderMaterial
	_mat_road.set_shader_parameter("u_base_color", Color(0.52, 0.53, 0.55))
	_mat_road.set_shader_parameter("u_checker_color", Color(0.46, 0.47, 0.49))
	_mat_road.set_shader_parameter("u_roughness", 0.92)

	# 5. 路面嵌石 / 石板 / 台阶 (清晰的深灰石料质感)
	_mat_road_stone = StandardMaterial3D.new()
	_mat_road_stone.albedo_color = Color(0.38, 0.39, 0.41, 1.0)
	_mat_road_stone.roughness = 0.85

	# 6. 树冠体积遮蔽体 (半透微灰绿白模，标示遮挡体量同时保证视线通透)
	_mat_tree_crown = StandardMaterial3D.new()
	_mat_tree_crown.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	_mat_tree_crown.albedo_color = Color(0.52, 0.56, 0.53, 0.70)
	_mat_tree_crown.roughness = 0.92

	# 7. 玩家测试实体：人体解剖结构分级 (告别单一白块，展现清晰层级)
	_mat_player_body = StandardMaterial3D.new()
	_mat_player_body.albedo_color = Color(0.66, 0.70, 0.75, 1.0) # 躯干外套中灰
	_mat_player_body.roughness = 0.75

	_mat_player_armor = StandardMaterial3D.new()
	_mat_player_armor.albedo_color = Color(0.92, 0.94, 0.96, 1.0) # 胸甲/护肩/护膝浅亮灰板
	_mat_player_armor.roughness = 0.48

	_mat_player_head = StandardMaterial3D.new()
	_mat_player_head.albedo_color = Color(0.90, 0.86, 0.82, 1.0) # 头颈与面部柔和浅泥色
	_mat_player_head.roughness = 0.80

	_mat_player_dark = StandardMaterial3D.new()
	_mat_player_dark.albedo_color = Color(0.24, 0.26, 0.29, 1.0) # 发型、帽子、皮带、战术靴深炭黑
	_mat_player_dark.roughness = 0.85

	_mat_player_weapon = StandardMaterial3D.new()
	_mat_player_weapon.albedo_color = Color(0.18, 0.20, 0.23, 1.0) # 武器主体深枪铁色
	_mat_player_weapon.roughness = 0.45
	_mat_player_weapon.metallic = 0.4

	_mat_player_sight = StandardMaterial3D.new()
	_mat_player_sight.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	_mat_player_sight.albedo_color = Color(0.20, 0.88, 0.98, 1.0) # 瞄具青蓝高亮准星

	# 8. 敌人测试实体：战斗体态结构分级
	_mat_enemy_body = StandardMaterial3D.new()
	_mat_enemy_body.albedo_color = Color(0.92, 0.40, 0.16, 1.0) # 警示高亮橙红肉身
	_mat_enemy_body.roughness = 0.65

	_mat_enemy_armor = StandardMaterial3D.new()
	_mat_enemy_armor.albedo_color = Color(0.30, 0.32, 0.36, 1.0) # 暗铁盾牌与重甲
	_mat_enemy_armor.roughness = 0.55

	_mat_enemy_blade = StandardMaterial3D.new()
	_mat_enemy_blade.albedo_color = Color(0.80, 0.82, 0.86, 1.0) # 刀锋亮银
	_mat_enemy_blade.roughness = 0.30
	_mat_enemy_blade.metallic = 0.7

	_mat_enemy_eye = StandardMaterial3D.new()
	_mat_enemy_eye.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	_mat_enemy_eye.albedo_color = Color(1.0, 0.20, 0.08, 1.0) # 核心红光

	# 9. 关键交互物 / 神庙 / 战利品 (科技青蓝高亮)
	_mat_accent = StandardMaterial3D.new()
	_mat_accent.albedo_color = Color(0.20, 0.82, 0.92, 1.0)
	_mat_accent.roughness = 0.45

	# 灰模弹体：不发光的浅芯 / 深色细外缘 / 短尾，保留原网格与轨迹。
	_mat_projectile_core = StandardMaterial3D.new()
	_mat_projectile_core.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	_mat_projectile_core.albedo_color = Color(0.92, 0.92, 0.92)
	_mat_projectile_rim = ShaderMaterial.new()
	_mat_projectile_rim.shader = PROJECTILE_RIM
	_mat_projectile_trail = StandardMaterial3D.new()
	_mat_projectile_trail.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	_mat_projectile_trail.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	_mat_projectile_trail.albedo_color = Color(0.16, 0.16, 0.16, 0.55)

func configure(values: Dictionary) -> void:
	for material in [_mat_ground, _mat_obstacle, _mat_wood_props, _mat_road]:
		material.set_shader_parameter("u_grid_size", values.grid_size)
		material.set_shader_parameter("u_major_grid_step", values.major_grid_step)
		material.set_shader_parameter("u_line_width", values.line_width)
		material.set_shader_parameter("u_major_line_width", values.major_line_width)
		material.set_shader_parameter("u_checker_strength", values.checker_strength)
	_mat_ground.set_shader_parameter("u_base_color", _color(values.ground_color))
	_mat_ground.set_shader_parameter("u_checker_color", _color(values.ground_color).darkened(0.12))
	_mat_obstacle.set_shader_parameter("u_base_color", _color(values.obstacle_color))
	_mat_obstacle.set_shader_parameter("u_checker_color", _color(values.obstacle_color).darkened(0.12))
	_mat_enemy_body.albedo_color = _color(values.enemy_color)

func for_projectile(part: String) -> Material:
	if part == "aura": return _mat_projectile_rim
	if part == "trail": return _mat_projectile_trail
	return _mat_projectile_core

func sync_wisp(source: BaseMaterial3D, applied: BaseMaterial3D) -> void:
	# 原材质继续由卫士索敌 / 超频 / 开火更新；只在独立灰模副本上压缩明度。
	var color := source.albedo_color
	var luminance := color.r * 0.2126 + color.g * 0.7152 + color.b * 0.0722
	if source.emission_enabled:
		luminance = 0.55 + minf(source.emission_energy_multiplier, 15.0) * 0.02
	elif source.shading_mode == BaseMaterial3D.SHADING_MODE_UNSHADED:
		luminance = 0.35 + luminance * 0.25
	luminance = clampf(luminance, 0.10, 0.90)
	applied.albedo_color = Color(luminance,luminance,luminance,clampf(color.a,0.0,1.0))
	applied.emission_enabled = false
	applied.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED if source.emission_enabled else source.shading_mode
	applied.metallic = 0.0
	applied.roughness = 0.85

func _color(value: Array) -> Color:
	return Color(value[0],value[1],value[2],1.0)

func for_role(role: String, part: String) -> Material:
	if role == "player":
		if _matches(part, ["sight","visor"]): return _mat_player_sight
		if _matches(part, ["gun","barrel","rail","handguard","magazine","grip","stock","brake"]): return _mat_player_weapon
		if _matches(part, ["plate","guard","pad","bracer","badge","collar"]): return _mat_player_armor
		if _matches(part, ["hair","cap","boot","sole","toe","cuff","belt","pouch","strap","pack"]): return _mat_player_dark
		if _matches(part, ["head","face","neck","skull","jaw","ear"]): return _mat_player_head
		return _mat_player_body
	if role == "enemy":
		if _matches(part, ["eye","core"]): return _mat_enemy_eye
		if _matches(part, ["blade","sword","axe","spear","tip"]): return _mat_enemy_blade
		if _matches(part, ["armor","plate","helm","metal","shield"]): return _mat_enemy_armor
		return _mat_enemy_body
	match role:
		"ground": return _mat_ground
		"road": return _mat_road
		"paving": return _mat_road_stone
		"crown": return _mat_tree_crown
		"wood": return _mat_wood_props
		"accent": return _mat_accent
	return _mat_obstacle

func _matches(value: String, words: Array) -> bool:
	for word in words:
		if value.contains(word): return true
	return false

