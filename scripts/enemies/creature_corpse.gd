extends Node3D
## 演出与残留独立于战斗宿主，回调不保留已死亡敌人。
var linger := 2.0


func begin(visual: Node3D, flash: Node) -> float:
	add_to_group("enemy_death_effect")
	add_to_group("enemy_corpses")
	visual.reparent(self, true)
	flash.reparent(self)
	visual.set_process(true)
	visual.death_finished.connect(_finished, CONNECT_ONE_SHOT)
	return visual.play_death()


func _finished() -> void:
	remove_from_group("enemy_death_effect")
	var timer := Timer.new()
	timer.one_shot = true
	timer.wait_time = maxf(linger, 0.01)
	add_child(timer)
	timer.timeout.connect(queue_free)
	timer.start()
