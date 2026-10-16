@tool
@icon("res://addons/pyrolux_fx/icons/effect.svg")
class_name PyroluxEffect2D
extends Node2D
## Base class for PYROLUX 2D effects (side view). Same timing, fading and one-shot rules as
## the 3D effects. Units are pixels; +y is down. Geometry lives in internal children with
## their own canvas rect, so it is never culled and never saved.

signal finished

enum QualitySetting { DEFAULT, LOW, MEDIUM, HIGH }

@export_range(0.0, 1.0, 0.01) var amount: float = _default(&"amount", 1.0)
@export_range(0.0, 4.0, 0.01) var time_scale: float = _default(&"time_scale", 1.0)
@export var autoplay: bool = _default(&"autoplay", true)
@export_range(0.0, 30.0, 0.01, "or_greater") var fade_time: float = _default(&"fade_time", 0.6)
@export var preview_in_editor: bool = true
@export_range(0.5, 20.0, 0.1) var preview_interval: float = _default(&"preview_interval", 3.0)
@export var random_seed: int = 0
@export var palette: PyroluxPalette = _default(&"palette", null):
	set(value):
		palette = value
		_palette_dirty = true
@export var quality: QualitySetting = QualitySetting.DEFAULT:
	set(value):
		quality = value
		_rebuild_queued = true

@export_group("Pixel Art")
## Snaps particles to a pixel grid, hardens edges and reduces the colours to bands.
@export var pixel_mode: bool = _default(&"pixel_mode", false)
@export_range(1.0, 16.0, 1.0) var pixel_size: float = _default(&"pixel_size", 3.0)
## Number of colour steps in pixel mode.
@export_range(2, 12, 1) var color_steps: int = 5

@export_group("Wind")
## Add Pyrolux.wind (x only) converted with pixels_per_metre.
@export var use_global_wind: bool = true
@export_range(1.0, 500.0, 0.1) var pixels_per_metre: float = 64.0
## Extra wind in pixels per second.
@export var wind: Vector2 = _default(&"wind", Vector2.ZERO)

@export_group("Light")
## Adds a PointLight2D (only affects lit canvas items).
@export var light_enabled: bool = _default(&"light_enabled", false):
	set(value):
		light_enabled = value
		_rebuild_queued = true
@export_range(0.0, 16.0, 0.01) var light_energy: float = _default(&"light_energy", 1.2)
@export_range(1.0, 4000.0, 1.0) var light_radius: float = _default(&"light_radius", 300.0)

var free_when_done: bool = false
var rng: RandomNumberGenerator = RandomNumberGenerator.new()
var seed_value: int = 1
var _time: float = 0.0
var _level: float = 0.0
var _running: bool = false
var _finished_emitted: bool = true
var _burst_age: float = -1.0
var _preview_clock: float = 0.0
var _layers: Array[MeshInstance2D] = []
var _layer_materials: Array[ShaderMaterial] = []
var _light: PointLight2D
var _last_pos: Vector2 = Vector2.ZERO
var _velocity: Vector2 = Vector2.ZERO
var _rebuild_queued: bool = false
var _palette_dirty: bool = true
var _fallback_palette: PyroluxPalette

static var _light_texture: GradientTexture2D


func _ready() -> void:
	if random_seed != 0:
		rng.seed = random_seed
	else:
		rng.randomize()
	seed_value = rng.randi_range(1, 1 << 30)
	_last_pos = global_position
	_rebuild()
	if Engine.is_editor_hint():
		if preview_in_editor:
			_start_preview()
	elif autoplay:
		if is_one_shot():
			trigger()
		else:
			_start_preview()
	_process(0.0)


func _process(delta: float) -> void:
	if _rebuild_queued:
		_rebuild()
	if Engine.is_editor_hint():
		_palette_dirty = true
	if Engine.is_editor_hint() and not preview_in_editor:
		for mi in _layers:
			mi.visible = false
		return
	var dt: float = delta * time_scale
	_time = fmod(_time + dt, 3600.0)
	if delta > 0.0:
		var pos: Vector2 = global_position
		_velocity = _velocity.lerp((pos - _last_pos) / delta, clampf(delta * 8.0, 0.0, 1.0))
		_last_pos = pos
	if is_one_shot():
		if _burst_age >= 0.0:
			_burst_age += dt
			_level = 1.0
			if _burst_age > get_duration():
				_burst_age = -1.0
				_level = 0.0
				if not _finished_emitted:
					_finished_emitted = true
					finished.emit()
					if free_when_done and not Engine.is_editor_hint():
						queue_free()
		if Engine.is_editor_hint() and preview_in_editor:
			_preview_clock += delta
			if _preview_clock >= maxf(preview_interval, get_duration() * 0.5):
				trigger()
	else:
		var target: float = 1.0 if _running else 0.0
		_level = move_toward(_level, target, delta / maxf(fade_time, 0.001)) if fade_time > 0.0 else target
		if not _running and _level <= 0.0 and not _finished_emitted:
			_finished_emitted = true
			finished.emit()
			if free_when_done and not Engine.is_editor_hint():
				queue_free()
	var on: bool = (_burst_age >= 0.0 and amount > 0.0) if is_one_shot() else effective_amount() > 0.0005
	for mi in _layers:
		mi.visible = on and mi.get_meta(&"pyrolux_off", false) != true
	_tick(dt)
	_push_common()


func play() -> void:
	if is_one_shot():
		trigger()
		return
	_running = true
	_finished_emitted = false


func stop() -> void:
	_running = false


func is_playing() -> bool:
	return _burst_age >= 0.0 if is_one_shot() else _running


func trigger() -> void:
	_burst_age = 0.0
	_level = 1.0
	_finished_emitted = false
	_preview_clock = 0.0
	_on_trigger()


