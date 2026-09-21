class_name PlayerWeapon
extends Node
## 玩家武器（从原 player.gd 中拆出）：射速 / 弹匣 / 换弹 / 后坐力 / 动态扩散 /
## 武器等级 / 子弹生成。
##
## 由 player.gd 在运行时创建并注入宿主引用，因此不需要改动 player.tscn。
## 节点路径集中在 setup() 里解析；若 player.tscn 改名，这里会给出警告而不是静默失效。
##
## 后坐力分两层：
##   1. view_kick（弧度，pitch/yaw）—— 由 player.gd 叠加到相机上，会产生真实的抬枪偏移；
##   2. visual_recoil —— 只驱动枪身模型的短促回弹，纯视觉。

## 弹药变化。由 player.gd 订阅后转给 HUD。
## 注意这几个信号都是"武器 → 它的宿主 Player"的内部通信，所以用本节点的
## 局部信号而不是事件总线；跨模块的通知（武器升级）才走 EventBus。
signal ammo_changed(current: int, capacity: int)
## 狙击弹匣状态。reload_remaining > 0 表示正在自动装填。
signal sniper_ammo_changed(current: int, capacity: int, reload_remaining: float)
const RunStateUtil := preload("res://scripts/run_state.gd")

## 已删除四个"只发不接"的死信号（fired / reload_changed / weapon_upgraded /
## ballistics_changed）：
## 它们从声明起就没有任何 connect，属于重构残留。武器等级变化改走
## EventBus.weapon_level_changed（刷怪方需要它），换弹进度则由 player.gd
## 每帧查询 is_reloading()/get_reload_ratio() 获得。

const BallisticsUtil := preload("res://scripts/ballistics.gd")
const AudioUtil := preload("res://scripts/audio_manager.gd")
const EventBusUtil := preload("res://scripts/event_bus.gd")
const ConfigUtil := preload("res://scripts/game_config.gd")

## 武器挂点独立于手臂：枪不再挂在手上，而是由 WeaponRig 统一定位与指向，
## 这样两条手臂的 IK 才能真正"追着枪走"，不会与枪的位置互相依赖成环。
const WEAPON_RIG_PATH := "PlayerModel/WeaponRig"
## 狙击在 weapon.list 里的 id。它的弹药 / 弹道参数在代码里是独立的第二套
## （weapon.sniper.*、_sniper_ammo…），所以这里只能按约定名去 list 里查它的分类。
const SNIPER_WEAPON_ID := "sniper"
const RECOIL_PIVOT_PATH := WEAPON_RIG_PATH + "/RecoilPivot"

## 腰射 / 开镜 两种持枪位置（PlayerModel 局部空间）。
const HIP_POSITION := Vector3(-0.05, 0.3, 0.2)
const ADS_POSITION := Vector3(-0.01, 0.42, 0.24)

## 握把与护木在 RecoilPivot 局部空间中的位置，供手臂 IK 抓取。
const GRIP_OFFSET := Vector3(0.0, -0.15, -0.05)
const FOREGRIP_OFFSET := Vector3(0.0, -0.105, 0.26)

@export_category("基础")
@export var shots_per_second := 7.0
@export var shot_range := 120.0

@export_category("弹匣")
@export var magazine_capacity := 30
@export var reload_duration := 1.35

@export_category("后坐力")
@export var recoil_pitch_degrees := 0.62
@export var recoil_yaw_degrees := 0.24
@export var recoil_recovery := 9.0
@export var max_view_kick_degrees := 6.5
@export var visual_recoil_strength := 0.12

@export_category("扩散")
@export var base_spread_degrees := 0.55
@export var bloom_per_shot := 0.85
@export var max_bloom_degrees := 6.5
@export var bloom_decay := 5.5
@export var ads_spread_multiplier := 0.35
@export var movement_spread_penalty := 1.8

@export_category("狙击模式（按住右键瞄准）")
@export var sniper_shots_per_second := 1.15
@export var sniper_recoil_multiplier := 3.4

@export_category("狙击弹药（独立弹匣，打空自动装填）")
@export var sniper_magazine_capacity := 5
@export var sniper_reload_duration := 5.0

@export_category("狙击伤害（固定伤害 + 血量档位匹配）")
## 基础伤害与成长系数定义在 Ballistics（SNIPER_BASE_DAMAGE / sniper_growth），
## 远程敌人的血量档位与它共用同一个成长系数，因此"几发打死"不随武器等级漂移。
##
##   基础 60，爆头 ×4.0 = 240 → 档位 0/1/2 都是一发爆头，档位 3 需要两发。
##   倍率上限受档位 3 约束：档 3 血量 = 5 × 60 × 0.92 = 276，倍率必须 < 4.6，
##   否则档 3 会塌成一发爆头，"几发打死"的档位契约被破坏。
@export var sniper_headshot_multiplier := 4.0
## 命中点高于碰撞胶囊总高度的这个比例即判定为爆头。
@export var sniper_headshot_height_ratio := 0.75
## 狙击穿透上限（一发最多击中几个敌人）。1 = 不穿透（旧行为）。
##
## 只对狙击生效；步枪一发永远只结算一个目标。穿透在【同一发】内完成：
## 命中敌人后把它排除、沿原方向继续打射线，直到打中地形或达到上限。
## 每个目标独立判定爆头、独立吃满伤害 —— 所以穿过三个杂兵 = 三次完整结算。
@export var sniper_pierce_max_targets := 3

## 由 player.gd 读取并叠加到相机（弧度）。
var view_kick := Vector2.ZERO

## 枪的"视觉朝向"，由 player.gd 每帧写入（= 身体水平朝向 + 相机俯仰）。
##
## 刻意与弹道解耦：弹道方向仍由 get_aim_point() 的准心射线决定，两者独立。
## 好处是枪不会因为相机的横向偏移、更不会因为身体转向的平滑滞后而相对身体
## "抢转" —— 之前那种"枪自己在动"的观感就是这两者不同步造成的。
var visual_direction := Vector3.ZERO

var _host: CharacterBody3D
var _camera: Camera3D
var _weapon_rig: Node3D
var _recoil_pivot: Node3D
var _muzzle: Node3D
var _muzzle_flash: MeshInstance3D
var _muzzle_light: OmniLight3D
var _gun_body: MeshInstance3D
var _gun_barrel: MeshInstance3D
var _gun_sight: MeshInstance3D
var _gun_sight_rear: MeshInstance3D
var _pose_weight := 0.0

