extends Area3D
## 掉落物：生命包 / 子弹包 / 三种武器升级模块。
##
## 【数据驱动】颜色、显示文字、效果量全部来自 data/game_config.json 的 pickups 段，
## 这里只保留"怎么使用这些数字"的逻辑。新增一种掉落物 =
##   配置里加一项 pickups.<key> + 这里加一个 enum 与分支。
##
## 【拾取契约】效果函数返回 false 表示"这次拾取没生效"（血量满 / 备弹满 / 模块满级）。
## 此时**不消耗掉落物** —— 玩家会把它留在原地，等真正需要时再来拿。
## 没有这条契约的话，残血玩家踩到已满级的模块会同时损失模块和满血机会。
##
## 契约在磁力下的含义：被吸到玩家身边但用不上时，掉落物**就地放下、不再跟随**
## （见 `_step_magnet` 与 `pickup.follow_until_usable`）。否则"满血捡到血包"会变成
## 挂在身上等下顿伤害的自动回血，玩家失去"什么时候用"的决定权。

const ConfigUtil := preload("res://scripts/game_config.gd")
const TargetingUtil := preload("res://scripts/targeting.gd")

enum PickupType { HEALTH, AMMO, FIRE_RATE, DAMAGE, MAGAZINE }

## 枚举 → 配置键。新增类型时这里也要补一行（以及上面的 enum）。
const TYPE_KEYS := {
	PickupType.HEALTH: "health",
	PickupType.AMMO: "ammo",
	PickupType.FIRE_RATE: "fire_rate",
	PickupType.DAMAGE: "damage",
	PickupType.MAGAZINE: "magazine",
}

@export var pickup_type: int = PickupType.HEALTH

var pickup_color: Color = Color(1.0, 0.72, 0.08, 1.0)
var hover_time: float
var last_hover_offset: float
var lifetime: float = 30.0
var consumed: bool
## 拾取磁力参数（配置 pickup.magnet_range / magnet_speed）。
var magnet_range: float = 11.0
var magnet_speed: float = 12.0
## 已经被吸引过就不再松手：玩家后退时掉落物会继续追，避免"差一点没捡到"。
var _magnetized := false
## 贴身但用不上（满血 / 备弹满 / 模块满级）时已经就地放下。
## 放下之后不再吸附、也不再跟随，退回普通掉落物。
var _settled := false
## 关掉之后（默认）：用不上就就地放下，想用再走回来踩。
## 打开之后：掉落物贴在玩家身上等时机，一掉血立刻被吃掉。
## 那是"随身补给"的设计，不是默认行为 —— 保留开关是为了将来真要做成特性时不必重写。
var follow_until_usable := false

@onready var core: MeshInstance3D = $Core
@onready var aura: MeshInstance3D = $Aura
@onready var glow: OmniLight3D = $Glow
@onready var label: Label3D = $Label


# ---------------------------------------------------------------- 掉落表

## 按配置的掉落表抽一个掉落物类型；返回 -1 表示这次不掉落。
##
## 近战与远程共用这一个入口，避免两边各写一份概率（原先就是这样，且远程还会
## 连掉两次）。想调"血包掉太多"只改 drops.weights.health 即可。
static func roll_drop(enemy_kind: String) -> int:
	var chance := ConfigUtil.get_float("drops.%s_chance" % enemy_kind, 0.5)
	if randf() >= chance:
		return -1
	var weights := ConfigUtil.get_dictionary("drops.weights")
	if weights.is_empty():
		return PickupType.HEALTH
	var total := 0.0
	for value in weights.values():
		if value is float or value is int:
			total += float(value)
	if total <= 0.0:
		return -1
	var roll := randf() * total
	for key in weights.keys():
		var value: Variant = weights[key]
		if not (value is float or value is int):
			continue
		roll -= float(value)
		if roll <= 0.0:
			return _type_from_key(String(key))
	return -1


static func _type_from_key(key: String) -> int:
	for type in TYPE_KEYS.keys():
		if String(TYPE_KEYS[type]) == key:
			return int(type)
	return PickupType.HEALTH


# ---------------------------------------------------------------- 生命周期

func _ready() -> void:
	# 登记进组供小地图画光点；不登记的话掉落物在小地图上完全不可见。
	add_to_group("pickups")
	# 生存时间与磁力参数统一走配置：原先 lifetime 写死在这里，
	# 而 data/game_config.json 的 pickup.lifetime 从来没有被读过（改了没反应）。
	lifetime = maxf(ConfigUtil.get_float("pickup.lifetime", lifetime), 1.0)
	magnet_range = maxf(ConfigUtil.get_float("pickup.magnet_range", magnet_range), 0.0)
	magnet_speed = maxf(ConfigUtil.get_float("pickup.magnet_speed", magnet_speed), 0.0)
	follow_until_usable = ConfigUtil.get_bool("pickup.follow_until_usable", false)
	body_entered.connect(on_body_entered)
	apply_appearance()


func configure(new_type: int) -> void:
	pickup_type = new_type
	if is_node_ready():
		apply_appearance()


func _process(delta: float) -> void:
	lifetime -= delta
	if lifetime <= 0.0:
		queue_free()
		return
	if _step_magnet(delta):
		return
	hover_time += delta
	var hover_offset := sin(hover_time * 2.8) * 0.14
	position.y += hover_offset - last_hover_offset
	last_hover_offset = hover_offset
	rotate_y(delta * 1.8)


