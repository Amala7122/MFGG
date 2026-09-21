extends Node
## 波次推进器：替代纯无尽的 DDA 刷怪（第五项）。
##
## ── 职责边界 ──────────────────────────────────────────────────────
##
## 本文件只决定【什么时候、出什么、出多少、在哪里出】。
## 单个敌人怎么构造读 enemy_roster 图鉴，不再用随机档位掷骰 —— 掷骰能把
## "大体型占比"拉高，但永远出不了"重型迫击炮"这种有明确身份与弹道图案的
## 敌人，而那正是原 15 个固定刷怪点的手工调校价值所在。
##
## ── 状态机 ───────────────────────────────────────────────────────
##
##   PREPARE → FIGHT ⇄ BREAK（共 N 波）→ BOSS → CLEARED
##
## ── 与其它刷怪路径的关系（重要）──────────────────────────────────
##
## spawn.mode = "endless" 时本节点整体休眠，survival_director 与 15 个固定
## 刷怪点照常工作。一条配置就能完整还原改动前的行为，方便对照手感、也方便
## 你正在调的难度曲线不被打断。

const ConfigUtil := preload("res://scripts/game_config.gd")
const ArenaUtil := preload("res://scripts/arena.gd")
const EventBusUtil := preload("res://scripts/event_bus.gd")
const TerrainFieldUtil := preload("res://scripts/terrain_field.gd")
const RunStateUtil := preload("res://scripts/run_state.gd")

# 只用来查"战局是否在进行中"。game_flow 不 preload wave_director，因此无环。
const GameFlowUtil := preload("res://scripts/game_flow.gd")

const TargetingUtil := preload("res://scripts/targeting.gd")

const GROUP_PLAYER := "player"

enum State { OFFLINE, PREPARE, FIGHT, BREAK, BOSS, CLEARED }

const STATE_LABELS := {
	State.OFFLINE: "休眠",
	State.PREPARE: "准备",
	State.FIGHT: "交战中",
	State.BREAK: "波间休整",
	State.BOSS: "BOSS 战",
	State.CLEARED: "阶段通过",
}

## 状态更新节流。波次倒数要显示到 0.1 秒，但没必要每帧广播。
const PUBLISH_INTERVAL := 0.2
## 兜底：状态机长时间没有任何【可识别的进展】才强制推进。
##
## 关键是"可识别的进展"—— 生成敌人、敌人死亡、状态切换都会把计时清零
##（见 _note_progress）。所以它的语义是【彻底卡死】的保护，不是【一波最多打多久】。
##
## 之前这里是 20 秒的无脑超时，结果在一波正常进行中就把波次判成清空：
## 日志里"第 1 波清空"时场上还剩 10 个敌人，而 20 秒本就是一波正常的时长。
## 在 _ready() 里从配置读入（spawn.wave_stuck_guard）。
## 这里的 const 只是"配置缺失时的兜底"，数值与配置段一致。
const DEFAULT_STUCK_GUARD := 120.0

var _stuck_guard := DEFAULT_STUCK_GUARD

## 配置读全了、本节点确实要接管波次。配置缺失 / endless 模式下恒为 false。
var _enabled := false
## 已经决定过"谁推进"（防止 run_started 与场景重载两条路径各开一次）。
var _started := false

var _state := State.OFFLINE
var _stage := 1
var _wave := 0
var _total_waves := 4
var _timer := 0.0
var _stuck := 0.0
var _publish_timer := 0.0

var _spawn_budget := 0
var _spawn_cooldown := 0.0
## 本波已经生成了几个。只用来给"每波第一个敌人"打一行日志 ——
## 排查"敌人没出来"时，有这一行就能立刻区分"压根没生成"和"生成了但在别处"。
var _wave_spawned := 0
var _boss: Node3D
var _boss_id := ""

