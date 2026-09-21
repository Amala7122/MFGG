class_name ObjectPool
extends RefCounted
## 轻量对象池。全部是静态方法，**不需要注册 autoload**，也不依赖场景树。
##
## 为什么必须有它：瞬发命中下每次扣扳机有 5~11 发弹丸全部命中，每发都会生成
## 火花 + 伤害飘字。命中火花每次要新建 8 个碎片网格 + 5 个材质 + 1 个点光，
## 高等级时相当于每秒数千个节点与资源被反复创建销毁 —— 这是目前最大的单项
## 性能开销，也是 GC 抖动的来源。
##
## 使用约定：
##   1. 被池化的节点提供 POOL_KEY 常量，并实现可重复调用的"重置型"入口
##      （如 trigger() / show_amount()），内部自己保证幂等；
##   2. 生命周期结束时调用 ObjectPool.release(KEY, self) 而不是 queue_free()；
##   3. 被回收的节点会脱离场景树，因此 _process 会自动停止，不占用帧时间。
##
## 池是静态的，所以节点可以跨场景复用；代价是它不会被场景释放，
## 因此用 performance.max_idle_per_key 限制常驻上限，避免内存无上限增长。

const ConfigUtil := preload("res://scripts/game_config.gd")

## 每个键最多缓存多少个空闲节点的【兜底值】。实际取 performance.max_idle_per_key。
const DEFAULT_MAX_IDLE_PER_KEY := 64

static var _pools: Dictionary = {}
## 缓存一份：release() 在高频路径上，不该每次都去点号查找配置。
static var _max_idle := -1


static func _max_idle_per_key() -> int:
	if _max_idle < 0:
		_max_idle = ConfigUtil.get_int("performance.max_idle_per_key", DEFAULT_MAX_IDLE_PER_KEY)
	return _max_idle


## 取出一个节点：优先复用空闲的，池空时才调用 script.new() 新建。
## 适用于**纯代码构建**的对象（命中火花、伤害飘字）。
static func acquire(key: String, script_class: GDScript) -> Node:
	var node := _pop(key)
	if node:
		return node
	return script_class.new()


## 取出一个节点，池空时用 scene.instantiate() 新建。
## 适用于**场景实例化**的对象（敌人子弹等 .tscn）—— 它们不是脚本 new 出来的，
## 不能和上面的 acquire() 共用创建路径，但释放路径完全一致。
##
## 刻意做成并列函数而不是把参数放宽成 Variant：保持类型明确，
## 避免每次取用都做一次运行期类型判断。
static func acquire_scene(key: String, scene: PackedScene) -> Node:
	var node := _pop(key)
	if node:
		return node
	return scene.instantiate()


## 从空闲池里弹出一个有效节点；池空或全失效时返回 null。
static func _pop(key: String) -> Node:
	var bucket: Array = _pools.get(key, [])
	while not bucket.is_empty():
		var node: Node = bucket.pop_back()
		if is_instance_valid(node):
			_pools[key] = bucket
			return node
	_pools[key] = bucket
	return null


## 回收一个节点：脱离场景树后放进空闲池。超出上限的直接释放。
static func release(key: String, node: Node) -> void:
	if not is_instance_valid(node):
		return
	var parent := node.get_parent()
	if parent:
		parent.remove_child(node)
	var bucket: Array = _pools.get(key, [])
	if bucket.size() >= _max_idle_per_key():
		node.queue_free()
	else:
		bucket.append(node)
	_pools[key] = bucket


## 清空所有池。切换关卡 / 重开一局 / 退出游戏时调用。
##
## 池化节点是**脱离场景树**的，因此不会被场景释放顺带回收。不主动清理的话，
## 游戏退出时引擎会报一堆 "RID allocations were leaked at exit"。
## 这里用 free() 而不是 queue_free()：这些节点已经不在树上，没有待处理的
## 回调，立即释放是安全的，而且能保证在进程退出前真正回收掉。
static func clear_all() -> void:
	for key in _pools.keys():
		var bucket: Array = _pools[key]
		for node in bucket:
			if is_instance_valid(node):
				node.free()
	_pools.clear()


## 调试用：当前各池的空闲节点数。
static func get_stats() -> Dictionary:
	var stats := {}
	for key in _pools.keys():
		stats[key] = (_pools[key] as Array).size()
	return stats
