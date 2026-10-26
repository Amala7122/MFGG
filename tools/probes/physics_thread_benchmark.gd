extends SceneTree
## 物理独立线程上限基准：只有地形 + N 个 CharacterBody，没有任何射线/导航/武器脚本。
## 用于回答“独立线程到底值不值”，不加载正式圣所场景。
## 用法：-- --bodies=100 --seconds=8

const EXTENT := 40.0
const STEPS := 80

var _manager: Node
var _seconds := 8.0
var _body_count := 100
var _elapsed := 0.0
var _last_report := 0.0
var _started_usec := 0


func _initialize() -> void:
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--bodies="):
			_body_count = clampi(int(arg.trim_prefix("--bodies=")), 1, 2000)
		elif arg.begins_with("--seconds="):
			_seconds = maxf(float(arg.trim_prefix("--seconds=")), 1.0)
	Engine.max_fps = 0
	paused = false
	var manager := BenchManager.new()
	manager.body_count = _body_count
	root.add_child(manager)
	_manager = manager
	_started_usec = Time.get_ticks_usec()
	process_frame.connect(_tick)
	print("[bench] bodies=%d separate_thread=%s" % [
		_body_count, str(ProjectSettings.get_setting("physics/3d/run_on_separate_thread", false))])


func _tick() -> void:
	paused = false
	_elapsed = float(Time.get_ticks_usec() - _started_usec) / 1000000.0
	if _elapsed - _last_report >= 2.0:
		_last_report = _elapsed
		print("[bench] t=%.1f fps=%.1f physics_ms=%.2f process_ms=%.2f ticks=%d loop_us=%.0f body0_y=%.2f phz=%.1f steps=%d phys_frames=%d paused=%s enabled=%s" % [
			_elapsed, Engine.get_frames_per_second(),
			Performance.get_monitor(Performance.TIME_PHYSICS_PROCESS) * 1000.0,
			Performance.get_monitor(Performance.TIME_PROCESS) * 1000.0,
			_manager.physics_ticks, _manager.loop_usec,
			_manager.first_body_y(),
			Engine.physics_ticks_per_second, Engine.max_physics_steps_per_frame,
			Engine.get_physics_frames(), str(paused), str(_manager.is_physics_processing())])
	if _elapsed >= _seconds:
		quit()


class BenchManager extends Node:
	const EXTENT := 40.0
	const STEPS := 80

	var body_count := 100
	var physics_ticks := 0
	var loop_usec := 0
	var _bodies: Array[CharacterBody3D] = []
	var _phase := 0.0

	func _ready() -> void:
		_build_world()
		_spawn_bodies()

	func _build_world() -> void:
		var ground := StaticBody3D.new()
		ground.name = "BenchGround"
		ground.collision_layer = 1
		ground.collision_mask = 0
		add_child(ground)
		var faces := PackedVector3Array()
		faces.resize(STEPS * STEPS * 6)
		var cursor := 0
		for iz in STEPS:
			var z0 := -EXTENT + float(iz) * (EXTENT * 2.0 / float(STEPS))
			var z1 := z0 + EXTENT * 2.0 / float(STEPS)
			for ix in STEPS:
				var x0 := -EXTENT + float(ix) * (EXTENT * 2.0 / float(STEPS))
				var x1 := x0 + EXTENT * 2.0 / float(STEPS)
				var a := Vector3(x0, _height(x0, z0), z0)
				var b := Vector3(x1, _height(x1, z0), z0)
				var c := Vector3(x0, _height(x0, z1), z1)
				var d := Vector3(x1, _height(x1, z1), z1)
				faces[cursor] = a
				faces[cursor + 1] = b
				faces[cursor + 2] = c
				faces[cursor + 3] = b
				faces[cursor + 4] = d
				faces[cursor + 5] = c
				cursor += 6
		var shape := ConcavePolygonShape3D.new()
		shape.set_faces(faces)
		shape.backface_collision = true
		var collision := CollisionShape3D.new()
		collision.shape = shape
		ground.add_child(collision)

		var mesh := ArrayMesh.new()
		var arrays := []
		arrays.resize(Mesh.ARRAY_MAX)
		arrays[Mesh.ARRAY_VERTEX] = faces
		mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
		var material := StandardMaterial3D.new()
		material.albedo_color = Color(0.22, 0.42, 0.18)
		var instance := MeshInstance3D.new()
		instance.mesh = mesh
		instance.material_override = material
		add_child(instance)

		var light := DirectionalLight3D.new()
		light.rotation_degrees = Vector3(-55, -35, 0)
		light.shadow_enabled = false
		add_child(light)
		var camera := Camera3D.new()
		add_child(camera)
		camera.position = Vector3(0, 24, 46)
		camera.look_at(Vector3.ZERO)
		camera.current = true

	func _spawn_bodies() -> void:
		for index in body_count:
			var body := CharacterBody3D.new()
			body.name = "BenchBody%d" % index
			body.collision_layer = 4
			body.collision_mask = 1
			var shape := CollisionShape3D.new()
			var capsule := CapsuleShape3D.new()
			capsule.radius = 0.4
			capsule.height = 1.6
			shape.shape = capsule
			body.add_child(shape)
			var angle := TAU * float(index) / float(maxi(body_count, 1))
			var radius := 6.0 + float(index % 12) * 1.4
			body.position = Vector3(cos(angle) * radius, 2.0, sin(angle) * radius)
			add_child(body)
			_bodies.append(body)

	func _physics_process(delta: float) -> void:
		physics_ticks += 1
		var started := Time.get_ticks_usec()
		_phase += delta
		for index in _bodies.size():
			var body := _bodies[index]
			var to_center := -body.global_position
			to_center.y = 0.0
			var direction := to_center.normalized()
			var tangent := Vector3(-direction.z, 0.0, direction.x) * 0.45
			var desired := (direction + tangent).normalized() * 3.2
			body.velocity.x = move_toward(body.velocity.x, desired.x, delta * 18.0)
			body.velocity.z = move_toward(body.velocity.z, desired.z, delta * 18.0)
			if not body.is_on_floor():
				body.velocity.y -= 24.0 * delta
			else:
				body.velocity.y = 0.0
			body.move_and_slide()
			if body.global_position.length() > 38.0:
				var angle := TAU * float(index) / float(maxi(_bodies.size(), 1))
				var radius := 6.0 + float(index % 12) * 1.4
				body.global_position = Vector3(cos(angle) * radius, 2.0, sin(angle) * radius)
				body.velocity = Vector3.ZERO
		loop_usec = Time.get_ticks_usec() - started

	func first_body_y() -> float:
		return _bodies[0].global_position.y if not _bodies.is_empty() else -999.0

	func _height(x: float, z: float) -> float:
		return sin(x * 0.11) * cos(z * 0.09) * 1.2 + sin((x + z) * 0.05) * 0.6
