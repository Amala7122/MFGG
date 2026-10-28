extends SceneTree
## 固定庭院回归：玩家在围墙外 (27.9,-35.9)，10 只炮灰从墙内 x=19.0..25.1 / z=-32.5 出发。
##
## 守住第 11 节的四条合同：
##   1. 不得用运行期瞬移到达（单步位移 > 0.5m 即失败；unstuck_count 运行期不得增加）；
##   2. 不得借“可达但隔墙”的槽位把整群吸到墙根（必须从真实开口绕出去）；
##   3. 不得钻到地形以下（> 0.08m 即失败）；
##   4. 人群必须真的离开围墙并接近玩家（墙内 0 只、10 只里至少 7 只进入 5m）。
##
## 只跑正式场景与烘焙表，不改地图/波次/参数。
## 说明：不把“站在 blocked 格里”当失败——1m 通行格是按格心 0.32m 探针烘的，
## 贴墙排队时格心可以落在 blocked 格，而身体并没有穿墙；穿墙由单步位移和地形穿透守。

const MainScene := preload("res://scenes/sanctum_main.tscn")
const Fodder := preload("res://scripts/prototypes/fodder_field.gd")
const NavDataset := preload("res://scripts/navigation/nav_dataset.gd")
const NAV_PATH := "res://data/navigation/sanctum_nav.json"
const Terrain := preload("res://scripts/terrain_field.gd")

const PLAYER_POINT := Vector2(27.9, -35.9)
const SPAWN_ORIGIN := Vector2(19.0, -32.5)
const SPAWN_STEP := 0.68
const AMOUNT := 10
const STEPS := 720
const JUMP_LIMIT := 0.5
const NEAR_DISTANCE := 5.0
const MIN_NEAR := 7
const PENETRATION_LIMIT := 0.08
const INTERIOR := Rect2(18.5, -33.5, 9.0, 9.5)

var _failures := 0


func _initialize() -> void:
	call_deferred("_run")


func _check(ok: bool, text: String) -> void:
	if not ok:
		_failures += 1
		push_error(text)


func _run() -> void:
	paused = false
	var menu := MainScene.instantiate()
	root.add_child(menu)
	current_scene = menu
	for _frame in 3:
		await process_frame
	var game_flow := root.get_node_or_null("GameFlow")
	if game_flow == null:
		_check(false, "GameFlow exists")
		_finish()
		return
	game_flow.call("start_run")
	for _frame in 360:
		await process_frame
		if current_scene != null and current_scene != menu \
				and not get_nodes_in_group("player").is_empty() \
				and not bool(game_flow.get("_preparing_run")):
			break
	var scene := current_scene as Node3D
	if scene == null or get_nodes_in_group("player").is_empty():
		_check(false, "formal scene and player ready")
		_finish()
		return
	var player := get_nodes_in_group("player")[0] as Node3D
	player.set_meta(&"experiment_invincible", true)
	player.process_mode = Node.PROCESS_MODE_DISABLED
	for director_name in ["WaveDirector", "SurvivalDirector"]:
		var director := scene.find_child(director_name, true, false)
		if director != null:
			director.set_process(false)
			director.set_physics_process(false)
	for enemy in get_nodes_in_group("enemies"):
		enemy.queue_free()
	for _frame in 2:
		await process_frame

	player.global_position = Vector3(PLAYER_POINT.x,
		Terrain.height_at(PLAYER_POINT.x, PLAYER_POINT.y) + 0.1, PLAYER_POINT.y)
	var field := Fodder.new()
	field.top_level = true
	scene.add_child(field)
	var nav := NavDataset.load_file(NAV_PATH)
	field.setup(player, null, AMOUNT, player.global_position,
		NavDataset.load_profile(nav), nav)
	var waited := 0
	while not field.is_surface_ready() and waited < 240:
		await physics_frame
		waited += 1
	while not bool(field.get("_flow_ready")) and waited < 900:
		await physics_frame
		waited += 1
	_check(field.is_surface_ready() and bool(field.get("_flow_ready")), "surface and flow ready")
	if not field.is_surface_ready():
		field.queue_free()
		_finish()
		return

	var surface = field.get("_surface")
	var body_offset: float = field.get("BODY_OFFSET")
	for index in AMOUNT:
		var x := SPAWN_ORIGIN.x + float(index) * SPAWN_STEP
		var z := SPAWN_ORIGIN.y
		var ground: float = surface.nav_height_at(x, z)
		field._positions[index] = Vector3(x, ground + body_offset, z)
		field._last_positions[index] = field._positions[index]
		field._ground_heights[index] = ground
		field._velocity[index] = Vector3.ZERO
		field._state[index] = 0
		field._stuck_count[index] = 0
		field._timer[index] = 0.0
	var initial_unstuck: int = field.unstuck_count

	var prior: PackedVector3Array = field._positions.duplicate()
	var jump_count := 0
	var max_jump := 0.0
	var penetration := 0.0
	for _step in STEPS:
		await physics_frame
		for index in AMOUNT:
			var position: Vector3 = field._positions[index]
			var moved: float = position.distance_to(prior[index])
			if moved > JUMP_LIMIT:
				jump_count += 1
				max_jump = maxf(max_jump, moved)
			penetration = maxf(penetration,
				Terrain.height_at(position.x, position.z) + body_offset - position.y)
		prior = field._positions.duplicate()

	var near := 0
	var interior := 0
	for position in field.live_positions():
		if Vector2(position.x - PLAYER_POINT.x, position.z - PLAYER_POINT.y).length() \
				<= NEAR_DISTANCE:
			near += 1
		if INTERIOR.has_point(Vector2(position.x, position.z)):
			interior += 1
	var relocated: int = field.unstuck_count - initial_unstuck
	var line := "[Fodder courtyard] near=%d/%d interior=%d jumps=%d max=%.3fm " \
		+ "penetration=%.3fm runtime_relocations=%d"
	print(line % [near, AMOUNT, interior, jump_count, max_jump, penetration, relocated])
	_check(relocated == 0, "no runtime relocation: %d" % relocated)
	_check(jump_count == 0, "no position jump over %.1fm: %d (max %.3f)" % [
		JUMP_LIMIT, jump_count, max_jump])
	_check(penetration <= PENETRATION_LIMIT, "no unit below world surface: %.3fm" % penetration)
	_check(interior == 0, "every unit left the courtyard through a real opening: %d" % interior)
	_check(near >= MIN_NEAR, "horde reaches the player: %d/%d within %.1fm" % [
		near, AMOUNT, NEAR_DISTANCE])
	field.queue_free()
	await process_frame
	_finish()


func _finish() -> void:
	print("[Fodder courtyard] ", "PASS" if _failures == 0 else "FAIL")
	quit(0 if _failures == 0 else 1)