var _arena: Dictionary = {}
var _wave_cfg: Dictionary = {}
var _spawn_cfg: Dictionary = {}
var _roster: Array = []
var _anchors: Array = []
var _alive: Array = []
var _anchor_cursor := 0
var _player: Node3D
## 敌人生成器（Enemies 容器下的 EnemySpawner）。只在服务器上有意义。
var _spawner: Node
var _weapon_level := 1
var _random := RandomNumberGenerator.new()


# ---------------------------------------------------------------- 生命周期

func _ready() -> void:
	_spawn_cfg = ConfigUtil.get_dictionary("spawn")
	if String(_spawn_cfg.get("mode", "waves")) != "waves":
		# 明确保留的退路：endless 模式下本节点不介入。
		_state = State.OFFLINE
		set_process(false)
		print("[波次] spawn.mode = endless，波次推进器休眠（纯无尽 DDA 生效）")
		return
	_arena = ArenaUtil.get_params()
	var raw: Variant = _arena.get("wave", null)
	if raw is Dictionary:
		_wave_cfg = raw as Dictionary
	if _wave_cfg.is_empty():
		# 竞技场没配 wave 段 → 不接管，避免"以为在跑波次其实一波都不出"。
		_state = State.OFFLINE
		set_process(false)
		push_warning("[波次] 竞技场 %s 没有 wave 配置，波次推进器休眠" % ArenaUtil.resolve_id())
		return
	_total_waves = maxi(int(_wave_cfg.get("count", 4)), 1)
	# 用 get_dictionary 再取 entries：game_config.gd 只提供类型化访问器
	# （get_float_array 之类要求元素全是数字），而图鉴是字典数组。
	var roster_root := ConfigUtil.get_dictionary("enemy_roster")
	var raw_entries: Variant = roster_root.get("entries", null)
	_roster = raw_entries as Array if raw_entries is Array else []
	if _roster.is_empty():
		_state = State.OFFLINE
		set_process(false)
		push_warning("[波次] enemy_roster.entries 为空，波次推进器休眠")
		return
	_stuck_guard = maxf(ConfigUtil.get_float("spawn.wave_stuck_guard", DEFAULT_STUCK_GUARD), 5.0)
	_spawner = get_parent().get_node_or_null("EnemySpawner")
	if _spawner == null:
		push_error("[波次] 找不到 EnemySpawner，本波不会出怪")
	_boss_id = String(_wave_cfg.get("boss_id", ""))
	_random.randomize()
	_build_anchors()
	EventBusUtil.subscribe_weapon_level_changed(_on_weapon_level_changed)
	# 玩家死亡后不该继续推进波次 —— 否则结算面板背后还在刷怪。
	EventBusUtil.subscribe_player_died(_on_player_died)
	_stage = RunStateUtil.get_stage()
	_enabled = true
	# 【不在 _ready 里直接开局】—— 场景是随启动加载的，那时可能还停在主菜单。
	# 切竞技场靠重载场景，新场景起来时一局已经在跑，所以这里补一次开局。
	if GameFlowUtil.is_playing():
		_start_waves()


## 一局开始时初始化波次状态机。
func _start_waves() -> void:
	if _started:
		return
	_started = true
	if not _enabled:
		return
	print("[波次] 阶段 %d · %s · 共 %d 波 · Boss=%s · 锚点 %d 个"
		% [_stage, String(_arena.get("label", ArenaUtil.resolve_id())), _total_waves,
			"无" if _boss_id.is_empty() else _boss_id, _anchors.size()])
	_enter_prepare(true)


func _on_weapon_level_changed(level: int) -> void:
	_weapon_level = level


func _on_player_died(_survival: float, _kills: int) -> void:
	set_process(false)


func _build_anchors() -> void:
	_anchors.clear()
	for pair in ArenaUtil.generate_spawn_anchors(_arena):
		var x := float(pair[0])
		var z := float(pair[1])
		# 这里只存【地面高度】，不预先加抬升量 ——
		# 抬升多少取决于生成什么东西（小兵 1.0、Boss 是 1.15×体型），
		# 由各自的生成方加，避免锚点里埋一个对 Boss 来说错误的常量。
		_anchors.append(Vector3(x, TerrainFieldUtil.height_at(x, z), z))


