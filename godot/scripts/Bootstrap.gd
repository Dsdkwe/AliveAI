extends Node3D

var _avatar: Node3D = null
var _cube: MeshInstance3D = null
var _cam: Camera3D = null

var _ui_layer: CanvasLayer = null
var _menu_btn: Button = null
var _sidebar: PanelContainer = null
var _sidebar_open := false
var _sidebar_w := 340.0
var _status: Label = null
var _model_box: VBoxContainer = null
var _scale_slider: HSlider = null
var _rot_slider: HSlider = null
var _dist_slider: HSlider = null
var _pitch_slider: HSlider = null

var _cam_distance := 3.0
var _cam_pitch := 15.0
var _cam_yaw := 0.0

var _touches: Dictionary = {}
var _pinch_dist := -1.0
var _pinch_mid := Vector2.ZERO

const MODEL_DIR := "res://assets/models"
const USER_MODEL_DIR := "user://models"
const APP_SETTINGS_PATH := "user://settings_app.json"
const FONT_PATH := "res://assets/fonts/SmileySans-Oblique.ttf"
const SCAN_DIRS := [
	"/storage/emulated/0/Download/HalfHearted",
]
const SIDEBAR_MIN_W := 520.0
const SIDEBAR_HANDLE_W := 44.0
const SCAN_AUTO_INTERVAL := 2.5

const EMO_CN := {
	"neutral": "平静",
	"happy": "开心",
	"sad": "难过",
	"angry": "生气",
	"surprised": "惊讶",
	"shy": "害羞",
	"thinking": "思考",
}
const ACT_CN := {
	"nod": "点头",
	"shake": "摇头",
	"tilt_head": "歪头",
	"wave": "挥手",
	"none": "无",
}

# AI / 角色
var _brain: AIBrain = null
var _tts: TTSEngine = null
var _avatar_ctrl: AvatarController = null

# 聊天 UI
var _chat_panel: PanelContainer = null
var _chat_log: RichTextLabel = null
var _chat_input: LineEdit = null
var _send_btn: Button = null
var _emotion_label: Label = null

# AI 设置 UI
var _key_edit: LineEdit = null
var _model_edit: LineEdit = null
var _tts_check: CheckBox = null
var _save_btn: Button = null
var _test_btn: Button = null
var _clear_btn: Button = null

# 模型下载
var _dl_http: HTTPRequest = null
var _dl_url_edit: LineEdit = null
var _dl_btn: Button = null
var _dl_label: Label = null
var _downloading := false
var _dl_final := ""
var _up_btn: Button = null
var _up_busy := false
var _scan_box: VBoxContainer = null
var _scan_dirs_override: Array = []
var _sidebar_handle: Control = null
var _sidebar_handle_bar: ColorRect = null
var _sidebar_dragging := false
var _scan_timer: Timer = null
var _last_scan_sig := ""
var _storage_warned := false
var _toast: Label = null
var _toast_seq := 0
var _cur_model_path := ""

func _ready() -> void:
	_setup_font()
	_setup_environment()
	_setup_light()
	_setup_camera()
	_setup_ai()
	_setup_ui()
	_scan_timer = Timer.new()
	_scan_timer.wait_time = SCAN_AUTO_INTERVAL
	_scan_timer.autostart = true
	_scan_timer.timeout.connect(_on_scan_timer)
	add_child(_scan_timer)
	var start_model := _load_last_model()
	if start_model == "":
		start_model = MODEL_DIR + "/gwen.vrm"
	_load_vrm(start_model)

func _notification(what: int) -> void:
	# 回到前台时自动刷新「文件夹自动识别」列表
	if what == NOTIFICATION_APPLICATION_FOCUS_IN:
		if _scan_box != null:
			_refresh_folder_models()

func _process(_delta: float) -> void:
	if _downloading and _dl_http and _dl_label:
		var got := _dl_http.get_downloaded_bytes()
		var total := _dl_http.get_body_size()
		if total > 0:
			_dl_label.text = "下载中 %d%%（%.1f / %.1f MB）" % [int(got * 100 / total), got / 1048576.0, total / 1048576.0]
		else:
			_dl_label.text = "下载中… %.1f MB" % (got / 1048576.0)
	if _sidebar_open:
		_update_sidebar_handle()

func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventScreenTouch:
		var t := event as InputEventScreenTouch
		if t.pressed:
			_touches[t.index] = t.position
		else:
			_touches.erase(t.index)
		if _touches.size() == 2:
			var pts: Array = _touches.values()
			var p0: Vector2 = pts[0]
			var p1: Vector2 = pts[1]
			_pinch_dist = p0.distance_to(p1)
			_pinch_mid = (p0 + p1) * 0.5
		else:
			_pinch_dist = -1.0
		return
	if event is InputEventScreenDrag:
		var d := event as InputEventScreenDrag
		if not _touches.has(d.index):
			return
		_touches[d.index] = d.position
		if _touches.size() == 1:
			if _avatar:
				_avatar.rotate_y(d.relative.x * 0.01)
		elif _touches.size() == 2:
			_handle_pinch()

func _handle_pinch() -> void:
	var pts: Array = _touches.values()
	var p0: Vector2 = pts[0]
	var p1: Vector2 = pts[1]
	var dist: float = p0.distance_to(p1)
	var mid: Vector2 = (p0 + p1) * 0.5
	if _pinch_dist > 0.0:
		var scale_factor: float = dist / _pinch_dist
		_cam_distance = clamp(_cam_distance / scale_factor, 1.0, 8.0)
		if _dist_slider:
			_dist_slider.value = _cam_distance
		var delta: Vector2 = mid - _pinch_mid
		_cam_yaw -= delta.x * 0.2
		_cam_pitch = clamp(_cam_pitch + delta.y * 0.2, -45.0, 75.0)
		if _pitch_slider:
			_pitch_slider.value = _cam_pitch
		_update_camera()
	_pinch_dist = dist
	_pinch_mid = mid

