extends CharacterBody3D

const HealthUtil := preload("res://scripts/health_util.gd")

signal died(enemy: Node3D)

## juice：死亡特效与波次接口
const EnemyDeathFXUtil := preload("res://scripts/enemy_death_fx.gd")
const CombatFXUtil := preload("res://scripts/combat_fx.gd")
const WaveDirectorUtil := preload("res://scripts/wave_director.gd")

## juice：死亡流程与「过量击杀」记录（决定尸体爆炸规模）。
var _dying := false
var _last_overkill: float = 0.0


const PICKUP_SCENE: PackedScene = preload("res://scenes/pickup.tscn")
## 用 preload 而不是裸类名：全局类名依赖 .godot 的 class 缓存，
## 新建脚本在编辑器扫描之前无法被其他脚本按名字引用。
const EnemyVisualsUtil := preload("res://scripts/enemy_visuals.gd")
const EnemyProfileUtil := preload("res://scripts/enemy_profile.gd")
const EnemyRigUtil := preload("res://scripts/enemy_rig.gd")
const NavSteeringUtil := preload("res://scripts/nav_steering.gd")
const GroundMovement := preload("res://scripts/ground_movement.gd")
const SpatialProfile := preload("res://scripts/combat_spatial_profile.gd")
@export var combat_spatial_profile: SpatialProfile = preload("res://data/combat_spatial/ground.tres")
const ConfigUtil := preload("res://scripts/game_config.gd")
const PickupUtil := preload("res://scripts/pickup.gd")
const TargetingUtil := preload("res://scripts/targeting.gd")
const TerrainFieldUtil := preload("res://scripts/terrain_field.gd")
const AttackArea := preload("res://scripts/enemy_attack_area.gd")
var _attack_area := AttackArea.new()
var _attack_elapsed := -1.0
var _attack_duration := 0.6
var _attack_target: CharacterBody3D

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
## 起步 / 刹停加速度 ÷ move_speed；可分别调节重量感。
var _accel_ratio := 7.0
var _brake_ratio := 9.0
## 0~1 霸体：手雷 / 脉冲击退力 × (1 - 本值)。
var _knockback_resistance := 0.0
## 贴身压力：每秒值折算到可预警挥击（值 × 攻击间隔），0 = 关。
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
	cancel_attack()
	if _steering.spatial != null:
		_steering.spatial.cancel_motion()
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
	add_child(_attack_area)
	# 半径取得比视觉体型略大，避免贴着掩体角"蹭"过去时穿模。
	_steering.setup(self, 0.6, 1.8)
	_steering.spatial.bind({"move_speed": move_speed, "gravity": gravity}, {"can_attack": _spatial_can_attack, "attack_pose": _spatial_attack_pose})
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


func configure_gait(settings: Dictionary) -> void:
	_rig.configure_gait(settings)


## 套用「重量」属性。缺项一律取旧行为默认值 —— 所以传空字典就是阶段 2 之前的样子。
func _apply_weight_attrs(attrs: Dictionary, safe_scale: float) -> void:
	_turn_speed = maxf(float(attrs.get("turn_speed", 0.0)), 0.0)
	_turn_speed_rad = deg_to_rad(_turn_speed)
	_accel_ratio = maxf(float(attrs.get("accel_ratio", 7.0)), 0.1)
	_brake_ratio = maxf(float(attrs.get("brake_ratio", _accel_ratio * 9.0 / 7.0)), 0.1)
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
func _physics_process(delta: float) -> void:
	# 掉出场地就先结算 —— 底下那个已经不是"一个还在战斗的敌人"，不该继续跑 AI。
	if _kill_if_below_world():
		return
	var prior_yaw := rotation.y
	var locomoting := _stagger_time <= 0.0
	if _steering.tick(delta, _stagger_time <= 0.0 and _attack_elapsed < 0.0 and is_instance_valid(target) and global_position.distance_to(target.global_position) <= detection_range, target, move_speed):
		attack_cooldown = maxf(attack_cooldown - delta, 0.0)
		update_feedback(delta)
	else:
		_update_behavior(delta)
	var actual_velocity := get_real_velocity()
	_rig.update(
		delta, Vector2(actual_velocity.x, actual_velocity.z).length(), move_speed, is_on_floor(),
		global_basis.orthonormalized().inverse() * actual_velocity, locomoting,
		wrapf(rotation.y - prior_yaw, -PI, PI) / maxf(delta, 0.001)
	)


## 行为层：追击 / 攻击。动画交给 EnemyRig，避免早退路径漏掉动画更新。
## 把击杀记到最近的玩家头上。
func _credit_killer() -> void:
	if not preload("res://scripts/combat_telemetry.gd").credits_player(self):
		return
	var player := TargetingUtil.nearest_player(self)
	if player != null and player.has_method("register_enemy_kill"):
		player.call("register_enemy_kill", self)


