@tool
@icon("res://addons/pyrolux_fx/icons/fire.svg")
class_name PyroluxFire3D
extends PyroluxEffect3D
## Continuous fire: flame tongues, rising flame puffs, embers, smoke and a flickering light.
## One node covers a candle, a torch, a campfire, a bonfire, a wall or ring of fire and
## burning ground, depending on `shape` and `size`.
##
##   $Fire.ignite()      # fade in
##   $Fire.extinguish()  # fade out, then `finished`

enum Shape { POINT, DISK, LINE, RING, BOX }

const TONGUE: Shader = preload("res://addons/pyrolux_fx/shaders/pyrolux_tongue.gdshader")
const PUFF: Shader = preload("res://addons/pyrolux_fx/shaders/pyrolux_puff.gdshader")
const SPARK: Shader = preload("res://addons/pyrolux_fx/shaders/pyrolux_spark.gdshader")

@export_group("Shape")
## Where the flames grow from.
@export var shape: Shape = _default(&"shape", Shape.DISK):
	set(value):
		shape = value
		_rebuild_queued = true
## POINT/DISK/RING: x = radius. LINE: x = half length, z = half depth. BOX: half size.
@export var size: Vector3 = _default(&"size", Vector3(0.35, 0.1, 0.35))

@export_group("Flames")
## Height of the flames in metres.
@export_range(0.0, 20.0, 0.01, "or_greater") var flame_height: float = _default(&"flame_height", 1.2)
## Width of one flame tongue in metres.
@export_range(0.0, 10.0, 0.01, "or_greater") var flame_width: float = _default(&"flame_width", 0.55)
## Number of flame tongues.
@export_range(0, 200, 1) var tongues: int = _default(&"tongues", 7):
	set(value):
		tongues = value
		_rebuild_queued = true
## Number of rising flame puffs.
@export_range(0, 600, 1) var puffs: int = _default(&"puffs", 40):
	set(value):
		puffs = value
		_rebuild_queued = true
## Flicker speed.
@export_range(0.0, 4.0, 0.01) var flicker_speed: float = _default(&"flicker_speed", 1.0)
## How far the flames bend with the wind.
@export_range(0.0, 2.0, 0.01) var lean: float = _default(&"lean", 0.3)
## Temperature; lower values give a darker, redder fire.
@export_range(0.2, 1.5, 0.01) var heat: float = _default(&"heat", 1.0)

@export_group("Embers")
## Number of embers rising from the fire. 0 = none.
@export_range(0, 500, 1) var embers: int = _default(&"embers", 24):
	set(value):
		embers = value
		_rebuild_queued = true
## How high the embers rise, in metres.
@export_range(0.0, 20.0, 0.01, "or_greater") var ember_height: float = _default(&"ember_height", 2.5)

@export_group("Smoke")
## Number of smoke puffs. 0 = none.
@export_range(0, 300, 1) var smoke: int = _default(&"smoke", 16):
	set(value):
		smoke = value
		_rebuild_queued = true
## Smoke density.
@export_range(0.0, 1.0, 0.01) var smoke_opacity: float = _default(&"smoke_opacity", 0.45)
## How high the smoke rises before it fades, in metres.
@export_range(0.0, 50.0, 0.01, "or_greater") var smoke_height: float = _default(&"smoke_height", 4.0)

var _tongue_mat: ShaderMaterial
var _puff_mat: ShaderMaterial
var _ember_mat: ShaderMaterial
var _smoke_mat: ShaderMaterial


func _class_defaults() -> Dictionary:
	return {&"light_energy": 2.5, &"light_range": 7.0, &"fade_time": 0.8}


## Lights the fire (fades in over fade_time).
func ignite() -> void:
	play()


## Puts the fire out (fades out over fade_time, then emits finished).
func extinguish() -> void:
	stop()


func is_burning() -> bool:
	return is_playing()


func _extent() -> Vector3:
	var h: float = maxf(maxf(flame_height, smoke_height if smoke > 0 else 0.0), ember_height if embers > 0 else 0.0)
	return Vector3(size.x + flame_width + 1.0, h + 1.0, size.z + flame_width + 1.0)


func _build() -> void:
	if smoke > 0:
		_smoke_mat = make_layer(PUFF, PyroluxMeshes.quads(count_for(smoke)), 0)
	else:
		_smoke_mat = null
	if puffs > 0:
		_puff_mat = make_layer(PUFF, PyroluxMeshes.quads(count_for(puffs)), 1)
	else:
		_puff_mat = null
	if tongues > 0:
		_tongue_mat = make_layer(TONGUE, PyroluxMeshes.strips(count_for(tongues), 1), 2)
	else:
		_tongue_mat = null
	if embers > 0:
		_ember_mat = make_layer(SPARK, PyroluxMeshes.quads(count_for(embers)), 3)
	else:
		_ember_mat = null


