extends RefCounted
## 一局进度（纯静态，不需要注册 autoload）。
##
## ── 为什么必须有它 ──────────────────────────────────────────────
##
## 阶段推进是靠【重载场景】换竞技场的，而场景里的一切都会被重建。所以
## "打到第几阶段、第几波、武器升到几级、叠了几层模块"这类属于【一局】而不属于
## 【一张地图】的状态，必须存在场景之外，否则每换一张图都从第 1 阶段、1 级武器
## 重新开始 —— 那不叫阶段推进，那叫重开。
##
## ── 边界 ────────────────────────────────────────────────────────
##
## 只存【一局之内、跨场景存活】的东西。跨局持久化的数据（最好成绩、总场次）
## 归 save_manager.gd，不要混进来；本模块在一局结束时会被 reset() 清空。
##
## 为什么是静态而不是 autoload：静态变量在同一个进程内本来就不会被场景重载清掉，
## 而本项目已有一套 preload + 静态入口的惯例（arena.gd / ballistics.gd / run_state 同类）。
## 用 autoload 反而要多改 project.godot，且逐脚本 check-only 时还得处理
## "Identifier not found" —— 与 event_bus.gd 注释里记着的那个坑是同一件事。

## 是否身处一局之中。false 时 get_* 返回的都是首局的初值。
static var _active := false
static var _stage := 1
## 已完成到第几波（0 = 本阶段还没打完任何一波）。
static var _wave := 0
static var _weapon_level := 1
## 升级模块层数：模块 id → 层数。
static var _upgrades: Dictionary = {}
## 选取的 Roguelite 强化卡清单（强化卡 id 列表）
static var _perks: Array = []
## 历史最好阶段（跨局保留，供结算与 HUD 显示）。
static var _best_stage := 1


## 开一局新的：从第 1 阶段、第 1 波、1 级武器开始。
static func begin_run() -> void:
	_active = true
	_stage = 1
	_wave = 0
	_weapon_level = 1
	_upgrades = {}
	_perks = []


## 结束一局。这里刻意不清 _best_stage —— 它是跨局的记录。
static func end_run() -> void:
	_active = false


static func is_active() -> bool:
	return _active


static func get_stage() -> int:
	return _stage


static func get_wave() -> int:
	return _wave


## 当前竞技场还没通过。用于区分"新开一局"与"阶段之间"。
static func is_mid_run() -> bool:
	return _active and (_stage > 1 or _wave > 0)


static func set_progress(stage: int, wave: int) -> void:
	_stage = maxi(stage, 1)
	_wave = maxi(wave, 0)


static func advance_stage() -> void:
	_stage += 1
	_wave = 0
	_best_stage = maxi(_best_stage, _stage)
	# 【每个竞技场从基础武器重新开始】
	#
	# 换图 = 换一场独立的战斗，不是接着用上一场的强度。原先跨阶段保留，
	# 一趟打下来武器能涨到 L8 以上，而每个竞技场的数值都是按"从 1 级起步"
	# 设计的 —— 后半程的 Boss 必然变成木桩（打不动反而是怪事）。
	#
	# 玩家不需要被提醒：武器变回基础这件事，配合"换了地图"本身就能读懂，
	# 而且"越往后越简单"才是真正需要解释的那件事。
	_weapon_level = 1
	_upgrades = {}


static func get_best_stage() -> int:
	return maxi(_best_stage, _stage)


## 武器等级与模块堆叠【不跨阶段】：每换一张图都从基础武器重新开始。
##
## 反过来（跨阶段保留）会让关卡难度被成长速度反超 —— 每个竞技场的数值都是
## 按"1 级起步"定的，而玩家带着上一场攒下的等级进场，后半程必然一路变简单。
## 阶段推进保留的是【进度】（第几阶段、最好成绩），不是强度。
static func get_weapon_level() -> int:
	return _weapon_level


static func set_weapon_level(level: int) -> void:
	_weapon_level = maxi(level, 1)


static func get_upgrade_stacks(id: String) -> int:
	return int(_upgrades.get(id, 0))


static func set_upgrade_stacks(id: String, stacks: int) -> void:
	if stacks <= 0:
		_upgrades.erase(id)
	else:
		_upgrades[id] = stacks


static func get_upgrades() -> Dictionary:
	return _upgrades.duplicate()


static func add_perk(id: String) -> void:
	_perks.append(id)


static func has_perk(id: String) -> bool:
	return _perks.has(id)


static func get_perk_count(id: String) -> int:
	var count := 0
	for p in _perks:
		if p == id:
			count += 1
	return count


static func get_perks() -> Array:
	return _perks.duplicate()