func _load_vrm(path: String) -> void:
	var av: Node = null
	if ResourceLoader.exists(path):
		var packed = load(path)
		if packed != null:
			av = packed.instantiate()
	if av == null and not path.begins_with("res://"):
		_show_status("正在加载模型…（大文件请稍等）")
		await get_tree().process_frame
		var res: Dictionary = {}
		# 帧间最多重试 2 轮（配合 VrmLoader 内部同帧重试），规避偶发生成中断
		for _round in range(3):
			res = VrmLoader.load_vrm(path)
			if res["ok"] and _anim_exists(res["node"]):
				break
			await get_tree().process_frame
		if res["ok"]:
			av = res["node"]
		else:
			_show_status("模型加载失败：" + str(res["error"]))
	if av == null:
		if path.begins_with("res://"):
			_show_status("模型加载失败：" + path.get_file())
		if _avatar == null:
			_setup_cube()
		return
	if _cube:
		_cube.queue_free()
		_cube = null
	if _avatar_ctrl:
		_avatar_ctrl.set_process(false)
		_avatar_ctrl.queue_free()
		_avatar_ctrl = null
	if _avatar:
		_avatar.queue_free()
		_avatar = null
	_avatar = av
	add_child(_avatar)
	_avatar_ctrl = AvatarController.new()
	_avatar_ctrl.name = "AvatarController"
	add_child(_avatar_ctrl)
	_avatar_ctrl.setup(_avatar)
	_apply_current_transforms()
	_cur_model_path = path
	_save_last_model(path)
	_show_status("已加载模型：" + path.get_file())

func _apply_current_transforms() -> void:
	if not _avatar:
		return
	if _scale_slider:
		_avatar.scale = Vector3.ONE * _scale_slider.value
	if _rot_slider:
		_avatar.rotation.y = deg_to_rad(_rot_slider.value)

# ------------------------------------------------------------------ 模型管理

func _gather_models() -> Array:
	var out: Array = []
	var dir := DirAccess.open(MODEL_DIR)
	if dir:
		dir.list_dir_begin()
		var f := dir.get_next()
		while f != "":
			if f.ends_with(".vrm"):
				out.append({"name": f, "path": MODEL_DIR + "/" + f, "user": false})
			f = dir.get_next()
		dir.list_dir_end()
	var udir := DirAccess.open(USER_MODEL_DIR)
	if udir:
		udir.list_dir_begin()
		var g := udir.get_next()
		while g != "":
			if g.ends_with(".vrm"):
				out.append({"name": g, "path": USER_MODEL_DIR + "/" + g, "user": true})
			g = udir.get_next()
		udir.list_dir_end()
	return out

func _refresh_model_list() -> void:
	if _model_box == null:
		return
	for c in _model_box.get_children():
		c.queue_free()
	var models := _gather_models()
	if models.is_empty():
		var empty := Label.new()
		empty.text = "（暂无自装模型；把 vrm/zip 放进 Download/HalfHearted/ 会自动出现）"
		empty.add_theme_font_size_override("font_size", 46)
		_model_box.add_child(empty)
		return
	for m in models:
		var row := HBoxContainer.new()
		row.add_theme_constant_override("separation", 12)
		var b := Button.new()
		b.text = str(m["name"]) + ("（自装）" if m["user"] else "")
		b.add_theme_font_size_override("font_size", 52)
		b.custom_minimum_size = Vector2(0, 128)
		b.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		b.pressed.connect(_on_model_picked.bind(str(m["path"])))
		row.add_child(b)
		if m["user"]:
			var del := Button.new()
			del.text = "删除"
			del.add_theme_font_size_override("font_size", 44)
			del.custom_minimum_size = Vector2(150, 128)
			del.pressed.connect(_on_delete_model.bind(str(m["path"]), str(m["name"])))
			row.add_child(del)
		_model_box.add_child(row)

func _on_model_picked(path: String) -> void:
	_load_vrm(path)

func _on_delete_model(path: String, name: String) -> void:
	var err := DirAccess.remove_absolute(path)
	if err == OK:
		if _cur_model_path == path:
			_cur_model_path = ""
			_save_last_model("")
			_show_status("已删除 " + name + "（重启后回到默认模型）")
		else:
			_show_status("已删除 " + name)
		_refresh_model_list()
	else:
		_show_status("删除失败（错误码 %d）" % err)

# ---------------------------------------------------------------- 设置持久化

func _save_last_model(path: String) -> void:
	var cfg := {}
	if FileAccess.file_exists(APP_SETTINGS_PATH):
		var f := FileAccess.open(APP_SETTINGS_PATH, FileAccess.READ)
		if f != null:
			var d = JSON.parse_string(f.get_as_text())
			f.close()
			if d is Dictionary:
				cfg = d
	cfg["last_model"] = path
	var w := FileAccess.open(APP_SETTINGS_PATH, FileAccess.WRITE)
	if w != null:
		w.store_string(JSON.stringify(cfg, " "))
		w.close()

func _load_last_model() -> String:
	if not FileAccess.file_exists(APP_SETTINGS_PATH):
		return ""
	var f := FileAccess.open(APP_SETTINGS_PATH, FileAccess.READ)
	if f == null:
		return ""
	var d = JSON.parse_string(f.get_as_text())
	f.close()
	if d is Dictionary:
		var p := str(d.get("last_model", ""))
		if p != "" and FileAccess.file_exists(p):
			return p
	return ""


# ---------------------------------------------------------------- 上传导入

func _on_upload_pressed() -> void:
	if _up_busy:
		_notify("文件选择器已打开，请先完成当前选择")
		return
	var err := DisplayServer.file_dialog_show("选择模型文件", "", "", false, DisplayServer.FILE_DIALOG_MODE_OPEN_FILE, ["*;所有文件;*"], _on_file_picked)
	if err != OK:
		_notify("无法打开文件选择器（错误码 %d）。可把模型复制到 Download/HalfHearted/ 自动识别" % err, true)
		return
	_up_busy = true
	_show_status("已打开文件选择器，请选择 .vrm 或 .zip …")
	await get_tree().create_timer(15.0).timeout
	if _up_busy:
		_up_busy = false
		_notify("未收到选择结果。若选了文件没反应：请把模型复制到 Download/HalfHearted/（自动识别）", true)

