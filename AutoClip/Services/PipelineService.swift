import Foundation

/// 六步 AI 管线（1:1 对齐 pipeline/step1_outline ~ step6_video 与 prompt/ 提示词约定）
/// step1 大纲(SRT→话题) → step2 时间点(话题→精确区间) → step3 评分(final_score)
/// → step4 标题 → step5 聚类 → step6 渲染（交给 RenderService）
final class PipelineService {
    static let shared = PipelineService()

    struct PipelineProgress { var phase: String; var percent: Double; var detail: String = "" }

    private var settings: SettingsStore { .shared }

    // MARK: - 全流程入口
    func process(project: Project, onProgress: @escaping (PipelineProgress) -> Void) async throws {
        guard Paths.hasEnoughDisk else { throw AppError.pipeline("磁盘空间不足（<1GB），请先清理") }
        let url = URL(fileURLWithPath: project.sourceRef)
        guard FileManager.default.fileExists(atPath: url.path) else { throw AppError.pipeline("源视频文件不存在") }

        // 探测
        onProgress(.init(phase: "解析媒体", percent: 0.02))
        let info = await MediaProbe.probe(url)
        guard info.isOK else { throw AppError.pipeline("媒体预检失败: " + info.problems.joined(separator: "；")) }
        var p = project
        p.duration = info.duration; p.width = info.width; p.height = info.height; p.fps = info.fps
        p.touch(.transcribing)

        // 转录
        let segs = try await TranscriptionService.shared.transcribe(url: url, lang: settings.transcribeLang) { pr in
            onProgress(.init(phase: "转写", percent: 0.05 + pr.percent * 0.30, detail: pr.phase))
        }
        guard !segs.isEmpty else { throw AppError.pipeline("转写结果为空") }
        Segment.clear(projectId: p.id)
        for s in segs { s.save(projectId: p.id) }
        let srtPath = Paths.subtitles.appendingPathComponent("\(p.id).srt")
        try SubtitleIO.writeSRT(segments: segs, to: srtPath)

        // step1 大纲
        onProgress(.init(phase: "AI 大纲", percent: 0.38))
        let srtText = try String(contentsOf: srtPath, encoding: .utf8)
        let outlineMD = try await step1Outline(srtText: srtText, contentType: settings.contentType)

        // step2 时间点
        onProgress(.init(phase: "时间点定位", percent: 0.48))
        var candidates = try await step2Timeline(outlineMD: outlineMD, srtText: srtText, duration: info.duration)

        // step3 评分
        onProgress(.init(phase: "评分排序", percent: 0.58))
        candidates = try await step3Scoring(candidates: candidates)
        candidates.sort { ($0.finalScore ?? 0) > ($1.finalScore ?? 0) }
        let passing = candidates.filter { ($0.finalScore ?? 0) >= settings.minScoreThreshold }
        guard !passing.isEmpty else { throw AppError.pipeline("无候选通过评分阈值 \(settings.minScoreThreshold)（共 \(candidates.count) 个候选）") }

        // step4 标题 + 简介/话题（移动版增补：desc/hashtags 一并生成）
        onProgress(.init(phase: "生成标题文案", percent: 0.68))
        var finalClips = try await step4Title(clips: passing)
        finalClips = try await step4bDescription(clips: finalClips)

        // step5 聚类 → 合集
        onProgress(.init(phase: "主题聚类", percent: 0.78))
        _ = try? await step5Clustering(clips: finalClips, projectId: p.id)

        // 建 Clip 记录
        Database.shared.run("DELETE FROM clips WHERE project_id=?", [p.id])
        for (i, c) in finalClips.enumerated() {
            var clip = Clip(projectId: p.id, idx: i, start: c.start, end: c.end)
            clip.title = c.outline
            clip.desc = c.desc
            clip.hashtags = c.hashtags
            clip.score = c.finalScore
            clip.save()
        }

        // step6 渲染（任务队列串行执行）
        p.touch(.rendering)
        onProgress(.init(phase: "入队渲染", percent: 0.85, detail: "\(finalClips.count) 个切片"))
        TaskQueue.shared.enqueueRender(projectId: p.id)
        p.touch(.done)
        onProgress(.init(phase: "完成", percent: 1.0, detail: "切片 \(finalClips.count) 个"))
    }

    // MARK: - step1 大纲
    func step1Outline(srtText: String, contentType: String) async throws -> String {
        let prompt = PromptAssets.load(contentType: contentType, name: "大纲")
        let chunks = Self.chunk(srtText, maxChars: settings.chunkSize)
        var parts: [String] = []
        if chunks.count == 1 {
            parts.append(try await chat(user: prompt + "\n\n以下是视频SRT字幕：\n" + chunks[0], jsonMode: false))
        } else {
            for (i, c) in chunks.enumerated() {
                let text = try await chat(user: prompt + "\n\n以下是视频SRT字幕（第 \(i + 1)/\(chunks.count) 段）：\n" + c, jsonMode: false)
                parts.append(text)
            }
        }
        return parts.joined(separator: "\n\n")
    }