var _weapon_level := 1
var _ammo := 0
var _sniper_ammo := 0
var _sniper_reload_timer := 0.0
var _fire_cooldown := 0.0
var _reload_timer := 0.0
var _bloom := 0.0
var _visual_recoil := 0.0
var _muzzle_flash_time := 0.0
var _aiming := false
var _movement_ratio := 0.0
var _rng := RandomNumberGenerator.new()

## 三种升级模块的层数。它们各自提供定向加成，同时**每层也算一级武器等级** ——
## 否则弹丸数 / 散布 / 基础伤害这些等级曲线就再没有提升来源了
## （原先那个"武器升级"掉落物已被这三种模块取代）。
var _upgrades: Dictionary = {
	"fire_rate": 0,
	"damage": 0,
	"magazine": 0,
}
var _upgrade_cfg: Dictionary = {}

## ── 备用弹夹（旧名"备弹池"，语义已经变了）──────────────────────
##
## 【主武器子弹无限】换弹永远能进行：备用弹夹是空的就直接给一个新的满弹匣
## （见 _finish_reload）。于是"一路没吃到子弹包"不再会导致彻底失去攻击手段 ——
## 最差也还有一个弹匣的量，足够杀掉一个怪再去找补给。
##
## 备用弹夹是【子弹包的溢出仓】：子弹包先压进弹匣，压满（magazine_ammo_max）
## 之后剩下的进这里，换弹时优先从这里取。它不再是"能不能换弹"的前置条件，
## 只是"能不能一口气补回几百发"。
##
## 狙击不参与这一条：它仍然靠自己的备用弹夹换弹（见 _update_sniper_reload）。
var _reserve := 0
var _sniper_reserve := 0
var _reserve_enabled := true
var _primary_reserve_max := 300
var _sniper_reserve_max := 40

## 武器成长曲线，在 setup() 里从 data/game_config.json 的 weapon 段读一次并缓存。
## 这些函数每帧都会被 HUD 查询（get_pellet_count / get_bullet_damage），
## 不能每次都做点号查找 —— 那需要 split 字符串再走一遍字典。
var _curve: Dictionary = {}


## ── 武器分类框架 ──────────────────────────────────────────────
##
## 配置里 weapon.classes 是"弹道范式"表（冲锋枪 / 散弹枪 / 狙击枪…），
## weapon.list 是 武器 id → class 的映射。弹道行为（几颗弹丸、有没有扇形图案、
## 按住连发还是点按）一律从 class 上取 —— 不再把某种行为焊死在某一把枪上。
##
## _class_traits 缓存的是【主武器】那一类的特征表：它和 _curve 一样处在每帧被
## HUD 查询的路径上，不能每帧再走一遍字典。
var _classes: Dictionary = {}
var _weapon_list: Dictionary = {}
var _installed_id := "smg"
var _class_traits: Dictionary = {}

## 弹匣内子弹数的硬上限，见配置里 magazine_ammo_max 的说明 ——
## 这是子弹包唯一的天花板（原先没有，所以能堆到 1000+ 发）。
var _magazine_ammo_max := 300
var _sniper_magazine_ammo_max := 15

## 上一帧的扳机状态。只给 single（点按）类武器判定"按下的一刻"用。
var _trigger_last := false


## 读"手感"参数（射速 / 弹匣 / 后坐力 / 扩散 / 狙击）。
##
## 与 player.gd 的 _read_feel_config 同理：这些是纯手感数值，原先是 @export，
## 实际上改不动。@export 默认值保留作为兜底，配置缺失时手感与改动前一致。
func _read_feel_config() -> void:
	shots_per_second = maxf(ConfigUtil.get_float("weapon.shots_per_second", 7.0), 0.1)
	shot_range = maxf(ConfigUtil.get_float("weapon.shot_range", 120.0), 1.0)
	magazine_capacity = maxi(ConfigUtil.get_int("weapon.magazine_capacity", 30), 1)
	reload_duration = maxf(ConfigUtil.get_float("weapon.reload_duration", 1.35), 0.0)

	recoil_pitch_degrees = maxf(ConfigUtil.get_float("weapon.recoil.pitch_degrees", 0.62), 0.0)
	recoil_yaw_degrees = maxf(ConfigUtil.get_float("weapon.recoil.yaw_degrees", 0.24), 0.0)
	recoil_recovery = maxf(ConfigUtil.get_float("weapon.recoil.recovery", 9.0), 0.1)
	max_view_kick_degrees = maxf(
		ConfigUtil.get_float("weapon.recoil.max_view_kick_degrees", 6.5), 0.0
	)
	visual_recoil_strength = maxf(ConfigUtil.get_float("weapon.recoil.visual_strength", 0.12), 0.0)

	base_spread_degrees = maxf(ConfigUtil.get_float("weapon.spread.base_degrees", 0.55), 0.0)
	bloom_per_shot = maxf(ConfigUtil.get_float("weapon.spread.bloom_per_shot", 0.85), 0.0)
	bloom_decay = maxf(ConfigUtil.get_float("weapon.spread.bloom_decay", 5.5), 0.0)
	max_bloom_degrees = maxf(ConfigUtil.get_float("weapon.spread.max_bloom_degrees", 6.5), 0.0)
	ads_spread_multiplier = clampf(
		ConfigUtil.get_float("weapon.spread.ads_multiplier", 0.35), 0.0, 2.0
	)
	movement_spread_penalty = maxf(
		ConfigUtil.get_float("weapon.spread.movement_penalty", 1.8), 0.0
	)

	sniper_shots_per_second = maxf(
		ConfigUtil.get_float("weapon.sniper.shots_per_second", 1.15), 0.05
	)
	sniper_recoil_multiplier = maxf(
		ConfigUtil.get_float("weapon.sniper.recoil_multiplier", 3.4), 0.0
	)
	sniper_magazine_capacity = maxi(ConfigUtil.get_int("weapon.sniper.magazine_capacity", 5), 1)
	sniper_reload_duration = maxf(
		ConfigUtil.get_float("weapon.sniper.reload_duration", 5.0), 0.0
	)
	sniper_headshot_multiplier = maxf(
		ConfigUtil.get_float("weapon.sniper.headshot_multiplier", 4.0), 1.0
	)
	sniper_headshot_height_ratio = clampf(
		ConfigUtil.get_float("weapon.headshot_height_ratio", 0.75), 0.0, 1.0
	)
	sniper_pierce_max_targets = maxi(
		ConfigUtil.get_int("weapon.sniper.pierce_max_targets", 3), 1
	)


