import Foundation
import AVFoundation
import CoreMedia

/// 媒体探测（对齐 pipeline/media_precheck.py：时长/分辨率/fps/音轨/损坏检查）
struct MediaInfo {
    var duration: Double = 0
    var width: Int = 0
    var height: Int = 0
    var fps: Double = 0
    var hasAudio = false
    var hasVideo = false
    var fileSize: Int64 = 0
    var problems: [String] = []   // 预检问题清单

    var isOK: Bool { problems.isEmpty }
    var summary: String { "\(width)×\(height) \(String(format: "%.1f", fps))fps \(TimeFmt.hms(duration))" }
}

enum TimeFmt {
    static func hms(_ t: Double) -> String {
        let s = Int(t.rounded())
        return String(format: "%02d:%02d:%02d", s / 3600, (s % 3600) / 60, s % 60)
    }
    static func stamp(_ t: Double) -> String {
        let ms = Int((t - floor(t)) * 1000)
        let s = Int(t)
        return String(format: "%02d:%02d:%02d.%03d", s / 3600, (s % 3600) / 60, s % 60, ms)
    }
}

enum MediaProbe {
    static func probe(_ url: URL) async -> MediaInfo {
        var info = MediaInfo()
        let asset = AVURLAsset(url: url)
        if let attrs = try? FileManager.default.attributesOfItem(atPath: url.path) {
            info.fileSize = attrs[.size] as? Int64 ?? 0
        }
        do {
            let duration = try await asset.load(.duration)
            info.duration = CMTimeGetSeconds(duration)
            let tracks = try await asset.loadTracks(withMediaType: .video)
            if let v = tracks.first {
                let size = try await v.load(.naturalSize)
                info.width = Int(abs(size.width))
                info.height = Int(abs(size.height))
                if let rate = try? await v.load(.nominalFrameRate) { info.fps = Double(rate) }
                info.hasVideo = true
            }
            let audio = try await asset.loadTracks(withMediaType: .audio)
            info.hasAudio = !audio.isEmpty
        } catch {
            info.problems.append("无法解析媒体：\(error.localizedDescription)")
            return info
        }
        if !info.hasVideo { info.problems.append("没有视频轨") }
        if !info.hasAudio { info.problems.append("没有音频轨（无法转写）") }
        if info.duration < 3 { info.problems.append("时长过短（<3 秒）") }
        if info.duration > 4 * 3600 { info.problems.append("时长超 4 小时，建议分段处理") }
        if info.width == 0 || info.height == 0 { info.problems.append("分辨率未知") }
        return info
    }
}
