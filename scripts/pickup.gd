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

const ConfigUtil := preload("res://scripts/game_config.gd")

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
	body_entered.connect(on_body_entered)
	apply_appearance()


func configure(new_type: int) -> void:
	pickup_type = new_type
	if is_node_ready():
		apply_appearance()


func _process(delta: float) -> void:
	hover_time += delta
	var hover_offset := sin(hover_time * 2.8) * 0.14
	position.y += hover_offset - last_hover_offset
	last_hover_offset = hover_offset
	rotate_y(delta * 1.8)
	lifetime -= delta
	if lifetime <= 0.0:
		queue_free()


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
