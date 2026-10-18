import Foundation

/// 统一 LLM 客户端：OpenAI 兼容 10+ 供应商 + Gemini 原生 REST
/// 对齐 core/llm_providers.py 的 4 Provider 类 + 工厂 + 重试
struct LLMMessage: Codable { var role: String; var content: String }

enum LLMError: Error, LocalizedError {
    case notConfigured(String)
    case http(Int, String)
    case empty
    var errorDescription: String? {
        switch self {
        case .notConfigured(let p): return "供应商未配置：\(p)（请到设置页填写 Key 与模型）"
        case .http(let code, let body): return "LLM HTTP \(code): \(body.prefix(300))"
        case .empty: return "LLM 返回为空"
        }
    }
}

final class LLMService {
    static let shared = LLMService()
    private var settings: SettingsStore { .shared }

    /// 对话补全。jsonMode 时附加 response_format=json_object（兼容端忽略之）
    func chat(_ messages: [LLMMessage], maxTokens: Int? = nil, temperature: Double = 0.7, jsonMode: Bool = false) async throws -> String {
        guard settings.llmReady else { throw LLMError.notConfigured(settings.llmProviderId) }
        guard let p = SettingsStore.provider(settings.llmProviderId) else { throw LLMError.notConfigured(settings.llmProviderId) }
        var lastError: Error = LLMError.empty
        for attempt in 0...max(0, settings.maxRetries) {
            do {
                let text = p.isGemini
                    ? try await callGemini(messages, maxTokens: maxTokens ?? settings.llmMaxTokens, temperature: temperature)
                    : try await callOpenAICompatible(messages, maxTokens: maxTokens ?? settings.llmMaxTokens, temperature: temperature, jsonMode: jsonMode)
                if !text.isEmpty { return text }
                throw LLMError.empty
            } catch {
                lastError = error
                if case LLMError.http(let code, _) = error, [401, 403, 404].contains(code) { throw error } // 无重试意义
                let backoff = pow(2.0, Double(attempt)) * 0.8
                Log.llm.error("LLM 第\(attempt + 1)次失败: \(error.localizedDescription)，退避 \(backoff)s")
                try await Task.sleep(nanoseconds: UInt64(backoff * 1_000_000_000))
            }
        }
        throw lastError
    }

    private func callOpenAICompatible(_ messages: [LLMMessage], maxTokens: Int, temperature: Double, jsonMode: Bool) async throws -> String {
        let url = URL(string: settings.effectiveLLMBaseURL.trimmingCharacters(in: CharacterSet(charactersIn: "/ ")) + "/chat/completions")!
        var req = URLRequest(url: url, timeoutInterval: settings.llmTimeout * 6)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let key = settings.apiKey(for: settings.llmProviderId)
        if !key.isEmpty { req.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization") }
        var body: [String: Any] = [
            "model": settings.llmModel,
            "messages": messages.map { ["role": $0.role, "content": $0.content] },
            "max_tokens": maxTokens,
            "temperature": temperature,
        ]
        if jsonMode { body["response_format"] = ["type": "json_object"] }
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        return try await execute(req)
    }

    /// Gemini REST：messages → contents 映射（system 并入首条 user）
    private func callGemini(_ messages: [LLMMessage], maxTokens: Int, temperature: Double) async throws -> String {
        let base = settings.effectiveLLMBaseURL.trimmingCharacters(in: CharacterSet(charactersIn: "/ "))
        let url = URL(string: "\(base)/models/\(settings.llmModel):generateContent?key=\(settings.apiKey(for: "gemini"))")!
        var req = URLRequest(url: url, timeoutInterval: settings.llmTimeout * 6)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        var system = ""
        var contents: [[String: Any]] = []
        for m in messages {
            if m.role == "system" { system += m.content + "\n"; continue }
            contents.append(["role": m.role == "assistant" ? "model" : "user",
                             "parts": [["text": (m.role == "user" && !system.isEmpty && contents.isEmpty) ? system + m.content : m.content]]])
        }
        let body: [String: Any] = ["contents": contents,
                                   "generationConfig": ["maxOutputTokens": maxTokens, "temperature": temperature]]
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        let raw = try await execute(req)
        // Gemini 返回 candidates[0].content.parts[*].text
        if let d = raw.data(using: .utf8),
           let j = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
           let cands = j["candidates"] as? [[String: Any]],
           let content = cands.first?["content"] as? [String: Any],
           let parts = content["parts"] as? [[String: Any]] {
            return parts.compactMap { $0["text"] as? String }.joined()
        }
        return raw
    }

    private func execute(_ req: URLRequest) async throws -> String {
        let (data, resp): (Data, URLResponse)
        do { (data, resp) = try await URLSession.shared.data(for: req) }
        catch { throw LLMError.http(-1, error.localizedDescription) }
        guard let http = resp as? HTTPURLResponse else { throw LLMError.http(-2, "非 HTTP 响应") }
        guard (200..<300).contains(http.statusCode) else {
            throw LLMError.http(http.statusCode, String(data: data, encoding: .utf8) ?? "")
        }
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choices = obj["choices"] as? [[String: Any]],
              let msg = choices.first?["message"] as? [String: Any],
              let text = msg["content"] as? String, !text.isEmpty else {
            throw LLMError.http(http.statusCode, "响应缺 choices/message/content: \(String(data: data, encoding: .utf8)?.prefix(200) ?? "")")
        }
        return text
    }

    // MARK: - 视觉（多模态）：content 数组格式（OpenAI 兼容；agnes-3.0-flash 实测支持）
    struct VisionImage { var data: Data; var mime: String = "image/jpeg" }

    func visionChat(system: String, userText: String, images: [VisionImage], maxTokens: Int? = nil, temperature: Double = 0.5) async throws -> String {
        guard settings.llmReady else { throw LLMError.notConfigured(settings.llmProviderId) }
        var content: [[String: Any]] = [["type": "text", "text": userText]]
        for img in images {
            let b64 = img.data.base64EncodedString()
            content.append(["type": "image_url", "image_url": ["url": "data:\(img.mime);base64,\(b64)"]])
        }
        var messages: [[String: Any]] = []
        if !system.isEmpty { messages.append(["role": "system", "content": system]) }
        messages.append(["role": "user", "content": content])
        let url = URL(string: settings.effectiveLLMBaseURL.trimmingCharacters(in: CharacterSet(charactersIn: "/ ")) + "/chat/completions")!
        var req = URLRequest(url: url, timeoutInterval: settings.llmTimeout * 8)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let key = settings.apiKey(for: settings.llmProviderId)
        if !key.isEmpty { req.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization") }
        let body: [String: Any] = ["model": settings.llmModel, "messages": messages,
                                   "max_tokens": maxTokens ?? settings.llmMaxTokens, "temperature": temperature]
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        return try await execute(req)
    }

    // MARK: - JSON 工具（对齐原版解析容错）
    static func extractJSON<T: Decodable>(_ text: String, _ type: T.Type) throws -> T {
        let cleaned = text
            .replacingOccurrences(of: "```json", with: "```")
            .components(separatedBy: "```")
            .filter { $0.contains("{") }
        for block in [text] + cleaned {
            guard let start = block.firstIndex(of: "{") else { continue }
            guard let end = block.lastIndex(of: "}") else { continue }
            let sub = String(block[start...end])
            if let d = try? JSONDecoder().decode(type, from: Data(sub.utf8)) { return d }
        }
        throw LLMError.empty
    }
}
