extends RefCounted
## 专用于玩家射线的可见受弹部位；不参与玩家／世界／手雷的实体碰撞。
const LAYER := 16
var areas: Array[Area3D] = []

func add_part(receiver: Node3D, part: MeshInstance3D, region: String) -> Area3D:
	var vertices := PackedVector3Array()
	var unique := {}
	for point: Vector3 in part.mesh.get_faces():
		if not unique.has(point):
			unique[point] = true
			vertices.append(point)
	var hull := ConvexPolygonShape3D.new()
	hull.margin = 0.001 # 射线部位不需要实体移动体的膨胀边距。
	hull.points = vertices
	var area := Area3D.new()
	area.name = "WeaponHitRegion"
	area.collision_layer = LAYER
	area.collision_mask = 0
	area.monitoring = false
	area.monitorable = false
	area.set_meta(&"damage_receiver", receiver.get_instance_id())
	area.set_meta(&"hit_region", region)
	var collision := CollisionShape3D.new()
	collision.shape = hull
	area.add_child(collision)
	part.add_child(area)
	areas.append(area)
	return area

func exclusions() -> Array[RID]:
	var result: Array[RID] = []
	for area in areas:
		if is_instance_valid(area): result.append(area.get_rid())
	return result

func disable() -> void:
	for area in areas:
		if is_instance_valid(area): area.collision_layer = 0
