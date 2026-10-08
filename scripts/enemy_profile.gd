extends RefCounted
## 敌人形体剖面：在共用骨架上"挂件 / 缩放 / 隐藏"，做出能在 30 米外区分的剪影。
##
## ── 为什么需要它 ────────────────────────────────────────────────
## 15 个图鉴条目共用两套模型（近战骑士 / 远程射手）。远程那边已经有按弹幕类型
## 换枪型的处理（ranged_enemy.apply_weapon_visual），近战这边却只有 tint 颜色
## 与体型缩放 —— 于是 8 个近战条目在 30 米外是同一个剪影，玩家只能靠头顶名字
## 分辨。辨识度是【打之前】的事：形状 → 动作 → 受击 → 死亡，四层里形状最靠前，
## 也最便宜。
##
## ── 为什么不是每个兵种一个 .tscn ──────────────────────────────
## 两份敌人场景各 1000+ 行。复制成 8 份意味着"改一次盔甲要改 8 处"，
## 而且骨骼命名 / rig 接口的漂移没有任何机制能拦住。剖面只动子节点：
## 隐藏（visible）、缩放（scale 乘法）、挂件（新建 MeshInstance3D），
## 骨架与动画完全不受影响。
##
## ── 为什么几何不写进 game_config.json ─────────────────────────
## 配置的边界是【数值平衡】。部件尺寸 / 位置属于造型，与骨骼命名、rig 接口、
## 场景里既有的网格尺寸强耦合（场景里的 BoxMesh_unit 是 1×1×1，所以
## scale 的数字就是"米"），拆出去反而更容易改错 —— 同 game_config.json 里
## 对地形山丘 / 掩体坐标的说明。配置只负责一件事：
## 【哪个图鉴条目用哪个 profile】（enemy_roster.entries[].profile）。
##
## ── 约定（改这里之前先读）───────────────────────────────────────
## 1. scale 一律用乘法（原部件本来就带尺寸），新增部件的 scale 直接写"米"；
## 2. 需要跟随护甲染色的部件加进组 "tint"，并且由敌人脚本在挂完之后
##    重新 register + 重染一次（见 melee_enemy.apply_body_profile）；
## 3. 材质按实例新建：场景里的材质都是 resource_local_to_scene，
##    共享材质会让一个实例的染色串到所有敌人身上；
## 4. 剪影优先于细节：在 30 米外只剩几十像素高，能读出来的只有轮廓。
##    所以宁可把盾做大、肩做宽，也不要在胸口加一枚小徽章。

const TINT_GROUP := "tint"

## 造型调色板。非数值平衡，故留在代码里；需要跟随护甲色的部件走 tint 组。
const COLOR_STEEL := Color(0.60, 0.63, 0.68, 1.0)
const COLOR_IRON := Color(0.33, 0.34, 0.36, 1.0)
const COLOR_LEATHER := Color(0.20, 0.13, 0.08, 1.0)
const COLOR_CLOTH := Color(0.09, 0.10, 0.12, 1.0)

## 已知剖面。写错 id 时只在自检里报，不影响出怪（退回原型骑士）。
const PROFILES := ["shield", "assassin", "berserker"]


## 应用一个形体剖面。profile 为空或未知 = 什么都不做（原型骑士）。
static func apply(model: Node3D, profile: String) -> void:
	if model == null or profile.is_empty():
		return
	match profile:
		"shield":
			_build_shield_guard(model)
		"assassin":
			_build_assassin(model)
		"berserker":
			_build_berserker(model)


# ---------------------------------------------------------------- 剖面

