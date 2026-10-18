import Foundation

/// 提示词资产：原版 prompt/ 全部 40 份（7 类内容 × 5 提示词 + 通用 5 份）
/// 预打包为单文件 Resources/Prompts.json（避免资源平铺重名冲突）
/// key: "contentType/名称" 为专用版，"名称" 为通用版；解析顺序专用 → 通用
enum PromptAssets {
    static let contentTypes = ["business", "content_review", "entertainment", "experience", "knowledge", "opinion", "speech", "drama"]
    static let contentTypeLabels = [
        "business": "商业财经", "content_review": "内容测评", "entertainment": "娱乐综艺",
        "experience": "经验分享", "knowledge": "知识科普", "opinion": "观点评论", "speech": "演讲访谈",
        "drama": "短剧（声画双分析）",
    ]
    static let promptNames = ["大纲", "时间点", "推荐理由", "标题生成", "主题聚类"]

    private static let dict: [String: String] = {
        guard let url = Bundle.main.url(forResource: "Prompts", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let d = try? JSONDecoder().decode([String: String].self, from: data) else {
            Log.pipeline.error("Prompts.json 缺失或损坏")
            return [:]
        }
        return d
    }()

    static func load(contentType: String, name: String) -> String {
        if let v = dict["\(contentType)/\(name)"], !v.isEmpty { return v }
        if let v = dict[name], !v.isEmpty { return v }
        Log.pipeline.error("提示词缺失: \(contentType)/\(name)")
        return "请根据输入完成任务，只输出 JSON。"
    }

    static var assetCount: Int { dict.count }
}
