import Foundation
import AVFoundation
import Security

/// 设置中枢：内置预设（Agnes 主模型 + hcnsec MiMo 大上下文）+ 供应商管理 + TTS 声音
/// 内置 Key 构建时经 GitHub Secrets 注入 SecretKeys.plist（公开仓库不落明文）
final class SettingsStore: ObservableObject {
    static let shared = SettingsStore()
    /// init 完成前 didSet 不做联动（避免引用未初始化属性）
    private var loaded = false

    /// 内置密钥（CI 注入；本地构建为空则用户手填）
    static let builtInKeys: [String: String] = {
        guard let url = Bundle.main.url(forResource: "SecretKeys", withExtension: "plist"),
              let d = NSDictionary(contentsOf: url) as? [String: String] else { return [:] }
        return d
    }()

    // MARK: - LLM 供应商（含内置预设）
    struct Provider: Identifiable, Codable, Hashable {
        var id: String
        var label: String
        var baseURL: String            // OpenAI 兼容端点；Gemini 特殊处理
        var isGemini: Bool = false
        var defaultModel: String = ""
        var needsKey: Bool = true
        var builtIn: Bool = false      // 内置预设（Key 已写死）
        var note: String = ""
    }
    static let providers: [Provider] = [
        .init(id: "agnes", label: "Agnes AI（内置主模型）", baseURL: "https://api.agnes-ai.cn/v1", defaultModel: "agnes-3.0-flash", builtIn: true, note: "多模态：可看图（短剧画面分析）"),
        .init(id: "hcnsec", label: "MiMo V2.6（内置·长上下文）", baseURL: "https://api.hcnsec.cn/v1", defaultModel: "MiMo-V2.6-Flash", builtIn: true, note: "1M 上下文，适合长视频字幕"),
        .init(id: "dashscope", label: "通义千问 DashScope", baseURL: "https://dashscope.aliyuncs.com/compatible-mode/v1", defaultModel: "qwen-plus"),
        .init(id: "openai", label: "OpenAI", baseURL: "https://api.openai.com/v1", defaultModel: "gpt-4o-mini"),
        .init(id: "gemini", label: "Google Gemini", baseURL: "https://generativelanguage.googleapis.com/v1beta", isGemini: true, defaultModel: "gemini-2.0-flash"),
        .init(id: "deepseek", label: "DeepSeek", baseURL: "https://api.deepseek.com/v1", defaultModel: "deepseek-chat"),
        .init(id: "seed", label: "火山方舟 Seed", baseURL: "https://ark.cn-beijing.volces.com/api/v3", defaultModel: "doubao-pro-32k"),
        .init(id: "kimi", label: "Kimi 月之暗面", baseURL: "https://api.moonshot.cn/v1", defaultModel: "moonshot-v1-8k"),
        .init(id: "glm", label: "智谱 GLM", baseURL: "https://open.bigmodel.cn/api/paas/v4", defaultModel: "glm-4-air"),
        .init(id: "grok", label: "xAI Grok", baseURL: "https://api.x.ai/v1", defaultModel: "grok-2-latest"),
        .init(id: "ollama", label: "Ollama 本机", baseURL: "http://localhost:11434/v1", defaultModel: "qwen2.5:7b", needsKey: false),
        .init(id: "lmstudio", label: "LM Studio 本机", baseURL: "http://localhost:1234/v1", defaultModel: "local-model", needsKey: false),
        .init(id: "infistar", label: "Infistar 中转", baseURL: "", defaultModel: ""),
        .init(id: "api88", label: "API88 中转", baseURL: "", defaultModel: ""),
        .init(id: "custom", label: "自定义 OpenAI 兼容", baseURL: "", defaultModel: ""),
    ]
    static func provider(_ id: String) -> Provider? { providers.first { $0.id == id } }

    // 当前选择
    @Published var llmProviderId: String {
        didSet {
            UserDefaults.standard.set(llmProviderId, forKey: "llm.provider")
            guard loaded else { return }
            if let p = Self.provider(llmProviderId) {
                if !p.baseURL.isEmpty { llmBaseURL = p.baseURL }
                if !p.defaultModel.isEmpty { llmModel = p.defaultModel }
            }
        }
    }
    @Published var llmBaseURL: String { didSet { guard loaded else { return }; UserDefaults.standard.set(llmBaseURL, forKey: "llm.baseURL") } }
    @Published var llmModel: String { didSet { guard loaded else { return }; UserDefaults.standard.set(llmModel, forKey: "llm.model") } }
    @Published var llmMaxTokens: Int { didSet { guard loaded else { return }; UserDefaults.standard.set(llmMaxTokens, forKey: "llm.maxTokens") } }
    @Published var llmTimeout: Double { didSet { guard loaded else { return }; UserDefaults.standard.set(llmTimeout, forKey: "llm.timeout") } }