## 盾卫：大盾 + 宽肩线 + 方正头线。目标剪影 = 一堵墙。
## 成员：大型盾卫。
static func _build_shield_guard(model: Node3D) -> void:
	var materials := {}
	# 去掉"骑士"的尖角：尖肩与双角会在轮廓上读成"普通兵"。
	for path in [
		"Chest/LeftShoulder/PauldronSpike", "Chest/RightShoulder/PauldronSpike",
		"Chest/Head/HornLeft", "Chest/Head/HornRight",
	]:
		_hide(model, path)
	_multiply_scale(model, "Chest/LeftShoulder/Pauldron", Vector3(1.38, 1.25, 1.30))
	_multiply_scale(model, "Chest/RightShoulder/Pauldron", Vector3(1.38, 1.25, 1.30))
	_multiply_scale(model, "Chest/Head/HelmTop", Vector3(1.12, 1.25, 1.12))
	# 短剑：盾卫的主防御是盾，武器压小一档，避免和狂战士读混。
	_multiply_scale(model, "Chest/RightShoulder/Elbow/Fist/WeaponPivot/Blade", Vector3(0.85, 0.78, 1.0))

	# 盾面朝前（模型正面 -Z），带一点外倾角。三块：盾面 + 竖脊 + 盾心。
	# 尺寸取"塔盾"而不是小圆盾：30 米外能读出来的只有轮廓，把盾做大才有效。
	_attach(model, "Chest/LeftShoulder/Elbow", _mesh_instance(
		_box(Vector3.ONE), _material(materials, "plate", COLOR_STEEL, 0.35, 0.5), true
	), Vector3(0.68, 1.18, 0.09), Vector3(-0.24, 0.02, -0.20), Vector3(0.0, -0.14, 0.0))
	_attach(model, "Chest/LeftShoulder/Elbow", _mesh_instance(
		_box(Vector3.ONE), _material(materials, "rib", COLOR_IRON, 0.5, 0.45)
	), Vector3(0.11, 1.02, 0.10), Vector3(-0.24, 0.02, -0.25), Vector3(0.0, -0.14, 0.0))
	_attach(model, "Chest/LeftShoulder/Elbow", _mesh_instance(
		_sphere(0.5), _material(materials, "boss", COLOR_IRON, 0.6, 0.35)
	), Vector3.ONE * 0.24, Vector3(-0.24, 0.02, -0.30), Vector3.ZERO)


## 刺客：无甲 + 兜帽 + 双短刃。目标剪影 = 低伏的布影（靠"没有盔甲"来读）。
## 成员：疾行刺客（猎杀幼体可以走同一套，换颜色即可）。
static func _build_assassin(model: Node3D) -> void:
	var materials := {}
	# 【拆掉骑士】这一步比"加东西"更重要：去掉肩甲/胸甲/背甲/背鳍/盔顶/角/面甲，
	# 剩下的布身 + 光头顶就是完全不同的一类轮廓。
	for path in [
		"Chest/ChestPlate", "Chest/AbPlate", "Chest/BackPlate",
		"Chest/SpineFinTop", "Chest/SpineFinMid", "Chest/SpineFinLow",
		"Chest/LeftShoulder/Pauldron", "Chest/RightShoulder/Pauldron",
		"Chest/LeftShoulder/PauldronSpike", "Chest/RightShoulder/PauldronSpike",
		"Chest/Head/HelmTop", "Chest/Head/HornLeft", "Chest/Head/HornRight",
		"Chest/Head/FaceGrill",
	]:
		_hide(model, path)
	# 兜帽：一个下宽上尖的锥，罩住整个头。它是这套剪影唯一的高辨识特征。
	_attach(model, "Chest/Head", _mesh_instance(
		_cone(0.07, 0.31, 0.50), _material(materials, "cloth", COLOR_CLOTH, 0.0, 0.92)
	), Vector3.ONE, Vector3(0.0, 0.22, 0.02), Vector3.ZERO)
	# 披风短摆：挂在胸后，把"人形"轮廓向下压宽一点。
	_attach(model, "Chest", _mesh_instance(
		_box(Vector3.ONE), _material(materials, "cloak", Color(0.13, 0.14, 0.17, 1.0), 0.0, 0.9)
	), Vector3(0.42, 0.62, 0.06), Vector3(0.0, -0.05, 0.20), Vector3(0.10, 0.0, 0.0))
	# 右手主刃压成匕首。
	_multiply_scale(model, "Chest/RightShoulder/Elbow/Fist/WeaponPivot/Blade", Vector3(0.62, 0.58, 1.0))
	_multiply_scale(model, "Chest/RightShoulder/Elbow/Fist/WeaponPivot/BladeSpine", Vector3(0.62, 0.58, 1.0))
	# 左手补第二把匕首：右手武器挂在 WeaponPivot 上，这里给左手复制一份同构的枢轴。
	var pivot := _make_offhand(model, "Chest/LeftShoulder/Elbow/Fist")
	if pivot == null:
		return
	_attach(pivot, "", _mesh_instance(
		_box(Vector3.ONE), _material(materials, "dagger", COLOR_STEEL, 0.55, 0.4)
	), Vector3(0.09, 0.36, 0.035), Vector3(0.0, 0.26, 0.0), Vector3.ZERO)
	_attach(pivot, "", _mesh_instance(
		_cone(0.028, 0.032, 0.16), _material(materials, "grip", COLOR_LEATHER, 0.0, 0.85)
	), Vector3.ONE, Vector3(0.0, 0.05, 0.0), Vector3.ZERO)


