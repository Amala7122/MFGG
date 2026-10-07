extends SceneTree
## 预警是一项施放承诺：输入变化不能让已经公布的攻击被 AI 撤回。
const SpatialScene := preload("res://prototypes/combat/spatial/combat_spatial_lab.tscn")
const Prop := preload("res://scripts/destructible_prop.gd")
var _lab: Node3D
var _failed := false


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	_lab = SpatialScene.instantiate()
	root.add_child(_lab)
	current_scene = _lab
	for _frame in range(8):
		await process_frame
	_lab._crowd_motion.button_pressed = false
	await _reject_before_warning()
	for scenario in [
		{"name": "玩家接近", "position": Vector3(0, 1.08, -1)},
		{"name": "玩家远离", "position": Vector3(60, 1.08, 10)},
		{"name": "玩家移到小台面", "position": Vector3(-10, 2.58, -15)},
		{"name": "玩家移到深坑", "position": Vector3(15, 1.08, -17)},
		{"name": "目标死亡"},
		{"name": "目标丢失"},
		{"name": "蓄力时受推力"},
		{"name": "蓄力时进入狂暴"},
	]:
		await _committed_leap(scenario)
	for skill in ["slam", "sweep"]:
		await _committed_melee(skill, false)
		await _committed_melee(skill, true)
	await _death_and_clear()
	paused = true
	_lab.clear_round()
	current_scene = null
	_lab.queue_free()
	await process_frame
	paused = false
	print("[泰坦施放承诺] ", "FAIL" if _failed else "PASS")
	quit(1 if _failed else 0)


func _spawn() -> CharacterBody3D:
	_lab.set_selection({_lab.SEDIMENT_TITAN_ID: 1})
	await _lab.generate_round()
	var enemy: CharacterBody3D = _lab._live_enemies[0]
	enemy.position = Vector3(0, 1.78, -3)
	enemy.ai_enabled = false
	_lab._player.position = Vector3(0, 1.08, 10)
	_lab._start_fight()
	_lab._player.process_mode = Node.PROCESS_MODE_DISABLED
	paused = false
	for _frame in range(250):
		await physics_frame
	return enemy


func _rock(at: Vector3) -> StaticBody3D:
	var rock := Prop.new()
	rock.position = at
	rock.dimensions = Vector3(0.7, 1.3, 0.7)
	_lab.get_node("NavigationRegion3D").add_child(rock)
	return rock


func _reject_before_warning() -> void:
	var enemy := await _spawn()
	# 模拟选招得到候选后、正式触发前，玩家改变位置。
	enemy._leap_plan = enemy._plan_leap()
	_check(not enemy._leap_plan.is_empty(), "初始候选合法")
	var effects := get_nodes_in_group("titan_ground_effect").size()
	for at in [Vector3(-10, 2.58, -15), Vector3(60, 1.08, 10), Vector3(0, 1.08, -1)]:
		_lab._player.position = at
		_check(not enemy.trigger_leap_attack() and not enemy._attack_area.visible,
			"落脚 / 距离不合法时在预警之前拒绝，不能使用过期候选")
	_check(get_nodes_in_group("titan_ground_effect").size() == effects
		and enemy._brain.history.is_empty(), "拒绝的技能没有蓄力效果或施放记录")
	paused = true


