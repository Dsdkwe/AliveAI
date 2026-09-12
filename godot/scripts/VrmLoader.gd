class_name VrmLoader
extends RefCounted
## 运行时加载 VRM（外部文件 / user://，不经过编辑器导入）。
##
## 关键点：GLTFDocument 的扩展注册是【全局静态】的（与编辑器插件一致）。
## VRM1.0 五个扩展全局注册；VRM0 扩展按需临时注册（见 load_vrm）。
## append_from_file + generate_scene 的结果与编辑器导入一致
## （含动画/表达式、弹簧骨、MToon 材质、VRM 元数据）。
##
## 已验证：Godot 4.4.1 + godot-vrm；运行时加载 gwen.vrm 与编辑器导入结构一致。
## 另含「动画缺失自动重试」修复：规避主循环首帧清理与扩展交互导致的偶发生成中断。

const VRM0_EXTENSION := preload("res://addons/vrm/vrm_extension.gd")
const VRM1_EXTENSIONS := [
	preload("res://addons/vrm/1.0/VRMC_vrm.gd"),
	preload("res://addons/vrm/1.0/VRMC_node_constraint.gd"),
	preload("res://addons/vrm/1.0/VRMC_springBone.gd"),
	preload("res://addons/vrm/1.0/VRMC_materials_hdr_emissiveMultiplier.gd"),
	preload("res://addons/vrm/1.0/VRMC_materials_mtoon.gd"),
]
# EditorSceneFormatImporter.IMPORT_USE_NAMED_SKIN_BINDS（编辑器常量，运行时硬编码为 16）。
# 注意：命名绑定在运行时可能解析不到骨骼名，VrmLoader.load_vrm 会统一修复（_fix_skins）。
const IMPORT_FLAGS := 16

static var _extensions_registered := false

static func ensure_extensions() -> void:
	if _extensions_registered:
		return
	_extensions_registered = true
	# 与编辑器插件一致：VRM1.0 的五个扩展全局注册；
	# VRM0 扩展改为按需临时注册（见 load_vrm），加载后立即卸载。
	for script in VRM1_EXTENSIONS:
		GLTFDocument.register_gltf_document_extension(script.new())

static func load_vrm(path: String) -> Dictionary:
	ensure_extensions()
	# VRM0.0 模型：临时注册 VRM0 扩展（与编辑器导入器 import_vrm.gd 的行为一致），
	# 加载完成后立即卸载，避免与 VRM1.0 的五个扩展产生交互。
	var vrm0_ext = null
	if _is_vrm0_file(path):
		vrm0_ext = VRM0_EXTENSION.new()
		GLTFDocument.register_gltf_document_extension(vrm0_ext, true)
	var res := _load_once(path)
	# 校验 + 最多重试 2 次：修复偶发生成中断（主循环首帧清理之后的首个加载，
	# 扩展生成阶段可能撞上已释放的中间节点，表现为场景缺动画、日志出现
	# "previously freed instance"）。不显式释放失败的中间场景，避免 free 副作用。
	# 对本身无动画的模型最多多耗两次加载时间。
	for _i in range(2):
		if _anim_ok(res):
			break
		res = _load_once(path)
	if vrm0_ext != null:
		GLTFDocument.unregister_gltf_document_extension(vrm0_ext)
	return res

static func _load_once(path: String) -> Dictionary:
	var gltf := GLTFDocument.new()
	var state := GLTFState.new()
	state.set_additional_data(&"vrm/head_hiding_method", 0)
	state.set_additional_data(&"vrm/first_person_layers", 2)
	state.set_additional_data(&"vrm/third_person_layers", 4)
	state.handle_binary_image = GLTFState.HANDLE_BINARY_EMBED_AS_UNCOMPRESSED
	var err := gltf.append_from_file(path, state, IMPORT_FLAGS)
	if err != OK:
		return {"ok": false, "error": "读取文件失败（错误码 %d）" % err, "node": null}
	_sanitize_vrm1_meta(state)
	var scene = gltf.generate_scene(state)
	if scene == null:
		return {"ok": false, "error": "场景生成失败", "node": null}
	_fix_skins(scene)
	return {"ok": true, "error": "", "node": scene}

static func _anim_ok(res: Dictionary) -> bool:
	# 生成完整性校验：VRM 扩展正常工作时会创建 AnimationPlayer 并填充动画轨道。
	# 失败表现为动画轨道为空（扩展生成阶段中断）。
	if not bool(res["ok"]) or res["node"] == null:
		return false
	var ap := _find_first(res["node"], "AnimationPlayer")
	if ap == null:
		return false
	return ap.get_animation_list().size() > 0

