extends SceneTree
## Guard the offline walkability bake: it must load without rebuilding and cover
## the full 120m sanctum extent at 1m resolution.
const Walkability := preload("res://scripts/navigation/walkability_grid.gd")
const PATH := "res://data/navigation/sanctum_walkability.json"
var _failures := 0


func _initialize() -> void:
	call_deferred("_run")


func _check(ok: bool, text: String) -> void:
	if not ok:
		_failures += 1
		push_error(text)


func _run() -> void:
	var grid := Walkability.new()
	var loaded := grid.load_json(PATH)
	_check(loaded, "walkability bake file loads")
	_check(grid.n == 161, "walkability covers 160m at 1m: n=%d" % grid.n)
	_check(is_equal_approx(grid.cell_size, 1.0), "walkability cell size is 1m")
	_check(grid.hit_count > 20000, "walkability has real geometry hits: %d" % grid.hit_count)
	_check(grid.build_usec == 0, "load does not rebuild the grid")
	var finite := true
	for value in grid.heights:
		if not is_finite(value):
			finite = false
			break
	_check(finite, "all baked heights are finite")
	var samples := 0
	for iz in range(0, grid.n, 7):
		for ix in range(0, grid.n, 7):
			var x := grid.origin.x + float(ix) * grid.cell_size
			var z := grid.origin.y + float(iz) * grid.cell_size
			var height := grid.height_at(x, z)
			samples += 1
			if not is_finite(height):
				_check(false, "sample height is finite at %f,%f" % [x, z])
	_check(samples > 200, "sampled enough walkability cells")
	print("[Walkability bake] samples=%d hit=%d n=%d" % [samples, grid.hit_count, grid.n])
	print("[Walkability bake] ", "PASS" if _failures == 0 else "FAIL")
	quit(0 if _failures == 0 else 1)
