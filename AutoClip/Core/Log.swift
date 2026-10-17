import Foundation
import os

/// os_log + 文件双通道（对齐 LoggingSettings: level/format/file）
enum Log {
    static let app = Logger(subsystem: "com.youlong.autoclip", category: "app")
    static let pipeline = Logger(subsystem: "com.youlong.autoclip", category: "pipeline")
    static let render = Logger(subsystem: "com.youlong.autoclip", category: "render")
    static let transcribe = Logger(subsystem: "com.youlong.autoclip", category: "transcribe")
    static let llm = Logger(subsystem: "com.youlong.autoclip", category: "llm")
    static let net = Logger(subsystem: "com.youlong.autoclip", category: "net")

    private static let queue = DispatchQueue(label: "autoclip.logfile")
    private static var fileHandle: FileHandle?

    static func appendFile(_ category: String, _ message: String) {
        queue.sync {
            if fileHandle == nil {
                let url = Paths.root.appendingPathComponent("backend.log")
                if !FileManager.default.fileExists(atPath: url.path) {
                    FileManager.default.createFile(atPath: url.path, contents: nil)
                }
                fileHandle = try? FileHandle(forWritingTo: url)
            }
            let line = "\(DateFormatter.log.string(from: Date())) - \(category) - \(message)\n"
            fileHandle?.write(line.data(using: .utf8)!)
        }
    }

    static func log(_ logger: Logger, _ category: String, _ message: String) {
        logger.info("\(message, privacy: .public)")
        appendFile(category, message)
    }
}

extension DateFormatter {
    static let log: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return f
    }()
}
