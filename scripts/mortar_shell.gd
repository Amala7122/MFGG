extends Node3D
## 迫击炮弹：从敌人枪口沿抛物线飞到落点。
##
## ── 为什么是解析抛物线，不是物理 ──────────────────────────────
##
## 弹体是【纯视觉】，但它必须"每次都是同一条弧线"。物理积分依赖帧率与碰撞，
## 各端必然分叉；解析式是纯函数：同样的起点 / 终点 / 时长 → 同样的轨迹。
## 而且它便宜：每帧一次 lerp，没有射线、没有刚体、没有碰撞体。
##
## ── 一条硬规矩：它绝不承担计时 ──────────────────────────────
##
## 落地伤害仍由 ground_warning 自己的倒计时判定（见那里的 explode）。
## 弹体没生成、被裁掉、或者这一帧没跑到，玩家该吃的伤害照吃 ——
## 反过来（等弹体落地才算伤害）会让一次视觉故障变成一次玩法故障。
## 所以两者的时长【各自独立】，只由调用方负责把两者设成同一个值。
##
## ── 它回答两个问题 ──────────────────────────────────────────
##
## 地面那个 X 只回答了"落在哪"，没回答"那是什么、从哪来的"。
## 弹体补上后半句：从【敌人枪口】出发、沿看得见的弧线飞过去 ——
## 于是"谁扔的"和"扔到哪"连成一条因果链。

const ConfigUtil := preload("res://scripts/game_config.gd")
const AudioUtil := preload("res://scripts/audio_manager.gd")

var _start := Vector3.ZERO
var _end := Vector3.ZERO
var _duration := 1.4
var _arc := 7.0
var _elapsed := 0.0
var _color := Color(1.0, 0.5, 0.15, 1.0)
var _visual: Node3D


## landing 是【落点】而不是"目标" —— 它应该正好是地面 X 的中心。
func setup(start: Vector3, landing: Vector3, duration: float, color: Color) -> void:
	# 显式命名：代码 new() 出来的节点默认没有有意义的名字，
	# 而"从外面找到它"（探针、后续的回收逻辑）都依赖这个名字。
	name = "MortarShell"
	_start = start
	_end = landing
	_duration = maxf(duration, 0.05)
	_color = color
	_arc = maxf(ConfigUtil.get_float("mortar.arc_height", 7.0), 1.0)
	global_position = start
	_build()
	# 落体音。音色表的"结束频率"低于起始频率，本身就是一段下坠的哨音。
	# 【它播在落点，不是跟着弹体飞】—— 音频管理只支持定点播放。
	# 但"哨音来自落点方向 + 频率下坠"已经足够读成"有东西正砸过来"。
	AudioUtil.play_at("mortar", landing, -4.0)


func _process(delta: float) -> void:
	_elapsed += delta
	var t := clampf(_elapsed / _duration, 0.0, 1.0)
	var previous := global_position
	var next := point_at(t)
	global_position = next
	_face_velocity(next - previous)
	if t >= 1.0:
		queue_free()


## 抛物线上的一点，t ∈ [0,1]。
##
## 竖直项 4t(1-t) 在 t=0.5 取 1、两端取 0，所以 _arc 就是【最高点高出弦多少】。
## 不用 sin(πt)：抛物线才是真实抛体的形状，而且这里只有一次乘法。
func point_at(t: float) -> Vector3:
	return _start.lerp(_end, t) + Vector3.UP * (_arc * 4.0 * t * (1.0 - t))


func get_flight_time() -> float:
	return _duration


## 朝向当前速度方向。用本小段的位移近似速度，比解析求导更直观也更稳。
##
## 【必须跳过接近竖直的方向】—— Node3D.look_at 的 up 向量与朝向共线时会报错
## （"trying to look at a vector parallel to up"）。高拱度弹体起飞与落下那两段
## 正好接近竖直，不挡的话每次射击都会在控制台刷一条错误。
func _face_velocity(travel: Vector3) -> void:
	if _visual == null or travel.length_squared() <= 0.000001:
		return
	var direction := travel.normalized()
	if absf(direction.dot(Vector3.UP)) > 0.985:
		return
	_visual.look_at(_visual.global_position + direction, Vector3.UP, true)


func _build() -> void:
	_visual = Node3D.new()
	# 不要叫 Shell —— 与根节点名字撞了会让"按名字找节点"找到子节点上去。
	_visual.name = "ShellVisual"
	add_child(_visual)

	var shell_material := StandardMaterial3D.new()
	shell_material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	shell_material.albedo_color = _color
	shell_material.emission_enabled = true
	shell_material.emission = _color
	shell_material.emission_energy_multiplier = 4.0

	var sphere := SphereMesh.new()
	sphere.radius = 0.22
	sphere.height = 0.44
	sphere.radial_segments = 12
	sphere.rings = 6
	var body := MeshInstance3D.new()
	body.mesh = sphere
	body.material_override = shell_material
	_visual.add_child(body)

	# 尾迹朝 -Z（look_at 用模型前方 -Z，所以速度方向是 -Z，尾迹要挂在 +Z）。
	var trail_material := shell_material.duplicate() as StandardMaterial3D
	trail_material.albedo_color = Color(_color.r, _color.g, _color.b, 0.45)
	trail_material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	var trail := MeshInstance3D.new()
	var box := BoxMesh.new()
	box.size = Vector3(0.09, 0.09, 0.75)
	trail.mesh = box
	trail.position = Vector3(0.0, 0.0, 0.42)
	trail.material_override = trail_material
	_visual.add_child(trail)

	var glow := OmniLight3D.new()
	glow.light_color = _color
	glow.light_energy = 3.0
	glow.omni_range = 4.5
	_visual.add_child(glow)
