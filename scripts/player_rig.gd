class_name PlayerRig
extends Node

## juice：每一步落地时发一次（is_sprint 用来区分走/跑音量）。
signal step_taken(is_sprint: bool)
## 玩家角色的程序化姿势与动画（v2：双骨骨架 + 手部 IK）。
##
## 节点命名说明（重要）：
## 玩家模型整体绕 Y 轴旋转了 PI，因此模型局部 -X 对应相机的右侧。
## 模型上位于 -X 的那一侧出现在画面右侧（与相机同侧），就是标准的
## 第三人称越肩持枪位，所以这里统一语义化为：
##   `gun_*`     = 持枪主手/主腿侧（player.tscn 里的 Left*）
##   `support_*` = 护木支撑手侧（player.tscn 里的 Right*）
##
## 手臂不再是"一根棍子"：肩 → 肘 → 手 三段，用解析式双骨 IK 实时求解，
## IK 目标直接取自武器（握把 / 护木的世界坐标），所以端枪、开镜、换弹、
## 后坐力下双手都会真正贴在枪上。

const ConfigUtil := preload("res://scripts/game_config.gd")

const UPPER_ARM_LENGTH := 0.32
const FOREARM_LENGTH := 0.30
const HIT_FLASH_DURATION := 0.16
const HIT_FLASH_FADE := 0.12

@export_category("步态")
@export var walk_cadence := 7.4
@export var run_cadence := 12.0
@export_range(0.0, 1.4) var walk_swing := 0.5
@export_range(0.0, 1.4) var run_swing := 0.8

@export_category("腿部")
@export_range(0.0, 1.0) var knee_base_bend := 0.14
@export_range(0.0, 1.6) var knee_swing_bend := 0.72

@export_category("躯干")
@export_range(-25.0, 0.0) var sprint_lean_degrees := -9.0
@export_range(0.0, 18.0) var ads_lean_degrees := 4.0
## 上半身跟随相机俯仰的比例与上限（弧度）。相机低头/抬头时躯干必须一起动，
## 否则俯仰只作用在枪上，看起来就像枪脱开身体自己在动。
@export_range(0.0, 1.0) var torso_pitch_follow := 0.62
@export_range(0.0, 0.8) var torso_pitch_limit := 0.5

@export_category("混合速度")
@export var pose_smoothing := 15.0
@export var aim_blend_speed := 9.0
@export var sprint_blend_speed := 6.5
@export var arm_ik_smoothing := 18.0

## 由 player.gd 每帧写入的运动状态。
var sprinting := false
var aiming := false
var rolling := false
var reloading := false
var dying := false
## 0..1，由 Player 的死亡过渡计时推进。
var death_progress := 0.0
## 翻滚进度 0..1，驱动模型的前滚翻转。
var roll_progress := 0.0
## 相机俯仰（弧度，正为抬头），由 player.gd 每帧写入。
var view_pitch := 0.0

var _model: Node3D
var _hips: Node3D
var _chest: Node3D
var _head: Node3D
var _gun_shoulder: Node3D
var _gun_elbow: Node3D
var _support_shoulder: Node3D
var _support_elbow: Node3D
var _gun_hip: Node3D
var _gun_knee: Node3D
var _gun_ankle: Node3D
var _support_hip: Node3D
var _support_knee: Node3D
var _support_ankle: Node3D
var _weapon: PlayerWeapon

var _rest_position := Vector3.ZERO
var _gait_phase := 0.0
var _locomotion_weight := 0.0
var _aim_weight := 0.0
var _sprint_weight := 0.0
var _reload_weight := 0.0
var _roll_blend := 0.0
var _flinch := 0.0
var _land := 0.0
## 空/地状态下的额外屈膝量（由 update 设置）。
var _leg_knee_extra := 0.0
var _hit_flash_remaining := 0.0
var _hit_flash_material: StandardMaterial3D
var _hit_flash_meshes: Array[MeshInstance3D] = []
var _hit_flash_overlays: Array[Material] = []