func _on_file_picked(ok: bool, paths: PackedStringArray, _filter_index: int) -> void:
	_up_busy = false
	if not ok or paths.is_empty():
		_notify("没有收到文件（取消，或系统未返回路径）。若选了文件没反应，请把模型复制到 Download/HalfHearted/", true)
		return
	var src := str(paths[0])
	var low := src.to_lower()
	if not (low.ends_with(".vrm") or low.ends_with(".zip")):
		_notify("选到的是「%s」，不是 .vrm / .zip 模型文件，请重新选择" % src.get_file(), true)
		return
	_notify("正在导入：" + src.get_file() + " …")
	await get_tree().process_frame
	var res := _import_model_file(src)
	_notify(str(res["msg"]), true)
	if bool(res["ok"]):
		_refresh_model_list()
		_load_vrm(str(res["path"]))

func _import_model_file(src: String) -> Dictionary:
	DirAccess.make_dir_recursive_absolute(USER_MODEL_DIR)
	if src.to_lower().ends_with(".zip"):
		return _import_zip(src)
	return _copy_to_user_models(src, src.get_file())

func _copy_to_user_models(src: String, name: String) -> Dictionary:
	var f := FileAccess.open(src, FileAccess.READ)
	if f == null:
		return {"ok": false, "msg": "读取失败（错误码 %d）。请到系统设置→应用→Half-hearted AI 开启「所有文件访问/所有文件管理」后重试；或改用「文件夹导入」" % FileAccess.get_open_error(), "path": ""}
	var size := f.get_length()
	if size <= 0:
		f.close()
		return {"ok": false, "msg": "文件为空或无法读取", "path": ""}
	var fname := _sanitize_filename(name)
	if fname == "":
		fname = "model_%d.vrm" % int(Time.get_unix_time_from_system())
	var dst := USER_MODEL_DIR + "/" + fname
	var w := FileAccess.open(dst, FileAccess.WRITE)
	if w == null:
		f.close()
		return {"ok": false, "msg": "写入失败（存储空间不足？）", "path": ""}
	var chunk := 4 * 1024 * 1024
	var done := 0
	while done < size:
		var n: int = mini(chunk, int(size) - done)
		var buf := f.get_buffer(n)
		if buf.is_empty():
			break
		w.store_buffer(buf)
		done += buf.size()
	f.close()
	w.close()
	if done != size:
		DirAccess.remove_absolute(dst)
		return {"ok": false, "msg": "复制中断（%d/%d 字节）" % [done, int(size)], "path": ""}
	return {"ok": true, "msg": "已导入：" + fname, "path": dst}

func _import_zip(src: String) -> Dictionary:
	var tmp := _copy_to_user_models(src, "_upload_tmp.zip")
	if not bool(tmp["ok"]):
		return tmp
	var zpath := str(tmp["path"])
	var zr := ZIPReader.new()
	var e := zr.open(zpath)
	if e != OK:
		DirAccess.remove_absolute(zpath)
		return {"ok": false, "msg": "无法读取压缩包（错误码 %d）" % e, "path": ""}
	var target := ""
	for p in zr.get_files():
		if str(p).to_lower().ends_with(".vrm"):
			target = str(p)
			break
	if target == "":
		zr.close()
		DirAccess.remove_absolute(zpath)
		return {"ok": false, "msg": "压缩包里没有找到 .vrm 模型文件", "path": ""}
	var data := zr.read_file(target)
	zr.close()
	DirAccess.remove_absolute(zpath)
	if data.is_empty():
		return {"ok": false, "msg": "压缩包内模型读取失败", "path": ""}
	var fname := _sanitize_filename(target.get_file())
	var dst := USER_MODEL_DIR + "/" + fname
	var w := FileAccess.open(dst, FileAccess.WRITE)
	if w == null:
		return {"ok": false, "msg": "写入失败（存储空间不足？）", "path": ""}
	w.store_buffer(data)
	w.close()
	return {"ok": true, "msg": "已从压缩包导入：" + fname, "path": dst}

# ---------------------------------------------------------------- 文件夹导入

func _scan_dirs() -> Array:
	if not _scan_dirs_override.is_empty():
		return _scan_dirs_override
	return SCAN_DIRS.duplicate()

func _on_scan_timer() -> void:
	if _sidebar_open:
		_refresh_folder_models()

func _refresh_folder_models(show_hint: bool = false) -> void:
	# 被动自动识别：只认指定文件夹（Download/HalfHearted）；
	# 触发点：打开侧边栏 / 回到前台 / 侧边栏可见时定时刷新。
	if _scan_box == null or not is_inside_tree():
		return
	_ensure_scan_dirs()
	var probe := DirAccess.open("/storage/emulated/0/Download")
	var found: Array = _find_model_files(_scan_dirs())
	var sig := ("denied" if probe == null else "ok") + "|"
	for m in found:
		sig += str(m["path"]) + "|" + str(int(m["mtime"])) + "\n"
	if sig == _last_scan_sig and not show_hint:
		return
	_last_scan_sig = sig
	for c in _scan_box.get_children():
		_scan_box.remove_child(c)
		c.queue_free()
	if found.is_empty():
		var hint := Label.new()
		hint.add_theme_font_size_override("font_size", 40)
		hint.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		if probe == null:
			hint.text = "读取不了手机存储：请到系统设置→应用→Half-hearted AI 开启「所有文件访问/所有文件管理」"
			if not _storage_warned:
				_storage_warned = true
				_notify(hint.text, true)
		else:
			hint.text = "（自动识别）把 .vrm / .zip 放进 Download/HalfHearted/ 就会自动出现"
		_scan_box.add_child(hint)
		return
	var shown := 0
	for m in found:
		if shown >= 30:
			break
		_add_scan_row(m)
		shown += 1
	if found.size() > shown:
		var more := Label.new()
		more.text = "……还有 %d 个未显示" % (found.size() - shown)
		more.add_theme_font_size_override("font_size", 40)
		_scan_box.add_child(more)
	if show_hint:
		_notify("找到 %d 个模型文件，点文件名即可导入" % found.size(), true)

func _ensure_scan_dirs() -> void:
	for d in _scan_dirs():
		DirAccess.make_dir_recursive_absolute(str(d))

