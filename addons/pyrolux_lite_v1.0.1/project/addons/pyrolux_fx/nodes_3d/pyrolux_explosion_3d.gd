@tool
@icon("res://addons/pyrolux_fx/icons/explosion.svg")
class_name PyroluxExplosion3D
extends PyroluxEffect3D
## One-shot explosion: flash, fireball that cools into smoke, dust skirt, shock ring,
## sparks, debris, scorch mark and a light pulse. Place the node on the ground for GROUND
## and NAPALM styles.
##
##   $Explosion.explode()
##   $Explosion.explode_at(hit_point)
##   Pyrolux.spawn(self, "explosion_grenade", hit_point)

enum Style { GROUND, AIR, MUSHROOM, NAPALM }

const PUFF: Shader = preload("res://addons/pyrolux_fx/shaders/pyrolux_puff.gdshader")
const SPARK: Shader = preload("res://addons/pyrolux_fx/shaders/pyrolux_spark.gdshader")
const RING: Shader = preload("res://addons/pyrolux_fx/shaders/pyrolux_ring.gdshader")
const SCORCH: Shader = preload("res://addons/pyrolux_fx/shaders/pyrolux_scorch.gdshader")
const TONGUE: Shader = preload("res://addons/pyrolux_fx/shaders/pyrolux_tongue.gdshader")

## GROUND: blast on the floor. AIR: mid-air burst, no dust or scorch. MUSHROOM: big blast
## whose smoke rolls into a mushroom cloud. NAPALM: fuel blast that leaves fire burning.
@export var style: Style = _default(&"style", Style.GROUND):
	set(value):
		style = value
		_rebuild_queued = true
## Radius of the fireball in metres.
@export_range(0.1, 50.0, 0.01, "or_greater") var radius: float = _default(&"radius", 2.0)

@export_group("Parts")
@export_range(0, 400, 1) var fireball: int = _default(&"fireball", 36):
	set(value):
		fireball = value
		_rebuild_queued = true
@export_range(0, 400, 1) var smoke: int = _default(&"smoke", 28):
	set(value):
		smoke = value
		_rebuild_queued = true
## Seconds the smoke lingers.
@export_range(0.5, 30.0, 0.01) var smoke_time: float = _default(&"smoke_time", 4.5)
@export_range(0.0, 1.0, 0.01) var smoke_opacity: float = _default(&"smoke_opacity", 0.85)
@export_range(0, 800, 1) var sparks: int = _default(&"sparks", 60):
	set(value):
		sparks = value
		_rebuild_queued = true
@export_range(0, 400, 1) var debris: int = _default(&"debris", 24):
	set(value):
		debris = value
		_rebuild_queued = true
## Ground dust thrown outward (GROUND, MUSHROOM, NAPALM).
@export var dust: bool = _default(&"dust", true):
	set(value):
		dust = value
		_rebuild_queued = true
## Expanding shock ring.
@export var shockwave: bool = _default(&"shockwave", true):
	set(value):
		shockwave = value
		_rebuild_queued = true
## Burn mark left on the ground.
@export var scorch: bool = _default(&"scorch", true):
	set(value):
		scorch = value
		_rebuild_queued = true
## Seconds the scorch mark stays.
@export_range(0.0, 120.0, 0.1, "or_greater") var scorch_time: float = _default(&"scorch_time", 10.0)
## NAPALM: seconds the fuel keeps burning.
@export_range(0.0, 60.0, 0.1) var burn_time: float = _default(&"burn_time", 6.0)

var _flash_mat: ShaderMaterial
var _fire_mat: ShaderMaterial
var _smoke_mat: ShaderMaterial
var _dust_mat: ShaderMaterial
var _spark_mat: ShaderMaterial
var _debris_mat: ShaderMaterial
var _ring_mat: ShaderMaterial
var _scorch_mat: ShaderMaterial
var _napalm_mat: ShaderMaterial
var _napalm_puff_mat: ShaderMaterial


