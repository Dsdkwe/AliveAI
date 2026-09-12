# Half-hearted AI — 项目交接文档

## 一句话
安卓 AI 语音助手/虚拟陪伴。最终愿景：AR 摄像头透视 3D 角色（VRM）。当前阶段：AI 驱动 3D 角色说话/表情的最小竖切片。

## 已定死的技术决策
- 客户端引擎：Godot 4.4.1（已放弃 Unity：个人版许可证无法在无桌面机环境激活，这是硬限制）
- 模型格式：VRM，用 godot-vrm 插件**运行时零转换直载**；MMD/PMX 暂缓（Godot 加载器不成熟：一个要自编译、一个要 .NET 版且 0 star）
- AI：DeepSeek 官方 API（base_url `https://api.deepseek.com`，模型 `deepseek-v4-flash`），角色名"720"（自然、友善、简洁，像普通朋友）
- 密钥：`brain/config.local.json`（已 gitignore，绝不提交 GitHub）
- 包名：`com.hta.halfhearted`；签名 keystore 存 GitHub Secret `ANDROID_KEYSTORE_B64`（alias `halfhearted`，密码 `android`）

## 仓库结构
- `brain/`：Python AI 大脑（`brain.py` 已跑通 `{text, emotion, action}` + Edge-TTS 出 `out.mp3`）
- `godot/`：Godot 4.4.1 工程（主场景 `scenes/main.tscn` → `scripts/Bootstrap.gd` 全代码搭场景）
- `unity/`：废弃的 Unity 工程（保留，勿删）
- `.github/workflows/godot-build.yml`：CI 构建（Godot 版本在顶部 env 改一处即可）

## 已完成（Godot 线）
1. CI 管线：headless 导出 debug APK ✅
2. godot-vrm 集成：VRM 零转换直载 + MToon 渲染 ✅
3. UI：左上角 ☰ → 左滑侧边栏（模型切换 / Scale / Rotate / Camera Distance / Pitch）✅
4. 手势：单指拖拽转角色、双指缩放=相机距离、双指拖动=平移视角 ✅
5. 固定签名 keystore（CI 每次签名一致，可覆盖安装）✅

## 下一步（竖切片核心，按优先级）
1. **AI 对话**：Godot `HTTPRequest` 直连 DeepSeek，实现消息循环（用户输入 → LLM → 展示回复）
2. **语音 TTS**：Godot 内置 `DisplayServer.tts_speak` 或复用 Edge-TTS
3. **表情**：blend shape 驱动 `emotion`（情绪→表情映射表，仿 Operit 的映射逻辑）
4. 渲染打磨：中文字体（默认字体不含 CJK）、MToon 调参、toon 效果

## 关键约定（接手必须遵守）
- Godot 版本锁定 **4.4.1**，升级只改 `.github/workflows/godot-build.yml` 顶部 `GODOT_VERSION`
- 模型放 `godot/assets/models/*.vrm`，**用英文文件名**（中文路径有风险）
- 导出预设 `godot/export_presets.cfg` 里 keystore 指向 `res://android/halfhearted.keystore`（CI 从 Secret 解码生成，不入库）
- 改动流程：改 `godot/` 代码 → `git add/commit/push` → GitHub Actions 自动构建 → 下载 APK 装手机验证

## 已知坑（不要再犯）
- GDScript 里 `elif event is X and _cond:` 复合条件会失效类型收窄，用 `var x := event as X` 显式转换
- Godot 导出模板 `.tpz` 解压后内部有 `templates/` 子目录，要上移到 `<version>.stable/` 下
- UI 默认字体不含中文，中文会变豆腐块，需配中文字体