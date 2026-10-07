class_name FloatingWisp
extends Node3D
## 战术浮游卫士（Tactical Sentry Drone / Ruin Sentry）：
## 盘旋在玩家左肩后方的自主战术支援无人机，核心使命是警戒并射击后方与侧翼视野盲区（>65°）的偷袭敌人。
##
## 玩法与美术风格：
##   1. 纯正科幻机械风格：暗钛装甲机身、单眼光学雷达传感器、双轴矢量推力短舱、机腹双联电磁脉冲炮；
##   2. 战术飞控动力学：具备悬停陀螺仪微颤、加减速动态倾斜飞行（Banking）、多轴矢量喷口自适应平衡；
##   3. 防背刺压制与战术预警：自动侦测视野盲区与绕后偷袭敌人，发射高速动能等离子脉冲弹并发出警报音效。

const BallisticsUtil := preload("res://scripts/ballistics.gd")
const AudioUtil := preload("res://scripts/audio_manager.gd")
const ConfigUtil := preload("res://scripts/game_config.gd")
const CombatFXUtil := preload("res://scripts/combat_fx.gd")
const TerrainFieldUtil := preload("res://scripts/terrain_field.gd")

var enabled := true
var base_damage := 9.0
var fire_rate := 1.35
var attack_range := 22.0
var blind_spot_angle := 65.0
var projectile_speed := 42.0
var spirit_color := Color(0.25, 0.88, 1.0, 1.0)
var ceasefire_min_enemies := 1

var _player: CharacterBody3D = null
var _camera: Camera3D = null
var _attack_cooldown := 0.0
var _time := 0.0
var _overclock_mult := 1.0

# 机械视觉节点树
var _model_pivot: Node3D = null
var _drone_body: Node3D = null
var _weapon_mount: Node3D = null
var _sensor_eye: MeshInstance3D = null
var _left_thruster: Node3D = null
var _right_thruster: Node3D = null
var _left_plume: CPUParticles3D = null
var _right_plume: CPUParticles3D = null
var _light: OmniLight3D = null
var _lens_material: StandardMaterial3D = null
var _glow_material: StandardMaterial3D = null
var _barrel_l: MeshInstance3D = null
var _barrel_r: MeshInstance3D = null
var _current_target: Node3D = null
var _recoil_offset := 0.0


func setup(player: CharacterBody3D, camera: Camera3D = null) -> void:
	_player = player
	_camera = camera
	top_level = true

	# 读取配置
	enabled = ConfigUtil.get_bool("wisp.enabled", true)
	base_damage = maxf(ConfigUtil.get_float("wisp.damage", 9.0), 1.0)
	fire_rate = maxf(ConfigUtil.get_float("wisp.fire_rate", 1.35), 0.1)
	attack_range = maxf(ConfigUtil.get_float("wisp.range", 22.0), 5.0)
	blind_spot_angle = clampf(ConfigUtil.get_float("wisp.blind_spot_angle", 65.0), 30.0, 120.0)
	projectile_speed = maxf(ConfigUtil.get_float("wisp.projectile_speed", 42.0), 10.0)
	ceasefire_min_enemies = maxi(ConfigUtil.get_int("wisp.ceasefire_min_enemies", 1), 0)

	var col_arr: Array = ConfigUtil.get_float_array("wisp.color", [0.25, 0.88, 1.0, 1.0])
	if col_arr.size() >= 3:
		spirit_color = Color(float(col_arr[0]), float(col_arr[1]), float(col_arr[2]), float(col_arr[3]) if col_arr.size() > 3 else 1.0)

	if not enabled:
		visible = false
		set_process(false)
		set_physics_process(false)
		return

	# 初始悬浮在玩家左肩后方
	if is_instance_valid(_player):
		var p_pos: Vector3 = _player.global_position if _player.is_inside_tree() else _player.position
		if is_inside_tree():
			global_position = p_pos + Vector3(-0.85, 1.65, 0.25)
		else:
			position = p_pos + Vector3(-0.85, 1.65, 0.25)

	_setup_visuals()


func apply_overclock() -> void:
	_overclock_mult = 1.4
	attack_range *= 1.3
	base_damage += 4.0
	if is_instance_valid(_light):
		_light.light_energy = 1.35
	if is_instance_valid(_lens_material):
		_lens_material.emission_energy_multiplier = 5.2
	if is_instance_valid(_glow_material):
		_glow_material.albedo_color = spirit_color * 1.35
	if is_instance_valid(_left_thruster):
		_left_thruster.scale = Vector3.ONE * 1.15
	if is_instance_valid(_right_thruster):
		_right_thruster.scale = Vector3.ONE * 1.15
	if is_instance_valid(_left_plume):
		_left_plume.amount = 16
	if is_instance_valid(_right_plume):
		_right_plume.amount = 16


