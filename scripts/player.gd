extends CharacterBody3D

## 流程与音频都通过 preload 静态调用：autoload 未注册时自动降级为空操作，
## 不会因为少了 autoload 就整个脚本报错。
const GameFlowUtil := preload("res://scripts/game_flow.gd")
const AudioUtil := preload("res://scripts/audio_manager.gd")
const EventBusUtil := preload("res://scripts/event_bus.gd")
const ConfigUtil := preload("res://scripts/game_config.gd")
const TerrainFieldUtil := preload("res://scripts/terrain_field.gd")
## 玩家控制器（P0 重构版）。
##
## 职责切分（原来 420 行的单文件已拆开）：
##   - 本文件     ：输入采集 / 移动物理 / 生命与受击 / 技能冷却 / 组件编排
##   - PlayerRig  ：程序化姿势与动画（含 ADS / 冲刺 / 翻滚 / 受击 / 落地）
##   - PlayerWeapon：射击 / 后坐力 / 扩散 / 弹匣换弹 / 武器等级
##   - PlayerHUD  ：HUD 显示（含动态准星与命中标记）
##
## 三个组件都在 _ready() 里用代码创建并注入节点引用，因此 player.tscn 不需要改结构。
## 对外保留原有接口（take_damage / try_heal / register_enemy_kill / upgrade_weapon /
## get_weapon_level / get_survival_time），敌人、掉落物、导演脚本无需改动。

@export_category("移动")
@export var speed: float = 5.0
@export var sprint_multiplier: float = 1.7
@export var acceleration: float = 24.0
@export var deceleration: float = 30.0
@export var air_control: float = 0.35
@export var jump_velocity: float = 7.0
@export var step_height: float = 0.75
@export var rotation_smooth: float = 16.0

@export_category("相机")
@export var mouse_sensitivity: float = 0.002
@export var camera_smooth: float = 22.0
@export var fov_smooth: float = 13.0
@export var hip_fov: float = 70.0

@export_category("狙击模式（按住右键）")
## 视野大幅收窄 + 相机拉近贴肩 + 鼠标灵敏度同步降低，方便瞄远处小目标。
@export var sniper_fov: float = 26.0
@export var sniper_sensitivity_multiplier: float = 0.34
@export var hip_spring_length: float = 5.0
@export var sniper_spring_length: float = 2.3
@export var hip_arm_offset: Vector3 = Vector3(1.05, 0.12, 0)
@export var sniper_arm_offset: Vector3 = Vector3(0.62, 0.2, 0)

@export_category("瞄准")
@export var ads_speed_multiplier: float = 0.62

@export_category("闪避翻滚")
@export var dodge_speed: float = 12.5
@export var dodge_duration: float = 0.42
@export var dodge_cooldown_time: float = 0.85
@export var dodge_invulnerability: float = 0.34

@export_category("生命")
@export var max_health: float = 100.0
@export var hit_invulnerability: float = 0.42

@export_category("技能")
@export var grenade_cooldown_time: float = 6.0
@export var grenade_throw_speed: float = 17.0
@export var skill_cooldown_time: float = 9.0
@export var skill_radius: float = 9.0
@export var skill_damage: float = 55.0
@export var skill_push: float = 15.0

var gravity: float = ProjectSettings.get_setting("physics/3d/default_gravity")
var target_yaw: float
var target_pitch: float
var health: float
## 护盾：《命运2》式 —— 先于生命承受伤害，停火一段时间后逐点回满。
##
## 它存在的唯一理由是给"被近战从背后捅刀"留出反应窗口：第三人称看不到背后，
## 原先一次背刺 24 点、连击几下就死，属于玩家无法应对的死亡。
## 现在背刺先打在护盾上，只要之后拉开距离就能恢复。
## 数值在 data/game_config.json 的 player 段（与敌人伤害倍率放在一起，便于整体调难度）。
var shield: float
var max_shield := 70.0
var _shield_regen_delay := 3.0
var _shield_regen_rate := 35.0
var _health_regen_delay := 6.0
var _health_regen_rate := 6.0
var _health_regen_cap_ratio := 0.5
## 距离"开始恢复"的剩余秒数，受击时被重置为完整延迟 —— 这就是停火才回血的机制。
var _shield_regen_timer := 0.0
var _health_regen_timer := 0.0
var kill_count: int
var survival_time: float
static var best_survival_time: float

@onready var camera_pivot: Node3D = $CameraPivot
@onready var spring_arm: SpringArm3D = get_node_or_null("CameraPivot/SpringArm3D")
@onready var camera: Camera3D = get_node_or_null("CameraPivot/SpringArm3D/Camera3D")
@onready var _flashlight: PlayerFlashlight = get_node_or_null("CameraPivot/FlashlightRig")
@onready var player_model: Node3D = get_node_or_null("PlayerModel")
@onready var aim_ui: CanvasLayer = get_node_or_null("AimUI")

