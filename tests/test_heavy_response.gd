extends SceneTree
## 重型对共鸣的反应回归。
##
## 【这条测试防的是什么】用户明确的设计要求：
##   1. 共鸣对**轻型**敌人即死，但**打不动重型** —— 否则"重型"这个分类没有意义；
##   2. 盾卫**检测到共鸣必定举盾**，举盾期间减伤；
##   3. 重型**被共鸣打中会激怒**（物理攻击叠层，挨得越多越强）—— 共鸣的代价。
## 这三条任何一条坏掉，症状都只是"打起来感觉不对"，不会报错。
const Config := preload("res://scripts/game_config.gd")
const ResonanceScript := preload("res://scripts/resonance.gd")
const MeleeScene: PackedScene = preload("res://scenes/melee_enemy.tscn")

var _failures := 0


class StubEnemy extends Node3D:
	var health := 5000.0
	var max_health := 5000.0
	func take_damage(amount: float) -> void:
		health -= amount


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	var world := Node3D.new()
	world.name = "HeavyWorld"
	root.add_child(world)

	# ── A. 共鸣的即死范围：轻型死、重型不死 ──
	var light := StubEnemy.new()
	light.add_to_group("enemies")
	world.add_child(light)
	light.scale = Vector3.ONE * 0.8
	light.global_position = Vector3(1.0, 0.0, 0.0)

	var heavy := StubEnemy.new()
	heavy.add_to_group("enemies")
	world.add_child(heavy)
	heavy.scale = Vector3.ONE * 1.4
	heavy.global_position = Vector3(-1.0, 0.0, 0.0)

	# `_player` 在 resonance.gd 里是 CharacterBody3D 类型，塞 Node3D 会被类型检查拒掉。
	var caster := CharacterBody3D.new()
	world.add_child(caster)
	var caster_pos := caster.global_position
	var resonance: Node = ResonanceScript.new()
	world.add_child(resonance)
	resonance.set("_player", caster)
	# `_read_config()` 平时由 setup() 调；这里手工驱动，让配置真的生效。
	resonance.call("_read_config")
	await process_frame

	# 100% 蓄力（ratio = 1.0）：基础伤害 520。
	var hit_count: int = int(resonance.call("_apply_burst_damage", caster_pos, 20.0, 520.0, 10.0, 1.0))
	_check(hit_count == 2, "爆发命中了场上两个敌人（实际 %d）" % hit_count)
	_check(not HealthUtil_alive(light), "轻型敌人被共鸣爆发秒杀")
	_check(HealthUtil_alive(heavy), "重型敌人不会被共鸣爆发秒杀")
	# 重型必须确实【吃到伤害】——"打不动"不等于"免疫"。
	var heavy_loss := 5000.0 - heavy.health
	_check(heavy_loss > 0.0, "重型仍然吃到了共鸣伤害（本次 %.0f）" % heavy_loss)
	_check(heavy_loss <= 620.0, "重型受到的是一次基础伤害，而不是 hp+600 的保底（本次 %.0f）" % heavy_loss)

	# ── B. 盾卫插盾姿态：起手 → 防御 → 解除，正面格挡、侧后挨打、爆炸不吃格挡 ──
	var guard: CharacterBody3D = MeleeScene.instantiate()
	world.add_child(guard)
	await process_frame
	guard.call("configure_melee_variant", "大型盾卫", Color(0.2, 0.3, 0.5))
	guard.call("configure_stats", 1.4, 20000.0, 2.5, 26.0, {})
	guard.call("apply_body_profile", "shield")
	guard.set("_shield_raise_chance", 0.0)
	await process_frame

	_check(guard.get("_shield_pivot") != null, "盾卫场景里找得到 ShieldPivot（插盾要转的就是它）")
	_check(bool(guard.call("_is_heavy")), "体型 1.4 的盾卫属于重型")

	var plant := float(Config.get_float("enemy.shield_plant_seconds", 0.35))
	var hold := float(Config.get_float("enemy.shield_hold_seconds", 2.4))
	var lower := float(Config.get_float("enemy.shield_lower_seconds", 0.55))
	var reduction := float(Config.get_float("enemy.shield_damage_reduction", 0.85))

	# 概率触发走**完整相位**：起手 0.35 秒 → 防御。
	guard.set("_shield_state", 0)
	guard.set("_shield_state_time", 0.0)
	guard.call("_enter_shield_stance")
	_check(int(guard.get("_shield_state")) == 1, "普通触发要先走插盾起手相位")
	_check(bool(guard.call("_shield_busy")), "起手期间也算忙（不移动、不攻击）")
	guard.call("_advance_shield_state", plant + 0.01)
	_check(int(guard.get("_shield_state")) == 2, "起手结束后进入防御（PLANTED）")

	# 共鸣是**反射式**：同一帧就立在防御相位。姿态靠相位机插值的话要 0.35 秒才成形，
	# 而爆发的视觉是同一帧 —— 错位就变成"先被炸、盾才抬起来"（用户实测反馈）。
	guard.set("_shield_state", 0)
	guard.set("_shield_state_time", 0.0)
	guard.call("on_resonance_incoming", Vector3.ZERO)
	_check(int(guard.get("_shield_state")) == 2, "检测到共鸣同一帧就立在防御相位（反射式，不等 0.35 秒）")
	_check(float(guard.get("_brace_resonance_time")) > 0.0, "共鸣这一发被盾格挡")

	# 共鸣被盾挡：这是紧随 on_resonance_incoming 的那一发（真实结算顺序）。
	var hp_before := float(guard.get("health"))
	guard.call("take_damage", 100.0)
	var brace_taken := hp_before - float(guard.get("health"))
	_check(is_equal_approx(brace_taken, 100.0 * (1.0 - reduction)), "共鸣被盾挡住（吃了 %.1f）" % brace_taken)

	var gp: Vector3 = guard.global_position
	var front := gp + Vector3(0.0, 0.0, -2.0)
	var back := gp + Vector3(0.0, 0.0, 2.0)

	# 正面子弹被削减。
	hp_before = float(guard.get("health"))
	guard.call("take_damage_at", 100.0, front, false)
	var front_taken := hp_before - float(guard.get("health"))
	_check(is_equal_approx(front_taken, 100.0 * (1.0 - reduction)),
		"正面子弹被盾削减（吃了 %.1f，期望 %.1f）" % [front_taken, 100.0 * (1.0 - reduction)])

	# 侧后子弹不被削减 —— 绕后是有效解法。
	hp_before = float(guard.get("health"))
	guard.call("take_damage_at", 100.0, back, false)
	_check(is_equal_approx(hp_before - float(guard.get("health")), 100.0), "侧后子弹不被格挡")

	# 爆炸不走正面格挡 —— 手雷因此是打盾卫的正解。
	hp_before = float(guard.get("health"))
	guard.call("take_damage", 100.0)
	_check(is_equal_approx(hp_before - float(guard.get("health")), 100.0), "爆炸绕过盾面格挡")

	# 解除需要时间：这一段既不格挡也不攻击，是反击窗口。
	guard.call("_advance_shield_state", hold + 0.01)
	_check(int(guard.get("_shield_state")) == 3, "保持结束后进入解除相位（LOWERING）")
	hp_before = float(guard.get("health"))
	guard.call("take_damage_at", 100.0, front, false)
	_check(is_equal_approx(hp_before - float(guard.get("health")), 100.0), "解除期间不格挡（反击窗口）")
	guard.call("_advance_shield_state", lower + 0.01)
	_check(int(guard.get("_shield_state")) == 0, "解除结束后回到普通状态")
	_check(not bool(guard.call("_shield_busy")), "普通状态不再算忙（可以移动和攻击）")

	# ── C. 重型激怒：叠层、封顶、非重型不涨 ──
	guard.set("_rage", 0.0)
	guard.call("on_resonance_hit", 100.0)
	var one := float(guard.get("_rage"))
	_check(one > 0.0, "重型挨一次共鸣会激怒（+%.2f）" % one)
	for _i in 30:
		guard.call("on_resonance_hit", 100.0)
	var rage_max := float(Config.get_float("enemy.rage_max", 0.9))
	_check(is_equal_approx(float(guard.get("_rage")), rage_max),
		"激怒叠层封顶在 rage_max（%.2f）" % rage_max)

	var plain: CharacterBody3D = MeleeScene.instantiate()
	world.add_child(plain)
	await process_frame
	plain.call("configure_melee_variant", "近战士兵", Color(0.4, 0.1, 0.5))
	plain.call("configure_stats", 1.0, 200.0, 4.0, 16.0, {})
	plain.set("_rage", 0.0)
	plain.call("on_resonance_hit", 100.0)
	_check(is_equal_approx(float(plain.get("_rage")), 0.0), "非重型不会激怒")

	# ── D. 插盾时始终面向玩家 ──
	# 【这条防的是什么】朝向角约定是 `atan2(-x, -z)`（本模型 -Z 为正面）。
	# 曾经写成 `atan2(x, z)`，方向正好差 180° —— 表现就是"盾卫不朝玩家、
	# 自己原地转圈，没有检测玩家方位"（用户实测反馈）。纯数学错误，
	# 只会表现为手感怪，所以必须钉住。
	var foe := CharacterBody3D.new()
	foe.add_to_group("player")
	world.add_child(foe)
	var guard_pos: Vector3 = guard.global_position
	foe.global_position = guard_pos + Vector3(0.0, 0.0, 6.0)
	guard.set("target", foe)
	guard.set("_shield_state", 2)  # PLANTED
	guard.set("_shield_state_time", 600.0)
	var to_foe := foe.global_position - guard_pos
	to_foe.y = 0.0
	# 起始朝向故意偏 90°，给受限转速留出"追得上"的空间。
	guard.rotation.y = atan2(-to_foe.x, -to_foe.z) + deg_to_rad(90.0)
	for _step in range(240):  # 4 秒 @60fps，转速 60°/s 足够转完 90°
		guard.call("_face_target_while_planted", 1.0 / 60.0)
	var facing := -guard.global_transform.basis.z
	facing.y = 0.0
	var dot := facing.normalized().dot(to_foe.normalized())
	_check(dot > 0.98, "插盾时盾面始终朝玩家（朝向点积 %.3f，1.0 为完全正对）" % dot)

	# 无论玩家绕到哪个方位，都应该收敛过去（而不是往反方向追）。
	for angle in [40.0, 150.0, -120.0]:
		var rad := deg_to_rad(angle)
		var offset := Vector3(sin(rad), 0.0, cos(rad)) * 6.0
		foe.global_position = guard_pos + offset
		guard.rotation.y = atan2(-offset.x, -offset.z) + deg_to_rad(180.0)
		for _step in range(300):
			guard.call("_face_target_while_planted", 1.0 / 60.0)
		var face := -guard.global_transform.basis.z
		face.y = 0.0
		_check(face.normalized().dot(offset.normalized()) > 0.98,
			"玩家在 %d° 方位时盾卫也转得过去（点积 %.3f）" % [int(angle), face.normalized().dot(offset.normalized())])

	# ── E. 击退必须推得动"已经贴脸/正在插盾"的敌人 ──
	# 【这条防的是什么】击退原本写在 `_update_behavior` 里，而它只在
	# `_steering.tick()` 返回 false 时才被调用；插盾姿态又更早地把 velocity 清零并 return。
	# 两者合起来的结果是：**贴脸的、正在插盾的敌人完全推不动** ——
	# 而贴脸恰恰是 Q 唯一的用途（用户实测："每次释放，盾卫都会被拉近一点而不是推远"）。
	# 这里直接构造最坏情况：插盾姿态 + 相邻，然后推。
	guard.set("gravity", 0.0)
	guard.velocity = Vector3.ZERO
	# 测试世界里没有地板：把"掉出世界"的判定深度放大，免得它坠落被回收
	#（被回收后再读 global_position 会直接抛错，协程就此中断、quit 收不到 → 挂住）。
	guard.set("_fall_kill_depth", 1.0e6)
	guard.set("_shield_state", 2)  # PLANTED
	guard.set("_shield_state_time", 600.0)
	guard.set("_stagger_time", 0.0)
	var push_origin: Vector3 = guard.global_position
	var away := (push_origin - foe.global_position)
	away.y = 0.0
	away = away.normalized()
	guard.call("apply_push", away, 30.0)
	_check(float(guard.get("_stagger_time")) > 0.0, "apply_push 进入了击退状态")
	guard.call("apply_push", away, 30.0)
	_check(float(guard.get("_stagger_time")) > 0.0, "apply_push 进入了击退状态")
	# 【必须解除暂停】GameFlow 在进入场景时会暂停 SceneTree，而暂停不会阻止
	# 协程的 await 恢复 —— 于是测试看着在跑，节点的 _physics_process 一次都没执行，
	# 断言就会以"位移 0.00 米"的形式误报（排查时靠 can_process=false / paused=true 定位）。
	paused = false
	for _frame in range(24):
		await physics_frame
		if not is_instance_valid(guard):
			break
	_check(is_instance_valid(guard), "击退过程中盾卫没有被回收")
	if not is_instance_valid(guard):
		world.free()
		await process_frame
		print("[重型反应] failures=", _failures)
		quit(1 if _failures else 0)
		return
	var travelled := (guard.global_position - push_origin)
	travelled.y = 0.0
	_check(travelled.length() > 0.5,
		"插盾中的盾卫也会被推开（实测位移 %.2f 米）" % travelled.length())
	_check(travelled.normalized().dot(away) > 0.7,
		"推开的方向是背离玩家而不是被拉近（点积 %.2f）" % travelled.normalized().dot(away))

	# ── F. 实验场的"敌人不死"开关 ──
	# 机制验证要在**挨打之后**才看得到反应（插盾 / 格挡 / 激怒），一打就死就没得看。
	# 要求：伤害照常结算、受击表现照常播，但不进入死亡。
	guard.set_meta(&"experiment_invincible", true)
	guard.set("health", 50.0)
	guard.call("take_damage", 99999.0)
	_check(float(guard.get("health")) >= 1.0 and not guard.is_queued_for_deletion(),
		"敌人不死：被打到 0 以下也不进入死亡（血 %.1f）" % float(guard.get("health")))
	guard.remove_meta(&"experiment_invincible")
	guard.call("take_damage", 99999.0)
	_check(guard.is_queued_for_deletion() or float(guard.get("health")) <= 0.0,
		"摘掉标记后照常死亡")

	world.remove_child(foe)
	foe.free()
	world.free()
	await process_frame

	print("[重型反应] failures=", _failures)
	quit(1 if _failures else 0)


func HealthUtil_alive(actor: Variant) -> bool:
	return preload("res://scripts/health_util.gd").is_alive(actor)


func _check(ok: bool, description: String) -> void:
	if not ok:
		_failures += 1
		push_error(description)
