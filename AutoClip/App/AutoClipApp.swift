import SwiftUI

@main
struct AutoClipApp: App {
    init() {
        _ = Paths.ensureAll()
        Database.shared.migrate()
        TaskQueue.shared.recoverIfNeeded()
        Log.app.info("AutoClip 启动 v\(AppInfo.version) build \(AppInfo.build)")
    }
    var body: some Scene {
        WindowGroup {
            RootView()
        }
    }
}

enum AppInfo {
    static var version: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.0.0"
    }
    static var build: String {
        Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "1"
    }
}
