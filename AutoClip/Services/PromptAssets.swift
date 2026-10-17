import Foundation

/// 提示词资产加载：prompt/ 目录原样打包进 Bundle（7 类内容 × 5 提示词 + 通用 5 份）
/// 选择顺序：contentType 专用版 → 通用版
enum PromptAssets {
    private static var cache: [String: String] = [:]
    private static let lock = NSLock()

    static let contentTypes = ["business", "content_review", "entertainment", "experience", "knowledge", "opinion", "speech"]
    static let contentTypeLabels = [
        "business": "商业财经", "content_review": "内容测评", "entertainment": "娱乐综艺",
        "experience": "经验分享", "knowledge": "知识科普", "opinion": "观点评论", "speech": "演讲访谈",
    ]
    static let promptNames = ["大纲", "时间点", "推荐理由", "标题生成", "主题聚类"]

    static func load(contentType: String, name: String) -> String {
        lock.lock(); defer { lock.unlock() }
        let key = "\(contentType)/\(name)"
        if let v = cache[key] { return v }
        let base = Bundle.main.resourceURL!.appendingPathComponent("Prompts", isDirectory: true)
        // 专用版优先
        let specific = base.appendingPathComponent("\(contentType)/\(name).txt")
        let generic = base.appendingPathComponent("\(name).txt")
        for url in [specific, generic] {
            if let s = try? String(contentsOf: url, encoding: .utf8), !s.isEmpty {
                cache[key] = s
                return s
            }
        }
        Log.pipeline.error("提示词缺失: \(key)")
        cache[key] = "请完成任务。"
        return cache[key]!
    }
}
