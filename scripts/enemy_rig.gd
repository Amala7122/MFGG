class_name EnemyRig
extends Node
## 敌人共享的程序化动画。
##
## 原本敌人完全没有动作（只有整体平移 + 一点上下浮动），腿和手臂是冻结的，
## 所以看起来像"滑行"。这里补上：步态摆腿、躯干起伏与前倾、手臂摆动、
## 受击抖动、近战蓄力挥砍，以及可选的右臂抓枪 IK。
##
## 两个敌人场景刻意用了同一套骨骼命名，因此同一份 rig 可直接复用：
##   Hips / Chest / Chest/Head
##   Hips/{Left,Right}Hip → Knee → Foot
##   Chest/{Left,Right}Shoulder → Elbow
##
## 注意敌人模型的正面是 -Z（脚本用不带 use_model_front 的 look_at），
## 所以手臂绕局部 X 轴正转是"向前挥"。

const ATTACK_RAISE_ANGLE := 3.9
const ATTACK_STRIKE_ANGLE := 1.15

@export_category("步态")
@export var walk_cadence := 6.2
@export var run_cadence := 8.8
@export_range(0.0, 1.4) var walk_swing := 0.42
@export_range(0.0, 1.4) var run_swing := 0.68
@export_range(0.0, 1.0) var knee_base_bend := 0.16
@export_range(0.0, 1.6) var knee_swing_bend := 0.6

@export_category("躯干")
@export_range(-25.0, 0.0) var move_lean_degrees := -7.0
@export var bob_height := 0.045
@export var pose_smoothing := 12.0

@export_category("手臂")
@export_range(0.0, 1.2) var arm_swing := 0.4
@export var forearm_length := 0.34
@export var arm_ik_smoothing := 16.0

## 右臂 IK 目标（远程敌人用来抓住枪身）。weight 为 0 时退回普通摆臂。
var right_hand_ik_target := Vector3.ZERO
var right_hand_ik_weight := 0.0

var upper_arm_length := 0.32

var _model: Node3D
var _hips: Node3D
var _chest: Node3D
var _head: Node3D
var _hip_joints: Array[Node3D] = []
var _knees: Array[Node3D] = []
var _feet: Array[Node3D] = []
var _shoulders: Array[Node3D] = []
var _elbows: Array[Node3D] = []

var _rest_position := Vector3.ZERO
var _phase := 0.0
var _motion_weight := 0.0
var _flinch := 0.0
var _attack_time := 0.0
var _attack_duration := 0.0


func setup(model: Node3D) -> void:
	_model = model
	if not _model:
		push_warning("EnemyRig: 未找到 EnemyModel，程序化动画已禁用")
		return
	_rest_position = _model.position
	_hips = _model.get_node_or_null("Hips")
	_chest = _model.get_node_or_null("Chest")
	_head = _model.get_node_or_null("Chest/Head")
	for side in ["Left", "Right"]:
		_hip_joints.append(_model.get_node_or_null("Hips/%sHip" % side))
		_knees.append(_model.get_node_or_null("Hips/%sHip/Knee" % side))
		_feet.append(_model.get_node_or_null("Hips/%sHip/Knee/Foot" % side))
		_shoulders.append(_model.get_node_or_null("Chest/%sShoulder" % side))
		_elbows.append(_model.get_node_or_null("Chest/%sShoulder/Elbow" % side))
	# 上臂长度直接从骨骼实际位置量出来，两个敌人臂长不同也能自适应。
	if _elbows[0]:
		var measured := _elbows[0].position.length()
		if measured > 0.01:
			upper_arm_length = measured


## 受击时调用。
func flinch() -> void:
	_flinch = 1.0


## 播放一次近战挥砍。
func play_attack(duration: float = 0.55) -> void:
	_attack_duration = maxf(duration, 0.05)
	_attack_time = _attack_duration


func is_attacking() -> bool:
	return _attack_duration > 0.0


