extends "res://tests/test_crystal_creature_combat.gd"
## 真实宿主，而不是手工申请占位：冷却边界、撤退退出、投射物与毒池接力。
const AttackQueue := preload("res://scripts/enemy_attack_queue.gd")
const QueuePolicy := preload("res://scripts/enemy_attack_queue_policy.gd")

func _run() -> void:
	for _frame in range(3): await process_frame
	Flow.instance.state = Flow.State.PLAYING
	Flow.instance.visible = false
	paused = false
	var original := QueuePolicy.current().duplicate(true)
	var config := QueuePolicy.defaults()
	config.global.merge({"max_active": 1, "max_ground": 1, "starts_per_frame": 8, "start_gap": 0.0}, true)
	QueuePolicy.apply(config)
	await _fixture("VisualBurstCrawler", 14)
	actor.set_meta(&"formal_enemy", true)
	actor.set_physics_process(false)
	var queue := AttackQueue.shared(actor)
	queue.set_physics_process(false)
	for retreat in [false, true]:
		actor.visual.behavior.reset()
		actor.visual.behavior.state = actor.visual.Behavior.State.RETREAT if retreat else actor.visual.Behavior.State.IDLE
		actor.visual.behavior.cooldown = 0.005
		_check(queue.request(player, player, "PrototypeMudGolem", "punch"), "其他真实在场攻击占满队列")
		var waiting_velocity: Vector3 = actor._think(1.0 / 60.0)
		_check(waiting_velocity.is_zero_approx(), "默认守势等待在完整复核帧也不短暂向前挪动")
		_check(actor.visual.behavior.state == actor.visual.Behavior.State.IDLE and actor.throws == 0,
			"退出撤退同帧不能绕过队列自动起手" if retreat else "冷却刚归零不能绕过队列自动起手")
		_check(queue.pending.size() == 1 and not actor.has_meta(&"attack_queue_id"), "真实宿主保持等待票，没有伪造已获准名额")
		queue.release(player)
		actor._think(1.0 / 60.0)
		_check(actor.visual.behavior.state == actor.visual.Behavior.State.TURN and actor.has_meta(&"attack_queue_id"), "获得名额后才从TURN开始完整前摇")
		actor.cancel_attack()
	# 原生AI完成一次投囊，检查真正的弹体和毒池都携带同一接力占位。
	await _fixture("VisualBurstCrawler", 14)
	actor.set_meta(&"formal_enemy", true)
	actor.ai_enabled = true
	_check(await _until("throws", 1), "正式爬兽原生AI可获准并投囊")
	queue = AttackQueue.shared(actor)
	var projectiles := get_nodes_in_group("enemy_projectiles")
	_check(projectiles.size() == 1 and projectiles[0].has_meta(&"attack_queue_effect"), "真实爆囊出手时已接力占位")
	actor.ai_enabled = false
	actor.cancel_attack()
	await _frames(100)
	var pools := get_nodes_in_group("enemy_hazards")
	_check(not pools.is_empty() and pools[0].has_meta(&"attack_queue_effect") and queue.snapshot().ground == 1,
		"真实落地毒池有接力名额，源敌人取消不丢失在场危险")
	for pool in pools: pool.free()
	_check(queue.snapshot().total == 0, "真实毒池退出后名额回收")
	await _dispose()
	QueuePolicy.apply(original)
	print("[起手队列真实宿主] ", "FAIL" if failed else "PASS")
	quit(1 if failed else 0)
