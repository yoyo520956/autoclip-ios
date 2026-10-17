import Foundation

/// 核心数据模型（对齐原版 models/ 与 studio/models.py 的 Draft/Scene 语义）

enum SourceKind: String, Codable { case file, bilibili, youtube, album }

enum ProjectStatus: String, Codable {
    case created, probing, transcribing, analyzing, rendering, done, failed, canceled
    var label: String {
        switch self {
        case .created: return "已创建"
        case .probing: return "解析中"
        case .transcribing: return "转写中"
        case .analyzing: return "AI 分析中"
        case .rendering: return "渲染中"
        case .done: return "完成"
        case .failed: return "失败"
        case .canceled: return "已取消"
        }
    }
}

enum RenderStatus: String, Codable {
    case pending, rendering, done, failed
    var label: String {
        switch self {
        case .pending: return "待渲染"
        case .rendering: return "渲染中"
        case .done: return "已出片"
        case .failed: return "失败"
        }
    }
}

struct Project: Identifiable, Codable {
    var id: String = UUID().uuidString
    var title: String
    var sourceKind: SourceKind
    var sourceRef: String          // 文件路径 / URL
    var status: ProjectStatus = .created
    var createdAt: Date = Date()
    var updatedAt: Date = Date()
    var duration: Double?
    var width: Int?
    var height: Int?
    var fps: Double?
    var error: String?

    static func from(row: [String: Any]) -> Project? {
        guard let id = row["id"] as? String,
              let title = row["title"] as? String,
              let sk = row["source_kind"] as? String,
              let ref = row["source_ref"] as? String,
              let st = row["status"] as? String else { return nil }
        var p = Project(id: id, title: title, sourceKind: SourceKind(rawValue: sk) ?? .file, sourceRef: ref)
        p.status = ProjectStatus(rawValue: st) ?? .created
        p.createdAt = Date(timeIntervalSince1970: row["created_at"] as? Double ?? 0)
        p.updatedAt = Date(timeIntervalSince1970: row["updated_at"] as? Double ?? 0)
        p.duration = row["duration"] as? Double
        p.width = row["width"] as? Int
        p.height = row["height"] as? Int
        p.fps = row["fps"] as? Double
        p.error = row["error"] as? String
        return p
    }

    func save() {
        let db = Database.shared
        db.run("""
        INSERT INTO projects(id,title,source_kind,source_ref,status,created_at,updated_at,duration,width,height,fps,error)
        VALUES(?,?,?,?,?,?,?,?,?,?,?,?)
        ON CONFLICT(id) DO UPDATE SET title=excluded.title,status=excluded.status,
        updated_at=excluded.updated_at,duration=excluded.duration,width=excluded.width,
        height=excluded.height,fps=excluded.fps,error=excluded.error
        """, [id, title, sourceKind.rawValue, sourceRef, status.rawValue,
              createdAt.timeIntervalSince1970, updatedAt.timeIntervalSince1970,
              duration ?? 0, width ?? 0, height ?? 0, fps ?? 0, error ?? ""])
    }

    static func all() -> [Project] {
        Database.shared.query("SELECT * FROM projects ORDER BY created_at DESC").compactMap { from(row: $0) }
    }
    static func get(_ id: String) -> Project? {
        Database.shared.query("SELECT * FROM projects WHERE id=?", [id]).first.flatMap { from(row: $0) }
    }
    mutating func touch(_ status: ProjectStatus? = nil) {
        if let s = status { self.status = s }
        updatedAt = Date()
        save()
    }
    func delete() {
        let db = Database.shared
        db.run("DELETE FROM projects WHERE id=?", [id])
        db.run("DELETE FROM clips WHERE project_id=?", [id])
        db.run("DELETE FROM segments WHERE project_id=?", [id])
        db.run("DELETE FROM tasks WHERE project_id=?", [id])
        db.run("DELETE FROM collections WHERE project_id=?", [id])
    }
}

struct Clip: Identifiable, Codable {
    var id: String = UUID().uuidString
    var projectId: String
    var idx: Int
    var title: String = ""
    var desc: String = ""          // 简介
    var hashtags: [String] = []    // 话题
    var start: Double
    var end: Double
    var score: Double?
    var style: String = "original" // original | interview | fullscreen（竖版处理在渲染时选择）
    var renderStatus: RenderStatus = .pending
    var outputPath: String?
    var coverPath: String?

    var duration: Double { max(0, end - start) }