var _rig: PlayerRig
var _weapon: PlayerWeapon
var _hud: PlayerHUD
## -1 跟随天气自动开关；按 F 后以玩家选择为准，直到本局结束。
var _flashlight_override := -1
var _flashlight_weather: Node
var _flashlight_sun: DirectionalLight3D

var _aiming := false
var _sprinting := false
var _free_look := false
var _rolling := false
var _roll_time := 0.0
var _roll_direction := Vector3.FORWARD
var _dodge_cooldown := 0.0
var _grenade_cooldown := 0.0
var _skill_cooldown := 0.0
var _damage_invulnerability := 0.0
var _fall_speed := 0.0
var _was_grounded := true
## 死亡不是一个瞬时跳转：先让角色与镜头完成倒地，再把结算事件交给 GameFlow。
var _dying := false
var _death_time := 0.0
var _death_duration := 1.35
var _death_event_sent := false
## 场景仍在探索阶段，边界尚未由山体 / 悬崖完整封闭。先保存最近一次稳定落脚点，
## 玩家掉出地形时拉回；它不参与最终箱庭边界的视觉设计。
var _last_safe_position := Vector3.ZERO
var _has_safe_position := false
var _safe_ground_time := 0.0
var _fall_rescue_depth := 14.0
const SAFE_GROUND_SETTLE_TIME := 0.25
const FALL_RESCUE_LIFT := 1.1

func _ready() -> void:
	# 只有真正进入游戏才捕获鼠标。启动时 GameFlow 停在主菜单，
	# 这里如果无条件捕获，菜单按钮就点不动了。
	if GameFlowUtil.is_playing():
		Input.mouse_mode = Input.MOUSE_MODE_CAPTURED
	if not camera:
		camera = get_node_or_null("CameraPivot/Camera3D")
	if camera:
		camera.fov = hip_fov
		# 场上只有一个相机。
		camera.current = true
	target_yaw = camera_pivot.rotation.y
	target_pitch = camera_pivot.rotation.x
	health = max_health
	_read_defense_config()
	_read_ability_config()
	_read_feel_config()
	_last_safe_position = global_position
	_has_safe_position = true
	shield = max_shield
	_setup_components()
	_update_flashlight()
	_refresh_hud()


## 读护盾 / 自愈参数。放在配置里而不是 @export：它们是全局机制，
## 与敌人伤害倍率摆在同一处才好一起调。
func _read_defense_config() -> void:
	max_shield = maxf(ConfigUtil.get_float("player.shield_max", 70.0), 0.0)
	_shield_regen_delay = maxf(ConfigUtil.get_float("player.shield_regen_delay", 3.0), 0.0)
	_shield_regen_rate = maxf(ConfigUtil.get_float("player.shield_regen_rate", 35.0), 0.0)
	_health_regen_delay = maxf(ConfigUtil.get_float("player.health_regen_delay", 6.0), 0.0)
	_health_regen_rate = maxf(ConfigUtil.get_float("player.health_regen_rate", 6.0), 0.0)
	_health_regen_cap_ratio = clampf(
		ConfigUtil.get_float("player.health_regen_cap_ratio", 0.5), 0.0, 1.0
	)


## 读技能与翻滚参数（翻滚 Shift / 手雷 E / 震地脉冲 Q）。
##
## 这些原先是本文件顶上的 @export 常量，改起来要开编辑器、在 Player 节点上找属性，
## 而手雷的引信与爆炸数值还另在 grenade.gd 里 —— 于是"想调 Q 键威力"根本找不到
## 在哪。现在统一到 data/game_config.json 的 abilities 段，改完重开游戏即生效。
func _read_ability_config() -> void:
	grenade_cooldown_time = maxf(
		ConfigUtil.get_float("abilities.grenade.cooldown", 6.0), 0.0
	)
	grenade_throw_speed = maxf(
		ConfigUtil.get_float("abilities.grenade.throw_speed", 17.0), 0.0
	)
	skill_cooldown_time = maxf(ConfigUtil.get_float("abilities.skill.cooldown", 9.0), 0.0)
	skill_radius = maxf(ConfigUtil.get_float("abilities.skill.radius", 9.0), 0.5)
	skill_damage = maxf(ConfigUtil.get_float("abilities.skill.damage", 55.0), 0.0)
	skill_push = maxf(ConfigUtil.get_float("abilities.skill.push", 15.0), 0.0)
	dodge_speed = maxf(ConfigUtil.get_float("abilities.dodge.speed", 12.5), 0.0)
	dodge_duration = maxf(ConfigUtil.get_float("abilities.dodge.duration", 0.42), 0.05)
	dodge_cooldown_time = maxf(ConfigUtil.get_float("abilities.dodge.cooldown", 0.85), 0.0)
	dodge_invulnerability = maxf(
		ConfigUtil.get_float("abilities.dodge.invulnerability", 0.34), 0.0
	)