    // MARK: - step2 时间点
    struct Candidate: Codable {
        var outline: String
        var content: [String]?
        var startTime: String
        var endTime: String
        var id: String?
        var finalScore: Double?
        var recommendReason: String?
        // 解析后
        var start: Double?
        var end: Double?
        var desc: String = ""
        var hashtags: [String] = []

        enum CodingKeys: String, CodingKey {
            case outline, content, id, final_score, recommend_reason, desc, hashtags
            case startTime = "start_time"
            case endTime = "end_time"
        }
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            outline = (try? c.decode(String.self, forKey: .outline)) ?? ""
            content = try? c.decode([String].self, forKey: .content)
            startTime = (try? c.decode(String.self, forKey: .startTime)) ?? ""
            endTime = (try? c.decode(String.self, forKey: .endTime)) ?? ""
            id = try? c.decode(String.self, forKey: .id)
            finalScore = try? c.decode(Double.self, forKey: .final_score)
            recommendReason = try? c.decode(String.self, forKey: .recommend_reason)
            start = Self.parseTime(startTime)
            end = Self.parseTime(endTime)
        }
        func encode(to encoder: Encoder) throws { /* 仅本地使用 */ }
        init() { outline = ""; content = nil; startTime = ""; endTime = ""; id = nil; finalScore = nil; recommendReason = nil; start = nil; end = nil }

