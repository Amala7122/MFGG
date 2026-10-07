class_name HealthUtil
extends RefCounted
## 运行期「这个 actor 还活着吗 / 它有多少血」的**唯一入口**。
##
## ── 为什么必须有它 ──────────────────────────────────────────────
## 项目里一度到处写 float(actor.get("health"))，隐含假设"凡是 actor 都有 health"。
## 这个假设对 Boss 不成立（它内部叫 _health，对外只有 get_health()），于是 Boss
## 一进 enemies 组，任何按组遍历的地方都会取到 null，float(null) 抛
## "Invalid call. Nonexistent 'float' constructor." 直接崩掉整局。
##
## 所以把"读血量"收成一处，按优先级解析：
##   1. get_health() 方法 —— 类自己声明的权威访问器（Boss 走这条）
##   2. health 属性    —— 常规敌人走这条
##   3. 两者都没有     —— 返回 null，调用方按"未知"处理
##
## 【为什么"未知"要当成存活】读不到血量 ≠ 已经死了。当成死亡会让新加入的 actor
## 类型（召唤物、可破坏物、将来的新 Boss）静默失去 AI 目标与受击判定，而且不报错；
## 当成存活最坏只是少一次提前剔除 —— 不会崩，也不会让敌人瞎掉。


## 读取 actor 的血量。返回 Variant：数值，或 null 表示该 actor 不暴露血量。
##
## 【参数为什么是 Variant 而不是 Object】已释放的对象传给 typed 参数（含 Object）
## 时，GDScript 在**参数类型检查**阶段就抛
## "previously freed is not a subclass of the expected argument class" ——
## 那正是本工具要消除的崩溃类型。Variant 才能在函数内部安全地做 is_instance_valid。
static func health_of(actor: Variant) -> Variant:
	if actor == null or not is_instance_valid(actor):
		return null
	# 先问类自己的访问器（Boss 这类内部字段名不同的走这里）
	if actor.has_method("get_health"):
		var value: Variant = actor.call("get_health")
		if value != null:
			return value
	# 再退回脚本变量；必须用 get()，静态类型上看不到脚本属性
	return actor.get("health")


## 血量数值；actor 不暴露血量（或已释放）时返回 fallback。
static func health_or(actor: Variant, fallback: float = 0.0) -> float:
	var value: Variant = health_of(actor)
	if value == null:
		return fallback
	return float(value)


## 是否存活。无法判定血量时视为存活；已失效或排队删除的视为不存活。
static func is_alive(actor: Variant) -> bool:
	if actor == null or not is_instance_valid(actor):
		return false
	if actor is Node and (actor as Node).is_queued_for_deletion():
		return false
	var value: Variant = health_of(actor)
	if value == null:
		return true
	return float(value) > 0.0


## 是否确定已死（对象已失效，或明确读到血量 <= 0）。
static func is_dead(actor: Variant) -> bool:
	return not is_alive(actor)
