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
@export var radius := 0.76
## 碰撞胶囊高度与脚底净空；运行时中心由 foot_clearance + body_height/2 推出。
@export var body_height := 1.6
@export var foot_clearance := 0.05
## 扫掠胶囊抬升：烘焙与运行时共用；0.76m 半径 / 40° 坡取 0.22。
@export var sweep_lift := 0.22
## 台阶探测距离与支撑下探距离（米）。
@export var step_probe := 0.6
@export var step_lookahead := 0.9
@export var support_reach := 2.2
## 人群分离：半径必须大于身体直径（0.76×2=1.52），强度是转向权重。
@export var separation_radius := 1.7
@export var separation_strength := 1.1


func allows_step(height_delta: float) -> bool:
	return ignore_terrain or absf(height_delta) <= step_height + 0.001