## 读"手感"参数（移动 / 相机 / 瞄准 / 生命）。
##
## 这些原先是本文件顶上的 @export。@export 的问题是：想改就得开编辑器、
## 在 Player 节点上逐个找属性，而且改完还得记得改 .tscn 才存得住 ——
## 实际上等于"改不动"。@export 默认值保留原样作为兜底，配置缺失时手感不变。
func _read_feel_config() -> void:
	speed = maxf(ConfigUtil.get_float("player.speed", 5.0), 0.1)
	sprint_multiplier = maxf(ConfigUtil.get_float("player.sprint_multiplier", 1.7), 1.0)
	acceleration = maxf(ConfigUtil.get_float("player.acceleration", 24.0), 0.1)
	deceleration = maxf(ConfigUtil.get_float("player.deceleration", 30.0), 0.1)
	air_control = clampf(ConfigUtil.get_float("player.air_control", 0.35), 0.0, 1.0)
	jump_velocity = maxf(ConfigUtil.get_float("player.jump_velocity", 7.0), 0.0)
	step_height = clampf(ConfigUtil.get_float("player.step_height", 0.75), 0.0, 1.25)
	rotation_smooth = maxf(ConfigUtil.get_float("player.rotation_smooth", 16.0), 0.1)
	ads_speed_multiplier = clampf(ConfigUtil.get_float("player.ads_speed_multiplier", 0.62), 0.05, 1.0)

	mouse_sensitivity = maxf(ConfigUtil.get_float("player.mouse_sensitivity", 0.002), 0.0)
	camera_smooth = maxf(ConfigUtil.get_float("player.camera_smooth", 22.0), 0.1)
	fov_smooth = maxf(ConfigUtil.get_float("player.fov_smooth", 13.0), 0.1)
	hip_fov = clampf(ConfigUtil.get_float("player.fov.hip", 70.0), 10.0, 140.0)
	sniper_fov = clampf(ConfigUtil.get_float("player.fov.sniper", 26.0), 5.0, 140.0)
	sniper_sensitivity_multiplier = clampf(
		ConfigUtil.get_float("player.sniper_sensitivity_multiplier", 0.34), 0.01, 1.0
	)
	hip_spring_length = maxf(ConfigUtil.get_float("player.hip_spring_length", 5.0), 0.1)
	sniper_spring_length = maxf(ConfigUtil.get_float("player.sniper_spring_length", 2.3), 0.1)

	max_health = maxf(ConfigUtil.get_float("player.max_health", 100.0), 1.0)
	hit_invulnerability = maxf(ConfigUtil.get_float("player.hit_invulnerability", 0.42), 0.0)
	_fall_rescue_depth = maxf(ConfigUtil.get_float("player.fall_rescue_depth", 14.0), 3.0)
	_death_duration = maxf(ConfigUtil.get_float("player.animation.death_duration", 1.35), 0.1)


# ---------------------------------------------------------------- 组件编排

func _setup_components() -> void:
	# 顺序有讲究：武器先就位，手臂 IK 才能取到握把/护木的世界坐标。
	_weapon = PlayerWeapon.new()
	_weapon.name = "PlayerWeapon"
	add_child(_weapon)
	_weapon.setup(self, camera)
	_weapon.ammo_changed.connect(_on_ammo_changed)
	_weapon.sniper_ammo_changed.connect(_on_sniper_ammo_changed)


	if player_model:
		_rig = PlayerRig.new()
		_rig.name = "PlayerRig"
		add_child(_rig)
		_rig.setup(player_model)
		_rig.set_weapon(_weapon)

	_hud = PlayerHUD.new()
	_hud.name = "PlayerHUD"
	add_child(_hud)
	# 相机给受击方向指示器判定"前方"，自身给小地图定位。
	_hud.setup(aim_ui, camera, self)


func _refresh_hud() -> void:
	if not _hud:
		return
	_hud.set_health(health, max_health)
	_hud.set_shield(shield, max_shield)
	_hud.set_kills(kill_count)
	_hud.set_survival(survival_time, best_survival_time)
	_hud.set_abilities(_grenade_cooldown, _skill_cooldown)
	if _weapon:
		_hud.set_weapon_level(
			_weapon.get_level(), _weapon.get_pellet_count(), _weapon.get_bullet_damage()
		)
		_hud.set_weapon_labels(_weapon.get_weapon_label(), _weapon.get_sniper_label())
		_hud.set_ammo(_weapon.get_ammo(), _weapon.get_capacity())
		_hud.set_sniper_ammo(
			_weapon.get_sniper_ammo(),
			_weapon.get_sniper_capacity(),
			_weapon.get_sniper_reload_remaining()
		)


func _on_ammo_changed(current: int, capacity: int) -> void:
	if _hud:
		_hud.set_ammo(current, capacity)


func _on_sniper_ammo_changed(current: int, capacity: int, reload_remaining: float) -> void:
	if _hud:
		_hud.set_sniper_ammo(current, capacity, reload_remaining)


# ---------------------------------------------------------------- 输入

func _held(base: String) -> bool:
	return Input.is_action_pressed(base)


func _just(base: String) -> bool:
	return Input.is_action_just_pressed(base)


func _move_vector() -> Vector2:
	return Input.get_vector("move_left", "move_right", "move_forward", "move_back")