func _curve_flat(key: String, fallback: Variant) -> Variant:
	return _curve.get(key, fallback)


## 读嵌套子表里的字段。配置文件损坏时 _curve 为空，调用方给的 fallback 全部生效。
##
## fallback 一律填【当前平衡调参后】的目标值，而不是历史默认值 —— 否则配置一坏就会
## 静默退回 21.7 倍的旧成长曲线，那正是这套数值要修掉的东西。
func _curve_field(section: String, key: String, fallback: Variant) -> Variant:
	var table: Variant = _curve.get(section, null)
	if table is Dictionary:
		return (table as Dictionary).get(key, fallback)
	return fallback


# ---------------------------------------------------------------- 武器分类框架


## 读 classes / list / installed，setup() 里调一次，之后全部走缓存。
##
## 配置缺失或被手改坏时不报错、不崩，直接退回"单发、无扇形"的保守档。这个兜底
## 方向是刻意的：宁可少打弹丸，也不要凭空多出一片散弹来。
func _read_class_config() -> void:
	_classes = ConfigUtil.get_dictionary("weapon.classes")
	_weapon_list = ConfigUtil.get_dictionary("weapon.list")
	_installed_id = ConfigUtil.get_string("weapon.installed", "smg")
	if _installed_id.is_empty() or not _weapon_list.has(_installed_id):
		_installed_id = "smg"
	_class_traits = _class_of(_installed_id)
	_magazine_ammo_max = maxi(ConfigUtil.get_int("weapon.magazine_ammo_max", 300), 1)
	_sniper_magazine_ammo_max = maxi(
		ConfigUtil.get_int("weapon.sniper.magazine_ammo_max", 15), 1
	)


## 取某个武器 id 所属 class 的特征表。id 或它引用的 class 不存在时返回空字典，
## 调用方据此落到"单发、无扇形"的保守档（见 _read_class_config）。
func _class_of(id: String) -> Dictionary:
	var entry: Variant = _weapon_list.get(id, null)
	var class_key := ""
	if entry is Dictionary:
		class_key = String((entry as Dictionary).get("class", ""))
	var traits: Variant = _classes.get(class_key, null)
	if traits is Dictionary:
		return traits as Dictionary
	return {}


## 主武器当前的射击节奏。缺配置时按 auto —— 与改动前"按住即连发"的行为一致。
func _fire_mode() -> String:
	return String(_class_traits.get("fire_mode", "auto"))


## 武器显示名（给 HUD 用，让"这把枪属于哪一类"在界面上可见）。
## 优先取 list 条目自己的 label，没有就取 class 的；两者都缺时返回空串，
## 调用方跳过绘制即可，不要画出一个空白标签。
func get_weapon_label() -> String:
	return _weapon_label_for(_installed_id)


func get_sniper_label() -> String:
	return _weapon_label_for(SNIPER_WEAPON_ID)


func _weapon_label_for(id: String) -> String:
	var entry: Variant = _weapon_list.get(id, null)
	if entry is Dictionary:
		var own := String((entry as Dictionary).get("label", ""))
		if not own.is_empty():
			return own
	return String(_class_of(id).get("label", ""))


func setup(host: CharacterBody3D, camera_node: Camera3D) -> void:
	_host = host
	_camera = camera_node
	_rng.randomize()
	# 读一次成长曲线并缓存（见 _curve 的说明）。
	_curve = ConfigUtil.get_dictionary("weapon")
	var upgrade_table: Variant = _curve.get("upgrades", null)
	if upgrade_table is Dictionary:
		_upgrade_cfg = upgrade_table as Dictionary
	_read_class_config()
	_read_reserve_config()
	_read_feel_config()
	# 先恢复成长再算容量：弹匣容量是基础值 + 弹匣模块层数，顺序反了会少算。
	_restore_progress()
	_ammo = get_capacity()
	_sniper_ammo = get_sniper_capacity()
	_weapon_rig = host.get_node_or_null(WEAPON_RIG_PATH)
	_recoil_pivot = host.get_node_or_null(RECOIL_PIVOT_PATH)
	if _recoil_pivot:
		_muzzle = _recoil_pivot.get_node_or_null("Muzzle")
		_gun_body = _recoil_pivot.get_node_or_null("GunBody")
		_gun_barrel = _recoil_pivot.get_node_or_null("Barrel")
		_gun_sight = _recoil_pivot.get_node_or_null("Sight")
		_gun_sight_rear = _recoil_pivot.get_node_or_null("SightRear")
	if _muzzle:
		_muzzle_flash = _muzzle.get_node_or_null("MuzzleFlash")
		_muzzle_light = _muzzle.get_node_or_null("MuzzleLight")
	if not _weapon_rig or not _muzzle:
		push_warning("PlayerWeapon: 未找到 WeaponRig/Muzzle，武器系统已禁用")
		return
	_set_muzzle_flash(false)
	apply_weapon_visual_upgrade()
	ammo_changed.emit(_ammo, get_capacity())
	sniper_ammo_changed.emit(_sniper_ammo, get_sniper_capacity(), 0.0)


# ---------------------------------------------------------------- 每帧驱动

func update(delta: float, trigger_held: bool, aiming: bool, movement_ratio: float) -> void:
	_aiming = aiming
	_movement_ratio = clampf(movement_ratio, 0.0, 1.6)

	_fire_cooldown = maxf(_fire_cooldown - delta, 0.0)
	_bloom = maxf(_bloom - delta * bloom_decay, 0.0)
	view_kick = view_kick.lerp(Vector2.ZERO, minf(delta * recoil_recovery, 1.0))
	_visual_recoil = move_toward(_visual_recoil, 0.0, delta * 0.9)
	if _recoil_pivot:
		_recoil_pivot.rotation.x = -_visual_recoil
	_pose_weapon(delta)
	_update_muzzle_flash(delta)

	# 狙击弹匣的自动装填独立于冲锋枪换弹，必须放在任何早退之前。
	_update_sniper_reload(delta)

	# 点按（single）类武器只在扳机【按下的一刻】开火，按住不放不连发。
	# 这一步刻意放在换弹早退之前：否则按住扳机过完一次换弹，会在换弹结束的那一帧
	# 被判成一次新的"按下"，白打一发。
	var trigger_pressed := trigger_held
	if _fire_mode() == "single":
		trigger_pressed = trigger_held and not _trigger_last
	_trigger_last = trigger_held

	if _reload_timer > 0.0:
		_reload_timer = maxf(_reload_timer - delta, 0.0)
		if _reload_timer <= 0.0:
			_finish_reload()
		return

	if not trigger_held:
		return
	if _aiming:
		# 狙击：独立弹匣，打空后 5 秒自动装填，装填期间不能开火。
		# 它有自己的触发路径（按住即按射速连发），刻意【不读】class 的 fire_mode ——
		# 右键是"开镜"不是"点按"，这两种节奏是两回事。
		if _sniper_reload_timer <= 0.0 and _sniper_ammo > 0 and _fire_cooldown <= 0.0:
			fire()
		return
	if not trigger_pressed:
		return
	if _ammo <= 0:
		start_reload()
		return
	if _fire_cooldown <= 0.0:
		fire()