func set_amount_smooth(value: float, seconds: float) -> void:
	var tw: Tween = create_tween()
	tw.tween_property(self, "amount", clampf(value, 0.0, 1.0), maxf(seconds, 0.0))


func effective_amount() -> float:
	return clampf(amount, 0.0, 1.0) * _level


func world_scale() -> float:
	var t: Transform2D = global_transform if is_inside_tree() else transform
	return (t.get_scale().x + t.get_scale().y) * 0.5


## Wind in pixels per second.
func get_wind() -> Vector2:
	var w: Vector2 = wind
	if use_global_wind:
		w += Vector2(Pyrolux.wind.x, 0.0) * pixels_per_metre
	return w * world_scale()


func get_age() -> float:
	return _burst_age


func get_palette() -> PyroluxPalette:
	if palette:
		return palette
	if _fallback_palette == null:
		_fallback_palette = PyroluxPalette.new()
	return _fallback_palette


func quality_factor() -> float:
	match quality:
		QualitySetting.LOW:
			return Pyrolux.quality_factor(Pyrolux.Quality.LOW)
		QualitySetting.MEDIUM:
			return Pyrolux.quality_factor(Pyrolux.Quality.MEDIUM)
		QualitySetting.HIGH:
			return Pyrolux.quality_factor(Pyrolux.Quality.HIGH)
	return Pyrolux.quality_factor(Pyrolux.quality)


func count_for(base: int) -> int:
	return maxi(1, roundi(float(base) * quality_factor()))


func rebuild() -> void:
	_rebuild_queued = true


func is_one_shot() -> bool:
	return false


func get_duration() -> float:
	return 2.0


func _class_defaults() -> Dictionary:
	return {}


func _default(property: StringName, fallback: Variant) -> Variant:
	return _class_defaults().get(property, fallback)


func _property_can_revert(property: StringName) -> bool:
	return _class_defaults().has(property)


func _property_get_revert(property: StringName) -> Variant:
	return _class_defaults().get(property)


func _build() -> void:
	pass


func _tick(_delta: float) -> void:
	pass


func _on_trigger() -> void:
	pass


func make_layer(shader: Shader, mesh: Mesh, z: int = 0) -> ShaderMaterial:
	var mi: MeshInstance2D = MeshInstance2D.new()
	mi.mesh = mesh
	mi.top_level = true
	mi.z_index = z
	mi.z_as_relative = true
	var mat: ShaderMaterial = ShaderMaterial.new()
	mat.shader = shader
	mat.set_shader_parameter("seed", seed_value + _layers.size() * 7919)
	mi.material = mat
	add_child(mi, false, Node.INTERNAL_MODE_BACK)
	mi.global_transform = Transform2D.IDENTITY
	RenderingServer.canvas_item_set_custom_rect(mi.get_canvas_item(), true, Rect2(-1.0e7, -1.0e7, 2.0e7, 2.0e7))
	_layers.append(mi)
	_layer_materials.append(mat)
	return mat


func set_layer_enabled(mat: ShaderMaterial, on: bool) -> void:
	var i: int = _layer_materials.find(mat)
	if i >= 0:
		_layers[i].set_meta(&"pyrolux_off", not on)
		if not on:
			_layers[i].visible = false


func set_light_level(level: float, offset: Vector2 = Vector2.ZERO) -> void:
	if _light == null:
		return
	_light.energy = light_energy * maxf(level, 0.0)
	_light.texture_scale = light_radius / 128.0
	_light.position = offset
	_light.visible = level > 0.001
	_light.color = get_palette().light


func _rebuild() -> void:
	_rebuild_queued = false
	for mi in _layers:
		remove_child(mi)
		mi.queue_free()
	_layers.clear()
	_layer_materials.clear()
	if _light:
		remove_child(_light)
		_light.queue_free()
		_light = null
	if light_enabled:
		_light = PointLight2D.new()
		_light.texture = _get_light_texture()
		add_child(_light, false, Node.INTERNAL_MODE_BACK)
	_build()
	_palette_dirty = true


func _start_preview() -> void:
	if is_one_shot():
		trigger()
	else:
		_running = true
		_level = 1.0
		_finished_emitted = false


static func _get_light_texture() -> GradientTexture2D:
	if _light_texture == null:
		var g: Gradient = Gradient.new()
		g.set_color(0, Color(1, 1, 1, 1))
		g.set_color(1, Color(1, 1, 1, 0))
		_light_texture = GradientTexture2D.new()
		_light_texture.gradient = g
		_light_texture.fill = GradientTexture2D.FILL_RADIAL
		_light_texture.fill_from = Vector2(0.5, 0.5)
		_light_texture.fill_to = Vector2(1.0, 0.5)
		_light_texture.width = 256
		_light_texture.height = 256
	return _light_texture


func _push_common() -> void:
	var t: Transform2D = global_transform
	var pal: PyroluxPalette = get_palette()
	var w: Vector2 = get_wind()
	var px: float = pixel_size * world_scale() if pixel_mode else 0.0
	for m in _layer_materials:
		m.set_shader_parameter("time", _time)
		m.set_shader_parameter("level", effective_amount())
		m.set_shader_parameter("age", _burst_age)
		m.set_shader_parameter("em_origin", t.origin)
		m.set_shader_parameter("em_x", t.x)
		m.set_shader_parameter("em_y", t.y)
		m.set_shader_parameter("em_velocity", _velocity)
		m.set_shader_parameter("wind", w)
		m.set_shader_parameter("pixel_size", px)
		m.set_shader_parameter("color_steps", color_steps)
		if _palette_dirty:
			pal.apply_to(m)
	_palette_dirty = false