func _setup_visuals() -> void:
	_model_pivot = Node3D.new()
	_model_pivot.name = "ModelPivot"
	add_child(_model_pivot)

	# 内部机体位移/倾角节点（负责悬浮微颤与运动倾角，与全局朝向解耦）
	_drone_body = Node3D.new()
	_drone_body.name = "DroneBody"
	_model_pivot.add_child(_drone_body)

	# --- 材质调色板 ---
	# 1. 战术暗钛主框架（哑光高金属感）
	var dark_metal_mat := StandardMaterial3D.new()
	dark_metal_mat.albedo_color = Color(0.14, 0.16, 0.19)
	dark_metal_mat.metallic = 0.88
	dark_metal_mat.roughness = 0.32

	# 2. 复合装甲强化板（高对比军规灰蓝复合材料）
	var armor_plate_mat := StandardMaterial3D.new()
	armor_plate_mat.albedo_color = Color(0.32, 0.36, 0.42)
	armor_plate_mat.metallic = 0.70
	armor_plate_mat.roughness = 0.38

	# 3. 机械黑合金部件（铰链、导轨、炮管、排气护罩）
	var black_alloy_mat := StandardMaterial3D.new()
	black_alloy_mat.albedo_color = Color(0.08, 0.08, 0.09)
	black_alloy_mat.metallic = 0.95
	black_alloy_mat.roughness = 0.22

	# 4. 战术能量与离子自发光材质
	_glow_material = StandardMaterial3D.new()
	_glow_material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	_glow_material.albedo_color = spirit_color

	# 5. 光学传感器透镜材质（高发光强透镜感）
	_lens_material = StandardMaterial3D.new()
	_lens_material.albedo_color = Color(0.92, 0.98, 1.0)
	_lens_material.emission_enabled = true
	_lens_material.emission = spirit_color
	_lens_material.emission_energy_multiplier = 3.6

	# --- 1. 机身主体（Central Fuselage）---
	var hull_mesh := MeshInstance3D.new()
	hull_mesh.name = "MainHull"
	var hull_box := BoxMesh.new()
	hull_box.size = Vector3(0.13, 0.065, 0.19)
	hull_mesh.mesh = hull_box
	hull_mesh.material_override = dark_metal_mat
	_drone_body.add_child(hull_mesh)

	# 前部切角楔形装甲鼻锥（斜面朝前 -Z）
	var nose_mesh := MeshInstance3D.new()
	nose_mesh.name = "NoseWedge"
	var nose_prism := PrismMesh.new()
	nose_prism.size = Vector3(0.12, 0.06, 0.075)
	nose_mesh.mesh = nose_prism
	nose_mesh.material_override = dark_metal_mat
	nose_mesh.rotation_degrees = Vector3(-90, 0, 0)
	nose_mesh.position = Vector3(0.0, 0.0, -0.115)
	_drone_body.add_child(nose_mesh)

	# 背部复合装甲盖板（Dorsal Cowl）
	var cowl_mesh := MeshInstance3D.new()
	cowl_mesh.name = "DorsalCowl"
	var cowl_box := BoxMesh.new()
	cowl_box.size = Vector3(0.085, 0.022, 0.15)
	cowl_mesh.mesh = cowl_box
	cowl_mesh.material_override = armor_plate_mat
	cowl_mesh.position = Vector3(0.0, 0.038, 0.005)
	_drone_body.add_child(cowl_mesh)

	# 背部刀锋式战术雷达天线（Blade Antenna）
	var antenna_mesh := MeshInstance3D.new()
	antenna_mesh.name = "AntennaFin"
	var antenna_prism := PrismMesh.new()
	antenna_prism.size = Vector3(0.012, 0.075, 0.055)
	antenna_mesh.mesh = antenna_prism
	antenna_mesh.material_override = black_alloy_mat
	antenna_mesh.position = Vector3(0.0, 0.068, 0.045)
	antenna_mesh.rotation_degrees = Vector3(-18, 0, 0)
	_drone_body.add_child(antenna_mesh)

	# 机侧能量散热缝隙（Energy Vents）
	var vent_l := MeshInstance3D.new()
	var vent_box := BoxMesh.new()
	vent_box.size = Vector3(0.136, 0.012, 0.09)
	vent_l.mesh = vent_box
	vent_l.material_override = _glow_material
	vent_l.position = Vector3(0.0, 0.002, -0.01)
	_drone_body.add_child(vent_l)

	# --- 2. 战术单眼光电传感器（Optical Sensor Turret）---
	var eye_mount := Node3D.new()
	eye_mount.name = "SensorEyeMount"
	eye_mount.position = Vector3(0.0, 0.008, -0.135)
	_drone_body.add_child(eye_mount)

	var eye_bezel := MeshInstance3D.new()
	var bezel_geo := CylinderMesh.new()
	bezel_geo.top_radius = 0.030
	bezel_geo.bottom_radius = 0.034
	bezel_geo.height = 0.022
	bezel_geo.radial_segments = 12
	eye_bezel.mesh = bezel_geo
	eye_bezel.material_override = black_alloy_mat
	eye_bezel.rotation_degrees = Vector3(90, 0, 0)
	eye_mount.add_child(eye_bezel)

	_sensor_eye = MeshInstance3D.new()
	_sensor_eye.name = "EyeLens"
	var lens_geo := SphereMesh.new()
	lens_geo.radius = 0.024
	lens_geo.height = 0.040
	lens_geo.radial_segments = 12
	lens_geo.rings = 6
	_sensor_eye.mesh = lens_geo
	_sensor_eye.material_override = _lens_material
	_sensor_eye.position = Vector3(0.0, 0.0, -0.008)
	eye_mount.add_child(_sensor_eye)

	# 辅助测距微型传感器（左、右副眼）
	for side in [-1.0, 1.0]:
		var sub_lens := MeshInstance3D.new()
		var sub_geo := SphereMesh.new()
		sub_geo.radius = 0.007
		sub_geo.height = 0.014
		sub_lens.mesh = sub_geo
		sub_lens.material_override = _glow_material
		sub_lens.position = Vector3(side * 0.032, -0.008, -0.002)
		eye_mount.add_child(sub_lens)

	# --- 3. 机腹双联电磁脉冲炮管（Underslung Twin Rail Barrels）---
	_weapon_mount = Node3D.new()
	_weapon_mount.name = "WeaponMount"
	_weapon_mount.position = Vector3(0.0, -0.042, -0.05)
	_drone_body.add_child(_weapon_mount)

	var weapon_base := MeshInstance3D.new()
	var wbase_box := BoxMesh.new()
	wbase_box.size = Vector3(0.058, 0.018, 0.075)
	weapon_base.mesh = wbase_box
	weapon_base.material_override = black_alloy_mat
	_weapon_mount.add_child(weapon_base)

	var barrel_geo := CylinderMesh.new()
	barrel_geo.top_radius = 0.0075
	barrel_geo.bottom_radius = 0.0085
	barrel_geo.height = 0.12
	barrel_geo.radial_segments = 8

	_barrel_l = MeshInstance3D.new()
	_barrel_l.mesh = barrel_geo
	_barrel_l.material_override = black_alloy_mat
	_barrel_l.rotation_degrees = Vector3(90, 0, 0)
	_barrel_l.position = Vector3(-0.018, -0.004, -0.055)
	_weapon_mount.add_child(_barrel_l)

	_barrel_r = MeshInstance3D.new()
	_barrel_r.mesh = barrel_geo
	_barrel_r.material_override = black_alloy_mat
	_barrel_r.rotation_degrees = Vector3(90, 0, 0)
	_barrel_r.position = Vector3(0.018, -0.004, -0.055)
	_weapon_mount.add_child(_barrel_r)

	# --- 4. 左右双侧多轴矢量推进引擎舱（Vectoring Thruster Pods）---
	_left_thruster = _build_thruster_pod(-1.0, dark_metal_mat, armor_plate_mat, black_alloy_mat)
	_drone_body.add_child(_left_thruster)

	_right_thruster = _build_thruster_pod(1.0, dark_metal_mat, armor_plate_mat, black_alloy_mat)
	_drone_body.add_child(_right_thruster)

	# --- 5. 战术探照照明与护航光晕 ---
	_light = OmniLight3D.new()
	_light.name = "DroneLight"
	_light.light_color = spirit_color
	_light.omni_range = 3.8
	_light.light_energy = 0.95
	_light.shadow_enabled = false
	_drone_body.add_child(_light)