func _committed_leap(scenario: Dictionary) -> void:
	var enemy := await _spawn()
	var rock := _rock(Vector3(0, 0, 10))
	for _frame in range(3):
		await physics_frame
	_check(enemy.trigger_leap_attack(), scenario.name + "：合法落点显示预警")
	var warning: Transform3D = enemy._attack_area.global_transform
	var origin := enemy.global_position
	var landing: Vector3 = enemy._leap_plan.landing
	var damage: float = enemy._attack_area.damage
	_check(enemy._attack_area.visible and enemy._attack_area.phase == enemy.AttackArea.Phase.LOCKED,
		scenario.name + "：预警出现时落点已经锁定")
	if scenario.has("position"):
		_lab._player.position = scenario.position
		_check(enemy._plan_leap().is_empty(), scenario.name + "：复现旧流程起跳重判会失败的条件")
	elif scenario.name == "目标死亡":
		_lab._player.health = 0.0
	elif scenario.name == "目标丢失":
		enemy.target = null
		enemy._attack_target = null
	elif scenario.name == "蓄力时受推力":
		enemy.apply_push(Vector3.RIGHT, 60.0)
		_lab._player.position = Vector3(0, 1.08, -1)
	elif scenario.name == "蓄力时进入狂暴":
		enemy._tuning.rage_enabled = true
		enemy.take_damage(enemy.max_hp * 0.6)
		_check(enemy.is_enraged, "伤害确实触发狂暴")
		_lab._player.position = Vector3(0, 1.08, -1)
	var launched := false
	var landed := false
	var resumed := false
	var limit := ceili((enemy._p("leap_windup") + float(enemy._leap_plan.flight)
		+ enemy._p("leap_landing_hold") + enemy._p("leap_recovery") + 1.0) * 60.0)
	for _frame in range(limit):
		await physics_frame
		if enemy.current_state == enemy.State.LEAP_WINDUP:
			_check(enemy.global_position.distance_to(origin) < 0.05, "承诺蓄力期间保持起跳位置")
			_check(enemy._leap_plan.landing.is_equal_approx(landing), "承诺蓄力期间不重选落点")
		_check(enemy._attack_area.global_transform.is_equal_approx(warning), "已经公布的落地区域不追踪新目标")
		_check(is_equal_approx(enemy._attack_area.damage, damage), "已公布的这一击不改变伤害")
		launched = launched or enemy.current_state == enemy.State.LEAP_AIR
		landed = landed or (launched and enemy.current_state == enemy.State.LEAP_RECOVERY)
		if landed and enemy.current_state == enemy.State.IDLE:
			resumed = true
			break
	_check(launched and landed and resumed and rock.is_broken, scenario.name + "：完整执行起跳、落地冲击、破坏与收招")
	_check(Vector2(enemy.position.x - landing.x, enemy.position.z - landing.z).length() < 0.35,
		scenario.name + "：实际落在已公布的位置")
	_check(enemy._brain.last_result == "miss" and _lab.get_stats_snapshot().received_hits == 0,
		scenario.name + "：按原位置挥空，不改为取消或追打新位置")
	_check(not enemy._attack_area.visible and get_nodes_in_group("combat_dangers").is_empty(), "收招后清理危险信息")
	print("[泰坦施放承诺] ", scenario.name, "：launch=", launched, " impact=", landed,
		" result=", enemy._brain.last_result, " at=", enemy.position)
	rock.free()
	paused = true


func _committed_melee(skill: String, lose_target: bool) -> void:
	var enemy := await _spawn()
	enemy.position = Vector3(0, 1.78, 8)
	_lab._player.position = Vector3(0, 1.08, 12)
	var rock := _rock(Vector3(0.5, 0, 11))
	for _frame in range(3):
		await physics_frame
	if skill == "slam":
		enemy.trigger_slam_attack()
	else:
		enemy.trigger_sweep_attack()
	var shape: Dictionary = enemy._attack_area.shape.duplicate(true)
	var damage: float = enemy._attack_area.damage
	if lose_target:
		enemy.target = null
		enemy._attack_target = null
	else:
		enemy._tuning.rage_enabled = true
		enemy.take_damage(enemy.max_hp * 0.6)
		_check(enemy.is_enraged, skill + "：实际伤害触发狂暴")
	for _frame in range(220):
		await physics_frame
		_check(is_equal_approx(enemy._attack_area.damage, damage), skill + "：这一击保持预警时的伤害")
		for field in ["kind", "width", "length", "offset", "radius", "angle", "height"]:
			if shape.has(field):
				_check(enemy._attack_area.shape[field] == shape[field], skill + "：这一击保持预警时的尺寸")
		if enemy.current_state == enemy.State.IDLE:
			break
	_check(rock.is_broken and enemy._brain.last_result == ("miss" if lose_target else "hit"),
		skill + "：目标丢失 / 狂暴转换不能撤回已经公布的地面攻击")
	_check(_lab.get_stats_snapshot().received_hits == (0 if lose_target else 1), skill + "：只结算实际命中")
	rock.free()
	paused = true


func _death_and_clear() -> void:
	var enemy := await _spawn()
	var rock := _rock(Vector3(0, 0, 10))
	for _frame in range(3):
		await physics_frame
	_check(enemy.trigger_leap_attack(), "死亡清理测试进入承诺蓄力")
	enemy.take_damage(enemy.max_hp * 10.0)
	await physics_frame
	_check(not is_instance_valid(enemy) and get_nodes_in_group("combat_dangers").is_empty(), "Boss 死亡必须撤销危险并清理动作")
	for _frame in range(140):
		await physics_frame
	_check(not rock.is_broken, "死亡后的旧回调不造成幽灵冲击")
	rock.free()
	enemy = await _spawn()
	_check(enemy.trigger_leap_attack(), "重开清理测试进入承诺蓄力")
	paused = true
	await _lab.generate_round()
	_check(not is_instance_valid(enemy) and get_nodes_in_group("combat_dangers").is_empty(), "重开仍清理旧施放与危险信息")


func _check(condition: bool, message: String) -> void:
	if not condition:
		_failed = true
		push_error("[泰坦施放承诺] " + message)