# ---------------------------------------------------------------- 主循环

func _process(delta: float) -> void:
	# 战局没开始就不推进。
	#
	# 这里刻意【不依赖 SceneTree.paused】：实测暂停对本节点的 _process 生效时机
	# 并不可靠 —— 无头环境下拦得住，导出产物实跑时却拦不住（主菜单期间日志里
	# 就出现了"第 1/4 波开始"）。根因是 _enter_menu() 设置 paused 的时机与场景
	# 加载/烘焙的时序相关，不值得去猜。
	#
	# 改成判断明确的战局状态之后，门控完全建立在"战局是否在进行中"上，
	# 位置与作用与这里完全一致。
	if not GameFlowUtil.is_playing():
		return
	_publish_timer -= delta
	_stuck += delta
	if _stuck > _stuck_guard and _state != State.CLEARED and _state != State.BOSS:
		push_warning("[波次] 状态 %s 超过 %.0f 秒无进展，强制推进" % [STATE_LABELS[_state], _stuck_guard])
		_advance()

	match _state:
		State.PREPARE:
			_timer -= delta
			if _timer <= 0.0:
				_start_wave()
		State.FIGHT:
			_tick_fight(delta)
		State.BREAK:
			_timer -= delta
			if _timer <= 0.0:
				_start_wave()
		State.BOSS:
			_tick_boss()

	if _publish_timer <= 0.0:
		_publish_timer = PUBLISH_INTERVAL
		_publish()


func _tick_fight(delta: float) -> void:
	_purge_dead()
	if _spawn_budget > 0:
		_spawn_cooldown -= delta
		var max_alive := maxi(int(_spawn_cfg.get("max_alive", 14)), 1)
		if _spawn_cooldown <= 0.0 and _alive.size() < max_alive:
			_spawn_one()
			_spawn_cooldown = maxf(float(_spawn_cfg.get("spawn_interval", 0.85)), 0.05)
		return
	if _alive.is_empty():
		_finish_wave()


func _tick_boss() -> void:
	if is_instance_valid(_boss):
		return
	# Boss 已经消失（被击杀了）。
	_boss = null
	_state = State.CLEARED
	_stuck = 0.0
	RunStateUtil.set_progress(_stage, _total_waves)
	print("[波次] 阶段 %d 通过（%s）" % [_stage, String(_arena.get("label", ""))])
	_publish()
	EventBusUtil.emit_stage_cleared(_stage)
	set_process(false)


func _advance() -> void:
	_stuck = 0.0
	match _state:
		State.PREPARE:
			_start_wave()
		State.FIGHT:
			_finish_wave()
		State.BREAK:
			_start_wave()
		_:
			pass


# ---------------------------------------------------------------- 阶段与波次

func _enter_prepare(first: bool) -> void:
	_state = State.PREPARE
	_wave = 0
	_timer = maxf(ConfigUtil.get_float("spawn.prepare_seconds", 4.0), 0.0) if first else 0.5
	_stuck = 0.0
	_publish()


## 把看门狗清零。凡是"确实发生了点什么"的地方都要调用它，
## 否则看门狗会退化成一个无脑计时器，在正常进行中误判成卡死。
func _note_progress() -> void:
	_stuck = 0.0


func _start_wave() -> void:
	_wave += 1
	if _wave > _total_waves:
		_start_boss()
		return
	_state = State.FIGHT
	_spawn_budget = _count_for_wave(_wave)
	_spawn_cooldown = 0.0
	_wave_spawned = 0
	_note_progress()
	RunStateUtil.set_progress(_stage, _wave - 1)
	print("[波次] 阶段 %d 第 %d/%d 波开始：%d 个敌人" % [_stage, _wave, _total_waves, _spawn_budget])
	_publish()


