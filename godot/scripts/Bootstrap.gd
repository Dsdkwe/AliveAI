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
const FONT_PATH := "res://assets/fonts/SmileySans-Oblique.ttf"

const EMO_CN := {
	"neutral": "平静",
	"happy": "开心",
	"sad": "难过",
	"angry": "生气",
	"surprised": "惊讶",
	"shy": "害羞",
	"thinking": "思考",
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

func _ready() -> void:
	_setup_font()
	_setup_environment()
	_setup_light()
	_setup_camera()
	_setup_ai()
	_setup_ui()
	_load_vrm(MODEL_DIR + "/gwen.vrm")

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
	if _avatar_ctrl:
		_avatar_ctrl.set_process(false)
		_avatar_ctrl.queue_free()
		_avatar_ctrl = null
	if _avatar:
		_avatar.queue_free()
		_avatar = null
	if not ResourceLoader.exists(path):
		_show_status("VRM not found: " + path.get_file())
		_setup_cube()
		return
	var packed = load(path)
	if packed == null:
		_show_status("VRM load failed: " + path.get_file())
		_setup_cube()
		return
	_avatar = packed.instantiate()
	if _avatar == null:
		_show_status("VRM instantiate failed")
		_setup_cube()
		return
	add_child(_avatar)
	if _cube:
		_cube.queue_free()
		_cube = null
	_avatar_ctrl = AvatarController.new()
	_avatar_ctrl.name = "AvatarController"
	add_child(_avatar_ctrl)
	_avatar_ctrl.setup(_avatar)
	_apply_current_transforms()
	_show_status("VRM loaded: " + path.get_file())

func _apply_current_transforms() -> void:
	if not _avatar:
		return
	if _scale_slider:
		_avatar.scale = Vector3.ONE * _scale_slider.value
	if _rot_slider:
		_avatar.rotation.y = deg_to_rad(_rot_slider.value)

func _list_models() -> Array:
	var out: Array = []
	var dir := DirAccess.open(MODEL_DIR)
	if dir == null:
		return out
	dir.list_dir_begin()
	var f := dir.get_next()
	while f != "":
		if f.ends_with(".vrm"):
			out.append(f)
		f = dir.get_next()
	dir.list_dir_end()
	out.sort()
	return out

func _refresh_model_list() -> void:
	if _model_box == null:
		return
	for c in _model_box.get_children():
		c.queue_free()
	var models := _list_models()
	if models.is_empty():
		var empty := Label.new()
		empty.text = "(no .vrm models)"
		empty.add_theme_font_size_override("font_size", 16)
		_model_box.add_child(empty)
		return
	for m in models:
		var b := Button.new()
		b.text = m
		b.add_theme_font_size_override("font_size", 15)
		b.pressed.connect(_on_model_picked.bind(m))
		_model_box.add_child(b)

func _on_model_picked(fname: String) -> void:
	_load_vrm(MODEL_DIR + "/" + fname)

func _toggle_sidebar() -> void:
	_sidebar_open = not _sidebar_open
	var target_x := 0.0 if _sidebar_open else -_sidebar_w
	var tween := create_tween()
	tween.tween_property(_sidebar, "position:x", target_x, 0.25)

func _add_slider_row(parent: Control, title: String, min_v: float, max_v: float, step_v: float, init_v: float, cb: Callable) -> HSlider:
	var lbl := Label.new()
	lbl.text = title
	lbl.add_theme_font_size_override("font_size", 18)
	parent.add_child(lbl)
	var s := HSlider.new()
	s.min_value = min_v
	s.max_value = max_v
	s.step = step_v
	s.value = init_v
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
		_emotion_label.text = "情绪: " + _emo_cn(emotion)
	if _avatar_ctrl:
		_avatar_ctrl.set_emotion(emotion)
		if action != "" and action != "none":
			_avatar_ctrl.play_action(action)
	if _tts and _tts.enabled and _tts_check and _tts_check.button_pressed:
		_tts.speak(text)
	if _send_btn:
		_send_btn.disabled = false
	_show_status("已回复（" + emotion + " / " + action + "）")

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
	theme.default_font_size = 22
	var win := get_window()
	if win:
		win.theme = theme
	print("[Bootstrap] font=", f != null, " font_path=", FONT_PATH)

func _setup_ui() -> void:
	_ui_layer = CanvasLayer.new()
	add_child(_ui_layer)

	var view: Vector2 = get_viewport().get_visible_rect().size
	_sidebar_w = clamp(view.x * 0.42, 300.0, 480.0)

	# ---- 聊天面板（底部，先加 → 侧边栏可滑过它）----
	var panel_sb := StyleBoxFlat.new()
	panel_sb.bg_color = Color(0.05, 0.06, 0.09, 0.82)
	panel_sb.corner_radius_top_left = 16
	panel_sb.corner_radius_top_right = 16
	panel_sb.corner_radius_bottom_left = 16
	panel_sb.corner_radius_bottom_right = 16
	panel_sb.content_margin_left = 12
	panel_sb.content_margin_right = 12
	panel_sb.content_margin_top = 10
	panel_sb.content_margin_bottom = 10
	_chat_panel = PanelContainer.new()
	_chat_panel.set_anchors_preset(Control.PRESET_BOTTOM_WIDE)
	_chat_panel.offset_left = 12
	_chat_panel.offset_right = -12
	_chat_panel.offset_top = -430
	_chat_panel.offset_bottom = -12
	_chat_panel.add_theme_stylebox_override("panel", panel_sb)
	_ui_layer.add_child(_chat_panel)

	var chat_vbox := VBoxContainer.new()
	chat_vbox.add_theme_constant_override("separation", 8)
	_chat_panel.add_child(chat_vbox)

	var chat_head := HBoxContainer.new()
	chat_vbox.add_child(chat_head)

	var who := Label.new()
	who.text = "720"
	who.add_theme_font_size_override("font_size", 24)
	chat_head.add_child(who)

	var head_spacer := Control.new()
	head_spacer.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	chat_head.add_child(head_spacer)

	_emotion_label = Label.new()
	_emotion_label.text = "情绪: 平静"
	_emotion_label.add_theme_font_size_override("font_size", 18)
	chat_head.add_child(_emotion_label)

	_chat_log = RichTextLabel.new()
	_chat_log.bbcode_enabled = true
	_chat_log.scroll_following = true
	_chat_log.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_chat_log.custom_minimum_size = Vector2(0, 220)
	_chat_log.add_theme_font_size_override("normal_font_size", 20)
	chat_vbox.add_child(_chat_log)

	var input_row := HBoxContainer.new()
	input_row.add_theme_constant_override("separation", 8)
	chat_vbox.add_child(input_row)

	_chat_input = LineEdit.new()
	_chat_input.placeholder_text = "和720说点什么…"
	_chat_input.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_chat_input.add_theme_font_size_override("font_size", 20)
	_chat_input.text_submitted.connect(_on_send)
	input_row.add_child(_chat_input)

	_send_btn = Button.new()
	_send_btn.text = "发送"
	_send_btn.add_theme_font_size_override("font_size", 20)
	_send_btn.pressed.connect(_on_send)
	input_row.add_child(_send_btn)

	# ---- 侧边栏 ----
	_sidebar = PanelContainer.new()
	_sidebar.position = Vector2(-_sidebar_w, 0)
	_sidebar.size = Vector2(_sidebar_w, view.y)
	_ui_layer.add_child(_sidebar)

	var scroll := ScrollContainer.new()
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_sidebar.add_child(scroll)

	var vbox := VBoxContainer.new()
	vbox.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	vbox.add_theme_constant_override("separation", 10)
	scroll.add_child(vbox)

	var spacer := Control.new()
	spacer.custom_minimum_size = Vector2(0, 96)
	vbox.add_child(spacer)

	var title := Label.new()
	title.text = "Half-hearted AI"
	title.add_theme_font_size_override("font_size", 28)
	vbox.add_child(title)

	var mlbl := Label.new()
	mlbl.text = "-- MODELS --"
	mlbl.add_theme_font_size_override("font_size", 18)
	vbox.add_child(mlbl)

	_model_box = VBoxContainer.new()
	vbox.add_child(_model_box)
	_refresh_model_list()

	_scale_slider = _add_slider_row(vbox, "Scale", 0.5, 2.0, 0.05, 1.0, _on_scale_changed)
	_rot_slider = _add_slider_row(vbox, "Rotate", -180.0, 180.0, 5.0, 0.0, _on_rot_changed)
	_dist_slider = _add_slider_row(vbox, "Camera Distance", 1.0, 8.0, 0.1, _cam_distance, _on_dist_changed)
	_pitch_slider = _add_slider_row(vbox, "Camera Pitch", -45.0, 75.0, 1.0, _cam_pitch, _on_pitch_changed)

	# ---- AI 设置 ----
	var ai_lbl := Label.new()
	ai_lbl.text = "-- AI 设置 --"
	ai_lbl.add_theme_font_size_override("font_size", 18)
	vbox.add_child(ai_lbl)

	var k_lbl := Label.new()
	k_lbl.text = "DeepSeek API Key"
	k_lbl.add_theme_font_size_override("font_size", 16)
	vbox.add_child(k_lbl)

	_key_edit = LineEdit.new()
	_key_edit.secret = true
	_key_edit.placeholder_text = "sk-..."
	_key_edit.add_theme_font_size_override("font_size", 15)
	if _brain:
		_key_edit.text = _brain.api_key
	vbox.add_child(_key_edit)

	var m_lbl := Label.new()
	m_lbl.text = "模型"
	m_lbl.add_theme_font_size_override("font_size", 16)
	vbox.add_child(m_lbl)

	_model_edit = LineEdit.new()
	_model_edit.add_theme_font_size_override("font_size", 15)
	if _brain:
		_model_edit.text = _brain.model
	vbox.add_child(_model_edit)

	var btn_row := HBoxContainer.new()
	btn_row.add_theme_constant_override("separation", 8)
	vbox.add_child(btn_row)

	_save_btn = Button.new()
	_save_btn.text = "保存设置"
	_save_btn.add_theme_font_size_override("font_size", 16)
	_save_btn.pressed.connect(_on_save_settings)
	btn_row.add_child(_save_btn)

	_test_btn = Button.new()
	_test_btn.text = "测试连接"
	_test_btn.add_theme_font_size_override("font_size", 16)
	_test_btn.pressed.connect(_on_test_pressed)
	btn_row.add_child(_test_btn)

	_tts_check = CheckBox.new()
	_tts_check.text = "语音朗读"
	_tts_check.add_theme_font_size_override("font_size", 16)
	_tts_check.button_pressed = _brain.tts_enabled if _brain else true
	_tts_check.toggled.connect(_on_tts_toggled)
	vbox.add_child(_tts_check)

	_clear_btn = Button.new()
	_clear_btn.text = "清空对话记忆"
	_clear_btn.add_theme_font_size_override("font_size", 16)
	_clear_btn.pressed.connect(_on_clear_pressed)
	vbox.add_child(_clear_btn)

	_status = Label.new()
	_status.text = "Half-hearted AI | ready"
	_status.add_theme_font_size_override("font_size", 16)
	_status.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	vbox.add_child(_status)

	# ---- 菜单按钮 ----
	_menu_btn = Button.new()
	_menu_btn.text = "\u2630"
	_menu_btn.position = Vector2(16, 16)
	_menu_btn.size = Vector2(88, 88)
	_menu_btn.add_theme_font_size_override("font_size", 42)
	_menu_btn.pressed.connect(_toggle_sidebar)
	_ui_layer.add_child(_menu_btn)

	# ---- 欢迎语 ----
	if _brain and _brain.configured():
		_chat_append("系统", "720已就绪，说点什么吧", "#9fd0ff")
	else:
		_chat_append("系统", "欢迎使用！先点左上角 ☰，在「AI 设置」里填入 DeepSeek API Key，然后就可以对话了", "#9fd0ff")

func _show_status(msg: String) -> void:
	if _status:
		_status.text = "Half-hearted AI | " + msg

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