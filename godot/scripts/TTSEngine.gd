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
var _last_warn_ms := 0
var _last_voice_count := -1
var _speak_time := 0
var _zh_voice_hint := ""
var _plug = null

func speak(text: String) -> void:
	if not enabled or text.strip_edges() == "":
		return
	var p = _get_plug()
	if p != null and p.has_method("ttsSpeak"):
		p.ttsSpeak(text)
		_speaking = true
		_speak_time = Time.get_ticks_msec()
		set_process(true)
		speech_started.emit()
		return
	if _voice == "":
		_refresh_voice()
	if _voice == "":
		var now := Time.get_ticks_msec()
		if now - _last_warn_ms > 30000:
			_last_warn_ms = now
			tts_unavailable.emit("设备未检测到可用的 TTS语音引擎（voices=%d），下次回复会自动重试" % _last_voice_count + _zh_voice_hint)
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
	var p = _get_plug()
	if p != null and p.has_method("ttsStop"):
		p.ttsStop()
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
	var spk := DisplayServer.tts_is_speaking()
	var p = _get_plug()
	if p != null and p.has_method("ttsIsSpeaking"):
		spk = bool(p.ttsIsSpeaking())
	if elapsed > 400 and not spk:
		_speaking = false
		set_process(false)
		speech_finished.emit()

func _get_plug():
	if _plug != null:
		return _plug
	_plug = Engine.get_singleton("HHCamera")
	return _plug

func _refresh_voice() -> void:
	var voices := DisplayServer.tts_get_voices()
	_last_voice_count = voices.size()
	var zh := ""
	for v in voices:
		var blob := str(v).to_lower()
		var id := str(v.get("id", ""))
		var is_zh := blob.find("zh") >= 0 or blob.find("cmn") >= 0 or blob.find("chi") >= 0 or blob.find("chinese") >= 0 or blob.find("中文") >= 0
		if is_zh and zh == "":
			zh = id
	if zh != "":
		_voice = zh
		_zh_voice_hint = ""
	elif voices.size() > 0:
		_voice = str(voices[0].get("id", ""))
		_zh_voice_hint = "（未找到中文语音，可到系统设置里安装/启用中文 TTS）"
	print("[TTS] voices=", voices.size(), " picked=", _voice)
