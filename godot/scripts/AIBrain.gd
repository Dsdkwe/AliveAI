class_name AIBrain
extends Node
## 720 的 AI 大脑：直连 DeepSeek（OpenAI 兼容），管理短期记忆，
## 解析 {text, emotion, action} 协议。设置存 user://settings.json（不随包发布）。

signal reply_ready(text: String, emotion: String, action: String)
signal request_failed(message: String)
signal thinking_changed(thinking: bool)
signal test_done(ok: bool, message: String)

const SETTINGS_PATH := "user://settings.json"
const MEMORY_PATH := "user://memory.json"
const DEFAULT_BASE_URL := "https://api.deepseek.com"
const DEFAULT_MODEL := "deepseek-v4-flash"
const DEFAULT_PERSONA := "你的名字叫720，说话自然、友善、简洁。不用'主人'这类称呼，像普通朋友一样交流。"
const HISTORY_MAX := 10  # 10 轮（20 条）对话窗口
const EMOTIONS := ["neutral", "happy", "sad", "angry", "surprised", "shy", "thinking"]

var base_url := DEFAULT_BASE_URL
var model := DEFAULT_MODEL
var api_key := ""
var persona := DEFAULT_PERSONA
var tts_enabled := true

var _history := []
var _http: HTTPRequest = null
var _busy := false
var _mode := ""

func _ready() -> void:
	_http = HTTPRequest.new()
	_http.timeout = 60.0
	add_child(_http)
	_http.request_completed.connect(_on_completed)
	load_settings()
	load_memory()

func configured() -> bool:
	return api_key.strip_edges() != ""

func ask(user_text: String) -> bool:
	if _busy:
		return false
	if not configured():
		request_failed.emit("未配置 API Key：点左上角 ☰，在「AI设置」里填入 DeepSeek Key")
		return false
	_busy = true
	_mode = "chat"
	thinking_changed.emit(true)
	_history.append({"role": "user", "content": user_text})
	var payload := {
		"model": model,
		"messages": _build_messages(),
		"temperature": 0.9,
		"stream": false,
	}
	var err := _http.request(base_url.rstrip("/") + "/chat/completions",
		PackedStringArray(["Content-Type: application/json", "Authorization: Bearer " + api_key]),
		HTTPClient.METHOD_POST, JSON.stringify(payload))
	if err != OK:
		_busy = false
		_mode = ""
		thinking_changed.emit(false)
		_pop_user_msg()
		request_failed.emit("网络请求发起失败（错误码 %d）" % err)
		return false
	return true

func test_connection() -> void:
	if _busy:
		return
	if not configured():
		test_done.emit(false, "未配置 API Key")
		return
	_busy = true
	_mode = "test"
	var err := _http.request(base_url.rstrip("/") + "/models",
		PackedStringArray(["Authorization: Bearer " + api_key]), HTTPClient.METHOD_GET)
	if err != OK:
		_busy = false
		_mode = ""
		test_done.emit(false, "请求发起失败（错误码 %d）" % err)

func clear_history() -> void:
	_history.clear()
	save_memory()

func load_settings() -> void:
	if not FileAccess.file_exists(SETTINGS_PATH):
		return
	var f := FileAccess.open(SETTINGS_PATH, FileAccess.READ)
	if f == null:
		return
	var d = JSON.parse_string(f.get_as_text())
	f.close()
	if typeof(d) == TYPE_DICTIONARY:
		base_url = str(d.get("base_url", base_url))
		model = str(d.get("model", model))
		api_key = str(d.get("api_key", api_key))
		persona = str(d.get("persona", persona))
		tts_enabled = bool(d.get("tts_enabled", tts_enabled))

func save_settings() -> void:
	var d := {"base_url": base_url, "model": model, "api_key": api_key, "persona": persona, "tts_enabled": tts_enabled}
	var f := FileAccess.open(SETTINGS_PATH, FileAccess.WRITE)
	if f:
		f.store_string(JSON.stringify(d, " "))
		f.close()

func load_memory() -> void:
	_history.clear()
	if not FileAccess.file_exists(MEMORY_PATH):
		return
	var f := FileAccess.open(MEMORY_PATH, FileAccess.READ)
	if f == null:
		return
	var d = JSON.parse_string(f.get_as_text())
	f.close()
	if typeof(d) == TYPE_DICTIONARY and d.has("history") and typeof(d["history"]) == TYPE_ARRAY:
		for m in d["history"]:
			if typeof(m) == TYPE_DICTIONARY and m.has("role") and m.has("content"):
				_history.append({"role": str(m["role"]), "content": str(m["content"])})
	_trim()

