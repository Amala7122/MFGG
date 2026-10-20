extends "res://tools/probes/creature_navigation_audit.gd"
## 使用项目schema默认值守住复现；诊断入口另按用户当前保存方案测量。
func _values(profile: String) -> Dictionary:
	return Tuning.defaults(profile)

func _record(row: Dictionary) -> void:
	super(row)
	if not bool(row.valid):
		failed = true
		push_error("六小怪导航/攻击回归失败：" + JSON.stringify(row))
