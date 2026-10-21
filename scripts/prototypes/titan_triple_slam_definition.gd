extends RefCounted
## 三线重击的共享快照、几何与时序；正式施放与定格预览读取同一份定义。
static func snapshot(values: Dictionary, size: float, damage_scale := 1.0) -> Dictionary:
	return {"windup":float(values.triple_slam_windup), "recovery":float(values.triple_slam_recovery),
		"damage":float(values.triple_slam_damage)*damage_scale, "width":float(values.triple_slam_width)*size,
		"length":float(values.triple_slam_length)*size, "spread":float(values.triple_slam_spread), "height":4.1}

static func shapes(data: Dictionary, origin: Transform3D) -> Array[Dictionary]:
	var result: Array[Dictionary] = []
	for slot in [-1,0,1]:
		var pose := Transform3D(origin.basis.orthonormalized().rotated(Vector3.UP,-deg_to_rad(slot*float(data.spread))),origin.origin)
		result.append({"pose":pose,"spec":{"kind":"rect","offset":0.0,"width":float(data.width),
			"length":float(data.length),"height":float(data.height),"stable_tracking_surface":true,"solid_footprint":true}})
	return result

static func timing(data: Dictionary, elapsed: float) -> Dictionary:
	var windup: float = data.windup
	var recovery := clampf((elapsed-windup)/float(data.recovery),0.0,1.0)
	return {"struck":elapsed+0.00001 >= windup, "raise":clampf(elapsed/maxf(windup,.01),0.0,1.0),
		"progress":clampf(elapsed/windup,0.0,1.0), "recovery":recovery,
		"impulse":clampf(1.0-(elapsed-windup)/.18,0.0,1.0),
		"phase":"已结束" if recovery >= 1.0 else "后摇（判定已结束）" if elapsed+0.00001 >= windup else "锁定预警"}