func update(delta: float, horizontal_speed: float, max_speed: float, grounded: bool) -> void:
	if not _model or not _chest:
		return
	var moving := horizontal_speed > 0.15
	_motion_weight = move_toward(_motion_weight, 1.0 if moving else 0.0, delta * 6.0)
	_flinch = maxf(_flinch - delta * 2.6, 0.0)
	var attack_progress := 0.0
	if _attack_duration > 0.0:
		_attack_time = maxf(_attack_time - delta, 0.0)
		attack_progress = clampf(1.0 - _attack_time / _attack_duration, 0.0, 1.0)
		if _attack_time <= 0.0:
			_attack_duration = 0.0
	var settle := minf(delta * pose_smoothing, 1.0)

	# ---- 步态 ----
	var speed_ratio := clampf(horizontal_speed / maxf(max_speed, 0.01), 0.0, 1.6)
	var run_blend := clampf((speed_ratio - 1.0) / 0.6, 0.0, 1.0)
	var cadence := lerpf(walk_cadence, run_cadence, run_blend)
	var swing_amount := lerpf(walk_swing, run_swing, run_blend)
	if moving and grounded:
		_phase = fmod(_phase + delta * cadence, TAU)
	else:
		_phase = lerp_angle(_phase, 0.0, minf(delta * 7.0, 1.0))
	var swing := sin(_phase) * swing_amount * _motion_weight
	var bob := absf(sin(_phase)) * bob_height * _motion_weight

	for index in range(2):
		_pose_leg(index, swing if index == 0 else -swing, settle)

	# ---- 躯干 ----
	var chest_pitch := deg_to_rad(move_lean_degrees) * run_blend * _motion_weight
	var chest_yaw := 0.0
	if _attack_duration > 0.0:
		chest_yaw = _attack_twist(attack_progress)
	_apply(_chest, Vector3(chest_pitch, chest_yaw, sin(_phase) * 0.03 * _motion_weight), settle)
	_apply(_head, Vector3(0.0, -chest_yaw * 0.6, 0.0), settle)
	if _hips:
		_apply(_hips, Vector3(0.0, sin(_phase) * 0.06 * _motion_weight, 0.0), settle)
	_model.position.y = lerp(_model.position.y, _rest_position.y + bob, settle)

	# 受击反馈必须"叠加"而不是当作平滑插值的目标：只有零点几秒的冲击
	# 经 pose_smoothing 抹平后只剩几度，等于看不见。这里在姿态解算之后
	# 直接叠加偏移，并用平方衰减让它前重后轻、够脆。
	if _flinch > 0.0:
		var impact := _flinch * _flinch
		_chest.rotation.x += 0.44 * impact
		_chest.rotation.z += sin(_flinch * 30.0) * 0.11 * impact
		if _head:
			_head.rotation.x += 0.32 * impact
		# 整身被向后推一点（敌人正面是 -Z，所以后退方向是 +Z）
		_model.position.z = _rest_position.z + 0.1 * impact
	elif not is_zero_approx(_model.position.z - _rest_position.z):
		_model.position.z = lerp(_model.position.z, _rest_position.z, settle)

	_pose_arms(swing, attack_progress, delta)


func _pose_leg(index: int, hip_angle: float, settle: float) -> void:
	var hip := _hip_joints[index]
	var knee := _knees[index]
	var foot := _feet[index]
	if not hip or not knee or not foot:
		return
	_apply(hip, Vector3(hip_angle, 0.0, 0.0), settle)
	var bend := knee_base_bend + knee_swing_bend * maxf(hip_angle, 0.0)
	_apply(knee, Vector3(bend, 0.0, 0.0), settle)
	_apply(foot, Vector3(-(hip_angle + bend) * 0.7, 0.0, 0.0), settle)


func _pose_arms(swing: float, attack_progress: float, delta: float) -> void:
	var settle := minf(delta * pose_smoothing, 1.0)
	# 左臂：与腿反向摆动，略微前伸。
	var left_arm := -swing * arm_swing * 1.5 + 0.2
	_apply(_shoulders[0], Vector3(left_arm, 0.0, 0.0), settle)
	_apply(_elbows[0], Vector3(0.24, 0.0, 0.0), settle)

	# 右臂：挥砍 > 抓枪 IK > 普通摆臂，优先级从高到低。
	var right_shoulder := _shoulders[1]
	var right_elbow := _elbows[1]
	if not right_shoulder:
		return
	if _attack_duration > 0.0:
		var angle := _attack_arm_angle(attack_progress)
		_apply(right_shoulder, Vector3(angle, 0.0, 0.0), minf(delta * 24.0, 1.0))
		_apply(right_elbow, Vector3(maxf(0.3 - angle * 0.18, 0.08), 0.0, 0.0), minf(delta * 20.0, 1.0))
		return
	if right_hand_ik_weight > 0.0 and right_elbow:
		_solve_arm(right_shoulder, right_elbow, right_hand_ik_target, delta)
		return
	_apply(right_shoulder, Vector3(swing * arm_swing * 1.5 + 0.2, 0.0, 0.0), settle)
	_apply(right_elbow, Vector3(0.24, 0.0, 0.0), settle)


