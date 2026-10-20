extends "res://tests/test_titan_followup.gd"
## 扇形细长三角形的边框回退不能退到整个三角形中心，覆盖真实危险面。
func _run() -> void:
	await setup("rage")
	for spec: Dictionary in [{"kind":"sector","radius":24.0,"angle":100.0},{"kind":"sector","radius":10.0,"angle":270.0},{"kind":"sector","radius":10.0,"angle":360.0},{"kind":"rect","width":4.3,"length":13.2}]:
		spec["height"] = 4.1
		boss._attack_area.prepare(Transform3D(Basis.IDENTITY,boss.global_position),spec,35.0,1.0)
		boss._attack_area.lock()
		var surface: RefCounted = boss._attack_area.get_surface()
		var edges: PackedVector3Array = surface._edge
		var largest := 0.0
		for i in range(0,edges.size(),6):
			largest = maxf(largest,edges[i+1].distance_to(edges[i+2]))
			largest = maxf(largest,edges[i].distance_to(edges[i+5]))
		check(not edges.is_empty() and largest <= float(surface.WARNING_BORDER_WIDTH)+.001,"边框只内收固定宽度，不出现大块三角填色")
		check(surface.allows(boss.global_position+Vector3(0,-boss.get_stand_height(),-3)),"边框处理不移除实际可达危险区域")
		results.append({"spec":spec,"maximum_border_width":largest,"triangles":edges.size()/3})
	var file := FileAccess.open(Artifacts.ensure_dir("reports","warning_border").path_join("result.json"),FileAccess.WRITE)
	if file == null:
		quit(1)
		return
	file.store_string(JSON.stringify({"trials":results,"failures":failures},"\t"))
	file.close()
	await dispose()
	preload("res://scripts/object_pool.gd").clear_all()
	await preload("res://tools/probes/sparring/sparring_runtime.gd").settle_audio(self)
	quit(1 if failures else 0)
