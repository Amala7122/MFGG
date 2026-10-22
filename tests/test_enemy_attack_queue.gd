extends SceneTree
const Queue := preload("res://scripts/enemy_attack_queue.gd")
const Policy := preload("res://scripts/enemy_attack_queue_policy.gd")
var _world: Node3D
var _queue: Node
var _target: Node3D
var _failed := false
var _checks := 0

class Actor extends Node3D:
	var health := 100.0
	var target: Node3D

func _initialize() -> void:
	call_deferred("_run")

func _check(condition: bool, text: String) -> void:
	_checks += 1
	if not condition: _failed = true; push_error(text)

func _case() -> Dictionary:
	current_scene = null
	if is_instance_valid(_world): _world.free()
	_target = null
	_world = Node3D.new()
	root.add_child(_world)
	current_scene = _world
	_target = _actor()
	_queue = Queue.shared(_target)
	_queue.set_physics_process(false)
	var config := Policy.defaults()
	config.global.merge({"max_active": 8, "max_ground": 8, "starts_per_frame": 8, "start_gap": 0.0}, true)
	for profile: String in config.profiles:
		config.profiles[profile].max_active = 8
		for skill: String in config.profiles[profile].skills: config.profiles[profile].skills[skill] = 8
	Policy.apply(config)
	return config

func _actor() -> Node3D:
	var actor := Actor.new()
	_world.add_child(actor)
	actor.set_meta(&"formal_enemy", true)
	actor.target = _target
	return actor

func _ask(actor: Node3D, profile := "PrototypeMudGolem", skill := "punch", reserve := "", continuation := false) -> bool:
	return _queue.request(actor, actor.target, profile, skill, reserve, continuation)

