class_name VrmLoader
extends RefCounted
## 运行时加载 VRM（外部文件 / user://，不经过编辑器导入）。
##
## 关键点：GLTFDocument 的扩展注册是【全局静态】的（与编辑器插件一致）。
## 需要把 VRM0 + VRM1.0 的全部 6 个扩展各注册一次，之后
## append_from_file + generate_scene 的结果就和编辑器导入一致
## （含动画/表达式、弹簧骨、MToon 材质、VRM 元数据）。
## 只注册 vrm_extension（VRM0 版）会导致 VRM1.0 模型缺少动画/弹簧骨！
##
## 已验证：Godot 4.4.1 + godot-vrm；运行时加载 gwen.vrm 与编辑器导入结构一致。

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
	# 与编辑器插件相同的顺序：VRM0 扩展优先，VRM1.0 五个扩展随后
	GLTFDocument.register_gltf_document_extension(VRM0_EXTENSION.new(), true)
	for script in VRM1_EXTENSIONS:
		GLTFDocument.register_gltf_document_extension(script.new())

static func load_vrm(path: String) -> Dictionary:
	ensure_extensions()
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

static func _find_first(n: Node, cls: String) -> Object:
	if n.is_class(cls):
		return n
	for c in n.get_children():
		var r = _find_first(c, cls)
		if r != null:
			return r
	return null