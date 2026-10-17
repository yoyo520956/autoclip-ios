import SwiftUI

/// 项目列表（对齐 ProjectDetailPage.tsx 的列表态）
struct ProjectsView: View {
    @State private var projects: [Project] = Project.all()

    var body: some View {
        NavigationStack {
            Group {
                if projects.isEmpty {
                    VStack(spacing: 10) {
                        Image(systemName: "film.stack").font(.system(size: 40)).foregroundColor(Theme.muted)
                        Text("还没有项目").font(.system(size: 15, weight: .medium)).foregroundColor(Theme.sub)
                        Text("到「开始」页导入视频，AI 会自动切片").font(.system(size: 12)).foregroundColor(Theme.muted)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    ScrollView {
                        LazyVStack(spacing: 10) {
                            ForEach(projects) { p in
                                NavigationLink(value: p.id) {
                                    ProjectRow(project: p)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        .padding(14)
                    }
                }
            }
            .background(Theme.bg.ignoresSafeArea())
            .navigationTitle("项目")
            .navigationDestination(for: String.self) { pid in
                ProjectDetailView(projectId: pid)
            }
            .onReceive(NotificationCenter.default.publisher(for: TaskQueue.progressNotification)) { _ in
                projects = Project.all()
            }
            .onAppear { projects = Project.all() }
        }
    }
}

struct ProjectRow: View {
    var project: Project
    var body: some View {
        HStack(spacing: 12) {
            RoundedRectangle(cornerRadius: 8)
                .fill(Theme.bg)
                .frame(width: 64, height: 44)
                .overlay(
                    Image(systemName: "play.rectangle").foregroundColor(Theme.muted)
                )
            VStack(alignment: .leading, spacing: 5) {
                Text(project.title).font(.system(size: 14, weight: .medium)).foregroundColor(Theme.ink).lineLimit(1)
                HStack(spacing: 8) {
                    if let d = project.duration { Text(TimeFmt.hms(d)).font(.system(size: 11)).foregroundColor(Theme.muted) }
                    if let w = project.width, let h = project.height { Text("\(w)×\(h)").font(.system(size: 11)).foregroundColor(Theme.muted) }
                    Text(DateFormatter.log.string(from: project.createdAt)).font(.system(size: 10)).foregroundColor(Theme.muted)
                }
            }
            Spacer()
            StatusPill(text: project.status.label, color: statusColor(project.status))
        }
        .padding(13)
        .background(Theme.card)
        .cornerRadius(12)
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Theme.line, lineWidth: 1))
    }
    private func statusColor(_ s: ProjectStatus) -> Color {
        switch s {
        case .done: return Theme.ok
        case .failed: return Theme.error
        case .rendering, .transcribing, .analyzing: return Theme.accent
        default: return Theme.muted
        }
    }
}

/// 项目详情：切片列表 + 播放 + 导出（对齐 ProjectDetailPage.tsx）
struct ProjectDetailView: View {
    let projectId: String
    @State private var project: Project?
    @State private var clips: [Clip] = []
    @State private var playingClip: Clip?
    @State private var shareURL: URL?
    @State private var showShare = false
    @State private var confirmDelete = false

    var body: some View {
        ScrollView {
            VStack(spacing: 12) {
                if let p = project {
                    Card {
                        VStack(alignment: .leading, spacing: 8) {
                            HStack {
                                Text(p.title).font(.system(size: 17, weight: .bold)).foregroundColor(Theme.ink)
                                Spacer()
                                StatusPill(text: p.status.label, color: p.status == .done ? Theme.ok : Theme.accent)
                            }
                            Row(title: "时长", value: p.duration.map { TimeFmt.hms($0) } ?? "-")
                            Row(title: "分辨率", value: p.width.map { "\($0)×\(p.height ?? 0) \($0 < p.height ?? 0 ? "竖版" : "横版")" } ?? "-")
                            if let err = p.error, !err.isEmpty {
                                Text(err).font(.system(size: 12)).foregroundColor(Theme.error)
                            }
                            HStack(spacing: 10) {
                                if TaskQueue.shared.isProcessing(projectId: p.id) {
                                    ProgressView().scaleEffect(0.8)
                                    Text("处理中…").font(.system(size: 12)).foregroundColor(Theme.sub)
                                } else {
                                    Button {
                                        TaskQueue.shared.enqueueProcess(projectId: p.id)
                                    } label: {
                                        Label("重新处理", systemImage: "arrow.clockwise")
                                            .font(.system(size: 13, weight: .medium)).foregroundColor(Theme.accent)
                                    }
                                }
                                Spacer()
                                Button {
                                    exportSRT()
                                } label: {
                                    Label("导出字幕", systemImage: "text.quote")
                                        .font(.system(size: 13)).foregroundColor(Theme.sub)
                                }
                            }
                        }
                    }

                    if clips.isEmpty {
                        Card {
                            Text("暂无切片（处理完成后这里会出现切片列表）")
                                .font(.system(size: 13)).foregroundColor(Theme.muted)
                        }
                    } else {
                        ForEach(clips) { clip in
                            ClipCard(clip: clip) {
                                if let path = clip.outputPath, FileManager.default.fileExists(atPath: path) {
                                    playingClip = clip
                                }
                            } onShare: {
                                if let path = clip.outputPath, FileManager.default.fileExists(atPath: path) {
                                    shareURL = URL(fileURLWithPath: path)
                                    showShare = true
                                }
                            } onRerender: {
                                TaskQueue.shared.enqueueRender(projectId: projectId)
                            }
                        }
                    }

                    Button(role: .destructive) { confirmDelete = true } label: {
                        Text("删除项目").font(.system(size: 13)).foregroundColor(Theme.error)
                    }
                    .padding(.top, 6)
                }
            }
            .padding(14)
            .padding(.bottom, 30)
        }
        .background(Theme.bg.ignoresSafeArea())
        .navigationTitle("项目详情")
        .navigationBarTitleDisplayMode(.inline)
        .onReceive(NotificationCenter.default.publisher(for: TaskQueue.progressNotification)) { _ in reload() }
        .onAppear { reload() }
        .sheet(item: $playingClip) { clip in
            PlayerSheet(url: URL(fileURLWithPath: clip.outputPath ?? ""))
                .ignoresSafeArea()
        }
        .sheet(isPresented: $showShare) {
            if let shareURL {
                ShareSheet(items: [shareURL])
            }
        }
        .confirmationDialog("确定删除该项目与全部切片？", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("删除", role: .destructive) {
                project?.delete()
                // 清理文件
                if let p = project {
                    try? FileManager.default.removeItem(at: Paths.outputs.appendingPathComponent(p.id, isDirectory: true))
                    try? FileManager.default.removeItem(at: Paths.subtitles.appendingPathComponent("\(p.id).srt"))
                    try? FileManager.default.removeItem(at: URL(fileURLWithPath: p.sourceRef))
                }
                self.project = nil
            }
        }
    }

    private func reload() {
        project = Project.get(projectId)
        clips = Clip.forProject(projectId)
    }

    private func exportSRT() {
        let src = Paths.subtitles.appendingPathComponent("\(projectId).srt")
        guard FileManager.default.fileExists(atPath: src.path) else { return }
        shareURL = src
        showShare = true
    }
}

struct ClipCard: View {
    var clip: Clip
    var onPlay: () -> Void
    var onShare: () -> Void
    var onRerender: () -> Void

    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: 9) {
                HStack(alignment: .top) {
                    Text(clip.title.isEmpty ? "切片 \(clip.idx + 1)" : clip.title)
                        .font(.system(size: 14, weight: .semibold)).foregroundColor(Theme.ink)
                        .lineLimit(2)
                    Spacer()
                    StatusPill(text: clip.renderStatus.label, color: clip.renderStatus == .done ? Theme.ok : (clip.renderStatus == .failed ? Theme.error : Theme.muted))
                }
                HStack(spacing: 10) {
                    Text("\(TimeFmt.hms(clip.start)) → \(TimeFmt.hms(clip.end))").font(.system(size: 11)).foregroundColor(Theme.muted)
                    Text(TimeFmt.hms(clip.duration)).font(.system(size: 11, weight: .medium)).foregroundColor(Theme.accent)
                    if let s = clip.score { Text("评分 \(String(format: "%.2f", s))").font(.system(size: 11)).foregroundColor(Theme.sub) }
                }
                if !clip.desc.isEmpty {
                    Text(clip.desc).font(.system(size: 12)).foregroundColor(Theme.sub).lineLimit(3)
                }
                if !clip.hashtags.isEmpty {
                    Text(clip.hashtags.map { "#\($0)" }.joined(separator: " "))
                        .font(.system(size: 12)).foregroundColor(Theme.accent).lineLimit(1)
                }
                HStack(spacing: 14) {
                    Button(action: onPlay) {
                        Label("播放", systemImage: "play.fill").font(.system(size: 13, weight: .medium)).foregroundColor(clip.renderStatus == .done ? Theme.accent : Theme.muted)
                    }
                    .disabled(clip.renderStatus != .done)
                    Button(action: onShare) {
                        Label("导出", systemImage: "square.and.arrow.up").font(.system(size: 13)).foregroundColor(clip.renderStatus == .done ? Theme.sub : Theme.muted)
                    }
                    .disabled(clip.renderStatus != .done)
                    Button(action: onRerender) {
                        Label("重渲", systemImage: "arrow.triangle.2.circlepath").font(.system(size: 13)).foregroundColor(Theme.sub)
                    }
                    Spacer()
                }
            }
        }
    }
}

/// 简易播放器
import AVKit
struct PlayerSheet: UIViewControllerRepresentable {
    var url: URL
    func makeUIViewController(context: Context) -> AVPlayerViewController {
        let vc = AVPlayerViewController()
        vc.player = AVPlayer(url: url)
        return vc
    }
    func updateUIViewController(_ vc: AVPlayerViewController, context: Context) {}
}

struct ShareSheet: UIViewControllerRepresentable {
    var items: [Any]
    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }
    func updateUIViewController(_ vc: UIActivityViewController, context: Context) {}
}