func _build_thruster_pod(side: float, dark_mat: Material, plate_mat: Material, black_mat: Material) -> Node3D:
	var root := Node3D.new()
	root.name = "Thruster_%s" % ("L" if side < 0.0 else "R")
	root.position = Vector3(side * 0.105, 0.005, 0.015)

	# 连接支架（Pylon Strut）
	var pylon := MeshInstance3D.new()
	var pylon_box := BoxMesh.new()
	pylon_box.size = Vector3(0.045, 0.012, 0.035)
	pylon.mesh = pylon_box
	pylon.material_override = black_mat
	pylon.position = Vector3(-side * 0.018, 0.0, 0.0)
	root.add_child(pylon)

	# 引擎圆柱短舱（Nacelle）
	var nacelle := MeshInstance3D.new()
	var nacelle_geo := CylinderMesh.new()
	nacelle_geo.top_radius = 0.024
	nacelle_geo.bottom_radius = 0.026
	nacelle_geo.height = 0.105
	nacelle_geo.radial_segments = 10
	nacelle.mesh = nacelle_geo
	nacelle.material_override = dark_mat
	nacelle.rotation_degrees = Vector3(90, 0, 0)
	root.add_child(nacelle)

	# 外侧复合装甲导流翼片（Armor Winglet）
	var winglet := MeshInstance3D.new()
	var winglet_box := BoxMesh.new()
	winglet_box.size = Vector3(0.010, 0.042, 0.085)
	winglet.mesh = winglet_box
	winglet.material_override = plate_mat
	winglet.position = Vector3(side * 0.024, 0.008, 0.0)
	winglet.rotation_degrees = Vector3(0, 0, side * 15.0)
	root.add_child(winglet)

	# 后部排气喷口环（Exhaust Nozzle）
	var nozzle := MeshInstance3D.new()
	var nozzle_geo := TorusMesh.new()
	nozzle_geo.inner_radius = 0.016
	nozzle_geo.outer_radius = 0.025
	nozzle_geo.rings = 10
	nozzle_geo.ring_segments = 6
	nozzle.mesh = nozzle_geo
	nozzle.material_override = black_mat
	nozzle.position = Vector3(0.0, 0.0, 0.052)
	root.add_child(nozzle)

	# 喷口内等离子发光体（Plasma Core）
	var core := MeshInstance3D.new()
	var core_geo := CylinderMesh.new()
	core_geo.top_radius = 0.015
	core_geo.bottom_radius = 0.015
	core_geo.height = 0.012
	core_geo.radial_segments = 8
	core.mesh = core_geo
	core.material_override = _glow_material
	core.rotation_degrees = Vector3(90, 0, 0)
	core.position = Vector3(0.0, 0.0, 0.048)
	root.add_child(core)

	# 尾部等离子离子微喷流粒子（严格绑定于短舱局部坐标系，杜绝世界坐标残留拖影）
	var plume := CPUParticles3D.new()
	plume.name = "IonPlume"
	plume.amount = 12
	plume.lifetime = 0.08
	plume.local_coords = true
	plume.direction = Vector3(0.0, -0.05, 1.0) # 向后喷射
	plume.spread = 8.0
	plume.gravity = Vector3.ZERO
	plume.initial_velocity_min = 2.2
	plume.initial_velocity_max = 3.6
	plume.scale_amount_min = 0.012
	plume.scale_amount_max = 0.024
	plume.position = Vector3(0.0, 0.0, 0.055)

	var p_curve := Curve.new()
	p_curve.add_point(Vector2(0.0, 1.0))
	p_curve.add_point(Vector2(0.7, 0.75))
	p_curve.add_point(Vector2(1.0, 0.0))
	plume.scale_amount_curve = p_curve

	var p_mesh := SphereMesh.new()
	p_mesh.radius = 0.012
	p_mesh.height = 0.024
	p_mesh.radial_segments = 6
	p_mesh.rings = 3
	plume.mesh = p_mesh
	plume.material_override = _glow_material
	root.add_child(plume)

	if side < 0.0:
		_left_plume = plume
	else:
		_right_plume = plume

	return root


