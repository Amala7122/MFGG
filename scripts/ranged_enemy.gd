extends CharacterBody3D

const ENEMY_BULLET_SCENE: PackedScene = preload("res://scenes/enemy_bullet.tscn")
const TargetingUtil := preload("res://scripts/targeting.gd")

## 重新选目标的间隔（秒）。两人分开跑位时，敌人应该转向更近的那个。
const RETARGET_INTERVAL := 1.5
## 远程兵不是直奔玩家，而是在玩家周围横移 / 环绕 / 进退。导航目标必须落在
## 它【实际想走的方向】前方，否则“通往玩家的直线畅通”会掩盖侧面那棵树。
## 8 米足够让导航看到树干和中型掩体的另一侧，又不会把短时战术移动拉得太远。
const NAV_MOTION_LOOKAHEAD := 8.0
const PICKUP_SCENE: PackedScene = preload("res://scenes/pickup.tscn")
const GROUND_WARNING_SCENE: PackedScene = preload("res://scenes/ground_warning.tscn")
const MortarShellUtil := preload("res://scripts/mortar_shell.gd")
## 用 preload 而不是裸类名：全局类名依赖 .godot 的 class 缓存，
## 新建脚本在编辑器扫描之前无法被其他脚本按名字引用。
const EnemyVisualsUtil := preload("res://scripts/enemy_visuals.gd")
const EnemyRigUtil := preload("res://scripts/enemy_rig.gd")
const NavSteeringUtil := preload("res://scripts/nav_steering.gd")
const GroundMovement := preload("res://scripts/ground_movement.gd")
const SpatialProfile := preload("res://scripts/combat_spatial_profile.gd")
@export var combat_spatial_profile: SpatialProfile = preload("res://data/combat_spatial/ground.tres")
const ConfigUtil := preload("res://scripts/game_config.gd")
const PickupUtil := preload("res://scripts/pickup.gd")
const AudioUtil := preload("res://scripts/audio_manager.gd")
const TerrainFieldUtil := preload("res://scripts/terrain_field.gd")
const PoolUtil := preload("res://scripts/object_pool.gd")
const BulletPoolKey := "enemy_bullet"
## juice：狙击红线（telegraph）+ 可见重弹 + 高威胁技能限流 + 命中特效
const TelegraphUtil := preload("res://scripts/telegraph.gd")
const SniperBulletScript := preload("res://scripts/sniper_bullet.gd")
const SkillLimiterUtil := preload("res://scripts/skill_limiter.gd")
const CombatFXUtil := preload("res://scripts/combat_fx.gd")

## 右臂 IK 要抓的握把位置（GunPivot 局部空间）。
## 取在机匣靠后处，枪身随弹幕形态变形时也仍然合理。
const GRIP_OFFSET := Vector3(0.0, -0.09, -0.14)

enum PatternType { FAN, AIMED_BURST, SPIRAL_RING, BULLET_WALL, MORTAR, SNIPER }
enum MovementStyle { SIDE_STEP, ORBIT, ADVANCE_RETREAT }

static var next_global_fire_msec: int

@export var max_health: float = 75.0
@export var move_speed: float = 4.2
## 玩家进入这个半径内才主动交战（开火判定还另取 detection_range 的 0.9 倍）。
## 默认值必须与 enemy.ranged_detection_range 一致，并且大于任何竞技场的刷怪半径
## —— 否则远处刷出的远程兵不会逼近也不会开火。
@export var detection_range: float = 75.0
@export var preferred_distance: float = 14.0
@export var fire_interval: float = 2.3
@export var projectile_damage: float = 13.0
@export var pattern_type: int = PatternType.FAN
@export var movement_style: int = MovementStyle.SIDE_STEP
@export var enemy_title: String = "散射兵"
@export var bullet_color: Color = Color(1.0, 0.04, 0.24, 1.0)