        static func parseTime(_ s: String) -> Double? {
            // HH:MM:SS,mmm 或 HH:MM:SS.mmm 或 MM:SS
            let t = s.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: ",", with: ".")
            let parts = t.split(separator: ":").map(String.init)
            switch parts.count {
            case 3: return (Double(parts[0]) ?? 0) * 3600 + (Double(parts[1]) ?? 0) * 60 + (Double(parts[2]) ?? 0)
            case 2: return (Double(parts[0]) ?? 0) * 60 + (Double(parts[1]) ?? 0)
            default: return Double(t)
            }
        }
    }

    func step2Timeline(outlineMD: String, srtText: String, duration: Double) async throws -> [Candidate] {
        let prompt = PromptAssets.load(contentType: settings.contentType, name: "时间点")
        // SRT 按原版规则分块喂给 LLM（chunkSize）
        let chunks = Self.chunk(srtText, maxChars: settings.chunkSize)
        var all: [Candidate] = []
        for (i, chunk) in chunks.enumerated() {
            let user = prompt + "\n\n## 大纲（一批话题）：\n" + outlineMD + "\n\n## SRT 字幕文本块（第 \(i + 1)/\(chunks.count) 段）：\n" + chunk
            let raw = try await chat(user: user, jsonMode: true)
            let cands = (try? LLMService.extractJSON(raw, [Candidate].self)) ?? []
            all.append(contentsOf: cands)
        }
        // 时长校验（≥90s / ≤8min / 越界裁剪 —— 对齐时间点.txt 合并策略的服务端兜底）
        var out: [Candidate] = []
        for c in all {
            guard var s = c.start, var e = c.end else { continue }
            s = max(0, min(s, duration)); e = max(0, min(e, duration))
            if e - s < 45 { continue } // 硬废：<45s 无救
            if e - s < 90 {
                // 尝试向后延展到 90s（自然扩展而非丢弃）
                if s + 90 <= duration { e = s + 90 } else if e - s >= 30 { /* 保留短片段 */ } else { continue }
            }
            if e - s > 8 * 60 { e = s + 8 * 60 }
            var c2 = c; c2.start = s; c2.end = e
            out.append(c2)
        }
        // 重叠去重（按 start 排序，重叠 >60% 丢弃后一个）
        out.sort { ($0.start ?? 0) < ($1.start ?? 0) }
        var deduped: [Candidate] = []
        for c in out {
            if let last = deduped.last, let ls = last.start, let le = last.end, let cs = c.start, let ce = c.end {
                let overlap = min(le, ce) - max(ls, cs)
                let minDur = min(le - ls, ce - cs)
                if overlap > minDur * 0.6 { continue }
            }
            deduped.append(c)
        }
        return deduped
    }

    // MARK: - step3 评分
    func step3Scoring(candidates: [Candidate]) async throws -> [Candidate] {
        let prompt = PromptAssets.load(contentType: settings.contentType, name: "推荐理由")
        let input = try JSONEncoder().encode(candidates.map { c in
            ["outline": c.outline, "content": c.content ?? [], "start_time": c.startTime, "end_time": c.endTime]
        })
        let raw = try await chat(user: prompt + "\n\n" + String(data: input, encoding: .utf8)!, jsonMode: true)
        let scored = (try? LLMService.extractJSON(raw, [Candidate].self)) ?? []
        // 按 start_time 对齐合并
        var out: [Candidate] = []
        for c in candidates {
            var c2 = c
            if let m = scored.first(where: { $0.startTime == c.startTime }) {
                c2.finalScore = m.finalScore
                c2.recommendReason = m.recommendReason
            }
            out.append(c2)
        }
        return out
    }

    // MARK: - step4 标题
    func step4Title(clips: [Candidate]) async throws -> [Candidate] {
        let prompt = PromptAssets.load(contentType: settings.contentType, name: "标题生成")
        let input: [[String: Any]] = clips.enumerated().map { (i, c) in
            ["id": String(i), "title": c.outline, "content": c.content ?? [], "recommend_reason": c.recommendReason ?? ""]
        }
        let raw = try await chat(user: prompt + "\n\n" + (String(data: try JSONSerialization.data(withJSONObject: input), encoding: .utf8) ?? "[]"), jsonMode: true)
        guard let map = try? LLMService.extractJSON(raw, [String: String].self) else { return clips }
        var out: [Candidate] = []
        for (i, c) in clips.enumerated() {
            var c2 = c
            if let t = map[String(i)] { c2.outline = t }
            out.append(c2)
        }
        return out
    }

    /// 简介 + 话题标签（发布文案；移动版对齐"生成封面和发布文案"）
    func step4bDescription(clips: [Candidate]) async throws -> [Candidate] {
        let input: [[String: Any]] = clips.enumerated().map { (i, c) in
            ["id": String(i), "title": c.outline, "content": c.content ?? [], "recommend_reason": c.recommendReason ?? ""]
        }
        let system = "你是短视频发布文案专家。为每个切片生成：1) description：80-140字发布简介，口语化、有钩子、不夸张；2) hashtags：3-6个话题标签（不带#号）。只输出 JSON：{\"结果\": [{\"id\":\"1\",\"description\":\"...\",\"hashtags\":[\"...\"]}]}"
        let raw = try? await chat(user: system + "\n\n" + (String(data: try JSONSerialization.data(withJSONObject: input), encoding: .utf8) ?? "[]"), jsonMode: true)
        struct Desc: Codable { var id: String; var description: String; var hashtags: [String] }
        guard let raw, let parsed = try? LLMService.extractJSON(raw, [String: [Desc]].self), let arr = parsed["结果"] else { return clips }
        var out: [Candidate] = []
        for (i, c) in clips.enumerated() {
            var c2 = c
            if let m = arr.first(where: { $0.id == String(i) }) {
                c2.desc = m.description
                c2.hashtags = m.hashtags
            }
            out.append(c2)
        }
        return out
    }

    // MARK: - step5 聚类
    struct CollectionOut: Codable {
        var collection_title: String
        var collection_summary: String
        var clips: [String]
    }
    @discardableResult
    func step5Clustering(clips: [Candidate], projectId: String) async throws -> [CollectionOut] {
        guard clips.count >= 2 else { return [] }
        let prompt = PromptAssets.load(contentType: settings.contentType, name: "主题聚类")
        let list = clips.map { "标题：\($0.outline)\n摘要：\(($0.content ?? []).joined(separator: "；"))" }
        let raw = try await chat(user: prompt + "\n\n" + list.joined(separator: "\n---\n"), jsonMode: true)
        let cols = (try? LLMService.extractJSON(raw, [CollectionOut].self)) ?? []
        Database.shared.run("DELETE FROM collections WHERE project_id=?", [projectId])
        for col in cols.prefix(12) {
            let ids = clips.filter { c in col.clips.contains(where: { $0.contains(c.outline) || c.outline.contains($0) }) }
                .prefix(settings.maxClipsPerCollection)
            guard ids.count >= 2 else { continue }
            Database.shared.run("INSERT INTO collections(id,project_id,title,clip_ids,created_at) VALUES(?,?,?,?,?)",
                                [UUID().uuidString, projectId, col.collection_title,
                                 (try? JSONEncoder().encode(ids.map { $0.outline })).flatMap { String(data: $0, encoding: .utf8) } ?? "[]",
                                 Date().timeIntervalSince1970])
        }
        return cols
    }

    // MARK: - 工具
    func chat(user: String, jsonMode: Bool) async throws -> String {
        try await LLMService.shared.chat([LLMMessage(role: "user", content: user)], jsonMode: jsonMode)
    }

    static func chunk(_ text: String, maxChars: Int) -> [String] {
        guard text.count > maxChars else { return [text] }
        var out: [String] = []
        var cur = ""
        for block in text.components(separatedBy: "\n\n") {
            if cur.count + block.count > maxChars, !cur.isEmpty {
                out.append(cur); cur = block
            } else {
                cur += (cur.isEmpty ? "" : "\n\n") + block
            }
        }
        if !cur.isEmpty { out.append(cur) }
        return out
    }
}
