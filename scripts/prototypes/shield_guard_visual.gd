extends Node3D
## 大型盾卫 · 插盾姿态的纯视觉预览角色。
##
## 【为什么整只敌人走正式生成器】颜色、体型、剖面都不是这里拼的：
## 通过 `enemy_spawner.spawn_enemy()` 用**图鉴条目 `L3ShieldGuard`** 生成，
## 于是护甲色（0.12, 0.18, 0.32）、scale 1.4、shield 剖面、gait 全都与正式游戏一致。
## 一开始手搓模型时得到的是"白盒子 + 护盾散落"——因为跳过了生成器里
## configure_melee_variant / configure_stats / apply_body_profile 这一整条链路。
##
## 姿态机同样是正式的：`_enter_shield_stance` / `_advance_shield_state` /
## `_spawn_shield_block_fx` 来自 melee_enemy，时长取自
## enemy.shield_plant_seconds / hold_seconds / lower_seconds。这里一个数字都不重写。
##
## 用法：A/D 换角色，**P 换姿态**，**M 冻结**（冻结后可以停在起手/解除的中间帧上
## 逐帧看盾面角度），B 看纯黑剪影，滚轮缩放。

const Spawner := preload("res://scripts/enemy_spawner.gd")
const ConfigUtil := preload("res://scripts/game_config.gd")

const POSE_NAMES := [
	"收盾 · 普通",
	"插盾 · 防御",
	"插盾 · 盾面受击",
	"全程循环 · 起手→防御→解除",
]
const ENTRY_ID := "L3ShieldGuard"
## 姿态 1/2 是"定格"：把相位时间设成远大于配置值，相位机就不会自己往下走。
const HOLD_SECONDS := 600.0
const BLOCK_FX_INTERVAL := 0.6

var preview_pose := 0
## 视觉台的契约之一：预览角色要能汇报"AI 已关"（`test_enemy_visual_lab` 会断言这一条）。
## 本角色的 AI 开关在内层敌人身上，这里转发 —— 否则视觉台读到 `null`，
## 而 `bool(null)` 会直接抛错并**中断整条画廊遍历**（截图脚本就是这么卡住的）。
var ai_enabled := false:
	set(value):
		ai_enabled = value
		if is_instance_valid(_enemy):
			_enemy.set("ai_enabled", value)

var _enemy: CharacterBody3D
var _fx_timer := 0.0


func _ready() -> void:
	var entry := _roster_entry()
	if entry.is_empty():
		push_error("图鉴里找不到 " + ENTRY_ID + "，盾卫预览无法生成")
		return
	# 生成器会把配置用 call_deferred 推到本帧稍后（见 enemy_spawner._build_enemy），
	# 所以这里必须等一帧才能拿到已配好的敌人与它的 ShieldPivot。
	var spawner := Spawner.new()
	spawner.name = "PreviewSpawner"
	add_child(spawner)
	_enemy = spawner.call("spawn_enemy", entry, Vector3.ZERO, 0.0) as CharacterBody3D
	_configure_preview.call_deferred()


func _process(delta: float) -> void:
	if _enemy == null:
		return
	if preview_pose == 3:
		# 真实时序：完全交给正式相位机，循环播放，便于配合 M 冻结观察中间帧。
		if int(_enemy.get("_shield_state")) == 0:
			_enemy.call("_enter_shield_stance")
		return
	if preview_pose == 2:
		_fx_timer -= delta
		if _fx_timer <= 0.0:
			_fx_timer = BLOCK_FX_INTERVAL
			_enemy.call("_spawn_shield_block_fx", Vector3.ZERO)


func set_preview_pose(index: int) -> void:
	preview_pose = posmod(index, POSE_NAMES.size())
	_apply_pose()


func get_preview_pose_name() -> String:
	return POSE_NAMES[preview_pose]


func get_preview_pose_count() -> int:
	return POSE_NAMES.size()


## 生成之后：纯观察化处理 + 摆到第一个姿态。
func _configure_preview() -> void:
	if not is_instance_valid(_enemy):
		return
	# 生成器把节点原点放在**胶囊中心**（它按 clearance 抬高到离地），
	# 而视觉台的机位预设假设"脚在挂点原点"。这里把它按自己的胶囊半高放下来，
	# 否则盾卫会悬在半空（用户反馈的"位置"就是这个）。
	var collision := _enemy.get_node_or_null("CollisionShape3D") as CollisionShape3D
	var half := 0.85 * _enemy.scale.y
	if collision != null and collision.shape is CapsuleShape3D:
		half = (collision.shape as CapsuleShape3D).height * 0.5 * _enemy.scale.y
	_enemy.position.y = half
	# 不进敌人分组：实验场统计、瞄准与共鸣爆发都不该看到它。
	_enemy.remove_from_group("enemies")
	# 关掉 AI：只播姿态与动画（物理处理保留，否则骨架不会被摆姿势）。
	ai_enabled = false
	_enemy.set("target", null)
	_enemy.collision_layer = 0
	_enemy.collision_mask = 0
	for node in _enemy.find_children("*", "Label3D", true, false):
		(node as Label3D).visible = false
	_apply_pose()


func _apply_pose() -> void:
	if not is_instance_valid(_enemy):
		return
	_fx_timer = 0.0
	match preview_pose:
		0:
			_hold_state(0)  # DOWN：剖面构建时的收盾姿态
		1:
			_hold_state(2)  # PLANTED：盾立在地上 + 身体下蹲
		2:
			_hold_state(2)  # PLANTED + 盾面火花/格挡反馈
		3:
			# 下一帧由 _process 看到 DOWN 后重新插盾，形成循环。
			_hold_state(0)


## 定格在某个相位：时间给足，相位机就不会自己往下走；姿态**立刻吸到位**，
## 因为视觉台的 M（静态）会关掉物理，靠物理帧插值的话切姿态看不到变化。
func _hold_state(state: int) -> void:
	_enemy.set("_shield_state", state)
	_enemy.set("_shield_state_time", HOLD_SECONDS)
	_enemy.call("_apply_shield_pose", 1.0)


func _roster_entry() -> Dictionary:
	var entries: Array = ConfigUtil.get_dictionary("enemy_roster").get("entries", [])
	for entry: Variant in entries:
		if entry is Dictionary and String(entry.get("id", "")) == ENTRY_ID:
			return entry
	return {}