func setup(model: Node3D) -> void:
	_model = model
	if not _model:
		push_warning("PlayerRig: 未找到 PlayerModel，程序化动画已禁用")
		return
	_rest_position = _model.position
	# 独立叠加材质，不改共享的皮肤/衣物材质；武器保持原色。
	var weapon_rig := _model.get_node_or_null("WeaponRig")
	for node in _model.find_children("*", "MeshInstance3D", true, false):
		if weapon_rig == null or not weapon_rig.is_ancestor_of(node):
			_hit_flash_meshes.append(node as MeshInstance3D)
	_hit_flash_material = StandardMaterial3D.new()
	_hit_flash_material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	_hit_flash_material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	_hit_flash_material.albedo_color = Color.WHITE
	_hips = _model.get_node_or_null("Hips")
	_chest = _model.get_node_or_null("Chest")
	_head = _model.get_node_or_null("Chest/Head")
	_gun_shoulder = _model.get_node_or_null("Chest/LeftShoulder")
	_gun_elbow = _model.get_node_or_null("Chest/LeftShoulder/Elbow")
	_support_shoulder = _model.get_node_or_null("Chest/RightShoulder")
	_support_elbow = _model.get_node_or_null("Chest/RightShoulder/Elbow")
	_gun_hip = _model.get_node_or_null("Hips/LeftHip")
	_gun_knee = _model.get_node_or_null("Hips/LeftHip/Knee")
	_gun_ankle = _model.get_node_or_null("Hips/LeftHip/Knee/Ankle")
	_support_hip = _model.get_node_or_null("Hips/RightHip")
	_support_knee = _model.get_node_or_null("Hips/RightHip/Knee")
	_support_ankle = _model.get_node_or_null("Hips/RightHip/Knee/Ankle")
	walk_cadence = maxf(ConfigUtil.get_float("player.animation.walk_cadence", 7.4), 0.1)
	run_cadence = maxf(
		ConfigUtil.get_float("player.animation.run_cadence", 12.0), walk_cadence
	)


## 注入武器，用于取握把 / 护木的世界坐标作为 IK 目标。
func set_weapon(weapon: PlayerWeapon) -> void:
	_weapon = weapon


## 受击时调用：触发一次头部/躯干弹跳。
func flinch() -> void:
	_flinch = 1.0


## 命中确认：短暂闪白后淡出，连续命中只刷新当前效果。
func flash_hit() -> void:
	if _hit_flash_material == null:
		return
	if _hit_flash_remaining <= 0.0:
		_hit_flash_overlays.clear()
		for mesh in _hit_flash_meshes:
			_hit_flash_overlays.append(mesh.material_overlay)
			mesh.material_overlay = _hit_flash_material
	_hit_flash_remaining = HIT_FLASH_DURATION
	_hit_flash_material.albedo_color = Color.WHITE


func _update_hit_flash(delta: float) -> void:
	if _hit_flash_remaining <= 0.0:
		return
	_hit_flash_remaining = maxf(_hit_flash_remaining - delta, 0.0)
	_hit_flash_material.albedo_color.a = minf(_hit_flash_remaining / HIT_FLASH_FADE, 1.0)
	if _hit_flash_remaining <= 0.0:
		for i in range(_hit_flash_meshes.size()):
			var mesh := _hit_flash_meshes[i]
			if is_instance_valid(mesh) and mesh.material_overlay == _hit_flash_material:
				mesh.material_overlay = _hit_flash_overlays[i]
		_hit_flash_overlays.clear()


## 落地时调用：impact 为 0..1 的落地强度。
func land(impact: float) -> void:
	_land = clampf(impact, 0.0, 1.0)


func begin_death() -> void:
	dying = true
	death_progress = 0.0
	rolling = false
	roll_progress = 0.0
	_flinch = 1.0


