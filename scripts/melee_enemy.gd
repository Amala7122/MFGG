extends CharacterBody3D

const PICKUP_SCENE: PackedScene = preload("res://scenes/pickup.tscn")
## 用 preload 而不是裸类名：全局类名依赖 .godot 的 class 缓存，
## 新建脚本在编辑器扫描之前无法被其他脚本按名字引用。
const EnemyVisualsUtil := preload("res://scripts/enemy_visuals.gd")
const EnemyProfileUtil := preload("res://scripts/enemy_profile.gd")
const EnemyRigUtil := preload("res://scripts/enemy_rig.gd")
const NavSteeringUtil := preload("res://scripts/nav_steering.gd")
const ConfigUtil := preload("res://scripts/game_config.gd")
const PickupUtil := preload("res://scripts/pickup.gd")
const TargetingUtil := preload("res://scripts/targeting.gd")
const TerrainFieldUtil := preload("res://scripts/terrain_field.gd")

## 重新选目标的间隔（秒）。两人分开跑位时，敌人应该转向更近的那个，
## 而不是被 _ready 时选中的那个人永远牵着走。
const RETARGET_INTERVAL := 1.5

@export var max_health: float = 100.0
@export var move_speed: float = 4.2
## 玩家进入这个半径内才主动交战。
## 默认值必须与 enemy.melee_detection_range 一致，并且【大于任何竞技场的刷怪半径】
## —— 否则远处刷出的近战兵会"还没察觉到玩家"，于是原地站定不动。
@export var detection_range: float = 75.0
@export var attack_distance: float = 1.85
@export var attack_damage: float = 24.0
@export var attack_interval: float = 0.72

var health: float
var target: CharacterBody3D
var gravity: float = ProjectSettings.get_setting("physics/3d/default_gravity")
var attack_cooldown: float
var hit_flash_time: float
var enemy_title: String = "近战兵"
var _stagger_time: float = 0.0
var _stagger_velocity := Vector3.ZERO
## 重新选目标的倒计时，见 RETARGET_INTERVAL。
var _retarget_timer := RETARGET_INTERVAL
## 被击退后的硬直时长（配置 enemy.stagger_duration）。
var _stagger_duration := 0.42
## 未察觉玩家时的游荡速度比例（配置 enemy.melee_idle_wander_speed_ratio）。
var _idle_wander_ratio := 0.35
## 近战伤害的全局倍率（data/game_config.json → enemy.melee_damage_scale）。
var _damage_scale := 1.0
## 本敌人打在玩家【护盾】上的伤害倍率（1.0 = 与打生命一致）。
##
## 小型快速近战会被压到 0.7：它们是当前主要威胁，而护盾原本对它们和对重装兵
## 一样厚，等于"一段会自动回复的血条" —— 削这 30% 才让护盾有兵种差异。
## 注意只削护盾、不削生命：护盾一旦被打穿，溢出部分仍是原始伤害，
## 所以"被小怪贴脸"依然危险，只是不再无脑吃满一整条护盾。
## 分类阈值见 data/game_config.json 的 enemy.small_fast_*。
var shield_damage_scale := 1.0

## ── 「重量」属性（阶段 2，来自 enemy_roster.attrs_default + 本条 attrs 覆盖）──
## 全部默认值都等于旧行为：turn_speed 0 = 瞬时转向（旧 look_at）、accel_ratio 7.0
## （旧 move_speed×7）、硬直 0.42、攻击距离不随体型缩放、无接触伤害、无护甲。
var _turn_speed := 0.0
var _turn_speed_rad := 0.0
## 起步加速度 ÷ move_speed。收脚（刹停）固定取它的 9/7 倍，以复刻旧行为。
var _accel_ratio := 7.0
## 0~1 霸体：手雷 / 脉冲击退力 × (1 - 本值)。
var _knockback_resistance := 0.0
## 贴身每秒伤害，0 = 关。
var _contact_damage := 0.0
## 0~1 减伤，对所有伤害来源生效。
var _armor := 0.0
## 0 = 攻击距离不随体型缩放（旧行为），1 = 完全随体型（base × scale）。
var _attack_distance_scale := 0.0
## 攻击距离基准（配置值），体型缩放乘在它之上。
var _attack_distance_base := 1.85
## 贴身伤害的秒累加器。
var _contact_timer := 0.0
## 掉出世界的判定深度（米，相对脚下的程序化地面）。见 _kill_if_below_world。
var _fall_kill_depth := 18.0

