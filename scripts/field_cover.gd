extends Node3D
## 战场掩体：按射击走廊手工布点的可断视线陈设。
##
## 为什么必须手工布点，而不是像草地那样随机撒：
##   远程敌人开火前会做视线判定（can_attack_from_current_view），掩体的价值
##   完全取决于"能不能挡住那条射线"。随机撒出来的掩体挡不住任何有意义的
##   视线，只会变成绊脚的杂物。下表的每条石墙都对应一段被切断的射击走廊。
##
## 高度统一取 2.2~2.6 米：
##   - 低于 2.2 米挡不住站立姿态的相互视线，等于没有掩体；
##   - 高于 2.8 米会把战场切成迷宫，而敌人没有寻路（只会直线追击），
##     会被卡住 —— 这是这个项目里最容易踩的坑。
##
## 所有掩体都通过 TerrainField.height_at() 贴合地形，且会自动沉降 0.25 米
## 来吃掉缓坡上的接缝。

const TerrainFieldUtil := preload("res://scripts/terrain_field.gd")
const ArenaUtil := preload("res://scripts/arena.gd")
## 只用于多环岩石；建筑与墙体明确禁止再走自定义倒角。
const LowPolyMeshUtil := preload("res://scripts/lowpoly_mesh.gd")

## 直接落到地面的沉降量，用于遮盖缓坡接缝。
const SINK := 0.25

## [x, z, 宽, 高, 深, 绕Y旋转(度), 类型]
## 类型：0 = 石墙残段（挡视线）  1 = 木箱堆（半身掩护）  2 = 巨石（球体，可平滑绕行）
## 类型 2 只用前三个数值里的第一个当半径，其余忽略。
##
## 布点原则：切断"主路 → 湖岸""出生点 → 遗迹""东侧旷野"这三条长射界，
## 同时避开主路、湖面、遗迹、营地与 22 棵树的实际坐标。
##
## 【只在配置缺失时使用】—— 正常情况下掩体表由竞技场提供：精修过的竞技场
## 直接给显式坐标表，新竞技场则由 arena.gd 按 cover_layout 确定性生成。
const PIECES: Array = [
	# --- 西侧：把主路到湖岸的长射界切成三段 ---
	[-11.0, 4.0, 6.5, 2.5, 1.1, 25.0, 0],
	[-15.0, -8.0, 5.5, 2.4, 1.1, -35.0, 0],
	[-23.0, 6.0, 7.0, 2.6, 1.2, -18.0, 0],
	[-31.0, -6.0, 6.0, 2.4, 1.1, 30.0, 0],
	# --- 东侧 ---
	[11.0, -9.0, 5.0, 2.4, 1.1, 15.0, 0],
	[15.0, -22.0, 6.5, 2.6, 1.2, -20.0, 0],
	[19.0, 2.0, 5.0, 2.4, 1.1, -25.0, 0],
	[28.0, -10.0, 6.0, 2.5, 1.1, 10.0, 0],
	[40.0, -22.0, 6.0, 2.5, 1.1, 25.0, 0],
	[44.0, 22.0, 6.5, 2.5, 1.2, -15.0, 0],
	# --- 北侧（出生点附近）---
	[-8.0, 26.0, 5.5, 2.4, 1.1, 55.0, 0],
	[-22.0, 30.0, 6.0, 2.4, 1.1, 70.0, 0],
	[0.0, 43.0, 6.5, 2.5, 1.2, 5.0, 0],
	[26.0, 44.0, 7.0, 2.6, 1.2, -10.0, 0],
	[-38.0, 36.0, 6.0, 2.4, 1.1, 40.0, 0],
	# --- 半身掩护（木箱）---
	[-6.0, -26.0, 5.0, 2.2, 1.1, 20.0, 1],
	[22.0, -12.0, 2.2, 2.2, 2.2, 30.0, 1],
	[36.0, 2.0, 2.6, 1.6, 2.6, 0.0, 1],
	[-36.0, 6.0, 2.8, 1.8, 2.8, 0.0, 1],
	[-14.0, -30.0, 2.2, 2.0, 2.2, 45.0, 1],
	[16.0, -32.0, 2.6, 1.5, 2.6, 0.0, 1],
	[-27.0, -14.0, 2.8, 1.7, 2.8, 0.0, 1],
	# --- 巨石：接管原来 6 个无碰撞的 RockOutcrops ---
	[-14.0, 7.0, 1.8, 0.0, 0.0, 0.0, 2],
	[-17.0, 9.0, 1.1, 0.0, 0.0, 0.0, 2],
	[7.0, 30.0, 1.5, 0.0, 0.0, 0.0, 2],
	[42.0, 22.0, 2.2, 0.0, 0.0, 0.0, 2],
	[30.0, -12.0, 1.5, 0.0, 0.0, 0.0, 2],
	[-37.0, 17.0, 2.0, 0.0, 0.0, 0.0, 2],
]

