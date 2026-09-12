class_name AvatarController
extends Node
## 720 的角色驱动器：表情（blend shape）、眨眼、口型、情绪姿态、动作。
## 全部防御式实现：模型缺少对应资源时静默跳过，绝不报错崩溃。
##
## 已验证（gwen.vrm，2026-09-12 本地 Godot 探针）：
## - Head 局部轴：X=低头(+)/抬头(-)，Y=左转(+)/右转(-)，Z=侧倾
## - Jaw 局部 X 负角 = 张嘴（骨骼无子节点，靠蒙皮呈现）
## - 眨眼 = morph_0（blink/blinkLeft/blinkRight 对应 0/1/2）
## - 视线 posedelta 可从 AnimationPlayer 的 lookUp/Down/Left/Right 动画提取

signal emotion_applied(emotion: String)

const EMOTIONS := ["neutral", "happy", "sad", "angry", "surprised", "shy", "thinking"]

# 情绪 -> blend shape 候选名（小写；短词仅精确匹配，长词可子串匹配）
const SHAPE_CANDIDATES := {
	"happy": ["happy", "joy", "fun", "smile", "fcl_all_joy", "fcl_all_fun", "mouthsmile"],
	"sad": ["sad", "sorrow", "fcl_all_sorrow"],
	"angry": ["angry", "anger", "fcl_all_angry"],
	"surprised": ["surprised", "surprise", "fcl_all_surprised"],
	"shy": ["shy", "embarrass", "blush"],
	"thinking": ["think"],
}

# 情绪 -> 头部姿态偏移（度）：x=低头(+)/抬头(-)，y=左转(+)/右转(-)，z=侧倾
const EMOTION_HEAD := {
	"neutral": Vector3(0, 0, 0),
	"happy": Vector3(-5, 0, 4),
	"sad": Vector3(10, 0, -4),
	"angry": Vector3(7, 0, 0),
	"surprised": Vector3(-9, 0, 0),
	"shy": Vector3(3, 14, 6),
	"thinking": Vector3(-6, -9, -4),
}

# 情绪 -> 视线方向（x: 左+/右-，y: 上+/下-，0~1 比例）
const EMOTION_EYES := {
	"neutral": Vector2(0, 0),
	"happy": Vector2(0, 0.15),
	"sad": Vector2(0, -0.5),
	"angry": Vector2(0, 0),
	"surprised": Vector2(0, 0.3),
	"shy": Vector2(-0.5, -0.15),
	"thinking": Vector2(-0.4, 0.45),
}

const HEAD_NOD := [Vector3(26, 0, 0), Vector3(-6, 0, 0), Vector3(18, 0, 0), Vector3.ZERO]
const HEAD_SHAKE := [Vector3(0, 20, 0), Vector3(0, -20, 0), Vector3(0, 15, 0), Vector3.ZERO]
const HEAD_TILT := [Vector3(0, 0, 20), Vector3.ZERO]
const ACTION_STEP_TIME := 0.24

var _avatar: Node3D = null
var _skel: Skeleton3D = null
var _meshes: Array = []
var _anim: AnimationPlayer = null

var _head_idx := -1
var _jaw_idx := -1
var _eye_l_idx := -1
var _eye_r_idx := -1
var _eye_def := Quaternion(0.707107, 0, 0, 0.707107)
var _look_deltas := {}

var _blink := {}
var _blink_l := {}
var _blink_r := {}
var _talk_open := {}

var _emotion := "neutral"
var _shape_vals := []      # [{mi, idx, value, target}] 情绪形态键平滑器
var _emotion_shapes := []  # [{mi, idx}]

var _head_offset := Vector3.ZERO
var _head_target := Vector3.ZERO
var _act_offset := Vector3.ZERO
var _act_target := Vector3.ZERO
var _act_seq := []
var _act_step := 0
var _act_timer := 0.0

var _eye_dir := Vector2.ZERO
var _eye_target := Vector2.ZERO
var _eye_wander := 4.0

var _jaw_angle := 0.0
var _talking := false
var _talk_phase := 0.0

var _blink_next := 2.5
var _blink_time := -1.0
var _blink_queue := 0