## 狂战士：加宽的躯干 + 一对大刃 + 保留尖角。目标剪影 = 又宽又扎人的猛兽。
## 成员：狂战士（巨型破坏者可以走同一套，换颜色与体型即可）。
static func _build_berserker(model: Node3D) -> void:
	var materials := {}
	_multiply_scale(model, "Chest/LeftShoulder/Pauldron", Vector3(1.45, 1.3, 1.4))
	_multiply_scale(model, "Chest/RightShoulder/Pauldron", Vector3(1.45, 1.3, 1.4))
	_multiply_scale(model, "Chest/LeftShoulder/PauldronSpike", Vector3(1.3, 1.35, 1.3))
	_multiply_scale(model, "Chest/RightShoulder/PauldronSpike", Vector3(1.3, 1.35, 1.3))
	_multiply_scale(model, "Chest/Head/HornLeft", Vector3(1.35, 1.45, 1.35))
	_multiply_scale(model, "Chest/Head/HornRight", Vector3(1.35, 1.45, 1.35))
	# 躯干横向加宽：低多边形下"宽"比"高"更容易在轮廓上读出来。
	_multiply_scale(model, "Chest/Body", Vector3(1.16, 1.0, 1.06))
	# 主刃加大。
	_multiply_scale(model, "Chest/RightShoulder/Elbow/Fist/WeaponPivot/Blade", Vector3(1.15, 1.20, 1.0))
	# 【双手刃向外张开成 V 字】—— 休息姿态下手臂自然下垂，武器枢轴的默认角度
	# （-2.2 弧度 = 刃尖朝下前方）会让刃完全藏在腿后，正面一根线都看不到。
	# rig 只驱动肩 / 肘 / 胸，不碰 WeaponPivot，所以在这里转枢轴【在游戏里同样生效】：
	# 两个刃尖挑到肩线以上、各自向外张开，就成了这个兵种唯一的正面识别特征。
	_set_rotation(model, "Chest/RightShoulder/Elbow/Fist/WeaponPivot", Vector3(-0.25, 0.0, -0.72))
	# 左手补一把同尺寸的重刃，姿态镜像。
	var pivot := _make_offhand(model, "Chest/LeftShoulder/Elbow/Fist", Vector3(-0.25, 0.0, 0.72))
	if pivot == null:
		return
	_attach(pivot, "", _mesh_instance(
		_box(Vector3.ONE), _material(materials, "blade", COLOR_STEEL, 0.6, 0.38)
	), Vector3(0.24, 1.05, 0.06), Vector3(0.0, 0.58, 0.0), Vector3.ZERO)
	_attach(pivot, "", _mesh_instance(
		_box(Vector3.ONE), _material(materials, "spine", COLOR_IRON, 0.55, 0.45)
	), Vector3(0.07, 0.92, 0.065), Vector3(0.0, 0.58, 0.045), Vector3.ZERO)
	_attach(pivot, "", _mesh_instance(
		_cone(0.036, 0.042, 0.22), _material(materials, "grip", COLOR_LEATHER, 0.0, 0.85)
	), Vector3.ONE, Vector3(0.0, 0.07, 0.0), Vector3.ZERO)