# ---------------------------------------------------------------- 开火

## 持枪姿态：在腰射/开镜两个位置之间混合，并让枪管始终指向准心命中点。
## 后坐视觉留在 RecoilPivot 上，避免与这里的 look_at 互相覆盖。
func _pose_weapon(delta: float) -> void:
	if not _weapon_rig:
		return
	_pose_weight = move_toward(_pose_weight, 1.0 if _aiming else 0.0, minf(delta * 13.0, 1.0))
	_weapon_rig.position = HIP_POSITION.lerp(ADS_POSITION, _pose_weight)
	var direction := visual_direction
	if direction.is_zero_approx():
		direction = -_camera.global_basis.z if _camera else Vector3.FORWARD
	direction = direction.normalized()
	var up := Vector3.UP
	if absf(direction.dot(Vector3.UP)) > 0.98:
		up = -(_host.global_basis.z) if is_instance_valid(_host) else Vector3.FORWARD
	# 注意第三参数必须为 true：Godot 的 look_at 默认让 -Z 指向目标，
	# 而枪口在 +Z 方向，漏掉它会让枪整体转 180°（枪口朝自己的胸口）。
	_weapon_rig.look_at(_weapon_rig.global_position + direction, up, true)


## 握把在世界空间的位置（持枪主手 IK 目标）。
func get_grip_world() -> Vector3:
	if not _recoil_pivot:
		return Vector3.ZERO
	return _recoil_pivot.global_transform * GRIP_OFFSET


## 护木在世界空间的位置（支撑手 IK 目标）。
func get_foregrip_world() -> Vector3:
	if not _recoil_pivot:
		return Vector3.ZERO
	return _recoil_pivot.global_transform * FOREGRIP_OFFSET


func fire() -> void:
	if not _weapon_rig or not _muzzle:
		return
	var aim_point := get_aim_point()
	var base_direction := (aim_point - _muzzle.global_position).normalized()
	if _aiming:
		if _sniper_ammo <= 0 or _sniper_reload_timer > 0.0:
			return
		_fire_sniper(base_direction)
		_sniper_ammo -= 1
		sniper_ammo_changed.emit(_sniper_ammo, get_sniper_capacity(), _sniper_reload_timer)
	else:
		_fire_rapid(base_direction)
		_ammo = maxi(_ammo - 1, 0)
		ammo_changed.emit(_ammo, get_capacity())
	_visual_recoil = minf(
		_visual_recoil + visual_recoil_strength
			* (1.0 + float(_weapon_level) * float(_curve_flat("visual_recoil_per_level", 0.08)))
			* (sniper_recoil_multiplier * 0.6 if _aiming else 1.0),
		visual_recoil_strength * 2.2 * (sniper_recoil_multiplier if _aiming else 1.0)
	)
	_apply_view_kick()
	_muzzle_flash_time = 0.055
	_set_muzzle_flash(true)
	AudioUtil.play("sniper" if _aiming else "shot", -4.0)


## 腰射：按当前武器的【分类】决定打几颗弹丸（冲锋枪 = 1 颗；散弹枪类 = 扇形多颗），
## 射速随武器等级提升。
func _fire_rapid(base_direction: Vector3) -> void:
	var spread := deg_to_rad(get_current_spread_degrees())
	var pattern_spread := get_pattern_spread_degrees()
	var pellets := get_pellet_count()
	var camera_right := _camera.global_basis.x if _camera else Vector3.RIGHT
	for index in range(pellets):
		var yaw := 0.0
		if pellets > 1:
			yaw = deg_to_rad(lerpf(-pattern_spread, pattern_spread, float(index) / float(pellets - 1)))
		yaw += _rng.randf_range(-spread, spread)
		var pitch := _rng.randf_range(-spread, spread) * 0.6
		var direction := base_direction.rotated(Vector3.UP, yaw).rotated(camera_right, pitch)
		# 玩家的射击固定为瞬发命中：原先的"T 键切换弹丸"已删除，
		# 玩家侧的飞行弹（bullet.gd / sniper_bullet.gd）随之退役。
		# 敌人弹幕仍然是飞行弹丸 —— 这个不对称是刻意保留的：
		# 玩家拿到即时反馈，敌人留下可读可躲的预警。
		_fire_hitscan(direction, false)
	var fire_rate_bonus := minf(
		1.0 + float(_weapon_level - 1) * float(_curve_flat("fire_rate_bonus_per_level", 0.09)),
		float(_curve_flat("fire_rate_bonus_max", 1.5))
	)
	_fire_cooldown = 1.0 / maxf(
		shots_per_second * fire_rate_bonus * get_fire_rate_multiplier(), 0.1
	)
	var bloom_growth := float(_curve_flat("bloom_growth_per_level", 0.05))
	_bloom = minf(_bloom + bloom_per_shot * (1.0 + float(_weapon_level) * bloom_growth), max_bloom_degrees)


## 狙击：单发、零散布（刻意不叠加 bloom），固定伤害 + 血量档位匹配远程敌人。
func _fire_sniper(base_direction: Vector3) -> void:
	_fire_cooldown = 1.0 / maxf(sniper_shots_per_second * get_fire_rate_multiplier(true), 0.05)
	_fire_hitscan(base_direction, true)


