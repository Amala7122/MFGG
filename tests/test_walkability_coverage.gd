extends SceneTree
## Static coverage guard: almost every non-blocked cell must be connected, and
## cells under canopy (top surface far above walk surface) must stay walkable.
const Walkability := preload("res://scripts/navigation/walkability_grid.gd")
const Terrain := preload("res://scripts/terrain_field.gd")
const NavDataset := preload("res://scripts/navigation/nav_dataset.gd")
const NAV_PATH := "res://data/navigation/sanctum_nav.json"

var _step_limit := 0.0
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
	_step_limit = float(profile.step_height)
	var grid := Walkability.new()
	_check(grid.load_json(String(nav["walkability"])), "walkability loads")
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
	# 0.76m 身体（直径 1.52m）下，1m 网格里会出现一些身体进不去的窄小袋。
	# 不能再用 0.42m 时代“>99% 全连通”的阈值，否则等于要求宽身体能钻窄缝；
	# 改为：整体连通率、最大孤立块、孤立总数三条一起看，大块断开仍会被抓住。
	_check(ratio > 0.95, "walkable coverage >95%%: %.4f" % ratio)
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
	var largest_pocket := 0
	var pocket_seen := PackedByteArray()
	pocket_seen.resize(total)
	for index in total:
		if grid.blocked[index] != 0 or visited[index] != 0 or pocket_seen[index] != 0:
			continue
		var pocket := PackedInt32Array()
		var pocket_head := 0
		pocket.append(index)
		pocket_seen[index] = 1
		var size := 0
		while pocket_head < pocket.size():
			var current := pocket[pocket_head]
			pocket_head += 1
			size += 1
			var px := current % n
			var pz := int(current / n)
			for direction in [Vector2i(1, 0), Vector2i(-1, 0), Vector2i(0, 1), Vector2i(0, -1)]:
				var nx: int = px + direction.x
				var nz: int = pz + direction.y
				if nx < 0 or nz < 0 or nx >= n or nz >= n:
					continue
				var neighbor: int = nz * n + nx
				if grid.blocked[neighbor] != 0 or visited[neighbor] != 0 \
						or pocket_seen[neighbor] != 0:
					continue
				pocket_seen[neighbor] = 1
				pocket.append(neighbor)
		largest_pocket = maxi(largest_pocket, size)
	_check(unreachable < 1000, "unreachable open cells below 1000: %d" % unreachable)
	_check(largest_pocket < 150, "largest isolated pocket below 150 cells: %d" % largest_pocket)
	_check(canopy_open > 20, "canopy-under cells exist: %d" % canopy_open)
	_check(canopy_reached == canopy_open,
		"all canopy-under cells reachable: %d/%d" % [canopy_reached, canopy_open])
	var summary := "[Walkability coverage] unblocked=%d reached=%d ratio=%.4f " \
		+ "unreachable=%d largest=%d body=%.2f canopy=%d"
	print(summary % [unblocked, reached, ratio, unreachable, largest_pocket,
		grid.body_radius, canopy_open])
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
		if absf(h - previous) > _step_limit + 0.02:
			return false
		previous = h
	return true


func _finish() -> void:
	print("[Walkability coverage] ", "PASS" if _failures == 0 else "FAIL")
	quit(0 if _failures == 0 else 1)
