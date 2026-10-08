extends NavigationRegion3D
## 运行时烘焙导航网格。
##
## 为什么必须运行时烘焙：地形是程序化生成的（terrain_field.gd 在 _ready() 里
## 才把网格建出来），编辑器里根本看不到实体几何，无法预先烘焙并保存进 .tscn。
##
## 源几何用【分组】收集，而不是塞成子节点：地形（Ground）、掩体（Cover）、
## 树木（Forest）在场景树里是三处平级节点，硬挪到 NavigationRegion3D 下面会
## 破坏它们互相之间的路径引用（field_cover 要查 Ground 的高度，etc.）。
## 所以它们各自把自己加进 "nav_source" 组，这里按组递归收集。
##
## 运行时只解析 StaticBody3D 的碰撞形状。以前解析 MeshInstance3D 会把已经上传
## 到显卡的顶点同步读回 CPU，Godot 会明确警告这是高成本阻塞；而本项目所有
## 可行走地形与实体掩体本来就有等价碰撞体，直接用它们更准确也更便宜。

const ConfigUtil := preload("res://scripts/game_config.gd")

const GROUP := "nav_source"
## 延迟若干帧再烘焙，等 Ground / Cover / Forest 把网格都建出来。
## 配置 navigation.bake_delay_frames —— 太小会烘出空网格（表现为敌人完全不动）。
var bake_delay_frames := 2

var _baked := false


func _ready() -> void:
	_build_mesh()
	# 世界导航地图默认 cell_size=0.25，而本项目网格按配置使用 0.3。
	# 两边栅格保持一致，避免导航服务器合并边界时采用不同精度。
	var nav_map := get_navigation_map()
	NavigationServer3D.map_set_cell_size(nav_map, navigation_mesh.cell_size)
	NavigationServer3D.map_set_cell_height(nav_map, navigation_mesh.cell_height)
	# 必须先连信号再发起烘焙，否则极快的烘焙会在连接之前就结束。
	bake_finished.connect(_on_bake_finished)
	bake_delay_frames = maxi(ConfigUtil.get_int("navigation.bake_delay_frames", 2), 0)
	for _frame in range(bake_delay_frames):
		await get_tree().process_frame
	# 同步烘焙（不用后台线程）。
	#
	# 原本用 bake_navigation_mesh(true) 是为了避免卡顿，但实测这条线程路径在
	# 反复重载脚本 / 长时间运行时可能卡住不返回（曾导致两个 headless 进程空转
	# 11 小时）。而卡顿其实是可以藏起来的：GameFlow 在主菜单里把场景树暂停了，
	# 这一两秒的烘焙正好发生在玩家还没点"开始游戏"的时候，完全看不见。
	#
	# 可靠性优先于这点可隐藏的开销。
	bake_navigation_mesh(false)


func _build_mesh() -> void:
	var mesh := NavigationMesh.new()
	# 以下六项来自 data/game_config.json 的 navigation 段。
	#
	# 【改之前必读】Godot 会把 agent_radius 吸附成 cell_size 的整数倍、把
	# agent_height 与 agent_max_climb 吸附成 cell_height 的整数倍。所以默认
	# 写的都是【已经对齐过的值】，与引擎实际生效值一致，也就不会有精度损失警告：
	#   半径 1.2  / 0.3  = 4 格，覆盖最大普通敌人 0.52 × 1.75 ≈ 0.91 米
	#   的碰撞半径，并给转角留出约 0.29 米余量。
	#   高度 1.8  / 0.25 = 7.2  → 向上取整 8 格 = 2.0
	#   攀爬 0.55 / 0.25 = 2.2  → 向下取整 2 格 = 0.5
	#
	# NavigationAgent3D.radius 仅用于局部避让，不会改变寻路通道宽度。
	mesh.agent_radius = maxf(ConfigUtil.get_float("navigation.agent_radius", 1.2), 0.05)
	mesh.agent_height = maxf(ConfigUtil.get_float("navigation.agent_height", 2.0), 0.05)
	mesh.agent_max_climb = maxf(ConfigUtil.get_float("navigation.agent_max_climb", 0.5), 0.0)
	# 45° 与 Godot 的默认可走坡度一致，因此"导航说能走"就等于"物理说能走"。
	mesh.agent_max_slope = clampf(
		ConfigUtil.get_float("navigation.agent_max_slope", 45.0), 1.0, 89.0
	)
	mesh.cell_size = maxf(ConfigUtil.get_float("navigation.cell_size", 0.3), 0.05)
	mesh.cell_height = maxf(ConfigUtil.get_float("navigation.cell_height", 0.25), 0.05)
	mesh.geometry_parsed_geometry_type = NavigationMesh.PARSED_GEOMETRY_STATIC_COLLIDERS
	mesh.geometry_source_geometry_mode = NavigationMesh.SOURCE_GEOMETRY_GROUPS_WITH_CHILDREN
	mesh.geometry_source_group_name = GROUP
	mesh.geometry_collision_mask = 1
	navigation_mesh = mesh


func _on_bake_finished() -> void:
	_baked = true
	print("[导航] 网格烘焙完成：%d 个多边形" % navigation_mesh.get_polygon_count())


## 烘焙是否已完成且真的产出了可行走面。
func is_baked() -> bool:
	if not _baked or navigation_mesh == null:
		return false
	return navigation_mesh.get_polygon_count() > 0


## 世界里最近的可导航点，供探针与调试用。
func sample_closest(point: Vector3) -> Vector3:
	return NavigationServer3D.map_get_closest_point(get_world_3d().navigation_map, point)