func _class_defaults() -> Dictionary:
	return {&"light_energy": 10.0, &"light_range": 14.0, &"preview_interval": 5.0}


func is_one_shot() -> bool:
	return true


func get_duration() -> float:
	var d: float = smoke_time + 1.5
	if style == Style.NAPALM:
		d = maxf(d, burn_time + 2.5)
	if style == Style.MUSHROOM:
		d += 2.0
	if scorch and _grounded():
		d = maxf(d, scorch_time)
	return d


## Plays the explosion where the node is.
func explode() -> void:
	trigger()


## Moves the node to `point` and plays the explosion.
func explode_at(point: Vector3) -> void:
	global_position = point
	_last_pos = point
	_velocity = Vector3.ZERO
	trigger()


func _grounded() -> bool:
	return style != Style.AIR


func _extent() -> Vector3:
	var h: float = radius * (6.0 if style == Style.MUSHROOM else 3.5)
	return Vector3(radius * 4.0, h, radius * 4.0)


func _build() -> void:
	var grounded: bool = _grounded()
	_scorch_mat = make_layer(SCORCH, PyroluxMeshes.quads(1), -2) if scorch and grounded else null
	_dust_mat = make_layer(PUFF, PyroluxMeshes.quads(count_for(28)), -1) if dust and grounded else null
	_smoke_mat = make_layer(PUFF, PyroluxMeshes.quads(count_for(smoke)), 0) if smoke > 0 else null
	_napalm_puff_mat = make_layer(PUFF, PyroluxMeshes.quads(count_for(40)), 1) if style == Style.NAPALM else null
	_fire_mat = make_layer(PUFF, PyroluxMeshes.quads(count_for(fireball)), 2) if fireball > 0 else null
	_napalm_mat = make_layer(TONGUE, PyroluxMeshes.strips(count_for(18), 1), 3) if style == Style.NAPALM else null
	_ring_mat = make_layer(RING, PyroluxMeshes.quads(1), 3) if shockwave else null
	_debris_mat = make_layer(SPARK, PyroluxMeshes.quads(count_for(debris)), 3) if debris > 0 else null
	_spark_mat = make_layer(SPARK, PyroluxMeshes.quads(count_for(sparks)), 4) if sparks > 0 else null
	_flash_mat = make_layer(RING, PyroluxMeshes.quads(1), 5)


