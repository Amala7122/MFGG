extends SceneTree
const Preparation := preload("res://scripts/combat_resource_preparation.gd")
func _initialize() -> void:
	call_deferred("_run")
func _run() -> void:
	seed(79191)
	var expected := randf()
	seed(79191)
	var rng := RandomNumberGenerator.new()
	print("rng_constructor=", randf() == expected, " rng=", rng.seed)
	seed(79191)
	var particles := CPUParticles3D.new()
	print("native_particles_constructor=", randf() == expected)
	particles.free()
	seed(79191)
	var profiles := Preparation._profiles("res://scenes/sanctum_main.tscn")
	print("profiles=", randf() == expected)
	for profile: String in profiles:
		seed(79191)
		var visual := Preparation._visual(profile, profiles[profile])
		print(profile, " constructor=", randf() == expected)
		visual.free()
	quit()
