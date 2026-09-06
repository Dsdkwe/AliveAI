extends Node3D

var _avatar: Node3D = null
var _cube: MeshInstance3D = null
var _drag_active := false
var _last_touch := Vector2.ZERO
var _status: Label = null

func _ready() -> void:
	_setup_environment()
	_setup_light()
	_setup_camera()
	_status = _setup_hud()
	_load_vrm()

func _process(delta: float) -> void:
	if _avatar:
		_avatar.rotate_y(delta * 0.3)
	elif _cube:
		_cube.rotate_y(delta * 0.8)

func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventScreenTouch:
		_drag_active = event.pressed
		_last_touch = event.position
		return
	if event is InputEventScreenDrag and _drag_active:
		var drag := event as InputEventScreenDrag
		var target: Node3D = _avatar if _avatar else _cube
		if target:
			target.rotate_y((drag.position.x - _last_touch.x) * 0.01)
		_last_touch = drag.position

func _load_vrm() -> void:
	var vrm_path := "res://assets/models/gwen.vrm"
	if not ResourceLoader.exists(vrm_path):
		_show_status("VRM not found -> cube")
		_setup_cube()
		return
	var packed = load(vrm_path)
	if packed == null:
		_show_status("VRM load failed -> cube")
		_setup_cube()
		return
	_avatar = packed.instantiate()
	if _avatar == null:
		_show_status("VRM instantiate failed -> cube")
		_setup_cube()
		return
	add_child(_avatar)
	_show_status("VRM loaded: gwen.vrm")

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
	var cam := Camera3D.new()
	cam.position = Vector3(0.0, 1.25, 3.0)
	cam.look_at(Vector3(0.0, 1.0, 0.0))
	add_child(cam)

func _setup_hud() -> Label:
	var layer := CanvasLayer.new()
	var label := Label.new()
	label.text = "Half-hearted AI | loading..."
	label.position = Vector2(24, 24)
	label.add_theme_font_size_override("font_size", 26)
	label.add_theme_color_override("font_color", Color.WHITE)
	layer.add_child(label)
	add_child(layer)
	return label

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