## 拾取磁力：进入吸引半径后飞向玩家，贴身后直接结算。
##
## 【为什么必须有】武器等级完全由"物理走过去捡模块"决定（player_weapon.apply_upgrade
## 每层 +1 级），而掉落物落在敌人的死亡位置 —— 敌人通常死在远处，玩家又未必敢离开掩体。
## 于是理论曲线（按拾取率 50/75/100% 推算）和实机体验直接脱钩：捡得到就滚雪球，
## 捡不到就一直卡着，同一局的手感可以差出一个量级。
##
## 磁力把"拾取"从走位负担变成自动结算，但保留策略部分：吸引半径只有 magnet_range，
## 所以"要不要前压到尸体附近"仍然是玩家的决定。
##
## 【贴身但用不上时就地放下】—— 这是修掉的一个 bug：满血时捡到血包，掉落物会
## 一直贴在玩家身上跟着跑，等玩家一掉血就被"顺手"吃掉。那不是磁力，那是挂件：
## 玩家失去了"什么时候用"的决定权，而且背包会不自觉地被回血占满。
## 现在改为放下、恢复普通待机 —— 玩家想用就自己走回去踩。若将来要把
## "随身补给跟着你等时机"做成一等设计，把 pickup.follow_until_usable 打开即可。
## 返回 true 表示这一帧由磁力接管，不再播待机漂浮。
func _step_magnet(delta: float) -> bool:
	if consumed or _settled or magnet_speed <= 0.0:
		return false
	var player := TargetingUtil.nearest_player(self)
	if player == null:
		return false
	var offset := (player.global_position + Vector3.UP * 0.9) - global_position
	var distance := offset.length()
	if distance > magnet_range and not _magnetized:
		return false
	_magnetized = true
	if distance <= 1.3:
		# 贴身直接结算：不依赖 Area 重叠检测，也不给"从身上穿过去"留空子。
		# 若这次拾取无效（满血 / 备弹满 / 模块满级）就放下 —— 见【拾取契约】。
		if _apply_to(player):
			consumed = true
			queue_free()
		elif not follow_until_usable:
			# 就地放下并退出磁力：之后它只是一个普通掉落物，玩家想用再走回来踩。
			# follow_until_usable 打开时保留旧的"跟着跑、一掉血就吃"行为（留给将来的设计用）。
			_settled = true
		return true
	# 越近越快，形成"被吸进去"的加速度感。
	var ratio := clampf(distance / maxf(magnet_range, 0.01), 0.0, 1.0)
	var speed := lerpf(magnet_speed * 2.2, magnet_speed, ratio)
	global_position += offset / distance * speed * delta
	return true


# ---------------------------------------------------------------- 配置读取

func _config_key() -> String:
	return String(TYPE_KEYS.get(pickup_type, "health"))


func _config_float(key: String, field: String, fallback: float) -> float:
	return ConfigUtil.get_float("pickups.%s.%s" % [key, field], fallback)


func _config_int(key: String, field: String, fallback: int) -> int:
	return ConfigUtil.get_int("pickups.%s.%s" % [key, field], fallback)


func _read_color(key: String) -> Color:
	var values := ConfigUtil.get_float_array("pickups.%s.color" % key, [])
	if values.size() < 4:
		return pickup_color
	return Color(float(values[0]), float(values[1]), float(values[2]), float(values[3]))


## 显示文字。模板里的 {value} 会换成效果量 —— 这样改了配置里的数值，
## 掉落物上的字会自动跟着变，不会出现"字写 +20、实际回 30"的脱钩。
func _label_text(key: String) -> String:
	var template := ConfigUtil.get_string("pickups.%s.label" % key, key)
	if not template.contains("{value}"):
		return template
	var value_text := ""
	match key:
		"health":
			value_text = "%d" % roundi(_config_float(key, "heal", 20.0))
		"ammo":
			value_text = "%d" % _config_int(key, "ammo", 60)
	return template.replace("{value}", value_text)


# ---------------------------------------------------------------- 外观

func apply_appearance() -> void:
	var key := _config_key()
	var display_color := _read_color(key)
	var core_material := core.material_override.duplicate() as StandardMaterial3D
	core_material.albedo_color = Color.WHITE
	core_material.emission = display_color
	core.material_override = core_material
	var aura_material := aura.material_override.duplicate() as StandardMaterial3D
	aura_material.albedo_color = Color(display_color.r, display_color.g, display_color.b, 0.3)
	aura_material.emission = display_color
	aura.material_override = aura_material
	glow.light_color = display_color
	label.modulate = display_color
	label.text = _label_text(key)


# ---------------------------------------------------------------- 拾取

func on_body_entered(body: Node3D) -> void:
	if consumed or not body.is_in_group("player"):
		return
	if _apply_to(body):
		consumed = true
		queue_free()


## 返回 true 表示拾取生效、掉落物应被消耗（见文件头的【拾取契约】）。
func _apply_to(body: Node3D) -> bool:
	var key := _config_key()
	match pickup_type:
		PickupType.HEALTH:
			if body.has_method("try_heal"):
				return bool(body.call("try_heal", _config_float(key, "heal", 20.0)))
			return false
		PickupType.AMMO:
			if body.has_method("try_take_ammo"):
				return bool(body.call(
					"try_take_ammo",
					_config_int(key, "ammo", 60),
					_config_int(key, "sniper_ammo", 6)
				))
			return false
		_:
			# 三种升级模块：由配置里的 upgrade 字段决定升哪一项。
			var module := ConfigUtil.get_string("pickups.%s.upgrade" % key, "")
			if module.is_empty() or not body.has_method("apply_weapon_module"):
				return false
			return bool(body.call("apply_weapon_module", module))