## 沿 direction 从 origin 打射线，收集这一发命中的所有目标。
##
## 非狙击只取第一个命中；狙击按 sniper_pierce_max_targets 连续穿透，每个目标
## 独立判爆头、独立算伤害。命中地形 / 掩体即中止（子弹被挡住）；已命中的敌人
## 会被排除，因此不会在同一发里反复打同一个目标。
##
## 返回 Array[Dictionary]，每项含：collider / position / normal / is_enemy /
## headshot / amount。调用方（本地结算或服务器复算）负责施加伤害与出表现。
func _collect_hits(direction: Vector3, sniper: bool, origin: Vector3) -> Array:
	var hits: Array = []
	if not is_instance_valid(_host):
		return hits
	var world := _host.get_world_3d()
	if world == null:
		return hits
	var max_targets := sniper_pierce_max_targets if sniper else 1
	var exclude: Array[RID] = [_host.get_rid()]
	for _i in range(maxi(max_targets, 1)):
		var query := PhysicsRayQueryParameters3D.create(origin, origin + direction * shot_range)
		query.collision_mask = 5
		query.collide_with_areas = true
		query.exclude = exclude
		var hit := world.direct_space_state.intersect_ray(query)
		if hit.is_empty():
			break
		var collider := hit.collider as Node
		var enemy := collider as Node3D
		var is_enemy := enemy != null and collider.is_in_group("enemies")
		var position: Vector3 = hit.position
		var headshot := (
			is_enemy and sniper
			and BallisticsUtil.is_headshot(enemy, position.y, sniper_headshot_height_ratio)
		)
		var amount := get_bullet_damage()
		if sniper:
			amount = BallisticsUtil.damage_with_headshot(
				BallisticsUtil.sniper_damage(_weapon_level), sniper_headshot_multiplier, headshot
			)
		hits.append({
			"collider": collider,
			"position": position,
			"normal": hit.get("normal", Vector3.UP),
			"is_enemy": is_enemy,
			"headshot": headshot,
			"amount": amount,
		})
		# 打到地形 / 掩体：子弹被挡下，穿透到此为止。
		if not is_enemy:
			break
		exclude.append(collider.get_rid())
	return hits


## 瞬发命中：从枪口直接打射线结算，不做飞行。
## 这是"关闭子弹飞行时间"的实现，用来对比手感；命中规则与弹丸完全一致。
func _fire_hitscan(direction: Vector3, sniper: bool) -> void:
	if not is_instance_valid(_host) or not _muzzle:
		return
	var scene := _host.get_tree().current_scene
	if not scene:
		return
	var origin := _muzzle.global_position
	var hits := _collect_hits(direction, sniper, origin)
	if hits.is_empty():
		return
	var impact_scale := 1.4 if sniper else 1.0
	# 穿透时逐个目标依次结算。
	for entry in hits:
		var killed := BallisticsUtil.apply_damage(
			entry["collider"], entry["amount"], entry["position"], entry["headshot"]
		)
		BallisticsUtil.play_hit_feedback_flagged(
			scene, entry["position"], entry["normal"], entry["is_enemy"],
			entry["amount"], entry["headshot"], killed, impact_scale, true
		)


## 后坐力抬枪：朝上 + 随机左右的瞬时偏移，由 update() 平滑回收。
func _apply_view_kick() -> void:
	var scale := 1.0 + float(_weapon_level) * float(_curve_flat("view_kick_per_level", 0.07))
	if _aiming:
		# 狙击模式后坐力显著更大，而不是像普通 ADS 那样更小。
		scale *= sniper_recoil_multiplier
	var kick_pitch := deg_to_rad(recoil_pitch_degrees * scale) * _rng.randf_range(0.82, 1.25)
	var kick_yaw := deg_to_rad(recoil_yaw_degrees * scale) * _rng.randf_range(-1.0, 1.0)
	view_kick.x = clampf(
		view_kick.x + kick_pitch, -deg_to_rad(max_view_kick_degrees), deg_to_rad(max_view_kick_degrees)
	)
	view_kick.y = clampf(
		view_kick.y + kick_yaw, -deg_to_rad(max_view_kick_degrees), deg_to_rad(max_view_kick_degrees)
	)


## 相机中心射线的命中点；无命中时取射程末端。
func get_aim_point() -> Vector3:
	if not _camera:
		return _muzzle.global_position + Vector3.FORWARD * shot_range
	var ray_origin := _camera.global_position
	var ray_end := ray_origin - _camera.global_basis.z * shot_range
	var query := PhysicsRayQueryParameters3D.create(ray_origin, ray_end)
	if is_instance_valid(_host):
		query.exclude = [_host.get_rid()]
	var hit := _camera.get_world_3d().direct_space_state.intersect_ray(query)
	return hit.position if hit else ray_end


# ---------------------------------------------------------------- 扩散

## 当前总散布（度）= 基础 + bloom + 移动惩罚，ADS 下整体收窄。
func get_current_spread_degrees() -> float:
	var spread := base_spread_degrees + _bloom
	spread *= 1.0 + _movement_ratio * movement_spread_penalty
	if _aiming:
		spread *= ads_spread_multiplier
	return spread


## bloom 占上限的比例，供 HUD 准星扩散使用。
func get_bloom_ratio() -> float:
	var reference := maxf(max_bloom_degrees, 0.01)
	var ratio := (base_spread_degrees + _bloom) / (base_spread_degrees + reference)
	if _aiming:
		ratio *= ads_spread_multiplier
	return clampf(ratio, 0.0, 1.0)


# ---------------------------------------------------------------- 弹匣

func is_reloading() -> bool:
	return _reload_timer > 0.0


func get_reload_ratio() -> float:
	if _reload_timer <= 0.0:
		return 0.0
	return clampf(1.0 - _reload_timer / maxf(reload_duration, 0.01), 0.0, 1.0)


func get_ammo() -> int:
	return _ammo


## 弹匣容量 = 基础值 + 弹匣模块层数 × 每层加成。
func get_capacity() -> int:
	var per_stack := int(_upgrade_effect("magazine", "capacity_per_stack", 5.0))
	return magazine_capacity + _upgrade_stacks("magazine") * per_stack


## 换弹耗时。弹匣模块可以顺带改变它（reload_per_stack，默认 0 = 不影响），
## 想把它做成有代价的选择就把它设成正数。
func get_reload_duration() -> float:
	var per_stack := _upgrade_effect("magazine", "reload_per_stack", 0.0)
	var scale := 1.0 + float(_upgrade_stacks("magazine")) * per_stack
	return maxf(reload_duration * scale, 0.2)


## 备用弹夹里的存货（还没压进弹匣的那一份）。
## -1 = 该机制被配置关掉了（此时主武器照样无限，只是没有存货可攒）。
func get_reserve() -> int:
	return -1 if not _reserve_enabled else _reserve


func get_sniper_reserve() -> int:
	return -1 if not _reserve_enabled else _sniper_reserve


func has_reserve_pool() -> bool:
	return _reserve_enabled