var health: float
var fire_cooldown: float = 0.8
var target: CharacterBody3D
var gravity: float = ProjectSettings.get_setting("physics/3d/default_gravity")
var hit_flash_time: float
var recoil_time: float
var _visuals := EnemyVisualsUtil.new()
var _rig := EnemyRigUtil.new()
var _steering := NavSteeringUtil.new()
## 是否挨过打。坠亡归属用：自己走出边界的敌人不该白送一笔击杀。
var _took_damage := false
var movement_time: float
var movement_direction_sign: float = 1.0
var spiral_offset: float
var burst_remaining: int
var burst_timer: float
var attack_queued: bool
var attack_charge_time: float
var _aim_locked := false
var _locked_aim := Vector3.FORWARD
var _locked_landing := Vector3.ZERO
var _landing_valid := false
var _pending_mortars: Array[WeakRef] = []
# juice：狙击锁定红线状态（复用主线的 _aim_locked 协议，不再另建一套锁定机制）
var _sniper_line: Telegraph = null
var _sniper_locked := false
var _sniper_locked_point := Vector3.ZERO
var _stagger_time: float = 0.0
var _stagger_velocity := Vector3.ZERO
## 重新选目标的倒计时，见 RETARGET_INTERVAL。
var _retarget_timer := RETARGET_INTERVAL
## 远程伤害的全局倍率（data/game_config.json → enemy.ranged_damage_scale）。
## 在【生成弹丸时】就乘好，而不是命中时再乘：这样迫击炮落点预警里的伤害数字
## 也走同一条路径，不会出现"弹幕降了、炮击没降"的不一致。
var _damage_scale := 1.0
## 三个全局远程手感旋钮只在出生时读取一次，避免每帧查配置。
var _charge_duration := 0.65
var _fire_range_ratio := 0.9
var _global_fire_cooldown_ms := 900

## ── 「重量」属性（阶段 2，来自 enemy_roster.attrs_default + 本条 attrs 覆盖）──
## 起停与转向支持步态预设；空 attrs 仍使用原有 6/5 加速刹停比例。
var _turn_speed := 0.0
var _turn_speed_rad := 0.0
var _accel_ratio := 6.0
var _brake_ratio := 5.0
## 0~1 霸体：手雷 / 脉冲击退力 × (1 - 本值)。
var _knockback_resistance := 0.0
## 被击退的硬直秒数（旧代码硬编码 0.42）。
var _stagger_duration := 0.42
## 0~1 减伤，对所有伤害来源生效。
var _armor := 0.0
## 掉出世界的判定深度（米，相对脚下的程序化地面）。见 _kill_if_below_world。
var _fall_kill_depth := 18.0


## 被手雷 / 震地脉冲击退：短时间接管移动形成明确的"被打飞"反馈。
## 【重量】霸体：击退力按 (1 - knockback_resistance) 打折。
func apply_push(direction: Vector3, force: float) -> void:
	if _steering.spatial != null:
		_steering.spatial.cancel_motion()
	var flat := Vector3(direction.x, 0.0, direction.z)
	if flat.is_zero_approx():
		flat = Vector3.FORWARD
	var resisted := maxf(force, 0.0) * (1.0 - clampf(_knockback_resistance, 0.0, 1.0))
	_stagger_velocity = flat.normalized() * resisted
	_stagger_time = _stagger_duration
	cancel_attack_charge()

@onready var enemy_model: Node3D = $EnemyModel
@onready var visor: MeshInstance3D = $EnemyModel/Chest/Head/Visor
@onready var power_cell: MeshInstance3D = $EnemyModel/Chest/PowerCell
@onready var gun_pivot: Node3D = $EnemyModel/GunPivot
@onready var gun_body: MeshInstance3D = $EnemyModel/GunPivot/GunBody
@onready var barrel: MeshInstance3D = $EnemyModel/GunPivot/Barrel
@onready var side_barrel_left: MeshInstance3D = $EnemyModel/GunPivot/SideBarrelLeft
@onready var side_barrel_right: MeshInstance3D = $EnemyModel/GunPivot/SideBarrelRight
@onready var weapon_orb: MeshInstance3D = $EnemyModel/GunPivot/WeaponOrb
@onready var muzzle: Node3D = $EnemyModel/GunPivot/Muzzle
@onready var muzzle_glow: OmniLight3D = $EnemyModel/GunPivot/Muzzle/MuzzleGlow
@onready var charge_orb: MeshInstance3D = $EnemyModel/GunPivot/Muzzle/ChargeOrb
@onready var health_label: Label3D = $HealthLabel


