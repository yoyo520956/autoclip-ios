import Foundation

/// 统一目录布局（对齐原版 path_manager.py 语义）
enum Paths {
    static let root = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    static var imports: URL { root.appendingPathComponent("imports", isDirectory: true) }
    static var outputs: URL { root.appendingPathComponent("outputs", isDirectory: true) }
    static var covers: URL { root.appendingPathComponent("outputs/covers", isDirectory: true) }
    static var subtitles: URL { root.appendingPathComponent("outputs/subtitles", isDirectory: true) }
    static var temp: URL { FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("work", isDirectory: true) }
    static var dbFile: URL { root.appendingPathComponent("data/autoclip.db") }
    static var prompts: URL { Bundle.main.resourceURL!.appendingPathComponent("Prompts", isDirectory: true) }

    @discardableResult
    static func ensureAll() -> Bool {
        var ok = true
        for d in [imports, outputs, covers, subtitles, temp, dbFile.deletingLastPathComponent()] {
            do { try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true) }
            catch { Log.app.error("目录创建失败 \(d.path): \(error.localizedDescription)"); ok = false }
        }
        return ok
    }

    /// 磁盘剩余空间（字节）。< 1GB 时拒绝新建任务（矩阵 I 节）。
    static var freeDiskBytes: Int64 {
        let url = URL(fileURLWithPath: NSHomeDirectory())
        guard let v = try? url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]) else { return -1 }
        return v.volumeAvailableCapacityForImportantUsage ?? -1
    }
    static var hasEnoughDisk: Bool { freeDiskBytes > 1_000_000_000 }

    static func cleanTemp() {
        try? FileManager.default.removeItem(at: temp)
        try? FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
    }
}