## 子弹包：【直接压进弹匣】，压满之后再进【备用弹夹】。
## 返回实际补进去的总数。
##
## ── 为什么不是"补备弹池" ────────────────────────────────────────
##
## 补备弹池的话，捡到子弹还得先换一次弹才能真正用上 —— 而换弹有两个动作延迟，
## 打起来节奏老被打断（尤其是被围住的时候，最不该停的就是这半秒）。
## 直接进弹匣之后，"捡子弹"本身就是即时的战力补充，不需要停下来。
##
## ── 为什么两个仓都要封顶 ────────────────────────────────────────
##
## 弹匣上限（weapon.magazine_ammo_max，300）：这条路径原先没有上限，实测能堆到
## 1000+ 发，换弹这一环直接消失 —— 游戏从"管理弹药"变成"无脑横扫"。
##
## 备用弹夹上限（weapon.reserve.primary_max，300）：它承接弹匣压满之后的溢出。
## 不封顶的话，"捡一个包"就能把备用仓堆到几千，之后每次换弹都直接补满上限，
## 等于把上面那个 300 的封顶从后门绕过去了。两个仓同一个上限，语义也简单：
## 全身最多存 600 发，其中弹匣 300、备夹 300。
##
## 两个仓都满了就返回 0，掉落物【不被消耗】—— 玩家可以留在原地，打空了再回来捡。
##
## 注意上限（300）与弹匣容量（30 + 5×模块层数）是两件事：容量决定"一次换弹至少
## 给多少"，上限只兜住子弹包的溢出，两者互不干扰。
func add_ammo(primary: int, sniper: int) -> int:
	var add_primary := maxi(primary, 0)
	var add_sniper := maxi(sniper, 0)
	if add_primary <= 0 and add_sniper <= 0:
		return 0
	# 先算"实际装得进去多少"再写回：返回值必须是真实补进去的量，否则调用方会
	# 以为捡到了、把掉落物吃掉，而玩家什么都没拿到。
	var taken_primary := mini(add_primary, maxi(_magazine_ammo_max - _ammo, 0))
	# 弹匣压满之后剩下的进备用弹夹 —— 这一份不会立刻变成战力，但换弹时优先取它。
	var taken_spare := mini(
		add_primary - taken_primary, maxi(_primary_reserve_max - _reserve, 0)
	)
	var taken_sniper := mini(add_sniper, maxi(_sniper_magazine_ammo_max - _sniper_ammo, 0))
	_ammo += taken_primary
	_reserve += taken_spare
	_sniper_ammo += taken_sniper
	return taken_primary + taken_spare + taken_sniper


func get_sniper_ammo() -> int:
	return _sniper_ammo


## 狙击弹匣容量。默认不受弹匣模块影响（见配置里 magazine.apply_to_sniper）——
## 狙击只有 5 发，+5 的收益远大于主武器，是否共享加成应当是可选的。
func get_sniper_capacity() -> int:
	if not _upgrade_flag("magazine", "apply_to_sniper", false):
		return sniper_magazine_capacity
	var per_stack := int(_upgrade_effect("magazine", "capacity_per_stack", 5.0))
	return sniper_magazine_capacity + _upgrade_stacks("magazine") * per_stack


func get_sniper_reload_remaining() -> float:
	return _sniper_reload_timer


func is_sniper_reloading() -> bool:
	return _sniper_reload_timer > 0.0


## 狙击弹匣打空后自动装填（5 秒一组），无需手动按 R。
func _update_sniper_reload(delta: float) -> void:
	var capacity := get_sniper_capacity()
	if _sniper_reload_timer > 0.0:
		_sniper_reload_timer = maxf(_sniper_reload_timer - delta, 0.0)
		if _sniper_reload_timer <= 0.0:
			if _reserve_enabled:
				var taken := mini(capacity - _sniper_ammo, _sniper_reserve)
				_sniper_ammo += taken
				_sniper_reserve -= taken
			else:
				_sniper_ammo = capacity
		sniper_ammo_changed.emit(_sniper_ammo, capacity, _sniper_reload_timer)
	elif _sniper_ammo <= 0 and ((not _reserve_enabled) or _sniper_reserve > 0):
		_sniper_reload_timer = sniper_reload_duration
		sniper_ammo_changed.emit(_sniper_ammo, capacity, _sniper_reload_timer)


func start_reload() -> void:
	# 按住右键时 R 键装填的是狙击弹匣，否则装填冲锋枪。
	if _aiming:
		var sniper_capacity := get_sniper_capacity()
		var sniper_can_reload := (not _reserve_enabled) or _sniper_reserve > 0
		if _sniper_reload_timer <= 0.0 and _sniper_ammo < sniper_capacity and sniper_can_reload:
			_sniper_reload_timer = sniper_reload_duration
			sniper_ammo_changed.emit(_sniper_ammo, sniper_capacity, _sniper_reload_timer)
		return
	# 【弹匣满了不让换】—— 换弹本来就是把弹匣补到容量，满了再换是白白停一下。
	# 这一条同时也是"弹匣里堆到 300 发时不会误触换弹"的保证。
	if _reload_timer > 0.0 or _ammo >= get_capacity():
		return
	# 【主武器不再有"没备弹就换不了"这一条】原先备弹打空就装不了，
	# 而备弹只能靠子弹包补 —— 一旦包捡不到，玩家就彻底失去攻击手段。
	# 那是无解局面，不是难度。现在换弹永远成立，缺的只是"能一口气补多少"。
	_reload_timer = get_reload_duration()


func _finish_reload() -> void:
	_reload_timer = 0.0
	var capacity := get_capacity()
	# 换弹 = 往弹匣里补到硬上限，优先用备用弹夹的存货。
	#
	# 【为什么不只补到容量】备用弹夹里可能攒着几百发（子弹包溢出来的），
	# 一次换弹只让装 30 发的话，那些存货要反复换十次才用得上 ——
	# 存进去容易、取出来难，等于不存在。所以一次尽量取满。
	var headroom := maxi(_magazine_ammo_max - _ammo, 0)
	var taken := mini(_reserve, headroom)
	if taken > 0:
		_ammo += taken
		_reserve -= taken
	else:
		# 备用弹夹空了：主武器子弹无限，保底给一个【满弹匣】。
		# 未强化是 30 发，强化过就按强化后的容量给 —— 用 get_capacity() 而不是
		# 写死 30，弹匣模块才有意义。
		_ammo = capacity
	ammo_changed.emit(_ammo, capacity)


