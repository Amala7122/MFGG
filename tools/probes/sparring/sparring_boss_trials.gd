extends RefCounted
## 命名且完整记录的泰坦单项反证；只覆盖陪练实例，不写正式方案。
## 未采用的近身争取实验随源产物保留，正式工具不静默模拟已撤掉的行为。
const IDS := ["", "baseline", "hitstop", "pursuit", "mobile_only", "cadence_soft", "cadence", "pre_links"]
const LABELS := ["正式配置", "基线：原顿帧／2.4秒收势", "单项：限制枪击顿帧", "反证：仅提高追速", "单项：枪击不刹停追击", "候选：狂暴收势1.56秒", "候选：狂暴收势1.2秒", "对照：本轮衔接改造前"]
const VALUES := {
	"pre_links": {"heavy_sheds_shield": true, "thrust_enabled": false, "leap_followup_enabled": false, "sweep_distance": 5.0, "sweep_windup": 0.42},
	"baseline": {"rage_bullet_hitstop_interval": 0.0, "rage_speed_multiplier": 1.3, "rage_shot_movement_armor": false, "rage_heavy_recovery_scale": 1.0},
	"hitstop": {"rage_bullet_hitstop_interval": 0.35, "rage_speed_multiplier": 1.3, "rage_shot_movement_armor": false, "rage_heavy_recovery_scale": 1.0},
	"pursuit": {"rage_bullet_hitstop_interval": 0.0, "rage_speed_multiplier": 1.6, "rage_shot_movement_armor": false, "rage_heavy_recovery_scale": 1.0},
	"mobile_only": {"rage_bullet_hitstop_interval": 0.35, "rage_speed_multiplier": 1.3, "rage_shot_movement_armor": true, "rage_heavy_recovery_scale": 1.0},
	"cadence_soft": {"rage_bullet_hitstop_interval": 0.35, "rage_speed_multiplier": 1.3, "rage_shot_movement_armor": true, "rage_heavy_recovery_scale": 0.65},
	"cadence": {"rage_bullet_hitstop_interval": 0.35, "rage_speed_multiplier": 1.3, "rage_shot_movement_armor": true, "rage_heavy_recovery_scale": 0.5},
}

static func values(experiment: Dictionary) -> Dictionary:
	var result: Dictionary = VALUES.get(String(experiment.get("pressure_trial", "")), {}).duplicate()
	if experiment.has("down_hold_seconds"):
		result["down_hold_seconds"] = experiment.down_hold_seconds
	return result
