extends "res://tools/probes/titan_sparring.gd"
## 通用无头入口；泰坦旧 CLI 保留默认场景。运行、重放与报告使用同一实现。
func default_scenario() -> String:
	return String(Settings.read_document().get("active_scenario", Settings.Scenarios.document().active))
