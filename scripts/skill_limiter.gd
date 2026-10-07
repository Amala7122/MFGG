class_name SkillLimiter
extends RefCounted
## 敌人高威胁技能全局并发限流器。
##
## 解决痛点：场上同时出现 3 个冲锋或 3 条狙击锁定红线时，
## 玩家视线被严重遮挡、地面预警重叠，无法形成有效的判断与闪避。
## 本模块限制同屏同时处于蓄力/出手阶段的高威胁技能数量。

static var _active: Dictionary = {}


static func can_start(skill_name: String, max_allowed: int = 1) -> bool:
	if skill_name.is_empty():
		return true
	return int(_active.get(skill_name, 0)) < max_allowed


static func acquire(skill_name: String) -> void:
	if skill_name.is_empty():
		return
	_active[skill_name] = int(_active.get(skill_name, 0)) + 1


static func release(skill_name: String) -> void:
	if skill_name.is_empty():
		return
	var current := int(_active.get(skill_name, 0))
	if current <= 1:
		_active.erase(skill_name)
	else:
		_active[skill_name] = current - 1


static func clear() -> void:
	_active.clear()