func _physics_process(delta: float) -> void:
	if not enabled or not is_instance_valid(_player):
		return

	if _player.is_queued_for_deletion():
		queue_free()
		return

	# 玩家死亡或倒地结算中，无人机渐隐收束
	var p_health: Variant = _player.get("health")
	if (p_health != null and float(p_health) <= 0.0) or _player.get("_dying") == true:
		scale = scale.lerp(Vector3.ZERO, delta * 4.0)
		if scale.x <= 0.05:
			visible = false
		return

	_time += delta
	if _attack_cooldown > 0.0:
		_attack_cooldown -= delta

	# 1. 战术飞行跟随与机动倾角（Banking）
	_update_follow_movement(delta)

	# 2. 机械悬停微调与矢量喷口动态平衡
	_update_idle_animation(delta)

	# 3. 视野盲区雷达索敌与高频射击判定
	_update_targeting_and_combat(delta)


func _update_follow_movement(delta: float) -> void:
	var fwd := Vector3.FORWARD
	var right := Vector3.RIGHT
	if is_instance_valid(_camera) and _camera.is_inside_tree():
		fwd = -_camera.global_transform.basis.z
		right = _camera.global_transform.basis.x
	elif is_instance_valid(_player) and _player.is_inside_tree():
		fwd = -_player.global_transform.basis.z
		right = _player.global_transform.basis.x

	fwd.y = 0.0
	right.y = 0.0
	if fwd.is_zero_approx():
		fwd = Vector3.FORWARD
	else:
		fwd = fwd.normalized()
	if right.is_zero_approx():
		right = Vector3.RIGHT
	else:
		right = right.normalized()

	var horiz_basis := Basis(right, Vector3.UP, -fwd).orthonormalized()

	var is_aiming: bool = (_player.get("_aiming") == true)
	# 瞄准（ADS）时适当向外和向上避让，确保护航视野一览无遗且绝不挡准星
	var offset := Vector3(-1.15, 1.85, 0.45) if is_aiming else Vector3(-0.85, 1.65, 0.25)
	var player_pos: Vector3 = _player.global_position if _player.is_inside_tree() else _player.position
	var target_pos: Vector3 = player_pos + horiz_basis * offset

	var my_pos := global_position if is_inside_tree() else position
	var dist_sq := my_pos.distance_squared_to(target_pos)
	if dist_sq > 64.0:
		if is_inside_tree():
			global_position = target_pos
		else:
			position = target_pos
	else:
		var follow_weight := 1.0 - exp(-14.0 * delta)
		if is_inside_tree():
			global_position = global_position.lerp(target_pos, follow_weight)
		else:
			position = position.lerp(target_pos, follow_weight)

	# 模拟无人机加减速动力学倾斜（Flight Banking）：
	# 根据玩家物理运动速度分解至无人机当前朝向，产生平滑、稳定的倾斜反馈，彻底告别位置差抖动与晃动
	if is_instance_valid(_drone_body) and is_instance_valid(_model_pivot):
		var p_vel: Vector3 = _player.velocity if is_instance_valid(_player) else Vector3.ZERO
		var horiz_vel := Vector3(p_vel.x, 0.0, p_vel.z)

		var pivot_basis := _model_pivot.global_transform.basis if is_inside_tree() else _model_pivot.transform.basis
		var pivot_fwd := -pivot_basis.z
		pivot_fwd.y = 0.0
		if not pivot_fwd.is_zero_approx():
			pivot_fwd = pivot_fwd.normalized()
		else:
			pivot_fwd = Vector3.FORWARD

		var pivot_right := pivot_basis.x
		pivot_right.y = 0.0
		if not pivot_right.is_zero_approx():
			pivot_right = pivot_right.normalized()
		else:
			pivot_right = Vector3.RIGHT

		var forward_speed := horiz_vel.dot(pivot_fwd)
		var strafe_speed := horiz_vel.dot(pivot_right)

		var target_pitch := clampf(-forward_speed * 0.012, -deg_to_rad(8.0), deg_to_rad(8.0))
		var target_roll := clampf(-strafe_speed * 0.015, -deg_to_rad(10.0), deg_to_rad(10.0))

		var bank_weight := 1.0 - exp(-10.0 * delta)
		_drone_body.rotation.x = lerpf(_drone_body.rotation.x, target_pitch, bank_weight)
		_drone_body.rotation.z = lerpf(_drone_body.rotation.z, target_roll, bank_weight)


