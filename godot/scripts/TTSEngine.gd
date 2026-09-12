class_name TTSEngine
extends Node
## 系统 TTS 封装（Godot 内置 DisplayServer.tts_*）。
## 优先挑选中文语音；设备没有 TTS 引擎时优雅降级（发 tts_unavailable 信号）。

signal speech_started
signal speech_finished
signal tts_unavailable(message: String)

const VOICE_VOLUME := 90  # 0~100（音量）
const VOICE_PITCH := 1.0  # 0.0~2.0，1.0 = 默认音高
const VOICE_RATE := 1.0   # 0.1~10.0，1.0 = 正常语速

var enabled := true

var _voice := ""
var _speaking := false
var _checked := false
var _speak_time := 0
var _zh_voice_hint := ""

func speak(text: String) -> void:
	if not enabled or text.strip_edges() == "":
		return
	if not _checked:
		_checked = true
		_refresh_voice()
	if _voice == "":
		_refresh_voice()
	if _voice == "":
		tts_unavailable.emit("设备未检测到可用的 TTS 语音引擎" + _zh_voice_hint)
		return
	DisplayServer.tts_stop()
	DisplayServer.tts_speak(text, _voice, VOICE_VOLUME, VOICE_PITCH, VOICE_RATE, 0, true)
	_speaking = true
	_speak_time = Time.get_ticks_msec()
	set_process(true)
	speech_started.emit()

func stop() -> void:
	if not _speaking:
		return
	DisplayServer.tts_stop()
	_speaking = false
	set_process(false)
	speech_finished.emit()

func is_speaking() -> bool:
	return _speaking

func _ready() -> void:
	set_process(false)

func _process(_delta: float) -> void:
	if not _speaking:
		set_process(false)
		return
	var elapsed := Time.get_ticks_msec() - _speak_time
	if elapsed > 400 and not DisplayServer.tts_is_speaking():
		_speaking = false
		set_process(false)
		speech_finished.emit()

func _refresh_voice() -> void:
	var voices := DisplayServer.tts_get_voices()
	var zh := ""
	var zh_any := ""
	for v in voices:
		var id := str(v.get("id", ""))
		var lang := str(v.get("language", "")).to_lower()
		var name := str(v.get("name", "")).to_lower()
		if lang.begins_with("zh") or name.find("chinese") >= 0 or name.find("中文") >= 0:
			if lang.find("cn") >= 0 or lang.find("hans") >= 0 or name.find("chinese") >= 0:
				if zh == "":
					zh = id
			if zh_any == "":
				zh_any = id
	if zh != "":
		_voice = zh
	elif zh_any != "":
		_voice = zh_any
	elif voices.size() > 0:
		_voice = str(voices[0].get("id", ""))
	if zh == "" and voices.size() > 0:
		_zh_voice_hint = "（未找到中文语音，可到系统设置安装中文 TTS 数据）"
	print("[TTS] voices=", voices.size(), " picked=", _voice)