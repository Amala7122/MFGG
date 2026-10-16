class_name Pyrolux
extends RefCounted
## Global settings and one-line helpers for PYROLUX.
##
##   Pyrolux.spawn(self, "explosion_grenade", hit_position)
##   Pyrolux.quality = Pyrolux.Quality.LOW

enum Quality { LOW, MEDIUM, HIGH }

const PRESET_DIR_3D: String = "res://addons/pyrolux_fx/presets/3d/"
const PRESET_DIR_2D: String = "res://addons/pyrolux_fx/presets/2d/"

## Default quality for every effect whose own quality is set to DEFAULT.
static var quality: Quality = Quality.HIGH
## Wind shared by every effect with use_global_wind on, metres per second.
static var wind: Vector3 = Vector3.ZERO


## Particle count multiplier for a quality level.
static func quality_factor(q: Quality) -> float:
	match q:
		Quality.LOW:
			return 0.4
		Quality.MEDIUM:
			return 0.7
	return 1.0


## Instances a preset (name like "explosion_grenade", or a full res:// path, or a
## PackedScene), adds it to `parent` at `position` and starts it. One-shot effects free
## themselves when they finish. Returns the new node, or null if the preset is missing.
static func spawn(parent: Node, preset: Variant, position: Variant = null) -> Node:
	var scene: PackedScene = null
	if preset is PackedScene:
		scene = preset
	elif preset is String or preset is StringName:
		var path: String = str(preset)
		if not path.begins_with("res://"):
			var dir: String = PRESET_DIR_2D if parent is CanvasItem else PRESET_DIR_3D
			path = dir + path + ".tscn"
		if ResourceLoader.exists(path):
			scene = load(path) as PackedScene
	if scene == null or parent == null:
		push_warning("Pyrolux.spawn: preset not found: %s" % str(preset))
		return null
	var node: Node = scene.instantiate()
	if node is PyroluxEffect3D:
		var e3: PyroluxEffect3D = node
		e3.free_when_done = true
	elif node is PyroluxEffect2D:
		var e2: PyroluxEffect2D = node
		e2.free_when_done = true
	parent.add_child(node)
	if position is Vector3 and node is Node3D:
		var n3: Node3D = node
		n3.global_position = position
	elif position is Vector2 and node is Node2D:
		var n2: Node2D = node
		n2.global_position = position
	if node.has_method(&"trigger"):
		node.call(&"trigger")
	return node