var _visuals := EnemyVisualsUtil.new()
## 最近一次下发的护甲色。形体剖面是在 configure 之后才挂部件的，挂完必须
## 重新 register + 重染一次，否则新部件不参与受击闪白、也不是护甲色。
var _armor_color := Color.WHITE
var _rig := EnemyRigUtil.new()
var _steering := NavSteeringUtil.new()
## 是否挨过打。坠亡归属用：自己走出边界的敌人不该白送一笔击杀。
var _took_damage := false


## 被手雷 / 震地脉冲击退：短时间接管移动形成明确的"被打飞"反馈。
## 【重量】霸体：击退力按 (1 - knockback_resistance) 打折，巨型几乎推不动。
func apply_push(direction: Vector3, force: float) -> void:
	var flat := Vector3(direction.x, 0.0, direction.z)
	if flat.is_zero_approx():
		flat = Vector3.FORWARD
	var resisted := maxf(force, 0.0) * (1.0 - clampf(_knockback_resistance, 0.0, 1.0))
	_stagger_velocity = flat.normalized() * resisted
	_stagger_time = _stagger_duration

@onready var enemy_model: Node3D = $EnemyModel
@onready var health_label: Label3D = $HealthLabel


func _ready() -> void:
	health = max_health
	target = TargetingUtil.nearest_player(self) as CharacterBody3D
	# 攻击间隔是全局值（刷怪点并不覆盖它），所以只能从这里调。
	attack_interval = maxf(ConfigUtil.get_float("enemy.melee_attack_interval", 0.72), 0.05)
	# 伤害倍率是最直接的难度旋钮：它乘在刷怪点给出的基础伤害之上，
	# 因此对 15 个固定点与动态刷怪同时生效，不必逐个改数值。
	_damage_scale = maxf(ConfigUtil.get_float("enemy.melee_damage_scale", 0.7), 0.0)
	# 察觉距离必须与"敌人在多远的地方生成"对齐，不然会出现"生成即冻结"。
	detection_range = maxf(
		ConfigUtil.get_float("enemy.melee_detection_range", 75.0), attack_distance + 1.0
	)
	# 攻击距离 / 基础伤害 / 硬直 / 未察觉时的游荡比例。
	# 注意 melee_base_damage 这一项：配置里早就有它，但代码从来没读过 ——
	# 于是"改配置里的近战基础伤害"一直是无效的，现在接上。
	attack_distance = maxf(ConfigUtil.get_float("enemy.melee_attack_distance", 1.85), 0.3)
	_attack_distance_base = attack_distance
	attack_damage = maxf(ConfigUtil.get_float("enemy.melee_base_damage", 24.0), 0.0)
	_stagger_duration = maxf(ConfigUtil.get_float("enemy.stagger_duration", 0.42), 0.0)
	_idle_wander_ratio = clampf(
		ConfigUtil.get_float("enemy.melee_idle_wander_speed_ratio", 0.35), 0.0, 1.0
	)
	_fall_kill_depth = maxf(ConfigUtil.get_float("enemy.fall_kill_depth", 18.0), 3.0)
	_visuals.register(enemy_model)
	_rig.name = "EnemyRig"
	add_child(_rig)
	_rig.setup(enemy_model)
	# 半径取得比视觉体型略大，避免贴着掩体角"蹭"过去时穿模。
	_steering.setup(self, 0.6, 1.8)
	update_health_label()


func configure_melee_variant(new_title: String, armor_color: Color) -> void:
	if not new_title.is_empty():
		enemy_title = new_title
	_armor_color = armor_color
	_visuals.apply_tint(armor_color)