func save_memory() -> void:
	var d := {"history": _history}
	var f := FileAccess.open(MEMORY_PATH, FileAccess.WRITE)
	if f:
		f.store_string(JSON.stringify(d, " "))
		f.close()

# ------------------------------------------------------------------ internals

func _build_messages() -> Array:
	var msgs := [{"role": "system", "content": _system_prompt()}]
	msgs.append_array(_history)
	return msgs

func _system_prompt() -> String:
	return persona + "\n\n你必须只输出一个 JSON 对象，不要输出任何其他文字。格式：\n" \
		+ "{\"text\":\"你要说的话\",\"emotion\":\"" + "/".join(EMOTIONS) + "中的一个\",\"action\":\"动作关键词，如 nod/tilt_head/wave/shake/none\"}\n\n" \
		+ "规则：\n1. text 是你用语音说出来的话，口语化，1~3句，不要动作描述、不要括号。\n" \
		+ "2. emotion 必须从给定列表选一个。\n" \
		+ "3. action 是头部/上半身动作关键词，没有就填 \"none\"。\n" \
		+ "4. 永不输出 JSON 以外内容。"

func _on_completed(result: int, code: int, _headers: PackedStringArray, body: PackedByteArray) -> void:
	var was_mode := _mode
	_busy = false
	_mode = ""
	var text := body.get_string_from_utf8()
	if was_mode == "test":
		var ok := result == HTTPRequest.RESULT_SUCCESS and code == 200
		if ok:
			test_done.emit(true, "连接正常（HTTP %d）" % code)
		else:
			test_done.emit(false, "连接失败：HTTP %d %s" % [code, text.substr(0, 160)])
		return
	if was_mode != "chat":
		return
	thinking_changed.emit(false)
	if result != HTTPRequest.RESULT_SUCCESS:
		_pop_user_msg()
		request_failed.emit("请求失败（网络错误 %d）" % result)
		return
	if code != 200:
		_pop_user_msg()
		request_failed.emit("服务返回 HTTP %d：%s" % [code, text.substr(0, 200)])
		return
	var reply := _parse_reply(text)
	if reply.is_empty():
		_pop_user_msg()
		request_failed.emit("无法解析模型返回内容")
		return
	_history.append({"role": "assistant", "content": JSON.stringify(reply)})
	_trim()
	save_memory()
	reply_ready.emit(reply["text"], reply["emotion"], reply["action"])

func _parse_reply(raw: String) -> Dictionary:
	var content := ""
	var d = JSON.parse_string(raw)
	if typeof(d) == TYPE_DICTIONARY and d.has("choices"):
		var choices = d["choices"]
		if typeof(choices) == TYPE_ARRAY and choices.size() > 0 and typeof(choices[0]) == TYPE_DICTIONARY:
			var msg = choices[0].get("message", {})
			if typeof(msg) == TYPE_DICTIONARY:
				content = str(msg.get("content", ""))
	if content == "":
		content = raw
	var data = _extract_json(content)
	if typeof(data) != TYPE_DICTIONARY:
		data = {"text": content.strip_edges(), "emotion": "neutral", "action": "none"}
	var emo := str(data.get("emotion", "neutral"))
	if not EMOTIONS.has(emo):
		emo = "neutral"
	var act := str(data.get("action", "none"))
	var txt := str(data.get("text", "")).strip_edges()
	if txt == "":
		return {}
	return {"text": txt, "emotion": emo, "action": act}

func _extract_json(t: String) -> Variant:
	var s := t.strip_edges()
	if s.begins_with("```"):
		s = s.trim_prefix("```")
		if s.to_lower().begins_with("json"):
			s = s.substr(4)
		s = s.strip_edges()
		if s.ends_with("```"):
			s = s.trim_suffix("```")
		s = s.strip_edges()
	var i := s.find("{")
	var j := s.rfind("}")
	if i >= 0 and j > i:
		var r = JSON.parse_string(s.substr(i, j - i + 1))
		if typeof(r) == TYPE_DICTIONARY:
			return r
	return null

func _pop_user_msg() -> void:
	if _history.size() > 0:
		var last = _history[_history.size() - 1]
		if typeof(last) == TYPE_DICTIONARY and str(last.get("role", "")) == "user":
			_history.pop_back()

func _trim() -> void:
	while _history.size() > HISTORY_MAX * 2:
		_history.pop_front()