var _materials: Dictionary = {}


func _ready() -> void:
	# 掩体是导航障碍：不登记的话敌人会直接穿过石墙。
	add_to_group("nav_source")
	# 【配色必须比地面亮一点点，但不能亮成主角】
	# 原先的石墙是 (0.49,0.47,0.4) —— 比地面草绿还亮，于是"厚重石构"在画面上
	# 读成了"发光的积木"，明度层级整个是反的。现在统一压到冷石色，只比地面
	# （各竞技场 ground_color，约 0.13~0.16）亮一档：既能靠明度差认出这是掩体，
	# 又不会把视觉焦点从地景轮廓上偷走。
	# 后面接【地图解耦】时，这三个颜色会随掩体一起迁进 data/game_config.json。
	_materials[0] = _make_material(Color(0.38, 0.39, 0.35, 1.0), 0.9)
	_materials[1] = _make_material(Color(0.25, 0.145, 0.07, 1.0), 0.95)
	_materials[2] = _make_material(Color(0.29, 0.30, 0.28, 1.0), 0.92)
	# 掩体表由竞技场提供：
	#   给了 cover 显式表  → 直接用（精修过的竞技场）
	#   给了 cover_layout → 按参数确定性生成
	#   两者都没有        → 回退到下面那张手工表（配置缺失时的兜底）
	# 注意用"键是否存在"而不是"结果是否为空"，否则空表会被误判成缺省。
	var arena := ArenaUtil.get_params()
	var layout: Array = []
	if arena.has("cover") or arena.has("cover_layout"):
		layout = ArenaUtil.generate_cover(arena)
	else:
		layout = PIECES
	for piece in layout:
		if int(piece[6]) == 2:
			_build_boulder(piece)
		else:
			_build_piece(piece)


func _build_piece(piece: Array) -> void:
	var kind := int(piece[6])
	var x := float(piece[0])
	var z := float(piece[1])
	var size := Vector3(float(piece[2]), float(piece[3]), float(piece[4]))

	var body := StaticBody3D.new()
	body.name = "Cover_%d_%d" % [roundi(x), roundi(z)]
	# 底面贴合地形，再整体下沉一点吃掉缓坡缝隙。
	body.position = Vector3(x, TerrainFieldUtil.height_at(x, z) + size.y * 0.5 - SINK, z)
	body.rotation.y = deg_to_rad(float(piece[5]))

	var mesh_instance := MeshInstance3D.new()
	# 掩体也走经过面序校验的公共倒角；薄墙按最短边取 10%，避免倒角吞掉主体。
	var bevel := minf(size.x, minf(size.y, size.z)) * 0.10
	var cover_mesh := LowPolyMeshUtil.chamfered_box(size, bevel)
	mesh_instance.mesh = cover_mesh
	mesh_instance.material_override = _materials.get(kind, _materials[0])
	body.add_child(mesh_instance)

	# 碰撞直接来自倒角后的凸网格，视觉切角和实际边界保持一致。
	var shape := cover_mesh.create_convex_shape(true, false)
	var collision := CollisionShape3D.new()
	collision.shape = shape
	body.add_child(collision)

	add_child(body)


## 巨石用球体网格 + 球体碰撞（而不是盒碰撞）：圆形剖面走起来是平滑绕行，
## 盒碰撞会让玩家撞上看不见的直角。
## 球心只抬到半径的 0.35 倍，看起来像从地里长出来的岩体。
func _build_boulder(piece: Array) -> void:
	var x := float(piece[0])
	var z := float(piece[1])
	var radius := float(piece[2])

	var body := StaticBody3D.new()
	body.name = "Boulder_%d_%d" % [roundi(x), roundi(z)]
	body.position = Vector3(x, TerrainFieldUtil.height_at(x, z) + radius * 0.35, z)

	var sphere := LowPolyMeshUtil.faceted_ellipsoid(radius, radius * 2.0, 14, 7, 0.16)
	var mesh_instance := MeshInstance3D.new()
	mesh_instance.mesh = sphere
	mesh_instance.material_override = _materials[2]
	body.add_child(mesh_instance)

	var shape := SphereShape3D.new()
	shape.radius = radius
	var collision := CollisionShape3D.new()
	collision.shape = shape
	body.add_child(collision)

	add_child(body)


func _make_material(color: Color, roughness: float) -> StandardMaterial3D:
	var material := StandardMaterial3D.new()
	material.albedo_color = color
	material.vertex_color_use_as_albedo = true
	material.vertex_color_is_srgb = true
	material.roughness = roughness
	return material
