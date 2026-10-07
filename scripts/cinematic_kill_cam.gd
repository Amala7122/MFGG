class_name CinematicKillCam
extends Camera3D
## 波次终结/Boss击杀特写慢动作镜头。
##
## 当波次最后一个敌人（或关卡 Boss）被消灭时激活：
## 1. 以被击败的敌人为视觉中心；
## 2. 近距离缓慢环绕旋转（流畅的电影级轨道运镜）；
## 3. 伴随平滑微变焦，强化终结时刻的打击感与戏剧性；
## 4. 运镜结束或界面切换时，平滑将控制权无缝归还给玩家主相机。
const TerrainFieldUtil := preload("res://scripts/terrain_field.gd")
const AudioUtil := preload("res://scripts/audio_manager.gd")

static var active_cam: CinematicKillCam = null

var _target_node: Node3D = null
var _target_pos := Vector3.ZERO
var _target_height := 0.85
var _player_node: Node3D = null
var _player_camera: Camera3D = null

var _dir_pe := Vector3.FORWARD
var _right_pe := Vector3.RIGHT
var _end_orbit_dir := Vector3.FORWARD
var _end_distance := 3.2
var _end_height_offset := 0.85
var _start_fov := 56.0
var _end_fov := 46.0

var _duration := 2.6
var _elapsed_real_time := 0.0
var _last_msec := 0
var _finished := false


## 全局清理当前激活的特写镜头，无缝归还给玩家主相机。
static func dismiss_active() -> void:
	if active_cam != null and is_instance_valid(active_cam):
		active_cam.restore_and_destroy()


func start(target: Node3D = null, fallback_pos: Vector3 = Vector3.ZERO, is_boss: bool = false, duration_sec: float = 2.6) -> void:
	# 若之前已有特写镜头未销毁，先清理
	if active_cam != null and active_cam != self and is_instance_valid(active_cam):
		active_cam.restore_and_destroy()
	active_cam = self

	_target_node = target
	_target_pos = fallback_pos
	if is_instance_valid(_target_node):
		_target_pos = _target_node.global_position if _target_node.is_inside_tree() else _target_node.position

	_duration = maxf(duration_sec, 0.8)
	_elapsed_real_time = 0.0
	_last_msec = Time.get_ticks_msec()
	_finished = false

	# 压低战场常规枪声杂音
	AudioUtil.duck(_duration + 0.3, -8.0)

	# 查找主角与主相机
	var player: Node = null
	if is_inside_tree() and get_tree() != null:
		player = get_tree().get_first_node_in_group("player")
	if player:
		_player_node = player as Node3D
		_player_camera = player.get_node_or_null("CameraPivot/SpringArm3D/Camera3D") as Camera3D
		if _player_camera == null:
			_player_camera = player.get("camera") as Camera3D
	if _player_camera == null and is_inside_tree() and get_viewport() != null:
		var current_viewport_cam := get_viewport().get_camera_3d()
		if current_viewport_cam != null and current_viewport_cam != self:
			_player_camera = current_viewport_cam

	# 尺寸与构图参数配置
	if is_boss:
		_target_height = 1.45
		_end_distance = 4.4
		_end_height_offset = 1.45
		_start_fov = 56.0
	else:
		_target_height = 0.85
		_end_distance = 2.8
		_end_height_offset = 0.95
		_start_fov = 56.0

	# 计算主角 -> 敌人的地面水平指向向量与侧向向量
	var p_pos := _player_node.global_position if is_instance_valid(_player_node) and _player_node.is_inside_tree() else (_player_node.position if is_instance_valid(_player_node) else _target_pos + Vector3.BACK * 6.0)
	var to_enemy := _target_pos - p_pos
	var to_enemy_h := Vector3(to_enemy.x, 0.0, to_enemy.z)
	var dist_pe := to_enemy_h.length()
	if dist_pe > 0.04:
		_dir_pe = to_enemy_h.normalized()
	else:
		_dir_pe = -_player_node.global_transform.basis.z if is_instance_valid(_player_node) and _player_node.is_inside_tree() else Vector3.FORWARD
		_dir_pe.y = 0.0
		_dir_pe = _dir_pe.normalized()

	_right_pe = _dir_pe.cross(Vector3.UP).normalized()

	# 终点长焦自适应（远距离击杀长焦压缩，突出背景主角的英姿）
	_end_fov = clampf(50.0 - (dist_pe - 5.0) * 0.65, 24.0, 52.0)

	fov = _start_fov
	process_mode = Node.PROCESS_MODE_ALWAYS

	_update_cam_transform(0.0)
	make_current()


func _process(_delta: float) -> void:
	if _finished:
		return

	# 使用真实时间跨度，保证慢动作（time_scale 0.16）下运镜依然保持电影级平滑优雅
	var now := Time.get_ticks_msec()
	var real_delta := float(now - _last_msec) * 0.001
	_last_msec = now
	_elapsed_real_time += real_delta

	var t := clampf(_elapsed_real_time / maxf(_duration, 0.01), 0.0, 1.0)
	_update_cam_transform(t)

	if t >= 1.0:
		_finished = true