## 开火/瞄准的前置条件：鼠标已捕获（否则在主菜单里点按钮会开枪）。
func _is_aim_captured() -> bool:
	return Input.mouse_mode == Input.MOUSE_MODE_CAPTURED


func _input(event: InputEvent) -> void:
	if _dying:
		return
	# 菜单 / 暂停 / 结算期间完全不接管鼠标，否则点不动按钮。
	# ESC 也统一交给 GameFlow 处理，避免两边各切一次状态。
	if not GameFlowUtil.is_playing():
		return
	if event.is_action_pressed("flashlight") and not event.is_echo():
		_flashlight_override = 0 if _flashlight != null and _flashlight.is_light_enabled() else 1
		_update_flashlight()
		if _hud:
			_hud.show_notice("手电筒已开启" if _flashlight_override == 1 else "手电筒已关闭")
	elif event is InputEventMouseMotion and _is_aim_captured():
		var sensitivity := mouse_sensitivity * (sniper_sensitivity_multiplier if _aiming else 1.0)
		target_yaw -= event.relative.x * sensitivity
		target_pitch -= event.relative.y * sensitivity
		target_pitch = clamp(target_pitch, deg_to_rad(-70.0), deg_to_rad(65.0))
	elif event is InputEventMouseButton and event.pressed:
		Input.mouse_mode = Input.MOUSE_MODE_CAPTURED


# ---------------------------------------------------------------- 主循环

func _physics_process(delta: float) -> void:
	_update_flashlight()
	if _dying:
		_update_death(delta)
		return
	if _recover_if_below_world():
		_update_camera(delta)
		_update_presentation(delta)
		return
	survival_time += delta
	_free_look = _held("free_look") and _is_aim_captured()
	_tick_timers(delta)
	_update_camera(delta)
	_update_movement(delta)
	_update_combat(delta)
	_update_presentation(delta)
	var move_start := global_transform
	var started_on_floor := is_on_floor()
	var requested_horizontal := Vector3(velocity.x, 0.0, velocity.z) * delta
	move_and_slide()
	_try_step_up(move_start, requested_horizontal, started_on_floor)
	_update_landing(delta)


func _update_flashlight() -> void:
	if _flashlight == null:
		return
	if not is_instance_valid(_flashlight_weather):
		_flashlight_weather = get_tree().root.find_child("WeatherSystem", true, false)
		if _flashlight_weather != null:
			_flashlight_sun = _flashlight_weather.get_node_or_null("../Sky3D/SunLight") as DirectionalLight3D
	var automatic := false
	if is_instance_valid(_flashlight_weather) and is_instance_valid(_flashlight_sun):
		var rain := float(_flashlight_weather.get("_rain_intensity"))
		var sun_height := _flashlight_sun.global_basis.z.normalized().y
		automatic = rain >= 0.68 and sun_height < 0.12
	var enabled := automatic if _flashlight_override < 0 else _flashlight_override == 1
	_flashlight.set_light_enabled(enabled)


## Godot 的 CharacterBody3D 不会自动跨过垂直小边，即使它只有半米高。
## 这里在水平移动被挡住时，从移动前的位置尝试“抬脚 → 向前 → 落地”。
## 高墙在抬高后仍会挡住，因此不会被这段逻辑翻越。
func _try_step_up(start: Transform3D, horizontal_motion: Vector3, started_on_floor: bool) -> void:
	if not started_on_floor or step_height <= 0.0 or velocity.y > 0.01:
		return
	if horizontal_motion.length_squared() < 0.000001:
		return
	var actual_horizontal := global_position - start.origin
	actual_horizontal.y = 0.0
	var blocked := is_on_wall() or actual_horizontal.length() < horizontal_motion.length() * 0.65
	if not blocked or not test_move(start, horizontal_motion):
		return
	var up := Vector3.UP * step_height
	if test_move(start, up):
		return
	var raised := start
	raised.origin += up
	if test_move(raised, horizontal_motion):
		return
	var ahead := raised
	ahead.origin += horizontal_motion
	var params := PhysicsTestMotionParameters3D.new()
	params.from = ahead
	params.motion = Vector3.DOWN * (step_height + 0.08)
	params.margin = 0.001
	var result := PhysicsTestMotionResult3D.new()
	if not PhysicsServer3D.body_test_motion(get_rid(), params, result):
		return
	if result.get_collision_count() <= 0:
		return
	var floor_normal := result.get_collision_normal(0)
	if floor_normal.dot(Vector3.UP) < cos(floor_max_angle):
		return
	var landing := ahead.origin + result.get_travel()
	var rise := landing.y - start.origin.y
	if rise <= 0.02 or rise > step_height + 0.02:
		return
	global_position = landing
	velocity.y = 0.0
	apply_floor_snap()


func _tick_timers(delta: float) -> void:
	_dodge_cooldown = maxf(_dodge_cooldown - delta, 0.0)
	_grenade_cooldown = maxf(_grenade_cooldown - delta, 0.0)
	_skill_cooldown = maxf(_skill_cooldown - delta, 0.0)
	_damage_invulnerability = maxf(_damage_invulnerability - delta, 0.0)
	_regenerate(delta)