func _run() -> void:
	for _frame in range(3): await process_frame
	paused = false
	var original := Policy.current().duplicate(true)
	_check(Policy.validate(original).is_empty(), "正式默认配置完整有效")
	var invalid := original.duplicate(true)
	invalid.global.max_active = 1.5
	_check(not Policy.apply(invalid) and Policy.current() == original, "非整数不静默取整，失败不修改运行配置")
	invalid.global.max_active = NAN
	_check(not Policy.validate(invalid).is_empty(), "拒绝非有限数值")
	invalid = original.duplicate(true)
	invalid.profiles.VisualBurstCrawler.skills.poison = -1
	_check(not Policy.validate(invalid).is_empty(), "技能限额拒绝负值")
	# 一帧多个物理步也只能消费一份起手名额；轮询顺序不能抢旧请求。
	var config := _case()
	config.global.max_active = 1
	config.global.starts_per_frame = 1
	Policy.apply(config)
	var a := _actor()
	var b := _actor()
	var c := _actor()
	_check(_ask(a) and not _ask(b) and not _ask(c), "同时到达只起手一个，其余入队")
	for _poll in range(5): _ask(b)
	_check(_queue.pending.size() == 2, "重复轮询不重复排队")
	_queue.release(a)
	_check(not _ask(b), "同一渲染帧释放后也不再起手")
	await process_frame
	_queue.clock += 0.02
	_check(not _ask(c) and _ask(b), "先来的有效请求优先，不被后轮询者抢占")
	_queue.release(b)
	await process_frame
	_check(_ask(c), "老请求最终起手，无固定遍历顺序饥饿")
	config = _case()
	config.global.max_active = 1
	Policy.apply(config)
	a = _actor(); b = _actor(); c = _actor()
	_ask(a)
	_ask(b, "PrototypeFastBeast", "pounce")
	_ask(c)
	_queue.release(a)
	_check(_ask(b, "PrototypeFastBeast", "normal_attack"), "同一敌人按最新距离换招，保留有效等待年龄，不因随机选招饥饿")
	config = _case()
	config.global.max_active = 1
	Policy.apply(config)
	a = _actor(); b = _actor()
	_ask(a); _ask(b)
	_check(_queue.defer_check(b, _target), "无名额且条件稳定时仅进入等待路径，不执行完整攻击规划")
	_target.position.x = 0.3
	_check(not _queue.defer_check(b, _target), "目标移动后立即退出等待缓存，不能沿用旧施放位置")
	_target.position.x = 0.0
	_queue.clock += Queue.WAIT_RECHECK + 0.01
	_check(not _queue.defer_check(b, _target), "稳定等待者也会定期完整复核条件")
	_ask(b)
	_queue.release(a)
	_check(not _queue.defer_check(b, _target) and _ask(b), "名额可用时先回宿主复核，轻量查询不会自己施放")
	# 30个等待者每物理步轮询，不得每次申请都全队重选／重算占位。
	config = _case()
	config.profiles.PrototypeFastBeast.skills.pounce = 0
	Policy.apply(config)
	var waiting: Array[Node3D] = []
	for _index in range(30):
		var actor := _actor()
		waiting.append(actor)
		_ask(actor, "PrototypeFastBeast", "pounce")
	var scans_before: int = _queue.selection_scans
	for _poll in range(10):
		for actor in waiting: _ask(actor, "PrototypeFastBeast", "pounce")
	_check(int(_queue.selection_scans) - scans_before <= 1 and _queue.pending.size() == 30,
		"同一帧300次等待轮询复用决策，不重复全队扫描")
	# 起手间隔按目标；被限额阻塞的队头不堵住其他可行技能／玩家。
	config = _case()
	config.global.start_gap = 0.5
	Policy.apply(config)
	a = _actor(); b = _actor(); c = _actor()
	var other_target := _actor()
	c.target = other_target
	_check(_ask(a) and not _ask(b) and _ask(c), "同一玩家有间隔，另一玩家不被队头间隔阻塞")
	_queue.clock += 0.3
	_check(not _ask(b), "间隔未到不提前公布预警")
	_queue.clock += 0.21
	_check(_ask(b), "间隔结束可正常获准")
	config = _case()
	config.global.max_ground = 1
	config.profiles.PrototypeFastBeast.skills.pounce = 1
	Policy.apply(config)
	a = _actor(); b = _actor(); c = _actor()
	_check(_ask(a, "PrototypeFastBeast", "pounce"), "地面技能占位")
	_check(not _ask(b, "PrototypeFastBeast", "pounce") and _ask(c), "地面／单技能满额时其他普通攻击仍可起手")
	_queue.release(a)
	_check(_ask(b, "PrototypeFastBeast", "pounce"), "结束后释放地面与技能占位")
	# 投囊预留毒池；出手后敌人取消／死亡，弹体和毒池都不能丢失占位。
	config = _case()
	config.profiles.VisualBurstCrawler.skills.poison = 1
	Policy.apply(config)
	a = _actor(); b = _actor()
	_check(_ask(a, "VisualBurstCrawler", "lob", "poison"), "投囊提前预留毒池容量")
	var projectile := Node3D.new()
	_world.add_child(projectile)
	Queue.track_effect(a, projectile)
	_queue.release(a)
	_check(_queue.snapshot().total == 1 and not _ask(b, "VisualBurstCrawler", "lob", "poison"), "敌人收招后在途弹体继续占位")
	var pool := Node3D.new()
	_world.add_child(pool)
	Queue.track_effect(projectile, pool, "poison")
	projectile.free()
	a.health = 0
	var state: Dictionary = _queue.snapshot()
	_check(state.total == 1 and state.ground == 1 and not state.skills.has("VisualBurstCrawler/lob")
		and state.skills.get("VisualBurstCrawler/poison", 0) == 1, "毒池独立接力；死亡不撤销毒池，不占已经结束的投囊技能限额")
	pool.free()
	_check(_ask(b, "VisualBurstCrawler", "lob", "poison"), "最后残留退出后正常释放预留")
	# 连招原子性：跃击接震拳共用预留组，不再次排队或重复起手名额。
	config = _case()
	config.profiles.PrototypeSedimentTitan.skills.thrust = 1
	Policy.apply(config)
	a = _actor(); b = _actor()
	_check(_ask(a, "PrototypeSedimentTitan", "leap", "thrust"), "Boss连招提前预留后续技能")
	_check(not _ask(b, "PrototypeSedimentTitan", "thrust"), "其他Boss不能夺走已经预留的连招名额")
	_check(_ask(a, "PrototypeSedimentTitan", "thrust", "", true) and _queue.snapshot().total == 1
		and _queue.history.size() == 1, "同组连招继续，不增加危险组或重新消耗起手间隔")
	_queue.release(a)
	_check(_ask(b, "PrototypeSedimentTitan", "thrust"), "连招结束后其他Boss恢复起手")
	# 死亡、换目标、失去施放条件后停止轮询，都不能留下永久队头。
	config = _case()
	config.global.max_active = 1
	Policy.apply(config)
	a = _actor(); b = _actor(); c = _actor()
	_ask(a); _ask(b)
	b.health = 0
	_queue.release(a)
	_check(_ask(c) and _queue.pending.is_empty(), "死亡请求自动清理")
	_queue.release(c)
	b.health = 100
	_ask(a); _ask(b)
	_queue.clock += Queue.REQUEST_GRACE + 0.01
	_queue.release(a)
	_check(_ask(c) and _queue.pending.is_empty(), "停止续约的过期请求不会阻塞后续起手")
	# 调低限额只阻止新起手，不撤回已经公布的动作。
	config = _case()
	a = _actor(); b = _actor(); c = _actor()
	_ask(a); _ask(b)
	config.global.max_active = 1
	Policy.apply(config)
	_check(not _ask(c) and _queue.snapshot().total == 2, "调低限额保留原动作，超额期间不准新起手")
	paused = true
	_queue.release(a); _queue.release(b)
	_check(not _ask(c), "暂停期间不会起手")
	paused = false
	_check(_ask(c), "解除暂停后继续同一现场")
	var before: Dictionary = _queue.snapshot()
	root.remove_child(_world)
	_check(_queue.snapshot().total == before.total, "整场离树观察时不清空占位")
	root.add_child(_world)
	current_scene = _world
	_check(_queue.snapshot().total == before.total and _queue.clock == before.clock, "返回原现场保留队列与时钟")
	_queue.set_physics_process(true)
	for _frame in range(3): await physics_frame
	paused = true
	var frozen: float = _queue.clock
	for _frame in range(5): await process_frame
	_check(_queue.clock == frozen, "真实暂停冻结队列时钟，不依赖宿主进程模式")
	paused = false
	for _frame in range(3): await physics_frame
	_check(_queue.clock > frozen, "恢复战斗后继续原队列时钟")
	Policy.apply(original)
	print("[敌人起手队列] checks=", _checks, " ", "FAIL" if _failed else "PASS")
	quit(1 if _failed else 0)
