extends SceneTree
## Guard the offline walkability bake: it must load without rebuilding and cover
## the full 120m sanctum extent at 1m resolution.
const Walkability := preload("res://scripts/navigation/walkability_grid.gd")
const NavDataset := preload("res://scripts/navigation/nav_dataset.gd")
const NAV_PATH := "res://data/navigation/sanctum_nav.json"
var _failures := 0


func _initialize() -> void:
	call_deferred("_run")


func _check(ok: bool, text: String) -> void:
	if not ok:
		_failures += 1
		push_error(text)


func _run() -> void:
	var nav := NavDataset.load_file(NAV_PATH)
	var profile = NavDataset.load_profile(nav)
	var grid := Walkability.new()
	var loaded := grid.load_json(String(nav["walkability"]))
	_check(loaded, "walkability bake file loads")
	var expected_n := int(round(float(nav.grid.half_extent) * 2.0
		/ float(nav.grid.cell_size))) + 1
	_check(grid.n == expected_n, "walkability covers nav extent: n=%d expected=%d" % [
		grid.n, expected_n])
	# 地图尺寸只有一个来源：nav.grid.half_extent 必须等于 arena 配置的 extent。
	var config = JSON.parse_string(FileAccess.get_file_as_string(
		"res://data/game_config.json"))
	var arena_id := String(nav.get("id", ""))
	var arena_extent := float(config["arenas"]["definitions"][arena_id]["extent"])
	_check(is_equal_approx(float(nav.grid.half_extent), arena_extent),
		"nav extent matches arena config: %.1f vs %.1f" % [
			float(nav.grid.half_extent), arena_extent])
	_check(is_equal_approx(grid.cell_size, float(nav.grid.cell_size)),
		"walkability cell size matches nav data")
	_check(grid.hit_count > 20000, "walkability has real geometry hits: %d" % grid.hit_count)
	_check(grid.build_usec == 0, "load does not rebuild the grid")
	_check(grid.clearance.size() == grid.n * grid.n, "clearance field covers the grid")
	_check(is_equal_approx(grid.body_radius, profile.radius),
		"bake body radius matches fodder profile: %.2f vs %.2f" % [
			grid.body_radius, profile.radius])
	_check(is_equal_approx(grid.body_height, profile.body_height),
		"bake body height matches profile: %.2f vs %.2f" % [
			grid.body_height, profile.body_height])
	_check(is_equal_approx(grid.body_lift, profile.sweep_lift) \
		and is_equal_approx(grid.body_clearance, profile.foot_clearance),
		"bake lift/clearance match profile")
	var blocked_cells := 0
	var min_open_clearance := INF
	for index in grid.n * grid.n:
		if grid.blocked[index] != 0:
			blocked_cells += 1
		else:
			min_open_clearance = minf(min_open_clearance, grid.clearance[index])
	_check(blocked_cells > 0, "blocker cells exist")
	_check(min_open_clearance > 0.0, "open cells have positive clearance")
	_check(min_open_clearance < 100.0, "clearance is in metres, not sentinel values")
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