func _update_cam_transform(t: float) -> void:
	if is_instance_valid(_target_node):
		_target_pos = _target_node.global_position if _target_node.is_inside_tree() else _target_node.position

	var enemy_center := _target_pos + Vector3.UP * _target_height

	var p_pos := _player_node.global_position if is_instance_valid(_player_node) and _player_node.is_inside_tree() else (_player_node.position if is_instance_valid(_player_node) else _target_pos + Vector3.BACK * 6.0)
	var player_chest := p_pos + Vector3.UP * 1.15

	# 1. 轨迹规划：起点位于敌前侧翼，推进并切入“敌后”，形成从敌后眺望主角的英姿构图
	var front_dist := 3.6 if _target_height < 1.0 else 5.2
	var start_side := 1.8 if _target_height < 1.0 else 2.6
	var start_h := 1.35 if _target_height < 1.0 else 1.9

	# 起点：敌前侧方低位
	var start_cam_pos := _target_pos - _dir_pe * front_dist + _right_pe * start_side + Vector3.UP * start_h
	# 弧线中点：掠过敌人身侧
	var mid_cam_pos := _target_pos + _right_pe * (start_side + 0.6) + Vector3.UP * (start_h - 0.15)
	# 终点：“敌后”（位于敌人后方，侧向微偏，前景为倒地敌人，背景为正前方的胜利主角）
	var behind_side := 1.25 if _target_height < 1.0 else 1.8
	var behind_cam_pos := _target_pos + _dir_pe * _end_distance + _right_pe * behind_side + Vector3.UP * _end_height_offset

	# 贝塞尔弧线推进插值（前 65% 时间推进至敌后）
	var push_u := smoothstep(0.0, 0.65, t)
	var desired_pos := (1.0 - push_u) * (1.0 - push_u) * start_cam_pos + 2.0 * (1.0 - push_u) * push_u * mid_cam_pos + push_u * push_u * behind_cam_pos

	# 后 35% 时间：在敌后缓慢升降微移（慢动作下的悬停威严感）
	var drift_u := smoothstep(0.65, 1.0, t)
	desired_pos += Vector3.UP * (drift_u * 0.15) + _dir_pe * (drift_u * 0.22)

	# 2. 地表防穿模与视线高度防护
	var terrain_h := TerrainFieldUtil.height_at(desired_pos.x, desired_pos.z)
	desired_pos.y = maxf(desired_pos.y, terrain_h + 0.55)

	# 检查机位与主角之间的地形遮挡，若有地势起伏则自动抬升机位确保主角清晰可见
	var mid_check := desired_pos.lerp(player_chest, 0.5)
	var mid_h := TerrainFieldUtil.height_at(mid_check.x, mid_check.z)
	if mid_h > mid_check.y - 0.25:
		desired_pos.y = maxf(desired_pos.y, mid_h + 1.1)

	# 场景遮挡物理射线防护
	if is_inside_tree():
		var space := get_world_3d().direct_space_state
		if space:
			var ray := PhysicsRayQueryParameters3D.create(enemy_center, desired_pos, 1)
			var hit := space.intersect_ray(ray)
			if not hit.is_empty():
				desired_pos = hit.position + hit.normal * 0.35
				desired_pos.y = maxf(desired_pos.y, terrain_h + 0.55)

	# 3. 转向主角（转向核心逻辑）：
	# 前期对准敌人（呈现终结致命一击），中后期掠至敌后时平滑转向主角（将主角带入死亡慢动作画面中）
	var look_enemy_dir := (enemy_center - desired_pos).normalized()
	if look_enemy_dir.is_zero_approx():
		look_enemy_dir = Vector3.FORWARD
	var enemy_up := Vector3.UP
	if absf(look_enemy_dir.dot(enemy_up)) > 0.99:
		enemy_up = Vector3.FORWARD
	var quat_enemy := Basis.looking_at(look_enemy_dir, enemy_up).orthonormalized().get_rotation_quaternion()

	var look_player_dir := (player_chest - desired_pos).normalized()
	if look_player_dir.is_zero_approx():
		look_player_dir = -_dir_pe
	var player_up := Vector3.UP
	if absf(look_player_dir.dot(player_up)) > 0.99:
		player_up = Vector3.FORWARD
	var quat_player := Basis.looking_at(look_player_dir, player_up).orthonormalized().get_rotation_quaternion()

	# 在 0.22 ~ 0.62 推进切入敌后期间平滑旋转转向主角
	var turn_u := smoothstep(0.22, 0.62, t)
	var final_quat := quat_enemy.slerp(quat_player, turn_u)

	# 4. 镜头变焦插值（转向主角时长焦拉近，凸显主角的英武姿态）
	var fov_u := smoothstep(0.22, 0.70, t)
	fov = lerpf(_start_fov, _end_fov, fov_u)

	if is_inside_tree():
		global_position = desired_pos
		global_transform.basis = Basis(final_quat)
	else:
		position = desired_pos
		transform.basis = Basis(final_quat)



## 恢复玩家相机并安全释放自身
func restore_and_destroy() -> void:
	if active_cam == self:
		active_cam = null
	if is_instance_valid(_player_camera):
		_player_camera.make_current()
	queue_free()


func _exit_tree() -> void:
	if active_cam == self:
		active_cam = null
	if current and is_instance_valid(_player_camera):
		_player_camera.make_current()