## 套用形体剖面（由 enemy_spawner 在读完图鉴条目之后调用）。
##
## 顺序上它必须晚于 configure_melee_variant：剖面会【新增】部件，而染色与
## 受击闪白是 register() 时一次性收集的，所以挂完要重扫一遍再补一次染色。
## 未配置 profile 的条目（空字符串）走原型骑士，与改动前逐帧一致。
func apply_body_profile(profile_id: String) -> void:
	if profile_id.is_empty():
		return
	EnemyProfileUtil.apply(enemy_model, profile_id)
	_visuals.register(enemy_model)
	_visuals.apply_tint(_armor_color)


func configure_stats(
	scale_multiplier: float,
	health_value: float,
	speed_value: float,
	damage_value: float,
	attrs: Dictionary = {}
) -> void:
	var safe_scale := maxf(scale_multiplier, 0.45)
	scale = Vector3.ONE * safe_scale
	health_label.scale = Vector3.ONE / safe_scale
	if health_value > 0.0:
		max_health = health_value
		health = max_health
	if speed_value > 0.0:
		move_speed = speed_value
	if damage_value > 0.0:
		attack_damage = damage_value
	_apply_weight_attrs(attrs, safe_scale)
	# 判定"小型快速近战"：只看体型与速度两项。
	# 图鉴里属于这一类的四种（追猎者 0.72/5.4、迅捷刀手 0.82/5.1、
	# 疾行刺客 0.68/6.0、猎杀幼体 0.65/6.2）体型都在 0.85 以下；
	# 其余近战（士兵、狂战士、重装、盾卫、破坏者、精英剑士）体型都 ≥1.0，
	# 即便速度随等级成长也不会被误判进来 —— 体型才是主判据。
	var small_fast_max_scale := ConfigUtil.get_float("enemy.small_fast_max_scale", 0.85)
	var small_fast_min_speed := ConfigUtil.get_float("enemy.small_fast_min_speed", 5.0)
	shield_damage_scale = ConfigUtil.get_float(
		"enemy.small_fast_shield_damage_scale", 0.7
	) if safe_scale <= small_fast_max_scale and move_speed >= small_fast_min_speed else 1.0
	update_health_label()


## 套用「重量」属性。缺项一律取旧行为默认值 —— 所以传空字典就是阶段 2 之前的样子。
func _apply_weight_attrs(attrs: Dictionary, safe_scale: float) -> void:
	_turn_speed = maxf(float(attrs.get("turn_speed", 0.0)), 0.0)
	_turn_speed_rad = deg_to_rad(_turn_speed)
	_accel_ratio = maxf(float(attrs.get("accel_ratio", 7.0)), 0.1)
	_knockback_resistance = clampf(float(attrs.get("knockback_resistance", 0.0)), 0.0, 1.0)
	_stagger_duration = maxf(float(attrs.get("stagger_duration", _stagger_duration)), 0.0)
	_contact_damage = maxf(float(attrs.get("contact_damage", 0.0)), 0.0)
	_armor = clampf(float(attrs.get("armor", 0.0)), 0.0, 1.0)
	_attack_distance_scale = clampf(float(attrs.get("attack_distance_scale", 0.0)), 0.0, 1.0)
	# 攻击距离随体型拉伸：0 = 不缩放（旧行为），1 = base × scale。
	attack_distance = _attack_distance_base * lerpf(1.0, safe_scale, _attack_distance_scale)


## 转向：turn_speed = 0 时瞬时（复刻旧 look_at），否则按度/秒平滑逼近目标朝向。
## 大怪转不过来，"绕背"第一次成为有效打法。
func _face_flat_direction(delta: float, flat_direction: Vector3) -> void:
	if flat_direction.is_zero_approx():
		return
	# 本模型 -Z 为正面，所以朝向角 = atan2(-x, -z)（与旧 look_at 等价，见注释）。
	var desired := atan2(-flat_direction.x, -flat_direction.z)
	if _turn_speed_rad <= 0.0:
		rotation.y = desired
		return
	var diff := wrapf(desired - rotation.y, -PI, PI)
	rotation.y += clampf(diff, -_turn_speed_rad * delta, _turn_speed_rad * delta)