## 护盾与生命的自动恢复。两段都是"先等 delay，再按 rate 逐点涨"。
##
## 生命刻意只回到上限的一个比例（health_regen_cap_ratio）：满血自愈会让生存模式
## 彻底失去压力，而"恢复到一半"既能救回被偷袭后的残血，又保留持续掉血的张力。
func _regenerate(delta: float) -> void:
	_shield_regen_timer = maxf(_shield_regen_timer - delta, 0.0)
	if _shield_regen_timer <= 0.0 and shield < max_shield:
		shield = minf(shield + _shield_regen_rate * delta, max_shield)
	_health_regen_timer = maxf(_health_regen_timer - delta, 0.0)
	if _health_regen_timer > 0.0:
		return
	var cap := max_health * _health_regen_cap_ratio
	if health < cap:
		health = minf(health + _health_regen_rate * delta, cap)


func _update_camera(delta: float) -> void:
	var weight := minf(camera_smooth * delta, 1.0)
	var yaw := lerp_angle(camera_pivot.rotation.y, target_yaw, weight)
	var pitch := lerpf(camera_pivot.rotation.x, target_pitch, weight)
	# 后坐力作为独立的视角偏移叠加，随后由武器平滑回收。
	if _weapon:
		yaw += _weapon.view_kick.y
		pitch += _weapon.view_kick.x
	camera_pivot.rotation.y = yaw
	camera_pivot.rotation.x = clampf(pitch, deg_to_rad(-80.0), deg_to_rad(75.0))
	var zoom := minf(fov_smooth * delta, 1.0)
	if camera:
		camera.fov = lerpf(camera.fov, sniper_fov if _aiming else hip_fov, zoom)
	if spring_arm:
		spring_arm.spring_length = lerpf(
			spring_arm.spring_length, sniper_spring_length if _aiming else hip_spring_length, zoom
		)
		spring_arm.position = spring_arm.position.lerp(
			sniper_arm_offset if _aiming else hip_arm_offset, zoom
		)


func _update_movement(delta: float) -> void:
	if not is_on_floor():
		velocity.y -= gravity * delta
		_fall_speed = minf(_fall_speed, velocity.y)
	elif _just("jump"):
		velocity.y = jump_velocity

	var input_dir := _move_vector()
	var direction := camera_pivot.global_basis * Vector3(input_dir.x, 0.0, input_dir.y)
	direction.y = 0.0
	direction = direction.normalized()

	if _rolling:
		_advance_roll(delta)
		return

	if _can_dodge() and _just("dodge"):
		_start_roll(direction)
		_advance_roll(delta)
		return

	_sprinting = (
		_held("sprint") and not direction.is_zero_approx() and is_on_floor()
	)
	var target_speed := speed * (sprint_multiplier if _sprinting else 1.0)
	if _aiming:
		target_speed *= ads_speed_multiplier
	var change_rate := acceleration if not direction.is_zero_approx() else deceleration
	if not is_on_floor():
		change_rate *= air_control
	velocity.x = move_toward(velocity.x, direction.x * target_speed, change_rate * delta)
	velocity.z = move_toward(velocity.z, direction.z * target_speed, change_rate * delta)

	# 第三人称射击：横向移动时躯干始终朝向相机准心方向（+PI 对应模型的 +Z 正面）。
	# 自由观察（按住 V）时不跟随相机，这样才能绕着角色看到正面。
	if player_model and not _free_look:
		player_model.rotation.y = lerp_angle(
			player_model.rotation.y, camera_pivot.rotation.y + PI, minf(rotation_smooth * delta, 1.0)
		)


func _can_dodge() -> bool:
	return is_on_floor() and _dodge_cooldown <= 0.0 and not _rolling


func _start_roll(direction: Vector3) -> void:
	var roll_direction := direction
	if roll_direction.is_zero_approx():
		roll_direction = -camera_pivot.global_basis.z
		roll_direction.y = 0.0
	_roll_direction = roll_direction.normalized()
	_rolling = true
	_roll_time = dodge_duration
	_dodge_cooldown = dodge_cooldown_time
	# 翻滚前段给无敌帧，用来躲弹幕。
	_damage_invulnerability = maxf(_damage_invulnerability, dodge_invulnerability)


func _advance_roll(delta: float) -> void:
	_roll_time = maxf(_roll_time - delta, 0.0)
	var remaining := clampf(_roll_time / maxf(dodge_duration, 0.01), 0.0, 1.0)
	var current_speed := dodge_speed * lerpf(0.35, 1.0, remaining)
	velocity.x = _roll_direction.x * current_speed
	velocity.z = _roll_direction.z * current_speed
	if _roll_time <= 0.0:
		_rolling = false