func setup(avatar: Node3D) -> void:
	_avatar = avatar
	if _avatar == null:
		return
	randomize()
	_skel = _find_first(_avatar, "Skeleton3D") as Skeleton3D
	_meshes.clear()
	_collect_meshes(_avatar)
	_anim = _find_first(_avatar, "AnimationPlayer") as AnimationPlayer
	if _skel:
		_head_idx = _find_bone(_skel, "Head")
		_jaw_idx = _find_bone(_skel, "Jaw")
		if _jaw_idx < 0:
			# 兜底：按后缀找 jaw（兼容不同命名的 VRM0 骨骼）
			for i in range(_skel.get_bone_count()):
				if String(_skel.get_bone_name(i)).to_lower().ends_with("jaw"):
					_jaw_idx = i
					break
		_eye_l_idx = _find_bone(_skel, "LeftEye")
		_eye_r_idx = _find_bone(_skel, "RightEye")
	_read_look_poses()
	_setup_blink()
	_setup_talk_shapes()
	print("[AvatarController] skel=", _skel != null, " head=", _head_idx, " jaw=", _jaw_idx,
		" eyes=", _eye_l_idx, "/", _eye_r_idx, " meshes=", _meshes.size(),
		" blink=", not _blink.is_empty(), " look_deltas=", _look_deltas.size())

func get_emotion() -> String:
	return _emotion

func set_emotion(e: String) -> void:
	if not EMOTIONS.has(e):
		e = "neutral"
	_emotion = e
	_head_target = EMOTION_HEAD.get(e, Vector3.ZERO)
	_eye_target = EMOTION_EYES.get(e, Vector2.ZERO)
	_apply_emotion_shapes(e)
	emotion_applied.emit(e)

func play_action(a: String) -> void:
	match a:
		"nod", "点头":
			_act_seq = HEAD_NOD.duplicate()
		"shake", "摇头":
			_act_seq = HEAD_SHAKE.duplicate()
		"tilt_head", "歪头":
			_act_seq = HEAD_TILT.duplicate()
		_:
			return
	_act_step = 0
	_act_timer = 0.0
	_act_target = _act_seq[0]

func set_talking(on: bool) -> void:
	_talking = on
	_talk_phase = 0.0
	if not on:
		_set_direct(_talk_open, 0.0)

func _process(delta: float) -> void:
	if _avatar == null or not is_instance_valid(_avatar):
		return
	_tick_blink(delta)
	_tick_mouth(delta)
	_tick_head(delta)
	_tick_eyes(delta)
	_tick_shapes(delta)

# ---------------------------------------------------------------- blink

func _tick_blink(delta: float) -> void:
	_blink_next -= delta
	if _blink_time < 0.0 and _blink_next <= 0.0:
		_blink_time = 0.0
		_blink_queue = 1 if randf() < 0.3 else 0
	if _blink_time >= 0.0:
		_blink_time += delta
		var t := _blink_time
		var v := 0.0
		if t < 0.06:
			v = t / 0.06
		elif t < 0.10:
			v = 1.0
		elif t < 0.20:
			v = 1.0 - (t - 0.10) / 0.10
		else:
			_blink_time = -1.0
			if _blink_queue > 0:
				_blink_queue -= 1
				_blink_time = 0.0
			else:
				_blink_next = randf_range(2.5, 5.5)
		if not _blink.is_empty():
			_set_direct(_blink, v * 0.9)
		else:
			_set_direct(_blink_l, v * 0.9)
			_set_direct(_blink_r, v * 0.9)

# ---------------------------------------------------------------- mouth

func _tick_mouth(delta: float) -> void:
	var jaw_target := 0.0
	if _talking:
		_talk_phase += delta * 9.0
		var s := 0.5 + 0.5 * sin(_talk_phase * 2.0)
		s = pow(s, 1.5)
		if not _talk_open.is_empty():
			_set_direct(_talk_open, s * 0.75)
		else:
			jaw_target = -0.07 * s
	_jaw_angle = lerpf(_jaw_angle, jaw_target, clampf(delta * 18.0, 0.0, 1.0))
	if _skel and _jaw_idx >= 0:
		_skel.set_bone_pose_rotation(_jaw_idx, Quaternion(Vector3(1, 0, 0), _jaw_angle))

# ---------------------------------------------------------------- head

