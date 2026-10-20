extends RefCounted
## 统一显示语义；存储键与默认值仍来自原 schema。顺序也是新敌人的接入合同。
const TABS := ["基础属性", "移动与距离", "攻击技能", "受击反馈", "个体差异", "群体运动", "外形与表现", "专属参数"]
const COMMON := {
	"max_health": ["最大生命", "点", 0], "body_size": ["基础体型倍率", "倍", 0],
	"armor": ["护甲减伤", "比例", 0], "formation_width": ["排列占位宽度", "米", 0],
	"move_speed": ["移动速度", "米/秒", 1], "flight_speed": ["移动速度", "米/秒", 1],
	"turn_speed": ["转向角速度", "弧度/秒", 1], "acceleration": ["移动加速度", "米/秒²", 1],
	"gravity": ["重力加速度", "米/秒²", 1], "circle_speed": ["绕行速度", "米/秒", 1],
	"circle_inner_distance": ["绕行内圈距离", "米", 1], "circle_outer_distance": ["绕行外圈距离", "米", 1],
	"retreat_range": ["撤退触发距离", "米", 1], "retreat_exit_range": ["撤退结束距离", "米", 1],
	"retreat_speed": ["撤退速度", "米/秒", 1], "preferred_distance": ["偏好交战距离", "米", 1],
	"hover_altitude": ["悬停高度", "米", 1], "strafe_distance": ["绕行半径", "米", 1],
	"separation_radius": ["个体避让直径", "米", 5],
	"stagger_on_damage": ["普通受击打断动作", "", 3], "push_multiplier": ["击退响应倍率", "倍", 3],
	"push_decay": ["击退衰减", "米/秒²", 3], "damage_recoil_speed": ["受击后退速度", "米/秒", 3],
	"stagger_duration": ["受击硬直时长", "秒", 3], "stagger_hit_time": ["受击进入时长", "秒", 3],
	"stagger_in": ["受击进入时长", "秒", 3], "stagger_hold": ["受击停留时长", "秒", 3],
	"stagger_recovery": ["受击恢复时长", "秒", 3], "stagger_out": ["受击恢复时长", "秒", 3],
	"hit_flash_duration": ["受击闪白时长", "秒", 3], "hit_flash_strength": ["受击闪白强度", "倍", 3],
	"variation_enabled": ["启用个体差异", "", 4], "variation_speed": ["移动速度浮动", "比例", 4],
	"variation_damage": ["攻击伤害浮动", "比例", 4], "variation_size": ["体型浮动", "比例", 4],
	"variation_timing": ["技能时序浮动", "比例", 4], "variation_gait": ["步频浮动", "比例", 4],
	"variation_phase": ["随机初始动作相位", "", 4],
	"crowd_enabled": ["启用群体运动", "", 5], "crowd_start_delay": ["首次行动延迟上限", "秒", 5],
	"crowd_neighbor_radius": ["群体感知半径", "米", 5], "crowd_separation_weight": ["避让权重", "权重", 5],
	"crowd_alignment_weight": ["方向对齐权重", "权重", 5], "crowd_cohesion_weight": ["聚拢权重", "权重", 5],
	"crowd_flank_width": ["路径散开宽度", "米", 5], "crowd_flank_distance": ["路径散开生效距离", "米", 5],
	"crowd_sway_strength": ["路径摆动强度", "比例", 5], "crowd_sway_period": ["路径摆动周期", "秒", 5],
	"crowd_density_brake": ["拥挤减速强度", "比例", 5], "crowd_surge_strength": ["推进速度浮动", "比例", 5],
	"crowd_surge_period": ["推进速度周期", "秒", 5], "crowd_response": ["群体转向响应", "1/秒", 5],
	"crowd_speed_limit": ["群体速度上限倍率", "倍", 5], "crowd_attack_fraction": ["同时攻击比例", "比例", 5],
	"crowd_attack_radius": ["攻击协同半径", "米", 5], "crowd_wait_speed": ["等待攻击速度倍率", "倍", 5],
	"breath_rate": ["呼吸频率", "Hz", 6], "breath_amount": ["呼吸幅度", "米", 6],
	"gait_rate": ["步态频率", "Hz", 6], "walk_frequency": ["步态频率", "Hz", 6], "trot_frequency": ["步态频率", "Hz", 6],
	"stride": ["步幅", "米", 6], "foot_lift": ["抬脚高度", "米", 6],
	"walk_bob": ["身体起伏幅度", "米", 6], "trot_bob": ["身体起伏幅度", "米", 6],
	"debris_lifetime": ["碎片保留时长", "秒", 6], "debris_mass": ["碎片质量", "kg", 6],
	"corpse_lifetime": ["尸体保留时长", "秒", 6], "scatter_horizontal": ["碎片水平散射速度", "米/秒", 6],
	"scatter_up_min": ["碎片上抛速度下限", "米/秒", 6], "scatter_up_max": ["碎片上抛速度上限", "米/秒", 6],
	"scatter_torque": ["碎片旋转冲量", "kg·米²/秒", 6],
	"death_prepare": ["死亡预备时长", "秒", 6], "death_action": ["死亡动作时长", "秒", 6],
	"death_twitch_time": ["死亡抽动时长", "秒", 6], "death_hold": ["死亡定格时长", "秒", 6],
	"death_leg_fold": ["死亡收腿程度", "比例", 6], "death_leg_twitch": ["死亡抽腿幅度", "度", 6],
	"death_twitch_rate": ["死亡抽动频率", "Hz", 6], "death_wobble": ["死亡摇晃角度", "度", 6],
	"rock_r": ["岩甲颜色 R", "0–1", 6], "rock_g": ["岩甲颜色 G", "0–1", 6], "rock_b": ["岩甲颜色 B", "0–1", 6],
	"crystal_r": ["晶体颜色 R", "0–1", 6], "crystal_g": ["晶体颜色 G", "0–1", 6], "crystal_b": ["晶体颜色 B", "0–1", 6],
	"glow": ["晶体发光强度", "倍", 6], "brace_spread": ["技能支撑脚展开", "米", 6],
	"windup_rise_ratio": ["姿态蓄力爬升比例", "比例", 6], "release_snap_ratio": ["姿态释放爆发比例", "比例", 6],
	"leg_thickness": ["腿部半径", "米", 6],
	"charge_setback": ["技能蓄力后撤幅度", "米", 6],
}
# 同一技能槽位使用固定名称与顺序。起手冷却与结束冷却不能合并。
const SLOTS := {
	"enabled": ["启用技能", ""], "min_range": ["施放距离下限", "米"], "max_range": ["施放距离上限", "米"],
	"reach": ["命中延伸距离", "米"], "length": ["命中长度", "米"], "radius": ["命中半径", "米"],
	"width": ["命中宽度", "米"], "height": ["命中高度容差", "米"], "angle": ["命中扇形全角", "度"],
	"half_angle": ["命中扇形半角", "度"], "offset": ["横向偏移", "米"], "damage": ["单次伤害", "点"],
	"windup": ["前摇时长", "秒"], "active": ["生效动作时长", "秒"], "hold": ["命中后停留时长", "秒"],
	"recovery": ["后摇时长", "秒"], "reset": ["最终回位时长", "秒"],
	"cooldown_start": ["起手冷却", "秒"], "cooldown_end": ["结束冷却", "秒"],
	"cooldown_release": ["出手冷却", "秒"],
	"speed": ["攻击移动速度", "米/秒"], "speed_scale": ["攻击移动速度倍率", "倍"],
	"jump_speed": ["起跳速度", "米/秒"], "timeout": ["施放时长上限", "秒"],
	"flight": ["飞行时长", "秒"], "arc_height": ["弹道弧高", "米"], "lock": ["末段锁向时长", "秒"],
	"projectile_speed": ["弹体速度", "米/秒"], "projectile_radius": ["弹体显示半径", "米"],
	"lifetime": ["弹体寿命", "秒"], "duration": ["持续时长", "秒"], "tick": ["伤害间隔", "秒"],
}
const SKILLS := {
	"PrototypeMudGolem": [ ["挥拳", {"attack_damage":"damage", "attack_distance":"max_range", "attack_reach_extra":"reach", "attack_angle":"half_angle", "attack_windup":"windup", "attack_swing":"active", "attack_recovery":"recovery", "attack_interval":"cooldown_start"}] ],
	"PrototypeFastBeast": [ ["飞扑", {"attack_damage":"damage", "pounce_min_distance":"min_range", "pounce_max_distance":"max_range", "pounce_hit_radius":"radius", "pounce_hit_height":"height", "pounce_hit_angle":"half_angle", "pounce_windup":"windup", "landing_time":"hold", "pounce_recovery":"recovery", "attack_interval":"cooldown_start", "pounce_speed_multiplier":"speed_scale", "pounce_jump_speed":"jump_speed", "pounce_max_time":"timeout"}], ["跳跃普攻", {"normal_attack_damage":"damage", "normal_attack_reach":"max_range", "normal_attack_height":"height", "normal_jump_speed":"jump_speed", "normal_attack_interval":"cooldown_start"}] ],
	"PrototypeHornet": [ ["晶针射击", {"needle_damage":"damage", "needle_range":"max_range", "fire_windup":"windup", "fire_recovery":"recovery", "fire_interval":"cooldown_start", "needle_travel_time":"flight"}], ["俯冲撕咬", {"bite_damage":"damage", "dive_range":"max_range", "bite_radius":"radius", "dive_windup":"windup", "recovery_pose_time":"recovery", "recovery_wait":"reset", "dive_interval":"cooldown_start", "dive_speed":"speed", "dive_max_time":"timeout"}] ],
	"PrototypeSedimentTitan": [ ["直线砸地", {"slam_damage":"damage", "slam_distance":"length", "slam_width":"width", "slam_offset":"offset", "slam_windup":"windup", "slam_swing":"active", "slam_hold":"hold", "slam_recovery":"recovery", "slam_cooldown":"cooldown_end"}], ["横扫", {"sweep_damage":"damage", "sweep_distance":"radius", "sweep_angle":"angle", "sweep_windup":"windup", "sweep_swing":"active", "sweep_recovery":"recovery", "sweep_cooldown":"cooldown_end"}], ["远距震拳", {"thrust_enabled":"enabled", "thrust_damage":"damage", "thrust_distance":"length", "thrust_width":"width", "thrust_windup":"windup", "thrust_swing":"active", "thrust_recovery":"recovery", "thrust_cooldown":"cooldown_end"}], ["跃击", {"leap_enabled":"enabled", "leap_damage":"damage", "leap_min_distance":"min_range", "leap_max_distance":"max_range", "leap_radius":"radius", "leap_windup":"windup", "leap_landing_hold":"hold", "leap_recovery":"recovery", "leap_cooldown":"cooldown_end", "leap_travel_speed":"speed", "leap_arc_height":"arc_height"}], ["三线重击", {"triple_slam_damage":"damage", "triple_slam_length":"length", "triple_slam_width":"width", "triple_slam_windup":"windup", "triple_slam_recovery":"recovery", "triple_slam_cooldown":"cooldown_end"}], ["跳跃普攻", {"normal_attack_damage":"damage", "normal_attack_reach":"max_range", "normal_attack_height":"height", "normal_jump_speed":"jump_speed", "normal_attack_interval":"cooldown_start"}], ["泥浆护盾", {"mud_shield_enabled":"enabled", "mud_shield_windup":"windup", "mud_shield_cast":"active", "mud_shield_recovery":"recovery", "mud_shield_duration":"duration"}] ],
	"VisualBurstCrawler": [ ["转身投囊", {"attack_damage":"damage", "attack_range":"max_range", "blast_radius":"radius", "blast_height":"height", "turn_duration":"windup", "release":"active", "recovery":"recovery", "windup":"reset", "attack_interval":"cooldown_end", "projectile_flight_time":"flight", "projectile_radius":"projectile_radius", "projectile_lifetime":"lifetime"}], ["落地黏液", {"poison_radius":"radius", "poison_hit_height":"height", "poison_damage":"damage", "poison_duration":"duration", "poison_tick_interval":"tick"}] ],
	"VisualPrismSpider": [ ["锁向狙击", {"attack_damage":"damage", "attack_range":"max_range", "windup":"windup", "release":"active", "recovery":"recovery", "attack_interval":"cooldown_start", "aim_lock_time":"lock", "projectile_speed":"projectile_speed", "projectile_radius":"projectile_radius", "projectile_lifetime":"lifetime"}] ],
	"VisualChargeBeetle": [ ["锁向冲锋", {"attack_damage":"damage", "charge_min_range":"min_range", "attack_range":"max_range", "charge_distance":"length", "charge_hit_height":"height", "charge_front_reach":"reach", "windup":"windup", "release":"active", "recovery":"recovery", "attack_interval":"cooldown_end", "charge_speed":"speed", "charge_timeout":"timeout", "aim_lock_time":"lock"}], ["近身顶撞", {"contact_damage":"damage", "contact_range":"max_range", "contact_windup":"windup"}] ],
}
# 已在技能 spec 中乘过体型的值不再改；仅转换世界空间读取路径。
const WORLD_KEYS := {
	"PrototypeMudGolem": [],
	"PrototypeFastBeast": ["circle_inner_distance", "circle_outer_distance", "pounce_min_distance", "pounce_max_distance", "pounce_speed_multiplier"],
	"PrototypeHornet": ["hover_altitude", "strafe_distance", "orbit_band", "needle_range", "dive_range", "dive_speed"],
	"PrototypeSedimentTitan": ["leap_min_distance", "leap_far_distance", "leap_max_distance", "near_enter_distance", "near_exit_distance", "leap_lead_limit", "rage_leap_lead_limit", "leap_max_elevation", "leap_travel_speed"],
	"VisualBurstCrawler": ["attack_range", "retreat_range", "retreat_exit_range", "projectile_gravity", "projectile_radius", "blast_radius", "blast_height", "poison_radius", "poison_hit_height"],
	"VisualPrismSpider": ["attack_range", "retreat_range", "retreat_exit_range", "preferred_distance", "projectile_speed", "projectile_radius", "aim_line_width"],
	"VisualChargeBeetle": ["attack_range", "charge_min_range", "charge_distance", "charge_speed", "charge_hit_height", "charge_front_reach", "contact_range"],
}
const CROWD_WORLD := ["crowd_neighbor_radius", "crowd_flank_width", "crowd_flank_distance", "crowd_attack_radius", "crowd_height_spread", "crowd_vertical_sway"]
const SPEC_SCALED := ["attack_distance", "attack_reach_extra", "pounce_hit_radius", "pounce_hit_height", "normal_attack_reach", "normal_attack_height", "bite_radius", "slam_distance", "slam_width", "slam_offset", "sweep_distance", "sweep_preferred_distance", "thrust_width", "thrust_distance", "triple_slam_width", "triple_slam_length", "rage_close_distance", "leap_radius", "leap_arc_height"]

