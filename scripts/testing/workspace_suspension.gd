extends RefCounted
## 退出回调只依赖这个无资源依赖的标记查询，避免敌人场景与UI目录循环预载。
static func suspended(node: Node) -> bool:
	while node != null:
		if node.get_meta("workspace_suspended", false): return true
		node = node.get_parent()
	return false
