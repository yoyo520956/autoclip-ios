import Foundation

/// 字幕读写：SRT 生成/解析 + 分页规则 + 4 风格参数（对齐 publish_export.py clean/bold/box/accent）
enum SubtitleIO {
    // MARK: - SRT 写出
    static func writeSRT(segments: [Segment], to url: URL) throws {
        var text = ""
        for (i, s) in segments.enumerated() {
            text += "\(i + 1)\n\(TimeFmt.stamp(s.start)) --> \(TimeFmt.stamp(s.end))\n\(paged(s.text))\n\n"
        }
        try text.write(to: url, atomically: true, encoding: .utf8)
    }

    /// 分页：每行 ≤16 字，最多 2 行（长文本按标点/空格断行）
    static func paged(_ text: String) -> String {
        let clean = text.replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespaces)
        guard clean.count > 16 else { return clean }
        return wrapLines(clean, perLine: 16, maxLines: 2).joined(separator: "\n")
    }

    static func wrapLines(_ s: String, perLine: Int, maxLines: Int) -> [String] {
        // 先按自然断点（标点/空格）切
        let breakers: Set<Character> = ["，", "。", "！", "？", "；", "、", " ", ","]
        var tokens: [String] = []
        var tok = ""
        for ch in s {
            tok.append(ch)
            if breakers.contains(ch) { tokens.append(tok); tok = "" }
        }
        if !tok.isEmpty { tokens.append(tok) }
        var lines: [String] = []
        var cur = ""
        for t in tokens {
            if cur.count + t.count > perLine, !cur.isEmpty { lines.append(cur); cur = t }
            else { cur += t }
        }
        if !cur.isEmpty { lines.append(cur) }
        // 超 maxLines：均分前两行
        if lines.count > maxLines {
            let joined = lines.joined()
            let half = (joined.count + 1) / 2
            let idx = joined.index(joined.startIndex, offsetBy: min(half, joined.count))
            lines = [String(joined[..<idx]), String(joined[idx...])]
        }
        return lines
    }

    // MARK: - SRT 解析（字幕编辑器用）
    static func parseSRT(_ text: String) -> [(start: Double, end: Double, text: String)] {
        var out: [(Double, Double, String)] = []
        let blocks = text.components(separatedBy: "\n\n")
        for b in blocks {
            let lines = b.components(separatedBy: "\n").filter { !$0.isEmpty }
            guard lines.count >= 2 else { continue }
            let arrow = lines.first { $0.contains("-->") }
            guard let arrowLine = arrow else { continue }
            let parts = arrowLine.components(separatedBy: "-->")
            guard parts.count == 2,
                  let s = TimeFmt.parse(parts[0].trimmingCharacters(in: .whitespaces)),
                  let e = TimeFmt.parse(parts[1].trimmingCharacters(in: .whitespaces)) else { continue }
            let body = lines.filter { $0 != arrowLine && !$0.allSatisfy { $0.isNumber } }.joined(separator: "\n")
            if !body.isEmpty { out.append((s, e, body)) }
        }
        return out
    }

    // MARK: - 字幕渲染风格（publish_export.py 参数 1:1，换算为相对画高比例）
    struct Style {
        var fontRatio: Double      // 字号 / 画高
        var bold: Bool
        var stroke: CGFloat        // 描边（相对 1080 宽基准 × 画宽/1080）
        var shadow: CGFloat
        var boxOpacity: Double     // 背景框（0=无）
        var color: (r: Double, g: Double, b: Double)
        var marginBottomRatio: Double
    }
    /// 原版以 1080 高为基准的 ASS Fontsize：clean16/bold22/box17/accent20（MarginV 48/56/52/56）
    static func style(_ name: String) -> Style {
        switch name {
        case "bold":
            return .init(fontRatio: 22.0 / 1080, bold: true, stroke: 3, shadow: 1, boxOpacity: 0,
                         color: (1, 1, 1), marginBottomRatio: 56.0 / 1080)
        case "box":
            return .init(fontRatio: 17.0 / 1080, bold: false, stroke: 6, shadow: 0, boxOpacity: 0.53,
                         color: (1, 1, 1), marginBottomRatio: 52.0 / 1080)
        case "accent":
            return .init(fontRatio: 20.0 / 1080, bold: true, stroke: 3, shadow: 0, boxOpacity: 0,
                         color: (1, 229.0 / 255, 0), marginBottomRatio: 56.0 / 1080)
        default: // clean
            return .init(fontRatio: 16.0 / 1080, bold: false, stroke: 2, shadow: 0, boxOpacity: 0,
                         color: (1, 1, 1), marginBottomRatio: 48.0 / 1080)
        }
    }
}