func _find_model_files(dirs: Array) -> Array:
	var out: Array = []
	var seen := {}
	for d in dirs:
		_scan_dir_rec(str(d), out, seen, 0)
	out.sort_custom(func(a, b): return int(a["mtime"]) > int(b["mtime"]))
	return out

func _scan_dir_rec(path: String, out: Array, seen: Dictionary, depth: int) -> void:
	if depth > 3 or out.size() > 200:
		return
	var dir := DirAccess.open(path)
	if dir == null:
		return
	dir.list_dir_begin()
	var f := dir.get_next()
	while f != "":
		if f.begins_with("."):
			f = dir.get_next()
			continue
		var full := path.path_join(f)
		if dir.current_is_dir():
			_scan_dir_rec(full, out, seen, depth + 1)
		else:
			var low := f.to_lower()
			if (low.ends_with(".vrm") or low.ends_with(".zip")) and not seen.has(full):
				seen[full] = true
				var fh := FileAccess.open(full, FileAccess.READ)
				var sz := 0
				if fh != null:
					sz = fh.get_length()
					fh.close()
				out.append({"path": full, "name": f, "size": sz, "mtime": FileAccess.get_modified_time(full)})
		f = dir.get_next()
	dir.list_dir_end()

func _add_scan_row(m: Dictionary) -> void:
	var b := Button.new()
	b.text = "%s（%.1f MB）" % [str(m["name"]), float(int(m["size"])) / 1048576.0]
	b.add_theme_font_size_override("font_size", 46)
	b.custom_minimum_size = Vector2(0, 118)
	b.pressed.connect(_on_scan_import.bind(str(m["path"])))
	_scan_box.add_child(b)

func _on_scan_import(path: String) -> void:
	_notify("正在导入：" + path.get_file() + " …")
	await get_tree().process_frame
	var res := _import_model_file(path)
	_notify(str(res["msg"]), true)
	if bool(res["ok"]):
		_refresh_model_list()
		_load_vrm(str(res["path"]))

func _notify(msg: String, to_chat: bool = false) -> void:
	_show_status(msg)
	if to_chat:
		_chat_append("系统", msg, "#ffd27f")

func _toast_show(msg: String) -> void:
	if _toast == null or not is_inside_tree():
		return
	_toast_seq += 1
	var seq := _toast_seq
	_toast.text = msg
	_toast.modulate.a = 1.0
	var t := get_tree().create_timer(6.0)
	t.timeout.connect(func() -> void:
		if _toast_seq == seq and _toast != null:
			_toast.modulate.a = 0.0)

func _test_action(a: String) -> void:
	if _avatar_ctrl == null:
		_show_status("角色尚未就绪")
		return
	_avatar_ctrl.play_action(a)
	_show_status("动作：" + _act_cn(a))

func _anim_exists(root: Node) -> bool:
	# 校验运行时加载的模型场景是否含可用动画（VRM 正常生成时应带 AnimationPlayer）
	if root == null:
		return false
	for c in root.get_children():
		if c is AnimationPlayer:
			return (c as AnimationPlayer).get_animation_list().size() > 0
	return false

func _sanitize_filename(fname: String) -> String:
	# 宽松过滤：保留中文等 Unicode 字符，只替换文件系统危险字符
	var out := ""
	for i in fname.length():
		var c := fname[i]
		var code := c.unicode_at(0)
		if c == "/" or c == ":" or c == "*" or c == "?" or c == "<" or c == ">" or c == "|" or code < 32 or code == 34 or code == 92:
			out += "_"
		else:
			out += c
	out = out.strip_edges()
	if out.length() > 60:
		out = out.substr(0, 60)
	return out

func _on_download_pressed() -> void:
	if _downloading:
		return
	var url := _dl_url_edit.text.strip_edges()
	if url == "" or not (url.begins_with("http://") or url.begins_with("https://")):
		_show_status("请输入合法的 http(s) 下载链接")
		return
	var fname := url.get_file()
	var qi := fname.find("?")
	if qi >= 0:
		fname = fname.substr(0, qi)
	if not fname.to_lower().ends_with(".vrm"):
		_show_status("链接需要指向 .vrm 文件")
		return
	fname = _sanitize_filename(fname)
	if fname == "" or fname == ".vrm":
		fname = "model.vrm"
	DirAccess.make_dir_recursive_absolute(USER_MODEL_DIR)
	var final_name := fname
	if FileAccess.file_exists(USER_MODEL_DIR + "/" + final_name):
		final_name = fname.get_basename() + "_" + str(int(Time.get_unix_time_from_system())) + ".vrm"
	_dl_final = USER_MODEL_DIR + "/" + final_name
	var tmp_path := USER_MODEL_DIR + "/_downloading.tmp"
	_dl_http.download_file = tmp_path
	var err := _dl_http.request(url)
	if err != OK:
		_show_status("下载请求发起失败（错误码 %d）" % err)
		return
	_downloading = true
	if _dl_btn:
		_dl_btn.disabled = true
	if _dl_label:
		_dl_label.text = "下载中…"
	_show_status("开始下载模型…")

func _on_download_completed(result: int, code: int, _headers: PackedStringArray, _body: PackedByteArray) -> void:
	_downloading = false
	if _dl_btn:
		_dl_btn.disabled = false
	var tmp_path := USER_MODEL_DIR + "/_downloading.tmp"
	if result != HTTPRequest.RESULT_SUCCESS or code != 200:
		_show_status("下载失败（HTTP %d / 错误 %d）" % [code, result])
		if _dl_label:
			_dl_label.text = "下载失败"
		if FileAccess.file_exists(tmp_path):
			DirAccess.remove_absolute(tmp_path)
		return
	var err := DirAccess.rename_absolute(tmp_path, _dl_final)
	if err != OK:
		_show_status("保存失败（错误码 %d）" % err)
		if _dl_label:
			_dl_label.text = "保存失败"
		if FileAccess.file_exists(tmp_path):
			DirAccess.remove_absolute(tmp_path)
		return
	if _dl_label:
		_dl_label.text = "下载完成：" + _dl_final.get_file()
	_show_status("下载完成，正在切换模型…")
	_refresh_model_list()
	_load_vrm(_dl_final)