## 贴身伤害：在攻击距离内按秒结算（用 1 秒的整块是为了跨过玩家 0.42s 的无敌帧）。
func _tick_contact_damage(delta: float) -> void:
	if _contact_damage <= 0.0:
		_contact_timer = 0.0
		return
	_contact_timer += delta
	if _contact_timer < 1.0:
		return
	if is_instance_valid(target):
		target.call(
			"take_damage", _contact_damage * _contact_timer * _damage_scale, global_position, 1.0
		)
	_contact_timer = 0.0


func _physics_process(delta: float) -> void:
	# 掉出场地就先结算 —— 底下那个已经不是"一个还在战斗的敌人"，不该继续跑 AI。
	if _kill_if_below_world():
		return
	_update_behavior(delta)
	_rig.update(
		delta, Vector2(velocity.x, velocity.z).length(), move_speed, is_on_floor()
	)


## 行为层：追击 / 攻击。动画交给 EnemyRig，避免早退路径漏掉动画更新。
## 把击杀记到最近的玩家头上。
func _credit_killer() -> void:
	var player := TargetingUtil.nearest_player(self)
	if player != null and player.has_method("register_enemy_kill"):
		player.call("register_enemy_kill")


func _update_behavior(delta: float) -> void:
	if not is_on_floor():
		velocity.y -= gravity * delta
	attack_cooldown = maxf(attack_cooldown - delta, 0.0)
	# 【目标一旦不能打了，立刻重选，不等定时器】
	# 只靠每 RETARGET_INTERVAL 秒选一次的话，玩家阵亡之后敌人会继续
	# 对着尸体打上最多 1.5 秒。
	if not is_instance_valid(target) or float(target.get("health")) <= 0.0:
		_retarget_timer = 0.0
	_retarget_timer -= delta
	if _retarget_timer <= 0.0:
		_retarget_timer = RETARGET_INTERVAL
		# 【找不到人就置空】—— 原来这里是 "if found != null 才覆盖"，
		# 于是目标倒下之后 target 会一直留着那个尸体，敌人继续捶它。
		target = TargetingUtil.nearest_player(self) as CharacterBody3D
	if _stagger_time > 0.0:
		_stagger_time = maxf(_stagger_time - delta, 0.0)
		velocity.x = _stagger_velocity.x
		velocity.z = _stagger_velocity.z
		_stagger_velocity = _stagger_velocity.move_toward(Vector3.ZERO, 34.0 * delta)
		_contact_timer = 0.0
		move_and_slide()
		update_feedback(delta)
		return
	if not is_instance_valid(target):
		_contact_timer = 0.0
		move_and_slide()
		return

	var offset := target.global_position - global_position
	var distance := offset.length()
	var flat_direction := Vector3(offset.x, 0.0, offset.z).normalized()
	if distance <= detection_range:
		_face_flat_direction(delta, flat_direction)
		if distance > attack_distance:
			# 用导航路径代替直线追击：场上有 34° 的坡和 28 个掩体，直线追
			# 会直接撞上去然后贴着滑。导航不可用时自动回退直线。
			var chase := _steering.direction_to(target.global_position, flat_direction, delta)
			velocity.x = move_toward(velocity.x, chase.x * move_speed, move_speed * _accel_ratio * delta)
			velocity.z = move_toward(velocity.z, chase.z * move_speed, move_speed * _accel_ratio * delta)
			_contact_timer = 0.0
		else:
			# 收脚速度固定取起步的 9/7 倍，以复刻旧行为（accel_ratio 默认 7 → 9）。
			var brake := move_speed * _accel_ratio * 9.0 / 7.0 * delta
			velocity.x = move_toward(velocity.x, 0.0, brake)
			velocity.z = move_toward(velocity.z, 0.0, brake)
			if attack_cooldown <= 0.0:
				attack()
			_tick_contact_damage(delta)
	else:
		_contact_timer = 0.0
		# 未察觉时不要"纯粹站定"。
		#
		# 这条分支原本只是减速到 0，于是只要"察觉距离 < 刷怪半径"就会让敌人
		# 生成即冻结（实测：近战 34 米 vs 湖畔锚点 40 米 → 一波里约 2/3 近战兵
		# 站着不动，玩家看到的就是"敌人没刷出来"，波次也因此清不掉）。
		# 改成低速朝玩家方向游荡：既保留了"还没锁定你"的手感，
		# 也保证以后再调竞技场半径不会再出现站桩。
		velocity.x = move_toward(
			velocity.x, flat_direction.x * move_speed * _idle_wander_ratio, move_speed * 5.0 * delta
		)
		velocity.z = move_toward(
			velocity.z, flat_direction.z * move_speed * _idle_wander_ratio, move_speed * 5.0 * delta
		)
	move_and_slide()
	update_feedback(delta)