func _ready() -> void:
	health = max_health
	target = TargetingUtil.nearest_player(self) as CharacterBody3D
	# 开火间隔是全局值（刷怪点并不覆盖它），所以只能从这里调。
	fire_interval = maxf(ConfigUtil.get_float("enemy.ranged_fire_interval", 2.3), 0.1)
	_damage_scale = maxf(ConfigUtil.get_float("enemy.ranged_damage_scale", 1.0), 0.0)
	_charge_duration = maxf(ConfigUtil.get_float("enemy.ranged_charge_time", 0.65), 0.0)
	_fire_range_ratio = clampf(
		ConfigUtil.get_float("enemy.ranged_fire_range_ratio", 0.9), 0.05, 1.0
	)
	_global_fire_cooldown_ms = maxi(
		ConfigUtil.get_int("enemy.ranged_global_fire_cooldown_ms", 900), 0
	)
	detection_range = maxf(
		ConfigUtil.get_float("enemy.ranged_detection_range", 75.0), preferred_distance + 1.0
	)
	_fall_kill_depth = maxf(ConfigUtil.get_float("enemy.fall_kill_depth", 18.0), 3.0)
	_visuals.register(enemy_model)
	_rig.name = "EnemyRig"
	add_child(_rig)
	_rig.setup(enemy_model)
	_rig.right_hand_ik_weight = 1.0
	_steering.setup(self, 0.65, 1.8)
	_steering.spatial.bind({"move_speed": move_speed, "gravity": gravity}, {"can_attack": can_attack_from_current_view})
	movement_direction_sign = -1.0 if get_instance_id() % 2 == 0 else 1.0
	update_health_label()


func configure(
	new_pattern: int,
	new_movement: int,
	new_title: String,
	armor_color: Color,
	new_bullet_color: Color,
	new_preferred_distance: float
) -> void:
	pattern_type = new_pattern
	movement_style = new_movement
	enemy_title = new_title
	bullet_color = new_bullet_color
	preferred_distance = new_preferred_distance
	_visuals.apply_tint(armor_color)
	muzzle_glow.light_color = new_bullet_color
	apply_weapon_visual()
	update_health_label()


func apply_weapon_visual() -> void:
	barrel.visible = true
	side_barrel_left.visible = false
	side_barrel_right.visible = false
	weapon_orb.visible = false
	barrel.rotation.x = 1.5708
	barrel.scale = Vector3.ONE
	match pattern_type:
		PatternType.AIMED_BURST:
			gun_body.scale = Vector3(0.09, 0.085, 0.52)
			barrel.scale = Vector3(0.72, 1.75, 0.72)
		PatternType.SPIRAL_RING:
			gun_body.scale = Vector3(0.15, 0.15, 0.24)
			barrel.visible = false
			weapon_orb.visible = true
			weapon_orb.scale = Vector3.ONE * 0.72
		PatternType.BULLET_WALL:
			gun_body.scale = Vector3(0.3, 0.16, 0.3)
			side_barrel_left.visible = true
			side_barrel_right.visible = true
			side_barrel_left.position.x = -0.18
			side_barrel_right.position.x = 0.18
		PatternType.MORTAR:
			gun_body.scale = Vector3(0.23, 0.22, 0.38)
			barrel.scale = Vector3(1.55, 1.65, 1.55)
			barrel.rotation.x = 1.08
			weapon_orb.visible = true
			weapon_orb.scale = Vector3.ONE * 0.45
		_:
			gun_body.scale = Vector3(0.2, 0.11, 0.3)
			side_barrel_left.visible = true
			side_barrel_right.visible = true
	# 面罩 / 能量核心 / 蓄力球也统一跟随弹幕颜色，让 5 种兵种一眼可辨。
	for mesh in [weapon_orb, visor, power_cell, charge_orb]:
		_apply_energy_material(mesh, bullet_color)


## 让能量部件跟随弹幕颜色。
func _apply_energy_material(mesh: MeshInstance3D, color: Color) -> void:
	if not mesh or not (mesh.material_override is StandardMaterial3D):
		return
	var material := mesh.material_override.duplicate() as StandardMaterial3D
	material.albedo_color = color
	material.emission = color
	mesh.material_override = material


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
		projectile_damage = damage_value
	# 缺项一律取旧行为默认，所以传空字典 == 阶段 2 之前的样子。
	_turn_speed = maxf(float(attrs.get("turn_speed", 0.0)), 0.0)
	_turn_speed_rad = deg_to_rad(_turn_speed)
	_accel_ratio = maxf(float(attrs.get("accel_ratio", 6.0)), 0.1)
	_brake_ratio = maxf(float(attrs.get("brake_ratio", 5.0)), 0.1)
	_knockback_resistance = clampf(float(attrs.get("knockback_resistance", 0.0)), 0.0, 1.0)
	_stagger_duration = maxf(float(attrs.get("stagger_duration", _stagger_duration)), 0.0)
	_armor = clampf(float(attrs.get("armor", 0.0)), 0.0, 1.0)
	update_health_label()


func configure_gait(settings: Dictionary) -> void:
	_rig.configure_gait(settings)