## 挥砍的手臂角度：先抬起蓄力，再快速劈下，最后收回。
func _attack_arm_angle(progress: float) -> float:
	if progress < 0.32:
		return lerpf(0.0, ATTACK_RAISE_ANGLE, ease(progress / 0.32, 0.5))
	if progress < 0.62:
		return lerpf(ATTACK_RAISE_ANGLE, ATTACK_STRIKE_ANGLE, ease((progress - 0.32) / 0.3, 2.6))
	if progress < 0.85:
		return lerpf(ATTACK_STRIKE_ANGLE, 0.0, (progress - 0.62) / 0.23)
	return 0.0


## 挥砍时躯干的反向拧腰，给动作带重量。
func _attack_twist(progress: float) -> float:
	if progress < 0.32:
		return lerpf(0.0, 0.42, progress / 0.32)
	if progress < 0.62:
		return lerpf(0.42, -0.5, (progress - 0.32) / 0.3)
	if progress < 0.85:
		return lerpf(-0.5, 0.0, (progress - 0.62) / 0.23)
	return 0.0


## 解析式双骨 IK：让右臂伸到 target（抓枪用）。
##
## 注意骨骼长度必须按模型的世界缩放换算：敌人会被 configure_stats() 缩放
## 0.65~1.75 倍，而 IK 是在世界空间里求解的，不换算的话小/大号敌人的手臂
## 会分别伸不直或过度弯曲。
func _solve_arm(shoulder: Node3D, elbow: Node3D, target: Vector3, delta: float) -> void:
	var origin := shoulder.global_position
	var to_target := target - origin
	var raw_length := to_target.length()
	if raw_length < 0.0001:
		return
	var scale_factor := 1.0
	if _model:
		scale_factor = maxf(_model.global_basis.get_scale().y, 0.01)
	var upper := upper_arm_length * scale_factor
	var lower := forearm_length * scale_factor

	var direction := to_target / raw_length
	var reach := (upper + lower) * 0.995
	var distance := clampf(raw_length, absf(upper - lower) + 0.02, reach)
	# 模型可能被整体缩放，取轴向时必须归一化。
	var model_x := _model.global_basis.x.normalized()
	var down := -_model.global_basis.y.normalized()
	# 敌人在自身 +X 侧持械，肘部朝外下。
	var pole_offset := down * 0.6 + model_x * 0.5
	var pole_dir := pole_offset - direction * pole_offset.dot(direction)
	if pole_dir.length_squared() < 0.0001:
		pole_dir = model_x
	pole_dir = pole_dir.normalized()

	var cos_angle := clampf(
		(upper * upper + distance * distance - lower * lower) / (2.0 * upper * distance),
		-1.0, 1.0
	)
	var bend := acos(cos_angle)
	var upper_dir := (direction * cos(bend) + pole_dir * sin(bend)).normalized()
	var elbow_position := origin + upper_dir * upper
	var forearm_dir := (target - elbow_position).normalized()

	var weight := minf(delta * arm_ik_smoothing, 1.0)
	_set_bone_direction(shoulder, upper_dir, pole_dir, weight)
	_set_bone_direction(elbow, forearm_dir, pole_dir, weight)


## 让 node 的局部 -Y 指向 world_direction（骨指向即局部 -Y）。
func _set_bone_direction(node: Node3D, world_direction: Vector3, reference: Vector3, weight: float) -> void:
	var y_axis := -world_direction
	var ref := reference
	if absf(ref.dot(y_axis)) > 0.95:
		ref = Vector3.UP if absf(Vector3.UP.dot(y_axis)) < 0.95 else Vector3.RIGHT
	var x_axis := ref.cross(y_axis)
	if x_axis.length_squared() < 0.0001:
		x_axis = Vector3.RIGHT
	x_axis = x_axis.normalized()
	var goal := Basis(x_axis, y_axis, x_axis.cross(y_axis))
	# 敌人根节点带缩放，global_basis 因此不是正交归一基，直接 slerp 会报错；
	# 先把当前朝向归一化再插值，最后把原有缩放乘回去，否则骨骼会被拉回 1 倍。
	var current_basis := node.global_basis
	var current_scale := current_basis.get_scale()
	var blended := goal if weight >= 1.0 else current_basis.orthonormalized().slerp(goal, weight)
	node.global_transform = Transform3D(
		Basis(blended).scaled(current_scale), node.global_position
	)


func _apply(node: Node3D, target: Vector3, weight: float) -> void:
	if not node:
		return
	node.rotation = Vector3(
		lerp_angle(node.rotation.x, target.x, weight),
		lerp_angle(node.rotation.y, target.y, weight),
		lerp_angle(node.rotation.z, target.z, weight)
	)