# ------------------------------------------------------------------ 手势/相机

func _toggle_sidebar() -> void:
	_sidebar_open = not _sidebar_open
	var target_x := 0.0 if _sidebar_open else -_sidebar_w
	var tween := create_tween()
	tween.tween_property(_sidebar, "position:x", target_x, 0.25)
	_update_sidebar_handle()
	if _sidebar_open:
		_refresh_folder_models()

# ---------------------------------------------------------------- 侧边栏拖拽

func _on_sidebar_handle_input(event: InputEvent) -> void:
	if event is InputEventScreenDrag:
		_set_sidebar_width(_sidebar_w + (event as InputEventScreenDrag).relative.x)
	elif event is InputEventMouseMotion:
		var mm := event as InputEventMouseMotion
		if mm.button_mask & MOUSE_BUTTON_MASK_LEFT:
			_set_sidebar_width(_sidebar_w + mm.relative.x)
	elif event is InputEventScreenTouch:
		if not (event as InputEventScreenTouch).pressed:
			_finish_sidebar_drag()
	elif event is InputEventMouseButton:
		if not (event as InputEventMouseButton).pressed:
			_finish_sidebar_drag()

func _set_sidebar_width(w: float) -> void:
	var view: Vector2 = get_viewport().get_visible_rect().size
	_sidebar_w = clampf(w, SIDEBAR_MIN_W, maxf(view.x * 0.94, SIDEBAR_MIN_W))
	if _sidebar:
		_sidebar.size = Vector2(_sidebar_w, view.y)
		_sidebar.position.x = 0.0 if _sidebar_open else -_sidebar_w
	_sidebar_dragging = true
	_update_sidebar_handle()

func _finish_sidebar_drag() -> void:
	if _sidebar_dragging:
		_sidebar_dragging = false
		_save_sidebar_width()

func _update_sidebar_handle() -> void:
	if _sidebar_handle == null or _sidebar == null:
		return
	_sidebar_handle.visible = _sidebar_open
	if _sidebar_open:
		_sidebar_handle.position = Vector2(_sidebar.position.x + _sidebar.size.x - SIDEBAR_HANDLE_W * 0.5, 0)
		var view: Vector2 = get_viewport().get_visible_rect().size
		if _sidebar_handle_bar:
			_sidebar_handle_bar.position = Vector2((SIDEBAR_HANDLE_W - 10.0) * 0.5, view.y * 0.5 - 110.0)

func _save_sidebar_width() -> void:
	var cfg := {}
	if FileAccess.file_exists(APP_SETTINGS_PATH):
		var f := FileAccess.open(APP_SETTINGS_PATH, FileAccess.READ)
		if f != null:
			var d = JSON.parse_string(f.get_as_text())
			f.close()
			if d is Dictionary:
				cfg = d
	cfg["sidebar_w"] = _sidebar_w
	var w := FileAccess.open(APP_SETTINGS_PATH, FileAccess.WRITE)
	if w != null:
		w.store_string(JSON.stringify(cfg, " "))
		w.close()

func _load_sidebar_width() -> float:
	if not FileAccess.file_exists(APP_SETTINGS_PATH):
		return 0.0
	var f := FileAccess.open(APP_SETTINGS_PATH, FileAccess.READ)
	if f == null:
		return 0.0
	var d = JSON.parse_string(f.get_as_text())
	f.close()
	if d is Dictionary:
		return float(d.get("sidebar_w", 0.0))
	return 0.0

func _add_slider_row(parent: Control, title: String, min_v: float, max_v: float, step_v: float, init_v: float, cb: Callable) -> HSlider:
	var lbl := Label.new()
	lbl.text = title
	lbl.add_theme_font_size_override("font_size", 50)
	parent.add_child(lbl)
	var s := HSlider.new()
	s.min_value = min_v
	s.max_value = max_v
	s.step = step_v
	s.value = init_v
	s.custom_minimum_size = Vector2(0, 96)
	s.value_changed.connect(cb)
	parent.add_child(s)
	return s

func _on_scale_changed(v: float) -> void:
	if _avatar:
		_avatar.scale = Vector3.ONE * v

func _on_rot_changed(v: float) -> void:
	if _avatar:
		_avatar.rotation.y = deg_to_rad(v)

func _on_dist_changed(v: float) -> void:
	_cam_distance = v
	_update_camera()

func _on_pitch_changed(v: float) -> void:
	_cam_pitch = v
	_update_camera()

func _update_camera() -> void:
	if not _cam:
		return
	var target := Vector3(0.0, 1.0, 0.0)
	var pitch_rad := deg_to_rad(_cam_pitch)
	var yaw_rad := deg_to_rad(_cam_yaw)
	var off := Vector3(
		_cam_distance * cos(pitch_rad) * sin(yaw_rad),
		_cam_distance * sin(pitch_rad),
		_cam_distance * cos(pitch_rad) * cos(yaw_rad)
	)
	_cam.position = target + off
	_cam.look_at(target)

# ------------------------------------------------------------------ AI 接线

func _setup_ai() -> void:
	_brain = AIBrain.new()
	_brain.name = "AIBrain"
	add_child(_brain)
	_brain.reply_ready.connect(_on_ai_reply)
	_brain.request_failed.connect(_on_ai_failed)
	_brain.thinking_changed.connect(_on_thinking)
	_brain.test_done.connect(_on_test_done)

	_tts = TTSEngine.new()
	_tts.name = "TTSEngine"
	add_child(_tts)
	_tts.enabled = _brain.tts_enabled
	_tts.speech_started.connect(_on_speech_started)
	_tts.speech_finished.connect(_on_speech_finished)
	_tts.tts_unavailable.connect(_on_tts_unavailable)

func _on_send(_text: String = "") -> void:
	if _brain == null:
		return
	var txt := _chat_input.text.strip_edges()
	if txt == "":
		return
	if _send_btn:
		_send_btn.disabled = true
	_chat_append("你", txt, "#9fd0ff")
	_chat_input.text = ""
	_chat_input.release_focus()
	var ok := _brain.ask(txt)
	if not ok and _send_btn:
		_send_btn.disabled = false

