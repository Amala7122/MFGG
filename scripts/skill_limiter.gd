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
	_prune(skill_name)
	return (_active.get(skill_name, {}) as Dictionary).size() < max_allowed


static func acquire(skill_name: String, owner: Node, max_allowed: int = 1) -> bool:
	if skill_name.is_empty() or not is_instance_valid(owner) or not owner.is_inside_tree():
		return false
	_prune(skill_name)
	var holders: Dictionary = _active.get(skill_name, {})
	var id := owner.get_instance_id()
	if holders.has(id):
		return true
	if holders.size() >= max_allowed:
		return false
	holders[id] = weakref(owner)
	_active[skill_name] = holders
	return true


static func release(skill_name: String, owner: Node) -> void:
	if skill_name.is_empty() or not is_instance_valid(owner):
		return
	var holders: Dictionary = _active.get(skill_name, {})
	holders.erase(owner.get_instance_id())
	if holders.is_empty():
		_active.erase(skill_name)
	else:
		_active[skill_name] = holders


static func _prune(skill_name: String) -> void:
	var holders: Dictionary = _active.get(skill_name, {})
	for id in holders.keys():
		var node := (holders[id] as WeakRef).get_ref() as Node
		if node == null or not node.is_inside_tree() or node.is_queued_for_deletion():
			holders.erase(id)
	if holders.is_empty():
		_active.erase(skill_name)


static func clear() -> void:
	_active.clear()