static func display_number(key: String, value: float) -> float:
	return value / TAU if key in ["walk_frequency", "trot_frequency"] else value

static func stored_number(key: String, value: float) -> float:
	return value * TAU if key in ["walk_frequency", "trot_frequency"] else value

static func scaled_runtime(profile: String, values: Dictionary, size: float) -> Dictionary:
	var result := values.duplicate(true)
	for key: String in WORLD_KEYS.get(profile, []):
		result[key] = float(result[key]) * size
	return result

static func field(profile: String, spec: Dictionary, source_group := "") -> Dictionary:
	var result := spec.duplicate(true)
	var key := String(spec.key)
	result["tab"] = 7
	result["section"] = source_group.split("（")[0].split(" · ")[0]
	result["semantic"] = "exclusive." + key
	result["unit"] = String(spec.get("unit", ""))
	if result.unit in ["世界米", "模型米"]: result.unit = "米"
	if key in ["walk_frequency", "trot_frequency"]:
		for member in ["min", "max", "step"]: result[member] = display_number(key, float(result[member]))
	if COMMON.has(key):
		result.label = COMMON[key][0]
		result.unit = COMMON[key][1]
		result.tab = COMMON[key][2]
		result.section = TABS[result.tab]
		result.semantic = key if key not in ["flight_speed", "gait_rate", "walk_frequency", "trot_frequency", "stagger_in", "stagger_out"] else {"flight_speed":"move_speed", "gait_rate":"gait_frequency", "walk_frequency":"gait_frequency", "trot_frequency":"gait_frequency", "stagger_in":"stagger_hit_time", "stagger_out":"stagger_recovery"}[key]
		if key == "turn_speed" and profile in ["PrototypeFastBeast", "PrototypeHornet"]:
			result.label = "转向响应率"
			result.unit = "1/秒"
			result.semantic = "turn_response"
	for skill: Array in SKILLS.get(profile, []):
		if skill[1].has(key):
			var slot := String(skill[1][key])
			if profile == "PrototypeHornet" and key in ["fire_interval", "dive_interval"]: slot = "cooldown_end"
			if profile == "VisualPrismSpider" and key == "attack_interval": slot = "cooldown_release"
			result.label = SLOTS[slot][0]
			result.unit = SLOTS[slot][1]
			result.tab = 2
			result.section = skill[0]
			result.semantic = "attack." + slot
			result["slot"] = slot
			break
	if result.tab == 7 and source_group in ["物种外形", "材质", "死亡表现（无伤害，可重播）", "死亡演出", "技能姿态张力（即时生效）"]:
		# 外形特有值仍集中在专属区，避免每个敌人改变公共布局。
		result.section = source_group.split("（")[0]
	result["scale_rule"] = "随体型（世界距离）" if key in WORLD_KEYS.get(profile, []) or key in CROWD_WORLD else "随体型（判定几何）" if key in SPEC_SCALED else "随体型（模型／占位）" if key in ["formation_width", "separation_radius", "collision_radius", "leg_thickness", "brace_spread"] or source_group in ["物种外形", "技能姿态张力（即时生效）"] or key in ["stride", "foot_lift", "walk_bob", "trot_bob", "breath_amount"] else "独立控制"
	return result

static func groups(profile: String, schema: Dictionary) -> Array[Dictionary]:
	var result: Array[Dictionary] = []
	for title: String in TABS: result.append({"title": title, "fields": []})
	var ordered: Array[Dictionary] = []
	for group: Dictionary in schema.groups:
		for spec: Dictionary in group.fields: ordered.append(field(profile, spec, String(group.title)))
	# 公共字段按统一表顺序；技能先按技能顺序，再按统一槽位顺序。
	for key: String in COMMON:
		for spec: Dictionary in ordered:
			if spec.key == key and spec.tab != 2: result[spec.tab].fields.append(spec)
	for skill: Array in SKILLS.get(profile, []):
		for slot: String in SLOTS:
			for spec: Dictionary in ordered:
				if spec.tab == 2 and spec.section == skill[0] and spec.slot == slot: result[2].fields.append(spec)
	for spec: Dictionary in ordered:
		if spec.tab == 7: result[7].fields.append(spec)
	return result