## 转向：turn_speed = 0 时瞬时（复刻旧 look_at），否则按度/秒平滑逼近目标朝向。
func _face_flat_direction(delta: float, flat_direction: Vector3) -> void:
	if flat_direction.is_zero_approx():
		return
	# 本模型 -Z 为正面，朝向角 = atan2(-x, -z)（与旧 look_at 等价）。
	var desired := atan2(-flat_direction.x, -flat_direction.z)
	if _turn_speed_rad <= 0.0:
		rotation.y = desired
		return
	var diff := wrapf(desired - rotation.y, -PI, PI)
	rotation.y += clampf(diff, -_turn_speed_rad * delta, _turn_speed_rad * delta)


func _physics_process(delta: float) -> void:
	# 同 melee_enemy：掉出场地先结算，不再跑 AI。
	if _kill_if_below_world():
		return
	var prior_yaw := rotation.y
	var locomoting := _stagger_time <= 0.0
	if _steering.tick(delta, _stagger_time <= 0.0 and not attack_queued and burst_remaining <= 0 and is_instance_valid(target) and global_position.distance_to(target.global_position) <= detection_range, target, move_speed):
		fire_cooldown = maxf(fire_cooldown - delta, 0.0)
		update_feedback(delta)
	else:
		_update_behavior(delta)
	# 右臂 IK 目标必须取枪的实时位置，所以放在行为更新之后。
	if gun_pivot:
		_rig.right_hand_ik_target = gun_pivot.global_transform * GRIP_OFFSET
	var actual_velocity := get_real_velocity()
	_rig.update(
		delta, Vector2(actual_velocity.x, actual_velocity.z).length(), move_speed, is_on_floor(),
		global_basis.orthonormalized().inverse() * actual_velocity, locomoting,
		wrapf(rotation.y - prior_yaw, -PI, PI) / maxf(delta, 0.001)
	)


## 行为层：走位 / 开火。动画交给 EnemyRig，避免早退路径漏掉动画更新。
## 把击杀记到最近的玩家头上（见 melee_enemy 里的同类说明）。
func _credit_killer() -> void:
	if not preload("res://scripts/combat_telemetry.gd").credits_player(self):
		return
	var player := TargetingUtil.nearest_player(self)
	if player != null and player.has_method("register_enemy_kill"):
		player.call("register_enemy_kill")


func _update_behavior(delta: float) -> void:
	# 【目标一旦不能打了，立刻重选，不等定时器】见 melee_enemy 里的同类说明。
	if not is_instance_valid(target) or float(target.get("health")) <= 0.0:
		if attack_queued or burst_remaining > 0:
			cancel_attack_charge()
		_retarget_timer = 0.0
	_retarget_timer -= delta
	if _retarget_timer <= 0.0:
		_retarget_timer = RETARGET_INTERVAL
		# 找不到人就置空，别把已经倒下的那个继续当目标。
		target = TargetingUtil.nearest_player(self) as CharacterBody3D
	if not is_on_floor():
		velocity.y -= gravity * delta
	movement_time += delta
	if _stagger_time > 0.0:
		_steering.direction_to(global_position, Vector3.ZERO, delta, false)
		_stagger_time = maxf(_stagger_time - delta, 0.0)
		velocity.x = _stagger_velocity.x
		velocity.z = _stagger_velocity.z
		_stagger_velocity = _stagger_velocity.move_toward(Vector3.ZERO, 34.0 * delta)
		move_and_slide()
		update_feedback(delta)
		animate_movement(delta)
		return
	if not is_instance_valid(target):
		_steering.direction_to(global_position, Vector3.ZERO, delta, false)
		stop_horizontal(delta)
		move_and_slide()
		return

	var offset := target.global_position - global_position
	var distance := offset.length()
	var flat_direction := Vector3(offset.x, 0.0, offset.z).normalized()
	if distance <= detection_range:
		if not _aim_locked:
			_face_flat_direction(delta, flat_direction)
		var move_direction := calculate_move_direction(flat_direction, distance)
		move_direction = _apply_navigation(move_direction, delta)
		# 蓄力/连发期间收脚站稳。射击时序不改，移动先让位给稳定瞄准。
		if attack_queued or burst_remaining > 0:
			move_direction = Vector3.ZERO
			_steering.direction_to(global_position, Vector3.ZERO, delta, false)
		var motion_ratio := _brake_ratio if move_direction.is_zero_approx() else _accel_ratio
		velocity.x = move_toward(velocity.x, move_direction.x * move_speed, move_speed * motion_ratio * delta)
		velocity.z = move_toward(velocity.z, move_direction.z * move_speed, move_speed * motion_ratio * delta)
		update_firing(delta, distance)
	else:
		if attack_queued or burst_remaining > 0:
			cancel_attack_charge()
		_steering.direction_to(global_position, Vector3.ZERO, delta, false)
		stop_horizontal(delta)
	GroundMovement.move(self, delta)
	update_feedback(delta)
	animate_movement(delta)


