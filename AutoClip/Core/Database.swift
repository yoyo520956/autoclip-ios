import Foundation
import SQLite3

/// SQLITE_TRANSIENT 宏的 Swift 桥接（SQLite3 模块不导出 C 宏）
private let SQLITE_TRANSIENT = unsafeBitCast(OpaquePointer(bitPattern: -1), to: sqlite3_destructor_type.self)

/// SQLite3 轻封装（替代 SQLAlchemy + Alembic；单文件 data/autoclip.db）
final class Database {
    static let shared = Database()
    private var db: OpaquePointer?
    private let queue = DispatchQueue(label: "autoclip.db")

    private init() {}

    func migrate() {
        queue.sync {
            openIfNeeded()
            exec("""
            CREATE TABLE IF NOT EXISTS projects(
              id TEXT PRIMARY KEY, title TEXT NOT NULL, source_kind TEXT NOT NULL,
              source_ref TEXT NOT NULL, status TEXT NOT NULL DEFAULT 'created',
              created_at REAL NOT NULL, updated_at REAL NOT NULL,
              duration REAL, width INTEGER, height INTEGER, fps REAL,
              meta TEXT NOT NULL DEFAULT '{}', error TEXT
            );
            CREATE TABLE IF NOT EXISTS clips(
              id TEXT PRIMARY KEY, project_id TEXT NOT NULL, idx INTEGER NOT NULL,
              title TEXT, description TEXT, hashtags TEXT,
              start REAL NOT NULL, end REAL NOT NULL, score REAL,
              style TEXT NOT NULL DEFAULT 'original',
              render_status TEXT NOT NULL DEFAULT 'pending',
              output_path TEXT, cover_path TEXT, meta TEXT NOT NULL DEFAULT '{}',
              created_at REAL NOT NULL
            );
            CREATE TABLE IF NOT EXISTS segments(
              id INTEGER PRIMARY KEY AUTOINCREMENT, project_id TEXT NOT NULL,
              idx INTEGER NOT NULL, start REAL NOT NULL, end REAL NOT NULL,
              text TEXT NOT NULL, words TEXT
            );
            CREATE TABLE IF NOT EXISTS collections(
              id TEXT PRIMARY KEY, project_id TEXT NOT NULL, title TEXT,
              clip_ids TEXT NOT NULL DEFAULT '[]', created_at REAL NOT NULL
            );
            CREATE TABLE IF NOT EXISTS tasks(
              id TEXT PRIMARY KEY, project_id TEXT, kind TEXT NOT NULL,
              state TEXT NOT NULL DEFAULT 'queued', progress REAL NOT NULL DEFAULT 0,
              detail TEXT, payload TEXT NOT NULL DEFAULT '{}',
              created_at REAL NOT NULL, updated_at REAL NOT NULL
            );
            CREATE TABLE IF NOT EXISTS kv(key TEXT PRIMARY KEY, value TEXT NOT NULL);
            CREATE INDEX IF NOT EXISTS idx_clips_project ON clips(project_id);
            CREATE INDEX IF NOT EXISTS idx_seg_project ON segments(project_id);
            CREATE INDEX IF NOT EXISTS idx_tasks_state ON tasks(state);
            """)
        }
    }

    private func openIfNeeded() {
        guard db == nil else { return }
        try? Paths.dbFile.deletingLastPathComponent().ensureDir()
        let rc = sqlite3_open_v2(Paths.dbFile.path, &db, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX, nil)
        guard rc == SQLITE_OK else { Log.app.error("SQLite 打开失败 rc=\(rc)"); return }
        exec("PRAGMA journal_mode=WAL; PRAGMA busy_timeout=5000; PRAGMA synchronous=NORMAL;")
    }

    func exec(_ sql: String) { queue.sync { self._exec(sql) } }
    private func _exec(_ sql: String) {
        openIfNeeded()
        var err: UnsafeMutablePointer<CChar>?
        sqlite3_exec(db, sql, nil, nil, &err)
        if let e = err {
            Log.app.error("SQL 错误: \(String(cString: e)) :: \(sql.prefix(120))")
            sqlite3_free(e)
        }
    }

    /// 查询返回行字典（文本/双精度/整型自动映射）
    func query(_ sql: String, _ bind: [Any] = []) -> [[String: Any]] {
        queue.sync { self._query(sql, bind) }
    }
    private func _query(_ sql: String, _ bind: [Any]) -> [[String: Any]] {
        openIfNeeded()
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            Log.app.error("prepare 失败: \(String(cString: sqlite3_errmsg(self.db)))")
            return []
        }
        defer { sqlite3_finalize(stmt) }
        bindParams(stmt!, bind)
        var rows: [[String: Any]] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            var row: [String: Any] = [:]
            for i in 0..<sqlite3_column_count(stmt) {
                let name = String(cString: sqlite3_column_name(stmt, i))
                switch sqlite3_column_type(stmt, i) {
                case SQLITE_TEXT: row[name] = String(cString: sqlite3_column_text(stmt, i))
                case SQLITE_FLOAT: row[name] = sqlite3_column_double(stmt, i)
                case SQLITE_INTEGER: row[name] = Int(sqlite3_column_int64(stmt, i))
                case SQLITE_BLOB: row[name] = Data(bytes: sqlite3_column_blob(stmt, i), count: Int(sqlite3_column_bytes(stmt, i)))
                default: row[name] = NSNull()
                }
            }
            rows.append(row)
        }
        return rows
    }

    func run(_ sql: String, _ bind: [Any] = []) {
        queue.sync {
            openIfNeeded()
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
                Log.app.error("prepare 失败: \(String(cString: sqlite3_errmsg(self.db)))")
                return
            }
            defer { sqlite3_finalize(stmt) }
            bindParams(stmt!, bind)
            if sqlite3_step(stmt) != SQLITE_DONE {
                Log.app.error("exec 失败: \(String(cString: sqlite3_errmsg(self.db)))")
            }
        }
    }

    private func bindParams(_ stmt: OpaquePointer, _ bind: [Any]) {
        for (i, v) in bind.enumerated() {
            let idx = Int32(i + 1)
            switch v {
            case let s as String: sqlite3_bind_text(stmt, idx, s, -1, SQLITE_TRANSIENT)
            case let d as Double: sqlite3_bind_double(stmt, idx, d)
            case let n as Int: sqlite3_bind_int64(stmt, idx, Int64(n))
            case let n as Int64: sqlite3_bind_int64(stmt, idx, n)
            case let b as Bool: sqlite3_bind_int64(stmt, idx, b ? 1 : 0)
            case let data as Data: data.withUnsafeBytes { sqlite3_bind_blob(stmt, idx, $0.baseAddress, Int32($0.count), SQLITE_TRANSIENT) }
            default: sqlite3_bind_null(stmt, idx)
            }
        }
    }
    func scalar(_ sql: String, _ bind: [Any] = []) -> Any? { _query(sql, bind).first?.first?.value }
    func kvGet(_ key: String) -> String? { query("SELECT value FROM kv WHERE key=?", [key]).first?["value"] as? String }
    func kvSet(_ key: String, _ value: String) { run("INSERT INTO kv(key,value) VALUES(?,?) ON CONFLICT(key) DO UPDATE SET value=excluded.value", [key, value]) }
}

extension URL {
    func ensureDir() throws {
        try FileManager.default.createDirectory(at: self, withIntermediateDirectories: true)
    }
}