func _tick(_delta: float) -> void:
	var sh: int = int(shape)
	var sz: Vector3 = size
	if shape == Shape.POINT:
		sz = Vector3(flame_width * 0.15, 0.02, flame_width * 0.15)
	var area: float = maxf(sz.x, sz.z)
	if _tongue_mat:
		var m: ShaderMaterial = _tongue_mat
		m.set_shader_parameter("shape", sh)
		m.set_shader_parameter("shape_size", sz)
		m.set_shader_parameter("height", flame_height)
		m.set_shader_parameter("width", flame_width)
		m.set_shader_parameter("speed", flicker_speed)
		m.set_shader_parameter("lean", lean)
		m.set_shader_parameter("heat", heat)
	if _puff_mat:
		var m: ShaderMaterial = _puff_mat
		var life: float = clampf(flame_height / 1.6, 0.35, 2.5)
		m.set_shader_parameter("kind", 0)
		m.set_shader_parameter("shape", 1 if shape == Shape.POINT else sh)
		m.set_shader_parameter("shape_size", Vector3(sz.x * 0.75, flame_height * 0.35, sz.z * 0.75))
		m.set_shader_parameter("spawn_offset", Vector3(0.0, flame_height * 0.3, 0.0))
		m.set_shader_parameter("lifetime", life)
		m.set_shader_parameter("lifetime_var", 0.35)
		m.set_shader_parameter("velocity", Vector3(0.0, flame_height * 0.55 / life, 0.0))
		m.set_shader_parameter("spread", 0.12)
		m.set_shader_parameter("buoyancy", flame_height * 1.2 / (life * life))
		m.set_shader_parameter("drag", 0.0)
		m.set_shader_parameter("turbulence", 0.25 * flame_width)
		m.set_shader_parameter("turb_freq", 1.4)
		m.set_shader_parameter("size_start", flame_width * 0.45)
		m.set_shader_parameter("size_end", flame_width * 0.12)
		m.set_shader_parameter("size_curve", 1.2)
		m.set_shader_parameter("stretch", 0.25)
		m.set_shader_parameter("heat", heat * 0.85)
		m.set_shader_parameter("cool_rate", 0.9)
		m.set_shader_parameter("fade_in", 0.12)
		m.set_shader_parameter("fade_out", 0.65)
		m.set_shader_parameter("noise_speed", 1.2 * flicker_speed)
		m.set_shader_parameter("erosion", 1.1)
		m.set_shader_parameter("flame_opacity", 0.05)
		m.set_shader_parameter("noise_scale", 1.1)
		m.set_shader_parameter("wind_follow", lean * 1.2)
		m.set_shader_parameter("inherit", 1.0)
	if _ember_mat:
		var m: ShaderMaterial = _ember_mat
		var life_e: float = 1.6
		m.set_shader_parameter("kind", 1)
		m.set_shader_parameter("shape", 1)
		m.set_shader_parameter("shape_size", Vector3(area * 0.7 + 0.05, 0.0, area * 0.7 + 0.05))
		m.set_shader_parameter("lifetime", life_e)
		m.set_shader_parameter("lifetime_var", 0.5)
		m.set_shader_parameter("velocity", Vector3(0.0, ember_height / life_e * 0.8, 0.0))
		m.set_shader_parameter("spread", 0.35)
		m.set_shader_parameter("speed_var", 0.5)
		m.set_shader_parameter("drag", 0.6)
		m.set_shader_parameter("gravity", 0.0)
		m.set_shader_parameter("buoyancy", ember_height * 0.35)
		m.set_shader_parameter("turbulence", 0.5)
		m.set_shader_parameter("turb_freq", 1.2)
		m.set_shader_parameter("width", 0.018 + flame_width * 0.012)
		m.set_shader_parameter("stretch", 0.02)
		m.set_shader_parameter("heat", heat)
		m.set_shader_parameter("cool_rate", 0.8)
		m.set_shader_parameter("fade_out", 0.4)
		m.set_shader_parameter("wind_follow", 1.0)
	if _smoke_mat:
		var m: ShaderMaterial = _smoke_mat
		var life_s: float = clampf(smoke_height / 1.2, 1.5, 8.0)
		m.set_shader_parameter("kind", 1)
		m.set_shader_parameter("shape", 1)
		m.set_shader_parameter("shape_size", Vector3(area * 0.5 + 0.05, flame_height * 0.3, area * 0.5 + 0.05))
		m.set_shader_parameter("spawn_offset", Vector3(0.0, flame_height * 0.85, 0.0))
		m.set_shader_parameter("lifetime", life_s)
		m.set_shader_parameter("lifetime_var", 0.3)
		m.set_shader_parameter("velocity", Vector3(0.0, smoke_height / life_s * 0.75, 0.0))
		m.set_shader_parameter("spread", 0.15)
		m.set_shader_parameter("buoyancy", 0.15)
		m.set_shader_parameter("drag", 0.15)
		m.set_shader_parameter("turbulence", 0.3)
		m.set_shader_parameter("turb_freq", 0.6)
		m.set_shader_parameter("size_start", flame_width * 0.9 + area * 0.4)
		m.set_shader_parameter("size_end", flame_width * 2.2 + area * 1.2 + smoke_height * 0.25)
		m.set_shader_parameter("size_curve", 0.7)
		m.set_shader_parameter("smoke_opacity", smoke_opacity)
		m.set_shader_parameter("fade_in", 0.35)
		m.set_shader_parameter("fade_out", 0.55)
		m.set_shader_parameter("erosion", 0.7)
		m.set_shader_parameter("noise_scale", 1.3)
		m.set_shader_parameter("noise_speed", 0.25)
		m.set_shader_parameter("glow_under", 0.6)
		m.set_shader_parameter("spin", 0.3)
		m.set_shader_parameter("wind_follow", 1.0)
	var flick: float = 0.82 + 0.1 * sin(_time * 13.0 * flicker_speed) + 0.08 * sin(_time * 7.3 * flicker_speed + 1.3)
	set_light_level(effective_amount() * flick)
	var l: OmniLight3D = get_light()
	if l:
		l.position = Vector3(0.0, flame_height * 0.45, 0.0)
		l.light_size = 0.0