func _on_ai_reply(text: String, emotion: String, action: String) -> void:
	_chat_append("720", text, "#ffd9a0")
	if _emotion_label:
		_emotion_label.text = "情绪：" + _emo_cn(emotion)
	if _avatar_ctrl:
		_avatar_ctrl.set_emotion(emotion)
		if action != "" and action != "none":
			_avatar_ctrl.play_action(action)
	if _tts and _tts.enabled and _tts_check and _tts_check.button_pressed:
		_tts.speak(text)
	if _send_btn:
		_send_btn.disabled = false
	_show_status("已回复（%s / %s）" % [_emo_cn(emotion), _act_cn(action)])

func _on_ai_failed(msg: String) -> void:
	_chat_append("系统", msg, "#ff9f9f")
	if _send_btn:
		_send_btn.disabled = false
	_show_status("出错了，看看聊天框里的提示")

func _on_thinking(thinking: bool) -> void:
	if thinking:
		_show_status("720正在思考…")

func _on_test_done(ok: bool, msg: String) -> void:
	_show_status(msg)
	_chat_append("系统", msg, "#9fd0ff" if ok else "#ff9f9f")

func _on_speech_started() -> void:
	if _avatar_ctrl:
		_avatar_ctrl.set_talking(true)
	_show_status("720说话中…")

func _on_speech_finished() -> void:
	if _avatar_ctrl:
		_avatar_ctrl.set_talking(false)
	_show_status("就绪")

func _on_tts_unavailable(msg: String) -> void:
	_chat_append("系统", msg, "#ff9f9f")
	if _tts_check:
		_tts_check.button_pressed = false
	if _brain:
		_brain.tts_enabled = false
		_brain.save_settings()

func _on_save_settings() -> void:
	if _brain == null:
		return
	_brain.api_key = _key_edit.text.strip_edges()
	var m := _model_edit.text.strip_edges()
	if m != "":
		_brain.model = m
	_brain.save_settings()
	_show_status("设置已保存")
	_chat_append("系统", "设置已保存" + ("，可以开始对话了" if _brain.configured() else "，别忘了填 API Key"), "#9fd0ff")

func _on_test_pressed() -> void:
	if _brain:
		_show_status("连接测试中…")
		_brain.test_connection()

func _on_tts_toggled(on: bool) -> void:
	if _brain:
		_brain.tts_enabled = on
		_brain.save_settings()
	if _tts:
		_tts.enabled = on

func _on_clear_pressed() -> void:
	if _brain:
		_brain.clear_history()
	_chat_append("系统", "对话记忆已清空", "#9fd0ff")

func _chat_append(who: String, text: String, color: String) -> void:
	if _chat_log == null:
		return
	var safe := text.replace("[", "[lb]")
	_chat_log.append_text("[color=" + color + "]" + who + "[/color] " + safe + "\n")

func _emo_cn(e: String) -> String:
	return EMO_CN.get(e, e)

func _act_cn(a: String) -> String:
	return ACT_CN.get(a, a)

# ------------------------------------------------------------------ UI

func _setup_font() -> void:
	var theme := Theme.new()
	var f: Font = null
	if ResourceLoader.exists(FONT_PATH):
		f = load(FONT_PATH)
		if f:
			theme.default_font = f
	var sys := SystemFont.new()
	sys.font_names = PackedStringArray(["sans-serif", "Noto Sans CJK SC", "Noto Sans SC", "Droid Sans Fallback"])
	if f and f.get("fallbacks") != null:
		f.set("fallbacks", [sys])
	theme.default_font_size = 52
	var win := get_window()
	if win:
		win.theme = theme
	print("[Bootstrap] font=", f != null, " font_path=", FONT_PATH)

