extends Node3D
## PYROLUX Lite demo: a campfire and a grenade explosion. Space: explosion, E: fire on/off.
## H or ?: help. Every key also has an on-screen button.

const STAGE := preload("res://demo/shared/demo_stage.gd")
const UI := preload("res://demo/shared/demo_ui.gd")
const P3: String = "res://addons/pyrolux_fx/presets/3d/"

var fire: PyroluxFire3D
var cam: Camera3D
var ui: UI
var _t: float = 0.0
var _next: float = 0.8
var _rng: RandomNumberGenerator = RandomNumberGenerator.new()


func _ready() -> void:
	_rng.seed = 5
	var stage: Node3D = STAGE.new()
	add_child(stage)
	stage.call("campfire_base", Vector3(-1.5, 0, 0))
	stage.call("tree", Vector3(-4.0, 0, -3.0), 1.2)
	stage.call("crate", Vector3(3.5, 0, -1.5), 0.9)
	fire = (load(P3 + "fire_campfire.tscn") as PackedScene).instantiate() as PyroluxFire3D
	add_child(fire)
	fire.position = Vector3(-1.5, 0, 0)
	cam = Camera3D.new()
	cam.fov = 60.0
	add_child(cam)
	cam.look_at_from_position(Vector3(0.5, 2.6, 7.5), Vector3(0.5, 0.9, 0.0))
	ui = UI.new()
	add_child(ui)
	ui.set_info("PYROLUX Lite", "Free sample: a campfire and a grenade explosion.", "The full pack adds 38 3D + 11 2D presets: lava, smoke, sparks, burning objects, meteors and more.")
	ui.add_bar_button("Explosion", "Space", _boom)
	ui.add_bar_button("Fire on / off", "E", _toggle_fire)
	ui.add_bar_gap()
	ui.add_bar_button("Help", "H", ui.show_help.bind(false))
	ui.help_heading = "Lite demo"
	ui.help_rows = [
		{"keys": PackedStringArray(["Space"]), "text": "Grenade explosion (one also goes off every few seconds)"},
		{"keys": PackedStringArray(["E"]), "text": "Put the campfire out / light it again"},
		{"keys": PackedStringArray(["H", "?"]), "text": "Show this help again"},
	]
	ui.show_intro_once()


func _unhandled_input(event: InputEvent) -> void:
	var k: InputEventKey = event as InputEventKey
	if k and k.pressed and not k.echo:
		if k.keycode == KEY_SPACE:
			_boom()
		elif k.keycode == KEY_E:
			_toggle_fire()


func _process(delta: float) -> void:
	_t += delta
	if _t >= _next:
		_next = _t + 2.6
		_boom()
	if _t > 4.0 and _t < 4.0 + delta:
		fire.extinguish()
	if _t > 6.0 and _t < 6.0 + delta:
		fire.ignite()


func _toggle_fire() -> void:
	if fire.is_burning():
		fire.extinguish()
	else:
		fire.ignite()


func _boom() -> void:
	Pyrolux.spawn(self, "explosion_grenade", Vector3(_rng.randf_range(1.5, 3.5), 0.0, _rng.randf_range(-0.5, 1.0)))