func _tick(_delta: float) -> void:
	var r: float = radius
	var grounded: bool = _grounded()
	var gy: float = global_position.y if grounded else -100000.0
	var mush: bool = style == Style.MUSHROOM
	if _flash_mat:
		var m: ShaderMaterial = _flash_mat
		m.set_shader_parameter("kind", 2)
		m.set_shader_parameter("facing", 1)
		m.set_shader_parameter("radius", r * 1.6)
		m.set_shader_parameter("duration", 0.22)
		m.set_shader_parameter("intensity", 1.4)
	if _fire_mat:
		var m: ShaderMaterial = _fire_mat
		m.set_shader_parameter("mode", 1)
		m.set_shader_parameter("kind", 2)
		m.set_shader_parameter("shape", 5)
		m.set_shader_parameter("shape_size", Vector3(r * 0.3, 0.0, 0.0))
		m.set_shader_parameter("spawn_offset", Vector3(0.0, r * 0.25 if grounded else 0.0, 0.0))
		m.set_shader_parameter("spread_mode", 1 if grounded else 2)
		m.set_shader_parameter("spread", 0.85)
		m.set_shader_parameter("velocity", Vector3(0.0, r * 4.0, 0.0))
		m.set_shader_parameter("speed_var", 0.45)
		m.set_shader_parameter("drag", 4.0)
		m.set_shader_parameter("buoyancy", r * 0.9)
		m.set_shader_parameter("gravity", 0.0)
		m.set_shader_parameter("turbulence", r * 0.12)
		m.set_shader_parameter("lifetime", 1.9 + (2.5 if mush else 0.0))
		m.set_shader_parameter("lifetime_var", 0.35)
		m.set_shader_parameter("spawn_window", 0.06)
		m.set_shader_parameter("delay", 0.0)
		m.set_shader_parameter("size_start", r * 0.45)
		m.set_shader_parameter("size_end", r * 1.0)
		m.set_shader_parameter("size_curve", 0.35)
		m.set_shader_parameter("size_var", 0.35)
		m.set_shader_parameter("heat", 1.35)
		m.set_shader_parameter("heat_var", 0.3)
		m.set_shader_parameter("cool_rate", 0.45 if mush else 1.5)
		m.set_shader_parameter("smoke_opacity", smoke_opacity)
		m.set_shader_parameter("flame_opacity", 0.65)
		m.set_shader_parameter("fade_in", 0.02)
		m.set_shader_parameter("fade_out", 0.45)
		m.set_shader_parameter("erosion", 0.5)
		m.set_shader_parameter("noise_scale", 1.3)
		m.set_shader_parameter("noise_speed", 0.6)
		m.set_shader_parameter("glow_under", 0.8)
		m.set_shader_parameter("spin", 0.8)
		m.set_shader_parameter("ground_y", gy)
		m.set_shader_parameter("mushroom", 1.0 if mush else 0.0)
		m.set_shader_parameter("mushroom_height", r * 4.5)
		m.set_shader_parameter("mushroom_rise", 1.1)
	if _smoke_mat:
		var m: ShaderMaterial = _smoke_mat
		m.set_shader_parameter("mode", 1)
		m.set_shader_parameter("kind", 1)
		m.set_shader_parameter("shape", 5)
		m.set_shader_parameter("shape_size", Vector3(r * 0.5, 0.0, 0.0))
		m.set_shader_parameter("spawn_offset", Vector3(0.0, r * 0.5 if grounded else 0.0, 0.0))
		m.set_shader_parameter("spread_mode", 1 if grounded else 2)
		m.set_shader_parameter("spread", 0.7)
		m.set_shader_parameter("velocity", Vector3(0.0, r * 1.6, 0.0))
		m.set_shader_parameter("speed_var", 0.5)
		m.set_shader_parameter("drag", 1.2)
		m.set_shader_parameter("buoyancy", r * 0.35)
		m.set_shader_parameter("turbulence", r * 0.1)
		m.set_shader_parameter("lifetime", smoke_time)
		m.set_shader_parameter("lifetime_var", 0.25)
		m.set_shader_parameter("spawn_window", 0.35)
		m.set_shader_parameter("delay", 0.12)
		m.set_shader_parameter("size_start", r * 0.6)
		m.set_shader_parameter("size_end", r * 1.7)
		m.set_shader_parameter("size_curve", 0.5)
		m.set_shader_parameter("smoke_opacity", smoke_opacity * 0.85)
		m.set_shader_parameter("fade_in", 0.08)
		m.set_shader_parameter("fade_out", 0.5)
		m.set_shader_parameter("erosion", 0.55)
		m.set_shader_parameter("noise_scale", 1.1)
		m.set_shader_parameter("noise_speed", 0.25)
		m.set_shader_parameter("glow_under", 0.9)
		m.set_shader_parameter("spin", 0.25)
		m.set_shader_parameter("ground_y", gy)
		m.set_shader_parameter("mushroom", 1.0 if mush else 0.0)
		m.set_shader_parameter("mushroom_height", r * 4.5)
		m.set_shader_parameter("mushroom_rise", 1.3)
	if _dust_mat:
		var m: ShaderMaterial = _dust_mat
		m.set_shader_parameter("mode", 1)
		m.set_shader_parameter("kind", 3)
		m.set_shader_parameter("shape", 3)
		m.set_shader_parameter("shape_size", Vector3(r * 0.4, 0.1, r * 0.2))
		m.set_shader_parameter("spawn_offset", Vector3(0.0, r * 0.15, 0.0))
		m.set_shader_parameter("spread_mode", 3)
		m.set_shader_parameter("spread", 0.35)
		m.set_shader_parameter("velocity", Vector3(0.0, r * 5.0, 0.0))
		m.set_shader_parameter("speed_var", 0.4)
		m.set_shader_parameter("drag", 3.0)
		m.set_shader_parameter("buoyancy", r * 0.15)
		m.set_shader_parameter("turbulence", r * 0.05)
		m.set_shader_parameter("lifetime", smoke_time * 0.7)
		m.set_shader_parameter("lifetime_var", 0.3)
		m.set_shader_parameter("spawn_window", 0.05)
		m.set_shader_parameter("delay", 0.03)
		m.set_shader_parameter("size_start", r * 0.35)
		m.set_shader_parameter("size_end", r * 1.1)
		m.set_shader_parameter("size_curve", 0.45)
		m.set_shader_parameter("smoke_opacity", smoke_opacity * 0.7)
		m.set_shader_parameter("fade_in", 0.05)
		m.set_shader_parameter("fade_out", 0.6)
		m.set_shader_parameter("erosion", 0.6)
		m.set_shader_parameter("glow_under", 0.0)
		m.set_shader_parameter("tint", Color(1.9, 1.6, 1.3, 1.0))
		m.set_shader_parameter("ground_y", gy)
	if _spark_mat:
		var m: ShaderMaterial = _spark_mat
		m.set_shader_parameter("mode", 1)
		m.set_shader_parameter("kind", 0)
		m.set_shader_parameter("shape", 5)
		m.set_shader_parameter("shape_size", Vector3(r * 0.2, 0.0, 0.0))
		m.set_shader_parameter("spawn_offset", Vector3(0.0, r * 0.2 if grounded else 0.0, 0.0))
		m.set_shader_parameter("spread_mode", 1 if grounded else 2)
		m.set_shader_parameter("spread", 0.9)
		m.set_shader_parameter("velocity", Vector3(0.0, 9.0 + r * 3.0, 0.0))
		m.set_shader_parameter("speed_var", 0.6)
		m.set_shader_parameter("drag", 1.4)
		m.set_shader_parameter("gravity", 9.8)
		m.set_shader_parameter("lifetime", 1.3)
		m.set_shader_parameter("lifetime_var", 0.5)
		m.set_shader_parameter("spawn_window", 0.05)
		m.set_shader_parameter("width", 0.035 + r * 0.008)
		m.set_shader_parameter("stretch", 0.045)
		m.set_shader_parameter("heat", 1.2)
		m.set_shader_parameter("cool_rate", 1.0)
		m.set_shader_parameter("bounce", 0.35)
		m.set_shader_parameter("ground_y", gy)
	if _debris_mat:
		var m: ShaderMaterial = _debris_mat
		m.set_shader_parameter("mode", 1)
		m.set_shader_parameter("kind", 2)
		m.set_shader_parameter("shape", 5)
		m.set_shader_parameter("shape_size", Vector3(r * 0.25, 0.0, 0.0))
		m.set_shader_parameter("spawn_offset", Vector3(0.0, r * 0.15 if grounded else 0.0, 0.0))
		m.set_shader_parameter("spread_mode", 1 if grounded else 2)
		m.set_shader_parameter("spread", 0.75)
		m.set_shader_parameter("velocity", Vector3(0.0, 6.0 + r * 2.5, 0.0))
		m.set_shader_parameter("speed_var", 0.55)
		m.set_shader_parameter("drag", 0.6)
		m.set_shader_parameter("gravity", 9.8)
		m.set_shader_parameter("lifetime", 2.4)
		m.set_shader_parameter("lifetime_var", 0.3)
		m.set_shader_parameter("spawn_window", 0.04)
		m.set_shader_parameter("width", 0.06 + r * 0.02)
		m.set_shader_parameter("heat", 0.9)
		m.set_shader_parameter("cool_rate", 0.9)
		m.set_shader_parameter("bounce", 0.25)
		m.set_shader_parameter("fade_out", 0.2)
		m.set_shader_parameter("ground_y", gy)
	if _ring_mat:
		var m: ShaderMaterial = _ring_mat
		m.set_shader_parameter("kind", 0)
		m.set_shader_parameter("facing", 0 if grounded else 1)
		m.set_shader_parameter("radius", r * 4.0)
		m.set_shader_parameter("expand", 3.5)
		m.set_shader_parameter("duration", 0.55)
		m.set_shader_parameter("thickness", r * 0.12)
		m.set_shader_parameter("intensity", 0.5)
	if _scorch_mat:
		var m: ShaderMaterial = _scorch_mat
		m.set_shader_parameter("radius", r * 1.8)
		m.set_shader_parameter("lifetime", scorch_time)
		m.set_shader_parameter("fade_time", minf(3.0, scorch_time * 0.4))
		m.set_shader_parameter("ember_cool", 3.0 + (burn_time if style == Style.NAPALM else 0.0))
	if _napalm_mat:
		var m: ShaderMaterial = _napalm_mat
		m.set_shader_parameter("shape", 1)
		m.set_shader_parameter("shape_size", Vector3(r * 1.3, 0.0, r * 1.3))
		m.set_shader_parameter("height", r * 0.9)
		m.set_shader_parameter("width", r * 0.5)
		m.set_shader_parameter("burn_time", burn_time)
		m.set_shader_parameter("heat", 0.95)
	if _napalm_puff_mat:
		var m: ShaderMaterial = _napalm_puff_mat
		m.set_shader_parameter("mode", 0)
		m.set_shader_parameter("kind", 1)
		m.set_shader_parameter("shape", 1)
		m.set_shader_parameter("shape_size", Vector3(r * 1.1, 0.0, r * 1.1))
		m.set_shader_parameter("spawn_offset", Vector3(0.0, r * 0.8, 0.0))
		m.set_shader_parameter("velocity", Vector3(0.0, r * 0.9, 0.0))
		m.set_shader_parameter("lifetime", 3.0)
		m.set_shader_parameter("size_start", r * 0.6)
		m.set_shader_parameter("size_end", r * 1.6)
		m.set_shader_parameter("smoke_opacity", 0.75)
		m.set_shader_parameter("glow_under", 0.9)
		m.set_shader_parameter("noise_speed", 0.3)
		var a: float = get_age()
		var on: float = 0.0
		if a >= 0.0:
			on = smoothstep(0.4, 1.2, a) * (1.0 - smoothstep(burn_time * 0.7, burn_time + 1.0, a))
		m.set_shader_parameter("level", on)
	_update_light()


func _push_common() -> void:
	super._push_common()
	# The napalm smoke layer loops with its own level; keep it after the common update.
	if _napalm_puff_mat:
		var a: float = get_age()
		var on: float = 0.0
		if a >= 0.0:
			on = smoothstep(0.4, 1.2, a) * (1.0 - smoothstep(burn_time * 0.7, burn_time + 1.0, a))
		_napalm_puff_mat.set_shader_parameter("level", on)


func _update_light() -> void:
	var a: float = get_age()
	if a < 0.0:
		set_light_level(0.0)
		return
	var l: float = exp(-a * 3.5) * smoothstep(0.0, 0.03, a) + 0.12 * exp(-a * 0.8)
	if style == Style.NAPALM:
		l += 0.35 * smoothstep(0.3, 1.0, a) * (1.0 - smoothstep(burn_time * 0.7, burn_time + 1.0, a)) * (0.85 + 0.15 * sin(a * 17.0))
	set_light_level(l * amount)
	var lt: OmniLight3D = get_light()
	if lt:
		lt.position = Vector3(0.0, radius * (0.8 if _grounded() else 0.0), 0.0)