func _setup_ui() -> void:
	_ui_layer = CanvasLayer.new()
	add_child(_ui_layer)

	var view: Vector2 = get_viewport().get_visible_rect().size
	_sidebar_w = clamp(view.x * 0.52, 560.0, 760.0)
	var sw_saved := _load_sidebar_width()
	if sw_saved > 0.0:
		_sidebar_w = clampf(sw_saved, SIDEBAR_MIN_W, maxf(view.x * 0.94, SIDEBAR_MIN_W))

	# ---- 聊天面板（底部）----
	var panel_sb := StyleBoxFlat.new()
	panel_sb.bg_color = Color(0.05, 0.06, 0.09, 0.82)
	panel_sb.corner_radius_top_left = 20
	panel_sb.corner_radius_top_right = 20
	panel_sb.corner_radius_bottom_left = 20
	panel_sb.corner_radius_bottom_right = 20
	panel_sb.content_margin_left = 16
	panel_sb.content_margin_right = 16
	panel_sb.content_margin_top = 12
	panel_sb.content_margin_bottom = 12
	_chat_panel = PanelContainer.new()
	_chat_panel.set_anchors_preset(Control.PRESET_BOTTOM_WIDE)
	_chat_panel.offset_left = 16
	_chat_panel.offset_right = -16
	_chat_panel.offset_top = -840
	_chat_panel.offset_bottom = -16
	_chat_panel.add_theme_stylebox_override("panel", panel_sb)
	_ui_layer.add_child(_chat_panel)

	var chat_vbox := VBoxContainer.new()
	chat_vbox.add_theme_constant_override("separation", 16)
	_chat_panel.add_child(chat_vbox)

	var chat_head := HBoxContainer.new()
	chat_vbox.add_child(chat_head)

	var who := Label.new()
	who.text = "720"
	who.add_theme_font_size_override("font_size", 64)
	chat_head.add_child(who)

	var head_spacer := Control.new()
	head_spacer.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	chat_head.add_child(head_spacer)

	_emotion_label = Label.new()
	_emotion_label.text = "情绪：平静"
	_emotion_label.add_theme_font_size_override("font_size", 50)
	chat_head.add_child(_emotion_label)

	_chat_log = RichTextLabel.new()
	_chat_log.bbcode_enabled = true
	_chat_log.scroll_following = true
	_chat_log.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_chat_log.custom_minimum_size = Vector2(0, 460)
	_chat_log.add_theme_font_size_override("normal_font_size", 54)
	chat_vbox.add_child(_chat_log)

	var input_row := HBoxContainer.new()
	input_row.add_theme_constant_override("separation", 16)
	chat_vbox.add_child(input_row)

	_chat_input = LineEdit.new()
	_chat_input.placeholder_text = "和720说点什么…"
	_chat_input.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_chat_input.custom_minimum_size = Vector2(0, 132)
	_chat_input.add_theme_font_size_override("font_size", 54)
	_chat_input.text_submitted.connect(_on_send)
	input_row.add_child(_chat_input)

	_send_btn = Button.new()
	_send_btn.text = "发送"
	_send_btn.custom_minimum_size = Vector2(240, 132)
	_send_btn.add_theme_font_size_override("font_size", 54)
	_send_btn.pressed.connect(_on_send)
	input_row.add_child(_send_btn)

	# ---- 侧边栏 ----
	_sidebar = PanelContainer.new()
	_sidebar.position = Vector2(-_sidebar_w, 0)
	_sidebar.size = Vector2(_sidebar_w, view.y)
	_ui_layer.add_child(_sidebar)

	# ---- 侧边栏宽度拖拽手柄（右缘，向右拖加宽 / 向左拖收窄） ----
	_sidebar_handle = Control.new()
	_sidebar_handle.mouse_filter = Control.MOUSE_FILTER_STOP
	_sidebar_handle.mouse_default_cursor_shape = Control.CURSOR_HSIZE
	_sidebar_handle.size = Vector2(SIDEBAR_HANDLE_W, view.y)
	_sidebar_handle.visible = false
	_sidebar_handle.gui_input.connect(_on_sidebar_handle_input)
	_ui_layer.add_child(_sidebar_handle)
	_sidebar_handle_bar = ColorRect.new()
	_sidebar_handle_bar.color = Color(1.0, 1.0, 1.0, 0.22)
	_sidebar_handle_bar.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_sidebar_handle_bar.size = Vector2(10, 220)
	_sidebar_handle.add_child(_sidebar_handle_bar)

	var scroll := ScrollContainer.new()
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_sidebar.add_child(scroll)

	var vbox := VBoxContainer.new()
	vbox.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	vbox.add_theme_constant_override("separation", 20)
	scroll.add_child(vbox)

	var spacer := Control.new()
	spacer.custom_minimum_size = Vector2(0, 184)
	vbox.add_child(spacer)

	var title := Label.new()
	title.text = "Half-hearted AI"
	title.add_theme_font_size_override("font_size", 64)
	vbox.add_child(title)

	# ---- 角色模型 ----
	var mlbl := Label.new()
	mlbl.text = "-- 角色模型 --"
	mlbl.add_theme_font_size_override("font_size", 54)
	vbox.add_child(mlbl)

	_model_box = VBoxContainer.new()
	_model_box.add_theme_constant_override("separation", 12)
	vbox.add_child(_model_box)
	_refresh_model_list()

	# ---- 上传 / 动作测试 ----
	var up_lbl := Label.new()
	up_lbl.text = "换模型（推荐：从手机选择文件）"
	up_lbl.add_theme_font_size_override("font_size", 50)
	vbox.add_child(up_lbl)
	_up_btn = Button.new()
	_up_btn.text = "从手机选择 .vrm / .zip"
	_up_btn.add_theme_font_size_override("font_size", 52)
	_up_btn.custom_minimum_size = Vector2(0, 128)
	_up_btn.pressed.connect(_on_upload_pressed)
	vbox.add_child(_up_btn)
	# ---- 文件夹自动识别 ----
	var scan_lbl := Label.new()
	scan_lbl.text = "文件夹自动识别"
	scan_lbl.add_theme_font_size_override("font_size", 50)
	vbox.add_child(scan_lbl)
	var scan_tip := Label.new()
	scan_tip.text = "把 .vrm / .zip 复制到手机文件夹：\n内部存储/Download/HalfHearted/\n放进去就会自动出现在这里"
	scan_tip.add_theme_font_size_override("font_size", 40)
	scan_tip.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	vbox.add_child(scan_tip)
	_scan_box = VBoxContainer.new()
	_scan_box.add_theme_constant_override("separation", 12)
	vbox.add_child(_scan_box)
	_refresh_folder_models()
	var act_lbl := Label.new()
	act_lbl.text = "动作测试"
	act_lbl.add_theme_font_size_override("font_size", 50)
	vbox.add_child(act_lbl)
	var act_row := HBoxContainer.new()
	act_row.add_theme_constant_override("separation", 12)
	for item in [["点头", "nod"], ["摇头", "shake"], ["歪头", "tilt_head"]]:
		var ab := Button.new()
		ab.text = item[0]
		ab.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		ab.custom_minimum_size = Vector2(0, 120)
		ab.add_theme_font_size_override("font_size", 48)
		ab.pressed.connect(_test_action.bind(item[1]))
		act_row.add_child(ab)
	vbox.add_child(act_row)

	var dl_lbl := Label.new()
	dl_lbl.text = "下载新模型（.vrm 直链）"
	dl_lbl.add_theme_font_size_override("font_size", 50)
	vbox.add_child(dl_lbl)

	_dl_url_edit = LineEdit.new()
	_dl_url_edit.placeholder_text = "粘贴 .vrm 下载链接…"
	_dl_url_edit.add_theme_font_size_override("font_size", 46)
	_dl_url_edit.custom_minimum_size = Vector2(0, 128)
	vbox.add_child(_dl_url_edit)

	_dl_btn = Button.new()
	_dl_btn.text = "下载并切换"
	_dl_btn.add_theme_font_size_override("font_size", 52)
	_dl_btn.custom_minimum_size = Vector2(0, 128)
	_dl_btn.pressed.connect(_on_download_pressed)
	vbox.add_child(_dl_btn)

	_dl_label = Label.new()
	_dl_label.text = ""
	_dl_label.add_theme_font_size_override("font_size", 44)
	_dl_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	vbox.add_child(_dl_label)

	_scale_slider = _add_slider_row(vbox, "缩放", 0.5, 2.0, 0.05, 1.0, _on_scale_changed)
	_rot_slider = _add_slider_row(vbox, "旋转", -180.0, 180.0, 5.0, 0.0, _on_rot_changed)
	_dist_slider = _add_slider_row(vbox, "相机距离", 1.0, 8.0, 0.1, _cam_distance, _on_dist_changed)
	_pitch_slider = _add_slider_row(vbox, "相机俯仰", -45.0, 75.0, 1.0, _cam_pitch, _on_pitch_changed)

	# ---- AI 设置 ----
	var ai_lbl := Label.new()
	ai_lbl.text = "-- AI 设置 --"
	ai_lbl.add_theme_font_size_override("font_size", 54)
	vbox.add_child(ai_lbl)

	var k_lbl := Label.new()
	k_lbl.text = "DeepSeek 密钥"
	k_lbl.add_theme_font_size_override("font_size", 50)
	vbox.add_child(k_lbl)

	_key_edit = LineEdit.new()
	_key_edit.secret = true
	_key_edit.placeholder_text = "sk-..."
	_key_edit.add_theme_font_size_override("font_size", 46)
	_key_edit.custom_minimum_size = Vector2(0, 128)
	if _brain:
		_key_edit.text = _brain.api_key
	vbox.add_child(_key_edit)

	var m_lbl := Label.new()
	m_lbl.text = "对话模型（DeepSeek）"
	m_lbl.add_theme_font_size_override("font_size", 50)
	vbox.add_child(m_lbl)

	_model_edit = LineEdit.new()
	_model_edit.add_theme_font_size_override("font_size", 46)
	_model_edit.custom_minimum_size = Vector2(0, 128)
	if _brain:
		_model_edit.text = _brain.model
	vbox.add_child(_model_edit)

	var btn_row := HBoxContainer.new()
	btn_row.add_theme_constant_override("separation", 16)
	vbox.add_child(btn_row)

	_save_btn = Button.new()
	_save_btn.text = "保存设置"
	_save_btn.add_theme_font_size_override("font_size", 52)
	_save_btn.custom_minimum_size = Vector2(0, 128)
	_save_btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_save_btn.pressed.connect(_on_save_settings)
	btn_row.add_child(_save_btn)

	_test_btn = Button.new()
	_test_btn.text = "测试连接"
	_test_btn.add_theme_font_size_override("font_size", 52)
	_test_btn.custom_minimum_size = Vector2(0, 128)
	_test_btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_test_btn.pressed.connect(_on_test_pressed)
	btn_row.add_child(_test_btn)

	_tts_check = CheckBox.new()
	_tts_check.text = "语音朗读"
	_tts_check.add_theme_font_size_override("font_size", 52)
	_tts_check.button_pressed = _brain.tts_enabled if _brain else true
	_tts_check.toggled.connect(_on_tts_toggled)
	vbox.add_child(_tts_check)

	_clear_btn = Button.new()
	_clear_btn.text = "清空对话记忆"
	_clear_btn.add_theme_font_size_override("font_size", 52)
	_clear_btn.custom_minimum_size = Vector2(0, 128)
	_clear_btn.pressed.connect(_on_clear_pressed)
	vbox.add_child(_clear_btn)

	_status = Label.new()
	_status.text = "就绪"
	_status.add_theme_font_size_override("font_size", 46)
	_status.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	vbox.add_child(_status)

	# ---- 菜单按钮 ----
	_menu_btn = Button.new()
	_menu_btn.text = "\u2630"
	_menu_btn.position = Vector2(20, 20)
	_menu_btn.size = Vector2(140, 140)
	_menu_btn.add_theme_font_size_override("font_size", 88)
	_menu_btn.pressed.connect(_toggle_sidebar)
	_ui_layer.add_child(_menu_btn)

	# ---- 顶部提示条（重要消息直接显示在画面顶部）----
	_toast = Label.new()
	_toast.set_anchors_preset(Control.PRESET_TOP_WIDE)
	_toast.offset_left = 24
	_toast.offset_right = -24
	_toast.offset_top = 190
	_toast.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_toast.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_toast.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_toast.add_theme_font_size_override("font_size", 50)
	_toast.add_theme_color_override("font_color", Color(1, 1, 1))
	_toast.add_theme_color_override("font_outline_color", Color(0, 0, 0, 0.9))
	_toast.add_theme_constant_override("outline_size", 12)
	_toast.modulate.a = 0.0
	_ui_layer.add_child(_toast)

	# ---- 下载器 ----
	_dl_http = HTTPRequest.new()
	_dl_http.timeout = 300.0
	add_child(_dl_http)
	_dl_http.request_completed.connect(_on_download_completed)

	# ---- 欢迎语 ----
	if _brain and _brain.configured():
		_chat_append("系统", "720已就绪，说点什么吧", "#9fd0ff")
	else:
		_chat_append("系统", "欢迎使用！先点左上角 ☰，在「AI 设置」里填入 DeepSeek 密钥，然后就可以对话了。想换模型？把模型复制到 Download/HalfHearted/ 会自动识别，也可以点「从手机选择」。", "#9fd0ff")

func _show_status(msg: String) -> void:
	if _status:
		_status.text = msg
	_toast_show(msg)

func _setup_environment() -> void:
	var we := WorldEnvironment.new()
	var env := Environment.new()
	env.background_mode = Environment.BG_COLOR
	env.background_color = Color(0.08, 0.09, 0.13)
	env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.ambient_light_color = Color(0.7, 0.7, 0.8)
	env.ambient_light_energy = 0.6
	we.environment = env
	add_child(we)

func _setup_light() -> void:
	var sun := DirectionalLight3D.new()
	sun.rotation_degrees = Vector3(-50.0, -30.0, 0.0)
	sun.light_energy = 1.4
	sun.shadow_enabled = true
	add_child(sun)

func _setup_camera() -> void:
	_cam = Camera3D.new()
	add_child(_cam)
	_update_camera()

func _setup_cube() -> void:
	_cube = MeshInstance3D.new()
	var mesh := BoxMesh.new()
	mesh.size = Vector3(0.9, 0.9, 0.9)
	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color(0.85, 0.16, 0.20)
	mesh.material = mat
	_cube.mesh = mesh
	_cube.position = Vector3(0.0, 0.6, 0.0)
	add_child(_cube)