# ---------------------------------------------------------------- 等级与视觉

func get_level() -> int:
	return _weapon_level


## 读备用弹夹参数。放在配置里而不是 @export：它与"子弹包掉落"是配套的一对，
## 必须能一起调（改了上限，掉落量也该跟着改）。
func _read_reserve_config() -> void:
	var table := ConfigUtil.get_dictionary("weapon.reserve")
	_reserve_enabled = ConfigUtil.get_bool("weapon.reserve.enabled", true)
	_primary_reserve_max = maxi(int(table.get("primary_max", 300)), 0)
	_sniper_reserve_max = maxi(int(table.get("sniper_max", 40)), 0)
	if not _reserve_enabled:
		# 关掉就等于"没有备用仓"：主武器照样无限（保底满弹匣），
		# 只是不再有任何存货，也就不会出现"关了机制却还留着 180 发"这种自相矛盾。
		_reserve = 0
		_sniper_reserve = 0
		return
	_reserve = clampi(int(table.get("primary_start", 180)), 0, _primary_reserve_max)
	_sniper_reserve = clampi(int(table.get("sniper_start", 20)), 0, _sniper_reserve_max)


## 从一局进度里恢复武器成长。
##
## 阶段推进是靠重载场景换竞技场的，不恢复的话每换一张图都会退回 1 级、
## 模块层数清零 —— 前一阶段的成长全部作废，阶段推进就失去了意义。
##
## 新开一局时 RunState 就是初值（1 级 / 0 层），所以"新开一局"与"阶段之间"
## 走的是同一条路径，这里不需要分支。
func _restore_progress() -> void:
	if not RunStateUtil.is_active():
		return
	_weapon_level = RunStateUtil.get_weapon_level()
	for kind in _upgrades.keys():
		_upgrades[kind] = RunStateUtil.get_upgrade_stacks(String(kind))
	# 恢复完必须广播等级：wave_director 与 enemy_spawn_point 都是订阅方，
	# 它们的缓存初值是 1，不通知就会按 1 级出怪。
	EventBusUtil.emit_weapon_level_changed(_weapon_level)


## 纯等级提升（保留给调试与旧接口）。游戏内的提升现在都走 apply_upgrade()。
func upgrade() -> bool:
	_weapon_level += 1
	RunStateUtil.set_weapon_level(_weapon_level)
	apply_weapon_visual_upgrade()
	# 走事件总线：刷怪方订阅它来缓存等级，不必每帧 player.call("get_weapon_level")。
	EventBusUtil.emit_weapon_level_changed(_weapon_level)
	return true


## 拾取一个升级模块。kind ∈ {"fire_rate", "damage", "magazine"}。
##
## 返回值有讲究：false 表示"已达到层数上限"，调用方据此【不消耗掉落物】——
## 否则玩家满了之后会白白踩掉模块。
func apply_upgrade(kind: String) -> bool:
	if not _upgrades.has(kind):
		push_error("PlayerWeapon: 未知的升级模块 %s" % kind)
		return false
	var max_stacks := int(_upgrade_effect(kind, "max_stacks", 8.0))
	if max_stacks > 0 and _upgrade_stacks(kind) >= max_stacks:
		return false
	_upgrades[kind] = _upgrade_stacks(kind) + 1
	# 等级与模块并行推进：等级维持既有曲线（弹丸/散布/基础伤害/档位血量契约），
	# 模块提供定向加成。
	_weapon_level += 1
	# 写回一局进度，供阶段之间保留。
	RunStateUtil.set_weapon_level(_weapon_level)
	RunStateUtil.set_upgrade_stacks(kind, _upgrade_stacks(kind))
	apply_weapon_visual_upgrade()
	EventBusUtil.emit_weapon_level_changed(_weapon_level)
	return true


func get_upgrade_stacks(kind: String) -> int:
	return _upgrade_stacks(kind)


func _upgrade_stacks(kind: String) -> int:
	return int(_upgrades.get(kind, 0))


## 读某个模块的参数，带兜底（配置损坏时回退到 fallback）。
func _upgrade_effect(kind: String, key: String, fallback: float) -> float:
	var table: Variant = _upgrade_cfg.get(kind, null)
	if table is Dictionary:
		var value: Variant = (table as Dictionary).get(key, null)
		if value is float or value is int:
			return float(value)
	return fallback


func _upgrade_flag(kind: String, key: String, fallback: bool) -> bool:
	var table: Variant = _upgrade_cfg.get(kind, null)
	if table is Dictionary:
		var value: Variant = (table as Dictionary).get(key, null)
		if value is bool:
			return value
	return fallback


## 射速倍率（1.0 = 无加成）。狙击是否受益由配置的 apply_to_sniper 决定。
func get_fire_rate_multiplier(sniper: bool = false) -> float:
	if sniper and not _upgrade_flag("fire_rate", "apply_to_sniper", true):
		return 1.0
	return 1.0 + float(_upgrade_stacks("fire_rate")) * _upgrade_effect("fire_rate", "per_stack", 0.08)


## 威力倍率（1.0 = 无加成）。
##
## 默认【不影响狙击】：远程敌人的血量是按"狙击几发打死"定的档位，
## 一旦狙击伤害被加成，那个契约当场失效。射速模块没有这个问题，所以默认两边都吃。
func get_damage_multiplier(sniper: bool = false) -> float:
	if sniper and not _upgrade_flag("damage", "apply_to_sniper", false):
		return 1.0
	return 1.0 + float(_upgrade_stacks("damage")) * _upgrade_effect("damage", "per_stack", 0.1)


## 以下三条曲线的数值都来自 data/game_config.json 的 weapon 段，
## 参数里的字面量是兜底默认值（配置丢失时手感与改动前完全一致）。
##
## 统一模型：per_level 数组给出前几级的显式档位，其后的等级走线性段
##   late_base + (等级 - 线性段起点) × late_per_level
## 线性段起点 = per_level.size() + 1（与本文件改动前的 "4 级起" 一致）。

## 每发的弹丸数。由【武器分类】决定：class 没声明 pellet_curve 就是单发（冲锋枪）。
##
## 原先是硬编码去读 pellet_count 曲线，等于所有枪都自带"弹丸越打越多"——
## 那本是散弹枪的特征，却被焊在了冲锋枪身上。现在这条曲线只归 classes.shotgun，
## 详见 game_config.json 的 weapon._cancel_shotgun_doc。
func get_pellet_count() -> int:
	var curve_key := String(_class_traits.get("pellet_curve", ""))
	if curve_key.is_empty():
		return 1
	return _pellet_count_from_curve(curve_key)