func _update_idle_animation(delta: float) -> void:
	# 悬浮微动：柔和低频动力学浮沉（纯平滑浮游，无任何人工高频微震，保证画面如丝般顺滑）
	var bob_y := sin(_time * 2.0) * 0.022
	var bob_x := cos(_time * 1.3) * 0.012
	_drone_body.position = Vector3(bob_x, bob_y, _recoil_offset)

	# 左右多轴矢量推力短舱自适应姿态微调（Pitch & Yaw Gimballing）
	if is_instance_valid(_left_thruster):
		_left_thruster.rotation.x = sin(_time * 2.4) * 0.05
		_left_thruster.rotation.z = deg_to_rad(-8.0) + cos(_time * 1.8) * 0.02
	if is_instance_valid(_right_thruster):
		_right_thruster.rotation.x = sin(_time * 2.4 + 0.4) * 0.05
		_right_thruster.rotation.z = deg_to_rad(8.0) - cos(_time * 1.8) * 0.02

	# 武器与机身后坐力平滑复位
	if is_instance_valid(_weapon_mount) and _weapon_mount.position.z > -0.05:
		_weapon_mount.position.z = move_toward(_weapon_mount.position.z, -0.05, delta * 0.28)
	if _recoil_offset > 0.0001:
		_recoil_offset = move_toward(_recoil_offset, 0.0, delta * 0.08)