func _tick_head(delta: float) -> void:
	_head_offset = _head_offset.lerp(_head_target, clampf(delta * 6.0, 0.0, 1.0))
	if not _act_seq.is_empty():
		_act_timer += delta
		if _act_timer >= ACTION_STEP_TIME:
			_act_timer = 0.0
			_act_step += 1
			if _act_step < _act_seq.size():
				_act_target = _act_seq[_act_step]
			else:
				_act_seq = []
				_act_target = Vector3.ZERO
	_act_offset = _act_offset.lerp(_act_target, clampf(delta * 14.0, 0.0, 1.0))
	if _skel and _head_idx >= 0:
		var total := _head_offset + _act_offset
		var e := Vector3(deg_to_rad(total.x), deg_to_rad(total.y), deg_to_rad(total.z))
		var q := Quaternion(Basis.from_euler(e))
		_skel.set_bone_pose_rotation(_head_idx, q)

# ---------------------------------------------------------------- eyes

func _tick_eyes(delta: float) -> void:
	_eye_wander -= delta
	if _eye_wander <= 0.0:
		_eye_wander = randf_range(3.5, 7.5)
		if _emotion == "neutral":
			_eye_target = Vector2(randf_range(-0.5, 0.5), randf_range(-0.3, 0.3))
	_eye_dir = _eye_dir.lerp(_eye_target, clampf(delta * 6.0, 0.0, 1.0))
	if _skel and _eye_l_idx >= 0 and _eye_r_idx >= 0 and not _look_deltas.is_empty():
		var q := _eye_pose(_eye_dir)
		_skel.set_bone_pose_rotation(_eye_l_idx, q)
		_skel.set_bone_pose_rotation(_eye_r_idx, q)

func _eye_pose(dir: Vector2) -> Quaternion:
	var q := _eye_def
	var parts := [
		[_look_deltas.get("up"), maxf(dir.y, 0.0)],
		[_look_deltas.get("down"), maxf(-dir.y, 0.0)],
		[_look_deltas.get("left"), maxf(dir.x, 0.0)],
		[_look_deltas.get("right"), maxf(-dir.x, 0.0)],
	]
	for p in parts:
		var d = p[0]
		var amt: float = p[1]
		if d != null and amt > 0.0:
			q = _qscale(d, amt) * q
	return q

func _qscale(q: Quaternion, s: float) -> Quaternion:
	if q.w > 0.999999:
		return Quaternion.IDENTITY
	return Quaternion(q.get_axis(), q.get_angle() * s)

# ---------------------------------------------------------------- shapes

func _tick_shapes(delta: float) -> void:
	for d in _shape_vals:
		d["value"] = lerpf(float(d["value"]), float(d["target"]), clampf(delta * 8.0, 0.0, 1.0))
		var mi: MeshInstance3D = d["mi"]
		if is_instance_valid(mi):
			mi.set_blend_shape_value(int(d["idx"]), float(d["value"]))

func _apply_emotion_shapes(e: String) -> void:
	for d in _emotion_shapes:
		_set_shape_target(d, 0.0)
	_emotion_shapes.clear()
	var cands = SHAPE_CANDIDATES.get(e, [])
	if cands.is_empty():
		return
	for c in cands:
		var d := _find_shape([c])
		if not d.is_empty() and not _has_emotion_shape(d):
			_emotion_shapes.append(d)
			_set_shape_target(d, 1.0)

func _has_emotion_shape(d: Dictionary) -> bool:
	for e in _emotion_shapes:
		if e["mi"] == d["mi"] and e["idx"] == d["idx"]:
			return true
	return false

func _set_shape_target(d: Dictionary, target: float) -> void:
	for s in _shape_vals:
		if s["mi"] == d["mi"] and s["idx"] == d["idx"]:
			s["target"] = target
			return
	var mi: MeshInstance3D = d["mi"]
	var idx: int = d["idx"]
	_shape_vals.append({"mi": mi, "idx": idx, "value": mi.get_blend_shape_value(idx), "target": target})

func _set_direct(d: Dictionary, v: float) -> void:
	if d.is_empty():
		return
	var mi: MeshInstance3D = d["mi"]
	if is_instance_valid(mi):
		mi.set_blend_shape_value(int(d["idx"]), v)

# ---------------------------------------------------------------- lookup

