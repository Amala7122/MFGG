class_name SurfaceGrid
extends RefCounted
## 静态表面高度网格：从上方向下打射线，记录每个格子最高的可站立表面。
## 与 Terrain.height_at 不同，它包含平台、台阶、石头顶面；用于数据场炮灰贴地。
## 目前只负责高度查询；步高/跳跃/飞行的通行判定由使用方按 profile 决定。

const Terrain := preload("res://scripts/terrain_field.gd")

var cell_size := 2.0
var _n := 0
var _origin := Vector2.ZERO
var _heights := PackedFloat32Array()
var ready := false
var build_usec := 0


func build(world: World3D, center: Vector3, radius: float, cell := 2.0) -> void:
	cell_size = maxf(cell, 0.5)
	_n = int(ceil(radius * 2.0 / cell_size)) + 1
	_origin = Vector2(center.x - radius, center.z - radius)
	_heights.resize(_n * _n)
	var started := Time.get_ticks_usec()
	var space := world.direct_space_state
	for iz in _n:
		for ix in _n:
			var x := _origin.x + float(ix) * cell_size
			var z := _origin.y + float(iz) * cell_size
			var from := Vector3(x, 200.0, z)
			var to := Vector3(x, -100.0, z)
			var query := PhysicsRayQueryParameters3D.create(from, to, 1)
			var hit := space.intersect_ray(query)
			var height := Terrain.height_at(x, z)
			if not hit.is_empty():
				height = float(hit.position.y)
			_heights[iz * _n + ix] = height
	ready = true
	build_usec = Time.get_ticks_usec() - started


func height_at(x: float, z: float) -> float:
	if not ready or _n <= 0:
		return Terrain.height_at(x, z)
	var ix := clampi(int(round((x - _origin.x) / cell_size)), 0, _n - 1)
	var iz := clampi(int(round((z - _origin.y) / cell_size)), 0, _n - 1)
	return _heights[iz * _n + ix]


func step_allowed(from_height: float, to_height: float, step_height: float) -> bool:
	return absf(to_height - from_height) <= step_height + 0.001