## 在机动风格给出的【真实移动方向】前方放一个短程导航目标。
##
## 旧实现把玩家当导航目标，再用“导航方向与玩家直线的夹角”判断要不要绕行。
## 这对近战成立，对远程兵不成立：它可能在玩家正前方横移，通往玩家的直线
## 完全畅通，但横移方向正好撞树。此时旧逻辑会把正确的导航结果权重降到 0。
##
## 现在导航只修正路线，不改变战术意图：目标始终位于原始移动方向前方；没有
## 障碍时返回方向与原始方向一致，有障碍时才沿网格绕开。
func _apply_navigation(move_direction: Vector3, delta: float) -> Vector3:
	var expects_movement := not move_direction.is_zero_approx()
	if not expects_movement:
		# 仍让卡死状态机收到“本帧不打算移动”，但不能让旧的脱困/换路状态
		# 反过来拖着一个本该站定的远程兵走。
		_steering.direction_to(global_position, Vector3.ZERO, delta, false)
		return Vector3.ZERO
	var motion_goal := global_position + move_direction.normalized() * NAV_MOTION_LOOKAHEAD
	return _steering.ground_velocity(motion_goal, move_direction * move_speed, delta) / maxf(move_speed, 0.01)


func calculate_move_direction(flat_direction: Vector3, distance: float) -> Vector3:
	var tangent := Vector3(-flat_direction.z, 0.0, flat_direction.x)
	var distance_error := clampf((distance - preferred_distance) / 5.0, -1.0, 1.0)
	match movement_style:
		MovementStyle.ORBIT:
			# Constant tangential velocity produces an obvious orbit around the player.
			return (tangent * movement_direction_sign + flat_direction * distance_error * 0.55).normalized()
		MovementStyle.ADVANCE_RETREAT:
			# Swoop forward and retreat on a fixed rhythm, like a shoot-em-up wave.
			var pulse := sin(movement_time * 1.25)
			return (flat_direction * pulse + tangent * 0.42 * movement_direction_sign).normalized()
		_:
			# Change strafing side every 2.4 seconds while correcting combat distance.
			var step_sign := 1.0 if fmod(movement_time, 4.8) < 2.4 else -1.0
			return (tangent * step_sign * movement_direction_sign + flat_direction * distance_error * 0.7).normalized()


func update_firing(delta: float, distance: float) -> void:
	fire_cooldown = maxf(fire_cooldown - delta, 0.0)
	if burst_remaining > 0:
		if not can_attack_from_current_view():
			burst_remaining = 0
			cancel_attack_charge()
			return
		burst_timer -= delta
		if burst_timer <= 0.0:
			fire_aimed_burst_round()
		return
	if attack_queued:
		# 狙击红线一旦瞄准必须射击到底：玩家靠躲避子弹，而不是靠脱离视野取消
		var is_sniper_shot := _is_sniper_pattern()
		if not is_sniper_shot and not can_attack_from_current_view():
			cancel_attack_charge()
			return
		attack_charge_time = maxf(attack_charge_time - delta, 0.0)
		# 红线跟随目标头部
		if _sniper_line != null and is_instance_valid(_sniper_line) and not _sniper_locked:
			if is_instance_valid(target):
				_sniper_locked_point = target.global_position + Vector3.UP * 0.8
			_sniper_line.update_line(muzzle.global_position, _sniper_locked_point)
		if not _aim_locked and attack_charge_time <= _charge_duration * 0.35:
			_lock_aim()
			# 复用主线的锁定时机：主线锁瞄准的同时把红线钉死
			if _sniper_line != null and is_instance_valid(_sniper_line) and not _sniper_locked:
				_sniper_locked = true
				if is_instance_valid(target):
					_sniper_locked_point = target.global_position + Vector3.UP * 0.8
				_sniper_line.lock_in()
				AudioUtil.play_at("shot", muzzle.global_position, -8.0, 2.2)
		var progress := 1.0 - attack_charge_time / maxf(_charge_duration, 0.01)
		muzzle_glow.light_energy = 5.0 if _aim_locked else 3.5 + sin(progress * 18.0) * 1.5
		charge_orb.visible = true
		charge_orb.scale = Vector3.ONE * (0.72 if _aim_locked else 0.5 + sin(progress * 14.0) * 0.12)
		if attack_charge_time <= 0.0:
			attack_queued = false
			fire_pattern()
			muzzle_glow.light_energy = 0.65
			charge_orb.visible = false
		return
	if fire_cooldown <= 0.0 \
			and Time.get_ticks_msec() >= next_global_fire_msec \
			and distance < detection_range * _fire_range_ratio \
			and can_attack_from_current_view():
		var is_sniper := _is_sniper_pattern()
		if is_sniper and not SkillLimiterUtil.can_start("sniper_lock", 1):
			return
		attack_queued = true
		attack_charge_time = _charge_duration * (1.35 if is_sniper else 1.0)
		_aim_locked = false
		_landing_valid = false
		if is_sniper:
			SkillLimiterUtil.acquire("sniper_lock")
			var target_head := target.global_position + Vector3.UP * 0.8
			_sniper_locked_point = target_head
			_sniper_line = TelegraphUtil.create_line(
				get_tree().current_scene, muzzle.global_position, target_head, attack_charge_time
			)
			_sniper_locked = false
		# 在准备前排队，不能让已经亮起的预警反复延长。
		next_global_fire_msec = Time.get_ticks_msec() + _global_fire_cooldown_ms