func _finish_wave() -> void:
	_state = State.BREAK
	_timer = maxf(float(_wave_cfg.get("intermission", 6.0)), 0.0)
	_note_progress()
	RunStateUtil.set_progress(_stage, _wave)
	print("[波次] 第 %d 波清空，休整 %.1f 秒" % [_wave, _timer])
	_publish()


func _start_boss() -> void:
	if _boss_id.is_empty():
		# 没配 Boss 的竞技场（或配置被删空）直接判通过，不要卡在这里。
		_state = State.CLEARED
		_stuck = 0.0
		_publish()
		EventBusUtil.emit_stage_cleared(_stage)
		set_process(false)
		return
	var bcfg := ConfigUtil.get_dictionary("bosses.%s" % _boss_id)
	if _spawner == null:
		return
	_boss = _spawner.call("spawn_boss", _boss_id, _pick_anchor()) as Node3D
	_state = State.BOSS
	_stuck = 0.0
	print("[波次] 阶段 %d 全部波次结束，Boss 出场：%s" % [_stage, String(bcfg.get("label", _boss_id))])
	_publish()


## 本波的敌人总数。
##
## 竞技场配置给"底数 + 每波增量"，武器等级的加量沿用原 DDA 的两个参数
## （extra_enemies_per_level / threat_level_offset）—— 这样"等级越高越挤"
## 这条你正在调的手感没有变，只是它现在作用在波次总额上，而不是同时存活数上。
func _count_for_wave(wave: int) -> int:
	var base := float(_wave_cfg.get("base_enemies", 10))
	var growth := float(_wave_cfg.get("growth_per_wave", 4))
	var total := base + growth * float(wave - 1)
	var extra_per_level := float(_spawn_cfg.get("extra_enemies_per_level", 7))
	var offset := float(_spawn_cfg.get("threat_level_offset", 4))
	total += extra_per_level * maxf(float(_weapon_level) - offset, 0.0)
	return maxi(roundi(total), 1)


# ---------------------------------------------------------------- 生成

func _spawn_one() -> void:
	var entry := _pick_entry()
	if entry.is_empty():
		# 图鉴里没有当前等级可用的敌人 —— 直接算这波出完，避免永远等下去。
		_spawn_budget = 0
		return
	var enemy := _make_enemy(entry, _pick_anchor())
	_spawn_budget -= 1
	_wave_spawned += 1
	if enemy == null:
		return
	# 每波只报第一个：既能在日志里确认"敌人真的落地了、落在哪"，
	# 又不会把日志刷满（后面的数量看"剩 N"就够）。
	if _wave_spawned == 1:
		print("[波次] 本波首个敌人：%s @ (%.0f, %.2f, %.0f)"
			% [
				String(entry.get("title", "?")),
				enemy.global_position.x,
				enemy.global_position.y,
				enemy.global_position.z,
			])
	_alive.append(enemy)
	_note_progress()
	enemy.tree_exited.connect(_on_enemy_gone.bind(enemy), CONNECT_ONE_SHOT)


func _on_enemy_gone(enemy: Node3D) -> void:
	_alive.erase(enemy)
	# 有敌人被清掉就是进展（下一波迟早会开始），把看门狗清零。
	_note_progress()


func _purge_dead() -> void:
	var index := _alive.size() - 1
	while index >= 0:
		if not is_instance_valid(_alive[index]):
			_alive.remove_at(index)
		index -= 1


## 按图鉴条目生成一个敌人。
##
## 构造本身搬到 enemy_spawner.gd，本节点只管"什么时候、在哪里出什么"。
## 数值规则没变，仍是：
##   远程血量 = Ballistics.ranged_health(tier, level)（"狙击几发打死"的契约）
##   近战血量 = health × (1 + level × health_growth)
##   伤害 / 速度 = 基准 × (1 + level × 成长)，速度封顶 max_speed_growth
func _make_enemy(entry: Dictionary, position: Vector3) -> Node3D:
	if _spawner == null:
		return null
	return _spawner.call("spawn_enemy", entry, position, float(_weapon_level)) as Node3D