func _setup_blink() -> void:
	_blink = _find_shape(["blink", "eye_close", "fcl_eye_close", "闭眼", "眨眼"])
	_blink_l = _find_shape(["blinkleft", "blink_left", "eye_close_l", "fcl_eye_close_l", "左眼闭", "左闭眼"])
	_blink_r = _find_shape(["blinkright", "blink_right", "eye_close_r", "fcl_eye_close_r", "右眼闭", "右闭眼"])
	# 通用 morph_N 命名兜底（gwen.vrm：0=blink, 1=blinkLeft, 2=blinkRight）
	if _blink.is_empty():
		for mi in _meshes:
			var m: Mesh = mi.mesh
			if m == null:
				continue
			if m.get_blend_shape_count() == 3 and String(m.get_blend_shape_name(0)).begins_with("morph"):
				_blink = {"mi": mi, "idx": 0}
				if _blink_l.is_empty():
					_blink_l = {"mi": mi, "idx": 1}
				if _blink_r.is_empty():
					_blink_r = {"mi": mi, "idx": 2}
				break
	# 若主眨眼只匹配到单眼（如 furina 的 vrc.blink_left），改为左右眼同步驱动
	if not _blink.is_empty() and not _blink_l.is_empty() and not _blink_r.is_empty():
		if _same_shape(_blink, _blink_l) or _same_shape(_blink, _blink_r):
			_blink = {}

func _setup_talk_shapes() -> void:
	# 口型优先：VRM0 标准 A 口 / 中文模型常见 "a"；再退到英文命名
	_talk_open = _find_shape(["aa", "a", "fcl_mth_a", "mouthopen", "jawopen"])

func _read_look_poses() -> void:
	if _anim == null:
		return
	var q_def = _eye_quat_from_anim("neutral")
	if q_def != null:
		_eye_def = q_def
	var names := {"up": "lookUp", "down": "lookDown", "left": "lookLeft", "right": "lookRight"}
	for k in names:
		var q = _eye_quat_from_anim(names[k])
		if q != null:
			_look_deltas[k] = q * _eye_def.inverse()

func _eye_quat_from_anim(an: String) -> Variant:
	if _anim == null or not _anim.has_animation(an):
		return null
	var a := _anim.get_animation(an)
	for ti in range(a.get_track_count()):
		if a.track_get_type(ti) != Animation.TYPE_ROTATION_3D:
			continue
		var p := String(a.track_get_path(ti))
		if p.find("Eye") >= 0 or p.find("eye") >= 0:
			var v = a.track_get_key_value(ti, 0)
			if v is Quaternion:
				return v
	return null

func _find_shape(cands: Array) -> Dictionary:
	# 第一遍：精确匹配
	for mi in _meshes:
		var m: Mesh = mi.mesh
		if m == null:
			continue
		for i in range(m.get_blend_shape_count()):
			var n := String(m.get_blend_shape_name(i)).to_lower()
			for c in cands:
				if n == String(c):
					return {"mi": mi, "idx": i}
	# 第二遍：子串匹配（仅长词，避免 "ou" 撞 "mouth" 之类的误伤）
	for mi in _meshes:
		var m2: Mesh = mi.mesh
		if m2 == null:
			continue
		for i in range(m2.get_blend_shape_count()):
			var n2 := String(m2.get_blend_shape_name(i)).to_lower()
			for c in cands:
				var cs := String(c)
				if cs.length() >= 4 and n2.find(cs) >= 0:
					return {"mi": mi, "idx": i}
	return {}

func _same_shape(a: Dictionary, b: Dictionary) -> bool:
	if a.is_empty() or b.is_empty():
		return false
	return a["mi"] == b["mi"] and int(a["idx"]) == int(b["idx"])

func _collect_meshes(n: Node) -> void:
	if n is MeshInstance3D:
		_meshes.append(n)
	for c in n.get_children():
		_collect_meshes(c)

func _find_bone(sk: Skeleton3D, bn: String) -> int:
	for i in range(sk.get_bone_count()):
		if String(sk.get_bone_name(i)).to_lower() == bn.to_lower():
			return i
	return -1

func _find_first(n: Node, cls: String) -> Object:
	if n.is_class(cls):
		return n
	for c in n.get_children():
		var r = _find_first(c, cls)
		if r != null:
			return r
	return null