func can_attack_from_current_view() -> bool:
	# 可见性判断用【目标玩家自己的相机】，而不是敌人所在场景的视口相机 ——
	# 玩家相机才代表"玩家此刻能看到什么"。
	var player_camera := _target_camera()
	if not player_camera or not player_camera.is_position_in_frustum(global_position + Vector3.UP * 0.55):
		return false
	# Do not fire through hills, ruins or trees even when the enemy is inside the camera cone.
	var query := PhysicsRayQueryParameters3D.create(
		muzzle.global_position,
		target.global_position + Vector3.UP * 0.35,
		3,
		[get_rid()]
	)
	var hit := get_world_3d().direct_space_state.intersect_ray(query)
	return not hit.is_empty() and hit.collider == target


## 独立成一个可回归测试的入口，防止以后又误改回根视口 current camera。
func _target_camera() -> Camera3D:
	if not is_instance_valid(target):
		return null
	var player_camera := target.get("camera") as Camera3D
	if player_camera == null:
		player_camera = target.get_node_or_null("CameraPivot/Camera3D") as Camera3D
	return player_camera


func cancel_attack_charge() -> void:
	_aim_locked = false
	_landing_valid = false
	burst_remaining = 0
	burst_timer = 0.0
	for reference in _pending_mortars:
		var warning := reference.get_ref() as Node
		if is_instance_valid(warning):
			warning.call("cancel")
	_pending_mortars.clear()
	attack_queued = false
	attack_charge_time = 0.0
	fire_cooldown = maxf(fire_cooldown, 0.8)
	muzzle_glow.light_energy = 0.65
	charge_orb.visible = false
	# juice：狙击红线与限流一并清理
	if _sniper_line != null and is_instance_valid(_sniper_line):
		_sniper_line.cancel()
		_sniper_line = null
	if _sniper_locked or _is_sniper_pattern():
		SkillLimiterUtil.release("sniper_lock")
	_sniper_locked = false


func fire_pattern() -> void:
	var aim_direction := get_aim_direction()
	# 五种弹幕共用的唯一分发入口，所以在这里响一次就够，不必逐个模式加。
	AudioUtil.play_at("enemy_shot", muzzle.global_position, -7.0)
	match pattern_type:
		PatternType.MORTAR:
			fire_mortar_warning()
		PatternType.SNIPER:
			fire_sniper_shot()
		PatternType.AIMED_BURST:
			burst_remaining = 3
			burst_timer = 0.0
		PatternType.SPIRAL_RING:
			# A forward spiral fan stays visible; it never fires into the player's back.
			for index in range(5):
				var base_angle := lerpf(-30.0, 30.0, float(index) / 4.0)
				var wave_angle := sin(spiral_offset + float(index) * 0.8) * 8.0
				var spiral_direction := aim_direction.rotated(Vector3.UP, deg_to_rad(base_angle + wave_angle))
				var curve := -0.1 if index % 2 == 0 else 0.1
				spawn_enemy_bullet(spiral_direction, 6.6, curve)
			spiral_offset = fmod(spiral_offset + 0.75, TAU)
		PatternType.BULLET_WALL:
			# Four lanes deliberately leave a wide safe gap through the center.
			var side := Vector3.UP.cross(aim_direction).normalized()
			var wall_offsets := [-2.7, -0.9, 0.9, 2.7]
			for lateral_offset in wall_offsets:
				spawn_enemy_bullet(aim_direction, 6.8, 0.0, side * lateral_offset)
		_:
			# A restrained three-lane fan replaces the former five-lane spread.
			for index in range(3):
				var ratio := float(index) / 2.0
				var angle := deg_to_rad(lerpf(-18.0, 18.0, ratio))
				spawn_enemy_bullet(aim_direction.rotated(Vector3.UP, angle), 7.0, 0.0)
	fire_cooldown = fire_interval
	recoil_time = 0.12
	if burst_remaining == 0:
		_aim_locked = false


