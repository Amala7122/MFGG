extends SceneTree

const LabScene := preload("res://prototypes/visual/painterly/painterly_style_lab.tscn")
const Geometry := preload("res://scripts/lowpoly_mesh.gd")
const ArtistPresets := preload("res://prototypes/visual/painterly/artist_presets.gd")
const StylizedGeometry := preload("res://prototypes/visual/painterly/stylized_geometry.gd")
var failures := 0

func _initialize() -> void:
	_run.call_deferred()

func check(condition: bool, description: String) -> void:
	if not condition:
		failures += 1
		push_error(description)

func _run() -> void:
	for size: Vector3 in [Vector3.ONE, Vector3(8, 0.4, 4), Vector3(0.8, 7, 1), Vector3(15, 2, 0.8), Vector3(2, 3, 4)]:
		for bevel in [0.0, 0.08, 0.12, 0.2]:
			var stone := StylizedGeometry.closed_chamfer(size, bevel)
			check(Geometry.validate_convex_outward(stone).is_empty(), "Dedicated chamfer fronts and normals must agree")
			check(StylizedGeometry.validate_closed_surface(stone).is_empty(), "Dedicated chamfer must pair every edge exactly twice")
	for frame in 12:
		await process_frame
	var original_main: String = ProjectSettings.get_setting("application/run/main_scene")
	var previous_environment := root.world_3d.environment
	var previous_paused := paused
	var flow := root.get_node("GameFlow") as CanvasLayer
	var previous_mode := flow.process_mode
	var previous_visible := flow.visible
	var lab = LabScene.instantiate()
	root.add_child(lab)
	current_scene = lab
	for frame in 8:
		await process_frame
	check(not paused and not flow.visible, "Lab must be unpaused and hide the production menu")
	check(lab.get_node_or_null("WorldEnvironment") == null, "Lab atmosphere must remain independent of production graphics")
	check(lab.get_node_or_null("Ground") == null, "Lab must not trigger the production menu camera")
	check(lab.surface_records.size() > 30, "Composition surfaces must be created")
	check(get_nodes_in_group("players").is_empty(), "Lab must not spawn production players")
	check(get_nodes_in_group("enemies").is_empty(), "Lab must not spawn enemies")
	var stone_count := 0
	for record: Dictionary in lab.surface_records:
		var node := record.node as MeshInstance3D
		check(node.scale.x > 0 and node.scale.y > 0 and node.scale.z > 0, "Negative scales can invert mesh winding")
		if node.mesh is ArrayMesh and not record.ground:
			stone_count += 1
			var errors := Geometry.validate_convex_outward(node.mesh)
			check(errors.is_empty(), "Beveled ruin must be outward-facing: %s" % errors)
		if record.ground:
			var arrays: Array = node.mesh.surface_get_arrays(0)
			var vertices: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
			var normals: PackedVector3Array = arrays[Mesh.ARRAY_NORMAL]
			check(vertices.size() == 72 * 72 * 6, "Meadow topology must be complete")
			for i in range(0, vertices.size(), 6):
				var cross := (vertices[i + 1] - vertices[i]).cross(vertices[i + 2] - vertices[i])
				if cross.dot(normals[i]) >= 0 or normals[i].y < 0.9:
					check(false, "Meadow winding and normals must face up consistently")
					break
	check(stone_count > 10, "Beveled stone checks must cover the whole ruin")
	for record: Dictionary in lab.surface_records:
		for variant_index in record.shape_variants.size():
			var mesh: Mesh = record.shape_variants[variant_index]
			if mesh is ArrayMesh and not record.ground:
				var errors: PackedStringArray = StylizedGeometry.validate_trunk_outward(mesh, (record.base_mesh as CylinderMesh).height, variant_index == 0) if record.kind == 3 else Geometry.validate_convex_outward(mesh)
				check(errors.is_empty(), "Stylized shape winding/normal regression: %s %s" % [(record.node as Node).name, errors])
				var closure := StylizedGeometry.validate_closed_surface(mesh)
				check(closure.is_empty(), "Stylized shape must be watertight: %s (%d invalid edges)" % [record.asset_name, closure.size()])
	check(lab.STYLE_NAMES.size() == 8, "Retained presets plus five artistic directions must be available")
	check(lab.STYLE_NAMES[3].contains("水墨丹青"), "Chinese ink and color must be a first-class preset")
	var original_materials: Array[Material] = []
	lab.set_style(1)
	for record: Dictionary in lab.surface_records:
		original_materials.append((record.node as MeshInstance3D).material_override)
	var original_sky: Material = lab.environment.sky.sky_material
	var original_sun_color: Color = lab.sun.light_color
	var original_sun_energy: float = lab.sun.light_energy
	for index in lab.STYLE_NAMES.size():
		lab.set_style(index)
		check(lab.style_index == index, "Style selector must update")
		for record: Dictionary in lab.surface_records:
			var expected: Material = record.artist if index >= 3 else record.plain if index == 0 else record.painted
			check((record.node as MeshInstance3D).material_override == expected, "Every surface must follow the style switch")
			if index >= 3:
				var preset: Dictionary = ArtistPresets.PRESETS[index - 3]
				check((record.artist as ShaderMaterial).get_shader_parameter("artist_mode") == preset.mode, "Artist stroke algorithm must match the chosen preset")
				check((record.artist as ShaderMaterial).get_shader_parameter("base_color") == Color(preset.palette[record.kind]), "Each material category must use its corresponding palette")
			var node := record.node as MeshInstance3D
			var outline := record.outline as MeshInstance3D
			if index in [3, 7]:
				check(node.mesh == record.shape_variants[0 if index == 3 else 1], "Ink/woodblock must use modeled shape variants, not only recoloring")
				if outline.visible:
					check(outline.mesh == record.contour_variants[0 if index == 3 else 1], "Ink contours must follow the corresponding closed shape hull")
					if node.mesh is ArrayMesh:
						check(outline.mesh.surface_get_arrays(0)[Mesh.ARRAY_VERTEX] == node.mesh.surface_get_arrays(0)[Mesh.ARRAY_VERTEX], "Smoothing outline normals must not move model vertices")
				check(not outline.visible if record.asset_name.begins_with("Grass") else true, "Grass must not receive accidental contours after Godot sibling renaming")
				if record.get("artist_only", false):
					check(node.visible, "Supporting boughs must be visible in shape studies")
			else:
				check(node.mesh == record.base_mesh and node.transform == record.base_transform and not outline.visible, "Switching back must restore the original model and transform")
				if record.get("artist_only", false):
					check(not node.visible, "Shape-study boughs must not alter retained presets")
		for lighting in 3:
			lab.set_lighting(lighting)
			check(lab.flashlight.visible == (lighting == 2), "All artistic directions must support night flashlight")
		lab.set_lighting(0)
	for index in [3, 7]:
		lab.set_style(index)
		var material_before: Material = lab.surface_records[0].node.material_override
		lab.set_shape_studies_enabled(false)
		for record: Dictionary in lab.surface_records:
			check(record.node.mesh == record.base_mesh and record.node.transform == record.base_transform and not record.outline.visible, "Shape A/B toggle must completely restore base geometry")
		check(lab.surface_records[0].node.material_override == material_before, "Shape A/B comparison must not change material or palette")
		lab.set_shape_studies_enabled(true)
	lab.set_style(1)
	check(lab.environment.sky.sky_material == original_sky, "Returning to gouache must restore its original sky material")
	check(lab.sun.light_color == original_sun_color and is_equal_approx(lab.sun.light_energy, original_sun_energy), "Artist atmosphere must not leak into retained gouache")
	check(is_equal_approx(lab.environment.fog_density, 0.004), "Retained fog density must remain unchanged")
	for i in lab.surface_records.size():
		check((lab.surface_records[i].node as MeshInstance3D).material_override == original_materials[i], "Retained materials must not be replaced by artist variants")
	lab.set_brush_strength(0.25)
	for record: Dictionary in lab.surface_records:
		check(is_equal_approx(float((record.painted as ShaderMaterial).get_shader_parameter("brush_strength")), 0.25), "Brush slider must reach every painted surface")
	for index in range(3, 8):
		lab.set_style(index)
		for record: Dictionary in lab.surface_records:
			check(is_equal_approx(float((record.artist as ShaderMaterial).get_shader_parameter("brush_strength")), 0.25), "Brush slider must reach every artist material")
	for index in 3:
		lab.set_lighting(index)
		check(lab.flashlight.visible == (index == 2), "Night flashlight must use a real directional spotlight")
		check(root.world_3d.environment == lab.environment, "Graphics autoload must not overwrite lab atmosphere")
	for index in 4:
		lab.set_view(index)
		check(lab.camera.position.is_finite(), "All reference cameras must be valid")
		check(lab.camera.global_basis.determinant() > 0, "Camera orientation must not be reflected")
	check(ProjectSettings.get_setting("application/run/main_scene") == original_main, "Main scene setting must not change")
	lab.free()
	check(root.world_3d.environment == previous_environment, "Lab must restore the previous atmosphere on exit")
	check(paused == previous_paused, "Lab must restore prior pause state")
	check(flow.process_mode == previous_mode and flow.visible == previous_visible, "Lab must restore the normal menu lifecycle")
	print("PAINTERLY_LAB_TEST: %s" % ("PASS" if failures == 0 else "FAIL (%d)" % failures))
	quit(0 if failures == 0 else 1)