func _update_combat(delta: float) -> void:
	if not _weapon:
		return
	_weapon.visual_direction = _compute_weapon_direction()
	var captured := _is_aim_captured()
	_aiming = _held("aim") and captured and not _rolling and not _free_look
	var trigger := _held("shoot") and captured and not _rolling
	if _just("reload"):
		_weapon.start_reload()
	_handle_grenade()
	_handle_skill()
	var movement_ratio := Vector2(velocity.x, velocity.z).length() / maxf(speed, 0.01)
	_weapon.update(delta, trigger, _aiming, movement_ratio)


## 相机俯仰（弧度，正为抬头）。上半身与枪的俯仰都由它驱动，
## 保证"抬头时人和枪一起仰"，而不是只有枪单独动。
func _view_pitch() -> float:
	return camera_pivot.rotation.x if camera_pivot else 0.0


## 枪的视觉朝向 = 身体水平朝向 + 相机俯仰。
##
## yaw 取自身体而不是相机：身体转向带平滑滞后，若用相机 yaw，快速转视角时
## 枪会先于身体转过去，看起来像枪脱开身体自己甩。用身体朝向则两者永远同步。
## （弹道不受影响，仍由 get_aim_point() 的准心射线决定。）
func _compute_weapon_direction() -> Vector3:
	var pitch := _view_pitch()
	var horizontal := Vector3.FORWARD
	if player_model:
		horizontal = player_model.global_basis.z
	horizontal.y = 0.0
	if horizontal.is_zero_approx():
		horizontal = Vector3.FORWARD
	horizontal = horizontal.normalized()
	return (horizontal * cos(pitch) + Vector3.UP * sin(pitch)).normalized()


func _handle_grenade() -> void:
	if _grenade_cooldown > 0.0 or not _just("grenade"):
		return
	var scene := get_tree().current_scene
	if not scene:
		return
	_grenade_cooldown = grenade_cooldown_time
	var forward := -camera_pivot.global_basis.z
	var origin := global_position + Vector3.UP * 1.35 + forward * 0.7
	var grenade := Grenade.new()
	grenade.set_meta(&"combat_context", preload("res://scripts/combat_telemetry.gd").begin_attack(self, "E"))
	scene.add_child(grenade)
	grenade.launch(origin, forward + Vector3.UP * 0.16, grenade_throw_speed)


func _handle_skill() -> void:
	if _skill_cooldown > 0.0 or not _just("skill"):
		return
	var scene := get_tree().current_scene
	if not scene:
		return
	_skill_cooldown = skill_cooldown_time
	var wave := Shockwave.new()
	wave.set_meta(&"combat_context", preload("res://scripts/combat_telemetry.gd").begin_attack(self, "Q"))
	scene.add_child(wave)
	wave.global_position = global_position + Vector3.UP * 0.15
	wave.perform(skill_radius, skill_damage, skill_push)


func _update_presentation(delta: float) -> void:
	var horizontal_speed := Vector2(velocity.x, velocity.z).length()
	if _rig:
		_rig.sprinting = _sprinting
		_rig.aiming = _aiming
		_rig.rolling = _rolling
		_rig.reloading = _weapon.is_reloading() if _weapon else false
		# 只在翻滚期间推进；非翻滚状态固定在 0，避免 rest 状态下落到 TAU。
		_rig.roll_progress = (
			clampf(1.0 - _roll_time / dodge_duration, 0.0, 1.0)
			if _rolling and dodge_duration > 0.0
			else 0.0
		)
		_rig.view_pitch = _view_pitch()
		_rig.update(
			delta, horizontal_speed, velocity.y, is_on_floor(), speed, speed * sprint_multiplier
		)
	if not _hud:
		return
	_hud.set_survival(survival_time, best_survival_time)
	_hud.set_abilities(_grenade_cooldown, _skill_cooldown)
	# 生命与护盾都必须每帧刷新，不能只在受伤时推送。
	# 原因：两者都会【自动回复】，而回复这条路不会经过 take_damage / try_heal ——
	# 只推一次的话，自愈期间 HUD 显示的是旧值，低血量叠加层也会一直不消退。
	# HUD 内部按文本去重，所以这里每帧调用没有额外开销。
	_hud.set_health(health, max_health)
	_hud.set_shield(shield, max_shield)
	if _weapon:
		# 备弹会随换弹 / 拾取变化，同样每帧推（面板内部不做查询）。
		_hud.set_reserve(_weapon.get_reserve(), _weapon.get_sniper_reserve())
		_hud.set_weapon_upgrades(
			_weapon.get_upgrade_stacks("fire_rate"),
			_weapon.get_upgrade_stacks("damage"),
			_weapon.get_upgrade_stacks("magazine")
		)
	if _weapon:
		_hud.update(delta, _weapon.get_bloom_ratio(), _aiming, _weapon.is_reloading())
		_hud.set_weapon_level(
			_weapon.get_level(), _weapon.get_pellet_count(), _weapon.get_bullet_damage()
		)
		_hud.set_weapon_labels(_weapon.get_weapon_label(), _weapon.get_sniper_label())
		if _weapon.is_reloading():
			_hud.set_reload(true, _weapon.get_reload_ratio())
		else:
			_hud.set_ammo(_weapon.get_ammo(), _weapon.get_capacity())
		_hud.set_sniper_ammo(
			_weapon.get_sniper_ammo(),
			_weapon.get_sniper_capacity(),
			_weapon.get_sniper_reload_remaining()
		)
	else:
		_hud.update(delta, 0.0, _aiming, false)


