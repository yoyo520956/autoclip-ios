import SwiftUI

/// 设置页（对齐 SettingsPage.tsx：供应商/转录/处理参数/输出 全量配置）
struct SettingsView: View {
    @State private var s = SettingsStore.shared
    @State private var apiKey = ""
    @State private var imageKey = ""

    var body: some View {
        NavigationStack {
            Form {
                Section("AI 供应商") {
                    Picker("供应商", selection: $s.llmProviderId) {
                        ForEach(SettingsStore.providers) { p in
                            Text(p.label).tag(p.id)
                        }
                    }
                    TextField("Base URL（OpenAI 兼容）", text: $s.llmBaseURL)
                        .font(.system(size: 12)).autocorrectionDisabled().textInputAutocapitalization(.never)
                    TextField("模型名", text: $s.llmModel).font(.system(size: 13))
                    TextField("API Key", text: $apiKey)
                        .font(.system(size: 12)).textInputAutocapitalization(.never).autocorrectionDisabled()
                        .onSubmit { s.setApiKey(apiKey, for: s.llmProviderId) }
                    HStack {
                        Text("Key 状态").font(.system(size: 13)).foregroundColor(Theme.sub)
                        Spacer()
                        if s.llmReady { StatusPill(text: "已配置", color: Theme.ok) }
                        else { StatusPill(text: "未配置", color: Theme.warn) }
                    }
                    Stepper("max_tokens \(s.llmMaxTokens)", value: $s.llmMaxTokens, in: 512...32768, step: 512)
                    Stepper("超时 \(Int(s.llmTimeout))s", value: $s.llmTimeout, in: 10...300, step: 10)
                    Button("保存 Key") { s.setApiKey(apiKey, for: s.llmProviderId) }
                        .font(.system(size: 13, weight: .semibold))
                }

                Section("封面生图（v0.2 启用）") {
                    Picker("图片供应商", selection: $s.imageProviderId) {
                        Text("OpenAI").tag("openai")
                        Text("xAI Grok").tag("grok")
                        Text("智谱 GLM").tag("glm")
                        Text("即梦 Seedream").tag("seedream")
                    }
                    TextField("模型", text: $s.imageModel).font(.system(size: 13))
                    TextField("图片 API Key", text: $imageKey)
                        .font(.system(size: 12))
                        .onSubmit { s.setApiKey(imageKey, for: "img.\(s.imageProviderId)") }
                }

                Section("语音转录") {
                    Picker("识别引擎", selection: $s.transcribeSource) {
                        ForEach(SettingsStore.TranscribeSource.allCases, id: \.self) { t in
                            Text(t.label).tag(t)
                        }
                    }
                    Picker("语言", selection: $s.transcribeLang) {
                        Text("中文").tag("zh")
                        Text("English").tag("en")
                        Text("日本語").tag("ja")
                        Text("한국어").tag("ko")
                    }
                    if s.transcribeSource == .cloud {
                        TextField("云端模型（whisper-1 等）", text: $s.cloudTranscribeModel).font(.system(size: 13))
                    }
                    if s.transcribeSource == .appleSpeech {
                        Text("设备端识别：免费、离线、隐私安全；依赖系统对该语言的支持。")
                            .font(.system(size: 11)).foregroundColor(Theme.muted)
                    }
                }

                Section("处理参数（默认值与原版一致）") {
                    Stepper("分块大小 \(s.chunkSize) 字符", value: $s.chunkSize, in: 1000...20000, step: 500)
                    HStack {
                        Text("评分阈值")
                        Slider(value: $s.minScoreThreshold, in: 0.3...0.95, step: 0.05)
                        Text(String(format: "%.2f", s.minScoreThreshold)).font(.system(size: 12)).monospacedDigit()
                    }
                    Stepper("单合集上限 \(s.maxClipsPerCollection) 条", value: $s.maxClipsPerCollection, in: 2...10)
                    Stepper("失败重试 \(s.maxRetries) 次", value: $s.maxRetries, in: 0...6)
                }

                Section("输出") {
                    Picker("画幅", selection: $s.aspectMode) {
                        Text("保留原画幅").tag("original")
                        Text("访谈式（模糊底）").tag("interview")
                        Text("满屏竖版").tag("fullscreen")
                    }
                    Picker("字幕风格", selection: $s.subtitleStyle) {
                        Text("clean 简洁").tag("clean")
                        Text("bold 加粗").tag("bold")
                        Text("box 底框").tag("box")
                        Text("accent 强调").tag("accent")
                    }
                    Toggle("「Made with AutoClip」水印", isOn: $s.watermarkEnabled)
                    Stepper("切片最短 \(Int(s.clipMinDuration))s", value: $s.clipMinDuration, in: 5...120, step: 5)
                    Stepper("切片最长 \(Int(s.clipMaxDuration))s", value: $s.clipMaxDuration, in: 60...600, step: 30)
                }

                Section("工具") {
                    Button {
                        let url = Paths.root.appendingPathComponent("backend.log")
                        if FileManager.default.fileExists(atPath: url.path) {
                            let av = UIActivityViewController(activityItems: [url], applicationActivities: nil)
                            UIApplication.shared.connectedScenes.compactMap { ($0 as? UIWindowScene)?.keyWindow?.rootViewController }
                                .first?.present(av, animated: true)
                        }
                    } label: {
                        Label("导出日志 backend.log", systemImage: "doc.text")
                    }
                    HStack {
                        Text("磁盘剩余").font(.system(size: 13)).foregroundColor(Theme.sub)
                        Spacer()
                        Text(ByteFmt.human(Paths.freeDiskBytes)).font(.system(size: 13, weight: .medium))
                    }
                    HStack {
                        Text("版本").font(.system(size: 13)).foregroundColor(Theme.sub)
                        Spacer()
                        Text("v\(AppInfo.version) (\(AppInfo.build))").font(.system(size: 13, weight: .medium))
                    }
                    Text("移植自 AutoClip v1.5.7（MIT）· iOS 原生重写：AVFoundation 渲染 / Apple Speech 转录 / Vision 取景（v0.3）")
                        .font(.system(size: 11)).foregroundColor(Theme.muted)
                }
            }
            .navigationTitle("设置")
            .onAppear {
                apiKey = s.apiKey(for: s.llmProviderId)
                imageKey = s.apiKey(for: "img.\(s.imageProviderId)")
            }
        }
    }
}

enum ByteFmt {
    static func human(_ bytes: Int64) -> String {
        let f = ByteCountFormatter()
        f.countStyle = .binary
        return f.string(fromByteCount: bytes)
    }
}