func update(
	delta: float,
	horizontal_speed: float,
	vertical_speed: float,
	grounded: bool,
	walk_speed: float,
	max_speed: float
) -> void:
	_update_hit_flash(delta)
	if not _model or not _chest:
		return
	if dying:
		_update_death_pose(delta)
		return

	_aim_weight = move_toward(_aim_weight, 1.0 if aiming else 0.0, delta * aim_blend_speed)
	_sprint_weight = move_toward(_sprint_weight, 1.0 if sprinting else 0.0, delta * sprint_blend_speed)
	_reload_weight = move_toward(_reload_weight, 1.0 if reloading else 0.0, delta * 6.0)
	_roll_blend = move_toward(_roll_blend, 1.0 if rolling else 0.0, delta * 7.0)
	_flinch = maxf(_flinch - delta * 3.4, 0.0)
	_land = maxf(_land - delta * 2.8, 0.0)

	var moving := horizontal_speed > 0.18
	_locomotion_weight = move_toward(_locomotion_weight, 1.0 if moving else 0.0, delta * 7.0)
	var settle := minf(delta * pose_smoothing, 1.0)

	# ---- 步态 ----
	var run_blend := _run_blend_for_speed(horizontal_speed, walk_speed, max_speed)
	var cadence := _cadence_for_speed(horizontal_speed, walk_speed, max_speed)
	var swing_amount := lerpf(walk_swing, run_swing, run_blend)
	if moving and grounded:
		var prev_phase := _gait_phase
		_gait_phase = fmod(_gait_phase + delta * cadence, TAU)
		# juice：相位跨过半圈（或回绕）即视为落下一步
		if (prev_phase < PI and _gait_phase >= PI) or (prev_phase > _gait_phase):
			step_taken.emit(sprinting)
	else:
		_gait_phase = lerp_angle(_gait_phase, 0.0, minf(delta * 8.0, 1.0))
	var swing := sin(_gait_phase) * swing_amount * _locomotion_weight
	var bob := absf(sin(_gait_phase)) * lerpf(0.024, 0.052, run_blend) * _locomotion_weight

	# ---- 腿部（正向运动学 + 只能向后弯的膝）----
	var gun_hip_angle := -swing
	var support_hip_angle := swing
	if not grounded:
		var rising := vertical_speed > 0.0
		gun_hip_angle = -0.32 if rising else 0.16
		support_hip_angle = 0.42 if rising else -0.14
		_leg_knee_extra = 0.5
	else:
		_leg_knee_extra = 0.0
	if _roll_blend > 0.0:
		gun_hip_angle = lerpf(gun_hip_angle, -1.15, _roll_blend)
		support_hip_angle = lerpf(support_hip_angle, -1.15, _roll_blend)
		_leg_knee_extra = lerpf(_leg_knee_extra, 1.0, _roll_blend)
	_pose_leg(_gun_hip, _gun_knee, _gun_ankle, gun_hip_angle, settle)
	_pose_leg(_support_hip, _support_knee, _support_ankle, support_hip_angle, settle)

	# ---- 躯干 / 头 / 胯 ----
	var body_pitch := deg_to_rad(sprint_lean_degrees) * _sprint_weight
	body_pitch += deg_to_rad(ads_lean_degrees) * _aim_weight
	# 上半身跟着相机俯仰靠仰（抬头后仰 / 低身前倾）。
	body_pitch += clampf(-view_pitch * torso_pitch_follow, -torso_pitch_limit, torso_pitch_limit)
	var body_roll := sin(_gait_phase) * 0.026 * _locomotion_weight
	var head_yaw := -body_roll * 0.8
	if _flinch > 0.0:
		body_pitch -= 0.14 * _flinch
		head_yaw += sin(Time.get_ticks_msec() * 0.05) * 0.12 * _flinch
	_apply_rotation(_chest, Vector3(body_pitch, body_roll, 0.0), settle)
	_apply_rotation(_head, Vector3(0.0, head_yaw, 0.0), settle)
	if _hips:
		_apply_rotation(_hips, Vector3(0.0, sin(_gait_phase) * 0.05 * _locomotion_weight, 0.0), settle)

	var model_height := _rest_position.y + bob
	if not moving and grounded:
		model_height = _rest_position.y + sin(Time.get_ticks_msec() * 0.0025) * 0.006
	if _roll_blend > 0.0:
		model_height -= 0.42 * _roll_blend
	if _land > 0.0:
		model_height -= 0.12 * _land
	_model.position.y = lerp(_model.position.y, model_height, settle)
	# 翻滚前滚翻转：必须用普通赋值，lerp_angle 会因 0 与 TAU 同角而完全不转。
	_model.rotation.x = TAU * roll_progress

	# ---- 手臂 IK（必须在躯干姿态确定之后求解）----
	_solve_arms(delta)


