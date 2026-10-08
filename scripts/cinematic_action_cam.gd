class_name CinematicActionCam
extends Camera3D
## 动态全景动作镜头。
## 专门用于高光时刻（如遗迹共鸣爆发、完美格挡慢动作等）。
## 支持多套随机的运镜轨迹、多角度和不同距离，确保每次表现不重复。
const TerrainFieldUtil := preload("res://scripts/terrain_field.gd")
const AudioUtil := preload("res://scripts/audio_manager.gd")
const Session := preload("res://scripts/cinematic_session.gd")

static var active_cam: CinematicActionCam = null

var _target_node: Node3D = null
var _player_camera: Camera3D = null

var _duration := 1.0
var _elapsed_real_time := 0.0
var _last_msec := 0
var _finished := false
var _restored := true

var _original_time_scale := 1.0

# 运镜参数 (随机生成)
var _start_dist := 12.0
var _end_dist := 18.0
var _start_height := 5.0
var _end_height := 8.0
var _start_angle := 0.0
var _orbit_speed := 1.0
var _look_offset := Vector3.UP * 1.0
var _start_fov := 60.0
var _end_fov := 50.0

enum TrajectoryType { ORBIT_PULLBACK, SWEEP_LOW, SPIRAL_UP, OVERHEAD_DROP }
var _trajectory: TrajectoryType

static func dismiss_active() -> void:
	if active_cam != null and is_instance_valid(active_cam):
		active_cam.restore_and_destroy()

func start(target: Node3D, duration_sec: float = 1.0, slow_mo_scale: float = 0.12) -> void:
	Session.claim(self)
	active_cam = self
	_restored = false

	_target_node = target
	_duration = maxf(duration_sec, 0.4)
	_elapsed_real_time = 0.0
	_last_msec = Time.get_ticks_msec()
	_finished = false

	# 锁定角色输入，专心享受大招慢镜头演播
	if is_instance_valid(_target_node) and _target_node.has_method("set_cinematic_locked"):
		_target_node.call("set_cinematic_locked", true)

	_original_time_scale = Engine.time_scale
	Engine.time_scale = maxf(slow_mo_scale, 0.001)

	# 压低战场常规枪声杂音，让位于慢动作与大招低频轰鸣
	AudioUtil.duck(_duration + 0.4, -11.0)

	# 寻找玩家原生主相机
	if is_instance_valid(_target_node):
		_player_camera = _target_node.get_node_or_null("CameraPivot/SpringArm3D/Camera3D") as Camera3D
		if _player_camera == null:
			_player_camera = _target_node.get("camera") as Camera3D
	if _player_camera == null and is_inside_tree() and get_viewport() != null:
		var current_viewport_cam := get_viewport().get_camera_3d()
		if current_viewport_cam != null and current_viewport_cam != self:
			_player_camera = current_viewport_cam

	# 随机生成运镜参数，确保每次爆发视觉不同
	var rng := RandomNumberGenerator.new()
	rng.randomize()

	_trajectory = rng.randi_range(0, 3) as TrajectoryType
	_start_angle = rng.randf_range(0, TAU)
	_orbit_speed = rng.randf_range(-1.2, 1.2)
	if absf(_orbit_speed) < 0.45:
		_orbit_speed = signf(_orbit_speed) * 0.45

	match _trajectory:
		TrajectoryType.ORBIT_PULLBACK:
			# 标准全景拉远：从近处向后上方拉远，缓慢旋转俯瞰全场
			_start_dist = rng.randf_range(6.5, 9.0)
			_end_dist = rng.randf_range(16.0, 22.0)
			_start_height = rng.randf_range(2.0, 3.5)
			_end_height = rng.randf_range(5.5, 8.5)
			_start_fov = 58.0
			_end_fov = 42.0
		TrajectoryType.SWEEP_LOW:
			# 低空横扫：贴近地面高速掠过身侧，英雄仰角
			_start_dist = rng.randf_range(11.0, 15.0)
			_end_dist = rng.randf_range(7.5, 11.0)
			_start_height = rng.randf_range(0.9, 1.6)
			_end_height = rng.randf_range(1.6, 2.8)
			_orbit_speed *= 1.8
			_start_fov = 72.0
			_end_fov = 58.0
			_look_offset = Vector3.UP * 1.8
		TrajectoryType.SPIRAL_UP:
			# 螺旋上升：俯视角度逐渐拉高，全方位鸟瞰能量释放
			_start_dist = rng.randf_range(12.0, 16.0)
			_end_dist = rng.randf_range(8.0, 11.0)
			_start_height = rng.randf_range(2.8, 4.5)
			_end_height = rng.randf_range(11.0, 16.0)
			_orbit_speed *= 1.4
			_start_fov = 62.0
			_end_fov = 70.0
		TrajectoryType.OVERHEAD_DROP:
			# 上帝视角下俯：从高空极具压迫感地向下俯瞰与俯冲
			_start_dist = rng.randf_range(2.5, 5.0)
			_end_dist = rng.randf_range(8.0, 12.0)
			_start_height = rng.randf_range(18.0, 24.0)
			_end_height = rng.randf_range(7.0, 11.0)
			_orbit_speed = rng.randf_range(-0.6, 0.6)
			_start_fov = 52.0
			_end_fov = 46.0

	fov = _start_fov
	process_mode = Node.PROCESS_MODE_ALWAYS

	_update_cam_transform(0.0)
	make_current()