func _update_behavior(delta: float) -> void:
	if not is_on_floor():
		velocity.y -= gravity * delta
	attack_cooldown = maxf(attack_cooldown - delta, 0.0)
	if _attack_elapsed >= 0.0:
		if not HealthUtil.is_alive(_attack_target):
			cancel_attack()
		else:
			_update_attack(delta)
			velocity.x = 0.0
			velocity.z = 0.0
			move_and_slide()
			update_feedback(delta)
			return
	# 【目标一旦不能打了，立刻重选，不等定时器】
	# 只靠每 RETARGET_INTERVAL 秒选一次的话，玩家阵亡之后敌人会继续
	# 对着尸体打上最多 1.5 秒。
	if not HealthUtil.is_alive(target):
		_retarget_timer = 0.0
	_retarget_timer -= delta
	if _retarget_timer <= 0.0:
		_retarget_timer = RETARGET_INTERVAL
		# 【找不到人就置空】—— 原来这里是 "if found != null 才覆盖"，
		# 于是目标倒下之后 target 会一直留着那个尸体，敌人继续捶它。
		target = TargetingUtil.nearest_player(self) as CharacterBody3D
	if _stagger_time > 0.0:
		_steering.direction_to(global_position, Vector3.ZERO, delta, false)
		_stagger_time = maxf(_stagger_time - delta, 0.0)
		velocity.x = _stagger_velocity.x
		velocity.z = _stagger_velocity.z
		_stagger_velocity = _stagger_velocity.move_toward(Vector3.ZERO, 34.0 * delta)
		move_and_slide()
		update_feedback(delta)
		return
	if not is_instance_valid(target):
		_steering.direction_to(global_position, Vector3.ZERO, delta, false)
		var brake := move_speed * _brake_ratio * delta
		velocity.x = move_toward(velocity.x, 0.0, brake)
		velocity.z = move_toward(velocity.z, 0.0, brake)
		move_and_slide()
		return

	var offset := target.global_position - global_position
	var distance := offset.length()
	var flat_direction := Vector3(offset.x, 0.0, offset.z).normalized()
	if distance <= detection_range:
		if not _spatial_can_attack():
			# 用导航路径代替直线追击：场上有 34° 的坡和 28 个掩体，直线追
			# 会直接撞上去然后贴着滑。导航不可用时自动回退直线。
			var chase := _steering.ground_velocity(target.global_position, flat_direction * move_speed, delta) / maxf(move_speed, 0.01)
			_face_flat_direction(delta, flat_direction if chase.is_zero_approx() else chase)
			velocity.x = move_toward(velocity.x, chase.x * move_speed, move_speed * _accel_ratio * delta)
			velocity.z = move_toward(velocity.z, chase.z * move_speed, move_speed * _accel_ratio * delta)
		else:
			_face_flat_direction(delta, flat_direction)
			_steering.direction_to(global_position, Vector3.ZERO, delta, false)
			var brake := move_speed * _brake_ratio * delta
			velocity.x = move_toward(velocity.x, 0.0, brake)
			velocity.z = move_toward(velocity.z, 0.0, brake)
			if attack_cooldown <= 0.0:
				attack()
			# 贴身压力并入可躲的挥击，不再另开无预警扣血计时器。
	else:
		_steering.direction_to(global_position, Vector3.ZERO, delta, false)
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
	GroundMovement.move(self, delta)
	update_feedback(delta)


func attack() -> void:
	if _attack_elapsed >= 0.0 or health <= 0.0 or _stagger_time > 0.0 or not HealthUtil.is_alive(target):
		return
	_attack_target = target
	_attack_duration = maxf(attack_interval * 0.85, 0.5)
	attack_cooldown = maxf(attack_interval, _attack_duration)
	_attack_elapsed = 0.0
	velocity.x = 0.0
	velocity.z = 0.0
	var angle := ConfigUtil.get_float("enemy.melee_attack_angle", 110.0)
	_attack_area.prepare(global_transform, {"kind": "sector", "radius": attack_distance + 0.35,
		"angle": angle, "height": 2.0 * scale.y, "ground_effect": false},
		(attack_damage + _contact_damage * attack_interval) * _damage_scale)
	_rig.play_attack(_attack_duration)


func _spatial_can_attack() -> bool:
	return _spatial_attack_pose(global_transform)

func _spatial_attack_pose(pose: Transform3D) -> bool:
	return is_instance_valid(target) and AttackArea.candidate_can_hit(self, pose,
		{"kind": "sector", "radius": attack_distance + 0.35,
		"angle": ConfigUtil.get_float("enemy.melee_attack_angle", 110.0), "height": 2.0 * scale.y, "ground_effect": false}, target)


