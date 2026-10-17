import Foundation

/// 本地任务队列（替代 Celery/Redis + studio/jobs.py 编排语义）
/// 串行执行（SE3 内存/散热约束）；状态持久化 tasks 表；启动恢复断点
final class TaskQueue {
    static let shared = TaskQueue()
    private let queue = OperationQueue()
    private var running: [String: TaskRecord] = [:]
    private let lock = NSLock()

    static let progressNotification = Notification.Name("autoclip.task.progress")

    private init() {
        queue.maxConcurrentOperationCount = 1
        queue.qualityOfService = .userInitiated
    }

    /// 启动恢复：running → queued 重入队（restart_recovery.py 语义）
    func recoverIfNeeded() {
        let stuck = Database.shared.query("SELECT * FROM tasks WHERE state='running'")
        for row in stuck {
            guard var t = TaskRecord.from(row: row) else { continue }
            t.state = "queued"; t.progress = 0; t.save()
        }
        for t in TaskRecord.active().filter({ $0.state == "queued" }) {
            start(record: t)
        }
    }

    // MARK: - 入口
    @discardableResult
    func enqueueProcess(projectId: String) -> TaskRecord {
        var t = TaskRecord(projectId: projectId, kind: "process_project")
        t.save()
        start(record: t)
        return t
    }

    func enqueueRender(projectId: String) {
        var t = TaskRecord(projectId: projectId, kind: "render_project")
        t.save()
        start(record: t)
    }

    func cancel(taskId: String) {
        lock.lock(); defer { lock.unlock() }
        if var t = running[taskId] {
            t.state = "canceled"
            t.save()
            running[taskId] = t
            canceled.insert(taskId)
        }
    }
    private var canceled: Set<String> = []

    // MARK: - 执行
    private func start(record: TaskRecord) {
        lock.lock()
        canceled.remove(record.id)
        running[record.id] = record
        lock.unlock()
        let op = BlockOperation { [weak self] in
            Task { await self?.run(record: record) }
        }
        queue.addOperation(op)
    }

    private func run(record: TaskRecord) async {
        var t = record
        guard !canceled.contains(t.id) else { return }
        t.state = "running"; t.save()
        let pid = t.projectId ?? ""
        do {
            switch t.kind {
            case "process_project":
                guard let project = Project.get(pid) else { throw AppError.pipeline("项目不存在") }
                try await PipelineService.shared.process(project: project) { pr in
                    self.update(t.id, progress: pr.percent, detail: "\(pr.phase) \(pr.detail)".trimmingCharacters(in: .whitespaces))
                }
            case "render_project":
                guard let project = Project.get(pid) else { throw AppError.render("项目不存在") }
                let clips = Clip.forProject(pid)
                for (i, clip) in clips.enumerated() {
                    guard !canceled.contains(t.id) else { throw CancellationError() }
                    try await RenderService.shared.render(clip: clip, project: project) { pr in
                        let overall = (Double(i) + pr.percent) / Double(max(1, clips.count))
                        self.update(t.id, progress: overall, detail: "切片 \(i + 1)/\(clips.count) \(pr.phase)")
                    }
                    _ = try? CoverService.shared.generate(clip: Clip.forProject(pid).first { $0.id == clip.id } ?? clip, project: project)
                }
            default:
                throw AppError.pipeline("未知任务类型 \(t.kind)")
            }
            finish(t.id, state: "done", detail: "")
        } catch is CancellationError {
            finish(t.id, state: "canceled", detail: "已取消")
        } catch {
            if let p = Project.get(pid), t.kind == "process_project" {
                var pp = p; pp.touch(.failed); pp.error = error.localizedDescription; pp.save()
            }
            finish(t.id, state: "failed", detail: error.localizedDescription)
        }
    }

    private func update(_ id: String, progress: Double, detail: String) {
        lock.lock()
        var t = running[id]
        lock.unlock()
        guard t != nil, !canceled.contains(id) else { return }
        t?.progress = min(1, max(0, progress))
        t?.detail = detail
        t?.save()
        NotificationCenter.default.post(name: Self.progressNotification, object: nil)
    }

    private func finish(_ id: String, state: String, detail: String) {
        lock.lock()
        var t = running[id]
        running[id] = nil
        lock.unlock()
        if t != nil {
            let oldDetail = t?.detail ?? ""
            t?.state = state
            t?.detail = detail.isEmpty ? oldDetail : detail
            if state == "done" { t?.progress = 1 }
            t?.save()
            NotificationCenter.default.post(name: Self.progressNotification, object: nil)
        }
    }

    func isProcessing(projectId: String) -> Bool {
        TaskRecord.active().contains { $0.projectId == projectId }
    }
}
