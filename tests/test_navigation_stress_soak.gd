extends "res://tests/test_navigation_stress.gd"
## 256 个体持续四次跨区域迁移目标，最后保留 90 秒追踪窗口。
func _report_name() -> String:
	return "navigation_stress_soak.json"

func _specifications() -> Array:
	return [{"count": 256, "mode": "soak", "seed": 57721}]
