# AutoClip iOS 移植功能矩阵（审计 → 实现 → 验收）

原版：github.com/zhouxiaoka/autoclip v1.5.7（MIT）· Tauri+React+Python 98,453 行
本矩阵在开发过程中持续更新；任何功能不得未记录即删除/简化。
状态标记：✅已实现 · 🔨开发中 · 📋计划 · ⚠️远程依赖 · ❌平台不可行（需说明）

## A. 输入与素材管理
| 功能 | 原版源码 | iOS 实现 | 状态 |
|---|---|---|---|
| 本地视频导入 | api/v1/files.py, upload.py | UIDocumentPicker + PhotosPicker → 沙盒 Documents/imports | ✅ |
| 相册导入 | （桌面无） | PhotosPicker 原生增强 | ✅ |
| B站链接下载 | services/bilibili_service.py（937行, 直连 API+cookie） | URLSession 重写 B站 API（playurl 登录 cookie/二维码） | 📋 |
| YouTube 链接下载 | yt-dlp[default]（JS challenge） | ❌ 无法内置（JS challenge 需持续维护的求解器）→ 保留输入框, 用户自行下载后导入, 或远端 yt-dlp 服务（⚠️标记） | ✅决策 |
| 媒体预检（时长/分辨率/损坏/黑屏） | pipeline/media_precheck.py | AVAsset 探测 + 抽帧 CI 检查 | ✅ |
| 素材库/项目管理 | models/ repositories/ | SQLite（SQLite3 直连）表: projects/clips/subtitles/tasks/settings | ✅ |
| 智能导入 | tests/test_smart_import.py | 同规则移植（重复检测/自动改名） | 📋 |

## B. 语音转录与字幕
| 功能 | 原版源码 | iOS 实现 | 状态 |
|---|---|---|---|
| 本地 whisper | whisper_runtime.py + whisper_model_manager.py（faster-whisper 1.2.1, 模型管理器） | v1: Apple Speech 框架（SFSpeechRecognizer 设备端, 免费离线, 时间戳）→ 生成同结构字幕; v2 计划 whisper.cpp CoreML 包（tiny/base）对齐 faster-whisper | 🔨v1 |
| 云端转录 | services/cloud_transcription.py | OpenAI 兼容 /audio/transcriptions + DashScope paraformer（URLSession） | 📋 |
| SenseVoice 对齐 | sensevoice_runtime/worker/alignment.py | ❌ Python 运行时; 等价=本地 Apple Speech + 词级时间戳对齐 | ✅决策 |
| 字幕文件（SRT/分页） | utils/speech_recognizer.py（945行）+ pysrt | SRTWriter/ASSWriter 自研 + 分页规则（字数/行数/时长约束移植） | 🔨 |
| 字幕编辑器 | api/v1/subtitle_editor.py | SwiftUI 字幕表格编辑（文本/时间轴微调） | 📋 |
| 语言配置 | LanguageCode 枚举 | 同枚举（zh/en/ja/ko…） | ✅ |

