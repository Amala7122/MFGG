extends SceneTree
## Static coverage audit for the baked 1m walkability grid.
const Walkability := preload("res://scripts/navigation/walkability_grid.gd")
const Terrain := preload("res://scripts/terrain_field.gd")
const PATH := "res://data/navigation/sanctum_walkability.json"
const STEP := 0.7


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	var grid := Walkability.new()
	if not grid.load_json(PATH):
		print("[coverage] load failed")
		quit(1)
		return
	var n := grid.n
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
	print("[coverage] unblocked=%d reached=%d ratio=%.3f" % [
		unblocked, reached, float(reached) / maxf(1.0, float(unblocked))])
	# Count unreachable open cells and print a few clusters.
	var unreachable := 0
	var min_x := n
	var max_x := 0
	var min_z := n
	var max_z := 0
	for iz in n:
		for ix in n:
			var index := iz * n + ix
			if grid.blocked[index] == 0 and visited[index] == 0:
				unreachable += 1
				min_x = mini(min_x, ix)
				max_x = maxi(max_x, ix)
				min_z = mini(min_z, iz)
				max_z = maxi(max_z, iz)
	print("[coverage] unreachable_open=%d bounds=(%d,%d)-(%d,%d)" % [
		unreachable, min_x, min_z, max_x, max_z])
	quit(0)


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
