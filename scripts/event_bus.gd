extends Node
## 全局事件总线（autoload「EventBus」）。
##
## 解决的痛点：跨模块通知原本靠"发送方直接调用接收方的静态方法"，
## 发送方因此必须知道接收方是谁、甚至得按组去查节点：
##
##     GameFlowUtil.notify_player_died(...)   # player 必须认识 game_flow
##     CombatFX.flash_hit_marker(...)         # 内部 get_first_node_in_group("player_hud")
##
## 事件总线把依赖方向倒过来：发送方只管广播，接收方自己订阅。
##
## ── 边界（防止它退化成"什么都往里塞"的垃圾桶）────────────────────────
##
##   1. 只放【跨模块】的通知。父子之间的直接调用保持原样 ——
##      Player 创建并持有 PlayerHUD，`_hud.set_health()` 比绕一层总线更好读、
##      也更好调试（栈里直接能看到谁改的 HUD）。
##   2. 只放【有真实接收方】的事件。没人订阅的信号就是死代码，
##      会让人误以为某个功能"已经接线了"。
##   3. 事件是"发生了什么"，不是"你要做什么"。带命令语义的名字
##      （如 request_spawn）说明它其实是 RPC，该走直接调用。
##
## ── 用法（沿用本项目一贯的 preload + 静态入口）──────────────────────
##
##     const EventBusUtil := preload("res://scripts/event_bus.gd")
##
##     EventBusUtil.emit_player_died(survival, kills)          # 发送
##     EventBusUtil.subscribe_player_died(_on_player_died)     # 订阅（通常在 _ready）
##
## 为什么不直接写 `EventBus.player_died.connect(...)`（那才是 Godot 的常见写法）：
## 全局 autoload 标识符在【单脚本隔离编译】下不存在 —— `godot --check-only
## --script xxx.gd` 会报 "Identifier not found: EventBus"。本项目的校验流程
## 正是建立在逐脚本 check-only 之上，而且项目里 Player / GameFlow / Audio /
## Save / Ballistics / CombatFX 全部采用 preload 静态入口（注释里写明是为了
## "autoload 未注册时自动降级"）。总线没有理由成为唯一的例外。
##
## 代价：下面每个转发函数内部用了按名字的动态 connect/emit_signal，
## 名字写错会在 connect / emit 时报错（不会静默失败）。但调用方是
## 完全类型化的，写错参数类型在编译期就会被拦下。

## 信号名常量：与下面 signal 声明一一对应，避免两处各写一次字面量。
const SIG_PLAYER_DIED := &"player_died"
const SIG_HIT_CONFIRMED := &"hit_confirmed"
const SIG_WEAPON_LEVEL_CHANGED := &"weapon_level_changed"
const SIG_WAVE_UPDATED := &"wave_updated"
const SIG_BOSS_UPDATED := &"boss_updated"
const SIG_STAGE_CLEARED := &"stage_cleared"

## autoload 实例。未注册时为 null，所有转发函数自动降级为空操作。
static var instance: Node


## 玩家死亡。发送：player.gd 的 _die()。接收：game_flow.gd（弹结算面板）。
signal player_died(survival: float, kills: int)


## 命中确认（打中敌人时触发）。发送：ballistics.gd 的 resolve_hit()。
## 接收：player_hud.gd（准星命中标记）。
##
## 之所以必须走总线：Ballistics 是无状态工具类，手里根本没有 HUD 引用，
## 原先只能用 get_first_node_in_group("player_hud") 去"猜"接收方。
signal hit_confirmed(headshot: bool, killed: bool)


## 武器等级变化。发送：player_weapon.gd 的 upgrade()。
## 接收：enemy_spawn_point.gd / survival_director.gd。
##
## 这两个原本每帧都做 get_first_node_in_group("player") + call("get_weapon_level")，
## 改成订阅后既省掉每帧的组查询，也让它们不再需要认识 Player 的接口。
##
## 契约：武器等级在一局开始时恒为 1（player_weapon._weapon_level 的初值），
## 之后只通过 upgrade() 递增。因此订阅方把"未收到过任何事件"当作 1 级是正确的。
signal weapon_level_changed(level: int)


## 波次状态快照。发送：wave_director.gd。接收：player_hud.gd（阶段/波次读数）。
##
## 用字典而不是一长串参数：HUD 需要在同一帧里读阶段、波次、状态、剩余数量、
## 倒计时。摊成六七个形参后，"加一个要显示的字段"就得改三处签名。
signal wave_updated(info: Dictionary)


## Boss 血条。active = false 表示当前没有 Boss（HUD 收起血条）。
## 发送：wave_director.gd / boss.gd。接收：player_hud.gd。
signal boss_updated(active: bool, title: String, current: float, maximum: float)


## 一个阶段（一张竞技场）被清空。发送：wave_director.gd。
## 接收：game_flow.gd —— "显示通过面板 → 切下一个竞技场"属于流程节奏，
## 不该散落在战斗节点里，所以这里只报告事实。
signal stage_cleared(stage: int)


func _ready() -> void:
	instance = self


# ---------------------------------------------------------------- 发送

static func emit_player_died(survival: float, kills: int) -> void:
	if instance:
		instance.emit_signal(SIG_PLAYER_DIED, survival, kills)


static func emit_hit_confirmed(headshot: bool, killed: bool) -> void:
	if instance:
		instance.emit_signal(SIG_HIT_CONFIRMED, headshot, killed)


static func emit_weapon_level_changed(level: int) -> void:
	if instance:
		instance.emit_signal(SIG_WEAPON_LEVEL_CHANGED, level)


# ---------------------------------------------------------------- 订阅

## 订阅方若随场景重载被释放，Godot 会自动断开该连接，无需手动清理。
static func subscribe_player_died(callback: Callable) -> void:
	if instance:
		instance.connect(SIG_PLAYER_DIED, callback)


static func subscribe_hit_confirmed(callback: Callable) -> void:
	if instance:
		instance.connect(SIG_HIT_CONFIRMED, callback)


static func subscribe_weapon_level_changed(callback: Callable) -> void:
	if instance:
		instance.connect(SIG_WEAPON_LEVEL_CHANGED, callback)


static func emit_wave_updated(info: Dictionary) -> void:
	if instance:
		instance.emit_signal(SIG_WAVE_UPDATED, info)


static func emit_boss_updated(
	active: bool, title: String, current: float, maximum: float
) -> void:
	if instance:
		instance.emit_signal(SIG_BOSS_UPDATED, active, title, current, maximum)


static func emit_stage_cleared(stage: int) -> void:
	if instance:
		instance.emit_signal(SIG_STAGE_CLEARED, stage)


static func subscribe_wave_updated(callback: Callable) -> void:
	if instance:
		instance.connect(SIG_WAVE_UPDATED, callback)


static func subscribe_boss_updated(callback: Callable) -> void:
	if instance:
		instance.connect(SIG_BOSS_UPDATED, callback)


static func subscribe_stage_cleared(callback: Callable) -> void:
	if instance:
		instance.connect(SIG_STAGE_CLEARED, callback)
