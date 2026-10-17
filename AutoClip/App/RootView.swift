import SwiftUI

/// 全局骨架：首页 / 项目 / 发布 / 设置
/// 设计基调：Calm Premium —— 暖浅灰底、墨色正文、唯一强调蓝 #2D6BFF
struct RootView: View {
    @State private var tab = 0
    var body: some View {
        TabView(selection: $tab) {
            HomeView()
                .tabItem { Label("开始", systemImage: "sparkles.rectangle.stack") }
                .tag(0)
            ProjectsView()
                .tabItem { Label("项目", systemImage: "folder") }
                .tag(1)
            PublishView()
                .tabItem { Label("发布", systemImage: "paperplane") }
                .tag(2)
            SettingsView()
                .tabItem { Label("设置", systemImage: "gearshape") }
                .tag(3)
        }
        .tint(Theme.accent)
    }
}

enum Theme {
    static let accent = Color(red: 0x2D/255, green: 0x6B/255, blue: 0xFF/255)
    static let bg = Color(red: 0xF6/255, green: 0xF5/255, blue: 0xF3/255)
    static let card = Color.white
    static let ink = Color(red: 0x1A/255, green: 0x1A/255, blue: 0x19/255)
    static let sub = Color(red: 0x6E/255, green: 0x6B/255, blue: 0x66/255)
    static let muted = Color(red: 0xA8/255, green: 0xA5/255, blue: 0x9F/255)
    static let line = Color(red: 0xEB/255, green: 0xE9/255, blue: 0xE4/255)
    static let ok = Color(red: 0x5B/255, green: 0xB3/255, blue: 0x6A/255)
    static let warn = Color(red: 0xE6/255, green: 0xB2/255, blue: 0x3C/255)
    static let error = Color(red: 0xE6/255, green: 0x6A/255, blue: 0x5C/255)
}
