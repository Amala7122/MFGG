extends SceneTree
## 敌人图鉴完整性回归。
##
## 【这条测试防的是什么】狙击兵（`ranged_pattern = 5`）曾经被**静默删掉过**：
## 移植期它靠"标题里含『游骑兵』"来判定，后来为修误判改成只认 `pattern_type`，
## 却没有任何条目配 5 —— 于是红线预警、重型穿甲弹、技能限流整条链路在正式关卡
## 不可达，而项目里没有任何检查会报出来。用户是在试玩时凭手感发现的。
##
## 覆盖：
##   1. 图鉴 id 唯一；
##   2. 每条都有 kind / min_weapon_level，且 kind 合法；
##   3. 远程条目必须有合法 ranged_pattern，近战条目必须有正血量；
##   4. **每一种 ranged_pattern（含狙击 5）都必须至少有一条可达条目**。
const Config := preload("res://scripts/game_config.gd")
const RangedEnemy := preload("res://scripts/ranged_enemy.gd")

var _failures := 0


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	var root_cfg := Config.get_dictionary("enemy_roster")
	var entries: Array = root_cfg.get("entries", [])
	_check(not entries.is_empty(), "图鉴非空")

	var seen := {}
	var ranged_patterns := {}
	for entry in entries:
		_check(entry is Dictionary, "图鉴条目是字典")
		if not (entry is Dictionary):
			continue
		var id := String(entry.get("id", ""))
		var kind := String(entry.get("kind", ""))
		_check(not id.is_empty(), "条目有 id")
		_check(not seen.has(id), "图鉴 id 唯一：%s" % id)
		seen[id] = true
		_check(kind == "melee" or kind == "ranged", "%s 的 kind 合法（实际 %s）" % [id, kind])
		_check(int(entry.get("min_weapon_level", 0)) >= 1, "%s 有解锁等级" % id)
		if kind == "ranged":
			var pattern := int(entry.get("ranged_pattern", -1))
			_check(pattern >= 0 and pattern <= int(RangedEnemy.PatternType.SNIPER),
				"%s 的 ranged_pattern 在合法范围（实际 %d）" % [id, pattern])
			_check(int(entry.get("health_tier", -1)) >= 0,
				"%s 作为远程必须有 health_tier（否则『狙击几发打死』契约失效）" % id)
			ranged_patterns[pattern] = id
		elif kind == "melee":
			_check(float(entry.get("health", -1.0)) > 0.0, "%s 作为近战必须有正血量" % id)
		_check(float(entry.get("damage", -1.0)) > 0.0, "%s 有正伤害" % id)
		_check(float(entry.get("move_speed", -1.0)) > 0.0, "%s 有正移速" % id)

	# 每一种弹幕图案都必须有兵种在用它 —— 否则那套机制就是死代码。
	for pattern in range(int(RangedEnemy.PatternType.SNIPER) + 1):
		_check(ranged_patterns.has(pattern),
			"ranged_pattern = %d 有兵种使用（缺失即该机制在正式关卡不可达）" % pattern)

	print("[图鉴] failures=", _failures)
	quit(1 if _failures else 0)


func _check(ok: bool, description: String) -> void:
	if not ok:
		_failures += 1
		push_error(description)
