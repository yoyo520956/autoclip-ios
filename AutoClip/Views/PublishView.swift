import SwiftUI

/// 发布页 v0.1：发布文案管理（标题/简介/话题 复制）
/// v0.3 接入：B 站直发（bilibili_publisher.py 等价）+ Upload-Post（TikTok/IG/Shorts/X）
struct PublishView: View {
    @State private var projects: [Project] = Project.all().filter { $0.status == .done }
    @State private var selected: String?
    @State private var clips: [Clip] = []
    @State private var copiedTip: String?

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                if projects.isEmpty {
                    VStack(spacing: 10) {
                        Image(systemName: "paperplane").font(.system(size: 38)).foregroundColor(Theme.muted)
                        Text("暂无完成的项目").font(.system(size: 14)).foregroundColor(Theme.sub)
                        Text("处理完成后可在这里管理发布文案；直发 B 站/海外平台在 v0.3 提供")
                            .font(.system(size: 12)).foregroundColor(Theme.muted)
                            .multilineTextAlignment(.center)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 8) {
                            ForEach(projects) { p in
                                let on = selected == p.id
                                Button { select(p.id) } label: {
                                    Text(p.title).font(.system(size: 12, weight: on ? .semibold : .regular))
                                        .padding(.horizontal, 12).padding(.vertical, 7)
                                        .background(on ? Theme.ink : Theme.card)
                                        .foregroundColor(on ? .white : Theme.sub)
                                        .cornerRadius(16)
                                }
                            }
                        }
                        .padding(.horizontal, 14)
                    }
                    .padding(.vertical, 10)
                    if !clips.isEmpty {
                        List {
                            ForEach(clips) { clip in
                                VStack(alignment: .leading, spacing: 6) {
                                    Text(clip.title).font(.system(size: 14, weight: .semibold)).foregroundColor(Theme.ink)
                                    if !clip.desc.isEmpty {
                                        Text(clip.desc).font(.system(size: 12)).foregroundColor(Theme.sub)
                                    }
                                    if !clip.hashtags.isEmpty {
                                        Text(clip.hashtags.map { "#\($0)" }.joined(separator: " "))
                                            .font(.system(size: 12)).foregroundColor(Theme.accent)
                                    }
                                    HStack(spacing: 14) {
                                        Button { copy(clip.title) } label: { Label("标题", systemImage: "doc.on.doc").font(.system(size: 12)) }
                                        Button { copy(clip.desc) } label: { Label("简介", systemImage: "doc.on.doc").font(.system(size: 12)) }
                                        Button { copy(clip.hashtags.map { "#\($0)" }.joined(separator: " ")) } label: { Label("话题", systemImage: "doc.on.doc").font(.system(size: 12)) }
                                    }
                                    .buttonStyle(.borderless)
                                    .foregroundColor(Theme.accent)
                                }
                                .padding(.vertical, 4)
                            }
                        }
                        .listStyle(.plain)
                    } else {
                        Spacer()
                    }
                }
                if let tip = copiedTip {
                    Text(tip).font(.system(size: 12)).foregroundColor(Theme.ok).padding(.bottom, 8)
                }
            }
            .background(Theme.bg.ignoresSafeArea())
            .navigationTitle("发布")
            .onAppear { projects = Project.all().filter { $0.status == .done } }
        }
    }

    private func select(_ pid: String) {
        selected = pid
        clips = Clip.forProject(pid)
    }
    private func copy(_ text: String) {
        UIPasteboard.general.string = text
        copiedTip = "已复制"
        Task { try? await Task.sleep(nanoseconds: 1_500_000_000); await MainActor.run { copiedTip = nil } }
    }
}