func _pick_entry() -> Dictionary:
	var total := 0.0
	for entry in _roster:
		if int(entry.get("min_weapon_level", 1)) > _weapon_level:
			continue
		total += maxf(float(entry.get("weight", 1.0)), 0.0)
	if total <= 0.0:
		return {}
	var roll := _random.randf() * total
	for entry in _roster:
		if int(entry.get("min_weapon_level", 1)) > _weapon_level:
			continue
		roll -= maxf(float(entry.get("weight", 1.0)), 0.0)
		if roll <= 0.0:
			return entry
	return {}


## 选一个离玩家足够远的锚点。
##
## 沿锚点环顺序推进（游标），而不是每次随机 —— 随机会让同一方向反复出怪，
## 玩家只需要守一个口；顺序推进能逼他转身。
func _pick_anchor() -> Vector3:
	if _anchors.is_empty():
		var player := _player_position()
		return player + Vector3(0.0, 0.0, -22.0)
	var minimum := ConfigUtil.get_float("enemy_roster.anchor_min_player_distance", 14.0)
	# 上限同样是硬需求：太远的锚点可能落在敌人察觉距离之外，
	# 敌人生成后就不会来追（各竞技场 radius_max 最大 44 米）。
	var maximum := ConfigUtil.get_float("enemy_roster.anchor_max_player_distance", 34.0)
	var origin := _player_position()
	var best: Vector3 = _anchors[_anchor_cursor % _anchors.size()]
	var best_distance := -1.0
	for offset in range(_anchors.size()):
		var index := (_anchor_cursor + offset) % _anchors.size()
		var candidate: Vector3 = _anchors[index]
		# "不能贴脸刷"要按【所有玩家】判：两人分开跑时，只避开其中一个
		# 等于把敌人直接刷在另一个人的脸上。
		if TargetingUtil.any_within(self, candidate, minimum):
			continue
		# 上限按"离最近的玩家"算：锚点至少要落在某个人的追击范围内，
		# 否则敌人刷出来谁也不追。
		var nearest := TargetingUtil.nearest_to(self, candidate)
		var distance := (
			candidate.distance_to(nearest.global_position) if nearest != null else INF
		)
		if distance <= maximum:
			_anchor_cursor = (index + 1) % _anchors.size()
			return candidate
		if distance > best_distance:
			best_distance = distance
			best = candidate
	_anchor_cursor = (_anchor_cursor + 1) % _anchors.size()
	return best


func _player_position() -> Vector3:
	# 本节点是 Node（没有自己的位置），所以"最近的玩家"对它没有意义 ——
	# 这里只取任意一个玩家，用于"一个锚点都没有"时的兜底落点。
	# 真正需要"离所有玩家多远"的判断在 _pick_anchor 里按每个候选点单独算。
	if not is_instance_valid(_player):
		_player = TargetingUtil.first_player(self)
	if is_instance_valid(_player):
		return _player.global_position
	return Vector3.ZERO


static func _color(value: Variant, fallback: Color) -> Color:
	if value is Array and (value as Array).size() >= 3:
		var parts := value as Array
		return Color(float(parts[0]), float(parts[1]), float(parts[2]), 1.0)
	return fallback


# ---------------------------------------------------------------- 对外读数

func _publish() -> void:
	EventBusUtil.emit_wave_updated(get_snapshot())


## HUD 与其他系统读的波次快照。字典形式，加字段不用改签名。
func get_snapshot() -> Dictionary:
	return {
		"stage": _stage,
		"arena_id": ArenaUtil.resolve_id(),
		"arena_label": String(_arena.get("label", "")),
		"wave": _wave,
		"total_waves": _total_waves,
		"state": STATE_LABELS.get(_state, "?"),
		"remaining": _alive.size() + maxi(_spawn_budget, 0),
		"timer": maxf(_timer, 0.0),
		"boss": is_instance_valid(_boss),
	}


func is_active() -> bool:
	return _state != State.OFFLINE


func get_state() -> State:
	return _state