func _update_targeting_and_combat(delta: float) -> void:
	var cam_fwd: Vector3
	var cam_right: Vector3
	if is_instance_valid(_camera) and _camera.is_inside_tree():
		cam_fwd = -_camera.global_transform.basis.z
		cam_right = _camera.global_transform.basis.x
	elif is_instance_valid(_player) and _player.is_inside_tree():
		cam_fwd = -_player.global_transform.basis.z
		cam_right = _player.global_transform.basis.x
	else:
		cam_fwd = Vector3.FORWARD
		cam_right = Vector3.RIGHT
	cam_fwd.y = 0.0
	cam_right.y = 0.0
	if cam_fwd.is_zero_approx():
		cam_fwd = Vector3.FORWARD
	else:
		cam_fwd = cam_fwd.normalized()
	if cam_right.is_zero_approx():
		cam_right = Vector3.RIGHT
	else:
		cam_right = cam_right.normalized()

	var cos_thresh := cos(deg_to_rad(blind_spot_angle))
	var best_target: Node3D = null
	var best_score := -INF
	var player_pos: Vector3 = _player.global_position if _player.is_inside_tree() else _player.position
	var my_pos: Vector3 = global_position if is_inside_tree() else position
	var world: World3D = get_world_3d() if is_inside_tree() else null
	var space_state: PhysicsDirectSpaceState3D = world.direct_space_state if world != null else null
	var enemies: Array = []
	if is_inside_tree() and get_tree() != null:
		enemies = get_tree().get_nodes_in_group("enemies")
	elif is_instance_valid(_player) and _player.get_parent():
		for child in _player.get_parent().get_children():
			if child.is_in_group("enemies"):
				enemies.append(child)

	var extent := TerrainFieldUtil.get_extent()
	var living_enemies: Array[Node3D] = []
	for node in enemies:
		var enemy := node as Node3D
		if not is_instance_valid(enemy) or enemy.is_queued_for_deletion():
			continue
		if enemy.get("_dying") == true:
			continue
		var enemy_health = enemy.get("health")
		if enemy_health != null and float(enemy_health) <= 0.0:
			continue
		var e_pos: Vector3 = enemy.global_position if enemy.is_inside_tree() else enemy.position
		# 战术感知过滤 1: 掉出地图边界或已在虚空中的目标绝不锁定
		if absf(e_pos.x) > (extent + 0.4) or absf(e_pos.z) > (extent + 0.4):
			continue
		# 战术感知过滤 2: 掉落至地面以下/悬崖下方的目标绝不锁定
		var ground_h := TerrainFieldUtil.height_at(e_pos.x, e_pos.z)
		if e_pos.y < (ground_h - 1.2):
			continue
		living_enemies.append(enemy)

	# 战场停火守则：仅剩 1 个（或配置阈值）敌人时，浮游卫士停火，把终结机会和特写留给玩家
	if ceasefire_min_enemies > 0 and living_enemies.size() <= ceasefire_min_enemies:
		_current_target = null
		if is_instance_valid(_lens_material):
			_lens_material.emission_energy_multiplier = 3.6
		var sweep_side := cam_right * (sin(_time * 1.1) * 0.32)
		var rear_dir := (-cam_fwd + sweep_side).normalized()
		if not rear_dir.is_zero_approx():
			var up_vec := Vector3.UP
			if absf(rear_dir.dot(up_vec)) > 0.99:
				up_vec = Vector3.FORWARD
			var rear_basis := Basis.looking_at(rear_dir, up_vec).orthonormalized()
			var rear_quat := rear_basis.get_rotation_quaternion()
			var rot_weight := 1.0 - exp(-5.0 * delta)
			_model_pivot.quaternion = _model_pivot.quaternion.slerp(rear_quat, rot_weight)
		return

	for enemy in living_enemies:
		var enemy_pos: Vector3 = enemy.global_position if enemy.is_inside_tree() else enemy.position
		var to_enemy := enemy_pos - player_pos
		var dist := to_enemy.length()
		if dist > (attack_range * _overclock_mult) or dist < 0.2:
			continue

		# 战术感知过滤 3: 俯视角过陡（悬崖边缘下方深渊盲区敌人不锁定射击）
		if (enemy_pos.y - player_pos.y) < -3.2 and absf(to_enemy.y / maxf(dist, 0.01)) > 0.65:
			continue

		var dir_flat := Vector3(to_enemy.x, 0.0, to_enemy.z).normalized()
		var dot := cam_fwd.dot(dir_flat)

		# 盲区判断：处于相机视口外（> 65°）或身后的敌人；或者极近距离贴身偷袭（< 3.2m）
		var in_blind_spot := (dot < cos_thresh)
		var is_emergency := (dist <= 3.2)
		if not in_blind_spot and not is_emergency:
			continue

		# 评分：越在背后（dot越小，1.0 - dot 越大）权重越高，距离越近越优先
		var behindness := (1.0 - dot)
		var score := behindness * 20.0 - dist * 0.75
		if is_emergency:
			score += 6.0

		if score > best_score:
			# 遮挡射线检测（确保掩体与墙体后面不会盲穿透射击）
			var is_visible := true
			if space_state:
				var ray_query := PhysicsRayQueryParameters3D.create(
					my_pos,
					enemy_pos + Vector3.UP * 0.85,
					1 # 仅与世界地形/掩体静态碰撞体相交
				)
				ray_query.exclude = [self, _player, enemy]
				var hit: Dictionary = space_state.intersect_ray(ray_query)
				is_visible = hit.is_empty()
			if is_visible:
				best_score = score
				best_target = enemy

	if is_instance_valid(best_target):
		_current_target = best_target
		var enemy_pt: Vector3 = best_target.global_position if best_target.is_inside_tree() else best_target.position
		var target_aim_pt := enemy_pt + Vector3.UP * 0.85
		var look_dir := (target_aim_pt - my_pos).normalized()
		if not look_dir.is_zero_approx():
			var up_vec := Vector3.UP
			if absf(look_dir.dot(up_vec)) > 0.99:
				up_vec = Vector3.FORWARD
			var target_basis := Basis.looking_at(look_dir, up_vec).orthonormalized()
			var target_quat := target_basis.get_rotation_quaternion()
			var aim_weight := 1.0 - exp(-16.0 * delta)
			_model_pivot.quaternion = _model_pivot.quaternion.slerp(target_quat, aim_weight)

		# 锁定目标时传感器高光增强
		if is_instance_valid(_lens_material):
			_lens_material.emission_energy_multiplier = 4.8

		if _attack_cooldown <= 0.0:
			_attack_cooldown = 1.0 / (fire_rate * _overclock_mult)
			_fire_spirit_dart(best_target)
	else:
		_current_target = null
		if is_instance_valid(_lens_material):
			_lens_material.emission_energy_multiplier = 3.6
		# 无盲区敌人时，无人机在后方两侧平缓警戒巡视（扇面扫描，侧向依据相机坐标系，不随世界坐标偏转）
		var sweep_side := cam_right * (sin(_time * 1.1) * 0.32)
		var rear_dir := (-cam_fwd + sweep_side).normalized()
		if not rear_dir.is_zero_approx():
			var up_vec := Vector3.UP
			if absf(rear_dir.dot(up_vec)) > 0.99:
				up_vec = Vector3.FORWARD
			var rear_basis := Basis.looking_at(rear_dir, up_vec).orthonormalized()
			var rear_quat := rear_basis.get_rotation_quaternion()
			var rot_weight := 1.0 - exp(-5.0 * delta)
			_model_pivot.quaternion = _model_pivot.quaternion.slerp(rear_quat, rot_weight)