func attack() -> void:
	attack_cooldown = attack_interval
	_rig.play_attack(attack_interval * 0.85)
	if is_instance_valid(target) and global_position.distance_to(target.global_position) <= attack_distance + 0.35:
		# 第二个参数是伤害来源的世界坐标，供 HUD 的受击方向指示器使用 ——
		# 第三人称看不到背后，没有这个指示玩家完全无法应对背刺。
		# 第三个参数是护盾倍率：小型快速近战对护盾打折，对生命不打折。
		target.call(
			"take_damage", attack_damage * _damage_scale, global_position, shield_damage_scale
		)


func take_damage(amount: float) -> void:
	_took_damage = true
	# 【重量】护甲：对所有伤害来源减伤（含手雷 / 脉冲的爆炸结算）。
	health -= amount * (1.0 - _armor)
	if health <= 0.0:
		die()
		return
	hit_flash_time = 0.1
	_visuals.set_flash(true)
	_rig.flinch()
	update_health_label()


func die() -> void:
	_credit_killer()
	# 掉落表在配置里（drops 段）：总概率与各类型权重都可调，不写死。
	var drop := PickupUtil.roll_drop("melee")
	if drop >= 0:
		var pickup := PICKUP_SCENE.instantiate()
		get_tree().current_scene.add_child(pickup)
		pickup.global_position = global_position + Vector3(0.0, 0.2, 0.0)
		pickup.call("configure", drop)
	queue_free()


## 掉出场地就地判死。
##
## 玩家那边有一份对称的保险（player._recover_if_below_world），但它是【拉回来】：
## 人有要去的地方、有要接着打的局，送回地面才合理。敌人反过来 —— 它躺在谁也看不见
## 的虚空里，拉回来等于凭空多一个兵，不如当场结算。
##
## 这不是可有可无的收尾：波次推进器靠 tree_exited 减存活数（wave_director 的
## _on_enemy_gone），掉下去的敌人永远不退出场景树，于是【永久挂在 _alive 名单里】
## —— 表现正是"最后一个敌人不见了、剩 1 卡着不动"，最后只能等看门狗把这一波强推。
##
## 判定基准与玩家那份一致，都取脚下位置的程序化地面 TerrainField.height_at()：
## 山地起伏不会被误判，而"水平走出边界"也照样成立 —— 边界外没有碰撞体，
## 落体不会停，迟早越过这条线。
func _kill_if_below_world() -> bool:
	var expected_ground := TerrainFieldUtil.height_at(global_position.x, global_position.z)
	if global_position.y >= expected_ground - _fall_kill_depth:
		return false
	health = 0.0
	# 【一次性结算】queue_free() 要到帧末才真正摘掉节点，这中间主循环若再次进来
	#（同一帧被多处调用就会发生），没有这一句就会按调用次数重复记账 ——
	# 掉一次被记成 N 次击杀。停掉主循环才是"之后不再需要它"的正解。
	set_physics_process(false)
	# 坠落本身没有加害者，白送人头不合理：刚被人打过（多半正是被打退下去的）
	# 才把这笔击杀记给他，一次没挨过打就不记。
	if _took_damage:
		_credit_killer()
	# 掉落物会跟着一起落进虚空，所以坠亡不掷掉落表，直接退场。
	queue_free()
	return true


func update_feedback(delta: float) -> void:
	hit_flash_time = maxf(hit_flash_time - delta, 0.0)
	_visuals.set_flash(hit_flash_time > 0.0)


func update_health_label() -> void:
	health_label.text = "%s  %d/%d" % [enemy_title, ceili(health), ceili(max_health)]
