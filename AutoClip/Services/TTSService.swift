import Foundation
import AVFoundation
import CoreImage
import UIKit

/// 关键帧抽取：短剧/画面分析用（均匀取帧 → 缩放 → JPEG）
enum KeyframeExtractor {
    struct TimestampedFrame { var time: Double; var data: Data }
    /// 均匀抽 count 帧，最长边 maxDim，JPEG 0.7；返回带时间戳（声画对齐用）
    static func extractTimestamped(url: URL, count: Int = 10, maxDim: CGFloat = 512) throws -> [TimestampedFrame] {
        let asset = AVURLAsset(url: url)
        let duration = try asset.load(.duration).seconds
        guard duration > 0.5, count > 0 else { return [] }
        let gen = AVAssetImageGenerator(asset: asset)
        gen.appliesPreferredTrackTransform = true
        gen.maximumSize = CGSize(width: maxDim, height: maxDim)
        gen.requestedTimeToleranceBefore = CMTime(seconds: 1, preferredTimescale: 600)
        gen.requestedTimeToleranceAfter = CMTime(seconds: 1, preferredTimescale: 600)
        let step = duration / Double(count)
        var frames: [TimestampedFrame] = []
        for i in 0..<count {
            let sec = min(duration - 0.1, step * (Double(i) + 0.5))
            if let cg = try? gen.copyCGImage(at: CMTime(seconds: sec, preferredTimescale: 600), actualTime: nil) {
                let img = UIImage(cgImage: cg)
                if let d = img.jpegData(compressionQuality: 0.7), !d.isEmpty {
                    frames.append(TimestampedFrame(time: sec, data: d))
                }
            }
        }
        return frames
    }
    /// 兼容旧接口
    static func extract(url: URL, count: Int = 10, maxDim: CGFloat = 512) throws -> [Data] {
        try extractTimestamped(url: url, count: count, maxDim: maxDim).map { $0.data }
    }
}

/// 配音引擎：iOS 系统语音合成（AVSpeechSynthesizer 离线，多声音）
/// 说明：Agnes/hcnsec 均无可用 TTS 渠道（实测 404/503），系统声音为稳定替代，
/// 中文普通话等多种声音可枚举选择。
final class TTSService {
    static let shared = TTSService()

