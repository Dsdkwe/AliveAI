extends Node3D
## Bootstrap: minimal vertical-slice smoke test.
## Builds the whole scene in code (no editor needed).
## Shows a red rotating cube; touch-drag to rotate.

var _cube: MeshInstance3D
var _drag_active := false
var _last_touch := Vector2.ZERO

func _ready() -> void:
	_setup_environment()
	_setup_light()
	_setup_cube()
	_setup_camera()
	_setup_hud()

func _process(delta: float) -> void:
	if _cube:
		_cube.rotate_y(delta * 0.8)

func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventScreenTouch:
		_drag_active = event.pressed
		_last_touch = event.position
		return
	if event is InputEventScreenDrag and _drag_active:
		var drag := event as InputEventScreenDrag
		if _cube:
			_cube.rotate_y((drag.position.x - _last_touch.x) * 0.01)
			_cube.rotate_x((drag.position.y - _last_touch.y) * 0.01)
		_last_touch = drag.position

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
	sun.rotation_degrees = Vector3(-55.0, -35.0, 0.0)
	sun.light_energy = 1.2
	sun.shadow_enabled = true
	add_child(sun)

func _setup_cube() -> void:
	_cube = MeshInstance3D.new()
	var mesh := BoxMesh.new()
	mesh.size = Vector3(0.9, 0.9, 0.9)
	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color(0.85, 0.16, 0.20)
	mat.metallic = 0.1
	mat.roughness = 0.4
	mesh.material = mat
	_cube.mesh = mesh
	_cube.position = Vector3(0.0, 0.3, 0.0)
	add_child(_cube)

func _setup_camera() -> void:
	var cam := Camera3D.new()
	cam.position = Vector3(0.0, 1.4, 3.6)
	cam.look_at(Vector3(0.0, 0.3, 0.0))
	add_child(cam)

func _setup_hud() -> void:
	var layer := CanvasLayer.new()
	var label := Label.new()
	label.text = "Half-hearted AI | Godot OK\nTouch and drag to rotate"
	label.position = Vector2(24, 24)
	label.add_theme_font_size_override("font_size", 26)
	label.add_theme_color_override("font_color", Color.WHITE)
	layer.add_child(label)
	add_child(layer)
