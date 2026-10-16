extends Node3D
## 敌人弹幕子弹。
##
## 【池化改造】玩家改成瞬发命中后不再生成子弹，但敌人弹幕仍在持续产生，
## 是当前唯一还在反复 instantiate / queue_free 的对象。改造要点：
##   1. 材质只在首次使用时 duplicate 一次，之后只改属性 —— 原来每次 setup()
##      都要 duplicate 三个材质，池化后它会变成主要剩余开销；
##   2. pulse_time 必须在 setup() 里归零，否则脉冲相位会带到下一次命中，
##      光环缩放会出现肉眼可见的跳变；
##   3. 生命周期结束时交还对象池，而不是 queue_free()。

const PoolUtil := preload("res://scripts/object_pool.gd")
const AudioUtil := preload("res://scripts/audio_manager.gd")
const TargetingUtil := preload("res://scripts/targeting.gd")
const ConfigUtil := preload("res://scripts/game_config.gd")

const POOL_KEY := "enemy_bullet"

## 近失弹呼啸参数（配置 enemy.bullet_whiz_*）。首次使用时读一次。
static var _whiz_configured := false
static var _whiz_radius := 2.4
static var _whiz_head_height := 1.35
static var _whiz_cooldown_ms := 140
## 破空声的增益（dB）。音效库接入后 `shot`/`sniper` 换成了真实采样，
## 而 `bullet_whiz` 仍是合成音色 —— 两者响度不再同一量级，旧的 -6 dB 会被枪声盖住。
## 现在由配置给一个与文件音源配平过的值。
static var _whiz_volume_db := -2.0
## 【只给狙击手】普通弹幕的近失呼啸总开关，默认关。
## 一次交火几十发子弹都在擦身时，这个声音就不再是信息而是噪声 ——
## 玩家只听得出"狙击重弹擦过去了"这一种，才有意义。
static var _whiz_enabled := false
## 跨子弹的全局冷却时间戳：密集弹幕同时擦身时只响一次，避免叠成一片噪声。
static var _next_whiz_msec := 0

@export var speed: float = 9.0
@export var damage: float = 14.0
@export var lifetime: float = 6.0
@export var turn_rate: float

var direction: Vector3 = Vector3.FORWARD
var shooter: CollisionObject3D
var fired_by_player: bool
var pulse_time: float
## 这一发是否已经响过破空声（每发最多一次）。
var _whizzed: bool

var _core_material: StandardMaterial3D
var _aura_material: StandardMaterial3D


func setup(
	new_direction: Vector3,
	source: CollisionObject3D,
	new_damage: float = 14.0,
	new_speed: float = 9.0,
	new_turn_rate: float = 0.0,
	new_color: Color = Color(1.0, 0.04, 0.24, 1.0)
) -> void:
	direction = new_direction.normalized()
	shooter = source
	fired_by_player = source.is_in_group("player")
	# 池化时覆盖来源快照；发射者死亡后弹丸仍能正确归属。
	set_meta(&"combat_source", preload("res://scripts/combat_telemetry.gd").source_info(source, "弹幕"))
	damage = new_damage
	speed = new_speed
	turn_rate = new_turn_rate
	# 池化复用必须把全部随时间累积的状态归零，否则上一发的相位会带过来。
	pulse_time = 0.0
	lifetime = 6.0
	_whizzed = false
	_load_whiz_config()
	($Aura as MeshInstance3D).scale = Vector3.ONE
	apply_color(new_color)
	look_at(global_position + direction, Vector3.UP, true)
	# juice：加入敌方弹丸组，供震地脉冲破招检索
	if not is_in_group("enemy_projectiles"):
		add_to_group("enemy_projectiles")


func apply_color(new_color: Color) -> void:
	if _core_material == null:
		_build_materials()
	_core_material.albedo_color = Color.WHITE
	_core_material.emission = Color.WHITE.lerp(new_color, 0.32)
	var contrast_color := Color.from_hsv(fmod(new_color.h + 0.18, 1.0), 0.88, 1.0, 0.34)
	_aura_material.albedo_color = contrast_color
	_aura_material.emission = contrast_color
	($Glow as OmniLight3D).light_color = new_color


## 每个实例只 duplicate 一次材质。Trail 与 Aura 共用同一份，保持原来的观感。
func _build_materials() -> void:
	var core_mesh: MeshInstance3D = $Core
	_core_material = core_mesh.material_override.duplicate() as StandardMaterial3D
	core_mesh.material_override = _core_material
	var aura_mesh: MeshInstance3D = $Aura
	_aura_material = aura_mesh.material_override.duplicate() as StandardMaterial3D
	aura_mesh.material_override = _aura_material
	($Trail as MeshInstance3D).material_override = _aura_material