func _process(_delta: float) -> void:
	var now := Time.get_ticks_msec()
	var real_delta := maxf(float(now - _last_msec) * 0.001, 0.0)
	_last_msec = now
	if _finished or _restored or get_tree().paused:
		return
	_elapsed_real_time += real_delta

	var t := clampf(_elapsed_real_time / maxf(_duration, 0.01), 0.0, 1.0)
	var ease_t := smoothstep(0.0, 1.0, t)

	_update_cam_transform(ease_t)

	if t >= 1.0:
		_finished = true
		restore_and_destroy()

func _update_cam_transform(t: float) -> void:
	if not is_instance_valid(_target_node):
		return

	var center := _target_node.global_position if _target_node.is_inside_tree() else _target_node.position

	var current_dist := lerpf(_start_dist, _end_dist, t)
	var current_height := lerpf(_start_height, _end_height, t)
	var current_angle := _start_angle + _orbit_speed * t * PI

	var offset := Vector3(cos(current_angle), 0, sin(current_angle)) * current_dist
	var desired_pos := center + offset + Vector3.UP * current_height

	# 地形防穿模
	var terrain_h := TerrainFieldUtil.height_at(desired_pos.x, desired_pos.z)
	desired_pos.y = maxf(desired_pos.y, terrain_h + 0.8)

	var look_target := center + _look_offset

	# 物理射线遮挡防护
	if is_inside_tree():
		var space := get_world_3d().direct_space_state
		if space:
			var ray := PhysicsRayQueryParameters3D.create(look_target, desired_pos, 1)
			var hit := space.intersect_ray(ray)
			if not hit.is_empty():
				desired_pos = hit.position + hit.normal * 0.4
				desired_pos.y = maxf(desired_pos.y, terrain_h + 0.8)

	var look_dir := (look_target - desired_pos).normalized()
	if look_dir.is_zero_approx():
		look_dir = Vector3.FORWARD

	var up_dir := Vector3.UP
	if absf(look_dir.dot(up_dir)) > 0.99:
		up_dir = Vector3.FORWARD

	var final_quat := Basis.looking_at(look_dir, up_dir).orthonormalized().get_rotation_quaternion()

	fov = lerpf(_start_fov, _end_fov, t)

	if is_inside_tree():
		global_position = desired_pos
		global_transform.basis = Basis(final_quat)
	else:
		position = desired_pos
		transform.basis = Basis(final_quat)

func restore_and_destroy() -> void:
	_restore_controls()
	queue_free()


func _restore_controls() -> void:
	if _restored:
		return
	_restored = true
	_finished = true
	if active_cam == self:
		active_cam = null
	Session.release(self)

	# 恢复控制权与时间倍率
	if is_instance_valid(_target_node) and _target_node.has_method("set_cinematic_locked"):
		_target_node.call("set_cinematic_locked", false)

	Engine.time_scale = _original_time_scale
	if current and is_instance_valid(_player_camera) and _player_camera.is_inside_tree():
		_player_camera.make_current()

func _exit_tree() -> void:
	_restore_controls()