## 弹丸曲线的求值本身（4 级起每 2 级 +1 颗：L4→5, L6→6, L8→7，封顶 7）。
## 步进与封顶原本是 +2 / 11，弹丸是成长曲线上最大的乘数
## （×11，而射速只 ×1.99、单发 ×0.99），详见 weapon._pellet_balance_doc。
##
## _weapon_level 是 int，所以这里的 `/` 是整数除法 —— 这是刻意的档位步进，
## 不是漏写小数点（漏写会触发 INTEGER_DIVISION 警告）。用 @warning_ignore 显式
## 声明意图，比写成 float()/floori() 更能说明"这里就该整除"。
@warning_ignore("integer_division")
func _pellet_count_from_curve(curve_key: String) -> int:
	var per_level: Array = _curve_field(curve_key, "per_level", [1, 2, 3])
	if _weapon_level <= per_level.size():
		return int(per_level[_weapon_level - 1])
	var late_start := per_level.size() + 1
	var step_levels := maxi(int(_curve_field(curve_key, "late_step_levels", 2)), 1)
	var steps := (_weapon_level - late_start) / step_levels
	var base := int(_curve_field(curve_key, "late_base", 5))
	var step_pellets := int(_curve_field(curve_key, "late_step_pellets", 1))
	var cap := int(_curve_field(curve_key, "late_max", 7))
	return mini(base + steps * step_pellets, cap)


## 扇形图案宽度（度）。同样由分类决定：class 没声明 pattern_spread_curve 就没有扇形
## —— 单发武器用不上它，只需要 bloom 那种随机散布。
func get_pattern_spread_degrees() -> float:
	var curve_key := String(_class_traits.get("pattern_spread_curve", ""))
	if curve_key.is_empty():
		return 0.0
	return _pattern_spread_from_curve(curve_key)


func _pattern_spread_from_curve(curve_key: String) -> float:
	var per_level: Array = _curve_field(curve_key, "per_level", [7.25, 2.5, 6.0])
	if _weapon_level <= per_level.size():
		return float(per_level[_weapon_level - 1])
	var late_base := float(_curve_field(curve_key, "late_base", 11.0))
	var late_per_level := float(_curve_field(curve_key, "late_per_level", 1.25))
	var late_max := float(_curve_field(curve_key, "late_max", 24.0))
	var late_start := per_level.size() + 1
	return minf(late_base + float(_weapon_level - late_start) * late_per_level, late_max)


## 注意：这条曲线的单位是【每发】，不是【每颗弹丸】。
## 取消散弹后 smg 类没有 pellet_curve，这条曲线就得自己承担全部伤害，
## 所以三个兜底值必须与配置同步（= 重推后的目标值）；写成旧的 [20,14,12] /
## 9.0 / 0.5 会让配置损坏时静默退回那条"越升越弱"的曲线。
func get_bullet_damage() -> float:
	var per_level: Array = _curve_field("bullet_damage", "per_level", [20.0, 28.0, 36.0])
	var base := 0.0
	if _weapon_level <= per_level.size():
		base = float(per_level[_weapon_level - 1])
	else:
		# 伤害随等级线性增长，避免后期等级让生存模式失去意义。
		var late_base := float(_curve_field("bullet_damage", "late_base", 45.0))
		var late_per_level := float(_curve_field("bullet_damage", "late_per_level", 5.75))
		var late_start := per_level.size() + 1
		base = late_base + float(_weapon_level - late_start) * late_per_level
	# 威力模块在这里生效一次，显式档位与线性段两条路都不会漏。
	return base * get_damage_multiplier()


func _update_muzzle_flash(delta: float) -> void:
	_muzzle_flash_time = maxf(_muzzle_flash_time - delta, 0.0)
	_set_muzzle_flash(_muzzle_flash_time > 0.0)


func _set_muzzle_flash(enabled: bool) -> void:
	if _muzzle_flash:
		_muzzle_flash.visible = enabled
	if _muzzle_light:
		_muzzle_light.visible = enabled


## 等级越高，枪身能量色越往冷色偏移，并略微增大。
func apply_weapon_visual_upgrade() -> void:
	var energy_color := Color.from_hsv(fmod(0.08 + float(_weapon_level) * 0.065, 1.0), 0.86, 1.0)
	var body_material := _duplicate_material(_gun_body)
	if body_material:
		body_material.albedo_color = Color(
			energy_color.r * 0.18, energy_color.g * 0.18, energy_color.b * 0.18, 1.0
		)
		_apply_emissive(_gun_body, body_material, energy_color, minf(0.25 + _weapon_level * 0.08, 1.5))
		var body_growth := minf(1.0 + float(_weapon_level - 1) * 0.018, 1.35)
		_gun_body.scale = Vector3(0.12, 0.1, 0.32) * body_growth
	_apply_emissive_simple(_gun_barrel, energy_color, minf(0.35 + _weapon_level * 0.1, 2.0), false)
	_apply_emissive_simple(_gun_sight, energy_color, minf(2.0 + _weapon_level * 0.3, 7.0), true)
	_apply_emissive_simple(_gun_sight_rear, energy_color, minf(2.0 + _weapon_level * 0.3, 7.0), true)
	_apply_emissive_simple(_muzzle_flash, energy_color, minf(4.0 + _weapon_level * 0.3, 10.0), true)
	if _muzzle_light:
		_muzzle_light.light_color = energy_color
		_muzzle_light.light_energy = minf(4.0 + _weapon_level * 0.35, 12.0)
		_muzzle_light.omni_range = minf(3.0 + _weapon_level * 0.12, 6.0)


func _duplicate_material(mesh: MeshInstance3D) -> StandardMaterial3D:
	if not mesh or not (mesh.material_override is StandardMaterial3D):
		return null
	return mesh.material_override.duplicate() as StandardMaterial3D


func _apply_emissive(
	mesh: MeshInstance3D, material: StandardMaterial3D, color: Color, energy: float
) -> void:
	if not mesh or not material:
		return
	material.emission_enabled = true
	material.emission = color
	material.emission_energy_multiplier = energy
	mesh.material_override = material


func _apply_emissive_simple(
	mesh: MeshInstance3D, color: Color, energy: float, tint_albedo: bool
) -> void:
	var material := _duplicate_material(mesh)
	if not material:
		return
	if tint_albedo:
		material.albedo_color = color
	_apply_emissive(mesh, material, color, energy)