    // 图片供应商（封面生图）
    @Published var imageProviderId: String { didSet { guard loaded else { return }; UserDefaults.standard.set(imageProviderId, forKey: "img.provider") } }
    @Published var imageModel: String { didSet { guard loaded else { return }; UserDefaults.standard.set(imageModel, forKey: "img.model") } }

    // 转录
    enum TranscribeSource: String, CaseIterable, Codable {
        case nvidiaOmni = "nvidia_omni"     // 云端 NVIDIA omni（音频输入→文字）
        case appleSpeech = "apple_speech"   // 设备端系统识别（免费离线，云端失败时兜底）
        case cloud = "cloud"                // OpenAI 兼容 /audio/transcriptions
        var label: String {
            switch self {
            case .nvidiaOmni: return "云端识别（NVIDIA omni）"
            case .appleSpeech: return "设备端识别（系统）"
            case .cloud: return "云端 API（OpenAI 兼容）"
            }
        }
    }
    @Published var transcribeSource: TranscribeSource { didSet { guard loaded else { return }; UserDefaults.standard.set(transcribeSource.rawValue, forKey: "tr.source") } }
    @Published var transcribeLang: String { didSet { guard loaded else { return }; UserDefaults.standard.set(transcribeLang, forKey: "tr.lang") } }
    @Published var cloudTranscribeModel: String { didSet { guard loaded else { return }; UserDefaults.standard.set(cloudTranscribeModel, forKey: "tr.cloudModel") } }

    // 处理参数（core/config.py 默认值 1:1）
    @Published var chunkSize: Int { didSet { guard loaded else { return }; UserDefaults.standard.set(chunkSize, forKey: "proc.chunk") } }
    @Published var minScoreThreshold: Double { didSet { guard loaded else { return }; UserDefaults.standard.set(minScoreThreshold, forKey: "proc.minScore") } }
    @Published var maxClipsPerCollection: Int { didSet { guard loaded else { return }; UserDefaults.standard.set(maxClipsPerCollection, forKey: "proc.maxClips") } }
    @Published var maxRetries: Int { didSet { guard loaded else { return }; UserDefaults.standard.set(maxRetries, forKey: "proc.retries") } }

    // 内容类型（原版 7 类 + iOS 增补 drama 短剧）
    @Published var contentType: String { didSet { guard loaded else { return }; UserDefaults.standard.set(contentType, forKey: "proc.contentType") } }

    // 输出
    @Published var watermarkEnabled: Bool { didSet { guard loaded else { return }; UserDefaults.standard.set(watermarkEnabled, forKey: "out.watermark") } }
    @Published var subtitleStyle: String { didSet { guard loaded else { return }; UserDefaults.standard.set(subtitleStyle, forKey: "out.subtitleStyle") } }
    @Published var aspectMode: String { didSet { guard loaded else { return }; UserDefaults.standard.set(aspectMode, forKey: "out.aspect") } }
    @Published var clipMinDuration: Double { didSet { guard loaded else { return }; UserDefaults.standard.set(clipMinDuration, forKey: "out.clipMin") } }
    @Published var clipMaxDuration: Double { didSet { guard loaded else { return }; UserDefaults.standard.set(clipMaxDuration, forKey: "out.clipMax") } }

    // MARK: - 配音（TTS）
    @Published var dubbingEnabled: Bool { didSet { guard loaded else { return }; UserDefaults.standard.set(dubbingEnabled, forKey: "dub.enabled") } }
    @Published var dubbingVoiceId: String { didSet { guard loaded else { return }; UserDefaults.standard.set(dubbingVoiceId, forKey: "dub.voice") } }
    @Published var dubbingRate: Double { didSet { guard loaded else { return }; UserDefaults.standard.set(dubbingRate, forKey: "dub.rate") } }
    @Published var dubbingVolume: Double { didSet { guard loaded else { return }; UserDefaults.standard.set(dubbingVolume, forKey: "dub.vol") } } // 原音压低量 0~1

