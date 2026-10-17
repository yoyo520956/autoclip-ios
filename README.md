# AutoClip iOS

AutoClip（github.com/zhouxiaoka/autoclip，MIT）的 iPhone 原生移植版——「一个链接，一键出片」的 AI 视频切片工具。

**技术栈**：SwiftUI + AVFoundation（渲染）+ Apple Speech（转录）+ Vision（取景）+ SQLite（存储）+ URLSession（LLM/平台 API）。无 Python、无 FFmpeg、无 Redis/Celery——全部 iOS 原生等价实现，面向 iPhone SE3（4GB RAM）优化。

## 功能（对应原版）

- 导入本地/相册视频（B 站直连下载 v0.3；YouTube 因 JS 求解器无法内置，需先在桌面下载后导入）
- 语音转录：设备端 Apple Speech（免费离线）或云端 OpenAI 兼容 API
- AI 六步管线：大纲 → 时间点定位 → 评分 → 标题 → 简介/话题 → 主题聚类（提示词原样移植 prompt/ 目录，7 类内容 × 5 提示词）
- 切片渲染：AVFoundation 硬编（等价 videotoolbox 优先策略）、三种画幅（原画幅/访谈式模糊底/满屏竖版）、字幕烧录 4 风格（clean/bold/box/accent，参数 1:1 对齐 publish_export.py）、「Made with AutoClip」水印（可关）
- 封面：抽帧 + 标题合成（AI 生图 v0.2）
- 发布：文案管理（v0.1）；B 站直发 + Upload-Post（v0.3）
- 设置：13 个 LLM 供应商（DashScope/OpenAI/Gemini/DeepSeek/火山 Seed/Kimi/智谱 GLM/Grok/Ollama/LM Studio/中转站/自定义）、转录引擎、全部处理参数（默认值与原版 config.py 一致）
- 任务队列：持久化 + 断点恢复（等价 Celery 语义）+ 磁盘空间预检

## 构建

GitHub Actions（macos runner）自动构建未签名 IPA：push 到 main 即触发，或手动 workflow_dispatch。产物在 Artifacts（AutoClip-IPA）。

本地构建：

```bash
brew install xcodegen
xcodegen generate
xcodebuild -project AutoClip.xcodeproj -scheme AutoClip -sdk iphoneos -configuration Release \
  CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY="" build
# 产物 build/Build/Products/Release-iphoneos/AutoClip.app → 手工打 Payload zip 成 .ipa
```

## 安装（侧载）

未签名 IPA 需自签安装：AltStore / SideStore / StikJIT / Sideloadly / 爱思助手。
免费 Apple ID：签名 7 天有效、最多 3 台设备；付费开发者账号（$99/年）：证书 1 年有效。
本应用不上架 App Store。

## 已知限制（平台差异，均记录于 AUDIT-功能矩阵.md）

- YouTube 链接下载：依赖 yt-dlp 的 JS challenge 求解器，iOS 无法内置 → 引导先下载后导入
- SenseVoice 本地推理：Python 运行时不可移植 → 等价方案为 Apple Speech + 云端 API
- libx264 软编兜底：Apple 全系硬编可用，无需软编
- 精确码率控制（0.13bpp 公式）：v0.1 使用系统 preset，v0.2 切 AVAssetWriter 精控

## License

MIT（沿用原版）