func _update_landing(delta: float) -> void:
	var grounded := is_on_floor()
	if grounded and not _was_grounded:
		var impact := clampf(absf(_fall_speed) / 14.0, 0.0, 1.0)
		if _rig and impact > 0.05:
			_rig.land(impact)
	if grounded:
		_fall_speed = 0.0
		_safe_ground_time += delta
		if _safe_ground_time >= SAFE_GROUND_SETTLE_TIME:
			_last_safe_position = global_position
			_has_safe_position = true
	else:
		_safe_ground_time = 0.0
	_was_grounded = grounded


## 临时的世界下方保险。最终边界会由山体、悬崖和遗迹自然封闭；在那之前，
## 这里只负责让探索测试不中断，不生成任何看不见的墙，也不限制空中运动。
func _recover_if_below_world() -> bool:
	var expected_ground := TerrainFieldUtil.height_at(global_position.x, global_position.z)
	if global_position.y >= expected_ground - _fall_rescue_depth:
		return false
	var rescue := _last_safe_position if _has_safe_position else Vector3(
		0.0, TerrainFieldUtil.height_at(0.0, 0.0), 0.0
	)
	global_position = rescue + Vector3.UP * FALL_RESCUE_LIFT
	velocity = Vector3.ZERO
	_fall_speed = 0.0
	_was_grounded = false
	_safe_ground_time = 0.0
	apply_floor_snap()
	if _hud:
		_hud.show_notice("已返回最近的安全位置", "shield")
	return true


# ---------------------------------------------------------------- 对外接口

## source_position 是伤害来源的世界坐标，仅用于受击方向指示。
## 传 Vector3.ZERO 表示"来源无方位信息"，指示器会跳过（敌人都会传自己的位置）。
##
## shield_damage_scale 是【打在护盾上】那一部分的伤害倍率，默认 1.0。
## 生命那一部分恒定按原始伤害结算，不受它影响 —— 见下方换算注释。
func take_damage(
	amount: float, source_position: Vector3 = Vector3.ZERO, shield_damage_scale: float = 1.0
) -> void:
	# 实验关可在玩家实例上加这个元数据；正式关卡没有它，受伤规则完全不变。
	if bool(get_meta(&"experiment_invincible", false)):
		# 测试无敌只免扣血；翻滚免伤仍算成功躲避，不播放命中闪白。
		if amount > 0.0 and health > 0.0 and _damage_invulnerability <= 0.0 and _rig:
			_rig.flash_hit()
		return
	if _damage_invulnerability > 0.0 or health <= 0.0:
		return
	amount = maxf(amount, 0.0)
	# 护盾与生命从这次改动起走两套独立的计算：
	#   护盾：伤害 × shield_damage_scale（小型快速近战是 0.7，其余恒为 1.0）
	#   生命：始终按原始伤害结算，不打折
	#
	# 换算：护盾剩余量 ÷ 倍率 = 它还能挡住多少【原始伤害】。
	#   倍率 0.7、护盾 70 时等效于能挡 100 点原始伤害 —— 小怪要打出同样的
	#   血量损失得多砍 43%，护盾对它们明显更"耐打"。
	#   但护盾一旦被打穿，溢出的仍是未经削减的原始伤害：被小怪贴脸依然危险，
	#   只是不再让护盾退化成"一段会自动回复的血条"。
	#
	# 倍率为 1.0 时下面两式退化成 min(shield, amount) 与 amount - absorbed，
	# 与改动前逐位相同 —— 所有没传倍率的调用方（远程兵、Boss、弹幕、炮击）
	# 行为完全不变，便于单独隔离测试这一组改动。
	var scale := clampf(shield_damage_scale, 0.01, 10.0)
	var absorbed_raw := minf(shield / scale, amount)
	shield = maxf(shield - absorbed_raw * scale, 0.0)
	# 先扣护盾，溢出部分才进生命。护盾吸完就"碎"，不会挡住溢出伤害 ——
	# 否则高护盾等于一段无敌时间，生存压力会消失。
	health = maxf(health - (amount - absorbed_raw), 0.0)
	# 任何一次受击都重置两个计时器：这就是"停火才回血"的全部机制。
	_shield_regen_timer = _shield_regen_delay
	_health_regen_timer = _health_regen_delay
	_damage_invulnerability = hit_invulnerability
	AudioUtil.play("hurt")
	if _rig:
		if amount > 0.0:
			_rig.flash_hit()
		_rig.flinch()
	if _hud:
		_hud.set_health(health, max_health)
		_hud.set_shield(shield, max_shield)
		_hud.flash_damage()
		_hud.show_damage_direction(global_position, source_position)
	if health <= 0.0:
		_die()


