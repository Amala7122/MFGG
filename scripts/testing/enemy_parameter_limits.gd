extends RefCounted
## 原schema范围作为建议；实验边界供界面、草稿、存储与真实实例共同校验。
const Layout := preload("res://scripts/testing/enemy_parameter_layout.gd")
const COUNTS := ["needle_count", "grenade_reserve_capacity", "grenade_reserve_start", "shield_grenade_hits", "crystal_sniper_hits", "offense_front_limit", "offense_rage_limit"]

static func apply(profile: String, schema: Dictionary) -> void:
	for group: Dictionary in schema.groups:
		for spec: Dictionary in group.fields:
			if spec.value is bool: continue
			var display := Layout.field(profile, spec, String(group.title))
			var unit := String(display.unit)
			var key := String(spec.key)
			var lower := float(spec.min)
			var upper := float(spec.max)
			spec["recommended_min"] = lower
			spec["recommended_max"] = upper
			spec["limit_kind"] = "bounded"
			spec["limit_reason"] = "专属参数的已登记约束"
			var ceiling := upper
			if key in COUNTS:
				spec["integer"] = true
				# 蜂的三枚晶针与固定可见插槽一一对应，其余为逻辑计数。
				ceiling = upper if key == "needle_count" else maxf(upper, 100.0)
				spec.limit_reason = "固定晶针插槽，必须为整数" if key == "needle_count" else "逻辑计数必须为整数；实验计数预算"
			elif String(spec.get("unit", "")) == "±比例":
				lower = 0.0
				ceiling = 0.99
				spec.limit_reason = "随机倍率为1±此值，必须保留正体型／正时长／正速度"
			elif key in ["windup_rise_ratio", "release_snap_ratio", "rage_health_ratio"]:
				lower = 0.001
				ceiling = 0.999
				spec.limit_reason = "阶段／触发占比必须介于0与1之间，避免零时段和无效阶段"
			elif key == "sac_deflate":
				spec.limit_reason = "囊体收缩会从缩放中相减，保留正几何的当前支持范围"
			elif key == "hit_flash_strength" or unit == "0–1" or (unit == "比例" and key not in ["crowd_sway_strength", "crowd_vertical_separation"]):
				lower = 0.0
				ceiling = 1.0
				spec.limit_reason = "颜色／透明度／减伤／群体占比的有效范围为0–1"
			elif key in ["attack_angle", "pounce_hit_angle", "sweep_angle"]:
				ceiling = 360.0 if key == "sweep_angle" else 180.0
				spec.limit_reason = "命中全角不超过360度，半角不超过180度"
			else:
				if unit == "米/秒":
					lower = 0.0
					ceiling = 1000.0
				elif unit in ["米/秒²", "1/秒", "/秒", "弧度/秒", "度/秒", "kg·米²/秒", "牛顿秒", "牛顿米秒"]:
					ceiling = 10000.0
				elif unit in ["米", "世界米", "模型米", "米×体型"]:
					ceiling = 1000.0
				elif unit in ["秒", "秒/枚"]:
					ceiling = 300.0
					# 真实弹道预计算按物理帧取样，不能不加预算循环数年。
					if key in ["pounce_max_time", "needle_travel_time", "projectile_flight_time"]: ceiling = 30.0
				elif unit in ["Hz", "次/秒", "周期/秒"]:
					ceiling = Layout.stored_number(key, 100.0)
				elif unit == "点":
					ceiling = 1000000000.0
				elif unit in ["倍", "权重", "kg", "千克"] or key in ["crowd_sway_strength", "crowd_vertical_separation", "repeat_penalty"]:
					ceiling = 100.0 if key != "body_size" else 20.0
				elif unit == "级":
					ceiling = 10000.0
				elif unit in ["度", "弧度"]:
					ceiling = 360.0 if unit == "度" else TAU
					if lower < 0.0: lower = -ceiling
				if ceiling > upper:
					spec.limit_kind = "experiment"
					spec.limit_reason = "实验数值预算，不代表玩法／推荐上限"
					if lower > 0.0: lower = minf(lower, 0.001)
			# 不缩窄既有合法方案；仅范围元数据变化，绝不改value。
			spec.min = minf(float(spec.min), lower)
			spec.max = maxf(upper, ceiling)