static func _is_vrm0_file(path: String) -> bool:
	# 读取 GLB 头部 JSON，判断是否为 VRM0.0（extensions 含 "VRM"）
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		return false
	var magic := f.get_buffer(4)
	if magic != "glTF".to_ascii_buffer():
		f.close()
		return false
	f.seek(12)
	var clen := f.get_32()
	var ctype := f.get_32()
	if ctype != 0x4E4F534A or clen <= 0 or clen > 16 * 1024 * 1024:
		f.close()
		return false
	var jtxt := f.get_buffer(clen).get_string_from_utf8()
	f.close()
	var js = JSON.parse_string(jtxt)
	if typeof(js) != TYPE_DICTIONARY:
		return false
	var exts = js.get("extensions", {})
	if typeof(exts) != TYPE_DICTIONARY:
		return false
	return exts.has("VRM")

static func _sanitize_vrm1_meta(state: GLTFState) -> void:
	# 部分模型（如 gwen.vrm）的 meta 缺少 "modification" 字段，会让 addon 的
	# _create_meta 在字典取值时报错（日志噪音 + 元数据不完整）。做最小修补：
	# 缺失/非法时用 allowRedistribution 的值兜底，再退到 "prohibited"。
	const MOD_OK := ["prohibited", "allowModification", "allowModificationRedistribution"]
	var exts = state.json.get("extensions", {})
	if not (exts is Dictionary):
		return
	var vrm1 = exts.get("VRMC_vrm", {})
	if not (vrm1 is Dictionary):
		return
	var meta1 = vrm1.get("meta", {})
	if not (meta1 is Dictionary):
		return
	if MOD_OK.has(str(meta1.get("modification", ""))):
		return
	var alt := str(meta1.get("allowRedistribution", ""))
	meta1["modification"] = alt if MOD_OK.has(alt) else "prohibited"

static func _fix_skins(scene: Node) -> void:
	# 运行时导入的命名绑定可能残留 glTF 原始名（如 'spine'），而骨架已被
	# 重命名为人形模板名（如 'Spine'）。做一次大小写不敏感匹配修复，
	# 否则引擎会把解析不到的绑定回退到骨骼 0，导致蒙皮错乱。
	var skel := _find_first(scene, "Skeleton3D") as Skeleton3D
	if skel == null:
		return
	var ci_map := {}
	for i in range(skel.get_bone_count()):
		var key := String(skel.get_bone_name(i)).to_lower()
		if not ci_map.has(key):
			ci_map[key] = i
	var meshes := []
	_collect_meshes(scene, meshes)
	for mi in meshes:
		var skin: Skin = mi.skin
		if skin == null:
			continue
		for bi in range(skin.get_bind_count()):
			var bn := String(skin.get_bind_name(bi))
			if bn == "" or skel.find_bone(bn) >= 0:
				continue
			var idx = ci_map.get(bn.to_lower(), -1)
			if typeof(idx) == TYPE_INT and idx >= 0:
				skin.set_bind_name(bi, skel.get_bone_name(idx))

static func _collect_meshes(n: Node, out: Array) -> void:
	if n is MeshInstance3D:
		out.append(n)
	for c in n.get_children():
		_collect_meshes(c, out)

static func refresh_skeleton_poses(root: Node) -> void:
	# 修复 Godot 骨骼全局姿态缓存问题（“青蛙腿”/“头部内凹”根因）：
	# VRM 插件在场景树外完成「pose 初始化成 rest 值」后，由于 set_bone_pose_*
	# 在未入树时不标记全局姿态脏位，部分骨骼的全局姿态缓存会冻结在中间状态，
	# 表现为四肢/头部朝向错误（大腿倒转 180°、手 120°、眼 90° 等）。
	# 必须在 root 已 add_child（进入场景树）之后调用：把每个骨骼的 pose 分量
	# 按原值重写一遍，触发全骨架脏位重算，缓存即与 rest 一致。
	var skels: Array = []
	_collect_skels(root, skels)
	for sk in skels:
		for i in range(sk.get_bone_count()):
			sk.set_bone_pose_position(i, sk.get_bone_pose_position(i))
			sk.set_bone_pose_rotation(i, sk.get_bone_pose_rotation(i))
			sk.set_bone_pose_scale(i, sk.get_bone_pose_scale(i))
		if sk.has_method("force_update_all_bone_transforms"):
			sk.call("force_update_all_bone_transforms")

static func _collect_skels(n: Node, out: Array) -> void:
	if n is Skeleton3D:
		out.append(n)
	for c in n.get_children():
		_collect_skels(c, out)

static func _find_first(n: Node, cls: String) -> Object:
	if n.is_class(cls):
		return n
	for c in n.get_children():
		var r = _find_first(c, cls)
		if r != null:
			return r
	return null