# ---------------------------------------------------------------- 工具

## 左手武器枢轴。右手那把在场景里叫 WeaponPivot，枢轴的位移照抄，
## 角度可覆盖（默认与主手同姿），这样副手武器和主手成对。
static func _make_offhand(model: Node3D, fist_path: String, rotation: Vector3 = Vector3.ZERO) -> Node3D:
	var fist := _node(model, fist_path)
	if fist == null:
		return null
	var reference := _node(model, "Chest/RightShoulder/Elbow/Fist/WeaponPivot")
	var pivot := Node3D.new()
	pivot.name = "OffHandPivot"
	pivot.position = reference.position if reference != null else Vector3(0.0, -0.02, -0.04)
	pivot.rotation = rotation if rotation != Vector3.ZERO \
		else (reference.rotation if reference != null else Vector3(-2.2, 0.0, 0.0))
	fist.add_child(pivot)
	return pivot


## 按相对路径取节点；不存在时返回 null（不报错 —— 路径改名时由自检兜住）。
static func _node(root: Node, path: String) -> Node3D:
	return root.get_node_or_null(path) as Node3D


static func _hide(root: Node, path: String) -> void:
	var node := _node(root, path)
	if node != null:
		node.visible = false


## 乘法缩放：保留原部件在场景里的尺寸设定，只在其上叠系数。
static func _multiply_scale(root: Node, path: String, factor: Vector3) -> void:
	var node := _node(root, path)
	if node != null:
		node.scale = Vector3(
			node.scale.x * factor.x, node.scale.y * factor.y, node.scale.z * factor.z
		)


## 覆盖某个节点的旋转（弧度）。武器枢轴用它 —— rig 不碰这些节点，所以
## 这里定下的角度在游戏里同样成立。
static func _set_rotation(root: Node, path: String, rotation: Vector3) -> void:
	var node := _node(root, path)
	if node != null:
		node.rotation = rotation


## 挂一个部件。parent_path 为空时挂在 root 上，position/rotation 相对父节点，
## scale 直接是"米"（场景里的 BoxMesh_unit 为 1×1×1）。
static func _attach(
	root: Node,
	parent_path: String,
	node: MeshInstance3D,
	size: Vector3,
	position: Vector3,
	rotation: Vector3
) -> void:
	var parent: Node = _node(root, parent_path) if not parent_path.is_empty() else root
	if parent == null:
		return
	node.scale = size
	node.position = position
	node.rotation = rotation
	parent.add_child(node)


static func _mesh_instance(mesh: Mesh, material: Material, tintable: bool = false) -> MeshInstance3D:
	var instance := MeshInstance3D.new()
	instance.mesh = mesh
	instance.material_override = material
	if tintable:
		instance.add_to_group(TINT_GROUP)
	return instance


## 材质按实例新建并缓存（同一个敌人内部复用）。
static func _material(
	cache: Dictionary, key: String, color: Color, metallic: float, roughness: float
) -> StandardMaterial3D:
	var cached: Variant = cache.get(key, null)
	if cached is StandardMaterial3D:
		return cached as StandardMaterial3D
	var material := StandardMaterial3D.new()
	material.albedo_color = color
	material.metallic = metallic
	material.roughness = roughness
	cache[key] = material
	return material


static func _box(size: Vector3) -> BoxMesh:
	var mesh := BoxMesh.new()
	mesh.size = size
	return mesh


static func _sphere(radius: float) -> SphereMesh:
	var mesh := SphereMesh.new()
	mesh.radius = radius
	mesh.height = radius * 2.0
	mesh.radial_segments = 10
	mesh.rings = 5
	return mesh


static func _cone(top_radius: float, bottom_radius: float, height: float) -> CylinderMesh:
	var mesh := CylinderMesh.new()
	mesh.top_radius = top_radius
	mesh.bottom_radius = bottom_radius
	mesh.height = height
	mesh.radial_segments = 10
	mesh.rings = 1
	return mesh