## 步频直接跟实际水平速度走：加速阶段也会逐渐加快，而不是只在按下冲刺键时跳档。
func _cadence_for_speed(horizontal_speed: float, walk_speed: float, max_speed: float) -> float:
	var safe_walk := maxf(walk_speed, 0.01)
	var walk_ratio := clampf(horizontal_speed / safe_walk, 0.0, 1.0)
	var walking_cadence := lerpf(walk_cadence * 0.68, walk_cadence, walk_ratio)
	return lerpf(
		walking_cadence,
		run_cadence,
		_run_blend_for_speed(horizontal_speed, walk_speed, max_speed)
	)


func _run_blend_for_speed(horizontal_speed: float, walk_speed: float, max_speed: float) -> float:
	var span := maxf(max_speed - walk_speed, 0.01)
	return clampf((horizontal_speed - walk_speed) / span, 0.0, 1.0)


## 程序化倒地：先受击后仰，再侧身砸地，最后让四肢松开。
## 整体旋转发生在 PlayerModel 上，因此武器会跟身体一起倒下，不会漂在半空。
func _update_death_pose(delta: float) -> void:
	var progress := clampf(death_progress, 0.0, 1.0)
	var fall := smoothstep(0.05, 0.82, progress)
	var settle := minf(delta * pose_smoothing, 1.0)
	_locomotion_weight = move_toward(_locomotion_weight, 0.0, delta * 8.0)

	_model.rotation.x = lerp_angle(_model.rotation.x, deg_to_rad(-7.0), settle)
	_model.rotation.z = lerp_angle(_model.rotation.z, deg_to_rad(82.0) * fall, settle)
	_model.position.y = lerpf(_model.position.y, _rest_position.y - 0.28 * fall, settle)

	_apply_rotation(_chest, Vector3(-0.28, 0.0, -0.12), settle)
	_apply_rotation(_head, Vector3(0.18, 0.0, 0.22), settle)
	if _hips:
		_apply_rotation(_hips, Vector3(0.12, -0.08, 0.0), settle)
	_pose_leg(_gun_hip, _gun_knee, _gun_ankle, -0.38, settle)
	_pose_leg(_support_hip, _support_knee, _support_ankle, 0.58, settle)
	_apply_rotation(_gun_shoulder, Vector3(0.38, 0.0, -0.48), settle)
	_apply_rotation(_gun_elbow, Vector3(0.55, 0.0, 0.0), settle)
	_apply_rotation(_support_shoulder, Vector3(-0.2, 0.0, 0.62), settle)
	_apply_rotation(_support_elbow, Vector3(0.7, 0.0, 0.0), settle)


func _pose_leg(hip: Node3D, knee: Node3D, ankle: Node3D, hip_angle: float, settle: float) -> void:
	if not hip or not knee or not ankle:
		return
	_apply_rotation(hip, Vector3(hip_angle, 0.0, 0.0), settle)
	var bend := knee_base_bend + knee_swing_bend * maxf(hip_angle, 0.0) + _leg_knee_extra
	_apply_rotation(knee, Vector3(bend, 0.0, 0.0), settle)
	# 脚掌尽量贴地：反向抵消大腿+小腿的旋转。
	_apply_rotation(ankle, Vector3(-(hip_angle + bend) * 0.75, 0.0, 0.0), settle)


