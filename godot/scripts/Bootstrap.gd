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

func _ready() -> void:
	_setup_environment()
	_setup_light()
	_setup_camera()
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
	if not ResourceLoader.exists(path):
		_show_status("VRM not found: " + path.get_file())
		_setup_cube()
		return
	var packed = load(path)
	if packed == null:
		_show_status("VRM load failed: " + path.get_file())
		_setup_cube()
		return
	if _avatar:
		_avatar.queue_free()
		_avatar = null
	_avatar = packed.instantiate()
	if _avatar == null:
		_show_status("VRM instantiate failed")
		_setup_cube()
		return
	add_child(_avatar)
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

func _setup_ui() -> void:
	_ui_layer = CanvasLayer.new()
	add_child(_ui_layer)

	var view: Vector2 = get_viewport().get_visible_rect().size
	_sidebar_w = clamp(view.x * 0.42, 300.0, 480.0)

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

	_status = Label.new()
	_status.text = "Half-hearted AI | ready"
	_status.add_theme_font_size_override("font_size", 16)
	_status.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	vbox.add_child(_status)

	_menu_btn = Button.new()
	_menu_btn.text = "\u2630"
	_menu_btn.position = Vector2(16, 16)
	_menu_btn.size = Vector2(88, 88)
	_menu_btn.add_theme_font_size_override("font_size", 42)
	_menu_btn.pressed.connect(_toggle_sidebar)
	_ui_layer.add_child(_menu_btn)

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