func _die() -> void:
	if _dying:
		return
	best_survival_time = maxf(best_survival_time, survival_time)
	_dying = true
	_death_time = 0.0
	_death_event_sent = false
	GameFlowUtil.begin_death_transition()
	_rolling = false
	_sprinting = false
	_aiming = false
	_free_look = false
	if _rig:
		_rig.begin_death()
	if _hud:
		_hud.set_death_progress(0.0)


## 死亡过渡期间世界仍在运行，但玩家不再接受输入、攻击或累计生存时间。
## CharacterBody 仍处理重力，避免玩家在半空死亡时尸体悬停。
func _update_death(delta: float) -> void:
	_death_time = minf(_death_time + delta, _death_duration)
	var progress := clampf(_death_time / maxf(_death_duration, 0.01), 0.0, 1.0)
	velocity.x = move_toward(velocity.x, 0.0, deceleration * delta)
	velocity.z = move_toward(velocity.z, 0.0, deceleration * delta)
	if not is_on_floor():
		velocity.y -= gravity * delta
	else:
		velocity.y = 0.0
	move_and_slide()

	if _rig:
		_rig.death_progress = progress
		_rig.update(delta, 0.0, velocity.y, is_on_floor(), speed, speed * sprint_multiplier)
	if _hud:
		_hud.set_death_progress(progress)

	# 镜头不跟着模型一起横倒，否则会造成强烈晕动；只做轻微低头、侧倾与拉近。
	var camera_weight := minf(delta * 3.2, 1.0)
	if camera_pivot:
		camera_pivot.rotation.x = lerp_angle(
			camera_pivot.rotation.x, deg_to_rad(-12.0), camera_weight
		)
		camera_pivot.rotation.z = lerp_angle(
			camera_pivot.rotation.z, deg_to_rad(7.0), camera_weight
		)
	if spring_arm:
		spring_arm.spring_length = lerpf(
			spring_arm.spring_length, hip_spring_length * 0.82, camera_weight
		)

	if progress >= 1.0:
		_finish_death()


func _finish_death() -> void:
	if _death_event_sent:
		return
	_death_event_sent = true
	set_physics_process(false)
	# 结算链路仍走事件总线，但现在是在倒地动画完成后才弹面板。
	EventBusUtil.emit_player_died(survival_time, kill_count)


func try_heal(amount: float) -> bool:
	if health >= max_health:
		return false
	var before := health
	health = minf(health + amount, max_health)
	AudioUtil.play("pickup", -2.0, 1.0)
	if _hud:
		_hud.set_health(health, max_health)
		_hud.show_notice("恢复生命 +%d" % roundi(health - before), "health")
	return true


func register_enemy_kill() -> void:
	kill_count += 1
	if _hud:
		_hud.set_kills(kill_count)


func upgrade_weapon() -> bool:
	if not _weapon:
		return false
	var upgraded: bool = _weapon.upgrade()
	if upgraded:
		# 比拾血更高的音高，让"升级"听起来就是比"补血"更值得高兴的事。
		AudioUtil.play("pickup", -1.0, 1.35)
	if upgraded and _hud:
		_hud.set_weapon_level(
			_weapon.get_level(), _weapon.get_pellet_count(), _weapon.get_bullet_damage()
		)
		_hud.show_notice("武器升级　LV %d" % _weapon.get_level(), "upgrade")
	return upgraded


## 拾取一个武器升级模块（"fire_rate" / "damage" / "magazine"）。
## 返回 false 表示该模块已满级 —— 掉落物据此【不被消耗】，玩家不会白踩。
func apply_weapon_module(kind: String) -> bool:
	if not _weapon:
		return false
	var applied: bool = _weapon.apply_upgrade(kind)
	if applied:
		# 比拾血更高的音高，让"升级"听起来就是比"补血"更值得高兴的事。
		AudioUtil.play("pickup", -1.0, 1.35)
		if _hud:
			_hud.set_weapon_level(
				_weapon.get_level(), _weapon.get_pellet_count(), _weapon.get_bullet_damage()
			)
			var names := {"fire_rate": "射速模块", "damage": "威力模块", "magazine": "弹匣模块"}
			_hud.show_notice("获得：%s" % String(names.get(kind, "升级模块")), "upgrade")
	return applied


## 子弹包：直接压进弹匣，不是补备弹池（见 PlayerWeapon.add_ammo）。
## 返回 false 表示一点都没补进去（弹匣已到上限），掉落物不该被消耗。
func try_take_ammo(primary: int, sniper: int) -> bool:
	if not _weapon:
		return false
	var added := _weapon.add_ammo(primary, sniper)
	if added <= 0:
		return false
	AudioUtil.play("pickup", -3.0, 0.9)
	if _hud:
		_hud.show_notice("补充弹药 +%d" % added, "ammo")
	return true


func get_weapon_level() -> int:
	return _weapon.get_level() if _weapon else 1


func get_survival_time() -> float:
	return survival_time


func get_shield() -> float:
	return shield


func get_max_shield() -> float:
	return max_shield
