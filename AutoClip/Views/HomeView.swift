import SwiftUI
import PhotosUI
import UniformTypeIdentifiers

/// 首页：导入 → 建项目 → 一键出片（对齐 HomePage.tsx）
struct HomeView: View {
    @State private var urlText = ""
    @State private var showFilePicker = false
    @State private var showPhotoPicker = false
    @State private var photoItem: PhotosPickerItem?
    @State private var contentType = SettingsStore.shared.contentType
    @State private var busy = false
    @State private var message: String?
    @State private var tasks: [TaskRecord] = TaskRecord.recent(limit: 8)
    @State private var diskOK = Paths.hasEnoughDisk

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 14) {
                    Card {
                        VStack(alignment: .leading, spacing: 12) {
                            Text("一个链接，一键出片").font(.system(size: 20, weight: .bold)).foregroundColor(Theme.ink)
                            Text("粘贴 B站 / YouTube 链接（B 站直下 v0.3 支持），或直接导入本地视频。AI 自动转写、切片、出标题与封面。")
                                .font(.system(size: 13)).foregroundColor(Theme.sub)

                            TextField("https://（B 站 / YouTube）", text: $urlText)
                                .textFieldStyle(.plain)
                                .font(.system(size: 14))
                                .padding(11)
                                .background(Theme.bg)
                                .cornerRadius(10)
                                .autocorrectionDisabled()

                            HStack(spacing: 10) {
                                Button {
                                    showFilePicker = true
                                } label: {
                                    Label("导入视频", systemImage: "doc.badge.plus")
                                        .font(.system(size: 14, weight: .medium))
                                        .frame(maxWidth: .infinity)
                                        .padding(.vertical, 11)
                                        .background(Theme.bg)
                                        .cornerRadius(10)
                                        .foregroundColor(Theme.ink)
                                }
                                PhotosPicker(selection: $photoItem, matching: .videos) {
                                    Label("相册", systemImage: "photo.on.rectangle")
                                        .font(.system(size: 14, weight: .medium))
                                        .frame(maxWidth: .infinity)
                                        .padding(.vertical, 11)
                                        .background(Theme.bg)
                                        .cornerRadius(10)
                                        .foregroundColor(Theme.ink)
                                }
                            }

                            Button {
                                startFromURL()
                            } label: {
                                if busy { ProgressView().tint(.white).frame(maxWidth: .infinity).padding(.vertical, 12) }
                                else { Text("开始处理").frame(maxWidth: .infinity).padding(.vertical, 12) }
                            }
                            .buttonStyle(CTAStyle())
                            .disabled(busy)
                        }
                    }

                    // 内容类型（prompt/ 七类）
                    Card {
                        VStack(alignment: .leading, spacing: 10) {
                            Text("内容类型").font(.system(size: 14, weight: .semibold)).foregroundColor(Theme.ink)
                            LazyVGrid(columns: [GridItem(.adaptive(minimum: 76), spacing: 8)], spacing: 8) {
                                ForEach(PromptAssets.contentTypes, id: \.self) { ct in
                                    let selected = contentType == ct
                                    Button { contentType = ct; SettingsStore.shared.contentType = ct } label: {
                                        Text(PromptAssets.contentTypeLabels[ct] ?? ct)
                                            .font(.system(size: 12, weight: selected ? .semibold : .regular))
                                            .padding(.horizontal, 10).padding(.vertical, 7)
                                            .background(selected ? Theme.ink : Theme.bg)
                                            .foregroundColor(selected ? .white : Theme.sub)
                                            .cornerRadius(16)
                                    }
                                }
                            }
                        }
                    }

                    // 任务进度
                    if !tasks.isEmpty {
                        Card {
                            VStack(alignment: .leading, spacing: 12) {
                                Text("最近任务").font(.system(size: 14, weight: .semibold)).foregroundColor(Theme.ink)
                                ForEach(tasks) { t in
                                    VStack(alignment: .leading, spacing: 6) {
                                        HStack {
                                            Text(t.kind == "process_project" ? "处理项目" : "渲染切片")
                                                .font(.system(size: 13, weight: .medium)).foregroundColor(Theme.ink)
                                            Spacer()
                                            StatusPill(text: stateLabel(t.state),
                                                       color: stateColor(t.state))
                                        }
                                        if t.state == "running" || t.state == "queued" {
                                            ProgressLine(value: t.progress)
                                            Text(t.detail.isEmpty ? "排队中" : t.detail)
                                                .font(.system(size: 11)).foregroundColor(Theme.muted)
                                        } else if !t.detail.isEmpty {
                                            Text(t.detail).font(.system(size: 11)).foregroundColor(Theme.muted).lineLimit(2)
                                        }
                                    }
                                    .padding(.vertical, 2)
                                }
                            }
                        }
                    }

                    if !diskOK {
                        Card {
                            Label("磁盘空间不足 1GB，无法新建任务。请先清理。", systemImage: "exclamationmark.triangle")
                                .font(.system(size: 13)).foregroundColor(Theme.error)
                        }
                    }
                    if let message {
                        Text(message).font(.system(size: 12)).foregroundColor(Theme.sub)
                            .multilineTextAlignment(.center)
                    }
                }
                .padding(14)
                .padding(.bottom, 30)
            }
            .background(Theme.bg.ignoresSafeArea())
            .navigationTitle("AutoClip")
            .navigationBarTitleDisplayMode(.inline)
            .fileImporter(isPresented: $showFilePicker, allowedContentTypes: [.movie, .mpeg4Movie, .quickTimeMovie, .audiovisualContent]) { result in
                handleFilePick(result)
            }
            .onChange(of: photoItem) { item in
                handlePhotoPick(item)
            }
            .onReceive(NotificationCenter.default.publisher(for: TaskQueue.progressNotification)) { _ in
                tasks = TaskRecord.recent(limit: 8)
                diskOK = Paths.hasEnoughDisk
            }
            .onAppear {
                tasks = TaskRecord.recent(limit: 8)
                diskOK = Paths.hasEnoughDisk
            }
        }
    }

    private func stateLabel(_ s: String) -> String {
        switch s {
        case "queued": return "排队"
        case "running": return "进行中"
        case "done": return "完成"
        case "failed": return "失败"
        case "canceled": return "已取消"
        default: return s
        }
    }
    private func stateColor(_ s: String) -> Color {
        switch s {
        case "done": return Theme.ok
        case "failed": return Theme.error
        case "running": return Theme.accent
        default: return Theme.muted
        }
    }

    private func startFromURL() {
        let url = urlText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !url.isEmpty else { return }
        let isBili = url.contains("bilibili.com") || url.contains("b23.tv")
        let isYT = url.contains("youtube.com") || url.contains("youtu.be")
        if isYT {
            message = "YouTube 下载依赖桌面版 yt-dlp 的 JS 求解器，iOS 端无法内置。请先在电脑下载后 AirDrop/文件导入本 App。"
            return
        }
        if isBili {
            message = "B 站直连下载在 v0.3 提供。当前请先下载后导入。"
            return
        }
        message = "暂不支持该链接。请导入本地视频文件。"
    }

    private func handleFilePick(_ result: Result<URL, Error>) {
        guard case .success(let picked) = result else { return }
        let secured = picked.startAccessingSecurityScopedResource()
        defer { if secured { picked.stopAccessingSecurityScopedResource() } }
        createProject(from: picked)
    }

    private func handlePhotoPick(_ item: PhotosPickerItem?) {
        guard let item else { return }
        busy = true
        Task {
            do {
                guard let data = try await item.loadTransferable(type: Data.self) else {
                    throw AppError.import_("相册读取失败")
                }
                let dst = Paths.imports.appendingPathComponent("album_\(Int(Date().timeIntervalSince1970)).mp4")
                try data.write(to: dst)
                await MainActor.run { createProject(from: dst, cleanupTemp: false) }
            } catch {
                await MainActor.run { message = "导入失败: \(error.localizedDescription)"; busy = false }
            }
        }
    }

    private func createProject(from src: URL, cleanupTemp: Bool = true) {
        busy = true
        Task {
            do {
                // 拷贝进沙盒（安全区外长期保留）
                let name = "import_\(Int(Date().timeIntervalSince1970))_\(src.lastPathComponent)"
                let dst = Paths.imports.appendingPathComponent(name)
                try? FileManager.default.removeItem(at: dst)
                try FileManager.default.copyItem(at: src, to: dst)
                if cleanupTemp, src.path.hasPrefix(PathWork.root.path) { /* 同区拷贝无需清理 */ }
                var project = Project(title: src.deletingPathExtension().lastPathComponent, sourceKind: .file, sourceRef: dst.path)
                project.save()
                TaskQueue.shared.enqueueProcess(projectId: project.id)
                await MainActor.run {
                    busy = false
                    message = "已创建项目「\(project.title)」，开始处理…"
                    tasks = TaskRecord.recent(limit: 8)
                }
            } catch {
                await MainActor.run { message = "导入失败: \(error.localizedDescription)"; busy = false }
            }
        }
    }
}

enum PathWork { static let root = Paths.root }

/// 实心墨按钮样式
struct CTAStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 15, weight: .semibold))
            .foregroundColor(configuration.isPressed ? .white.opacity(0.8) : .white)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 12)
            .background(Theme.ink)
            .cornerRadius(12)
    }
}