func _physics_process(delta: float) -> void:
	pulse_time += delta
	$Aura.scale = Vector3.ONE * (1.0 + sin(pulse_time * 9.0) * 0.13)
	if not is_zero_approx(turn_rate):
		direction = direction.rotated(Vector3.UP, turn_rate * delta).normalized()
		look_at(global_position + direction, Vector3.UP, true)
	var next_position := global_position + direction * speed * delta
	# 先做近失判定，再走射线：擦身而过的那一发即使随后命中掩体，也该留下呼啸。
	_step_whiz(next_position)
	var query := PhysicsRayQueryParameters3D.create(global_position, next_position)
	# Enemy barrage hits only world geometry (layer 1) and the player (layer 2).
	query.collision_mask = 5 if fired_by_player else 3
	if is_instance_valid(shooter):
		query.exclude = [shooter.get_rid()]
	var hit := get_world_3d().direct_space_state.intersect_ray(query)
	if hit:
		global_position = hit.position
		var collider: Object = hit.collider
		var collider_node := collider as Node
		var hit_player := collider_node != null and collider_node.is_in_group("player")
		var hit_enemy := collider_node != null and collider_node.is_in_group("enemies")
		var valid_target: bool = hit_enemy if fired_by_player else hit_player
		if valid_target and collider.has_method("take_damage"):
			if hit_player:
				# 玩家额外接收一个"伤害来源坐标"，供 HUD 画受击方向指示。
				# 敌人版本没有这个参数，所以必须分开调用，不能统一传两个参数。
				preload("res://scripts/combat_telemetry.gd").hurt_player(collider_node,
					damage, global_position, 1.0, get_meta(&"combat_source", {}))
			else:
				collider.call("take_damage", damage)
		_spawn_hit_feedback(hit, valid_target and hit_player)
		_retire()
		return
	global_position = next_position
	lifetime -= delta
	if lifetime <= 0.0:
		_retire()


## 【近失弹呼啸】弹丸这一帧的位移段擦过玩家头部附近时，播一次破空声。
##
## 这条判定在旧的 ruin-star 线里是有的（`godot-ruin-star/scripts/enemy_bullet.gd`），
## 移植到本工程时整段丢了 —— 于是 `bullet_whiz` 这个音色在合成银行里写着、
## 全项目却没有任何调用方，"擦身而过"的爽感直接消失。这里按旧线补回，
## 并把半径 / 头部高度 / 冷却做成配置（`enemy.bullet_whiz_*`）。
##
## 每发最多响一次；另有一个跨子弹的全局冷却，避免十几发弹幕同时擦身时叠成噪声。
func _step_whiz(next_position: Vector3) -> void:
	# 【只给狙击手】默认关闭：普通弹幕量太大，几十发都在擦身时这个声音就不再是信息。
	if _whizzed or fired_by_player or not _whiz_enabled or _whiz_radius <= 0.0:
		return
	var player := TargetingUtil.nearest_player(self)
	if player == null:
		return
	var head := player.global_position + Vector3.UP * _whiz_head_height
	var segment := next_position - global_position
	var length_sq := segment.length_squared()
	if length_sq <= 0.0001:
		return
	var t := clampf((head - global_position).dot(segment) / length_sq, 0.0, 1.0)
	var closest := global_position + segment * t
	if closest.distance_to(head) > _whiz_radius:
		return
	var now := Time.get_ticks_msec()
	if now < _next_whiz_msec:
		return
	_whizzed = true
	_next_whiz_msec = now + _whiz_cooldown_ms
	# 走【优先声道】：轮转池在密集交火里每帧都在被命中音覆盖，
	# 走池子的 0.16 秒破空声会被下一个音效当场截断 —— 那才是"听不到"的真因。
	AudioUtil.play_at_priority("bullet_whiz", closest, _whiz_volume_db, randf_range(0.92, 1.15))


func _load_whiz_config() -> void:
	if _whiz_configured:
		return
	_whiz_configured = true
	_whiz_radius = maxf(ConfigUtil.get_float("enemy.bullet_whiz_radius", _whiz_radius), 0.0)
	_whiz_head_height = maxf(ConfigUtil.get_float("enemy.bullet_whiz_head_height", _whiz_head_height), 0.0)
	_whiz_cooldown_ms = maxi(
		int(ConfigUtil.get_float("enemy.bullet_whiz_cooldown_ms", float(_whiz_cooldown_ms))), 0
	)
	_whiz_volume_db = ConfigUtil.get_float("enemy.bullet_whiz_volume_db", _whiz_volume_db)
	_whiz_enabled = ConfigUtil.get_bool("enemy.bullet_whiz_enabled", false)


## 交还对象池。调用方无需持有引用，也不需要再做任何清理。
func _retire() -> void:	# 池化回收前退出破招检索组，避免组里残留已回收的弹丸
	if is_in_group("enemy_projectiles"):
		remove_from_group("enemy_projectiles")
	PoolUtil.release(POOL_KEY, self)


## 被玩家震地脉冲格挡偏折。
func deflect() -> void:
	_retire()


## 命中反馈：打中玩家用受击色、打中场景用中性色。
func _spawn_hit_feedback(hit: Dictionary, hit_player: bool) -> void:
	var scene := get_tree().current_scene
	if not scene:
		return
	var normal: Vector3 = hit.get("normal", Vector3.UP)
	# 不能叫 position：Node3D 自带同名属性，会触发 SHADOWED_VARIABLE_BASE_CLASS。
	var hit_position: Vector3 = hit.get("position", global_position)
	var color: Color = CombatFX.COLOR_PLAYER_HIT if hit_player else CombatFX.COLOR_WORLD_HIT
	CombatFX.spawn_impact(scene, hit_position, normal, color, 0.85)
