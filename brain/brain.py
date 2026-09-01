#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""Half-hearted AI 大脑 v0.2
OpenAI兼容LLM + 情绪/动作JSON + Edge-TTS(带口型时间戳) + 会话记忆
密钥通过环境变量 LLM_API_KEY 或 config.local.json 提供，绝不写进 config.json
用法:
    export LLM_API_KEY=sk-xxx
    python brain.py "主人好呀"
    python brain.py loop
"""
import json, os, sys, asyncio
import requests

CFG_FILE = "config.json"
LOCAL_CFG = "config.local.json"

DEFAULT_CONFIG = {
    "base_url": "https://api.siliconflow.cn/v1",
    "model": "deepseek-ai/DeepSeek-V3",
    "voice": "zh-CN-XiaoyiNeural",
    "persona": "你是咖啡甜心格温，一只软萌的猫娘，称呼用户为'主人'，语气可爱但不油腻。",
    "emotions": ["neutral","happy","sad","angry","surprised","shy","thinking"],
    "history_max": 20,
    "memory_file": "memory.json",
}

def load_config():
    cfg = dict(DEFAULT_CONFIG)
    for p in (CFG_FILE, LOCAL_CFG):
        if os.path.exists(p):
            cfg.update(json.load(open(p, encoding="utf-8")))
    key = os.environ.get("LLM_API_KEY", "").strip()
    if key:
        cfg["api_key"] = key
    cfg.setdefault("api_key", "")
    return cfg

def build_system(cfg):
    emo = "/".join(cfg["emotions"])
    return f"""{cfg["persona"]}

你必须**只输出一个 JSON 对象**，不要输出任何其他文字。格式：
{{"text":"你要说的话","emotion":"{emo} 中的一个","action":"动作关键词，如 nod/tilt_head/wave/shake/none"}}

规则：
1. text 是你用语音说出来的话，口语化，1~3句，不要动作描述、不要括号。
2. emotion 必须从给定列表选一个。
3. action 是头部/上半身动作关键词，没有就填 "none"。
4. 永不输出 JSON 以外内容。"""

def extract_json(text):
    t = text.strip()
    if t.startswith("```"):
        t = t.strip("`")
        if t.lower().startswith("json"):
            t = t[4:]
    i, j = t.find("{"), t.rfind("}")
    if i >= 0 and j > i:
        try:
            return json.loads(t[i:j+1])
        except Exception:
            pass
    return None

class Memory:
    def __init__(self, path, history_max):
        self.path, self.history_max, self.history, self.facts = path, history_max, [], []
        if os.path.exists(path):
            try:
                d = json.load(open(path, encoding="utf-8"))
                self.history, self.facts = d.get("history", []), d.get("facts", [])
            except Exception:
                pass
    def save(self):
        json.dump({"history": self.history, "facts": self.facts},
                  open(self.path, "w", encoding="utf-8"), ensure_ascii=False, indent=2)
    def add(self, role, content):
        self.history.append({"role": role, "content": content})
        if len(self.history) > self.history_max * 2:
            self.history = self.history[-self.history_max * 2:]
    def messages(self, system):
        msgs = [{"role": "system", "content": system}]
        if self.facts:
            msgs.append({"role": "system",
                         "content": "你记得关于用户的事：\n" + "\n".join("- " + f for f in self.facts)})
        msgs.extend(self.history)
        return msgs

def chat(cfg, messages):
    try:
        r = requests.post(cfg["base_url"].rstrip("/") + "/chat/completions",
            headers={"Authorization": "Bearer " + cfg["api_key"], "Content-Type": "application/json"},
            json={"model": cfg["model"], "messages": messages, "temperature": 0.9}, timeout=120)
        r.raise_for_status()
        return r.json()["choices"][0]["message"]["content"]
    except Exception as e:
        raise RuntimeError(f"LLM请求失败: {e}")

def brain_reply(cfg, mem, user_text):
    mem.add("user", user_text)
    raw = chat(cfg, mem.messages(build_system(cfg)))
    data = extract_json(raw) or {"text": raw.strip(), "emotion": "neutral", "action": "none"}
    mem.add("assistant", json.dumps(data, ensure_ascii=False))
    mem.save()
    return data

async def synthesize(text, voice, out_mp3="out.mp3", out_viseme="viseme.json"):
    import edge_tts
    comm = edge_tts.Communicate(text, voice)
    words = []
    with open(out_mp3, "wb") as f:
        async for chunk in comm.stream():
            if chunk["type"] == "audio":
                f.write(chunk["data"])
            elif chunk["type"] == "WordBoundary":
                words.append({"word": chunk["text"],
                              "t": round(chunk["offset"] / 1e7, 3),
                              "dur": round(chunk["duration"] / 1e7, 3)})
    json.dump(words, open(out_viseme, "w", encoding="utf-8"), ensure_ascii=False)
    return out_mp3, words

def main():
    cfg = load_config()
    if not cfg.get("api_key"):
        print("未找到密钥。两种方式二选一：")
        print("  1) export LLM_API_KEY=sk-你的key")
        print("  2) 复制 config.local.example.json 为 config.local.json 并填入 key")
        return
    mem = Memory(cfg["memory_file"], cfg["history_max"])
    args = sys.argv[1:]
    if args and args[0] == "loop":
        print("连续对话模式，输入 q 退出")
        while True:
            line = input("你说：").strip()
            if not line or line.lower() in ("q", "quit", "exit"):
                break
            reply = brain_reply(cfg, mem, line)
            print(">", json.dumps(reply, ensure_ascii=False))
            mp3, words = asyncio.run(synthesize(reply["text"], cfg["voice"]))
            print(f"  语音:{mp3}  口型词:{len(words)}")
        return
    user = " ".join(args).strip() or input("你说：").strip()
    if not user:
        return
    reply = brain_reply(cfg, mem, user)
    print(">", json.dumps(reply, ensure_ascii=False))
    mp3, words = asyncio.run(synthesize(reply["text"], cfg["voice"]))
    print(f"  语音:{mp3}  口型词:{len(words)}")

if __name__ == "__main__":
    main()