## 是否为狙击型敌人。
##
## 只认 pattern_type（由 enemy_roster.entries[].ranged_pattern = 5 显式配置），
## 刻意不做标题匹配：主线里「点射游骑兵」是 AIMED_BURST 单位，若按标题含
## 「游骑兵」判定，会把它误变成狙击兵。
func _is_sniper_pattern() -> bool:
	return pattern_type == PatternType.SNIPER


## juice：发射可见的超音速狙击重弹（带电离尾迹与近身呼啸），随后清理红线与限流。
func fire_sniper_shot() -> void:
	AudioUtil.play_at("sniper", muzzle.global_position, 2.4, 1.05)
	var from_pos := muzzle.global_position
	var to_pos := _sniper_locked_point if (_sniper_locked or not _sniper_locked_point.is_zero_approx()) \
		else (target.global_position + Vector3.UP * 0.8 if is_instance_valid(target) \
		else from_pos - global_transform.basis.z * 40.0)
	var dir := (to_pos - from_pos).normalized()
	if dir.is_zero_approx():
		dir = -global_transform.basis.z
	var scene := get_tree().current_scene if get_tree() else null
	if scene:
		# 枪口爆破烈焰
		CombatFXUtil.spawn_impact(scene, from_pos, dir, bullet_color, 2.0)
		var bullet := SniperBulletScript.new()
		scene.add_child(bullet)
		bullet.setup(from_pos, dir, self, projectile_damage * _damage_scale * 2.3, bullet_color)
	if _sniper_line != null and is_instance_valid(_sniper_line):
		_sniper_line.cancel()
		_sniper_line = null
	SkillLimiterUtil.release("sniper_lock")
	_sniper_locked = false


func fire_mortar_warning() -> void:
	if not _aim_locked:
		_lock_aim()
	if not _landing_valid:
		return
	var landing := _locked_landing
	var radius := clampf(2.2 + scale.x * 0.35, 2.2, 3.2)
	var flight := maxf(ConfigUtil.get_float("mortar.flight_time", 1.4), 0.2)
	var warning := GROUND_WARNING_SCENE.instantiate()
	warning.set_meta(&"combat_source", preload("res://scripts/combat_telemetry.gd").source_info(self, "炮击"))
	get_tree().current_scene.add_child(warning)
	warning.global_position = landing
	warning.call("setup", radius, flight, projectile_damage * 1.7 * _damage_scale, bullet_color)
	warning.call("bind_attacker", self)
	_pending_mortars = _pending_mortars.filter(func(ref: WeakRef) -> bool: return is_instance_valid(ref.get_ref()))
	_pending_mortars.append(weakref(warning))
	var shell := MortarShellUtil.new()
	get_tree().current_scene.add_child(shell)
	shell.global_position = muzzle.global_position
	shell.call("setup", muzzle.global_position, landing, flight, bullet_color)
	shell.warning_owner = weakref(warning)
	_aim_locked = false
	_landing_valid = false


func _lock_aim() -> void:
	if not is_instance_valid(target) or float(target.get("health")) <= 0.0:
		return
	_locked_aim = (target.global_position + Vector3.UP * 0.35 - muzzle.global_position).normalized()
	_aim_locked = true
	var predicted_position := target.global_position + target.velocity * 0.55
	var ground_query := PhysicsRayQueryParameters3D.create(
		predicted_position + Vector3.UP * 12.0,
		predicted_position + Vector3.DOWN * 6.0,
		1
	)
	var ground_hit := get_world_3d().direct_space_state.intersect_ray(ground_query)
	_landing_valid = not ground_hit.is_empty()
	if _landing_valid:
		_locked_landing = ground_hit.position + Vector3.UP * 0.035


func fire_aimed_burst_round() -> void:
	spawn_enemy_bullet(get_aim_direction(), 9.5, 0.0)
	burst_remaining -= 1
	if burst_remaining == 0:
		_aim_locked = false
	burst_timer = 0.26
	recoil_time = 0.08


