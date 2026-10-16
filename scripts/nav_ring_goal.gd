extends RefCounted
## 已退役（2026-10-12）：用户取消单环目标方向；活跃观察台和探针不再引用本模块。
## 保留源码供历史证据核对，不作为当前导航入口。
## 单环追击模型（唯一模型，无调节参数）。
##
## 环心 = 主角当前位置，随主角移动；半径固定 RING_RADIUS（直径 60 米）。
## 追击者的目标永远是**距离自己最近的环上点**：
##     G = C + normalize(P − C) · R
## 进圈由观察台处理（销毁重生），所以模型本身没有「进圈后追谁」的分支。
##
## 几何点不能直接当导航目标：它可能落在墙里、空中或导航面外。resolve() 按固定档位
## 绕自己那一侧微调，取第一个「这个身体真能站住」的点；全部不行才回落几何点并计数。
## 档位与阈值都是代码常量，不对外暴露，观察台也不提供旋钮。
##
## 可达性不在这里预验：规划器本来就要算整条路线，这里只保证目标点可站立
## （投影 + 真实支撑 + 完整身体脚印 + 落脚净空），避免把整段身体通道再算一遍。
const Query := preload("res://scripts/spatial_query.gd")
const ProjCache := preload("res://scripts/nav_projection_cache.gd")

## 环半径（米）。直径 60。
const RING_RADIUS := 30.0
## 偏转档位（度）：先正对自己，再左右对称展开，避免一上来就绕到背面。
const SWING_ANGLES := [0.0, 12.0, -12.0, 24.0, -24.0, 40.0, -40.0]
## 几何点投影到导航面的最大水平漂移（米）。超过说明这一点不在可行走面上。
const MAX_PROJECTION_DRIFT := 4.0
## 下探真实支撑的深度（米）。超出即视为没有支撑。
const SUPPORT_DEPTH := 1.2

## 观测计数（观察台与探针消费）。
static var resolved := 0
static var swung := 0
static var fallback := 0
static var last_swing := 0.0
static var last_reason := ""

static func reset_counters() -> void:
	resolved = 0
	swung = 0
	fallback = 0
	last_swing = 0.0
	last_reason = ""


## 档位：1 = 环外（用环上最近点），0 = 环内（观察台据此销毁重生）。
static func band_for(distance: float) -> int:
	return 1 if distance > RING_RADIUS else 0


## 距离 from 最近的环上点（水平面）。from 与 centre 重合时取 +X 方向。
static func nearest_point(centre: Vector3, from: Vector3, radius := RING_RADIUS) -> Vector3:
	var offset := from - centre
	offset.y = 0.0
	if offset.length() < 0.05:
		return centre + Vector3(radius, 0.0, 0.0)
	return centre + offset.normalized() * radius


## 解析这个身体能站住的环上目标。
## start：从第几个偏转档开始试。调用方在「停住一个窗口」后递增它来换候选角——
## 环上的点可能站得住却走不到（隔层 / 断层 / 孤岛），只验可站立不够。
## 返回 {"ok": bool, "point": Vector3, "swing": float, "reason": String}。
static func resolve(body: CharacterBody3D, map: RID, centre: Vector3, safe_drop: float,
		exclude: Array[RID] = [], start := 0) -> Dictionary:
	last_swing = 0.0
	if not is_instance_valid(body) or not map.is_valid():
		return _fail("no_body_or_map")
	if NavigationServer3D.map_get_iteration_id(map) == 0:
		return _fail("map_not_ready")
	var offset := body.global_position - centre
	offset.y = 0.0
	if offset.length() < 0.05:
		return _fail("on_centre")
	var base := offset.normalized()
	var count := SWING_ANGLES.size()
	for step in range(count):
		var angle: float = SWING_ANGLES[(start + step) % count]
		var direction := base.rotated(Vector3.UP, deg_to_rad(angle))
		var wanted := centre + direction * RING_RADIUS
		var point := _standable(body, map, wanted, exclude)
		if not point.is_zero_approx():
			last_swing = angle
			resolved += 1
			if not is_zero_approx(angle):
				swung += 1
			return {"ok": true, "point": point, "swing": angle, "reason": ""}
	return _fail("no_standable_ring_point")


static func _fail(reason: String) -> Dictionary:
	fallback += 1
	last_reason = reason
	return {"ok": false, "point": Vector3.ZERO, "swing": 0.0, "reason": reason}


## 这个候选点能不能站：投影到导航面 → 真实支撑 → 完整身体脚印 → 落脚净空。
## 投影走与 steering 层同一份共享缓存（同一个纯函数、同一个容差），
## 原来这里每个候选都直接调原生投影：约 98 µs/次 × 19 次/帧 ≈ 1.8 ms/帧。
static func _standable(body: CharacterBody3D, map: RID, wanted: Vector3, exclude: Array[RID]) -> Vector3:
	var projected := ProjCache.closest(map, wanted)
	if Vector2(projected.x - wanted.x, projected.z - wanted.z).length() > MAX_PROJECTION_DRIFT:
		return Vector3.ZERO
	var hit := Query.floor_at(body, projected, SUPPORT_DEPTH, exclude)
	if hit.is_empty():
		return Vector3.ZERO
	if not Query.full_support(body, hit, exclude):
		return Vector3.ZERO
	var pose := Query.ground_pose(body, hit, exclude)
	if not Query.landing_clear(body, pose):
		return Vector3.ZERO
	return pose