    static func from(row: [String: Any]) -> Clip? {
        guard let id = row["id"] as? String, let pid = row["project_id"] as? String,
              let idx = row["idx"] as? Int,
              let s = row["start"] as? Double, let e = row["end"] as? Double else { return nil }
        var c = Clip(id: id, projectId: pid, idx: idx, start: s, end: e)
        c.title = row["title"] as? String ?? ""
        c.desc = row["description"] as? String ?? ""
        if let h = row["hashtags"] as? String, let arr = try? JSONDecoder().decode([String].self, from: Data(h.utf8)) { c.hashtags = arr }
        c.score = row["score"] as? Double
        c.style = row["style"] as? String ?? "original"
        c.renderStatus = RenderStatus(rawValue: row["render_status"] as? String ?? "") ?? .pending
        c.outputPath = row["output_path"] as? String
        c.coverPath = row["cover_path"] as? String
        return c
    }

    func save() {
        let h = (try? JSONEncoder().encode(hashtags)).flatMap { String(data: $0, encoding: .utf8) } ?? "[]"
        Database.shared.run("""
        INSERT INTO clips(id,project_id,idx,title,description,hashtags,start,end,score,style,render_status,output_path,cover_path,created_at)
        VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?,?)
        ON CONFLICT(id) DO UPDATE SET title=excluded.title,description=excluded.description,
        hashtags=excluded.hashtags,score=excluded.score,style=excluded.style,
        render_status=excluded.render_status,output_path=excluded.output_path,cover_path=excluded.cover_path
        """, [id, projectId, idx, title, desc, h, start, end, score ?? 0, style,
              renderStatus.rawValue, outputPath ?? "", coverPath ?? "", Date().timeIntervalSince1970])
    }

    static func forProject(_ pid: String) -> [Clip] {
        Database.shared.query("SELECT * FROM clips WHERE project_id=? ORDER BY idx", [pid]).compactMap { from(row: $0) }
    }
    func delete() { Database.shared.run("DELETE FROM clips WHERE id=?", [id]) }
}

/// 转写片段（segments 表；words 存词级时间戳 JSON）
struct Segment: Codable {
    var idx: Int
    var start: Double
    var end: Double
    var text: String
    var words: [Word]?
    struct Word: Codable { var w: String; var s: Double; var e: Double }

    static func all(projectId: String) -> [Segment] {
        Database.shared.query("SELECT * FROM segments WHERE project_id=? ORDER BY idx", [projectId]).compactMap { row in
            guard let idx = row["idx"] as? Int, let s = row["start"] as? Double,
                  let e = row["end"] as? Double, let t = row["text"] as? String else { return nil }
            var seg = Segment(idx: idx, start: s, end: e, text: t)
            if let w = row["words"] as? String, let arr = try? JSONDecoder().decode([Word].self, from: Data(w.utf8)) { seg.words = arr }
            return seg
        }
    }
    func save(projectId: String) {
        let w = (try? JSONEncoder().encode(words)).flatMap { String(data: $0, encoding: .utf8) }
        Database.shared.run("INSERT INTO segments(project_id,idx,start,end,text,words) VALUES(?,?,?,?,?,?)",
                            [projectId, idx, start, end, text, w ?? ""])
    }
    static func clear(projectId: String) { Database.shared.run("DELETE FROM segments WHERE project_id=?", [projectId]) }
}

/// 任务记录（tasks 表；等价 Celery 任务 + 断点恢复）
struct TaskRecord: Identifiable, Codable {
    var id: String = UUID().uuidString
    var projectId: String?
    var kind: String            // process_project | render_clip | transcribe ...
    var state: String = "queued" // queued | running | done | failed | canceled
    var progress: Double = 0
    var detail: String = ""
    var payload: String = "{}"
    var createdAt: Date = Date()

    func save() {
        Database.shared.run("""
        INSERT INTO tasks(id,project_id,kind,state,progress,detail,payload,created_at,updated_at)
        VALUES(?,?,?,?,?,?,?,?,?)
        ON CONFLICT(id) DO UPDATE SET state=excluded.state,progress=excluded.progress,
        detail=excluded.detail,updated_at=excluded.updated_at
        """, [id, projectId ?? "", kind, state, progress, detail, payload,
              createdAt.timeIntervalSince1970, Date().timeIntervalSince1970])
    }
    static func from(row: [String: Any]) -> TaskRecord? {
        guard let id = row["id"] as? String, let kind = row["kind"] as? String else { return nil }
        var t = TaskRecord(id: id, projectId: row["project_id"] as? String, kind: kind)
        t.state = row["state"] as? String ?? "queued"
        t.progress = row["progress"] as? Double ?? 0
        t.detail = row["detail"] as? String ?? ""
        t.payload = row["payload"] as? String ?? "{}"
        t.createdAt = Date(timeIntervalSince1970: row["created_at"] as? Double ?? 0)
        return t
    }
    static func active() -> [TaskRecord] {
        Database.shared.query("SELECT * FROM tasks WHERE state IN ('queued','running') ORDER BY created_at").compactMap { from(row: $0) }
    }
    static func recent(limit: Int = 30) -> [TaskRecord] {
        Database.shared.query("SELECT * FROM tasks ORDER BY created_at DESC LIMIT \(limit)").compactMap { from(row: $0) }
    }
}
