extends SceneTree
## 震地脉冲（Q）点数制回归。
##
## 【这条测试防的是什么】Q 从「固定冷却」改成「点数 + 冷却」双闸门之后，
## 有三个必须成立的性质，任何一个坏掉都只在实机里表现为"手感怪"：
##   1. **点数会扣**、扣完不能放（否则点数只是装饰）；
##   2. **冷却仍然拦得住**（用户明确要求「防止直接 3」——点数再多也不能瞬发三次）；
##   3. **点数会回充且不超上限**（否则要么永远只有 3 次，要么无限刷）。
## 这里用最小场景直接驱动，不依赖输入时序，所以结果是确定的。
const Config := preload("res://scripts/game_config.gd")
const PlayerScene: PackedScene = preload("res://scenes/player.tscn")

var _failures := 0


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	var cfg: Dictionary = Config.get_dictionary("abilities").get("skill", {})
	var want_max := int(cfg.get("charges_max", -1))
	var want_start := int(cfg.get("charges_start", -1))
	var recharge := float(cfg.get("charge_recharge_seconds", -1.0))
	var cooldown := float(cfg.get("cooldown", -1.0))
	_check(want_max > 0 and want_start > 0 and recharge > 0.0 and cooldown > 0.0,
		"配置存在 charges_max / charges_start / charge_recharge_seconds / cooldown")

	var world := Node3D.new()
	world.name = "ChargeWorld"
	root.add_child(world)
	current_scene = world

	var player: CharacterBody3D = PlayerScene.instantiate()
	world.add_child(player)
	await process_frame
	await physics_frame
	# 关掉自动物理：本测试要精确控制"哪一步触发了什么"。
	player.set_physics_process(false)
	player.set_process(false)

	# 1. 配置接线。
	_check(int(player.get("_skill_charges_max")) == want_max,
		"点数上限来自配置（实例 %d / 配置 %d）" % [int(player.get("_skill_charges_max")), want_max])
	_check(int(player.get("_skill_charges")) == want_start,
		"起手点数为满点（实例 %d / 配置 %d）" % [int(player.get("_skill_charges")), want_start])
	_check(is_equal_approx(float(player.get("skill_cooldown_time")), cooldown), "冷却来自配置")

	# 2. 有点数 + 冷却为零 → 能用，扣 1 点并进入冷却。
	player.set("_skill_charges", want_max)
	player.set("_skill_cooldown", 0.0)
	var used := await _engine_use(player)
	_check(used, "点数充足且无冷却时可以释放")
	_check(int(player.get("_skill_charges")) == want_max - 1,
		"释放扣 1 点（剩 %d）" % int(player.get("_skill_charges")))
	_check(is_equal_approx(float(player.get("_skill_cooldown")), cooldown), "释放后进入冷却")

	# 3. 【防止直接 3】冷却期间再按不能生效，也不扣点。
	var before := int(player.get("_skill_charges"))
	var used2 := await _engine_use(player)
	_check(not used2 and int(player.get("_skill_charges")) == before,
		"冷却期间不能再次释放，也不扣点（防『直接 3』）")

	# 4. 点数耗尽时即使冷却为零也不能放。
	player.set("_skill_charges", 0)
	player.set("_skill_cooldown", 0.0)
	var used3 := await _engine_use(player)
	_check(not used3 and int(player.get("_skill_charges")) == 0, "没有点数时不能释放")

	# 5. 回充：不超上限，且按配置的间隔逐个回。
	player.set("_skill_charges", 0)
	player.set("_skill_recharge_timer", recharge)
	player.call("_tick_skill_charges", recharge + 0.01)
	_check(int(player.get("_skill_charges")) == 1, "达到回充间隔后 +1 点")
	player.call("_tick_skill_charges", recharge + 0.01)
	_check(int(player.get("_skill_charges")) == 2, "再过一个间隔再 +1 点")
	player.set("_skill_charges", want_max)
	player.call("_tick_skill_charges", recharge * 10.0)
	_check(int(player.get("_skill_charges")) == want_max, "回充不会超过上限")

	# 6. 【实验场】无冷却无限次：挂上 meta 后连按三次都不扣点、不进冷却。
	#    这里的 A/B 是可信的 —— 上面第 2 步已经用同一个 `_engine_use` 证明了
	#    "注入按键 → 真的会扣点"，所以这里的"没扣"不是按键没生效造成的空过。
	#    这是"实验场无冷却"这条需求的真正验收点；实验场里玩家输入被自身状态挡住，
	#    同样的断言写在那边会永远通过。
	player.set_meta(&"experiment_unlimited_abilities", true)
	player.set("_skill_charges", want_max)
	player.set("_skill_cooldown", 0.0)
	for _i in range(3):
		var consumed := await _engine_use(player)
		_check(not consumed, "实验场标记下连按 Q 不扣点")
		_check(is_equal_approx(float(player.get("_skill_cooldown")), 0.0), "实验场标记下 Q 不进冷却")
	_check(int(player.get("_skill_charges")) == want_max, "实验场标记下点数保持满")
	player.remove_meta(&"experiment_unlimited_abilities")

	# 7. E 手雷同理，并且带对照：摘掉标记时**必须**能观察到冷却 ——
	#    否则"标记下不进冷却"可能只是按键没生效。
	player.set("_grenade_cooldown", 0.0)
	await _engine_press(player, "grenade")
	_check(float(player.get("_grenade_cooldown")) > 0.0, "对照：无标记时 E 会进冷却")
	player.set_meta(&"experiment_unlimited_abilities", true)
	player.set("_grenade_cooldown", 0.0)
	for _i in range(3):
		await _engine_press(player, "grenade")
	_check(is_equal_approx(float(player.get("_grenade_cooldown")), 0.0), "实验场标记下 E 不进冷却")
	player.remove_meta(&"experiment_unlimited_abilities")

	# 释放测试期间 `_handle_skill` 生成过震地脉冲与其网格/碰撞体；
	# 整棵测试场景一起释放，避免退出时留下 ObjectDB 泄漏（会被验收当成非零退出）。
	world.free()
	await process_frame

	print("[Q 点数] failures=", _failures)
	quit(1 if _failures else 0)


## 让引擎自己驱动一次释放：短暂打开玩家的物理处理，注入一次"按下 Q"的
## 真实输入事件，等一帧，再关掉。手动调 `_handle_skill()` 不可靠 ——
## `_just()` 走的是 `Input.is_action_just_pressed`，它只在真正处理输入的那一帧为真。
func _engine_use(player: Node) -> bool:
	var before := int(player.get("_skill_charges"))
	await _engine_press(player, "skill")
	return int(player.get("_skill_charges")) < before


## 注入一次真实按键（按下 → 等一帧物理 → 松开 → 再等一帧）。
func _engine_press(player: Node, action: String) -> void:
	player.set_physics_process(true)
	_press(action, true)
	await physics_frame
	_press(action, false)
	await physics_frame
	player.set_physics_process(false)


func _press(action: String, pressed: bool) -> void:
	var event := InputEventAction.new()
	event.action = action
	event.pressed = pressed
	Input.parse_input_event(event)
	Input.flush_buffered_events()


func _check(ok: bool, description: String) -> void:
	if not ok:
		_failures += 1
		push_error(description)
