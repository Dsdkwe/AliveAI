# Half-hearted AI — 项目交接文档

## 一句话
安卓 AI 语音助手/虚拟陪伴。最终愿景：AR 摄像头透视 3D 角色（VRM）。
当前阶段：**竖切片已完成**（AI 对话 + 语音朗读 + 表情/姿态 + 中文界面）。

## 已定死的技术决策
- 客户端引擎：Godot 4.4.1（已放弃 Unity：个人版许可证无法在无桌面机环境激活，这是硬限制）
- 模型格式：VRM，用 godot-vrm 插件**运行时零转换直载**；MMD/PMX 暂缓
- AI：DeepSeek 官方 API（base_url `https://api.deepseek.com`，模型 `deepseek-v4-flash`），角色名"720"（自然、友善、简洁，像普通朋友）
- 密钥：App 内运行时填写，存设备 `user://settings.json`（不随包发布，绝不提交 GitHub）；`brain/` 用 `config.local.json`
- 包名：`com.hta.halfhearted`；签名 keystore 存 GitHub Secret `ANDROID_KEYSTORE_B64`（alias `halfhearted`，密码 `android`）

## 仓库结构
- `brain/`：Python AI 大脑（参考实现，`{text, emotion, action}` + Edge-TTS）
- `godot/`：Godot 4.4.1 工程（主场景 `scenes/main.tscn` → `scripts/Bootstrap.gd` 全代码搭场景）
  - `scripts/AIBrain.gd`：DeepSeek 直连 + 短期记忆（user://memory.json，10 轮窗口）
  - `scripts/AvatarController.gd`：表情 / 眨眼 / 口型 / 情绪姿态 / 动作
  - `scripts/TTSEngine.gd`：系统 TTS 封装（自动挑中文语音，无引擎时优雅降级）
  - `assets/fonts/SmileySans-Oblique.ttf`：中文字体（OFL 协议）
- `unity/`：废弃的 Unity 工程（保留，勿删）
- `.github/workflows/godot-build.yml`：CI 构建（Godot 版本在顶部 `GODOT_VERSION` 改一处即可）

## 已完成（Godot 线）
1. CI 管线：headless 导出 debug APK，且每次 push 自动发布到 Release `apk-latest`（固定下载地址，方便手机直接装）✅
2. godot-vrm 集成：VRM 零转换直载 + MToon 渲染 ✅
3. UI：左上角 ☰ → 左滑侧边栏（模型切换 / Scale / Rotate / Camera Distance / Pitch）✅
4. 手势：单指拖拽转角色、双指缩放=相机距离、双指拖动=平移视角 ✅
5. 固定签名 keystore（CI 每次签名一致，可覆盖安装）✅
6. **AI 对话**：底部聊天面板，HTTPRequest 直连 DeepSeek，解析 `{text, emotion, action}` 协议 ✅
7. **TTS**：系统引擎朗读（自动挑中文语音），说话时下颌/口型动画 ✅
8. **表情与姿态**：情绪→头部姿态 + 视线；眨眼（morph 驱动）；动作 nod / shake / tilt_head ✅
9. **中文字体**：内嵌 Smiley Sans（+ SystemFont 兜底）✅
10. AI 设置页：API Key / 模型 / 语音开关 / 测试连接 / 清空对话记忆 ✅

## 下一步（阶段 2：角色生动化，按优先级）
1. **换更完整的 VRM 模型**：当前 gwen.vrm 只有 3 个 morph（眨眼），没有表情/口型形态键，情绪表达受限（见"已知坑"）
2. 眼神追踪 LookAt 摄像头（插件自带 lookUp/Down/Left/Right 姿态，可直接复用）
3. Spring Bone 物理开启验证（vrm_toplevel 中有 spring_bones 设置）
4. 渲染打磨：MToon 调参、toon 描边、光影
5. 可选：语音输入（STT）、Edge-TTS 音色（比系统 TTS 甜）

## 关键约定（接手必须遵守）
- Godot 版本锁定 **4.4.1**，升级只改 `.github/workflows/godot-build.yml` 顶部 `GODOT_VERSION`
- 模型放 `godot/assets/models/*.vrm`，**用英文文件名**
- 改动流程：改 `godot/` 代码 → `git add/commit/push` → GitHub Actions 自动构建 → 从 Release `apk-latest` 下载 APK 装手机验证
- 新功能优先加新脚本并给 `class_name`；场景坚持全代码搭建（不新建 .tscn）

## 已知坑（不要再犯）
- GDScript 里 `elif event is X and _cond:` 复合条件会失效类型收窄，用 `var x := event as X` 显式转换
- Godot 导出模板 `.tpz` 解压后内部有 `templates/` 子目录，要上移到 `<version>.stable/` 下
- **gwen.vrm 只有 3 个 morph（morph_0/1/2 = blink/blinkLeft/blinkRight），没有表情和口型形态键**；情绪靠头部骨骼姿态 + 视线表达。换模型时 `AvatarController` 的候选名匹配会自动找 happy/sad 等形态键
- 骨骼轴向（已在 gwen.vrm 上验证）：Head 局部 X=低头(+)/抬头(-)、Y=左转(+)、Z=侧倾；Jaw 负角=张嘴；眼皮骨默认四元数 (0.707,0,0,0.707)
- 系统 TTS 依赖设备引擎；手机需装中文 TTS 数据，无引擎时 App 内自动降级提示
- UI 字体缺字（如 ☰ 符号）由 SystemFont 兜底