    init() {
        let d = UserDefaults.standard
        let savedProvider = d.string(forKey: "llm.provider") ?? "agnes"   // 内置默认 Agnes
        llmProviderId = savedProvider
        llmBaseURL = d.string(forKey: "llm.baseURL") ?? Self.provider(savedProvider)?.baseURL ?? ""
        llmModel = d.string(forKey: "llm.model") ?? Self.provider(savedProvider)?.defaultModel ?? ""
        llmMaxTokens = d.object(forKey: "llm.maxTokens") as? Int ?? 4096
        llmTimeout = d.object(forKey: "llm.timeout") as? Double ?? 30
        imageProviderId = d.string(forKey: "img.provider") ?? "agnes"
        imageModel = d.string(forKey: "img.model") ?? "agnes-image-2.1-flash"
        transcribeSource = TranscribeSource(rawValue: d.string(forKey: "tr.source") ?? "") ?? .nvidiaOmni
        transcribeLang = d.string(forKey: "tr.lang") ?? "zh"
        cloudTranscribeModel = d.string(forKey: "tr.cloudModel") ?? "whisper-1"
        chunkSize = d.object(forKey: "proc.chunk") as? Int ?? 5000
        minScoreThreshold = d.object(forKey: "proc.minScore") as? Double ?? 0.7
        maxClipsPerCollection = d.object(forKey: "proc.maxClips") as? Int ?? 5
        maxRetries = d.object(forKey: "proc.retries") as? Int ?? 3
        contentType = d.string(forKey: "proc.contentType") ?? "entertainment"
        watermarkEnabled = d.object(forKey: "out.watermark") as? Bool ?? true
        subtitleStyle = d.string(forKey: "out.subtitleStyle") ?? "clean"
        aspectMode = d.string(forKey: "out.aspect") ?? "original"
        clipMinDuration = d.object(forKey: "out.clipMin") as? Double ?? 20
        clipMaxDuration = d.object(forKey: "out.clipMax") as? Double ?? 90
        dubbingEnabled = d.object(forKey: "dub.enabled") as? Bool ?? false
        dubbingVoiceId = d.string(forKey: "dub.voice") ?? ""
        dubbingRate = d.object(forKey: "dub.rate") as? Double ?? 0.5
        dubbingVolume = d.object(forKey: "dub.vol") as? Double ?? 0.15
        loaded = true
    }

    // MARK: - Key 管理（Keychain 优先 → 内置兜底）
    func apiKey(for providerId: String) -> String {
        if let k = Keychain.get("key.\(providerId)"), !k.isEmpty { return k }
        if providerId == "agnes" { return Self.builtInKeys["AGNES_KEY"] ?? "" }
        if providerId == "hcnsec" { return Self.builtInKeys["HCN_KEY"] ?? "" }
        return ""
    }
    func setApiKey(_ key: String, for providerId: String) { Keychain.set(key, service: "autoclip", account: "key.\(providerId)") }

    var effectiveLLMBaseURL: String {
        llmBaseURL.isEmpty ? (Self.provider(llmProviderId)?.baseURL ?? "") : llmBaseURL
    }
    var llmReady: Bool {
        guard let p = Self.provider(llmProviderId) else { return false }
        if p.needsKey && apiKey(for: llmProviderId).isEmpty { return false }
        return !effectiveLLMBaseURL.isEmpty && !llmModel.isEmpty
    }

    // MARK: - TTS 声音枚举（系统声音，中文优先展示）
    struct VoiceInfo: Identifiable, Hashable {
        var id: String
        var name: String
        var lang: String
    }
    static func availableVoices() -> [VoiceInfo] {
        let voices = AVSpeechSynthesisVoice.speechVoices()
        let zh = voices.filter { $0.language.hasPrefix("zh") }
            .map { VoiceInfo(id: $0.identifier, name: "\($0.name)（\($0.language)）", lang: $0.language) }
        let other = voices.filter { v in !v.language.hasPrefix("zh") && ["en", "ja", "ko"].contains { v.language.hasPrefix($0) } }
            .map { VoiceInfo(id: $0.identifier, name: "\($0.name)（\($0.language)）", lang: $0.language) }
        return zh + other
    }
    static func defaultVoiceId() -> String {
        if let v = AVSpeechSynthesisVoice(language: "zh-CN") { return v.identifier }
        return availableVoices().first?.id ?? ""
    }
}

/// Keychain 存取（API Key 安全存储）
enum Keychain {
    static func set(_ value: String, service: String, account: String) {
        guard let data = value.data(using: .utf8) else { return }
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                kSecAttrService as String: service, kSecAttrAccount as String: account]
        SecItemDelete(q as CFDictionary)
        var add = q
        add[kSecValueData as String] = data
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        SecItemAdd(add as CFDictionary, nil)
    }
    static func get(_ account: String, service: String = "autoclip") -> String? {
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                kSecAttrService as String: service, kSecAttrAccount as String: account,
                                kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne]
        var out: AnyObject?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let d = out as? Data else { return nil }
        return String(data: d, encoding: .utf8)
    }
    static func delete(_ account: String, service: String = "autoclip") {
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                kSecAttrService as String: service, kSecAttrAccount as String: account]
        SecItemDelete(q as CFDictionary)
    }
}