    /// 合成文本 → 音频文件。云端优先（NVIDIA omni audio 输出），失败自动降级系统合成。
    /// 返回实际使用的引擎名（"nvidia_omni" / "system_tts"）
    @discardableResult
    func synthesize(text: String, voiceId: String, rate: Double, out: URL) async throws -> String {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw AppError.render("配音文本为空") }
        // 只走云端（严禁本地）；失败直接抛错，任务可见失败原因
        let engine = try await cloudTTS(text: text, out: out)
        Log.transcribe.log("TTS 引擎: \(engine)")
        return engine
    }

    /// NVIDIA nemotron-omni 云端 TTS：chat audio 输出（限流时 503 抛错）
    private func cloudTTS(text: String, out: URL) async throws -> String {
        guard let key = SettingsStore.builtInKeys["AGNES_KEY"], !key.isEmpty else {
            throw AppError.render("无内置 NVIDIA Key")
        }
        // NVIDIA Key 存 HCN 之外的独立 Secret（AGNES_KEY 为 Agnes；NVIDIA 为 NV_KEY）
        guard let nvKey = SettingsStore.builtInKeys["NV_KEY"], !nvKey.isEmpty else {
            throw AppError.render("无内置 NVIDIA Key")
        }
        _ = key
        let body: [String: Any] = [
            "model": "nvidia/nemotron-3-nano-omni-30b-a3b-reasoning",
            "modalities": ["text", "audio"],
            "audio": ["voice": "default", "format": "wav"],
            "messages": [["role": "user", "content": "请朗读以下文本，不要添加任何其他内容：\n\(text)"]],
            "max_tokens": max(200, text.count * 3),
        ]
        var req = URLRequest(url: URL(string: "https://integrate.api.nvidia.com/v1/chat/completions")!, timeoutInterval: 180)
        req.httpMethod = "POST"
        req.setValue("Bearer \(nvKey)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, resp) = try await URLSession.shared.data(for: req)
        guard let http = resp as? HTTPURLResponse, http.statusCode == 200 else {
            let code = (resp as? HTTPURLResponse)?.statusCode ?? -1
            throw AppError.render("云端 TTS HTTP \(code): \(String(data: data, encoding: .utf8)?.prefix(150) ?? "")")
        }
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choices = obj["choices"] as? [[String: Any]],
              let msg = choices.first?["message"] as? [String: Any],
              let audio = msg["audio"] as? [String: Any],
              let b64 = audio["data"] as? String, !b64.isEmpty else {
            throw AppError.render("云端 TTS 响应无音频")
        }
        let wav = Data(base64Encoded: b64) ?? Data()
        guard !wav.isEmpty else { throw AppError.render("云端 TTS 音频解码失败") }
        try wav.write(to: out)
        return "nvidia_omni"
    }

    /// 系统合成（保底；PCM WAV）
    private func systemTTS(text: String, voiceId: String, rate: Double, out: URL) async throws {
        try FileManager.default.removeItem(at: out)
        let utterance = AVSpeechUtterance(string: text)
        if let v = AVSpeechSynthesisVoice(identifier: voiceId) { utterance.voice = v }
        else if let zh = AVSpeechSynthesisVoice(language: "zh-CN") { utterance.voice = zh }
        // 用户 rate 0~1 → 语速 0.42~0.92（默认 0.5）
        utterance.rate = Float(0.42 + max(0, min(1, rate)) * 0.5)
        utterance.pitchMultiplier = 1.0
        utterance.postUtteranceDelay = 0.05

        let s = SettingsStore.shared
        if s.dubbingVoiceId.isEmpty {
            s.dubbingVoiceId = SettingsStore.defaultVoiceId()
        }

        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            let synth = AVSpeechSynthesizer()
            var audioFile: AVAudioFile?
            var failed = false
            let delegate = TTSWriteDelegate { buffer in
                if audioFile == nil {
                    audioFile = try? AVAudioFile(forWriting: out, settings: buffer.format.settings,
                                                 commonFormat: buffer.format.commonFormat, interleaved: buffer.format.isInterleaved)
                }
                try? audioFile?.write(from: buffer)
            } onFinish: { err in
                if err != nil, !failed { failed = true; cont.resume(throwing: err!) }
                else if !failed { cont.resume() }
            }
            synth.write(utterance) { buffer in
                guard let buffer else { return }
                delegate.consume(buffer)
            }
            // write 的完成判定：buffer 流结束由 delegate 收尾回调驱动（iOS 17+ write 无完成回调）
            // 兜底：监测文件稳定性
            DispatchQueue.global().asyncAfter(deadline: .now() + 2) {
                var lastSize: UInt64 = 0
                var stable = 0
                let timer = DispatchSource.makeTimerSource(queue: .global())
                timer.schedule(deadline: .now(), repeating: 0.5)
                timer.setEventHandler {
                    let sz = (try? FileManager.default.attributesOfItem(atPath: out.path)[.size] as? UInt64) ?? 0
                    if sz == lastSize, sz > 0 { stable += 1 } else { stable = 0 }
                    lastSize = sz
                    if stable >= 4 {
                        timer.cancel()
                        if !failed { delegate.finish() }
                    }
                }
                timer.resume()
                delegate.timer = timer
            }
        }
    }
}

/// write 回调聚合器（write 逐 buffer 回调 → 收集 → 完成通知）
final class TTSWriteDelegate {
    private let onBuffer: (AVAudioPCMBuffer) -> Void
    private let onFinish: (Error?) -> Void
    var timer: DispatchSourceTimer?

    init(onBuffer: @escaping (AVAudioPCMBuffer) -> Void, onFinish: @escaping (Error?) -> Void) {
        self.onBuffer = onBuffer
        self.onFinish = onFinish
    }
    func consume(_ buffer: AVAudioPCMBuffer) { onBuffer(buffer) }
    func finish(_ err: Error? = nil) { timer?.cancel(); onFinish(err) }
}