## C. AI 切片管线（六步，pipeline/）
| 功能 | 原版源码 | iOS 实现 | 状态 |
|---|---|---|---|
| step1 大纲（分段） | pipeline/step1_outline.py | PipelineStep1Outline（文本分块 chunk_size=5000 → LLM 大纲） | 🔨 |
| step2 时间轴 | pipeline/step2_timeline.py | LLM 时间轴 JSON（提示词 1:1 移植 prompt/） | 🔨 |
| step3 评分 | pipeline/step3_scoring.py + scoring_backend.py | 评分模型（阈值 0.7） | 🔨 |
| step4 标题 | pipeline/step4_title.py + prompt/标题生成.txt | LLM 标题/简介/话题 | 🔨 |
| step5 聚类 | pipeline/step5_clustering.py | 合集聚类（max_clips_per_collection=5） | 📋 |
| step6 视频合成 | pipeline/step6_video.py + video_encoder.py | RenderService（AVFoundation） | 🔨 |
| clip_finder/quality/failures | pipeline/*.py | 同逻辑 Swift 化 | 📋 |
| 提示词资产 | prompt/（7 类内容 + 聚类/大纲/推荐理由/时间点/标题） | 原文打包进 Bundle, 原样引用 | ✅决策 |

## D. Studio 高级管线（services/studio/ 40+ 模块）
| 功能 | 原版源码 | iOS 实现 | 状态 |
|---|---|---|---|
| 双路线分析（subtitle/visual） | studio/intelligence.py analyze() | LLM 分析 + 路由选择 | 📋 |
| 草稿生成/场景 | studio/models.py Draft/Scene | 同模型 Codable | 📋 |
| 人物取景（人脸跟踪裁切） | studio/framing.py + tests/test_auto_framing.py | Vision VNDetectFaceRectanglesRequest 逐帧 + 平滑取景框 | 📋v2 |
| 画幅转换（竖版/原画幅） | caption_layout/framing | 竖版: 模糊底+居中 or 填满; 原画幅直出 | 🔨 |
| 字幕烧录 4 风格 | publish_export.py: clean/bold/box/accent（Fontsize/Outline/MarginV 全参数） | CALayer+CoreText 烧录, 4 风格参数 1:1 | 🔨 |
| 标题艺术字（4 代） | studio/title_art v1/v2/v3/v6 + titles.py | v1 先行（drawtext 等价=CATextLayer 描边阴影） | 📋 |
| 封面设计/缩略图 | cover.py(883行) + cover_design.py + thumbnails.py | 帧抽取+CATextLayer 合成; AI 生图走图片供应商 | 📋 |
| 模板系统 | studio/templates/ + template_choice/recommend | 模板 JSON 同结构 | 📋 |
| 水印「Made with AutoClip」 | output_branding.py:169（fontsize=width*.035） | 同规则 CATextLayer, 可关 | 🔨 |
| QA 检查 | studio/qa/ | 渲染后校验（时长/音轨/黑帧） | 📋 |
| 音频处理 | studio/audio.py boundaries.py | AVAudioEngine 响度归一 | 📋 |

## E. 渲染与导出
| 功能 | 原版源码 | iOS 实现 | 状态 |
|---|---|---|---|
| H.264 编码（硬件优先） | video_encoder.py（VT/NVENC/QSV/AMF→libx264 兜底, ~0.13bpp, crf20 等效, yuv420p, high profile） | AVAssetExportSession H.264（Apple 硬编天生优先）, 码率公式同款 | 🔨 |
| 按时间轴切片（-ss/-to 无重编码或重编码） | pipeline/step6 + packaging | passthrough（同参数）与重编码双模式 | 🔨 |
| 批量渲染队列 | studio/jobs.py（1750行, ThreadPool 2+1） | OperationQueue maxConcurrent=1 渲染 + 持久化任务队列（替代 Celery/Redis） | 🔨 |
| 断点恢复/重试 | enhanced_retry.py + restart_recovery.py | 任务状态持久化 + 恢复 | 🔨 |
| 进度事件 | progress_*（5个服务, websocket 推送） | 本地 @Observable 进度 + 通知中心（无需 websocket） | ✅决策 |
| 输出元数据 JSON | step6 save_clip_metadata | 同结构 JSON 输出 | 🔨 |
| 多平台输出参数 | platform_strategy.py | 平台配置表（抖音/小红书/TikTok/Reels/Shorts/B站/YouTube: 时长/画幅/标题长度） | 📋 |

## F. 发布
| 功能 | 原版源码 | iOS 实现 | 状态 |
|---|---|---|---|
| B站直发（多账号/健康检查/轮询） | bilibili_publisher.py(653行) + bilibili_service.py 账号管理 | URLSession 重写 B站上传 API + cookie 钥匙串存储 | 📋 |
| Upload-Post（TikTok/IG/Shorts/X） | upload_post_publisher.py | URLSession 调 Upload-Post API（同参数 platform[]/video/user） | 📋 |
| 发布日历/周计划 | PublishListPage/PublishWeekPage | SwiftUI 对应页 | 📋 |
| 发布文案/标题 | publish_kit.py post_copy.py | LLM 生成 + 手动编辑 | 🔨 |

## G. 设置与供应商
| 功能 | 原版源码 | iOS 实现 | 状态 |
|---|---|---|---|
| LLM 供应商 10+（dashscope/openai/gemini/deepseek/seed/kimi/glm/grok/ollama/lmstudio/infistar/api88） | core/llm_providers.py（686行, 4 Provider 类+工厂） | LLMProvider 统一 OpenAI 兼容客户端（base_url+key+model+max_tokens+timeout）, Gemini 走 REST 转换 | 🔨 |
| 图片供应商（seedream/grok/智谱/openai） | core/image_providers.py（656行） | 封面生图客户端同参数 | 📋 |
| 处理参数（chunk/score阈值/max clips/重试） | core/config.py | 设置页全量暴露, 默认值同款 | 🔨 |
| API Key 安全存储 | 数据目录 json | iOS Keychain | ✅ |
| 转录配置 | SpeechRecognitionConfig | 设置页 | 🔨 |
| 日志 | LoggingSettings | os_log + 文件日志 | ✅ |

## H. CLI / MCP / 自动化等价入口
| 功能 | 原版源码 | iOS 实现 | 状态 |
|---|---|---|---|
| CLI（autoclip 命令, 711行） | backend/cli.py | ❌ 无终端语义; 等价=App Intents（快捷指令可调：处理链接/项目/导出）+ URL scheme autoclip:// | 📋 |
| MCP server | mcp_server.py + mcp_jobs/telemetry | ❌ iOS 无 MCP 宿主语义; 等价=快捷指令 Action（get_version/list_projects/process） | 📋 |
| skills/autoclip | skills/ | 保留为内置文档页 | 📋 |
| Sentry/PostHog | sentry-sdk, posthog | 默认关闭（隐私），设置页可开匿名统计 | 📋决策 |

## I. iPhone SE3（4GB）性能对策（硬要求）
分段处理（长视频按 10min 分段转录/分析）、AVAssetReader 低内存逐帧、渲染串行队列、临时文件统一 Temp/ + 任务结束清理、磁盘空间预检（<1GB 拒绝新任务）、后台切换任务挂起/恢复、API 失败指数退避重试（max_retries=3）、断点续跑。禁止以删功能掩盖性能问题。

## J. 验收标准（交付物清单）
1. 本矩阵逐项状态终值 ✅（❌项附平台不可行说明与等价方案）
2. 完整 iOS 源码（仓库 yoyo520956/autoclip-ios）
3. 可重复构建脚本（GitHub Actions build-ios.yml, XcodeGen 生成工程）
4. 实际生成的 .ipa（Release 资产, md5 核验）
5. 侧载说明（AltStore/SideStore/StikJIT/爱思; 免费 ID 7 天/3 台 限制说明, 付费 $99/年 证书 1 年）
6. 原版↔iOS 功能对照表（本文件）
7. 自动化测试结果 + 已知限制

## 版本规划
- v0.1.0（首个可构建）：工程骨架+导入+媒体预检+Apple Speech 转录+字幕生成+SRT/分页+六步管线(LLM)+切片渲染(AVFoundation 硬编+字幕烧录+水印)+项目管理+设置页(供应商/参数全量)+任务队列+SQLite
- v0.2.0：聚类/合集、多平台参数、封面(帧合成)、发布文案
- v0.3.0：B站下载+发布、Upload-Post、人物取景(Vision)、画幅转换完整版
- v0.4.0：Studio 双路线/模板/艺术字/QA、whisper.cpp、快捷指令入口
