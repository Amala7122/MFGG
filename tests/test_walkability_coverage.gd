extends SceneTree
## Static coverage guard: almost every non-blocked cell must be connected, and
## cells under canopy (top surface far above walk surface) must stay walkable.
const Walkability := preload("res://scripts/navigation/walkability_grid.gd")
const Terrain := preload("res://scripts/terrain_field.gd")
const PATH := "res://data/navigation/sanctum_walkability.json"
const STEP := 0.7

var _failures := 0


func _initialize() -> void:
	call_deferred("_run")


func _check(ok: bool, text: String) -> void:
	if not ok:
		_failures += 1
		push_error(text)


func _run() -> void:
	var grid := Walkability.new()
	_check(grid.load_json(PATH), "walkability loads")
	if not grid.ready:
		_finish()
		return
	var n: int = grid.n
	var total := n * n
	var unblocked := 0
	for value in grid.blocked:
		if value == 0:
			unblocked += 1
	var start := int(n / 2) * n + int(n / 2)
	if grid.blocked[start] != 0:
		start = _nearest_open(grid, start)
	var visited := PackedByteArray()
	visited.resize(total)
	var queue := PackedInt32Array()
	queue.resize(total)
	var head := 0
	var tail := 0
	queue[tail] = start
	tail += 1
	visited[start] = 1
	var reached := 0
	while head < tail:
		var index := queue[head]
		head += 1
		reached += 1
		var ix := index % n
		var iz := int(index / n)
		for direction in [Vector2i(1, 0), Vector2i(-1, 0), Vector2i(0, 1), Vector2i(0, -1)]:
			var nx: int = ix + direction.x
			var nz: int = iz + direction.y
			if nx < 0 or nz < 0 or nx >= n or nz >= n:
				continue
			var neighbor: int = nz * n + nx
			if visited[neighbor] != 0 or grid.blocked[neighbor] != 0:
				continue
			if not _edge_ok(grid, ix, iz, nx, nz):
				continue
			visited[neighbor] = 1
			queue[tail] = neighbor
			tail += 1
	var ratio := float(reached) / maxf(1.0, float(unblocked))
	_check(ratio > 0.99, "walkable coverage >99%%: %.4f" % ratio)
	var unreachable := 0
	var canopy_open := 0
	var canopy_reached := 0
	for iz in n:
		for ix in n:
			var index := iz * n + ix
			if grid.blocked[index] != 0:
				continue
			if visited[index] == 0:
				unreachable += 1
			if grid.heights[index] - grid.nav_height_at(
					grid.origin.x + float(ix) * grid.cell_size,
					grid.origin.y + float(iz) * grid.cell_size) > 1.0:
				canopy_open += 1
				if visited[index] != 0:
					canopy_reached += 1
	_check(unreachable < 100, "unreachable open cells below 100: %d" % unreachable)
	_check(canopy_open > 20, "canopy-under cells exist: %d" % canopy_open)
	_check(canopy_reached == canopy_open,
		"all canopy-under cells reachable: %d/%d" % [canopy_reached, canopy_open])
	print("[Walkability coverage] unblocked=%d reached=%d ratio=%.4f unreachable=%d canopy=%d" % [
		unblocked, reached, ratio, unreachable, canopy_open])
	_finish()


func _nearest_open(grid, start: int) -> int:
	var n: int = grid.n
	var sx := start % n
	var sz := int(start / n)
	for radius in range(1, 20):
		for dz in range(-radius, radius + 1):
			for dx in range(-radius, radius + 1):
				var ix := sx + dx
				var iz := sz + dz
				if ix < 0 or iz < 0 or ix >= n or iz >= n:
					continue
				var index := iz * n + ix
				if grid.blocked[index] == 0:
					return index
	return start


func _edge_ok(grid, ix: int, iz: int, nx: int, nz: int) -> bool:
	var ax: float = grid.origin.x + float(ix) * grid.cell_size
	var az: float = grid.origin.y + float(iz) * grid.cell_size
	var bx: float = grid.origin.x + float(nx) * grid.cell_size
	var bz: float = grid.origin.y + float(nz) * grid.cell_size
	var steps := 6
	var previous := Terrain.height_at(ax, az)
	for step in range(1, steps + 1):
		var t := float(step) / float(steps)
		var h := Terrain.height_at(lerpf(ax, bx, t), lerpf(az, bz, t))
		if absf(h - previous) > STEP + 0.02:
			return false
		previous = h
	return true


func _finish() -> void:
	print("[Walkability coverage] ", "PASS" if _failures == 0 else "FAIL")
	quit(0 if _failures == 0 else 1)