func _fire_spirit_dart(target: Node3D) -> void:
	if not is_instance_valid(target):
		return

	# 机腹炮架后坐力与机身微后坐
	if is_instance_valid(_weapon_mount):
		_weapon_mount.position.z = -0.025 # 向后弹退
	_recoil_offset = 0.016

	if is_instance_valid(_light):
		_light.light_energy = 2.4
		var light_tween := create_tween()
		light_tween.tween_property(_light, "light_energy", 0.95, 0.20)

	var my_pos := global_position if is_inside_tree() else position
	AudioUtil.play_at("wisp_shot", my_pos, -2.5, randf_range(1.10, 1.28))

	var dart := WispDart.new()
	# 弹药自前置双联炮管前端精准发射（-Z 轴正前方向）
	var spawn_pos := (my_pos + _model_pivot.global_transform.basis * Vector3(0.0, -0.045, -0.16)) if is_inside_tree() else (my_pos + Vector3(0.0, -0.045, -0.16))
	var scene: Node = (get_tree().current_scene if get_tree() else null) if is_inside_tree() else null
	if not scene:
		scene = get_parent()
	if scene:
		scene.add_child(dart)
		dart.setup(spawn_pos, target, base_damage * _overclock_mult, projectile_speed, spirit_color)


# ---------------------------------------------------------------- 战术电磁脉冲钉弹
class WispDart extends Node3D:
	var _target: Node3D = null
	var _damage: float = 9.0
	var _speed: float = 42.0
	var _color: Color = Color(0.25, 0.88, 1.0)
	var _velocity: Vector3 = Vector3.ZERO
	var _life_time: float = 1.35
	var _mesh_inst: MeshInstance3D = null
	var _light: OmniLight3D = null

	func setup(start_pos: Vector3, target: Node3D, dmg: float, spd: float, col: Color) -> void:
		if is_inside_tree():
			global_position = start_pos
		else:
			position = start_pos
		_target = target
		_damage = dmg
		_speed = spd
		_color = col

		var target_pos := target.global_position if (is_instance_valid(target) and target.is_inside_tree()) else (target.position if is_instance_valid(target) else start_pos + Vector3.FORWARD)
		var target_pt := target_pos + Vector3.UP * 0.85
		var to_target := (target_pt - start_pos).normalized()
		if to_target.is_zero_approx():
			to_target = Vector3.FORWARD
		_velocity = to_target * _speed
		if is_inside_tree():
			var up := Vector3.UP
			if absf(to_target.dot(up)) > 0.99:
				up = Vector3.FORWARD
			look_at(global_position + to_target, up)

		_build_visuals()

	func _build_visuals() -> void:
		# 高速动能脉冲钉弹（菱形破甲曳光弹体）
		_mesh_inst = MeshInstance3D.new()
		var mesh := BoxMesh.new()
		mesh.size = Vector3(0.024, 0.024, 0.38)
		var mat := StandardMaterial3D.new()
		mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		mat.albedo_color = Color(0.9, 0.98, 1.0)
		_mesh_inst.mesh = mesh
		_mesh_inst.material_override = mat
		add_child(_mesh_inst)

		_light = OmniLight3D.new()
		_light.light_color = _color
		_light.omni_range = 2.4
		_light.light_energy = 1.1
		_light.shadow_enabled = false
		add_child(_light)

	func _physics_process(delta: float) -> void:
		_life_time -= delta
		if _life_time <= 0.0:
			queue_free()
			return

		var cur_pos := global_position if is_inside_tree() else position
		# 智能微调追踪弧线（机动飞行修正，确保在高速机动中精准钉中弱点）
		if is_instance_valid(_target) and _target.is_inside_tree() and _target.get("_dying") != true:
			var t_pos: Vector3 = _target.global_position
			var ground_h := TerrainFieldUtil.height_at(t_pos.x, t_pos.z)
			if t_pos.y >= (ground_h - 1.2):
				var target_pt := t_pos + Vector3.UP * 0.85
				var desired_dir := (target_pt - cur_pos).normalized()
				_velocity = _velocity.slerp(desired_dir * _speed, clampf(delta * 14.0, 0.0, 1.0))
				if _velocity.length_squared() > 0.01 and is_inside_tree():
					var fwd := _velocity.normalized()
					var up := Vector3.UP
					if absf(fwd.dot(up)) > 0.99:
						up = Vector3.FORWARD
					look_at(global_position + fwd, up)

		var move_step := _velocity * delta
		var world := get_world_3d() if is_inside_tree() else null
		var space_state := world.direct_space_state if world else null
		if space_state:
			var ray_query := PhysicsRayQueryParameters3D.create(
				global_position,
				global_position + move_step + _velocity.normalized() * 0.15,
				3 # 碰撞检测掩码：1世界层 + 2敌人层
			)
			ray_query.exclude = [self]
			var res := space_state.intersect_ray(ray_query)
			if not res.is_empty():
				_on_hit(res["position"], res["normal"], res["collider"])
				return

		# 贴近判定兜底
		if is_instance_valid(_target):
			var target_pt := _target.global_position + Vector3.UP * 0.85
			if global_position.distance_to(target_pt) <= 0.45:
				_on_hit(target_pt, -_velocity.normalized(), _target)
				return

		global_position += move_step

	func _on_hit(hit_pos: Vector3, normal: Vector3, collider: Object) -> void:
		var scene := get_tree().current_scene if get_tree() else get_parent()
		if scene:
			CombatFXUtil.spawn_impact(scene, hit_pos, normal, _color, 0.6)
			if collider != null:
				BallisticsUtil.resolve_hit(scene, hit_pos, normal, collider, _damage, false, 0.6)
		queue_free()
