class_name MovementProfile
extends Resource
## 单位移动能力。SurfaceGrid 只提供表面高度；能不能走由这里的参数决定。

@export var id := "mud_golem"
## 垂直单步可跨越高度。
@export var step_height := 0.7
## 连续坡最大坡度（度）；用于流场粗格判定。
@export var max_slope_deg := 40.0
## 完全无视地形：蜘蛛/攀爬类；流场不做高度约束，贴地高度直接取表面。
@export var ignore_terrain := false
@export var avoid_step := 1.0
@export var can_jump := false
@export var jump_height := 0.0
@export var can_fly := false
@export var radius := 0.42


func flow_edge_limit(cell_size: float) -> float:
	if ignore_terrain:
		return INF
	return maxf(step_height, tan(deg_to_rad(max_slope_deg)) * cell_size)


func allows_step(height_delta: float) -> bool:
	return ignore_terrain or absf(height_delta) <= step_height + 0.001
