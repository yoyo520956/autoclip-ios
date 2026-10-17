import Foundation
import Security

/// 设置中枢：供应商（10+，OpenAI 兼容统一）、转录、处理参数
/// Keychain 存 API Key；其余 UserDefaults + kv 表镜像
final class SettingsStore: ObservableObject {
    static let shared = SettingsStore()

    // MARK: - LLM 供应商（env.example 全清单）
    struct Provider: Identifiable, Codable, Hashable {
        var id: String                 // dashscope/openai/gemini/deepseek/seed/kimi/glm/grok/ollama/lmstudio/infistar/api88/custom
        var label: String
        var baseURL: String            // OpenAI 兼容端点；Gemini 特殊处理
        var isGemini: Bool = false
        var defaultModel: String = ""
        var needsKey: Bool = true
    }
    static let providers: [Provider] = [
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
        didSet { UserDefaults.standard.set(llmProviderId, forKey: "llm.provider"); if let p = Self.provider(llmProviderId) { if !p.baseURL.isEmpty { llmBaseURL = p.baseURL }; if !p.defaultModel.isEmpty { llmModel = p.defaultModel } } }
    }
    @Published var llmBaseURL: String { didSet { UserDefaults.standard.set(llmBaseURL, forKey: "llm.baseURL") } }
    @Published var llmModel: String { didSet { UserDefaults.standard.set(llmModel, forKey: "llm.model") } }
    @Published var llmMaxTokens: Int { didSet { UserDefaults.standard.set(llmMaxTokens, forKey: "llm.maxTokens") } }
    @Published var llmTimeout: Double { didSet { UserDefaults.standard.set(llmTimeout, forKey: "llm.timeout") } }

    // 图片供应商（封面生图）
    @Published var imageProviderId: String { didSet { UserDefaults.standard.set(imageProviderId, forKey: "img.provider") } }
    @Published var imageModel: String { didSet { UserDefaults.standard.set(imageModel, forKey: "img.model") } }

    // 转录
    enum TranscribeSource: String, CaseIterable, Codable {
        case appleSpeech = "apple_speech"   // 设备端系统识别（免费离线）
        case cloud = "cloud"                // OpenAI 兼容 /audio/transcriptions
        var label: String { self == .appleSpeech ? "设备端识别（系统）" : "云端 API" }
    }
    @Published var transcribeSource: TranscribeSource { didSet { UserDefaults.standard.set(transcribeSource.rawValue, forKey: "tr.source") } }
    @Published var transcribeLang: String { didSet { UserDefaults.standard.set(transcribeLang, forKey: "tr.lang") } } // zh/en/ja/ko/auto
    @Published var cloudTranscribeModel: String { didSet { UserDefaults.standard.set(cloudTranscribeModel, forKey: "tr.cloudModel") } }

    // 处理参数（core/config.py 默认值 1:1）
    @Published var chunkSize: Int { didSet { UserDefaults.standard.set(chunkSize, forKey: "proc.chunk") } }
    @Published var minScoreThreshold: Double { didSet { UserDefaults.standard.set(minScoreThreshold, forKey: "proc.minScore") } }
    @Published var maxClipsPerCollection: Int { didSet { UserDefaults.standard.set(maxClipsPerCollection, forKey: "proc.maxClips") } }
    @Published var maxRetries: Int { didSet { UserDefaults.standard.set(maxRetries, forKey: "proc.retries") } }

    // 内容类型（prompt/ 七类：business/content_review/entertainment/experience/knowledge/opinion/speech）
    @Published var contentType: String { didSet { UserDefaults.standard.set(contentType, forKey: "proc.contentType") } }

    // 输出
    @Published var watermarkEnabled: Bool { didSet { UserDefaults.standard.set(watermarkEnabled, forKey: "out.watermark") } }
    @Published var subtitleStyle: String { didSet { UserDefaults.standard.set(subtitleStyle, forKey: "out.subtitleStyle") } } // clean/bold/box/accent
    @Published var aspectMode: String { didSet { UserDefaults.standard.set(aspectMode, forKey: "out.aspect") } } // original/interview/fullscreen
    @Published var clipMinDuration: Double { didSet { UserDefaults.standard.set(clipMinDuration, forKey: "out.clipMin") } }
    @Published var clipMaxDuration: Double { didSet { UserDefaults.standard.set(clipMaxDuration, forKey: "out.clipMax") } }

    init() {
        let d = UserDefaults.standard
        llmProviderId = d.string(forKey: "llm.provider") ?? "dashscope"
        llmBaseURL = d.string(forKey: "llm.baseURL") ?? Self.provider(llmProviderId)?.baseURL ?? ""
        llmModel = d.string(forKey: "llm.model") ?? "qwen-plus"
        llmMaxTokens = d.object(forKey: "llm.maxTokens") as? Int ?? 4096
        llmTimeout = d.object(forKey: "llm.timeout") as? Double ?? 30
        imageProviderId = d.string(forKey: "img.provider") ?? "openai"
        imageModel = d.string(forKey: "img.model") ?? "gpt-image-1"
        transcribeSource = TranscribeSource(rawValue: d.string(forKey: "tr.source") ?? "") ?? .appleSpeech
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
    }

    func apiKey(for providerId: String) -> String { Keychain.get("key.\(providerId)") ?? "" }
    func setApiKey(_ key: String, for providerId: String) { Keychain.set(key, service: "autoclip", account: "key.\(providerId)") }

    var effectiveLLMBaseURL: String {
        llmBaseURL.isEmpty ? (Self.provider(llmProviderId)?.baseURL ?? "") : llmBaseURL
    }
    var llmReady: Bool {
        guard let p = Self.provider(llmProviderId) else { return false }
        if p.needsKey && apiKey(for: llmProviderId).isEmpty { return false }
        return !effectiveLLMBaseURL.isEmpty && !llmModel.isEmpty
    }
}

/// Keychain 存取（API Key 安全存储，对齐"密钥不落明文文件"）
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