func get_aim_direction() -> Vector3:
	if _aim_locked:
		return _locked_aim
	var aim_point := target.global_position + Vector3.UP * 0.35
	return (aim_point - muzzle.global_position).normalized()


func spawn_enemy_bullet(
	shot_direction: Vector3,
	shot_speed: float,
	curve: float,
	spawn_offset: Vector3 = Vector3.ZERO
) -> void:
	var scene := get_tree().current_scene
	if not scene:
		return
	# 走对象池：弹幕一次齐射会生成 3~5 颗，是全项目唯一还在反复
	# instantiate / queue_free 的对象。
	var bullet := PoolUtil.acquire_scene(BulletPoolKey, ENEMY_BULLET_SCENE)
	scene.add_child(bullet)
	# 顺序不能反：先摆到世界坐标，setup() 里的 look_at 才有正确基准。
	bullet.global_position = muzzle.global_position + spawn_offset
	bullet.call("setup", shot_direction, self,
		projectile_damage * _damage_scale, shot_speed, curve, bullet_color)


func stop_horizontal(delta: float) -> void:
	velocity.x = move_toward(velocity.x, 0.0, move_speed * _brake_ratio * delta)
	velocity.z = move_toward(velocity.z, 0.0, move_speed * _brake_ratio * delta)


func take_damage(amount: float) -> void:
	if health <= 0.0 or is_queued_for_deletion():
		return
	var before := health
	_took_damage = true
	# 【重量】护甲：对所有伤害来源减伤（含手雷 / 脉冲的爆炸结算）。
	health -= amount * (1.0 - _armor)
	preload("res://scripts/combat_telemetry.gd").enemy_damaged(self, before)
	if health <= 0.0:
		die()
		return
	hit_flash_time = 0.1
	_visuals.set_flash(true)
	_rig.flinch()
	update_health_label()


func die() -> void:
	cancel_attack_charge()
	set_physics_process(false)
	_credit_killer()
	# 掉落表在配置里（drops 段）。远程兵种的 chance 配得比近战略高 ——
	# 它们更难打，也有理由给更好的回报。
	var drop := PickupUtil.roll_drop("ranged")
	if drop >= 0:
		spawn_pickup(drop, Vector3(0.0, 0.25, 0.0))
	queue_free()


## 掉出场地就地判死。判定与设计理由见 melee_enemy 的同名函数，两份实现刻意保持一致
## —— 谁漏掉一边，就会重新出现"最后一个敌人不见了、波次卡住"。
func _kill_if_below_world() -> bool:
	var expected_ground := TerrainFieldUtil.height_at(global_position.x, global_position.z)
	if global_position.y >= expected_ground - _fall_kill_depth:
		return false
	health = 0.0
	cancel_attack_charge()
	# 同 melee_enemy：queue_free() 帧末才生效，不停主循环就会重复结算这笔击杀。
	set_physics_process(false)
	if _took_damage:
		_credit_killer()
	queue_free()
	return true


func spawn_pickup(pickup_type: int, local_offset: Vector3) -> void:
	var scene := get_tree().current_scene
	if not scene:
		return
	var pickup := PICKUP_SCENE.instantiate()
	scene.add_child(pickup)
	pickup.global_position = global_position + local_offset
	# configure() 本身已按类型分发，直接调用即可（原先这里有两个内容完全
	# 相同的历史分支，已在上一轮清掉）。
	pickup.call("configure", pickup_type)


func update_feedback(delta: float) -> void:
	hit_flash_time = maxf(hit_flash_time - delta, 0.0)
	_visuals.set_flash(hit_flash_time > 0.0)
	recoil_time = maxf(recoil_time - delta, 0.0)
	gun_pivot.rotation.x = lerp(gun_pivot.rotation.x, -0.22 if recoil_time > 0.0 else 0.0, minf(delta * 18.0, 1.0))


## 姿态由 EnemyRig 在自身坐标内解算，去掉旧的世界 X 速度倾斜。
func animate_movement(delta: float) -> void:
	enemy_model.rotation.z = lerp_angle(
		enemy_model.rotation.z, 0.0, 1.0 - exp(-delta * 7.0)
	)


func update_health_label() -> void:
	health_label.text = "%s  %d/%d" % [enemy_title, ceili(health), ceili(max_health)]


## juice：被震地脉冲破招——打断蓄力并陷入硬直（供 shockwave 破招链路调用）。
func parry() -> void:
	cancel_attack_charge()
	_stagger_time = _stagger_duration * 1.5
	_stagger_velocity = -global_transform.basis.z * 7.5
	hit_flash_time = 0.15
	_visuals.set_flash(true)
	if _rig:
		_rig.flinch()