func _solve_arms(delta: float) -> void:
	if not _weapon:
		return
	var model_x := _model.global_basis.x
	var model_down := -_model.global_basis.y
	var model_forward := _model.global_basis.z
	var weight := minf(delta * arm_ik_smoothing, 1.0)

	var grip_target := _weapon.get_grip_world()
	var foregrip_target := _weapon.get_foregrip_world()

	# 换弹时支撑手离开护木，回到腰侧，做出"卸弹匣"的动作。
	if _reload_weight > 0.0 and _support_hip:
		var rest := _support_hip.global_position + model_down * 0.26 - model_forward * 0.12
		foregrip_target = foregrip_target.lerp(rest, _reload_weight)
	# 翻滚时双手收进胸前。
	if _roll_blend > 0.0 and _chest:
		var tuck := _chest.global_position + model_down * 0.2 + model_forward * 0.06
		grip_target = grip_target.lerp(tuck, _roll_blend)
		foregrip_target = foregrip_target.lerp(tuck, _roll_blend)

	_solve_arm(_gun_shoulder, _gun_elbow, grip_target, -model_x, model_down, weight)
	_solve_arm(_support_shoulder, _support_elbow, foregrip_target, model_x, model_down, weight)


## 解析式双骨 IK：把 shoulder→elbow 与 elbow→hand 两段摆到能抓到 target 的位置。
## 骨的局部 -Y 就是骨指向，肘部弯曲平面由 outward / down 决定。
func _solve_arm(
	shoulder: Node3D,
	elbow: Node3D,
	target: Vector3,
	outward: Vector3,
	down: Vector3,
	weight: float
) -> void:
	if not shoulder or not elbow:
		return
	var origin := shoulder.global_position
	var to_target := target - origin
	var raw_length := to_target.length()
	if raw_length < 0.0001:
		return
	var direction := to_target / raw_length
	var reach := (UPPER_ARM_LENGTH + FOREARM_LENGTH) * 0.995
	var distance := clampf(raw_length, absf(UPPER_ARM_LENGTH - FOREARM_LENGTH) + 0.02, reach)

	# 肘部朝向：向外下方，构成自然的弯曲平面。
	var pole_offset := down * 0.62 + outward * 0.5
	var pole_dir := pole_offset - direction * pole_offset.dot(direction)
	if pole_dir.length_squared() < 0.0001:
		pole_dir = outward
	pole_dir = pole_dir.normalized()

	var cos_angle := clampf(
		(UPPER_ARM_LENGTH * UPPER_ARM_LENGTH + distance * distance
			- FOREARM_LENGTH * FOREARM_LENGTH) / (2.0 * UPPER_ARM_LENGTH * distance),
		-1.0, 1.0
	)
	var bend_angle := acos(cos_angle)
	var upper_dir := (direction * cos(bend_angle) + pole_dir * sin(bend_angle)).normalized()
	var elbow_position := origin + upper_dir * UPPER_ARM_LENGTH
	var forearm_dir := (target - elbow_position).normalized()

	_set_bone_direction(shoulder, upper_dir, pole_dir, weight)
	_set_bone_direction(elbow, forearm_dir, pole_dir, weight)


## 让 node 的局部 -Y 指向 world_direction，reference 用来固定滚转。
func _set_bone_direction(node: Node3D, world_direction: Vector3, reference: Vector3, weight: float) -> void:
	var y_axis := -world_direction
	var ref := reference
	if absf(ref.dot(y_axis)) > 0.95:
		ref = Vector3.UP if absf(Vector3.UP.dot(y_axis)) < 0.95 else Vector3.RIGHT
	var x_axis := ref.cross(y_axis)
	if x_axis.length_squared() < 0.0001:
		x_axis = Vector3.RIGHT
	x_axis = x_axis.normalized()
	var z_axis := x_axis.cross(y_axis)
	var goal := Basis(x_axis, y_axis, z_axis)
	var blended := goal if weight >= 1.0 else node.global_basis.slerp(goal, weight)
	node.global_transform = Transform3D(blended.orthonormalized(), node.global_position)


func _apply_rotation(node: Node3D, target: Vector3, weight: float) -> void:
	if not node:
		return
	node.rotation = Vector3(
		lerp_angle(node.rotation.x, target.x, weight),
		lerp_angle(node.rotation.y, target.y, weight),
		lerp_angle(node.rotation.z, target.z, weight)
	)