func _update_attack(delta: float) -> void:
	if _attack_elapsed < 0.0:
		return
	_attack_elapsed += delta
	_attack_area.set_progress(_attack_elapsed / (_attack_duration * EnemyRigUtil.ATTACK_HIT_PROGRESS))
	# 与 EnemyRig 的抬臂/劈下/回收曲线共用 0.32 / 0.62 命中进度。
	if _attack_elapsed >= _attack_duration * EnemyRigUtil.ATTACK_LOCK_PROGRESS:
		_attack_area.lock()
	if _attack_elapsed >= _attack_duration * EnemyRigUtil.ATTACK_HIT_PROGRESS and _attack_area.strike():
		if _attack_area.can_hit(_attack_target, _attack_area.global_position):
			preload("res://scripts/combat_telemetry.gd").hurt_player(_attack_target,
				_attack_area.damage, _attack_area.global_position, shield_damage_scale,
				preload("res://scripts/combat_telemetry.gd").source_info(self, "近战攻击"))
		_attack_area.recover()
	if _attack_elapsed >= _attack_duration:
		cancel_attack()


func cancel_attack() -> void:
	_attack_elapsed = -1.0
	_attack_target = null
	_attack_area.cancel()
	_rig.cancel_attack()


func take_damage(amount: float) -> void:
	if health <= 0.0 or is_queued_for_deletion():
		return
	var before := health
	_took_damage = true
	# 【重量】护甲：对所有伤害来源减伤（含手雷 / 脉冲的爆炸结算）。
	health -= amount * (1.0 - _armor)
	preload("res://scripts/combat_telemetry.gd").enemy_damaged(self, before)
	if health <= 0.0:
		_last_overkill = absf(health)
		die()
		return
	hit_flash_time = 0.1
	_visuals.set_flash(true)
	_rig.flinch()
	update_health_label()


func die() -> void:
	if _dying:
		return
	_dying = true
	hit_flash_time = 0.0
	_visuals.set_flash(false)
	cancel_attack()
	_credit_killer()
	# 掉落表在配置里（drops 段）。
	var drop := PickupUtil.roll_drop("melee")
	var scene: Node = (get_tree().current_scene if get_tree() else null) if is_inside_tree() else null
	if not scene:
		scene = get_parent()
	var my_pos := global_position if is_inside_tree() else position
	if drop >= 0 and scene:
		var pickup := PICKUP_SCENE.instantiate()
		scene.add_child(pickup)
		if pickup.is_inside_tree():
			pickup.global_position = my_pos + Vector3(0.0, 0.2, 0.0)
		else:
			pickup.position = my_pos + Vector3(0.0, 0.2, 0.0)
		pickup.call("configure", drop)
	# juice：死亡瞬间退出敌人组并关闭碰撞 —— 不再吃伤害、不再挡路
	remove_from_group("enemies")
	collision_layer = 0
	collision_mask = 0
	if is_instance_valid(health_label):
		health_label.visible = false
	if scene:
		CombatFXUtil.spawn_impact(scene, my_pos + Vector3.UP * 0.9, Vector3.UP, Color(1.0, 0.45, 0.2, 1.0), 1.8)
	# juice：尸体 / 碎块 / 倒地演出
	var is_last := WaveDirectorUtil.is_last_enemy(self)
	var is_large := _is_large_enemy()
	var death_fx: Node3D = null
	if scene and is_instance_valid(enemy_model):
		if is_large:
			death_fx = EnemyDeathFXUtil.spawn_large(scene, enemy_model, my_pos, _armor_color, false, is_last)
		else:
			var overkill_ratio := clampf(_last_overkill / maxf(max_health * 0.38, 1.0), 0.0, 2.2)
			var overkill_scale := 1.0 + overkill_ratio * 0.65
			death_fx = EnemyDeathFXUtil.spawn_small(scene, enemy_model, my_pos, _armor_color, is_last, overkill_scale)
	if death_fx != null:
		WaveDirectorUtil.notify_death_fx(death_fx, my_pos)
	_rig.release_model()
	died.emit(self)
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
	cancel_attack()
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


## juice：被震地脉冲破招——陷入硬直并后仰（B 的近战怪没有蓄力技能，故不取消技能）。
func parry() -> void:
	_stagger_time = _stagger_duration * 1.5
	_stagger_velocity = -global_transform.basis.z * 7.5
	hit_flash_time = 0.15
	_visuals.set_flash(true)
	if _rig:
		_rig.flinch()


## juice：大体型敌人（更大的尸体爆炸与更长的演出）。
func _is_large_enemy() -> bool:
	return scale.x >= 1.25 \
		or enemy_title.contains("巨型") \
		or enemy_title.contains("大型") \
		or enemy_title.contains("重装") \
		or enemy_title.contains("重型") \
		or enemy_title.contains("破坏者")
