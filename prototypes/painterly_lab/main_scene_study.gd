extends Node3D
## Use the same geometry builders as the main scene/editor preview, without
## instantiating combat, weather, menu, or player lifecycle scripts.
const Terrain := preload("res://scripts/terrain_field.gd")
const Map := preload("res://scripts/world_map_builder.gd")
const Decor := preload("res://scripts/world_decor.gd")
const Grass := preload("res://scripts/grass_field.gd")
const Backdrop := preload("res://scripts/backdrop_landmark.gd")

func _ready() -> void:
	for factory in [Terrain, Map, Decor, Grass, Backdrop]:
		var content: Node = factory.new()
		if factory == Backdrop:
			content.name = "Backdrop"
		add_child(content)
	# Backdrop builds deferred; hide its legacy clouds only after that build.
	_hide_legacy_clouds.call_deferred(self)
	# Keep the preview static after generation (including grass LOD/interaction).
	process_mode = Node.PROCESS_MODE_DISABLED

func _hide_legacy_clouds(node: Node) -> void:
	if node.name == "BackdropClouds" and node is Node3D:
		node.visible = false
	for child in node.get_children():
		_hide_legacy_clouds(child)
